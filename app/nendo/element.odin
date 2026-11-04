package nendo

// Element ids, text measurement cache, and opening/closing elements.

@(private)
hash_number :: proc(offset, seed: u32) -> Id {
	hash := seed
	hash += (offset + 48)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	hash ~= (hash >> 11)
	hash += (hash << 15)
	return Id{id = hash + 1, offset = offset, base_id = seed} // Reserve the hash result of zero as "null id"
}

@(private)
hash_string :: proc(key: String, seed: u32) -> Id {
	hash := seed

	for i: i32 = 0; i < key.length; i += 1 {
		// C char is signed on x86-64
		hash += u32(i32(i8(key.chars[i])))
		hash += (hash << 10)
		hash ~= (hash >> 6)
	}

	hash += (hash << 3)
	hash ~= (hash >> 11)
	hash += (hash << 15)
	return Id {
		id = hash + 1,
		offset = 0,
		base_id = hash + 1,
		label = to_string(key.chars, key.length),
	} // Reserve the hash result of zero as "null id"
}

@(private)
hash_string_with_offset :: proc(key: String, offset, seed: u32) -> Id {
	hash: u32 = 0
	base := seed

	for i: i32 = 0; i < key.length; i += 1 {
		base += u32(i32(i8(key.chars[i])))
		base += (base << 10)
		base ~= (base >> 6)
	}
	hash = base
	hash += offset
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	base += (base << 3)
	hash ~= (hash >> 11)
	base ~= (base >> 11)
	hash += (hash << 15)
	base += (base << 15)
	return Id {
		id = hash + 1,
		offset = offset,
		base_id = base + 1,
		label = to_string(key.chars, key.length),
	} // Reserve the hash result of zero as "null id"
}

// A 128-bit ARX mix, computed lane by lane: each [2]u64 is one SSE register.
@(private)
simd_rotate_left :: #force_inline proc "contextless" (x: [2]u64, r: u64) -> [2]u64 {
	return {(x[0] << r) | (x[0] >> (64 - r)), (x[1] << r) | (x[1] >> (64 - r))}
}

@(private)
simd_arx_mix :: #force_inline proc "contextless" (a, b: ^[2]u64) {
	a^ = {a[0] + b[0], a[1] + b[1]}
	r := simd_rotate_left(b^, 17)
	b^ = {r[0] ~ a[0], r[1] ~ a[1]}
}

@(private)
load_u64_le :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	v: u64 = 0
	for i: uint = 0; i < 8; i += 1 {
		v |= u64(p[i]) << (8 * i)
	}
	return v
}

@(private)
hash_data :: proc(data: [^]u8, length: uint) -> u64 {
	data := data
	length := length
	// Pinched these constants from the BLAKE implementation
	v0 := [2]u64{0x6a09e667f3bcc908, 0x6a09e667f3bcc908}
	v1 := [2]u64{0xbb67ae8584caa73b, 0xbb67ae8584caa73b}
	v2 := [2]u64{0x3c6ef372fe94f82b, 0x3c6ef372fe94f82b}
	v3 := [2]u64{0xa54ff53a5f1d36f1, 0xa54ff53a5f1d36f1}

	overflow_buffer: [16]u8 // Temporary buffer for small inputs

	for length > 0 {
		msg: [2]u64
		if length >= 16 {
			msg = {load_u64_le(data), load_u64_le(data[8:])}
			data = data[16:]
			length -= 16
		} else {
			for i: uint = 0; i < length; i += 1 {
				overflow_buffer[i] = data[i]
			}
			buf := ([^]u8)(&overflow_buffer[0])
			msg = {load_u64_le(buf), load_u64_le(buf[8:])}
			length = 0
		}

		v0 = {v0[0] ~ msg[0], v0[1] ~ msg[1]}
		simd_arx_mix(&v0, &v1)
		simd_arx_mix(&v2, &v3)

		v0 = {v0[0] + v2[0], v0[1] + v2[1]}
		v1 = {v1[0] + v3[0], v1[1] + v3[1]}
	}

	simd_arx_mix(&v0, &v1)
	simd_arx_mix(&v2, &v3)
	v0 = {v0[0] + v2[0], v0[1] + v2[1]}
	v1 = {v1[0] + v3[0], v1[1] + v3[1]}
	v0 = {v0[0] + v1[0], v0[1] + v1[1]}

	return v0[0] ~ v0[1]
}

