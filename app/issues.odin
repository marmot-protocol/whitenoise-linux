package main

import marmot "../marmot"
import "core:slice"
import "core:strings"

// White Noise private-group issue settings. Optional MLS component, v1.
@(private)
ISSUE_COMPONENT :: u16(0xf301)
@(private)
ISSUE_KINDS :: [6]u64{1621, 1111, 1068, 1630, 1631, 1632}
@(private)
Issue_Setting :: enum {
	Unavailable,
	Disabled,
	Enabled,
}
@(private)
Issue_Status :: enum {
	Open,
	Resolved,
	Closed,
}
@(private)
Issue_Row :: struct {
	record:    int,
	id:        string,
	at:        u64,
	status:    Issue_Status,
	status_at: u64,
	status_id: string,
	comments:  [dynamic]Issue_Comment,
}

@(private)
Issue_Comment :: struct {
	record: int,
	id:     string,
	at:     u64,
}

@(private)
issue_setting :: proc(data: []u8) -> Issue_Setting {
	if len(data) != 2 || data[0] != 1 || data[1] > 1 {return .Unavailable}
	return data[1] == 1 ? .Enabled : .Disabled
}

// Duplicate singleton tags are ambiguous; reject them rather than choosing one.
@(private)
issue_tag :: proc(tags: []marmot.Message_Tag, key: string) -> string {
	value: string
	found := false
	for tag in tags {
		if tag.values_len == 0 || string(tag.values[0]) != key {continue}
		if found || tag.values_len < 2 {return ""}
		value = string(tag.values[1])
		found = true
	}
	return value
}

// Lowercase p tags include both the parent author and mentioned members.
@(private)
issue_has_author :: proc(tags: []marmot.Message_Tag, author: string) -> bool {
	for tag in tags {
		if tag.values_len >= 2 && string(tag.values[0]) == "p" && string(tag.values[1]) == author { return true }
	}
	return false
}

@(private)
issue_hex :: proc(value: string) -> bool {
	if len(value) != 64 {return false}
	for ch in value {
		if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') {return false}
	}
	return true
}

@(private)
issue_chat_hidden :: proc(kind: u64, tags: []marmot.Message_Tag) -> bool {
	if kind == 1621 || (kind >= 1630 && kind <= 1632) {return true}
	if kind != 1111 && kind != 1068 {return false}
	for tag in tags {
		if tag.values_len >= 2 &&
		   string(tag.values[0]) == "K" &&
		   string(tag.values[1]) == "1621" {return true}
	}
	return false
}

@(private)
issue_root :: proc(record: ^marmot.App_Message_Record) -> string {
	tags := record.tags[:record.tags_len]
	if record.kind == 1111 || record.kind == 1068 {
		if issue_tag(tags, "K") != "1621" {return ""}
		return issue_tag(tags, "E")
	}
	root: string
	for tag in tags {
		if tag.values_len < 4 ||
		   string(tag.values[0]) != "e" ||
		   string(tag.values[3]) != "root" {continue}
		if root != "" {return ""}
		root = string(tag.values[1])
	}
	return root
}

