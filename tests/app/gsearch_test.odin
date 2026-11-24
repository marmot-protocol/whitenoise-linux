// Global-search dates, filters, preserved requests, and snippets.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "nendo"
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
gs_local_date_boundaries :: proc(t: ^testing.T) {
	ui: Ui_State
	defer {delete(ui.gs_since); delete(ui.gs_until)}
	// Bounds are the local midnights around the day, in any timezone.
	append(&ui.gs_since, "2000-02-29")
	append(&ui.gs_until, "2000-02-29")
	since, until, valid := gs_dates(&ui)
	testing.expect(t, valid)
	testing.expect_value(t, local_seconds(since), u64(951782400))
	testing.expect_value(t, local_seconds(until), u64(951868800))

	// Every displayed date form names the same day.
	iso, _ := gs_day("2000-02-29")
	for form in ([]string{"Feb 29, 2000", "29 Feb 2000", "feb. 29 2000", " Feb 29 , 2000 "}) {
		days, ok := gs_day(form)
		testing.expect(t, ok && days == iso, form)
	}

	// A missing year is the current local year.
	this_year := local_time(now_unix()).year
	days, ok := gs_day("Jan 1")
	dated, _ := gs_day(fmt.tprintf("Jan 1, %d", this_year))
	testing.expect(t, ok && days == dated, "Jan 1 without a year")

	for bad in ([]string{"2100-02-29", "2025-02-29", "2026-04-31", "1969-12-31", "2026-1-01", "2026-10-00", "Feb 30", "Smarch 3", "3", "Oct 3 26", "Oct Oct", "Oct 3 2026 1"}) {
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
	testing.expect_value(t, local_seconds(until), u64(1790899200))
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

// Choosing a Known senders entry fills the field with its name, never the
// hex key, and that name must resolve back to the chosen key, even when
// another contact shares the display name.
@(test)
gs_known_sender_shows_name :: proc(t: ^testing.T) {
	SELF :: "05c6a606d76f90238022afe4b92824d44127f10c42d68605c16ae072262f4b8f"
	ALICE :: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	TWIN :: "1111111111111111111111111111111111111111111111111111111111111111"
	ui := Ui_State {
		gs_picker   = 2,
		account_ref = SELF,
	}
	append(&ui.contacts, Contact_Ui{id_hex = ALICE, name = "Alice"})
	append(&ui.contacts, Contact_Ui{id_hex = TWIN, name = "Alice"})
	append(&ui.gs_senders, ALICE, TWIN)
	defer {delete(ui.contacts); delete(ui.gs_senders); delete(ui.gs_sender_input)}
	for i in 1 ..< len(ui.gs_senders) + 2 {
		label, want := gs_option(&ui, i)
		testing.expect(t, deeplink_hex(label) == "", "A known sender must be listed by name")
		ui.gs_sender = want
		clear(&ui.gs_sender_input); append(&ui.gs_sender_input, label)
		key, valid := gs_sender_key(&ui)
		testing.expect(t, valid)
		testing.expect_value(t, key, want)
	}
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
	defer {delete(ui.messages); delete(ui.jump_id); delete(ui.gs_flash_id)}
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
chat_refresh_remaps_selection :: proc(t: ^testing.T) {
	// Chat refresh writes the global profile cache and retired_chats. They
	// outlive this test, so they must not grow in its per-test allocator.
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	context.allocator = runtime.default_context().allocator
	defer profile_session_clear()
	rows := [?]marmot.Presented_Chat_Row {
		{row = {group_id_hex = "notes"}},
		{row = {group_id_hex = "peer"}},
	}
	list := marmot.Presented_Chat_List {
		rows     = raw_data(rows[:]),
		rows_len = len(rows),
	}
	job := Chat_List_Work {
		account = "acct",
		rows    = &list,
	}
	ui: Ui_State
	defer {
		chats_collect()
		for chat in ui.chats {chat_free(chat)}
		delete(ui.chats)
		for chat in ui.gs_chats {chat_free(chat)}
		delete(ui.gs_chats)
		delete(ui.filter_hits)
	}

	// The restored conversation was first until the new notepad arrived.
	append(&ui.chats, chat_clone(Chat_Row_Ui{group_id = "peer"}))
	ui.selected = 0
	chat_list_apply(&ui, &job)
	if !testing.expect_value(t, ui.selected, 1) {return}
	testing.expect_value(t, ui.chats[ui.selected].group_id, "peer")

	list.rows_len = 1
	chat_list_apply(&ui, &job)
	testing.expect_value(t, ui.selected, -1)

	for chat in ui.chats {chat_free(chat)}
	clear(&ui.chats)
	ui.selected = 0
	append(&ui.chats, chat_clone(Chat_Row_Ui{group_id = "archived", search_only = true}))
	chat_list_apply(&ui, &job)
	testing.expect_value(t, ui.selected, -1)
	testing.expect_value(t, len(ui.chats), 1)
	testing.expect_value(t, ui.chats[0].group_id, "notes")

	for chat in ui.chats {chat_free(chat)}
	clear(&ui.chats)
	append(&ui.chats, chat_clone(Chat_Row_Ui{group_id = "archived", search_only = true}))
	append(&ui.gs_chats, chat_clone(Chat_Row_Ui{group_id = "archived", title = "Archived"}))
	ui.selected = 0
	chat_list_apply(&ui, &job)
	testing.expect_value(t, ui.selected, 1)
	testing.expect_value(t, ui.chats[ui.selected].group_id, "archived")
	testing.expect(t, ui.chats[ui.selected].search_only)
}

@(test)
gs_remember_skips_blank_query :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gs-recent", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	ui: Ui_State
	defer {
		for q in ui.prefs.recent_searches {delete(q)}
		delete(ui.prefs.recent_searches)
		delete(ui.gs_input)
	}
	append(&ui.gs_input, " \t ")
	gs_remember(&ui)
	testing.expect_value(t, len(ui.prefs.recent_searches), 0)
	clear(&ui.gs_input)
	append(&ui.gs_input, "  hello  ")
	gs_remember(&ui)
	testing.expect_value(t, len(ui.prefs.recent_searches), 1)
	testing.expect_value(t, ui.prefs.recent_searches[0], "hello")
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
	dir, err := os.make_directory_temp("", "wn-search-viewport-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	if !testing.expect_value(
		t,
		marmot.client_new(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)

	rl.InitWindow(740, 700, "Global search")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0); set_locale("ja")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {740, 700})
	defer {nendo.set_context(previous); delete(memory)}
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
		gs_layout_free(&ui.gs_layout)
	}
	for size in ([][2]i32{{740, 700}, {390, 420}, {740, 500}, {800, 180}, {180, 300}}) {
		rl.SetWindowSize(size[0], size[1])
		nendo.set_dimensions({f32(size[0]), f32(size[1])})
		for _ in 0 ..< 3 {gs_test_frame(&ui)}
		modal := nendo.element(nendo.id("GsModal")).rect
		body := nendo.element(nendo.id("GsBody")).rect
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
			body.height >= (size[1] == 180 ? 16 : 44) &&
			body.y + body.height <= modal.y + modal.height,
			"Short windows must retain a scrollable search body",
		)
		nendo.set_pointer({body.x + body.width / 2, body.y + body.height / 2}, .Up)
		gs_test_frame(&ui, {0, -10000})
		for _ in 0 ..< 2 {gs_test_frame(&ui)}
		thumb_id := nendo.id("ScrollThumb", nendo.id("GsBody").id)
		prior_thumb := nendo.element(thumb_id)
		more := nendo.element(nendo.id("GsMore"))
		if !testing.expect(
			t,
			more.found &&
			(more.rect.y >= body.y || more.rect.height > body.height) &&
			more.rect.y + more.rect.height > body.y &&
			more.rect.y + more.rect.height <= body.y + body.height + 1,
			"Scrolling must bring the paging action into reach",
		) {continue}
		nendo.set_pointer(
			{
				more.rect.x + more.rect.width / 2,
				(max(body.y, more.rect.y) + more.rect.y + more.rect.height) / 2,
			},
			.Up,
		)
		forced_release = true
		handle_gsearch(&ui, client)
		forced_release = false

		// Leave the page queued so it cannot finish between frames.
		wheel: nendo.Vector2
		for frame in 0 ..< 3 {
			commands := gs_test_frame(&ui, wheel)
			pending_body := nendo.element(nendo.id("GsBody")).rect
			busy := nendo.element(nendo.id("GsBusy"))
			label_visible := false
			for cmd in commands {
				if cmd.kind == .Text &&
				   cmd.text.text == tr("Searching local history…") &&
				   cmd.rect.y >= modal.y &&
				   cmd.rect.y + cmd.rect.height <= pending_body.y {
					label_visible = true
					break
				}
			}
			testing.expect(
				t,
				label_visible &&
				busy.found &&
				busy.rect.y >= modal.y &&
				busy.rect.y + busy.rect.height <= pending_body.y,
				"Pending feedback must stay visible above the scrolled controls",
			)
			testing.expect(
				t,
				busy.rect.x >= modal.x && busy.rect.x + busy.rect.width <= modal.x + modal.width,
				"The progress track must fit in the modal",
			)
			testing.expect_value(t, pending_body, body)
			if frame == 0 {
				thumb := nendo.element(thumb_id)
				testing.expect_value(t, thumb.found, prior_thumb.found)
				testing.expect_value(t, thumb.rect, prior_thumb.rect)
				rl.BeginDrawing(); render_nendo(commands)
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-gsearch-%d-%d.png", size[0], size[1]))
				rl.EndDrawing()
			}
			nendo.set_pointer({body.x + body.width / 2, body.y + body.height / 2}, .Up)
			wheel = {0, 20}
		}
		search_stop()
		ui.gs_loading = false
		gs_test_frame(&ui)
		testing.expect(
			t,
			!nendo.element(nendo.id("GsBusy")).found,
			"Completed searches hide progress",
		)
	}
}

