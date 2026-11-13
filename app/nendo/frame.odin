package nendo

// Per-frame public API: pointer and scroll input, begin/end with
// the transition state machine, element queries and limits.

// Byte comparison; equality of signed chars equals equality of their bytes.
@(private)
mem_cmp :: proc(s1, s2: [^]u8, length: i32) -> bool {
	for i: i32 = 0; i < length; i += 1 {
		if s1[i] != s2[i] {
			return false
		}
	}
	return true
}

@(private)
pointer_over_ids :: proc() -> Array(Id) {
	return active_context.pointer_over_ids
}

set_measure_text :: proc(fn: Measure_Text, user_data: rawptr = nil) {
	ctx := active_context
	measure_text = fn
	ctx.measure_text_user_data = user_data
}

set_dimensions :: proc(dimensions: Dimensions) {
	ctx := active_context
	ctx.root_resized_last_frame =
		!float_equal(ctx.layout_dimensions.width, dimensions.width) ||
		!float_equal(ctx.layout_dimensions.height, dimensions.height)
	ctx.layout_dimensions = dimensions
}

set_pointer :: proc(position: Vector2, button: Pointer_Button) {
	ctx := active_context
	if ctx.warnings.max_elements_exceeded {
		return
	}
	ctx.pointer_info.position = position
	ctx.pointer_over_ids.length = 0
	dfs_buffer := ctx.layout_element_children_buffer
	for root_index := ctx.layout_element_tree_roots.length - 1; root_index >= 0; root_index -= 1 {
		dfs_buffer.length = 0
		root := array_get(&ctx.layout_element_tree_roots, root_index)
		array_add(&dfs_buffer, i32(root.layout_element_index))
		ctx.tree_node_visited.items[0] = false
		found := false
		skip_tree := false
		for dfs_buffer.length > 0 {
			if ctx.tree_node_visited.items[dfs_buffer.length - 1] {
				dfs_buffer.length -= 1
				continue
			}
			ctx.tree_node_visited.items[dfs_buffer.length - 1] = true
			current_element := array_get(
				&ctx.layout_elements,
				array_get_value(&dfs_buffer, dfs_buffer.length - 1),
			)

			map_item := get_hash_map_item(current_element.id) // TODO think of a way around this, maybe the fact that it's essentially a binary tree limits the cost, but the worst case is not great
			clip_element_id := array_get_value(
				&ctx.layout_element_clip_element_ids,
				i32(
					(uintptr(current_element) - uintptr(ctx.layout_elements.items)) /
					size_of(Layout_Element),
				),
			)
			clip_item := get_hash_map_item(u32(clip_element_id))
			// This check skips mouse interactions for elements that are currently "exit transitioning"
			if map_item != nil && map_item.generation > ctx.generation {
				// Conditionally skip mouse interactions on non-exit transitions, based on user config
				if !current_element.is_text_element &&
				   current_element.config.transition.handler != nil {
					for t: i32 = 0; t < ctx.transition_datas.length; t += 1 {
						data := array_get(&ctx.transition_datas, t)
						if data.element_id == current_element.id {
							if current_element.config.transition.interaction ==
							   .Disable_While_Moving {
								if data.state == .Exiting ||
								   data.state == .Entering ||
								   ((data.active_properties & TRANSITION_POSITION != {}) &&
										   data.state == .Transitioning) {
									skip_tree = true
								}
							} else if current_element.config.transition.interaction ==
							   .Allow_While_Moving {
								if data.state == .Exiting {
									skip_tree = true
								}
							}
						}
					}
				}

				if skip_tree {
					dfs_buffer.length -= 1
					continue
				}

				element_box := map_item.bounding_box
				if (point_is_inside_rect(position, element_box)) &&
				   (clip_element_id == 0 ||
						   (point_is_inside_rect(position, clip_item.bounding_box))) {
					if !skip_tree {
						array_add(&ctx.pointer_over_ids, map_item.element_id)
					}
					found = true
				}

				// A clipping element hides its overflowing children, so a
				// point outside it can reach none of them, however deep.
				clips_children :=
					!current_element.is_text_element &&
					(current_element.config.clip.x || current_element.config.clip.y)
				if clips_children && !point_is_inside_rect(position, element_box) {
					continue
				}
				for i := i32(current_element.children.length) - 1; i >= 0; i -= 1 {
					array_add(&dfs_buffer, current_element.children.elements[i])
					ctx.tree_node_visited.items[dfs_buffer.length - 1] = false // TODO needs to be ranged checked
				}
			} else {
				dfs_buffer.length -= 1
			}
		}

		root_element := array_get(&ctx.layout_elements, root.layout_element_index)
		if found &&
		   root_element.config.floating.attach_to != .None &&
		   root_element.config.floating.pointer == .Capture {
			break
		}
	}

	if button == .Down {
		if ctx.pointer_info.state == .Pressed_This_Frame {
			ctx.pointer_info.state = .Pressed
		} else if ctx.pointer_info.state != .Pressed {
			ctx.pointer_info.state = .Pressed_This_Frame
		}
	} else {
		if ctx.pointer_info.state == .Released_This_Frame {
			ctx.pointer_info.state = .Released
		} else if ctx.pointer_info.state != .Released {
			ctx.pointer_info.state = .Released_This_Frame
		}
	}
}

