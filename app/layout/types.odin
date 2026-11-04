// Public types of the layout engine, a native Odin port of clay
// (https://github.com/nicbarker/clay, pinned e6cc369) with White Noise's
// local changes folded in. Field names and layouts follow clay's Odin
// binding, so callers read the same as they did against the C library.
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
// Linux authors, without the debug view or external scroll handling, and with
// White Noise's fixes to hash map reuse, scroll targeting and reflow, floating
// layers, nested clip hit testing and CJK line breaking.
package clay

String :: struct {
	isStaticallyAllocated: bool,
	length:                i32,
	chars:                 [^]u8,
}

StringSlice :: struct {
	length:    i32,
	chars:     [^]u8,
	baseChars: [^]u8,
}

Vector2 :: [2]f32

Dimensions :: struct {
	width:  f32,
	height: f32,
}

Arena :: struct {
	nextAllocation: uintptr,
	capacity:       uint,
	memory:         [^]u8,
}

BoundingBox :: struct {
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

Color :: [4]f32

CornerRadius :: struct {
	topLeft:     f32,
	topRight:    f32,
	bottomLeft:  f32,
	bottomRight: f32,
}

ElementId :: struct {
	id:       u32,
	offset:   u32,
	baseId:   u32,
	stringId: String,
}

ClayArray :: struct($type: typeid) {
	capacity:      i32,
	length:        i32,
	internalArray: [^]type,
}

ElementIdArray :: ClayArray(ElementId)

RenderCommandType :: enum u8 {
	None,
	Rectangle,
	Border,
	Text,
	Image,
	ScissorStart,
	ScissorEnd,
	OverlayColorStart,
	OverlayColorEnd,
	Custom,
}

RectangleElementConfig :: struct {
	color: Color,
}

TextWrapMode :: enum u8 {
	Words,
	Newlines,
	None,
}

TextAlignment :: enum u8 {
	Left,
	Center,
	Right,
}

TextElementConfig :: struct {
	userData:      rawptr,
	textColor:     Color,
	fontId:        u16,
	fontSize:      u16,
	letterSpacing: u16,
	lineHeight:    u16,
	wrapMode:      TextWrapMode,
	textAlignment: TextAlignment,
}

AspectRatioElementConfig :: struct {
	aspectRatio: f32,
}

ImageElementConfig :: struct {
	imageData: rawptr,
}

CustomElementConfig :: struct {
	customData: rawptr,
}

BorderWidth :: struct {
	left:            u16,
	right:           u16,
	top:             u16,
	bottom:          u16,
	betweenChildren: u16,
}

BorderElementConfig :: struct {
	color: Color,
	width: BorderWidth,
}

TransitionData :: struct {
	boundingBox:     BoundingBox,
	backgroundColor: Color,
	overlayColor:    Color,
	borderColor:     Color,
	borderWidth:     BorderWidth,
}

TransitionState :: enum i32 {
	Idle,
	Entering,
	Transitioning,
	Exiting,
}

TransitionProperty :: enum i32 {
	X,
	Y,
	Width,
	Height,
	BackgroundColor,
	OverlayColor,
	CornerRadius,
	BorderColor,
	BorderWidth,
}

TransitionPropertyFlags :: bit_set[TransitionProperty;i32]
TransitionPropertyPosition :: TransitionPropertyFlags{.X, .Y}
TransitionPropertyDimensions :: TransitionPropertyFlags{.Width, .Height}
TransitionPropertyBoundingBox :: TransitionPropertyPosition + TransitionPropertyDimensions
TransitionPropertyBorder :: TransitionPropertyFlags{.BorderColor, .BorderWidth}

TransitionCallbackArguments :: struct {
	transitionState: TransitionState,
	initial:         TransitionData,
	current:         ^TransitionData,
	target:          TransitionData,
	elapsedTime:     f32,
	duration:        f32,
	properties:      TransitionPropertyFlags,
}

TransitionEnterTriggerType :: enum u8 {
	SkipOnFirstParentFrame,
	TriggerOnFirstParentFrame,
}

TransitionExitTriggerType :: enum u8 {
	SkipWhenParentExits,
	TriggerWhenParentExits,
}

TransitionInteractionHandlingType :: enum u8 {
	DisableInteractionsWhileTransitioningPosition,
	AllowInteractionsWhileTransitioningPosition,
}

ExitTransitionSiblingOrdering :: enum u8 {
	UnderneathSiblings,
	NaturalOrder,
	AboveSiblings,
}

TransitionElementConfig :: struct {
	handler:             proc(args: TransitionCallbackArguments) -> bool,
	duration:            f32,
	properties:          TransitionPropertyFlags,
	interactionHandling: TransitionInteractionHandlingType,
	enter:               struct {
		setInitialState: proc(
			targetState: TransitionData,
			properties: TransitionPropertyFlags,
		) -> TransitionData,
		trigger:         TransitionEnterTriggerType,
	},
	exit:                struct {
		setFinalState:   proc(
			initialState: TransitionData,
			properties: TransitionPropertyFlags,
		) -> TransitionData,
		trigger:         TransitionExitTriggerType,
		siblingOrdering: ExitTransitionSiblingOrdering,
	},
}

ClipElementConfig :: struct {
	horizontal:  bool, // clip overflowing elements on the "X" axis
	vertical:    bool, // clip overflowing elements on the "Y" axis
	childOffset: Vector2, // offsets the [X,Y] positions of all child elements, primarily for scrolling containers
}

FloatingAttachPointType :: enum u8 {
	LeftTop,
	LeftCenter,
	LeftBottom,
	CenterTop,
	CenterCenter,
	CenterBottom,
	RightTop,
	RightCenter,
	RightBottom,
}

FloatingAttachPoints :: struct {
	element: FloatingAttachPointType,
	parent:  FloatingAttachPointType,
}

PointerCaptureMode :: enum u8 {
	Capture,
	Passthrough,
}

FloatingAttachToElement :: enum u8 {
	None,
	Parent,
	ElementWithId,
	Root,
}

FloatingClipToElement :: enum u8 {
	None,
	AttachedParent,
}

FloatingElementConfig :: struct {
	offset:             Vector2,
	expand:             Dimensions,
	parentId:           u32,
	zIndex:             i16,
	attachment:         FloatingAttachPoints,
	pointerCaptureMode: PointerCaptureMode,
	attachTo:           FloatingAttachToElement,
	clipTo:             FloatingClipToElement,
}

TextRenderData :: struct {
	stringContents: StringSlice,
	textColor:      Color,
	fontId:         u16,
	fontSize:       u16,
	letterSpacing:  u16,
	lineHeight:     u16,
}

RectangleRenderData :: struct {
	backgroundColor: Color,
	cornerRadius:    CornerRadius,
}

ImageRenderData :: struct {
	backgroundColor: Color,
	cornerRadius:    CornerRadius,
	imageData:       rawptr,
}

CustomRenderData :: struct {
	backgroundColor: Color,
	cornerRadius:    CornerRadius,
	customData:      rawptr,
}

ClipRenderData :: struct {
	horizontal: bool,
	vertical:   bool,
}

OverlayColorRenderData :: struct {
	color: Color,
}

BorderRenderData :: struct {
	color:        Color,
	cornerRadius: CornerRadius,
	width:        BorderWidth,
}

RenderCommandData :: struct #raw_union {
	rectangle:    RectangleRenderData,
	text:         TextRenderData,
	image:        ImageRenderData,
	custom:       CustomRenderData,
	border:       BorderRenderData,
	clip:         ClipRenderData,
	overlayColor: OverlayColorRenderData,
}

