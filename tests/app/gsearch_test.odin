// Global-search dates, filters, preserved requests, and snippets.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
gs_fold_latin1 :: proc(t: ^testing.T) {
	testing.expect_value(t, gs_fold("Café Über"), "cafe uber")
	testing.expect_value(t, gs_fold("naïve"), "naive")
	testing.expect_value(t, gs_fold("寝る"), "寝る") // non-latin passes through
}

@(test)
gs_subseq_match :: proc(t: ^testing.T) {
	testing.expect(t, gs_subseq("white noise linux", "wnl"))
	testing.expect(t, !gs_subseq("white noise", "wnl"))
	testing.expect(t, gs_subseq("anything", ""))
}

@(test)
gs_snippet_window :: proc(t: ^testing.T) {
	s := gs_snippet("one\ntwo", 0)
	defer delete(s)
	testing.expect_value(t, s, "one two") // newline flattened
}

// A mention renders as a chip only while its token is whole, so the
// window never cuts one and charges it a single rune.
@(test)
gs_snippet_keeps_mentions :: proc(t: ^testing.T) {
	NPUB :: "@npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh"
	pad := strings.repeat("a", 100, context.temp_allocator)

	// Token starts 3 runes before the 90-rune cut.
	head := pad[:86]
	s := gs_snippet(strings.concatenate({head, " ", NPUB, " tail"}, context.temp_allocator), 0)
	defer delete(s)
	testing.expect_value(
		t,
		s,
		strings.concatenate({head, " ", NPUB, " t\u2026"}, context.temp_allocator),
	)

	// Window start lands inside the token: it is kept whole.
	u := gs_snippet(strings.concatenate({NPUB, " ", pad}, context.temp_allocator), 30)
	defer delete(u)
	testing.expect_value(
		t,
		u,
		strings.concatenate({"\u2026", NPUB, " ", pad[:88], "\u2026"}, context.temp_allocator),
	)
}

@(test)
gs_utc_date_boundaries :: proc(t: ^testing.T) {
	ui: Ui_State
	defer {delete(ui.gs_since); delete(ui.gs_until)}
	append(&ui.gs_since, "1970-01-01")
	append(&ui.gs_until, "1970-01-01")
	since, until, valid := gs_dates(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, since, u64(0))
	testing.expect_value(t, until, u64(86400))
	clear(&ui.gs_since); clear(&ui.gs_until)
	append(&ui.gs_since, "2000-02-29")
	append(&ui.gs_until, "2000-02-29")
	since, until, valid = gs_dates(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, since, u64(951782400))
	testing.expect_value(t, until, u64(951868800))
	for bad in ([]string{"2100-02-29", "2025-02-29", "2026-04-31", "1969-12-31", "2026-1-01", "2026-10-00", "2026-10-01 "}) {
		_, ok := gs_day(bad)
		testing.expect(t, !ok, bad)
	}
	clear(&ui.gs_since); clear(&ui.gs_until)
	append(&ui.gs_since, "2026-10-02")
	append(&ui.gs_until, "2026-10-01")
	_, _, valid = gs_dates(&ui)
	testing.expect(t, !valid, "A reversed range must not issue a request")
	gs_remove_filter(&ui, 3)
	since, until, valid = gs_dates(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, since, u64(0))
	testing.expect_value(t, until, u64(1790899200))
}

@(test)
gs_preserves_request_and_removes_each_filter :: proc(t: ^testing.T) {
	ui := Ui_State {
		gs_group        = strings.clone("group"),
		gs_sender       = strings.clone("sender"),
		gs_attachment   = 2,
		gs_cursor_at    = 50,
		gs_cursor_id    = strings.clone("cursor"),
		gs_cursor_group = strings.clone("group"),
		gs_more         = true,
		gs_append       = true,
	}
	append(&ui.gs_input, "literal %_\\")
	append(&ui.gs_sender_input, "Alice")
	append(&ui.gs_since, "2026-09-01")
	append(&ui.gs_until, "2026-09-30")
	append(&ui.gs_hits, Gs_Hit{msg_id = strings.clone("message"), group = strings.clone("group")})
	defer {
		delete(ui.gs_input); delete(ui.gs_sender_input); delete(ui.gs_since); delete(ui.gs_until)
		delete(
			ui.gs_group,
		); delete(ui.gs_sender); delete(ui.gs_cursor_id); delete(ui.gs_cursor_group)
		gs_clear_hits(&ui); delete(ui.gs_hits)
	}
	gs_open_modal(&ui)
	gs_close(&ui)
	gs_open_modal(&ui)
	testing.expect_value(t, string(ui.gs_input[:]), "literal %_\\")
	testing.expect_value(t, ui.gs_hits[0].msg_id, "message")
	testing.expect_value(t, ui.gs_cursor_id, "cursor")
	testing.expect(t, ui.gs_more && ui.gs_append)
	gs_remove_filter(&ui, 3)
	testing.expect(t, string(ui.gs_until[:]) == "2026-09-30", "Removing start must preserve end")
	for i in ([]u32{1, 2, 4, 5}) {gs_remove_filter(&ui, i)}
	testing.expect(t, !gs_has_filters(&ui))
	testing.expect(
		t,
		string(ui.gs_input[:]) == "literal %_\\",
		"Removing predicates must preserve literal text",
	)
	gs_remove_filter(&ui, 0)
	testing.expect_value(t, string(ui.gs_input[:]), "")
	ui.gs_loading = true
	gs_close(&ui)
	testing.expect(
		t,
		ui.gs_resume && !ui.gs_loading,
		"Closing a pending request must record the need to resume",
	)
}

