// Torrent metainfo: v1 multi-file with BEP 47 padding and tracker
// filtering, v2 file trees with padding leaves, and hostile bencode
// rejected.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"

// Bencoded byte string: "4:spam".
@(private = "file")
bs :: proc(s: string) -> string {
	return fmt.tprintf("%d:%s", len(s), s)
}

@(test)
torrent_v1_multi_file :: proc(t: ^testing.T) {
	// Same bytes aria2c -S reads as infohash c94bd4a4…05cb.
	info := strings.concatenate(
		{
			"d5:filesl",
			"d6:lengthi3e4:pathl3:dir5:a.txtee",
			"d4:attr1:p6:lengthi5e4:pathl4:.pad1:5ee", // padding, not listed
			"d6:lengthi5e4:pathl5:b.binee",
			"e4:name4:demo12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAe",
		},
		context.temp_allocator,
	)
	a := "udp://tracker.example:80/announce"
	b := "https://t2.example/announce?k=v&x"
	meta := strings.concatenate(
		{
			"d8:announce",
			bs(a),
			"13:announce-listll",
			bs(a),
			bs(b),
			bs("javascript:x"),
			"ee",
			"7:comment",
			bs("ripped from the archive"),
			"10:created by",
			bs("mktorrent 1.1"),
			"13:creation datei1790000000e",
			"4:info",
			info,
			"e",
		},
		context.temp_allocator,
	)

	view := tor_view_make(transmute([]u8)meta)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer tor_view_free(view)
	testing.expect_value(t, view.name, "demo")
	testing.expect_value(t, view.count, 2)
	testing.expect_value(t, view.total, i64(8))
	testing.expect_value(t, len(view.files), 2)
	testing.expect_value(t, view.files[0].path, "dir/a.txt")
	testing.expect_value(t, view.files[0].size, i64(3))
	testing.expect_value(t, view.files[1].path, "b.bin")
	// Duplicate announce folded, non-tracker scheme dropped.
	testing.expect_value(
		t,
		view.magnet,
		"magnet:?xt=urn:btih:c94bd4a423856cc36ff047d6e75d24c208cd05cb&dn=demo&tr=udp%3A%2F%2Ftracker.example%3A80%2Fannounce&tr=https%3A%2F%2Ft2.example%2Fannounce%3Fk%3Dv%26x",
	)
	testing.expect_value(t, view.infohash, "c94bd4a423856cc36ff047d6e75d24c208cd05cb")
	testing.expect_value(t, len(view.trackers), 2)
	testing.expect_value(t, view.piece_len, i64(16384))
	testing.expect_value(t, view.created, i64(1790000000))
	testing.expect_value(t, view.created_by, "mktorrent 1.1")
	testing.expect_value(t, view.comment, "ripped from the archive")
	testing.expect(t, !view.private)
	testing.expect_value(t, arc_size_label(1 << 30 + 1 << 20), "1.0 GiB")
}

@(test)
torrent_v2_file_tree :: proc(t: ^testing.T) {
	root := strings.repeat("R", 32, context.temp_allocator)
	info := strings.concatenate(
		{
			"d9:file treed",
			"4:.padd1:9d0:d4:attr1:p6:lengthi9eeee", // padding leaf, not listed
			"3:dird5:x.bind0:d6:lengthi7e11:pieces root32:",
			root,
			"eee",
			"1:yd0:d6:lengthi0eee",
			"e12:meta versioni2e4:name3:pkg12:piece lengthi16384e7:privatei1ee",
		},
		context.temp_allocator,
	)
	meta := strings.concatenate({"d4:info", info, "e"}, context.temp_allocator)

	view := tor_view_make(transmute([]u8)meta)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer tor_view_free(view)
	testing.expect_value(t, view.count, 2)
	testing.expect_value(t, view.total, i64(7))
	testing.expect_value(t, view.files[0].path, "dir/x.bin")
	testing.expect(t, view.private)
	testing.expect_value(t, view.files[1].path, "y")
	sum := hash.hash_string(.SHA256, info, context.temp_allocator)
	testing.expect_value(
		t,
		view.magnet,
		fmt.tprintf(
			"magnet:?xt=urn:btmh:1220%s&dn=pkg",
			string(hex.encode(sum, context.temp_allocator)),
		),
	)
}