pointer :: proc() -> Pointer {
	return active_context.pointer_info
}

@(private)
get_scroll_offset :: proc() -> Vector2 {
	ctx := active_context
	if ctx.warnings.max_elements_exceeded {
		return {}
	}
	open_layout_element := get_open_layout_element()
	for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
		mapping := array_get(&ctx.scroll_container_datas, i)
		if mapping.element_id == open_layout_element.id {
			return mapping.scroll_position
		}
	}
	return {}
}

update_scroll :: proc(drag: Drag_Scroll, scroll_delta: Vector2, delta_time: f32) {
	ctx := active_context
	is_pointer_active :=
		drag == .On &&
		(ctx.pointer_info.state == .Pressed || ctx.pointer_info.state == .Pressed_This_Frame)
	// Don't apply scroll events to ancestors of the inner element
	highest_priority_element_index: i32 = -1
	highest_priority_scroll_data: ^Scroll_Container_Data_Internal = nil
	for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
		scroll_data := array_get(&ctx.scroll_container_datas, i)
		if !scroll_data.open_this_frame {
			array_remove_swapback(&ctx.scroll_container_datas, i)
			continue
		}
		scroll_data.open_this_frame = false
		hash_map_item := get_hash_map_item(scroll_data.element_id)
		// Element isn't rendered this frame but scroll offset has been retained
		if hash_map_item == nil {
			array_remove_swapback(&ctx.scroll_container_datas, i)
			continue
		}

		// Touch / click is released
		if !is_pointer_active && scroll_data.pointer_scroll_active {
			x_diff := scroll_data.scroll_position.x - scroll_data.scroll_origin.x
			if x_diff < -10 || x_diff > 10 {
				scroll_data.scroll_momentum.x =
					(scroll_data.scroll_position.x - scroll_data.scroll_origin.x) /
					(scroll_data.momentum_time * 25)
			}
			y_diff := scroll_data.scroll_position.y - scroll_data.scroll_origin.y
			if y_diff < -10 || y_diff > 10 {
				scroll_data.scroll_momentum.y =
					(scroll_data.scroll_position.y - scroll_data.scroll_origin.y) /
					(scroll_data.momentum_time * 25)
			}
			scroll_data.pointer_scroll_active = false

			scroll_data.pointer_origin = Vector2{0, 0}
			scroll_data.scroll_origin = Vector2{0, 0}
			scroll_data.momentum_time = 0
		}

		// Apply existing momentum
		scroll_data.scroll_position.x += scroll_data.scroll_momentum.x
		scroll_data.scroll_momentum.x *= 0.95
		scroll_occurred := scroll_delta.x != 0 || scroll_delta.y != 0
		if (scroll_data.scroll_momentum.x > -0.1 && scroll_data.scroll_momentum.x < 0.1) ||
		   scroll_occurred {
			scroll_data.scroll_momentum.x = 0
		}
		scroll_data.scroll_position.x = cmin(
			cmax(
				scroll_data.scroll_position.x,
				-(cmax(
						scroll_data.content_size.width -
						scroll_data.layout_element.dimensions.width,
						0,
					)),
			),
			0,
		)

		scroll_data.scroll_position.y += scroll_data.scroll_momentum.y
		scroll_data.scroll_momentum.y *= 0.95
		if (scroll_data.scroll_momentum.y > -0.1 && scroll_data.scroll_momentum.y < 0.1) ||
		   scroll_occurred {
			scroll_data.scroll_momentum.y = 0
		}
		scroll_data.scroll_position.y = cmin(
			cmax(
				scroll_data.scroll_position.y,
				-(cmax(
						scroll_data.content_size.height -
						scroll_data.layout_element.dimensions.height,
						0,
					)),
			),
			0,
		)

		// Input goes to the innermost container under the pointer that can move
		// along it. One that can't (a clipped one-line label under a vertical
		// wheel) passes the input to its ancestors instead of swallowing it.
		clip := &scroll_data.layout_element.config.clip
		moves_x :=
			clip.x && scroll_data.content_size.width > scroll_data.layout_element.dimensions.width
		moves_y :=
			clip.y &&
			scroll_data.content_size.height > scroll_data.layout_element.dimensions.height
		takes_input :=
			is_pointer_active ? moves_x || moves_y : (scroll_delta.x != 0 && moves_x) || (scroll_delta.y != 0 && moves_y)
		if !takes_input {
			continue
		}
		for j: i32 = 0; j < ctx.pointer_over_ids.length; j += 1 { 	// TODO n & m are small here but this being n*m gives me the creeps
			// pointer_over_ids runs parent before child: a higher index is deeper.
			if j > highest_priority_element_index &&
			   scroll_data.layout_element.id == array_get(&ctx.pointer_over_ids, j).id {
				highest_priority_element_index = j
				highest_priority_scroll_data = scroll_data
			}
		}
	}

	if highest_priority_element_index > -1 && highest_priority_scroll_data != nil {
		scroll_element := highest_priority_scroll_data.layout_element
		clip_config := &scroll_element.config.clip
		can_scroll_vertically :=
			clip_config.y &&
			highest_priority_scroll_data.content_size.height > scroll_element.dimensions.height
		can_scroll_horizontally :=
			clip_config.x &&
			highest_priority_scroll_data.content_size.width > scroll_element.dimensions.width
		// Handle wheel scroll
		if can_scroll_vertically {
			highest_priority_scroll_data.scroll_position.y =
				highest_priority_scroll_data.scroll_position.y + scroll_delta.y * 10
		}
		if can_scroll_horizontally {
			highest_priority_scroll_data.scroll_position.x =
				highest_priority_scroll_data.scroll_position.x + scroll_delta.x * 10
		}
		// Handle click / touch scroll
		if is_pointer_active {
			highest_priority_scroll_data.scroll_momentum = {}
			if !highest_priority_scroll_data.pointer_scroll_active {
				highest_priority_scroll_data.pointer_origin = ctx.pointer_info.position
				highest_priority_scroll_data.scroll_origin =
					highest_priority_scroll_data.scroll_position
				highest_priority_scroll_data.pointer_scroll_active = true
			} else {
				scroll_delta_x, scroll_delta_y: f32 = 0, 0
				if can_scroll_horizontally {
					old_xScroll_position := highest_priority_scroll_data.scroll_position.x
					highest_priority_scroll_data.scroll_position.x =
						highest_priority_scroll_data.scroll_origin.x +
						(ctx.pointer_info.position.x -
								highest_priority_scroll_data.pointer_origin.x)
					highest_priority_scroll_data.scroll_position.x = cmax(
						cmin(highest_priority_scroll_data.scroll_position.x, 0),
						-(highest_priority_scroll_data.content_size.width -
							highest_priority_scroll_data.bounding_box.width),
					)
					scroll_delta_x =
						highest_priority_scroll_data.scroll_position.x - old_xScroll_position
				}
				if can_scroll_vertically {
					old_yScroll_position := highest_priority_scroll_data.scroll_position.y
					highest_priority_scroll_data.scroll_position.y =
						highest_priority_scroll_data.scroll_origin.y +
						(ctx.pointer_info.position.y -
								highest_priority_scroll_data.pointer_origin.y)
					highest_priority_scroll_data.scroll_position.y = cmax(
						cmin(highest_priority_scroll_data.scroll_position.y, 0),
						-(highest_priority_scroll_data.content_size.height -
							highest_priority_scroll_data.bounding_box.height),
					)
					scroll_delta_y =
						highest_priority_scroll_data.scroll_position.y - old_yScroll_position
				}
				if scroll_delta_x > -0.1 &&
				   scroll_delta_x < 0.1 &&
				   scroll_delta_y > -0.1 &&
				   scroll_delta_y < 0.1 &&
				   highest_priority_scroll_data.momentum_time > 0.15 {
					highest_priority_scroll_data.momentum_time = 0
					highest_priority_scroll_data.pointer_origin = ctx.pointer_info.position
					highest_priority_scroll_data.scroll_origin =
						highest_priority_scroll_data.scroll_position
				} else {
					highest_priority_scroll_data.momentum_time += delta_time
				}
			}
		}
		// Clamp any changes to scroll position to the maximum size of the contents
		if can_scroll_vertically {
			highest_priority_scroll_data.scroll_position.y = cmax(
				cmin(highest_priority_scroll_data.scroll_position.y, 0),
				-(highest_priority_scroll_data.content_size.height -
					scroll_element.dimensions.height),
			)
		}
		if can_scroll_horizontally {
			highest_priority_scroll_data.scroll_position.x = cmax(
				cmin(highest_priority_scroll_data.scroll_position.x, 0),
				-(highest_priority_scroll_data.content_size.width -
					scroll_element.dimensions.width),
			)
		}
	}
}

