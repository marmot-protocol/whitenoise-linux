// Nostr event references (nevent1 / note1, bare or "nostr:"-prefixed)
// drawn as a card under the body instead of a bare token.
//
// The event is pulled by id from the user's fetch relays (Settings →
// Network, ditto + primal by default) plus any relay hints the nevent
// carries, on its own thread, and cached twice: in memory for the
// session and as <home>/events/<id>.json across runs. Kind 1 (and the
// kind-11/1111 reply shapes) render as author + text; any other kind
// shows the raw event JSON. A note's text goes through marmot's
// markdown parser like a chat body, and image links in it are fetched
// into <home>/events/img/ and drawn inline where they were written. Every card offers one
// "Open in client" button, the web client set in Settings → Network.
//
//   body token ──inline_segs──▶ Inline_Seg.evid ──render_segs──▶ nev_card
//                                                    │ miss
//                                              nev_worker ──▶ ws_shim.c
//
// ponytail: relays are tried one after another with a 6s ceiling
// each, and the returned event's id is trusted, not re-hashed. Race
// the relays and verify the id when the first lying relay shows up.
package main

import "base:runtime"
import "core:testing"
import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"

import marmot "../marmot"
import rl "sdlrl"

foreign import wslib {
	"../build/libwnws.a",
	"system:curl",
}

@(default_calling_convention = "c")
foreign wslib {
	wn_ws_fetch :: proc(url: cstring, req: cstring, out: [^]u8, cap: c.size_t, timeout_ms: c.long) -> c.int ---
}

DEFAULT_FETCH_RELAYS := []string{"wss://relay.ditto.pub", "wss://relay.primal.net"}
DEFAULT_EVENT_CLIENT :: "https://ditto.pub/{id}"

NEV_IMAGE_EXTS := []string{".jpg", ".jpeg", ".png", ".gif", ".webp"}

// One relay's answer must fit here; bigger events show as a miss.
NEV_MAX :: 256 * 1024
NEV_TIMEOUT_MS :: 6000

// Kinds drawn as author + text. Everything else is raw JSON.
NEV_TEXT_KINDS := []i64{1, 11, 1111, 30023}

Nev_Card :: struct {
	product: Nev_Product,
	geocache: Nev_Geocache,
	done:    bool, // fetch finished; raw == "" then means not found
	kind:    i64,
	pubkey:  string,
	content: string,
	created: i64,
	stamp:   string, // created formatted for the header, set on drain
	raw:     string, // pretty-printed event JSON
	blocks:  [dynamic]Md_Block_Ui, // content as markdown blocks, built on drain
}

// event id hex → card. An entry appears the frame the token is first
// laid out and is overwritten when its worker lands, so presence also
// means "already requested".
nev_cards: map[string]Nev_Card

@(private = "file")
nev_mutex: sync.Mutex
@(private = "file")
nev_fresh: [dynamic]struct {
	id:   string, // owned, moves into nev_cards
	card: Nev_Card,
}

// image url → texture; nil while pending or after a miss. Presence
// means requested, like nev_cards.
@(private = "file")
nev_images: map[string]^rl.Texture2D
@(private = "file")
nev_img_fresh: [dynamic]struct {
	url:  string, // owned, moves into nev_images
	data: []u8, // owned, nil = miss
}

// Cards nest (a note quoting a note); a card inside a card draws its
// tokens as text so a self-quote cannot recurse.
@(private = "file")
nev_depth: int

@(private = "file")
Nev_Job :: struct {
	id:     string, // owned
	author: string, // owned, for NIP-65 discovery after a miss
	relays: []string, // owned, hints first then the prefs list
}

// ── token parsing ───────────────────────────────────────────────────

// Parse an event reference at text[i:]: optional "nostr:", then
// note1/nevent1 plus its bech32 run. end is the byte past the token,
// id the 32-byte event id as hex, relays the nevent's relay hints (both
// temp-allocated).
nevent_at :: proc(text: string, i: int) -> (end: int, id: string, relays: []string, ok: bool) {
	ref: Nostr_Ref
	end, ref = nostr_at(text, i)
	if ref.kind != .Event && ref.kind != .Address { return 0, "", nil, false }
	return end, ref.key, ref.relays, true
}

// ── fetch ───────────────────────────────────────────────────────────

@(private = "file")
nev_cache_path :: proc(id: string) -> string {
	key := id
	if strings.has_prefix(id, "naddr1") { key = string(hex.encode(hash.hash_string(.SHA256, id, context.temp_allocator), context.temp_allocator)) }
	return fmt.tprintf("%s/events/%s.json", data_home, key)
}

