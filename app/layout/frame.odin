package clay

// Per-frame public API: pointer and scroll input, BeginLayout/EndLayout with
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

GetPointerOverIds :: proc() -> ElementIdArray {
	return current_context.pointerOverIds
}

SetMeasureTextFunction :: proc(fn: MeasureTextFunction, userData: rawptr) {
	ctx := current_context
	measure_text = fn
	ctx.measureTextUserData = userData
}

SetLayoutDimensions :: proc(dimensions: Dimensions) {
	ctx := current_context
	ctx.rootResizedLastFrame =
		!float_equal(ctx.layoutDimensions.width, dimensions.width) ||
		!float_equal(ctx.layoutDimensions.height, dimensions.height)
	ctx.layoutDimensions = dimensions
}

GetLayoutDimensions :: proc() -> Dimensions {
	ctx := current_context
	return ctx.layoutDimensions
}

SetPointerState :: proc(position: Vector2, isPointerDown: bool) {
	ctx := current_context
	if ctx.booleanWarnings.maxElementsExceeded {
		return
	}
	ctx.pointerInfo.position = position
	ctx.pointerOverIds.length = 0
	dfsBuffer := ctx.layoutElementChildrenBuffer
	for rootIndex := ctx.layoutElementTreeRoots.length - 1; rootIndex >= 0; rootIndex -= 1 {
		dfsBuffer.length = 0
		root := array_get(&ctx.layoutElementTreeRoots, rootIndex)
		array_add(&dfsBuffer, i32(root.layoutElementIndex))
		ctx.treeNodeVisited.internalArray[0] = false
		found := false
		skipTree := false
		for dfsBuffer.length > 0 {
			if ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
				dfsBuffer.length -= 1
				continue
			}
			ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true
			currentElement := array_get(
				&ctx.layoutElements,
				array_get_value(&dfsBuffer, dfsBuffer.length - 1),
			)

			mapItem := get_hash_map_item(currentElement.id) // TODO think of a way around this, maybe the fact that it's essentially a binary tree limits the cost, but the worst case is not great
			clipElementId := array_get_value(
				&ctx.layoutElementClipElementIds,
				i32(
					(uintptr(currentElement) - uintptr(ctx.layoutElements.internalArray)) /
					size_of(Layout_Element),
				),
			)
			clipItem := get_hash_map_item(u32(clipElementId))
			// This check skips mouse interactions for elements that are currently "exit transitioning"
			if mapItem != nil && mapItem.generation > ctx.generation {
				// Conditionally skip mouse interactions on non-exit transitions, based on user config
				if !currentElement.isTextElement &&
				   currentElement.config.transition.handler != nil {
					for I: i32 = 0; I < ctx.transitionDatas.length; I += 1 {
						data := array_get(&ctx.transitionDatas, I)
						if data.elementId == currentElement.id {
							if currentElement.config.transition.interactionHandling ==
							   .DisableInteractionsWhileTransitioningPosition {
								if data.state == .Exiting ||
								   data.state == .Entering ||
								   ((data.activeProperties & TransitionPropertyPosition != {}) &&
										   data.state == .Transitioning) {
									skipTree = true
								}
							} else if currentElement.config.transition.interactionHandling ==
							   .AllowInteractionsWhileTransitioningPosition {
								if data.state == .Exiting {
									skipTree = true
								}
							}
						}
					}
				}

				if skipTree {
					dfsBuffer.length -= 1
					continue
				}

				elementBox := mapItem.boundingBox
				if (point_is_inside_rect(position, elementBox)) &&
				   (clipElementId == 0 || (point_is_inside_rect(position, clipItem.boundingBox))) {
					if !skipTree {
						if mapItem.onHoverFunction != nil {
							mapItem.onHoverFunction(
								mapItem.elementId,
								ctx.pointerInfo,
								mapItem.hoverFunctionUserData,
							)
						}
						array_add(&ctx.pointerOverIds, mapItem.elementId)
					}
					found = true
				}

				// A clipping element hides its overflowing children, so a
				// point outside it can reach none of them, however deep.
				clipsChildren :=
					!currentElement.isTextElement &&
					(currentElement.config.clip.horizontal || currentElement.config.clip.vertical)
				if clipsChildren && !point_is_inside_rect(position, elementBox) {
					continue
				}
				for i := i32(currentElement.children.length) - 1; i >= 0; i -= 1 {
					array_add(&dfsBuffer, currentElement.children.elements[i])
					ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = false // TODO needs to be ranged checked
				}
			} else {
				dfsBuffer.length -= 1
			}
		}

		rootElement := array_get(&ctx.layoutElements, root.layoutElementIndex)
		if found &&
		   rootElement.config.floating.attachTo != .None &&
		   rootElement.config.floating.pointerCaptureMode == .Capture {
			break
		}
	}

	if isPointerDown {
		if ctx.pointerInfo.state == .PressedThisFrame {
			ctx.pointerInfo.state = .Pressed
		} else if ctx.pointerInfo.state != .Pressed {
			ctx.pointerInfo.state = .PressedThisFrame
		}
	} else {
		if ctx.pointerInfo.state == .ReleasedThisFrame {
			ctx.pointerInfo.state = .Released
		} else if ctx.pointerInfo.state != .Released {
			ctx.pointerInfo.state = .ReleasedThisFrame
		}
	}
}

GetPointerState :: proc() -> PointerData {
	return current_context.pointerInfo
}

