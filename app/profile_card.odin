// Bare profile mentions: a message whose whole body is one npub or
// nprofile token draws as the person's profile card instead of a
// one-chip line. The peer popup draws the same card with its own
// actions. A published profile theme recolors it, as on the contact
// page; a kind-0 banner fills the top band.
//
//   ╭───────────────────────────────────────────╮
//   │ banner photo, or a band in their color    │
//   │  ╭──────╮                        ○  ○  ◯  │
//   ├──│  ◉◉  │─────────────────────────────────┤
//   │  ╰──────╯                                │
//   │  Name  YOU                                │
//   │  name@example.com                         │
//   │  npub1abcdef...uvwxyz                     │
//   │  About, at most three lines.              │
//   │  [ Message          ] [ View profile   ]  │
//   ╰───────────────────────────────────────────╯
package main

import "core:fmt"
import "core:math"
import "core:strings"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private = "file")
BANNER_H :: 84
@(private = "file")
FACE :: 68
@(private = "file")
INSET :: 16

// Profile card under the pointer (account hex), rebound every build.
@(private)
profile_card_hover: string

// Where a card is drawn. In a message the whole card is the button to
// the full profile; in the peer popup it carries the popup's actions.
@(private)
Profile_Card_Use :: enum {
	Message,
	Peer_Popup,
}

// The peer popup's card index; message cards use multiples of 4096.
@(private)
PEER_CARD_ID :: 0xFFFF_FFFF

// Pubkey hex when the trimmed body is exactly one profile token, else "".
@(private)
bare_mention_hex :: proc(body: string) -> string {
	return mention_hex(strings.trim_space(body))
}

// Click a profile card: straight to the full profile page, not the
// popup a mention chip opens. A chip in the card's about text wins.
@(private)
handle_profile_card_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if profile_card_hover == "" || mention_hover != "" || !mouse_released() {
		return
	}
	hx := profile_card_hover
	profile_card_hover = ""
	info := profile_info(client, hx)
	open_peer(ui, client, hx, profile_label(client, hx), info.pic_url)
	view_peer_profile(ui, client)
}

