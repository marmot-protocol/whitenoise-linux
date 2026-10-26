// Nostr event references (nevent1 / note1, bare or "nostr:"-prefixed)
// drawn as a card under the body instead of a bare token.
//
// The event is pulled by id from the user's fetch relays (Settings →
// Network, ditto + primal by default) plus any relay hints the nevent
// carries, on its own thread, and cached twice: in memory for the
// session and as <home>/events/<id>.json across runs. Notes, replies,
// articles, pull requests and issues render as author + text; patches
// show their mail subject, description and a literal, colored diff. Product and
// geocache cards show their metadata. Highlights quote the selected
// text with context, commentary and source attribution. Other kinds
// show raw event JSON.
// Note text goes through marmot's
// markdown parser like a chat body; image links are fetched into memory
// for this session and drawn inline. Every card offers one
// "Open in client" button, the web client set in Settings → Network;
// patches use the ngit client chosen there instead.
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
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"

import marmot "../marmot"
import rl "sdlrl"

foreign import wslib {WN_BUILD_DIR + "/libwnws.a", "system:curl"}

@(default_calling_convention = "c")
foreign wslib {
	wn_ws_fetch :: proc(url: cstring, req: cstring, out: [^]u8, cap: c.size_t, timeout_ms: c.long) -> c.int ---
}

DEFAULT_FETCH_RELAYS := []string{"wss://relay.ditto.pub", "wss://relay.primal.net"}
DEFAULT_EVENT_CLIENT :: "https://ditto.pub/{id}"

// The ngit web client a patch card opens instead of the event client.
// Each resolves a bare nevent/note path to the patch's repository view,
// e.g. https://committish.app/nevent1….
@(private)
Git_Client :: enum {
	Committish,
	Gitworkshop,
	NostrHub,
}

// Product names, never translated.
@(private)
GIT_CLIENT_NAMES := [Git_Client]string {
	.Committish  = "Committish",
	.Gitworkshop = "gitworkshop",
	.NostrHub    = "NostrHub",
}

@(private = "file")
GIT_CLIENT_URLS := [Git_Client]string {
	.Committish  = "https://committish.app/",
	.Gitworkshop = "https://gitworkshop.dev/",
	.NostrHub    = "https://nostrhub.io/",
}

NEV_IMAGE_EXTS := []string{".jpg", ".jpeg", ".png", ".gif", ".webp"}

@(private = "file")
NEV_IMG_MAX_BYTES :: 16 * 1024 * 1024

// One relay's answer must fit here; bigger events show as a miss.
NEV_MAX :: 256 * 1024
NEV_TIMEOUT_MS :: 6000

// Kinds drawn as author + text. Everything else is raw JSON.
NEV_TEXT_KINDS := []i64{1, 11, 1111, NEV_PULL_REQUEST_KIND, NEV_ISSUE_KIND, 30023}

@(private = "file")
NEV_PATCH_KIND :: 1617

@(private = "file")
NEV_PULL_REQUEST_KIND :: 1618

@(private = "file")
NEV_ISSUE_KIND :: 1621

Nev_Card :: struct {
	excerpt:       Excerpt,
	product:       Nev_Product,
	geocache:      Nev_Geocache,
	highlight:     Nev_Highlight,
	patch:         Nev_Patch,
	done:          bool, // fetch finished; raw == "" then means not found
	kind:          i64,
	pubkey:        string,
	content:       string,
	subject:       string, // NIP-34 patch, pull request or issue title, owned
	subject_fonts: string, // cached title font map for bounded wrapping
	created:       i64,
	stamp:         string, // created formatted for the header, set on drain
	raw:           string, // pretty-printed event JSON
	blocks:        [dynamic]Md_Block_Ui, // content as markdown blocks, built on drain
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

// Body wrapping keeps nested event references as plain text, so a
// self-quote cannot recurse or escape the card's content width.
@(private)
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
	if ref.kind != .Event && ref.kind != .Address {return 0, "", nil, false}
	return end, ref.key, ref.relays, true
}

// ── fetch ───────────────────────────────────────────────────────────

@(private = "file")
nev_cache_path :: proc(id: string) -> string {
	key := id
	if strings.has_prefix(
		id,
		"naddr1",
	) {key = string(hex.encode(hash.hash_string(.SHA256, id, context.temp_allocator), context.temp_allocator))}
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
				if len(job.author) == 0 {break}
				relays = nil
				discover := fmt.ctprintf(
					`["REQ","wn",{{"authors":["%s"],"kinds":[10002],"limit":1}}]`,
					job.author,
				)
				for relay in job.relays {
					n := wn_ws_fetch(
						strings.clone_to_cstring(relay, context.temp_allocator),
						discover,
						raw_data(buf),
						NEV_MAX,
						NEV_TIMEOUT_MS,
					)
					if n <= 0 {continue}
					relays = nev_relay_urls(buf[:n], job.author)
					if len(relays) > 0 {break}
				}
			}
			for relay in relays {
				if seen[relay] {continue}
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
				delete(card.raw); delete(card.content); delete(card.pubkey); delete(card.subject)
				delete(card.subject_fonts)
				delete(card.patch.repository); delete(card.patch.series); delete(card.patch.lines)
				delete(card.highlight.comment); delete(card.highlight.surrounding)
				delete(card.highlight.fonts)
				for source in card.highlight.sources {delete(source.text); delete(source.url)}
				for author in card.highlight.authors {delete(author.pubkey); delete(author.role)}
				delete(card.highlight.sources); delete(card.highlight.authors)
				for value in ([]string{card.product.title, card.product.summary, card.product.image, card.product.price, card.product.availability, card.product.stock, card.product.location}) {delete(value)}
				for value in ([]string{card.geocache.name, card.geocache.image, card.geocache.hint, card.geocache.size, card.geocache.mission, card.geocache.geohash}) {delete(value)}
				card = fresh
				found = true
				os.make_directory(fmt.tprintf("%s/events", data_home))
				_ = os.write_entire_file(nev_cache_path(job.id), transmute([]u8)card.raw)
				break
			}
			if found {break}
		}
	}

	sync.lock(&nev_mutex)
	append(&nev_fresh, struct {
		id:   string,
		card: Nev_Card,
	}{job.id, card})
	sync.unlock(&nev_mutex)
}

