package main

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import rl "sdlrl"

// Run queued sticker jobs to completion. A nil client makes every MDK call
// fail fast, which leaves only the app's own storage observable.
@(private)
sticker_test_drain :: proc(ui: ^Ui_State) {
	for len(sticker_jobs) > 0 {
		drain_stickers(ui, nil)
		for job in sticker_jobs {
			if job.worker == nil {continue}
			for !thread.is_done(job.worker) {time.sleep(time.Millisecond)}
		}
	}
}

@(test)
sticker_image_storage :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	defer vault_lock()
	previous := data_home
	data_home = "/tmp/wn-sticker-storage-test"
	defer {data_home = previous}
	os.make_directory(data_home); defer os.remove_all(data_home)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)
	bytes, err := base64.decode("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
	testing.expect(t, err == nil); defer delete(bytes)
	// A message reference carries no MIME type, so the bytes pick the decoder.
	image := sticker_image(bytes)
	testing.expect(t, image.data != nil)
	if image.data != nil {rl.UnloadImage(image)}
	testing.expect(t, sticker_image(bytes[:12]).data == nil)
	testing.expect(
		t,
		sticker_image(transmute([]u8)string("GIF89a\x01\x00\x01\x00\x00\x00")).data == nil,
	)
	sha := string(
		hex.encode(
			hash.hash_bytes(.SHA256, bytes, context.temp_allocator),
			context.temp_allocator,
		),
	)
	testing.expect(t, media_write_sealed(sticker_blob_path(sha), bytes))
	stored, read_err := os.read_entire_file(sticker_blob_path(sha), context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(stored) != string(bytes),
		"cached artwork is encrypted at rest",
	)
	restored := sticker_read_blob(sha); defer delete(restored)
	testing.expect_value(t, string(restored), string(bytes))

	// Personal stickers survive a reload and a vault password change. A pack
	// sticker left in library.bin from before MDK is no longer personal.
	ui: Ui_State
	defer {
		for item in ui.stickers {sticker_item_free(item)}
		delete(ui.stickers)
		for value in ui.sticker_recent {delete(value)}
		delete(ui.sticker_recent)
	}
	sticker_add_item(&ui, {ref = {sha = sha, code = "tiny"}, label = "Tiny", mime = "image/webp"})
	old_pack := strings.concatenate({"30031:", sha, ":old"}, context.temp_allocator)
	sticker_add_item(&ui, {ref = {pack = old_pack, code = "old", sha = sha}})
	append(&ui.sticker_recent, strings.clone(sha))
	legacy := Sticker_Library{ui.stickers, nil, ui.sticker_recent}
	encoded, encode_err := json.marshal(legacy, allocator = context.temp_allocator)
	testing.expect(t, encode_err == nil)
	testing.expect(t, media_write_sealed(sticker_library_path(), encoded))
	for password in ([]string{"", "second password"}) {
		if password != "" {
			testing.expect_value(t, vault_rekey(password), Vault_Err.None)
			vault_lock()
			testing.expect_value(t, vault_open(password), Vault_Err.None)
		}
		reloaded: Ui_State
		sticker_library_open(&reloaded)
		sticker_test_drain(&reloaded)
		testing.expect_value(t, len(reloaded.stickers), 1)
		if len(reloaded.stickers) == 1 {
			testing.expect_value(t, reloaded.stickers[0].ref.sha, sha)
			testing.expect_value(t, reloaded.stickers[0].ref.pack, "")
		}
		testing.expect_value(t, len(reloaded.sticker_recent), 1)
		for item in reloaded.stickers {sticker_item_free(item)}
		delete(reloaded.stickers)
		for value in reloaded.sticker_recent {delete(value)}
		delete(reloaded.sticker_recent)
		kept := sticker_read_blob(sha)
		testing.expect_value(t, string(kept), string(bytes))
		delete(kept)
	}

	// Shutdown must complete a queued library write before releasing its bytes.
	delete(ui.stickers[0].label)
	ui.stickers[0].label = strings.clone("Renamed")
	sticker_save_library(&ui)
	sticker_stop()
	sticker_jobs, sticker_textures, sticker_requested = {}, {}, {}
	sealed, sealed_err := os.read_entire_file(sticker_library_path(), context.temp_allocator)
	testing.expect(t, sealed_err == nil)
	plain, opened := vault_open_blob(sealed, context.temp_allocator)
	testing.expect(t, opened && strings.contains(string(plain), "Renamed"))
	testing.expect(t, media_write_sealed(sticker_blob_path(sha), []u8{1, 2, 3}))
	testing.expect_value(t, len(sticker_read_blob(sha)), 0)
}

@(test)
message_application_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	sha :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	p := Pending_Send {
		effect = 3,
		reply_to = sha,
		sticker = {pack = "30031:" + sha + ":tiny", code = "ok", sha = sha},
	}
	// MDK writes a pack sticker's tag itself; only the effect and reply ride along.
	tags := send_message_tags(&p)
	testing.expect_value(t, len(tags), 3)
	testing.expect_value(t, string(tags[0].values[0]), "effect")
	testing.expect_value(t, string(tags[0].values[1]), "party")
	testing.expect_value(t, string(tags[1].values[0]), "e")
	testing.expect_value(t, string(tags[2].values[0]), "q")
	testing.expect_value(t, string(tags[2].values[1]), sha)
	// A personal sticker is this app's own tag on its attachment send.
	p.sticker.pack = ""
	tags = send_message_tags(&p)
	testing.expect_value(t, len(tags), 4)
	testing.expect_value(t, string(tags[0].values[0]), "wn-sticker")
	testing.expect_value(t, string(tags[0].values[1]), sha)
	testing.expect_value(t, string(tags[0].values[2]), "ok")
}

@(test)
sticker_artwork_preserved :: proc(t: ^testing.T) {
	pixels: [32 * 32][4]u8
	for &pixel, i in pixels {pixel = {80, 100, 120, u8(i % 256)}}
	before := pixels
	image := image_fit({data = ([^]u8)(raw_data(pixels[:])), width = 32, height = 32}, STICKER_PX)
	testing.expect_value(t, image.width, i32(32))
	testing.expect_value(t, image.height, i32(32))
	testing.expect_value(t, pixels, before)
	testing.expect(t, image_fit({}, STICKER_PX).data == nil)
}
