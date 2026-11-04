package clay

// Internal state: the context, its arena-backed arrays and memory setup.
//
// Every array lives in one caller-provided arena. Persistent arrays (hash
// maps, text cache, scroll and transition state) are carved once at
// Initialize; ephemeral ones (elements, render commands, scratch stacks)
// are re-carved from arenaResetOffset at every BeginLayout:
//
//   arena.memory
//   | Context | persistent arrays ... | ephemeral arrays ...   |
//                                     ^ arenaResetOffset

@(private)
MAX_FLOAT :: f32(3.40282346638528859812e+38)
@(private)
EPSILON :: f32(0.01)
@(private)
ROOT_CONTAINER :: "Clay__RootContainer"

@(private)
Boolean_Warnings :: struct {
	maxElementsExceeded:           bool,
	maxRenderCommandsExceeded:     bool,
	maxTextMeasureCacheExceeded:   bool,
	textMeasurementFunctionNotSet: bool,
	hashMapCapacityExceeded:       bool,
}

// A view into a ClayArray's storage, without its own capacity.
@(private)
Array_Slice :: struct($T: typeid) {
	length:        i32,
	internalArray: [^]T,
}

@(private)
Wrapped_Text_Line :: struct {
	dimensions: Dimensions,
	line:       String,
}

@(private)
Text_Element_Data :: struct {
	text:                String,
	preferredDimensions: Dimensions,
	wrappedLines:        Array_Slice(Wrapped_Text_Line),
}

@(private)
Layout_Element_Children :: struct {
	elements: [^]i32,
	length:   u16,
}

@(private)
Text_Element_Payload :: struct {
	textConfig:      TextElementConfig,
	textElementData: Text_Element_Data,
}

// A text element stores its text config where other elements store their
// declaration. Code that reads `config` on a text element reads the text
// payload's bytes, exactly as clay's C union does.
@(private)
Layout_Element_Data :: struct #raw_union {
	config:     ElementDeclaration,
	using text: Text_Element_Payload,
}

@(private)
Layout_Element :: struct {
	children:              Layout_Element_Children,
	dimensions:            Dimensions,
	minDimensions:         Dimensions,
	using data:            Layout_Element_Data,
	id:                    u32,
	floatingChildrenCount: u16,
	isTextElement:         bool,
	// True while the element is exit transitioning: a synthetic copy
	// retained from earlier frames.
	exiting:               bool,
}

@(private)
Scroll_Container_Data_Internal :: struct {
	layoutElement:       ^Layout_Element,
	boundingBox:         BoundingBox,
	contentSize:         Dimensions,
	scrollOrigin:        Vector2,
	pointerOrigin:       Vector2,
	scrollMomentum:      Vector2,
	scrollPosition:      Vector2,
	previousDelta:       Vector2,
	momentumTime:        f32,
	elementId:           u32,
	openThisFrame:       bool,
	pointerScrollActive: bool,
}

@(private)
Transition_Data_Internal :: struct {
	initialState:              TransitionData,
	currentState:              TransitionData,
	targetState:               TransitionData,
	elementThisFrame:          ^Layout_Element,
	oldParentRelativePosition: Vector2,
	elementId:                 u32,
	parentId:                  u32,
	siblingIndex:              u32,
	elapsedTime:               f32,
	state:                     TransitionState,
	transitionOut:             bool,
	reparented:                bool,
	activeProperties:          TransitionPropertyFlags,
}

@(private)
Layout_Element_Hash_Map_Item :: struct {
	boundingBox:           BoundingBox,
	elementId:             ElementId,
	layoutElement:         ^Layout_Element,
	onHoverFunction:       OnHoverFunction,
	hoverFunctionUserData: rawptr,
	nextIndex:             i32,
	generation:            u32,
	appearedThisFrame:     bool,
}

@(private)
Measured_Word :: struct {
	startOffset: i32,
	length:      i32,
	width:       f32,
	next:        i32,
}

@(private)
Measure_Text_Cache_Item :: struct {
	unwrappedDimensions:     Dimensions,
	measuredWordsStartIndex: i32,
	minWidth:                f32,
	containsNewlines:        bool,
	// Hash map data
	id:                      u32,
	nextIndex:               i32,
	generation:              u32,
}

@(private)
Layout_Element_Tree_Node :: struct {
	layoutElement:   ^Layout_Element,
	position:        Vector2,
	nextChildOffset: Vector2,
}

@(private)
Layout_Element_Tree_Root :: struct {
	layoutElementIndex: i32,
	parentId:           u32, // zero for the root layout tree
	clipElementId:      u32, // zero without a clip element
	zIndex:             i16,
}