@(test)
gs_sender_identity_validation :: proc(t: ^testing.T) {
	KEY :: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	ui: Ui_State
	defer {delete(ui.gs_sender_input); delete(ui.contacts)}
	append(&ui.gs_sender_input, strings.to_upper(KEY, context.temp_allocator))
	key, valid := gs_sender_key(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, key, KEY)
	clear(&ui.gs_sender_input); append(&ui.gs_sender_input, "Alice")
	append(&ui.contacts, Contact_Ui{id_hex = KEY, name = "Alice"})
	key, valid = gs_sender_key(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, key, KEY)
	append(&ui.contacts, Contact_Ui{id_hex = "other", name = "Alice"})
	_, valid = gs_sender_key(&ui)
	testing.expect(t, !valid, "A display-name collision must require choosing an identity")
	clear(&ui.gs_sender_input); append(&ui.gs_sender_input, "not a public key")
	_, valid = gs_sender_key(&ui)
	testing.expect(t, !valid)
}

@(test)
gs_old_result_keeps_seek_target :: proc(t: ^testing.T) {
	previous := timeline_job
	job: Timeline_Work
	timeline_job = &job
	defer {timeline_job = previous}
	ui := Ui_State {
		jump_id         = strings.clone("old-result"),
		gs_jump_pending = true,
		tl_has_more     = true,
	}
	append(&ui.messages, Msg_Ui{id = "newer-page-anchor"})
	defer {delete(ui.messages); delete(ui.jump_id)}
	testing.expect(t, gs_seek_jump(&ui))
	testing.expect(t, ui.timeline_paging)
	testing.expect(
		t,
		ui.jump_id == "old-result",
		"Paging must not replace the requested hit with its viewport anchor",
	)
	testing.expect_value(t, job.request, Timeline_Direction.Older)
	ui.timeline_paging = false
	ui.messages[0].id = "old-result"
	testing.expect(t, !gs_seek_jump(&ui))
	testing.expect(t, !ui.gs_jump_pending)
	testing.expect_value(t, ui.jump_id, "old-result")
	ui.gs_jump_pending, ui.tl_has_more = true, false
	ui.messages[0].id = "different"
	testing.expect(t, !gs_seek_jump(&ui), "An exhausted history must stop seeking")
	testing.expect(t, !ui.gs_jump_pending)
}

@(test)
gs_account_change_discards_previous_history :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref     = "new-account",
		gs_account      = strings.clone("old-account"),
		gs_group        = strings.clone("old-group"),
		gs_cursor_id    = strings.clone("old-cursor"),
		gs_more         = true,
		gs_jump_pending = true,
		jump_id         = strings.clone("old-message"),
	}
	append(&ui.gs_input, "private phrase")
	append(&ui.gs_chats, chat_clone(Chat_Row_Ui{group_id = "old-group", title = "Private chat"}))
	append(&ui.gs_hits, Gs_Hit{msg_id = strings.clone("old-message")})
	defer {delete(ui.gs_account); delete(ui.gs_input); delete(ui.gs_chats); delete(ui.gs_hits)
		delete(ui.jump_id)}
	gs_open_modal(&ui)
	testing.expect_value(t, ui.gs_account, "new-account")
	testing.expect_value(t, string(ui.gs_input[:]), "")
	testing.expect_value(t, len(ui.gs_hits), 0)
	testing.expect_value(t, len(ui.gs_chats), 0)
	testing.expect_value(t, ui.gs_cursor_id, "")
	testing.expect(t, !gs_has_filters(&ui) && !ui.gs_more)
	testing.expect(
		t,
		!ui.gs_jump_pending && ui.jump_id == "",
		"Account changes must discard pending navigation",
	)
	testing.expect(
		t,
		ui.gs_resume,
		"Opening without a catalog must request this account's local chats",
	)
}

