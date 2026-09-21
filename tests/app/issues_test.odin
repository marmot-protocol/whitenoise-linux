package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import rl "sdlrl"

@(private = "file")
issue_test_record :: proc(
	kind: u64,
	id, sender: string,
	at: u64,
	tags: [][]string,
	group: string = "group",
) -> marmot.App_Message_Record {
	rows := make([]marmot.Message_Tag, len(tags), context.temp_allocator)
	for tag, i in tags {
		values := make([]cstring, len(tag), context.temp_allocator)
		for value, j in tag {values[j] = strings.clone_to_cstring(value, context.temp_allocator)}
		rows[i] = {raw_data(values), uint(len(values))}
	}
	return {
		message_id_hex = strings.clone_to_cstring(id, context.temp_allocator),
		sender = strings.clone_to_cstring(sender, context.temp_allocator),
		group_id_hex = strings.clone_to_cstring(group, context.temp_allocator),
		plaintext = "Body",
		kind = kind,
		recorded_at = at,
		tags = raw_data(rows),
		tags_len = uint(len(rows)),
	}
}

@(test)
issue_settings_and_projection :: proc(t: ^testing.T) {
	testing.expect_value(t, issue_setting([]u8{1, 0}), Issue_Setting.Disabled)
	testing.expect_value(t, issue_setting([]u8{1, 1}), Issue_Setting.Enabled)
	malformed_values := [][]u8{nil, {1}, {2, 1}, {1, 2}, {1, 1, 0}}
	for malformed in malformed_values {
		testing.expect_value(t, issue_setting(malformed), Issue_Setting.Unavailable)
	}
	root := strings.repeat("a", 64, context.temp_allocator)
	author := strings.repeat("b", 64, context.temp_allocator)
	admin := strings.repeat("c", 64, context.temp_allocator)
	member := strings.repeat("d", 64, context.temp_allocator)
	status1 := strings.repeat("1", 64, context.temp_allocator)
	status2 := strings.repeat("2", 64, context.temp_allocator)
	comment := strings.repeat("3", 64, context.temp_allocator)
	spoof := strings.repeat("4", 64, context.temp_allocator)
	tags := [][]string{{"e", root, "", "root"}}
	comments := [][]string {
		{"E", root, "", author},
		{"K", "1621"},
		{"P", author},
		{"e", root, "", author},
		{"k", "1621"},
		{"p", author},
	}
	records := []marmot.App_Message_Record {
		issue_test_record(1631, status1, author, 20, tags),
		issue_test_record(1111, comment, member, 15, comments),
		issue_test_record(1632, status2, admin, 20, tags),
		issue_test_record(1621, root, author, 10, [][]string{{"subject", "Report"}}),
		issue_test_record(1630, spoof, member, 99, tags),
		issue_test_record(1111, comment, member, 15, comments), // duplicate
	}
	records[2].has_moderation_grant, records[2].moderation_grant = true, true
	rows, index := issues_project(records, "group", 100)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[index[root]].status, Issue_Status.Closed)
	testing.expect_value(t, len(rows[0].comments), 1)
	issues_rows_free(rows, index)
	// Losing-branch tombstones and unknown source authority cannot moderate.
	records[2].invalidated = true
	rows, index = issues_project(records, "group", 100)
	testing.expect_value(t, rows[index[root]].status, Issue_Status.Resolved)
	issues_rows_free(rows, index)
	records[2].invalidated = false
	records[2].has_moderation_grant = false
	rows, index = issues_project(records, "group", 100)
	testing.expect_value(t, rows[index[root]].status, Issue_Status.Resolved)
	issues_rows_free(rows, index)
	records[2].has_moderation_grant = true
	// Current roster changes cannot retroactively authorize an old member event.
	records[4].has_moderation_grant = true
	records[4].moderation_grant = false
	for i in 0 ..< len(records) / 2 {records[i], records[len(records) - 1 - i] = records[len(records) - 1 - i], records[i]}
	rows, index = issues_project(records, "group", 100)
	testing.expect_value(t, rows[index[root]].status, Issue_Status.Closed)
	testing.expect_value(t, len(rows[0].comments), 1)
	issues_rows_free(rows, index)
	rows, index = issues_project(records, "other-group", 100)
	testing.expect_value(t, len(rows), 0)
	issues_rows_free(rows, index)
	for &record in records {
		if record.kind ==
		   1621 {record.has_retention_expires_at = true; record.retention_expires_at = 100}
	}
	rows, index = issues_project(records, "group", 100)
	testing.expect_value(t, len(rows), 0)
	issues_rows_free(rows, index)
	malformed := issue_test_record(
		1621,
		root,
		author,
		10,
		[][]string{{"subject", "One"}, {"subject", "Two"}},
	)
	rows, index = issues_project([]marmot.App_Message_Record{malformed}, "group", 100)
	testing.expect_value(t, len(rows), 0)
	issues_rows_free(rows, index)
	reply := issue_test_record(1111, comment, member, 15, comments)
	testing.expect(t, issue_chat_hidden(1111, reply.tags[:reply.tags_len]))
	testing.expect(t, !issue_chat_hidden(1111, nil))
	testing.expect(t, issue_chat_hidden(1621, nil))
	testing.expect(t, issue_chat_hidden(1632, nil))
	testing.expect(t, !issue_chat_hidden(9, nil))
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=issues_layout
@(test)
issues_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "issues_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1280, 800, "Issues")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1280, 800})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		issue_setting    = .Enabled,
		issues_open      = true,
		issue_admin      = true,
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "Project discussion"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; issue_page = nil}
	root := "66675158e6338fe89fda418e42a0bf2a7a2b132504dd347f015a18971b644430"
	author := strings.repeat("b", 64, context.temp_allocator)
	ui.account_ref = author
	start_pic_worker()
	defer stop_pic_worker()
	for key in ([]string{root, author}) {
		url := fmt.tprintf("crop-circle:%s", key)
		for n := 0;
		    url_pic(url) == nil && n < 100;
		    n += 1 {time.sleep(10 * time.Millisecond); drain_pics()}
	}
	now := u64(time.time_to_unix(time.now()))
	records := []marmot.App_Message_Record {
		issue_test_record(
			1621,
			root,
			author,
			now - 3600,
			[][]string{{"subject", "Notifications stop after reconnect"}, {"t", "bug"}},
		),
		issue_test_record(
			1111,
			strings.repeat("c", 64, context.temp_allocator),
			author,
			now - 1800,
			[][]string {
				{"E", root},
				{"K", "1621"},
				{"P", author},
				{"e", root},
				{"k", "1621"},
				{"p", author},
			},
		),
	}
	records[0].plaintext = "Reconnect succeeds, but new messages no longer trigger desktop notifications.\n\nSteps: disconnect the network, reconnect, then send another message."
	records[1].plaintext = "I can reproduce this after resuming from sleep."
	page := marmot.App_Message_List{raw_data(records), uint(len(records))}
	issue_page = &page
	ui.issues, ui.issue_index = issues_project(records, "group", now)
	defer issues_rows_free(ui.issues, ui.issue_index)
	msg := Msg_Ui {
		id        = string(records[1].message_id_hex),
		sender    = "You",
		sender_id = author,
		mine      = true,
		body      = string(records[1].plaintext),
		at        = "11:42",
		thread_of = root,
	}
	append(
		&msg.reactions,
		Reaction_Ui {
			emoji = "👍",
			label = "👍 2",
			count = "2",
			mine = true,
			who = "You, Jordan",
		},
	)
	append(&ui.messages, msg)
	for theme in 0 ..< 2 {
		apply_theme(theme, 0)
		set_locale(theme == 0 ? "en" : "de")
		for width in ([]i32{1280, 420}) {
			rl.SetWindowSize(width, 800)
			clay.SetLayoutDimensions({f32(width), 800})
			for mode in 0 ..< 3 {
				ui.issue_selected = mode == 0 ? "" : root
				ui.issue_new = mode == 2
				ui.focus = ui.issue_new ? .Issue_Body : .Compose
				ui.compose_issue = ui.issue_new || mode == 0 ? "" : root
				if ui.issue_new {ed_set(&ui, &ui.issue_body, "Describe what happened.\n\nAdd steps to reproduce it here.")}
				for frame in 0 ..< 3 {
					commands := build_layout(&ui, 0)
					if frame < 2 {continue}
					for id in ([]string{"IssueSidebar", "IssueDetail", "IssueCreate", "ComposeBox", "IssueStatusBar", "IssueIdentityDetail", "ComposeTools"}) {
						box := clay.GetElementData(clay.ID(id))
						if box.found {testing.expect(t, box.boundingBox.x >= 0 && box.boundingBox.x + box.boundingBox.width <= f32(width) + 1, id)}
					}
					testing.expect(
						t,
						clay.GetElementData(clay.ID(mode == 0 ? "IssueSidebar" : "IssueDetail")).found,
					)
					rl.BeginDrawing(); draw_frame(&commands)
					rl.TakeScreenshot(fmt.ctprintf("/tmp/issues-%d-%d-%d.png", theme, width, mode))
					rl.EndDrawing()
				}
			}
		}
	}
}


