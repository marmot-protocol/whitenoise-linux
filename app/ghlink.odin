// GitHub pull request and issue links, drawn as a card under the body
// instead of a bare URL.
//
// A link only ever names the fetch: owner, repo and number are read
// out of the URL and rebuilt into an api.github.com path, so a message
// cannot point this at a host of its own choosing. The card falls back
// to "owner/repo #12" when the fetch fails. Clicking it goes through
// the same external-link guard a text link does.
//
// ponytail: cards are cached for the session and never refetched, and
// the unauthenticated API allows 60 calls an hour. Persist the cache
// and back off on 403 when a busy chat starts hitting the ceiling.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"

GH_PREFIX :: "https://github.com/"
GH_API :: "https://api.github.com/repos/"

Gh_Ref :: struct {
	owner: string, // all four slice into the message body
	repo:  string,
	num:   string,
	url:   string, // what a click opens
	pull:  bool,   // false = issue
}

Gh_Card :: struct {
	title:  string, // "" = pending, or a fetch that failed
	state:  string, // open / draft / merged / closed
	author: string,
}

// api path ("owner/repo/pulls/12") → card. An entry appears the frame
// the link is first laid out and is overwritten when its worker lands,
// so presence also means "already requested".
gh_cards: map[string]Gh_Card

@(private = "file")
gh_mutex: sync.Mutex
@(private = "file")
gh_fresh: [dynamic]struct {
	key:  string, // owned, moves into gh_cards
	card: Gh_Card,
}

// Set while a message body lays out: render_segs draws a card in place
// of every GitHub link it meets. Off everywhere else, so the composer,
// reply previews and the preview modal keep plain link text.
gh_cards_on: bool

// The PR or issue a URL names, or ok = false. Any ?query/#fragment is
// cut, so the number is the number as written.
gh_ref :: proc(url: string) -> (ref: Gh_Ref, ok: bool) {
	if !strings.has_prefix(url, GH_PREFIX) {
		return
	}

	parts := strings.split(url[len(GH_PREFIX):], "/", context.temp_allocator)
	if len(parts) < 4 || len(parts[0]) == 0 || len(parts[1]) == 0 {
		return
	}
	pull: bool
	switch parts[2] {
	case "pull":
		pull = true
	case "issues":
		pull = false
	case:
		return
	}

	num := parts[3]
	if cut := strings.index_any(num, "?#"); cut >= 0 {
		num = num[:cut]
	}
	if len(num) == 0 {
		return
	}
	for c in num {
		if c < '0' || c > '9' {
			return
		}
	}
	return Gh_Ref{owner = parts[0], repo = parts[1], num = num, url = url, pull = pull}, true
}

// "owner/repo/pulls/12": the api.github.com path, and the cache key.
// The REST endpoint is plural where the web URL is singular.
gh_key :: proc(ref: Gh_Ref, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s/%s/%s", ref.owner, ref.repo, ref.pull ? "pulls" : "issues", ref.num, allocator = allocator)
}

@(private = "file")
gh_worker :: proc(key: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	url := fmt.aprintf("%s%s", GH_API, key)
	defer delete(url)
	state, out, _, err := os.process_exec(
		{command = {"curl", "-sf", "--max-time", "10", "-H", "Accept: application/vnd.github+json", url}},
		context.allocator,
	)
	defer delete(out)

	card: Gh_Card
	if err == nil && state.exit_code == 0 && len(out) > 0 {
		card = gh_parse(out)
	}

	sync.lock(&gh_mutex)
	append(&gh_fresh, struct {
		key:  string,
		card: Gh_Card,
	}{key, card})
	sync.unlock(&gh_mutex)
}

