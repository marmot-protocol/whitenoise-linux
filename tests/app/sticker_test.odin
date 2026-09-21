package main

import "base:runtime"
import "core:c"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import rl "sdlrl"

@(private, default_calling_convention = "c", link_prefix = "rustsecp256k1_v0_10_0_")
foreign _ {
	context_create :: proc(flags: u32) -> rawptr ---
	context_destroy :: proc(ctx: rawptr) ---
	keypair_create :: proc(ctx: rawptr, pair: ^[96]u8, secret: [^]u8) -> c.int ---
	schnorrsig_sign32 :: proc(ctx: rawptr, sig: ^[64]u8, msg: [^]u8, pair: ^[96]u8, aux: rawptr) -> c.int ---
}

@(test)
sticker_pack_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	pk :: "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
	coordinate :: "30031:" + pk + ":tiny"
	sha :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	event := Sticker_Event {
		pubkey     = pk,
		kind       = STICKER_PACK_KIND,
		created_at = 123,
		tags       = {
			{"d", "tiny"},
			{"title", "Tiny"},
			{"pack_format", "sonar-sticker-pack-v1"},
			{
				"sticker",
				"ok",
				"url https://example.com/ok.png",
				"x " + sha,
				"m image/png",
				"alt A small marmot",
			},
			{"sticker", "ok", "url https://example.com/other.png", "x " + sha, "m image/png"},
			{"sticker", "bad", "url http://example.com/bad.png", "x " + sha, "m image/png"},
		},
	}
	tags_json, tags_err := json.marshal(event.tags)
	testing.expect(t, tags_err == nil)
	bytes := fmt.tprintf(`[0,"%s",123,30031,%s,""]`, pk, string(tags_json))
	digest := hash.hash_bytes(.SHA256, transmute([]u8)bytes)
	event.id = string(hex.encode(digest))
	secret: [32]u8; secret[31] = 3
	pair: [96]u8; sig: [64]u8
	ctx := context_create(1); defer context_destroy(ctx)
	testing.expect_value(t, keypair_create(ctx, &pair, raw_data(secret[:])), c.int(1))
	testing.expect_value(t, schnorrsig_sign32(ctx, &sig, raw_data(digest), &pair, nil), c.int(1))
	event.sig = string(hex.encode(sig[:]))
	testing.expect(t, sticker_event_valid(event))
	pack, items := sticker_parse_pack(event, coordinate, "wss://relay.example")
	testing.expect_value(t, pack.title, "Tiny")
	testing.expect_value(t, len(items), 1)
	if len(items) == 1 {
		testing.expect_value(t, items[0].label, "A small marmot")
		testing.expect_value(t, items[0].ref.pack, coordinate)
		testing.expect_value(t, items[0].ref.event, event.id)
		ref := sticker_ref_tag(sticker_tags(items[0].ref)[0])
		testing.expect_value(t, ref.pack, coordinate)
		testing.expect_value(t, ref.sha, sha)
	}
	event.tags[1][1] = "Forged"
	testing.expect(t, !sticker_event_valid(event), "changed signed metadata must be rejected")
	for invalid in ([]string{"", "30031:bad:tiny", "30030:" + pk + ":tiny", coordinate + "/../escape"}) {testing.expect(t, !sticker_coordinate(invalid))}
	for invalid in ([]string{"0x1", "1x0", "4097x1", "1x4097", "huge", "-1x4"}) {testing.expect(t, !sticker_dim_ok(invalid))}
	_, ok := sticker_pack_entry(
		{"sticker", "ok", "url https://example.com/a", "x " + sha, "m image/png", "invalid"},
	)
	testing.expect(t, !ok)
	item, valid := sticker_pack_entry(
		{
			"sticker",
			"ok",
			"m image/png",
			"x " + sha,
			"url https://example.com/a",
			"url http://ignored.example",
			"alt text with spaces",
		},
	)
	testing.expect(t, valid)
	testing.expect_value(t, item.label, "text with spaces")
	testing.expect_value(t, item.url, "https://example.com/a")
	testing.expect_value(t, sticker_ref_tag({"sticker", coordinate, "ok", "bad"}).sha, "")
}

