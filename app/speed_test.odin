package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"
import rl "sdlrl"

@(test)
chat_refresh_ownership :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	old_retired := retired_chats
	retired_chats = {}
	rows: [dynamic]Chat_Row_Ui
	for i in 0 ..< 1000 {
		fresh := make([dynamic]Chat_Row_Ui)
		append(&fresh, Chat_Row_Ui{group_id = strings.clone("a"), title = strings.clone("unchanged")})
		append(&fresh, Chat_Row_Ui{group_id = strings.clone("b"), title = fmt.aprintf("revision %d", i)})
		old := len(rows) > 0 ? raw_data(rows[0].title) : nil
		borrowed := len(rows) > 0 ? rows[1].title : ""
		chats_replace(&rows, fresh)
		if i > 0 {
			testing.expect_value(t, raw_data(rows[0].title), old)
			testing.expect_value(t, borrowed, fmt.tprintf("revision %d", i - 1))
		}
		chats_collect()
	}
	for row in rows { chat_free(row) }
	delete(rows); delete(retired_chats)
	retired_chats = old_retired
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
search_cache_and_stale :: proc(t: ^testing.T) {
	ui := Ui_State{account_ref = "account", gs_open = true}
	append(&ui.gs_input, "cafe")
	defer delete(ui.gs_input)
	job := new(Search_Job)
	job.account, job.input = strings.clone("account"), strings.clone("cafe")
	job.revision = search_revision
	append(&job.groups, strings.clone("group"))
	records := [?]marmot.Timeline_Message_Record{
		{message_id_hex = "match", plaintext = "Café", sender = "sender", kind = 9},
		{message_id_hex = "deleted", plaintext = "cafe", deleted = true},
		{message_id_hex = "hidden", plaintext = "cafe"},
	}
	page := marmot.Timeline_Page{messages = raw_data(records[:]), messages_len = len(records)}
	folded := make([]string, len(records))
	for r, i in records { folded[i] = gs_fold(string(r.plaintext), context.allocator) }
	job.cache[strings.clone("group")] = {&page, folded}
	job.hidden[strings.clone("hidden")] = true
	// A nil client makes any accidental repeated database query fail this check.
	worker := thread.Thread{data = job}
	search_worker(&worker)
	testing.expect_value(t, len(job.hits), 1)
	testing.expect_value(t, job.hits[0].msg_id, "match")
	testing.expect(t, search_current(job, &ui))
	ui.account_ref = "other"
	testing.expect(t, !search_current(job, &ui))
	ui.account_ref = "account"
	append(&ui.gs_input, "x")
	testing.expect(t, !search_current(job, &ui))
	entry := job.cache["group"]
	entry.page = nil // the fixture page is stack-owned
	job.cache["group"] = entry
	search_free(job)
}

@(test)
timeline_scope_changes :: proc(t: ^testing.T) {
	// Worker results use the process allocator, as in the running app.
	context.allocator = runtime.default_context().allocator
	old := timeline_job
	old_retired := timeline_retired
	timeline_retired = {}
	defer { timeline_job = old; timeline_retired = old_retired }
	job := Timeline_Work{account = "account", group = "group", search = ""}
	timeline_job = &job
	ui := Ui_State{account_ref = "account"}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer delete(ui.chats)
	testing.expect(t, timeline_scope(&ui, ""))
	testing.expect(t, !timeline_scope(&ui, "new search"))
	ui.account_ref = "other"
	testing.expect(t, !timeline_scope(&ui, ""))
	ui.selected = -1
	testing.expect(t, !timeline_scope(&ui, ""))
	timeline_job = nil
	ui.selected = 0
	ui.account_ref = "account"
	// A failed old scope must not publish its error into the next chat.
	timeline_start(nil, &ui, "")
	thread.join(timeline_job.worker)
	ui.account_ref = "other"
	timeline_drain(&ui, nil)
	testing.expect_value(t, ui.client_status, "")
	testing.expect(t, timeline_job == nil)
	timeline_start(nil, &ui, "")
	thread.join(timeline_job.worker)
	timeline_drain(&ui, nil)
	testing.expect(t, ui.client_status != "")
	testing.expect(t, !ui.timeline_loading)
	delete(ui.client_status)
	timeline_stop()
}

