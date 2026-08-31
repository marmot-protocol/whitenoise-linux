// Offline-queue roundtrip: a queued send with an attachment survives
// save_offline + load_offline (body, reply, attempts, base64 bytes,
// media type re-derived from the name).
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:os"
import "core:sync"
import "core:testing"

OFFLINE_TEST_HOME :: "/tmp/wn-odin-offline-test"

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
