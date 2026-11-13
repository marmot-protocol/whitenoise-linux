package nendo

import "base:runtime"

// Internal state: the context, its arena-backed arrays and memory setup.
//
// Every array lives in one caller-provided arena. Persistent arrays (hash
// maps, text cache, scroll and transition state) are carved once at
// init; ephemeral ones (elements, render commands, scratch stacks)
// are re-carved from arena_reset_offset at every begin:
//
//   arena.memory
//   | Context | persistent arrays ... | ephemeral arrays ...   |
//                                     ^ arena_reset_offset

@(private)
MAX_FLOAT :: f32(3.40282346638528859812e+38)
@(private)
EPSILON :: f32(0.01)
@(private)
ROOT_CONTAINER :: "nendo_root"

@(private)
Warnings :: struct {
	max_elements_exceeded:             bool,
	max_render_commands_exceeded:      bool,
	max_text_measure_cache_exceeded:   bool,
	text_measurement_function_not_set: bool,
	hash_map_capacity_exceeded:        bool,
}

// Text as the engine hashes it: a statically allocated string hashes by
// address and length instead of by content.
@(private)
String :: struct {
	is_static: bool,
	length:    i32,
	chars:     [^]u8,
}

@(private)
Arena :: struct {
	next_allocation: uintptr,
	capacity:        uint,
	memory:          [^]u8,
}

@(private)
Array :: struct($T: typeid) {
	capacity, length: i32,
	items:            [^]T,
}

// A view into an Array's storage, without its own capacity.
@(private)
Array_Slice :: struct($T: typeid) {
	length: i32,
	items:  [^]T,
}

@(private)
Wrapped_Text_Line :: struct {
	dimensions: Dimensions,
	line:       String,
}

@(private)
Text_Element_Data :: struct {
	text:                 String,
	preferred_dimensions: Dimensions,
	wrapped_lines:        Array_Slice(Wrapped_Text_Line),
}

@(private)
Layout_Element_Children :: struct {
	elements: [^]i32,
	length:   u16,
}

@(private)
Text_Element_Payload :: struct {
	text_config:       Text_Style,
	text_element_data: Text_Element_Data,
}

// A text element stores its text config where other elements store their
// declaration. Code that reads `config` on a text element reads the text
// payload's bytes, as a C union would.
@(private)
Layout_Element_Data :: struct #raw_union {
	config:     Box,
	using text: Text_Element_Payload,
}

@(private)
Layout_Element :: struct {
	children:                Layout_Element_Children,
	dimensions:              Dimensions,
	min_dimensions:          Dimensions,
	using data:              Layout_Element_Data,
	id:                      u32,
	floating_children_count: u16,
	is_text_element:         bool,
	// True while the element is exit transitioning: a synthetic copy
	// retained from earlier frames.
	exiting:                 bool,
}

@(private)
Scroll_Container_Data_Internal :: struct {
	layout_element:        ^Layout_Element,
	bounding_box:          Rect,
	content_size:          Dimensions,
	scroll_origin:         Vector2,
	pointer_origin:        Vector2,
	scroll_momentum:       Vector2,
	scroll_position:       Vector2,
	previous_delta:        Vector2,
	momentum_time:         f32,
	element_id:            u32,
	open_this_frame:       bool,
	pointer_scroll_active: bool,
}

@(private)
Transition_Data_Internal :: struct {
	initial_state:                Transition_Data,
	current_state:                Transition_Data,
	target_state:                 Transition_Data,
	element_this_frame:           ^Layout_Element,
	old_parent_relative_position: Vector2,
	element_id:                   u32,
	parent_id:                    u32,
	sibling_index:                u32,
	elapsed_time:                 f32,
	state:                        Transition_State,
	transition_out:               bool,
	reparented:                   bool,
	active_properties:            Transition_Properties,
}

@(private)
Layout_Element_Hash_Map_Item :: struct {
	bounding_box:        Rect,
	element_id:          Id,
	layout_element:      ^Layout_Element,
	next_index:          i32,
	generation:          u32,
	appeared_this_frame: bool,
}

@(private)
Measured_Word :: struct {
	start_offset: i32,
	length:       i32,
	width:        f32,
	next:         i32,
}

@(private)
Measure_Text_Cache_Item :: struct {
	unwrapped_dimensions:       Dimensions,
	measured_words_start_index: i32,
	min_width:                  f32,
	contains_newlines:          bool,
	// Hash map data
	id:                         u32,
	next_index:                 i32,
	generation:                 u32,
}