@(test)
torrent_rejects_hostile :: proc(t: ^testing.T) {
	info := "d6:lengthi1e4:name1:a6:pieces20:AAAAAAAAAAAAAAAAAAAAe"
	cases := []string {
		"",
		"d4:info", // truncated
		strings.concatenate({"d4:info", info[:len(info) - 3]}, context.temp_allocator),
		"d4:infod6:lengthi1e4:name1:aee", // neither pieces nor meta version
		"d4:infod6:lengthi-1e4:name1:a6:pieces0:ee", // negative size
		"d4:info99999999999999999999999:e", // string length overflow
		"d4:infod6:lengthi99999999999999999999999e4:name1:a6:pieces0:ee", // int overflow
		strings.concatenate(
			{
				"d1:x",
				strings.repeat("l", 100, context.temp_allocator),
				strings.repeat("e", 100, context.temp_allocator),
				"4:info",
				info,
				"e",
			},
			context.temp_allocator,
		), // nesting past TOR_MAX_DEPTH
	}
	for input, i in cases {
		testing.expectf(t, tor_view_make(transmute([]u8)input) == nil, "case %d parsed", i)
	}

	// The same info inside a sane wrapper does parse: the rejections above
	// are about the damage, not the fixture.
	good := strings.concatenate({"d4:info", info, "e"}, context.temp_allocator)
	view := tor_view_make(transmute([]u8)good)
	testing.expect(t, view != nil)
	if view != nil {
		tor_view_free(view)
	}
}

// Closed: header and magnet button only. Open: the file rows appear.
// Either way no text runs past the tile's right edge, which a long
// release name used to do.
@(test)
torrent_tile_layout :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	name := "GTO.2026.EP10.1080p.NF.WEB-DL.AAC2.0.H.264-MagicStar.mkv"
	files := []Tor_File {
		{strings.concatenate({"Season 1/", name}, context.temp_allocator), 1 << 30},
		{"Season 1/sample.nfo", 900},
	}
	view := Tor_View {
		name       = name,
		files      = files,
		count      = 2,
		total      = 1 << 30 + 900,
		infohash   = "c94bd4a423856cc36ff047d6e75d24c208cd05cb",
		// The shape that ran past the tile: a URL with no space to wrap at.
		comment    = "https://avistaz.to/torrent/364971-gto-great-teacher-onizuka-s01e09-1080p-nf-web-dl-aac20-x264-magicstar",
		created_by = "avistaz.to",
		piece_len  = 2 << 20,
	}
	msg := Msg_Ui {
		sender = strings.clone("A"),
	}
	defer message_free(msg)
	append(&msg.att_names, strings.clone("x.torrent"))
	append(&msg.att_keys, strings.clone("k"))
	append(&msg.tors, Att_Item(^Tor_View){&view, 0})

	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 2000})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	heights: [2]f32
	for open, pass in ([]bool{false, true}) {
		view.open = open
		clay.BeginLayout()
		message_row(0, msg)
		commands := clay.EndLayout(0)
		tile := clay.GetElementData(clay.ID("MsgTor", 0))
		testing.expect(t, tile.found)
		heights[pass] = tile.boundingBox.height
		right := tile.boundingBox.x + tile.boundingBox.width
		listed := false
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			box := command.boundingBox
			if box.y < tile.boundingBox.y ||
			   box.y > tile.boundingBox.y + tile.boundingBox.height {continue}
			testing.expectf(
				t,
				box.x + box.width <= right + 0.5,
				"text overflows the tile (open=%v)",
				open,
			)
			text := command.renderData.text.stringContents
			listed ||= strings.has_suffix(string(text.chars[:text.length]), "sample.nfo")
		}
		testing.expect_value(t, listed, open)
	}
	testing.expect(t, heights[1] > heights[0])
}
