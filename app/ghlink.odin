// GitHub pull request and issue links, drawn in place of a bare URL.
// A link alone on its line becomes a card of its own row; one written
// inside a sentence becomes a small chip in the text flow:
//
//   see [* mdk#12] before merging     inline: gh_chip
//
//   https://github.com/o/mdk/pull/12  alone:  gh_card
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
import "core:strings"
import "core:sync"
import "core:thread"

import "nendo"
import rl "sdlrl"

GH_PREFIX :: "https://github.com/"
GH_API :: "https://api.github.com/repos/"

Gh_Ref :: struct {
	owner: string, // all four slice into the message body
	repo:  string,
	num:   string,
	url:   string, // what a click opens
	pull:  bool, // false = issue
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

// Set while a message body lays out: render_segs draws a card or chip
// in place of every GitHub link it meets. Off everywhere else, so the
// composer, reply previews and the preview modal keep plain link text.
gh_cards_on: bool

// Space between the chip's icon and its label.
@(private = "file")
GH_CHIP_GAP :: 4

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
	return fmt.aprintf(
		"%s/%s/%s/%s",
		ref.owner,
		ref.repo,
		ref.pull ? "pulls" : "issues",
		ref.num,
		allocator = allocator,
	)
}

@(private = "file")
gh_worker :: proc(key: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	url := fmt.aprintf("%s%s", GH_API, key)
	defer delete(url)
	state, out, _, err := tool_exec(
		{
			command = {
				curl_path(),
				"-sf",
				"--max-time",
				"10",
				"-H",
				"Accept: application/vnd.github+json",
				url,
			},
		},
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

// The cached card for a link, requesting it the first time it is drawn.
@(private = "file")
gh_fetch :: proc(ref: Gh_Ref) -> Gh_Card {
	key := gh_key(ref)
	card, cached := gh_cards[key]
	if !cached {
		owned := strings.clone(key)
		gh_cards[owned] = Gh_Card{}
		append(&send_threads, thread.create_and_start_with_poly_data(owned, gh_worker))
	}
	return card
}

@(private = "file")
gh_badge :: proc(state: string) -> nendo.Color {
	switch state {
	case "closed":
		return DANGER
	case "merged":
		return ACCENT_DIM
	case "draft":
		return TEXT_LO
	}
	return ACCENT
}

@(private = "file")
gh_icon :: proc(ref: Gh_Ref) -> string {
	return ref.pull ? "\uf407" : ICON_INFO
}

// "mdk#12": the chip's label. The owner is left to the tooltip URL.
@(private = "file")
gh_label :: proc(ref: Gh_Ref) -> string {
	return fmt.tprintf("%s#%s", ref.repo, ref.num)
}

// Drawn chip width, for wrapping and pointer hit testing: both insets,
// the icon, the gap and the label.
@(private)
gh_chip_w :: proc(ref: Gh_Ref, size: u16) -> f32 {
	icon := rl.MeasureTextLine(FONT_ICON, size, gh_icon(ref), 0).x
	label := rl.MeasureTextLine(FONT_TITLE, size, gh_label(ref), 0).x
	return 2 * MENTION_PAD_X + GH_CHIP_GAP + icon + label
}

// The inline form: state-colored icon and "repo#12", the title on hover.
gh_chip :: proc(id: u32, ref: Gh_Ref, size: u16) {
	card := gh_fetch(ref)
	badge := gh_badge(card.state)
	if nendo.box(nendo.id("GhChip", id))(
	{
		padding = {left = MENTION_PAD_X, right = MENTION_PAD_X, top = 1, bottom = 1},
		gap = GH_CHIP_GAP,
		align = {y = .Center},
		color = fade(badge, hovered() ? 0.24 : 0.12),
		radius = rr(7),
	},
	) {
		if hovered() {
			link_hover = ref.url
			tooltip(len(card.title) > 0 ? card.title : ref.url)
		}
		nendo.text(gh_icon(ref), {font = FONT_ICON, size = size, color = badge})
		nendo.text(gh_label(ref), {font = FONT_TITLE, size = size, color = ACCENT, wrap = .None})
	}
}

// The card itself, drawn on its own row where the link was written.
gh_card :: proc(id: u32, ref: Gh_Ref) {
	card := gh_fetch(ref)
	badge := gh_badge(card.state)

	if nendo.box(nendo.id("GhCard", id))(
	{
		width = nendo.fixed(att_w(360)),
		direction = .Column,
		padding = nendo.pad(14),
		gap = 12,
		color = PLATE,
		radius = rr(12),
		border = {color = hovered() ? fade(badge, 0.5) : CARD_BORDER, width = bw()},
	},
	) {
		if hovered() {link_hover = ref.url}
		if nendo.box(nendo.id("GhCardHead", id))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			if nendo.box(nendo.id("GhCardIcon", id))(
			{
				width = nendo.fixed(28),
				height = nendo.fixed(28),
				align = {x = .Center, y = .Center},
				color = fade(badge, 0.1),
				radius = rr(8),
			},
			) {
				nendo.text(gh_icon(ref), {font = FONT_ICON, size = 15, color = badge})
			}
			if nendo.box(nendo.id("GhCardRepo", id))(
			{width = nendo.grow(), direction = .Column, gap = 3, clip = {x = true}},
			) {
				kind := ref.pull ? tr("PULL REQUEST") : tr("ISSUE")
				nendo.text(
					fmt.tprintf("%s  #%s", kind, ref.num),
					{font = FONT_BODY, size = 9, color = TEXT_DIM, spacing = 1, wrap = .None},
				)
				nendo.text(
					fmt.tprintf("%s/%s", ref.owner, ref.repo),
					{font = FONT_BODY, size = 11, color = TEXT_DIM, wrap = .None},
				)
			}
			if len(card.state) > 0 {
				if nendo.box(nendo.id("GhCardState", id))(
				{
					padding = {left = 8, right = 8, top = 4, bottom = 4},
					color = fade(badge, 0.12),
					radius = rr(9),
				},
				) {
					nendo.text(
						card.state,
						{font = FONT_TITLE, size = 10, color = badge, wrap = .None},
					)
				}
			}
		}
		// The reference remains useful while metadata is unavailable.
		title :=
			len(card.title) > 0 ? card.title : fmt.tprintf("%s/%s #%s", ref.owner, ref.repo, ref.num)
		nendo.text(title, {font = FONT_TITLE, size = 15, color = TEXT})
		if nendo.box(nendo.id("GhCardFoot", id))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			if nendo.box(nendo.id("GhCardAuthor", id))({width = nendo.grow(), clip = {x = true}}) {
				if len(card.author) > 0 {
					nendo.text(
						fmt.tprintf("@%s", card.author),
						{font = FONT_BODY, size = 11, color = TEXT_DIM, wrap = .None},
					)
				}
			}
			if nendo.box(nendo.id("GhCardOpen", id))(
			{padding = {top = 3, bottom = 3}, gap = 6, align = {y = .Center}},
			) {
				nendo.text(
					external_link_action(),
					{font = FONT_BODY, size = 10, color = TEXT_DIM, wrap = .None},
				)
				nendo.text("\uf08e", {font = FONT_ICON, size = 10, color = TEXT_DIM})
			}
		}
	}
}
