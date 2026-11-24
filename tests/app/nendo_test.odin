package main

import "core:sync"
import "core:testing"

import "nendo"

// Counts layout errors through the error handler's user_data.
@(private = "file")
count_layout_error :: proc(err: nendo.Error) {
	(^int)(err.user_data)^ += 1
}

@(private = "file")
fixed_width_text :: proc(
	text: string,
	config: ^nendo.Text_Style,
	user_data: rawptr,
) -> nendo.Dimensions {
	return {f32(len(text)) * 10, 16}
}

// A full element hash map must reuse the slots its pruned items freed,
// and an id attached to a reused slot must still resolve.
@(test)
layout_hash_map_reuses_slots :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	nendo.set_max_element_count(64)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {
		nendo.set_context(nil)
		nendo.set_max_element_count(32768)
		nendo.set_context(previous)
		delete(memory)
	}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})

	// Two generations fill the map. Later frames must reuse freed slots.
	for frame in 0 ..< 20 {
		nendo.begin()
		for i in 0 ..< (frame < 2 ? 31 : 30) {
			if nendo.box(nendo.id("Row", u32(frame * 31 + i)))({}) {}
		}
		if frame >= 2 {
			anchor := nendo.id("Row", u32(frame * 31))
			if nendo.box(nendo.id("Floating"))(
			{floating = {parent = anchor.id, attach_to = .Element}},
			) {}
		}
		nendo.end(0)
	}
	testing.expect_value(t, errors, 0)
	testing.expect(t, nendo.element(nendo.id("Floating")).found)
}

// Most rows only clip their preview; the second can also scroll sideways.
@(private = "file")
scroll_list_layout :: proc(second_clip := nendo.Clip{x = true, scroll = true}) {
	nendo.begin()
	if nendo.box(nendo.id("List"))(
	{
		width = nendo.fixed(200),
		height = nendo.fixed(100),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		for i in 0 ..< 140 {
			clip := i == 1 ? second_clip : nendo.Clip{x = true, offset = {-7, 0}}
			width := i == 0 ? nendo.fixed(160) : nendo.grow()
			if nendo.box(nendo.id("Label", u32(i)))(
			{width = width, height = nendo.fixed(40), clip = clip},
			) {
				if nendo.box(nendo.id("LabelInk", u32(i)))({}) {
					nendo.text(
						"a preview far too long for the row it sits in",
						{size = 16, wrap = .None},
					)
				}
			}
		}
	}
	nendo.end(0)
}

@(private = "file")
scroll_detail_layout :: proc() {
	nendo.begin()
	if nendo.box(nendo.id("Detail"))(
	{
		width = nendo.fixed(240),
		height = nendo.fixed(120),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		if nendo.box(nendo.id("DetailContent"))(
		{width = nendo.fixed(240), height = nendo.fixed(400)},
		) {}
	}
	nendo.end(0)
}

// Wheel input goes to the innermost container that can move along it,
// and a rebuilt container keeps its own extents.
@(test)
layout_scroll_targets_movable_container :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})
	nendo.set_measure_text(fixed_width_text, nil)

	// Two frames settle content sizes; the pointer rests on the first label.
	for _ in 0 ..< 2 {
		nendo.set_pointer({20, 20}, .Up)
		nendo.update_scroll(.Off, {0, 0}, 0.016)
		scroll_list_layout()
	}
	testing.expect(t, !nendo.scroll(nendo.id("Label", 0)).found)
	ink := nendo.id("LabelInk", 0)
	testing.expect_value(t, nendo.element(ink).rect.x, -7)
	nendo.set_pointer({20, 8}, .Up)
	testing.expect(t, nendo.pointer_over(ink))
	nendo.set_pointer({180, 8}, .Up)
	testing.expect(t, nendo.pointer_over(nendo.id("List")))
	testing.expect(t, !nendo.pointer_over(ink))

	// A vertical wheel goes to the list even over the sideways scroller.
	nendo.set_pointer({20, 50}, .Up)
	nendo.update_scroll(.Off, {0, -3}, 0.016)
	scroll_list_layout()
	list := nendo.scroll(nendo.id("List"))
	if !testing.expect(t, list.found) {return}
	testing.expect_value(t, list.position.y, -30)

	// A sideways wheel still reaches the innermost label that can take it.
	// The list sits 30px down, so the pointer now rests on the second label.
	nendo.set_pointer({20, 20}, .Up)
	nendo.update_scroll(.Off, {-2, 0}, 0.016)
	scroll_list_layout()
	label := nendo.scroll(nendo.id("Label", 1))
	if !testing.expect(t, label.found) {return}
	testing.expect_value(t, label.position.x, -20)
	testing.expect_value(t, nendo.element(nendo.id("LabelInk", 1)).rect.x, -20)
	testing.expect_value(t, list.position.y, -30)

	scroll_list_layout({x = true, offset = {-5, 0}})
	testing.expect(t, !nendo.scroll(nendo.id("Label", 1)).found)
	testing.expect_value(t, nendo.element(nendo.id("LabelInk", 1)).rect.x, -5)

	// A responsive rebuild can replace a container before the next event
	// pump. Reused layout slots must not give its extents to the old list.
	scroll_detail_layout()
	testing.expect(t, !nendo.scroll(nendo.id("List")).found)
	detail := nendo.scroll(nendo.id("Detail"))
	if !testing.expect(t, detail.found) {return}
	testing.expect_value(t, detail.content.height, 400)
	testing.expect_value(t, detail.viewport.height, 120)
	testing.expect_value(t, errors, 0)
}