// Two passes resolve references regardless of delivery order. All strings borrow
// the scoped MDK snapshot; discard rows before releasing that snapshot.
@(private)
issues_project :: proc(
	records: []marmot.App_Message_Record,
	group: string,
	now: u64,
) -> (
	rows: [dynamic]Issue_Row,
	index: map[string]int,
) {
	index = make(map[string]int)
	seen := make(map[string]bool, context.temp_allocator)
	by_id := make(map[string]int, context.temp_allocator)
	for &record, i in records {
		if !record.invalidated &&
		   string(record.group_id_hex) == group &&
		   (!record.has_retention_expires_at ||
				   record.retention_expires_at > now) {by_id[string(record.message_id_hex)] = i}
	}
	for &record, i in records {
		id := string(record.message_id_hex)
		if record.invalidated ||
		   record.kind != 1621 ||
		   string(record.group_id_hex) != group ||
		   !issue_hex(id) ||
		   !issue_hex(string(record.sender)) {continue}
		if record.has_retention_expires_at && record.retention_expires_at <= now {continue}
		if seen[id] {continue}
		seen[id] = true
		if strings.trim_space(issue_tag(record.tags[:record.tags_len], "subject")) == "" {continue}
		index[id] = len(rows)
		append(
			&rows,
			Issue_Row {
				record = i,
				id = id,
				at = record.recorded_at,
				status_at = record.recorded_at,
			},
		)
	}
	clear(&seen)
	for &record, i in records {
		id := string(record.message_id_hex)
		if record.invalidated ||
		   string(record.group_id_hex) != group ||
		   !issue_hex(id) ||
		   !issue_hex(string(record.sender)) {continue}
		if record.has_retention_expires_at && record.retention_expires_at <= now {continue}
		if seen[id] {continue}
		seen[id] = true
		slot, found := index[issue_root(&record)]
		if !found {continue}
		row := &rows[slot]
		root := &records[row.record]
		if record.kind == 1111 || record.kind == 1068 {
			tags := record.tags[:record.tags_len]
			has_content := strings.trim_space(string(record.plaintext)) != ""
			for tag in tags {has_content ||= tag.values_len > 1 && string(tag.values[0]) == "imeta"}
			if issue_tag(tags, "P") != string(root.sender) || !has_content {continue}
			parent := issue_tag(tags, "e")
			// Nested replies must resolve inside the same issue.
			if !issue_hex(parent) {continue}
			parent_kind := issue_tag(tags, "k")
			if parent == string(root.message_id_hex) {
				if parent_kind != "1621" || !issue_has_author(tags, string(root.sender)) {continue}
			} else {
				if parent_kind != "1111" && parent_kind != "1068" {continue}
				parent_index, parent_found := by_id[parent]
				if !parent_found {continue}
				candidate := &records[parent_index]
				if (candidate.kind != 1111 && candidate.kind != 1068) ||
				   (candidate.kind == 1111 ? "1111" : "1068") != parent_kind ||
				   issue_root(candidate) != string(root.message_id_hex) ||
				   !issue_has_author(tags, string(candidate.sender)) {continue}
			}
			append(&row.comments, Issue_Comment{record = i, id = id, at = record.recorded_at})
			continue
		}
		if record.kind < 1630 || record.kind > 1632 {continue}
		if string(record.sender) != string(root.sender) &&
		   !(record.has_moderation_grant && record.moderation_grant) {continue}
		if record.recorded_at < root.recorded_at ||
		   record.recorded_at < row.status_at ||
		   (record.recorded_at == row.status_at && id <= row.status_id) {continue}
		row.status, row.status_at, row.status_id =
			Issue_Status(record.kind - 1630), record.recorded_at, id
	}
	// Sorting indices keeps borrowed records stationary and ID lookups explicit.
	for &row in rows {
		slice.sort_by(
			row.comments[:],
			proc(a, b: Issue_Comment) -> bool {return a.at == b.at ? a.id < b.id : a.at < b.at},
		)
	}
	slice.sort_by(
		rows[:],
		proc(a, b: Issue_Row) -> bool {return a.at == b.at ? a.id > b.id : a.at > b.at},
	)
	clear(&index)
	for row, i in rows {index[string(records[row.record].message_id_hex)] = i}
	return
}

@(private)
issues_rows_free :: proc(rows: [dynamic]Issue_Row, index: map[string]int) {
	for row in rows {delete(row.comments)}
	delete(rows)
	delete(index)
}

// The same composer and pending-send queue serve chat and issue discussions.
// Persist the NIP-22 address with the send so retries cannot follow UI navigation.
@(private)
Issue_Reply :: struct {
	root, author, parent, parent_author, parent_kind: string,
}

