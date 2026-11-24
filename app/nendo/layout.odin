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

@(private)
grid_content_height :: proc(element: ^Layout_Element) -> f32 {
	columns := i32(element.grid_columns)
	rows := (i32(element.grid_count) + columns - 1) / columns
	return(
		f32(rows) * element.config.grid.row_height +
		f32(cmax(rows - 1, 0)) * f32(element.config.gap) \
	)
}

@(private)
resolve_percent :: proc(size: Size, available: f32) -> f32 {
	length := cmax(f32(0), available) * size.percent
	return size.max > 0 ? cmin(length, size.max) : length
}

@(private)
size_wrapped_item :: proc(child: ^Layout_Element, inner_width: f32) {
	if child.is_text_element {
		if child.text_config.wrap == .Words {
			child.dimensions.width = cmax(
				child.min_dimensions.width,
				cmin(child.text_element_data.preferred_dimensions.width, inner_width),
			)
		}
		return
	}
	box := &child.config
	switch box.width.kind {
	case .Fit, .Grow:
		child.dimensions.width = cmax(
			child.min_dimensions.width,
			cmin(child.dimensions.width, inner_width),
		)
	case .Percent:
		child.dimensions.width = resolve_percent(box.width, inner_width)
	case .Fixed:
	}
	if box.aspect > 0 && box.height.kind != .Percent && .Height not_in child.animated_size {
		child.dimensions.height = child.dimensions.width / box.aspect
		box.height = fixed(child.dimensions.height)
	}
}

@(private)
wrap_item_height :: proc(child: ^Layout_Element, inner_height: f32) -> f32 {
	if !child.is_text_element && child.config.height.kind == .Percent {
		child.dimensions.height = resolve_percent(child.config.height, inner_height)
	}
	return child.dimensions.height
}

@(private)
measure_wrap_rows :: proc(ctx: ^Context, parent: ^Layout_Element) -> f32 {
	parent.wrap_first = ctx.wrapped_rows.length
	box := &parent.config
	inner_width := parent.dimensions.width - f32(box.padding.left) - f32(box.padding.right)
	inner_height: f32
	if box.height.kind == .Fixed || box.aspect != 0 {
		inner_height = cmax(
			f32(0),
			parent.dimensions.height - f32(box.padding.top) - f32(box.padding.bottom),
		)
	}
	gap := f32(box.gap)
	row := Dimensions{}
	height: f32
	has_item := false
	count := i32(parent.children.length)
	for i in 0 ..< count {
		child := array_get(&ctx.layout_elements, parent.children.elements[i])
		if child.exiting {continue}
		size := Dimensions{child.dimensions.width, wrap_item_height(child, inner_height)}
		width := row.width + (has_item ? gap : 0) + size.width
		if has_item && width > inner_width {
			array_add(&ctx.wrapped_rows, Wrapped_Row{end = i, dimensions = row})
			height += row.height + gap
			row = size
		} else {
			row = {width, cmax(row.height, size.height)}
		}
		has_item = true
	}
	array_add(&ctx.wrapped_rows, Wrapped_Row{end = count, dimensions = row})
	return height + row.height
}

@(private)
resize_wrap_rows :: proc(ctx: ^Context, parent: ^Layout_Element, inner_height: f32) {
	start: i32
	for index := parent.wrap_first; start < i32(parent.children.length); index += 1 {
		row := array_get(&ctx.wrapped_rows, index)
		row.dimensions.height = 0
		for i in start ..< row.end {
			child := array_get(&ctx.layout_elements, parent.children.elements[i])
			if child.exiting {continue}
			row.dimensions.height = cmax(
				row.dimensions.height,
				wrap_item_height(child, inner_height),
			)
		}
		start = row.end
	}
}

@(private)
align_x_offset :: proc(align: Align_X, space: f32) -> f32 {
	#partial switch align {
	case .Center:
		return space / 2
	case .Right:
		return space
	}
	return 0
}

@(private)
align_y_offset :: proc(align: Align_Y, space: f32) -> f32 {
	#partial switch align {
	case .Center:
		return space / 2
	case .Bottom:
		return space
	}
	return 0
}

@(private)
Layout_Pass :: enum {
	Static,
	Target,
	Animated,
}