@(private)
nev_image_url :: proc(url: string) -> bool {
	if end, _, ok := url_at(url, 0); !ok || end != len(url) {return false}
	path := url
	if cut := strings.index_any(path, "?#"); cut >= 0 {path = path[:cut]}
	// A host named example.png is not an image path.
	scheme := strings.has_prefix(path, "https://") ? 8 : 7
	if !strings.contains(path[scheme:], "/") {return false}
	for ext in NEV_IMAGE_EXTS {
		if len(path) >= len(ext) &&
		   strings.equal_fold(path[len(path) - len(ext):], ext) {return true}
	}
	return false
}

// http(s) links in text whose path ends in an image extension. The
// slices point into text.
@(private)
nev_image_urls :: proc(text: string, fonts: string = "") -> []string {
	out := make([dynamic]string)
	for i := 0; i + 8 <= len(text); i += 1 {
		if text[i] != 'h' || text_literal(fonts, i) {
			continue
		}
		end, url, ok := url_at(text, i)
		if !ok {
			continue
		}
		i = end - 1
		if nev_image_url(url) {append(&out, url)}
	}
	return out[:]
}

// Paragraphs holding image links split around them into text /
// Image / text blocks, so the picture sits where the link was.
nev_split_images :: proc(blocks: ^[dynamic]Md_Block_Ui) {
	out := make([dynamic]Md_Block_Ui)
	for block in blocks {
		urls := block.kind == .Para ? nev_image_urls(block.text, block.fonts) : nil
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
				append(
					&out,
					Md_Block_Ui {
						kind = .Para,
						text = strings.clone(before),
						fonts = strings.clone(text_fonts(block.fonts, lo, lo + len(before))),
						links = links_clone(block.links[:], lo, lo + len(before)),
						timestamps = timestamps_clone(block.timestamps[:], lo, lo + len(before)),
					},
				)
			}
			append(&out, Md_Block_Ui{kind = .Image, text = strings.clone(url)})
			at = start + len(url)
		}
		after := strings.trim_space(block.text[at:])
		if len(after) > 0 {
			lo := len(block.text) - len(strings.trim_left_space(block.text[at:]))
			append(
				&out,
				Md_Block_Ui {
					kind = .Para,
					text = strings.clone(after),
					fonts = strings.clone(text_fonts(block.fonts, lo, lo + len(after))),
					links = links_clone(block.links[:], lo, lo + len(after)),
					timestamps = timestamps_clone(block.timestamps[:], lo, lo + len(after)),
				},
			)
		}
		out[first].blank_lines_before = block.blank_lines_before
		delete(block.text)
		delete(block.fonts)
		links_free(block.links)
		delete(block.timestamps)
	}
	delete(blocks^)
	blocks^ = out
}

// ── images ──────────────────────────────────────────────────────────

// Keep private-message image bytes in memory, never in the public event cache.
// drain_nev consumes the owned buffer for texture upload.
@(private = "file")
nev_img_worker :: proc(url: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	state, data, stderr, err := tool_exec(
		{
			command = {
				curl_path(),
				"-sfL",
				"--proto",
				"=http,https",
				"--proto-redir",
				"=http,https",
				"--max-redirs",
				"3",
				"--user-agent",
				"WhiteNoiseLinux/1.0 (image previews)",
				"--max-time",
				"20",
				"--max-filesize",
				fmt.tprintf("%d", NEV_IMG_MAX_BYTES),
				"--",
				url,
			},
		},
		context.allocator,
	)
	delete(stderr)
	if err != nil || state.exit_code != 0 || len(data) > NEV_IMG_MAX_BYTES {
		delete(data)
		data = nil
	}
	sync.lock(&nev_mutex)
	append(&nev_img_fresh, struct {
		url:  string,
		data: []u8,
	}{url, data})
	sync.unlock(&nev_mutex)
}

// Enforce the card's decoded-image budget inside the helper and at its boundary.
@(private)
nev_image_decode :: proc(bytes: []u8) -> rl.Image {
	if len(bytes) < 12 || len(bytes) > NEV_IMG_MAX_BYTES {return {}}
	return rl.LoadImageFromMemory(
		"",
		raw_data(bytes),
		i32(len(bytes)),
		max_dimension = 8192,
		max_bytes = 64 * 1024 * 1024,
	)
}

