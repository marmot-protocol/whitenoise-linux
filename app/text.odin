// Markdown attachments (.md/.markdown), and font
// attachments (.ttf/.otf) rendered as a type specimen.
//
// The markdown here is line-level: headings, fenced code, quotes,
// list items, rules; consecutive plain lines join into paragraphs.
// That matches the message renderer's block model (Md_Block_Ui), so
// the tiles and the preview modal reuse the same md_blocks pass.
package main

import "core:fmt"
import "core:strings"

import rl "sdlrl"

TXT_MAX_BLOCKS :: 400 // parse cap
TXT_TILE_BLOCKS :: 20 // blocks shown on the tile (modal shows more)
TXT_MODAL_BLOCKS :: 80

Txt_View :: struct {
	blocks: [dynamic]Md_Block_Ui, // block texts owned by the view
}

txt_view_make :: proc(text: string) -> ^Txt_View {
	view := new(Txt_View)
	view.blocks = parse_md_text(text)
	return view
}

txt_view_free :: proc(view: ^Txt_View) {
	for block in view.blocks {
		delete(block.text)
	}
	delete(view.blocks)
	free(view)
}

@(private = "file")
flush_para :: proc(blocks: ^[dynamic]Md_Block_Ui, para: ^strings.Builder) {
	if strings.builder_len(para^) > 0 {
		append(blocks, Md_Block_Ui{kind = .Para, text = strings.clone(strings.to_string(para^))})
		strings.builder_reset(para)
	}
}

parse_md_text :: proc(text: string) -> [dynamic]Md_Block_Ui {
	blocks: [dynamic]Md_Block_Ui
	para, code: strings.Builder
	strings.builder_init(&para)
	strings.builder_init(&code)
	defer strings.builder_destroy(&para)
	defer strings.builder_destroy(&code)
	in_code := false

	it := text
	for line in strings.split_lines_iterator(&it) {
		if len(blocks) >= TXT_MAX_BLOCKS {
			break
		}
		l := strings.trim_right_space(line)
		t := strings.trim_space(l)

		if in_code {
			if strings.has_prefix(t, "```") {
				append(&blocks, Md_Block_Ui{kind = .Code, text = strings.clone(strings.to_string(code))})
				strings.builder_reset(&code)
				in_code = false
			} else {
				if strings.builder_len(code) > 0 {
					strings.write_byte(&code, '\n')
				}
				strings.write_string(&code, l)
			}
			continue
		}

		switch {
		case strings.has_prefix(t, "```"):
			flush_para(&blocks, &para)
			in_code = true
		case len(t) == 0:
			flush_para(&blocks, &para)
		case strings.has_prefix(t, "#"):
			flush_para(&blocks, &para)
			level := 0
			for level < len(t) && t[level] == '#' {
				level += 1
			}
			append(&blocks, Md_Block_Ui{kind = .Heading, text = strings.clone(strings.trim_space(t[level:])), level = min(level, 6)})
		case t == "---" || t == "***" || t == "___":
			flush_para(&blocks, &para)
			append(&blocks, Md_Block_Ui{kind = .Rule})
		case strings.has_prefix(t, "> "):
			flush_para(&blocks, &para)
			append(&blocks, Md_Block_Ui{kind = .Quote, text = strings.clone(t[2:])})
		case strings.has_prefix(t, "- ") || strings.has_prefix(t, "* "):
			flush_para(&blocks, &para)
			append(&blocks, Md_Block_Ui{kind = .List_Item, text = fmt.aprintf("• %s", t[2:]), marker_len = len("• ")})
		case:
			if strings.builder_len(para) > 0 {
				strings.write_byte(&para, ' ')
			}
			strings.write_string(&para, t)
		}
	}

	if in_code && strings.builder_len(code) > 0 {
		append(&blocks, Md_Block_Ui{kind = .Code, text = strings.clone(strings.to_string(code))})
	}
	flush_para(&blocks, &para)
	return blocks
}

// Font specimen: pangram lines at a few sizes, rasterized with the
// attachment's own font through stb_truetype.
Ttf_View :: struct {
	tex:  rl.Texture2D,
	w, h: i32,
}

SPECIMEN_LINES := []string{
	"AaBbCcDdEeFfGgHh 0123456789",
	"The quick brown fox jumps over the lazy dog.",
	"Sphinx of black quartz, judge my vow.",
}
SPECIMEN_SIZES := []f32{30, 20, 14}

// nil when stb can't parse the font.
ttf_view_make :: proc(data: []u8) -> ^Ttf_View {
	image := rl.FontSpecimen(data, SPECIMEN_LINES, SPECIMEN_SIZES, clay_color(TEXT), 640)
	if image.data == nil {
		return nil
	}
	defer delete(([^]u8)(image.data)[:image.width * image.height * 4])
	tex := rl.LoadTextureFromImage(image)
	view := new(Ttf_View)
	view^ = {tex = tex, w = tex.width, h = tex.height}
	return view
}

ttf_view_free :: proc(view: ^Ttf_View) {
	rl.UnloadTexture(view.tex)
	free(view)
}