// Writes out the location of text elements to layout elements buffer 1
@(private)
size_containers_along_axis :: proc(
	x_axis: bool,
	pass: Layout_Pass,
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
					root_element.dimensions.width = resolve_percent(
						root_element.config.width,
						parent_layout_element.dimensions.width,
					)
				}
				#partial switch root_element.config.height.kind {
				case .Grow:
					root_element.dimensions.height = parent_layout_element.dimensions.height
				case .Percent:
					root_element.dimensions.height = resolve_percent(
						root_element.config.height,
						parent_layout_element.dimensions.height,
					)
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
			grid := parent_layout_config.grid.min_cell_width > 0
			wrap := !grid && parent_layout_config.direction == .Wrap_Row
			in_wrap_flow :=
				wrap ||
				parent.in_wrap_flow ||
				(parent.wrap_subtree && (sizing_along_axis || parent_layout_config.clip.x))
			preserve_intrinsic :=
				x_axis && pass != .Static && (in_wrap_flow || parent.wrap_subtree)
			inner: f32
			if x_axis && (grid || wrap) {
				inner = cmax(f32(0), parent_size - parent_padding)
			}
			if !x_axis && wrap && parent_layout_config.height.kind == .Percent {
				resize_wrap_rows(ctx, parent, parent_size - parent_padding)
			}
			if grid && x_axis {
				stride := parent_layout_config.grid.min_cell_width + parent_child_gap
				columns := clamp((inner + parent_child_gap) / stride, 1, f32(max(u16)))
				parent.grid_columns = u16(columns)
				parent.grid_cell_width =
					(inner + parent_child_gap) / f32(parent.grid_columns) - parent_child_gap
				parent.grid_count = 0
			}

			for child_offset: i32 = 0;
			    child_offset < i32(parent.children.length);
			    child_offset += 1 {
				child_element_index := parent.children.elements[child_offset]
				child_element := array_get(&ctx.layout_elements, child_element_index)
				if preserve_intrinsic &&
				   (in_wrap_flow || child_element.wrap_subtree) &&
				   !child_element.exiting {
					// The target pass can narrow a subtree that has more room during the animation.
					if pass == .Target {
						child_element.in_wrap_flow = in_wrap_flow
						child_element.wrap_intrinsic = child_element.dimensions
					} else {
						if .Width not_in
						   child_element.animated_size {child_element.dimensions.width = child_element.wrap_intrinsic.width}
						if .Height not_in
						   child_element.animated_size {child_element.dimensions.height = child_element.wrap_intrinsic.height}
					}
				}

				if text_elements_out != nil && child_element.is_text_element {
					array_add(text_elements_out, child_element_index)
				} else if child_element.children.length > 0 {
					array_add(&bfs_buffer, child_element_index)
				}

				if grid {
					if child_element.exiting {continue}
					if x_axis {
						parent.grid_count += 1
						if child_element.is_text_element {
							if child_element.text_config.wrap == .Words {
								child_element.dimensions.width = cmax(
									parent.grid_cell_width,
									child_element.min_dimensions.width,
								)
							}
						} else if .Width not_in child_element.animated_size {
							child_element.dimensions.width = parent.grid_cell_width
						}
					} else if !child_element.is_text_element &&
					   .Height not_in child_element.animated_size {
						child_element.dimensions.height = parent_layout_config.grid.row_height
					}
					continue
				}
				if wrap {
					if x_axis && !child_element.exiting {size_wrapped_item(child_element, inner)}
					continue
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

				child_sizing := get_element_sizing(child_element, x_axis)
				child_size :=
					x_axis ? child_element.dimensions.width : child_element.dimensions.height
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
			if grid || wrap {continue}

			// Expand percentage containers to size
			for child_offset: i32 = 0;
			    child_offset < i32(parent.children.length);
			    child_offset += 1 {
				child_element_index := parent.children.elements[child_offset]
				child_element := array_get(&ctx.layout_elements, child_element_index)
				if child_element.exiting {continue}
				child_sizing := get_element_sizing(child_element, x_axis)
				child_size :=
					x_axis ? &child_element.dimensions.width : &child_element.dimensions.height
				if child_sizing.kind == .Percent {
					child_size^ = resolve_percent(
						child_sizing,
						parent_size - total_padding_and_child_gaps,
					)
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
calculate_final_layout :: proc(pass: Layout_Pass) {
	ctx := active_context
	use_stored_bounding_boxes := pass == .Animated
	generate_render_commands := pass != .Target

	// Calculate sizing along the X axis
	text_elements := ctx.open_clip_element_stack
	text_elements.length = 0
	aspect_ratio_elements := ctx.reusable_element_index_buffer
	aspect_ratio_elements.length = 0
	size_containers_along_axis(true, pass, &text_elements, &aspect_ratio_elements)

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
			container_element.dimensions.height = line_height
			array_add(
				&ctx.wrapped_text_lines,
				Wrapped_Text_Line {
					{text_element_data.preferred_dimensions.width, line_height},
					text_element_data.text,
				},
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
		box := &aspect_element.config
		if box.height.kind == .Percent {continue}
		if box.direction == .Wrap_Row && box.grid.min_cell_width <= 0 {
			if .Height not_in aspect_element.animated_size {
				aspect_element.dimensions.height = aspect_element.dimensions.width / box.aspect
			}
			// Width is final. A smaller height would break the ratio without repacking.
			box.height = fixed(aspect_element.dimensions.height)
			continue
		}
		aspect_element.dimensions.height = (1 / box.aspect) * aspect_element.dimensions.width
		box.height.max = aspect_element.dimensions.height
		if box.width.kind == .Percent {
			aspect_element.min_dimensions.height = cmin(
				aspect_element.min_dimensions.height,
				box.height.max,
			)
		}
	}

	// Propagate effect of text wrapping, aspect scaling etc. on height of parents
	ctx.wrapped_rows.length = 0
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
			if !current_element.is_text_element &&
			   current_element.config.height.kind == .Percent &&
			   current_element.config.floating.attach_to == .None {
				current_element.dimensions.height = 0
			}
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
		relative_height := layout_config.height.kind == .Percent
		if current_element.grid_columns > 0 || layout_config.direction == .Wrap_Row {
			rows_height :=
				current_element.grid_columns > 0 ? grid_content_height(current_element) : measure_wrap_rows(ctx, current_element)
			content_height :=
				rows_height + f32(layout_config.padding.top) + f32(layout_config.padding.bottom)
			if !relative_height &&
			   (current_element.grid_columns > 0 || layout_config.aspect == 0) {
				current_element.dimensions.height = clamp(
					content_height,
					layout_config.height.min,
					layout_config.height.max,
				)
			}
			if !relative_height && !layout_config.clip.y {
				current_element.min_dimensions.height = current_element.dimensions.height
			}
		} else if relative_height {
			continue
		} else if layout_config.direction == .Row {
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
	size_containers_along_axis(false, pass, nil, nil)

	// Scale horizontal widths according to aspect ratio
	for i: i32 = 0; i < aspect_ratio_elements.length; i += 1 {
		aspect_element := array_get(
			&ctx.layout_elements,
			array_get_value(&aspect_ratio_elements, i),
		)
		box := &aspect_element.config
		if (box.width.kind == .Percent && box.height.kind == .Percent) ||
		   (box.direction == .Wrap_Row && box.grid.min_cell_width <= 0) {continue}
		aspect_element.dimensions.width = box.aspect * aspect_element.dimensions.height
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
									fill = current_element.config.color,
									radius = current_element.config.radius,
									width = border_config.width,
								},
							},
							user_data = current_element.config.user_data,
							id = hash_number(current_element.id, u32(current_element.children.length)).id,
							kind = .Border,
						}
						add_render_command(render_command)
						if current_element.grid_columns == 0 &&
						   layout_config.direction != .Wrap_Row &&
						   border_config.width.between > 0 &&
						   border_config.color.a > 0 {
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
			grid_columns := i32(current_element.grid_columns)
			wrap := grid_columns == 0 && layout_config.direction == .Wrap_Row
			gap := f32(layout_config.gap)
			if grid_columns > 0 {
				if scroll_container_data != nil {
					columns_used := cmin(i32(current_element.grid_count), grid_columns)
					content_size_current.width =
						f32(columns_used) * current_element.grid_cell_width +
						f32(cmax(columns_used - 1, 0)) * gap
					content_size_current.height = grid_content_height(current_element)
				}
			} else if layout_config.direction == .Row {
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
				current_element_tree_node.next_child_offset.x += align_x_offset(
					layout_config.align.x,
					cmax(f32(0), extra_space),
				)
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
				current_element_tree_node.next_child_offset.y += align_y_offset(
					layout_config.align.y,
					cmax(f32(0), extra_space),
				)
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
			grid_column, grid_row: i32
			grid_step_x := current_element.grid_cell_width + gap
			grid_step_y := layout_config.grid.row_height + gap
			wrap_row: Wrapped_Row
			wrap_index := current_element.wrap_first
			wrap_y: f32
			for i: i32 = 0; i < i32(current_element.children.length); i += 1 {
				child_element := array_get(
					&ctx.layout_elements,
					current_element.children.elements[i],
				)
				_ = get_hash_map_item(child_element.id) // unused lookup, kept for its range check
				// Alignment along non layout axis
				if grid_columns > 0 {
					current_element_tree_node.next_child_offset = {
						f32(layout_config.padding.left) + f32(grid_column) * grid_step_x,
						f32(layout_config.padding.top) + f32(grid_row) * grid_step_y,
					}
				} else if wrap {
					if i == wrap_row.end {
						wrap_y +=
							i == 0 ? f32(layout_config.padding.top) : wrap_row.dimensions.height + gap
						wrap_row = array_get_value(&ctx.wrapped_rows, wrap_index)
						wrap_index += 1
						pad_x := f32(layout_config.padding.left) + f32(layout_config.padding.right)
						spare :=
							current_element.dimensions.width - pad_x - wrap_row.dimensions.width
						current_element_tree_node.next_child_offset.x =
							f32(layout_config.padding.left) +
							align_x_offset(layout_config.align.x, cmax(f32(0), spare))
						if scroll_container_data != nil {
							content := &scroll_container_data.content_size
							content.width = cmax(content.width, wrap_row.dimensions.width + pad_x)
							content.height =
								wrap_y +
								wrap_row.dimensions.height +
								f32(layout_config.padding.bottom)
						}
					}
					spare := wrap_row.dimensions.height - child_element.dimensions.height
					current_element_tree_node.next_child_offset.y =
						wrap_y + align_y_offset(layout_config.align.y, spare)
				} else if layout_config.direction == .Row {
					current_element_tree_node.next_child_offset.y = f32(
						current_element.config.padding.top,
					)
					white_space_around_child :=
						current_element.dimensions.height -
						f32(i32(layout_config.padding.top) + i32(layout_config.padding.bottom)) -
						child_element.dimensions.height
					current_element_tree_node.next_child_offset.y += align_y_offset(
						layout_config.align.y,
						white_space_around_child,
					)
				} else {
					current_element_tree_node.next_child_offset.x = f32(
						current_element.config.padding.left,
					)
					white_space_around_child :=
						current_element.dimensions.width -
						f32(i32(layout_config.padding.left) + i32(layout_config.padding.right)) -
						child_element.dimensions.width
					current_element_tree_node.next_child_offset.x += align_x_offset(
						layout_config.align.x,
						white_space_around_child,
					)
				}

				child_offset := current_element_tree_node.next_child_offset
				if wrap &&
				   !child_element.is_text_element &&
				   child_element.config.transition.exit.final != nil {
					if child_element.exiting {
						child_offset = child_element.wrap_exit_position
					} else {
						child_element.wrap_exit_position = child_offset
					}
				}
				child_position := Vector2 {
					current_element_bounding_box.x + child_offset.x + scroll_offset.x,
					current_element_bounding_box.y + child_offset.y + scroll_offset.y,
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
					if grid_columns > 0 {
						if scroll_container_data != nil && child_element.is_text_element {
							content := &scroll_container_data.content_size
							offset := current_element_tree_node.next_child_offset
							content.width = cmax(
								content.width,
								offset.x +
								child_element.dimensions.width +
								f32(layout_config.padding.right),
							)
							content.height = cmax(
								content.height,
								offset.y +
								child_element.dimensions.height +
								f32(layout_config.padding.bottom),
							)
						}
						grid_column += 1
						if grid_column == grid_columns {
							grid_column = 0
							grid_row += 1
						}
					} else if wrap || layout_config.direction == .Row {
						current_element_tree_node.next_child_offset.x +=
							child_element.dimensions.width + gap
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
