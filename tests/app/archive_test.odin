// Sandboxed archive listing, extraction and parent-side metadata validation.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:hash"
import "core:testing"

@(private = "file")
le16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

@(private = "file")
le32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(test)
archive_zip :: proc(t: ^testing.T) {
	name := "hello.txt"
	body := "hi there"
	crc := hash.crc32(transmute([]u8)body)

	zip: [dynamic]u8
	// Local file header + name + stored data.
	le32(&zip, 0x04034b50)
	le16(&zip, 20) // version needed
	le16(&zip, 0) // flags
	le16(&zip, 0) // method: stored
	le32(&zip, 0) // dos time+date
	le32(&zip, crc)
	le32(&zip, u32(len(body)))
	le32(&zip, u32(len(body)))
	le16(&zip, u16(len(name)))
	le16(&zip, 0)
	append(&zip, name)
	append(&zip, body)

	// Central directory.
	cd_off := u32(len(zip))
	le32(&zip, 0x02014b50)
	le16(&zip, 20)
	le16(&zip, 20)
	le16(&zip, 0)
	le16(&zip, 0)
	le32(&zip, 0)
	le32(&zip, crc)
	le32(&zip, u32(len(body)))
	le32(&zip, u32(len(body)))
	le16(&zip, u16(len(name)))
	le16(&zip, 0) // extra
	le16(&zip, 0) // comment
	le16(&zip, 0) // disk
	le16(&zip, 0) // internal attrs
	le32(&zip, 0) // external attrs
	le32(&zip, 0) // local header offset
	append(&zip, name)
	cd_size := u32(len(zip)) - cd_off

	// End of central directory.
	le32(&zip, 0x06054b50)
	le16(&zip, 0)
	le16(&zip, 0)
	le16(&zip, 1)
	le16(&zip, 1)
	le32(&zip, cd_size)
	le32(&zip, cd_off)
	le16(&zip, 0)

	view := arc_view_make(zip[:])
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer arc_view_free(view)
	testing.expect_value(t, len(view.entries), 1)
	testing.expect_value(t, view.entries[0].name, name)
	testing.expect_value(t, view.entries[0].size, i64(len(body)))

	bytes, ok := arc_entry_bytes(view, view.entries[0].index)
	defer delete(bytes)
	testing.expect(t, ok)
	testing.expect_value(t, string(bytes), body)

	// Garbage input is rejected, not listed.
	junk := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, arc_view_make(junk) == nil)
}

@(private = "file")
arc_test_record :: proc(out: ^[dynamic]u8, index: u32, name: string, size: i64 = 0) {
	le32(out, index)
	le32(out, u32(len(name)))
	bits := transmute(u64)size
	le32(out, u32(bits))
	le32(out, u32(bits >> 32))
	append(out, name)
}

@(test)
archive_metadata :: proc(t: ^testing.T) {
	payload: [dynamic]u8
	defer delete(payload)
	arc_test_record(&payload, 2, "café.txt", -1)
	arc_test_record(&payload, ARC_MAX_HEADERS - 1, "empty", 0)
	entries, ok := arc_parse_entries(payload[:], 2)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, entries[0].name, "café.txt")
		testing.expect_value(t, entries[0].size, i64(-1))
		testing.expect_value(t, entries[1].index, ARC_MAX_HEADERS - 1)
		for entry in entries {delete(entry.name)}
		delete(entries)
	}
	// Truncated records/names and undeclared trailing records cannot publish
	// partial metadata, even when the first record was valid.
	for length in 0 ..< len(payload) {
		rejected, valid := arc_parse_entries(payload[:length], 2)
		testing.expect(t, !valid && rejected == nil)
	}
	for count in ([]u32{0, 1, 3, ARC_MAX_ENTRIES + 1}) {
		rejected, valid := arc_parse_entries(payload[:], count)
		testing.expect(t, !valid && rejected == nil)
	}
	for index in ([]u32{0, 2, ARC_MAX_HEADERS, 0xffffffff}) {
		clear(&payload)
		arc_test_record(&payload, 2, "first")
		arc_test_record(&payload, index, "second")
		rejected, valid := arc_parse_entries(payload[:], 2)
		testing.expect(t, !valid && rejected == nil)
	}
	for name in ([]string{"", "bad\x00name", "\xff", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80"}) {
		clear(&payload)
		arc_test_record(&payload, 0, name)
		rejected, valid := arc_parse_entries(payload[:], 1)
		testing.expect(t, !valid && rejected == nil)
	}
	clear(&payload)
	arc_test_record(&payload, 0, "negative", -2)
	rejected, valid := arc_parse_entries(payload[:], 1)
	testing.expect(t, !valid && rejected == nil)
	clear(&payload)
	arc_test_record(&payload, 0, "short")
	// A huge declared name length must be rejected before slicing.
	for i in 4 ..< 8 {payload[i] = 0xff}
	rejected, valid = arc_parse_entries(payload[:], 1)
	testing.expect(t, !valid && rejected == nil)
	long_name := make([]u8, ARC_MAX_NAME_BYTES + 1)
	defer delete(long_name)
	for &b in long_name {b = 'a'}
	clear(&payload)
	arc_test_record(&payload, 0, string(long_name))
	rejected, valid = arc_parse_entries(payload[:], 1)
	testing.expect(t, !valid && rejected == nil)
	oversized := make([]u8, ARC_MAX_LIST_BYTES + 1)
	defer delete(oversized)
	rejected, valid = arc_parse_entries(oversized, 1)
	testing.expect(t, !valid && rejected == nil)
}
