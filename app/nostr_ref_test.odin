package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
TEST_NADDR :: "naddr1qqxnzd3cxqmrzv3exgmr2wfeqgsxu35yyt0mwjjh8pcz4zprhxegz69t4wr9t74vk6zne58wzh0waycrqsqqqa28pjfdhz"
@(private)
TEST_PRIMAL :: "https://primal.net/e/nevent1qqsg3vj3x4n7058n5yv25zjvdsue604cvv2mkyjrcvuv720r30ktzpgpz3mhxue69uhhyetvv9ujuerpd46hxtnfdudrh9q7"
@(private)
TEST_MENTIONS :: " @npub1klkk3vrzme455yh9rl2jshq7rc8dpegj3ndf82c3ks2sk40dxt7qulx3vt @npub1zuuajd7u3sx8xu92yav9jwxpr839cs0kc3q6t56vd5u9q033xmhsk6c2uc please add npub1ptujqywytey7cd4kmuj5vj2cmaxd26l37qw7tjvhy5ttxg5rgyzspc74c2"

@(private)
TEST_GEOCACHE :: "naddr1qq0h2mnfde6x2un9wd6x2epdv9a82un9943k7aedxgcrjvmzv9snsq3qyzfm42rzr3dj2h50flpvdl0uzrv22kv2y4ghve804w5xqu6lzqcqxpqqqzfgcsns8xq"
@(private)
TEST_GEOCACHE_JSON :: `{"kind":37516,"pubkey":"2093baa8621c5b255e8f4fc2c6fdfc10d8a5598a25517664efaba860735f1030","content":"A lucky cat sits up high, looking out for good fortune.","tags":[["d","uninterested-azure-cow-2093baa8"],["name","Kitty lookout"],["D","2"],["T","1"],["S","small"],["g","xn7"],["g","xn77hdukr"],["g","xn77"],["hint","Sitting above the stickers - on a shelf above the pillar of stickers"],["image","https://blossom.primal.net/26d6cdf1e8a630e6ca4f1d5d2f9c9236e668c1e4400d4ba146f91bec9a3fa1c4.jpg"]]}`

@(test)
nostr_geocache_preview :: proc(t: ^testing.T) {
	card := nev_parse(transmute([]u8)string(TEST_GEOCACHE_JSON), .Event, TEST_GEOCACHE)
	c := card.geocache
	testing.expect_value(t, card.kind, i64(NEV_GEOCACHE_KIND))
	testing.expect_value(t, c.name, "Kitty lookout")
	testing.expect_value(t, c.difficulty, 2)
	testing.expect_value(t, c.terrain, 1)
	testing.expect_value(t, c.size, "Small")
	testing.expect_value(t, c.geohash, "xn77hdukr")
	testing.expect(t, c.lat > 35.69944 && c.lat < 35.69946)
	testing.expect(t, c.lon > 139.77421 && c.lon < 139.77424)
	lat, lon, valid := geohash_coords("ezs42")
	testing.expect(t, valid && lat > 42.58 && lat < 42.61 && lon > -5.61 && lon < -5.58)
	for bad in ([]string{"", "xx", "aaaaaaaaa", "xn77hdukrx", "xn77hduk!"}) {
		_, _, valid := geohash_coords(bad)
		testing.expect(t, !valid)
	}
	variant, _ := strings.replace_all(TEST_GEOCACHE_JSON, `"tags":[`, `"tags":[null,[],["D",3],["T","6"],["S",{}],["g","invalid00"],["image","file:///tmp/no"],`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).geocache.geohash, c.geohash)
	variant, _ = strings.replace_all(TEST_GEOCACHE_JSON, `"g","xn77hdukr"`, `"g","invalid00"`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).geocache.geohash, "xn77")
}