GetScrollOffset :: proc() -> Vector2 {
	ctx := current_context
	if ctx.booleanWarnings.maxElementsExceeded {
		return {}
	}
	openLayoutElement := get_open_layout_element()
	for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
		mapping := array_get(&ctx.scrollContainerDatas, i)
		if mapping.elementId == openLayoutElement.id {
			return mapping.scrollPosition
		}
	}
	return {}
}

UpdateScrollContainers :: proc(enableDragScrolling: bool, scrollDelta: Vector2, deltaTime: f32) {
	ctx := current_context
	isPointerActive :=
		enableDragScrolling &&
		(ctx.pointerInfo.state == .Pressed || ctx.pointerInfo.state == .PressedThisFrame)
	// Don't apply scroll events to ancestors of the inner element
	highestPriorityElementIndex: i32 = -1
	highestPriorityScrollData: ^Scroll_Container_Data_Internal = nil
	for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
		scrollData := array_get(&ctx.scrollContainerDatas, i)
		if !scrollData.openThisFrame {
			array_remove_swapback(&ctx.scrollContainerDatas, i)
			continue
		}
		scrollData.openThisFrame = false
		hashMapItem := get_hash_map_item(scrollData.elementId)
		// Element isn't rendered this frame but scroll offset has been retained
		if hashMapItem == nil {
			array_remove_swapback(&ctx.scrollContainerDatas, i)
			continue
		}

		// Touch / click is released
		if !isPointerActive && scrollData.pointerScrollActive {
			xDiff := scrollData.scrollPosition.x - scrollData.scrollOrigin.x
			if xDiff < -10 || xDiff > 10 {
				scrollData.scrollMomentum.x =
					(scrollData.scrollPosition.x - scrollData.scrollOrigin.x) /
					(scrollData.momentumTime * 25)
			}
			yDiff := scrollData.scrollPosition.y - scrollData.scrollOrigin.y
			if yDiff < -10 || yDiff > 10 {
				scrollData.scrollMomentum.y =
					(scrollData.scrollPosition.y - scrollData.scrollOrigin.y) /
					(scrollData.momentumTime * 25)
			}
			scrollData.pointerScrollActive = false

			scrollData.pointerOrigin = Vector2{0, 0}
			scrollData.scrollOrigin = Vector2{0, 0}
			scrollData.momentumTime = 0
		}

		// Apply existing momentum
		scrollData.scrollPosition.x += scrollData.scrollMomentum.x
		scrollData.scrollMomentum.x *= 0.95
		scrollOccurred := scrollDelta.x != 0 || scrollDelta.y != 0
		if (scrollData.scrollMomentum.x > -0.1 && scrollData.scrollMomentum.x < 0.1) ||
		   scrollOccurred {
			scrollData.scrollMomentum.x = 0
		}
		scrollData.scrollPosition.x = cmin(
			cmax(
				scrollData.scrollPosition.x,
				-(cmax(
						scrollData.contentSize.width - scrollData.layoutElement.dimensions.width,
						0,
					)),
			),
			0,
		)

		scrollData.scrollPosition.y += scrollData.scrollMomentum.y
		scrollData.scrollMomentum.y *= 0.95
		if (scrollData.scrollMomentum.y > -0.1 && scrollData.scrollMomentum.y < 0.1) ||
		   scrollOccurred {
			scrollData.scrollMomentum.y = 0
		}
		scrollData.scrollPosition.y = cmin(
			cmax(
				scrollData.scrollPosition.y,
				-(cmax(
						scrollData.contentSize.height - scrollData.layoutElement.dimensions.height,
						0,
					)),
			),
			0,
		)

		// Input goes to the innermost container under the pointer that can move
		// along it. One that can't (a clipped one-line label under a vertical
		// wheel) passes the input to its ancestors instead of swallowing it.
		clip := &scrollData.layoutElement.config.clip
		movesX :=
			clip.horizontal &&
			scrollData.contentSize.width > scrollData.layoutElement.dimensions.width
		movesY :=
			clip.vertical &&
			scrollData.contentSize.height > scrollData.layoutElement.dimensions.height
		takesInput :=
			isPointerActive ? movesX || movesY : (scrollDelta.x != 0 && movesX) || (scrollDelta.y != 0 && movesY)
		if !takesInput {
			continue
		}
		for j: i32 = 0; j < ctx.pointerOverIds.length; j += 1 { 	// TODO n & m are small here but this being n*m gives me the creeps
			// pointerOverIds runs parent before child: a higher index is deeper.
			if j > highestPriorityElementIndex &&
			   scrollData.layoutElement.id == array_get(&ctx.pointerOverIds, j).id {
				highestPriorityElementIndex = j
				highestPriorityScrollData = scrollData
			}
		}
	}

	if highestPriorityElementIndex > -1 && highestPriorityScrollData != nil {
		scrollElement := highestPriorityScrollData.layoutElement
		clipConfig := &scrollElement.config.clip
		canScrollVertically :=
			clipConfig.vertical &&
			highestPriorityScrollData.contentSize.height > scrollElement.dimensions.height
		canScrollHorizontally :=
			clipConfig.horizontal &&
			highestPriorityScrollData.contentSize.width > scrollElement.dimensions.width
		// Handle wheel scroll
		if canScrollVertically {
			highestPriorityScrollData.scrollPosition.y =
				highestPriorityScrollData.scrollPosition.y + scrollDelta.y * 10
		}
		if canScrollHorizontally {
			highestPriorityScrollData.scrollPosition.x =
				highestPriorityScrollData.scrollPosition.x + scrollDelta.x * 10
		}
		// Handle click / touch scroll
		if isPointerActive {
			highestPriorityScrollData.scrollMomentum = {}
			if !highestPriorityScrollData.pointerScrollActive {
				highestPriorityScrollData.pointerOrigin = ctx.pointerInfo.position
				highestPriorityScrollData.scrollOrigin = highestPriorityScrollData.scrollPosition
				highestPriorityScrollData.pointerScrollActive = true
			} else {
				scrollDeltaX, scrollDeltaY: f32 = 0, 0
				if canScrollHorizontally {
					oldXScrollPosition := highestPriorityScrollData.scrollPosition.x
					highestPriorityScrollData.scrollPosition.x =
						highestPriorityScrollData.scrollOrigin.x +
						(ctx.pointerInfo.position.x - highestPriorityScrollData.pointerOrigin.x)
					highestPriorityScrollData.scrollPosition.x = cmax(
						cmin(highestPriorityScrollData.scrollPosition.x, 0),
						-(highestPriorityScrollData.contentSize.width -
							highestPriorityScrollData.boundingBox.width),
					)
					scrollDeltaX = highestPriorityScrollData.scrollPosition.x - oldXScrollPosition
				}
				if canScrollVertically {
					oldYScrollPosition := highestPriorityScrollData.scrollPosition.y
					highestPriorityScrollData.scrollPosition.y =
						highestPriorityScrollData.scrollOrigin.y +
						(ctx.pointerInfo.position.y - highestPriorityScrollData.pointerOrigin.y)
					highestPriorityScrollData.scrollPosition.y = cmax(
						cmin(highestPriorityScrollData.scrollPosition.y, 0),
						-(highestPriorityScrollData.contentSize.height -
							highestPriorityScrollData.boundingBox.height),
					)
					scrollDeltaY = highestPriorityScrollData.scrollPosition.y - oldYScrollPosition
				}
				if scrollDeltaX > -0.1 &&
				   scrollDeltaX < 0.1 &&
				   scrollDeltaY > -0.1 &&
				   scrollDeltaY < 0.1 &&
				   highestPriorityScrollData.momentumTime > 0.15 {
					highestPriorityScrollData.momentumTime = 0
					highestPriorityScrollData.pointerOrigin = ctx.pointerInfo.position
					highestPriorityScrollData.scrollOrigin =
						highestPriorityScrollData.scrollPosition
				} else {
					highestPriorityScrollData.momentumTime += deltaTime
				}
			}
		}
		// Clamp any changes to scroll position to the maximum size of the contents
		if canScrollVertically {
			highestPriorityScrollData.scrollPosition.y = cmax(
				cmin(highestPriorityScrollData.scrollPosition.y, 0),
				-(highestPriorityScrollData.contentSize.height - scrollElement.dimensions.height),
			)
		}
		if canScrollHorizontally {
			highestPriorityScrollData.scrollPosition.x = cmax(
				cmin(highestPriorityScrollData.scrollPosition.x, 0),
				-(highestPriorityScrollData.contentSize.width - scrollElement.dimensions.width),
			)
		}
	}
}

