package clay

// Declaration sugar, kept call-compatible with clay's Odin binding:
//
//   if clay.UI(clay.ID("Row"))({layout = {...}}) {
//       ...children
//   }
//
// UI opens the element and returns the configure proc; the deferred
// close_element runs when the caller's `if` block ends.

ConfigureOpenElement :: proc(config: ElementDeclaration) -> bool {
	config := config
	configure_open_element_ptr(&config)
	return true
}

@(deferred_none = close_element)
UI_WithId :: proc(id: ElementId) -> proc(config: ElementDeclaration) -> bool {
	open_element_with_id(id)
	return ConfigureOpenElement
}

@(deferred_none = close_element)
UI_AutoId :: proc() -> proc(config: ElementDeclaration) -> bool {
	open_element()
	return ConfigureOpenElement
}

UI :: proc {
	UI_WithId,
	UI_AutoId,
}

Text :: proc {
	TextStatic,
	TextDynamic,
}

// A literal lives for the whole program, so its measurement caches by
// address instead of by content.
TextStatic :: proc($text: string, config: TextElementConfig) {
	wrapped := MakeString(text)
	wrapped.isStaticallyAllocated = true
	open_text_element(wrapped, config)
}

TextDynamic :: proc(text: string, config: TextElementConfig) {
	open_text_element(MakeString(text), config)
}

PaddingAll :: proc(allPadding: u16) -> Padding {
	return {left = allPadding, right = allPadding, top = allPadding, bottom = allPadding}
}

BorderOutside :: proc(width: u16) -> BorderWidth {
	return {width, width, width, width, 0}
}

BorderAll :: proc(width: u16) -> BorderWidth {
	return {width, width, width, width, width}
}

CornerRadiusAll :: proc(radius: f32) -> CornerRadius {
	return CornerRadius{radius, radius, radius, radius}
}

SizingFit :: proc(sizeMinMax: SizingConstraintsMinMax = {}) -> SizingAxis {
	return SizingAxis{type = SizingType.Fit, constraints = {sizeMinMax = sizeMinMax}}
}

SizingGrow :: proc(sizeMinMax: SizingConstraintsMinMax = {}) -> SizingAxis {
	return SizingAxis{type = SizingType.Grow, constraints = {sizeMinMax = sizeMinMax}}
}

SizingFixed :: proc(size: f32) -> SizingAxis {
	return SizingAxis{type = SizingType.Fixed, constraints = {sizeMinMax = {size, size}}}
}

SizingPercent :: proc(sizePercent: f32) -> SizingAxis {
	return SizingAxis{type = SizingType.Percent, constraints = {sizePercent = sizePercent}}
}

MakeString :: proc(label: string) -> String {
	return String{chars = raw_data(label), length = i32(len(label))}
}

// The index seeds the hash, as clay's Odin binding always did. C clay's
// CLAY_IDI offsets it instead; the two schemes give different ids.
ID :: proc(label: string, index: u32 = 0) -> ElementId {
	return hash_string(MakeString(label), index)
}

ID_LOCAL :: proc(label: string, index: u32 = 0) -> ElementId {
	return hash_string_with_offset(MakeString(label), index, GetOpenElementId())
}
