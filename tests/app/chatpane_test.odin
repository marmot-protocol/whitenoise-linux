package main

// nendo and the UI caches are global. Run this check alone:
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=chat_title_overflow
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "nendo"
import rl "sdlrl"

// Run alone because nendo and SDL state are global.
@(test)
group_settings_permissions :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "group_settings_permissions" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 1000, "Group settings permissions")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	memory: []u8
	init_layout(&memory, 32768, {1200, 1000})
	defer delete(memory)
	ui := Ui_State {
		show_members     = true,
		info_tab         = .Settings,
		row_menu         = -1,
		member_menu      = -1,
		member_nick      = -1,
		selected_contact = -1,
		group_desc       = "Shared description",
		group_retention  = 7776000,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Shared group"})
	append(&ui.members, Member_Ui{is_self = true})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.accounts); delete(ui.chats); delete(ui.members)
		delete(ui.compose); delete(ui.mention_cands); delete(ui.rename_input)
	}
	ui.info_tab = .Members
	ed_set(&ui, &ui.rename_input, "Previous group")
	open_group_info(&ui, nil, .Settings)
	testing.expect_value(t, string(ui.rename_input[:]), "Shared group")
	ed_set(&ui, &ui.rename_input, "Unpublished rename")
	open_group_info(&ui, nil, .Settings)
	testing.expect_value(t, string(ui.rename_input[:]), "Unpublished rename")
	open_group_info(&ui, nil, .Members)
	ui.chats[0].title = "Updated group"
	open_group_info(&ui, nil, .Settings)
	testing.expect_value(t, string(ui.rename_input[:]), "Updated group")
	// Include demotion with stale editor/menu state.
	for admin, i in ([]bool{false, true, false}) {
		ui.members[0].is_admin = admin
		ui.desc_editing, ui.gpic_menu_open = i == 2, i == 2
		for _ in 0 ..< 3 {build_layout(&ui, 0)}
		commands := build_layout(&ui, 0)
		for id in ([]string{"RenameBox", "RenameBtn", "HeroPicBtn", "DescEditBtn", "RetentionRow", "RetChip2"}) {
			testing.expect(t, nendo.element(nendo.id(id)).found == admin, id)
		}
		for id in ([]string{"DescBox", "DescSave", "GpicMenu"}) {
			testing.expect(t, !nendo.element(nendo.id(id)).found, id)
		}
		testing.expect(t, nendo.element(nendo.id("InfoTimerCard")).found)
		description_visible := false
		for command in commands {
			if command.kind != .Text {continue}
			text := command.text.text
			part := text
			description_visible ||= part == ui.group_desc
		}
		testing.expect(t, description_visible)
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-group-settings-%d.png", i))
		rl.EndDrawing()
	}
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=thread_reply_count_layout
@(test)
thread_reply_count_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "thread_reply_count_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 400, "Thread reply counts")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 400})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	append(&ui.messages, Msg_Ui{id = "parent", sender = "Parent", thread_replies = 1})
	append(
		&ui.messages,
		Msg_Ui{id = "child", sender = "Child", thread_of = "parent", thread_replies = 2},
	)
	defer {g_ui, g_prefs = nil, nil; delete(ui.messages); delete(ui.thread_stack)}
	for root in ([]string{"", "parent", "child", "parent", ""}) {
		clear(&ui.thread_stack)
		if root != "" {append(&ui.thread_stack, root)}
		nendo.begin()
		if nendo.box(nendo.id("ThreadCountTest"))(
		{direction = .Column, width = nendo.fixed(600)},
		) {
			if root != "" {thread_root_plate(&ui)}
			for msg, i in ui.messages {
				if msg.id != root {message_row(u32(i), msg)}
			}
		}
		nendo.end(0)
		for msg, i in ui.messages {
			testing.expect_value(
				t,
				nendo.element(nendo.id("MsgThreadChip", u32(i))).found,
				msg.id != root,
			)
			testing.expect_value(t, msg.thread_replies, i + 1)
		}
	}
}

