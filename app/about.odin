// Settings → About.
//
// A live readout: the app explaining what it does with its own running
// numbers, and an animated trace of the path a message takes from this
// machine to the other end. Nothing here is a marketing claim you have
// to take on faith; every figure comes from the session.
package main

import "core:math"

import "core:fmt"

import "nendo"
import rl "sdlrl"

// Wall clock at window creation, for the uptime readout.
app_started: f64

// One leg of the message path. The trace animates a packet across them
// in order, resting a beat at each stop.
HOPS := [][2]string {
	{N_("YOU"), N_("plaintext")},
	{"MLS", N_("sealed here")},
	{N_("RELAY"), N_("carries the blob")},
	{N_("THEM"), N_("opened there")},
}

TRACE_SECS :: 1.1 // per hop

settings_about :: proc(ui: ^Ui_State) {
	about_wordmark()

	if nendo.box(nendo.id("AboutDescriptionGroup"))(settings_box()) {
		settings_group(tr("What it is"))
		nendo.text(
			tr(
				"A client for private group chat. Messages are sealed with MLS on this device, handed to Nostr relays as opaque blobs, and opened again only inside the group.",
			),
			{font = FONT_BODY, size = 13, color = TEXT},
		)
	}

	if nendo.box(nendo.id("AboutTraceGroup"))(settings_box()) {
		settings_group(tr("Where a message goes"))
		about_trace(ui)
		nendo.text(
			tr("The relay in the middle stores and forwards. It never holds a key."),
			{font = FONT_BODY, size = 11, color = TEXT_LO},
		)
	}

	if nendo.box(nendo.id("AboutSessionGroup"))(settings_box()) {
		settings_group(tr("This session"))
		about_readout(ui)
	}

	if nendo.box(nendo.id("AboutCreditsGroup"))(settings_box()) {
		settings_group(tr("Built with"))
		about_credits(ui)
	}

	update_settings_row()

	if nendo.box(nendo.id("AboutFoot"))(
	{width = nendo.grow(), direction = .Column, gap = 4, padding = {top = 8}},
	) {
		nendo.text(
			fmt.tprintf("White Noise %s", APP_VERSION),
			{font = FONT_MONO, size = 11, color = TEXT_DIM},
		)
		nendo.text(tr("Data folder"), {font = FONT_BODY, size = 10, color = TEXT_DIM})
		nendo.text(data_home, {font = FONT_MONO, size = 10, color = TEXT_LO})
	}
}

