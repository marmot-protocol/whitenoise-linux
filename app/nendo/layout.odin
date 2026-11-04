package nendo

// Layout passes: axis sizing, text wrapping, final positioning and render
// command generation.

@(private)
float_equal :: proc(left, right: f32) -> bool {
	subtracted := left - right
	return subtracted < EPSILON && subtracted > -EPSILON
}

@(private)
get_element_sizing :: proc(element: ^Layout_Element, x_axis: bool) -> Size {
	if element.is_text_element {
		return Size{}
	} else {
		return x_axis ? element.config.width : element.config.height
	}
}

// Writes out the location of text elements to layout elements buffer 1
@(private)
size_containers_along_axis :: proc(
	x_axis: bool,
	delta_time: f32,
	text_elements_out: ^Array(i32),
	aspect_ratio_elements_out: ^Array(i32),
) {
	ctx := active_context
	bfs_buffer := ctx.layout_element_children_buffer
	resizable_container_buffer := ctx.open_layout_element_stack
	for root_index: i32 = 0; root_index < ctx.layout_element_tree_roots.length; root_index += 1 {
		bfs_buffer.length = 0
		root := array_get(&ctx.layout_element_tree_roots, root_index)
		root_element := array_get(&ctx.layout_elements, root.layout_element_index)
		array_add(&bfs_buffer, root.layout_element_index)

		// Size floating containers to their parents
		if root_element.config.floating.attach_to != .None {
			floating_element_config := &root_element.config.floating
			parent_item := get_hash_map_item(floating_element_config.parent)
			if parent_item != nil && parent_item != default_of(Layout_Element_Hash_Map_Item) {
				parent_layout_element := parent_item.layout_element
				#partial switch root_element.config.width.kind {
				case .Grow:
					root_element.dimensions.width = parent_layout_element.dimensions.width
				case .Percent:
					root_element.dimensions.width =
						parent_layout_element.dimensions.width * root_element.config.width.percent
				}
				#partial switch root_element.config.height.kind {
				case .Grow:
					root_element.dimensions.height = parent_layout_element.dimensions.height
				case .Percent:
					root_element.dimensions.height =
						parent_layout_element.dimensions.height *
						root_element.config.height.percent
				}
			}
		}

		if root_element.config.width.kind != .Percent {
			root_element.dimensions.width = cmin(
				cmax(root_element.dimensions.width, root_element.config.width.min),
				root_element.config.width.max,
			)
		}
		if root_element.config.height.kind != .Percent {
			root_element.dimensions.height = cmin(
				cmax(root_element.dimensions.height, root_element.config.height.min),
				root_element.config.height.max,
			)
		}

		for i: i32 = 0; i < bfs_buffer.length; i += 1 {
			parent_index := array_get_value(&bfs_buffer, i)
			parent := array_get(&ctx.layout_elements, parent_index)
			parent_layout_config := &parent.config
			grow_container_count: i32 = 0
			parent_size := x_axis ? parent.dimensions.width : parent.dimensions.height
			parent_padding := f32(
				x_axis ? (i32(parent_layout_config.padding.left) + i32(parent_layout_config.padding.right)) : (i32(parent_layout_config.padding.top) + i32(parent_layout_config.padding.bottom)),
			)
			inner_content_size: f32 = 0
			total_padding_and_child_gaps := parent_padding
			sizing_along_axis :=
				(x_axis && parent_layout_config.direction == .Row) ||
				(!x_axis && parent_layout_config.direction == .Column)
			resizable_container_buffer.length = 0
			parent_child_gap := f32(parent_layout_config.gap)
			is_first_child := true

			for child_offset: i32 = 0;
			    child_offset < i32(parent.children.length);
			    child_offset += 1 {
				child_element_index := parent.children.elements[child_offset]
				child_element := array_get(&ctx.layout_elements, child_element_index)
				child_sizing := get_element_sizing(child_element, x_axis)
				child_size :=
					x_axis ? child_element.dimensions.width : child_element.dimensions.height

				if text_elements_out != nil && child_element.is_text_element {
					array_add(text_elements_out, child_element_index)
				} else if child_element.children.length > 0 {
					array_add(&bfs_buffer, child_element_index)
				}

				if !child_element.is_text_element &&
				   aspect_ratio_elements_out != nil &&
				   child_element.config.aspect != 0 {
					array_add(aspect_ratio_elements_out, child_element_index)
				}

				// Note: setting is_first_child = false is skipped here
				if child_element.exiting {
					continue
				}

				if child_sizing.kind != .Percent &&
				   child_sizing.kind != .Fixed &&
				   (!child_element.is_text_element || child_element.text_config.wrap == .Words) {
					array_add(&resizable_container_buffer, child_element_index)
				}

				if sizing_along_axis {
					inner_content_size += (child_sizing.kind == .Percent ? 0 : child_size)
					if child_sizing.kind == .Grow {
						grow_container_count += 1
					}
					if !is_first_child {
						inner_content_size += parent_child_gap // For children after index 0, the child_axis_offset is the gap from the previous child
						total_padding_and_child_gaps += parent_child_gap
					}
				} else {
					inner_content_size = cmax(child_size, inner_content_size)
				}
				is_first_child = false
			}

			// Expand percentage containers to size
			for child_offset: i32 = 0;
			    child_offset < i32(parent.children.length);
			    child_offset += 1 {
				child_element_index := parent.children.elements[child_offset]
				child_element := array_get(&ctx.layout_elements, child_element_index)
				child_sizing := get_element_sizing(child_element, x_axis)
				child_size :=
					x_axis ? &child_element.dimensions.width : &child_element.dimensions.height
				if child_sizing.kind == .Percent {
					child_size^ =
						(parent_size - total_padding_and_child_gaps) * child_sizing.percent
					if sizing_along_axis {
						inner_content_size += child_size^
					}
					update_aspect_ratio_box(child_element)
				}
			}

			if sizing_along_axis {
				size_to_distribute := parent_size - parent_padding - inner_content_size
				// The content is too large, compress the children as much as possible
				if size_to_distribute < 0 {
					// If the parent clips content in this axis direction, don't compress children, just leave them alone
					if ((x_axis && parent.config.clip.x) || (!x_axis && parent.config.clip.y)) {
						continue
					}
					// Scrolling containers preferentially compress before others
					for size_to_distribute < -EPSILON && resizable_container_buffer.length > 0 {
						largest: f32 = 0
						second_largest: f32 = 0
						width_to_add := size_to_distribute
						for child_index: i32 = 0;
						    child_index < resizable_container_buffer.length;
						    child_index += 1 {
							child := array_get(
								&ctx.layout_elements,
								array_get_value(&resizable_container_buffer, child_index),
							)
							child_size := x_axis ? child.dimensions.width : child.dimensions.height
							if float_equal(child_size, largest) {continue}
							if child_size > largest {
								second_largest = largest
								largest = child_size
							}
							if child_size < largest {
								second_largest = cmax(second_largest, child_size)
								width_to_add = second_largest - largest
							}
						}

						width_to_add = cmax(
							width_to_add,
							size_to_distribute / f32(resizable_container_buffer.length),
						)

						for child_index: i32 = 0;
						    child_index < resizable_container_buffer.length;
						    child_index += 1 {
							child := array_get(
								&ctx.layout_elements,
								array_get_value(&resizable_container_buffer, child_index),
							)
							child_size :=
								x_axis ? &child.dimensions.width : &child.dimensions.height
							min_size :=
								x_axis ? child.min_dimensions.width : child.min_dimensions.height
							previous_width := child_size^
							if float_equal(child_size^, largest) {
								child_size^ += width_to_add
								if child_size^ <= min_size {
									child_size^ = min_size
									array_remove_swapback(&resizable_container_buffer, child_index)
									child_index -= 1
								}
								size_to_distribute -= (child_size^ - previous_width)
							}
						}
					}
					// The content is too small, allow SIZING_GROW containers to expand
				} else if size_to_distribute > 0 && grow_container_count > 0 {
					for child_index: i32 = 0;
					    child_index < resizable_container_buffer.length;
					    child_index += 1 {
						child := array_get(
							&ctx.layout_elements,
							array_get_value(&resizable_container_buffer, child_index),
						)
						child_sizing := get_element_sizing(child, x_axis).kind
						if child_sizing != .Grow {
							array_remove_swapback(&resizable_container_buffer, child_index)
							child_index -= 1
						}
					}
					for size_to_distribute > EPSILON && resizable_container_buffer.length > 0 {
						smallest := MAX_FLOAT
						second_smallest := MAX_FLOAT
						width_to_add := size_to_distribute
						for child_index: i32 = 0;
						    child_index < resizable_container_buffer.length;
						    child_index += 1 {
							child := array_get(
								&ctx.layout_elements,
								array_get_value(&resizable_container_buffer, child_index),
							)
							child_size := x_axis ? child.dimensions.width : child.dimensions.height
							if float_equal(child_size, smallest) {continue}
							if child_size < smallest {
								second_smallest = smallest
								smallest = child_size
							}
							if child_size > smallest {
								second_smallest = cmin(second_smallest, child_size)
								width_to_add = second_smallest - smallest
							}
						}

						width_to_add = cmin(
							width_to_add,
							size_to_distribute / f32(resizable_container_buffer.length),
						)

						for child_index: i32 = 0;
						    child_index < resizable_container_buffer.length;
						    child_index += 1 {
							child := array_get(
								&ctx.layout_elements,
								array_get_value(&resizable_container_buffer, child_index),
							)
							child_size :=
								x_axis ? &child.dimensions.width : &child.dimensions.height
							child_sizing := get_element_sizing(child, x_axis)
							max_size := child_sizing.max
							previous_width := child_size^
							if float_equal(child_size^, smallest) {
								child_size^ += width_to_add
								if child_size^ >= max_size {
									child_size^ = max_size
									array_remove_swapback(&resizable_container_buffer, child_index)
									child_index -= 1
								}
								size_to_distribute -= (child_size^ - previous_width)
							}
						}
					}
				}
				// Sizing along the non layout axis ("off axis")
			} else {
				for child_offset: i32 = 0;
				    child_offset < resizable_container_buffer.length;
				    child_offset += 1 {
					child_element := array_get(
						&ctx.layout_elements,
						array_get_value(&resizable_container_buffer, child_offset),
					)
					child_sizing := get_element_sizing(child_element, x_axis)
					min_size :=
						x_axis ? child_element.min_dimensions.width : child_element.min_dimensions.height
					child_size :=
						x_axis ? &child_element.dimensions.width : &child_element.dimensions.height

					max_size := parent_size - parent_padding
					// If we're laying out the children of a scroll panel, grow containers expand to the size of the inner content, not the outer container
					if ((x_axis && parent.config.clip.x) || (!x_axis && parent.config.clip.y)) {
						max_size = cmax(max_size, inner_content_size)
					}
					if child_sizing.kind == .Grow {
						child_size^ = cmin(max_size, child_sizing.max)
					}
					child_size^ = cmax(min_size, cmin(child_size^, max_size))
				}
			}
		}
	}
}

