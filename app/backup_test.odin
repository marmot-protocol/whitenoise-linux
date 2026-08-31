package main

import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_backup_round_trip :: proc(t: ^testing.T) {
	plain := transmute([]u8)string(`[{"path":"settings.json","data":"aGk="}]`)
	sealed := backup_seal(plain, "correct horse")
	defer delete(sealed)

	testing.expect(t, len(sealed) == BACKUP_HEADER + len(plain), "container is header + plaintext")
	testing.expect(t, string(sealed[0:4]) == BACKUP_MAGIC, "magic")

	opened, ok := backup_open(sealed, "correct horse")
	defer delete(opened)
	testing.expect(t, ok, "opens with the right password")
	testing.expect(t, string(opened) == string(plain), "round-trips the bytes")

	_, wrong := backup_open(sealed, "correct horsf")
	testing.expect(t, !wrong, "wrong password fails the tag")

	sealed[5] += 1 // the cost byte is authenticated
	_, tampered := backup_open(sealed, "correct horse")
	testing.expect(t, !tampered, "a flipped header byte fails")
}

@(test)
test_backup_target :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)

	data_home = "/tmp/wn-test-home"

	path, ok := backup_target("themes/mine.toml")
	testing.expect(t, ok, "a known label resolves")
	testing.expect(t, strings.has_suffix(path, "/themes/mine.toml"), path)

	rejected := [?]string{"../evil", "emoji/../../evil", "emoji/", "secrets.json", "themes/a/b"}
	for label in rejected {
		_, bad := backup_target(label)
		testing.expectf(t, !bad, "%s must be rejected", label)
	}
}

@(test)
test_human_size :: proc(t: ^testing.T) {
	testing.expect(t, human_size(0) == "0 B", human_size(0))
	testing.expect(t, human_size(512) == "512 B", human_size(512))
	testing.expect(t, human_size(1_500) == "1.5 KB", human_size(1_500))
	testing.expect(t, human_size(2_500_000) == "2.5 MB", human_size(2_500_000))
}