@(private = "file")
virtual_rows_layout :: proc(
	count: int,
	height: nendo.Size,
	clip := nendo.Clip{y = true, scroll = true},
	row_height: f32 = 20,
	header_height: f32 = 19,
) -> []nendo.Render_Command {
	nendo.begin()
	if nendo.box(nendo.id("VirtualList"))(
	{
		width = nendo.fixed(200),
		height = height,
		padding = {left = 11, right = 7, top = 7, bottom = 9},
		gap = 5,
		direction = .Column,
		clip = clip,
	},
	) {
		if nendo.box(nendo.id("VirtualHeader"))({direction = .Column}) {
			if nendo.box()({height = nendo.fixed(header_height)}) {}
		}
		rows := nendo.virtual_rows(nendo.id("VirtualRun"), count, row_height, gap = 4)
		for i in rows.first ..< rows.end {
			if nendo.box(nendo.id("VirtualRow", u32(i)))(
			{width = nendo.grow(), height = nendo.fixed(row_height), color = {1, 1, 1, 1}},
			) {}
		}
	}
	return nendo.end(0)
}

@(test)
layout_virtual_rows_preserves_geometry_when_scrolled_and_shrunk :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})

	list_id := nendo.id("VirtualList")
	virtual_rows_layout(1000, nendo.fixed(100))
	view := nendo.scroll(list_id)
	if !testing.expect(t, view.found) {return}
	testing.expect_value(t, view.content.height, 24036)
	testing.expect_value(t, nendo.element(nendo.id("VirtualHeader")).rect.y, 7)
	testing.expect_value(
		t,
		nendo.element(nendo.id("VirtualRow", 0)).rect,
		nendo.Rect{11, 31, 182, 20},
	)
	testing.expect_value(t, nendo.element(nendo.id("VirtualRow", 1)).rect.y, 55)
	testing.expect(t, !nendo.element(nendo.id("VirtualRow", 999)).found)

	view.position.y = view.viewport.height - view.content.height
	frames := [?]struct {
		count:           int,
		height, content: f32,
	}{{1000, 100, 24036}, {12, 100, 324}, {12, 140, 324}}
	// Shrinking and resizing must clamp on the first frame, without a scroll update.
	for frame in frames {
		commands := virtual_rows_layout(frame.count, nendo.fixed(frame.height))
		view = nendo.scroll(list_id)
		if !testing.expect(t, view.found) {return}
		testing.expect_value(t, view.viewport.height, frame.height)
		testing.expect_value(t, view.content.height, frame.content)
		testing.expect_value(t, view.position.y, frame.height - frame.content)

		last_id := nendo.id("VirtualRow", u32(frame.count - 1))
		expected := nendo.Rect{11, frame.height - 9 - 20, 182, 20}
		clipping := false
		last_drawn := false
		for command in commands {
			if command.kind == .Scissor_Start && command.id == list_id.id {
				testing.expect_value(t, command.rect, nendo.Rect{0, 0, 200, frame.height})
				clipping = command.data.clip.y
			} else if command.kind == .Scissor_End {
				clipping = false
			} else if command.kind == .Rectangle && command.id == last_id.id {
				testing.expect(t, clipping)
				testing.expect_value(t, command.rect, expected)
				last_drawn = true
			}
		}
		testing.expect(t, last_drawn)
	}

	virtual_rows_layout(1000, nendo.grow())
	view = nendo.scroll(list_id)
	view.position.y = view.viewport.height - view.content.height
	nendo.set_dimensions({800, 100})
	virtual_rows_layout(12, nendo.grow())
	last := nendo.element(nendo.id("VirtualRow", 11))
	testing.expect(t, last.found)
	testing.expect_value(t, last.rect, nendo.Rect{11, 71, 182, 20})

	virtual_rows_layout(100, nendo.fixed(40), row_height = 0)
	nendo.scroll(list_id).position.y = -39
	virtual_rows_layout(100, nendo.fixed(40), row_height = 0)
	testing.expect_value(t, nendo.element(nendo.id("VirtualRow", 2)).rect.y, 0)
	testing.expect_value(t, nendo.scroll(list_id).content.height, 436)

	virtual_rows_layout(100, nendo.fixed(100))
	nendo.scroll(list_id).position.y = -432
	virtual_rows_layout(100, nendo.fixed(100), header_height = 300)
	testing.expect_value(
		t,
		nendo.element(nendo.id("VirtualRow", 5)).rect,
		nendo.Rect{11, 0, 182, 20},
	)
	nendo.scroll(list_id).position.y = -2817
	virtual_rows_layout(100, nendo.fixed(100), header_height = 500)
	testing.expect_value(t, nendo.scroll(list_id).position.y, -2817)
	testing.expect_value(t, nendo.element(nendo.id("VirtualRow", 99)).rect.y, 71)

	virtual_rows_layout(1000, nendo.fixed(100), {y = true, offset = {0, -200}})
	testing.expect(t, !nendo.scroll(list_id).found)
	row := nendo.element(nendo.id("VirtualRow", 8))
	testing.expect(t, row.found)
	testing.expect_value(t, row.rect, nendo.Rect{11, 23, 182, 20})
	testing.expect_value(t, errors, 0)
}

