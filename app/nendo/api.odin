package nendo

// Declaration sugar:
//
//   if nendo.box(nendo.id("Row"))({direction = .Column, ...}) {
//       ...children
//   }
//
// box opens the element and returns the configure proc; the deferred
// close_element runs when the caller's `if` block ends.

@(private)
configure :: proc(declaration: Box) -> bool {
	declaration := declaration
	if scroll_enabled(&declaration.clip) {
		declaration.clip.offset = get_scroll_offset()
	}
	configure_open_element_ptr(&declaration)
	return true
}

@(deferred_none = close_element)
box_with_id :: proc(id: Id) -> proc(declaration: Box) -> bool {
	open_element_with_id(id)
	return configure
}

@(deferred_none = close_element)
box_auto :: proc() -> proc(declaration: Box) -> bool {
	open_element()
	return configure
}

box :: proc {
	box_with_id,
	box_auto,
}

Virtual_Range :: struct {
	first, end: int,
	remaining:  f32,
}

// Declare the final run in a top-aligned column. Build one row per index in first..<end.
virtual_rows :: proc {
	virtual_rows_fixed,
	virtual_rows_offsets,
}

@(private, deferred_out = finish_virtual_rows)
virtual_rows_fixed :: proc(id: Id, count: int, row_height: f32, gap: u16 = 0) -> Virtual_Range {
	stride := row_height + f32(gap)
	height := cmax(f32(0), f32(count) * stride - f32(gap))
	top, bottom := virtual_window(height)
	if bottom < 0 || top > height || top > bottom {
		open_virtual_run(id, 0, 0, gap)
		return {remaining = height}
	}
	first := clamp(int(top / stride) - 1, 0, count)
	end := clamp(int(bottom / stride) + 2, first, count)
	open_virtual_run(id, first, f32(first) * stride, gap)
	return {first, end, cmax(f32(0), f32(count - end) * stride - f32(gap))}
}

// Offsets start at zero and end at the sum of row heights, without gaps.
@(private, deferred_out = finish_virtual_rows)
virtual_rows_offsets :: proc(
	id: Id,
	offsets: []f32,
	gap: u16 = 0,
	overscan: f32 = 0,
) -> Virtual_Range {
	count := max(0, len(offsets) - 1)
	if count == 0 {
		virtual_window(0)
		open_virtual_run(id, 0, 0, gap)
		return {}
	}
	space := f32(gap)
	height := offsets[count] + f32(count - 1) * space
	top, bottom := virtual_window(height)
	top -= overscan
	bottom += overscan
	if bottom < 0 || top > height || top > bottom {
		open_virtual_run(id, 0, 0, gap)
		return {remaining = height}
	}
	// Shift the top by one gap to search row ends using the same edges.
	first := clamp(virtual_lower_bound(offsets, space, top + space) - 2, 0, count)
	end := clamp(virtual_lower_bound(offsets, space, bottom) + 1, first, count)
	open_virtual_run(id, first, offsets[first] + f32(first) * space, gap)
	tail := end < count ? offsets[count] - offsets[end] + f32(count - end - 1) * space : 0
	return {first, end, tail}
}

