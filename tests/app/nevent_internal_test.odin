package main

import "base:runtime"
import "core:testing"

@(private)
nev_highlight_test_free :: proc(card: Nev_Card) {
	blocks_free(card.blocks)
	for value in ([]string{card.raw, card.content, card.pubkey, card.stamp, card.subject, card.subject_fonts, card.highlight.comment, card.highlight.surrounding}) {delete(value)}
	for source in card.highlight.sources {delete(source.text); delete(source.url)}
	for author in card.highlight.authors {delete(author.pubkey); delete(author.role)}
	delete(card.highlight.sources)
	delete(card.highlight.authors)
}

@(test)
highlight_metadata :: proc(t: ^testing.T) {
	id :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	author :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	editor :: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	mention :: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	unmarked :: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	event := fmt.tprintf(
		`{{"kind":9802,"pubkey":"%s","content":"**literal quote**","tags":[null,{{}},[],["comment"],["comment",42],["context",{{}}],["r"],["r",42],["p",false],["comment","First commentary"],["comment","Ignored commentary"],["context","Before **literal quote** after"],["context","Ignored context"],["r","https://mention.example/","mention"],["r","https://unmarked.example/"],["r","https://source.example/","source"],["r","https://second-source.example/","source"],["r","javascript:alert(1)","source"],["r","file:///tmp/private"],["r","https://bad.example/\nunsafe"],["i","isbn:9780131103627","https://books.example/reference"],["i","doi:unsafe","javascript:alert(1)"],["a","30023:%s:chapter:one"],["a","30023:not-a-pubkey:invalid"],["a","bad:%s:invalid"],["e","%s"],["e","short"],["e",42],["p","%s","","mention"],["p","%s","","author"],["p","%s","","editor"],["p","%s"],["p","%s","","reviewer"],["p","invalid","","author"]]}}`,
		author,
		author,
		author,
		id,
		mention,
		author,
		editor,
		unmarked,
		mention,
	)
	card := nev_parse(transmute([]u8)event, .Event)
	defer nev_highlight_test_free(card)
	testing.expect_value(t, card.kind, i64(9802))
	testing.expect_value(t, card.content, "**literal quote**")
	testing.expect_value(t, card.highlight.comment, "First commentary")
	testing.expect_value(t, card.highlight.surrounding, "Before **literal quote** after")
	if testing.expect(t, len(card.highlight.sources) >= 3) {
		testing.expect_value(t, card.highlight.sources[0].url, "https://source.example/")
		testing.expect_value(t, card.highlight.sources[1].url, "https://second-source.example/")
	}
	plain_r, book, unsafe_identifier, native_event, native_address: bool
	for source in card.highlight.sources {
		testing.expect(
			t,
			source.text != "https://mention.example/",
			"A mentioned URL is not a highlight source.",
		)
		testing.expect(
			t,
			!strings.has_prefix(source.url, "javascript:") &&
			!strings.has_prefix(source.url, "file:") &&
			!strings.contains(source.url, "\n"),
			"Unsafe sources must never be clickable.",
		)
		switch source.text {
		case "https://unmarked.example/":
			plain_r = source.url == source.text
		case "isbn:9780131103627":
			book = source.url == "https://books.example/reference"
		case "doi:unsafe":
			unsafe_identifier = source.url == ""
		case:
			if strings.has_prefix(source.text, "note1") {
				_, ref := nostr_at(source.text, 0)
				if ref.kind == .Event && ref.key == id {native_event = true}
				testing.expect_value(t, source.url, "")
			} else if strings.has_prefix(source.text, "naddr1") {
				_, ref := nostr_at(source.text, 0)
				if ref.kind == .Address &&
				   ref.author == author &&
				   ref.event_kind == 30023 &&
				   ref.identifier == "chapter:one" {native_address = true}
				testing.expect_value(t, source.url, "")
			}
		}
	}
	testing.expect(
		t,
		plain_r && book && unsafe_identifier && native_event && native_address,
		"All legitimate source forms must survive parsing.",
	)
	testing.expect_value(t, len(card.highlight.authors), 3)
	found_author, found_editor, found_unmarked: bool
	for attribution in card.highlight.authors {
		testing.expect(t, attribution.pubkey != mention && attribution.pubkey != "invalid")
		switch attribution.pubkey {
		case author:
			found_author = true; testing.expect_value(t, attribution.role, "author")
		case editor:
			found_editor = true; testing.expect_value(t, attribution.role, "editor")
		case unmarked:
			found_unmarked = true; testing.expect_value(t, attribution.role, "author")
		case:
			testing.expect(
				t,
				false,
				"Only source authors and editors belong in the attribution list.",
			)
		}
	}
	testing.expect(t, found_author && found_editor && found_unmarked)
	empty := nev_parse(
		transmute([]u8)string(
			`{"kind":9802,"pubkey":"highlighter","content":"","tags":[["comment",""],["comment","Not the first comment"],["context",""],["context","Not the first context"]]}`,
		),
		.Event,
	)
	defer nev_highlight_test_free(empty)
	testing.expect_value(t, empty.kind, i64(9802))
	testing.expect_value(t, empty.content, "")
	testing.expect_value(t, empty.highlight.comment, "")
	testing.expect_value(t, empty.highlight.surrounding, "")
	invalid := nev_parse(
		transmute([]u8)string(
			`{"kind":9802,"pubkey":"highlighter","content":"quote","tags":[["a","30023:no:bad"],["a","-1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:x"],["e","zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"],["p","not-hex"]]}`,
		),
		.Event,
	)
	defer nev_highlight_test_free(invalid)
	for source in invalid.highlight.sources {
		testing.expect_value(t, source.url, "")
		_, ref := nostr_at(source.text, 0)
		testing.expect(
			t,
			ref.kind != .Event && ref.kind != .Address,
			"Invalid native ids cannot become navigable references.",
		)
	}
	testing.expect_value(t, len(invalid.highlight.authors), 0)
}