@(private = "file")
nev_worker :: proc(job: ^Nev_Job) {
	context.allocator = reload_allocator()
	defer frame_wake()
	defer {
		for r in job.relays {
			delete(r)
		}
		delete(job.relays)
		delete(job.author)
		free(job)
	}

	card: Nev_Card
	card.done = true
	if data, err := os.read_entire_file(nev_cache_path(job.id), context.allocator); err == nil {
		card = nev_parse(data, .Event, job.id)
		delete(data)
	}
	// Addresses can be replaced. Refresh once per session; retain disk data offline.
	if len(card.raw) == 0 || strings.has_prefix(job.id, "naddr1") {
		req := nev_request(job.id)
		req_c := strings.clone_to_cstring(req)
		defer delete(req_c)
		buf := make([]u8, NEV_MAX)
		defer delete(buf)
		relays := job.relays
		found := false
		seen := make(map[string]bool, context.temp_allocator)
		for pass in 0 ..< 2 {
			if pass == 1 {
				if len(job.author) == 0 { break }
				relays = nil
				discover := fmt.ctprintf(`["REQ","wn",{{"authors":["%s"],"kinds":[10002],"limit":1}}]`, job.author)
				for relay in job.relays {
					n := wn_ws_fetch(strings.clone_to_cstring(relay, context.temp_allocator), discover, raw_data(buf), NEV_MAX, NEV_TIMEOUT_MS)
					if n <= 0 { continue }
					relays = nev_relay_urls(buf[:n], job.author)
					if len(relays) > 0 { break }
				}
			}
			for relay in relays {
				if seen[relay] { continue }
				seen[relay] = true
				relay_c := strings.clone_to_cstring(relay)
				n := wn_ws_fetch(relay_c, req_c, raw_data(buf), NEV_MAX, NEV_TIMEOUT_MS)
				delete(relay_c)
				if n <= 0 {
					continue
				}
				fresh := nev_parse(buf[:n], .Message, job.id)
				if len(fresh.raw) == 0 {
					continue
				}
				delete(card.raw); delete(card.content); delete(card.pubkey)
				for value in ([]string{card.product.title, card.product.summary, card.product.image, card.product.price, card.product.availability, card.product.stock, card.product.location}) { delete(value) }
				for value in ([]string{card.geocache.name, card.geocache.image, card.geocache.hint, card.geocache.size, card.geocache.mission, card.geocache.geohash}) { delete(value) }
				card = fresh
				found = true
				os.make_directory(fmt.tprintf("%s/events", data_home))
				_ = os.write_entire_file(nev_cache_path(job.id), transmute([]u8)card.raw)
				break
			}
			if found { break }
		}
	}

	sync.lock(&nev_mutex)
	append(&nev_fresh, struct {
		id:   string,
		card: Nev_Card,
	}{job.id, card})
	sync.unlock(&nev_mutex)
}

// http(s) links in text whose path ends in an image extension. The
// slices point into text.
nev_image_urls :: proc(text: string) -> []string {
	out := make([dynamic]string)
	for i := 0; i + 8 <= len(text); i += 1 {
		if text[i] != 'h' {
			continue
		}
		end, url, ok := url_at(text, i)
		if !ok {
			continue
		}
		i = end - 1
		path := url
		if cut := strings.index_any(path, "?#"); cut >= 0 {
			path = path[:cut]
		}
		for ext in NEV_IMAGE_EXTS {
			if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ext) {
				append(&out, url)
				break
			}
		}
	}
	return out[:]
}

// Paragraphs holding image links split around them into text /
// Image / text blocks, so the picture sits where the link was.
nev_split_images :: proc(blocks: ^[dynamic]Md_Block_Ui) {
	out := make([dynamic]Md_Block_Ui)
	for block in blocks {
		urls := block.kind == .Para ? nev_image_urls(block.text) : nil
		defer delete(urls)
		if len(urls) == 0 {
			append(&out, block)
			continue
		}
		first := len(out)
		at := 0
		for url in urls {
			start := strings.index(block.text[at:], url) + at
			before := strings.trim_space(block.text[at:start])
			if len(before) > 0 {
				lo := start - len(strings.trim_left_space(block.text[at:start]))
				append(&out, Md_Block_Ui{kind = .Para, text = strings.clone(before), fonts = strings.clone(text_fonts(block.fonts, lo, lo + len(before)))})
			}
			append(&out, Md_Block_Ui{kind = .Image, text = strings.clone(url)})
			at = start + len(url)
		}
		after := strings.trim_space(block.text[at:])
		if len(after) > 0 {
			lo := len(block.text) - len(strings.trim_left_space(block.text[at:]))
			append(&out, Md_Block_Ui{kind = .Para, text = strings.clone(after), fonts = strings.clone(text_fonts(block.fonts, lo, lo + len(after)))})
		}
		out[first].blank_lines_before = block.blank_lines_before
		delete(block.text)
		delete(block.fonts)
	}
	delete(blocks^)
	blocks^ = out
}