@(private)
add_render_command :: proc(render_command: Render_Command) {
	ctx := active_context
	if ctx.render_commands.length < ctx.render_commands.capacity - 1 {
		array_add(&ctx.render_commands, render_command)
	} else {
		if !ctx.warnings.max_render_commands_exceeded {
			ctx.warnings.max_render_commands_exceeded = true
			report_error(
				.Elements_Capacity_Exceeded,
				"nendo ran out of capacity while attempting to create render commands. This is usually caused by a large amount of wrapping text elements while close to the max element capacity. Try using nendo.set_max_element_count() with a higher value.",
			)
		}
	}
}

@(private)
element_is_offscreen :: proc(bounding_box: ^Rect) -> bool {
	ctx := active_context
	return(
		(bounding_box.x > ctx.layout_dimensions.width) ||
		(bounding_box.y > ctx.layout_dimensions.height) ||
		(bounding_box.x + bounding_box.width < 0) ||
		(bounding_box.y + bounding_box.height < 0) \
	)
}

@(private)
calculate_final_layout :: proc(
	delta_time: f32,
	use_stored_bounding_boxes: bool,
	generate_render_commands: bool,
) {
	ctx := active_context

	// Calculate sizing along the X axis
	text_elements := ctx.open_clip_element_stack
	text_elements.length = 0
	aspect_ratio_elements := ctx.reusable_element_index_buffer
	aspect_ratio_elements.length = 0
	size_containers_along_axis(true, delta_time, &text_elements, &aspect_ratio_elements)

	// Wrap text
	for text_element_index: i32 = 0;
	    text_element_index < text_elements.length;
	    text_element_index += 1 {
		element := array_get(
			&ctx.layout_elements,
			array_get_value(&text_elements, text_element_index),
		)
		text_element_data := &element.text_element_data
		text_element_data.wrapped_lines = Array_Slice(Wrapped_Text_Line) {
			length = 0,
			items  = &ctx.wrapped_text_lines.items[ctx.wrapped_text_lines.length],
		}
		container_element := array_get(
			&ctx.layout_elements,
			array_get_value(&text_elements, text_element_index),
		)
		measure_text_cache_item := measure_text_cached(
			&text_element_data.text,
			&container_element.text_config,
		)
		line_width: f32 = 0
		line_height :=
			container_element.text_config.line_height > 0 ? f32(container_element.text_config.line_height) : text_element_data.preferred_dimensions.height
		line_length_chars: i32 = 0
		line_start_offset: i32 = 0
		if !measure_text_cache_item.contains_newlines &&
		   text_element_data.preferred_dimensions.width <= container_element.dimensions.width {
			array_add(
				&ctx.wrapped_text_lines,
				Wrapped_Text_Line{container_element.dimensions, text_element_data.text},
			)
			text_element_data.wrapped_lines.length += 1
			continue
		}
		space_width :=
			measure_text(" ", &container_element.text_config, ctx.measure_text_user_data).width
		word_index := measure_text_cache_item.measured_words_start_index
		for word_index != -1 {
			if ctx.wrapped_text_lines.length > ctx.wrapped_text_lines.capacity - 1 {
				break
			}
			measured_word := array_get(&ctx.measured_words, word_index)
			// Only word on the line is too large, just render it anyway
			if line_length_chars == 0 &&
			   line_width + measured_word.width > container_element.dimensions.width {
				array_add(
					&ctx.wrapped_text_lines,
					Wrapped_Text_Line {
						{measured_word.width, line_height},
						{
							length = measured_word.length,
							chars = &text_element_data.text.chars[measured_word.start_offset],
						},
					},
				)
				text_element_data.wrapped_lines.length += 1
				word_index = measured_word.next
				line_start_offset = measured_word.start_offset + measured_word.length
			} else if measured_word.length == 0 ||
			   line_width + measured_word.width > container_element.dimensions.width {
				// measured_word.length == 0 means a newline character
				// Wrapped text lines list has overflowed, just render out the line
				final_char_is_space :=
					text_element_data.text.chars[cmax(line_start_offset + line_length_chars - 1, 0)] ==
					' '
				array_add(
					&ctx.wrapped_text_lines,
					Wrapped_Text_Line {
						{line_width + (final_char_is_space ? -space_width : 0), line_height},
						{
							length = line_length_chars + (final_char_is_space ? i32(-1) : i32(0)),
							chars = &text_element_data.text.chars[line_start_offset],
						},
					},
				)
				text_element_data.wrapped_lines.length += 1
				if line_length_chars == 0 || measured_word.length == 0 {
					word_index = measured_word.next
				}
				line_width = 0
				line_length_chars = 0
				line_start_offset = measured_word.start_offset
			} else {
				line_width += measured_word.width + f32(container_element.text_config.spacing)
				line_length_chars += measured_word.length
				word_index = measured_word.next
			}
		}
		if line_length_chars > 0 {
			array_add(
				&ctx.wrapped_text_lines,
				Wrapped_Text_Line {
					{line_width - f32(container_element.text_config.spacing), line_height},
					{
						length = line_length_chars,
						chars = &text_element_data.text.chars[line_start_offset],
					},
				},
			)
			text_element_data.wrapped_lines.length += 1
		}
		container_element.dimensions.height =
			line_height * f32(text_element_data.wrapped_lines.length)
	}

	// Scale vertical heights according to aspect ratio
	for i: i32 = 0; i < aspect_ratio_elements.length; i += 1 {
		aspect_element := array_get(
			&ctx.layout_elements,
			array_get_value(&aspect_ratio_elements, i),
		)
		aspect_element.dimensions.height =
			(1 / aspect_element.config.aspect) * aspect_element.dimensions.width
		aspect_element.config.height.max = aspect_element.dimensions.height
	}

	// Propagate effect of text wrapping, aspect scaling etc. on height of parents
	dfs_buffer := ctx.layout_element_tree_node_array1
	dfs_buffer.length = 0
	for i: i32 = 0; i < ctx.layout_element_tree_roots.length; i += 1 {
		root := array_get(&ctx.layout_element_tree_roots, i)
		ctx.tree_node_visited.items[dfs_buffer.length] = false
		array_add(
			&dfs_buffer,
			Layout_Element_Tree_Node {
				layout_element = array_get(&ctx.layout_elements, root.layout_element_index),
			},
		)
	}
	for dfs_buffer.length > 0 {
		current_element_tree_node := array_get(&dfs_buffer, dfs_buffer.length - 1)
		current_element := current_element_tree_node.layout_element
		if !ctx.tree_node_visited.items[dfs_buffer.length - 1] {
			ctx.tree_node_visited.items[dfs_buffer.length - 1] = true
			// If the element has no children or is the container for a text element, don't bother inspecting it
			if current_element.is_text_element || current_element.children.length == 0 {
				dfs_buffer.length -= 1
				continue
			}
			// Add the children to the DFS buffer (needs to be pushed in reverse so that stack traversal is in correct layout order)
			for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
				ctx.tree_node_visited.items[dfs_buffer.length] = false
				array_add(
					&dfs_buffer,
					Layout_Element_Tree_Node {
						layout_element = array_get(
							&ctx.layout_elements,
							current_element.children.elements[i],
						),
					},
				)
			}
			continue
		}
		dfs_buffer.length -= 1

		// DFS node has been visited, this is on the way back up to the root
		layout_config := &current_element.config
		if layout_config.direction == .Row {
			// Resize any parent containers that have grown in height along their non layout axis
			for j: i32 = 0; j < i32(current_element.children.length); j += 1 {
				child_element := array_get(
					&ctx.layout_elements,
					current_element.children.elements[j],
				)
				child_height_with_padding := cmax(
					child_element.dimensions.height +
					f32(layout_config.padding.top) +
					f32(layout_config.padding.bottom),
					current_element.dimensions.height,
				)
				current_element.dimensions.height = cmin(
					cmax(child_height_with_padding, layout_config.height.min),
					layout_config.height.max,
				)
			}
		} else if layout_config.direction == .Column {
			// Resizing along the layout axis
			content_height := f32(
				i32(layout_config.padding.top) + i32(layout_config.padding.bottom),
			)
			for j: i32 = 0; j < i32(current_element.children.length); j += 1 {
				child_element := array_get(
					&ctx.layout_elements,
					current_element.children.elements[j],
				)
				content_height += child_element.dimensions.height
			}
			content_height += f32(
				cmax(i32(current_element.children.length) - 1, 0) * i32(layout_config.gap),
			)
			current_element.dimensions.height = cmin(
				cmax(content_height, layout_config.height.min),
				layout_config.height.max,
			)
		}
	}

	// Calculate sizing along the Y axis
	size_containers_along_axis(false, delta_time, nil, nil)

	// Scale horizontal widths according to aspect ratio
	for i: i32 = 0; i < aspect_ratio_elements.length; i += 1 {
		aspect_element := array_get(
			&ctx.layout_elements,
			array_get_value(&aspect_ratio_elements, i),
		)
		aspect_element.dimensions.width =
			aspect_element.config.aspect * aspect_element.dimensions.height
	}

	// Sort tree roots by z-index
	sort_max := ctx.layout_element_tree_roots.length - 1
	for sort_max > 0 { 	// todo dumb bubble sort
		for i: i32 = 0; i < sort_max; i += 1 {
			current := array_get(&ctx.layout_element_tree_roots, i)^
			next := array_get(&ctx.layout_element_tree_roots, i + 1)^
			if next.z < current.z {
				array_set(&ctx.layout_element_tree_roots, i, next)
				array_set(&ctx.layout_element_tree_roots, i + 1, current)
			}
		}
		sort_max -= 1
	}

	// Calculate final positions and generate render commands
	ctx.render_commands.length = 0
	dfs_buffer.length = 0

	for root_index: i32 = 0; root_index < ctx.layout_element_tree_roots.length; root_index += 1 {
		dfs_buffer.length = 0
		root := array_get(&ctx.layout_element_tree_roots, root_index)
		root_element := array_get(&ctx.layout_elements, root.layout_element_index)
		root_position := Vector2{}
		parent_hash_map_item := get_hash_map_item(root.parent_id)
		// Position root floating containers
		if root_element.config.floating.attach_to != .None && parent_hash_map_item != nil {
			config := &root_element.config.floating
			root_dimensions := root_element.dimensions
			parent_bounding_box := parent_hash_map_item.bounding_box
			// Set X position
			target_attach_position := Vector2{}
			switch config.attach.parent {
			case .Left_Top, .Left_Center, .Left_Bottom:
				target_attach_position.x = parent_bounding_box.x
			case .Center_Top, .Center_Center, .Center_Bottom:
				target_attach_position.x = parent_bounding_box.x + (parent_bounding_box.width / 2)
			case .Right_Top, .Right_Center, .Right_Bottom:
				target_attach_position.x = parent_bounding_box.x + parent_bounding_box.width
			}
			switch config.attach.element {
			case .Left_Top, .Left_Center, .Left_Bottom:
			case .Center_Top, .Center_Center, .Center_Bottom:
				target_attach_position.x -= (root_dimensions.width / 2)
			case .Right_Top, .Right_Center, .Right_Bottom:
				target_attach_position.x -= root_dimensions.width
			}
			switch config.attach.parent { 	// I know I could merge the x and y switch statements, but this is easier to read
			case .Left_Top, .Right_Top, .Center_Top:
				target_attach_position.y = parent_bounding_box.y
			case .Left_Center, .Center_Center, .Right_Center:
				target_attach_position.y = parent_bounding_box.y + (parent_bounding_box.height / 2)
			case .Left_Bottom, .Center_Bottom, .Right_Bottom:
				target_attach_position.y = parent_bounding_box.y + parent_bounding_box.height
			}
			switch config.attach.element {
			case .Left_Top, .Right_Top, .Center_Top:
			case .Left_Center, .Center_Center, .Right_Center:
				target_attach_position.y -= (root_dimensions.height / 2)
			case .Left_Bottom, .Center_Bottom, .Right_Bottom:
				target_attach_position.y -= root_dimensions.height
			}
			target_attach_position.x += config.offset.x
			target_attach_position.y += config.offset.y
			root_position = target_attach_position
		}
		if root.clip_element_id != 0 {
			clip_hash_map_item := get_hash_map_item(root.clip_element_id)
			if clip_hash_map_item != nil &&
			   !element_is_offscreen(&clip_hash_map_item.bounding_box) {
				if generate_render_commands {
					add_render_command(
						Render_Command {
							rect      = clip_hash_map_item.bounding_box,
							user_data = nil,
							id        = hash_number(root_element.id, u32(root_element.children.length) + 10).id, // TODO need a better strategy for managing derived ids
							z         = root.z,
							kind      = .Scissor_Start,
						},
					)
				}
			}
		}
		array_add(
			&dfs_buffer,
			Layout_Element_Tree_Node {
				layout_element = root_element,
				position = root_position,
				next_child_offset = {
					f32(root_element.config.padding.left),
					f32(root_element.config.padding.top),
				},
			},
		)

		ctx.tree_node_visited.items[0] = false
		for dfs_buffer.length > 0 {
			current_element_tree_node := array_get(&dfs_buffer, dfs_buffer.length - 1)
			current_element := current_element_tree_node.layout_element
			layout_config :=
				current_element.is_text_element ? default_of(Box) : &current_element.config
			scroll_offset := Vector2{}

			// DFS is returning back upwards
			if ctx.tree_node_visited.items[dfs_buffer.length - 1] {
				if current_element.is_text_element {
					dfs_buffer.length -= 1
					continue
				}
				current_element_data := get_hash_map_item(current_element.id)
				if generate_render_commands &&
				   !element_is_offscreen(&current_element_data.bounding_box) {
					// DFS is returning upwards backwards
					close_clip_element := false
					if current_element.config.clip.x || current_element.config.clip.y {
						close_clip_element = true
						for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
							mapping := array_get(&ctx.scroll_container_datas, i)
							if mapping.element_id == current_element.id {
								scroll_offset = current_element.config.clip.offset
								break
							}
						}
					}

					if border_has_any_width(&current_element.config.border) {
						current_element_bounding_box := current_element_data.bounding_box
						border_config := &current_element.config.border
						render_command := Render_Command {
							rect = current_element_bounding_box,
							data = {
								border = {
									color = border_config.color,
									radius = current_element.config.radius,
									width = border_config.width,
								},
							},
							user_data = current_element.config.user_data,
							id = hash_number(current_element.id, u32(current_element.children.length)).id,
							kind = .Border,
						}
						add_render_command(render_command)
						if border_config.width.between > 0 && border_config.color.a > 0 {
							// Integer divisions
							half_gap := f32(i32(layout_config.gap) / 2)
							half_width := f32(i32(border_config.width.between) / 2)
							border_offset := Vector2 {
								f32(layout_config.padding.left) - half_gap,
								f32(layout_config.padding.top) - half_gap,
							}
							if layout_config.direction == .Row {
								for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
									child_element := array_get(
										&ctx.layout_elements,
										current_element.children.elements[i],
									)
									if i > 0 {
										add_render_command(
											Render_Command {
												rect = {
													current_element_bounding_box.x +
													border_offset.x +
													scroll_offset.x -
													half_width,
													current_element_bounding_box.y +
													scroll_offset.y,
													f32(border_config.width.between),
													current_element.dimensions.height,
												},
												data = {rectangle = {color = border_config.color}},
												user_data = current_element.config.user_data,
												id = hash_number(current_element.id, u32(current_element.children.length) + 1 + u32(i)).id,
												kind = .Rectangle,
											},
										)
									}
									border_offset.x +=
										(child_element.dimensions.width + f32(layout_config.gap))
								}
							} else {
								for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
									child_element := array_get(
										&ctx.layout_elements,
										current_element.children.elements[i],
									)
									if i > 0 {
										add_render_command(
											Render_Command {
												rect = {
													current_element_bounding_box.x +
													scroll_offset.x,
													current_element_bounding_box.y +
													border_offset.y +
													scroll_offset.y -
													half_width,
													current_element.dimensions.width,
													f32(border_config.width.between),
												},
												data = {rectangle = {color = border_config.color}},
												user_data = current_element.config.user_data,
												id = hash_number(current_element.id, u32(current_element.children.length) + 1 + u32(i)).id,
												kind = .Rectangle,
											},
										)
									}
									border_offset.y +=
										(child_element.dimensions.height + f32(layout_config.gap))
								}
							}
						}
					}
					if current_element.config.overlay.a > 0 {
						render_command := Render_Command {
							user_data = current_element.config.user_data,
							id        = current_element.id,
							z         = root.z,
							kind      = .Overlay_End,
						}
						add_render_command(render_command)
					}
					// This exists because the scissor needs to end _after_ borders between elements
					if close_clip_element {
						add_render_command(
							Render_Command {
								id = hash_number(current_element.id, u32(root_element.children.length) + 11).id,
								kind = .Scissor_End,
							},
						)
					}
				}

				dfs_buffer.length -= 1
				continue
			}

			// This will only be run a single time for each element in downwards DFS order
			ctx.tree_node_visited.items[dfs_buffer.length - 1] = true
			current_element_bounding_box := Rect {
				current_element_tree_node.position.x,
				current_element_tree_node.position.y,
				current_element.dimensions.width,
				current_element.dimensions.height,
			}
			scroll_container_data: ^Scroll_Container_Data_Internal = nil
			if !current_element.is_text_element {
				if use_stored_bounding_boxes && current_element.config.transition.handler != nil {
					found := false
					for j: i32 = 0; j < ctx.transition_datas.length; j += 1 {
						transition_data := array_get(&ctx.transition_datas, j)
						if transition_data.element_id == current_element.id {
							found = true
							if transition_data.state != .Idle {
								if .X in
								   transition_data.active_properties {current_element_bounding_box.x = transition_data.current_state.rect.x}
								if .Y in
								   transition_data.active_properties {current_element_bounding_box.y = transition_data.current_state.rect.y}
								if .Width in
								   transition_data.active_properties {current_element_bounding_box.width = transition_data.current_state.rect.width}
								if .Height in
								   transition_data.active_properties {current_element_bounding_box.height = transition_data.current_state.rect.height}
							}
							break
						}
					}
					// An exiting element that completed its transition this frame - skip tree
					if !found && current_element.config.transition.exit.final != nil {
						dfs_buffer.length -= 1
						continue
					}
				}
				if current_element.config.floating.attach_to != .None {
					floating_element_config := &current_element.config.floating
					expand := floating_element_config.expand
					current_element_bounding_box.x -= expand.width
					current_element_bounding_box.width += expand.width * 2
					current_element_bounding_box.y -= expand.height
					current_element_bounding_box.height += expand.height * 2
				}

				// Apply scroll offsets to container
				if current_element.config.clip.x || current_element.config.clip.y {
					// This linear scan could theoretically be slow under very strange conditions, but I can't imagine a real UI with more than a few 10's of scroll containers
					for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
						mapping := array_get(&ctx.scroll_container_datas, i)
						if mapping.element_id == current_element.id {
							scroll_container_data = mapping
							mapping.bounding_box = current_element_bounding_box
							scroll_offset = current_element.config.clip.offset
							break
						}
					}
				}
			}

			offscreen := element_is_offscreen(&current_element_bounding_box)

			// Generate render commands for current element
			if generate_render_commands && !offscreen {
				if current_element.is_text_element {
					text_element_config := &current_element.text_config
					natural_line_height :=
						current_element.text_element_data.preferred_dimensions.height
					final_line_height :=
						text_element_config.line_height > 0 ? f32(text_element_config.line_height) : natural_line_height
					line_height_offset := (final_line_height - natural_line_height) / 2
					y_position := line_height_offset
					for line_index: i32 = 0;
					    line_index < current_element.text_element_data.wrapped_lines.length;
					    line_index += 1 {
						wrapped_line := slice_get(
							&current_element.text_element_data.wrapped_lines,
							line_index,
						)
						if wrapped_line.line.length == 0 {
							y_position += final_line_height
							continue
						}
						offset :=
							(current_element_bounding_box.width - wrapped_line.dimensions.width)
						if text_element_config.align == .Left {
							offset = 0
						}
						if text_element_config.align == .Center {
							offset /= 2
						}
						add_render_command(
							Render_Command {
								rect = {
									current_element_bounding_box.x + offset,
									current_element_bounding_box.y + y_position,
									wrapped_line.dimensions.width,
									wrapped_line.dimensions.height,
								},
								data = {
									text = {
										text = to_string(
											wrapped_line.line.chars,
											wrapped_line.line.length,
										),
										color = text_element_config.color,
										font = text_element_config.font,
										size = text_element_config.size,
										spacing = text_element_config.spacing,
										line_height = text_element_config.line_height,
									},
								},
								user_data = text_element_config.user_data,
								id = hash_number(u32(line_index), current_element.id).id,
								z = root.z,
								kind = .Text,
							},
						)
						y_position += final_line_height

						if current_element_bounding_box.y + y_position >
						   ctx.layout_dimensions.height {
							break
						}
					}
				} else {
					if current_element.config.overlay.a > 0 {
						render_command := Render_Command {
							data = {overlay = {color = current_element.config.overlay}},
							user_data = current_element.config.user_data,
							id = current_element.id,
							z = root.z,
							kind = .Overlay_Start,
						}
						add_render_command(render_command)
					}
					if current_element.config.image != nil {
						render_command := Render_Command {
							rect = current_element_bounding_box,
							data = {
								image = {
									color = current_element.config.color,
									radius = current_element.config.radius,
									image = current_element.config.image,
								},
							},
							user_data = current_element.config.user_data,
							id = current_element.id,
							z = root.z,
							kind = .Image,
						}
						add_render_command(render_command)
					}
					if current_element.config.custom != nil {
						render_command := Render_Command {
							rect = current_element_bounding_box,
							data = {
								custom = {
									color = current_element.config.color,
									radius = current_element.config.radius,
									custom = current_element.config.custom,
								},
							},
							user_data = current_element.config.user_data,
							id = current_element.id,
							z = root.z,
							kind = .Custom,
						}
						add_render_command(render_command)
					}
					if current_element.config.clip.x || current_element.config.clip.y {
						render_command := Render_Command {
							rect = current_element_bounding_box,
							data = {
								clip = {
									x = current_element.config.clip.x,
									y = current_element.config.clip.y,
								},
							},
							user_data = current_element.config.user_data,
							id = current_element.id,
							z = root.z,
							kind = .Scissor_Start,
						}
						add_render_command(render_command)
					}
					if current_element.config.color.a > 0 {
						render_command := Render_Command {
							rect = current_element_bounding_box,
							data = {
								rectangle = {
									color = current_element.config.color,
									radius = current_element.config.radius,
								},
							},
							user_data = current_element.config.user_data,
							id = current_element.id,
							z = root.z,
							kind = .Rectangle,
						}
						add_render_command(render_command)
					}
				}
			}

			hash_map_item := get_hash_map_item(current_element.id)
			hash_map_item.bounding_box = current_element_bounding_box

			if current_element.is_text_element {continue}

			// Setup positions for child elements and add to DFS buffer ----------

			// On-axis alignment
			content_size_current := Dimensions{}
			if layout_config.direction == .Row {
				for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
					child_element := array_get(
						&ctx.layout_elements,
						current_element.children.elements[i],
					)
					if child_element.exiting {continue}
					content_size_current.width += child_element.dimensions.width
					content_size_current.height = cmax(
						content_size_current.height,
						child_element.dimensions.height,
					)
				}
				content_size_current.width += f32(
					cmax(i32(current_element.children.length) - 1, 0) * i32(layout_config.gap),
				)
				extra_space :=
					current_element.dimensions.width -
					f32(i32(layout_config.padding.left) + i32(layout_config.padding.right)) -
					content_size_current.width
				#partial switch layout_config.align.x {
				case .Left:
					extra_space = 0
				case .Center:
					extra_space /= 2
				}
				extra_space = cmax(f32(0), extra_space)
				current_element_tree_node.next_child_offset.x += extra_space
			} else if layout_config.direction == .Column {
				for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
					child_element := array_get(
						&ctx.layout_elements,
						current_element.children.elements[i],
					)
					if child_element.exiting {continue}
					content_size_current.width = cmax(
						content_size_current.width,
						child_element.dimensions.width,
					)
					content_size_current.height += child_element.dimensions.height
				}
				content_size_current.height += f32(
					cmax(i32(current_element.children.length) - 1, 0) * i32(layout_config.gap),
				)
				extra_space :=
					current_element.dimensions.height -
					f32(i32(layout_config.padding.top) + i32(layout_config.padding.bottom)) -
					content_size_current.height
				#partial switch layout_config.align.y {
				case .Top:
					extra_space = 0
				case .Center:
					extra_space /= 2
				}
				extra_space = cmax(f32(0), extra_space)
				current_element_tree_node.next_child_offset.y += extra_space
			}

			if scroll_container_data != nil {
				scroll_container_data.content_size = Dimensions {
					content_size_current.width +
					f32(i32(layout_config.padding.left) + i32(layout_config.padding.right)),
					content_size_current.height +
					f32(i32(layout_config.padding.top) + i32(layout_config.padding.bottom)),
				}
			}

			// Add children to the DFS buffer
			dfs_buffer.length += i32(current_element.children.length)
			for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
				child_element := array_get(
					&ctx.layout_elements,
					current_element.children.elements[i],
				)
				_ = get_hash_map_item(child_element.id) // unused lookup, kept for its range check
				// Alignment along non layout axis
				if layout_config.direction == .Row {
					current_element_tree_node.next_child_offset.y = f32(
						current_element.config.padding.top,
					)
					white_space_around_child :=
						current_element.dimensions.height -
						f32(i32(layout_config.padding.top) + i32(layout_config.padding.bottom)) -
						child_element.dimensions.height
					switch layout_config.align.y {
					case .Top:
					case .Center:
						current_element_tree_node.next_child_offset.y +=
							white_space_around_child / 2
					case .Bottom:
						current_element_tree_node.next_child_offset.y += white_space_around_child
					}
				} else {
					current_element_tree_node.next_child_offset.x = f32(
						current_element.config.padding.left,
					)
					white_space_around_child :=
						current_element.dimensions.width -
						f32(i32(layout_config.padding.left) + i32(layout_config.padding.right)) -
						child_element.dimensions.width
					switch layout_config.align.x {
					case .Left:
					case .Center:
						current_element_tree_node.next_child_offset.x +=
							white_space_around_child / 2
					case .Right:
						current_element_tree_node.next_child_offset.x += white_space_around_child
					}
				}

				child_position := Vector2 {
					current_element_bounding_box.x +
					current_element_tree_node.next_child_offset.x +
					scroll_offset.x,
					current_element_bounding_box.y +
					current_element_tree_node.next_child_offset.y +
					scroll_offset.y,
				}

				// DFS buffer elements need to be added in reverse because stack traversal happens backwards
				new_node_index := u32(dfs_buffer.length - 1 - i)
				// A text child reads its padding through the union's text payload bytes
				dfs_buffer.items[new_node_index] = Layout_Element_Tree_Node {
					layout_element    = child_element,
					position          = Vector2{child_position.x, child_position.y},
					next_child_offset = {
						f32(child_element.config.padding.left),
						f32(child_element.config.padding.top),
					},
				}
				ctx.tree_node_visited.items[new_node_index] = false

				// Update parent offsets
				if !child_element.exiting {
					if layout_config.direction == .Row {
						current_element_tree_node.next_child_offset.x +=
							child_element.dimensions.width + f32(layout_config.gap)
					} else {
						current_element_tree_node.next_child_offset.y +=
							child_element.dimensions.height + f32(layout_config.gap)
					}
				}
			}
		}

		if root.clip_element_id != 0 {
			clip_hash_map_item := get_hash_map_item(root.clip_element_id)
			if clip_hash_map_item != nil &&
			   !element_is_offscreen(&clip_hash_map_item.bounding_box) {
				add_render_command(
					Render_Command {
						id = hash_number(root_element.id, u32(root_element.children.length) + 11).id,
						kind = .Scissor_End,
					},
				)
			}
		}
	}
}
