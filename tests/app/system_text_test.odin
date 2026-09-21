package main

import "core:testing"
import "core:strings"
import "base:runtime"
import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
system_text_participants :: proc(t: ^testing.T) {
	cases := [?]struct {
		kind: cstring,
		actor, subject, name: cstring,
		want: string,
	}{
		{"admin_added", "Alice", "Bob", nil, "Alice made Bob an admin"},
		{"admin_added", nil, "Bob", nil, "Bob was made an admin"},
		{"admin_added", "", "Bob", nil, "Bob was made an admin"},
		{"admin_removed", "Alice", "Bob", nil, "Alice dismissed Bob as admin"},
		{"admin_removed", nil, "Bob", nil, "Bob is no longer an admin"},
		{"member_added", "Alice", "Bob", nil, "Alice added Bob"},
		{"member_added", nil, "Bob", nil, "Bob was added to the group"},
		{"member_removed", "Alice", "Bob", nil, "Alice removed Bob"},
		{"member_removed", nil, "Bob", nil, "Bob was removed from the group"},
		{"member_left", "Alice", "Bob", nil, "Bob left the group"},
		{"member_left", "Alice", nil, nil, "Alice left the group"},
		{"group_renamed", "Alice", nil, "Friends", "Alice renamed the group to Friends"},
		{"group_renamed", nil, nil, "Friends", "The group was renamed to Friends"},
		{"group_avatar_changed", "Alice", nil, nil, "Alice changed the group photo"},
		{"disappearing_timer_changed", "Alice", nil, nil, "Alice changed the disappearing message timer"},
		{"group_disbanded", "Alice", nil, nil, "Alice disbanded the group"},
		{"admin_added", "Alice", nil, nil, "Fallback"},
		{"admin_added", nil, nil, nil, "Fallback"},
		{"future_event", "Alice", "Bob", nil, "Fallback"},
	}
	for tc in cases {
		ev := marmot.Group_System_Event{
			system_type = tc.kind, text = "Fallback",
			actor_display_name = tc.actor, subject_display_name = tc.subject,
			name = tc.name,
		}
		testing.expect_value(t, system_text(nil, &ev), tc.want)
		actor_hex :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		subject_hex :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		if tc.actor != nil && string(tc.actor) != "" { ev.actor_account_id_hex = actor_hex }
		if tc.subject != nil && string(tc.subject) != "" { ev.subject_account_id_hex = subject_hex }
		actor_chips, subject_chips := 0, 0
		for seg in inline_segs(system_text(nil, &ev, .Mentions)) {
			if seg.hex == actor_hex { actor_chips += 1 }
			if seg.hex == subject_hex { subject_chips += 1 }
		}
		testing.expect_value(t, actor_chips, strings.contains(tc.want, "Alice") ? 1 : 0)
		testing.expect_value(t, subject_chips, strings.contains(tc.want, "Bob") ? 1 : 0)
	}
	// Missing event text must remain safe to render.
	ev: marmot.Group_System_Event
	testing.expect_value(t, system_text(nil, &ev), "")
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=system_mentions_layout
@(test)
system_mentions_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "system_mentions_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(800, 320, "System mentions")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {800, 320})
	defer delete(memory)
	actor :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	subject :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	ui: Ui_State
	ui.nicknames[actor], ui.nicknames[subject] = "Alice", "Bob"
	g_ui = &ui
	defer { g_ui = nil; delete(ui.nicknames) }
	clay.BeginLayout()
	if clay.UI(clay.ID("SystemTest"))({
		layout = {sizing = {width = clay.SizingFixed(800), height = clay.SizingFixed(320)},
			layoutDirection = .TopToBottom, padding = {top = 20}, childGap = 12},
		backgroundColor = BG,
	}) {
		for kind, i in ([]cstring{"admin_added", "admin_removed", "member_removed", "group_renamed", "member_added"}) {
			ev := marmot.Group_System_Event{system_type = kind, subject_account_id_hex = subject,
				subject_display_name = "Bob", name = "Friends"}
			if i > 2 { ev.actor_account_id_hex = actor; ev.actor_display_name = "Alice" }
			msg := Msg_Ui{system = true, sys_text = system_text(nil, &ev, .Mentions), at = "08:28"}
			if i == 4 { msg.sys_added_hex = subject }
			system_row(u32(i), msg)
		}
	}
	commands := clay.EndLayout(0)
	for i in 0 ..< 5 {
		chip := clay.GetElementData(clay.ID("SegMention", (0xD00000 + u32(i) * 8) * 128))
		testing.expect(t, chip.found && chip.boundingBox.width > 0, "System participant must render as a mention chip")
	}
	rl.BeginDrawing()
	clay_raylib_render(&commands)
	rl.TakeScreenshot("/tmp/wn-system-mentions.png")
	rl.EndDrawing()
}
