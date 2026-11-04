package clay

// Element ids, text measurement cache, and opening/closing elements.

@(private)
hash_number :: proc(offset, seed: u32) -> ElementId {
	hash := seed
	hash += (offset + 48)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	hash ~= (hash >> 11)
	hash += (hash << 15)
	return ElementId{id = hash + 1, offset = offset, baseId = seed, stringId = {}} // Reserve the hash result of zero as "null id"
}

@(private)
hash_string :: proc(key: String, seed: u32) -> ElementId {
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
	return ElementId{id = hash + 1, offset = 0, baseId = hash + 1, stringId = key} // Reserve the hash result of zero as "null id"
}

@(private)
hash_string_with_offset :: proc(key: String, offset, seed: u32) -> ElementId {
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
	return ElementId{id = hash + 1, offset = offset, baseId = base + 1, stringId = key} // Reserve the hash result of zero as "null id"
}

// clay's x86-64 SSE variant, computed lane by lane: each [2]u64 is one __m128i.
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

	overflowBuffer: [16]u8 // Temporary buffer for small inputs

	for length > 0 {
		msg: [2]u64
		if length >= 16 {
			msg = {load_u64_le(data), load_u64_le(data[8:])}
			data = data[16:]
			length -= 16
		} else {
			for i: uint = 0; i < length; i += 1 {
				overflowBuffer[i] = data[i]
			}
			buf := ([^]u8)(&overflowBuffer[0])
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
hash_string_contents_with_config :: proc(text: ^String, config: ^TextElementConfig) -> u32 {
	hash: u32 = 0
	if text.isStaticallyAllocated {
		hash += u32(uintptr(text.chars))
		hash += (hash << 10)
		hash ~= (hash >> 6)
		hash += u32(text.length)
		hash += (hash << 10)
		hash ~= (hash >> 6)
	} else {
		hash = u32(hash_data(text.chars, uint(text.length)) % u64(max(u32)))
	}

	hash += u32(config.fontId)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += u32(config.fontSize)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += u32(config.letterSpacing)
	hash += (hash << 10)
	hash ~= (hash >> 6)

	hash += (hash << 3)
	hash ~= (hash >> 11)
	hash += (hash << 15)
	return hash + 1 // Reserve the hash result of zero as "null id"
}

@(private)
add_measured_word :: proc(word: Measured_Word, previousWord: ^Measured_Word) -> ^Measured_Word {
	ctx := current_context
	if ctx.measuredWordsFreeList.length > 0 {
		newItemIndex := u32(
			array_get_value(&ctx.measuredWordsFreeList, ctx.measuredWordsFreeList.length - 1),
		)
		ctx.measuredWordsFreeList.length -= 1
		array_set(&ctx.measuredWords, i32(newItemIndex), word)
		previousWord.next = i32(newItemIndex)
		return array_get(&ctx.measuredWords, i32(newItemIndex))
	} else {
		previousWord.next = ctx.measuredWords.length
		return array_add(&ctx.measuredWords, word)
	}
}

@(private)
SPACE_CHAR :: " "

@(private)
measure_text_cached :: proc(
	text: ^String,
	config: ^TextElementConfig,
) -> ^Measure_Text_Cache_Item {
	ctx := current_context
	if measure_text == nil {
		if !ctx.booleanWarnings.textMeasurementFunctionNotSet {
			ctx.booleanWarnings.textMeasurementFunctionNotSet = true
			report_error(
				.TextMeasurementFunctionNotProvided,
				"Clay's internal MeasureText function is null. You may have forgotten to call Clay_SetMeasureTextFunction(), or passed a NULL function pointer by mistake.",
			)
		}
		return default_of(Measure_Text_Cache_Item)
	}
	id := hash_string_contents_with_config(text, config)
	hashBucket := id % u32(ctx.maxMeasureTextCacheWordCount / 32)
	elementIndexPrevious: i32 = 0
	elementIndex := ctx.measureTextHashMap.internalArray[hashBucket]
	for elementIndex != 0 {
		hashEntry := array_get(&ctx.measureTextHashMapInternal, elementIndex)
		if hashEntry.id == id {
			hashEntry.generation = ctx.generation
			return hashEntry
		}
		// This element hasn't been seen in a few frames, delete the hash map item
		if ctx.generation - hashEntry.generation > 2 {
			// Add all the measured words that were included in this measurement to the freelist
			nextWordIndex := hashEntry.measuredWordsStartIndex
			for nextWordIndex != -1 {
				measuredWord := array_get(&ctx.measuredWords, nextWordIndex)
				array_add(&ctx.measuredWordsFreeList, nextWordIndex)
				nextWordIndex = measuredWord.next
			}

			nextIndex := hashEntry.nextIndex
			array_set(
				&ctx.measureTextHashMapInternal,
				elementIndex,
				Measure_Text_Cache_Item{measuredWordsStartIndex = -1},
			)
			array_add(&ctx.measureTextHashMapInternalFreeList, elementIndex)
			if elementIndexPrevious == 0 {
				ctx.measureTextHashMap.internalArray[hashBucket] = nextIndex
			} else {
				previousHashEntry := array_get(
					&ctx.measureTextHashMapInternal,
					elementIndexPrevious,
				)
				previousHashEntry.nextIndex = nextIndex
			}
			elementIndex = nextIndex
		} else {
			elementIndexPrevious = elementIndex
			elementIndex = hashEntry.nextIndex
		}
	}

	newItemIndex: i32 = 0
	newCacheItem := Measure_Text_Cache_Item {
		measuredWordsStartIndex = -1,
		id                      = id,
		generation              = ctx.generation,
	}
	measured: ^Measure_Text_Cache_Item = nil
	if ctx.measureTextHashMapInternalFreeList.length > 0 {
		newItemIndex = array_get_value(
			&ctx.measureTextHashMapInternalFreeList,
			ctx.measureTextHashMapInternalFreeList.length - 1,
		)
		ctx.measureTextHashMapInternalFreeList.length -= 1
		array_set(&ctx.measureTextHashMapInternal, newItemIndex, newCacheItem)
		measured = array_get(&ctx.measureTextHashMapInternal, newItemIndex)
	} else {
		if ctx.measureTextHashMapInternal.length == ctx.measureTextHashMapInternal.capacity - 1 {
			if !ctx.booleanWarnings.maxTextMeasureCacheExceeded {
				report_error(
					.ElementsCapacityExceeded,
					"Clay ran out of capacity while attempting to measure text elements. Try using Clay_SetMaxElementCount() with a higher value.",
				)
				ctx.booleanWarnings.maxTextMeasureCacheExceeded = true
			}
			return default_of(Measure_Text_Cache_Item)
		}
		measured = array_add(&ctx.measureTextHashMapInternal, newCacheItem)
		newItemIndex = ctx.measureTextHashMapInternal.length - 1
	}

	start: i32 = 0
	end: i32 = 0
	lineWidth: f32 = 0
	measuredWidth: f32 = 0
	measuredHeight: f32 = 0
	spaceChars := raw_data(string(SPACE_CHAR))
	spaceWidth :=
		measure_text(StringSlice{length = 1, chars = spaceChars, baseChars = spaceChars}, config, ctx.measureTextUserData).width
	tempWord := Measured_Word {
		next = -1,
	}
	previousWord := &tempWord
	for end < text.length {
		if ctx.measuredWords.length == ctx.measuredWords.capacity - 1 {
			if !ctx.booleanWarnings.maxTextMeasureCacheExceeded {
				report_error(
					.TextMeasurementCapacityExceeded,
					"Clay has run out of space in it's internal text measurement cache. Try using Clay_SetMaxMeasureTextCacheWordCount() (default 16384, with 1 unit storing 1 measured word).",
				)
				ctx.booleanWarnings.maxTextMeasureCacheExceeded = true
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
				StringSlice{length = length, chars = &text.chars[start], baseChars = text.chars},
				config,
				ctx.measureTextUserData,
			)
			measured.minWidth = cmax(dimensions.width, measured.minWidth)
			measuredHeight = cmax(measuredHeight, dimensions.height)
			previousWord = add_measured_word(
				Measured_Word {
					startOffset = start,
					length = length,
					width = dimensions.width,
					next = -1,
				},
				previousWord,
			)
			lineWidth += dimensions.width
			start = end + 3
			end = start
			continue
		}
		if current == ' ' || current == '\n' {
			length := end - start
			dimensions := Dimensions{}
			if length > 0 {
				dimensions = measure_text(
					StringSlice {
						length = length,
						chars = &text.chars[start],
						baseChars = text.chars,
					},
					config,
					ctx.measureTextUserData,
				)
			}
			measured.minWidth = cmax(dimensions.width, measured.minWidth)
			measuredHeight = cmax(measuredHeight, dimensions.height)
			if current == ' ' {
				dimensions.width += spaceWidth
				previousWord = add_measured_word(
					Measured_Word {
						startOffset = start,
						length = length + 1,
						width = dimensions.width,
						next = -1,
					},
					previousWord,
				)
				lineWidth += dimensions.width
			}
			if current == '\n' {
				if length > 0 {
					previousWord = add_measured_word(
						Measured_Word {
							startOffset = start,
							length = length,
							width = dimensions.width,
							next = -1,
						},
						previousWord,
					)
				}
				previousWord = add_measured_word(
					Measured_Word{startOffset = end + 1, length = 0, width = 0, next = -1},
					previousWord,
				)
				lineWidth += dimensions.width
				measuredWidth = cmax(lineWidth, measuredWidth)
				measured.containsNewlines = true
				lineWidth = 0
			}
			start = end + 1
		}
		end += 1
	}
	if end - start > 0 {
		dimensions := measure_text(
			StringSlice{length = end - start, chars = &text.chars[start], baseChars = text.chars},
			config,
			ctx.measureTextUserData,
		)
		add_measured_word(
			Measured_Word {
				startOffset = start,
				length = end - start,
				width = dimensions.width,
				next = -1,
			},
			previousWord,
		)
		lineWidth += dimensions.width
		measuredHeight = cmax(measuredHeight, dimensions.height)
		measured.minWidth = cmax(dimensions.width, measured.minWidth)
	}
	measuredWidth = cmax(lineWidth, measuredWidth) - f32(config.letterSpacing)

	measured.measuredWordsStartIndex = tempWord.next
	measured.unwrappedDimensions.width = measuredWidth
	measured.unwrappedDimensions.height = measuredHeight

	if elementIndexPrevious != 0 {
		array_get(&ctx.measureTextHashMapInternal, elementIndexPrevious).nextIndex = newItemIndex
	} else {
		ctx.measureTextHashMap.internalArray[hashBucket] = newItemIndex
	}
	return measured
}

@(private)
point_is_inside_rect :: proc(point: Vector2, rect: BoundingBox) -> bool {
	return(
		point.x >= rect.x &&
		point.x <= rect.x + rect.width &&
		point.y >= rect.y &&
		point.y <= rect.y + rect.height \
	)
}

@(private)
add_hash_map_item :: proc(
	elementId: ElementId,
	layoutElement: ^Layout_Element,
) -> ^Layout_Element_Hash_Map_Item {
	ctx := current_context
	item := Layout_Element_Hash_Map_Item {
		elementId         = elementId,
		layoutElement     = layoutElement,
		nextIndex         = -1,
		generation        = ctx.generation + 1,
		appearedThisFrame = true,
	}
	hashBucket := elementId.id % u32(ctx.layoutElementsHashMap.capacity)
	hashItemPrevious: i32 = -1
	hashItemIndex := ctx.layoutElementsHashMap.internalArray[hashBucket]
	for hashItemIndex != -1 { 	// Just replace collision, not a big deal - leave it up to the end user
		hashItem := array_get(&ctx.layoutElementsHashMapInternal, hashItemIndex)
		if hashItem.elementId.id == elementId.id { 	// Collision - resolve based on generation
			item.nextIndex = hashItem.nextIndex
			if hashItem.generation <= ctx.generation { 	// First collision - assume this is the "same" element
				hashItem.appearedThisFrame = hashItem.generation < ctx.generation
				hashItem.elementId = elementId // If the stringId reference has changed, update the hash item to use the new one.
				hashItem.generation = ctx.generation + 1
				hashItem.layoutElement = layoutElement
				hashItem.onHoverFunction = nil
				hashItem.hoverFunctionUserData = nil
			} else { 	// Multiple collisions this frame - two elements have the same ID
				report_error(
					.DuplicateId,
					"An element with this ID was already previously declared during this layout.",
				)
			}
			return hashItem
		}
		hashItemPrevious = hashItemIndex
		hashItemIndex = hashItem.nextIndex
	}

	indexToUse: i32 = 0
	if ctx.layoutElementsHashMapFreeList.length > 0 {
		indexToUse = array_get_value(
			&ctx.layoutElementsHashMapFreeList,
			ctx.layoutElementsHashMapFreeList.length - 1,
		)
		ctx.layoutElementsHashMapFreeList.length -= 1
	} else {
		if ctx.layoutElementsHashMapInternal.length >=
		   ctx.layoutElementsHashMapInternal.capacity - 1 {
			if !ctx.booleanWarnings.hashMapCapacityExceeded {
				report_error(
					.HashMapCapacityExceeded,
					"Clay has run out of space in it's internal element ID hashmap.  Try using Clay_SetMaxElementCount() with a higher value.",
				)
				ctx.booleanWarnings.hashMapCapacityExceeded = true
			}
			return nil
		}
		indexToUse = ctx.layoutElementsHashMapInternal.length
	}
	hashItem := array_set(&ctx.layoutElementsHashMapInternal, indexToUse, item)
	if hashItemPrevious != -1 {
		array_get(&ctx.layoutElementsHashMapInternal, hashItemPrevious).nextIndex = indexToUse
	} else {
		ctx.layoutElementsHashMap.internalArray[hashBucket] = indexToUse
	}
	return hashItem
}

@(private)
get_hash_map_item :: proc(id: u32) -> ^Layout_Element_Hash_Map_Item {
	ctx := current_context
	hashBucket := id % u32(ctx.layoutElementsHashMap.capacity)
	elementIndex := ctx.layoutElementsHashMap.internalArray[hashBucket]
	for elementIndex != -1 {
		hashEntry := array_get(&ctx.layoutElementsHashMapInternal, elementIndex)
		if hashEntry.elementId.id == id {
			return hashEntry
		}
		elementIndex = hashEntry.nextIndex
	}
	return default_of(Layout_Element_Hash_Map_Item)
}

@(private)
update_aspect_ratio_box :: proc(layoutElement: ^Layout_Element) {
	if layoutElement.config.aspectRatio.aspectRatio != 0 {
		if layoutElement.dimensions.width == 0 && layoutElement.dimensions.height != 0 {
			layoutElement.dimensions.width =
				layoutElement.dimensions.height * layoutElement.config.aspectRatio.aspectRatio
		} else if layoutElement.dimensions.width != 0 && layoutElement.dimensions.height == 0 {
			layoutElement.dimensions.height =
				layoutElement.dimensions.width * (1 / layoutElement.config.aspectRatio.aspectRatio)
		}
	}
}

@(private)
close_element :: proc() {
	ctx := current_context
	if ctx.booleanWarnings.maxElementsExceeded {
		return
	}
	openLayoutElement := get_open_layout_element()
	layoutConfig := &openLayoutElement.config.layout
	elementHasClipHorizontal := openLayoutElement.config.clip.horizontal
	elementHasClipVertical := openLayoutElement.config.clip.vertical
	if elementHasClipHorizontal ||
	   elementHasClipVertical ||
	   openLayoutElement.config.floating.attachTo != .None {
		ctx.openClipElementStack.length -= 1
	}

	leftRightPadding := f32(i32(layoutConfig.padding.left) + i32(layoutConfig.padding.right))
	topBottomPadding := f32(i32(layoutConfig.padding.top) + i32(layoutConfig.padding.bottom))

	// Attach children to the current open element
	openLayoutElement.children.elements = &ctx.layoutElementChildren.internalArray[ctx.layoutElementChildren.length]
	if layoutConfig.layoutDirection == .LeftToRight {
		openLayoutElement.dimensions.width = leftRightPadding
		openLayoutElement.minDimensions.width = leftRightPadding
		for i: i32 = 0; i < i32(openLayoutElement.children.length); i += 1 {
			childIndex := array_get_value(
				&ctx.layoutElementChildrenBuffer,
				ctx.layoutElementChildrenBuffer.length -
				i32(openLayoutElement.children.length) +
				i,
			)
			child := array_get(&ctx.layoutElements, childIndex)
			openLayoutElement.dimensions.width += child.dimensions.width
			openLayoutElement.dimensions.height = cmax(
				openLayoutElement.dimensions.height,
				child.dimensions.height + topBottomPadding,
			)
			// Minimum size of child elements doesn't matter to clip containers as they can shrink and hide their contents
			if !elementHasClipHorizontal {
				openLayoutElement.minDimensions.width += child.minDimensions.width
			}
			if !elementHasClipVertical {
				openLayoutElement.minDimensions.height = cmax(
					openLayoutElement.minDimensions.height,
					child.minDimensions.height + topBottomPadding,
				)
			}
			array_add(&ctx.layoutElementChildren, childIndex)
		}
		childGap := f32(
			cmax(i32(openLayoutElement.children.length) - 1, 0) * i32(layoutConfig.childGap),
		)
		openLayoutElement.dimensions.width += childGap
		if !elementHasClipHorizontal {
			openLayoutElement.minDimensions.width += childGap
		}
	} else if layoutConfig.layoutDirection == .TopToBottom {
		openLayoutElement.dimensions.height = topBottomPadding
		openLayoutElement.minDimensions.height = topBottomPadding
		for i: i32 = 0; i < i32(openLayoutElement.children.length); i += 1 {
			childIndex := array_get_value(
				&ctx.layoutElementChildrenBuffer,
				ctx.layoutElementChildrenBuffer.length -
				i32(openLayoutElement.children.length) +
				i,
			)
			child := array_get(&ctx.layoutElements, childIndex)
			openLayoutElement.dimensions.height += child.dimensions.height
			openLayoutElement.dimensions.width = cmax(
				openLayoutElement.dimensions.width,
				child.dimensions.width + leftRightPadding,
			)
			// Minimum size of child elements doesn't matter to clip containers as they can shrink and hide their contents
			if !elementHasClipVertical {
				openLayoutElement.minDimensions.height += child.minDimensions.height
			}
			if !elementHasClipHorizontal {
				openLayoutElement.minDimensions.width = cmax(
					openLayoutElement.minDimensions.width,
					child.minDimensions.width + leftRightPadding,
				)
			}
			array_add(&ctx.layoutElementChildren, childIndex)
		}
		childGap := f32(
			cmax(i32(openLayoutElement.children.length) - 1, 0) * i32(layoutConfig.childGap),
		)
		openLayoutElement.dimensions.height += childGap
		if !elementHasClipVertical {
			openLayoutElement.minDimensions.height += childGap
		}
	}

	ctx.layoutElementChildrenBuffer.length -= i32(openLayoutElement.children.length)

	// Clamp element min and max width to the values configured in the layout
	if layoutConfig.sizing.width.type != .Percent {
		if layoutConfig.sizing.width.constraints.sizeMinMax.max <= 0 { 	// Set the max size if the user didn't specify, makes calculations easier
			layoutConfig.sizing.width.constraints.sizeMinMax.max = MAX_FLOAT
		}
		openLayoutElement.dimensions.width = cmin(
			cmax(
				openLayoutElement.dimensions.width,
				layoutConfig.sizing.width.constraints.sizeMinMax.min,
			),
			layoutConfig.sizing.width.constraints.sizeMinMax.max,
		)
		openLayoutElement.minDimensions.width = cmin(
			cmax(
				openLayoutElement.minDimensions.width,
				layoutConfig.sizing.width.constraints.sizeMinMax.min,
			),
			layoutConfig.sizing.width.constraints.sizeMinMax.max,
		)
	} else {
		openLayoutElement.dimensions.width = 0
	}

	// Clamp element min and max height to the values configured in the layout
	if layoutConfig.sizing.height.type != .Percent {
		if layoutConfig.sizing.height.constraints.sizeMinMax.max <= 0 { 	// Set the max size if the user didn't specify, makes calculations easier
			layoutConfig.sizing.height.constraints.sizeMinMax.max = MAX_FLOAT
		}
		openLayoutElement.dimensions.height = cmin(
			cmax(
				openLayoutElement.dimensions.height,
				layoutConfig.sizing.height.constraints.sizeMinMax.min,
			),
			layoutConfig.sizing.height.constraints.sizeMinMax.max,
		)
		openLayoutElement.minDimensions.height = cmin(
			cmax(
				openLayoutElement.minDimensions.height,
				layoutConfig.sizing.height.constraints.sizeMinMax.min,
			),
			layoutConfig.sizing.height.constraints.sizeMinMax.max,
		)
	} else {
		openLayoutElement.dimensions.height = 0
	}

	update_aspect_ratio_box(openLayoutElement)

	elementIsFloating := openLayoutElement.config.floating.attachTo != .None

	// Close the currently open element
	closingElementIndex := array_remove_swapback(
		&ctx.openLayoutElementStack,
		ctx.openLayoutElementStack.length - 1,
	)

	// Get the currently open parent
	openLayoutElement = get_open_layout_element()

	if ctx.openLayoutElementStack.length > 1 {
		if elementIsFloating {
			openLayoutElement.floatingChildrenCount += 1
			return
		}
		openLayoutElement.children.length += 1
		array_add(&ctx.layoutElementChildrenBuffer, closingElementIndex)
	}
}

@(private)
open_element :: proc() {
	ctx := current_context
	if ctx.layoutElements.length == ctx.layoutElements.capacity - 1 ||
	   ctx.booleanWarnings.maxElementsExceeded {
		ctx.booleanWarnings.maxElementsExceeded = true
		return
	}
	layoutElement := Layout_Element{}
	openLayoutElement := array_add(&ctx.layoutElements, layoutElement)
	array_add(&ctx.openLayoutElementStack, ctx.layoutElements.length - 1)
	// Generate an ID
	parentElement := array_get(
		&ctx.layoutElements,
		array_get_value(&ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2),
	)
	offset := u32(parentElement.children.length) + u32(parentElement.floatingChildrenCount)
	elementId := hash_number(offset, parentElement.id)
	openLayoutElement.id = elementId.id
	add_hash_map_item(elementId, openLayoutElement)
	if ctx.openClipElementStack.length > 0 {
		array_set(
			&ctx.layoutElementClipElementIds,
			ctx.layoutElements.length - 1,
			array_get_value(&ctx.openClipElementStack, ctx.openClipElementStack.length - 1),
		)
	} else {
		array_set(&ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, 0)
	}
}

@(private)
open_element_with_id :: proc(elementId: ElementId) {
	ctx := current_context
	if ctx.layoutElements.length == ctx.layoutElements.capacity - 1 ||
	   ctx.booleanWarnings.maxElementsExceeded {
		ctx.booleanWarnings.maxElementsExceeded = true
		return
	}
	layoutElement := Layout_Element{}
	layoutElement.id = elementId.id
	openLayoutElement := array_add(&ctx.layoutElements, layoutElement)
	array_add(&ctx.openLayoutElementStack, ctx.layoutElements.length - 1)
	add_hash_map_item(elementId, openLayoutElement)
	if ctx.openClipElementStack.length > 0 {
		array_set(
			&ctx.layoutElementClipElementIds,
			ctx.layoutElements.length - 1,
			array_get_value(&ctx.openClipElementStack, ctx.openClipElementStack.length - 1),
		)
	} else {
		array_set(&ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, 0)
	}
}

@(private)
open_text_element :: proc(text: String, textConfig: TextElementConfig) {
	text := text
	textConfig := textConfig
	ctx := current_context
	if ctx.layoutElements.length == ctx.layoutElements.capacity - 1 ||
	   ctx.booleanWarnings.maxElementsExceeded {
		ctx.booleanWarnings.maxElementsExceeded = true
		return
	}
	parentElement := get_open_layout_element()

	layoutElement := Layout_Element{}
	layoutElement.textConfig = textConfig
	layoutElement.isTextElement = true
	textElement := array_add(&ctx.layoutElements, layoutElement)
	if ctx.openClipElementStack.length > 0 {
		array_set(
			&ctx.layoutElementClipElementIds,
			ctx.layoutElements.length - 1,
			array_get_value(&ctx.openClipElementStack, ctx.openClipElementStack.length - 1),
		)
	} else {
		array_set(&ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, 0)
	}

	array_add(&ctx.layoutElementChildrenBuffer, ctx.layoutElements.length - 1)
	textMeasured := measure_text_cached(&text, &textConfig)
	elementId := hash_number(
		u32(parentElement.children.length) + u32(parentElement.floatingChildrenCount),
		parentElement.id,
	)
	textElement.id = elementId.id
	add_hash_map_item(elementId, textElement)
	textDimensions := Dimensions {
		width  = textMeasured.unwrappedDimensions.width,
		height = textConfig.lineHeight > 0 ? f32(textConfig.lineHeight) : textMeasured.unwrappedDimensions.height,
	}
	textElement.dimensions = textDimensions
	textElement.minDimensions = Dimensions {
		width  = textMeasured.minWidth,
		height = textDimensions.height,
	}
	textElement.textElementData = Text_Element_Data {
		text                = text,
		preferredDimensions = textMeasured.unwrappedDimensions,
	}
	parentElement.children.length += 1
}

@(private)
configure_open_element_ptr :: proc(declaration: ^ElementDeclaration) {
	ctx := current_context
	openLayoutElement := get_open_layout_element()
	openLayoutElement.config = declaration^
	if (declaration.layout.sizing.width.type == .Percent &&
		   declaration.layout.sizing.width.constraints.sizePercent > 1) ||
	   (declaration.layout.sizing.height.type == .Percent &&
			   declaration.layout.sizing.height.constraints.sizePercent > 1) {
		report_error(
			.PercentageOver1,
			"An element was configured with CLAY_SIZING_PERCENT, but the provided percentage value was over 1.0. Clay expects a value between 0 and 1, i.e. 20% is 0.2.",
		)
	}

	if declaration.floating.attachTo != .None {
		floatingConfig := &openLayoutElement.config.floating
		// This looks dodgy but because of the auto generated root element the depth of the tree will always be at least 2 here
		hierarchicalParent := array_get(
			&ctx.layoutElements,
			array_get_value(&ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2),
		)
		if hierarchicalParent != nil {
			clipElementId: u32 = 0
			if declaration.floating.attachTo == .Parent {
				// Attach to the element's direct hierarchical parent
				floatingConfig.parentId = hierarchicalParent.id
				if ctx.openClipElementStack.length > 0 {
					clipElementId = u32(
						array_get_value(
							&ctx.openClipElementStack,
							ctx.openClipElementStack.length - 1,
						),
					)
				}
			} else if declaration.floating.attachTo == .ElementWithId {
				parentItem := get_hash_map_item(floatingConfig.parentId)
				if parentItem == default_of(Layout_Element_Hash_Map_Item) {
					report_error(
						.FloatingContainerParentNotFound,
						"A floating element was declared with a parentId, but no element with that ID was found.",
					)
				} else {
					clipElementId = u32(
						array_get_value(
							&ctx.layoutElementClipElementIds,
							i32(
								(uintptr(parentItem.layoutElement) -
									uintptr(ctx.layoutElements.internalArray)) /
								size_of(Layout_Element),
							),
						),
					)
				}
			} else if declaration.floating.attachTo == .Root {
				floatingConfig.parentId = hash_string(static_string(ROOT_CONTAINER), 0).id
			}
			if declaration.floating.clipTo == .None {
				clipElementId = 0
			}
			// A float attached to its parent without a z of its own draws in
			// the layer of the innermost open float, not at z 0, which would
			// sort it under that float (a text caret in a floating picker).
			if declaration.floating.attachTo == .Parent && floatingConfig.zIndex == 0 {
				found := false
				for r := ctx.layoutElementTreeRoots.length - 1; r >= 0 && !found; r -= 1 {
					root := array_get(&ctx.layoutElementTreeRoots, r)
					for s: i32 = 0; s < ctx.openLayoutElementStack.length - 1; s += 1 {
						if array_get_value(&ctx.openLayoutElementStack, s) ==
						   root.layoutElementIndex {
							floatingConfig.zIndex = root.zIndex
							found = true
							break
						}
					}
				}
			}
			currentElementIndex := array_get_value(
				&ctx.openLayoutElementStack,
				ctx.openLayoutElementStack.length - 1,
			)
			array_set(&ctx.layoutElementClipElementIds, currentElementIndex, i32(clipElementId))
			array_add(&ctx.openClipElementStack, i32(clipElementId))
			array_add(
				&ctx.layoutElementTreeRoots,
				Layout_Element_Tree_Root {
					layoutElementIndex = array_get_value(
						&ctx.openLayoutElementStack,
						ctx.openLayoutElementStack.length - 1,
					),
					parentId = floatingConfig.parentId,
					clipElementId = clipElementId,
					zIndex = floatingConfig.zIndex,
				},
			)
		}
	}

	if declaration.clip.horizontal || declaration.clip.vertical {
		array_add(&ctx.openClipElementStack, i32(openLayoutElement.id))
		// Retrieve or create cached data to track scroll position across frames
		scrollOffset: ^Scroll_Container_Data_Internal = nil
		for i: i32 = 0; i < ctx.scrollContainerDatas.length; i += 1 {
			mapping := array_get(&ctx.scrollContainerDatas, i)
			if openLayoutElement.id == mapping.elementId {
				scrollOffset = mapping
				scrollOffset.layoutElement = openLayoutElement
				scrollOffset.openThisFrame = true
			}
		}
		if scrollOffset == nil {
			scrollOffset = array_add(
				&ctx.scrollContainerDatas,
				Scroll_Container_Data_Internal {
					layoutElement = openLayoutElement,
					scrollOrigin = {-1, -1},
					elementId = openLayoutElement.id,
					openThisFrame = true,
				},
			)
		}
	}
	// Setup data to track transitions across frames
	if declaration.transition.handler != nil {
		transitionData: ^Transition_Data_Internal = nil
		parentElement := get_parent_element()
		for i: i32 = 0; i < ctx.transitionDatas.length; i += 1 {
			existingData := array_get(&ctx.transitionDatas, i)
			if openLayoutElement.id == existingData.elementId {
				if existingData.state == .Exiting {
					existingData.state = .Idle
					hashMapItem := get_hash_map_item(openLayoutElement.id)
					hashMapItem.appearedThisFrame = false
				}
				transitionData = existingData
				transitionData.elementThisFrame = openLayoutElement
				if transitionData.parentId != parentElement.id {
					transitionData.reparented = true
				}
				transitionData.parentId = parentElement.id
				transitionData.siblingIndex = u32(parentElement.children.length)
				transitionData.transitionOut = declaration.transition.exit.setFinalState != nil
			}
		}
		if transitionData == nil {
			transitionData = array_add(
				&ctx.transitionDatas,
				Transition_Data_Internal {
					elementThisFrame = openLayoutElement,
					elementId = openLayoutElement.id,
					parentId = parentElement.id,
					siblingIndex = u32(parentElement.children.length),
					transitionOut = declaration.transition.exit.setFinalState != nil,
				},
			)
		}
	}
}
