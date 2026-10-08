package main

import "base:runtime"
import "core:testing"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=pull_request_card_layout
@(test)
pull_request_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "pull_request_card_layout" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-pr-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	rl.InitWindow(1200, 720, "Pull request preview")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 720})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.event_client = DEFAULT_EVENT_CLIENT
	ui.prefs.reduce_motion = true
	ui.nicknames["author"] = "Contributor"
	g_ui, g_prefs, g_client = &ui, &ui.prefs, client
	defer {g_ui, g_prefs, g_client = nil, nil, nil; wrap_clear(); delete(ui.nicknames)}
	gh_cards_on = true
	defer {gh_cards_on = false}
	token :: "note13ze9zdt8ulg08ggc4g9ycmpen5ltscc4hvfy8seceu578zlvkyzsq77jau"
	reported :: "nevent1qqs9vsvh2tklhuxfjy3f6vjuekf7n8xkvzlpawecgn386ravz3rm6nqprpmhxue69uhhyetvv9ujucmevfjhyem40yhxv7tf06mqr7"
	_, reference := nostr_at(reported, 0)
	if !testing.expect_value(t, reference.kind, Nostr_Kind.Event) {return}
	card_id :: u32(100 * 8 * 128)
	_, key, _, _ := nevent_at(token, 0)
	for subject, index in ([]string{`["subject","Fix relay reconnects"]`, `["subject"],["subject",42]`, `["subject","Fix relay reconnects without interrupting conversations on unreliable networks"]`}) {
		ui.nicknames["author"] =
			index == 2 ? "Contributor with a long display name" : "Contributor"
		event := fmt.tprintf(
			`{{"kind":1618,"pubkey":"author","created_at":1791417600,"content":"Keep **messages** flowing.\n\nfixes\n%s","tags":[%s]}}`,
			reported,
			subject,
		)
		append(&nev_fresh, struct {
			id:   string,
			card: Nev_Card,
		}{key, nev_parse(transmute([]u8)event, .Event)})
		drain_nev()
		for theme in ([]int{0, 1}) {
			apply_theme(theme, 0)
			for width in ([]f32{240, 360, 520}) {
				for frame in 0 ..< 3 {
					clay.BeginLayout()
					if clay.UI(clay.ID("Timeline"))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {
								width = clay.SizingFixed(width + 78),
								height = clay.SizingGrow(),
							},
							padding = clay.PaddingAll(16),
						},
						backgroundColor = BG,
					},
					) {
						if clay.UI(clay.ID("PullRequestBubble"))(
						{
							layout = {
								layoutDirection = .TopToBottom,
								sizing = {width = clay.SizingFixed(width + 32)},
								padding = clay.PaddingAll(16),
								childGap = 10,
							},
							backgroundColor = CARD,
							cornerRadius = rr(14),
						},
						) {
							clay.Text(
								"Shared pull request",
								{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT},
							)
							body_text(100, token, BODY_FS, TEXT, wrap_w = width)
						}
					}
					commands := clay.EndLayout(0)
					if frame < 2 {continue}
					shown := strings.builder_make(context.temp_allocator)
					bold := false
					title_bold := index != 0
					box := clay.GetElementData(clay.ID("PullRequestBubble")).boundingBox
					card_box := clay.GetElementData(clay.ID("NevCard", card_id)).boundingBox
					testing.expect(t, card_box.width <= width)
					if width ==
					   520 {testing.expect(t, card_box.width >= 480, "A wide chat must give the pull request enough reading room.")}
					for command in commands.internalArray[:commands.length] {
						if command.commandType != .Text {continue}
						text := command.renderData.text.stringContents
						part := string(text.chars[:text.length])
						strings.write_string(&shown, part)
						if part == "messages" {bold = command.renderData.text.fontId == FONT_TITLE}
						if strings.contains(
							part,
							"Fix relay",
						) {title_bold = command.renderData.text.fontId == FONT_TITLE}
						testing.expect(
							t,
							command.boundingBox.x >= box.x &&
							command.boundingBox.x + command.boundingBox.width <= box.x + box.width,
							part,
						)
					}
					visible := strings.to_string(shown)
					testing.expect(t, strings.contains(visible, "Contributor"))
					testing.expect(t, strings.contains(visible, "Keep messages flowing."))
					testing.expect(
						t,
						strings.contains(visible, reported),
						"The complete reference must remain readable after wrapping.",
					)
					testing.expect(t, bold)
					testing.expect(t, title_bold)
					testing.expect(
						t,
						!strings.contains(visible, "pubkey") && !strings.contains(visible, "**"),
					)
					if index ==
					   0 {testing.expect(t, strings.contains(visible, "Fix relay reconnects"))}
					rl.BeginDrawing()
					clay_raylib_render(&commands)
					rl.TakeScreenshot(
						fmt.ctprintf(
							"/tmp/wn-pull-request-%d-%d-%d.png",
							index,
							theme,
							int(width),
						),
					)
					rl.EndDrawing()
				}
			}
		}
		card := nev_cards[key]
		blocks_free(card.blocks)
		delete(
			card.raw,
		); delete(card.content); delete(card.pubkey); delete(card.stamp); delete(card.subject)
		delete(card.subject_fonts)
		delete_key(&nev_cards, key)
	}
}

// Isolated layout fixtures seed the session-only image cache without a network request.
@(private)
nev_test_image :: proc(url: string, tex: ^rl.Texture2D) {
	if tex == nil {delete_key(&nev_images, url)} else {nev_images[url] = tex}
}

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