@(private)
virtual_lower_bound :: proc(offsets: []f32, gap, y: f32) -> int {
	lo, hi := 0, len(offsets)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if offsets[mid] + f32(mid) * gap < y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
virtual_window :: proc(height: f32) -> (top, bottom: f32) {
	ctx := active_context
	owner := get_open_layout_element()
	limit := ctx.layout_dimensions.height
	if owner.config.height.max > 0 {
		limit = cmin(limit, owner.config.height.max)
	}
	bottom = limit
	clip := &owner.config.clip
	inherited_clip := false
	// A bounded picker keeps its own small window for keyboard reveal.
	if !scroll_enabled(clip) ||
	   owner.config.height.max <= 0 ||
	   owner.config.height.max > ctx.layout_dimensions.height {
		top, bottom, inherited_clip = virtual_ancestor_window(owner)
		bottom = cmin(bottom, cmax(f32(0), top) + limit)
	}
	prefix := flow_prefix_y(owner, ctx.layout_element_children_buffer.length)
	if view := scroll_enabled(clip) ? find_scroll_data(owner.id) : nil; view != nil {
		viewport := view.bounding_box.height
		if owner.config.height.kind == .Fixed {
			viewport = owner.config.height.min
		} else if !inherited_clip {
			viewport = cmin(viewport, limit)
		} else if owner.config.height.max > 0 {
			viewport = cmin(viewport, owner.config.height.max)
		}
		content := prefix + height + f32(owner.config.padding.bottom)
		offset := clamp(-view.scroll_position.y, 0, cmax(f32(0), content - viewport))
		view.scroll_position.y = -offset
		clip.offset.y = -offset
	}
	if clip.y {top = cmax(f32(0), top)}
	if clip.x || clip.y {prefix += clip.offset.y}
	return top - prefix, bottom - prefix
}

@(private)
open_virtual_run :: proc(id: Id, skipped: int, prefix: f32, gap: u16) {
	open_element_with_id(id)
	configure(Box{width = grow(), direction = .Column, gap = gap})
	if skipped > 0 {
		if box(id_local("VirtualBefore"))({height = fixed(prefix - f32(gap))}) {}
	}
}

@(private)
flow_prefix_y :: proc(parent: ^Layout_Element, children_end: i32) -> (y: f32) {
	y = f32(parent.config.padding.top)
	if parent.config.direction != .Column {return}
	ctx := active_context
	siblings := i32(parent.children.length)
	height_sum := parent.virtual_prefix_height
	// An open column only appends completed children. Reuse the prefix for later runs.
	for i in children_end - siblings + parent.virtual_prefix_count ..< children_end {
		child := array_get(
			&ctx.layout_elements,
			array_get_value(&ctx.layout_element_children_buffer, i),
		)
		height := child.dimensions.height
		// Keep fixed children at their current heights. Only estimate the reflow.
		if child.height_reflows {
			prior := get_hash_map_item(child.id)
			if prior.layout_element == child && !prior.appeared_this_frame {
				height += prior.bounding_box.height - prior.declared_height
				if child.is_text_element || child.config.aspect != 0 {
					height = cmax(f32(0), height)
				} else {
					bounds := child.config.height
					height = clamp(height, bounds.min, bounds.max)
				}
			}
		}
		height_sum += height
	}
	parent.virtual_prefix_height = height_sum
	parent.virtual_prefix_count = siblings
	return y + f32(siblings) * f32(parent.config.gap) + height_sum
}

@(private)
virtual_ancestor_window :: proc(owner: ^Layout_Element) -> (top, bottom: f32, clipped: bool) {
	ctx := active_context
	canvas := ctx.layout_dimensions.height
	if owner.config.floating.attach_to != .None {
		y := floating_origin_y(owner)
		return -y, canvas - y, false
	}
	top, bottom = -MAX_FLOAT, MAX_FLOAT
	relative: f32
	child := owner
	children_end := ctx.layout_element_children_buffer.length - i32(owner.children.length)
	for i := ctx.open_layout_element_stack.length - 2; i > 0; i -= 1 {
		ancestor := array_get(
			&ctx.layout_elements,
			array_get_value(&ctx.open_layout_element_stack, i),
		)
		config := &ancestor.config
		if config.align.y == .Top &&
		   config.direction != .Wrap_Row &&
		   config.grid.min_cell_width <= 0 {
			relative += flow_prefix_y(ancestor, children_end)
		} else {
			// Layout-dependent positions come from the last arrangement, without its scroll.
			prior_child, prior_parent :=
				get_hash_map_item(child.id), get_hash_map_item(ancestor.id)
			if prior_child.bounding_box.height > 0 && prior_parent.bounding_box.height > 0 {
				relative +=
					prior_child.bounding_box.y -
					prior_parent.bounding_box.y -
					prior_parent.laid_out_y
			}
		}
		if config.clip.x || config.clip.y {
			relative += config.clip.offset.y
		}
		if config.clip.y {
			clipped = true
			top = cmax(top, -relative)
			viewport := canvas
			if config.height.kind == .Fixed {
				viewport = config.height.min
			} else if config.height.max > 0 {
				viewport = cmin(viewport, config.height.max)
			}
			bottom = cmin(bottom, viewport - relative)
		}
		if config.floating.attach_to != .None {
			relative += floating_origin_y(ancestor)
			break
		}
		child = ancestor
		children_end -= i32(ancestor.children.length)
	}
	top = cmax(top, -relative)
	bottom = cmin(bottom, canvas - relative)
	return
}

@(private)
floating_origin_y :: proc(box: ^Layout_Element) -> f32 {
	config := &box.config.floating
	anchor: Rect
	if config.attach_to == .Root {
		anchor.height = active_context.layout_dimensions.height
	} else {
		anchor = element({id = config.parent}).rect
	}
	height := box.config.height.min
	if box.config.height.kind != .Fixed {
		height = cmax(height, element({id = box.id}).rect.height - 2 * config.expand.height)
	}
	return(
		anchor.y +
		attach_y(config.attach.parent, anchor.height) -
		attach_y(config.attach.element, height) +
		config.offset.y -
		config.expand.height \
	)
}

@(private)
finish_virtual_rows :: proc(rows: Virtual_Range) {
	if rows.remaining > 0 {
		if box(id_local("VirtualAfter"))({height = fixed(rows.remaining)}) {}
	}
	close_element()
}

text :: proc {
	text_static,
	text_dynamic,
}

// A literal lives for the whole program, so its measurement caches by
// address instead of by content.
text_static :: proc($s: string, style: Text_Style) {
	wrapped := make_string(s)
	wrapped.is_static = true
	open_text_element(wrapped, style)
}

text_dynamic :: proc(s: string, style: Text_Style) {
	open_text_element(make_string(s), style)
}

pad :: proc(n: u16) -> Padding {
	return {left = n, right = n, top = n, bottom = n}
}

outline :: proc(w: u16) -> Border_Width {
	return {w, w, w, w, 0}
}

radius :: proc(r: f32) -> Radius {
	return Radius{r, r, r, r}
}

fit :: proc(min: f32 = 0, max: f32 = 0) -> Size {
	return Size{min = min, max = max, kind = .Fit}
}

grow :: proc(min: f32 = 0, max: f32 = 0) -> Size {
	return Size{min = min, max = max, kind = .Grow}
}

fixed :: proc(size: f32) -> Size {
	return Size{min = size, max = size, kind = .Fixed}
}

percent :: proc(p: f32, max: f32 = 0) -> Size {
	return Size{percent = p, max = max, kind = .Percent}
}

@(private)
make_string :: proc(label: string) -> String {
	return String{chars = raw_data(label), length = i32(len(label))}
}

// The index seeds the label's hash, so ("Row", 3) and ("Row3", 0) differ.
id :: proc(label: string, index: u32 = 0) -> Id {
	return hash_string(make_string(label), index)
}

id_local :: proc(label: string, index: u32 = 0) -> Id {
	return hash_string_with_offset(make_string(label), index, open_id())
}