@(test)
layout_variable_virtual_rows :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})

	layout :: proc(offsets: []f32) {
		nendo.begin()
		if nendo.box(nendo.id("MixedView"))(
		{
			width = nendo.fixed(200),
			height = nendo.fixed(60),
			direction = .Column,
			padding = nendo.pad(5),
			gap = 3,
			clip = {y = true, scroll = true},
		},
		) {
			if nendo.box(nendo.id("MixedHeader"))({height = nendo.fixed(11)}) {}
			rows := nendo.virtual_rows(nendo.id("MixedRun"), offsets, gap = 4)
			for i in rows.first ..< rows.end {
				if nendo.box(nendo.id("MixedRow", u32(i)))(
				{width = nendo.grow(), height = nendo.fixed(offsets[i + 1] - offsets[i])},
				) {}
			}
		}
		nendo.end(0)
	}
	offsets: [1001]f32
	heights := [3]f32{9, 100, 27}
	for i in 0 ..< 1000 {offsets[i + 1] = offsets[i] + heights[i % len(heights)]}
	list := nendo.id("MixedView")
	layout(offsets[:])
	view := nendo.scroll(list)
	if !testing.expect(t, view.found) {return}
	testing.expect_value(t, view.content.height, 49317)
	testing.expect_value(t, nendo.element(nendo.id("MixedRow", 0)).rect, nendo.Rect{5, 19, 190, 9})
	testing.expect(t, !nendo.element(nendo.id("MixedRow", 500)).found)
	view.position.y = -100
	layout(offsets[:])
	testing.expect_value(
		t,
		nendo.element(nendo.id("MixedRow", 1)).rect,
		nendo.Rect{5, -68, 190, 100},
	)
	testing.expect_value(
		t,
		nendo.element(nendo.id("MixedRow", 2)).rect,
		nendo.Rect{5, 36, 190, 27},
	)
	view = nendo.scroll(list)
	view.position.y = view.viewport.height - view.content.height
	layout(offsets[:])
	testing.expect_value(
		t,
		nendo.element(nendo.id("MixedRow", 999)).rect,
		nendo.Rect{5, 46, 190, 9},
	)
	testing.expect(t, !nendo.element(nendo.id("MixedRow", 0)).found)
	layout(offsets[:4])
	testing.expect_value(
		t,
		nendo.element(nendo.id("MixedRow", 2)).rect,
		nendo.Rect{5, 28, 190, 27},
	)
	testing.expect_value(t, nendo.scroll(list).content.height, 168)
	layout(offsets[:1])
	testing.expect_value(t, nendo.scroll(list).position.y, 0)
	testing.expect(t, !nendo.element(nendo.id("MixedRow", 2)).found)
	testing.expect_value(t, errors, 0)
}

