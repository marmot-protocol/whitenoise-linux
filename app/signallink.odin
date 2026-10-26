// Signal call links, drawn as a card under the body instead of a bare
// URL.
//
//   https://signal.link/call/#key=rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb
//
// The root key in the fragment is the call's only credential, so the
// card shows it redacted the way Signal does ("rxqb-****-…"). Nothing is
// fetched. Clicking goes through the same external-link guard a text
// link does, and signal.link hands the call to the Signal app.
package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"

// Both path spellings Signal's clients accept.
@(private = "file")
SIGNAL_CALL_PREFIXES :: [?]string{"https://signal.link/call/#", "https://signal.link/call#"}

// ringrtc's "consonant base 16": one byte is two of these.
@(private = "file")
SIGNAL_KEY_ALPHABET :: "bcdfghkmnpqrstxz"

// Characters per dash-separated group. v0 keys are 16 bytes in pairs;
// v1 keys append a version byte and a server epoch.
@(private = "file")
SIGNAL_KEY_V0 :: [?]int{4, 4, 4, 4, 4, 4, 4, 4}
@(private = "file")
SIGNAL_KEY_V1 :: [?]int{8, 8, 8, 8, 2, 8}

// The call's root key (a slice of url), or ok = false. The fragment is
// "&"-separated name=value pairs, as Signal parses it; "key" must be
// present once and other names are ignored.
@(private)
signal_call_key :: proc(url: string) -> (key: string, ok: bool) {
	fragment := ""
	prefixes := SIGNAL_CALL_PREFIXES
	for prefix in prefixes {
		if strings.has_prefix(url, prefix) {
			fragment = url[len(prefix):]
			break
		}
	}
	if fragment == "" {return}

	for part in strings.split_iterator(&fragment, "&") {
		name, eq, value := strings.partition(part, "=")
		if name == "" || strings.contains_rune(value, '=') {return "", false}
		if name != "key" {continue}
		if key != "" || eq == "" {return "", false}
		key = value
	}
	v0, v1 := SIGNAL_KEY_V0, SIGNAL_KEY_V1
	if !signal_key_shape(key, v0[:]) && !signal_key_shape(key, v1[:]) {return "", false}
	return key, true
}

// key is exactly `groups` runs of alphabet characters joined by '-'.
@(private = "file")
signal_key_shape :: proc(key: string, groups: []int) -> bool {
	at := 0
	for n, g in groups {
		if g > 0 {
			if at == len(key) || key[at] != '-' {return false}
			at += 1
		}
		if at + n > len(key) {return false}
		for i in at ..< at + n {
			if strings.index_byte(SIGNAL_KEY_ALPHABET, key[i]) < 0 {return false}
		}
		at += n
	}
	return at == len(key)
}

// "rxqb-hxff-…" → "rxqb-****-…": the first four characters identify the
// call at a glance without handing the key to anyone reading over a
// shoulder.
@(private = "file")
signal_key_redacted :: proc(key: string) -> string {
	out := strings.clone(key, context.temp_allocator)
	bytes := transmute([]u8)out
	for i in 4 ..< len(bytes) {
		if bytes[i] != '-' {bytes[i] = '*'}
	}
	return out
}

// The card reads as another app's, not a White Noise call: no accent
// anywhere (accent is this app's own voice), a tinted header band that
// names Signal under an EXTERNAL APP tag, and a sentence saying where
// the call runs. The tag stacks above the title so a compact column
// never squeezes it.
//
//   +--------------------------------------------+
//   | [cam]  [EXTERNAL APP ^]                     |  header band
//   |        Signal call                         |
//   |        rxqb-****-****-...                  |
//   +--------------------------------------------+
//   | This call runs in the Signal app, not in   |
//   | White Noise. You need Signal to join.      |
//   | signal.link              Open in browser ^ |
//   +--------------------------------------------+
@(private)
signal_call_card :: proc(id: u32, url, key: string) {
	radius := rr(12)
	if clay.UI(clay.ID("SignalCard", id))(
	{
		layout = {sizing = {width = clay.SizingFixed(att_w(360))}, layoutDirection = .TopToBottom},
		backgroundColor = PLATE,
		cornerRadius = radius,
		border = {color = hovered() ? fade(TEXT_DIM, 0.6) : CARD_BORDER, width = bw()},
	},
	) {
		if hovered() {link_hover = url}

		if clay.UI(clay.ID("SignalCardHead", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = clay.PaddingAll(14),
				childGap = 12,
				childAlignment = {y = .Center},
			},
			backgroundColor = fade(TEXT, 0.05),
			cornerRadius = {topLeft = radius.topLeft, topRight = radius.topRight},
		},
		) {
			if clay.UI(clay.ID("SignalCardIcon", id))(
			{
				layout = {
					sizing = {clay.SizingFixed(40), clay.SizingFixed(40)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = fade(TEXT, 0.08),
				cornerRadius = rr(20),
			},
			) {
				clay.Text("\uf03d", {fontId = FONT_ICON, fontSize = 17, textColor = TEXT})
			}
			if clay.UI(clay.ID("SignalCardName", id))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 4,
				},
				clip = {horizontal = true},
			},
			) {
				if clay.UI(clay.ID("SignalCardTag", id))(
				{
					layout = {
						padding = {left = 7, right = 7, top = 3, bottom = 3},
						childGap = 5,
						childAlignment = {y = .Center},
					},
					cornerRadius = rr(8),
					border = {color = fade(TEXT_DIM, 0.5), width = bw()},
				},
				) {
					clay.Text(
						tr("EXTERNAL APP"),
						{
							fontId = FONT_BODY,
							fontSize = 9,
							textColor = TEXT_DIM,
							letterSpacing = 1,
							wrapMode = .None,
						},
					)
					clay.Text("\uf08e", {fontId = FONT_ICON, fontSize = 9, textColor = TEXT_DIM})
				}
				clay.Text(
					tr("Signal call"),
					{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT, wrapMode = .None},
				)
				clay.Text(
					signal_key_redacted(key),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
				)
			}
		}

		if clay.UI(clay.ID("SignalCardBody", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(14),
				childGap = 12,
			},
		},
		) {
			clay.Text(
				tr(
					"This call runs in the Signal app, not in White Noise. You need Signal to join.",
				),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("SignalCardFoot", id))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 10,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("SignalCardHost", id))(
				{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
				) {
					clay.Text(
						url_host(url),
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
					)
				}
				clay.Text(
					external_link_action(),
					{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_DIM, wrapMode = .None},
				)
				clay.Text("\uf08e", {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_DIM})
			}
		}
	}
}