@(private)
profile_card :: proc(id: u32, hex: string, width: f32, use: Profile_Card_Use) {
	// Their theme, fonts and banner are remote fetches, which the
	// link-preview switch also governs.
	style := link_cards_enabled() ? profile_style(hex) : {}
	old := profile_palette(profile_colors(style))
	defer profile_palette(old)
	title_font := profile_font(style.fonts[1])
	cards := gh_cards_on
	gh_cards_on = false
	defer {gh_cards_on = cards}

	info := profile_info(g_client, hex)
	name := mention_label(hex)
	npub := hex_npub(hex)
	defer delete(npub)
	inset: u16 = use == .Peer_Popup ? 20 : INSET
	inner_w := width - 2 * f32(inset)
	radius := rr(use == .Peer_Popup ? 16 : 12).top_left
	photo := url_pic(info.pic_url)
	over := use == .Message && nendo.pointer_over(nendo.id("ProfileCard", id))
	if over {
		profile_card_hover = hex
		cursor_raise(.Pointer)
	}

	if nendo.box(nendo.id("ProfileCard", id))(
	{
		width = nendo.fixed(width),
		direction = .Column,
		color = use == .Peer_Popup ? CARD : PLATE,
		radius = nendo.radius(radius),
		border = {color = over ? ACCENT : CARD_BORDER, width = bw()},
	},
	) {
		banner: rawptr
		if tex := nev_img(info.banner); tex != nil && tex.width > 0 && tex.height > 0 {
			view := new(Banner_View, context.temp_allocator)
			view^ = {.Banner, tex, radius}
			banner = view
		}
		// Without a photo the band takes their theme color, else a hue
		// from their key, so two cards in a row tell apart at a glance.
		band := style.colors[0].a > 0 ? ACCENT : avatar_color(hex)
		if nendo.box(nendo.id("ProfileCardBanner", id))(
		{
			width = nendo.grow(),
			height = nendo.fixed(BANNER_H),
			padding = {right = INSET, bottom = 10},
			gap = 8,
			align = {x = .Right, y = .Bottom},
			color = banner == nil ? band : {},
			radius = {top_left = radius, top_right = radius},
			custom = banner,
		},
		) {
			if banner == nil {
				for size, i in ([3]f32{14, 22, 34}) {
					if nendo.box(nendo.id("ProfileCardDot", id * 4 + u32(i)))(
					{
						width = nendo.fixed(size),
						height = nendo.fixed(size),
						color = {255, 255, 255, 28},
						radius = rr(size / 2),
					},
					) {}
				}
			}
			// The popup's close sits on the band, clear of the dots below it.
			if use == .Peer_Popup {
				if nendo.box(nendo.id("PeerClose"))(
				{
					width = nendo.fixed(settings_tap_size(28)),
					height = nendo.fixed(settings_tap_size(28)),
					align = {x = .Center, y = .Center},
					floating = {
						attach_to = .Parent,
						offset = {-8, 8},
						attach = {element = .Right_Top, parent = .Right_Top},
					},
					color = hovered() ? {0, 0, 0, 150} : {0, 0, 0, 90},
					radius = rr(14),
				},
				) {
					nendo.text(
						ICON_CLOSE,
						{font = FONT_ICON, size = 12, color = {255, 255, 255, 235}},
					)
				}
			}
		}

		// The face rides the band's lower edge in its own shape: a ring
		// would be a circle around a star, heart or square face.
		if nendo.box(nendo.id("ProfileCardFace", id))(
		{
			width = nendo.fixed(FACE),
			height = nendo.fixed(FACE),
			floating = {
				attach_to = .Parent,
				clip_to = .Parent,
				pointer = .Passthrough,
				offset = {f32(inset), BANNER_H - FACE / 2},
				attach = {element = .Left_Top, parent = .Left_Top},
			},
		},
		) {
			avatar("ProfileCardAvatar", id, hex, name, FACE, photo)
		}

		if use == .Message {
			if nendo.box(nendo.id("ProfileCardActions", id))(
			{
				width = nendo.grow(),
				height = single_pane() ? nendo.fit() : nendo.fit(min = FACE / 2 + 8),
				direction = single_pane() ? .Column : .Row,
				padding = {right = INSET - 4, top = single_pane() ? FACE / 2 + 8 : 10},
				gap = 8,
				align = {x = .Right, y = .Top},
			},
			) {
				// Lit with the card: the whole card is this button.
				card_pill(
					nendo.id("ProfileCardOpen", id),
					ICON_PROFILE,
					tr("View profile"),
					over ? .Lit : .Quiet,
				)
			}
		} else {
			if nendo.box(nendo.id("ProfileCardFaceGap", id))(
			{height = nendo.fixed(FACE / 2 + 8)},
			) {}
		}

		if nendo.box(nendo.id("ProfileCardInfo", id))(
		{
			width = nendo.grow(),
			direction = .Column,
			padding = {left = inset, right = inset, top = 6, bottom = inset},
			gap = use == .Peer_Popup ? 5 : 3,
		},
		) {
			me := g_ui != nil && hex == g_ui.account_ref
			name_font := title_font != 0 ? title_font : FONT_TITLE
			name_size := use == .Peer_Popup ? u16(20) : 18
			if nendo.box(nendo.id("ProfileCardName", id))({gap = 8, align = {y = .Center}}) {
				nendo.text(
					text_ellipsis(name, me ? inner_w - 48 : inner_w, name_font, name_size),
					{font = name_font, size = name_size, color = TEXT, wrap = .None},
				)
				if me {
					if nendo.box(nendo.id("ProfileCardYou", id))(
					{
						padding = {left = 6, right = 6, top = 2, bottom = 2},
						color = ACCENT,
						radius = rr(6),
					},
					) {
						nendo.text(
							strings.to_upper(tr("You"), context.temp_allocator),
							{font = FONT_TITLE, size = 10, color = ON_ACCENT},
						)
					}
				}
			}
			if name != info.name && info.name != "" {
				nendo.text(
					text_ellipsis(fmt.tprintf(tr("aka %s"), info.name), inner_w, FONT_BODY, 12),
					{font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None},
				)
			}
			if len(info.nip05) > 0 {
				nendo.text(
					text_ellipsis(strings.trim_prefix(info.nip05, "_@"), inner_w, FONT_BODY, 12),
					{font = FONT_BODY, size = 12, color = ACCENT, wrap = .None},
				)
			}
			// A photo hides the key's crop circle, so it rides the npub.
			if nendo.box(nendo.id("ProfileCardKey", id))({gap = 6, align = {y = .Center}}) {
				if photo != nil {
					crop_circle("ProfileCardCircle", id, hex, 18)
				}
				copy := use == .Peer_Popup
				key_id := copy ? nendo.id("PeerCopyNpubKey") : nendo.id("ProfileCardKeyText", id)
				if nendo.box(key_id)(
				{
					padding = {top = copy ? 4 : 0, bottom = copy ? 4 : 0},
					gap = 8,
					align = {y = .Center},
					color = copy && nendo.pointer_over(key_id) ? HOVER : {},
					radius = rr(4),
				},
				) {
					ink := copy && hovered() ? TEXT : TEXT_LO
					nendo.text(
						npub_tail(npub),
						{font = FONT_MONO, size = 11, color = ink, wrap = .None},
					)
					if copy {
						nendo.text(ICON_COPY, {font = FONT_ICON, size = 11, color = ink})
						if hovered() {cursor_raise(.Pointer); tooltip(tr("Copy npub"))}
					}
				}
			}
			if about := strings.trim_space(info.about); len(about) > 0 {
				// body_text emits one element per line; they stack.
				if nendo.box(nendo.id("ProfileCardAbout", id))(
				{direction = .Column, padding = {top = 6}, gap = 2},
				) {
					body_text(
						0x32000000 + id,
						about,
						13,
						TEXT_DIM,
						wrap_w = inner_w,
						max_lines = 3,
					)
				}
			}
			if use == .Peer_Popup {
				if nendo.box(nendo.id("PeerMessageRow"))(
				{
					width = nendo.grow(),
					direction = inner_w < 320 ? .Column : .Row,
					padding = {top = 16},
					gap = 8,
				},
				) {
					if g_ui != nil && !me {
						card_pill(nendo.id("PeerMessage"), ICON_CHATS, tr("Message"), .Primary)
					}
					card_pill(
						nendo.id("PeerViewProfile"),
						ICON_PROFILE,
						tr("View profile"),
						.Secondary,
					)
				}
				if nendo.box(nendo.id("PeerOtherActions"))(
				{
					width = nendo.grow(),
					direction = inner_w < 320 ? .Column : .Row,
					padding = {top = 4},
					gap = 8,
				},
				) {
					if g_ui != nil && !me && !contact_saved(g_ui, hex) {
						card_pill(nendo.id("PeerAddContact"), "", tr("Add contact"), .Quiet)
					}
					card_pill(nendo.id("PeerCopyNpub"), "", tr("Copy npub"), .Quiet)
				}
			}
		}
	}
}

