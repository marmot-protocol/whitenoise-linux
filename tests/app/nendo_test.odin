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

// A vertical list whose rows hold a clipped, overflowing one-line label,
// like a chat row with a long preview. The label can only scroll sideways.
@(private = "file")
scroll_list_layout :: proc() {
	nendo.begin()
	if nendo.box(nendo.id("List"))(
	{
		width = nendo.fixed(200),
		height = nendo.fixed(100),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		for i in 0 ..< 10 {
			if nendo.box(nendo.id("Label", u32(i)))(
			{width = nendo.grow(), height = nendo.fixed(40), clip = {x = true}},
			) {
				nendo.text(
					"a preview far too long for the row it sits in",
					{size = 16, wrap = .None},
				)
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

	// A vertical wheel over the label scrolls the list instead of vanishing
	// into the label's horizontal-only clip.
	nendo.set_pointer({20, 20}, .Up)
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
	testing.expect_value(t, list.position.y, -30)

	// A responsive rebuild can replace a container before the next event
	// pump. Reused layout slots must not give its extents to the old list.
	scroll_detail_layout()
	detail := nendo.scroll(nendo.id("Detail"))
	if !testing.expect(t, detail.found) {return}
	testing.expect_value(t, detail.content.height, 400)
	testing.expect_value(t, detail.viewport.height, 120)
	testing.expect_value(t, errors, 0)
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