BeginLayout :: proc() {
	ctx := current_context
	initialize_ephemeral_memory(ctx)
	ctx.generation += 1
	// Set up the root container that covers the entire window
	rootDimensions := Dimensions{ctx.layoutDimensions.width, ctx.layoutDimensions.height}
	ctx.booleanWarnings = {}
	open_element_with_id(hash_string(static_string(ROOT_CONTAINER), 0))
	declaration := ElementDeclaration {
		layout = {
			sizing = {
				width = {
					constraints = {sizeMinMax = {rootDimensions.width, rootDimensions.width}},
					type = .Fixed,
				},
				height = {
					constraints = {sizeMinMax = {rootDimensions.height, rootDimensions.height}},
					type = .Fixed,
				},
			},
		},
	}
	configure_open_element_ptr(&declaration)
	array_add(&ctx.openLayoutElementStack, 0)
	array_add(&ctx.layoutElementTreeRoots, Layout_Element_Tree_Root{layoutElementIndex = 0})
}

@(private)
clone_elements_with_exit_transition :: proc() {
	ctx := current_context
	nextIndex := ctx.layoutElements.capacity - 1
	nextChildIndex := ctx.layoutElementChildren.capacity - 1

	for i: i32 = 0; i < ctx.transitionDatas.length; i += 1 {
		data := array_get(&ctx.transitionDatas, i)
		if data.transitionOut {
			bfsBuffer := ctx.openLayoutElementStack
			bfsBuffer.length = 0
			newElement := array_set_keep_length(
				&ctx.layoutElements,
				nextIndex,
				data.elementThisFrame^,
			)
			array_add(&bfsBuffer, nextIndex)
			data.elementThisFrame = newElement
			nextIndex -= 1

			bufferIndex: i32 = 0
			for bufferIndex < bfsBuffer.length {
				layoutElement := array_get_check_capacity(
					&ctx.layoutElements,
					array_get_value(&bfsBuffer, bufferIndex),
				)
				bufferIndex += 1
				for j := i32(layoutElement.children.length) - 1; j >= 0; j -= 1 {
					childElement := array_get_check_capacity(
						&ctx.layoutElements,
						layoutElement.children.elements[j],
					)
					array_add(&bfsBuffer, nextIndex)
					array_set_keep_length(&ctx.layoutElements, nextIndex, childElement^)
					array_set_keep_length(&ctx.layoutElementChildren, nextChildIndex, nextIndex)
					nextIndex -= 1
					nextChildIndex -= 1
				}
				layoutElement.children.elements = &ctx.layoutElementChildren.internalArray[nextChildIndex + 1]
			}
		}
	}
}