begin :: proc() {
	ctx := active_context
	initialize_ephemeral_memory(ctx)
	ctx.generation += 1
	// Set up the root container that covers the entire window
	root_dimensions := Dimensions{ctx.layout_dimensions.width, ctx.layout_dimensions.height}
	ctx.warnings = {}
	open_element_with_id(hash_string(static_string(ROOT_CONTAINER), 0))
	declaration := Box {
		width  = fixed(root_dimensions.width),
		height = fixed(root_dimensions.height),
	}
	configure_open_element_ptr(&declaration)
	array_add(&ctx.open_layout_element_stack, 0)
	array_add(&ctx.layout_element_tree_roots, Layout_Element_Tree_Root{layout_element_index = 0})
}

@(private)
clone_elements_with_exit_transition :: proc() {
	ctx := active_context
	next_index := ctx.layout_elements.capacity - 1
	next_child_index := ctx.layout_element_children.capacity - 1

	for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
		data := array_get(&ctx.transition_datas, i)
		if data.transition_out {
			bfs_buffer := ctx.open_layout_element_stack
			bfs_buffer.length = 0
			new_element := array_set_keep_length(
				&ctx.layout_elements,
				next_index,
				data.element_this_frame^,
			)
			array_add(&bfs_buffer, next_index)
			data.element_this_frame = new_element
			next_index -= 1

			buffer_index: i32 = 0
			for buffer_index < bfs_buffer.length {
				layout_element := array_get_check_capacity(
					&ctx.layout_elements,
					array_get_value(&bfs_buffer, buffer_index),
				)
				buffer_index += 1
				for j := i32(layout_element.children.length) - 1; j >= 0; j -= 1 {
					child_element := array_get_check_capacity(
						&ctx.layout_elements,
						layout_element.children.elements[j],
					)
					array_add(&bfs_buffer, next_index)
					array_set_keep_length(&ctx.layout_elements, next_index, child_element^)
					array_set_keep_length(
						&ctx.layout_element_children,
						next_child_index,
						next_index,
					)
					next_index -= 1
					next_child_index -= 1
				}
				layout_element.children.elements = &ctx.layout_element_children.items[next_child_index + 1]
			}
		}
	}
}

