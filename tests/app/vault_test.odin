// The vault's load-bearing claims: secrets survive a reseal, a wrong
// password is the only "wrong password" signal there is, and a blob
// sealed under one vault's blob key is unreadable under another vault.
// A password change keeps the blob key, so those files stay readable.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"

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
	sealed, sealed_ok := vault_seal_blob(transmute([]u8)string("private session"))
	testing.expect(t, sealed_ok)
	defer delete(sealed)
	vault_relock()
	testing.expect(
		t,
		dev_vault_manual_locked(),
		"manual authentication survives a watcher process replacement",
	)
	testing.expect(t, !g_vault.unlocked)
	testing.expect_value(t, g_vault.key, [VAULT_KEY_LEN]u8{})
	testing.expect_value(t, vault_open("", .Dev_Cache), Vault_Err.Wrong_Password)
	_, opened := vault_open_blob(sealed)
	testing.expect(t, !opened)
	testing.expect_value(t, vault_open("wrong"), Vault_Err.Wrong_Password)
	testing.expect(t, !g_vault.unlocked)
	testing.expect_value(t, vault_open("second"), Vault_Err.None)
	plain, reopened := vault_open_blob(sealed)
	testing.expect(
		t,
		!dev_vault_manual_locked(),
		"a real password unlock re-enables development reload",
	)
	defer delete(plain)
	testing.expect(t, reopened && string(plain) == "private session")
	vault_delete()
	n, _ := linux.pread(fd, stale[:], 0)
	testing.expect_value(t, n, 0)
}

@(test)
vault_round_trip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

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

	// The sealed file is the Argon2id envelope, not plaintext.
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

// Rotating the password keeps every secret and the blob key: the old
// password stops working, the new one opens the file, and a blob sealed
// before the change still opens after a restart.
@(test)
vault_rekey_round_trip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

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

	plain, opened := vault_open_blob(stale)
	defer delete(plain)
	testing.expect(
		t,
		opened && string(plain) == "cached bytes",
		"the blob key survived the rotation",
	)

	vault_lock()
	testing.expect_value(t, vault_open("second password"), Vault_Err.None)
	again, again_ok := vault_open_blob(stale)
	defer delete(again)
	testing.expect(t, again_ok && string(again) == "cached bytes")
}

@(private = "file")
vault_test_paths :: proc() -> [6]string {
	return {
		offline_path(),
		fmt.tprintf("%s/x.bin", media_cache_dir()),
		fmt.tprintf("%s/stickers/library.bin", data_home),
		fmt.tprintf("%s/stickers/aa.bin", data_home),
		fmt.tprintf("%s/gifs/library.bin", data_home),
		fmt.tprintf("%s/gifs/item.bin", data_home),
	}
}

@(private = "file")
vault_test_write_stores :: proc() -> bool {
	for path in vault_test_paths() {
		if !media_write_sealed(path, transmute([]u8)string("saved")) {
			return false
		}
	}
	return true
}

@(private = "file")
vault_test_read_stores :: proc() -> bool {
	for path in vault_test_paths() {
		sealed, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return false
		}
		plain, ok := vault_open_blob(sealed, context.temp_allocator)
		if !ok || string(plain) != "saved" {
			return false
		}
	}
	return true
}

// Fresh vaults persist a random blob key. A legacy vault (no blob-key
// entry) keeps the derived key, and the password change stores that
// same key. Either way the sealed files reopen after a restart.
@(test)
vault_rekey_preserves_stores :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect_value(t, vault_create("first"), Vault_Err.None)
	testing.expect(t, vault_has(VAULT_BLOB_KEY))
	testing.expect(t, vault_test_write_stores())
	testing.expect_value(t, vault_rekey("second"), Vault_Err.None)
	vault_lock()
	testing.expect_value(t, vault_open("second"), Vault_Err.None)
	testing.expect(t, vault_test_read_stores(), "fresh vault files survive the password change")

	testing.expect_value(t, vault_remove(VAULT_BLOB_KEY), Vault_Err.None)
	testing.expect(t, !vault_has(VAULT_BLOB_KEY))
	testing.expect(t, vault_test_write_stores(), "legacy files are sealed with the derived key")
	testing.expect_value(t, vault_rekey("third"), Vault_Err.None)
	testing.expect(t, vault_has(VAULT_BLOB_KEY))
	vault_lock()
	testing.expect_value(t, vault_open("third"), Vault_Err.None)
	testing.expect(t, vault_test_read_stores(), "legacy files survive the password change")
	testing.expect(t, vault_has(VAULT_BLOB_KEY))

	testing.expect_value(t, vault_set(VAULT_BLOB_KEY, "zz"), Vault_Err.None)
	_, bad_ok := vault_seal_blob(transmute([]u8)string("nope"))
	testing.expect(t, !bad_ok, "a broken blob-key entry does not fall back to a different key")
}

