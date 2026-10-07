package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:strings"
import rl "sdlrl"

@(private)
TIMESTAMP_CLOCK :: "\uf017 "

// Source ranges stay immutable. Display text, font bytes and link ranges share
// the same replacement pass, so wrapping and selection see the current label.
@(private)
timestamp_text :: proc(
	text, fonts: string,
	links: [dynamic]Inline_Link,
	stamps: []Md_Timestamp,
	now: i64,
) -> (
	string,
	string,
	[dynamic]Inline_Link,
) {
	if len(stamps) == 0 {return text, fonts, links}
	builder := strings.builder_make(context.temp_allocator)
	styles := strings.builder_make(context.temp_allocator)
	deltas := make([]int, len(stamps) + 1, context.temp_allocator)
	tips := make([]Inline_Link, len(stamps), context.temp_allocator)
	at := 0
	for stamp, i in stamps {
		strings.write_string(&builder, text[at:stamp.start])
		for j in at ..< stamp.start {strings.write_byte(&styles, len(fonts) > 0 ? fonts[j] : u8(FONT_BODY))}
		start := strings.builder_len(builder)
		label := fmt.tprintf(
			"%s%s",
			TIMESTAMP_CLOCK,
			timestamp_label(stamp.seconds, stamp.style, now),
		)
		strings.write_string(&builder, label)
		style := len(fonts) > 0 ? fonts[stamp.start] : u8(FONT_BODY)
		for j in 0 ..< len(label) {
			strings.write_byte(
				&styles,
				j < len(TIMESTAMP_CLOCK) - 1 ? (style & ~TEXT_FONT_MASK) | FONT_ICON : style,
			)
		}
		tips[i] = {
			start = start,
			end   = strings.builder_len(builder),
			stamp = &stamps[i],
		}
		deltas[i + 1] = deltas[i] + len(label) - (stamp.end - stamp.start)
		at = stamp.end
	}
	strings.write_string(&builder, text[at:])
	for j in at ..< len(text) {strings.write_byte(&styles, len(fonts) > 0 ? fonts[j] : u8(FONT_BODY))}
	mapped := make([dynamic]Inline_Link, len(links), len(links), context.temp_allocator)
	for link, i in links {
		mapped[i] = link
		mapped[i].start = timestamp_offset(link.start, stamps, deltas)
		mapped[i].end = timestamp_offset(link.end, stamps, deltas)
	}
	// Split links at timestamp boundaries. Each label has one tooltip while
	// every surrounding or wrapped link fragment keeps its destination.
	runs := make([dynamic]Inline_Link, 0, len(links) + len(stamps) * 2, context.temp_allocator)
	link_index := 0
	for &tip in tips {
		for link_index < len(mapped) && mapped[link_index].end <= tip.start {
			append(&runs, mapped[link_index])
			link_index += 1
		}
		if link_index < len(mapped) && mapped[link_index].start < tip.end {
			link := &mapped[link_index]
			if link.start < tip.start {
				before := link^
				before.end = tip.start
				append(&runs, before)
			}
			tip.url = link.url
			link.start = tip.end
			if link.start >= link.end {link_index += 1}
		}
		append(&runs, tip)
	}
	append(&runs, ..mapped[link_index:])
	return strings.to_string(builder), strings.to_string(styles), runs
}

@(private)
timestamp_tooltip :: proc(stamp: ^Md_Timestamp) {
	date := timestamp_label(stamp.seconds, .LONG_DATE_TIME, 0)
	token := timestamp_token(stamp.seconds, stamp.style)
	width :=
		max(
			rl.MeasureTextLine(FONT_BODY, 11, date, 0).x,
			rl.MeasureTextLine(FONT_BODY, 11, token, 0).x,
		) +
		16
	box := clay.GetElementData({id = clay.GetOpenElementId()}).boundingBox
	left := box.x + box.width / 2 - width / 2
	x, _ := panel_pos(left, box.y, width, 0)
	tooltip(fmt.tprintf("%s\n%s", date, token), .Below, x - left)
}

@(private = "file")
timestamp_offset :: proc(offset: int, stamps: []Md_Timestamp, deltas: []int) -> int {
	lo, hi := 0, len(stamps)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if stamps[mid].end <= offset {lo = mid + 1} else {hi = mid}
	}
	return offset + deltas[lo]
}

@(private)
timestamp_block :: proc(source: Md_Block_Ui, now: i64) -> Md_Block_Ui {
	if len(source.timestamps) == 0 {return source}
	block := source
	stamps := source.timestamps[:]
	if block.kind != .Table {
		text, fonts, links := timestamp_text(block.text, block.fonts, block.links, stamps, now)
		block.text, block.fonts, block.links = text, fonts, links
		return block
	}
	block.cells = make([][]string, len(source.cells), context.temp_allocator)
	block.cell_fonts = make([][]string, len(source.cell_fonts), context.temp_allocator)
	block.cell_links = make(
		[][][dynamic]Inline_Link,
		len(source.cell_links),
		context.temp_allocator,
	)
	copy(block.cells, source.cells)
	copy(block.cell_fonts, source.cell_fonts)
	copy(block.cell_links, source.cell_links)
	at := 0
	for at < len(stamps) {
		r := stamps[at].row
		block.cells[r] = make([]string, len(source.cells[r]), context.temp_allocator)
		block.cell_fonts[r] = make([]string, len(source.cell_fonts[r]), context.temp_allocator)
		block.cell_links[r] = make(
			[][dynamic]Inline_Link,
			len(source.cell_links[r]),
			context.temp_allocator,
		)
		copy(block.cells[r], source.cells[r])
		copy(block.cell_fonts[r], source.cell_fonts[r])
		copy(block.cell_links[r], source.cell_links[r])
		for at < len(stamps) && stamps[at].row == r {
			c := stamps[at].cell
			end := at + 1
			for end < len(stamps) && stamps[end].row == r && stamps[end].cell == c {end += 1}
			text, fonts, links := timestamp_text(
				block.cells[r][c],
				block.cell_fonts[r][c],
				block.cell_links[r][c],
				stamps[at:end],
				now,
			)
			block.cells[r][c], block.cell_fonts[r][c] = text, fonts
			block.cell_links[r][c] = links
			at = end
		}
	}
	return block
}

@(private)
timestamps_clone :: proc(
	stamps: []Md_Timestamp,
	lo: int = 0,
	hi: int = max(int),
) -> [dynamic]Md_Timestamp {
	owned: [dynamic]Md_Timestamp
	for stamp in stamps {
		if stamp.start < lo || stamp.end > hi {continue}
		copy := stamp
		copy.start -= lo
		copy.end -= lo
		append(&owned, copy)
	}
	return owned
}
