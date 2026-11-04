package clay

// Layout passes: axis sizing, text wrapping, final positioning and render
// command generation (clay.h Clay__FloatEqual .. Clay__CalculateFinalLayout).

@(private)
float_equal :: proc(left, right: f32) -> bool {
	subtracted := left - right
	return subtracted < EPSILON && subtracted > -EPSILON
}

@(private)
get_element_sizing :: proc(element: ^Layout_Element, xAxis: bool) -> SizingAxis {
	if element.isTextElement {
		return SizingAxis{}
	} else {
		return xAxis ? element.config.layout.sizing.width : element.config.layout.sizing.height
	}
}

// Writes out the location of text elements to layout elements buffer 1
@(private)
size_containers_along_axis :: proc(
	xAxis: bool,
	deltaTime: f32,
	textElementsOut: ^ClayArray(i32),
	aspectRatioElementsOut: ^ClayArray(i32),
) {
	ctx := current_context
	bfsBuffer := ctx.layoutElementChildrenBuffer
	resizableContainerBuffer := ctx.openLayoutElementStack
	for rootIndex: i32 = 0; rootIndex < ctx.layoutElementTreeRoots.length; rootIndex += 1 {
		bfsBuffer.length = 0
		root := array_get(&ctx.layoutElementTreeRoots, rootIndex)
		rootElement := array_get(&ctx.layoutElements, root.layoutElementIndex)
		array_add(&bfsBuffer, root.layoutElementIndex)

		// Size floating containers to their parents
		if rootElement.config.floating.attachTo != .None {
			floatingElementConfig := &rootElement.config.floating
			parentItem := get_hash_map_item(floatingElementConfig.parentId)
			if parentItem != nil && parentItem != default_of(Layout_Element_Hash_Map_Item) {
				parentLayoutElement := parentItem.layoutElement
				#partial switch rootElement.config.layout.sizing.width.type {
				case .Grow:
					rootElement.dimensions.width = parentLayoutElement.dimensions.width
				case .Percent:
					rootElement.dimensions.width =
						parentLayoutElement.dimensions.width *
						rootElement.config.layout.sizing.width.constraints.sizePercent
				}
				#partial switch rootElement.config.layout.sizing.height.type {
				case .Grow:
					rootElement.dimensions.height = parentLayoutElement.dimensions.height
				case .Percent:
					rootElement.dimensions.height =
						parentLayoutElement.dimensions.height *
						rootElement.config.layout.sizing.height.constraints.sizePercent
				}
			}
		}

		if rootElement.config.layout.sizing.width.type != .Percent {
			rootElement.dimensions.width = cmin(
				cmax(
					rootElement.dimensions.width,
					rootElement.config.layout.sizing.width.constraints.sizeMinMax.min,
				),
				rootElement.config.layout.sizing.width.constraints.sizeMinMax.max,
			)
		}
		if rootElement.config.layout.sizing.height.type != .Percent {
			rootElement.dimensions.height = cmin(
				cmax(
					rootElement.dimensions.height,
					rootElement.config.layout.sizing.height.constraints.sizeMinMax.min,
				),
				rootElement.config.layout.sizing.height.constraints.sizeMinMax.max,
			)
		}

		for i: i32 = 0; i < bfsBuffer.length; i += 1 {
			parentIndex := array_get_value(&bfsBuffer, i)
			parent := array_get(&ctx.layoutElements, parentIndex)
			parentLayoutConfig := &parent.config.layout
			growContainerCount: i32 = 0
			parentSize := xAxis ? parent.dimensions.width : parent.dimensions.height
			parentPadding := f32(
				xAxis ? (i32(parentLayoutConfig.padding.left) + i32(parentLayoutConfig.padding.right)) : (i32(parentLayoutConfig.padding.top) + i32(parentLayoutConfig.padding.bottom)),
			)
			innerContentSize: f32 = 0
			totalPaddingAndChildGaps := parentPadding
			sizingAlongAxis :=
				(xAxis && parentLayoutConfig.layoutDirection == .LeftToRight) ||
				(!xAxis && parentLayoutConfig.layoutDirection == .TopToBottom)
			resizableContainerBuffer.length = 0
			parentChildGap := f32(parentLayoutConfig.childGap)
			isFirstChild := true

			for childOffset: i32 = 0; childOffset < i32(parent.children.length); childOffset += 1 {
				childElementIndex := parent.children.elements[childOffset]
				childElement := array_get(&ctx.layoutElements, childElementIndex)
				childSizing := get_element_sizing(childElement, xAxis)
				childSize := xAxis ? childElement.dimensions.width : childElement.dimensions.height

				if textElementsOut != nil && childElement.isTextElement {
					array_add(textElementsOut, childElementIndex)
				} else if childElement.children.length > 0 {
					array_add(&bfsBuffer, childElementIndex)
				}

				if !childElement.isTextElement &&
				   aspectRatioElementsOut != nil &&
				   childElement.config.aspectRatio.aspectRatio != 0 {
					array_add(aspectRatioElementsOut, childElementIndex)
				}

				// Note: setting isFirstChild = false is skipped here
				if childElement.exiting {
					continue
				}

				if childSizing.type != .Percent &&
				   childSizing.type != .Fixed &&
				   (!childElement.isTextElement || childElement.textConfig.wrapMode == .Words) {
					array_add(&resizableContainerBuffer, childElementIndex)
				}

				if sizingAlongAxis {
					innerContentSize += (childSizing.type == .Percent ? 0 : childSize)
					if childSizing.type == .Grow {
						growContainerCount += 1
					}
					if !isFirstChild {
						innerContentSize += parentChildGap // For children after index 0, the childAxisOffset is the gap from the previous child
						totalPaddingAndChildGaps += parentChildGap
					}
				} else {
					innerContentSize = cmax(childSize, innerContentSize)
				}
				isFirstChild = false
			}

			// Expand percentage containers to size
			for childOffset: i32 = 0; childOffset < i32(parent.children.length); childOffset += 1 {
				childElementIndex := parent.children.elements[childOffset]
				childElement := array_get(&ctx.layoutElements, childElementIndex)
				childSizing := get_element_sizing(childElement, xAxis)
				childSize :=
					xAxis ? &childElement.dimensions.width : &childElement.dimensions.height
				if childSizing.type == .Percent {
					childSize^ =
						(parentSize - totalPaddingAndChildGaps) *
						childSizing.constraints.sizePercent
					if sizingAlongAxis {
						innerContentSize += childSize^
					}
					update_aspect_ratio_box(childElement)
				}
			}

			if sizingAlongAxis {
				sizeToDistribute := parentSize - parentPadding - innerContentSize
				// The content is too large, compress the children as much as possible
				if sizeToDistribute < 0 {
					// If the parent clips content in this axis direction, don't compress children, just leave them alone
					if ((xAxis && parent.config.clip.horizontal) ||
						   (!xAxis && parent.config.clip.vertical)) {
						continue
					}
					// Scrolling containers preferentially compress before others
					for sizeToDistribute < -EPSILON && resizableContainerBuffer.length > 0 {
						largest: f32 = 0
						secondLargest: f32 = 0
						widthToAdd := sizeToDistribute
						for childIndex: i32 = 0;
						    childIndex < resizableContainerBuffer.length;
						    childIndex += 1 {
							child := array_get(
								&ctx.layoutElements,
								array_get_value(&resizableContainerBuffer, childIndex),
							)
							childSize := xAxis ? child.dimensions.width : child.dimensions.height
							if float_equal(childSize, largest) {continue}
							if childSize > largest {
								secondLargest = largest
								largest = childSize
							}
							if childSize < largest {
								secondLargest = cmax(secondLargest, childSize)
								widthToAdd = secondLargest - largest
							}
						}

						widthToAdd = cmax(
							widthToAdd,
							sizeToDistribute / f32(resizableContainerBuffer.length),
						)

						for childIndex: i32 = 0;
						    childIndex < resizableContainerBuffer.length;
						    childIndex += 1 {
							child := array_get(
								&ctx.layoutElements,
								array_get_value(&resizableContainerBuffer, childIndex),
							)
							childSize := xAxis ? &child.dimensions.width : &child.dimensions.height
							minSize :=
								xAxis ? child.minDimensions.width : child.minDimensions.height
							previousWidth := childSize^
							if float_equal(childSize^, largest) {
								childSize^ += widthToAdd
								if childSize^ <= minSize {
									childSize^ = minSize
									array_remove_swapback(&resizableContainerBuffer, childIndex)
									childIndex -= 1
								}
								sizeToDistribute -= (childSize^ - previousWidth)
							}
						}
					}
					// The content is too small, allow SIZING_GROW containers to expand
				} else if sizeToDistribute > 0 && growContainerCount > 0 {
					for childIndex: i32 = 0;
					    childIndex < resizableContainerBuffer.length;
					    childIndex += 1 {
						child := array_get(
							&ctx.layoutElements,
							array_get_value(&resizableContainerBuffer, childIndex),
						)
						childSizing := get_element_sizing(child, xAxis).type
						if childSizing != .Grow {
							array_remove_swapback(&resizableContainerBuffer, childIndex)
							childIndex -= 1
						}
					}
					for sizeToDistribute > EPSILON && resizableContainerBuffer.length > 0 {
						smallest := MAX_FLOAT
						secondSmallest := MAX_FLOAT
						widthToAdd := sizeToDistribute
						for childIndex: i32 = 0;
						    childIndex < resizableContainerBuffer.length;
						    childIndex += 1 {
							child := array_get(
								&ctx.layoutElements,
								array_get_value(&resizableContainerBuffer, childIndex),
							)
							childSize := xAxis ? child.dimensions.width : child.dimensions.height
							if float_equal(childSize, smallest) {continue}
							if childSize < smallest {
								secondSmallest = smallest
								smallest = childSize
							}
							if childSize > smallest {
								secondSmallest = cmin(secondSmallest, childSize)
								widthToAdd = secondSmallest - smallest
							}
						}

						widthToAdd = cmin(
							widthToAdd,
							sizeToDistribute / f32(resizableContainerBuffer.length),
						)

						for childIndex: i32 = 0;
						    childIndex < resizableContainerBuffer.length;
						    childIndex += 1 {
							child := array_get(
								&ctx.layoutElements,
								array_get_value(&resizableContainerBuffer, childIndex),
							)
							childSize := xAxis ? &child.dimensions.width : &child.dimensions.height
							childSizing := get_element_sizing(child, xAxis)
							maxSize := childSizing.constraints.sizeMinMax.max
							previousWidth := childSize^
							if float_equal(childSize^, smallest) {
								childSize^ += widthToAdd
								if childSize^ >= maxSize {
									childSize^ = maxSize
									array_remove_swapback(&resizableContainerBuffer, childIndex)
									childIndex -= 1
								}
								sizeToDistribute -= (childSize^ - previousWidth)
							}
						}
					}
				}
				// Sizing along the non layout axis ("off axis")
			} else {
				for childOffset: i32 = 0;
				    childOffset < resizableContainerBuffer.length;
				    childOffset += 1 {
					childElement := array_get(
						&ctx.layoutElements,
						array_get_value(&resizableContainerBuffer, childOffset),
					)
					childSizing := get_element_sizing(childElement, xAxis)
					minSize :=
						xAxis ? childElement.minDimensions.width : childElement.minDimensions.height
					childSize :=
						xAxis ? &childElement.dimensions.width : &childElement.dimensions.height

					maxSize := parentSize - parentPadding
					// If we're laying out the children of a scroll panel, grow containers expand to the size of the inner content, not the outer container
					if ((xAxis && parent.config.clip.horizontal) ||
						   (!xAxis && parent.config.clip.vertical)) {
						maxSize = cmax(maxSize, innerContentSize)
					}
					if childSizing.type == .Grow {
						childSize^ = cmin(maxSize, childSizing.constraints.sizeMinMax.max)
					}
					childSize^ = cmax(minSize, cmin(childSize^, maxSize))
				}
			}
		}
	}
}