Context :: struct {
	maxElementCount:                    i32,
	maxMeasureTextCacheWordCount:       i32,
	rootResizedLastFrame:               bool,
	errorHandler:                       ErrorHandler,
	booleanWarnings:                    Boolean_Warnings,
	pointerInfo:                        PointerData,
	layoutDimensions:                   Dimensions,
	disableCulling:                     bool,
	generation:                         u32,
	arenaResetOffset:                   uintptr,
	measureTextUserData:                rawptr,
	internalArena:                      Arena,
	// Layout elements and render commands
	layoutElements:                     ClayArray(Layout_Element),
	renderCommands:                     ClayArray(RenderCommand),
	openLayoutElementStack:             ClayArray(i32),
	layoutElementChildren:              ClayArray(i32),
	layoutElementChildrenBuffer:        ClayArray(i32),
	reusableElementIndexBuffer:         ClayArray(i32),
	layoutElementClipElementIds:        ClayArray(i32),
	// Misc data structures
	wrappedTextLines:                   ClayArray(Wrapped_Text_Line),
	layoutElementTreeNodeArray1:        ClayArray(Layout_Element_Tree_Node),
	layoutElementTreeRoots:             ClayArray(Layout_Element_Tree_Root),
	layoutElementsHashMapInternal:      ClayArray(Layout_Element_Hash_Map_Item),
	layoutElementsHashMap:              ClayArray(i32),
	layoutElementsHashMapFreeList:      ClayArray(i32),
	measureTextHashMapInternal:         ClayArray(Measure_Text_Cache_Item),
	measureTextHashMapInternalFreeList: ClayArray(i32),
	measureTextHashMap:                 ClayArray(i32),
	measuredWords:                      ClayArray(Measured_Word),
	measuredWordsFreeList:              ClayArray(i32),
	openClipElementStack:               ClayArray(i32),
	pointerOverIds:                     ElementIdArray,
	scrollContainerDatas:               ClayArray(Scroll_Container_Data_Internal),
	transitionDatas:                    ClayArray(Transition_Data_Internal),
	treeNodeVisited:                    ClayArray(bool),
}

@(private)
current_context: ^Context
@(private)
default_max_element_count: i32 = 8192
@(private)
default_max_measure_text_word_cache_count: i32 = 16384
// Process-wide like clay's, while its userData is per context.
@(private)
measure_text: MeasureTextFunction

// ── Helpers shared by every pass ────────────────────────────────────

// clay's CLAY__MAX/CLAY__MIN: the left operand wins ties and NaN
// comparisons, which the builtins do not promise.
@(private)
cmax :: #force_inline proc "contextless" (x, y: $T) -> T {
	return x > y ? x : y
}

@(private)
cmin :: #force_inline proc "contextless" (x, y: $T) -> T {
	return x < y ? x : y
}

@(private)
static_string :: proc "contextless" (text: string) -> String {
	return {isStaticallyAllocated = true, length = i32(len(text)), chars = raw_data(text)}
}

@(private)
report_error :: proc(type: ErrorType, text: string) {
	ctx := current_context
	ctx.errorHandler.handler(
		{errorType = type, errorText = static_string(text), userData = ctx.errorHandler.userData},
	)
}

@(private)
error_handler_default :: proc(errorData: ErrorData) {}

// ── Bounds-checked arrays ───────────────────────────────────────────
//
// clay answers an out-of-range access with an InternalError report and a
// shared, mutable default value per element type. Writes through that
// pointer persist and later failed reads observe them, so every accessor
// for a type shares one default.

@(private)
default_of :: proc "contextless" ($T: typeid) -> ^T {
	@(static) value: T
	return &value
}

@(private)
range_check :: proc(index, length: i32) -> bool {
	if index < length && index >= 0 {
		return true
	}
	report_error(
		.InternalError,
		"Clay attempted to make an out of bounds array access. This is an internal error and is likely a bug.",
	)
	return false
}

@(private)
add_capacity_check :: proc(length, capacity: i32) -> bool {
	if length < capacity {
		return true
	}
	report_error(
		.InternalError,
		"Clay attempted to make an out of bounds array access. This is an internal error and is likely a bug.",
	)
	return false
}

@(private)
arena_allocate :: proc(capacity: i32, itemSize: int, arena: ^Arena) -> rawptr {
	totalSizeBytes := uintptr(u32(capacity) * u32(itemSize))
	nextAllocOffset := arena.nextAllocation + ((64 - (arena.nextAllocation % 64)) & 63)
	if nextAllocOffset + totalSizeBytes <= uintptr(arena.capacity) {
		arena.nextAllocation = nextAllocOffset + totalSizeBytes
		return rawptr(uintptr(arena.memory) + nextAllocOffset)
	}
	report_error(
		.ArenaCapacityExceeded,
		"Clay attempted to allocate memory in its arena, but ran out of capacity. Try increasing the capacity of the arena passed to Clay_Initialize()",
	)
	return nil
}