@(private)
apply_transitioned_properties_to_element :: proc(
	current_element: ^Layout_Element,
	properties: Transition_Properties,
	current_transition_data: Transition_Data,
	bounding_box: ^Rect,
	reparented: bool,
) {
	if .Width in properties {
		if !reparented {
			current_element.dimensions.width = current_transition_data.rect.width
			current_element.config.width = fixed(current_transition_data.rect.width)
		} else {
			bounding_box.width = current_transition_data.rect.width
		}
	}
	if .Height in properties {
		if !reparented {
			current_element.dimensions.height = current_transition_data.rect.height
			current_element.config.height = fixed(current_transition_data.rect.height)
		} else {
			bounding_box.height = current_transition_data.rect.height
		}
	}
	if .X in properties {
		bounding_box.x = current_transition_data.rect.x
	}
	if .Y in properties {
		bounding_box.y = current_transition_data.rect.y
	}
	if .Overlay in properties {
		current_element.config.overlay = current_transition_data.overlay
	}
	if .Color in properties {
		current_element.config.color = current_transition_data.color
	}
	if .Border_Color in properties {
		current_element.config.border.color = current_transition_data.border_color
	}
	if .Border_Width in properties {
		current_element.config.border.width = current_transition_data.border_width
	}
}

end :: proc(delta_time: f32) -> []Render_Command {
	ctx := active_context
	close_element()

	if ctx.open_layout_element_stack.length > 1 {
		report_error(
			.Unbalanced_Open_Close,
			"There were still open layout elements when nendo.end was called: an element was opened without being closed.",
		)
	}

	// Prune non exiting transitions
	for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
		data := array_get(&ctx.transition_datas, i)
		hash_map_item := get_hash_map_item(data.element_id)
		// Transition element exited and doesn't have an exit handler defined
		// Or, the user deleted the transition handler from one frame to the next
		if !data.transition_out &&
		   (hash_map_item.generation <= ctx.generation ||
				   hash_map_item.layout_element.config.transition.handler == nil) {
			array_remove_swapback(&ctx.transition_datas, i)
			i -= 1
			continue
		}
	}

	element_ids_to_remove_transitions := ctx.reusable_element_index_buffer
	element_ids_to_remove_transitions.length = 0

	for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
		data := array_get(&ctx.transition_datas, i)
		hash_map_item := get_hash_map_item(data.element_id)
		// If the element had no exit transition it has vanished entirely by now,
		// so only the stored transition_out flag can say whether to transition out.
		if data.transition_out {
			config := &data.element_this_frame.config.transition
			// Element wasn't found this frame - either delete transition data or transition out
			if hash_map_item.generation <= ctx.generation {
				parent_hash_map_item := get_hash_map_item(data.parent_id)
				// Don't exit transition if the parent has also exited and SKIP_WHEN_PARENT_EXITS is used
				if config.exit.trigger == .Trigger_When_Parent_Exits ||
				   parent_hash_map_item == nil ||
				   parent_hash_map_item.generation > ctx.generation {
					// This if only runs one single time when the element first starts exiting
					if data.state != .Exiting {
						if parent_hash_map_item.generation <= ctx.generation {
							data.element_this_frame.config.floating.attach_to = .Root
							data.element_this_frame.config.floating.offset = Vector2 {
								hash_map_item.bounding_box.x,
								hash_map_item.bounding_box.y,
							}
							data.element_this_frame.config.floating.parent =
								hash_string(static_string(ROOT_CONTAINER), 0).id
						}
						hash_map_item.appeared_this_frame = false
						data.element_this_frame.exiting = true
						data.element_this_frame.config.width = fixed(
							data.element_this_frame.dimensions.width,
						)
						data.element_this_frame.config.height = fixed(
							data.element_this_frame.dimensions.height,
						)
						data.state = .Exiting
						data.active_properties = config.properties
						data.elapsed_time = 0
						data.target_state = config.exit.final(data.target_state, config.properties)
					}

					// Below this line runs every frame while element is exiting -----------

					// Clone the entire subtree back into the main UI layout tree
					bfs_buffer := ctx.open_layout_element_stack
					bfs_buffer.length = 0
					data.element_this_frame = array_add(
						&ctx.layout_elements,
						data.element_this_frame^,
					)
					exiting_element_index := i32(
						(uintptr(data.element_this_frame) - uintptr(ctx.layout_elements.items)) /
						size_of(Layout_Element),
					)
					array_add(
						&ctx.layout_element_clip_element_ids,
						array_get_check_capacity(
							&ctx.layout_element_clip_element_ids,
							exiting_element_index,
						)^,
					)
					array_add(&bfs_buffer, exiting_element_index)
					buffer_index: i32 = 0
					for buffer_index < bfs_buffer.length {
						layout_element := array_get_check_capacity(
							&ctx.layout_elements,
							array_get_value(&bfs_buffer, buffer_index),
						)
						bfs_map_item := get_hash_map_item(layout_element.id)
						// Children of exiting elements may have been moved elsewhere in the layout, this prevents a duplicate ID error if they still exist.
						if bfs_map_item.generation <= ctx.generation {
							add_hash_map_item(Id{id = layout_element.id}, layout_element)
							first_child_slot := ctx.layout_element_children.length
							new_children_length := layout_element.children.length
							for j: i32 = 0; j < i32(layout_element.children.length); j += 1 {
								child_element := array_get_check_capacity(
									&ctx.layout_elements,
									layout_element.children.elements[j],
								)
								child_map_item := get_hash_map_item(child_element.id)
								if child_map_item.generation <= ctx.generation {
									// Remove any nested transitions inside exiting trees
									if !child_element.is_text_element &&
									   child_element.config.transition.handler != nil {
										array_add(
											&element_ids_to_remove_transitions,
											i32(child_element.id),
										)
									}
									child_element_index := i32(
										(uintptr(child_element) -
											uintptr(ctx.layout_elements.items)) /
										size_of(Layout_Element),
									)
									new_child_element := array_add(
										&ctx.layout_elements,
										child_element^,
									)
									array_add(
										&ctx.layout_element_clip_element_ids,
										array_get_check_capacity(
											&ctx.layout_element_clip_element_ids,
											child_element_index,
										)^,
									)
									array_add(&bfs_buffer, ctx.layout_elements.length - 1)
									if new_child_element.is_text_element {
										new_child_element.text_element_data.wrapped_lines.length = 0
									}
									array_add(
										&ctx.layout_element_children,
										ctx.layout_elements.length - 1,
									)
								} else {
									new_children_length -= 1
								}
							}
							layout_element.children = Layout_Element_Children {
								elements = &ctx.layout_element_children.items[first_child_slot],
								length   = new_children_length,
							}
						}
						buffer_index += 1
					}
					hash_map_item.layout_element = data.element_this_frame

					// Reattach the inserted subtree to its previous parent if it still exists
					// and the exiting element is not floating
					floating_config := &hash_map_item.layout_element.config.floating
					if parent_hash_map_item.generation > ctx.generation &&
					   floating_config.attach_to == .None {
						parent_element := parent_hash_map_item.layout_element
						new_children_start_index := ctx.layout_element_children.length
						found := false
						if config.exit.order == .Underneath_Siblings {
							array_add(&ctx.layout_element_children, exiting_element_index)
							found = true
						}
						for j: i32 = 0; j < i32(parent_element.children.length); j += 1 {
							if config.exit.order == .Natural_Order &&
							   u32(j) == data.sibling_index {
								array_add(&ctx.layout_element_children, exiting_element_index)
								found = true
							}
							array_add(
								&ctx.layout_element_children,
								parent_element.children.elements[j],
							)
						}
						if !found {
							array_add(&ctx.layout_element_children, exiting_element_index)
						}
						parent_element.children.length += 1
						parent_element.children.elements = &ctx.layout_element_children.items[new_children_start_index]
						// Otherwise, create the tree root for the floating element (needs to be created every frame)
					} else {
						array_add(
							&ctx.layout_element_tree_roots,
							Layout_Element_Tree_Root {
								layout_element_index = i32(
									(uintptr(data.element_this_frame) -
										uintptr(ctx.layout_elements.items)) /
									size_of(Layout_Element),
								),
								parent_id = floating_config.parent,
								z = floating_config.z,
							},
						)
					}
					// Parent exited, just delete child without exit transition
				} else {
					array_remove_swapback(&ctx.transition_datas, i)
					i -= 1
					continue
				}
			}
		}
	}

	for i: i32 = 0; i < element_ids_to_remove_transitions.length; i += 1 {
		for j: i32 = 0; j < ctx.transition_datas.length; j += 1 {
			if array_get(&ctx.transition_datas, j).element_id ==
			   u32(array_get_value(&element_ids_to_remove_transitions, i)) {
				array_remove_swapback(&ctx.transition_datas, j)
				break
			}
		}
	}

	// A resized window or a settle request (a zoom or font change) moves
	// everything at once. That geometry lands where it is laid out; it
	// does not glide there.
	jumped := ctx.root_resized_last_frame || ctx.settle_requested
	ctx.settle_requested = false

	if ctx.warnings.max_elements_exceeded {
		message :: "nendo error: layout elements exceeded the element limit"
		report_error(.Elements_Capacity_Exceeded, message)
		command := Render_Command {
			rect = {
				ctx.layout_dimensions.width / 2 - 59 * 4,
				ctx.layout_dimensions.height / 2,
				0,
				0,
			},
			kind = .Text,
		}
		command.text = {
			text  = message,
			color = {255, 0, 0, 255},
			size  = 16,
		}
		add_render_command(command)
	} else {
		if ctx.transition_datas.length > 0 {
			calculate_final_layout(delta_time, false, false)

			for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
				transition_data := array_get(&ctx.transition_datas, i)
				current_element := transition_data.element_this_frame
				map_item := get_hash_map_item(transition_data.element_id)
				parent_map_item := get_hash_map_item(transition_data.parent_id)
				target_state := transition_data.target_state
				if transition_data.state != .Exiting {
					target_state = Transition_Data {
						map_item.bounding_box,
						current_element.config.color,
						current_element.config.overlay,
						current_element.config.border.color,
						current_element.config.border.width,
					}
				}
				old_target_state := transition_data.target_state
				transition_data.target_state = target_state
				if map_item.appeared_this_frame {
					if current_element.config.transition.enter.initial != nil &&
					   !(parent_map_item.appeared_this_frame &&
							   current_element.config.transition.enter.trigger ==
								   .Skip_On_First_Parent_Frame) {
						transition_data.state = .Entering
						transition_data.initial_state =
							current_element.config.transition.enter.initial(
								transition_data.target_state,
								current_element.config.transition.properties,
							)
						transition_data.current_state = transition_data.initial_state
						transition_data.active_properties =
							current_element.config.transition.properties
						apply_transitioned_properties_to_element(
							current_element,
							current_element.config.transition.properties,
							transition_data.initial_state,
							&map_item.bounding_box,
							transition_data.reparented,
						)
					} else {
						transition_data.initial_state = target_state
						transition_data.current_state = target_state
						transition_data.active_properties = {}
					}
				} else {
					if transition_data.state != .Exiting {
						parent_scroll_offset := parent_map_item.layout_element.config.clip.offset
						new_relative_position := Vector2 {
							map_item.bounding_box.x -
							parent_map_item.bounding_box.x -
							parent_scroll_offset.x,
							map_item.bounding_box.y -
							parent_map_item.bounding_box.y -
							parent_scroll_offset.y,
						}
						old_relative_position := transition_data.old_parent_relative_position
						transition_data.old_parent_relative_position = new_relative_position
						properties := current_element.config.transition.properties
						new_active_properties: Transition_Properties
						if .X in properties {
							// Don't trigger a transition if...
							if (!float_equal(
									   old_target_state.rect.x, // The element's absolute position didn't change
									   target_state.rect.x,
								   ) && (!(float_equal(old_relative_position.x, new_relative_position.x)) || transition_data.reparented) && !jumped) { 	// The element is still in the same parent container, and it's parent-relative position didn't change (parent moved) // The position changed was triggered by the outer window resizing
								new_active_properties += {.X}
							}
						}
						if .Y in properties {
							// See extended comments above in PROPERTY_X for explanation
							if !float_equal(old_target_state.rect.y, target_state.rect.y) &&
							   (!(float_equal(old_relative_position.y, new_relative_position.y)) ||
									   transition_data.reparented) &&
							   !jumped {
								new_active_properties += {.Y}
							}
						}
						if .Width in properties {
							if !float_equal(
								   old_target_state.rect.width,
								   target_state.rect.width,
							   ) &&
							   !jumped {
								new_active_properties += {.Width}
							}
						}
						if .Height in properties {
							if !float_equal(
								   old_target_state.rect.height,
								   target_state.rect.height,
							   ) &&
							   !jumped {
								new_active_properties += {.Height}
							}
						}
						if .Color in properties {
							if !mem_cmp(
								([^]u8)(&old_target_state.color),
								([^]u8)(&target_state.color),
								size_of(Color),
							) {
								new_active_properties += {.Color}
							}
						}
						if .Overlay in properties {
							if !mem_cmp(
								([^]u8)(&old_target_state.overlay),
								([^]u8)(&target_state.overlay),
								size_of(Color),
							) {
								new_active_properties += {.Overlay}
							}
						}
						if .Border_Color in properties {
							if !mem_cmp(
								([^]u8)(&old_target_state.border_color),
								([^]u8)(&target_state.border_color),
								size_of(Color),
							) {
								new_active_properties += {.Border_Color}
							}
						}
						if .Border_Width in properties {
							if !mem_cmp(
								([^]u8)(&old_target_state.border_width),
								([^]u8)(&target_state.border_width),
								size_of(Border_Width),
							) {
								new_active_properties += {.Border_Width}
							}
						}

						if new_active_properties != {} {
							transition_data.elapsed_time = 0
							transition_data.initial_state = transition_data.current_state
							transition_data.state = .Transitioning
							transition_data.active_properties =
								transition_data.active_properties + new_active_properties
						}
					}

					if transition_data.state == .Idle {
						transition_data.initial_state = target_state
						transition_data.current_state = target_state
						transition_data.target_state = target_state
						transition_data.active_properties = {}
					} else {
						transition_complete := true
						transition_complete = current_element.config.transition.handler(
							Transition_Args {
								transition_data.state,
								transition_data.initial_state,
								&transition_data.current_state,
								target_state,
								transition_data.elapsed_time,
								current_element.config.transition.duration,
								transition_data.active_properties,
							},
						)

						apply_transitioned_properties_to_element(
							current_element,
							transition_data.active_properties,
							transition_data.current_state,
							&map_item.bounding_box,
							transition_data.reparented,
						)
						transition_data.elapsed_time += delta_time

						if transition_complete {
							if transition_data.state == .Entering ||
							   transition_data.state == .Transitioning {
								transition_data.state = .Idle
								transition_data.elapsed_time = 0
								transition_data.reparented = false
								transition_data.active_properties = {}
							} else if transition_data.state == .Exiting {
								array_remove_swapback(&ctx.transition_datas, i)
							}
						}
					}
				}
			}

			calculate_final_layout(delta_time, true, true)
			clone_elements_with_exit_transition()
		} else {
			calculate_final_layout(delta_time, false, true)
		}
	}

	for i: i32 = 0; i < ctx.layout_elements_hash_map.capacity; i += 1 {
		current_element_index := ctx.layout_elements_hash_map.items[i]
		previous_element_index: i32 = -1
		for current_element_index != -1 {
			current_item := array_get(
				&ctx.layout_elements_hash_map_internal,
				current_element_index,
			)
			next_index := current_item.next_index
			// Needs to be pruned
			if current_item.generation <= ctx.generation {
				// Delete the underlying item and add it to the freelist
				array_set(
					&ctx.layout_elements_hash_map_internal,
					current_element_index,
					Layout_Element_Hash_Map_Item{next_index = -1},
				)
				array_add(&ctx.layout_elements_hash_map_free_list, current_element_index)
				// If it's the very top of the bucket, rewrite the first bucket pointer
				if previous_element_index == -1 {
					array_set(&ctx.layout_elements_hash_map, i, next_index)
					current_element_index = next_index
					previous_element_index = -1
				} else {
					// Rewrite previous pointer
					previous_item := array_get(
						&ctx.layout_elements_hash_map_internal,
						previous_element_index,
					)
					previous_item.next_index = next_index
					current_element_index = next_index
				}
			} else {
				previous_element_index = current_element_index
				current_element_index = next_index
			}
		}
	}

	return ctx.render_commands.items[:ctx.render_commands.length]
}