@(private)
issue_reply :: proc(ui: ^Ui_State) -> Issue_Reply {
	slot, found := ui.issue_index[ui.compose_issue]
	if !found || issue_page == nil {return {}}
	root := &issue_page.items[ui.issues[slot].record]
	parent, author, kind := ui.compose_issue, string(root.sender), "1621"
	if ui.replying !=
	   "" {parent = ui.replying} else if len(ui.thread_stack) > 0 {parent = thread_cur(ui)}
	if parent != ui.compose_issue {
		for comment in ui.issues[slot].comments {
			if comment.id != parent {continue}
			record := &issue_page.items[comment.record]
			author, kind = string(record.sender), record.kind == 1068 ? "1068" : "1111"
			break
		}
	}
	return {
		strings.clone(ui.compose_issue),
		strings.clone(string(root.sender)),
		strings.clone(parent),
		strings.clone(author),
		strings.clone(kind),
	}
}

@(private)
issue_reply_free :: proc(reply: Issue_Reply) {
	delete(
		reply.root,
	); delete(reply.author); delete(reply.parent); delete(reply.parent_author); delete(reply.parent_kind)
}

@(private)
issue_reply_tags :: proc(reply: Issue_Reply) -> [][]string {
	tags := [][]string {
		{"E", reply.root, "", reply.author},
		{"K", "1621"},
		{"P", reply.author},
		{"e", reply.parent, "", reply.parent_author},
		{"k", reply.parent_kind},
		{"p", reply.parent_author},
	}
	rows := make([][]string, len(tags), context.temp_allocator)
	for tag, i in tags {rows[i] = make([]string, len(tag), context.temp_allocator); copy(rows[i], tag)}
	return rows
}

@(private)
compose_draft_key :: proc(ui: ^Ui_State) -> string {
	group := ui.chats[ui.selected].group_id
	return(
		ui.compose_issue == "" ? group : strings.concatenate({group, ":issue:", ui.compose_issue}, context.temp_allocator) \
	)
}

@(private)
issues_sync_route :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.selected < 0 {return}
	desired :=
		ui.issues_open && !ui.issue_new && ui.issue_setting == .Enabled ? ui.issue_selected : ""
	if !(desired in ui.issue_index) {desired = ""}
	if ui.compose_issue != desired {
		stash_draft(ui)
		stash_staged(ui)
		delete(ui.compose_issue); ui.compose_issue = strings.clone(desired)
		ui.replying, ui.editing = "", ""
		thread_clear(ui)
		ed_set(ui, &ui.compose, ui.drafts[compose_draft_key(ui)])
		ui.staged = ui.staged_drafts[compose_draft_key(ui)]
		if compose_draft_key(ui) in ui.staged_drafts {ui.staged_drafts[compose_draft_key(ui)] = {}}
		ui.scroll_pending = false
	}
	if client != nil && (timeline_job == nil || timeline_job.issues != ui.issues_open) {
		load_timeline(client, ui, ui.search_open ? string(ui.search_input[:]) : "")
	}
}

@(private)
stash_staged :: proc(ui: ^Ui_State) {
	if ui.selected < 0 || len(ui.staged) == 0 {return}
	key := compose_draft_key(ui)
	if !(key in ui.staged_drafts) {key = strings.clone(key)}
	ui.staged_drafts[key] = ui.staged
	ui.staged = {}
}

@(private)
issue_send_allowed :: proc(client: ^marmot.Client, account, group: cstring) -> marmot.Status {
	component: ^marmot.Group_App_Component
	status := marmot.group_app_component(client, account, group, ISSUE_COMPONENT, &component)
	defer {if component != nil {marmot.app_component_free(component)}}
	if status != .OK {return status}
	if component == nil ||
	   issue_setting(component.data[:component.data_len]) !=
		   .Enabled {return .INVALID_APP_COMPONENT}
	return .OK
}