@(private)
apply_transitioned_properties_to_element :: proc(
	currentElement: ^Layout_Element,
	properties: TransitionPropertyFlags,
	currentTransitionData: TransitionData,
	boundingBox: ^BoundingBox,
	reparented: bool,
) {
	if .Width in properties {
		if !reparented {
			currentElement.dimensions.width = currentTransitionData.boundingBox.width
			currentElement.config.layout.sizing.width = {
				constraints = {
					sizeMinMax = {
						currentTransitionData.boundingBox.width,
						currentTransitionData.boundingBox.width,
					},
				},
				type = .Fixed,
			}
		} else {
			boundingBox.width = currentTransitionData.boundingBox.width
		}
	}
	if .Height in properties {
		if !reparented {
			currentElement.dimensions.height = currentTransitionData.boundingBox.height
			currentElement.config.layout.sizing.height = {
				constraints = {
					sizeMinMax = {
						currentTransitionData.boundingBox.height,
						currentTransitionData.boundingBox.height,
					},
				},
				type = .Fixed,
			}
		} else {
			boundingBox.height = currentTransitionData.boundingBox.height
		}
	}
	if .X in properties {
		boundingBox.x = currentTransitionData.boundingBox.x
	}
	if .Y in properties {
		boundingBox.y = currentTransitionData.boundingBox.y
	}
	if .OverlayColor in properties {
		currentElement.config.overlayColor = currentTransitionData.overlayColor
	}
	if .BackgroundColor in properties {
		currentElement.config.backgroundColor = currentTransitionData.backgroundColor
	}
	if .BorderColor in properties {
		currentElement.config.border.color = currentTransitionData.borderColor
	}
	if .BorderWidth in properties {
		currentElement.config.border.width = currentTransitionData.borderWidth
	}
}