@(private)
Layout_Element_Tree_Node :: struct {
	layout_element:    ^Layout_Element,
	position:          Vector2,
	next_child_offset: Vector2,
}

@(private)
Layout_Element_Tree_Root :: struct {
	layout_element_index: i32,
	parent_id:            u32, // zero for the root layout tree
	clip_element_id:      u32, // zero without a clip element
	z:                    i16,
}

Context :: struct {
	max_element_count:                        i32,
	max_measure_text_cache_word_count:        i32,
	root_resized_last_frame:                  bool,
	settle_requested:                         bool, // next end() treats geometry as resized
	error_handler:                            Error_Handler,
	warnings:                                 Warnings,
	pointer_info:                             Pointer,
	layout_dimensions:                        Dimensions,
	generation:                               u32,
	arena_reset_offset:                       uintptr,
	measure_text_user_data:                   rawptr,
	internal_arena:                           Arena,
	// Layout elements and render commands
	layout_elements:                          Array(Layout_Element),
	render_commands:                          Array(Render_Command),
	open_layout_element_stack:                Array(i32),
	layout_element_children:                  Array(i32),
	layout_element_children_buffer:           Array(i32),
	reusable_element_index_buffer:            Array(i32),
	layout_element_clip_element_ids:          Array(i32),
	// Misc data structures
	wrapped_text_lines:                       Array(Wrapped_Text_Line),
	layout_element_tree_node_array1:          Array(Layout_Element_Tree_Node),
	layout_element_tree_roots:                Array(Layout_Element_Tree_Root),
	layout_elements_hash_map_internal:        Array(Layout_Element_Hash_Map_Item),
	layout_elements_hash_map:                 Array(i32),
	layout_elements_hash_map_free_list:       Array(i32),
	measure_text_hash_map_internal:           Array(Measure_Text_Cache_Item),
	measure_text_hash_map_internal_free_list: Array(i32),
	measure_text_hash_map:                    Array(i32),
	measured_words:                           Array(Measured_Word),
	measured_words_free_list:                 Array(i32),
	open_clip_element_stack:                  Array(i32),
	pointer_over_ids:                         Array(Id),
	scroll_container_datas:                   Array(Scroll_Container_Data_Internal),
	transition_datas:                         Array(Transition_Data_Internal),
	tree_node_visited:                        Array(bool),
}

@(private)
active_context: ^Context
@(private)
default_max_element_count: i32 = 8192
@(private)
default_max_measure_text_word_cache_count: i32 = 16384
// Process-wide, while its user_data is per context.
@(private)
measure_text: Measure_Text

// ── Helpers shared by every pass ────────────────────────────────────

// max/min where the left operand wins ties and NaN
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
	return {is_static = true, length = i32(len(text)), chars = raw_data(text)}
}

@(private)
report_error :: proc(kind: Error_Kind, text: string) {
	ctx := active_context
	ctx.error_handler.handler({kind = kind, text = text, user_data = ctx.error_handler.user_data})
}

@(private)
error_handler_default :: proc(error: Error) {}

// An engine String or slice as an Odin string, without a bounds check:
// lengths pass through unchanged.
@(private)
to_string :: #force_inline proc "contextless" (chars: [^]u8, length: i32) -> string {
	return transmute(string)runtime.Raw_String{data = chars, len = int(length)}
}

// ── Bounds-checked arrays ───────────────────────────────────────────
//
// nendo answers an out-of-range access with an InternalError report and a
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
		.Internal_Error,
		"nendo attempted to make an out of bounds array access. This is an internal error and is likely a bug.",
	)
	return false
}

@(private)
add_capacity_check :: proc(length, capacity: i32) -> bool {
	if length < capacity {
		return true
	}
	report_error(
		.Internal_Error,
		"nendo attempted to make an out of bounds array access. This is an internal error and is likely a bug.",
	)
	return false
}

@(private)
arena_allocate :: proc(capacity: i32, item_size: int, arena: ^Arena) -> rawptr {
	total_size_bytes := uintptr(u32(capacity) * u32(item_size))
	next_alloc_offset := arena.next_allocation + ((64 - (arena.next_allocation % 64)) & 63)
	if next_alloc_offset + total_size_bytes <= uintptr(arena.capacity) {
		arena.next_allocation = next_alloc_offset + total_size_bytes
		return rawptr(uintptr(arena.memory) + next_alloc_offset)
	}
	report_error(
		.Arena_Capacity_Exceeded,
		"nendo attempted to allocate memory in its arena, but ran out of capacity. Try increasing the capacity of the arena passed to nendo.init()",
	)
	return nil
}

