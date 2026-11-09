// nendo, White Noise's layout engine. This file holds its public types.
//
// nendo is an altered version of software under the following license.
//
// zlib/libpng license
//
// Copyright (c) 2024 Nic Barker
//
// This software is provided 'as-is', without any express or implied warranty.
// In no event will the authors be held liable for any damages arising from the
// use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
//     1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software in a
//     product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//     2. Altered source versions must be plainly marked as such, and must not
//     be misrepresented as being the original software.
//
//     3. This notice may not be removed or altered from any source
//     distribution.
//
// This is an altered version: translated from C to Odin by the White Noise
// Linux authors, with White Noise's own fixes and an Odin-shaped API.
package nendo

Vector2 :: [2]f32
Color :: [4]f32

Dimensions :: struct {
	width, height: f32,
}

Rect :: struct {
	x, y, width, height: f32,
}

Radius :: struct {
	top_left, top_right, bottom_left, bottom_right: f32,
}

Padding :: struct {
	left, right, top, bottom: u16,
}

Border_Width :: struct {
	left, right, top, bottom, between: u16,
}

Border :: struct {
	color: Color,
	width: Border_Width,
}

Id :: struct {
	id, offset, base_id: u32,
	label:               string,
}

Size_Kind :: enum u8 {
	Fit,
	Grow,
	Percent,
	Fixed,
}

Size :: struct {
	min, max, percent: f32,
	kind:              Size_Kind,
}

Direction :: enum u8 {
	Row,
	Column,
}

Align_X :: enum u8 {
	Left,
	Right,
	Center,
}

Align_Y :: enum u8 {
	Top,
	Bottom,
	Center,
}

Align :: struct {
	x: Align_X,
	y: Align_Y,
}

Wrap :: enum u8 {
	Words,
	Newlines,
	None,
}

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Text_Style :: struct {
	user_data:   rawptr,
	color:       Color,
	font:        u16,
	size:        u16,
	spacing:     u16,
	line_height: u16,
	wrap:        Wrap,
	align:       Text_Align,
}

// `x`/`y` clip overflowing children on that axis; `offset` shifts every child,
// and `scroll` sets it to the element's retained scroll position.
Clip :: struct {
	x, y:   bool,
	scroll: bool,
	offset: Vector2,
}

Attach_Point :: enum u8 {
	Left_Top,
	Left_Center,
	Left_Bottom,
	Center_Top,
	Center_Center,
	Center_Bottom,
	Right_Top,
	Right_Center,
	Right_Bottom,
}

Attach_Points :: struct {
	element, parent: Attach_Point,
}

Pointer_Capture :: enum u8 {
	Capture,
	Passthrough,
}

Attach_To :: enum u8 {
	None,
	Parent,
	Element,
	Root,
}

Clip_To :: enum u8 {
	None,
	Parent,
}

Floating :: struct {
	offset:    Vector2,
	expand:    Dimensions,
	parent:    u32,
	z:         i16,
	attach:    Attach_Points,
	pointer:   Pointer_Capture,
	attach_to: Attach_To,
	clip_to:   Clip_To,
}

Transition_Data :: struct {
	rect:           Rect,
	color, overlay: Color,
	border_color:   Color,
	border_width:   Border_Width,
}

Transition_State :: enum i32 {
	Idle,
	Entering,
	Transitioning,
	Exiting,
}

Transition_Property :: enum i32 {
	X,
	Y,
	Width,
	Height,
	Color,
	Overlay,
	Radius,
	Border_Color,
	Border_Width,
}

Transition_Properties :: bit_set[Transition_Property;i32]
TRANSITION_POSITION :: Transition_Properties{.X, .Y}
TRANSITION_DIMENSIONS :: Transition_Properties{.Width, .Height}
TRANSITION_RECT :: TRANSITION_POSITION + TRANSITION_DIMENSIONS
TRANSITION_BORDER :: Transition_Properties{.Border_Color, .Border_Width}

Transition_Args :: struct {
	state:             Transition_State,
	initial:           Transition_Data,
	current:           ^Transition_Data,
	target:            Transition_Data,
	elapsed, duration: f32,
	properties:        Transition_Properties,
}

Enter_Trigger :: enum u8 {
	Skip_On_First_Parent_Frame,
	Trigger_On_First_Parent_Frame,
}

