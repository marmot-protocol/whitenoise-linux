package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:math"
import "core:strings"
import "core:unicode/utf16"
import rl "sdlrl"

@(private)
Secret_Ui :: struct {
	blocks: [dynamic]Md_Block_Ui,
	open:   bool,
}

// Rail and reply previews only need a short cover, never the hidden payload.
@(private)
chat_preview :: proc(text: string) -> string {
	cover, _ := hidden_message(text)
	PREVIEW_BYTES :: 256
	if len(cover) <= PREVIEW_BYTES {return cover}
	end := PREVIEW_BYTES
	for end > 0 && cover[end] & 0xc0 == 0x80 {end -= 1}
	return strings.concatenate({cover[:end], "…"}, context.temp_allocator)
}

// Decoding shrinks each layer. Keep nesting flat and parse Markdown once.
@(private)
secret_layers :: proc(client: ^marmot.Client, text: string) -> [dynamic]Secret_Ui {
	layers: [dynamic]Secret_Ui
	text := text
	for text != "" {
		cover, inner := hidden_message(text)
		layer: Secret_Ui
		doc: ^marmot.Markdown_Document
		if marmot.parse_markdown(
			   client,
			   strings.clone_to_cstring(cover, context.temp_allocator),
			   &doc,
		   ) ==
		   .OK {
			convert_blocks(
				&layer.blocks,
				doc.blocks,
				doc.blocks_len,
				false,
				([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
			)
			marmot.markdown_document_free(doc)
		}
		if len(layer.blocks) == 0 {
			append(&layer.blocks, Md_Block_Ui{kind = .Para, text = strings.clone(cover)})
		}
		append(&layers, layer)
		text = inner
	}
	return layers
}

@(private)
hidden_border: Model_Kind = .Hidden_Border

@(private)
hidden_border_draw :: proc(b: clay.BoundingBox) {
	STEPS :: 8
	WIDTH :: f32(2)
	radius := min(max(WIDTH, rr(8).topLeft), min(b.width, b.height) / 2)
	centers := [4]rl.Vector2 {
		{b.x + radius, b.y + radius},
		{b.x + b.width - radius, b.y + radius},
		{b.x + b.width - radius, b.y + b.height - radius},
		{b.x + radius, b.y + b.height - radius},
	}
	colors := [4]rl.FColor {
		{1, 0.25, 0.4, 1},
		{1, 0.8, 0.2, 1},
		{0.2, 0.85, 0.5, 1},
		{0.45, 0.35, 1, 1},
	}
	points: [4 * (STEPS + 1) * 2]rl.Vertex
	for center, corner in centers {
		for step in 0 ..= STEPS {
			angle := (f32(corner * 90) + f32(step) * 90 / STEPS + 180) * math.PI / 180
			x, y := math.cos(angle), math.sin(angle)
			i := (corner * (STEPS + 1) + step) * 2
			points[i] = {
				position = {center.x + x * radius, center.y + y * radius},
				color    = colors[corner],
			}
			points[i + 1] = {
				position = {center.x + x * (radius - WIDTH), center.y + y * (radius - WIDTH)},
				color    = colors[corner],
			}
		}
	}
	triangles: [len(points) * 3]rl.Vertex
	for i in 0 ..< len(points) / 2 {
		n := (i + 1) % (len(points) / 2)
		triangles[i * 6 + 0], triangles[i * 6 + 1], triangles[i * 6 + 2] =
			points[i * 2], points[i * 2 + 1], points[n * 2]
		triangles[i * 6 + 3], triangles[i * 6 + 4], triangles[i * 6 + 5] =
			points[i * 2 + 1], points[n * 2 + 1], points[n * 2]
	}
	rl.DrawTrianglesClipped(triangles[:], b.x, b.y, b.width, b.height)
}

// ZWNJ = 0, ZWJ = 1; ZWSP separates 16-bit UTF-16 code units.
// Validate whole runs so normal joiners and truncated payloads stay untouched.
@(private)
hidden_message :: proc(text: string) -> (cover, secret: string) {
	UNIT_BITS :: 16
	UNIT_BYTES :: UNIT_BITS * 3
	STRIDE :: UNIT_BYTES + 3
	context.allocator = context.temp_allocator
	visible, hidden: strings.Builder
	last, start := 0, -1
	for at := 0; at <= len(text); at += 1 {
		if at + 2 < len(text) &&
		   text[at] == 0xe2 &&
		   text[at + 1] == 0x80 &&
		   text[at + 2] >= 0x8b &&
		   text[at + 2] <= 0x8d {
			if start < 0 {start = at}
			at += 2
			continue
		}
		if start < 0 {continue}
		run := text[start:at]
		lo := start
		start = -1
		// Each unit is 48 bytes, followed by a 3-byte separator except the last.
		if (len(run) + 3) % STRIDE != 0 {continue}
		decoded: strings.Builder
		high: rune
		valid := true
		for pos := 0; pos < len(run); pos += STRIDE {
			value: rune
			for bit in 0 ..< UNIT_BITS {
				b := run[pos + bit * 3 + 2]
				if b != 0x8c && b != 0x8d {valid = false; break}
				value = value << 1 | rune(b - 0x8c)
			}
			if !valid ||
			   (pos + UNIT_BYTES < len(run) &&
					   run[pos + STRIDE - 1] != 0x8b) {valid = false; break}
			if high != 0 {
				if value < 0xdc00 || value > 0xdfff {valid = false; break}
				value = utf16.decode_surrogate_pair(high, value)
				high = 0
			} else if value >= 0xd800 && value <= 0xdbff {
				high = value
				continue
			} else if utf16.is_surrogate(value) {
				valid = false
				break
			}
			if value == 0 {valid = false; break}
			strings.write_rune(&decoded, value)
		}
		if !valid || high != 0 {continue}
		strings.write_string(&visible, text[last:lo])
		last = at
		if strings.builder_len(hidden) > 0 {strings.write_byte(&hidden, '\n')}
		strings.write_string(&hidden, strings.to_string(decoded))
	}
	if last == 0 {return text, ""}
	strings.write_string(&visible, text[last:])
	return strings.to_string(visible), strings.to_string(hidden)
}