EndLayout :: proc(deltaTime: f32) -> ClayArray(RenderCommand) {
	ctx := current_context
	close_element()

	if ctx.openLayoutElementStack.length > 1 {
		report_error(
			.UnbalancedOpenClose,
			"There were still open layout elements when EndLayout was called. This results from an unequal number of calls to Clay__OpenElement and Clay__CloseElement.",
		)
	}

	// Prune non exiting transitions
	for i: i32 = 0; i < ctx.transitionDatas.length; i += 1 {
		data := array_get(&ctx.transitionDatas, i)
		hashMapItem := get_hash_map_item(data.elementId)
		// Transition element exited and doesn't have an exit handler defined
		// Or, the user deleted the transition handler from one frame to the next
		if !data.transitionOut &&
		   (hashMapItem.generation <= ctx.generation ||
				   hashMapItem.layoutElement.config.transition.handler == nil) {
			array_remove_swapback(&ctx.transitionDatas, i)
			i -= 1
			continue
		}
	}

	elementIdsToRemoveTransitions := ctx.reusableElementIndexBuffer
	elementIdsToRemoveTransitions.length = 0

	for i: i32 = 0; i < ctx.transitionDatas.length; i += 1 {
		data := array_get(&ctx.transitionDatas, i)
		hashMapItem := get_hash_map_item(data.elementId)
		// If the element had no exit transition it has vanished entirely by now,
		// so only the stored transitionOut flag can say whether to transition out.
		if data.transitionOut {
			config := &data.elementThisFrame.config.transition
			// Element wasn't found this frame - either delete transition data or transition out
			if hashMapItem.generation <= ctx.generation {
				parentHashMapItem := get_hash_map_item(data.parentId)
				// Don't exit transition if the parent has also exited and SKIP_WHEN_PARENT_EXITS is used
				if config.exit.trigger == .TriggerWhenParentExits ||
				   parentHashMapItem == nil ||
				   parentHashMapItem.generation > ctx.generation {
					// This if only runs one single time when the element first starts exiting
					if data.state != .Exiting {
						if parentHashMapItem.generation <= ctx.generation {
							data.elementThisFrame.config.floating.attachTo = .Root
							data.elementThisFrame.config.floating.offset = Vector2 {
								hashMapItem.boundingBox.x,
								hashMapItem.boundingBox.y,
							}
							data.elementThisFrame.config.floating.parentId =
								hash_string(static_string(ROOT_CONTAINER), 0).id
						}
						hashMapItem.appearedThisFrame = false
						data.elementThisFrame.exiting = true
						data.elementThisFrame.config.layout.sizing.width = {
							constraints = {
								sizeMinMax = {
									data.elementThisFrame.dimensions.width,
									data.elementThisFrame.dimensions.width,
								},
							},
							type = .Fixed,
						}
						data.elementThisFrame.config.layout.sizing.height = {
							constraints = {
								sizeMinMax = {
									data.elementThisFrame.dimensions.height,
									data.elementThisFrame.dimensions.height,
								},
							},
							type = .Fixed,
						}
						data.state = .Exiting
						data.activeProperties = config.properties
						data.elapsedTime = 0
						data.targetState = config.exit.setFinalState(
							data.targetState,
							config.properties,
						)
					}

					// Below this line runs every frame while element is exiting -----------

					// Clone the entire subtree back into the main UI layout tree
					bfsBuffer := ctx.openLayoutElementStack
					bfsBuffer.length = 0
					data.elementThisFrame = array_add(&ctx.layoutElements, data.elementThisFrame^)
					exitingElementIndex := i32(
						(uintptr(data.elementThisFrame) -
							uintptr(ctx.layoutElements.internalArray)) /
						size_of(Layout_Element),
					)
					array_add(
						&ctx.layoutElementClipElementIds,
						array_get_check_capacity(
							&ctx.layoutElementClipElementIds,
							exitingElementIndex,
						)^,
					)
					array_add(&bfsBuffer, exitingElementIndex)
					bufferIndex: i32 = 0
					for bufferIndex < bfsBuffer.length {
						layoutElement := array_get_check_capacity(
							&ctx.layoutElements,
							array_get_value(&bfsBuffer, bufferIndex),
						)
						bfsMapItem := get_hash_map_item(layoutElement.id)
						// Children of exiting elements may have been moved elsewhere in the layout, this prevents a duplicate ID error if they still exist.
						if bfsMapItem.generation <= ctx.generation {
							add_hash_map_item(ElementId{id = layoutElement.id}, layoutElement)
							firstChildSlot := ctx.layoutElementChildren.length
							newChildrenLength := layoutElement.children.length
							for j: i32 = 0; j < i32(layoutElement.children.length); j += 1 {
								childElement := array_get_check_capacity(
									&ctx.layoutElements,
									layoutElement.children.elements[j],
								)
								childMapItem := get_hash_map_item(childElement.id)
								if childMapItem.generation <= ctx.generation {
									// Remove any nested transitions inside exiting trees
									if !childElement.isTextElement &&
									   childElement.config.transition.handler != nil {
										array_add(
											&elementIdsToRemoveTransitions,
											i32(childElement.id),
										)
									}
									childElementIndex := i32(
										(uintptr(childElement) -
											uintptr(ctx.layoutElements.internalArray)) /
										size_of(Layout_Element),
									)
									newChildElement := array_add(
										&ctx.layoutElements,
										childElement^,
									)
									array_add(
										&ctx.layoutElementClipElementIds,
										array_get_check_capacity(
											&ctx.layoutElementClipElementIds,
											childElementIndex,
										)^,
									)
									array_add(&bfsBuffer, ctx.layoutElements.length - 1)
									if newChildElement.isTextElement {
										newChildElement.textElementData.wrappedLines.length = 0
									}
									array_add(
										&ctx.layoutElementChildren,
										ctx.layoutElements.length - 1,
									)
								} else {
									newChildrenLength -= 1
								}
							}
							layoutElement.children = Layout_Element_Children {
								elements = &ctx.layoutElementChildren.internalArray[firstChildSlot],
								length   = newChildrenLength,
							}
						}
						bufferIndex += 1
					}
					hashMapItem.layoutElement = data.elementThisFrame

					// Reattach the inserted subtree to its previous parent if it still exists
					// and the exiting element is not floating
					floatingConfig := &hashMapItem.layoutElement.config.floating
					if parentHashMapItem.generation > ctx.generation &&
					   floatingConfig.attachTo == .None {
						parentElement := parentHashMapItem.layoutElement
						newChildrenStartIndex := ctx.layoutElementChildren.length
						found := false
						if config.exit.siblingOrdering == .UnderneathSiblings {
							array_add(&ctx.layoutElementChildren, exitingElementIndex)
							found = true
						}
						for j: i32 = 0; j < i32(parentElement.children.length); j += 1 {
							if config.exit.siblingOrdering == .NaturalOrder &&
							   u32(j) == data.siblingIndex {
								array_add(&ctx.layoutElementChildren, exitingElementIndex)
								found = true
							}
							array_add(
								&ctx.layoutElementChildren,
								parentElement.children.elements[j],
							)
						}
						if !found {
							array_add(&ctx.layoutElementChildren, exitingElementIndex)
						}
						parentElement.children.length += 1
						parentElement.children.elements = &ctx.layoutElementChildren.internalArray[newChildrenStartIndex]
						// Otherwise, create the tree root for the floating element (needs to be created every frame)
					} else {
						array_add(
							&ctx.layoutElementTreeRoots,
							Layout_Element_Tree_Root {
								layoutElementIndex = i32(
									(uintptr(data.elementThisFrame) -
										uintptr(ctx.layoutElements.internalArray)) /
									size_of(Layout_Element),
								),
								parentId = floatingConfig.parentId,
								zIndex = floatingConfig.zIndex,
							},
						)
					}
					// Parent exited, just delete child without exit transition
				} else {
					array_remove_swapback(&ctx.transitionDatas, i)
					i -= 1
					continue
				}
			}
		}
	}

	for i: i32 = 0; i < elementIdsToRemoveTransitions.length; i += 1 {
		for j: i32 = 0; j < ctx.transitionDatas.length; j += 1 {
			if array_get(&ctx.transitionDatas, j).elementId ==
			   u32(array_get_value(&elementIdsToRemoveTransitions, i)) {
				array_remove_swapback(&ctx.transitionDatas, j)
				break
			}
		}
	}

	if ctx.booleanWarnings.maxElementsExceeded {
		message := static_string("Clay Error: Layout elements exceeded Clay__maxElementCount")
		report_error(
			.ElementsCapacityExceeded,
			"Clay Error: Layout elements exceeded Clay__maxElementCount",
		)
		command := RenderCommand {
			boundingBox = {
				ctx.layoutDimensions.width / 2 - 59 * 4,
				ctx.layoutDimensions.height / 2,
				0,
				0,
			},
			commandType = .Text,
		}
		command.renderData.text = {
			stringContents = StringSlice {
				length = message.length,
				chars = message.chars,
				baseChars = message.chars,
			},
			textColor = {255, 0, 0, 255},
			fontSize = 16,
		}
		add_render_command(command)
	} else {
		if ctx.transitionDatas.length > 0 {
			calculate_final_layout(deltaTime, false, false)

			for i: i32 = 0; i < ctx.transitionDatas.length; i += 1 {
				transitionData := array_get(&ctx.transitionDatas, i)
				currentElement := transitionData.elementThisFrame
				mapItem := get_hash_map_item(transitionData.elementId)
				parentMapItem := get_hash_map_item(transitionData.parentId)
				targetState := transitionData.targetState
				if transitionData.state != .Exiting {
					targetState = TransitionData {
						mapItem.boundingBox,
						currentElement.config.backgroundColor,
						currentElement.config.overlayColor,
						currentElement.config.border.color,
						currentElement.config.border.width,
					}
				}
				oldTargetState := transitionData.targetState
				transitionData.targetState = targetState
				if mapItem.appearedThisFrame {
					if currentElement.config.transition.enter.setInitialState != nil &&
					   !(parentMapItem.appearedThisFrame &&
							   currentElement.config.transition.enter.trigger ==
								   .SkipOnFirstParentFrame) {
						transitionData.state = .Entering
						transitionData.initialState =
							currentElement.config.transition.enter.setInitialState(
								transitionData.targetState,
								currentElement.config.transition.properties,
							)
						transitionData.currentState = transitionData.initialState
						transitionData.activeProperties =
							currentElement.config.transition.properties
						apply_transitioned_properties_to_element(
							currentElement,
							currentElement.config.transition.properties,
							transitionData.initialState,
							&mapItem.boundingBox,
							transitionData.reparented,
						)
					} else {
						transitionData.initialState = targetState
						transitionData.currentState = targetState
						transitionData.activeProperties = {}
					}
				} else {
					if transitionData.state != .Exiting {
						parentScrollOffset := parentMapItem.layoutElement.config.clip.childOffset
						newRelativePosition := Vector2 {
							mapItem.boundingBox.x -
							parentMapItem.boundingBox.x -
							parentScrollOffset.x,
							mapItem.boundingBox.y -
							parentMapItem.boundingBox.y -
							parentScrollOffset.y,
						}
						oldRelativePosition := transitionData.oldParentRelativePosition
						transitionData.oldParentRelativePosition = newRelativePosition
						properties := currentElement.config.transition.properties
						newActiveProperties: TransitionPropertyFlags
						if .X in properties {
							// Don't trigger a transition if...
							if (!float_equal(
									   oldTargetState.boundingBox.x,// The element's absolute position didn't change
									   targetState.boundingBox.x,
								   ) && (!(float_equal(oldRelativePosition.x, newRelativePosition.x)) || transitionData.reparented) && !ctx.rootResizedLastFrame) { 	// The element is still in the same parent container, and it's parent-relative position didn't change (parent moved) // The position changed was triggered by the outer window resizing
								newActiveProperties += {.X}
							}
						}
						if .Y in properties {
							// See extended comments above in PROPERTY_X for explanation
							if !float_equal(
								   oldTargetState.boundingBox.y,
								   targetState.boundingBox.y,
							   ) &&
							   (!(float_equal(oldRelativePosition.y, newRelativePosition.y)) ||
									   transitionData.reparented) &&
							   !ctx.rootResizedLastFrame {
								newActiveProperties += {.Y}
							}
						}
						if .Width in properties {
							if !float_equal(
								   oldTargetState.boundingBox.width,
								   targetState.boundingBox.width,
							   ) &&
							   !ctx.rootResizedLastFrame {
								newActiveProperties += {.Width}
							}
						}
						if .Height in properties {
							if !float_equal(
								   oldTargetState.boundingBox.height,
								   targetState.boundingBox.height,
							   ) &&
							   !ctx.rootResizedLastFrame {
								newActiveProperties += {.Height}
							}
						}
						if .BackgroundColor in properties {
							if !mem_cmp(
								([^]u8)(&oldTargetState.backgroundColor),
								([^]u8)(&targetState.backgroundColor),
								size_of(Color),
							) {
								newActiveProperties += {.BackgroundColor}
							}
						}
						if .OverlayColor in properties {
							if !mem_cmp(
								([^]u8)(&oldTargetState.overlayColor),
								([^]u8)(&targetState.overlayColor),
								size_of(Color),
							) {
								newActiveProperties += {.OverlayColor}
							}
						}
						if .BorderColor in properties {
							if !mem_cmp(
								([^]u8)(&oldTargetState.borderColor),
								([^]u8)(&targetState.borderColor),
								size_of(Color),
							) {
								newActiveProperties += {.BorderColor}
							}
						}
						if .BorderWidth in properties {
							if !mem_cmp(
								([^]u8)(&oldTargetState.borderWidth),
								([^]u8)(&targetState.borderWidth),
								size_of(BorderWidth),
							) {
								newActiveProperties += {.BorderWidth}
							}
						}

						if newActiveProperties != {} {
							transitionData.elapsedTime = 0
							transitionData.initialState = transitionData.currentState
							transitionData.state = .Transitioning
							transitionData.activeProperties =
								transitionData.activeProperties + newActiveProperties
						}
					}

					if transitionData.state == .Idle {
						transitionData.initialState = targetState
						transitionData.currentState = targetState
						transitionData.targetState = targetState
						transitionData.activeProperties = {}
					} else {
						transitionComplete := true
						transitionComplete = currentElement.config.transition.handler(
							TransitionCallbackArguments {
								transitionData.state,
								transitionData.initialState,
								&transitionData.currentState,
								targetState,
								transitionData.elapsedTime,
								currentElement.config.transition.duration,
								transitionData.activeProperties,
							},
						)

						apply_transitioned_properties_to_element(
							currentElement,
							transitionData.activeProperties,
							transitionData.currentState,
							&mapItem.boundingBox,
							transitionData.reparented,
						)
						transitionData.elapsedTime += deltaTime

						if transitionComplete {
							if transitionData.state == .Entering ||
							   transitionData.state == .Transitioning {
								transitionData.state = .Idle
								transitionData.elapsedTime = 0
								transitionData.reparented = false
								transitionData.activeProperties = {}
							} else if transitionData.state == .Exiting {
								array_remove_swapback(&ctx.transitionDatas, i)
							}
						}
					}
				}
			}

			calculate_final_layout(deltaTime, true, true)
			clone_elements_with_exit_transition()
		} else {
			calculate_final_layout(deltaTime, false, true)
		}
	}

	for i: i32 = 0; i < ctx.layoutElementsHashMap.capacity; i += 1 {
		currentElementIndex := ctx.layoutElementsHashMap.internalArray[i]
		previousElementIndex: i32 = -1
		for currentElementIndex != -1 {
			currentItem := array_get(&ctx.layoutElementsHashMapInternal, currentElementIndex)
			nextIndex := currentItem.nextIndex
			// Needs to be pruned
			if currentItem.generation <= ctx.generation {
				// Delete the underlying item and add it to the freelist
				array_set(
					&ctx.layoutElementsHashMapInternal,
					currentElementIndex,
					Layout_Element_Hash_Map_Item{nextIndex = -1},
				)
				array_add(&ctx.layoutElementsHashMapFreeList, currentElementIndex)
				// If it's the very top of the bucket, rewrite the first bucket pointer
				if previousElementIndex == -1 {
					array_set(&ctx.layoutElementsHashMap, i, nextIndex)
					currentElementIndex = nextIndex
					previousElementIndex = -1
				} else {
					// Rewrite previous pointer
					previousItem := array_get(
						&ctx.layoutElementsHashMapInternal,
						previousElementIndex,
					)
					previousItem.nextIndex = nextIndex
					currentElementIndex = nextIndex
				}
			} else {
				previousElementIndex = currentElementIndex
				currentElementIndex = nextIndex
			}
		}
	}

	return ctx.renderCommands
}