@(private)
array_allocate :: proc($T: typeid, capacity: i32, arena: ^Arena) -> Array(T) {
	return {capacity = capacity, items = ([^]T)(arena_allocate(capacity, size_of(T), arena))}
}

@(private)
array_get :: proc(array: ^Array($T), index: i32) -> ^T {
	return range_check(index, array.length) ? &array.items[index] : default_of(T)
}

@(private)
array_get_value :: proc(array: ^Array($T), index: i32) -> T {
	return range_check(index, array.length) ? array.items[index] : default_of(T)^
}

@(private)
array_get_check_capacity :: proc(array: ^Array($T), index: i32) -> ^T {
	return range_check(index, array.capacity) ? &array.items[index] : default_of(T)
}

@(private)
array_add :: proc(array: ^Array($T), item: T) -> ^T {
	if add_capacity_check(array.length, array.capacity) {
		array.items[array.length] = item
		array.length += 1
		return &array.items[array.length - 1]
	}
	return default_of(T)
}

@(private)
slice_get :: proc(slice: ^Array_Slice($T), index: i32) -> ^T {
	return range_check(index, slice.length) ? &slice.items[index] : default_of(T)
}

@(private)
array_remove_swapback :: proc(array: ^Array($T), index: i32) -> T {
	if range_check(index, array.length) {
		array.length -= 1
		removed := array.items[index]
		array.items[index] = array.items[array.length]
		return removed
	}
	return default_of(T)^
}

@(private)
array_set :: proc(array: ^Array($T), index: i32, value: T) -> ^T {
	if range_check(index, array.capacity) {
		array.items[index] = value
		array.length = index < array.length ? array.length : index + 1
		return &array.items[index]
	}
	return nil
}

@(private)
array_set_keep_length :: proc(array: ^Array($T), index: i32, value: T) -> ^T {
	if range_check(index, array.capacity) {
		array.items[index] = value
		return &array.items[index]
	}
	return nil
}

// ── Open element stack ──────────────────────────────────────────────

@(private)
get_open_layout_element :: proc() -> ^Layout_Element {
	ctx := active_context
	return array_get(
		&ctx.layout_elements,
		array_get_value(&ctx.open_layout_element_stack, ctx.open_layout_element_stack.length - 1),
	)
}

@(private)
get_parent_element :: proc() -> ^Layout_Element {
	ctx := active_context
	return array_get(
		&ctx.layout_elements,
		array_get_value(&ctx.open_layout_element_stack, ctx.open_layout_element_stack.length - 2),
	)
}

@(private)
border_has_any_width :: proc "contextless" (border: ^Border) -> bool {
	w := border.width
	return w.between > 0 || w.left > 0 || w.right > 0 || w.top > 0 || w.bottom > 0
}

// ── Memory ──────────────────────────────────────────────────────────

@(private)
context_allocate_arena :: proc(arena: ^Arena) -> ^Context {
	total_size_bytes := uint(size_of(Context))
	if total_size_bytes > arena.capacity {
		return nil
	}
	arena.next_allocation += uintptr(total_size_bytes)
	return (^Context)(arena.memory)
}

@(private)
initialize_ephemeral_memory :: proc(ctx: ^Context) {
	max_element_count := ctx.max_element_count
	arena := &ctx.internal_arena
	arena.next_allocation = ctx.arena_reset_offset

	ctx.layout_element_children_buffer = array_allocate(i32, max_element_count, arena)
	ctx.layout_elements = array_allocate(Layout_Element, max_element_count, arena)
	ctx.wrapped_text_lines = array_allocate(Wrapped_Text_Line, max_element_count, arena)
	ctx.layout_element_tree_node_array1 = array_allocate(
		Layout_Element_Tree_Node,
		max_element_count,
		arena,
	)
	ctx.layout_element_tree_roots = array_allocate(
		Layout_Element_Tree_Root,
		max_element_count,
		arena,
	)
	ctx.layout_element_children = array_allocate(i32, max_element_count, arena)
	ctx.open_layout_element_stack = array_allocate(i32, max_element_count, arena)
	ctx.render_commands = array_allocate(Render_Command, max_element_count, arena)
	ctx.tree_node_visited = array_allocate(bool, max_element_count, arena)
	ctx.tree_node_visited.length = ctx.tree_node_visited.capacity // indexed directly, not used as a list
	ctx.open_clip_element_stack = array_allocate(i32, max_element_count, arena)
	ctx.reusable_element_index_buffer = array_allocate(i32, max_element_count, arena)
	ctx.layout_element_clip_element_ids = array_allocate(i32, max_element_count, arena)
}