open_id :: proc() -> u32 {
	return get_open_layout_element().id
}

// Whether any element is still moving toward its layout. The app keeps
// drawing frames instead of idling until this is false.
transitioning :: proc() -> bool {
	ctx := active_context
	for i: i32 = 0; i < ctx.transition_datas.length; i += 1 {
		if array_get(&ctx.transition_datas, i).state != .Idle {
			return true
		}
	}
	return false
}

// Treat the next end() as a window resize: elements land where they are
// laid out instead of gliding from coordinates that no longer exist.
settle_transitions :: proc() {
	active_context.settle_requested = true
}

hovered :: proc() -> bool {
	ctx := active_context
	if ctx.warnings.max_elements_exceeded {
		return false
	}
	open_layout_element := get_open_layout_element()
	for i: i32 = 0; i < ctx.pointer_over_ids.length; i += 1 {
		if array_get(&ctx.pointer_over_ids, i).id == open_layout_element.id {
			return true
		}
	}
	return false
}

pointer_over :: proc(id: Id) -> bool { 	// TODO return priority for separating multiple results
	ctx := active_context
	for i: i32 = 0; i < ctx.pointer_over_ids.length; i += 1 {
		if array_get(&ctx.pointer_over_ids, i).id == id.id {
			return true
		}
	}
	return false
}