// The texture for an image link, requesting it on first sight.
nev_img :: proc(url: string) -> ^rl.Texture2D {
	if g_ui != nil && g_ui.prefs.disable_link_previews {return nil}
	if end, _, ok := url_at(url, 0); !ok || end != len(url) {return nil}
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
		if message != "EVENT" || subscription != "wn" {return}
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
			if kind != json.Float(ref.event_kind) || pubkey != json.String(ref.author) {return}
			if ref.event_kind >= 30000 {
				matched := false
				if tags, ok := ev["tags"].(json.Array); ok {
					for tag in tags {
						if values, ok := tag.(json.Array); ok && len(values) >= 2 {
							name, _ := values[0].(json.String)
							if name != "d" {continue}
							identifier, ok := values[1].(json.String)
							matched = ok && identifier == json.String(ref.identifier)
							break
						}
					}
				}
				if !matched {return}
			}
		} else {
			id, _ := ev["id"].(json.String)
			if id != json.String(key) {return}
		}
	}
	card.kind = i64(kind)
	card.pubkey = strings.clone(pubkey)
	if card.kind == NEV_PRODUCT_KIND {card.product = nev_product_parse(ev)}
	if card.kind == NEV_GEOCACHE_KIND {card.geocache = nev_geocache_parse(ev)}
	if card.kind == NEV_HIGHLIGHT_KIND {card.highlight = nev_highlight_parse(ev)}
	if card.kind == NEV_PULL_REQUEST_KIND || card.kind == NEV_ISSUE_KIND {
		tags, _ := ev["tags"].(json.Array)
		for tag in tags {
			values, ok := tag.(json.Array)
			if !ok || len(values) < 2 {continue}
			name, _ := values[0].(json.String)
			subject, is_string := values[1].(json.String)
			if name != "subject" || !is_string {continue}
			card.subject = strings.clone(subject)
			font := [1]u8{FONT_TITLE}
			card.subject_fonts = strings.repeat(string(font[:]), len(subject))
			break
		}
	}
	if content, ok := ev["content"].(json.String); ok {
		card.content = strings.clone(content)
	}
	if card.kind == NEV_PATCH_KIND {nev_patch_parse(&card, ev)}
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

