// The vault's load-bearing claims: secrets survive a reseal, a wrong
// password is the only "wrong password" signal there is, and a blob
// sealed under one vault key is unreadable under another.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"

// data_home is one global and the vault is keyed off it, so tests that
// repoint it run one at a time (the runner threads them in parallel).
test_home_lock: sync.Mutex

@(private = "file")
VAULT_TEST_HOME :: "/tmp/wn-odin-vault-test"

// Run both configurations: tests/odin.sh app -define:WN_DEV=true
// -define:ODIN_TEST_NAMES=vault_dev_session (and without WN_DEV).
@(test)
vault_dev_session :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	fd, err := linux.memfd_create("wn-vault-test", {})
	testing.expect(t, err == .NONE)
	if err != .NONE {return}
	defer linux.close(fd)
	previous := os.get_env("WN_DEV_VAULT_FD", context.temp_allocator)
	os.set_env("WN_DEV_VAULT_FD", fmt.tprintf("%d", fd))
	defer {
		if previous ==
		   "" {os.unset_env("WN_DEV_VAULT_FD")} else {os.set_env("WN_DEV_VAULT_FD", previous)}
	}
	testing.expect_value(t, vault_create("first"), Vault_Err.None)
	testing.expect_value(t, vault_set("account:alice", "secret"), Vault_Err.None)
	defer vault_delete()

	when !#config(WN_DEV, false) {
		testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.Wrong_Password)
		return
	}
	// Simulate losing the process's key, then reopen without a password.
	g_vault.key = {}
	g_vault.unlocked = false
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.None)
	value, found := vault_get("account:alice", context.temp_allocator)
	testing.expect(t, found && value == "secret")
	stale: [VAULT_SALT_LEN + VAULT_KEY_LEN]u8
	linux.pread(fd, stale[:], 0)
	testing.expect_value(t, vault_rekey("second"), Vault_Err.None)
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.None)
	linux.pwrite(fd, stale[:], 0)
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.Wrong_Password)
	testing.expect_value(t, vault_open("second"), Vault_Err.None)

	// Matching salt with a corrupted key must still fail authentication.
	linux.pread(fd, stale[:], 0)
	stale[VAULT_SALT_LEN] ~= 1
	linux.pwrite(fd, stale[:], 0)
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.Wrong_Password)
	linux.ftruncate(fd, 1)
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.Wrong_Password)
	testing.expect_value(t, vault_open("second"), Vault_Err.None)
	vault_delete()
	n, _ := linux.pread(fd, stale[:], 0)
	testing.expect_value(t, n, 0)
}

@(test)
vault_round_trip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect(t, !vault_exists())
	testing.expect_value(t, vault_create("correct horse battery"), Vault_Err.None)
	testing.expect_value(t, vault_set("account:alice", "deadbeef"), Vault_Err.None)
	testing.expect(t, vault_exists())

	blob := transmute([]u8)string("cached attachment bytes")
	sealed, sealed_ok := vault_seal_blob(blob)
	testing.expect(t, sealed_ok)

	// The envelope is the slint app's shape, so both read one vault file.
	on_disk, read_err := os.read_entire_file(vault_path(), context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect(t, strings.contains(string(on_disk), "argon2id"))
	testing.expect(t, strings.contains(string(on_disk), "ciphertext_hex"))
	testing.expect(t, !strings.contains(string(on_disk), "deadbeef"))

	// Wrong password fails the Poly1305 tag and leaves the session alone.
	testing.expect_value(t, vault_open("wrong password"), Vault_Err.Wrong_Password)
	testing.expect_value(t, vault_open("correct horse battery"), Vault_Err.None)

	value, found := vault_get("account:alice")
	testing.expect(t, found)
	testing.expect_value(t, value, "deadbeef")
	testing.expect(t, !vault_has("account:bob"))

	plain, opened := vault_open_blob(sealed)
	testing.expect(t, opened)
	testing.expect_value(t, string(plain), "cached attachment bytes")

	// A truncated blob is rejected rather than read out of bounds.
	_, short_ok := vault_open_blob(sealed[:VAULT_NONCE_LEN - 1])
	testing.expect(t, !short_ok)

	testing.expect_value(t, vault_remove("account:alice"), Vault_Err.None)
	testing.expect(t, !vault_has("account:alice"))

	// "Use another key": the fresh vault cannot read the old one's blobs,
	// which is why vault_delete drops the cache and the queue with it.
	vault_delete()
	testing.expect(t, !vault_exists())
	testing.expect_value(t, vault_create("another password"), Vault_Err.None)
	_, foreign_ok := vault_open_blob(sealed)
	testing.expect(t, !foreign_ok)
}

// Rotating the password keeps every secret and rekeys the file: the old
// password stops working, the new one opens it, and blobs sealed before
// the change are dead (which is why the caller drops the media cache).
@(test)
vault_rekey_round_trip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect_value(t, vault_create("first password"), Vault_Err.None)
	testing.expect_value(t, vault_set("account:alice", "deadbeef"), Vault_Err.None)

	stale, stale_ok := vault_seal_blob(transmute([]u8)string("cached bytes"))
	testing.expect(t, stale_ok)
	defer delete(stale)

	testing.expect(t, vault_verify("first password"), "the live password verifies")
	testing.expect(t, !vault_verify("second password"), "any other one does not")

	testing.expect_value(t, vault_rekey("second password"), Vault_Err.None)
	testing.expect(t, vault_verify("second password"), "the new password is live")

	// The file on disk moved with it, both ways.
	testing.expect_value(t, vault_open("first password"), Vault_Err.Wrong_Password)
	testing.expect_value(t, vault_open("second password"), Vault_Err.None)

	value, found := vault_get("account:alice")
	defer delete(value)
	testing.expect(t, found, "the secrets came through the rotation")
	testing.expect_value(t, value, "deadbeef")

	_, opened := vault_open_blob(stale)
	testing.expect(t, !opened, "a blob sealed under the old key is unreadable")
}
