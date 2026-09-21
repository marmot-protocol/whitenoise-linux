// External links in message bodies, and the guard in front of them.
//
// A tapped http(s) link never goes straight to the browser: the guard
// names the host it is about to hand the click to, because a link in a
// chat came from someone else. "Always open links to this site" adds
// the host to the trusted list Settings → Advanced manages, and later
// links to that exact host open without the stop.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Link under the pointer this frame (its URL), rebound every build.
link_hover: string

// A URL starting at `at`, or ok = false. Trailing punctuation is left
// out so "see https://a.example/x." doesn't swallow the period.
url_at :: proc(text: string, at: int) -> (end: int, url: string, ok: bool) {
	rest := text[at:]
	scheme := 0
	switch {
	case strings.has_prefix(rest, "https://"):
		scheme = len("https://")
	case strings.has_prefix(rest, "http://"):
		scheme = len("http://")
	case:
		return 0, "", false
	}

	i := at + scheme
	for i < len(text) && text[i] > ' ' {
		i += 1
	}
	for i > at + scheme && strings.contains(".,;:!?)]}'\"", text[i - 1:i]) {
		i -= 1
	}
	if i <= at + scheme {
		return 0, "", false // scheme with no host
	}
	return i, text[at:i], true
}

// "example.com" from "https://example.com/a?b" (port and userinfo stay
// with the host: they change who answers).
url_host :: proc(url: string) -> string {
	rest := url
	if slash := strings.index(rest, "://"); slash >= 0 {
		rest = rest[slash + 3:]
	}
	if cut := strings.index_any(rest, "/?#"); cut >= 0 {
		rest = rest[:cut]
	}
	return rest
}

trusted_site :: proc(ui: ^Ui_State, host: string) -> bool {
	for site in ui.prefs.trusted_sites {
		if site == host {
			return true
		}
	}
	return false
}

// Trusted hosts open immediately; everything else asks first.
open_link :: proc(ui: ^Ui_State, url: string) {
	if trusted_site(ui, url_host(url)) {
		spawn_link(ui, url)
		return
	}
	delete(ui.link_url)
	ui.link_url = strings.clone(url)
	ui.link_trust = false
	ui.link_open = true
}

spawn_link :: proc(ui: ^Ui_State, url: string) {
	spawn_cmd(fmt.tprintf("xdg-open %q", url))
	toast(ui, tr("Opening in your browser"))
}

// Click on a link run in a body.
handle_link_click :: proc(ui: ^Ui_State) {
	if len(link_hover) == 0 || !mouse_released() {
		return
	}
	open_link(ui, link_hover)
	link_hover = ""
}

link_modal :: proc(ui: ^Ui_State) {
	host := url_host(ui.link_url)
	if clay.UI(clay.ID("LinkModal"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("LinkModal"), 440))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 12,
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 16,
			offset = {0, rise(clay.ID("LinkModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("LinkHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			clay.Text(ICON_GLOBE, {fontId = FONT_ICON, fontSize = 15, textColor = ACCENT})
			clay.Text(
				tr("Open this link?"),
				{fontId = FONT_TITLE, fontSize = 18, textColor = TEXT},
			)
		}
		clay.Text(
			tr("This leaves White Noise and opens in your browser."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)

		eyebrow("SITE")
		if clay.UI(clay.ID("LinkCard"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(12),
				childGap = 5,
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(host, {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
			// Chopped to the card: a nevent URL has no space to wrap at.
			mono_lines(ui.link_url, modal_w(clay.ID("LinkModal"), 440) - 64, TEXT_LO)
		}

		if clay.UI(clay.ID("LinkTrustRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			toggle("LinkTrust", ui.link_trust)
			clay.Text(
				tr("Always open links to this site"),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
		}

		if clay.UI(clay.ID("LinkActions"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}},
		) {
			if clay.UI(clay.ID("LinkCancel"))(
			{
				layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(tr("Cancel"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("LinkGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("LinkGo"))(
			{
				layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}},
				backgroundColor = hovered() ? ACCENT_DIM : ACCENT,
				cornerRadius = rr(9),
			},
			) {
				clay.Text(tr("Open"), {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
			}
		}
	}
}

handle_link_modal :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) {
		ui.link_open = false
		return
	}
	if !mouse_released() && !rl.IsKeyPressed(.ENTER) {
		return
	}
	if clay.PointerOver(clay.ID("LinkTrust")) {
		ui.link_trust = !ui.link_trust
		return
	}
	if clicked("LinkGo") || rl.IsKeyPressed(.ENTER) {
		if ui.link_trust {
			append(&ui.prefs.trusted_sites, strings.clone(url_host(ui.link_url)))
			save_settings(ui)
		}
		spawn_link(ui, ui.link_url)
		ui.link_open = false
		return
	}
	if clicked("LinkCancel") || !clay.PointerOver(clay.ID("LinkModal")) {
		ui.link_open = false
	}
}