@(test)
layout_virtual_rows_follow_ancestor_scroll :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})
	for trial in ([4]struct {
			wheel:  f32,
			header: f32,
			row:    u32,
			y:      f32,
		}{{0, 20, 0, 20}, {-3000, 20, 999, 90}, {40, 20, 979, 90}, {0, 420, 959, 90}}) {
		nendo.set_pointer({50, 50}, .Up)
		nendo.update_scroll(.Off, {0, trial.wheel}, 0)
		nendo.begin()
		if nendo.box(nendo.id("OuterViewport"))(
		{
			width = nendo.fixed(200),
			height = nendo.fixed(110),
			direction = .Column,
			clip = {y = true, scroll = true},
		},
		) {
			if nendo.box()({height = nendo.fixed(trial.header)}) {}
			if nendo.box(nendo.id("InnerViewport"))(
			{
				width = nendo.grow(),
				height = nendo.grow(),
				direction = .Column,
				clip = {y = true, scroll = true},
			},
			) {
				rows := nendo.virtual_rows(nendo.id("NestedRun"), 1000, 20)
				for i in rows.first ..< rows.end {
					if nendo.box(nendo.id("NestedRow", u32(i)))(
					{width = nendo.grow(), height = nendo.fixed(20)},
					) {}
				}
			}
		}
		nendo.end(0)
		row := nendo.element(nendo.id("NestedRow", trial.row))
		testing.expect(t, row.found)
		testing.expect_value(t, row.rect, nendo.Rect{0, trial.y, 200, 20})
		if trial.wheel != 0 {testing.expect(t, !nendo.element(nendo.id("NestedRow", 0)).found)}
	}

	nendo.set_dimensions({800, 100})
	for offset in ([2]int{-200, -140}) {
		nendo.begin()
		if nendo.box(nendo.id("FloatingViewport"))(
		{
			width = nendo.fixed(200),
			height = nendo.fixed(300),
			direction = .Column,
			clip = {y = true, scroll = true},
			floating = {attach_to = .Root, offset = {0, f32(offset)}},
		},
		) {
			rows := nendo.virtual_rows(nendo.id("FloatingRun"), 100, 20)
			for i in rows.first ..< rows.end {
				if nendo.box(nendo.id("FloatingRow", u32(i)))(
				{width = nendo.grow(), height = nendo.fixed(20)},
				) {}
			}
		}
		nendo.end(0)
		first_visible := u32(-offset / 20)
		row := nendo.element(nendo.id("FloatingRow", first_visible))
		testing.expect(t, row.found)
		testing.expect_value(t, row.rect, nendo.Rect{0, 0, 200, 20})
		testing.expect(t, !nendo.element(nendo.id("FloatingRow", 0)).found)
	}
	testing.expect_value(t, errors, 0)
}

