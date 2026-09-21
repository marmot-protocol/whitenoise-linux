package main

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
profile_theme_and_shapes :: proc(t: ^testing.T) {
	raw := `{"kind":16767,"tags":[["c","#123456","background"],["c","#f1f2f3","text"],["c","#abcdef","primary"],["f","Body","https://example.org/body.woff2"],["f","Title","https://example.org/title.otf","title"],["bg","url https://example.org/tile.png","mode tile","m image/png"]]}`
	theme := profile_theme_parse(raw)
	defer {delete(theme.background); for font in theme.fonts {delete(font)}}
	testing.expect_value(t, theme.colors[0], clay.Color{18, 52, 86, 255})
	testing.expect_value(t, theme.colors[1], clay.Color{241, 242, 243, 255})
	testing.expect_value(t, theme.fonts[0], "https://example.org/body.woff2")
	testing.expect_value(t, theme.fonts[1], "https://example.org/title.otf")
	testing.expect(t, theme.tile && theme.background == "https://example.org/tile.png")
	for bad in ([]string{"{}", `{"kind":0,"tags":[]}`, `{"kind":16767,"content":"{\"background\":\"red\"}"}`, `{"kind":16767,"tags":[["c","#123456","background"],["c","#ffffff","text"],["c","#nope00","primary"]]}`, `{"kind":16767,"tags":[["c","#123456","background"],["c","#ffffff","text"],["c","#111111","primary"],["c","#222222","primary"]]}`}) {
		testing.expect(
			t,
			profile_theme_parse(bad).colors[0].a == 0,
			"incomplete or malformed themes must leave the app palette intact",
		)
	}
	for url in ([]string{"file:///etc/passwd", "javascript:alert(1)", "https://example.org/\nheader", "data:image/png,abc"}) {
		testing.expect(t, !profile_asset_url(url))
	}
	before := BG
	old := profile_palette(profile_colors(theme))
	testing.expect_value(t, BG, theme.colors[0])
	profile_palette(old)
	testing.expect_value(t, BG, before)
	for tc in ([][2]string{{`{"shape":"⭐"}`, "⭐"}, {`{"shape":"🐱"}`, "🐱"}, {`{"shape":"🇮🇹"}`, "🇮🇹"}, {`{"shape":"👩🏽‍💻"}`, "👩🏽‍💻"}, {`{"shape":"1️⃣"}`, "1️⃣"}, {`{"shape":"circle"}`, ""}, {`{"shape":"⭐🌙"}`, ""}, {`{"shape":42}`, ""}}) {
		shape := profile_shape_parse(tc[0])
		testing.expect_value(t, shape, tc[1])
		delete(shape)
	}
	pixels := make([]u8, 64 * 64 * 4, context.temp_allocator)
	for &byte in pixels {byte = 255}
	image := rl.Image{raw_data(pixels), 64, 64}
	for shape in ([]string{"circle", "rounded", "square", "⭐", "invalid"}) {
		masked := avatar_mask_pixels(image, shape)
		testing.expect(t, masked[(32 * 64 + 32) * 4 + 3] == 255, shape)
		testing.expect(t, masked[3] == (shape == "square" ? 255 : 0), shape)
		if shape == "square" {testing.expect(t, slice.equal(masked, pixels))}
		delete(masked)
	}
	for shape in Crop_Shape {
		pixels, side := crop_circle_pixels(strings.repeat("ab", 32, context.temp_allocator), shape)
		testing.expect(t, side > 0 && len(pixels) == int(side * side * 4))
		delete(pixels)
	}
	prefs := Prefs {
		avatar_shape      = .Square,
		crop_avatar_shape = .Rounded,
	}
	encoded, err := json.marshal(prefs, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	round_trip: Prefs
	testing.expect(t, json.unmarshal(encoded, &round_trip) == nil)
	testing.expect(
		t,
		round_trip.avatar_shape == .Square && round_trip.crop_avatar_shape == .Rounded,
	)
}

@(test)
profile_theme_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "profile_theme_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1100, 950, "Profile themes")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	memory: []u8
	init_layout(&memory, 32768, {1100, 950})
	defer delete(memory)
	data_home = "/tmp/wn-profile-layout"
	for dir in ([]string{"", "/events", "/events/img", "/events/fonts"}) {os.make_directory(fmt.tprintf("%s%s", data_home, dir))}
	key := strings.repeat("ab", 32)
	background := "https://example.invalid/theme-background.png"
	font := "https://example.invalid/profile-font.woff2"
	for asset, i in ([2]string{background, font}) {
		sum := string(
			hex.encode(
				hash.hash_string(.SHA256, asset, context.temp_allocator),
				context.temp_allocator,
			),
		)
		path :=
			i == 0 ? fmt.tprintf("%s/events/img/%s", data_home, sum) : fmt.tprintf("%s/events/fonts/%s.ttf", data_home, sum)
		bytes, err := os.read_entire_file(
			i == 0 ? "assets/whitenoise-linux.png" : "vendor/fonts/LiberationMono-Regular.ttf",
			context.temp_allocator,
		)
		testing.expect(t, err == nil && os.write_entire_file(path, bytes) == nil)
	}
	for kind in ([2]u32{16767, 0}) {
		payload: [42]u8
		payload[2], payload[3], payload[36], payload[37] = 2, 32, 3, 4
		for &byte in payload[4:36] {byte = 0xab}
		payload[40], payload[41] = u8(kind >> 8), u8(kind)
		ref := bech32_encode("naddr", payload[:])
		raw := fmt.tprintf(
			`{{"kind":16767,"tags":[["c","#171229","background"],["c","#fff2d9","text"],["c","#ffb66d","primary"],["f","Mono","%s","body"],["f","Mono","%s","title"],["bg","url %s","mode tile","m image/png"]]}}`,
			font,
			font,
			background,
		)
		nev_cards[ref] = {
			done    = true,
			raw     = kind == 16767 ? strings.clone(raw) : "",
			content = kind == 0 ? `{"shape":"⭐"}` : "",
		}
	}
	image := rl.LoadImage("assets/whitenoise-linux.png")
	register_local_pic("test://avatar", image)
	rl.UnloadImage(image)
	ui := Ui_State {
		account_ref      = key,
		selected_contact = 0,
	}
	ui.profile = {
		name  = "Theme visitor",
		about = "A profile with Ditto colors, a tiled background and custom fonts.",
		npub  = hex_npub(key),
	}
	ui.my_pic_url = "test://avatar"
	append(
		&ui.contacts,
		Contact_Ui {
			id_hex = key,
			name = "Theme visitor",
			npub = ui.profile.npub,
			pic_url = ui.my_pic_url,
		},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	// A timeline/list avatar resolves its shape before any profile has been opened.
	style := profile_style(key, .Avatar)
	testing.expect(
		t,
		style.shape == "⭐" && !style.done[0],
		"avatar lookup must not load profile themes",
	)
	photo := local_pic(ui.my_pic_url)
	ui.prefs.avatar_shape = .Square
	clay.BeginLayout()
	avatar("OutsideProfile", 0, key, "Visitor", 42, photo)
	avatar_commands := clay.EndLayout(0)
	for command in avatar_commands.internalArray[:avatar_commands.length] {
		if command.commandType != .Image {continue}
		testing.expect(
			t,
			command.renderData.image.imageData == rawptr(shaped_avatar(photo, "⭐")),
			"published shapes override the local default outside profiles too",
		)
	}
	profile_style(key)
	profile_font(font)
	nev_img(background)
	for worker in send_threads {thread.join(worker); thread.destroy(worker)}
	clear(&send_threads)
	drain_nev()
	testing.expect(t, profile_font(font) >= 32 && nev_img(background) != nil)
	before := BG
	for pane in 0 ..< 3 {
		for frame in 0 ..< 3 {
			clay.UpdateScrollContainers(false, {}, 0)
			clay.BeginLayout()
			if clay.UI(clay.ID("ProfileTestRoot"))(
			{
				layout = {sizing = {clay.SizingFixed(1100), clay.SizingFixed(950)}},
				backgroundColor = CARD,
			},
			) {
				if clay.UI(clay.ID("UnstyledSidebar"))(
				{
					layout = {
						sizing = {clay.SizingFixed(220), clay.SizingGrow()},
						padding = clay.PaddingAll(20),
					},
					backgroundColor = CARD,
				},
				) {
					avatar("SidebarShape", 0, key, "Visitor", 30, photo)
					clay.Text(
						"App stays unchanged",
						{fontId = FONT_BODY, fontSize = 14, textColor = TEXT},
					)
				}
				switch pane {
				case 0:
					contacts_pane(&ui)
				case 1:
					profile_pane(&ui)
				case 2:
					if clay.UI(clay.ID("SettingsTest"))(
					{
						layout = {
							sizing = {clay.SizingGrow(), clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(20),
							childGap = 10,
						},
					},
					) {settings_appearance(&ui)}
				}
			}
			commands := clay.EndLayout(0)
			testing.expect(
				t,
				BG == before,
				"profile colors must not leak to the sidebar or settings",
			)
			if pane < 2 {
				found_background, found_font := false, false
				for cmd in commands.internalArray[:commands.length] {
					if cmd.commandType == .Custom &&
					   (^Model_Kind)(cmd.renderData.custom.customData)^ ==
						   .Profile_Background {found_background = true}
					if cmd.commandType == .Text &&
					   cmd.renderData.text.fontId >= 32 {found_font = true}
				}
				testing.expect(t, found_background && found_font)
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-profile-theme-%d.png", pane))
			rl.EndDrawing()
		}
	}
}
