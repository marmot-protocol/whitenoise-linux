package main

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
TEXT_FONT_MASK :: u8(7)
@(private)
TEXT_STRIKE :: u8(8)
@(private)
TEXT_CODE :: u8(16)
@(private)
TEXT_MATH :: u8(32)

@(private)
text_font :: proc(fonts: string, at: int) -> u16 {
	return len(fonts) > 0 ? u16(fonts[at] & TEXT_FONT_MASK) : FONT_BODY
}

@(private)
text_literal :: proc(fonts: string, at: int) -> bool {
	return len(fonts) > 0 && fonts[at] & (TEXT_CODE | TEXT_MATH) != 0
}

@(private)
text_fonts :: proc(fonts: string, start, end: int) -> string {
	return len(fonts) > 0 ? fonts[start:end] : ""
}

// Style changes stay inside one inline segment, without adding spacing.
@(private)
styled_text :: proc(text, fonts: string, size: u16, color: clay.Color) {
	if len(fonts) == 0 {
		clay.Text(text, {fontId = FONT_BODY, fontSize = size, textColor = color})
		return
	}
	if clay.UI()({layout = {childAlignment = {y = .Center}}}) {
		for at := 0; at < len(text); {
			end := at + 1
			for end < len(text) && fonts[end] == fonts[at] {end += 1}
			clay.Text(
				text[at:end],
				{
					fontId = text_font(fonts, at),
					fontSize = size,
					textColor = fonts[at] & TEXT_MATH != 0 ? ACCENT : color,
					wrapMode = .None,
					userData = rawptr(uintptr(fonts[at] & ~TEXT_FONT_MASK)),
				},
			)
			at = end
		}
	}
}