// Hard-wrap literal text, including unbroken ids and URLs. ASCII uses the
// mono cell width; Unicode fallback glyphs can be wider than one cell.
mono_lines :: proc(
	text: string,
	width: f32,
	color: clay.Color,
	limit: int = max(int),
) -> (
	used: int,
	complete: bool,
) {
	rest_text := text
	col_w := rl.MeasureTextLine(FONT_MONO, 11, "0", 0).x
	for line in strings.split_lines_iterator(&rest_text) {
		rest := line
		for len(rest) > 0 {
			if used >= limit {return used, false}
			cut := 0
			line_width := f32(0)
			for cut < len(rest) {
				_, w := utf8.decode_rune_in_string(rest[cut:])
				cell := col_w
				if w > 1 ||
				   rest[cut] ==
					   '\t' {cell = rl.MeasureTextLine(FONT_MONO, 11, rest[cut:cut + w], 0).x}
				if cut > 0 && line_width + cell > width {break}
				line_width += cell
				cut += w
			}
			clay.Text(rest[:cut], {fontId = FONT_MONO, fontSize = 11, textColor = color})
			used += 1
			rest = rest[cut:]
		}
	}
	return used, true
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
		if card.kind == NEV_HIGHLIGHT_KIND {
			// Cache the quote's font map; the literal text stays in card.content.
			font := [1]u8{u8(FONT_TITLE)}
			card.highlight.fonts = strings.repeat(string(font[:]), len(card.content))
		} else if card.kind != 0 &&
		   card.kind != NEV_PATCH_KIND &&
		   card.kind != 16767 &&
		   len(card.content) > 0 &&
		   g_client != nil {
			doc: ^marmot.Markdown_Document
			if marmot.parse_markdown(
				   g_client,
				   strings.clone_to_cstring(card.content, context.temp_allocator),
				   &doc,
			   ) ==
			   .OK {
				convert_blocks(
					&card.blocks,
					doc.blocks,
					doc.blocks_len,
					false,
					([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
				)
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
		image := nev_image_decode(f.data)
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
	card := nev_lookup(evid, token, hints)
	nev_depth += 1
	defer {nev_depth -= 1}

	textual := false
	for k in NEV_TEXT_KINDS {
		if card.kind == k {
			textual = true
		}
	}
	git_card :=
		(card.kind == NEV_PATCH_KIND ||
			card.kind == NEV_PULL_REQUEST_KIND ||
			card.kind == NEV_ISSUE_KIND) &&
		len(card.raw) > 0
	highlight := card.kind == NEV_HIGHLIGHT_KIND && len(card.raw) > 0
	width := att_w(git_card || highlight ? 520 : 320)
	padding := u16(git_card || highlight ? 20 : 12)
	inner_w := width - f32(padding * 2)

	if clay.UI(clay.ID("NevCard", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(padding),
			childGap = git_card || highlight ? 18 : 6,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(git_card || highlight ? 16 : 10),
		border = {color = highlight ? fade(ACCENT, 0.18) : CARD_BORDER, width = bw()},
	},
	) {
		if !highlight {
			// Keep Clay's deferred close inside the guard.
			if clay.UI(clay.ID("NevCardHead", id))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(inner_w)},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				if git_card {
					if clay.UI(clay.ID("NevGitIcon", id))(
					{
						layout = {
							sizing = {clay.SizingFixed(32), clay.SizingFixed(32)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = fade(ACCENT, 0.1),
						cornerRadius = rr(8),
					},
					) {
						clay.Text(
							card.kind == NEV_PATCH_KIND ? "\uf1d3" : (card.kind == NEV_ISSUE_KIND ? "\uf41b" : "\uf407"),
							{fontId = FONT_ICON, fontSize = 17, textColor = ACCENT},
						)
					}
				} else {
					clay.Text(ICON_GLOBE, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_LO})
				}
				switch {
				case len(card.raw) == 0:
					eyebrow(tr("NOSTR EVENT"))
				case card.kind == NEV_PRODUCT_KIND:
					eyebrow(tr("PRODUCT"))
				case card.kind == NEV_GEOCACHE_KIND:
					eyebrow(tr("GEOCACHE"))
				case git_card:
					clay.Text(
						card.kind == NEV_PATCH_KIND ? tr("PATCH") : (card.kind == NEV_ISSUE_KIND ? tr("ISSUE") : tr("PULL REQUEST")),
						{fontId = FONT_BODY, fontSize = 10, textColor = ACCENT, letterSpacing = 1},
					)
				case textual:
					eyebrow(tr("NOTE"))
				case:
					clay.Text(
						fmt.tprintf(tr("KIND %d"), card.kind),
						{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
					)
				}
				if len(card.pubkey) > 0 &&
				   !git_card &&
				   card.kind != NEV_PRODUCT_KIND &&
				   card.kind != NEV_GEOCACHE_KIND {
					clay.Text(
						fmt.tprintf("%s · %s", mention_label(card.pubkey), card.stamp),
						{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO},
					)
				}
			}
		}

		switch {
		case !card.done:
			clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		case len(card.raw) == 0:
			clay.Text(
				tr("Couldn't load this event. Check your relay settings and try again."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("NevRetry", id))(
			{layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}},
			) {
				if hovered() {nev_retry_hover = evid}
				clay.Text(tr("Retry"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
			}
		case card.kind == NEV_PRODUCT_KIND:
			if len(card.pubkey) >
			   0 {body_text(0x30000000 + id, mention_label(card.pubkey), 11, TEXT_LO, wrap_w = inner_w, max_lines = 1)}
			nev_product_card(id, evid, card, inner_w)
		case card.kind == NEV_GEOCACHE_KIND:
			nev_geocache_card(id, evid, card, inner_w)
		case card.kind == NEV_HIGHLIGHT_KIND:
			nev_highlight_card(id, evid, card, inner_w)
		case textual || card.kind == NEV_PATCH_KIND:
			if git_card {
				if clay.UI(clay.ID("NevGitTitle", id))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(inner_w)},
						layoutDirection = .TopToBottom,
						childGap = 6,
					},
				},
				) {
					if len(card.subject) > 0 {
						lines := wrapped_lines(
							card.subject,
							inner_w,
							20,
							.Text,
							card.subject_fonts,
						)
						for line, i in lines[:min(len(lines), 3)] {
							text := card.subject[line.start:line.end]
							if i == 2 &&
							   len(lines) >
								   3 {text = text_ellipsis(card.subject[line.start:], inner_w, FONT_TITLE, 20)}
							clay.Text(
								text,
								{
									fontId = FONT_TITLE,
									fontSize = 20,
									textColor = TEXT,
									wrapMode = .None,
								},
							)
						}
					}
					if len(card.pubkey) > 0 {
						clay.Text(
							text_ellipsis(mention_label(card.pubkey), inner_w, FONT_BODY, 12),
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = TEXT_DIM,
								wrapMode = .None,
							},
						)
					}
					if len(card.stamp) > 0 {
						body_text(0x32000000 + id, card.stamp, 11, TEXT_LO, wrap_w = inner_w)
					}
				}
			}
			if git_card {
				if clay.UI(clay.ID("NevGitBody", id))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingGrow()},
						padding = {top = 16},
						childGap = 8,
					},
					border = {color = DIVIDER, width = {top = 1}},
				},
				) {
					if card.kind == NEV_PATCH_KIND {
						nev_patch_card(id, evid, card, inner_w)
					} else {
						nev_card_excerpt(id, evid, card, inner_w)
					}
				}
			} else {
				nev_card_excerpt(id, evid, card, inner_w)
			}
		case:
			nev_card_excerpt(id, evid, card, inner_w, card.raw)
		}

		// Hovering binds link_hover, so a click goes through the same
		// external-link guard as a text link.
		if url := nev_open_url(card.kind, token); len(url) > 0 {
			if clay.UI(clay.ID("NevOpen", id))(
			{
				layout = {
					sizing = {
						width = git_card || highlight ? clay.SizingGrow() : clay.SizingFit(),
					},
					padding = {
						left = 10,
						right = 10,
						top = git_card || highlight ? 10 : 5,
						bottom = git_card || highlight ? 10 : 5,
					},
					childGap = 6,
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : (git_card ? fade(ACCENT, 0.08) : (highlight ? fade(ACCENT, 0.06) : clay.Color{})),
				cornerRadius = rr(7),
				border = {
					color = git_card ? fade(ACCENT, 0.25) : (highlight ? fade(ACCENT, 0.18) : FIELD_BORDER),
					width = bw(),
				},
			},
			) {
				if hovered() {
					link_hover = url
				}
				clay.Text(
					tr("Open in client"),
					{
						fontId = FONT_BODY,
						fontSize = git_card || highlight ? 12 : 11,
						textColor = git_card || highlight ? ACCENT : TEXT_DIM,
					},
				)
				if git_card || highlight {
					clay.Text("\uf08e", {fontId = FONT_ICON, fontSize = 11, textColor = ACCENT})
				}
			}
		}
	}
}

@(private)
NEV_PRODUCT_KIND :: 30402