@(test)
layout_virtual_wrapped_header :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	nendo.set_measure_text(fixed_width_text, nil)
	offsets: [101]f32
	for i in 0 ..< 100 {offsets[i + 1] = offsets[i] + f32(20 + 8 * (i % 2))}

	page := nendo.id("WrappedView")
	header := nendo.id("WrappedHeading")
	target := nendo.id("WrappedRow", 10)
	HEADER_CAP :: f32(120)
	Header :: enum {
		Wrapped,
		Fixed,
		Single_Word,
		At_Cap,
		Grow_Aspect,
		Fixed_Aspect,
	}
	for step in ([?]struct {
			kind:          Header,
			scroll_height: f32,
		}{{.Wrapped, 0}, {.Wrapped, -1}, {.Single_Word, 16}, {.Wrapped, 0}, {.Fixed, 20}, {.Wrapped, 0}, {.At_Cap, HEADER_CAP}, {.Grow_Aspect, 0}, {.Fixed_Aspect, 100}}) {
		if step.scroll_height != 0 {
			h := step.scroll_height
			if h < 0 {
				h = nendo.element(header).rect.height
				if !testing.expect(t, h >= 96, "heading wraps to at least six lines") {return}
			}
			nendo.scroll(page).position.y = -(h + offsets[10])
		}
		nendo.begin()
		if nendo.box(page)(
		{
			width = nendo.fixed(100),
			height = nendo.fixed(60),
			direction = .Column,
			clip = {y = true, scroll = true},
		},
		) {
			if step.kind == .Grow_Aspect || step.kind == .Fixed_Aspect {
				width := step.kind == .Grow_Aspect ? nendo.grow() : nendo.fixed(100)
				if nendo.box(header)({width = width, aspect = 1}) {}
			} else if nendo.box(header)(
			{width = nendo.grow(), height = nendo.fit(max = HEADER_CAP), direction = .Column},
			) {
				if step.kind == .Fixed {
					if nendo.box()({height = nendo.fixed(20)}) {}
				} else {
					LABEL :: "aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa"
					nendo.text(step.kind == .Single_Word ? "Loading" : LABEL, {wrap = .Words})
					if step.kind == .At_Cap {
						if nendo.box()({height = nendo.fixed(HEADER_CAP)}) {}
					}
				}
			}
			if nendo.box(nendo.id("NestedContent"))(
			{width = nendo.grow(), height = nendo.fixed(offsets[100]), direction = .Column},
			) {
				rows := nendo.virtual_rows(nendo.id("WrappedRun"), offsets[:])
				for i in rows.first ..< rows.end {
					if nendo.box(nendo.id("WrappedRow", u32(i)))(
					{width = nendo.grow(), height = nendo.fixed(offsets[i + 1] - offsets[i])},
					) {}
				}
			}
		}
		nendo.end(0)
		if step.scroll_height != 0 {
			testing.expect_value(t, nendo.element(target).rect, nendo.Rect{0, 0, 100, 20})
			nendo.set_pointer({50, 10}, .Up)
			testing.expect(t, nendo.pointer_over(target))
		}
	}
}

// Three fixed rows keyed by identity, laid out in `order` inside a
// scrolling list, like the inbox after a message reorders it.
@(private = "file")
moves_layout :: proc(order: []u32) {
	nendo.begin()
	if nendo.box(nendo.id("Moves"))(
	{
		width = nendo.fixed(200),
		height = nendo.fixed(100),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		for key in order {
			if nendo.box(nendo.id("Move", key))(
			{width = nendo.grow(), height = nendo.fixed(40), transition = layout_motion()},
			) {}
		}
	}
	nendo.end(1.0 / 60)
}

// A reordered row glides from its old slot to its new one and stops
// there; scrolling and a settle request land rows without a glide.
@(test)
layout_motion_glides_reordered_rows :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	errors := 0
	nendo.init(memory, {800, 600}, {handler = count_layout_error, user_data = &errors})

	for _ in 0 ..< 2 {moves_layout({0, 1, 2})}
	testing.expect(t, !nendo.transitioning())

	// The bottom row moves to the top: it starts where it was.
	moves_layout({2, 0, 1})
	testing.expect(t, nendo.transitioning())
	last := nendo.element(nendo.id("Move", 2)).rect.y
	testing.expect_value(t, last, 80)

	frames := 0
	for nendo.transitioning() && frames < 120 {
		moves_layout({2, 0, 1})
		y := nendo.element(nendo.id("Move", 2)).rect.y
		testing.expect(t, y <= last)
		last = y
		frames += 1
	}
	testing.expect(t, frames > 2 && frames < 120)
	testing.expect_value(t, last, 0)
	testing.expect_value(t, nendo.element(nendo.id("Move", 1)).rect.y, 80)

	// Scrolling moves every row on screen, but none of them moved.
	nendo.scroll(nendo.id("Moves")).position.y = -20
	moves_layout({2, 0, 1})
	testing.expect(t, !nendo.transitioning())
	testing.expect_value(t, nendo.element(nendo.id("Move", 2)).rect.y, -20)

	// A zoom or font change settles: the next reorder lands at once.
	nendo.settle_transitions()
	moves_layout({0, 1, 2})
	testing.expect(t, !nendo.transitioning())
	testing.expect_value(t, nendo.element(nendo.id("Move", 2)).rect.y, 60)
	testing.expect_value(t, errors, 0)
}