// Three accent bars breathing out of phase, then the name, drawn as
// geometry so the header animates and follows the theme.
@(private = "file")
about_wordmark :: proc() {
	t := rl.GetTime()
	if nendo.box(nendo.id("AboutMark"))(
	{
		width = nendo.grow(),
		padding = {top = 8, bottom = 12},
		gap = 16,
		align = {y = .Center},
		border = {color = DIVIDER, width = {bottom = BORDER_W}},
	},
	) {
		if nendo.box(nendo.id("AboutBars"))({gap = 5, align = {y = .Center}}) {
			for i in 0 ..< 3 {
				// 26..46px, each bar a third of a cycle behind the last.
				phase := t * 1.6 + f64(i) * 2.1
				h := f32(36 + 10 * f32(math.sin(phase)))
				if nendo.box(nendo.id("AboutBar", u32(i)))(
				{
					width = nendo.fixed(5),
					height = nendo.fixed(h),
					color = i == 1 ? ACCENT : ACCENT_DIM,
					radius = rr(3),
				},
				) {}
			}
		}
		if nendo.box(nendo.id("AboutMarkCol"))({direction = .Column, gap = 4}) {
			nendo.text("White Noise", {font = FONT_TITLE, size = 21, color = TEXT})
			nendo.text(
				tr("Private group chat over Nostr"),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
		}
	}
}

// The four hops with a packet crossing them. The packet is one accent
// square parked under the hop it currently occupies.
@(private = "file")
about_trace :: proc(ui: ^Ui_State) {
	at := int(rl.GetTime() / TRACE_SECS) % len(HOPS)
	if nendo.box(nendo.id("AboutTrace"))(
	{
		width = nendo.grow(),
		direction = settings_body_width(ui) - 24 < 520 ? .Column : .Row,
		gap = 8,
		align = {y = .Center},
	},
	) {
		for hop, i in HOPS {
			here := i == at
			if nendo.box(nendo.id("AboutHop", u32(i)))(
			{
				width = nendo.grow(),
				direction = .Column,
				padding = nendo.pad(8),
				gap = 6,
				color = here ? PLATE : {},
				border = {color = here ? ACCENT : DIVIDER, width = {bottom = BORDER_W}},
			},
			) {
				nendo.text(
					tr(hop[0]),
					{font = FONT_MONO, size = 11, color = here ? ACCENT : TEXT_DIM, spacing = 0},
				)
				nendo.text(tr(hop[1]), {font = FONT_BODY, size = 11, color = TEXT_LO})
				// The packet: a filled square while the trace is here, a
				// hairline track otherwise.
				if nendo.box(nendo.id("AboutHopTrack", u32(i)))(
				{
					width = nendo.grow(),
					height = nendo.fixed(3),
					color = here ? ACCENT : DIVIDER,
					radius = rr(2),
				},
				) {}
			}
			if i < len(HOPS) - 1 {
				nendo.text(
					settings_body_width(ui) - 24 < 520 ? "↓" : "→",
					{font = FONT_BODY, size = 14, color = i < at ? ACCENT : TEXT_LO},
				)
			}
		}
	}
}

// Six live tiles. Three columns, so the grid is two rows of three.
@(private = "file")
about_readout :: proc(ui: ^Ui_State) {
	tiles := [][2]string {
		{fmt.tprintf("%d", len(ui.chats)), tr("CHATS")},
		{fmt.tprintf("%d", len(ui.contacts)), tr("CONTACTS")},
		{
			fmt.tprintf(
				"%d/%d",
				ui.health_ok ? int(ui.health.connected) : 0,
				ui.health_ok ? int(ui.health.total_relays) : len(DEFAULT_RELAYS),
			),
			tr("RELAYS"),
		},
		{fmt.tprintf("%d", len(ui.messages)), tr("LOADED MESSAGES")},
		{
			len(theme_packs) > 0 ? tr(theme_packs[clamp(ui.theme, 0, len(theme_packs) - 1)].name) : "—",
			tr("THEME"),
		},
		{uptime_label(), tr("UPTIME")},
	}
	columns := single_pane() ? 1 : settings_body_width(ui) - 24 < 520 ? 2 : 3
	if nendo.box(nendo.id("AboutGrid"))({width = nendo.grow(), direction = .Column, gap = 8}) {
		for row in 0 ..< (len(tiles) + columns - 1) / columns {
			if nendo.box(nendo.id("AboutGridRow", u32(row)))({width = nendo.grow(), gap = 8}) {
				for i in row * columns ..< min(row * columns + columns, len(tiles)) {
					if nendo.box(nendo.id("AboutTile", u32(i)))(
					{
						width = nendo.grow(),
						direction = .Column,
						padding = {top = 8, bottom = 8},
						gap = 4,
						border = {color = DIVIDER, width = {bottom = BORDER_W}},
					},
					) {
						nendo.text(tiles[i][0], {font = FONT_TITLE, size = 20, color = TEXT})
						nendo.text(
							tiles[i][1],
							{font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 2},
						)
					}
				}
			}
		}
	}
}

CREDITS := []string {
	"Odin",
	"nendo",
	"SDL3",
	"marmot",
	"MLS",
	"Nostr",
	"stb",
	"Noto Emoji",
	"Twemoji",
	"OpenMoji",
	"mpv",
}

@(private = "file")
about_credits :: proc(ui: ^Ui_State) {
	columns := single_pane() ? 1 : settings_body_width(ui) - 24 < 520 ? 3 : 5
	if nendo.box(nendo.id("AboutCredits"))({width = nendo.grow(), direction = .Column, gap = 6}) {
		for first := 0; first < len(CREDITS); first += columns {
			if nendo.box(nendo.id("AboutCreditRow", u32(first)))({width = nendo.grow(), gap = 6}) {
				for i in first ..< min(first + columns, len(CREDITS)) {
					if nendo.box(nendo.id("AboutCredit", u32(i)))(
					{width = nendo.grow(), padding = {top = 4, bottom = 4}},
					) {
						nendo.text(CREDITS[i], {font = FONT_MONO, size = 11, color = TEXT_DIM})
					}
				}
			}
		}
	}
}

// "4m" / "2h 11m" since the window opened.
uptime_label :: proc() -> string {
	total := int(rl.GetTime() - app_started)
	if total < 3600 {
		return fmt.tprintf("%dm", total / 60)
	}
	return fmt.tprintf("%dh %dm", total / 3600, (total % 3600) / 60)
}
