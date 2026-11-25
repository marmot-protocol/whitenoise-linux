package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:text/edit"
import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(test)
reaction_details_dispatch :: proc(t: ^testing.T) {
	if !test_isolated("reaction_details_dispatch") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Reaction details")
	defer rl.CloseWindow()
	load_themes(); apply_theme(0, 0); init_fonts()
	UI_ZOOM, UI_SCALE = 1, 1
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(nil); delete(memory)}
	ui := Ui_State {
		page        = .Chats,
		row_menu    = -1,
		member_menu = -1,
		prefs       = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	ui.account_ref = "0000000000000000000000000000000000000000000000000000000000000001"
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Trail crew"})
	append(&ui.accounts, Account_Row_Ui{name = "Test profile"})
	append(&ui.compose, "Unsent draft")
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs, kb_focus = nil, nil, ""
		edit.destroy(&ui.ed)
		delete(ui.compose); delete(ui.accounts); delete(ui.chats)
		delete(ui.messages_account); delete(ui.messages_group)
		for msg in ui.messages {message_free(msg)}
		delete(ui.messages)
		messages_collect()
		profile_session_clear()
	}

	people: [24]cstring
	for &sender, i in people {sender = fmt.ctprintf("%064x", i + 1)}
	last: [1]cstring = {fmt.ctprintf("%064x", len(people) + 1)}
	tallies := [?]marmot.Timeline_Reaction_Emoji {
		{
			emoji = "👍",
			count = len(people),
			senders = raw_data(people[:]),
			senders_len = len(people),
		},
		{emoji = "🎉", count = 1, senders = raw_data(last[:]), senders_len = len(last)},
	}
	record := marmot.Timeline_Message_Record {
		kind = KIND_CHAT_MESSAGE,
		message_id_hex = "trailhead",
		sender = people[0],
		plaintext = "Meet at the trailhead?",
		reactions = {by_emoji = raw_data(tallies[:]), by_emoji_len = len(tallies)},
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	timeline_apply(nil, &ui, &page)
	client: marmot.Client

	layout :: proc(ui: ^Ui_State) -> []nendo.Render_Command {
		commands: []nendo.Render_Command
		for _ in 0 ..< 3 {commands = build_layout(ui, 0)}
		return commands
	}
	shows :: proc(commands: []nendo.Render_Command, text: string) -> bool {
		for command in commands {
			if command.kind == .Text && command.text.text == text {return true}
		}
		return false
	}
	key :: proc(ui: ^Ui_State, client: ^marmot.Client, k: rl.KeyboardKey) {
		rl.WindowShouldClose()
		rl.PushKey(k, true)
		if ui.reaction_details_id == "" {handle_chat(ui, client)} else {handle_reaction_modal(ui)}
		rl.PushKey(k, false)
	}
	layout(&ui)
	key(&ui, &client, .TAB)
	key(&ui, &client, .ENTER)
	if !testing.expect_value(t, ui.reaction_details_id, "trailhead") {return}
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	testing.expect_value(t, len(ui.react_pending), 0)
	commands := layout(&ui)
	testing.expect(
		t,
		shows(commands, profile_label(nil, string(people[1]))),
		"first emoji's sender",
	)
	key(&ui, &client, .END)
	commands = layout(&ui)
	testing.expect(
		t,
		shows(commands, profile_label(nil, string(last[0]))),
		"other emoji beyond the first viewport",
	)
	key(&ui, &client, .ESCAPE)
	testing.expect_value(t, ui.reaction_details_id, "")
	layout(&ui)

	button := nendo.element(reaction_button_id("trailhead"))
	if !testing.expect(t, button.found) {return}
	point := nendo.Vector2 {
		button.rect.x + button.rect.width / 2,
		button.rect.y + button.rect.height / 2,
	}
	chip := nendo.element(nendo.id("MsgReactionChip", msg_slot_id(0, 0)))
	if !testing.expect(t, chip.found) {return}
	chip_point := nendo.Vector2 {
		chip.rect.x + chip.rect.width / 2,
		chip.rect.y + chip.rect.height / 2,
	}
	click :: proc(t: ^testing.T, from, to: nendo.Vector2) {
		event: sdl.Event
		event.type = .MOUSE_BUTTON_DOWN
		event.button.button, event.button.down = 1, true
		event.button.x, event.button.y = from.x, from.y
		testing.expect(t, sdl.PushEvent(&event))
		event.type, event.button.down = .MOUSE_BUTTON_UP, false
		event.button.x, event.button.y = to.x, to.y
		testing.expect(t, sdl.PushEvent(&event))
		rl.WindowShouldClose()
		nendo.set_pointer(to, .Up)
	}
	for pair, i in ([2][2]nendo.Vector2{{point, chip_point}, {chip_point, point}}) {
		click(t, pair[0], pair[1])
		testing.expect_value(t, reaction_pointer(&ui), i == 0)
		testing.expect_value(t, ui.reaction_details_id, "")
	}
	ui.compose_more = true
	click(t, point, point)
	testing.expect(t, !reaction_pointer(&ui), "the composer menu owns its outside click")
	ui.compose_more = false
	ui.row_menu = 0
	click(t, point, point)
	testing.expect(t, !reaction_pointer(&ui), "the rail menu owns its outside click")
	ui.row_menu = -1

	record.reactions.by_emoji_len = 0
	timeline_apply(nil, &ui, &page)
	click(t, point, chip_point)
	testing.expect(t, reaction_pointer(&ui), "the displayed control still owns the canceled click")
	testing.expect_value(t, ui.reaction_details_id, "")
	record.reactions.by_emoji_len = len(tallies)
	timeline_apply(nil, &ui, &page)
	ui.prefs.reduce_motion = false
	ui.mention_active = true
	anim_tick(1.0 / 60)
	layout(&ui)
	mention := nendo.id("MentionPop")
	testing.expect(
		t,
		nendo.element(mention).found,
		"suggestions are visible before opening details",
	)

	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, true)
	nendo.set_pointer(point, .Down)
	testing.expect(t, reaction_pointer(&ui), "details owns the press")
	layout(&ui)
	rows := [2]marmot.Timeline_Message_Record{record, record}
	rows[0].message_id_hex = "another-message"
	page.messages, page.messages_len = raw_data(rows[:]), len(rows)
	timeline_apply(nil, &ui, &page)
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, false)
	nendo.set_pointer(point, .Up)
	testing.expect(t, reaction_pointer(&ui), "details owns the release after a repage")
	if !testing.expect_value(t, ui.reaction_details_id, "trailhead") {return}
	layout(&ui)
	testing.expect(t, !nendo.element(mention).found, "no outgoing suggestions over details")
	ui.prefs.reduce_motion = true
	testing.expect_value(t, len(ui.react_pending), 0)

	page.messages, page.messages_len = &record, 1
	record.reactions.by_emoji, record.reactions.by_emoji_len = &tallies[1], 1
	timeline_apply(nil, &ui, &page)
	messages_collect()
	commands = layout(&ui)
	testing.expect(
		t,
		!shows(commands, profile_label(nil, string(people[1]))),
		"removed senders do not linger",
	)
	testing.expect(
		t,
		shows(commands, profile_label(nil, string(last[0]))),
		"the remaining reaction stays visible",
	)
	page.messages_len = 0
	timeline_apply(nil, &ui, &page)
	messages_collect()
	testing.expect_value(t, ui.reaction_details_id, "")

	page.messages_len = 1
	timeline_apply(nil, &ui, &page)
	layout(&ui)
	key(&ui, &client, .TAB)
	page.messages_len = 0
	timeline_apply(nil, &ui, &page)
	messages_collect()
	layout(&ui)
	key(&ui, &client, .ENTER)
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	testing.expect_value(t, len(ui.pending), 0)
}
