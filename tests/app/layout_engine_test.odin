package main

import "core:sync"
import "core:testing"

import clay "layout"

// Counts layout errors through the error handler's userData.
@(private = "file")
count_layout_error :: proc(err: clay.ErrorData) {
	(^int)(err.userData)^ += 1
}

@(private = "file")
fixed_width_text :: proc(
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	return {f32(text.length) * 10, 16}
}

// A full element hash map must reuse the slots its pruned items freed,
// and an id attached to a reused slot must still resolve.
@(test)
layout_hash_map_reuses_slots :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	clay.SetCurrentContext(nil)
	clay.SetMaxElementCount(64)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer {
		clay.SetCurrentContext(nil)
		clay.SetMaxElementCount(32768)
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{800, 600},
		{handler = count_layout_error, userData = &errors},
	)

	// Two generations fill the map. Later frames must reuse freed slots.
	for frame in 0 ..< 20 {
		clay.BeginLayout()
		for i in 0 ..< (frame < 2 ? 31 : 30) {
			if clay.UI(clay.ID("Row", u32(frame * 31 + i)))({}) {}
		}
		if frame >= 2 {
			anchor := clay.ID("Row", u32(frame * 31))
			if clay.UI(clay.ID("Floating"))(
			{floating = {parentId = anchor.id, attachTo = .ElementWithId}},
			) {}
		}
		clay.EndLayout(0)
	}
	testing.expect_value(t, errors, 0)
	testing.expect(t, clay.GetElementData(clay.ID("Floating")).found)
}

// A vertical list whose rows hold a clipped, overflowing one-line label,
// like a chat row with a long preview. The label can only scroll sideways.
@(private = "file")
scroll_list_layout :: proc() {
	clay.BeginLayout()
	if clay.UI(clay.ID("List"))(
	{
		layout = {
			sizing = {clay.SizingFixed(200), clay.SizingFixed(100)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		for i in 0 ..< 10 {
			if clay.UI(clay.ID("Label", u32(i)))(
			{
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(40)}},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					"a preview far too long for the row it sits in",
					{fontSize = 16, wrapMode = .None},
				)
			}
		}
	}
	clay.EndLayout(0)
}

@(private = "file")
scroll_detail_layout :: proc() {
	clay.BeginLayout()
	if clay.UI(clay.ID("Detail"))(
	{
		layout = {
			sizing = {clay.SizingFixed(240), clay.SizingFixed(120)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		if clay.UI(clay.ID("DetailContent"))(
		{layout = {sizing = {clay.SizingFixed(240), clay.SizingFixed(400)}}},
		) {}
	}
	clay.EndLayout(0)
}

// Wheel input goes to the innermost container that can move along it,
// and a rebuilt container keeps its own extents.
@(test)
layout_scroll_targets_movable_container :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	clay.SetCurrentContext(nil)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer {clay.SetCurrentContext(previous); delete(memory)}
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{800, 600},
		{handler = count_layout_error, userData = &errors},
	)
	clay.SetMeasureTextFunction(fixed_width_text, nil)

	// Two frames settle content sizes; the pointer rests on the first label.
	for _ in 0 ..< 2 {
		clay.SetPointerState({20, 20}, false)
		clay.UpdateScrollContainers(false, {0, 0}, 0.016)
		scroll_list_layout()
	}

	// A vertical wheel over the label scrolls the list instead of vanishing
	// into the label's horizontal-only clip.
	clay.SetPointerState({20, 20}, false)
	clay.UpdateScrollContainers(false, {0, -3}, 0.016)
	scroll_list_layout()
	list := clay.GetScrollContainerData(clay.ID("List"))
	if !testing.expect(t, list.found) {return}
	testing.expect_value(t, list.scrollPosition.y, -30)

	// A sideways wheel still reaches the innermost label that can take it.
	// The list sits 30px down, so the pointer now rests on the second label.
	clay.SetPointerState({20, 20}, false)
	clay.UpdateScrollContainers(false, {-2, 0}, 0.016)
	scroll_list_layout()
	label := clay.GetScrollContainerData(clay.ID("Label", 1))
	if !testing.expect(t, label.found) {return}
	testing.expect_value(t, label.scrollPosition.x, -20)
	testing.expect_value(t, list.scrollPosition.y, -30)

	// A responsive rebuild can replace a container before the next event
	// pump. Reused layout slots must not give its extents to the old list.
	scroll_detail_layout()
	detail := clay.GetScrollContainerData(clay.ID("Detail"))
	if !testing.expect(t, detail.found) {return}
	testing.expect_value(t, detail.contentDimensions.height, 400)
	testing.expect_value(t, detail.scrollContainerDimensions.height, 120)
	testing.expect_value(t, errors, 0)
}
