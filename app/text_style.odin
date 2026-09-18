package main

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
text_font :: proc(fonts: string, at: int) -> u16 {
	return len(fonts) > 0 ? u16(fonts[at]) : FONT_BODY
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
			for end < len(text) && fonts[end] == fonts[at] { end += 1 }
			clay.Text(text[at:end], {fontId = u16(fonts[at]), fontSize = size, textColor = color, wrapMode = .None})
			at = end
		}
	}
}