@(test)
chat_title_overflow :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "chat_title_overflow" {return}
	rl.InitWindow(987, 1382, "Layout regression")
	defer rl.CloseWindow()
	UI_ZOOM = 1.875
	UI_SCALE = UI_ZOOM
	init_fonts()
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	previous := nendo.current_context()
	defer nendo.set_context(previous)
	nendo.init(memory, {400, 700}, {})
	nendo.set_measure_text(measure_text, nil)

	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	g_ui = &ui
	g_prefs = &ui.prefs
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	defer delete(ui.accounts)
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "01e88b174112addb56b562777c32c5f"})
	defer delete(ui.chats)
	append(
		&ui.messages,
		Msg_Ui {
			sender = "Alice",
			body = "This is a longer message with several words to exercise wrapping in a narrow window.",
		},
	)
	append(
		&ui.messages,
		Msg_Ui {
			sender = "Another participant",
			body = "A short reply",
			reply_from = "Alice",
			reply_text = ui.messages[0].body,
		},
	)
	append(&ui.messages, Msg_Ui{system = true, body = "Disappearing timer changed", at = "12:00"})
	defer delete(ui.messages)
	for locale in ([]string{"en", "it", "de", "ja"}) {
		set_locale(locale)
		for search in ([]bool{false, true}) {
			ui.search_open = search
			for width in ([]f32{526.4, 340, 400, 700}) {
				rl.SetWindowSize(i32(width * UI_ZOOM), 1382)
				nendo.set_dimensions({width, 700})
				commands := build_layout(&ui, 0)
				for id in ([]string{"ChatPane", "ChatHeader", "SearchBtn", "FilesBtn", "BellBtn", "MembersBtn", "Composer"}) {
					element := nendo.element(nendo.id(id))
					testing.expect(t, element.found, id)
					testing.expect(t, element.rect.x + element.rect.width <= width + 0.01, id)
				}
				view := nendo.element(nendo.id("ChatHeadTitleClip")).rect
				clipped := false
				for command in commands {
					if command.kind == .Scissor_Start && command.rect == view {
						clipped = true
					}
				}
				testing.expect(t, clipped, "title must be clipped inside the header")
				for id in ([]string{"FilesBtn", "SearchBtn", "BellBtn", "MembersBtn"}) {
					nendo.set_pointer({-100, -100}, .Up)
					anim_snap_all()
					anim_tick(0.02)
					build_layout(&ui, 0)
					button := nendo.element(nendo.id(id)).rect
					pointer := nendo.Vector2 {
						button.x + button.width / 2,
						button.y + button.height / 2,
					}
					first_width: f32
					for frame in 0 ..< 5 {
						nendo.set_pointer(pointer, .Up)
						anim_tick(0.02)
						build_layout(&ui, 0)
						expanded := nendo.element(nendo.id(id)).rect
						if frame == 0 {first_width = expanded.width}
						testing.expect(t, expanded.width > button.width, id)
						testing.expect(
							t,
							expanded.x <= pointer.x && expanded.x + expanded.width >= pointer.x,
							id,
						)
						testing.expect(t, expanded.x + expanded.width <= width + 0.01, id)
						right := nendo.element(nendo.id("MembersBtn")).rect
						testing.expect(t, right.x + right.width <= width + 0.01, id)
					}
					full := nendo.element(nendo.id(id)).rect.width
					testing.expect(
						t,
						full > first_width,
						"label must animate rather than appear instantly",
					)
					anim_tick(0.02)
					build_layout(&ui, 0)
					testing.expect(
						t,
						nendo.element(nendo.id(id)).rect.width == full,
						"animation must finish in 100 ms",
					)
					nendo.set_pointer({-100, -100}, .Up)
					for _ in 0 ..< 5 {anim_tick(0.02); build_layout(&ui, 0)}
					testing.expect_value(t, nendo.element(nendo.id(id)).rect.width, button.width)
					ui.prefs.reduce_motion = true
					nendo.set_pointer(pointer, .Up)
					anim_tick(0.02)
					build_layout(&ui, 0)
					testing.expect_value(t, nendo.element(nendo.id(id)).rect.width, full)
					ui.prefs.reduce_motion = false
				}
				nendo.set_pointer({-100, -100}, .Up)
			}
		}
	}
	set_locale("en")
}

// A preview too long for its row ends in an ellipsis inside the clip,
// and the fit stays put frame to frame and follows a rail resize.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=chat_preview_ellipsis
@(test)
chat_preview_ellipsis :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "chat_preview_ellipsis" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1400, 600, "Chat previews")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	memory: []u8
	init_layout(&memory, 32768, {1400, 600})
	defer delete(memory)
	ui := Ui_State {
		selected         = -1,
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	long_word :=
		"Pneumonoultramicroscopicsilicovolcanoconiosis" +
		"Pneumonoultramicroscopicsilicovolcanoconiosis"
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "a", title = "New group", preview = long_word, tick = .DELIVERED},
		Chat_Row_Ui {
			group_id = "b",
			title = "New group",
			preview = "日本語の長いメッセージを送ります。マーモットは山に住んでいます。山の上で会いましょう。お弁当と水を忘れないでください。",
		},
		Chat_Row_Ui {
			group_id = "c",
			title = "Hikers",
			preview = "Are you still coming to the marmot meetup tonight? Bring snacks 🧀 and water 🥾",
			tick = .PENDING,
		},
		Chat_Row_Ui{group_id = "d", title = "Short", preview = "See you there"},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.accounts); delete(ui.chats); delete(ui.rail_rows)
		wrap_clear()
	}

	// Text drawn inside each row's preview clip, joined.
	shown :: proc(commands: []nendo.Render_Command, index: u32) -> (string, bool) {
		clip := nendo.element(nendo.id("ChatRowPrevClip", index)).rect
		parts: [dynamic]string
		parts.allocator = context.temp_allocator
		inside := true
		for command in commands {
			box := command.rect
			if command.kind != .Text ||
			   box.y < clip.y ||
			   box.y >= clip.y + clip.height ||
			   box.x < clip.x ||
			   box.x >= clip.x + clip.width {
				continue
			}
			text := command.text.text
			append(&parts, text)
			inside &&= box.x + box.width <= clip.x + clip.width + 0.5
		}
		return strings.concatenate(parts[:], context.temp_allocator), inside
	}

	for rail_w in ([]int{RAIL_W_MIN, RAIL_W_MAX, RAIL_W_MIN}) {
		ui.prefs.rail_w = rail_w
		for _ in 0 ..< 3 {anim_snap_all(); build_layout(&ui, 0)}
		commands := build_layout(&ui, 0)
		for index in 0 ..< u32(3) {
			text, inside := shown(commands, index)
			testing.expect(t, strings.has_suffix(text, "…"), text)
			testing.expect(t, inside, text)
			frame := strings.clone(text, context.temp_allocator)
			again, _ := shown(build_layout(&ui, 0), index)
			testing.expect_value(t, again, frame)
			commands = build_layout(&ui, 0)
		}
		text, _ := shown(commands, 3)
		testing.expect_value(t, text, "See you there")
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-chat-previews-%d.png", rail_w))
		rl.EndDrawing()
	}
}