RenderCommand :: struct {
	boundingBox: BoundingBox,
	renderData:  RenderCommandData,
	userData:    rawptr,
	id:          u32,
	zIndex:      i16,
	commandType: RenderCommandType,
}

ScrollContainerData :: struct {
	// Note: This is a pointer to the real internal scroll position, mutating it may cause a change in final layout.
	// Intended for use with external functionality that modifies scroll position, such as scroll bars or auto scrolling.
	scrollPosition:            ^Vector2,
	scrollContainerDimensions: Dimensions,
	contentDimensions:         Dimensions,
	config:                    ClipElementConfig,
	// Indicates whether an actual scroll container matched the provided ID or if the default struct was returned.
	found:                     bool,
}

ElementData :: struct {
	boundingBox: BoundingBox,
	found:       bool,
}

PointerDataInteractionState :: enum u8 {
	PressedThisFrame,
	Pressed,
	ReleasedThisFrame,
	Released,
}

PointerData :: struct {
	position: Vector2,
	state:    PointerDataInteractionState,
}

SizingType :: enum u8 {
	Fit,
	Grow,
	Percent,
	Fixed,
}

SizingConstraintsMinMax :: struct {
	min: f32,
	max: f32,
}

SizingConstraints :: struct #raw_union {
	sizeMinMax:  SizingConstraintsMinMax,
	sizePercent: f32,
}

SizingAxis :: struct {
	// Note: `min` is used for SizingPercent, slightly different to clay.h due to lack of C anonymous unions
	constraints: SizingConstraints,
	type:        SizingType,
}

Sizing :: struct {
	width:  SizingAxis,
	height: SizingAxis,
}

Padding :: struct {
	left:   u16,
	right:  u16,
	top:    u16,
	bottom: u16,
}

LayoutDirection :: enum u8 {
	LeftToRight,
	TopToBottom,
}

LayoutAlignmentX :: enum u8 {
	Left,
	Right,
	Center,
}

LayoutAlignmentY :: enum u8 {
	Top,
	Bottom,
	Center,
}

ChildAlignment :: struct {
	x: LayoutAlignmentX,
	y: LayoutAlignmentY,
}

LayoutConfig :: struct {
	sizing:          Sizing,
	padding:         Padding,
	childGap:        u16,
	childAlignment:  ChildAlignment,
	layoutDirection: LayoutDirection,
}

ElementDeclaration :: struct {
	layout:          LayoutConfig,
	backgroundColor: Color,
	overlayColor:    Color,
	cornerRadius:    CornerRadius,
	aspectRatio:     AspectRatioElementConfig,
	image:           ImageElementConfig,
	floating:        FloatingElementConfig,
	custom:          CustomElementConfig,
	clip:            ClipElementConfig,
	border:          BorderElementConfig,
	transition:      TransitionElementConfig,
	userData:        rawptr,
}

ErrorType :: enum u8 {
	TextMeasurementFunctionNotProvided,
	ArenaCapacityExceeded,
	ElementsCapacityExceeded,
	TextMeasurementCapacityExceeded,
	DuplicateId,
	FloatingContainerParentNotFound,
	PercentageOver1,
	InternalError,
	UnbalancedOpenClose,
	HashMapCapacityExceeded,
}

ErrorData :: struct {
	errorType: ErrorType,
	errorText: String,
	userData:  rawptr,
}

ErrorHandler :: struct {
	handler:  proc(errorData: ErrorData),
	userData: rawptr,
}

MeasureTextFunction :: proc(
	text: StringSlice,
	config: ^TextElementConfig,
	userData: rawptr,
) -> Dimensions

OnHoverFunction :: proc(elementId: ElementId, pointerData: PointerData, userData: rawptr)
