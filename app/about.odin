// Settings → About.
//
// Not the slint page (hero card, feature rows, credits). This one is a
// live readout: the app explaining what it does with its own running
// numbers, and an animated trace of the path a message takes from this
// machine to the other end. Nothing here is a marketing claim you have
// to take on faith; every figure comes from the session.
package main

import "core:fmt"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Wall clock at window creation, for the uptime readout.
app_started: f64

// One leg of the message path. The trace animates a packet across them
// in order, resting a beat at each stop.
HOPS := [][2]string {
	{"YOU", N_("plaintext")},
	{"MLS", N_("sealed here")},
	{"RELAY", N_("carries the blob")},
	{"THEM", N_("opened there")},
}

TRACE_SECS :: 1.1 // per hop

settings_about :: proc(ui: ^Ui_State) {
	about_wordmark()

	if clay.UI(clay.ID("AboutDescriptionGroup"))(settings_box()) {
		settings_group(N_("What it is"))
		clay.Text(
			tr(
				"A desktop client for private group chat. Messages are sealed with MLS on this machine, handed to Nostr relays as opaque blobs, and opened again only inside the group.",
			),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
		)
	}

	if clay.UI(clay.ID("AboutTraceGroup"))(settings_box()) {
		settings_group(N_("Where a message goes"))
		about_trace(ui)
		clay.Text(
			tr("The relay in the middle stores and forwards. It never holds a key."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
	}

	if clay.UI(clay.ID("AboutSessionGroup"))(settings_box()) {
		settings_group(N_("This session"))
		about_readout(ui)
	}

	if clay.UI(clay.ID("AboutCreditsGroup"))(settings_box()) {
		settings_group(N_("Built with"))
		about_credits(ui)
	}

	if clay.UI(clay.ID("AboutFoot"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 4,
			padding = {top = 8},
		},
	},
	) {
		clay.Text(
			fmt.tprintf("White Noise %s · odin port", APP_VERSION),
			{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
		)
		clay.Text(data_home, {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO})
	}
}

// Three accent bars breathing out of phase, then the name: the login
// card's "///" mark as geometry, so it animates and follows the theme.
@(private = "file")
about_wordmark :: proc() {
	t := rl.GetTime()
	if clay.UI(clay.ID("AboutMark"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {top = 8, bottom = 12},
			childGap = 16,
			childAlignment = {y = .Center},
		},
		border = {color = DIVIDER, width = {bottom = BORDER_W}},
	},
	) {
		if clay.UI(clay.ID("AboutBars"))(
		{layout = {childGap = 5, childAlignment = {y = .Center}}},
		) {
			for i in 0 ..< 3 {
				// 26..46px, each bar a third of a cycle behind the last.
				phase := t * 1.6 + f64(i) * 2.1
				h := f32(36 + 10 * sin_approx(phase))
				if clay.UI(clay.ID("AboutBar", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(5), height = clay.SizingFixed(h)},
					},
					backgroundColor = i == 1 ? ACCENT : ACCENT_DIM,
					cornerRadius = rr(3),
				},
				) {}
			}
		}
		if clay.UI(clay.ID("AboutMarkCol"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 4}},
		) {
			clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 21, textColor = TEXT})
			clay.Text(
				tr("Private group chat over Nostr"),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
		}
	}
}

