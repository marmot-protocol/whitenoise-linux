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
	append(&ui.accounts, Account_Row_Ui{id_hex = ui.account_ref, name = "Test profile"})
	append(&ui.compose, "Unsent draft")
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs, kb_focus = nil, nil, ""
		close_msg_menu(&ui)
		delete(ui.ctx_items)
		delete(ui.reply_hint)
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
	more := message_more_id("trailhead")
	if !testing.expect_value(t, ui.timeline_focus, more.id) {return}
	commands := layout(&ui)
	testing.expect(t, shows(commands, "⋯"), "the focused message exposes More actions")

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .LSHIFT
	testing.expect(t, sdl.PushEvent(&event))
	event.key.scancode = .F10
	testing.expect(t, sdl.PushEvent(&event))
	rl.WindowShouldClose()
	handle_chat(&ui, &client)
	event.type = .KEY_UP
	testing.expect(t, sdl.PushEvent(&event))
	event.key.scancode = .LSHIFT
	testing.expect(t, sdl.PushEvent(&event))
	if !testing.expect_value(t, ui.ctx_message, "trailhead") {return}
	commands = layout(&ui)
	testing.expect(t, shows(commands, "Copy text"))
	key(&ui, &client, .DOWN)
	layout(&ui)
	key(&ui, &client, .ESCAPE)
	testing.expect(t, !ui.ctx_open)
	testing.expect_value(t, ui.timeline_focus, more.id)
	layout(&ui)
	key(&ui, &client, .ENTER)
	layout(&ui)
	for _ in 0 ..< len(ui.ctx_items) {
		if ui.ctx_focus == nendo.id("CtxCopy").id {break}
		key(&ui, &client, .DOWN)
		layout(&ui)
	}
	key(&ui, &client, .ENTER)
	clipboard := sdl.GetClipboardText()
	defer sdl.free(clipboard)
	testing.expect_value(t, string(cstring(clipboard)), "Meet at the trailhead?")
	testing.expect_value(t, ui.timeline_focus, more.id)
	layout(&ui)
	key(&ui, &client, .ENTER)
	if !testing.expect_value(t, ui.ctx_message, "trailhead") {return}
	rows_with_menu := [2]marmot.Timeline_Message_Record{record, record}
	rows_with_menu[0].message_id_hex = "earlier-message"
	page.messages, page.messages_len = raw_data(rows_with_menu[:]), len(rows_with_menu)
	timeline_apply(nil, &ui, &page)
	layout(&ui)
	key(&ui, &client, .DOWN)
	layout(&ui)
	key(&ui, &client, .ENTER)
	if !testing.expect_value(t, ui.replying, "trailhead") {return}
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	ui.replying = ""
	page.messages, page.messages_len = &record, 1
	timeline_apply(nil, &ui, &page)
	layout(&ui)
	key(&ui, &client, .TAB)
	key(&ui, &client, .TAB)
	key(&ui, &client, .ENTER)
	if !testing.expect_value(t, ui.reaction_details_id, "trailhead") {return}
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	testing.expect_value(t, len(ui.react_pending), 0)
	commands = layout(&ui)
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
	// The hover control and right click both open the same menu.
	box := nendo.element(more).rect
	more_at := nendo.Vector2{box.x + box.width / 2, box.y + box.height / 2}
	nendo.set_pointer(more_at, .Up)
	testing.expect(t, shows(layout(&ui), "⋯"))
	click(t, more_at, chip_point)
	testing.expect(t, timeline_pointer(&ui, &client))
	testing.expect(t, !ui.ctx_open, "releasing away from More cancels the click")
	click(t, more_at, more_at)
	testing.expect(t, timeline_pointer(&ui, &client))
	testing.expect_value(t, ui.ctx_message, "trailhead")
	testing.expect(t, shows(layout(&ui), "Copy text"))
	key(&ui, &client, .ESCAPE)
	layout(&ui)
	rl.WindowShouldClose()
	rl.PushMouseButton(.RIGHT, true)
	nendo.set_pointer(chip_point, .Up)
	handle_chat(&ui, &client)
	testing.expect_value(t, ui.ctx_message, "trailhead")
	testing.expect(t, shows(layout(&ui), "Copy text"))
	rl.PushMouseButton(.RIGHT, false)
	// A menu consumes an outside press through release even if the
	// targeted message is tombstoned between those two frames.
	send := nendo.element(nendo.id("SendBtn")).rect
	send_at := nendo.Vector2{send.x + send.width / 2, send.y + send.height / 2}
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, true)
	nendo.set_pointer(send_at, .Down)
	layout(&ui)
	record.deleted = true
	timeline_apply(nil, &ui, &page)
	layout(&ui)
	handle_ctx_menu(&ui, &client)
	testing.expect(t, ui.ctx_open)
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, false)
	nendo.set_pointer(send_at, .Up)
	testing.expect(t, !composer_clicked("SendBtn"))
	handle_ctx_menu(&ui, &client)
	testing.expect(t, !ui.ctx_open)
	rl.WindowShouldClose()
	layout(&ui)
	handle_chat(&ui, &client) // an idle frame does not give focus to the composer
	key(&ui, &client, .ENTER)
	key(&ui, &client, .ENTER)
	testing.expect_value(t, len(ui.pending), 0)
	record.deleted = false
	timeline_apply(nil, &ui, &page)
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	ui.timeline_focus = 0
	layout(&ui)

	for pair, i in ([2][2]nendo.Vector2{{point, chip_point}, {chip_point, point}}) {
		click(t, pair[0], pair[1])
		testing.expect_value(t, timeline_pointer(&ui, &client), i == 0)
		testing.expect_value(t, ui.reaction_details_id, "")
	}
	ui.compose_more = true
	click(t, point, point)
	testing.expect(t, !timeline_pointer(&ui, &client), "the composer menu owns its outside click")
	ui.compose_more = false
	ui.row_menu = 0
	click(t, point, point)
	testing.expect(t, !timeline_pointer(&ui, &client), "the rail menu owns its outside click")
	ui.row_menu = -1

	record.reactions.by_emoji_len = 0
	timeline_apply(nil, &ui, &page)
	click(t, point, chip_point)
	testing.expect(
		t,
		timeline_pointer(&ui, &client),
		"the displayed control still owns the canceled click",
	)
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
	testing.expect(t, timeline_pointer(&ui, &client), "details owns the press")
	layout(&ui)
	rows := [2]marmot.Timeline_Message_Record{record, record}
	rows[0].message_id_hex = "another-message"
	page.messages, page.messages_len = raw_data(rows[:]), len(rows)
	timeline_apply(nil, &ui, &page)
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, false)
	nendo.set_pointer(point, .Up)
	testing.expect(t, timeline_pointer(&ui, &client), "details owns the release after a repage")
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

	history: [42]marmot.Timeline_Message_Record
	history[0] = record
	for i in 1 ..< len(history) {
		history[i] = {
			kind           = KIND_CHAT_MESSAGE,
			message_id_hex = fmt.ctprintf("older-%d", i),
			sender         = people[i % len(people)],
			deleted        = true,
		}
	}
	page.messages, page.messages_len = raw_data(history[:]), len(history)
	timeline_apply(nil, &ui, &page)
	append(
		&ui.pending,
		Pending_Send {
			ticket = 42,
			account_ref = ui.account_ref,
			group_id = "test",
			sender = "You",
			body = "Failed message",
			failed = true,
		},
	)
	defer delete(ui.pending)
	layout(&ui)
	view := nendo.scroll(nendo.id("Timeline"))
	view.position.y = 0
	layout(&ui)
	rl.PushKey(.LEFT_SHIFT, true)
	key(&ui, &client, .TAB)
	layout(&ui)
	testing.expect(t, view.position.y < 0, "reverse Tab reveals the retry below the viewport")
	key(&ui, &client, .TAB)
	rl.PushKey(.LEFT_SHIFT, false)
	layout(&ui)
	key(&ui, &client, .ENTER)
	testing.expect_value(t, ui.reaction_details_id, "trailhead")
	testing.expect_value(t, string(ui.compose[:]), "Unsent draft")
	key(&ui, &client, .ESCAPE)
	view.position.y = 0
	layout(&ui)
	viewport := nendo.element(nendo.id("Timeline")).rect
	button_box := nendo.element(more).rect
	view.position.y -= button_box.y + button_box.height - viewport.y + 3
	layout(&ui)
	row := nendo.element(nendo.id("MsgRow", 0)).rect
	rl.WindowShouldClose()
	rl.PushMouseButton(.RIGHT, true)
	nendo.set_pointer({row.x + 100, row.y + row.height - 5}, .Up)
	handle_chat(&ui, &client)
	if !testing.expect_value(t, ui.ctx_message, "trailhead") {return}
	rl.PushMouseButton(.RIGHT, false)
	layout(&ui)
	timeline := nendo.id("Timeline")
	thumb := nendo.element(nendo.id("ScrollThumb", timeline.id))
	if !testing.expect(t, thumb.found) {return}
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, true)
	nendo.set_pointer({thumb.rect.x + 1, thumb.rect.y + 1}, .Down)
	layout(&ui)
	testing.expect(t, scroll_drag.container != timeline.id, "the background thumb cannot grab")
	rl.PushMouseButton(.LEFT, false)
	key(&ui, &client, .ESCAPE)
	layout(&ui)
	testing.expect(
		t,
		nendo.element(more).rect.y >= viewport.y - 0.5,
		"Esc reveals the restored focus",
	)

	// Notes use a small floating overflow control. On touch its hidden
	// geometry must not intercept a swipe or the long-press timer.
	ui.prefs.notes_group = "test"
	view.position.y = 0
	layout(&ui)
	box = nendo.element(more).rect
	more_at = {box.x + box.width / 2, box.y + box.height / 2}
	rl.InjectFinger(.Down, more_at.x, more_at.y)
	rl.WindowShouldClose()
	nendo.set_pointer(more_at, .Down)
	testing.expect(t, !timeline_pointer(&ui, &client))
	update_drag_scroll(&ui, false)
	long_pressed = true
	handle_chat(&ui, &client)
	long_pressed = false
	if !testing.expect_value(t, ui.ctx_message, "trailhead") {return}
	position := view.position.y
	rl.InjectFinger(.Move, more_at.x, more_at.y - 80)
	rl.WindowShouldClose()
	update_drag_scroll(&ui, true)
	testing.expect_value(t, view.position.y, position)
	rl.InjectFinger(.Up, more_at.x, more_at.y)
	rl.WindowShouldClose()
}
