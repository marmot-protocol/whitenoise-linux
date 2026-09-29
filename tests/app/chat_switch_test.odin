package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
chat_switch_settings_keep_latest_snapshot :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-switch-settings", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	ui: Ui_State
	defer delete(ui.drafts)
	ui.prefs.zoom_pct = 100
	ui.prefs.last_chat = "first"
	ui.drafts["first"] = "draft before switching"
	save_settings(&ui, background = true)
	ui.prefs.last_chat = "second"
	ui.drafts["first"] = "latest draft"
	save_settings(&ui, background = true)
	// An ordinary preference save must not be overwritten by either switch.
	ui.prefs.last_chat = "third"
	ui.prefs.hour12 = true
	save_settings(&ui)
	settings_stop(&ui)
	data, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	actual: Settings
	if !testing.expect(
		t,
		json.unmarshal(data, &actual, allocator = context.temp_allocator) == nil,
	) {return}
	testing.expect_value(t, actual.prefs.last_chat, "third")
	testing.expect_value(t, actual.drafts["first"], "latest draft")
	testing.expect(t, actual.prefs.hour12)
}

@(test)
chat_switch_read_anchor_and_latest_window :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := timeline_job
	defer timeline_job = previous
	job: Timeline_Work
	job.account = strings.clone_to_cstring("account")
	job.group = strings.clone_to_cstring("group")
	timeline_job = &job
	defer {
		delete(job.account); delete(job.group); delete(job.read_request); delete(job.read_latest)
	}
	ui := Ui_State {
		account_ref    = "account",
		selected       = 0,
		unread_mark_id = "first-unread",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	append(
		&ui.messages,
		Msg_Ui{id = "mls-newest", mls_order = 9},
		Msg_Ui{id = "wall-clock-newest", mls_order = 3},
	)
	defer delete(ui.chats)
	defer delete(ui.messages)
	ui.timeline_loading = true
	timeline_mark_read(&ui)
	testing.expect(t, job.read_request == nil, "loading must not mark an unapplied window read")
	ui.timeline_loading = false
	ui.tl_has_after = true
	timeline_mark_read(&ui)
	testing.expect(
		t,
		job.read_request == nil,
		"older pages must not mark unseen latest messages read",
	)
	ui.tl_has_after = false
	timeline_mark_read(&ui)
	testing.expect_value(t, string(job.read_request), "mls-newest")
	testing.expect_value(t, ui.unread_mark_id, "first-unread")
	ui.account_ref = "other-account"
	ui.messages[0].id = "must-not-cross-account"
	timeline_mark_read(&ui)
	testing.expect_value(t, string(job.read_request), "mls-newest")
}

@(test)
chat_switch_failure_keeps_local_outcome :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := timeline_job
	defer timeline_job = previous
	job: Timeline_Work
	job.account = strings.clone_to_cstring("account")
	job.group = strings.clone_to_cstring("group")
	job.err = strings.clone("transport closed")
	timeline_job = &job
	defer {delete(job.account); delete(job.group)}
	ui := Ui_State {
		account_ref      = "account",
		selected         = 0,
		timeline_loading = true,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {delete(ui.chats); delete(ui.timeline_error); delete(ui.client_status)}
	timeline_drain(&ui, nil)
	testing.expect(t, !ui.timeline_loading)
	testing.expect(t, strings.contains(ui.timeline_error, "transport closed"))
	delete(ui.client_status)
	ui.client_status = strings.clone("unrelated operation")
	testing.expect(
		t,
		strings.contains(ui.timeline_error, "transport closed"),
		"other workers must not erase the selected timeline's failure",
	)
}