@(test)
nostr_reference_cases :: proc(t: ^testing.T) {
	list := `["EVENT","wn",{"kind":10002,"pubkey":"seller","tags":[["r","wss://nos.lol"],["r","wss://read.only","read"],["r","wss://write.only","write"],["r","file:///tmp/no"],null]}]`
	relays := nev_relay_urls(transmute([]u8)list, "seller")
	testing.expect_value(t, len(relays), 2)
	testing.expect_value(t, relays[0], "wss://nos.lol")
	testing.expect_value(t, relays[1], "wss://write.only")
	testing.expect_value(t, len(nev_relay_urls(transmute([]u8)list, "someone-else")), 0)
	end, address := nostr_at(TEST_NADDR, 0)
	testing.expect_value(t, end, len(TEST_NADDR))
	testing.expect_value(t, address.kind, Nostr_Kind.Address)
	testing.expect_value(t, address.event_kind, 30023)
	testing.expect(t, len(address.identifier) > 0)
	request := nev_request(address.key)
	value, err := json.parse_string(request)
	testing.expect(t, err == nil, request)
	if err == nil {
		defer json.destroy_value(value)
		filter := value.(json.Array)[2].(json.Object)
		testing.expect_value(t, string(filter["authors"].(json.Array)[0].(json.String)), address.author)
		testing.expect_value(t, string(filter["#d"].(json.Array)[0].(json.String)), address.identifier)
	}
	_, event := nostr_at(TEST_PRIMAL, 0)
	testing.expect_value(t, event.kind, Nostr_Kind.Event)
	testing.expect_value(t, len(event.key), 64)
	testing.expect(t, strings.has_prefix(event.token, "nevent1"))
	value, err = json.parse_string(nev_request(event.key))
	testing.expect(t, err == nil)
	if err == nil { json.destroy_value(value) }
	segs := inline_segs("see " + TEST_PRIMAL + " now")
	testing.expect_value(t, len(segs), 3)
	testing.expect_value(t, segs[1].evid, event.key)

	for bad in ([]string{
		"nostr:npub1thisisnotvalidbech32datawillfailchecksum000000000000000000",
		"nevent1qqstna2yrezu5wghjvswqqculwvwxsrcvu7uc0f78gan4xqhvz49d9spr3mhxue69uhkummnw3ez6un9d3shjtn4de6x2argwghx6egpr4mhxue69uhkummnw3ez6ur4vgh8wetvd3hhyer9wghxuet5",
		"naddr1qqqq", "Npub1qqqq",
	}) {
		last, ref := nostr_at(bad, 0)
		testing.expect_value(t, last, len(bad))
		testing.expect_value(t, ref.kind, Nostr_Kind.Invalid)
		parts := inline_segs(bad)
		testing.expect_value(t, len(parts), 1)
		testing.expect(t, parts[0].bad_ref)
		testing.expect_value(t, parts[0].evid, "")
	}
	// A valid checksum cannot excuse truncated or duplicate TLVs.
	payload: [35]u8
	payload[1] = 32
	payload[34] = 1
	for hrp in ([]string{"nevent", "nprofile", "naddr"}) {
		token := bech32_encode(hrp, payload[:])
		defer delete(token)
		_, ref := nostr_at(token, 0)
		testing.expect_value(t, ref.kind, Nostr_Kind.Invalid)
	}
	// Preserve an identifier containing JSON syntax literally.
	_, data, _ := bech32_decode(TEST_NADDR)
	data[2], data[3] = '"', '\\'
	escaped := bech32_encode("naddr", data)
	defer delete(escaped)
	_, ref := nostr_at(escaped, 0)
	value, err = json.parse_string(nev_request(ref.key))
	testing.expect(t, err == nil)
	if err == nil {
		defer json.destroy_value(value)
		filter := value.(json.Array)[2].(json.Object)
		testing.expect_value(t, string(filter["#d"].(json.Array)[0].(json.String)), ref.identifier)
	}
}

// SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=mention_wrap_layout
@(test)
mention_wrap_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mention_wrap_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(800, 600, "Mention wrapping")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer { g_ui = nil; wrap_clear(); delete(sel_lines); sel_lines = nil }
	labels := []string{"Max", "JeffG", "Pepi Testing"}
	n := 0
	for seg in inline_segs(TEST_MENTIONS) {
		if len(seg.hex) == 0 { continue }
		ui.nicknames[seg.hex] = labels[n]
		n += 1
	}
	testing.expect_value(t, n, 3)
	for width in ([]f32{120, 480}) {
		clear(&sel_lines)
		clay.BeginLayout()
		if clay.UI(clay.ID("MentionTest"))({layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(width)}}}) {
			body_text(42, TEST_MENTIONS, BODY_FS, TEXT, true, width)
		}
		commands := clay.EndLayout(0)
		if width == 480 { testing.expect_value(t, len(sel_lines), 1) }
		for line in sel_lines {
			box := clay.GetElementData(clay.ID("BodyLine", line.id)).boundingBox
			testing.expect(t, box.width <= width + 0.1, fmt.tprintf("%.1f > %.1f", box.width, width))
			at := 0
			for seg, k in inline_segs(line.text) {
				if len(seg.hex) > 0 {
					chip := clay.GetElementData(clay.ID("SegMention", line.id * 128 + u32(k))).boundingBox
					testing.expect_value(t, hit_plain(line.text, chip.x + chip.width * 0.25 - box.x, line.size, line.tile_px), at)
					testing.expect_value(t, hit_plain(line.text, chip.x + chip.width * 0.75 - box.x, line.size, line.tile_px), at + len(seg.text))
				}
				at += len(seg.text)
			}
		}
		if width == 480 {
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot("/tmp/wn-mention-wrap.png")
			rl.EndDrawing()
		}
	}
	gh_cards_on = true
	defer { gh_cards_on = false }
	for token in ([]string{TEST_NADDR, TEST_PRIMAL}) {
		text := fmt.tprintf("before %s after", token)
		lines := wrapped_lines(text, 480, BODY_FS, .Cards)
		testing.expect_value(t, len(lines), 3)
		testing.expect_value(t, text[lines[1].start:lines[1].end], token)
	}
}

