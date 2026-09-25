package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import cc "../vendor/crop-circles"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import rl "sdlrl"

@(test)
crop_circle_raw_digest :: proc(t: ^testing.T) {
	digest: [32]u8
	for &byte, i in digest {byte = u8(i)}
	key, _ := hex.encode(digest[:], context.temp_allocator)
	pixels, side := crop_circle_pixels(string(key))
	defer delete(pixels)
	expected := cc.make_from_digest(digest, .Detailed, module_size = 2, alpha = .Opaque)
	defer cc.image_destroy(expected)
	square, square_side := crop_circle_pixels(string(key), .Square)
	defer delete(square)
	testing.expect(t, square_side == side && slice.equal(square, expected.pixels))
	testing.expect_value(t, side, i32(expected.width))
	// Both original edges survive on every row, even at the slanted boundaries.
	for y in 0 ..< int(side) {
		row := y * int(side) * 4
		first, last := -1, -1
		for x in 0 ..< int(side) {
			if pixels[row + x * 4 + 3] == 0 {continue}
			if first < 0 {first = x}
			last = x
		}
		testing.expect(t, first >= 0 && last >= first)
		if first < 0 {continue}
		testing.expect(
			t,
			slice.equal(pixels[row + first * 4:row + first * 4 + 3], expected.pixels[row:row + 3]),
		)
		end := row + (int(side) - 1) * 4
		testing.expect(
			t,
			slice.equal(pixels[row + last * 4:row + last * 4 + 3], expected.pixels[end:end + 3]),
		)
	}
	// The sloped sides remove opposite corners and retain the center and other corners.
	testing.expect(t, pixels[3] > 0)
	testing.expect(t, pixels[len(pixels) - 1] > 0)
	testing.expect_value(t, pixels[(int(side) - 1) * 4 + 3], u8(0))
	testing.expect_value(t, pixels[(int(side) - 1) * int(side) * 4 + 3], u8(0))
	testing.expect_value(t, pixels[(int(side) / 2 * int(side) + int(side) / 2) * 4 + 3], u8(255))
	upper, upper_side := crop_circle_pixels(strings.to_upper(string(key), context.temp_allocator))
	defer delete(upper)
	testing.expect(t, side == upper_side && slice.equal(pixels, upper))
	hashed := cc.make_from_data(digest[:], .Detailed, module_size = 2, alpha = .Opaque)
	defer cc.image_destroy(hashed)
	testing.expect(
		t,
		!slice.equal(expected.pixels, hashed.pixels),
		"The npub must not be hashed a second time",
	)
	group_pixels, group_side := crop_circle_pixels(string(key[:32]))
	defer delete(group_pixels)
	group_digest: [32]u8
	hash.hash(.SHA256, digest[:16], group_digest[:])
	group_key, _ := hex.encode(group_digest[:], context.temp_allocator)
	group_expected, _ := crop_circle_pixels(string(group_key))
	defer delete(group_expected)
	testing.expect(t, group_side == side && slice.equal(group_pixels, group_expected))
	for bad in ([]string{"", "npub1invalid", strings.repeat("z", 64, context.temp_allocator), string(key[:62])}) {
		data, size := crop_circle_pixels(bad)
		testing.expect(t, data == nil && size == 0)
	}
}