@(test)
gs_archived_destination_owns_navigation_metadata :: proc(t: ^testing.T) {
	ui: Ui_State
	append(
		&ui.gs_chats,
		chat_clone(Chat_Row_Ui{group_id = "archive", title = "Archived history", stable = true}),
	)
	defer {for row in ui.chats {chat_free(row)}; delete(ui.chats); delete(ui.gs_chats)}
	gs_keep_open_chat(&ui, "archive")
	testing.expect_value(t, ui.chats[0].title, "Archived history")
	testing.expect(t, ui.chats[0].search_only && ui.chats[0].stable)
	// Replacing the search catalog must not invalidate an open destination.
	chat_free(ui.gs_chats[0]); clear(&ui.gs_chats)
	testing.expect_value(t, ui.chats[0].group_id, "archive")
	testing.expect_value(t, ui.chats[0].title, "Archived history")
	gs_keep_open_chat(&ui, "archive")
	testing.expect(
		t,
		len(ui.chats) == 1,
		"Repeated navigation must not duplicate the same conversation",
	)
}

@(test)
gs_jump_leaves_settings :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		selected         = -1,
		gs_open          = true,
		timeline_loading = true,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {delete(ui.chats); delete(ui.jump_id); delete(ui.prefs.last_chat)
		delete(ui.unread_mark_id)}
	gs_jump(&ui, nil, "group", "message")
	testing.expect_value(t, ui.page, Page.Chats)
	testing.expect_value(t, ui.selected, 0)
	testing.expect_value(t, ui.jump_id, "message")
	testing.expect(t, ui.gs_jump_pending && !ui.gs_open)
}

// Runs in an isolated SDL process; also writes screenshots for visual review.
@(test)
gs_viewport :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "gs_viewport" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(740, 700, "Global search")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0); set_locale("ja")
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {740, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		gs_open       = true,
		gs_group      = "group",
		gs_attachment = 2,
		gs_more       = true,
	}
	ui.prefs.reduce_motion = true
	append(&ui.gs_input, "literal %_\\")
	append(&ui.gs_sender_input, "Alice")
	append(&ui.gs_since, "2026-09-01")
	append(&ui.gs_until, "2026-09-30")
	append(&ui.gs_chats, Chat_Row_Ui{group_id = "group", title = "History"})
	append(
		&ui.gs_hits,
		Gs_Hit {
			group = "group",
			msg_id = "message",
			title = "History",
			sender = "Alice",
			snippet = "literal %_\\",
			at = "2026-09-30",
		},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.gs_input); delete(ui.gs_sender_input); delete(ui.gs_since); delete(ui.gs_until)
		delete(ui.gs_chats); delete(ui.gs_hits)
	}
	for size in ([][2]i32{{740, 700}, {390, 420}, {740, 500}}) {
		rl.SetWindowSize(size[0], size[1])
		clay.SetLayoutDimensions({f32(size[0]), f32(size[1])})
		for _ in 0 ..< 3 {gs_test_frame(&ui)}
		modal := clay.GetElementData(clay.ID("GsModal")).boundingBox
		body := clay.GetElementData(clay.ID("GsBody")).boundingBox
		testing.expect(
			t,
			modal.x >= 0 &&
			modal.y >= 0 &&
			modal.x + modal.width <= f32(size[0]) &&
			modal.y + modal.height <= f32(size[1]),
			"Search modal must fit the viewport",
		)
		testing.expect(
			t,
			body.height >= 44 && body.y + body.height <= modal.y + modal.height,
			"Short windows must retain a scrollable search body",
		)
		clay.SetPointerState({body.x + body.width / 2, body.y + body.height / 2}, false)
		gs_test_frame(&ui, {0, -10000})
		for _ in 0 ..< 2 {gs_test_frame(&ui)}
		more := clay.GetElementData(clay.ID("GsMore")).boundingBox
		testing.expect(
			t,
			more.y >= body.y && more.y + more.height <= body.y + body.height + 1,
			"Scrolling must reveal the complete paging action",
		)
		ui.gs_loading = true
		for _ in 0 ..< 3 {gs_test_frame(&ui)}
		body = clay.GetElementData(clay.ID("GsBody")).boundingBox
		busy := clay.GetElementData(clay.ID("GsBusy"))
		testing.expect(
			t,
			busy.found &&
			busy.boundingBox.y >= modal.y &&
			busy.boundingBox.y + busy.boundingBox.height <= body.y,
			"Pending feedback must stay visible above the scrolled controls",
		)
		ui.gs_loading = false
		commands := gs_test_frame(&ui)
		rl.BeginDrawing(); clay_raylib_render(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-gsearch-%d-%d.png", size[0], size[1]))
		rl.EndDrawing()
	}
}

@(private)
gs_test_frame :: proc(
	ui: ^Ui_State,
	wheel: clay.Vector2 = {},
) -> clay.ClayArray(clay.RenderCommand) {
	anim_tick(1.0 / 60)
	open_now(clay.ID("GsModal"), true)
	clay.UpdateScrollContainers(false, wheel, 1.0 / 60)
	clay.BeginLayout()
	if clay.UI(clay.ID("GsTestRoot"))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}},
		backgroundColor = BG,
	},
	) {gsearch_modal(ui)}
	return clay.EndLayout(0)
}