@(private)
hash_string_contents_with_config :: proc(text: ^String, config: ^Text_Style) -> u32 {
	hash: u32 = 0
	if text.is_static {
		hash += u32(uintptr(text.chars))
		hash += (hash << 10)
		hash ~= (hash >> 6)
		hash += u32(text.length)
		hash += (hash << 10)
		hash ~= (hash >> 6)
	} else {
		hash = u32(hash_data(text.chars, uint(text.length)) % u64(max(u32)))
	}

	hash += u32(config.font)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += u32(config.size)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += u32(config.spacing)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	hash ~= (hash >> 11)
	hash += (hash << 15)
	return hash + 1 // Reserve the hash result of zero as "null id"
}

@(private)
add_measured_word :: proc(word: Measured_Word, previous_word: ^Measured_Word) -> ^Measured_Word {
	ctx := active_context
	if ctx.measured_words_free_list.length > 0 {
		new_item_index := u32(
			array_get_value(
				&ctx.measured_words_free_list,
				ctx.measured_words_free_list.length - 1,
			),
		)
		ctx.measured_words_free_list.length -= 1
		array_set(&ctx.measured_words, i32(new_item_index), word)
		previous_word.next = i32(new_item_index)
		return array_get(&ctx.measured_words, i32(new_item_index))
	} else {
		previous_word.next = ctx.measured_words.length
		return array_add(&ctx.measured_words, word)
	}
}

@(private)
SPACE_CHAR :: " "