// Where a card's "Open in client" goes: patches to the ngit client,
// everything else to the event client template. Empty hides the button.
@(private = "file")
nev_open_url :: proc(kind: i64, token: string) -> string {
	if g_ui == nil {return ""}
	_, ref := nostr_at(token, 0)
	if kind == NEV_PATCH_KIND {
		return strings.concatenate(
			{GIT_CLIENT_URLS[g_ui.prefs.git_client], ref.token},
			context.temp_allocator,
		)
	}
	if !strings.contains(g_ui.prefs.event_client, "{id}") {return ""}
	url, _ := strings.replace_all(
		g_ui.prefs.event_client,
		"{id}",
		ref.token,
		context.temp_allocator,
	)
	return url
}

@(private = "file")
NEV_HIGHLIGHT_KIND :: 9802

@(private = "file")
Nev_Source :: struct {
	text, url: string,
}

@(private = "file")
Nev_Attribution :: struct {
	pubkey, role: string,
}

@(private = "file")
Nev_Highlight :: struct {
	comment, surrounding: string,
	fonts:                string, // cached literal quotation font map
	sources:              [dynamic]Nev_Source,
	authors:              [dynamic]Nev_Attribution,
}

// Convert NIP-84 event/address sources without fetching or nesting another card.
@(private = "file")
nev_highlight_ref :: proc(name, value: string) -> string {
	digest: [32]u8
	if name == "e" {
		bytes, valid := hex.decode_into_buffer(transmute([]u8)value, digest[:])
		if !valid || len(bytes) != len(digest) {return ""}
		return bech32_encode("note", digest[:])
	}
	first := strings.index(value, ":")
	if first < 0 {return ""}
	second := strings.index(value[first + 1:], ":")
	if second < 0 {return ""}
	second += first + 1
	kind, valid := strconv.parse_u64(value[:first])
	if !valid || kind > u64(max(u32)) {return ""}
	bytes, decoded := hex.decode_into_buffer(transmute([]u8)value[first + 1:second], digest[:])
	identifier := value[second + 1:]
	if !decoded || len(bytes) != len(digest) || len(identifier) > 255 {return ""}
	data: [297]u8
	data[0], data[1] = 0, u8(len(identifier))
	copy(data[2:], transmute([]u8)identifier)
	at := 2 + len(identifier)
	data[at], data[at + 1] = 2, 32
	copy(data[at + 2:], digest[:])
	at += 34
	data[at], data[at + 1] = 3, 4
	for i in 0 ..< 4 {data[at + 2 + i] = u8(kind >> (24 - u32(i) * 8))}
	token := bech32_encode("naddr", data[:at + 6])
	_, ref := nostr_at(token, 0)
	if ref.kind == .Address {return token}
	delete(token)
	return ""
}

@(private = "file")
nev_highlight_parse :: proc(ev: json.Object) -> (h: Nev_Highlight) {
	tags, _ := ev["tags"].(json.Array)
	comment_seen, context_seen := false, false
	// Explicit source URLs lead; comment mentions must never become attribution.
	for pass in 0 ..< 2 {
		for tag in tags {
			values, ok := tag.(json.Array)
			if !ok || len(values) < 2 {continue}
			name, _ := values[0].(json.String)
			value, is_string := values[1].(json.String)
			if !is_string {continue}
			role: json.String
			if len(values) > 2 {role, _ = values[len(values) - 1].(json.String)}
			explicit := name == "r" && role == "source"
			if explicit != (pass == 0) {continue}
			text := string(value)
			source: Nev_Source
			switch name {
			case "comment":
				if !comment_seen {h.comment = strings.clone(text); comment_seen = true}
			case "context":
				if !context_seen {h.surrounding = strings.clone(text); context_seen = true}
			case "p":
				if role == "mention" {continue}
				digest: [32]u8
				bytes, valid := hex.decode_into_buffer(transmute([]u8)text, digest[:])
				if !valid || len(bytes) != len(digest) {continue}
				// A three-field p-tag ends in its relay hint, not a role.
				author_role := len(values) >= 4 ? string(role) : "author"
				if author_role == "" {author_role = "author"}
				if author_role != "editor" && author_role != "author" {continue}
				append(
					&h.authors,
					Nev_Attribution{strings.clone(text), strings.clone(author_role)},
				)
			case "r", "i":
				if role == "mention" || len(text) == 0 {continue}
				source.text = text
				url := text
				if name == "i" {
					url = ""
					if len(values) > 2 {hint, _ := values[2].(json.String); url = string(hint)}
				}
				if end, _, valid := url_at(url, 0); valid && end == len(url) {source.url = url}
			case "a", "e":
				if role == "mention" {continue}
				source.text = nev_highlight_ref(string(name), text)
				if len(source.text) > 0 {append(&h.sources, source)}
				continue
			}
			if len(source.text) > 0 {
				append(
					&h.sources,
					Nev_Source{strings.clone(source.text), strings.clone(source.url)},
				)
			}
		}
	}
	return
}