@(test)
sticker_image_storage :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	previous := data_home
	data_home = "/tmp/wn-sticker-storage-test"
	defer {data_home = previous}
	os.make_directory(data_home); defer os.remove_all(data_home)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)
	bytes, err := base64.decode("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
	testing.expect(t, err == nil); defer delete(bytes)
	image := sticker_image(bytes, "image/webp")
	testing.expect(t, image.data != nil)
	if image.data != nil {rl.UnloadImage(image)}
	testing.expect(t, sticker_image(bytes, "image/png").data == nil)
	testing.expect(t, sticker_image(bytes[:12], "image/webp").data == nil)
	sha := string(
		hex.encode(
			hash.hash_bytes(.SHA256, bytes, context.temp_allocator),
			context.temp_allocator,
		),
	)
	testing.expect(t, sticker_write(sticker_blob_path(sha), bytes))
	stored, read_err := os.read_entire_file(sticker_blob_path(sha), context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(stored) != string(bytes),
		"library assets are encrypted at rest",
	)
	restored := sticker_read_blob(sha); defer delete(restored)
	testing.expect_value(t, string(restored), string(bytes))
	ui: Ui_State
	sticker_add_item(&ui, {ref = {sha = sha, code = "tiny"}, label = "Tiny", mime = "image/webp"})
	defer {for item in ui.stickers {sticker_item_free(item)}; delete(ui.stickers)}
	sticker_save_library(&ui)
	drain_stickers(&ui, nil)
	testing.expect_value(t, len(sticker_jobs), 1)
	thread.join(sticker_jobs[0].worker)
	drain_stickers(&ui, nil)
	testing.expect_value(t, len(sticker_jobs), 0)
	reloaded: Ui_State
	sticker_library_open(&reloaded)
	drain_stickers(&reloaded, nil)
	thread.join(sticker_jobs[0].worker)
	drain_stickers(&reloaded, nil)
	testing.expect(t, reloaded.sticker_loaded)
	testing.expect_value(t, len(reloaded.stickers), 1)
	if len(reloaded.stickers) == 1 {testing.expect_value(t, reloaded.stickers[0].ref.sha, sha)}
	for item in reloaded.stickers {sticker_item_free(item)}
	delete(reloaded.stickers)
	// Shutdown must complete a queued library write before releasing its bytes.
	delete(ui.stickers[0].label)
	ui.stickers[0].label = strings.clone("Renamed")
	sticker_save_library(&ui)
	sticker_stop()
	sticker_jobs, sticker_textures, sticker_requested = {}, {}, {}
	index, index_err := os.read_entire_file(
		fmt.tprintf("%s/stickers/library.bin", data_home),
		context.temp_allocator,
	)
	testing.expect(t, index_err == nil)
	plain, opened := vault_open_blob(index, context.temp_allocator)
	testing.expect(t, opened && strings.contains(string(plain), "Renamed"))
	testing.expect(t, sticker_write(sticker_blob_path(sha), []u8{1, 2, 3}))
	testing.expect_value(t, len(sticker_read_blob(sha)), 0)
}

@(test)
message_application_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	sha :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	p := Pending_Send {
		effect = 3,
		reply_to = sha,
		sticker = {
			pack = "30031:" + sha + ":tiny",
			code = "ok",
			sha = sha,
			event = sha,
			relay = "wss://example.com",
		},
	}
	tags := send_message_tags(&p)
	testing.expect_value(t, len(tags), 5)
	testing.expect_value(t, string(tags[0].values[0]), "sticker")
	testing.expect_value(t, string(tags[0].values[1]), p.sticker.pack)
	testing.expect_value(t, string(tags[1].values[0]), "sticker-relay")
	testing.expect_value(t, string(tags[2].values[0]), "effect")
	testing.expect_value(t, string(tags[2].values[1]), "party")
	testing.expect_value(t, string(tags[3].values[0]), "e")
	testing.expect_value(t, string(tags[4].values[0]), "q")
}

@(test)
sticker_artwork_preserved :: proc(t: ^testing.T) {
	pixels: [32 * 32][4]u8
	for &pixel, i in pixels {pixel = {80, 100, 120, u8(i % 256)}}
	before := pixels
	image := sticker_thumb({data = ([^]u8)(raw_data(pixels[:])), width = 32, height = 32})
	testing.expect_value(t, image.width, i32(32))
	testing.expect_value(t, image.height, i32(32))
	testing.expect_value(t, pixels, before)
	testing.expect(t, sticker_thumb({}).data == nil)
}