@(private)
measure_text_cached :: proc(text: ^String, config: ^Text_Style) -> ^Measure_Text_Cache_Item {
	ctx := active_context
	if measure_text == nil {
		if !ctx.warnings.text_measurement_function_not_set {
			ctx.warnings.text_measurement_function_not_set = true
			report_error(
				.Text_Measurement_Function_Not_Provided,
				"nendo has no measure text procedure. You may have forgotten to call nendo.set_measure_text(), or passed a nil procedure.",
			)
		}
		return default_of(Measure_Text_Cache_Item)
	}
	id := hash_string_contents_with_config(text, config)
	hash_bucket := id % u32(ctx.max_measure_text_cache_word_count / 32)
	element_index_previous: i32 = 0
	element_index := ctx.measure_text_hash_map.items[hash_bucket]
	for element_index != 0 {
		hash_entry := array_get(&ctx.measure_text_hash_map_internal, element_index)
		if hash_entry.id == id {
			hash_entry.generation = ctx.generation
			return hash_entry
		}
		// This element hasn't been seen in a few frames, delete the hash map item
		if ctx.generation - hash_entry.generation > 2 {
			// Add all the measured words that were included in this measurement to the freelist
			next_word_index := hash_entry.measured_words_start_index
			for next_word_index != -1 {
				measured_word := array_get(&ctx.measured_words, next_word_index)
				array_add(&ctx.measured_words_free_list, next_word_index)
				next_word_index = measured_word.next
			}

			next_index := hash_entry.next_index
			array_set(
				&ctx.measure_text_hash_map_internal,
				element_index,
				Measure_Text_Cache_Item{measured_words_start_index = -1},
			)
			array_add(&ctx.measure_text_hash_map_internal_free_list, element_index)
			if element_index_previous == 0 {
				ctx.measure_text_hash_map.items[hash_bucket] = next_index
			} else {
				previous_hash_entry := array_get(
					&ctx.measure_text_hash_map_internal,
					element_index_previous,
				)
				previous_hash_entry.next_index = next_index
			}
			element_index = next_index
		} else {
			element_index_previous = element_index
			element_index = hash_entry.next_index
		}
	}

	new_item_index: i32 = 0
	new_cache_item := Measure_Text_Cache_Item {
		measured_words_start_index = -1,
		id                         = id,
		generation                 = ctx.generation,
	}
	measured: ^Measure_Text_Cache_Item = nil
	if ctx.measure_text_hash_map_internal_free_list.length > 0 {
		new_item_index = array_get_value(
			&ctx.measure_text_hash_map_internal_free_list,
			ctx.measure_text_hash_map_internal_free_list.length - 1,
		)
		ctx.measure_text_hash_map_internal_free_list.length -= 1
		array_set(&ctx.measure_text_hash_map_internal, new_item_index, new_cache_item)
		measured = array_get(&ctx.measure_text_hash_map_internal, new_item_index)
	} else {
		if ctx.measure_text_hash_map_internal.length ==
		   ctx.measure_text_hash_map_internal.capacity - 1 {
			if !ctx.warnings.max_text_measure_cache_exceeded {
				report_error(
					.Elements_Capacity_Exceeded,
					"nendo ran out of capacity while attempting to measure text elements. Try using nendo.set_max_element_count() with a higher value.",
				)
				ctx.warnings.max_text_measure_cache_exceeded = true
			}
			return default_of(Measure_Text_Cache_Item)
		}
		measured = array_add(&ctx.measure_text_hash_map_internal, new_cache_item)
		new_item_index = ctx.measure_text_hash_map_internal.length - 1
	}

	start: i32 = 0
	end: i32 = 0
	line_width: f32 = 0
	measured_width: f32 = 0
	measured_height: f32 = 0
	space_width := measure_text(SPACE_CHAR, config, ctx.measure_text_user_data).width
	temp_word := Measured_Word {
		next = -1,
	}
	previous_word := &temp_word
	for end < text.length {
		if ctx.measured_words.length == ctx.measured_words.capacity - 1 {
			if !ctx.warnings.max_text_measure_cache_exceeded {
				report_error(
					.Text_Measurement_Capacity_Exceeded,
					"nendo has run out of space in it's internal text measurement cache. Try using nendo.set_max_element_count() with a higher value.",
				)
				ctx.warnings.max_text_measure_cache_exceeded = true
			}
			return default_of(Measure_Text_Cache_Item)
		}
		current := text.chars[end]
		// CJK text has no spaces: each ideograph, kana or Hangul syllable
		// (3-byte UTF-8, U+3000-U+DFFF, and fullwidth forms) ends a word,
		// so a line can break between characters.
		lead := current
		if end + 2 < text.length &&
		   ((lead >= 0xE3 && lead <= 0xED) || (lead == 0xEF && text.chars[end + 1] >= 0xBC)) {
			length := end + 3 - start
			dimensions := measure_text(
				to_string(&text.chars[start], length),
				config,
				ctx.measure_text_user_data,
			)
			measured.min_width = cmax(dimensions.width, measured.min_width)
			measured_height = cmax(measured_height, dimensions.height)
			previous_word = add_measured_word(
				Measured_Word {
					start_offset = start,
					length = length,
					width = dimensions.width,
					next = -1,
				},
				previous_word,
			)
			line_width += dimensions.width
			start = end + 3
			end = start
			continue
		}
		if current == ' ' || current == '\n' {
			length := end - start
			dimensions := Dimensions{}
			if length > 0 {
				dimensions = measure_text(
					to_string(&text.chars[start], length),
					config,
					ctx.measure_text_user_data,
				)
			}
			measured.min_width = cmax(dimensions.width, measured.min_width)
			measured_height = cmax(measured_height, dimensions.height)
			if current == ' ' {
				dimensions.width += space_width
				previous_word = add_measured_word(
					Measured_Word {
						start_offset = start,
						length = length + 1,
						width = dimensions.width,
						next = -1,
					},
					previous_word,
				)
				line_width += dimensions.width
			}
			if current == '\n' {
				if length > 0 {
					previous_word = add_measured_word(
						Measured_Word {
							start_offset = start,
							length = length,
							width = dimensions.width,
							next = -1,
						},
						previous_word,
					)
				}
				previous_word = add_measured_word(
					Measured_Word{start_offset = end + 1, length = 0, width = 0, next = -1},
					previous_word,
				)
				line_width += dimensions.width
				measured_width = cmax(line_width, measured_width)
				measured.contains_newlines = true
				line_width = 0
			}
			start = end + 1
		}
		end += 1
	}
	if end - start > 0 {
		dimensions := measure_text(
			to_string(&text.chars[start], end - start),
			config,
			ctx.measure_text_user_data,
		)
		add_measured_word(
			Measured_Word {
				start_offset = start,
				length = end - start,
				width = dimensions.width,
				next = -1,
			},
			previous_word,
		)
		line_width += dimensions.width
		measured_height = cmax(measured_height, dimensions.height)
		measured.min_width = cmax(dimensions.width, measured.min_width)
	}
	measured_width = cmax(line_width, measured_width) - f32(config.spacing)

	measured.measured_words_start_index = temp_word.next
	measured.unwrapped_dimensions.width = measured_width
	measured.unwrapped_dimensions.height = measured_height

	if element_index_previous != 0 {
		array_get(&ctx.measure_text_hash_map_internal, element_index_previous).next_index =
			new_item_index
	} else {
		ctx.measure_text_hash_map.items[hash_bucket] = new_item_index
	}
	return measured
}