@(private = "file")
nev_highlight_card :: proc(id: u32, key: string, card: Nev_Card, width: f32) {
	h := card.highlight
	// Both panels expand together; one measured height cannot animate both.
	state := card.excerpt
	state.changed = {}
	base := 0x24000000 + id * 64
	if clay.UI(clay.ID("NevHighlightByline", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			childGap = 10,
			childAlignment = {y = .Center},
		},
	},
	) {
		name := mention_label(card.pubkey)
		avatar(
			"NevHighlightAvatar",
			id,
			card.pubkey,
			name,
			32,
			url_pic(profile_info(g_client, card.pubkey).pic_url),
		)
		if clay.UI(clay.ID("NevHighlightBylineText", id))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(max(width - 42, 1))},
				layoutDirection = .TopToBottom,
				childGap = 4,
			},
		},
		) {
			clay.Text(
				text_ellipsis(name, max(width - 42, 1), FONT_TITLE, 13),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
			)
			if len(card.stamp) > 0 {
				clay.Text(
					text_ellipsis(card.stamp, max(width - 42, 1), FONT_BODY, 10),
					{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
				)
			}
		}
	}
	more := state.expanded
	if len(h.comment) > 0 {
		if clay.UI(clay.ID("NevHighlightComment", id))(
		{layout = {sizing = {width = clay.SizingFixed(width)}, layoutDirection = .TopToBottom}},
		) {more = excerpt_body(base + 10, h.comment, nil, state, width, TEXT, .Embed)}
	}
	if clay.UI(clay.ID("NevHighlightQuote", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			layoutDirection = .TopToBottom,
			padding = {left = 18, right = 16, top = 18, bottom = 16},
			childGap = 12,
		},
		backgroundColor = fade(ACCENT, 0.045),
		cornerRadius = rr(10),
		border = {color = fade(ACCENT, 0.65), width = {left = max(BORDER_W, 2)}},
	},
	) {
		quote_w := max(width - 34, 1)
		clay.Text("\uf10d", {fontId = FONT_ICON, fontSize = 26, textColor = fade(ACCENT, 0.55)})
		if len(card.content) == 0 {
			body_text(base + 2, tr("Media highlight"), 18, TEXT_DIM, wrap_w = quote_w)
		}
		// Context keeps its original order, but never shares the quote's type scale.
		passages := [3]string{"", card.content, h.surrounding}
		if at := strings.index(h.surrounding, card.content); len(card.content) > 0 && at >= 0 {
			passages[0] = strings.trim_space(h.surrounding[:at])
			passages[2] = strings.trim_space(h.surrounding[at + len(card.content):])
		}
		for passage, index in passages {
			if len(passage) == 0 {continue}
			selected := index == 1
			size := u16(selected ? (width < 260 ? 19 : 22) : 12)
			limit :=
				state.expanded || message_line_limit() == max(int) ? max(int) : (selected ? message_line_limit() : 2)
			text := passage
			if index == 0 && limit < max(int) {
				lines := wrapped_lines(passage, quote_w, size, .Text)
				if len(lines) >
				   limit {text = passage[lines[len(lines) - limit].start:]; more = true}
			}
			panel :=
				selected ? clay.ID("ExcerptBody", base + 5) : clay.ID("NevHighlightContext", id * 4 + u32(index))
			if clay.UI(panel)(
			{
				layout = {
					sizing = {width = clay.SizingFixed(quote_w)},
					layoutDirection = .TopToBottom,
					childGap = selected ? 5 : 2,
				},
			},
			) {
				literal := [1]Inline_Link{{start = 0, end = len(text)}}
				more =
					body_text(
						base + 5 + u32(index),
						text,
						size,
						selected ? TEXT : TEXT_DIM,
						wrap_w = quote_w,
						max_lines = limit,
						fonts = selected ? h.fonts : "",
						links = literal[:],
					) >
						limit ||
					more
			}
		}
		for author, index in h.authors {
			if clay.UI(clay.ID("NevHighlightAuthor", id * 64 + u32(index)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(quote_w)},
					padding = {top = 12},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				border = {color = fade(ACCENT, 0.12), width = {top = BORDER_W}},
			},
			) {
				name := mention_label(author.pubkey)
				avatar(
					"NevHighlightAuthorAvatar",
					id * 64 + u32(index),
					author.pubkey,
					name,
					20,
					url_pic(profile_info(g_client, author.pubkey).pic_url),
				)
				label := author.role == "editor" ? tr("Editor: %s") : tr("Author: %s")
				clay.Text(
					text_ellipsis(fmt.tprintf(label, name), max(quote_w - 28, 1), FONT_BODY, 11),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
				)
			}
		}
	}
	if more && message_line_limit() < max(int) {
		if clay.UI(clay.ID("NevMore", id))(
		{
			layout = {
				padding = {left = 10, right = 10, top = 6, bottom = 6},
				childGap = 6,
				childAlignment = {y = .Center},
			},
			backgroundColor = hovered() ? HOVER : fade(ACCENT, 0.06),
			cornerRadius = rr(6),
		},
		) {
			if hovered() {nev_more_hover, nev_more_id = key, base + 5}
			clay.Text(
				card.excerpt.expanded ? tr("Show less") : tr("Read more"),
				{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
			)
			clay.Text(
				card.excerpt.expanded ? "\uf106" : "\uf107",
				{fontId = FONT_ICON, fontSize = 12, textColor = ACCENT},
			)
		}
	}
	for source, index in h.sources {
		url := source.url
		_, ref := nostr_at(source.text, 0)
		if (ref.kind == .Event || ref.kind == .Address) && g_ui != nil {
			if strings.contains(g_ui.prefs.event_client, "{id}") {
				url, _ = strings.replace_all(
					g_ui.prefs.event_client,
					"{id}",
					ref.token,
					context.temp_allocator,
				)
			}
		}
		title, detail := source.text, tr("Source")
		if ref.kind == .Event || ref.kind == .Address {
			title = len(ref.identifier) > 0 ? ref.identifier : tr("NOSTR EVENT")
			detail = len(url) > 0 ? url_host(url) : ref.token
		} else if end, _, valid := url_at(source.text, 0); valid && end == len(source.text) {
			title = url_host(source.text)
			start := strings.index(source.text, "://") + 3 + len(title)
			path := strings.trim_left(source.text[start:], "/")
			if cut := strings.index_any(path, "?#"); cut >= 0 {path = path[:cut]}
			if len(path) > 0 {detail = path}
		} else if len(url) > 0 {detail = url_host(url)}
		if clay.UI(clay.ID("NevHighlightSource", id * 64 + u32(index)))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(width)},
				padding = clay.PaddingAll(12),
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = hovered() && len(url) > 0 ? HOVER : CARD,
			cornerRadius = rr(9),
			border = {color = CARD_BORDER, width = bw()},
		},
		) {
			if hovered() && len(url) > 0 {link_hover = url}
			if clay.UI(clay.ID("NevHighlightSourceIcon", id * 64 + u32(index)))(
			{
				layout = {
					sizing = {clay.SizingFixed(28), clay.SizingFixed(28)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = fade(ACCENT, 0.09),
				cornerRadius = rr(7),
			},
			) {clay.Text(ref.kind == .Event || ref.kind == .Address ? "\uf02d" : "\uf0c1", {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})}
			if clay.UI(clay.ID("NevHighlightSourceText", id * 64 + u32(index)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(max(width - 84, 1))},
					layoutDirection = .TopToBottom,
					childGap = 4,
				},
			},
			) {
				clay.Text(
					text_ellipsis(title, max(width - 84, 1), FONT_TITLE, 12),
					{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT, wrapMode = .None},
				)
				clay.Text(
					text_ellipsis(detail, max(width - 84, 1), FONT_BODY, 10),
					{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
				)
			}
			if clay.UI(clay.ID("NevHighlightSourceArrow", id * 64 + u32(index)))(
			{layout = {sizing = {width = clay.SizingFixed(12)}, childAlignment = {x = .Center}}},
			) {
				if len(url) >
				   0 {clay.Text("\uf08e", {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM})}
			}
		}
	}
}

