// Offline-queue roundtrip: a queued send with an attachment survives
// save_offline + load_offline (body, reply, attempts, base64 bytes,
// media type re-derived from the name).
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

OFFLINE_TEST_HOME :: "/tmp/wn-odin-offline-test"

@(test)
offline_delete_pending :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

	previous_home := data_home
	data_home = OFFLINE_TEST_HOME
	defer {data_home = previous_home}
	os.remove_all(OFFLINE_TEST_HOME)
	os.make_directory(OFFLINE_TEST_HOME)
	defer os.remove_all(OFFLINE_TEST_HOME)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)

	ui := Ui_State {
		selected = -1,
	}
	defer delete(ui.pending)
	append(
		&ui.pending,
		Pending_Send {
			ticket = 1,
			account_ref = strings.clone("account"),
			body = strings.repeat("x", 65537),
			failed = true,
		},
	)
	append(
		&ui.pending,
		Pending_Send {
			ticket = 2,
			account_ref = strings.clone("account"),
			body = strings.clone("queued"),
			queued = true,
		},
	)
	append(
		&ui.pending,
		Pending_Send {
			ticket = 3,
			account_ref = strings.clone("account"),
			body = strings.clone("sending"),
			attempts = 1,
		},
	)
	save_offline(&ui)

	delete_pending(&ui, 2)
	testing.expect_value(t, len(ui.pending), 3)
	testing.expect(t, ui.pending[2].dismissed)
	delete_pending(&ui, 0)
	testing.expect_value(t, len(ui.pending), 2)
	testing.expect_value(t, ui.pending[0].ticket, 2)

	restored: Ui_State
	load_offline(&restored)
	testing.expect_value(t, len(restored.pending), 1)
	testing.expect_value(t, restored.pending[0].body, "queued")
	free_pending(&restored.pending[0])
	delete(restored.pending)

	delete_pending(&ui, 0)
	testing.expect_value(t, len(ui.pending), 1)
	testing.expect_value(t, ui.pending[0].ticket, 3)
	_, read_err := os.read_entire_file(offline_path(), context.temp_allocator)
	testing.expect(t, read_err != nil)
	append(&sends_done, Send_Done{ticket = 3, status = .PUBLISH, err = strings.clone("too large")})
	drain_sends(&ui, nil)
	testing.expect_value(t, len(ui.pending), 0)

	// A late successful publish must stay hidden after restarting too.
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", OFFLINE_TEST_HOME)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	append(
		&ui.pending,
		Pending_Send {
			ticket = 4,
			account_ref = strings.clone("account"),
			body = strings.clone("sending"),
		},
	)
	delete_pending(&ui, 0)
	done := Send_Done {
		ticket = 4,
	}
	append(&done.ids, strings.clone("late-message-id"))
	append(&sends_done, done)
	drain_sends(&ui, nil)
	testing.expect_value(t, len(ui.pending), 0)
	testing.expect(t, ui.hidden["late-message-id"])
	load_hidden(&restored)
	testing.expect(t, restored.hidden["late-message-id"])
	for id in ui.hidden {
		delete(id)
	}
	delete(ui.hidden)
	for id in restored.hidden {
		delete(id)
	}
	delete(restored.hidden)
}

@(test)
offline_roundtrip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

	data_home = OFFLINE_TEST_HOME
	os.remove_all(OFFLINE_TEST_HOME)
	os.make_directory(OFFLINE_TEST_HOME)
	defer os.remove_all(OFFLINE_TEST_HOME)

	// The queue is sealed with the vault's blob subkey, so it needs one.
	testing.expect_value(t, vault_create("test"), Vault_Err.None)

	ui: Ui_State
	p := Pending_Send {
		ticket = 1,
		effect = 3,
		sticker = {
			pack = "30031:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:tiny",
			code = "ok",
			sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		},
		group_id = "g1",
		account_ref = "account",
		sender = "you",
		body = "hello",
		reply_to = "r1",
		attempts = 2,
		queued = true,
	}
	append(
		&p.atts,
		Pending_Att{name = "notes.txt", media_type = "text/plain", data = []u8{1, 2, 3}},
	)
	append(&ui.pending, p)
	save_offline(&ui)

	restored: Ui_State
	load_offline(&restored)
	testing.expect_value(t, len(restored.pending), 1)
	q := restored.pending[0]
	testing.expect_value(t, q.account_ref, "account")
	testing.expect_value(t, q.effect, 3)
	testing.expect_value(t, q.sticker.pack, p.sticker.pack)
	testing.expect_value(t, q.sticker.sha, p.sticker.sha)
	testing.expect_value(t, q.body, "hello")
	testing.expect_value(t, q.reply_to, "r1")
	testing.expect_value(t, q.attempts, 2)
	testing.expect(t, q.queued)
	testing.expect_value(t, len(q.atts), 1)
	testing.expect_value(t, q.atts[0].media_type, "text/plain")
	testing.expect(t, len(q.atts[0].data) == 3 && q.atts[0].data[2] == 3)

	// Acked queue removes the file.
	clear(&ui.pending)
	save_offline(&ui)
	_, read_err := os.read_entire_file(offline_path(), context.temp_allocator)
	testing.expect(t, read_err != nil)
}

@(test)
offline_ownerless_preserved :: proc(t: ^testing.T) {
	if !MULTI_DEVICE {return}
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()
	dir, err := os.make_directory_temp("", "wn-owned-queue-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(dir)
	old := data_home
	data_home = dir
	defer data_home = old
	if !testing.expect_value(t, vault_create("test"), Vault_Err.None) {return}
	items := []Offline_Item {
		{group_id = "same-chat", body = "legacy"},
		{group_id = "same-chat", body = "A", account_ref = "owner-a"},
		{group_id = "same-chat", body = "B", account_ref = "owner-b"},
	}
	plain, _ := json.marshal(items, allocator = context.temp_allocator)
	sealed, ok := vault_seal_blob(plain, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	if !testing.expect(t, os.write_entire_file(offline_path(), sealed) == nil) {return}
	ui: Ui_State
	load_offline(&ui)
	defer {
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending)
		offline_clear(&ui)
	}
	if !testing.expect_value(t, len(ui.pending), 2) {return}
	testing.expect_value(t, len(ui.offline_unowned), 1)
	offline_wipe(&ui, "owner-a")
	if !testing.expect_value(t, len(ui.pending), 1) {return}
	testing.expect_value(t, ui.pending[0].account_ref, "owner-b")
	saved, read_err := os.read_entire_file(offline_path(), context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	plain, ok = vault_open_blob(saved, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	var: []Offline_Item
	if !testing.expect(
		t,
		json.unmarshal(plain, &var, allocator = context.temp_allocator) == nil,
	) {return}
	if !testing.expect_value(t, len(var), 2) {return}
	testing.expect_value(t, var[0].body, "legacy")
	testing.expect_value(t, var[0].account_ref, "")
	testing.expect_value(t, var[1].account_ref, "owner-b")
}