@(private)
point_is_inside_rect :: proc(point: Vector2, rect: Rect) -> bool {
	return(
		point.x >= rect.x &&
		point.x <= rect.x + rect.width &&
		point.y >= rect.y &&
		point.y <= rect.y + rect.height \
	)
}

@(private)
add_hash_map_item :: proc(
	element_id: Id,
	layout_element: ^Layout_Element,
) -> ^Layout_Element_Hash_Map_Item {
	ctx := active_context
	item := Layout_Element_Hash_Map_Item {
		element_id          = element_id,
		layout_element      = layout_element,
		next_index          = -1,
		generation          = ctx.generation + 1,
		appeared_this_frame = true,
	}
	hash_bucket := element_id.id % u32(ctx.layout_elements_hash_map.capacity)
	hash_item_previous: i32 = -1
	hash_item_index := ctx.layout_elements_hash_map.items[hash_bucket]
	for hash_item_index != -1 { 	// Just replace collision, not a big deal - leave it up to the end user
		hash_item := array_get(&ctx.layout_elements_hash_map_internal, hash_item_index)
		if hash_item.element_id.id == element_id.id { 	// Collision - resolve based on generation
			item.next_index = hash_item.next_index
			if hash_item.generation <= ctx.generation { 	// First collision - assume this is the "same" element
				hash_item.appeared_this_frame = hash_item.generation < ctx.generation
				hash_item.element_id = element_id // If the string_id reference has changed, update the hash item to use the new one.
				hash_item.generation = ctx.generation + 1
				hash_item.layout_element = layout_element
			} else { 	// Multiple collisions this frame - two elements have the same ID
				report_error(
					.Duplicate_Id,
					"An element with this ID was already previously declared during this layout.",
				)
			}
			return hash_item
		}
		hash_item_previous = hash_item_index
		hash_item_index = hash_item.next_index
	}

	index_to_use: i32 = 0
	if ctx.layout_elements_hash_map_free_list.length > 0 {
		index_to_use = array_get_value(
			&ctx.layout_elements_hash_map_free_list,
			ctx.layout_elements_hash_map_free_list.length - 1,
		)
		ctx.layout_elements_hash_map_free_list.length -= 1
	} else {
		if ctx.layout_elements_hash_map_internal.length >=
		   ctx.layout_elements_hash_map_internal.capacity - 1 {
			if !ctx.warnings.hash_map_capacity_exceeded {
				report_error(
					.Hash_Map_Capacity_Exceeded,
					"nendo has run out of space in it's internal element ID hashmap.  Try using nendo.set_max_element_count() with a higher value.",
				)
				ctx.warnings.hash_map_capacity_exceeded = true
			}
			return nil
		}
		index_to_use = ctx.layout_elements_hash_map_internal.length
	}
	hash_item := array_set(&ctx.layout_elements_hash_map_internal, index_to_use, item)
	if hash_item_previous != -1 {
		array_get(&ctx.layout_elements_hash_map_internal, hash_item_previous).next_index =
			index_to_use
	} else {
		ctx.layout_elements_hash_map.items[hash_bucket] = index_to_use
	}
	return hash_item
}