@(private)
array_allocate :: proc($T: typeid, capacity: i32, arena: ^Arena) -> ClayArray(T) {
	return {
		capacity = capacity,
		internalArray = ([^]T)(arena_allocate(capacity, size_of(T), arena)),
	}
}

@(private)
array_get :: proc(array: ^ClayArray($T), index: i32) -> ^T {
	return range_check(index, array.length) ? &array.internalArray[index] : default_of(T)
}

@(private)
array_get_value :: proc(array: ^ClayArray($T), index: i32) -> T {
	return range_check(index, array.length) ? array.internalArray[index] : default_of(T)^
}

@(private)
array_get_check_capacity :: proc(array: ^ClayArray($T), index: i32) -> ^T {
	return range_check(index, array.capacity) ? &array.internalArray[index] : default_of(T)
}

@(private)
array_add :: proc(array: ^ClayArray($T), item: T) -> ^T {
	if add_capacity_check(array.length, array.capacity) {
		array.internalArray[array.length] = item
		array.length += 1
		return &array.internalArray[array.length - 1]
	}
	return default_of(T)
}

@(private)
slice_get :: proc(slice: ^Array_Slice($T), index: i32) -> ^T {
	return range_check(index, slice.length) ? &slice.internalArray[index] : default_of(T)
}

@(private)
array_remove_swapback :: proc(array: ^ClayArray($T), index: i32) -> T {
	if range_check(index, array.length) {
		array.length -= 1
		removed := array.internalArray[index]
		array.internalArray[index] = array.internalArray[array.length]
		return removed
	}
	return default_of(T)^
}

@(private)
array_set :: proc(array: ^ClayArray($T), index: i32, value: T) -> ^T {
	if range_check(index, array.capacity) {
		array.internalArray[index] = value
		array.length = index < array.length ? array.length : index + 1
		return &array.internalArray[index]
	}
	return nil
}

@(private)
array_set_keep_length :: proc(array: ^ClayArray($T), index: i32, value: T) -> ^T {
	if range_check(index, array.capacity) {
		array.internalArray[index] = value
		return &array.internalArray[index]
	}
	return nil
}

// ── Open element stack ──────────────────────────────────────────────

@(private)
get_open_layout_element :: proc() -> ^Layout_Element {
	ctx := current_context
	return array_get(
		&ctx.layoutElements,
		array_get_value(&ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 1),
	)
}

@(private)
get_parent_element :: proc() -> ^Layout_Element {
	ctx := current_context
	return array_get(
		&ctx.layoutElements,
		array_get_value(&ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2),
	)
}

@(private)
border_has_any_width :: proc "contextless" (border: ^BorderElementConfig) -> bool {
	w := border.width
	return w.betweenChildren > 0 || w.left > 0 || w.right > 0 || w.top > 0 || w.bottom > 0
}

// ── Memory ──────────────────────────────────────────────────────────

@(private)
context_allocate_arena :: proc(arena: ^Arena) -> ^Context {
	totalSizeBytes := uint(size_of(Context))
	if totalSizeBytes > arena.capacity {
		return nil
	}
	arena.nextAllocation += uintptr(totalSizeBytes)
	return (^Context)(arena.memory)
}

@(private)
initialize_ephemeral_memory :: proc(ctx: ^Context) {
	maxElementCount := ctx.maxElementCount
	arena := &ctx.internalArena
	arena.nextAllocation = ctx.arenaResetOffset

	ctx.layoutElementChildrenBuffer = array_allocate(i32, maxElementCount, arena)
	ctx.layoutElements = array_allocate(Layout_Element, maxElementCount, arena)
	ctx.wrappedTextLines = array_allocate(Wrapped_Text_Line, maxElementCount, arena)
	ctx.layoutElementTreeNodeArray1 = array_allocate(
		Layout_Element_Tree_Node,
		maxElementCount,
		arena,
	)
	ctx.layoutElementTreeRoots = array_allocate(Layout_Element_Tree_Root, maxElementCount, arena)
	ctx.layoutElementChildren = array_allocate(i32, maxElementCount, arena)
	ctx.openLayoutElementStack = array_allocate(i32, maxElementCount, arena)
	ctx.renderCommands = array_allocate(RenderCommand, maxElementCount, arena)
	ctx.treeNodeVisited = array_allocate(bool, maxElementCount, arena)
	ctx.treeNodeVisited.length = ctx.treeNodeVisited.capacity // indexed directly, not used as a list
	ctx.openClipElementStack = array_allocate(i32, maxElementCount, arena)
	ctx.reusableElementIndexBuffer = array_allocate(i32, maxElementCount, arena)
	ctx.layoutElementClipElementIds = array_allocate(i32, maxElementCount, arena)
}

