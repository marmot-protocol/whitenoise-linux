package main

// nendo and the UI caches are global. Run this check alone:
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=chat_title_overflow
import marmot "../marmot"
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
	ui.account_ref = "offline-fixture"
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
	ui.account_ref = "offline-fixture"
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
	for locale in ([]string{"en", "it", "de", "ja", "ko"}) {
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
	ui.account_ref = "offline-fixture"
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
	token := strings.trim_prefix(TEST_PRIMAL, "https://primal.net/e/")
	short_event := fmt.tprintf("Look at nostr:%s today", token)
	ordinary_url := fmt.tprintf("https://example.com/%s", token)
	relay := fmt.tprintf(
		"wss://relay.example/%s",
		strings.repeat("r", 120, context.temp_allocator),
	)
	payload := make([]u8, 36 + len(relay), context.temp_allocator)
	payload[1], payload[34], payload[35] = 32, 1, u8(len(relay))
	copy(payload[36:], transmute([]u8)relay)
	long_event := bech32_encode("nevent", payload)
	for source, i in ([]string{short_event, long_event, "nostr:nevent1qqqq"}) {
		last := marmot.Chat_List_Message_Preview {
			kind      = 9,
			plaintext = strings.clone_to_cstring(source, context.temp_allocator),
		}
		row := marmot.Chat_List_Row {
			last_message = &last,
		}
		preview, _ := chat_row_preview(nil, &row, ui.account_ref, nil)
		append(
			&ui.chats,
			Chat_Row_Ui {
				group_id = fmt.tprintf("event-%d", i),
				title = "Event link",
				preview = preview,
			},
		)
	}
	url_message := marmot.Chat_List_Message_Preview {
		kind      = 9,
		plaintext = strings.clone_to_cstring(ordinary_url, context.temp_allocator),
	}
	url_row := marmot.Chat_List_Row {
		last_message = &url_message,
	}
	url_preview, _ := chat_row_preview(nil, &url_row, ui.account_ref, nil)
	testing.expect_value(t, url_preview, ordinary_url)
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
		for want, i in ([]string{"Look at Nostr event today", "Nostr event", "Invalid Nostr reference"}) {
			text, inside := shown(commands, u32(4 + i))
			testing.expect_value(t, text, want)
			testing.expect(t, inside, text)
		}
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-chat-previews-%d.png", rail_w))
		rl.EndDrawing()
	}
}

@(test)
chat_draft_text_resolution :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "acct-a",
		selected    = -1,
	}
	defer {
		delete(ui.chats)
		delete(ui.compose)
		delete(ui.drafts)
	}
	alpha := Chat_Row_Ui {
		group_id = "alpha",
		preview  = "Last message",
	}
	beta := Chat_Row_Ui {
		group_id = "beta",
		preview  = "Older message",
	}
	invite := Chat_Row_Ui {
		group_id = "invite",
		pending  = true,
	}
	append(&ui.chats, alpha, beta, invite)

	testing.expect_value(t, chat_draft_text(nil, alpha), "")
	testing.expect_value(t, chat_draft_text(&ui, alpha), "")

	ui.drafts["acct-a:alpha"] = "  see you soon  "
	ui.drafts["acct-a:beta"] = "   \n\t  "
	ui.drafts["acct-a:invite"] = "ignored invite draft"
	ui.drafts["acct-b:alpha"] = "other account draft"

	testing.expect_value(t, chat_draft_text(&ui, alpha), "see you soon")
	testing.expect_value(t, chat_draft_text(&ui, beta), "")
	testing.expect_value(t, chat_draft_text(&ui, invite), "")

	// While selected, live composer text takes precedence over stale stashed text.
	ui.selected = 0
	testing.expect_value(t, chat_draft_text(&ui, alpha), "")
	append(&ui.compose, "live reply")
	testing.expect_value(t, chat_draft_text(&ui, alpha), "live reply")
	testing.expect_value(
		t,
		chat_draft_text(&ui, Chat_Row_Ui{group_id = "alpha", archived = true}),
		"live reply",
	)

	// While editing a sent message, the composer holds the edit, not a draft.
	ui.editing = "msg-1"
	testing.expect_value(t, chat_draft_text(&ui, alpha), "see you soon")
	ui.editing = ""

	// Switching accounts isolates drafts by account_ref.
	ui.selected = -1
	ui.account_ref = "acct-b"
	testing.expect_value(t, chat_draft_text(&ui, alpha), "other account draft")
}