GetOpenElementId :: proc() -> u32 {
	return get_open_layout_element().id
}

GetElementId :: proc(idString: String) -> ElementId {
	return hash_string(idString, 0)
}

GetElementIdWithIndex :: proc(idString: String, index: u32) -> ElementId {
	return hash_string_with_offset(idString, index, 0)
}

Hovered :: proc() -> bool {
	ctx := current_context
	if ctx.booleanWarnings.maxElementsExceeded {
		return false
	}
	openLayoutElement := get_open_layout_element()
	for i: i32 = 0; i < ctx.pointerOverIds.length; i += 1 {
		if array_get(&ctx.pointerOverIds, i).id == openLayoutElement.id {
			return true
		}
	}
	return false
}

OnHover :: proc(onHoverFunction: OnHoverFunction, userData: rawptr) {
	ctx := current_context
	if ctx.booleanWarnings.maxElementsExceeded {
		return
	}
	openLayoutElement := get_open_layout_element()
	hashMapItem := get_hash_map_item(openLayoutElement.id)
	hashMapItem.onHoverFunction = onHoverFunction
	hashMapItem.hoverFunctionUserData = userData
}

PointerOver :: proc(elementId: ElementId) -> bool { 	// TODO return priority for separating multiple results
	ctx := current_context
	for i: i32 = 0; i < ctx.pointerOverIds.length; i += 1 {
		if array_get(&ctx.pointerOverIds, i).id == elementId.id {
			return true
		}
	}
	return false
}

