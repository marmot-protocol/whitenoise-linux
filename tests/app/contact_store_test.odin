package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import rl "sdlrl"

@(private = "file")
CONTACT_TEST_OWNER :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
@(private = "file")
CONTACT_TEST_OTHER :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
@(private = "file")
CONTACT_TEST_PEER :: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
@(private = "file")
CONTACT_TEST_SECOND :: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

@(private = "file")
contact_test_entry :: proc(owner, peer: string) -> ^Contact_Record {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		contact_store_drain()
		if entry := contact_store_entry(owner, peer); entry != nil {return entry}
		time.sleep(time.Millisecond)
	}
	return nil
}

@(private = "file")
contact_test_result :: proc(t: ^testing.T, owner, peer: string, want_ok: bool) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		abandoned_failure := contact_store_drain()
		if done, ok := contact_store_result(owner, peer); done {
			testing.expect_value(t, abandoned_failure, !want_ok)
			consumed, _ := contact_store_result(owner, peer)
			testing.expect(t, !consumed, "save result is consumed once")
			return testing.expect(t, ok == want_ok, "unexpected save result")
		}
		time.sleep(time.Millisecond)
	}
	return testing.expect(t, false, "save did not produce a result")
}

@(private = "file")
contact_test_path :: proc(owner, peer: string) -> string {
	return fmt.tprintf("%s/private-contacts/%s/%s.bin", data_home, owner, peer)
}

@(private = "file")
contact_test_photo :: proc(edge: i32) -> (Pic_Draft, bool) {
	pixels := [16]u8{20, 30, 40, 255, 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255}
	return photo_crop_draft(
		{data = raw_data(pixels[:]), width = edge, height = edge},
		{true, 0, 0, edge},
	)
}