@(test)
layout_grid_reflows_cells :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	nendo.set_measure_text(fixed_width_text, nil)
	grid := nendo.id("AutoFit")
	LABEL :: "This text stays on one line"
	WORD :: "UnbreakableWord"
	SHORT :: "OK"

	for trial in ([4]struct {
			width:   f32,
			last:    nendo.Rect,
			bottom:  f32,
			short_x: f32,
		}{{217, {14, 134, 189, 30}, 168, 98.5}, {218, {114, 54, 90, 30}, 88, 149}, {318, {14, 54, 90, 30}, 88, 149}, {98, {14, 134, 70, 30}, 168, 39}}) {
		label := trial.width < 100 ? WORD : LABEL
		nendo.begin()
		if nendo.box(nendo.id("GridParent"))(
		{width = nendo.fixed(trial.width), direction = .Column, padding = nendo.pad(10)},
		) {
			if nendo.box(grid)(
			{
				width = nendo.grow(),
				padding = nendo.pad(4),
				gap = 10,
				grid = {min_cell_width = 90, row_height = 30},
				clip = {x = true, y = true, scroll = true},
			},
			) {
				nendo.text(label, {wrap = label == WORD ? .Words : .None})
				nendo.text(SHORT, {align = .Center, line_height = 24})
				for i in 2 ..< 4 {
					if nendo.box(nendo.id("Cell", u32(i)))({padding = nendo.pad(2)}) {
						if nendo.box(nendo.id("CellContent", u32(i)))({width = nendo.grow()}) {}
					}
				}
			}
			if nendo.box(nendo.id("AfterGrid"))({height = nendo.fixed(10)}) {}
		}
		lines := 0
		for command in nendo.end(0) {
			if command.kind != .Text {continue}
			if command.data.text.text == SHORT {
				testing.expect_value(t, command.rect.x, trial.short_x)
				testing.expect_value(t, command.rect.height, 24)
			} else {
				testing.expect_value(t, command.data.text.text, label)
			}
			lines += 1
		}
		testing.expect_value(t, lines, 2)
		testing.expect_value(t, nendo.element(nendo.id("Cell", 3)).rect, trial.last)
		testing.expect_value(
			t,
			nendo.element(nendo.id("CellContent", 3)).rect.width,
			trial.last.width - 4,
		)
		testing.expect_value(t, nendo.element(nendo.id("AfterGrid")).rect.y, trial.bottom)
		content := nendo.scroll(grid).content
		testing.expect_value(t, content.height, trial.bottom - 10)
		testing.expect_value(t, content.width, max(trial.width - 20, f32(len(label) * 10 + 8)))
	}
}

@(test)
layout_grid_animates_contents :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	tile, child, next := nendo.id("Tile"), nendo.id("TileContent"), nendo.id("NextTile")

	for width in ([2]f32{250, 280}) {
		nendo.begin()
		if nendo.box(nendo.id("Grid"))(
		{width = nendo.fixed(width), gap = 10, grid = {min_cell_width = 100, row_height = 30}},
		) {
			if nendo.box(tile)(
			{
				transition = {
					properties = {.Width},
					duration = 1,
					handler = proc(args: nendo.Transition_Args) -> bool {
						args.current.rect.width =
							(args.initial.rect.width + args.target.rect.width) / 2
						return false
					},
				},
			},
			) {
				if nendo.box(child)({width = nendo.grow()}) {}
			}
			if nendo.box(next)({}) {}
		}
		nendo.end(1.0 / 60)
	}
	testing.expect_value(t, nendo.element(tile).rect.width, 127.5)
	testing.expect_value(t, nendo.element(child).rect.width, 127.5)
	testing.expect_value(t, nendo.element(next).rect.x, 145)
}

@(test)
layout_wrap_row_reflows :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	row, first, last := nendo.id("Choices"), nendo.id("First"), nendo.id("Last")

	for trial in ([3]struct {
			width, first_y, content_h: f32,
			last_position:             nendo.Vector2,
		}{{198, 10, 38, {132, 8}}, {124, 10, 66, {58, 40}}, {123, 4, 90, {57, 64}}}) {
		nendo.begin()
		if nendo.box(nendo.id("NarrowParent"))(
		{width = nendo.fixed(trial.width), direction = .Column},
		) {
			if nendo.box(row)(
			{
				width = nendo.grow(),
				height = nendo.fit(max = 70),
				direction = .Wrap_Row,
				padding = nendo.pad(4),
				gap = 6,
				align = {x = .Right, y = .Center},
				clip = {y = true, scroll = true},
			},
			) {
				if nendo.box(first)({width = nendo.fixed(60), height = nendo.fixed(18)}) {}
				if nendo.box(nendo.id("Tall"))(
				{width = nendo.fixed(50), height = nendo.fixed(30)},
				) {}
				if nendo.box(last)({width = nendo.fixed(62), height = nendo.fixed(22)}) {}
			}
			if nendo.box(nendo.id("AfterChoices"))({height = nendo.fixed(8)}) {}
		}
		nendo.end(0)
		box := nendo.element(last).rect
		testing.expect_value(t, nendo.Vector2{box.x, box.y}, trial.last_position)
		testing.expect_value(t, nendo.element(first).rect.y, trial.first_y)
		testing.expect_value(t, nendo.scroll(row).content.height, trial.content_h)
		testing.expect_value(
			t,
			nendo.element(nendo.id("AfterChoices")).rect.y,
			min(70, trial.content_h),
		)
		nendo.set_pointer({box.x + 1, box.y + 1}, .Up)
		testing.expect(t, nendo.pointer_over(last))
	}
}

