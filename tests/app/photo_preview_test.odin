package main

import "core:encoding/base64"
import "core:encoding/endian"
import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
photo_crop_pixels :: proc(t: ^testing.T) {
	// Distinct RGBA pixels, including alpha, expose offsets/stride mistakes.
	pixels: [4 * 3 * 4]u8
	for i in 0 ..< 12 {
		pixels[i * 4 + 0] = u8(i)
		pixels[i * 4 + 1] = u8(100 + i)
		pixels[i * 4 + 2] = 200
		pixels[i * 4 + 3] = u8(20 + i)
	}
	source := rl.Image {
		data   = &pixels[0],
		width  = 4,
		height = 3,
	}
	draft, ok := photo_crop_draft(source, {true, 1, 1, 2})
	if !testing.expect(t, ok) {return}
	defer pic_draft_free(&draft)
	testing.expect_value(t, draft.media_type, "image/png")
	decoded := rl.LoadImageFromMemory(".png", raw_data(draft.data), i32(len(draft.data)))
	if !testing.expect(t, decoded.data != nil) {return}
	defer rl.UnloadImage(decoded)
	testing.expect_value(t, decoded.width, i32(2))
	testing.expect_value(t, decoded.height, i32(2))
	actual := ([^]u8)(decoded.data)[:16]
	for original, i in ([]int{5, 6, 9, 10}) {
		for channel in 0 ..< 4 {testing.expect_value(t, actual[i * 4 + channel], pixels[original * 4 + channel])}
	}
	bad, bad_ok := photo_crop_draft(source, {true, 3, 1, 2})
	testing.expect(t, !bad_ok && bad.data == nil && bad.image.data == nil)
	p := Photo_Preview {
		draft = {image = source},
	}
	photo_crop_start(&p)
	testing.expect_value(t, p.crop.side, i32(3))
	p.crop.x = 100; p.crop.y = -100; p.crop.side = 2
	photo_crop_clamp(&p)
	testing.expect_value(t, p.crop.x, i32(2))
	testing.expect_value(t, p.crop.y, i32(0))
	photo_crop_resize(&p, 100)
	testing.expect_value(t, p.crop.side, i32(3))
	testing.expect_value(t, p.crop.x, i32(1))
}

@(test)
photo_crop_corner_resize :: proc(t: ^testing.T) {
	p := Photo_Preview {
		draft = {image = {width = 800, height = 600}},
	}
	origin := Photo_Crop{true, 200, 150, 200}
	for corner in 1 ..= 4 {
		p.crop, p.crop_origin, p.crop_corner = origin, origin, corner
		left := corner == 1 || corner == 3
		top := corner == 1 || corner == 2
		anchor_x := origin.x + (left ? origin.side : 0)
		anchor_y := origin.y + (top ? origin.side : 0)
		for delta in ([]f32{80, -80, 2000, -2000}) {
			photo_crop_drag_to(&p, left ? -delta : delta, top ? -delta : delta)
			testing.expect(t, p.crop.side >= 1 && p.crop.x >= 0 && p.crop.y >= 0)
			testing.expect(t, p.crop.x + p.crop.side <= 800 && p.crop.y + p.crop.side <= 600)
			testing.expect_value(t, p.crop.x + (left ? p.crop.side : 0), anchor_x)
			testing.expect_value(t, p.crop.y + (top ? p.crop.side : 0), anchor_y)
			if delta == 80 {testing.expect_value(t, p.crop.side, i32(280))}
			if delta == -80 {testing.expect_value(t, p.crop.side, i32(120))}
			if delta == -2000 {testing.expect_value(t, p.crop.side, i32(1))}
		}
		// One-axis drags still resize a square, with no pointer-jump on press.
		photo_crop_drag_to(&p, 0, 0)
		testing.expect_value(t, p.crop, origin)
		photo_crop_drag_to(&p, left ? f32(-80) : f32(80), 0)
		testing.expect_value(t, p.crop.side, i32(240))
	}
	p.crop, p.crop_origin, p.crop_corner = origin, origin, 0
	photo_crop_drag_to(&p, 35, -20)
	testing.expect_value(t, p.crop, Photo_Crop{true, 235, 130, 200})
	photo_crop_drag_to(&p, 2000, -2000)
	testing.expect_value(t, p.crop, Photo_Crop{true, 600, 0, 200})
}

