// libarchive listing + single-entry extraction on a handcrafted
// stored (uncompressed) zip.
// Run: ODIN_ROOT=build/odin-root odin test app
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
