package main

import "core:encoding/entity"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Hn_Card :: struct {
	title, author: string,
}

// ponytail: session cache, including failures; add expiry if retries are needed.
@(private)
hn_cards: map[string]Hn_Card
@(private = "file")
hn_mutex: sync.Mutex
@(private = "file")
hn_fresh: [dynamic]struct {
	key:  string,
	card: Hn_Card,
}

// Only numeric IDs from the exact HN item endpoint reach the fixed API host.
@(private)
hn_ref :: proc(url: string) -> string {
	path := strings.trim_prefix(url, strings.has_prefix(url, "https://") ? "https://" : "http://")
	prefix :: "news.ycombinator.com/item?"
	if path == url || !strings.has_prefix(path, prefix) {return ""}
	query := path[len(prefix):]
	if cut := strings.index_byte(query, '#'); cut >= 0 {query = query[:cut]}
	num := ""
	for part in strings.split_iterator(&query, "&") {
		if !strings.has_prefix(part, "id=") {continue}
		if num != "" {return ""}
		num = part[3:]
		if len(num) == 0 || len(num) > 19 {return ""}
		for c in num {
			if c < '0' || c > '9' {return ""}
		}
	}
	return strings.trim_left(num, "0")
}

@(private)
hn_parse :: proc(body: []u8) -> (card: Hn_Card) {
	val, err := json.parse(body)
	if err != nil {return}
	defer json.destroy_value(val)
	root, ok := val.(json.Object)
	if !ok {return}
	deleted, _ := root["deleted"].(json.Boolean)
	dead, _ := root["dead"].(json.Boolean)
	title, _ := root["title"].(json.String)
	if deleted || dead || title == "" {return}
	decoded, allocated, decode_err := entity.unescape_html(title)
	if decode_err != nil {return}
	card.title = allocated ? decoded : strings.clone(decoded)
	author, _ := root["by"].(json.String)
	card.author = strings.clone(author)
	return
}

@(private = "file")
hn_worker :: proc(key: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	url := fmt.aprintf("https://hacker-news.firebaseio.com/v0/item/%s.json", key)
	defer delete(url)
	state, out, _, err := os.process_exec(
		{command = {"curl", "-sf", "--max-time", "10", "--max-filesize", "1048576", url}},
		context.allocator,
	)
	defer delete(out)
	card: Hn_Card
	if err == nil && state.exit_code == 0 {card = hn_parse(out)}
	sync.lock(&hn_mutex)
	append(&hn_fresh, struct {
		key:  string,
		card: Hn_Card,
	}{key, card})
	sync.unlock(&hn_mutex)
}

@(private)
drain_hn :: proc() {
	sync.lock(&hn_mutex)
	defer sync.unlock(&hn_mutex)
	for fresh in hn_fresh {hn_cards[fresh.key] = fresh.card}
	clear(&hn_fresh)
}

@(private)
hn_card :: proc(id: u32, key, url: string) {
	card, cached := hn_cards[key]
	if !cached {
		owned := strings.clone(key)
		hn_cards[owned] = {}
		append(&send_threads, thread.create_and_start_with_poly_data(owned, hn_worker))
	}
	if clay.UI(clay.ID("HnCard", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(att_w(360))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(14),
			childGap = 12,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(12),
		border = {color = hovered() ? fade(ACCENT, 0.5) : CARD_BORDER, width = bw()},
	},
	) {
		if hovered() {link_hover = url}
		clay.Text(
			"HACKER NEWS",
			{fontId = FONT_BODY, fontSize = 9, textColor = TEXT_DIM, letterSpacing = 1},
		)
		title := card.title != "" ? card.title : fmt.tprintf("Hacker News #%s", key)
		clay.Text(title, {fontId = FONT_TITLE, fontSize = 15, textColor = TEXT})
		if card.author != "" {
			clay.Text(
				fmt.tprintf("@%s", card.author),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
		}
		clay.Text(tr("Open in browser"), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_DIM})
	}
}