// Real encoded fixture, decoded by the same helper used for native picks.
photo_test_bytes :: proc() -> []u8 {
	bytes, _ := base64.decode("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
	return bytes
}

photo_test_ui :: proc() -> Ui_State {
	ui := Ui_State {
		account_ref = "account-a",
		selected    = 0,
	}
	append(&ui.accounts, Account_Row_Ui{id_hex = "account-a"})
	append(&ui.chats, Chat_Row_Ui{group_id = "group-a"})
	append(&ui.members, Member_Ui{is_self = true, is_admin = true})
	return ui
}

photo_test_free :: proc(ui: ^Ui_State) {
	photo_cancel(ui)
	delete(ui.accounts); delete(ui.chats); delete(ui.members)
	delete(ui.client_status)
}

@(test)
photo_preview_targets :: proc(t: ^testing.T) {
	ui := photo_test_ui()
	defer photo_test_free(&ui)
	testing.expect(t, photo_pick_begin(&ui, .Group))
	testing.expect_value(t, ui.photo.account, "account-a")
	testing.expect_value(t, ui.photo.group, "group-a")
	testing.expect(t, !photo_pick_begin(&ui, .Profile), "An outstanding pick cannot be retargeted")
	ui.account_ref = "account-b"
	photo_check_target(&ui)
	testing.expect_value(t, ui.photo.kind, Photo_Kind.None)
	testing.expect(
		t,
		ui.photo.pending && photo_input_capture(&ui),
		"Invalidation retains the callback tombstone",
	)
	photo_pick_complete(&ui, []string{"/does/not/exist.png"})
	testing.expect(t, !photo_input_capture(&ui))
	testing.expect_value(t, len(ui.staged), 0)

	ui.account_ref = "account-a"
	testing.expect(t, photo_pick_begin(&ui, .Group))
	ui.chats[0].group_id = "group-b"
	testing.expect(t, !photo_target_valid(&ui))
	photo_pick_complete(&ui, nil)
	testing.expect(t, !photo_input_capture(&ui), "Native cancellation consumes the intent")
	ui.chats[0].group_id = "group-a"
	testing.expect(t, photo_pick_begin(&ui, .Group))
	ui.photo.pending = false
	ui.members[0].is_admin = false
	testing.expect(t, !photo_target_valid(&ui))
	ui.members[0].is_admin = true
	ui.selected = -1
	testing.expect(t, !photo_target_valid(&ui))
	ui.selected = 0
	clear(&ui.accounts)
	testing.expect(t, !photo_target_valid(&ui), "Removed accounts cannot confirm")
	append(&ui.accounts, Account_Row_Ui{id_hex = "account-a"})
	job := Account_Job {
		account = "account-a",
		group   = "group-a",
		kind    = .Leave,
	}
	old_jobs := account_jobs
	account_jobs = {}
	append(&account_jobs, &job)
	defer {delete(account_jobs); account_jobs = old_jobs}
	testing.expect(t, !photo_target_valid(&ui))
	job.kind = .Remove
	testing.expect(t, !photo_target_valid(&ui))
}

@(test)
photo_preview_invalid_files :: proc(t: ^testing.T) {
	ui := photo_test_ui()
	defer photo_test_free(&ui)
	dir, err := os.make_directory_temp("", "wn-photo-validation", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(dir)
	for name in ([]string{"bad.png", "not-an-image.txt"}) {
		path := strings.concatenate({dir, "/", name}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, []u8{1, 2, 3}) == nil)
		testing.expect(t, photo_pick_begin(&ui, .Profile))
		photo_pick_complete(&ui, []string{path})
		testing.expect(t, !photo_input_capture(&ui))
		testing.expect(t, ui.photo.draft.data == nil && ui.photo.draft.image.data == nil)
		delete(ui.client_status); ui.client_status = ""
	}
	testing.expect(t, photo_pick_begin(&ui, .Profile))
	photo_pick_complete(&ui, []string{"/does/not/exist.png"})
	testing.expect(t, !photo_input_capture(&ui))
	testing.expect(t, !ppic_busy && !gimg_writes_pending())
}

@(test)
photo_profile_result_account :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-b",
		my_pic_url  = "existing-b",
	}
	adopt_profile_pic(&ui, "account-a", strings.clone("uploaded-a"))
	testing.expect_value(t, ui.my_pic_url, "existing-b")
	testing.expect(t, !ui.profile.pic_set)
	adopt_profile_pic(&ui, "account-b", strings.clone("uploaded-b"))
	testing.expect_value(t, ui.my_pic_url, "uploaded-b")
	testing.expect(t, ui.profile.pic_set)
	delete(ui.my_pic_url)
}

