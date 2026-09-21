// Offline-queue roundtrip: a queued send with an attachment survives
// save_offline + load_offline (body, reply, attempts, base64 bytes,
// media type re-derived from the name).
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

OFFLINE_TEST_HOME :: "/tmp/wn-odin-offline-test"

@(test)
offline_delete_pending :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	previous_home := data_home
	data_home = OFFLINE_TEST_HOME
	defer { data_home = previous_home }
	os.remove_all(OFFLINE_TEST_HOME)
	os.make_directory(OFFLINE_TEST_HOME)
	defer os.remove_all(OFFLINE_TEST_HOME)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)

	ui := Ui_State{selected = -1}
	defer delete(ui.pending)
	append(&ui.pending, Pending_Send{ticket = 1, body = strings.repeat("x", 65537), failed = true})
	append(&ui.pending, Pending_Send{ticket = 2, body = strings.clone("queued"), queued = true})
	append(&ui.pending, Pending_Send{ticket = 3, body = strings.clone("sending"), attempts = 1})
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
	append(&ui.pending, Pending_Send{ticket = 4, body = strings.clone("sending")})
	delete_pending(&ui, 0)
	done := Send_Done{ticket = 4}
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

	data_home = OFFLINE_TEST_HOME
	os.remove_all(OFFLINE_TEST_HOME)
	os.make_directory(OFFLINE_TEST_HOME)
	defer os.remove_all(OFFLINE_TEST_HOME)

	// The queue is sealed with the vault's blob subkey, so it needs one.
	testing.expect_value(t, vault_create("test"), Vault_Err.None)

	ui: Ui_State
	p := Pending_Send{ticket = 1, group_id = "g1", sender = "you", body = "hello", reply_to = "r1", attempts = 2, queued = true}
	append(&p.atts, Pending_Att{name = "notes.txt", media_type = "text/plain", data = []u8{1, 2, 3}})
	append(&ui.pending, p)
	save_offline(&ui)

	restored: Ui_State
	load_offline(&restored)
	testing.expect_value(t, len(restored.pending), 1)
	q := restored.pending[0]
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
