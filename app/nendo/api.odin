package nendo

// Declaration sugar:
//
//   if nendo.box(nendo.id("Row"))({direction = .Column, ...}) {
//       ...children
//   }
//
// box opens the element and returns the configure proc; the deferred
// close_element runs when the caller's `if` block ends.

@(private)
configure :: proc(declaration: Box) -> bool {
	declaration := declaration
	if declaration.clip.scroll {
		declaration.clip.offset = get_scroll_offset()
	}
	configure_open_element_ptr(&declaration)
	return true
}

@(deferred_none = close_element)
box_with_id :: proc(id: Id) -> proc(declaration: Box) -> bool {
	open_element_with_id(id)
	return configure
}

@(deferred_none = close_element)
box_auto :: proc() -> proc(declaration: Box) -> bool {
	open_element()
	return configure
}

box :: proc {
	box_with_id,
	box_auto,
}

text :: proc {
	text_static,
	text_dynamic,
}

// A literal lives for the whole program, so its measurement caches by
// address instead of by content.
text_static :: proc($s: string, style: Text_Style) {
	wrapped := make_string(s)
	wrapped.is_static = true
	open_text_element(wrapped, style)
}

text_dynamic :: proc(s: string, style: Text_Style) {
	open_text_element(make_string(s), style)
}

pad :: proc(n: u16) -> Padding {
	return {left = n, right = n, top = n, bottom = n}
}

outline :: proc(w: u16) -> Border_Width {
	return {w, w, w, w, 0}
}

radius :: proc(r: f32) -> Radius {
	return Radius{r, r, r, r}
}

fit :: proc(min: f32 = 0, max: f32 = 0) -> Size {
	return Size{min = min, max = max, kind = .Fit}
}

grow :: proc(min: f32 = 0, max: f32 = 0) -> Size {
	return Size{min = min, max = max, kind = .Grow}
}

fixed :: proc(size: f32) -> Size {
	return Size{min = size, max = size, kind = .Fixed}
}

percent :: proc(p: f32) -> Size {
	return Size{percent = p, kind = .Percent}
}

@(private)
make_string :: proc(label: string) -> String {
	return String{chars = raw_data(label), length = i32(len(label))}
}

// The index seeds the label's hash, so ("Row", 3) and ("Row3", 0) differ.
id :: proc(label: string, index: u32 = 0) -> Id {
	return hash_string(make_string(label), index)
}

id_local :: proc(label: string, index: u32 = 0) -> Id {
	return hash_string_with_offset(make_string(label), index, open_id())
}