@(private)
Nev_Product :: struct {
	title, summary, image, price, availability, stock, location: string,
}

@(private)
nev_more_hover: string
@(private)
nev_more_id: u32
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
		if !ok || len(values) < 2 {continue}
		name, _ := values[0].(json.String)
		value, is_string := values[1].(json.String)
		if !is_string {continue}
		text := string(value)
		switch name {
		case "title":
			product.title = text
		case "summary":
			product.summary = text
		case "location":
			product.location = text
		case "status":
			status = text
		case "visibility":
			visibility = text
		case "stock":
			if _, valid := strconv.parse_u64(text); valid {product.stock = text}
		case "image":
			end, _, valid := url_at(text, 0)
			if !valid || end != len(text) {continue}
			order := i64(index)
			if len(values) > 3 {
				if raw, ok := values[3].(json.String); ok {
					if n, valid := strconv.parse_i64(string(raw)); valid {order = n}
				}
			}
			if order < image_order {product.image, image_order = text, order}
		case "price":
			if len(values) < 3 {continue}
			currency, ok := values[2].(json.String)
			if !ok || len(text) == 0 || len(currency) == 0 {continue}
			product.price = fmt.tprintf("%s %s", text, currency)
			if len(values) > 3 {
				if frequency, ok := values[3].(json.String); ok && len(frequency) > 0 {
					product.price = fmt.tprintf("%s / %s", product.price, frequency)
				}
			}
		}
	}
	switch {
	case visibility == "hidden":
		product.availability = N_("Hidden")
	case status == "sold":
		product.availability = N_("Sold")
	case product.stock == "0":
		product.availability = N_("Out of stock")
	case visibility == "pre-order":
		product.availability = N_("Pre-order")
	case visibility == "on-sale" || status == "active":
		product.availability = N_("On sale")
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
		for &font in fonts {font = u8(FONT_TITLE)}
		body_text(base, p.title, 17, TEXT, wrap_w = width, max_lines = 2, fonts = string(fonts))
	}
	if len(p.price) > 0 {body_text(base + 1, p.price, 16, ACCENT, wrap_w = width, max_lines = 2)}
	if len(p.availability) >
	   0 {body_text(base + 2, tr(p.availability), 12, TEXT_DIM, wrap_w = width)}
	if len(p.stock) >
	   0 {body_text(base + 3, fmt.tprintf(tr("Stock: %s"), p.stock), 12, TEXT_LO, wrap_w = width)}
	if len(p.location) >
	   0 {body_text(base + 4, p.location, 12, TEXT_LO, wrap_w = width, max_lines = 2)}
	nev_card_excerpt(id, key, card, width, p.summary)
}

@(private)
nev_card_image :: proc(id: u32, url: string, width: f32) {
	if len(url) == 0 {return}
	if tex := nev_img(url); tex != nil && tex.width > 0 && tex.height > 0 {
		scale := min(width / f32(tex.width), 200 / f32(tex.height))
		if clay.UI(clay.ID("NevImage", id))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(f32(tex.width) * scale),
					height = clay.SizingFixed(f32(tex.height) * scale),
				},
			},
			image = {imageData = tex},
			cornerRadius = rr(6),
		},
		) {}
	}
}

