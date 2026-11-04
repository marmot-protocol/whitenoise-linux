// External links in message bodies, and the guard in front of them.
//
// A tapped http(s) link never goes straight to the browser: the guard
// names the host it is about to hand the click to, because a link in a
// chat came from someone else. "Always open links to this site" adds
// the host to the trusted list Settings → Advanced manages, and later
// links to that exact host open without the stop.
// OpenBSD instead offers Copy link; it never hands links to another program.
package main

import "core:fmt"
import "core:strings"

import "nendo"
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
	when ODIN_OS != .OpenBSD {
		if trusted_site(ui, url_host(url)) {
			spawn_link(ui, url)
			return
		}
	}
	delete(ui.link_url)
	ui.link_url = strings.clone(url)
	ui.link_trust = false
	ui.link_open = true
	kb_focus = "" // Tab starts over at Cancel
	if nendo.current_context() != nil {
		if data := nendo.scroll(nendo.id("LinkAddress")); data.found {
			data.position^ = {}
		}
	}
}

spawn_link :: proc(ui: ^Ui_State, url: string) {
	when ODIN_OS == .OpenBSD {
		copy_text(ui, url, tr("Copied"))
	} else {
		if target, app := call_app_link(url); target != "" {
			open_external(target)
			toast(ui, fmt.tprintf(tr("Opening in %s"), app))
			return
		}
		open_external(url)
		toast(ui, tr("Opening in your browser"))
	}
}

@(private)
external_link_action :: proc() -> string {
	when ODIN_OS == .OpenBSD {
		return tr("Copy link")
	} else {
		return tr("Open in browser")
	}
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
	title, explanation, action :=
		tr("Open this link?"), tr("This leaves White Noise and opens in your browser."), tr("Open")
	if target, app := call_app_link(ui.link_url); target != "" {
		explanation = fmt.tprintf(tr("This leaves White Noise and opens the call in %s."), app)
	}
	when ODIN_OS == .OpenBSD {
		title = tr("Copy link")
		explanation = tr("Copy this link and open it in your browser.")
		action = tr("Copy link")
	}
	if nendo.box(nendo.id("LinkModal"))(
	{
		width = nendo.fixed(modal_w(nendo.id("LinkModal"), 440)),
		height = nendo.fit(max = modal_h(1200)),
		direction = .Column,
		padding = nendo.pad(20),
		gap = 12,
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			z = 16,
			offset = {0, rise(nendo.id("LinkModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		scrollbar(nendo.id("LinkModal"), 17)
		if nendo.box(nendo.id("LinkHead"))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			nendo.text(ICON_GLOBE, {font = FONT_ICON, size = 15, color = ACCENT})
			nendo.text(title, {font = FONT_TITLE, size = 18, color = TEXT})
		}
		nendo.text(explanation, {font = FONT_BODY, size = 12, color = TEXT_DIM})

		eyebrow(tr("SITE"))
		if nendo.box(nendo.id("LinkCard"))(
		{
			width = nendo.grow(),
			direction = .Column,
			padding = nendo.pad(12),
			gap = 5,
			color = ROW_BG,
			radius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			// Keep even an npub host visible in full above the scrollable address.
			inner := modal_w(nendo.id("LinkModal"), 440) - 64
			for rest := host; len(rest) > 0; {
				lo, hi := 1, len(rest)
				for lo < hi {
					mid := (lo + hi + 1) / 2
					if rl.MeasureTextLine(FONT_TITLE, 14, rest[:mid], 0).x <=
					   inner {lo = mid} else {hi = mid - 1}
				}
				for lo < len(rest) && (rest[lo] & 0xc0) == 0x80 {lo += 1}
				nendo.text(rest[:lo], {font = FONT_TITLE, size = 14, color = TEXT})
				rest = rest[lo:]
			}
			if nendo.box(nendo.id("LinkAddress"))(
			{width = nendo.grow(), height = nendo.fixed(18), clip = {x = true, scroll = true}},
			) {
				nendo.text(
					ui.link_url,
					{font = FONT_MONO, size = 11, color = TEXT_LO, wrap = .None},
				)
			}
			if rl.MeasureTextLine(FONT_MONO, 11, ui.link_url, 0).x > inner {
				nendo.text(
					tr("Scroll to read the full address."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
			}
		}

		when ODIN_OS != .OpenBSD {
			if nendo.box(nendo.id("LinkTrustRow"))(
			{
				width = nendo.grow(),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = nendo.pad(4), // room for kb_ring
				// The whole row is the touch target for the trust switch.
				// Space and Enter retain the existing explicit control order.
				gap = 10,
				align = {y = .Center},
				border = kb_focus == "LinkTrust" ? kb_ring(ACCENT) : {},
				radius = rr(6),
			},
			) {
				toggle("LinkTrust", ui.link_trust)
				nendo.text(
					tr("Always open links to this site"),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
		}

		if nendo.box(nendo.id("LinkActions"))({width = nendo.grow(), gap = 10}) {
			if nendo.box(nendo.id("LinkCancel"))(
			{
				width = single_pane() ? nendo.grow() : nendo.fit(),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 16, right = 16, top = 9, bottom = 9},
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(9),
				border = kb_focus == "LinkCancel" ? kb_ring(ACCENT) : {color = FIELD_BORDER, width = bw()},
			},
			) {
				nendo.text(tr("Cancel"), {font = FONT_TITLE, size = 13, color = TEXT})
			}
			if !single_pane() {if nendo.box(nendo.id("LinkGap"))({width = nendo.grow()}) {}}
			if nendo.box(nendo.id("LinkGo"))(
			{
				width = single_pane() ? nendo.grow() : nendo.fit(),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 16, right = 16, top = 9, bottom = 9},
				align = {x = .Center, y = .Center},
				color = hovered() ? ACCENT_DIM : ACCENT,
				radius = rr(9),
				border = kb_focus == "LinkGo" ? kb_ring(TEXT) : {},
			},
			) {
				nendo.text(action, {font = FONT_TITLE, size = 13, color = ON_ACCENT})
			}
		}
	}
}

// The modal's controls in Tab order. OpenBSD has no trust switch.
when ODIN_OS != .OpenBSD {
	@(private = "file")
	link_controls := [?]string{"LinkCancel", "LinkTrust", "LinkGo"}
} else {
	@(private = "file")
	link_controls := [?]string{"LinkCancel", "LinkGo"}
}

// Escape cancels. Tab walks the controls and Space or Enter presses the
// focused one; Enter with none focused opens. A click outside the card
// cancels.
handle_link_modal :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) {
		ui.link_open = false
		return
	}

	hit := ""
	switch control_keys(link_controls[:]) {
	case .Moved:
		return
	case .Pressed:
		hit = kb_focus
	case .None:
		if rl.IsKeyPressed(.ENTER) {
			hit = "LinkGo"
		} else if mouse_released() {
			hit = nendo.pointer_over(nendo.id("LinkModal")) ? "" : "LinkCancel"
			when ODIN_OS != .OpenBSD {if clicked("LinkTrustRow") {hit = "LinkTrust"}}
			for id in link_controls {
				if clicked(id) {
					hit = id
				}
			}
		}
	}

	switch hit {
	case "LinkTrust":
		ui.link_trust = !ui.link_trust
	case "LinkGo":
		when ODIN_OS != .OpenBSD {
			if ui.link_trust {
				append(&ui.prefs.trusted_sites, strings.clone(url_host(ui.link_url)))
				save_settings(ui)
			}
		}
		spawn_link(ui, ui.link_url)
		ui.link_open = false
	case "LinkCancel":
		ui.link_open = false
	}
}
