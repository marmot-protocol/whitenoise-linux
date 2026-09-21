package main

import "core:strings"
import "core:testing"

@(test)
nevent_at_tokens :: proc(t: ^testing.T) {
	id := "88b2513567e7d0f3a118aa0a4c6c399d3eb86315bb1243c338cf29e38becb105"

	// nevent with one relay hint, nostr:-prefixed, trailing text.
	text := "see nostr:nevent1qqsg3vj3x4n7058n5yv25zjvdsue604cvv2mkyjrcvuv720r30ktzpgpz3mhxue69uhhyetvv9ujuerpd46hxtnfdudrh9q7 now"
	end, hx, hints, ok := nevent_at(text, 4)
	testing.expect(t, ok)
	testing.expect_value(t, hx, id)
	testing.expect_value(t, text[end:], " now")
	testing.expect_value(t, len(hints), 1)
	testing.expect_value(t, hints[0], "wss://relay.damus.io")

	// bare note1 carries no hints.
	end2, hx2, hints2, ok2 := nevent_at(
		"note13ze9zdt8ulg08ggc4g9ycmpen5ltscc4hvfy8seceu578zlvkyzsq77jau",
		0,
	)
	testing.expect(t, ok2)
	testing.expect_value(t, hx2, id)
	testing.expect_value(
		t,
		end2,
		len("note13ze9zdt8ulg08ggc4g9ycmpen5ltscc4hvfy8seceu578zlvkyzsq77jau"),
	)
	testing.expect_value(t, len(hints2), 0)

	// npub is a mention, not an event; garbage is nothing.
	_, _, _, ok3 := nevent_at("npub1xyz", 0)
	testing.expect(t, !ok3)
	_, _, _, ok4 := nevent_at("nevent1qqqq", 0)
	testing.expect(t, !ok4)
}

@(test)
nev_parse_shapes :: proc(t: ^testing.T) {
	msg := transmute([]u8)string(
		`["EVENT","wn",{"content":"hi","created_at":1788349644,"id":"ab","kind":1,"pubkey":"6b8f","sig":"00","tags":[]}]`,
	)
	card := nev_parse(msg, .Message)
	testing.expect(t, card.done)
	testing.expect_value(t, card.kind, 1)
	testing.expect_value(t, card.pubkey, "6b8f")
	testing.expect_value(t, card.content, "hi")
	testing.expect_value(t, card.created, 1788349644)
	testing.expect(t, len(card.raw) > 0)

	// The disk cache holds the bare object, and round-trips.
	again := nev_parse(transmute([]u8)card.raw, .Event)
	testing.expect_value(t, again.kind, 1)
	testing.expect_value(t, again.content, "hi")

	// EOSE-shaped or broken input leaves raw empty (a miss).
	miss := nev_parse(transmute([]u8)string(`["EOSE","wn"]`), .Message)
	testing.expect_value(t, miss.raw, "")
	bad := nev_parse(transmute([]u8)string("nope"), .Event)
	testing.expect_value(t, bad.raw, "")
}

@(test)
nevent_inline_seg :: proc(t: ^testing.T) {
	segs := inline_segs(
		"look at this nevent1qqsg3vj3x4n7058n5yv25zjvdsue604cvv2mkyjrcvuv720r30ktzpgpz3mhxue69uhhyetvv9ujuerpd46hxtnfdudrh9q7 and more",
	)
	testing.expect_value(t, len(segs), 3)
	testing.expect_value(
		t,
		segs[1].evid,
		"88b2513567e7d0f3a118aa0a4c6c399d3eb86315bb1243c338cf29e38becb105",
	)
	testing.expect_value(t, segs[2].text, " and more")
}

@(test)
nevent_bare_note_in_text :: proc(t: ^testing.T) {
	segs := inline_segs(
		"just a note: note1evtv9rerzqa6g6wt2pjuw9vhkkza2zq2p9qfn6aa4kdkrmumdpssy3nw7z",
	)
	testing.expect_value(t, len(segs), 2)
	testing.expect_value(
		t,
		segs[1].evid,
		"cb16c28f23103ba469cb5065c71597b585d5080a094099ebbdad9b61ef9b6861",
	)
}

@(test)
nev_image_urls_scan :: proc(t: ^testing.T) {
	urls := nev_image_urls(
		"pic https://x.io/a.JPG?w=1 and https://x.io/doc.pdf then https://y.io/b.webp.",
	)
	testing.expect_value(t, len(urls), 2)
	testing.expect_value(t, urls[0], "https://x.io/a.JPG?w=1")
	testing.expect_value(t, urls[1], "https://y.io/b.webp")
}

@(test)
nev_split_images_blocks :: proc(t: ^testing.T) {
	blocks := make([dynamic]Md_Block_Ui)
	append(&blocks, Md_Block_Ui{kind = .Para, text = strings.clone("look https://x.io/a.png wow")})
	append(&blocks, Md_Block_Ui{kind = .Code, text = strings.clone("https://x.io/b.png")})
	nev_split_images(&blocks)
	testing.expect_value(t, len(blocks), 4)
	testing.expect_value(t, blocks[0].text, "look")
	testing.expect_value(t, blocks[1].kind, Md_Kind.Image)
	testing.expect_value(t, blocks[1].text, "https://x.io/a.png")
	testing.expect_value(t, blocks[2].text, "wow")
	testing.expect_value(t, blocks[3].kind, Md_Kind.Code)
}