@(test)
gs_virtual_results :: proc(t: ^testing.T) {
	if !test_isolated("gs_virtual_results") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 800, "Global search results")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {900, 800})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		gs_open          = true,
		gs_group         = "group",
		selected         = -1,
		timeline_loading = true,
	}
	ui.prefs.reduce_motion = true
	append(&ui.gs_input, "needle")
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "History"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		gs_clear_hits(&ui); delete(ui.gs_hits); gs_layout_free(&ui.gs_layout)
		delete(ui.gs_input); delete(ui.chats); delete(ui.jump_id); delete(ui.prefs.last_chat)
	}
	append_page :: proc(ui: ^Ui_State, count: int) {
		start := len(ui.gs_hits)
		for i in start ..< start + count {
			append(
				&ui.gs_hits,
				Gs_Hit {
					group = strings.clone("group"),
					msg_id = fmt.aprintf("message-%d", i),
					title = strings.clone(
						i % 2 == 0 ? "History" : "A long conversation title that keeps going until it wraps into another visible line",
					),
					sender = strings.clone("Alice"),
					at = strings.clone("2026-09-30, 12:34"),
					snippet = strings.clone(
						i % 2 == 0 ? "one needle" : "The needle was in a paragraph long enough to wrap. Several more words show whether each result still gets the full snippet.",
					),
				},
			)
		}
	}
	owner := nendo.id("GsList")
	append_page(&ui, GS_HITS_MAX)
	commands := gs_test_frame(&ui)
	first, second := nendo.element(nendo.id("GsHit", 0)), nendo.element(nendo.id("GsHit", 1))
	testing.expect(t, first.found && second.found && second.rect.height > first.rect.height)
	accent := false
	for cmd in commands {
		if cmd.kind == .Text &&
		   cmd.text.text == "needle" &&
		   cmd.text.color == ACCENT {accent = true}
	}
	testing.expect(t, accent)
	data := nendo.scroll(owner)
	if !testing.expect(t, data.found && data.content.height > data.viewport.height) {return}
	data.position.y = data.viewport.height - data.content.height
	gs_test_frame(&ui)
	end_of_page := nendo.id("GsHit", GS_HITS_MAX - 1)
	page_tail := nendo.element(end_of_page)
	before := data.position.y
	append_page(&ui, 5 * GS_HITS_MAX)
	gs_test_frame(&ui)
	testing.expect(t, page_tail.found && nendo.element(end_of_page).rect.y == page_tail.rect.y)
	testing.expect_value(t, nendo.scroll(owner).position.y, before)

	desktop_height := nendo.scroll(owner).content.height
	last_id := nendo.id("GsHit", u32(len(ui.gs_hits) - 1))
	for width in ([]i32{900, 390, 900}) {
		rl.SetWindowSize(width, 800)
		nendo.set_dimensions({f32(width), 800})
		gs_test_frame(&ui)
		data = nendo.scroll(owner)
		height := data.content.height
		testing.expect(t, width == 390 ? height > desktop_height : height == desktop_height)
		data.position.y = data.viewport.height - height
		commands = gs_test_frame(&ui)
		viewport := nendo.element(owner).rect
		last := nendo.element(last_id)
		testing.expect(
			t,
			last.found &&
			last.rect.y >= viewport.y &&
			last.rect.y + last.rect.height <= viewport.y + viewport.height + 0.01,
		)
		mounted := 0
		for _, i in ui.gs_hits {
			if nendo.element(nendo.id("GsHit", u32(i))).found {mounted += 1}
		}
		testing.expect(t, mounted > 0 && mounted < 15)
		if width == 390 {
			rl.BeginDrawing(); render_nendo(commands)
			rl.TakeScreenshot("/tmp/wn-gsearch-results.png")
			rl.EndDrawing()
		}
	}

	clear(&ui.gs_input) // A filter-only click does not write search history.
	last := nendo.element(last_id).rect
	nendo.set_pointer({last.x + last.width / 2, last.y + last.height / 2}, .Up)
	forced_release = true
	handle_gsearch(&ui, nil)
	forced_release = false
	testing.expect(t, !ui.gs_open && ui.gs_jump_pending)
	testing.expect_value(t, ui.jump_id, "message-239")

	gs_clear_hits(&ui)
	append_page(&ui, 1)
	gs_test_frame(&ui)
	new_hit := nendo.element(nendo.id("GsHit", 0))
	testing.expect(t, new_hit.found && new_hit.rect.y == nendo.element(owner).rect.y)

	// Use a wide highlight face so measuring in the body face clips visibly.
	rl.SelectFontStack(FONT_TITLE, FONT_MONO)
	nendo.reset_measure_cache()
	rl.SetWindowSize(390, 800)
	nendo.set_dimensions({390, 800})
	query := strings.repeat("i", 60, context.temp_allocator)
	append(&ui.gs_input, query)
	gs_clear_hits(&ui)
	append_page(&ui, 1)
	delete(ui.gs_hits[0].snippet)
	ui.gs_hits[0].snippet = strings.concatenate({query, "🙂🙂🙂tail"})
	commands = gs_test_frame(&ui)
	card := nendo.element(nendo.id("GsHit", 0)).rect
	header := nendo.element(nendo.id("GsHitTop", 0)).rect
	end := card.x + card.width - 10
	match_bytes := 0
	found_tail := false
	for cmd in commands {
		if cmd.kind != .Text ||
		   cmd.rect.y < header.y + header.height ||
		   cmd.rect.y >= card.y + card.height {
			continue
		}
		testing.expect(t, cmd.rect.x + cmd.rect.width <= end + 0.01, cmd.text.text)
		if cmd.text.color == ACCENT {match_bytes += len(cmd.text.text)}
		found_tail ||= strings.contains(cmd.text.text, "tail")
	}
	testing.expect_value(t, match_bytes, len(query))
	testing.expect(t, found_tail)
}

@(private)
gs_test_frame :: proc(ui: ^Ui_State, wheel: nendo.Vector2 = {}) -> []nendo.Render_Command {
	anim_tick(1.0 / 60)
	open_now(nendo.id("GsModal"), true)
	nendo.update_scroll(.Off, wheel, 1.0 / 60)
	nendo.begin()
	if nendo.box(nendo.id("GsTestRoot"))(
	{width = nendo.grow(), height = nendo.grow(), color = BG},
	) {gsearch_modal(ui)}
	return nendo.end(0)
}