// A failed persist leaves the previous password and the previous blob
// key in force, including a legacy vault that had not stored one yet.
@(test)
vault_rekey_rolls_back :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	defer {
		os.chmod(VAULT_TEST_HOME, os.perm(0o700))
		vault_delete()
	}
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect_value(t, vault_create("first"), Vault_Err.None)
	testing.expect_value(t, vault_remove(VAULT_BLOB_KEY), Vault_Err.None)
	sealed, sealed_ok := vault_seal_blob(transmute([]u8)string("legacy"))
	testing.expect(t, sealed_ok)
	defer delete(sealed)

	testing.expect(t, os.chmod(VAULT_TEST_HOME, os.perm(0o500)) == nil)
	testing.expect_value(t, vault_rekey("second"), Vault_Err.Io)
	testing.expect(t, os.chmod(VAULT_TEST_HOME, os.perm(0o700)) == nil)

	testing.expect(t, vault_verify("first"))
	testing.expect(t, !vault_has(VAULT_BLOB_KEY))
	plain, opened := vault_open_blob(sealed)
	defer delete(plain)
	testing.expect(t, opened && string(plain) == "legacy")

	vault_lock()
	testing.expect_value(t, vault_open("first"), Vault_Err.None)
	testing.expect_value(t, vault_open("second"), Vault_Err.Wrong_Password)
	testing.expect_value(t, vault_open("first"), Vault_Err.None)
	again, again_ok := vault_open_blob(sealed)
	defer delete(again)
	testing.expect(t, again_ok && string(again) == "legacy")
	testing.expect(t, !vault_has(VAULT_BLOB_KEY))

	vault_delete()
	testing.expect_value(t, vault_create("fresh"), Vault_Err.None)
	fresh, fresh_ok := vault_seal_blob(transmute([]u8)string("fresh"))
	testing.expect(t, fresh_ok)
	defer delete(fresh)
	testing.expect(t, os.chmod(VAULT_TEST_HOME, os.perm(0o500)) == nil)
	testing.expect_value(t, vault_rekey("other"), Vault_Err.Io)
	testing.expect(t, os.chmod(VAULT_TEST_HOME, os.perm(0o700)) == nil)
	testing.expect(t, vault_verify("fresh"))
	testing.expect(t, vault_has(VAULT_BLOB_KEY))
	fresh_plain, fresh_opened := vault_open_blob(fresh)
	defer delete(fresh_plain)
	testing.expect(t, fresh_opened && string(fresh_plain) == "fresh")
}

@(private = "file")
Vault_Race :: struct {
	mu:   sync.Mutex,
	n:    int,
	stop: bool,
}

@(private = "file")
vault_race_write :: proc(t: ^thread.Thread) {
	context.allocator = runtime.default_context().allocator
	race := (^Vault_Race)(t.data)
	plain := transmute([]u8)string("race")
	for {
		free_all(context.temp_allocator)
		sync.lock(&race.mu)
		if race.stop {
			sync.unlock(&race.mu)
			return
		}
		race.n += 1
		n := race.n
		sync.unlock(&race.mu)
		path := fmt.tprintf("%s/race/%d.bin", data_home, n)
		media_write_sealed(path, plain)
	}
}

// A seal that blocks on the vault lock during rekey finishes under the
// same blob key and stays readable.
@(test)
vault_rekey_during_write :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	defer vault_delete()
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect_value(t, vault_create("first"), Vault_Err.None)
	testing.expect(
		t,
		media_write_sealed(
			fmt.tprintf("%s/race/before.bin", data_home),
			transmute([]u8)string("before"),
		),
	)

	race := Vault_Race{}
	worker := thread.create(vault_race_write)
	worker.data = &race
	thread.start(worker)
	for {
		sync.lock(&race.mu)
		started := race.n > 0
		sync.unlock(&race.mu)
		if started {
			break
		}
	}
	testing.expect_value(t, vault_rekey("second"), Vault_Err.None)
	sync.lock(&race.mu)
	race.stop = true
	n := race.n
	sync.unlock(&race.mu)
	thread.join(worker)
	thread.destroy(worker)

	vault_lock()
	testing.expect_value(t, vault_open("second"), Vault_Err.None)
	before, before_err := os.read_entire_file(
		fmt.tprintf("%s/race/before.bin", data_home),
		context.temp_allocator,
	)
	testing.expect(t, before_err == nil)
	before_plain, before_ok := vault_open_blob(before, context.temp_allocator)
	testing.expect(t, before_ok && string(before_plain) == "before")

	opened := 0
	for i in 1 ..= n {
		sealed, err := os.read_entire_file(
			fmt.tprintf("%s/race/%d.bin", data_home, i),
			context.temp_allocator,
		)
		if err != nil {
			continue
		}
		plain, ok := vault_open_blob(sealed, context.temp_allocator)
		testing.expect(t, ok && string(plain) == "race")
		if ok {
			opened += 1
		}
	}
	testing.expect(t, opened > 0, "a write that overlapped the password change is readable")
}

// Reset removes every vault-bound store. Clearing the media cache does
// not take the sticker library or the saved GIFs with it.
@(test)
vault_reset_removes_stores :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	defer vault_lock()

	prev_home := data_home
	data_home = VAULT_TEST_HOME
	defer data_home = prev_home
	os.remove_all(VAULT_TEST_HOME)
	os.make_directory(VAULT_TEST_HOME)
	defer os.remove_all(VAULT_TEST_HOME)

	testing.expect_value(t, vault_create("first"), Vault_Err.None)
	testing.expect(t, vault_test_write_stores())
	ui: Ui_State
	cache_clear(&ui)
	testing.expect(t, !os.exists(fmt.tprintf("%s/x.bin", media_cache_dir())))
	testing.expect(t, os.exists(fmt.tprintf("%s/stickers/library.bin", data_home)))
	testing.expect(t, os.exists(fmt.tprintf("%s/stickers/aa.bin", data_home)))
	testing.expect(t, os.exists(fmt.tprintf("%s/gifs/library.bin", data_home)))
	testing.expect(t, os.exists(fmt.tprintf("%s/gifs/item.bin", data_home)))
	testing.expect(t, os.exists(offline_path()))

	vault_delete()
	testing.expect(t, !vault_exists())
	testing.expect(t, !os.exists(offline_path()))
	testing.expect(t, !os.exists(media_cache_dir()))
	testing.expect(t, !os.exists(fmt.tprintf("%s/stickers", data_home)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/gifs", data_home)))
}
