package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -o:speed -define:WN_PERF=true -define:ODIN_TEST_NAMES=large_group_layout
@(test)
large_group_layout :: proc(t: ^testing.T) {
	when !#config(WN_PERF, false) {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Large group regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 131072, {1200, 800})
	defer delete(memory)
	ui := Ui_State {
		show_members     = true,
		row_menu         = -1,
		member_menu      = -1,
		member_nick      = -1,
		selected_contact = -1,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Large group"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for i in 0 ..< 1000 {
		id := fmt.aprintf("%064x", i)
		append(
			&ui.members,
			Member_Ui{id_hex = id, npub = hex_npub(id), name = fmt.aprintf("Member %04d", i)},
		)
	}
	defer {
		for member in ui.members {delete(member.id_hex); delete(member.npub); delete(member.name)}
		delete(ui.members); delete(ui.chats); delete(ui.accounts)
		delete(ui.compose); delete(ui.mention_cands)
	}
	for _ in 0 ..< 5 {build_layout(&ui, 0)}
	samples: [31]f64
	for &ms in samples {
		start := time.tick_now()
		build_layout(&ui, 0)
		ms = time.duration_milliseconds(time.tick_since(start))
		free_all(context.temp_allocator)
	}
	slice.sort(samples[:])
	data := clay.GetScrollContainerData(clay.ID("MembersScroll"))
	testing.expect(t, data.found && !layout_overflow)
	full_height := data.contentDimensions.height
	for fraction in ([]f32{0, 0.5, 1}) {
		data.scrollPosition.y = -fraction * (full_height - data.scrollContainerDimensions.height)
		commands := build_layout(&ui, 0)
		mounted := 0
		for _, i in ui.members {if clay.GetElementData(clay.ID("MemberName", u32(i))).found {mounted += 1}}
		fmt.printf(
			"members=1000 scroll=%.1f mounted=%d median_ms=%.3f p95_ms=%.3f\n",
			fraction,
			mounted,
			samples[15],
			samples[29],
		)
		testing.expect(t, mounted > 0 && mounted < 30)
		testing.expect(
			t,
			abs(
				clay.GetScrollContainerData(clay.ID("MembersScroll")).contentDimensions.height -
				full_height,
			) <
			1,
		)
		rl.BeginDrawing()
		clay_raylib_render(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-members-%d.png", int(fraction * 2)))
		rl.EndDrawing()
	}
	testing.expect(t, clay.GetElementData(clay.ID("MemberRow", 999)).found)
	ui.member_nick = 500
	build_layout(&ui, 0)
	testing.expect(t, clay.GetElementData(clay.ID("MemberNickBox", 500)).found)
	testing.expect(
		t,
		abs(
			clay.GetScrollContainerData(clay.ID("MembersScroll")).contentDimensions.height -
			full_height -
			34,
		) <
		1,
	)
	ui.member_nick = -1
	for width in ([]i32{600, 1200}) {
		rl.SetWindowSize(width, 800)
		clay.SetLayoutDimensions({f32(width), 800})
		for _ in 0 ..< 3 {build_layout(&ui, 0)}
		data = clay.GetScrollContainerData(clay.ID("MembersScroll"))
		data.scrollPosition.y = -(data.contentDimensions.height -
			data.scrollContainerDimensions.height)
		build_layout(&ui, 0)
		testing.expect(t, clay.GetElementData(clay.ID("MemberName", 999)).found)
		testing.expect(t, !layout_overflow)
	}
	ui.focus = .Compose
	ui.ed_target = &ui.compose
	ui.mention_dismissed = -1
	ed_set(&ui, &ui.compose, "@zzzzzz")
	for &ms in samples {
		start := time.tick_now()
		mention_update(&ui, nil)
		ms = time.duration_milliseconds(time.tick_since(start))
		free_all(context.temp_allocator)
	}
	slice.sort(samples[:])
	testing.expect_value(t, len(ui.mention_cands), 0)
	fmt.printf("mentions=1000 median_ms=%.3f p95_ms=%.3f\n", samples[15], samples[29])
	ed_set(&ui, &ui.compose, "@MEMBER")
	mention_update(&ui, nil)
	testing.expect_value(t, len(ui.mention_cands), MENTION_CANDS_MAX)
	ed_set(&ui, &ui.compose, "@0999")
	mention_update(&ui, nil)
	testing.expect_value(t, len(ui.mention_cands), 1)
	testing.expect_value(t, ui.mention_cands[0], 999)
	ed_set(&ui, &ui.compose, fmt.tprintf("@%s", ui.members[999].npub))
	mention_update(&ui, nil)
	testing.expect_value(t, len(ui.mention_cands), 1)
	testing.expect_value(t, ui.mention_cands[0], 999)
	ed_set(&ui, &ui.compose, "@zzzzzz")
	mention_update(&ui, nil)
	ui.show_members = false
	rl.SetWindowSize(1200, 800)
	clay.SetLayoutDimensions({1200, 800})
	for i in 0 ..< 1000 {
		append(
			&ui.messages,
			Msg_Ui {
				id = fmt.aprintf("joined-%d", i),
				system = true,
				body = strings.clone("Member joined the group"),
				sys_text = fmt.aprintf("@%s joined the group", ui.members[i].npub),
			},
		)
	}
	defer {for msg in ui.messages {message_free(msg)}; delete(ui.messages); wrap_clear()}
	for _ in 0 ..< 5 {build_layout(&ui, 0)}
	for &ms in samples {
		start := time.tick_now()
		build_layout(&ui, 0)
		ms = time.duration_milliseconds(time.tick_since(start))
		free_all(context.temp_allocator)
	}
	slice.sort(samples[:])
	fmt.printf("system_rows=1000 median_ms=%.3f p95_ms=%.3f\n", samples[15], samples[29])
	data = clay.GetScrollContainerData(clay.ID("Timeline"))
	full_height = data.contentDimensions.height
	for fraction in ([]f32{0, 0.5, 1}) {
		data.scrollPosition.y = -fraction * (full_height - data.scrollContainerDimensions.height)
		build_layout(&ui, 0)
		mounted := 0
		for _, i in ui.messages {if clay.GetElementData(clay.ID("SysPill", u32(i))).found {mounted += 1}}
		testing.expect(t, mounted > 0 && mounted < 100)
		testing.expect(
			t,
			abs(
				clay.GetScrollContainerData(clay.ID("Timeline")).contentDimensions.height -
				full_height,
			) <
			1,
		)
	}
	testing.expect(t, clay.GetElementData(clay.ID("SysPill", 999)).found)
	// Hold the scrollbar while moving it through several positions. Layout
	// must not mistake a pointer-driven offset for a change in row heights.
	rl.PushMouseButton(.LEFT, true)
	clay.SetPointerState({-100, -100}, true)
	defer {rl.PushMouseButton(.LEFT, false); scroll_drag = {}}
	for fraction in ([]f32{0.25, 0.5, 0.75, 0.25}) {
		for _ in 0 ..< 3 {
			data = clay.GetScrollContainerData(clay.ID("Timeline"))
			span := data.contentDimensions.height - data.scrollContainerDimensions.height
			thumb := max(
				24,
				data.scrollContainerDimensions.height *
				data.scrollContainerDimensions.height /
				data.contentDimensions.height,
			)
			travel := data.scrollContainerDimensions.height - thumb
			scroll_drag = {
				clay.ID("Timeline").id,
				rl.GetMousePosition().y / UI_ZOOM - fraction * travel,
			}
			build_layout(&ui, 0)
			if abs(data.scrollPosition.y - timeline_draw_offset) > 0.01 {build_layout(&ui, 0)}
			testing.expect(t, rl.IsMouseButtonDown(.LEFT))
			testing.expect(t, abs(data.scrollPosition.y - timeline_draw_offset) < 1)
			testing.expect(
				t,
				abs(data.scrollPosition.y + fraction * span) < 1,
				"the view must follow the scrollbar before release",
			)
		}
	}
}

@(test)
members_snapshot_owned :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	id := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	profile_info(nil, id)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	member := marmot.Group_Member_Details {
		member_id_hex = strings.clone_to_cstring(id, context.temp_allocator),
		display_name  = "Published",
		is_admin      = true,
	}
	details := marmot.Group_Details {
		members     = &member,
		members_len = 1,
	}
	ui: Ui_State
	ui.nicknames[id] = "Local"
	for _ in 0 ..< 3 {
		members_apply(&ui, nil, &details)
		testing.expect_value(t, ui.members[0].name, "Local")
		testing.expect_value(t, mention_hex(ui.members[0].npub), id)
		testing.expect(t, ui.members[0].is_admin)
	}
	members_clear(&ui)
	delete(ui.members); delete(ui.nicknames); delete(ui.group_desc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
members_stale_completion :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	ui := Ui_State {
		account_ref = "account",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {delete(ui.chats); delete(ui.client_status); members_stop()}
	for scope in ([][2]string{{"other", "group"}, {"account", "other"}, {"account", "group"}}) {
		job := new(Members_Work)
		job.account, job.group =
			strings.clone_to_cstring(scope[0]), strings.clone_to_cstring(scope[1])
		job.err = strings.clone("failure")
		job.worker = thread.create(proc(_: ^thread.Thread) {})
		members_job = job
		thread.start(job.worker)
		thread.join(job.worker)
		members_drain(&ui, nil)
		testing.expect(t, members_job == nil)
		testing.expect_value(
			t,
			ui.client_status != "",
			scope[0] == "account" && scope[1] == "group",
		)
	}
}