@(private)
initialize_persistent_memory :: proc(ctx: ^Context) {
	max_element_count := ctx.max_element_count
	max_measure_text_cache_word_count := ctx.max_measure_text_cache_word_count
	arena := &ctx.internal_arena

	ctx.scroll_container_datas = array_allocate(Scroll_Container_Data_Internal, 100, arena)
	ctx.transition_datas = array_allocate(Transition_Data_Internal, 200, arena)
	ctx.layout_elements_hash_map_internal = array_allocate(
		Layout_Element_Hash_Map_Item,
		max_element_count,
		arena,
	)
	ctx.layout_elements_hash_map = array_allocate(i32, max_element_count, arena)
	ctx.layout_elements_hash_map_free_list = array_allocate(i32, max_element_count, arena)
	ctx.measure_text_hash_map_internal = array_allocate(
		Measure_Text_Cache_Item,
		max_element_count,
		arena,
	)
	ctx.measure_text_hash_map_internal_free_list = array_allocate(i32, max_element_count, arena)
	ctx.measured_words_free_list = array_allocate(i32, max_measure_text_cache_word_count, arena)
	ctx.measure_text_hash_map = array_allocate(i32, max_element_count, arena)
	ctx.measured_words = array_allocate(Measured_Word, max_measure_text_cache_word_count, arena)
	ctx.pointer_over_ids = array_allocate(Id, max_element_count, arena)
	ctx.arena_reset_offset = arena.next_allocation
}

// Bytes init needs at the current element and word-cache limits.
min_memory_size :: proc() -> int {
	fake := Context {
		max_element_count = default_max_element_count,
		max_measure_text_cache_word_count = default_max_measure_text_word_cache_count,
		internal_arena = {capacity = max(uint)},
	}
	if active_context != nil {
		fake.max_element_count = active_context.max_element_count
		fake.max_measure_text_cache_word_count = active_context.max_measure_text_cache_word_count
	}
	// Reserve the context itself, as init does.
	context_allocate_arena(&fake.internal_arena)
	initialize_persistent_memory(&fake)
	initialize_ephemeral_memory(&fake)
	return int(fake.internal_arena.next_allocation) + 128
}

// Builds the context and its arrays inside `memory`, which must outlive it
// and hold at least min_memory_size() bytes.
init :: proc(memory: []u8, dimensions: Dimensions, handler: Error_Handler = {}) -> ^Context {
	arena := Arena {
		capacity = uint(len(memory)),
		memory   = raw_data(memory),
	}
	// Cacheline-align the memory passed in.
	base_offset := 64 - (uintptr(arena.memory) % 64)
	base_offset = base_offset == 64 ? 0 : base_offset
	arena.memory = arena.memory[base_offset:]
	ctx := context_allocate_arena(&arena)
	if ctx == nil {
		return nil
	}
	old := active_context
	ctx^ = {
		max_element_count                 = old != nil ? old.max_element_count : default_max_element_count,
		max_measure_text_cache_word_count = old != nil ? old.max_measure_text_cache_word_count : default_max_measure_text_word_cache_count,
		error_handler                     = handler.handler != nil ? handler : {error_handler_default, nil},
		layout_dimensions                 = dimensions,
		internal_arena                    = arena,
	}
	set_context(ctx)
	initialize_persistent_memory(ctx)
	initialize_ephemeral_memory(ctx)
	for i in 0 ..< ctx.layout_elements_hash_map.capacity {
		ctx.layout_elements_hash_map.items[i] = -1
	}
	for i in 0 ..< ctx.measure_text_hash_map.capacity {
		ctx.measure_text_hash_map.items[i] = 0
	}
	ctx.measure_text_hash_map_internal.length = 1 // index 0 means "no next element"
	ctx.layout_dimensions = dimensions
	return ctx
}

current_context :: proc "contextless" () -> ^Context {
	return active_context
}

set_context :: proc "contextless" (ctx: ^Context) {
	active_context = ctx
}