GetScrollContainerData :: proc(id: ElementId) -> ScrollContainerData {
	ctx := current_context
	for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
		scrollContainerData := array_get(&ctx.scrollContainerDatas, i)
		if scrollContainerData.elementId == id.id {
			if scrollContainerData.layoutElement == nil { 	// This can happen on the first frame before a scroll container is declared
				return {}
			}
			return ScrollContainerData {
				scrollPosition = &scrollContainerData.scrollPosition,
				scrollContainerDimensions = {
					scrollContainerData.boundingBox.width,
					scrollContainerData.boundingBox.height,
				},
				contentDimensions = scrollContainerData.contentSize,
				config = scrollContainerData.layoutElement.config.clip,
				found = true,
			}
		}
	}
	return {}
}

GetElementData :: proc(id: ElementId) -> ElementData {
	item := get_hash_map_item(id.id)
	if item == default_of(Layout_Element_Hash_Map_Item) {
		return {}
	}

	return ElementData{boundingBox = item.boundingBox, found = true}
}

SetCullingEnabled :: proc(enabled: bool) {
	ctx := current_context
	ctx.disableCulling = !enabled
}

GetMaxElementCount :: proc() -> i32 {
	ctx := current_context
	return ctx.maxElementCount
}

SetMaxElementCount :: proc(maxElementCount: i32) {
	ctx := current_context
	if ctx != nil {
		ctx.maxElementCount = maxElementCount
	} else {
		default_max_element_count = maxElementCount // TODO: Fix this
		default_max_measure_text_word_cache_count = maxElementCount * 2
	}
}