@(test)
layout_wrap_row_animates :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	nendo.set_measure_text(fixed_width_text, nil)
	row, item, last := nendo.id("WrapAnim"), nendo.id("FitLabel"), nendo.id("Exit")
	outer := nendo.id("AnimatedColumn")
	LABEL :: "first one"
	resize: nendo.Transition = {
		properties = {.Width},
		handler = proc(args: nendo.Transition_Args) -> bool {
			args.current.rect.width = 100
			return false
		},
	}
	for frame in 0 ..< 3 {
		nendo.begin()
		if nendo.box(outer)(
		{width = nendo.fixed(frame == 0 ? 140 : 60), direction = .Column, transition = resize},
		) {
			if nendo.box()({direction = .Column}) {
				if nendo.box(row)(
				{height = nendo.fixed(80), direction = .Wrap_Row, clip = {x = true}},
				) {
					if nendo.box(item)({}) {nendo.text(LABEL, {size = 16})}
					if frame < 2 {
						if nendo.box(last)(
						{
							width = nendo.fixed(20),
							height = nendo.fixed(20),
							color = {255, 255, 255, 255},
							transition = {
								properties = {.Color},
								handler = proc(args: nendo.Transition_Args) -> bool {return false},
								exit = {
									order = .Natural_Order,
									final = proc(
										initial: nendo.Transition_Data,
										properties: nendo.Transition_Properties,
									) -> nendo.Transition_Data {
										final := initial
										final.color.a = 0
										return final
									},
								},
							},
						},
						) {}
					}
				}
			}
		}
		commands := nendo.end(1.0 / 60)
		if frame == 0 {continue}
		testing.expect_value(t, nendo.element(outer).rect.width, 100)
		testing.expect_value(t, nendo.element(row).rect.width, frame == 1 ? f32(100) : 90)
		testing.expect_value(t, nendo.element(item).rect, nendo.Rect{0, 0, 90, 16})
		testing.expect_value(t, nendo.element(last).rect, nendo.Rect{0, 16, 20, 20})
		lines := 0
		for command in commands {
			if command.kind != .Text {continue}
			testing.expect_value(t, command.data.text.text, LABEL)
			lines += 1
		}
		testing.expect_value(t, lines, 1)
	}

	outer = nendo.id("AnimatedRow")
	for frame in 0 ..< 2 {
		nendo.begin()
		if nendo.box(outer)({width = nendo.fixed(frame == 0 ? 140 : 60), transition = resize}) {
			if nendo.box(row)({direction = .Wrap_Row}) {
				if nendo.box(item)({width = nendo.fixed(40), height = nendo.fixed(20)}) {}
				if nendo.box(last)({width = nendo.fixed(40), height = nendo.fixed(20)}) {}
			}
			nendo.text("a a a aa", {size = 16})
		}
		nendo.end(1.0 / 60)
	}
	testing.expect_value(t, nendo.element(row).rect.width, 50)
	testing.expect_value(t, nendo.element(last).rect, nendo.Rect{0, 20, 40, 20})
}

@(test)
layout_wrap_row_aspect :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	row, first, last := nendo.id("AspectRow"), nendo.id("First"), nendo.id("Last")
	nendo.begin()
	if nendo.box()({width = nendo.fixed(200), height = nendo.fixed(50), direction = .Column}) {
		if nendo.box(row)(
		{
			width = nendo.fixed(200),
			aspect = 2,
			direction = .Wrap_Row,
			padding = nendo.pad(10),
			gap = 6,
			align = {y = .Bottom},
			clip = {y = true},
		},
		) {
			if nendo.box(first)({width = nendo.fixed(80), height = nendo.percent(0.5)}) {}
			if nendo.box(last)({width = nendo.fixed(80), height = nendo.fixed(20)}) {}
		}
	}
	nendo.end(0)
	testing.expect_value(t, nendo.element(row).rect, nendo.Rect{0, 0, 200, 100})
	testing.expect_value(t, nendo.element(first).rect, nendo.Rect{10, 10, 80, 40})
	testing.expect_value(t, nendo.element(last).rect, nendo.Rect{96, 30, 80, 20})
}