@(test)
contact_store_round_trip :: proc(t: ^testing.T) {
	if !test_isolated("contact_store_round_trip") {return}
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-contact-store-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	prev_home := data_home
	data_home = home
	defer data_home = prev_home
	defer vault_lock()
	if !testing.expect(t, vault_create("contact test") == .None) {return}

	rl.InitWindow(64, 64, "Private contact store")
	defer rl.CloseWindow()
	defer contact_store_stop()
	one, one_ok := contact_test_photo(1)
	if !testing.expect(t, one_ok) {return}
	defer pic_draft_free(&one)
	two, two_ok := contact_test_photo(2)
	if !testing.expect(t, two_ok) {return}
	defer pic_draft_free(&two)
	owner, other, peer, second :=
		CONTACT_TEST_OWNER, CONTACT_TEST_OTHER, CONTACT_TEST_PEER, CONTACT_TEST_SECOND
	path := contact_test_path(owner, peer)

	contact_store_select(owner)
	testing.expect(t, contact_store_entry(other, peer) == nil)
	testing.expect(t, contact_store_entry(owner, "../unrelated") == nil)
	testing.expect(t, !contact_store_save(other, peer, "wrong account", nil, .Keep))
	too_long := make([]u8, CONTACT_NOTE_MAX + 1, context.temp_allocator)
	testing.expect(t, !contact_store_save(owner, peer, string(too_long), nil, .Keep))
	testing.expect(t, !contact_store_save(owner, peer, "malformed PNG", too_long, .Replace))
	testing.expect(t, contact_store_entry(owner, peer) == nil)
	entry := contact_test_entry(owner, peer)
	if !testing.expect(
		t,
		entry != nil && entry.note == "" && entry.photo == nil && !entry.unreadable,
	) {return}

	note := [17]u8{}
	copy(note[:], "private note text")
	png := make([]u8, len(one.data), context.temp_allocator)
	copy(png, one.data)
	if !testing.expect(t, contact_store_save(owner, peer, string(note[:]), png, .Replace)) {return}
	mem.zero_slice(note[:]); mem.zero_slice(png)
	testing.expect(
		t,
		entry.note == "" && entry.photo == nil,
		"pending save does not change old values",
	)
	if !contact_test_result(t, owner, peer, true) {return}
	if !testing.expect(
		t,
		contact_store_entry(owner, peer) == entry &&
		entry.note == "private note text" &&
		entry.has_photo &&
		entry.photo != nil &&
		entry.photo.width == 1,
	) {return}
	square := shaped_avatar(entry.photo, "square")
	testing.expect(t, square != nil && square != entry.photo && square.tex != nil)
	sealed, read_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	testing.expect(t, !strings.contains(string(sealed), "private note text"))
	vault_rekey_ok := vault_rekey("rotated contact test") == .None
	if !testing.expect(t, vault_rekey_ok) {return}
	contact_store_stop()
	vault_lock()
	if !testing.expect(t, vault_open("rotated contact test") == .None) {return}
	contact_store_select(owner)
	entry = contact_test_entry(owner, peer)
	if !testing.expect(
		t,
		entry != nil && entry.note == "private note text" && entry.photo != nil,
	) {return}

	if !testing.expect(t, contact_store_save(owner, peer, "", nil, .Keep)) {return}
	deadline := time.tick_now()
	for entry.saving && time.tick_since(deadline) < 5 * time.Second {
		contact_store_drain()
		time.sleep(time.Millisecond)
	}
	if !testing.expect(t, !entry.saving && entry.done && entry.ok) {return}
	testing.expect(
		t,
		entry.note == "" && entry.photo != nil && entry.photo.width == 1,
		"clearing a note keeps the photo",
	)
	// A closed editor can leave its result unread. The next save supersedes it.
	if !testing.expect(
		t,
		contact_store_save(owner, peer, "keep this note", two.data, .Replace),
	) {return}
	stale, _ := contact_store_result(owner, peer)
	testing.expect(t, !stale)
	if !contact_test_result(t, owner, peer, true) {return}
	if !testing.expect(
		t,
		entry.note == "keep this note" && entry.photo != nil && entry.photo.width == 2,
	) {return}
	if !testing.expect(t, contact_store_save(owner, peer, "keep this note", nil, .Remove)) {return}
	if !contact_test_result(t, owner, peer, true) {return}
	testing.expect(
		t,
		entry.note == "keep this note" && entry.photo == nil && !entry.has_photo,
		"clearing a photo keeps the note",
	)

	// A file from a different peer or owner must not decrypt there, even
	// though both owners use the same vault blob key.
	other_path := contact_test_path(other, peer)
	if !testing.expect(
		t,
		os.make_directory_all(fmt.tprintf("%s/private-contacts/%s", data_home, other)) == nil,
	) {return}
	if !testing.expect(
		t,
		os.write_entire_file(other_path, sealed) == nil &&
		os.write_entire_file(contact_test_path(owner, second), sealed) == nil,
	) {return}
	copied_peer := contact_test_entry(owner, second)
	if !testing.expect(
		t,
		copied_peer != nil &&
		copied_peer.unreadable &&
		copied_peer.note == "" &&
		copied_peer.photo == nil,
	) {return}
	contact_store_select(other)
	testing.expect(t, contact_store_entry(owner, peer) == nil)
	copied_owner := contact_test_entry(other, peer)
	if !testing.expect(
		t,
		copied_owner != nil &&
		copied_owner.unreadable &&
		copied_owner.note == "" &&
		copied_owner.photo == nil,
	) {return}
	if !testing.expect(
		t,
		contact_store_save(other, peer, "would discard the photo", nil, .Keep),
	) {return}
	if !contact_test_result(t, other, peer, false) {return}
	still_copied, copied_err := os.read_entire_file(other_path, context.temp_allocator)
	testing.expect(t, copied_err == nil && string(still_copied) == string(sealed))
	if !testing.expect(t, contact_store_save(other, peer, "other owner", nil, .Remove)) {return}
	if !contact_test_result(t, other, peer, true) {return}
	testing.expect(t, copied_owner.note == "other owner" && !copied_owner.unreadable)

	// A valid envelope can still contain a broken image. Reject its declared
	// dimensions before decode, retain the note, and let Remove recover it.
	plain, opened := vault_open_blob(sealed, context.temp_allocator)
	if !testing.expect(t, opened && len(plain) >= len(one.data)) {return}
	defer mem.zero_slice(plain)
	png_at := len(plain) - len(one.data)
	plain[png_at + 16] = 0xff
	bad_png, sealed_bad := vault_seal_blob(plain, context.temp_allocator)
	if !testing.expect(t, sealed_bad && os.write_entire_file(path, bad_png) == nil) {return}
	contact_store_select(owner)
	entry = contact_test_entry(owner, peer)
	if !testing.expect(
		t,
		entry != nil &&
		entry.has_photo &&
		entry.photo == nil &&
		entry.unreadable &&
		entry.note == "private note text",
	) {return}
	if !testing.expect(t, contact_store_save(owner, peer, "new note", nil, .Keep)) {return}
	if !contact_test_result(t, owner, peer, false) {return}
	preserved, preserved_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(
		t,
		preserved_err == nil &&
		string(preserved) == string(bad_png) &&
		entry.note == "private note text",
	)
	if !testing.expect(
		t,
		contact_store_save(owner, peer, "remove damaged photo", nil, .Remove),
	) {return}
	if !contact_test_result(t, owner, peer, true) {return}
	testing.expect(
		t,
		entry.note == "remove damaged photo" && !entry.has_photo && !entry.unreadable,
	)

	// An atomic rename failure leaves the old in-memory values published.
	if !testing.expect(t, os.remove(path) == nil && os.make_directory(path) == nil) {return}
	if !testing.expect(
		t,
		contact_store_save(owner, peer, "cannot commit", two.data, .Replace),
	) {return}
	if !contact_test_result(t, owner, peer, false) {return}
	testing.expect(
		t,
		entry.note == "remove damaged photo" && entry.photo == nil && !entry.has_photo,
	)
	if !testing.expect(
		t,
		contact_store_save(owner, peer, "cannot commit", two.data, .Replace),
	) {return}
	contact_store_select(other)
	if !testing.expect(t, contact_test_entry(other, peer) != nil) {return}
	testing.expect(t, !contact_store_drain())
	contact_store_select(owner)
	testing.expect(t, contact_store_drain(), "failed write is reported only to its owner")
	if !testing.expect(t, os.remove(path) == nil) {return}

	// Purge may run before or after a queued save grabs the disk lock. Neither
	// ordering may recreate the deleted owner's directory.
	if !testing.expect(
		t,
		contact_store_save(owner, peer, "pending before purge", two.data, .Replace),
	) {return}
	testing.expect(t, contact_store_purge(owner))
	contact_store_stop()
	testing.expect(t, !os.exists(path) && os.exists(other_path))
	contact_store_select(other)
	entry = contact_test_entry(other, peer)
	if !testing.expect(t, entry != nil && entry.note == "other owner") {return}
	if !testing.expect(
		t,
		contact_store_save(other, peer, "accepted before switch", nil, .Keep),
	) {return}
	contact_store_select(owner)
	foreign_result, _ := contact_store_result(other, peer)
	testing.expect(t, !foreign_result && contact_store_entry(other, peer) == nil)
	contact_store_stop()
	contact_store_select(other)
	entry = contact_test_entry(other, peer)
	testing.expect(t, entry != nil && entry.note == "accepted before switch")
	contact_store_purge_all()
	testing.expect(t, !os.exists(fmt.tprintf("%s/private-contacts", data_home)))
}