GetMaxMeasureTextCacheWordCount :: proc() -> i32 {
	ctx := current_context
	return ctx.maxMeasureTextCacheWordCount
}

SetMaxMeasureTextCacheWordCount :: proc(maxMeasureTextCacheWordCount: i32) {
	ctx := current_context
	if ctx != nil {
		current_context.maxMeasureTextCacheWordCount = maxMeasureTextCacheWordCount
	} else {
		default_max_measure_text_word_cache_count = maxMeasureTextCacheWordCount // TODO: Fix this
	}
}

ResetMeasureTextCache :: proc() {
	ctx := current_context
	ctx.measureTextHashMapInternal.length = 0
	ctx.measureTextHashMapInternalFreeList.length = 0
	ctx.measureTextHashMap.length = 0
	ctx.measuredWords.length = 0
	ctx.measuredWordsFreeList.length = 0

	for i: i32 = 0; i < ctx.measureTextHashMap.capacity; i += 1 {
		ctx.measureTextHashMap.internalArray[i] = 0
	}
	ctx.measureTextHashMapInternal.length = 1 // Reserve the 0 value to mean "no next element"
}

EaseOut :: proc(arguments: TransitionCallbackArguments) -> bool {
	ratio: f32 = 1
	if arguments.duration > 0 {
		ratio = cmin(arguments.elapsedTime / arguments.duration, 1)
	}
	inverse := 1.0 - ratio
	lerpAmount := 1.0 - (inverse * inverse * inverse)
	initial := arguments.initial
	target := arguments.target
	if .X in arguments.properties {
		arguments.current.boundingBox.x =
			initial.boundingBox.x + (target.boundingBox.x - initial.boundingBox.x) * lerpAmount
	}
	if .Y in arguments.properties {
		arguments.current.boundingBox.y =
			initial.boundingBox.y + (target.boundingBox.y - initial.boundingBox.y) * lerpAmount
	}
	if .Width in arguments.properties {
		arguments.current.boundingBox.width =
			initial.boundingBox.width +
			(target.boundingBox.width - initial.boundingBox.width) * lerpAmount
	}
	if .Height in arguments.properties {
		arguments.current.boundingBox.height =
			initial.boundingBox.height +
			(target.boundingBox.height - initial.boundingBox.height) * lerpAmount
	}
	if .BackgroundColor in arguments.properties {
		arguments.current.backgroundColor = Color {
			initial.backgroundColor.r +
			(target.backgroundColor.r - initial.backgroundColor.r) * lerpAmount,
			initial.backgroundColor.g +
			(target.backgroundColor.g - initial.backgroundColor.g) * lerpAmount,
			initial.backgroundColor.b +
			(target.backgroundColor.b - initial.backgroundColor.b) * lerpAmount,
			initial.backgroundColor.a +
			(target.backgroundColor.a - initial.backgroundColor.a) * lerpAmount,
		}
	}
	if .OverlayColor in arguments.properties {
		arguments.current.overlayColor = Color {
			initial.overlayColor.r + (target.overlayColor.r - initial.overlayColor.r) * lerpAmount,
			initial.overlayColor.g + (target.overlayColor.g - initial.overlayColor.g) * lerpAmount,
			initial.overlayColor.b + (target.overlayColor.b - initial.overlayColor.b) * lerpAmount,
			initial.overlayColor.a + (target.overlayColor.a - initial.overlayColor.a) * lerpAmount,
		}
	}
	if .BorderColor in arguments.properties {
		arguments.current.borderColor = Color {
			initial.borderColor.r + (target.borderColor.r - initial.borderColor.r) * lerpAmount,
			initial.borderColor.g + (target.borderColor.g - initial.borderColor.g) * lerpAmount,
			initial.borderColor.b + (target.borderColor.b - initial.borderColor.b) * lerpAmount,
			initial.borderColor.a + (target.borderColor.a - initial.borderColor.a) * lerpAmount,
		}
	}
	if .BorderWidth in arguments.properties {
		// CLAY__LERP on u16: operands promote to int, then int * float.
		from := initial.borderWidth
		to := target.borderWidth
		arguments.current.borderWidth = BorderWidth {
			left            = u16(
				f32(i32(from.left)) + f32(i32(to.left) - i32(from.left)) * lerpAmount,
			),
			right           = u16(
				f32(i32(from.right)) + f32(i32(to.right) - i32(from.right)) * lerpAmount,
			),
			top             = u16(
				f32(i32(from.top)) + f32(i32(to.top) - i32(from.top)) * lerpAmount,
			),
			bottom          = u16(
				f32(i32(from.bottom)) + f32(i32(to.bottom) - i32(from.bottom)) * lerpAmount,
			),
			betweenChildren = u16(
				f32(i32(from.betweenChildren)) +
				f32(i32(to.betweenChildren) - i32(from.betweenChildren)) * lerpAmount,
			),
		}
	}
	return ratio >= 1
}

RenderCommandArray_Get :: proc(array: ^ClayArray(RenderCommand), index: i32) -> ^RenderCommand {
	return array_get(array, index)
}