scroll :: proc(id: Id) -> Scroll_Data {
	ctx := active_context
	for i: i32 = 0; i < ctx.scroll_container_datas.length; i += 1 {
		scroll_container_data := array_get(&ctx.scroll_container_datas, i)
		if scroll_container_data.element_id == id.id {
			if scroll_container_data.layout_element == nil { 	// This can happen on the first frame before a scroll container is declared
				return {}
			}
			return Scroll_Data {
				position = &scroll_container_data.scroll_position,
				viewport = {
					scroll_container_data.bounding_box.width,
					scroll_container_data.bounding_box.height,
				},
				content = scroll_container_data.content_size,
				clip = scroll_container_data.layout_element.config.clip,
				found = true,
			}
		}
	}
	return {}
}

element :: proc(id: Id) -> Element_Data {
	item := get_hash_map_item(id.id)
	if item == default_of(Layout_Element_Hash_Map_Item) {
		return {}
	}

	return Element_Data{rect = item.bounding_box, found = true}
}

max_element_count :: proc() -> i32 {
	ctx := active_context
	return ctx.max_element_count
}

set_max_element_count :: proc(n: i32) {
	ctx := active_context
	if ctx != nil {
		ctx.max_element_count = n
	} else {
		default_max_element_count = n // TODO: Fix this
		default_max_measure_text_word_cache_count = n * 2
	}
}