@(private)
get_hash_map_item :: proc(id: u32) -> ^Layout_Element_Hash_Map_Item {
	ctx := active_context
	hash_bucket := id % u32(ctx.layout_elements_hash_map.capacity)
	element_index := ctx.layout_elements_hash_map.items[hash_bucket]
	for element_index != -1 {
		hash_entry := array_get(&ctx.layout_elements_hash_map_internal, element_index)
		if hash_entry.element_id.id == id {
			return hash_entry
		}
		element_index = hash_entry.next_index
	}
	return default_of(Layout_Element_Hash_Map_Item)
}

@(private)
update_aspect_ratio_box :: proc(layout_element: ^Layout_Element) {
	if layout_element.config.aspect != 0 {
		if layout_element.dimensions.width == 0 && layout_element.dimensions.height != 0 {
			layout_element.dimensions.width =
				layout_element.dimensions.height * layout_element.config.aspect
		} else if layout_element.dimensions.width != 0 && layout_element.dimensions.height == 0 {
			layout_element.dimensions.height =
				layout_element.dimensions.width * (1 / layout_element.config.aspect)
		}
	}
}

@(private)
close_element :: proc() {
	ctx := active_context
	if ctx.warnings.max_elements_exceeded {
		return
	}
	open_layout_element := get_open_layout_element()
	layout_config := &open_layout_element.config
	element_has_clip_horizontal := open_layout_element.config.clip.x
	element_has_clip_vertical := open_layout_element.config.clip.y
	if element_has_clip_horizontal ||
	   element_has_clip_vertical ||
	   open_layout_element.config.floating.attach_to != .None {
		ctx.open_clip_element_stack.length -= 1
	}

	left_right_padding := f32(i32(layout_config.padding.left) + i32(layout_config.padding.right))
	top_bottom_padding := f32(i32(layout_config.padding.top) + i32(layout_config.padding.bottom))

	// Attach children to the current open element
	open_layout_element.children.elements = &ctx.layout_element_children.items[ctx.layout_element_children.length]
	if layout_config.direction == .Row {
		open_layout_element.dimensions.width = left_right_padding
		open_layout_element.min_dimensions.width = left_right_padding
		for i: i32 = 0; i < i32(open_layout_element.children.length); i += 1 {
			child_index := array_get_value(
				&ctx.layout_element_children_buffer,
				ctx.layout_element_children_buffer.length -
				i32(open_layout_element.children.length) +
				i,
			)
			child := array_get(&ctx.layout_elements, child_index)
			open_layout_element.dimensions.width += child.dimensions.width
			open_layout_element.dimensions.height = cmax(
				open_layout_element.dimensions.height,
				child.dimensions.height + top_bottom_padding,
			)
			// Minimum size of child elements doesn't matter to clip containers as they can shrink and hide their contents
			if !element_has_clip_horizontal {
				open_layout_element.min_dimensions.width += child.min_dimensions.width
			}
			if !element_has_clip_vertical {
				open_layout_element.min_dimensions.height = cmax(
					open_layout_element.min_dimensions.height,
					child.min_dimensions.height + top_bottom_padding,
				)
			}
			array_add(&ctx.layout_element_children, child_index)
		}
		child_gap := f32(
			cmax(i32(open_layout_element.children.length) - 1, 0) * i32(layout_config.gap),
		)
		open_layout_element.dimensions.width += child_gap
		if !element_has_clip_horizontal {
			open_layout_element.min_dimensions.width += child_gap
		}
	} else if layout_config.direction == .Column {
		open_layout_element.dimensions.height = top_bottom_padding
		open_layout_element.min_dimensions.height = top_bottom_padding
		for i: i32 = 0; i < i32(open_layout_element.children.length); i += 1 {
			child_index := array_get_value(
				&ctx.layout_element_children_buffer,
				ctx.layout_element_children_buffer.length -
				i32(open_layout_element.children.length) +
				i,
			)
			child := array_get(&ctx.layout_elements, child_index)
			open_layout_element.dimensions.height += child.dimensions.height
			open_layout_element.dimensions.width = cmax(
				open_layout_element.dimensions.width,
				child.dimensions.width + left_right_padding,
			)
			// Minimum size of child elements doesn't matter to clip containers as they can shrink and hide their contents
			if !element_has_clip_vertical {
				open_layout_element.min_dimensions.height += child.min_dimensions.height
			}
			if !element_has_clip_horizontal {
				open_layout_element.min_dimensions.width = cmax(
					open_layout_element.min_dimensions.width,
					child.min_dimensions.width + left_right_padding,
				)
			}
			array_add(&ctx.layout_element_children, child_index)
		}
		child_gap := f32(
			cmax(i32(open_layout_element.children.length) - 1, 0) * i32(layout_config.gap),
		)
		open_layout_element.dimensions.height += child_gap
		if !element_has_clip_vertical {
			open_layout_element.min_dimensions.height += child_gap
		}
	}

	ctx.layout_element_children_buffer.length -= i32(open_layout_element.children.length)

	// Clamp element min and max width to the values configured in the layout
	if layout_config.width.kind != .Percent {
		if layout_config.width.max <= 0 { 	// Set the max size if the user didn't specify, makes calculations easier
			layout_config.width.max = MAX_FLOAT
		}
		open_layout_element.dimensions.width = cmin(
			cmax(open_layout_element.dimensions.width, layout_config.width.min),
			layout_config.width.max,
		)
		open_layout_element.min_dimensions.width = cmin(
			cmax(open_layout_element.min_dimensions.width, layout_config.width.min),
			layout_config.width.max,
		)
	} else {
		open_layout_element.dimensions.width = 0
	}

	// Clamp element min and max height to the values configured in the layout
	if layout_config.height.kind != .Percent {
		if layout_config.height.max <= 0 { 	// Set the max size if the user didn't specify, makes calculations easier
			layout_config.height.max = MAX_FLOAT
		}
		open_layout_element.dimensions.height = cmin(
			cmax(open_layout_element.dimensions.height, layout_config.height.min),
			layout_config.height.max,
		)
		open_layout_element.min_dimensions.height = cmin(
			cmax(open_layout_element.min_dimensions.height, layout_config.height.min),
			layout_config.height.max,
		)
	} else {
		open_layout_element.dimensions.height = 0
	}

	update_aspect_ratio_box(open_layout_element)

	element_is_floating := open_layout_element.config.floating.attach_to != .None

	// Close the currently open element
	closing_element_index := array_remove_swapback(
		&ctx.open_layout_element_stack,
		ctx.open_layout_element_stack.length - 1,
	)

	// Get the currently open parent
	open_layout_element = get_open_layout_element()

	if ctx.open_layout_element_stack.length > 1 {
		if element_is_floating {
			open_layout_element.floating_children_count += 1
			return
		}
		open_layout_element.children.length += 1
		array_add(&ctx.layout_element_children_buffer, closing_element_index)
	}
}