// The four hops with a packet crossing them. The packet is one accent
// square parked under the hop it currently occupies.
@(private = "file")
about_trace :: proc(ui: ^Ui_State) {
	at := int(rl.GetTime() / TRACE_SECS) % len(HOPS)
	if clay.UI(clay.ID("AboutTrace"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = settings_body_width(ui) - 24 < 520 ? .TopToBottom : .LeftToRight,
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		for hop, i in HOPS {
			here := i == at
			if clay.UI(clay.ID("AboutHop", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(8),
					childGap = 6,
				},
				backgroundColor = here ? PLATE : {},
				border = {color = here ? ACCENT : DIVIDER, width = {bottom = BORDER_W}},
			},
			) {
				clay.Text(
					hop[0],
					{
						fontId = FONT_MONO,
						fontSize = 11,
						textColor = here ? ACCENT : TEXT_DIM,
						letterSpacing = 0,
					},
				)
				clay.Text(tr(hop[1]), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
				// The packet: a filled square while the trace is here, a
				// hairline track otherwise.
				if clay.UI(clay.ID("AboutHopTrack", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(3)}},
					backgroundColor = here ? ACCENT : DIVIDER,
					cornerRadius = rr(2),
				},
				) {}
			}
			if i < len(HOPS) - 1 {
				clay.Text(
					settings_body_width(ui) - 24 < 520 ? "↓" : "→",
					{fontId = FONT_BODY, fontSize = 14, textColor = i < at ? ACCENT : TEXT_LO},
				)
			}
		}
	}
}

// Six live tiles. Three columns, so the grid is two rows of three.
@(private = "file")
about_readout :: proc(ui: ^Ui_State) {
	tiles := [][2]string {
		{fmt.tprintf("%d", len(ui.chats)), "CHATS"},
		{fmt.tprintf("%d", len(ui.contacts)), "CONTACTS"},
		{
			fmt.tprintf(
				"%d/%d",
				ui.health_ok ? int(ui.health.connected) : 0,
				ui.health_ok ? int(ui.health.total_relays) : len(DEFAULT_RELAYS),
			),
			"RELAYS",
		},
		{fmt.tprintf("%d", len(ui.messages)), "LOADED"},
		{
			len(theme_packs) > 0 ? theme_packs[clamp(ui.theme, 0, len(theme_packs) - 1)].name : "—",
			"THEME",
		},
		{uptime_label(), "UPTIME"},
	}
	columns := settings_body_width(ui) - 24 < 520 ? 2 : 3
	if clay.UI(clay.ID("AboutGrid"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 8,
		},
	},
	) {
		for row in 0 ..< (len(tiles) + columns - 1) / columns {
			if clay.UI(clay.ID("AboutGridRow", u32(row)))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
			) {
				for i in row * columns ..< min(row * columns + columns, len(tiles)) {
					if clay.UI(clay.ID("AboutTile", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							padding = {top = 8, bottom = 8},
							childGap = 4,
						},
						border = {color = DIVIDER, width = {bottom = BORDER_W}},
					},
					) {
						clay.Text(
							tiles[i][0],
							{fontId = FONT_TITLE, fontSize = 20, textColor = TEXT},
						)
						clay.Text(
							tiles[i][1],
							{
								fontId = FONT_MONO,
								fontSize = 10,
								textColor = TEXT_LO,
								letterSpacing = 2,
							},
						)
					}
				}
			}
		}
	}
}

CREDITS := []string{"Odin", "clay", "SDL3", "marmot", "MLS", "Nostr", "stb", "Twemoji", "mpv"}

@(private = "file")
about_credits :: proc(ui: ^Ui_State) {
	columns := settings_body_width(ui) - 24 < 520 ? 3 : 5
	if clay.UI(clay.ID("AboutCredits"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 6,
		},
	},
	) {
		for first := 0; first < len(CREDITS); first += columns {
			if clay.UI(clay.ID("AboutCreditRow", u32(first)))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 6}},
			) {
				for i in first ..< min(first + columns, len(CREDITS)) {
					if clay.UI(clay.ID("AboutCredit", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = {top = 4, bottom = 4},
						},
					},
					) {
						clay.Text(
							CREDITS[i],
							{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
						)
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

// Sine without pulling in core:math for one decoration: a parabola pair
// over [-π, π], within ~1% of the real thing.
sin_approx :: proc(x: f64) -> f32 {
	PI :: 3.14159265358979
	t := x - 2 * PI * f64(int(x / (2 * PI)))
	if t > PI {
		t -= 2 * PI
	} else if t < -PI {
		t += 2 * PI
	}
	y := 4 / PI * t - 4 / (PI * PI) * t * abs(t)
	return f32(0.225 * (y * abs(y) - y) + y)
}