@(test)
crop_circle_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "crop_circle_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1000, 1000, "Profile fingerprints")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1000, 1000})
	defer delete(memory)
	key := "66675158e6338fe89fda418e42a0bf2a7a2b132504dd347f015a18971b644430"
	url := fmt.tprintf("crop-circle:%s", key)
	start_pic_worker()
	defer stop_pic_worker()
	tex := url_pic(url)
	group_url := fmt.tprintf("crop-circle:%s", key[:32])
	group_tex := url_pic(group_url)
	square_url := fmt.tprintf("crop-square:%s", key)
	square_tex := url_pic(square_url)
	for i := 0; (tex == nil || group_tex == nil || square_tex == nil) && i < 100; i += 1 {
		time.sleep(10 * time.Millisecond)
		drain_pics()
		tex = url_pic(url)
		group_tex = url_pic(group_url)
		square_tex = url_pic(square_url)
	}
	testing.expect(t, tex != nil, "worker must generate and upload a fingerprint texture")
	testing.expect(t, group_tex != nil, "16-byte MLS IDs must produce a fingerprint")
	testing.expect(
		t,
		square_tex != nil && square_tex != tex,
		"square and slanted fingerprints need separate cached textures",
	)
	for tc in ([]struct {
			key:         string,
			photo, want: ^rl.Texture2D,
		}{{key, nil, tex}, {key[:32], nil, group_tex}, {key, square_tex, square_tex}}) {
		clay.BeginLayout()
		avatar("FallbackAvatar", 0, tc.key, "Initials", 42, tc.photo)
		commands := clay.EndLayout(0)
		box := clay.GetElementData(clay.ID("FallbackAvatar", 0)).boundingBox
		testing.expect_value(t, box.width, f32(42))
		drawn := false
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Image &&
			   command.id == clay.ID("AvatarImage", clay.ID("FallbackAvatar", 0).id).id {
				drawn = true
				testing.expect_value(t, command.renderData.image.imageData, rawptr(tc.want))
				testing.expect(
					t,
					abs(command.boundingBox.width - (tc.photo == nil ? f32(37.8) : 42)) < 0.001,
				)
				testing.expect(
					t,
					abs(
						command.boundingBox.x +
						command.boundingBox.width / 2 -
						box.x -
						box.width / 2,
					) <
					0.001,
				)
			}
		}
		testing.expect(t, drawn, "users and groups render crop circles; photos take precedence")
	}
	ui := Ui_State {
		account_ref      = key,
		selected_contact = 0,
	}
	ui.prefs.reduce_motion = true
	ui.nicknames[key] = "Danny"
	ui.profile.npub = hex_npub(key)
	ui.profile.qr = qr_texture(ui.profile.npub)
	defer {rl.UnloadTexture(ui.profile.qr^); free(ui.profile.qr)}
	ui.peer_hex, ui.peer_npub, ui.peer_name = key, ui.profile.npub, strings.clone("Danny")
	append(
		&ui.contacts,
		Contact_Ui{id_hex = key, name = strings.clone("Danny"), npub = ui.profile.npub},
	)
	append(&ui.chats, Chat_Row_Ui{group_id = key[:32], title = "Testing Marmots"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; wrap_clear()}
	mention_width: f32
	clay.SetPointerState({-1, -1}, false)
	for photo_url in ([]string{"", square_url, ""}) {
		if photo_url != "" || profile_info(nil, key).pic_url != "" {
			testing.expect(t, update_profile(&ui, key, {pic_url = strings.clone(photo_url)}))
		}
		anim_tick(1.0 / 60)
		clay.BeginLayout()
		render_segs(70, []Inline_Seg{{hex = key}}, BODY_FS, TEXT, 18, chips = true)
		peer_modal(&ui)
		commands := clay.EndLayout(0)
		testing.expect_value(
			t,
			clay.GetElementData(clay.ID("PeerCircle", 0)).found,
			photo_url != "",
		)
		mention := clay.ID("MentionAvatar", 70 * 128).id
		testing.expect(t, !clay.GetElementData(clay.ID("PeepReveal", mention)).found)
		for id in ([]clay.ElementId{clay.ID("PeepPhoto", mention), clay.ID("PeerAvatar", 0)}) {
			drawn := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Image ||
				   command.id != clay.ID("AvatarImage", id.id).id {continue}
				drawn = true
				testing.expect_value(
					t,
					command.renderData.image.imageData,
					rawptr(photo_url == "" ? tex : square_tex),
				)
			}
			testing.expect(t, drawn, "the primary avatar must keep its photo or fallback")
		}
		_, measured := body_atom(fmt.tprintf("@%s", ui.profile.npub), 0, BODY_FS)
		chip := clay.GetElementData(clay.ID("SegMention", 70 * 128)).boundingBox
		testing.expect(
			t,
			abs(chip.width - measured) < 0.01,
			"mention wrapping must match its rendered width",
		)
		if mention_width == 0 {
			mention_width = chip.width
		} else {
			testing.expect(
				t,
				abs(chip.width - mention_width) < 0.01,
				"photo changes must not reflow mentions",
			)
		}
	}
	testing.expect(t, update_profile(&ui, key, {pic_url = strings.clone(square_url)}))
	msg := Msg_Ui {
		id        = "m1",
		sender    = "Danny",
		sender_id = key,
		pic_url   = square_url,
	}
	for over in ([]bool{false, true, false}) {
		chip_before := clay.GetElementData(clay.ID("SegMention", 70 * 128)).boundingBox
		clay.SetPointerState(
			over ? clay.Vector2{chip_before.x + chip_before.width - 4, chip_before.y + 4} : clay.Vector2{-1, -1},
			false,
		)
		anim_tick(1.0 / 60)
		clay.BeginLayout()
		render_segs(70, []Inline_Seg{{hex = key}}, BODY_FS, TEXT, 18, chips = true)
		_ = clay.EndLayout(0)
		mention := clay.ID("MentionAvatar", 70 * 128)
		reveal := clay.GetElementData(clay.ID("PeepReveal", mention.id))
		testing.expect_value(t, reveal.found, over)
		chip := clay.GetElementData(clay.ID("SegMention", 70 * 128)).boundingBox
		testing.expect(t, abs(chip.width - mention_width) < 0.01, "hover must not reflow mentions")
		if over {
			testing.expect_value(t, mention_hover, key)
			photo := clay.GetElementData(mention).boundingBox
			mark := clay.GetElementData(clay.ID("PeepCircle", mention.id)).boundingBox
			testing.expect(t, mark == photo, "hover identity must replace the entire avatar")
			testing.expect_value(t, reveal.boundingBox, photo)
		}
	}
	// The sender avatar beside a message opens the same peephole.
	for over in ([]bool{false, true, false}) {
		box := clay.GetElementData(clay.ID("MsgAvatar", 0)).boundingBox
		clay.SetPointerState(
			over ? clay.Vector2{box.x + box.width / 2, box.y + box.height / 2} : clay.Vector2{-1, -1},
			false,
		)
		anim_tick(1.0 / 60)
		clay.BeginLayout()
		message_row(0, msg)
		_ = clay.EndLayout(0)
		avatar := clay.ID("MsgAvatar", 0)
		reveal := clay.GetElementData(clay.ID("PeepReveal", avatar.id))
		testing.expect_value(t, reveal.found, over)
		if over {
			testing.expect_value(t, reveal.boundingBox, clay.GetElementData(avatar).boundingBox)
		}
	}
	testing.expect(t, update_profile(&ui, key, {pic_url = strings.clone("")}))
	for shape in Crop_Shape {
		ui.prefs.crop_avatar_shape = shape
		url := fmt.tprintf("%s:%s", CROP_SHAPE_PREFIX[shape], key[:32])
		want := url_pic(url)
		for i := 0; want == nil && i < 100; i += 1 {
			time.sleep(10 * time.Millisecond)
			drain_pics()
			want = url_pic(url)
		}
		testing.expect(t, want != nil)
		for pane in 0 ..< 2 {
			clay.BeginLayout()
			if pane == 0 {encryption_modal(&ui, ui.chats[0])} else {chat_pane(&ui)}
			commands := clay.EndLayout(0)
			drawn := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Image ||
				   command.id != clay.ID(pane == 0 ? "EncCircle" : "MlsCircle", 0).id {continue}
				drawn = true
				testing.expect_value(t, command.renderData.image.imageData, rawptr(want))
			}
			testing.expect(
				t,
				drawn,
				"group info and chat header must use the chosen crop-circle shape",
			)
		}
	}
	ui.prefs.crop_avatar_shape = .Slanted
	for pane in 0 ..< 9 {
		width := pane == 6 || pane == 7 ? f32(350) : f32(900)
		if pane == 8 {
			ui.contacts[0].id_hex = "saved-other"
			ui.account_ref = "self"
			view_peer_profile(&ui, nil)
		}
		rl.SetWindowSize(i32(width + 100), 1000)
		clay.SetLayoutDimensions({width + 100, 1000})
		for frame in 0 ..< 3 {
			clay.UpdateScrollContainers(false, {}, 0)
			clay.BeginLayout()
			if clay.UI(clay.ID("CircleRoot"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(width), height = clay.SizingFixed(900)},
					layoutDirection = .TopToBottom,
				},
				backgroundColor = CARD,
			},
			) {
				switch pane {
				case 0:
					body_text(70, fmt.tprintf("@%s", ui.profile.npub), BODY_FS, TEXT, wrap_w = 800)
				case 1:
					contacts_pane(&ui)
				case 2:
					profile_pane(&ui)
				case 3:
					peer_modal(&ui)
				case 4:
					encryption_modal(&ui, ui.chats[0])
				case 5:
					chat_pane(&ui)
				case 6:
					profile_pane(&ui)
				case 7:
					contacts_pane(&ui)
				case 8:
					contacts_pane(&ui)
				}
			}
			commands := clay.EndLayout(0)
			if pane > 0 && pane < 3 {
				ids := []string{"ContactCircle", "ProfileCircle", "PeerCircle"}
				testing.expect(t, clay.GetElementData(clay.ID(ids[pane - 1], 0)).found)
				if pane < 3 {
					box := clay.GetElementData(clay.ID(ids[pane - 1], 0)).boundingBox
					testing.expect_value(t, box.width, f32(160))
					testing.expect_value(t, box.height, f32(160))
					qr :=
						clay.GetElementData(clay.ID(pane == 2 ? "ProfileQr" : "ContactQr")).boundingBox
					testing.expect(t, box.x + box.width < qr.x)
					testing.expect_value(t, box.y + box.height / 2, qr.y + qr.height / 2)
				}
			}
			if pane == 4 || pane == 5 {
				testing.expect(
					t,
					clay.GetElementData(clay.ID(pane == 4 ? "EncCircle" : "MlsCircle", 0)).found,
				)
			}
			if pane == 3 {
				testing.expect(t, clay.GetElementData(clay.ID("PeerViewProfile")).found)
				testing.expect(t, !clay.GetElementData(clay.ID("PeerCircle", 0)).found)
			}
			if (pane == 6 || pane == 7) && frame == 2 {
				prefix := pane == 6 ? "Profile" : "Contact"
				pattern :=
					clay.GetElementData(clay.ID(fmt.tprintf("%sPatternCard", prefix))).boundingBox
				qr := clay.GetElementData(clay.ID(fmt.tprintf("%sScanCard", prefix))).boundingBox
				testing.expect(t, pattern.y + pattern.height < qr.y)
				testing.expect(t, qr.x >= 0 && qr.x + qr.width <= width)
				data := clay.GetScrollContainerData(clay.ID(fmt.tprintf("%sPage", prefix)))
				testing.expect(
					t,
					data.found &&
					data.contentDimensions.height > data.scrollContainerDimensions.height,
					prefix,
				)
			}
			if pane == 8 {
				testing.expect(t, !clay.GetElementData(clay.ID("RemoveContactBtn")).found)
				for id in ([]string{"ContactQr", "StartChatBtn", "CopyNpubBtn"}) {testing.expect(t, clay.GetElementData(clay.ID(id)).found, id)}
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-crop-circle-%d.png", pane))
			rl.EndDrawing()
		}
	}
}