@(private)
open_element :: proc() {
	ctx := active_context
	if ctx.layout_elements.length == ctx.layout_elements.capacity - 1 ||
	   ctx.warnings.max_elements_exceeded {
		ctx.warnings.max_elements_exceeded = true
		return
	}
	layout_element := Layout_Element{}
	open_layout_element := array_add(&ctx.layout_elements, layout_element)
	array_add(&ctx.open_layout_element_stack, ctx.layout_elements.length - 1)
	// Generate an ID
	parent_element := array_get(
		&ctx.layout_elements,
		array_get_value(&ctx.open_layout_element_stack, ctx.open_layout_element_stack.length - 2),
	)
	offset := u32(parent_element.children.length) + u32(parent_element.floating_children_count)
	element_id := hash_number(offset, parent_element.id)
	open_layout_element.id = element_id.id
	add_hash_map_item(element_id, open_layout_element)
	if ctx.open_clip_element_stack.length > 0 {
		array_set(
			&ctx.layout_element_clip_element_ids,
			ctx.layout_elements.length - 1,
			array_get_value(&ctx.open_clip_element_stack, ctx.open_clip_element_stack.length - 1),
		)
	} else {
		array_set(&ctx.layout_element_clip_element_ids, ctx.layout_elements.length - 1, 0)
	}
}