@(private = "file")
Pill_Look :: enum {
	Quiet,
	Lit,
	Primary,
	Secondary,
}

// Compact card pill, or a full-width primary/secondary popup action.
@(private = "file")
card_pill :: proc(id: nendo.Id, icon, label: string, look: Pill_Look) {
	over := nendo.pointer_over(id)
	action := look == .Primary || look == .Secondary
	lit := look == .Lit || look == .Primary || (look == .Quiet && over)
	if over {cursor_raise(.Pointer)}
	down := press_down(id)
	if nendo.box(id)(
	{
		width = action ? nendo.grow() : nendo.fit(),
		height = nendo.fit(min = settings_tap_size(action ? 40 : 28)),
		padding = {left = 12, right = 12, top = 6 + down, bottom = 6 - down},
		gap = action ? 8 : 6,
		align = {x = .Center, y = .Center},
		color = lit ? ACCENT : over ? HOVER : {},
		radius = rr(action ? 9 : 14),
		border = {color = lit ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		ink := lit ? ON_ACCENT : TEXT
		if icon != "" {
			nendo.text(icon, {font = FONT_ICON, size = action ? 12 : 11, color = ink})
		}
		nendo.text(label, {font = FONT_TITLE, size = action ? 13 : 12, color = ink, wrap = .None})
	}
}

@(private)
Banner_View :: struct {
	kind:   Model_Kind,
	tex:    ^rl.Texture2D,
	radius: f32,
}

// Cover-crop the photo about its center and round the top corners to
// the card's: one triangle fan from the center over the outline,
// bottom edge first, then the right and left arcs.
@(private)
banner_draw :: proc(view: ^Banner_View, bounds: nendo.Rect, tint: nendo.Color) {
	ARC :: 8
	tex := view.tex
	if tex.width <= 0 || tex.height <= 0 {return}
	scale := max(bounds.width / f32(tex.width), bounds.height / f32(tex.height))
	w, h := f32(tex.width) * scale, f32(tex.height) * scale
	crop_x, crop_y := (w - bounds.width) / 2, (h - bounds.height) / 2
	r := min(view.radius, bounds.width / 2, bounds.height)

	outline: [2 * ARC + 4][2]f32
	outline[0] = {0, bounds.height}
	outline[1] = {bounds.width, bounds.height}
	for k in 0 ..= ARC {
		a := f32(k) / ARC * math.PI / 2
		outline[2 + k] = {bounds.width - r + r * math.cos(a), r - r * math.sin(a)}
		b := math.PI / 2 + a
		outline[3 + ARC + k] = {r + r * math.cos(b), r - r * math.sin(b)}
	}

	color := rl.FColor{tint.r / 255, tint.g / 255, tint.b / 255, tint.a / 255}
	vertex :: proc(p: [2]f32, b: nendo.Rect, crop, size: [2]f32, color: rl.FColor) -> rl.Vertex {
		return {
			position = {b.x + p.x, b.y + p.y},
			color = color,
			tex_coord = {(p.x + crop.x) / size.x, (p.y + crop.y) / size.y},
		}
	}
	center := [2]f32{bounds.width / 2, bounds.height / 2}
	vertices: [3 * len(outline)]rl.Vertex
	for p, i in outline {
		q := outline[(i + 1) % len(outline)]
		vertices[3 * i + 0] = vertex(center, bounds, {crop_x, crop_y}, {w, h}, color)
		vertices[3 * i + 1] = vertex(p, bounds, {crop_x, crop_y}, {w, h}, color)
		vertices[3 * i + 2] = vertex(q, bounds, {crop_x, crop_y}, {w, h}, color)
	}
	rl.DrawTrianglesClipped(vertices[:], bounds.x, bounds.y, bounds.width, bounds.height, tex)
}
