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
//   │  ╰──────╯               [ View profile ]  │
//   │  Name  YOU                                │
//   │  name@example.com                         │
//   │  npub1abcdef...uvwxyz                     │
//   │  About, at most three lines.              │
//   ╰───────────────────────────────────────────╯
package main

import "core:math"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
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
	open_peer(ui, client, hx, len(info.name) > 0 ? info.name : short_hex(hx), info.pic_url)
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
	inner_w := width - 2 * INSET
	radius := rr(use == .Peer_Popup ? 16 : 12).topLeft
	photo := url_pic(info.pic_url)
	over := use == .Message && clay.PointerOver(clay.ID("ProfileCard", id))
	if over {
		profile_card_hover = hex
		cursor_raise(.Pointer)
	}

	if clay.UI(clay.ID("ProfileCard", id))(
	{
		layout = {sizing = {width = clay.SizingFixed(width)}, layoutDirection = .TopToBottom},
		backgroundColor = use == .Peer_Popup ? CARD : PLATE,
		cornerRadius = clay.CornerRadiusAll(radius),
		border = {color = over ? ACCENT : CARD_BORDER, width = bw()},
	},
	) {
		banner: clay.CustomElementConfig
		if tex := nev_img(info.banner); tex != nil && tex.width > 0 && tex.height > 0 {
			view := new(Banner_View, context.temp_allocator)
			view^ = {.Banner, tex, radius}
			banner = {
				customData = view,
			}
		}
		// Without a photo the band takes their theme color, else a hue
		// from their key, so two cards in a row tell apart at a glance.
		band := style.colors[0].a > 0 ? ACCENT : avatar_color(hex)
		if clay.UI(clay.ID("ProfileCardBanner", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(BANNER_H)},
				padding = {right = INSET, bottom = 10},
				childGap = 8,
				childAlignment = {x = .Right, y = .Bottom},
			},
			backgroundColor = banner.customData == nil ? band : {},
			cornerRadius = {topLeft = radius, topRight = radius},
			custom = banner,
		},
		) {
			if banner.customData == nil {
				for size, i in ([3]f32{14, 22, 34}) {
					if clay.UI(clay.ID("ProfileCardDot", id * 4 + u32(i)))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(size),
								height = clay.SizingFixed(size),
							},
						},
						backgroundColor = {255, 255, 255, 28},
						cornerRadius = rr(size / 2),
					},
					) {}
				}
			}
			// The popup's close sits on the band, clear of the dots below it.
			if use == .Peer_Popup {
				if clay.UI(clay.ID("PeerClose"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)},
						childAlignment = {x = .Center, y = .Center},
					},
					floating = {
						attachTo = .Parent,
						offset = {-8, 8},
						attachment = {element = .RightTop, parent = .RightTop},
					},
					backgroundColor = hovered() ? {0, 0, 0, 150} : {0, 0, 0, 90},
					cornerRadius = rr(14),
				},
				) {
					clay.Text(
						ICON_CLOSE,
						{fontId = FONT_ICON, fontSize = 12, textColor = {255, 255, 255, 235}},
					)
				}
			}
		}

		// The face rides the band's lower edge in its own shape: a ring
		// would be a circle around a star, heart or square face.
		if clay.UI(clay.ID("ProfileCardFace", id))(
		{
			layout = {sizing = {width = clay.SizingFixed(FACE), height = clay.SizingFixed(FACE)}},
			floating = {
				attachTo = .Parent,
				clipTo = .AttachedParent,
				pointerCaptureMode = .Passthrough,
				offset = {INSET, BANNER_H - FACE / 2},
				attachment = {element = .LeftTop, parent = .LeftTop},
			},
		},
		) {
			avatar("ProfileCardAvatar", id, hex, name, FACE, photo)
		}

		if clay.UI(clay.ID("ProfileCardActions", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(FACE / 2 + 8)},
				padding = {right = INSET - 4, top = 10},
				childGap = 8,
				childAlignment = {x = .Right, y = .Top},
			},
		},
		) {
			switch use {
			case .Message:
				// Lit with the card: the whole card is this button.
				card_pill(
					clay.ID("ProfileCardOpen", id),
					ICON_PROFILE,
					tr("View profile"),
					over ? .Lit : .Quiet,
				)
			case .Peer_Popup:
				card_pill(clay.ID("PeerCopyNpub"), ICON_COPY, tr("Copy npub"), .Quiet)
				card_pill(clay.ID("PeerViewProfile"), ICON_PROFILE, tr("View profile"), .Quiet)
			}
		}

		if clay.UI(clay.ID("ProfileCardInfo", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {left = INSET, right = INSET, top = 6, bottom = INSET},
				childGap = 3,
			},
		},
		) {
			me := g_ui != nil && hex == g_ui.account_ref
			name_font := title_font != 0 ? title_font : FONT_TITLE
			if clay.UI(clay.ID("ProfileCardName", id))(
			{layout = {childGap = 8, childAlignment = {y = .Center}}},
			) {
				clay.Text(
					text_ellipsis(name, me ? inner_w - 48 : inner_w, name_font, 18),
					{fontId = name_font, fontSize = 18, textColor = TEXT, wrapMode = .None},
				)
				if me {
					if clay.UI(clay.ID("ProfileCardYou", id))(
					{
						layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}},
						backgroundColor = ACCENT,
						cornerRadius = rr(6),
					},
					) {
						clay.Text(
							strings.to_upper(tr("You"), context.temp_allocator),
							{fontId = FONT_TITLE, fontSize = 10, textColor = ON_ACCENT},
						)
					}
				}
			}
			if len(info.nip05) > 0 {
				clay.Text(
					text_ellipsis(strings.trim_prefix(info.nip05, "_@"), inner_w, FONT_BODY, 12),
					{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT, wrapMode = .None},
				)
			}
			// A photo hides the key's crop circle, so it rides the npub.
			if clay.UI(clay.ID("ProfileCardKey", id))(
			{layout = {childGap = 6, childAlignment = {y = .Center}}},
			) {
				if photo != nil {
					crop_circle("ProfileCardCircle", id, hex, 18)
				}
				clay.Text(
					npub_tail(npub),
					{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO, wrapMode = .None},
				)
			}
			if about := strings.trim_space(info.about); len(about) > 0 {
				// body_text emits one element per line; they stack.
				if clay.UI(clay.ID("ProfileCardAbout", id))(
				{layout = {layoutDirection = .TopToBottom, padding = {top = 6}, childGap = 2}},
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
		}
	}
}

@(private = "file")
Pill_Look :: enum {
	Quiet,
	Lit,
}

// Rounded outline button; lit (accent filled) when asked or hovered.
@(private = "file")
card_pill :: proc(id: clay.ElementId, icon, label: string, look: Pill_Look) {
	lit := look == .Lit || clay.PointerOver(id)
	if lit {cursor_raise(.Pointer)}
	if clay.UI(id)(
	{
		layout = {
			padding = {left = 12, right = 12, top = 6, bottom = 6},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = lit ? ACCENT : {},
		cornerRadius = rr(14),
		border = {color = lit ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		ink := lit ? ON_ACCENT : TEXT
		clay.Text(icon, {fontId = FONT_ICON, fontSize = 11, textColor = ink})
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 12, textColor = ink, wrapMode = .None})
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
banner_draw :: proc(view: ^Banner_View, bounds: clay.BoundingBox, tint: clay.Color) {
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
	vertex :: proc(
		p: [2]f32,
		b: clay.BoundingBox,
		crop, size: [2]f32,
		color: rl.FColor,
	) -> rl.Vertex {
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