@(private)
add_render_command :: proc(renderCommand: RenderCommand) {
	ctx := current_context
	if ctx.renderCommands.length < ctx.renderCommands.capacity - 1 {
		array_add(&ctx.renderCommands, renderCommand)
	} else {
		if !ctx.booleanWarnings.maxRenderCommandsExceeded {
			ctx.booleanWarnings.maxRenderCommandsExceeded = true
			report_error(
				.ElementsCapacityExceeded,
				"Clay ran out of capacity while attempting to create render commands. This is usually caused by a large amount of wrapping text elements while close to the max element capacity. Try using Clay_SetMaxElementCount() with a higher value.",
			)
		}
	}
}

@(private)
element_is_offscreen :: proc(boundingBox: ^BoundingBox) -> bool {
	ctx := current_context
	if ctx.disableCulling {
		return false
	}

	return(
		(boundingBox.x > ctx.layoutDimensions.width) ||
		(boundingBox.y > ctx.layoutDimensions.height) ||
		(boundingBox.x + boundingBox.width < 0) ||
		(boundingBox.y + boundingBox.height < 0) \
	)
}

@(private)
calculate_final_layout :: proc(
	deltaTime: f32,
	useStoredBoundingBoxes: bool,
	generateRenderCommands: bool,
) {
	ctx := current_context

	// Calculate sizing along the X axis
	textElements := ctx.openClipElementStack
	textElements.length = 0
	aspectRatioElements := ctx.reusableElementIndexBuffer
	aspectRatioElements.length = 0
	size_containers_along_axis(true, deltaTime, &textElements, &aspectRatioElements)

	// Wrap text
	for textElementIndex: i32 = 0; textElementIndex < textElements.length; textElementIndex += 1 {
		element := array_get(&ctx.layoutElements, array_get_value(&textElements, textElementIndex))
		textElementData := &element.textElementData
		textElementData.wrappedLines = Array_Slice(Wrapped_Text_Line) {
			length        = 0,
			internalArray = &ctx.wrappedTextLines.internalArray[ctx.wrappedTextLines.length],
		}
		containerElement := array_get(
			&ctx.layoutElements,
			array_get_value(&textElements, textElementIndex),
		)
		measureTextCacheItem := measure_text_cached(
			&textElementData.text,
			&containerElement.textConfig,
		)
		lineWidth: f32 = 0
		lineHeight :=
			containerElement.textConfig.lineHeight > 0 ? f32(containerElement.textConfig.lineHeight) : textElementData.preferredDimensions.height
		lineLengthChars: i32 = 0
		lineStartOffset: i32 = 0
		if !measureTextCacheItem.containsNewlines &&
		   textElementData.preferredDimensions.width <= containerElement.dimensions.width {
			array_add(
				&ctx.wrappedTextLines,
				Wrapped_Text_Line{containerElement.dimensions, textElementData.text},
			)
			textElementData.wrappedLines.length += 1
			continue
		}
		spaceChar := " "
		spaceWidth :=
			measure_text(StringSlice{length = 1, chars = raw_data(spaceChar), baseChars = raw_data(spaceChar)}, &containerElement.textConfig, ctx.measureTextUserData).width
		wordIndex := measureTextCacheItem.measuredWordsStartIndex
		for wordIndex != -1 {
			if ctx.wrappedTextLines.length > ctx.wrappedTextLines.capacity - 1 {
				break
			}
			measuredWord := array_get(&ctx.measuredWords, wordIndex)
			// Only word on the line is too large, just render it anyway
			if lineLengthChars == 0 &&
			   lineWidth + measuredWord.width > containerElement.dimensions.width {
				array_add(
					&ctx.wrappedTextLines,
					Wrapped_Text_Line {
						{measuredWord.width, lineHeight},
						{
							length = measuredWord.length,
							chars = &textElementData.text.chars[measuredWord.startOffset],
						},
					},
				)
				textElementData.wrappedLines.length += 1
				wordIndex = measuredWord.next
				lineStartOffset = measuredWord.startOffset + measuredWord.length
			} else if measuredWord.length == 0 ||
			   lineWidth + measuredWord.width > containerElement.dimensions.width {
				// measuredWord.length == 0 means a newline character
				// Wrapped text lines list has overflowed, just render out the line
				finalCharIsSpace :=
					textElementData.text.chars[cmax(lineStartOffset + lineLengthChars - 1, 0)] ==
					' '
				array_add(
					&ctx.wrappedTextLines,
					Wrapped_Text_Line {
						{lineWidth + (finalCharIsSpace ? -spaceWidth : 0), lineHeight},
						{
							length = lineLengthChars + (finalCharIsSpace ? i32(-1) : i32(0)),
							chars = &textElementData.text.chars[lineStartOffset],
						},
					},
				)
				textElementData.wrappedLines.length += 1
				if lineLengthChars == 0 || measuredWord.length == 0 {
					wordIndex = measuredWord.next
				}
				lineWidth = 0
				lineLengthChars = 0
				lineStartOffset = measuredWord.startOffset
			} else {
				lineWidth += measuredWord.width + f32(containerElement.textConfig.letterSpacing)
				lineLengthChars += measuredWord.length
				wordIndex = measuredWord.next
			}
		}
		if lineLengthChars > 0 {
			array_add(
				&ctx.wrappedTextLines,
				Wrapped_Text_Line {
					{lineWidth - f32(containerElement.textConfig.letterSpacing), lineHeight},
					{
						length = lineLengthChars,
						chars = &textElementData.text.chars[lineStartOffset],
					},
				},
			)
			textElementData.wrappedLines.length += 1
		}
		containerElement.dimensions.height = lineHeight * f32(textElementData.wrappedLines.length)
	}

	// Scale vertical heights according to aspect ratio
	for i: i32 = 0; i < aspectRatioElements.length; i += 1 {
		aspectElement := array_get(&ctx.layoutElements, array_get_value(&aspectRatioElements, i))
		aspectElement.dimensions.height =
			(1 / aspectElement.config.aspectRatio.aspectRatio) * aspectElement.dimensions.width
		aspectElement.config.layout.sizing.height.constraints.sizeMinMax.max =
			aspectElement.dimensions.height
	}

	// Propagate effect of text wrapping, aspect scaling etc. on height of parents
	dfsBuffer := ctx.layoutElementTreeNodeArray1
	dfsBuffer.length = 0
	for i: i32 = 0; i < ctx.layoutElementTreeRoots.length; i += 1 {
		root := array_get(&ctx.layoutElementTreeRoots, i)
		ctx.treeNodeVisited.internalArray[dfsBuffer.length] = false
		array_add(
			&dfsBuffer,
			Layout_Element_Tree_Node {
				layoutElement = array_get(&ctx.layoutElements, root.layoutElementIndex),
			},
		)
	}
	for dfsBuffer.length > 0 {
		currentElementTreeNode := array_get(&dfsBuffer, dfsBuffer.length - 1)
		currentElement := currentElementTreeNode.layoutElement
		if !ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
			ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true
			// If the element has no children or is the container for a text element, don't bother inspecting it
			if currentElement.isTextElement || currentElement.children.length == 0 {
				dfsBuffer.length -= 1
				continue
			}
			// Add the children to the DFS buffer (needs to be pushed in reverse so that stack traversal is in correct layout order)
			for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
				ctx.treeNodeVisited.internalArray[dfsBuffer.length] = false
				array_add(
					&dfsBuffer,
					Layout_Element_Tree_Node {
						layoutElement = array_get(
							&ctx.layoutElements,
							currentElement.children.elements[i],
						),
					},
				)
			}
			continue
		}
		dfsBuffer.length -= 1

		// DFS node has been visited, this is on the way back up to the root
		layoutConfig := &currentElement.config.layout
		if layoutConfig.layoutDirection == .LeftToRight {
			// Resize any parent containers that have grown in height along their non layout axis
			for j: i32 = 0; j < i32(currentElement.children.length); j += 1 {
				childElement := array_get(&ctx.layoutElements, currentElement.children.elements[j])
				childHeightWithPadding := cmax(
					childElement.dimensions.height +
					f32(layoutConfig.padding.top) +
					f32(layoutConfig.padding.bottom),
					currentElement.dimensions.height,
				)
				currentElement.dimensions.height = cmin(
					cmax(
						childHeightWithPadding,
						layoutConfig.sizing.height.constraints.sizeMinMax.min,
					),
					layoutConfig.sizing.height.constraints.sizeMinMax.max,
				)
			}
		} else if layoutConfig.layoutDirection == .TopToBottom {
			// Resizing along the layout axis
			contentHeight := f32(i32(layoutConfig.padding.top) + i32(layoutConfig.padding.bottom))
			for j: i32 = 0; j < i32(currentElement.children.length); j += 1 {
				childElement := array_get(&ctx.layoutElements, currentElement.children.elements[j])
				contentHeight += childElement.dimensions.height
			}
			contentHeight += f32(
				cmax(i32(currentElement.children.length) - 1, 0) * i32(layoutConfig.childGap),
			)
			currentElement.dimensions.height = cmin(
				cmax(contentHeight, layoutConfig.sizing.height.constraints.sizeMinMax.min),
				layoutConfig.sizing.height.constraints.sizeMinMax.max,
			)
		}
	}

	// Calculate sizing along the Y axis
	size_containers_along_axis(false, deltaTime, nil, nil)

	// Scale horizontal widths according to aspect ratio
	for i: i32 = 0; i < aspectRatioElements.length; i += 1 {
		aspectElement := array_get(&ctx.layoutElements, array_get_value(&aspectRatioElements, i))
		aspectElement.dimensions.width =
			aspectElement.config.aspectRatio.aspectRatio * aspectElement.dimensions.height
	}

	// Sort tree roots by z-index
	sortMax := ctx.layoutElementTreeRoots.length - 1
	for sortMax > 0 { 	// todo dumb bubble sort
		for i: i32 = 0; i < sortMax; i += 1 {
			current := array_get(&ctx.layoutElementTreeRoots, i)^
			next := array_get(&ctx.layoutElementTreeRoots, i + 1)^
			if next.zIndex < current.zIndex {
				array_set(&ctx.layoutElementTreeRoots, i, next)
				array_set(&ctx.layoutElementTreeRoots, i + 1, current)
			}
		}
		sortMax -= 1
	}

	// Calculate final positions and generate render commands
	ctx.renderCommands.length = 0
	dfsBuffer.length = 0

	for rootIndex: i32 = 0; rootIndex < ctx.layoutElementTreeRoots.length; rootIndex += 1 {
		dfsBuffer.length = 0
		root := array_get(&ctx.layoutElementTreeRoots, rootIndex)
		rootElement := array_get(&ctx.layoutElements, root.layoutElementIndex)
		rootPosition := Vector2{}
		parentHashMapItem := get_hash_map_item(root.parentId)
		// Position root floating containers
		if rootElement.config.floating.attachTo != .None && parentHashMapItem != nil {
			config := &rootElement.config.floating
			rootDimensions := rootElement.dimensions
			parentBoundingBox := parentHashMapItem.boundingBox
			// Set X position
			targetAttachPosition := Vector2{}
			switch config.attachment.parent {
			case .LeftTop, .LeftCenter, .LeftBottom:
				targetAttachPosition.x = parentBoundingBox.x
			case .CenterTop, .CenterCenter, .CenterBottom:
				targetAttachPosition.x = parentBoundingBox.x + (parentBoundingBox.width / 2)
			case .RightTop, .RightCenter, .RightBottom:
				targetAttachPosition.x = parentBoundingBox.x + parentBoundingBox.width
			}
			switch config.attachment.element {
			case .LeftTop, .LeftCenter, .LeftBottom:
			case .CenterTop, .CenterCenter, .CenterBottom:
				targetAttachPosition.x -= (rootDimensions.width / 2)
			case .RightTop, .RightCenter, .RightBottom:
				targetAttachPosition.x -= rootDimensions.width
			}
			switch config.attachment.parent { 	// I know I could merge the x and y switch statements, but this is easier to read
			case .LeftTop, .RightTop, .CenterTop:
				targetAttachPosition.y = parentBoundingBox.y
			case .LeftCenter, .CenterCenter, .RightCenter:
				targetAttachPosition.y = parentBoundingBox.y + (parentBoundingBox.height / 2)
			case .LeftBottom, .CenterBottom, .RightBottom:
				targetAttachPosition.y = parentBoundingBox.y + parentBoundingBox.height
			}
			switch config.attachment.element {
			case .LeftTop, .RightTop, .CenterTop:
			case .LeftCenter, .CenterCenter, .RightCenter:
				targetAttachPosition.y -= (rootDimensions.height / 2)
			case .LeftBottom, .CenterBottom, .RightBottom:
				targetAttachPosition.y -= rootDimensions.height
			}
			targetAttachPosition.x += config.offset.x
			targetAttachPosition.y += config.offset.y
			rootPosition = targetAttachPosition
		}
		if root.clipElementId != 0 {
			clipHashMapItem := get_hash_map_item(root.clipElementId)
			if clipHashMapItem != nil && !element_is_offscreen(&clipHashMapItem.boundingBox) {
				if generateRenderCommands {
					add_render_command(
						RenderCommand {
							boundingBox = clipHashMapItem.boundingBox,
							userData    = nil,
							id          = hash_number(rootElement.id, u32(rootElement.children.length) + 10).id, // TODO need a better strategy for managing derived ids
							zIndex      = root.zIndex,
							commandType = .ScissorStart,
						},
					)
				}
			}
		}
		array_add(
			&dfsBuffer,
			Layout_Element_Tree_Node {
				layoutElement = rootElement,
				position = rootPosition,
				nextChildOffset = {
					f32(rootElement.config.layout.padding.left),
					f32(rootElement.config.layout.padding.top),
				},
			},
		)

		ctx.treeNodeVisited.internalArray[0] = false
		for dfsBuffer.length > 0 {
			currentElementTreeNode := array_get(&dfsBuffer, dfsBuffer.length - 1)
			currentElement := currentElementTreeNode.layoutElement
			layoutConfig :=
				currentElement.isTextElement ? default_of(LayoutConfig) : &currentElement.config.layout
			scrollOffset := Vector2{}

			// DFS is returning back upwards
			if ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
				if currentElement.isTextElement {
					dfsBuffer.length -= 1
					continue
				}
				currentElementData := get_hash_map_item(currentElement.id)
				if generateRenderCommands &&
				   !element_is_offscreen(&currentElementData.boundingBox) {
					// DFS is returning upwards backwards
					closeClipElement := false
					if currentElement.config.clip.horizontal ||
					   currentElement.config.clip.vertical {
						closeClipElement = true
						for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
							mapping := array_get(&ctx.scrollContainerDatas, i)
							if mapping.elementId == currentElement.id {
								scrollOffset = currentElement.config.clip.childOffset
								break
							}
						}
					}

					if border_has_any_width(&currentElement.config.border) {
						currentElementBoundingBox := currentElementData.boundingBox
						borderConfig := &currentElement.config.border
						renderCommand := RenderCommand {
							boundingBox = currentElementBoundingBox,
							renderData = {
								border = {
									color = borderConfig.color,
									cornerRadius = currentElement.config.cornerRadius,
									width = borderConfig.width,
								},
							},
							userData = currentElement.config.userData,
							id = hash_number(currentElement.id, u32(currentElement.children.length)).id,
							commandType = .Border,
						}
						add_render_command(renderCommand)
						if borderConfig.width.betweenChildren > 0 && borderConfig.color.a > 0 {
							// Integer divisions, as in clay
							halfGap := f32(i32(layoutConfig.childGap) / 2)
							halfWidth := f32(i32(borderConfig.width.betweenChildren) / 2)
							borderOffset := Vector2 {
								f32(layoutConfig.padding.left) - halfGap,
								f32(layoutConfig.padding.top) - halfGap,
							}
							if layoutConfig.layoutDirection == .LeftToRight {
								for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
									childElement := array_get(
										&ctx.layoutElements,
										currentElement.children.elements[i],
									)
									if i > 0 {
										add_render_command(
											RenderCommand {
												boundingBox = {
													currentElementBoundingBox.x +
													borderOffset.x +
													scrollOffset.x -
													halfWidth,
													currentElementBoundingBox.y + scrollOffset.y,
													f32(borderConfig.width.betweenChildren),
													currentElement.dimensions.height,
												},
												renderData = {
													rectangle = {
														backgroundColor = borderConfig.color,
													},
												},
												userData = currentElement.config.userData,
												id = hash_number(currentElement.id, u32(currentElement.children.length) + 1 + u32(i)).id,
												commandType = .Rectangle,
											},
										)
									}
									borderOffset.x +=
										(childElement.dimensions.width +
											f32(layoutConfig.childGap))
								}
							} else {
								for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
									childElement := array_get(
										&ctx.layoutElements,
										currentElement.children.elements[i],
									)
									if i > 0 {
										add_render_command(
											RenderCommand {
												boundingBox = {
													currentElementBoundingBox.x + scrollOffset.x,
													currentElementBoundingBox.y +
													borderOffset.y +
													scrollOffset.y -
													halfWidth,
													currentElement.dimensions.width,
													f32(borderConfig.width.betweenChildren),
												},
												renderData = {
													rectangle = {
														backgroundColor = borderConfig.color,
													},
												},
												userData = currentElement.config.userData,
												id = hash_number(currentElement.id, u32(currentElement.children.length) + 1 + u32(i)).id,
												commandType = .Rectangle,
											},
										)
									}
									borderOffset.y +=
										(childElement.dimensions.height +
											f32(layoutConfig.childGap))
								}
							}
						}
					}
					if currentElement.config.overlayColor.a > 0 {
						renderCommand := RenderCommand {
							userData    = currentElement.config.userData,
							id          = currentElement.id,
							zIndex      = root.zIndex,
							commandType = .OverlayColorEnd,
						}
						add_render_command(renderCommand)
					}
					// This exists because the scissor needs to end _after_ borders between elements
					if closeClipElement {
						add_render_command(
							RenderCommand {
								id = hash_number(currentElement.id, u32(rootElement.children.length) + 11).id,
								commandType = .ScissorEnd,
							},
						)
					}
				}

				dfsBuffer.length -= 1
				continue
			}

			// This will only be run a single time for each element in downwards DFS order
			ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true
			currentElementBoundingBox := BoundingBox {
				currentElementTreeNode.position.x,
				currentElementTreeNode.position.y,
				currentElement.dimensions.width,
				currentElement.dimensions.height,
			}
			scrollContainerData: ^Scroll_Container_Data_Internal = nil
			if !currentElement.isTextElement {
				if useStoredBoundingBoxes && currentElement.config.transition.handler != nil {
					found := false
					for j: i32 = 0; j < ctx.transitionDatas.length; j += 1 {
						transitionData := array_get(&ctx.transitionDatas, j)
						if transitionData.elementId == currentElement.id {
							found = true
							if transitionData.state != .Idle {
								if .X in
								   transitionData.activeProperties {currentElementBoundingBox.x = transitionData.currentState.boundingBox.x}
								if .Y in
								   transitionData.activeProperties {currentElementBoundingBox.y = transitionData.currentState.boundingBox.y}
								if .Width in
								   transitionData.activeProperties {currentElementBoundingBox.width = transitionData.currentState.boundingBox.width}
								if .Height in
								   transitionData.activeProperties {currentElementBoundingBox.height = transitionData.currentState.boundingBox.height}
							}
							break
						}
					}
					// An exiting element that completed its transition this frame - skip tree
					if !found && currentElement.config.transition.exit.setFinalState != nil {
						dfsBuffer.length -= 1
						continue
					}
				}
				if currentElement.config.floating.attachTo != .None {
					floatingElementConfig := &currentElement.config.floating
					expand := floatingElementConfig.expand
					currentElementBoundingBox.x -= expand.width
					currentElementBoundingBox.width += expand.width * 2
					currentElementBoundingBox.y -= expand.height
					currentElementBoundingBox.height += expand.height * 2
				}

				// Apply scroll offsets to container
				if currentElement.config.clip.horizontal || currentElement.config.clip.vertical {
					// This linear scan could theoretically be slow under very strange conditions, but I can't imagine a real UI with more than a few 10's of scroll containers
					for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
						mapping := array_get(&ctx.scrollContainerDatas, i)
						if mapping.elementId == currentElement.id {
							scrollContainerData = mapping
							mapping.boundingBox = currentElementBoundingBox
							scrollOffset = currentElement.config.clip.childOffset
							break
						}
					}
				}
			}

			offscreen := element_is_offscreen(&currentElementBoundingBox)

			// Generate render commands for current element
			if generateRenderCommands && !offscreen {
				if currentElement.isTextElement {
					textElementConfig := &currentElement.textConfig
					naturalLineHeight := currentElement.textElementData.preferredDimensions.height
					finalLineHeight :=
						textElementConfig.lineHeight > 0 ? f32(textElementConfig.lineHeight) : naturalLineHeight
					lineHeightOffset := (finalLineHeight - naturalLineHeight) / 2
					yPosition := lineHeightOffset
					for lineIndex: i32 = 0;
					    lineIndex < currentElement.textElementData.wrappedLines.length;
					    lineIndex += 1 {
						wrappedLine := slice_get(
							&currentElement.textElementData.wrappedLines,
							lineIndex,
						)
						if wrappedLine.line.length == 0 {
							yPosition += finalLineHeight
							continue
						}
						offset := (currentElementBoundingBox.width - wrappedLine.dimensions.width)
						if textElementConfig.textAlignment == .Left {
							offset = 0
						}
						if textElementConfig.textAlignment == .Center {
							offset /= 2
						}
						add_render_command(
							RenderCommand {
								boundingBox = {
									currentElementBoundingBox.x + offset,
									currentElementBoundingBox.y + yPosition,
									wrappedLine.dimensions.width,
									wrappedLine.dimensions.height,
								},
								renderData = {
									text = {
										stringContents = StringSlice {
											length = wrappedLine.line.length,
											chars = wrappedLine.line.chars,
											baseChars = currentElement.textElementData.text.chars,
										},
										textColor = textElementConfig.textColor,
										fontId = textElementConfig.fontId,
										fontSize = textElementConfig.fontSize,
										letterSpacing = textElementConfig.letterSpacing,
										lineHeight = textElementConfig.lineHeight,
									},
								},
								userData = textElementConfig.userData,
								id = hash_number(u32(lineIndex), currentElement.id).id,
								zIndex = root.zIndex,
								commandType = .Text,
							},
						)
						yPosition += finalLineHeight

						if !ctx.disableCulling &&
						   (currentElementBoundingBox.y + yPosition >
								   ctx.layoutDimensions.height) {
							break
						}
					}
				} else {
					if currentElement.config.overlayColor.a > 0 {
						renderCommand := RenderCommand {
							renderData = {
								overlayColor = {color = currentElement.config.overlayColor},
							},
							userData = currentElement.config.userData,
							id = currentElement.id,
							zIndex = root.zIndex,
							commandType = .OverlayColorStart,
						}
						add_render_command(renderCommand)
					}
					if currentElement.config.image.imageData != nil {
						renderCommand := RenderCommand {
							boundingBox = currentElementBoundingBox,
							renderData = {
								image = {
									backgroundColor = currentElement.config.backgroundColor,
									cornerRadius = currentElement.config.cornerRadius,
									imageData = currentElement.config.image.imageData,
								},
							},
							userData = currentElement.config.userData,
							id = currentElement.id,
							zIndex = root.zIndex,
							commandType = .Image,
						}
						add_render_command(renderCommand)
					}
					if currentElement.config.custom.customData != nil {
						renderCommand := RenderCommand {
							boundingBox = currentElementBoundingBox,
							renderData = {
								custom = {
									backgroundColor = currentElement.config.backgroundColor,
									cornerRadius = currentElement.config.cornerRadius,
									customData = currentElement.config.custom.customData,
								},
							},
							userData = currentElement.config.userData,
							id = currentElement.id,
							zIndex = root.zIndex,
							commandType = .Custom,
						}
						add_render_command(renderCommand)
					}
					if currentElement.config.clip.horizontal ||
					   currentElement.config.clip.vertical {
						renderCommand := RenderCommand {
							boundingBox = currentElementBoundingBox,
							renderData = {
								clip = {
									horizontal = currentElement.config.clip.horizontal,
									vertical = currentElement.config.clip.vertical,
								},
							},
							userData = currentElement.config.userData,
							id = currentElement.id,
							zIndex = root.zIndex,
							commandType = .ScissorStart,
						}
						add_render_command(renderCommand)
					}
					if currentElement.config.backgroundColor.a > 0 {
						renderCommand := RenderCommand {
							boundingBox = currentElementBoundingBox,
							renderData = {
								rectangle = {
									backgroundColor = currentElement.config.backgroundColor,
									cornerRadius = currentElement.config.cornerRadius,
								},
							},
							userData = currentElement.config.userData,
							id = currentElement.id,
							zIndex = root.zIndex,
							commandType = .Rectangle,
						}
						add_render_command(renderCommand)
					}
				}
			}

			hashMapItem := get_hash_map_item(currentElement.id)
			hashMapItem.boundingBox = currentElementBoundingBox

			if currentElement.isTextElement {continue}

			// Setup positions for child elements and add to DFS buffer ----------

			// On-axis alignment
			contentSizeCurrent := Dimensions{}
			if layoutConfig.layoutDirection == .LeftToRight {
				for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
					childElement := array_get(
						&ctx.layoutElements,
						currentElement.children.elements[i],
					)
					if childElement.exiting {continue}
					contentSizeCurrent.width += childElement.dimensions.width
					contentSizeCurrent.height = cmax(
						contentSizeCurrent.height,
						childElement.dimensions.height,
					)
				}
				contentSizeCurrent.width += f32(
					cmax(i32(currentElement.children.length) - 1, 0) * i32(layoutConfig.childGap),
				)
				extraSpace :=
					currentElement.dimensions.width -
					f32(i32(layoutConfig.padding.left) + i32(layoutConfig.padding.right)) -
					contentSizeCurrent.width
				#partial switch layoutConfig.childAlignment.x {
				case .Left:
					extraSpace = 0
				case .Center:
					extraSpace /= 2
				}
				extraSpace = cmax(f32(0), extraSpace)
				currentElementTreeNode.nextChildOffset.x += extraSpace
			} else if layoutConfig.layoutDirection == .TopToBottom {
				for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
					childElement := array_get(
						&ctx.layoutElements,
						currentElement.children.elements[i],
					)
					if childElement.exiting {continue}
					contentSizeCurrent.width = cmax(
						contentSizeCurrent.width,
						childElement.dimensions.width,
					)
					contentSizeCurrent.height += childElement.dimensions.height
				}
				contentSizeCurrent.height += f32(
					cmax(i32(currentElement.children.length) - 1, 0) * i32(layoutConfig.childGap),
				)
				extraSpace :=
					currentElement.dimensions.height -
					f32(i32(layoutConfig.padding.top) + i32(layoutConfig.padding.bottom)) -
					contentSizeCurrent.height
				#partial switch layoutConfig.childAlignment.y {
				case .Top:
					extraSpace = 0
				case .Center:
					extraSpace /= 2
				}
				extraSpace = cmax(f32(0), extraSpace)
				currentElementTreeNode.nextChildOffset.y += extraSpace
			}

			if scrollContainerData != nil {
				scrollContainerData.contentSize = Dimensions {
					contentSizeCurrent.width +
					f32(i32(layoutConfig.padding.left) + i32(layoutConfig.padding.right)),
					contentSizeCurrent.height +
					f32(i32(layoutConfig.padding.top) + i32(layoutConfig.padding.bottom)),
				}
			}

			// Add children to the DFS buffer
			dfsBuffer.length += i32(currentElement.children.length)
			for i: i32 = 0; i < i32(currentElement.children.length); i += 1 {
				childElement := array_get(&ctx.layoutElements, currentElement.children.elements[i])
				_ = get_hash_map_item(childElement.id) // clay's unused childMapItem lookup
				// Alignment along non layout axis
				if layoutConfig.layoutDirection == .LeftToRight {
					currentElementTreeNode.nextChildOffset.y = f32(
						currentElement.config.layout.padding.top,
					)
					whiteSpaceAroundChild :=
						currentElement.dimensions.height -
						f32(i32(layoutConfig.padding.top) + i32(layoutConfig.padding.bottom)) -
						childElement.dimensions.height
					switch layoutConfig.childAlignment.y {
					case .Top:
					case .Center:
						currentElementTreeNode.nextChildOffset.y += whiteSpaceAroundChild / 2
					case .Bottom:
						currentElementTreeNode.nextChildOffset.y += whiteSpaceAroundChild
					}
				} else {
					currentElementTreeNode.nextChildOffset.x = f32(
						currentElement.config.layout.padding.left,
					)
					whiteSpaceAroundChild :=
						currentElement.dimensions.width -
						f32(i32(layoutConfig.padding.left) + i32(layoutConfig.padding.right)) -
						childElement.dimensions.width
					switch layoutConfig.childAlignment.x {
					case .Left:
					case .Center:
						currentElementTreeNode.nextChildOffset.x += whiteSpaceAroundChild / 2
					case .Right:
						currentElementTreeNode.nextChildOffset.x += whiteSpaceAroundChild
					}
				}

				childPosition := Vector2 {
					currentElementBoundingBox.x +
					currentElementTreeNode.nextChildOffset.x +
					scrollOffset.x,
					currentElementBoundingBox.y +
					currentElementTreeNode.nextChildOffset.y +
					scrollOffset.y,
				}

				// DFS buffer elements need to be added in reverse because stack traversal happens backwards
				newNodeIndex := u32(dfsBuffer.length - 1 - i)
				// A text child reads its padding through the union's text payload bytes, as clay does
				dfsBuffer.internalArray[newNodeIndex] = Layout_Element_Tree_Node {
					layoutElement   = childElement,
					position        = Vector2{childPosition.x, childPosition.y},
					nextChildOffset = {
						f32(childElement.config.layout.padding.left),
						f32(childElement.config.layout.padding.top),
					},
				}
				ctx.treeNodeVisited.internalArray[newNodeIndex] = false

				// Update parent offsets
				if !childElement.exiting {
					if layoutConfig.layoutDirection == .LeftToRight {
						currentElementTreeNode.nextChildOffset.x +=
							childElement.dimensions.width + f32(layoutConfig.childGap)
					} else {
						currentElementTreeNode.nextChildOffset.y +=
							childElement.dimensions.height + f32(layoutConfig.childGap)
					}
				}
			}
		}

		if root.clipElementId != 0 {
			clipHashMapItem := get_hash_map_item(root.clipElementId)
			if clipHashMapItem != nil && !element_is_offscreen(&clipHashMapItem.boundingBox) {
				add_render_command(
					RenderCommand {
						id = hash_number(rootElement.id, u32(rootElement.children.length) + 11).id,
						commandType = .ScissorEnd,
					},
				)
			}
		}
	}
}