// title, author and the state the badge shows. A merged PR reports
// state "closed" with a merged_at timestamp, and an open one can be a
// draft, so both are folded into one word here.
gh_parse :: proc(body: []u8) -> (card: Gh_Card) {
	val, perr := json.parse(body)
	if perr != nil {
		return
	}
	defer json.destroy_value(val)

	root, is_obj := val.(json.Object)
	if !is_obj {
		return
	}
	title, has_title := root["title"].(json.String)
	if !has_title || len(title) == 0 {
		return
	}
	card.title = strings.clone(title)

	st, _ := root["state"].(json.String)
	_, merged := root["merged_at"].(json.String) // null unless merged
	draft, _ := root["draft"].(json.Boolean)
	switch {
	case merged:
		card.state = strings.clone("merged")
	case draft && st == "open":
		card.state = strings.clone("draft")
	case:
		card.state = strings.clone(st)
	}

	if user, ok := root["user"].(json.Object); ok {
		if login, ok2 := user["login"].(json.String); ok2 {
			card.author = strings.clone(login)
		}
	}
	return
}

// Frame-loop drain: publish finished fetches to the render side.
drain_gh :: proc() {
	sync.lock(&gh_mutex)
	defer sync.unlock(&gh_mutex)
	for f in gh_fresh {
		gh_cards[f.key] = f.card
	}
	clear(&gh_fresh)
}

// The card itself, drawn where the link it replaces was written.
gh_card :: proc(id: u32, ref: Gh_Ref) {
	key := gh_key(ref)
	card, cached := gh_cards[key]
	if !cached {
		owned := strings.clone(key)
		gh_cards[owned] = Gh_Card{}
		append(&send_threads, thread.create_and_start_with_poly_data(owned, gh_worker))
	}

	badge := ACCENT
	switch card.state {
	case "closed":
		badge = DANGER
	case "merged":
		badge = ACCENT_DIM
	case "draft":
		badge = TEXT_LO
	}

	if clay.UI(clay.ID("GhCard", id))(
	{
		layout = {sizing = {width = clay.SizingFixed(att_w(360))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(14), childGap = 12},
		backgroundColor = PLATE,
		cornerRadius = rr(12),
		border = {color = hovered() ? fade(badge, 0.5) : CARD_BORDER, width = bw()},
	},
	) {
		if hovered() { link_hover = ref.url }
		if clay.UI(clay.ID("GhCardHead", id))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
			if clay.UI(clay.ID("GhCardIcon", id))({layout = {sizing = {clay.SizingFixed(28), clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = fade(badge, 0.1), cornerRadius = rr(8)}) {
				clay.Text(ref.pull ? "\uf407" : ICON_INFO, {fontId = FONT_ICON, fontSize = 15, textColor = badge})
			}
			if clay.UI(clay.ID("GhCardRepo", id))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}, clip = {horizontal = true}}) {
				kind := ref.pull ? tr("PULL REQUEST") : tr("ISSUE")
				clay.Text(fmt.tprintf("%s  #%s", kind, ref.num), {fontId = FONT_BODY, fontSize = 9, textColor = TEXT_DIM, letterSpacing = 1, wrapMode = .None})
				clay.Text(fmt.tprintf("%s/%s", ref.owner, ref.repo), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None})
			}
			if len(card.state) > 0 {
				if clay.UI(clay.ID("GhCardState", id))(
				{layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}}, backgroundColor = fade(badge, 0.12), cornerRadius = rr(9)},
				) {
					clay.Text(card.state, {fontId = FONT_TITLE, fontSize = 10, textColor = badge, wrapMode = .None})
				}
			}
		}
		// The reference remains useful while metadata is unavailable.
		title := len(card.title) > 0 ? card.title : fmt.tprintf("%s/%s #%s", ref.owner, ref.repo, ref.num)
		clay.Text(title, {fontId = FONT_TITLE, fontSize = 15, textColor = TEXT})
		if clay.UI(clay.ID("GhCardFoot", id))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
			if clay.UI(clay.ID("GhCardAuthor", id))({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
				if len(card.author) > 0 {
					clay.Text(fmt.tprintf("@%s", card.author), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None})
				}
			}
			if clay.UI(clay.ID("GhCardOpen", id))({layout = {padding = {top = 3, bottom = 3}, childGap = 6, childAlignment = {y = .Center}}}) {
				clay.Text(tr("Open in browser"), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_DIM, wrapMode = .None})
				clay.Text("\uf08e", {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_DIM})
			}
		}
	}
}