@(private)
TEST_PRODUCT :: "naddr1qvzqqqrkcgpzqgglxfd4895k3tqv0xmupgps6a5zqmfj43slj0c58hs39wzeh4r0qqdhqun0v36kxazlxymnvwpnxscnvvesxq6rvhmr8ychs7ganuqhd"
@(private)
TEST_PRODUCT_JSON :: `{"kind":30402,"id":"8b3e3ad45de07d0180625e97970f59547db2ef5476c7c64ec60ef01e7aa58cc7","pubkey":"211f325b5396968ac0c79b7c0a030d768206d32ac61f93f143de112b859bd46f","created_at":1768336493,"tags":[["d","product_1768336493906_b3hw1"],["title","RoboCoin"],["price","2.50","GBP"],["type","simple","physical"],["visibility","on-sale"],["stock","100"],["summary",""],["image","https://cdn.nostrcheck.me/70a1827fd83b42c620686990c5cf35b382bce6c9f02fa6cba3f0039585963561.webp","800x600","0"],["t","Bitcoin"]],"content":"These are great gifts and can be loaded with Bitcoin using Lightning (specifically, these have LNUrl addresses loaded onto them). They can be used to pay for goods at merchants that support Bitcoin Lightning payments using NFC.\n\nThese do not come with Sats Preloaded so you can add your own sats and pick any colour of your choice."}`

@(test)
nostr_product_preview :: proc(t: ^testing.T) {
	_, ref := nostr_at(TEST_PRODUCT, 0)
	testing.expect_value(t, ref.kind, Nostr_Kind.Address)
	testing.expect_value(t, ref.event_kind, 30402)
	testing.expect_value(t, ref.author, "211f325b5396968ac0c79b7c0a030d768206d32ac61f93f143de112b859bd46f")
	testing.expect_value(t, ref.identifier, "product_1768341630046_c91xy")
	testing.expect_value(t, nev_parse(transmute([]u8)string(TEST_PRODUCT_JSON), .Event, ref.key).raw, "")
	_, payload, _ := bech32_decode(TEST_PRODUCT)
	start := strings.index(string(payload), ref.identifier)
	copy(payload[start:], transmute([]u8)string("product_1768336493906_b3hw1"))
	matching := bech32_encode("naddr", payload)
	defer delete(matching)
	_, ref = nostr_at(matching, 0)
	card := nev_parse(transmute([]u8)string(TEST_PRODUCT_JSON), .Event, ref.key)
	testing.expect_value(t, card.product.title, "RoboCoin")
	testing.expect_value(t, card.product.price, "2.50 GBP")
	testing.expect_value(t, card.product.availability, "On sale")
	testing.expect_value(t, card.product.stock, "100")
	testing.expect(t, strings.has_suffix(card.product.image, ".webp"))
	for replacement in ([][2]string{{"30402", "30023"}, {"product_1768336493906_b3hw1", "wrong"}, {ref.author, strings.repeat("0", 64, context.temp_allocator)}}) {
		wrong, _ := strings.replace_all(TEST_PRODUCT_JSON, replacement[0], replacement[1], context.temp_allocator)
		testing.expect_value(t, nev_parse(transmute([]u8)wrong, .Event, ref.key).raw, "")
	}
	variant, _ := strings.replace_all(TEST_PRODUCT_JSON, `"on-sale"`, `"pre-order"`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).product.availability, "Pre-order")
	variant, _ = strings.replace_all(TEST_PRODUCT_JSON, `"stock","100"`, `"stock","0"`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).product.availability, "Out of stock")
	variant, _ = strings.replace_all(TEST_PRODUCT_JSON, `["summary",""]`, `["status","sold"]`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).product.availability, "Sold")
	// Malformed optional tags must not break an otherwise usable preview.
	variant, _ = strings.replace_all(TEST_PRODUCT_JSON, `"tags":[`, `"tags":[null,[],["price",3],`, context.temp_allocator)
	testing.expect_value(t, nev_parse(transmute([]u8)variant, .Event).product.title, "RoboCoin")
	by_id := nev_parse(transmute([]u8)string(TEST_PRODUCT_JSON), .Event, "8b3e3ad45de07d0180625e97970f59547db2ef5476c7c64ec60ef01e7aa58cc7")
	testing.expect_value(t, by_id.product.title, "RoboCoin")
}