@(test)
edit_completion_scope :: proc(t: ^testing.T) {
	old := failed_edits
	failed_edits = {}
	defer { delete(failed_edits); failed_edits = old }
	ui := Ui_State{account_ref = "account", editing = "message", edit_ticket = 1}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	append(&ui.messages, Msg_Ui{id = "message"})
	ui.drafts["group"] = "draft"
	defer { delete(ui.chats); delete(ui.messages); delete(ui.compose); delete(ui.drafts); delete(ui.client_status) }
	ed_set(&ui, &ui.compose, "newer typing")
	complete := proc(err: string) -> Op_Done {
		return {ticket = 1, op = .Edit, account = strings.clone("account"), group = strings.clone("group"),
			target = strings.clone("message"), content = strings.clone("submitted"), err = strings.clone(err)}
	}
	edit_complete(&ui, complete(""))
	testing.expect_value(t, ui.edit_ticket, 0)
	testing.expect_value(t, string(ui.compose[:]), "newer typing")
	testing.expect_value(t, ui.editing, "message")
	ui.account_ref = "other"
	edit_complete(&ui, complete("offline"))
	edit_restore(&ui)
	testing.expect_value(t, string(ui.compose[:]), "newer typing")
	ui.account_ref = "account"
	edit_restore(&ui)
	testing.expect_value(t, string(ui.compose[:]), "submitted")
	testing.expect_value(t, ui.editing, "message")
	edit_complete(&ui, complete(""))
	testing.expect_value(t, len(failed_edits), 0)
	testing.expect_value(t, ui.editing, "")
	testing.expect_value(t, string(ui.compose[:]), "draft")
}

// SDL and Clay globals need a dedicated run, as with performance_layout.
@(test)
performance_sidebar :: proc(t: ^testing.T) {
	when !#config(WN_PERF, false) { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Sidebar regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	ui := Ui_State{row_menu = -1, member_menu = -1, selected_contact = -1}
	g_ui, g_prefs = &ui, &ui.prefs
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	for i in 0 ..< 100 {
		append(&ui.messages, Msg_Ui{id = fmt.aprintf("message-%d", i), sender = strings.clone("Alice"),
			body = fmt.aprintf("Message %d. A paragraph with several words to wrap across the conversation pane.", i)})
	}
	for i in 0 ..< 1000 {
		append(&ui.chats, Chat_Row_Ui{group_id = fmt.aprintf("chat-%d", i), title = fmt.aprintf("Conversation %d", i), preview = "A short preview with several words."})
	}
	for _ in 0 ..< 5 { anim_tick(1.0 / 60); build_layout(&ui, 1.0 / 60) }
	data := clay.GetScrollContainerData(clay.ID("ChatList"))
	testing.expect(t, data.found)
	testing.expect(t, clay.GetScrollContainerData(clay.ID("Timeline")).found)
	testing.expect_value(t, len(ui.rail_rows), 1000)
	full_height := 1000 * (chat_row_height() + 6) - 6
	testing.expect(t, abs(data.contentDimensions.height - full_height) < 1)
	samples: [31]f64
	for &ms in samples {
		anim_tick(1.0 / 60)
		start := time.tick_now()
		build_layout(&ui, 1.0 / 60)
		ms = time.duration_milliseconds(time.tick_since(start))
		free_all(context.temp_allocator)
	}
	slice.sort(samples[:])
	fmt.printf("sidebar chats=1000 median_ms=%.3f p95_ms=%.3f\n", samples[15], samples[29])
	for fraction in ([]f32{0, 0.5, 1}) {
		data.scrollPosition.y = -fraction * (full_height - data.scrollContainerDimensions.height)
		build_layout(&ui, 0)
		mounted := 0
		for _, i in ui.chats { if clay.GetElementData(clay.ID("ChatRow", u32(i))).found { mounted += 1 } }
		testing.expect(t, mounted > 0 && mounted < 30)
		testing.expect(t, abs(data.contentDimensions.height - full_height) < 1)
	}
	testing.expect(t, clay.GetElementData(clay.ID("ChatRow", 999)).found)
	commands := build_layout(&ui, 0)
	rl.BeginDrawing()
	draw_frame(&commands)
	rl.TakeScreenshot("/tmp/wn-sidebar-regression.png")
	rl.EndDrawing()
	ui.page = .Archived
	ui.archived = ui.chats
	for _ in 0 ..< 3 { build_layout(&ui, 0) }
	archive := clay.GetScrollContainerData(clay.ID("ArchivedList"))
	testing.expect(t, archive.found)
	testing.expect(t, abs(archive.contentDimensions.height - (1000 * (chat_row_height() + 8) - 8)) < 1)
	archive.scrollPosition.y = -(archive.contentDimensions.height - archive.scrollContainerDimensions.height)
	build_layout(&ui, 0)
	testing.expect(t, clay.GetElementData(clay.ID("ChatRow", 999)).found)
	for msg in ui.messages { message_free(msg) }
	delete(ui.messages)
	wrap_clear()
	for row in ui.chats { delete(row.group_id); delete(row.title) }
	delete(ui.chats); delete(ui.accounts); delete(ui.rail_rows)
	g_ui, g_prefs = nil, nil
}