@(test)
issue_comment_routes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := strings.repeat("a", 64)
	author := strings.repeat("b", 64)
	comment := strings.repeat("c", 64)
	records := []marmot.App_Message_Record {
		issue_test_record(1621, root, author, 1, [][]string{{"subject", "Report"}}),
		issue_test_record(
			1111,
			comment,
			author,
			2,
			[][]string {
				{"E", root},
				{"K", "1621"},
				{"P", author},
				{"e", root},
				{"k", "1621"},
				{"p", author},
				{"p", strings.repeat("d", 64, context.temp_allocator)},
				{"imeta", "url https://example.com/a"},
				{"imeta", "url https://example.com/b"},
			},
		),
	}
	records[1].plaintext = ""
	page := marmot.App_Message_List{raw_data(records), uint(len(records))}
	old_page := issue_page
	issue_page = &page
	defer {issue_page = old_page}
	ui := Ui_State {
		issue_setting  = .Enabled,
		issues_open    = true,
		issue_selected = root,
		account_ref    = author,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	ui.issues, ui.issue_index = issues_project(records, "group", 10)
	testing.expect(t, len(ui.issues[0].comments) == 1, "attachment-only albums are comments")
	ed_set(&ui, &ui.compose, "chat draft")
	append(&ui.staged, Staged_File{name = "chat.txt"})
	issues_sync_route(&ui, nil)
	testing.expect_value(t, string(ui.compose[:]), "")
	testing.expect_value(t, len(ui.staged), 0)
	testing.expect_value(t, thread_cur(&ui), root)
	ui.replying = comment
	reply := issue_reply(&ui)
	tags := issue_reply_tags(reply)
	testing.expect_value(t, tags[0][1], root)
	testing.expect_value(t, tags[3][1], comment)
	testing.expect_value(t, tags[4][1], "1111")
	testing.expect_value(t, tags[5][1], author)
	// The queued address survives switching routes and serializing an offline send.
	item := Offline_Item {
		thread = root,
		issue  = reply,
	}
	encoded, err := json.marshal(item, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	restored: Offline_Item
	testing.expect(t, json.unmarshal(encoded, &restored) == nil)
	testing.expect_value(t, restored.issue.parent, comment)
	testing.expect_value(t, restored.thread, root)
	ed_set(&ui, &ui.compose, "issue draft")
	append(&ui.staged, Staged_File{name = "issue.txt"})
	ui.issues_open = false
	issues_sync_route(&ui, nil)
	testing.expect_value(t, string(ui.compose[:]), "chat draft")
	testing.expect_value(t, ui.staged[0].name, "chat.txt")
	ui.issues_open = true
	issues_sync_route(&ui, nil)
	testing.expect_value(t, string(ui.compose[:]), "issue draft")
	testing.expect_value(t, ui.staged[0].name, "issue.txt")
	testing.expect_value(t, ui.replying, "")
}