@(private)
open_element_with_id :: proc(element_id: Id) {
	ctx := active_context
	if ctx.layout_elements.length == ctx.layout_elements.capacity - 1 ||
	   ctx.warnings.max_elements_exceeded {
		ctx.warnings.max_elements_exceeded = true
		return
	}
	layout_element := Layout_Element{}
	layout_element.id = element_id.id
	open_layout_element := array_add(&ctx.layout_elements, layout_element)
	array_add(&ctx.open_layout_element_stack, ctx.layout_elements.length - 1)
	add_hash_map_item(element_id, open_layout_element)
	if ctx.open_clip_element_stack.length > 0 {
		array_set(
			&ctx.layout_element_clip_element_ids,
			ctx.layout_elements.length - 1,
			array_get_value(&ctx.open_clip_element_stack, ctx.open_clip_element_stack.length - 1),
		)
	} else {
		array_set(&ctx.layout_element_clip_element_ids, ctx.layout_elements.length - 1, 0)
	}
}

@(private)
open_text_element :: proc(text: String, text_config: Text_Style) {
	text := text
	text_config := text_config
	ctx := active_context
	if ctx.layout_elements.length == ctx.layout_elements.capacity - 1 ||
	   ctx.warnings.max_elements_exceeded {
		ctx.warnings.max_elements_exceeded = true
		return
	}
	parent_element := get_open_layout_element()

	layout_element := Layout_Element{}
	layout_element.text_config = text_config
	layout_element.is_text_element = true
	text_element := array_add(&ctx.layout_elements, layout_element)
	if ctx.open_clip_element_stack.length > 0 {
		array_set(
			&ctx.layout_element_clip_element_ids,
			ctx.layout_elements.length - 1,
			array_get_value(&ctx.open_clip_element_stack, ctx.open_clip_element_stack.length - 1),
		)
	} else {
		array_set(&ctx.layout_element_clip_element_ids, ctx.layout_elements.length - 1, 0)
	}

	array_add(&ctx.layout_element_children_buffer, ctx.layout_elements.length - 1)
	text_measured := measure_text_cached(&text, &text_config)
	element_id := hash_number(
		u32(parent_element.children.length) + u32(parent_element.floating_children_count),
		parent_element.id,
	)
	text_element.id = element_id.id
	add_hash_map_item(element_id, text_element)
	text_dimensions := Dimensions {
		width  = text_measured.unwrapped_dimensions.width,
		height = text_config.line_height > 0 ? f32(text_config.line_height) : text_measured.unwrapped_dimensions.height,
	}
	text_element.dimensions = text_dimensions
	text_element.min_dimensions = Dimensions {
		width  = text_measured.min_width,
		height = text_dimensions.height,
	}
	text_element.text_element_data = Text_Element_Data {
		text                 = text,
		preferred_dimensions = text_measured.unwrapped_dimensions,
	}
	parent_element.children.length += 1
}

