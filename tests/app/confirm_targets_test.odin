// Destructive confirms keep the subject they captured: a cancelled
// retention change does nothing, an audit rescan drops a pending
// delete, and a custom emoji file is removed only on the second click.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
retention_cancel_keeps_timer :: proc(t: ^testing.T) {
	ui: Ui_State
	ui.group_retention = 3600
	append(&ui.chats, Chat_Row_Ui{group_id = strings.clone("group-a")})
	ui.selected = 0
	defer {
		if len(ui.chats) > 0 {
			delete(ui.chats[0].group_id)
		}
		delete(ui.chats)
		delete(ui.confirm.arg)
		delete(ui.confirm.name)
		delete(ui.client_status)
	}

	confirm_ask(&ui, .Retention, "group-a", "1 day", 86400)
	testing.expect_value(t, ui.group_retention, u64(3600))
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.Retention)
	confirm_close(&ui)
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
	testing.expect_value(t, ui.group_retention, u64(3600))

	confirm_ask(&ui, .Retention, "group-a", "1 day", 86400)
	delete(ui.chats[0].group_id)
	ui.chats[0].group_id = strings.clone("group-b")
	run_confirm(&ui, nil)
	testing.expect_value(t, ui.group_retention, u64(3600))
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
	testing.expect(t, len(ui.client_status) > 0)

	delete(ui.client_status)
	ui.client_status = ""
	confirm_ask(&ui, .Retention, "group-b", "5 minutes", 300)
	run_confirm(&ui, nil)
	testing.expect_value(t, ui.group_retention, u64(3600))
}

@(test)
audit_rescan_disarms_delete :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	ui: Ui_State
	defer {
		keys_disarm(&ui)
		for &file in ui.audit_files {
			delete(file.path)
			delete(file.name)
			delete(file.label)
		}
		delete(ui.audit_files)
	}

	ui.keys_confirm = "RotateBtn"
	keys_disarm(&ui)
	testing.expect_value(t, ui.keys_confirm, "")

	testing.expect(t, !owned_arm(&ui, "AuditDelete:/tmp/a.log"))
	testing.expect_value(t, ui.keys_confirm, "AuditDelete:/tmp/a.log")
	testing.expect(t, ui.keys_confirm != "AuditDelete:/tmp/b.log")
	append(
		&ui.audit_files,
		Audit_File {
			path = strings.clone("/tmp/a.log"),
			name = strings.clone("a.log"),
			label = strings.clone("1 KB"),
		},
	)
	audit_scan(&ui, nil)
	testing.expect_value(t, ui.keys_confirm, "")
	testing.expect_value(t, len(ui.audit_files), 0)
}

@(test)
emoji_remove_confirms :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-emoji-del", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous == "" {
			os.unset_env("XDG_CONFIG_HOME")
		} else {
			os.set_env("XDG_CONFIG_HOME", previous)
		}
	}

	ui: Ui_State
	defer {
		keys_disarm(&ui)
		for name in custom_emoji_names {
			delete(name)
		}
		delete(custom_emoji_names)
		custom_emoji_names = nil
		custom_emoji_scanned = false
	}
	dir := emoji_dir()
	os.make_directory_all(dir)
	party := fmt.tprintf("%s/party.png", dir)
	other := fmt.tprintf("%s/other.png", dir)
	testing.expect(t, os.write_entire_file(party, []u8{1, 2, 3}) == nil)
	testing.expect(t, os.write_entire_file(other, []u8{4}) == nil)

	emoji_remove(&ui, "party.png")
	testing.expect(t, os.exists(party))
	testing.expect_value(t, ui.keys_confirm, "EmojiDelete:party.png")

	emoji_remove(&ui, "other.png")
	testing.expect(t, os.exists(party))
	testing.expect(t, os.exists(other))
	testing.expect_value(t, ui.keys_confirm, "EmojiDelete:other.png")

	emoji_remove(&ui, "other.png")
	testing.expect(t, !os.exists(other))
	testing.expect(t, os.exists(party))
	testing.expect_value(t, ui.keys_confirm, "")
}