@(test)
chat_row_draft_preview :: proc(t: ^testing.T) {
	if !test_isolated("chat_row_draft_preview") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Chat row draft preview")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	memory: []u8
	init_layout(&memory, 65536, {1200, 800})
	defer delete(memory)

	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		row_menu         = -1,
		member_menu      = -1,
		member_nick      = -1,
		selected_contact = -1,
		account_ref      = "acct-draft",
		prefs            = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{id_hex = "acct-draft", name = "Self"})
	append(
		&ui.chats,
		Chat_Row_Ui {
			group_id = "g-short",
			title = "Short draft",
			preview = "Previous message",
			tick = .DELIVERED,
		},
		Chat_Row_Ui {
			group_id = "g-long",
			title = "Long draft",
			preview = "Older message",
			tick = .FAILED,
		},
		Chat_Row_Ui{group_id = "g-empty", title = "Brand new chat", preview = ""},
		Chat_Row_Ui{group_id = "g-multi", title = "Multiline draft", preview = "Fallback preview"},
		Chat_Row_Ui {
			group_id = "g-space",
			title = "Blank draft",
			preview = "Visible last message",
			tick = .DELIVERED,
		},
	)
	ui.drafts["acct-draft:g-short"] = "See you at five"
	ui.drafts["acct-draft:g-long"] = "This unsent draft is deliberately much longer than any sidebar width so it must truncate cleanly"
	ui.drafts["acct-draft:g-empty"] = "First message draft"
	ui.drafts["acct-draft:g-multi"] = "First line\nSecond line"
	ui.drafts["acct-draft:g-space"] = "   \n  "

	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.archived)
		delete(ui.rail_rows)
		delete(ui.compose)
		delete(ui.drafts)
		delete(ui.sidebar_filter)
		delete(ui.filter_hits)
		delete(ui.filter_previews)
		delete(ui.pending)
		wrap_clear()
	}

	preview_runs :: proc(
		commands: []nendo.Render_Command,
		index: u32,
	) -> (
		joined: string,
		prefix_color: nendo.Color,
		has_prefix: bool,
		inside: bool,
	) {
		clip := nendo.element(nendo.id("ChatRowPrevClip", index)).rect
		parts: [dynamic]string
		parts.allocator = context.temp_allocator
		inside = true
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
			if len(parts) == 0 && text == "Draft:" {
				has_prefix = true
				prefix_color = command.text.color
			}
			append(&parts, text)
			inside &&= box.x + box.width <= clip.x + clip.width + 0.5
		}
		joined = strings.concatenate(parts[:], context.temp_allocator)
		return
	}

	for rail_w in ([]int{RAIL_W_MIN, RAIL_W_MAX}) {
		ui.prefs.rail_w = rail_w
		for _ in 0 ..< 3 {anim_snap_all(); build_layout(&ui, 0)}
		commands := build_layout(&ui, 0)

		text0, color0, has0, inside0 := preview_runs(commands, 0)
		testing.expect(t, has0, "Short draft should show Draft: prefix")
		testing.expect_value(t, color0, ACCENT)
		testing.expect_value(t, text0, "Draft:See you at five")
		testing.expect(t, inside0, text0)
		// Delivery tick is hidden while showing a draft.
		testing.expect(t, !nendo.element(nendo.id("Tick", 0)).found)

		text1, _, has1, inside1 := preview_runs(commands, 1)
		testing.expect(t, has1, "Long draft should show Draft: prefix")
		testing.expect(t, strings.has_suffix(text1, "…"), text1)
		testing.expect(t, inside1, text1)

		text2, _, has2, inside2 := preview_runs(commands, 2)
		testing.expect(t, has2, "Empty-history chat should still show Draft: prefix")
		testing.expect_value(t, text2, "Draft:First message draft")
		testing.expect(t, inside2, text2)

		text3, _, has3, inside3 := preview_runs(commands, 3)
		testing.expect(t, has3, "Multiline draft should show Draft: prefix")
		testing.expect_value(t, text3, "Draft:First line…")
		testing.expect(t, inside3, text3)

		text4, _, has4, inside4 := preview_runs(commands, 4)
		testing.expect(t, !has4, "Whitespace-only draft must fall back to last message")
		testing.expect_value(t, text4, "Visible last message")
		testing.expect(t, inside4, text4)
		testing.expect(t, nendo.element(nendo.id("Tick", 4)).found)
	}

	// A pending send stays visible alongside the next message's draft.
	append(&ui.pending, Pending_Send{account_ref = "acct-draft", group_id = "g-short"})
	for _ in 0 ..< 2 {anim_snap_all(); build_layout(&ui, 0)}
	commands := build_layout(&ui, 0)
	draft_text, _, _, draft_inside := preview_runs(commands, 0)
	testing.expect_value(t, draft_text, "Draft:See you at five")
	testing.expect(t, draft_inside, draft_text)
	preview := nendo.element(nendo.id("ChatRowPrev", 0)).rect
	sending_visible := false
	for command in commands {
		box := command.rect
		if command.kind == .Text &&
		   command.text.text == "Sending..." &&
		   box.x >= preview.x &&
		   box.x + box.width <= preview.x + preview.width + 0.5 &&
		   box.y >= preview.y &&
		   box.y + box.height <= preview.y + preview.height + 0.5 {
			sending_visible = true
			break
		}
	}
	testing.expect(t, sending_visible, "The draft row must show its pending send")
	clear(&ui.pending)

	// Selecting row 0 uses live composer text and immediately clears when emptied.
	ui.selected = 0
	clear(&ui.compose)
	for _ in 0 ..< 2 {anim_snap_all(); build_layout(&ui, 0)}
	cleared_text, _, cleared_has, _ := preview_runs(build_layout(&ui, 0), 0)
	testing.expect(t, !cleared_has, "Empty composer on active row must not show stale draft")
	testing.expect_value(t, cleared_text, "Previous message")
	testing.expect(t, nendo.element(nendo.id("Tick", 0)).found)

	append(&ui.compose, "Typing live")
	for _ in 0 ..< 2 {anim_snap_all(); build_layout(&ui, 0)}
	live_text, _, live_has, _ := preview_runs(build_layout(&ui, 0), 0)
	testing.expect(t, live_has)
	testing.expect_value(t, live_text, "Draft:Typing live")

	// Sidebar filter match snippet outranks the draft so search hits stay visible.
	ui.selected = -1
	append(&ui.sidebar_filter, "match")
	append(&ui.filter_hits, true, false, false, false, false)
	append(&ui.filter_previews, "Matched search snippet", "", "", "", "")
	for _ in 0 ..< 2 {anim_snap_all(); build_layout(&ui, 0)}
	hit_text, _, hit_has, _ := preview_runs(build_layout(&ui, 0), 0)
	testing.expect(t, !hit_has, "Search snippet must outrank draft")
	testing.expect_value(t, hit_text, "Matched search snippet")
	clear(&ui.sidebar_filter)
	clear(&ui.filter_hits)
	clear(&ui.filter_previews)

	// Archived rows also surface saved drafts.
	append(
		&ui.archived,
		Chat_Row_Ui {
			group_id = "g-arch",
			title = "Archived chat",
			preview = "Old archived message",
			archived = true,
		},
	)
	ui.drafts["acct-draft:g-arch"] = "Archived reply"
	ui.page = .Archived
	for _ in 0 ..< 3 {anim_snap_all(); build_layout(&ui, 0)}
	arch_text, arch_color, arch_has, arch_inside := preview_runs(build_layout(&ui, 0), 0)
	testing.expect(t, arch_has, "Archived row should show Draft: prefix")
	testing.expect_value(t, arch_color, ACCENT)
	testing.expect_value(t, arch_text, "Draft:Archived reply")
	testing.expect(t, arch_inside, arch_text)
}