@(test)
photo_contact_exif :: proc(t: ^testing.T) {
	LITTLE :: "II\x2a\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00"
	BIG :: "MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x08\x00\x00\x00\x00\x00\x00"
	JPEG :: "\xff\xd8\xff\xe1\x00\x22Exif\x00\x00" + LITTLE
	WEBP :: "RIFF\x26\x00\x00\x00WEBPEXIF\x1a\x00\x00\x00" + BIG
	for fixture, i in ([2]string{JPEG, WEBP}) {
		bytes := transmute([]u8)fixture
		for end in 0 ..< len(bytes) {testing.expect_value(t, photo_orientation(bytes[:end]), u16(1))}
		testing.expect_value(t, photo_orientation(bytes), i == 0 ? u16(6) : u16(8))
	}
	// Insert a real PNG eXIf chunk after IHDR and send it through the decoder.
	pixels := [16]u8{1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255}
	plain, ok := photo_crop_draft(
		{data = raw_data(pixels[:]), width = 2, height = 2},
		{true, 0, 0, 2},
	)
	if !testing.expect(t, ok) {return}
	defer pic_draft_free(&plain)
	chunk: [12 + len(LITTLE)]u8
	endian.unchecked_put_u32be(chunk[:], len(LITTLE))
	copy(chunk[4:], transmute([]u8)string("eXIf" + LITTLE))
	endian.unchecked_put_u32be(chunk[len(chunk) - 4:], hash.crc32(chunk[4:len(chunk) - 4]))
	with_exif := make([]u8, len(plain.data) + len(chunk), context.temp_allocator)
	copy(with_exif, plain.data[:33])
	copy(with_exif[33:], chunk[:])
	copy(with_exif[33 + len(chunk):], plain.data[33:])
	decoded := photo_contact_decode(with_exif)
	if !testing.expect(t, decoded.image.data != nil) {return}
	defer pic_draft_free(&decoded)
	testing.expect(t, decoded.data == nil, "Original encoded bytes must not enter the preview")
	for value, i in ([4]u8{3, 1, 4, 2}) {testing.expect_value(t, decoded.image.data[i * 4], value)}
	clean, clean_ok := photo_crop_draft(decoded.image, {true, 0, 0, 2}, .Contact_Crop)
	if !testing.expect(t, clean_ok) {return}
	defer pic_draft_free(&clean)
	testing.expect_value(t, photo_orientation(clean.data), u16(1))
	testing.expect(t, !strings.contains(string(clean.data), "eXIf"))
}

@(test)
photo_contact_crop_cap :: proc(t: ^testing.T) {
	W :: 530
	H :: 528
	SIDE :: 520
	X :: 7
	Y :: 3
	pixels := make([][4]u8, W * H, context.temp_allocator)
	for y in Y ..< Y + SIDE {
		for x in X ..< X + SIDE {pixels[y * W + x] = {40, 100, 200, 128}}
	}
	source := rl.Image {
		data   = ([^]u8)(raw_data(pixels)),
		width  = W,
		height = H,
	}
	draft, ok := photo_crop_draft(source, {true, X, Y, SIDE}, .Contact_Crop)
	if !testing.expect(t, ok) {return}
	defer pic_draft_free(&draft)
	testing.expect_value(t, draft.image.width, i32(512))
	testing.expect_value(t, draft.image.height, i32(512))
	testing.expect(t, 0 < len(draft.data) && len(draft.data) <= 2 * 1024 * 1024)
	rgba := ([^][4]u8)(draft.image.data)
	for corner in ([4]int{0, 511, 511 * 512, 512 * 512 - 1}) {
		testing.expect_value(t, rgba[corner], [4]u8{40, 100, 200, 128})
	}
}