Exit_Trigger :: enum u8 {
	Skip_When_Parent_Exits,
	Trigger_When_Parent_Exits,
}

Transition_Interaction :: enum u8 {
	Disable_While_Moving,
	Allow_While_Moving,
}

Exit_Order :: enum u8 {
	Underneath_Siblings,
	Natural_Order,
	Above_Siblings,
}

Transition :: struct {
	handler:     proc(args: Transition_Args) -> bool,
	duration:    f32,
	properties:  Transition_Properties,
	interaction: Transition_Interaction,
	enter:       struct {
		initial: proc(
			target: Transition_Data,
			properties: Transition_Properties,
		) -> Transition_Data,
		trigger: Enter_Trigger,
	},
	exit:        struct {
		final:   proc(
			initial: Transition_Data,
			properties: Transition_Properties,
		) -> Transition_Data,
		trigger: Exit_Trigger,
		order:   Exit_Order,
	},
}

// An element declaration, also stored as the element's config.
Box :: struct {
	width, height: Size,
	padding:       Padding,
	gap:           u16,
	align:         Align,
	direction:     Direction,
	color:         Color,
	overlay:       Color,
	radius:        Radius,
	aspect:        f32,
	image:         rawptr,
	custom:        rawptr,
	floating:      Floating,
	clip:          Clip,
	border:        Border,
	transition:    Transition,
	user_data:     rawptr,
}

Command_Kind :: enum u8 {
	None,
	Rectangle,
	Border,
	Text,
	Image,
	Scissor_Start,
	Scissor_End,
	Overlay_Start,
	Overlay_End,
	Custom,
}

Rectangle_Command :: struct {
	color:  Color,
	radius: Radius,
}

Text_Command :: struct {
	text:                             string,
	color:                            Color,
	font, size, spacing, line_height: u16,
}

Image_Command :: struct {
	color:  Color,
	radius: Radius,
	image:  rawptr,
}

Custom_Command :: struct {
	color:  Color,
	radius: Radius,
	custom: rawptr,
}

Border_Command :: struct {
	color:  Color,
	fill:   Color, // the element's own fill, so a renderer can shade the edge against it
	radius: Radius,
	width:  Border_Width,
}

Clip_Command :: struct {
	x, y: bool,
}

Overlay_Command :: struct {
	color: Color,
}

Command_Data :: struct #raw_union {
	rectangle: Rectangle_Command,
	text:      Text_Command,
	image:     Image_Command,
	custom:    Custom_Command,
	border:    Border_Command,
	clip:      Clip_Command,
	overlay:   Overlay_Command,
}

Render_Command :: struct {
	rect:       Rect,
	using data: Command_Data,
	user_data:  rawptr,
	id:         u32,
	z:          i16,
	kind:       Command_Kind,
}

Element_Data :: struct {
	rect:  Rect,
	found: bool,
}

// `position` points at the engine's own scroll position; writing it scrolls.
Scroll_Data :: struct {
	position: ^Vector2,
	viewport: Dimensions,
	content:  Dimensions,
	clip:     Clip,
	found:    bool,
}

Pointer_State :: enum u8 {
	Pressed_This_Frame,
	Pressed,
	Released_This_Frame,
	Released,
}

Pointer :: struct {
	position: Vector2,
	state:    Pointer_State,
}

Pointer_Button :: enum u8 {
	Up,
	Down,
}

Drag_Scroll :: enum u8 {
	Off,
	On,
}

Error_Kind :: enum u8 {
	Text_Measurement_Function_Not_Provided,
	Arena_Capacity_Exceeded,
	Elements_Capacity_Exceeded,
	Text_Measurement_Capacity_Exceeded,
	Duplicate_Id,
	Floating_Container_Parent_Not_Found,
	Percentage_Over_1,
	Internal_Error,
	Unbalanced_Open_Close,
	Hash_Map_Capacity_Exceeded,
}

Error :: struct {
	kind:      Error_Kind,
	text:      string,
	user_data: rawptr,
}

Error_Handler :: struct {
	handler:   proc(error: Error),
	user_data: rawptr,
}

Measure_Text :: proc(text: string, style: ^Text_Style, user_data: rawptr) -> Dimensions