@(private = "file")
nev_card_excerpt :: proc(id: u32, key: string, card: Nev_Card, width: f32, summary: string = "") {
	description := len(summary) > 0 ? summary : card.content
	base := 0x20000000 + id * 64
	full :=
		message_line_limit() == max(int) ||
		card.excerpt.expanded ||
		card.excerpt.changed != {} &&
			motion_on() &&
			time.tick_since(card.excerpt.changed) < EXCERPT_DURATION
	blocks := card.blocks[:]
	if len(summary) > 0 {
		blocks = nil
		if full && card.kind == NEV_PRODUCT_KIND {
			description, blocks = card.content, card.blocks[:]
		}
	}
	if full && len(card.geocache.mission) > 0 {
		with_mission := make([]Md_Block_Ui, max(len(blocks), 1) + 1, context.temp_allocator)
		copy(with_mission, blocks)
		if len(blocks) == 0 {with_mission[0] = {
				kind = .Para,
				text = description,
			}}
		with_mission[len(with_mission) - 1] = {
			kind = .Para,
			text = card.geocache.mission,
		}
		blocks = with_mission
	}
	more := excerpt_body(base + 5, description, blocks, card.excerpt, width, TEXT_DIM, .Embed)
	if message_line_limit() < max(int) &&
	   (more || len(summary) > 0 && summary != card.content || len(card.geocache.mission) > 0) {
		if clay.UI(clay.ID("NevMore", id))(
		{layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}},
		) {
			if hovered() {nev_more_hover, nev_more_id = key, base + 5}
			clay.Text(
				card.excerpt.expanded ? tr("Show less") : tr("Read more"),
				{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
			)
		}
	}
}

@(private)
NEV_GEOCACHE_KIND :: 37516

@(private)
Nev_Geocache :: struct {
	name, image, hint, size, mission, geohash: string,
	difficulty, terrain:                       int,
	lat, lon:                                  f64,
}

// Geohash alternates longitude and latitude bisections, most significant bit first.
@(private)
geohash_coords :: proc(value: string) -> (lat, lon: f64, valid: bool) {
	if len(value) < 3 || len(value) > 9 {return}
	lo, hi := [2]f64{-180, -90}, [2]f64{180, 90}
	axis := 0
	for c in value {
		n := strings.index_rune("0123456789bcdefghjkmnpqrstuvwxyz", c)
		if n < 0 {return}
		for bit := 4; bit >= 0; bit -= 1 {
			mid := (lo[axis] + hi[axis]) / 2
			if n & (1 << uint(bit)) != 0 {lo[axis] = mid} else {hi[axis] = mid}
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
		if !ok || len(values) < 2 {continue}
		name, _ := values[0].(json.String)
		value, is_string := values[1].(json.String)
		if !is_string {continue}
		text := string(value)
		switch name {
		case "name":
			if len(cache.name) == 0 {cache.name = text}
		case "hint":
			if len(cache.hint) == 0 {cache.hint = text}
		case "mission":
			if len(cache.mission) == 0 {cache.mission = text}
		case "S":
			switch text {
			case "micro":
				cache.size = N_("Micro")
			case "small":
				cache.size = N_("Small")
			case "regular":
				cache.size = N_("Regular")
			case "large":
				cache.size = N_("Large")
			case "other":
				cache.size = N_("Other")
			}
		case "D", "T":
			n, valid := strconv.parse_int(text)
			if !valid || n < 1 || n > 5 {continue}
			if name == "D" {cache.difficulty = n} else {cache.terrain = n}
		case "image":
			end, _, valid := url_at(text, 0)
			if valid && end == len(text) && len(cache.image) == 0 {cache.image = text}
		case "g":
			lat, lon, valid := geohash_coords(text)
			if valid &&
			   len(text) >
				   len(cache.geohash) {cache.geohash, cache.lat, cache.lon = text, lat, lon}
		}
	}
	for field in ([]^string{&cache.name, &cache.image, &cache.hint, &cache.size, &cache.mission, &cache.geohash}) {field^ = strings.clone(field^)}
	return
}

@(private = "file")
nev_geocache_card :: proc(id: u32, key: string, card: Nev_Card, width: f32) {
	c := card.geocache
	base := 0x28000000 + id * 64
	fonts := make([]u8, len(c.name), context.temp_allocator)
	for &font in fonts {font = u8(FONT_TITLE)}
	body_text(base, c.name, 17, TEXT, wrap_w = width, max_lines = 2, fonts = string(fonts))
	nev_card_image(id, c.image, width)
	if c.difficulty >
	   0 {body_text(base + 1, fmt.tprintf(tr("Difficulty: %d/5"), c.difficulty), 12, TEXT_DIM, wrap_w = width)}
	if c.terrain >
	   0 {body_text(base + 2, fmt.tprintf(tr("Terrain: %d/5"), c.terrain), 12, TEXT_DIM, wrap_w = width)}
	if len(c.size) >
	   0 {body_text(base + 3, fmt.tprintf(tr("Size: %s"), tr(c.size)), 12, TEXT_DIM, wrap_w = width)}
	nev_card_excerpt(id, key, card, width)
	if len(c.mission) >
	   0 {body_text(base + 4, c.mission, BODY_FS, TEXT_DIM, wrap_w = width, max_lines = 3)}
	if len(c.hint) > 0 {
		if clay.UI(clay.ID("NevHint", id))(
		{layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}},
		) {
			if hovered() {nev_hint_hover = key}
			clay.Text(tr("Show hint"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
		}
	}
	if len(c.geohash) == 0 {return}
	// The geohash's precision picks the zoom: a coarse hash only says the area.
	zoom := min(15, len(c.geohash) * 2 + 2)
	geo_map(id, c.geohash, {c.lat, c.lon}, zoom, width, min(width, 256))
	open_url, open_label := geo_open(c.geohash, {c.lat, c.lon}, zoom)
	if clay.UI(clay.ID("NevMapOpen", id))(
	{layout = {sizing = {width = clay.SizingFixed(width)}, padding = {top = 4, bottom = 4}}},
	) {
		if hovered() {link_hover = open_url}
		clay.Text(open_label, {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
	}
}