@(test)
layout_percent_clamps_to_cap :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	nendo.set_context(nil)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {nendo.set_context(previous); delete(memory)}
	nendo.init(memory, {800, 600})
	anchor, menu, sibling := nendo.id("Anchor"), nendo.id("Menu"), nendo.id("Sibling")
	for trial in ([2]struct {
			width, anchor_w, menu_w, sibling_w: f32,
		}{{180, 76, 76, 76}, {400, 120, 100, 252}}) {
		nendo.begin()
		if nendo.box()(
		{
			width = nendo.fixed(trial.width),
			height = nendo.fixed(100),
			padding = nendo.pad(10),
			gap = 8,
		},
		) {
			if nendo.box(anchor)(
			{
				width = nendo.percent(0.5, max = 120),
				height = nendo.percent(0.75, max = 60),
				padding = nendo.pad(5),
			},
			) {}
			if nendo.box(sibling)({width = nendo.grow(), height = nendo.fixed(30)}) {}
			if nendo.box(menu)(
			{
				width = nendo.percent(1, max = 100),
				height = nendo.percent(0.5, max = 12),
				floating = {
					attach_to = .Element,
					parent = anchor.id,
					attach = {parent = .Left_Bottom},
				},
			},
			) {}
		}
		nendo.end(0)
		testing.expect_value(t, nendo.element(anchor).rect, nendo.Rect{10, 10, trial.anchor_w, 60})
		testing.expect_value(t, nendo.element(menu).rect, nendo.Rect{10, 70, trial.menu_w, 12})
		testing.expect_value(
			t,
			nendo.element(sibling).rect,
			nendo.Rect{18 + trial.anchor_w, 10, trial.sibling_w, 30},
		)
	}

	fit_row, tall_contents := nendo.id("FitRow"), nendo.id("TallContents")
	square, short_square := nendo.id("Square"), nendo.id("ShortSquare")
	wrap_child := nendo.id("WrapHeight")
	nendo.begin()
	if nendo.box(fit_row)({width = nendo.fixed(100)}) {
		if nendo.box()({height = nendo.fixed(20)}) {}
		if nendo.box(tall_contents)({height = nendo.percent(0.5, max = 1000)}) {
			if nendo.box()({height = nendo.fixed(80)}) {}
		}
	}
	if nendo.box()({width = nendo.fixed(200), height = nendo.fixed(200)}) {
		if nendo.box(square)({height = nendo.percent(0.5, max = 30), aspect = 1}) {}
		if nendo.box()(
		{
			width = nendo.fixed(100),
			height = nendo.percent(0.25),
			direction = .Wrap_Row,
			aspect = 2,
		},
		) {
			if nendo.box(wrap_child)(
			{width = nendo.fixed(50), height = nendo.percent(0.5, max = 24)},
			) {}
		}
	}
	if nendo.box()({width = nendo.fixed(200), height = nendo.fixed(40)}) {
		if nendo.box(short_square)({width = nendo.percent(0.5, max = 70), aspect = 1}) {}
	}
	nendo.end(0)
	testing.expect_value(t, nendo.element(fit_row).rect.height, 20)
	testing.expect_value(t, nendo.element(tall_contents).rect.height, 10)
	testing.expect_value(t, nendo.element(square).rect, nendo.Rect{100, 0, 30, 30})
	testing.expect_value(t, nendo.element(wrap_child).rect.height, 24)
	testing.expect_value(t, nendo.element(short_square).rect, nendo.Rect{300, 0, 40, 40})

	for width in ([2]f32{100, 80}) {
		nendo.begin()
		if nendo.box()({width = nendo.fixed(width), direction = .Wrap_Row, gap = 8}) {
			for i in 0 ..< 2 {
				if nendo.box(nendo.id("WrappedPercent", u32(i)))(
				{width = nendo.percent(0.5, max = 46), height = nendo.fixed(20)},
				) {}
			}
		}
		nendo.end(0)
		last := nendo.element(nendo.id("WrappedPercent", 1)).rect
		want := width == 100 ? nendo.Rect{54, 0, 46, 20} : nendo.Rect{0, 28, 40, 20}
		testing.expect_value(t, last, want)
	}
}