// ── images ──────────────────────────────────────────────────────────

@(private = "file")
nev_img_path :: proc(url: string) -> string {
	sum := hash.hash_string(.SHA256, url, context.temp_allocator)
	return fmt.tprintf("%s/events/img/%s", data_home, hex.encode(sum, context.temp_allocator))
}

// curl the image to its cache file (skipped when present), then hand
// the bytes to drain_nev for the texture upload.
@(private = "file")
nev_img_worker :: proc(url: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	path := nev_img_path(url)
	if !os.exists(path) {
		os.make_directory(fmt.tprintf("%s/events", data_home))
		os.make_directory(fmt.tprintf("%s/events/img", data_home))
		state, _, _, err := os.process_exec({command = {"curl", "-sfL", "--proto", "=http,https", "--proto-redir", "=http,https", "--user-agent", "WhiteNoiseLinux/1.0 (Nostr event previews)", "--max-time", "20", "--max-filesize", "16777216", "-o", path, "--", url}}, context.temp_allocator)
		if err != nil || state.exit_code != 0 {
			os.remove(path)
		}
	}
	data, _ := os.read_entire_file(path, context.allocator)
	sync.lock(&nev_mutex)
	append(&nev_img_fresh, struct {
		url:  string,
		data: []u8,
	}{url, data})
	sync.unlock(&nev_mutex)
}

// The texture for an image link, requesting it on first sight.
nev_img :: proc(url: string) -> ^rl.Texture2D {
	if tex, seen := nev_images[url]; seen {
		return tex
	}
	owned := strings.clone(url)
	nev_images[owned] = nil
	append(&send_threads, thread.create_and_start_with_poly_data(owned, nev_img_worker))
	return nil
}

// What nev_parse is handed: a relay's ["EVENT",sub,{…}] message or
// the bare event object from the disk cache.
Nev_Shape :: enum {
	Message,
	Event,
}

