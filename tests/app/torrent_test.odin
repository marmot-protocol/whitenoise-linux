// Torrent metainfo: v1 multi-file with BEP 47 padding and tracker
// dedupe, pure v2 file trees, and hostile bencode rejected.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:testing"

// Bencoded byte string: "4:spam".
@(private = "file")
bs :: proc(s: string) -> string {
	return fmt.tprintf("%d:%s", len(s), s)
}

@(private = "file")
sum_hex :: proc(algorithm: hash.Algorithm, data: string) -> string {
	return string(
		hex.encode(
			hash.hash_string(algorithm, data, context.temp_allocator),
			context.temp_allocator,
		),
	)
}

@(private = "file")
tor_free :: proc(view: ^Tor_View) {
	for file in view.files {
		delete(file.path)
	}
	delete(view.files)
	delete(view.name)
	delete(view.magnet)
	free(view)
}

@(test)
torrent_v1_multi_file :: proc(t: ^testing.T) {
	info := strings.concatenate(
		{
			"d5:filesl",
			"d6:lengthi3e4:pathl3:dir5:a.txtee",
			"d4:attr1:p6:lengthi5e4:pathl4:.pad1:5ee", // padding, not listed
			"d6:lengthi1073741824e4:pathl5:b.binee",
			"e4:name4:demo12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAe",
		},
		context.temp_allocator,
	)
	a := "udp://tracker.example:80/announce"
	b := "https://t2.example/announce?k=v&x"
	meta := strings.concatenate(
		{"d8:announce", bs(a), "13:announce-listll", bs(a), bs(b), "ee4:info", info, "e"},
		context.temp_allocator,
	)

	view := tor_view_make(transmute([]u8)meta)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer tor_free(view)
	testing.expect_value(t, view.name, "demo")
	testing.expect_value(t, view.count, 2)
	testing.expect_value(t, view.total, i64(1073741827))
	testing.expect_value(t, len(view.files), 2)
	testing.expect_value(t, view.files[0].path, "dir/a.txt")
	testing.expect_value(t, view.files[0].size, i64(3))
	testing.expect_value(t, view.files[1].path, "b.bin")
	want := fmt.tprintf(
		"magnet:?xt=urn:btih:%s&dn=demo&tr=udp%%3A%%2F%%2Ftracker.example%%3A80%%2Fannounce&tr=https%%3A%%2F%%2Ft2.example%%2Fannounce%%3Fk%%3Dv%%26x",
		sum_hex(.Insecure_SHA1, info),
	)
	testing.expect_value(t, view.magnet, want)
	testing.expect_value(t, arc_size_label(view.total), "1.0 GiB")
}

@(test)
torrent_v2_file_tree :: proc(t: ^testing.T) {
	root := strings.repeat("R", 32, context.temp_allocator)
	info := strings.concatenate(
		{
			"d9:file treed",
			"3:dird5:x.bind0:d6:lengthi7e11:pieces root32:",
			root,
			"eee",
			"1:yd0:d6:lengthi0eee",
			"e12:meta versioni2e4:name3:pkg12:piece lengthi16384ee",
		},
		context.temp_allocator,
	)
	meta := strings.concatenate({"d4:info", info, "e"}, context.temp_allocator)

	view := tor_view_make(transmute([]u8)meta)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer tor_free(view)
	testing.expect_value(t, view.count, 2)
	testing.expect_value(t, view.total, i64(7))
	testing.expect_value(t, view.files[0].path, "dir/x.bin")
	testing.expect_value(t, view.files[1].path, "y")
	testing.expect_value(
		t,
		view.magnet,
		fmt.tprintf("magnet:?xt=urn:btmh:1220%s&dn=pkg", sum_hex(.SHA256, info)),
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
		tor_free(view)
	}
}