@(private)
configure_open_element_ptr :: proc(declaration: ^Box) {
	ctx := active_context
	open_layout_element := get_open_layout_element()
	open_layout_element.config = declaration^
	if (declaration.width.kind == .Percent && declaration.width.percent > 1) ||
	   (declaration.height.kind == .Percent && declaration.height.percent > 1) {
		report_error(
			.Percentage_Over_1,
			"An element was configured with nendo.percent, but the provided percentage value was over 1.0. nendo expects a value between 0 and 1, i.e. 20% is 0.2.",
		)
	}

	if declaration.floating.attach_to != .None {
		floating_config := &open_layout_element.config.floating
		// This looks dodgy but because of the auto generated root element the depth of the tree will always be at least 2 here
		hierarchical_parent := array_get(
			&ctx.layout_elements,
			array_get_value(
				&ctx.open_layout_element_stack,
				ctx.open_layout_element_stack.length - 2,
			),
		)
		if hierarchical_parent != nil {
			clip_element_id: u32 = 0
			if declaration.floating.attach_to == .Parent {
				// Attach to the element's direct hierarchical parent
				floating_config.parent = hierarchical_parent.id
				if ctx.open_clip_element_stack.length > 0 {
					clip_element_id = u32(
						array_get_value(
							&ctx.open_clip_element_stack,
							ctx.open_clip_element_stack.length - 1,
						),
					)
				}
			} else if declaration.floating.attach_to == .Element {
				parent_item := get_hash_map_item(floating_config.parent)
				if parent_item == default_of(Layout_Element_Hash_Map_Item) {
					report_error(
						.Floating_Container_Parent_Not_Found,
						"A floating element was declared with a parentId, but no element with that ID was found.",
					)
				} else {
					clip_element_id = u32(
						array_get_value(
							&ctx.layout_element_clip_element_ids,
							i32(
								(uintptr(parent_item.layout_element) -
									uintptr(ctx.layout_elements.items)) /
								size_of(Layout_Element),
							),
						),
					)
				}
			} else if declaration.floating.attach_to == .Root {
				floating_config.parent = hash_string(static_string(ROOT_CONTAINER), 0).id
			}
			if declaration.floating.clip_to == .None {
				clip_element_id = 0
			}
			// A float attached to its parent without a z of its own draws in
			// the layer of the innermost open float, not at z 0, which would
			// sort it under that float (a text caret in a floating picker).
			if declaration.floating.attach_to == .Parent && floating_config.z == 0 {
				found := false
				for r := ctx.layout_element_tree_roots.length - 1; r >= 0 && !found; r -= 1 {
					root := array_get(&ctx.layout_element_tree_roots, r)
					for s: i32 = 0; s < ctx.open_layout_element_stack.length - 1; s += 1 {
						if array_get_value(&ctx.open_layout_element_stack, s) ==
						   root.layout_element_index {
							floating_config.z = root.z
							found = true
							break
						}
					}
				}
			}
			current_element_index := array_get_value(
				&ctx.open_layout_element_stack,
				ctx.open_layout_element_stack.length - 1,
			)
			array_set(
				&ctx.layout_element_clip_element_ids,
				current_element_index,
				i32(clip_element_id),
			)
			array_add(&ctx.open_clip_element_stack, i32(clip_element_id))
			array_add(
				&ctx.layout_element_tree_roots,
				Layout_Element_Tree_Root {
					layout_element_index = array_get_value(
						&ctx.open_layout_element_stack,
						ctx.open_layout_element_stack.length - 1,
					),
					parent_id = floating_config.parent,
					clip_element_id = clip_element_id,
					z = floating_config.z,
				},
			)
		}
	}

	if declaration.clip.x || declaration.clip.y {
		array_add(&ctx.open_clip_element_stack, i32(open_layout_element.id))
		// Retrieve or create cached data to track scroll position across frames
		scroll_offset: ^Scroll_Container_Data_Internal = nil
		for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
			mapping := array_get(&ctx.scroll_container_datas, i)
			if open_layout_element.id == mapping.element_id {
				scroll_offset = mapping
				scroll_offset.layout_element = open_layout_element
				scroll_offset.open_this_frame = true
			}
		}
		if scroll_offset == nil {
			scroll_offset = array_add(
				&ctx.scroll_container_datas,
				Scroll_Container_Data_Internal {
					layout_element = open_layout_element,
					scroll_origin = {-1, -1},
					element_id = open_layout_element.id,
					open_this_frame = true,
				},
			)
		}
	}
	// Setup data to track transitions across frames
	if declaration.transition.handler != nil {
		transition_data: ^Transition_Data_Internal = nil
		parent_element := get_parent_element()
		for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
			existing_data := array_get(&ctx.transition_datas, i)
			if open_layout_element.id == existing_data.element_id {
				if existing_data.state == .Exiting {
					existing_data.state = .Idle
					hash_map_item := get_hash_map_item(open_layout_element.id)
					hash_map_item.appeared_this_frame = false
				}
				transition_data = existing_data
				transition_data.element_this_frame = open_layout_element
				if transition_data.parent_id != parent_element.id {
					transition_data.reparented = true
				}
				transition_data.parent_id = parent_element.id
				transition_data.sibling_index = u32(parent_element.children.length)
				transition_data.transition_out = declaration.transition.exit.final != nil
			}
		}
		if transition_data == nil {
			transition_data = array_add(
				&ctx.transition_datas,
				Transition_Data_Internal {
					element_this_frame = open_layout_element,
					element_id = open_layout_element.id,
					parent_id = parent_element.id,
					sibling_index = u32(parent_element.children.length),
					transition_out = declaration.transition.exit.final != nil,
				},
			)
		}
	}
}