// Fields the card reads plus the pretty JSON it shows. raw stays ""
// when the bytes are not an event.
nev_parse :: proc(body: []u8, shape: Nev_Shape, key: string = "") -> (card: Nev_Card) {
	card.done = true
	val, perr := json.parse(body)
	if perr != nil {
		return
	}
	defer json.destroy_value(val)

	ev_val := val
	if shape == .Message {
		arr, is_arr := val.(json.Array)
		if !is_arr || len(arr) != 3 {
			return
		}
		message, _ := arr[0].(json.String)
		subscription, _ := arr[1].(json.String)
		if message != "EVENT" || subscription != "wn" { return }
		ev_val = arr[2]
	}
	ev, is_obj := ev_val.(json.Object)
	if !is_obj {
		return
	}
	kind, has_kind := ev["kind"].(json.Float)
	pubkey, has_pk := ev["pubkey"].(json.String)
	if !has_kind || !has_pk {
		return
	}
	if len(key) > 0 {
		_, ref := nostr_at(key, 0)
		if ref.kind == .Address {
			if kind != json.Float(ref.event_kind) || pubkey != json.String(ref.author) { return }
			if ref.event_kind >= 30000 {
				matched := false
				if tags, ok := ev["tags"].(json.Array); ok {
					for tag in tags {
						if values, ok := tag.(json.Array); ok && len(values) >= 2 {
							name, _ := values[0].(json.String)
							if name != "d" { continue }
							identifier, ok := values[1].(json.String)
							matched = ok && identifier == json.String(ref.identifier)
							break
						}
					}
				}
				if !matched { return }
			}
		} else {
			id, _ := ev["id"].(json.String)
			if id != json.String(key) { return }
		}
	}
	card.kind = i64(kind)
	card.pubkey = strings.clone(pubkey)
	if card.kind == NEV_PRODUCT_KIND { card.product = nev_product_parse(ev) }
	if card.kind == NEV_GEOCACHE_KIND { card.geocache = nev_geocache_parse(ev) }
	if content, ok := ev["content"].(json.String); ok {
		card.content = strings.clone(content)
	}
	if created, ok := ev["created_at"].(json.Float); ok {
		card.created = i64(created)
	}
	pretty, merr := json.marshal(ev_val, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil {
		card.raw = strings.clone(string(body))
		return
	}
	// ponytail: marshal prints every json.Float with a fractional
	// tail, so integer fields (kind, created_at) come out as
	// 1788350645.0000000000000000; a real fraction is left alone.
	raw, _ := strings.replace_all(string(pretty), ".0000000000000000", "")
	delete(pretty)
	card.raw = raw
	return
}

// Mono text as lines that fit `width`: clay wraps on spaces only, and
// a 64-hex id or a long URL has none, so each line is chopped every
// `cols` runes. The mono face makes a rune count a width. Used by the
// event card's JSON and the link guard's URL.
mono_lines :: proc(text: string, width: f32, color: clay.Color) {
	rest_text := text
	col_w := rl.MeasureTextLine(FONT_MONO, 11, "0", 0).x
	cols := max(int(width / max(col_w, 1)), 8)
	for line in strings.split_lines_iterator(&rest_text) {
		rest := line
		for len(rest) > 0 {
			cut := len(rest)
			if utf8.rune_count_in_string(rest) > cols {
				cut = 0
				for _ in 0 ..< cols {
					_, w := utf8.decode_rune_in_string(rest[cut:])
					cut += w
				}
			}
			clay.Text(rest[:cut], {fontId = FONT_MONO, fontSize = 11, textColor = color})
			rest = rest[cut:]
		}
	}
}

// Frame-loop drain: publish finished fetches to the render side.
drain_nev :: proc() {
	sync.lock(&nev_mutex)
	defer sync.unlock(&nev_mutex)
	for f in nev_fresh {
		card := f.card
		if card.created > 0 {
			card.stamp = format_full(u64(card.created))
		}
		if card.kind != 0 && card.kind != 16767 && len(card.content) > 0 && g_client != nil {
			doc: ^marmot.Markdown_Document
			if marmot.parse_markdown(g_client, strings.clone_to_cstring(card.content, context.temp_allocator), &doc) == .OK {
				convert_blocks(&card.blocks, doc.blocks, doc.blocks_len, false, ([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len])
				marmot.markdown_document_free(doc)
				nev_split_images(&card.blocks)
			}
		}
		nev_cards[f.id] = card
	}
	clear(&nev_fresh)
	for f in nev_img_fresh {
		if f.data == nil {
			continue
		}
		image := rl.LoadImageFromMemory(".img", raw_data(f.data), i32(len(f.data)))
		delete(f.data)
		if image.data == nil {
			continue
		}
		tex := new(rl.Texture2D)
		tex^ = rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
		nev_images[f.url] = tex
	}
	clear(&nev_img_fresh)
}

// ── card ────────────────────────────────────────────────────────────

// Shared cache and relay discovery for cards and profile presentation.
@(private)
nev_lookup :: proc(evid: string, token: string, hints: []string = nil) -> Nev_Card {
	card, cached := nev_cards[evid]
	if !cached {
		owned := strings.clone(evid)
		nev_cards[owned] = Nev_Card{}
		relays := make([dynamic]string)
		for h in hints {
			append(&relays, strings.clone(h))
		}
		if g_ui != nil {
			for r in g_ui.prefs.fetch_relays {
				append(&relays, strings.clone(r))
			}
		}
		job := new(Nev_Job)
		job.id = owned
		_, ref := nostr_at(token, 0)
		job.author = strings.clone(ref.author)
		job.relays = relays[:]
		append(&send_threads, thread.create_and_start_with_poly_data(job, nev_worker))
	}
	return card
}

// The card itself, drawn where the token was written. token is the
// bech32 as written (minus any nostr: prefix), what the button opens.
nev_card :: proc(id: u32, evid: string, token: string, hints: []string) {
	if nev_depth > 0 {
		clay.Text(token, {fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_DIM})
		return
	}
	card := nev_lookup(evid, token, hints)
	nev_depth += 1
	defer { nev_depth -= 1 }

	textual := false
	for k in NEV_TEXT_KINDS {
		if card.kind == k {
			textual = true
		}
	}
	inner_w := att_w() - 24

	if clay.UI(clay.ID("NevCard", id))(
	{
		layout = {sizing = {width = clay.SizingFixed(att_w())}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(12), childGap = 6},
		backgroundColor = PLATE,
		cornerRadius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("NevCardHead", id))({layout = {sizing = {width = clay.SizingFixed(inner_w)}, childGap = 8, childAlignment = {y = .Center}}}) {
			clay.Text(ICON_GLOBE, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_LO})
			switch {
			case len(card.raw) == 0:
				eyebrow("NOSTR EVENT")
			case card.kind == NEV_PRODUCT_KIND:
				eyebrow("PRODUCT")
			case card.kind == NEV_GEOCACHE_KIND:
				eyebrow("GEOCACHE")
			case textual:
				eyebrow("NOTE")
			case:
				clay.Text(fmt.tprintf("KIND %d", card.kind), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
			if len(card.pubkey) > 0 && card.kind != NEV_PRODUCT_KIND && card.kind != NEV_GEOCACHE_KIND {
				clay.Text(fmt.tprintf("%s · %s", mention_label(card.pubkey), card.stamp), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
			}
		}

		switch {
		case !card.done:
			clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		case len(card.raw) == 0:
			clay.Text(tr("Couldn't load this event. Check your relay settings and try again."), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
			if clay.UI(clay.ID("NevRetry", id))({layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}}) {
				if hovered() { nev_retry_hover = evid }
				clay.Text(tr("Retry"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
			}
		case card.kind == NEV_PRODUCT_KIND:
			if len(card.pubkey) > 0 { body_text(0x30000000 + id, mention_label(card.pubkey), 11, TEXT_LO, wrap_w = inner_w, max_lines = 1) }
			nev_product_card(id, evid, card, inner_w)
		case card.kind == NEV_GEOCACHE_KIND:
			nev_geocache_card(id, evid, card, inner_w)
		case textual:
			nev_card_excerpt(id, evid, card, inner_w)
		case:
			nev_card_excerpt(id, evid, card, inner_w, card.raw)
		}

		// Hovering binds link_hover, so a click goes through the same
		// external-link guard as a text link.
		if g_ui != nil && strings.contains(g_ui.prefs.event_client, "{id}") {
			_, ref := nostr_at(token, 0)
			url, _ := strings.replace_all(g_ui.prefs.event_client, "{id}", ref.token, context.temp_allocator)
			if clay.UI(clay.ID("NevOpen", id))(
			{layout = {padding = {left = 10, right = 10, top = 5, bottom = 5}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7), border = {color = FIELD_BORDER, width = bw()}},
			) {
				if hovered() {
					link_hover = url
				}
				clay.Text(tr("Open in client"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
		}
	}
}

@(private)
NEV_PRODUCT_KIND :: 30402

@(private)
Nev_Product :: struct {
	title, summary, image, price, availability, stock, location: string,
}

@(private)
nev_more_hover: string
@(private)
nev_retry_hover: string
@(private)
nev_hint_hover: string

// Read preview metadata once, while the event JSON is already parsed.
@(private)
nev_product_parse :: proc(ev: json.Object) -> (product: Nev_Product) {
	tags, _ := ev["tags"].(json.Array)
	status, visibility := "", ""
	image_order := max(i64)
	for tag, index in tags {
		values, ok := tag.(json.Array)
		if !ok || len(values) < 2 { continue }
		name, _ := values[0].(json.String)
		value, is_string := values[1].(json.String)
		if !is_string { continue }
		text := string(value)
		switch name {
		case "title": product.title = text
		case "summary": product.summary = text
		case "location": product.location = text
		case "status": status = text
		case "visibility": visibility = text
		case "stock":
			if _, valid := strconv.parse_u64(text); valid { product.stock = text }
		case "image":
			end, _, valid := url_at(text, 0)
			if !valid || end != len(text) { continue }
			order := i64(index)
			if len(values) > 3 {
				if raw, ok := values[3].(json.String); ok {
					if n, valid := strconv.parse_i64(string(raw)); valid { order = n }
				}
			}
			if order < image_order { product.image, image_order = text, order }
		case "price":
			if len(values) < 3 { continue }
			currency, ok := values[2].(json.String)
			if !ok || len(text) == 0 || len(currency) == 0 { continue }
			product.price = fmt.tprintf("%s %s", text, currency)
			if len(values) > 3 {
				if frequency, ok := values[3].(json.String); ok && len(frequency) > 0 {
					product.price = fmt.tprintf("%s / %s", product.price, frequency)
				}
			}
		}
	}
	switch {
	case visibility == "hidden": product.availability = N_("Hidden")
	case status == "sold": product.availability = N_("Sold")
	case product.stock == "0": product.availability = N_("Out of stock")
	case visibility == "pre-order": product.availability = N_("Pre-order")
	case visibility == "on-sale" || status == "active": product.availability = N_("On sale")
	}
	for field in ([]^string{&product.title, &product.summary, &product.image, &product.price, &product.availability, &product.stock, &product.location}) {
		field^ = strings.clone(field^)
	}
	return
}

@(private)
nev_product_card :: proc(id: u32, key: string, card: Nev_Card, width: f32) {
	p := card.product
	nev_card_image(id, p.image, width)
	base := 0x20000000 + id * 64
	if len(p.title) > 0 {
		fonts := make([]u8, len(p.title), context.temp_allocator)
		for &font in fonts { font = u8(FONT_TITLE) }
		body_text(base, p.title, 17, TEXT, wrap_w = width, max_lines = 2, fonts = string(fonts))
	}
	if len(p.price) > 0 { body_text(base + 1, p.price, 16, ACCENT, wrap_w = width, max_lines = 2) }
	if len(p.availability) > 0 { body_text(base + 2, tr(p.availability), 12, TEXT_DIM, wrap_w = width) }
	if len(p.stock) > 0 { body_text(base + 3, fmt.tprintf(tr("Stock: %s"), p.stock), 12, TEXT_LO, wrap_w = width) }
	if len(p.location) > 0 { body_text(base + 4, p.location, 12, TEXT_LO, wrap_w = width, max_lines = 2) }
	nev_card_excerpt(id, key, card, width, p.summary)
}

@(private = "file")
nev_card_image :: proc(id: u32, url: string, width: f32) {
	if len(url) == 0 { return }
	if tex := nev_img(url); tex != nil && tex.width > 0 && tex.height > 0 {
		scale := min(width / f32(tex.width), 200 / f32(tex.height))
		if clay.UI(clay.ID("NevImage", id))({layout = {sizing = {width = clay.SizingFixed(f32(tex.width) * scale), height = clay.SizingFixed(f32(tex.height) * scale)}}, image = {imageData = tex}, cornerRadius = rr(6)}) {}
	}
}

@(private = "file")
nev_card_excerpt :: proc(id: u32, key: string, card: Nev_Card, width: f32, summary: string = "") {
	description := len(summary) > 0 ? summary : card.content
	base := 0x20000000 + id * 64
	more := false
	if len(summary) == 0 && len(card.blocks) > 0 {
		more = md_blocks(card.blocks[:], base + 5, false, width, MESSAGE_LINES)
	} else {
		more = body_text(base + 5, description, BODY_FS, TEXT_DIM, wrap_w = width, max_lines = MESSAGE_LINES) > MESSAGE_LINES
	}
	if more || len(summary) > 0 && summary != card.content || len(card.geocache.mission) > 0 {
		if clay.UI(clay.ID("NevMore", id))({layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}}) {
			if hovered() { nev_more_hover = key }
			clay.Text(tr("Read more"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
		}
	}
}

@(private)
NEV_GEOCACHE_KIND :: 37516

@(private)
Nev_Geocache :: struct {
	name, image, hint, size, mission, geohash: string,
	difficulty, terrain: int,
	lat, lon: f64,
}

// Geohash alternates longitude and latitude bisections, most significant bit first.
@(private)
geohash_coords :: proc(value: string) -> (lat, lon: f64, valid: bool) {
	if len(value) < 3 || len(value) > 9 { return }
	lo, hi := [2]f64{-180, -90}, [2]f64{180, 90}
	axis := 0
	for c in value {
		n := strings.index_rune("0123456789bcdefghjkmnpqrstuvwxyz", c)
		if n < 0 { return }
		for bit := 4; bit >= 0; bit -= 1 {
			mid := (lo[axis] + hi[axis]) / 2
			if n & (1 << uint(bit)) != 0 { lo[axis] = mid } else { hi[axis] = mid }
			axis = 1 - axis
		}
	}
	return (lo[1] + hi[1]) / 2, (lo[0] + hi[0]) / 2, true
}

@(private)
nev_geocache_parse :: proc(ev: json.Object) -> (cache: Nev_Geocache) {
	tags, _ := ev["tags"].(json.Array)
	for tag in tags {
		values, ok := tag.(json.Array)
		if !ok || len(values) < 2 { continue }
		name, _ := values[0].(json.String)
		value, is_string := values[1].(json.String)
		if !is_string { continue }
		text := string(value)
		switch name {
		case "name": if len(cache.name) == 0 { cache.name = text }
		case "hint": if len(cache.hint) == 0 { cache.hint = text }
		case "mission": if len(cache.mission) == 0 { cache.mission = text }
		case "S":
			switch text {
			case "micro": cache.size = N_("Micro")
			case "small": cache.size = N_("Small")
			case "regular": cache.size = N_("Regular")
			case "large": cache.size = N_("Large")
			case "other": cache.size = N_("Other")
			}
		case "D", "T":
			n, valid := strconv.parse_int(text)
			if !valid || n < 1 || n > 5 { continue }
			if name == "D" { cache.difficulty = n } else { cache.terrain = n }
		case "image":
			end, _, valid := url_at(text, 0)
			if valid && end == len(text) && len(cache.image) == 0 { cache.image = text }
		case "g":
			lat, lon, valid := geohash_coords(text)
			if valid && len(text) > len(cache.geohash) { cache.geohash, cache.lat, cache.lon = text, lat, lon }
		}
	}
	for field in ([]^string{&cache.name, &cache.image, &cache.hint, &cache.size, &cache.mission, &cache.geohash}) { field^ = strings.clone(field^) }
	return
}

@(private = "file")
nev_geocache_card :: proc(id: u32, key: string, card: Nev_Card, width: f32) {
	c := card.geocache
	base := 0x28000000 + id * 64
	fonts := make([]u8, len(c.name), context.temp_allocator)
	for &font in fonts { font = u8(FONT_TITLE) }
	body_text(base, c.name, 17, TEXT, wrap_w = width, max_lines = 2, fonts = string(fonts))
	nev_card_image(id, c.image, width)
	if c.difficulty > 0 { body_text(base + 1, fmt.tprintf(tr("Difficulty: %d/5"), c.difficulty), 12, TEXT_DIM, wrap_w = width) }
	if c.terrain > 0 { body_text(base + 2, fmt.tprintf(tr("Terrain: %d/5"), c.terrain), 12, TEXT_DIM, wrap_w = width) }
	if len(c.size) > 0 { body_text(base + 3, fmt.tprintf(tr("Size: %s"), tr(c.size)), 12, TEXT_DIM, wrap_w = width) }
	nev_card_excerpt(id, key, card, width)
	if len(c.mission) > 0 { body_text(base + 4, c.mission, BODY_FS, TEXT_DIM, wrap_w = width, max_lines = 3) }
	if len(c.hint) > 0 {
		if clay.UI(clay.ID("NevHint", id))({layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}}) {
			if hovered() { nev_hint_hover = key }
			clay.Text(tr("Show hint"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
		}
	}
	if len(c.geohash) == 0 { return }
	map_url := fmt.tprintf("https://www.openstreetmap.org/?mlat=%.6f&mlon=%.6f#map=16/%.6f/%.6f", c.lat, c.lon, c.lat, c.lon)
	zoom := min(15, len(c.geohash) * 2 + 2)
	tiles := f64(u32(1) << uint(zoom))
	x := (c.lon + 180) / 360 * tiles
	lat := clamp(c.lat, -85.05112878, 85.05112878) * math.PI / 180
	y := clamp((1 - math.ln(math.tan(lat) + 1 / math.cos(lat)) / math.PI) / 2 * tiles, 0, tiles - 0.000001)
	tile_url := fmt.tprintf("https://tile.openstreetmap.org/%d/%d/%d.png", zoom, int(x), int(y))
	size := min(width, 256)
	pin_size := f32(14)
	tex: ^rl.Texture2D
	box := clay.GetElementData(clay.ID("NevMap", id))
	// Only request the visible tile. The shared disk cache retains it across runs.
	if box.found && box.boundingBox.y + box.boundingBox.height > 0 && box.boundingBox.y < f32(rl.GetScreenHeight()) / UI_ZOOM { tex = nev_img(tile_url) }
	if clay.UI(clay.ID("NevMap", id))({layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}, padding = {left = u16(clamp(f32(x - math.floor(x)) * size - pin_size / 2, 0, size - pin_size)), top = u16(clamp(f32(y - math.floor(y)) * size - pin_size / 2, 0, size - pin_size))}}, image = {imageData = tex}}) {
		if hovered() { link_hover = map_url }
		if clay.UI(clay.ID("NevMapPin", id))({layout = {sizing = {width = clay.SizingFixed(pin_size), height = clay.SizingFixed(pin_size)}}, backgroundColor = ACCENT, cornerRadius = clay.CornerRadiusAll(pin_size / 2), border = {color = BG, width = {left = 2, right = 2, top = 2, bottom = 2}}}) {}
	}
	if clay.UI(clay.ID("NevMapCredit", id))({layout = {sizing = {width = clay.SizingFixed(width)}}}) {
		if hovered() { link_hover = "https://www.openstreetmap.org/copyright" }
		body_text(base + 6, "© OpenStreetMap contributors", 10, TEXT_DIM, wrap_w = width)
	}
	if clay.UI(clay.ID("NevMapOpen", id))({layout = {sizing = {width = clay.SizingFixed(width)}, padding = {top = 4, bottom = 4}}}) {
		if hovered() { link_hover = map_url }
		clay.Text(tr("Open in OpenStreetMap"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
	}
}

// Place /tmp/wn-robocoin.webp before running to include the real product photo.
// SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=product_card_layout
@(test)
product_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "product_card_layout" { return }
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
	defer { g_ui = nil; wrap_clear(); preview_close() }
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
		if clay.UI(clay.ID("ProductTest"))({layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(width + 24)}, padding = clay.PaddingAll(12), childGap = 6}, backgroundColor = PLATE}) {
			nev_product_card(100, TEST_PRODUCT, card, width)
		}
		commands := clay.EndLayout(0)
		box := clay.GetElementData(clay.ID("ProductTest")).boundingBox
		testing.expect(t, box.width <= width + 24.1)
		testing.expect(t, box.height < 520) // Image, metadata, and a six-line excerpt.
		testing.expect(t, clay.GetElementData(clay.ID("NevMore", 100)).found)
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Text {
				testing.expect(t, command.boundingBox.x + command.boundingBox.width <= width + 24.1)
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
	if #config(ODIN_TEST_NAMES, "") != "nostr_live_lookup" { return }
	context.allocator = reload_allocator()
	path, err := os.make_directory_temp("/tmp", "wn-nostr-live-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil { return }
	old_home := data_home
	data_home = path
	defer { data_home = old_home; delete(path) }
	for token in ([]string{TEST_PRODUCT,
		TEST_GEOCACHE,
		"naddr1qvzqqqrcvypzppscgyy746fhmrt0nq955z6xmf80pkvrat0yq0hpknqtd00z8z68qqgkwet0vdskx6rfdenj6etkv4h8guc6gs5y5"}) {
		_, ref := nostr_at(token, 0)
		testing.expect_value(t, ref.kind, Nostr_Kind.Address)
		job := new(Nev_Job)
		job.id, job.author = strings.clone(ref.key), strings.clone(ref.author)
		job.relays = make([]string, len(DEFAULT_FETCH_RELAYS))
		for relay, i in DEFAULT_FETCH_RELAYS { job.relays[i] = strings.clone(relay) }
		nev_worker(job)
		card := nev_fresh[len(nev_fresh) - 1].card
		testing.expect(t, len(card.raw) > 0, fmt.tprintf("kind %d from %s", ref.event_kind, ref.author))
		testing.expect_value(t, card.kind, i64(ref.event_kind))
		if token == TEST_PRODUCT { testing.expect_value(t, card.product.title, "Lightning Piggy") }
		_ = os.write_entire_file(fmt.tprintf("/tmp/wn-live-%d.json", ref.event_kind), transmute([]u8)card.raw)
	}
}

// Optional real assets: /tmp/wn-geocache.jpg and /tmp/wn-osm.png.
@(test)
geocache_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "geocache_card_layout" { return }
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
	defer { g_ui = nil; wrap_clear(); preview_close() }
	card := nev_parse(transmute([]u8)string(TEST_GEOCACHE_JSON), .Event, TEST_GEOCACHE)
	textures: [2]rl.Texture2D
	for path, i in ([]string{"/tmp/wn-geocache.jpg", "/tmp/wn-osm.png"}) {
		image := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
		textures[i] = rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
	}
	defer { for texture in textures { rl.UnloadTexture(texture) } }
	nev_images[card.geocache.image] = &textures[0]
	nev_images["https://tile.openstreetmap.org/15/29106/12901.png"] = &textures[1]
	for width in ([]f32{200, 360}) {
		for _ in 0 ..< 2 {
			clay.BeginLayout()
			if clay.UI(clay.ID("GeocacheTest"))({layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(width + 24)}, padding = clay.PaddingAll(12), childGap = 6}, backgroundColor = PLATE}) {
				nev_geocache_card(101, TEST_GEOCACHE, card, width)
			}
			commands := clay.EndLayout(0)
			box := clay.GetElementData(clay.ID("GeocacheTest")).boundingBox
			testing.expect(t, box.width <= width + 24.1 && box.height < 800)
			testing.expect(t, clay.GetElementData(clay.ID("NevHint", 101)).found)
			map_box := clay.GetElementData(clay.ID("NevMap", 101)).boundingBox
			pin := clay.GetElementData(clay.ID("NevMapPin", 101)).boundingBox
			testing.expect(t, pin.x >= map_box.x && pin.y >= map_box.y && pin.x + pin.width <= map_box.x + map_box.width && pin.y + pin.height <= map_box.y + map_box.height)
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .Text { testing.expect(t, command.boundingBox.x + command.boundingBox.width <= width + 24.1) }
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
