package main

import "base:runtime"
import "core:testing"

// Place /tmp/wn-robocoin.webp before running to include the real product photo.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=product_card_layout
@(test)
product_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "product_card_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(800, 700, "Product preview")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer {g_ui = nil; wrap_clear(); preview_close()}
	card := nev_parse(transmute([]u8)string(TEST_PRODUCT_JSON), .Event)
	nev_cards[TEST_PRODUCT] = card
	image := rl.LoadImage("/tmp/wn-robocoin.webp")
	texture := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	defer rl.UnloadTexture(texture)
	// Register even a missing image to prevent a network request in the test.
	nev_images[card.product.image] = &texture
	for width in ([]f32{200, 360}) {
		clay.BeginLayout()
		if clay.UI(clay.ID("ProductTest"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(width + 24)},
				padding = clay.PaddingAll(12),
				childGap = 6,
			},
			backgroundColor = PLATE,
		},
		) {
			nev_product_card(100, TEST_PRODUCT, card, width)
		}
		commands := clay.EndLayout(0)
		box := clay.GetElementData(clay.ID("ProductTest")).boundingBox
		testing.expect(t, box.width <= width + 24.1)
		testing.expect(t, box.height < 520) // Image, metadata, and a six-line excerpt.
		testing.expect(t, clay.GetElementData(clay.ID("NevMore", 100)).found)
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Text {
				testing.expect(
					t,
					command.boundingBox.x + command.boundingBox.width <= width + 24.1,
				)
			}
		}
		rl.BeginDrawing()
		clay_raylib_render(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-product-%.0f.png", width))
		rl.EndDrawing()
	}
	preview_message(card.content, card.blocks[:])
	testing.expect_value(t, string(preview.bytes), card.content)
	testing.expect_value(t, preview.kind, Preview_Kind.Message)
}

// Explicit network check using an empty cache and only the default fetch relays.
@(test)
nostr_live_lookup :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "nostr_live_lookup" {return}
	context.allocator = reload_allocator()
	path, err := os.make_directory_temp("/tmp", "wn-nostr-live-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	old_home := data_home
	data_home = path
	defer {data_home = old_home; delete(path)}
	for token in ([]string{TEST_PRODUCT, TEST_GEOCACHE, "naddr1qvzqqqrcvypzppscgyy746fhmrt0nq955z6xmf80pkvrat0yq0hpknqtd00z8z68qqgkwet0vdskx6rfdenj6etkv4h8guc6gs5y5"}) {
		_, ref := nostr_at(token, 0)
		testing.expect_value(t, ref.kind, Nostr_Kind.Address)
		job := new(Nev_Job)
		job.id, job.author = strings.clone(ref.key), strings.clone(ref.author)
		job.relays = make([]string, len(DEFAULT_FETCH_RELAYS))
		for relay, i in DEFAULT_FETCH_RELAYS {job.relays[i] = strings.clone(relay)}
		nev_worker(job)
		card := nev_fresh[len(nev_fresh) - 1].card
		testing.expect(
			t,
			len(card.raw) > 0,
			fmt.tprintf("kind %d from %s", ref.event_kind, ref.author),
		)
		testing.expect_value(t, card.kind, i64(ref.event_kind))
		if token == TEST_PRODUCT {testing.expect_value(t, card.product.title, "Lightning Piggy")}
		_ = os.write_entire_file(
			fmt.tprintf("/tmp/wn-live-%d.json", ref.event_kind),
			transmute([]u8)card.raw,
		)
	}
}

// Optional real assets: /tmp/wn-geocache.jpg and /tmp/wn-osm.png.
@(test)
geocache_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "geocache_card_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(800, 900, "Geocache preview")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {800, 900})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer {g_ui = nil; wrap_clear(); preview_close()}
	card := nev_parse(transmute([]u8)string(TEST_GEOCACHE_JSON), .Event, TEST_GEOCACHE)
	textures: [2]rl.Texture2D
	for path, i in ([]string{"/tmp/wn-geocache.jpg", "/tmp/wn-osm.png"}) {
		image := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
		textures[i] = rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
	}
	defer {for texture in textures {rl.UnloadTexture(texture)}}
	nev_images[card.geocache.image] = &textures[0]
	nev_images["https://tile.openstreetmap.org/15/29106/12901.png"] = &textures[1]
	for width in ([]f32{200, 360}) {
		for _ in 0 ..< 2 {
			clay.BeginLayout()
			if clay.UI(clay.ID("GeocacheTest"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingFixed(width + 24)},
					padding = clay.PaddingAll(12),
					childGap = 6,
				},
				backgroundColor = PLATE,
			},
			) {
				nev_geocache_card(101, TEST_GEOCACHE, card, width)
			}
			commands := clay.EndLayout(0)
			box := clay.GetElementData(clay.ID("GeocacheTest")).boundingBox
			testing.expect(t, box.width <= width + 24.1 && box.height < 800)
			testing.expect(t, clay.GetElementData(clay.ID("NevHint", 101)).found)
			map_box := clay.GetElementData(clay.ID("NevMap", 101)).boundingBox
			pin := clay.GetElementData(clay.ID("NevMapPin", 101)).boundingBox
			testing.expect(
				t,
				pin.x >= map_box.x &&
				pin.y >= map_box.y &&
				pin.x + pin.width <= map_box.x + map_box.width &&
				pin.y + pin.height <= map_box.y + map_box.height,
			)
			for command in commands.internalArray[:commands.length] {
				if command.commandType ==
				   .Text {testing.expect(t, command.boundingBox.x + command.boundingBox.width <= width + 24.1)}
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-geocache-%.0f.png", width))
			rl.EndDrawing()
		}
	}
	preview_message(card.geocache.hint)
	testing.expect_value(t, string(preview.bytes), card.geocache.hint)
}