reset_measure_cache :: proc() {
	ctx := active_context
	ctx.measure_text_hash_map_internal.length = 0
	ctx.measure_text_hash_map_internal_free_list.length = 0
	ctx.measure_text_hash_map.length = 0
	ctx.measured_words.length = 0
	ctx.measured_words_free_list.length = 0

	for i: i32 = 0; i < ctx.measure_text_hash_map.capacity; i += 1 {
		ctx.measure_text_hash_map.items[i] = 0
	}
	ctx.measure_text_hash_map_internal.length = 1 // Reserve the 0 value to mean "no next element"
}

ease_out :: proc(arguments: Transition_Args) -> bool {
	ratio: f32 = 1
	if arguments.duration > 0 {
		ratio = cmin(arguments.elapsed / arguments.duration, 1)
	}
	inverse := 1.0 - ratio
	lerp_amount := 1.0 - (inverse * inverse * inverse)
	initial := arguments.initial
	target := arguments.target
	if .X in arguments.properties {
		arguments.current.rect.x = initial.rect.x + (target.rect.x - initial.rect.x) * lerp_amount
	}
	if .Y in arguments.properties {
		arguments.current.rect.y = initial.rect.y + (target.rect.y - initial.rect.y) * lerp_amount
	}
	if .Width in arguments.properties {
		arguments.current.rect.width =
			initial.rect.width + (target.rect.width - initial.rect.width) * lerp_amount
	}
	if .Height in arguments.properties {
		arguments.current.rect.height =
			initial.rect.height + (target.rect.height - initial.rect.height) * lerp_amount
	}
	if .Color in arguments.properties {
		arguments.current.color = Color {
			initial.color.r + (target.color.r - initial.color.r) * lerp_amount,
			initial.color.g + (target.color.g - initial.color.g) * lerp_amount,
			initial.color.b + (target.color.b - initial.color.b) * lerp_amount,
			initial.color.a + (target.color.a - initial.color.a) * lerp_amount,
		}
	}
	if .Overlay in arguments.properties {
		arguments.current.overlay = Color {
			initial.overlay.r + (target.overlay.r - initial.overlay.r) * lerp_amount,
			initial.overlay.g + (target.overlay.g - initial.overlay.g) * lerp_amount,
			initial.overlay.b + (target.overlay.b - initial.overlay.b) * lerp_amount,
			initial.overlay.a + (target.overlay.a - initial.overlay.a) * lerp_amount,
		}
	}
	if .Border_Color in arguments.properties {
		arguments.current.border_color = Color {
			initial.border_color.r +
			(target.border_color.r - initial.border_color.r) * lerp_amount,
			initial.border_color.g +
			(target.border_color.g - initial.border_color.g) * lerp_amount,
			initial.border_color.b +
			(target.border_color.b - initial.border_color.b) * lerp_amount,
			initial.border_color.a +
			(target.border_color.a - initial.border_color.a) * lerp_amount,
		}
	}
	if .Border_Width in arguments.properties {
		// Lerp on u16: operands widen to int, then int * float.
		from := initial.border_width
		to := target.border_width
		arguments.current.border_width = Border_Width {
			left    = u16(f32(i32(from.left)) + f32(i32(to.left) - i32(from.left)) * lerp_amount),
			right   = u16(
				f32(i32(from.right)) + f32(i32(to.right) - i32(from.right)) * lerp_amount,
			),
			top     = u16(f32(i32(from.top)) + f32(i32(to.top) - i32(from.top)) * lerp_amount),
			bottom  = u16(
				f32(i32(from.bottom)) + f32(i32(to.bottom) - i32(from.bottom)) * lerp_amount,
			),
			between = u16(
				f32(i32(from.between)) + f32(i32(to.between) - i32(from.between)) * lerp_amount,
			),
		}
	}
	return ratio >= 1
}
