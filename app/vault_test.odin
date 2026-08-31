// The vault's load-bearing claims: secrets survive a reseal, a wrong
// password is the only "wrong password" signal there is, and a blob
// sealed under one vault key is unreadable under another.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// data_home is one global and the vault is keyed off it, so tests that
// repoint it run one at a time (the runner threads them in parallel).
test_home_lock: sync.Mutex

@(private = "file")
VAULT_TEST_HOME :: "/tmp/wn-odin-vault-test"

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
