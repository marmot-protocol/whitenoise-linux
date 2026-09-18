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

import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
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
NEV_TEXT_KINDS := []i64{1, 11, 1111}

Nev_Card :: struct {
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
	relays: []string, // owned, hints first then the prefs list
}

// ── token parsing ───────────────────────────────────────────────────

// Parse an event reference at text[i:]: optional "nostr:", then
// note1/nevent1 plus its bech32 run. end is the byte past the token,
// id the 32-byte event id as hex, relays the nevent's relay hints (both
// temp-allocated).
nevent_at :: proc(text: string, i: int) -> (end: int, id: string, relays: []string, ok: bool) {
	j := i
	if strings.has_prefix(text[j:], "nostr:") {
		j += 6
	}
	start := j
	if strings.has_prefix(text[j:], "nevent1") {
		j += 7
	} else if strings.has_prefix(text[j:], "note1") {
		j += 5
	} else {
		return
	}
	for j < len(text) && strings.index_byte(BECH32_CHARSET, text[j]) >= 0 {
		j += 1
	}
	hrp, data, dec_ok := bech32_decode(text[start:j])
	if !dec_ok {
		return
	}
	if hrp == "note" {
		if len(data) != 32 {
			return
		}
		return j, string(hex.encode(data, context.temp_allocator)), nil, true
	}
	if hrp != "nevent" {
		return
	}
	// TLV: type 0 = event id, type 1 = relay hint (may repeat).
	hints := make([dynamic]string, context.temp_allocator)
	k := 0
	for k + 2 <= len(data) {
		t := data[k]
		l := int(data[k + 1])
		k += 2
		if k + l > len(data) {
			break
		}
		if t == 0 && l == 32 {
			id = string(hex.encode(data[k:k + 32], context.temp_allocator))
		}
		if t == 1 {
			append(&hints, string(data[k:k + l]))
		}
		k += l
	}
	if len(id) == 0 {
		return
	}
	return j, id, hints[:], true
}

// ── fetch ───────────────────────────────────────────────────────────

@(private = "file")
nev_cache_path :: proc(id: string) -> string {
	return fmt.tprintf("%s/events/%s.json", data_home, id)
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
		free(job)
	}

	card: Nev_Card
	card.done = true
	if data, err := os.read_entire_file(nev_cache_path(job.id), context.allocator); err == nil {
		card = nev_parse(data, .Event)
		delete(data)
	} else {
		req := fmt.aprintf(`["REQ","wn",{{"ids":["%s"]}}]`, job.id)
		defer delete(req)
		req_c := strings.clone_to_cstring(req)
		defer delete(req_c)
		buf := make([]u8, NEV_MAX)
		defer delete(buf)
		for relay in job.relays {
			relay_c := strings.clone_to_cstring(relay)
			n := wn_ws_fetch(relay_c, req_c, raw_data(buf), NEV_MAX, NEV_TIMEOUT_MS)
			delete(relay_c)
			if n <= 0 {
				continue
			}
			card = nev_parse(buf[:n], .Message)
			if len(card.raw) == 0 {
				continue
			}
			os.make_directory(fmt.tprintf("%s/events", data_home))
			_ = os.write_entire_file(nev_cache_path(job.id), transmute([]u8)card.raw)
			break
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
				append(&out, Md_Block_Ui{kind = .Para, text = strings.clone(before)})
			}
			append(&out, Md_Block_Ui{kind = .Image, text = strings.clone(url)})
			at = start + len(url)
		}
		after := strings.trim_space(block.text[at:])
		if len(after) > 0 {
			append(&out, Md_Block_Ui{kind = .Para, text = strings.clone(after)})
		}
		out[first].blank_lines_before = block.blank_lines_before
		delete(block.text)
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
		state, _, _, err := os.process_exec({command = {"curl", "-sfL", "--max-time", "20", "-o", path, url}}, context.temp_allocator)
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
nev_parse :: proc(body: []u8, shape: Nev_Shape) -> (card: Nev_Card) {
	card.done = true
	val, perr := json.parse(body)
	if perr != nil {
		return
	}
	defer json.destroy_value(val)

	ev_val := val
	if shape == .Message {
		arr, is_arr := val.(json.Array)
		if !is_arr || len(arr) < 3 {
			return
		}
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
	card.kind = i64(kind)
	card.pubkey = strings.clone(pubkey)
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
		if len(card.content) > 0 && g_client != nil {
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

// The card itself, drawn where the token was written. token is the
// bech32 as written (minus any nostr: prefix), what the button opens.
nev_card :: proc(id: u32, evid: string, token: string, hints: []string) {
	if nev_depth > 0 {
		clay.Text(token, {fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_DIM})
		return
	}
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
		job.relays = relays[:]
		append(&send_threads, thread.create_and_start_with_poly_data(job, nev_worker))
	}

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
			case textual:
				eyebrow("NOTE")
			case:
				clay.Text(fmt.tprintf("KIND %d", card.kind), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
			if len(card.pubkey) > 0 {
				clay.Text(fmt.tprintf("%s · %s", mention_label(card.pubkey), card.stamp), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
			}
		}

		switch {
		case !card.done:
			clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		case len(card.raw) == 0:
			clay.Text(tr("Couldn't load this event. Check your relay settings and try again."), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		case textual:
			// The note's own body: wrapped to the card, emoji as tiles,
			// links live. Ids sit in a high block so the lines do not
			// collide with the body this card is inside.
			nev_depth += 1
			if len(card.blocks) > 0 {
				if clay.UI(clay.ID("NevCardBody", id))({layout = {layoutDirection = .TopToBottom, childGap = 6}}) {
					md_blocks(card.blocks[:], 0x10000000 + id * 64, false, inner_w)
				}
			} else {
				body_text(0x10000000 + id * 64, card.content, BODY_FS, TEXT, wrap_w = inner_w)
			}
			nev_depth -= 1
		case:
			if clay.UI(clay.ID("NevCardJson", id))({layout = {layoutDirection = .TopToBottom}}) {
				mono_lines(card.raw, inner_w, TEXT)
			}
		}

		// Hovering binds link_hover, so a click goes through the same
		// external-link guard as a text link.
		if g_ui != nil && strings.contains(g_ui.prefs.event_client, "{id}") {
			url, _ := strings.replace_all(g_ui.prefs.event_client, "{id}", token, context.temp_allocator)
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