@(private)
initialize_persistent_memory :: proc(ctx: ^Context) {
	maxElementCount := ctx.maxElementCount
	maxMeasureTextCacheWordCount := ctx.maxMeasureTextCacheWordCount
	arena := &ctx.internalArena

	ctx.scrollContainerDatas = array_allocate(Scroll_Container_Data_Internal, 100, arena)
	ctx.transitionDatas = array_allocate(Transition_Data_Internal, 200, arena)
	ctx.layoutElementsHashMapInternal = array_allocate(
		Layout_Element_Hash_Map_Item,
		maxElementCount,
		arena,
	)
	ctx.layoutElementsHashMap = array_allocate(i32, maxElementCount, arena)
	ctx.layoutElementsHashMapFreeList = array_allocate(i32, maxElementCount, arena)
	ctx.measureTextHashMapInternal = array_allocate(
		Measure_Text_Cache_Item,
		maxElementCount,
		arena,
	)
	ctx.measureTextHashMapInternalFreeList = array_allocate(i32, maxElementCount, arena)
	ctx.measuredWordsFreeList = array_allocate(i32, maxMeasureTextCacheWordCount, arena)
	ctx.measureTextHashMap = array_allocate(i32, maxElementCount, arena)
	ctx.measuredWords = array_allocate(Measured_Word, maxMeasureTextCacheWordCount, arena)
	ctx.pointerOverIds = array_allocate(ElementId, maxElementCount, arena)
	ctx.arenaResetOffset = arena.nextAllocation
}

// Bytes Initialize needs at the current element and word-cache limits.
MinMemorySize :: proc() -> u32 {
	fake := Context {
		maxElementCount = default_max_element_count,
		maxMeasureTextCacheWordCount = default_max_measure_text_word_cache_count,
		internalArena = {capacity = max(uint)},
	}
	if current_context != nil {
		fake.maxElementCount = current_context.maxElementCount
		fake.maxMeasureTextCacheWordCount = current_context.maxMeasureTextCacheWordCount
	}
	// Reserve the context itself, as Initialize does.
	context_allocate_arena(&fake.internalArena)
	initialize_persistent_memory(&fake)
	initialize_ephemeral_memory(&fake)
	return u32(fake.internalArena.nextAllocation) + 128
}

CreateArenaWithCapacityAndMemory :: proc(capacity: uint, memory: [^]u8) -> Arena {
	return {capacity = capacity, memory = memory}
}

Initialize :: proc(
	arena: Arena,
	layoutDimensions: Dimensions,
	errorHandler: ErrorHandler,
) -> ^Context {
	arena := arena
	// Cacheline-align the memory passed in.
	baseOffset := 64 - (uintptr(arena.memory) % 64)
	baseOffset = baseOffset == 64 ? 0 : baseOffset
	arena.memory = arena.memory[baseOffset:]
	ctx := context_allocate_arena(&arena)
	if ctx == nil {
		return nil
	}
	old := current_context
	ctx^ = {
		maxElementCount              = old != nil ? old.maxElementCount : default_max_element_count,
		maxMeasureTextCacheWordCount = old != nil ? old.maxMeasureTextCacheWordCount : default_max_measure_text_word_cache_count,
		errorHandler                 = errorHandler.handler != nil ? errorHandler : {error_handler_default, nil},
		layoutDimensions             = layoutDimensions,
		internalArena                = arena,
	}
	SetCurrentContext(ctx)
	initialize_persistent_memory(ctx)
	initialize_ephemeral_memory(ctx)
	for i in 0 ..< ctx.layoutElementsHashMap.capacity {
		ctx.layoutElementsHashMap.internalArray[i] = -1
	}
	for i in 0 ..< ctx.measureTextHashMap.capacity {
		ctx.measureTextHashMap.internalArray[i] = 0
	}
	ctx.measureTextHashMapInternal.length = 1 // index 0 means "no next element"
	ctx.layoutDimensions = layoutDimensions
	return ctx
}

GetCurrentContext :: proc "contextless" () -> ^Context {
	return current_context
}

SetCurrentContext :: proc "contextless" (ctx: ^Context) {
	current_context = ctx
}