@(private)
nev_highlight_test_compact :: proc(text: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	for ch in text {
		if ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t' {strings.write_rune(&out, ch)}
	}
	return strings.to_string(out)
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=highlight_card_layout
@(test)
highlight_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "highlight_card_layout" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-highlight-*", context.temp_allocator)
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
	rl.InitWindow(900, 2400, "Highlight preview")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 2400})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.event_client = DEFAULT_EVENT_CLIENT
	ui.prefs.reduce_motion = true
	ui.prefs.message_lines = DEFAULT_MESSAGE_LINES
	ui.nicknames["highlighter"] = "Highlighter with an extraordinarily long display name that must stay inside its card"
	author :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	ui.nicknames[author] = "SourceAuthorWithAnExtremelyLongUnbrokenDisplayNameToExerciseNarrowCards"
	g_ui, g_prefs, g_client = &ui, &ui.prefs, client
	defer {g_ui, g_prefs, g_client = nil, nil, nil; wrap_clear(); delete(ui.nicknames)
		delete(ui.link_url)
		delete(sel_lines)
		sel_lines = nil}
	old_cards, old_fresh := nev_cards, nev_fresh
	old_previews := gh_cards_on
	gh_cards_on = true
	defer {gh_cards_on = old_previews}
	nev_cards, nev_fresh = nil, nil
	defer {delete(nev_cards); delete(nev_fresh); nev_cards, nev_fresh = old_cards, old_fresh}
	token :: "note13ze9zdt8ulg08ggc4g9ycmpen5ltscc4hvfy8seceu578zlvkyzsq77jau"
	_, key, _, valid := nevent_at(token, 0)
	if !testing.expect(t, valid) {return}
	card_id :: u32(100 * 8 * 128)
	excerpt_id :: u32(0x24000000 + card_id * 64 + 5)
	long_url := fmt.tprintf(
		"https://source.example/%s",
		strings.repeat("long-unbroken-source-", 12, context.temp_allocator),
	)
	long_quote := fmt.tprintf(
		"%sQUOTEEND",
		strings.repeat(
			"Literal quotation wraps without losing words. ",
			9,
			context.temp_allocator,
		),
	)
	long_comment := fmt.tprintf(
		"%sCOMMENTEND",
		strings.repeat(
			"Commentary also keeps its complete text when expanded. ",
			8,
			context.temp_allocator,
		),
	)
	leading_context := fmt.tprintf(
		"%s**LEADINGMARK** End of the surrounding passage.",
		strings.repeat(
			"Long leading context should not hide the selection. ",
			16,
			context.temp_allocator,
		),
	)
	for fixture, index in ([]struct {
			content, comment, surrounding: string,
		}{{"**BOLDMARK**", "Commentary above the selected passage.", "Quiet prefix **BOLDMARK** quiet suffix."}, {"", "A comment on a media-only passage.", ""}, {"QUOTEMISMATCH", "Commentary about a different context.", "CONTEXTMISMATCH describes the surrounding document, not the quotation."}, {long_quote, long_comment, ""}, {"**LEADINGMARK**", "Commentary on a selection late in its surrounding passage.", leading_context}}) {
		content_json, _ := json.marshal(fixture.content)
		comment_json, _ := json.marshal(fixture.comment)
		context_json, _ := json.marshal(fixture.surrounding)
		event := fmt.tprintf(
			`{{"kind":9802,"pubkey":"highlighter","created_at":1791417600,"content":%s,"tags":[["comment",%s],["context",%s],["r","%s","source"],["p","%s","","author"]]}}`,
			string(content_json),
			string(comment_json),
			string(context_json),
			long_url,
			author,
		)
		owned_key := strings.clone(key)
		append(&nev_fresh, struct {
			id:   string,
			card: Nev_Card,
		}{owned_key, nev_parse(transmute([]u8)event, .Event)})
		delete(content_json); delete(comment_json); delete(context_json)
		drain_nev()
		for theme in ([]int{0, 1}) {
			apply_theme(theme, 0)
			for width in ([]f32{220, 360, 460}) {
				for expanded in ([]bool{false, true}) {
					card := nev_cards[key]
					if card.excerpt.expanded !=
					   expanded {excerpt_toggle(&card.excerpt, expanded && index >= 3 ? nev_more_id : excerpt_id); nev_cards[key] = card}
					for frame in 0 ..< 3 {
						clear(&sel_lines)
						clay.SetPointerState({-100, -100}, false)
						if index >= 3 && frame > 0 {
							button := clay.GetElementData(clay.ID("NevMore", card_id)).boundingBox
							clay.SetPointerState(
								{button.x + button.width / 2, button.y + button.height / 2},
								false,
							)
						}
						nev_more_hover = ""
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
							if clay.UI(clay.ID("HighlightBubble"))(
							{
								layout = {
									layoutDirection = .TopToBottom,
									sizing = {width = clay.SizingFixed(width + 32)},
									padding = clay.PaddingAll(16),
								},
								backgroundColor = CARD,
								cornerRadius = rr(14),
							},
							) {body_text(100, token, BODY_FS, TEXT, wrap_w = width)}
						}
						commands := clay.EndLayout(0)
						if frame < 2 {continue}
						card_box := clay.GetElementData(clay.ID("NevCard", card_id)).boundingBox
						quote := clay.GetElementData(clay.ID("NevHighlightQuote", card_id))
						comment := clay.GetElementData(clay.ID("NevHighlightComment", card_id))
						selection := clay.GetElementData(clay.ID("ExcerptBody", excerpt_id))
						attribution := clay.GetElementData(
							clay.ID("NevHighlightAuthor", card_id * 64),
						)
						testing.expect(t, card_box.width > 0 && card_box.width <= width + 0.1)
						testing.expect(t, quote.found && comment.found)
						testing.expect(
							t,
							attribution.found &&
							clay.GetElementData(clay.ID("NevHighlightSource", card_id * 64)).found,
						)
						if index >= 3 {
							testing.expect(
								t,
								nev_more_hover == key,
								"The expansion action must be reachable through the rendered card.",
							)
							testing.expect_value(t, nev_more_id, excerpt_id)
						}
						for box in ([]clay.BoundingBox{quote.boundingBox, comment.boundingBox}) {
							testing.expect(
								t,
								box.x >= card_box.x &&
								box.x + box.width <= card_box.x + card_box.width + 0.1 &&
								box.y >= card_box.y &&
								box.y + box.height <= card_box.y + card_box.height + 0.1,
								"Highlight panels must remain contained by the event card.",
							)
						}
						testing.expect(
							t,
							comment.boundingBox.y + comment.boundingBox.height <=
							quote.boundingBox.y + 0.1,
							"Commentary must sit above the quotation.",
						)
						shown := strings.builder_make(context.temp_allocator)
						quote_text := strings.builder_make(context.temp_allocator)
						selection_text := strings.builder_make(context.temp_allocator)
						comment_text := strings.builder_make(context.temp_allocator)
						bold, mismatch_muted: bool
						for command in commands.internalArray[:commands.length] {
							if command.commandType != .Text {continue}
							data := command.renderData.text
							part := string(data.stringContents.chars[:data.stringContents.length])
							box := command.boundingBox
							strings.write_string(&shown, part)
							testing.expect(
								t,
								box.x >= card_box.x - 0.1 &&
								box.x + box.width <= card_box.x + card_box.width + 0.1,
								part,
							)
							if box.y >= quote.boundingBox.y &&
							   box.y < quote.boundingBox.y + quote.boundingBox.height {
								if box.y <
								   attribution.boundingBox.y {strings.write_string(&quote_text, part)}
								if strings.contains(part, "BOLDMARK") ||
								   strings.contains(
									   part,
									   "LEADINGMARK",
								   ) {bold = data.fontId == FONT_TITLE}
								testing.expect(
									t,
									box.x >= quote.boundingBox.x - 0.1 &&
									box.x + box.width <=
										quote.boundingBox.x + quote.boundingBox.width + 0.1 &&
									box.y + box.height <=
										quote.boundingBox.y + quote.boundingBox.height + 0.1,
									"Quote text must not escape its panel.",
								)
							}
							if selection.found &&
							   box.y >= selection.boundingBox.y &&
							   box.y <
								   selection.boundingBox.y +
									   selection.boundingBox.height {strings.write_string(&selection_text, part)}
							if box.y >= comment.boundingBox.y &&
							   box.y < comment.boundingBox.y + comment.boundingBox.height {
								strings.write_string(&comment_text, part)
								testing.expect(
									t,
									box.x >= comment.boundingBox.x - 0.1 &&
									box.x + box.width <=
										comment.boundingBox.x + comment.boundingBox.width + 0.1 &&
									box.y + box.height <=
										comment.boundingBox.y + comment.boundingBox.height + 0.1,
									"Comment text must not escape its panel.",
								)
							}
							if strings.contains(
								part,
								"CONTEXTMISMATCH",
							) {mismatch_muted = data.textColor == TEXT_DIM || data.textColor == TEXT_LO}
						}
						visible := strings.to_string(shown)
						quoted := strings.to_string(quote_text)
						selected := strings.to_string(selection_text)
						commentary := strings.to_string(comment_text)
						testing.expect(
							t,
							!strings.contains(visible, "\"tags\"") &&
							!strings.contains(visible, "pubkey") &&
							!strings.contains(visible, "created_at"),
							"The highlight must not fall back to raw event JSON.",
						)
						switch index {
						case 0:
							testing.expect(
								t,
								strings.count(visible, "**BOLDMARK**") == 1,
								"Context containing the selected text must display it only once, literally.",
							)
							testing.expect(t, bold)
							testing.expect(
								t,
								strings.contains(quoted, "Quiet") &&
								strings.contains(quoted, "suffix."),
							)
						case 2:
							testing.expect_value(t, strings.count(visible, "QUOTEMISMATCH"), 1)
							testing.expect(
								t,
								strings.contains(selected, "QUOTEMISMATCH") &&
								!strings.contains(selected, "CONTEXTMISMATCH"),
							)
							testing.expect(
								t,
								strings.contains(visible, "CONTEXTMISMATCH") && mismatch_muted,
								"Unrelated context must be separate muted text, not a replacement quotation.",
							)
						case 3:
							testing.expect(
								t,
								clay.GetElementData(clay.ID("NevMore", card_id)).found,
							)
							if expanded {
								testing.expect(
									t,
									nev_highlight_test_compact(selected) ==
									nev_highlight_test_compact(fixture.content),
									"Expansion must preserve the entire quotation.",
								)
								testing.expect(
									t,
									nev_highlight_test_compact(commentary) ==
									nev_highlight_test_compact(fixture.comment),
									"The same expansion control must preserve the entire commentary.",
								)
							} else {
								testing.expect(
									t,
									!strings.contains(quoted, "QUOTEEND") &&
									!strings.contains(commentary, "COMMENTEND"),
									"Both long passages should be bounded before expansion.",
								)
							}
						case 4:
							testing.expect(
								t,
								strings.count(quoted, "**LEADINGMARK**") == 1,
								"The selected passage must remain visible even after long leading context.",
							)
							testing.expect(t, bold)
							testing.expect(
								t,
								clay.GetElementData(clay.ID("NevMore", card_id)).found,
							)
							if expanded {testing.expect(t, nev_highlight_test_compact(selected) == nev_highlight_test_compact(fixture.surrounding), "Expansion must restore the full surrounding passage.")}
						}
						rl.BeginDrawing()
						clay_raylib_render(&commands)
						rl.TakeScreenshot(
							fmt.ctprintf(
								"/tmp/wn-highlight-%d-%d-%d-%d.png",
								index,
								theme,
								int(width),
								expanded ? 1 : 0,
							),
						)
						rl.EndDrawing()
					}
				}
			}
		}
		nev_highlight_test_free(nev_cards[key])
		delete_key(&nev_cards, key)
		delete(owned_key)
		wrap_clear()
	}
}

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
