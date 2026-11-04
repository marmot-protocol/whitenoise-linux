package main

import "core:fmt"
import "core:math"
import "core:strings"

import "nendo"
import rl "sdlrl"

@(private)
message_url :: proc(msg: Msg_Ui) -> string {
	for i in 0 ..< len(msg.body) {
		if _, url, ok := url_at(msg.body, i); ok {return url}
	}
	return ""
}

ctx_item :: proc(id_str: string, glyph: string, label: string, color: nendo.Color = {}) {
	menu_press_mark(nendo.id(id_str))
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = tap_size() ? tap_min() : 32),
		padding = {left = 10, right = 16},
		gap = 9,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(6),
	},
	) {
		if nendo.box(nendo.id_local("CtxGlyph"))(
		{width = nendo.fixed(16), align = {x = .Center}},
		) {
			nendo.text(
				glyph,
				{
					font = FONT_ICON,
					size = 13,
					color = color.a > 0 ? color : (hovered() ? TEXT : TEXT_DIM),
				},
			)
		}
		nendo.text(label, {font = FONT_BODY, size = 12, color = color.a > 0 ? color : TEXT})
	}
}

// Per-member action menu, opened by a member row's "⋯". Replaces the
// hover chips that used to grow the row; the admin items stay gated the
// same way (only the self row can step down, only others can be
// promoted, demoted or removed).
// The member a menu was opened on, kept past the close so the menu can
// animate out (see row_menu_shown).
member_menu_shown: int

member_menu_index :: proc(ui: ^Ui_State) -> int {
	if ui.member_menu >= 0 {
		member_menu_shown = ui.member_menu
	}
	return member_menu_shown
}

member_menu :: proc(ui: ^Ui_State) {
	defer scrollbar(nendo.id("MemberMenu"), 11)
	member := ui.members[member_menu_index(ui)]
	x, y := ui.member_menu_x, ui.member_menu_y
	width, height := f32(190), f32(140)
	if box, ok := element_box(nendo.id("MemberMenu")); ok {
		width, height = box.width, box.height
	}
	if anchor, ok := element_box(nendo.id("MemberMenuBtn", u32(member_menu_index(ui)))); ok {
		x, y = anchor.x + anchor.width - width, anchor.y + anchor.height + 4
		if y + height > f32(rl.GetScreenHeight()) / UI_ZOOM - 12 {
			y = anchor.y - height - 4
		}
	}
	x, y = panel_pos(x, y, width, height)

	if nendo.box(nendo.id("MemberMenu"))(
	{
		direction = .Column,
		width = nendo.fit(min = 190, max = fit_w(320)),
		height = nendo.fit(max = modal_h(360)),
		padding = nendo.pad(4),
		gap = 1,
		floating = {
			attach_to = .Root,
			offset = {x, y + rise(nendo.id("MemberMenu"))},
			attach = {element = .Left_Top, parent = .Left_Top},
			z = 10,
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
		clip = {y = true, scroll = true},
	},
	) {
		if member.is_self {
			if member.is_admin {
				ctx_item("MemberStepDown", ICON_BAN, tr("Step down"))
			}
			return
		}
		if self_is_admin(ui) {
			ctx_item(
				member.is_admin ? "MemberDemote" : "MemberPromote",
				ICON_STAR,
				member.is_admin ? tr("Demote") : tr("Promote"),
			)
			ctx_item("MemberRemove", ICON_TRASH, tr("Remove"))
		}
		ctx_item("MemberNick", ICON_PENCIL, tr("Nickname"))
	}
}

// Open it under the clicked "⋯", clamped to the window like the row menu.
open_member_menu :: proc(ui: ^Ui_State, index: int) {
	m := rl.GetMousePosition()
	ui.member_menu = index
	ui.member_menu_x, ui.member_menu_y = panel_pos(m.x / UI_ZOOM, m.y / UI_ZOOM, 200, 140)
}

// Clicks in the open member menu; true when the frame's input was
// consumed. Any click closes it, hit or miss.
handle_member_menu :: proc(ui: ^Ui_State) -> bool {
	if ui.member_menu >= len(ui.members) || rl.IsKeyPressed(.ESCAPE) {
		ui.member_menu = -1
		return true
	}
	if !mouse_released() {
		return false
	}
	if menu_keep(nendo.id("MemberMenu")) {return true}
	index := ui.member_menu
	member := ui.members[index]
	ui.member_menu = -1

	if member.is_self {
		if member.is_admin && nendo.pointer_over(nendo.id("MemberStepDown")) {
			confirm_ask(ui, .Step_Down, member.id_hex, member.name)
		}
		return true
	}
	if self_is_admin(ui) {
		if nendo.pointer_over(nendo.id(member.is_admin ? "MemberDemote" : "MemberPromote")) {
			confirm_ask(ui, member.is_admin ? .Demote : .Promote, member.id_hex, member.name)
			return true
		}
		if nendo.pointer_over(nendo.id("MemberRemove")) {
			confirm_ask(ui, .Remove_Member, member.id_hex, member.name)
			return true
		}
	}
	if nendo.pointer_over(nendo.id("MemberNick")) {
		ui.member_nick = index
		ed_set(ui, &ui.nick_input, ui.nicknames[member.id_hex])
		ui.focus = .Nick
	}
	return true
}

// Right-click context menu for a message: quick-reaction strip,
// divider, then the gated action rows.
@(private)
sheet_bottom :: proc() -> f32 {
	if nav := nendo.element(nendo.id("PhoneNavigation")); nav.found {
		return max(f32(rl.GetScreenHeight()) / UI_ZOOM - nav.rect.y, 0)
	}
	return 0
}

@(private)
sheet_max_h :: proc() -> f32 {
	return max(44, f32(rl.GetScreenHeight()) / UI_ZOOM - sheet_bottom() - 64)
}

@(private)
sheet_title :: proc(title: string, detail: string = "") {
	if nendo.box(nendo.id_local("SheetTitle"))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = {left = 12, right = 12, top = 12, bottom = 10},
		gap = 5,
	},
	) {
		width := f32(rl.GetScreenWidth()) / UI_ZOOM - 32
		nendo.text(
			text_ellipsis(title, width, FONT_TITLE, 14),
			{font = FONT_TITLE, size = 14, color = TEXT},
		)
		if detail !=
		   "" {nendo.text(text_ellipsis(detail, width, FONT_BODY, 12), {font = FONT_BODY, size = 12, color = TEXT_DIM})}
	}
}

context_menu :: proc(ui: ^Ui_State) {
	msg := ui.messages[ui.ctx_msg]

	// The open-time clamp in handlers.odin guesses the height; re-clamp
	// against the box nendo actually laid out, so a tall menu (own message,
	// attachments, dev mode) never runs past the window bottom.
	y := ui.ctx_y
	x := ui.ctx_x
	if box, laid_out := element_box(nendo.id("CtxMenu")); laid_out {
		x, y = panel_pos(x, y, box.width, box.height)
	}

	if nendo.box(nendo.id("CtxMenu"))(
	{
		direction = .Column,
		width = single_pane() ? nendo.fixed(f32(rl.GetScreenWidth()) / UI_ZOOM) : nendo.fit(min = 200, max = fit_w(560)),
		height = nendo.fit(max = single_pane() ? sheet_max_h() : modal_h(700)),
		padding = nendo.pad(4),
		gap = 1,
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			offset = {
				single_pane() ? 0 : x,
				(single_pane() ? -sheet_bottom() : y) + rise(nendo.id("CtxMenu")),
			},
			attach = {
				element = single_pane() ? .Left_Bottom : .Left_Top,
				parent = single_pane() ? .Left_Bottom : .Left_Top,
			},
			z = 10,
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if single_pane() {
			sheet_title(msg.sender, msg_preview(msg))
			nendo.text(msg.at_full, {font = FONT_BODY, size = 11, color = TEXT_DIM})
		}
		if !msg.deleted {
			if ui.selected < 0 || !ui.chats[ui.selected].archived {
				if nendo.box(nendo.id("CtxStrip"))(
				{
					width = nendo.grow(),
					padding = {left = 6, right = 6, top = 2, bottom = 2},
					gap = 1,
					clip = {x = true, scroll = true},
				},
				) {
					for emoji, i in ui.prefs.quick_reactions {
						menu_press_mark(nendo.id("CtxQuick", u32(i)))
						if nendo.box(nendo.id("CtxQuick", u32(i)))(
						{
							width = nendo.fixed(tap_size() ? tap_min() : 28),
							height = nendo.fixed(tap_size() ? tap_min() : 28),
							align = {x = .Center, y = .Center},
							color = hovered() ? HOVER : {},
							radius = rr(8),
						},
						) {
							if tex := emoji_tex(emoji); tex != nil {
								if nendo.box(nendo.id("CtxQuickImg", u32(i)))(
								{width = nendo.fixed(18), aspect = 1, image = tex},
								) {}
							} else {
								nendo.text(emoji, {font = FONT_BODY, size = 14, color = TEXT})
							}
						}
					}
					menu_press_mark(nendo.id("CtxQuickPlus"))
					if nendo.box(nendo.id("CtxQuickPlus"))(
					{
						width = nendo.fixed(tap_size() ? tap_min() : 28),
						height = nendo.fixed(tap_size() ? tap_min() : 28),
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(8),
					},
					) {
						nendo.text("+", {font = FONT_BODY, size = 15, color = TEXT})
					}
				}

				// Divider band under the strip.
				scrollbar(nendo.id("CtxStrip"), 11)
				if nendo.box(nendo.id("CtxDivBand"))(
				{
					width = nendo.grow(),
					height = nendo.fixed(7),
					padding = {left = 6, right = 6, top = 3},
				},
				) {
					if nendo.box(nendo.id("CtxDivLine"))(
					{width = nendo.grow(), height = nendo.fixed(1), color = BORDER_2},
					) {}
				}

			}
			read_only := ui.selected >= 0 && ui.chats[ui.selected].archived
			if !read_only && !single_pane() {ctx_item("CtxReact", ICON_SMILE, tr("Add reaction"))}
			if !read_only && len(msg.thread_of) == 0 {
				ctx_item("CtxReply", ICON_REPLY, tr("Reply"))
			}
			ctx_item("CtxThread", ICON_COMMENTS, tr("Reply in thread"))
			if msg.mine && !read_only {ctx_item("CtxEdit", ICON_PENCIL, tr("Edit message"))}
			if len(msg.body) > 0 {
				ctx_item("CtxCopy", ICON_COPY, tr("Copy text"))
				when ODIN_OS == .Linux {
					if translation_eligible(ui, msg) {
						ctx_item("CtxTranslate", ICON_COMMENTS, tr("Translate"))
					}
				}
				if ui.prefs.tts_enabled {
					ctx_item("CtxRead", ICON_COMMENTS, tr("Read aloud"))
				}
			}
			if message_url(msg) != "" {
				ctx_item("CtxCopyLink", ICON_COPY, tr("Copy link"))
				ctx_item("CtxOpenLink", ICON_GLOBE, tr("Open link"))
			}
			ctx_item("CtxForward", ICON_FORWARD, tr("Forward"))
			for slot, i in msg.attachments {
				if slot.state == .Rejected {
					continue
				}
				ctx_item(
					fmt.tprintf("CtxSave%d", i),
					ICON_DOWNLOAD,
					fmt.tprintf(tr("Save %s"), slot.name),
				)
			}
			if !read_only {
				if nendo.box(nendo.id("CtxDangerRule"))(
				{
					width = nendo.grow(),
					height = nendo.fixed(1),
					padding = {top = 4, bottom = 4},
					color = BORDER_2,
				},
				) {}
				ctx_item("CtxDelMe", ICON_TRASH, tr("Delete for me"), DANGER)
				if msg.mine {ctx_item("CtxDelAll", ICON_BAN, tr("Delete for everyone"), DANGER)}
			}
		}
		if ui.prefs.dev_mode {
			ctx_item("CtxRaw", ICON_CODE, tr("View raw event"))
		}
	}
	scrollbar(nendo.id("CtxMenu"), 11)
}

// Edit-history modal: original first, each edit after, current
// highlighted.
@(private)
HISTORY_WIDTH :: f32(420)
@(private)
HISTORY_GUTTER :: u16(12)

edit_history_modal :: proc(ui: ^Ui_State) {
	history := ui.hist_versions[:]
	cards := gh_cards_on
	gh_cards_on = false
	defer {gh_cards_on = cards}

	if nendo.box(nendo.id("HistModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("HistModal"), HISTORY_WIDTH)),
		height = nendo.fit(max = modal_h(640)),
		padding = nendo.pad(16),
		gap = 10,
		floating = {
			attach_to = .Root,
			z = 11,
			offset = {0, rise(nendo.id("HistModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("HistHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Edit history"), {font = FONT_TITLE, size = 18, color = TEXT})
			if nendo.box(nendo.id("HistHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("HistClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 24),
				height = nendo.fixed(tap_size() ? tap_min() : 24),
				padding = nendo.pad(6),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(6),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}
		if ui.hist_ticket !=
		   0 {nendo.text(tr("Loading..."), {font = FONT_BODY, size = 13, color = TEXT_DIM})}
		edit_count := max(0, len(history) - (ui.hist_original ? 1 : 0))
		nendo.text(
			fmt.tprintf(tr(edit_count == 1 ? N_("%d edit") : N_("%d edits")), edit_count),
			{font = FONT_BODY, size = 11, color = TEXT_DIM},
		)

		if nendo.box(nendo.id("HistScroll"))(
		{
			width = nendo.grow(),
			height = nendo.fit(max = max(f32(1), modal_h(640) - 120)),
			direction = .Column,
			gap = 10,
			padding = {right = HISTORY_GUTTER},
			clip = {x = true, y = true, scroll = true},
		},
		) {
			for version, i in history {
				current := i == len(history) - 1
				if nendo.box(nendo.id("HistRow", u32(i)))(
				{
					width = nendo.grow(),
					direction = .Column,
					padding = nendo.pad(10),
					gap = 4,
					color = ROW_BG,
					radius = rr(10),
					border = current ? nendo.Border{color = ACCENT, width = bw()} : {},
				},
				) {
					if nendo.box(nendo.id("HistRowHead", u32(i)))(
					{width = nendo.grow(), align = {y = .Center}},
					) {
						label :=
							i == 0 && ui.hist_original ? tr("Original") : (current ? tr("Current") : fmt.tprintf(tr("Edit %d"), i + (ui.hist_original ? 0 : 1)))
						nendo.text(
							label,
							{font = FONT_TITLE, size = 12, color = current ? ACCENT : TEXT},
						)
						if nendo.box(nendo.id("HistRowGap", u32(i)))({width = nendo.grow()}) {}
						nendo.text(version.at, {font = FONT_BODY, size = 11, color = TEXT_LO})
					}
					if len(version.blocks) > 0 {
						md_blocks(
							version.blocks[:],
							0xD0000 + u32(i) * 0x10000,
							wrap_w = edit_diff_wrap(),
						)
					} else {
						body_text(
							0xD0000 + u32(i) * 8,
							version.text,
							13,
							TEXT,
							wrap_w = edit_diff_wrap(),
						)
					}
				}
			}
		}
		scrollbar(nendo.id("HistScroll"), 12)
	}
}

// Horizontal budget for a diff line: modal width minus card and row
// padding.
@(private)
edit_diff_wrap :: proc() -> f32 {
	return max(f32(1), modal_w(nendo.id("HistModal"), HISTORY_WIDTH) - 52 - f32(HISTORY_GUTTER))
}

RAW_MODAL_W :: f32(560)
RAW_FS :: u16(11)
RAW_PLATE_PAD :: f32(2 * 16 + 2 * 10) // modal padding plus the plate's

// Byte length of the first `n` runes of s, so a chunk never splits a
// rune in half.
rune_prefix :: proc(s: string, n: int) -> int {
	count := 0
	for _, i in s {
		if count == n {
			return i
		}
		count += 1
	}
	return len(s)
}

// One JSON line, split into runs of at most `cols` runes.
raw_line :: proc(line: string, cols: int) {
	rest := line
	for len(rest) > 0 {
		cut := rune_prefix(rest, cols)
		nendo.text(rest[:cut], {font = FONT_MONO, size = RAW_FS, color = TEXT, wrap = .None})
		rest = rest[cut:]
	}
}

// View-raw-event modal (dev mode): the record's JSON in mono, a
// scrollable plate, Copy. Esc/backdrop closes (handle_input).
raw_event_modal :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("RawModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("RawModal"), RAW_MODAL_W)),
		height = nendo.fixed(modal_h(480)),
		padding = nendo.pad(16),
		gap = 10,
		floating = {
			attach_to = .Root,
			z = 11,
			offset = {0, rise(nendo.id("RawModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("RawHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Raw event"), {font = FONT_TITLE, size = 18, color = TEXT})
			if nendo.box(nendo.id("RawHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("RawClose"))(
			{padding = nendo.pad(6), color = hovered() ? HOVER : {}, radius = rr(6)},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}

		if nendo.box(nendo.id("RawScroll"))(
		{
			width = nendo.grow(),
			height = nendo.grow(),
			direction = .Column,
			padding = nendo.pad(10),
			color = PLATE,
			radius = rr(8),
			clip = {y = true, scroll = true},
		},
		) {
			// A blossom URL or the escaped media_json is one unbroken
			// token, and nendo wraps on words only, so every line is
			// hard-chunked to the plate width and drawn on its own.
			cw := rl.MeasureTextLine(FONT_MONO, RAW_FS, "0", 0).x
			cols := max(8, int((fit_w(RAW_MODAL_W) - RAW_PLATE_PAD) / max(cw, 1)))
			rest := ui.raw_json
			for line in strings.split_lines_iterator(&rest) {
				raw_line(line, cols)
			}
		}
		scrollbar(nendo.id("RawScroll"), 12) // the modal floats at 11

		if nendo.box(nendo.id("RawActions"))({width = nendo.grow(), gap = 8}) {
			micro_button("RawCopy", tr("Copy"))
		}
	}
}

// The "what is this?" explainer opened by tapping the MLS badge in the
// chat header: what end-to-end MLS encryption means in plain language,
// plus the chat's MLS group id with a Copy button and the current MLS
// epoch.
encryption_modal :: proc(ui: ^Ui_State, chat: Chat_Row_Ui) {
	if nendo.box(nendo.id("EncModal"))(
	{
		width = nendo.fixed(modal_w(nendo.id("EncModal"), 440)),
		height = nendo.fit(max = modal_h(640)),
		direction = .Column,
		padding = nendo.pad(20),
		gap = 12,
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("EncModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		clip = {y = true, scroll = true},
	},
	) {
		if nendo.box(nendo.id("EncHead"))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			nendo.text(ICON_LOCK, {font = FONT_ICON, size = 16, color = ACCENT})
			nendo.text(tr("End-to-end encrypted"), {font = FONT_TITLE, size = 20, color = TEXT})
			if nendo.box(nendo.id("EncHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("EncClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 26),
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(7),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}
		nendo.text(
			tr(
				"Whatever you send in this chat is encrypted on your device with MLS before it goes out. The relays that pass it along can't read it, and neither can anyone else.",
			),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)

		eyebrow(tr("GROUP ID"))
		if nendo.box(nendo.id("EncFingerprint"))({width = nendo.grow(), align = {x = .Center}}) {
			crop_circle("EncCircle", 0, chat.group_id, 128)
		}
		if nendo.box(nendo.id("EncIdChip"))(
		{
			width = nendo.grow(),
			padding = nendo.pad(10),
			color = ROW_BG,
			radius = rr(8),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			nendo.text(chat.group_id, {font = FONT_MONO, size = 11, color = TEXT})
		}

		if len(ui.enc_epoch) > 0 {
			eyebrow(tr("ENCRYPTION REVISION"))
			nendo.text(ui.enc_epoch, {font = FONT_MONO, size = 11, color = TEXT})
			nendo.text(
				tr("This number increases when the group's encryption keys change."),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
		}

		if nendo.box(nendo.id("EncActions"))({width = nendo.grow(), gap = 8}) {
			micro_button("EncCopyId", tr("Copy group id"))
		}
	}
	scrollbar(nendo.id("EncModal"), 14)
}

// Cap the result list; offscreen rows retain geometry but no tile elements.
PICKER_MAX_CELLS :: 396
PICKER_CELL_W :: f32(30 + 2) // cell plus the row's childGap

// Columns that fit the panel at this window width. The flat 11 assumed
// the full 400px panel, which a window narrower than that never gets,
// so the last columns fell outside the panel. Measured from the
// unanimated width: sizing off modal_w would reshuffle the grid every
// frame of the open.
picker_cols :: proc() -> int {
	inner := single_pane() ? fit_w(400, 8) - 24 : fit_w(400) - 24 - 13
	return clamp(int((inner + 2) / (tap_size() ? 46 : PICKER_CELL_W)), 1, 11)
}

// Indices into emoji_catalog matching the picker search, capped.
picker_matches :: proc(ui: ^Ui_State) -> [dynamic]int {
	matches := make([dynamic]int, context.temp_allocator)
	filter := strings.to_lower(string(ui.picker_filter[:]), context.temp_allocator)
	shortcode := fmt.tprintf(":%s:", strings.trim(filter, ":"))
	// Names and exact shortcodes precede substring matches (fire before firefighter).
	for exact in ([2]bool{true, false}) {
		for entry, i in emoji_catalog {
			if len(entry.pixels) == 0 {continue}
			if len(filter) > 0 && !strings.contains(entry.name, filter) {continue}
			name, _, _ := strings.partition(entry.name, " :")
			is_exact :=
				len(filter) > 0 && (name == filter || strings.contains(entry.name, shortcode))
			if is_exact != exact {continue}
			append(&matches, i)
			if len(matches) >= PICKER_MAX_CELLS {return matches}
		}
	}
	return matches
}

// Dock magnification: the tile under the pointer grows, and its
// neighbours grow less the further out they sit. The cell itself keeps
// its 30px slot, so the grid never reflows under the hand crossing it.
PICK_REACH :: f32(64) // px at which the pointer stops lifting a tile
PICK_TILE :: f32(22)
PICK_LIFT :: f32(11) // px the tile gains directly under the pointer

@(private = "file")
picker_lift :: proc(id: nendo.Id) -> f32 {
	box, laid_out := element_box(id)
	if !laid_out || !motion_on() {
		return 0
	}
	pos := rl.GetMousePosition()
	dx := box.x + box.width / 2 - pos.x / UI_ZOOM
	dy := box.y + box.height / 2 - pos.y / UI_ZOOM
	near := max(0, 1 - math.sqrt(dx * dx + dy * dy) / PICK_REACH)
	return anim_to(anim_key(id.id, 4), near * near, 26) // squared: a peak, not a dome
}

picker_cell :: proc(id_str: string, index: u32, tex: ^rl.Texture2D, width: f32 = 0) {
	id := nendo.id(id_str, index)
	tile := PICK_TILE + PICK_LIFT * picker_lift(id)
	if nendo.box(id)(
	{
		width = nendo.fixed(width > 0 ? width : tap_size() ? tap_min() : 30),
		height = nendo.fixed(tap_size() ? tap_min() : 30),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(8),
	},
	) {
		if nendo.box(nendo.id_local("PkCellImg"))(
		{width = nendo.fixed(tile), aspect = 1, image = tex},
		) {}
	}
}

// Emoji picker: recents, search, and an emoji grid.
emoji_picker :: proc(ui: ^Ui_State) {
	gif := ui.gif_tab && ui.picker_target == "" && ui.picker_mode == .Message
	width := single_pane() ? fit_w(400, 8) : modal_w(nendo.id("PickerPanel"), gif ? 560 : 400)
	height := modal_h(
		single_pane() ? (ui.picker_mode == .Group_Image ? 560 : 480) : gif ? 540 : ui.picker_mode == .Group_Image ? 560 : 440,
	)
	x, y := ui.picker_x, ui.picker_y
	if gif || single_pane() && ui.picker_mode == .Message {
		if composer := nendo.element(nendo.id("ComposeBox")); composer.found {
			if single_pane() {height = min(height, max(120, composer.rect.y - 16))}
			x, y = composer.rect.x + composer.rect.width - width, composer.rect.y - height - 8
		}
	}
	x, y = panel_pos(x, y, width, height)
	if nendo.box(nendo.id("PickerPanel"))(
	{
		direction = .Column,
		width = nendo.fixed(width),
		height = nendo.fixed(height),
		padding = nendo.pad(12),
		gap = 8,
		floating = {attach_to = .Root, offset = {x, y + rise(nendo.id("PickerPanel"))}, z = 12},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if ui.picker_mode != .Group_Image {
			if nendo.box(nendo.id("PickerHead"))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
			) {
				if ui.picker_target !=
				   "" {nendo.text(tr("Add reaction"), {font = FONT_TITLE, size = 16, color = TEXT})}
				if nendo.box(nendo.id("PickerHeadGap"))({width = nendo.grow()}) {}
				if tap_size() {micro_button("PickerClose", tr("Close"))}
			}
		}
		if ui.picker_mode == .Group_Image {
			emoji_mix_header(ui)
		}
		if ui.picker_target == "" && ui.picker_mode == .Message {
			if nendo.box(nendo.id("PickerTabs"))({width = nendo.grow(), gap = 6}) {
				sticker_control(
					"PickerEmoji",
					0,
					tr("Emoji"),
					!ui.sticker_tab && !ui.gif_tab ? .Selected : .Normal,
				)
				sticker_control(
					"PickerStickers",
					0,
					tr("Stickers"),
					ui.sticker_tab ? .Selected : .Normal,
				)
				sticker_control("PickerGifs", 0, tr("GIFs"), ui.gif_tab ? .Selected : .Normal)
			}
			if ui.gif_tab {gif_picker(ui); return}
			if ui.sticker_tab {sticker_picker(ui); return}
		}
		eyebrow(tr("RECENT"))
		if nendo.box(nendo.id("PkRecentRow"))(
		{width = nendo.grow(), gap = 2, clip = {x = true, scroll = true}},
		) {
			for recent, i in ui.prefs.recent_emoji {
				if tex := emoji_tex(recent); tex != nil {
					picker_cell("PkRecent", u32(i), tex)
				}
			}
		}
		scrollbar(nendo.id("PkRecentRow"), 13)

		if nendo.box(nendo.id("PickerSearch"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(tap_size() ? tap_min() : 34),
			padding = {left = 10, right = 10},
			gap = 4,
			align = {y = .Center},
			color = ROW_BG,
			radius = rr(8),
			border = {color = ui.focus == .Picker ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(
				ui,
				"PickerSearch",
				&ui.picker_filter,
				tr("Search emoji..."),
				ui.focus == .Picker,
				13,
				TEXT_LO,
			)
		}

		if nendo.box(nendo.id("PickerGrid"))(
		{
			width = nendo.grow(),
			height = nendo.grow(min = tap_size() ? tap_min() : 0),
			direction = .Column,
			gap = 2,
			clip = {y = true, scroll = true},
		},
		) {
			// Custom :shortcode: emoji lead the grid; the search box
			// matches their codes too.
			// ponytail: one unwrapped row; wrap it if the set grows.
			custom := picker_custom(string(ui.picker_filter[:]))
			if len(custom) > 0 {
				if nendo.box(nendo.id("PkCustomRow"))(
				{width = nendo.grow(), gap = 2, clip = {x = true, scroll = true}},
				) {
					for code, k in custom {
						picker_cell("PkCustom", u32(k), custom_tex_by_code(code))
					}
				}
				scrollbar(nendo.id("PkCustomRow"), 13)
			}
			matches := picker_matches(ui)
			cols := picker_cols()
			view := nendo.scroll(nendo.id("PickerGrid"))
			top := view.found ? max(0, -view.position.y) : 0
			view_height := view.found && view.viewport.height > 0 ? view.viewport.height : height
			bottom := top + view_height
			step := tap_size() ? f32(46) : PICKER_CELL_W
			y := len(custom) > 0 ? step : 0
			if len(matches) == 0 && len(custom) == 0 {
				nendo.text(
					tr("No emoji match your search."),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
			}
			for row_start := 0; row_start < len(matches); row_start += cols {
				visible := y + step >= top - step && y <= bottom + step
				y += step
				if nendo.box(nendo.id("PkRow", u32(row_start)))(
				{gap = 2, height = nendo.fixed(step - 2)},
				) {
					// Empty rows retain scroll geometry without uploading offscreen tiles.
					if !visible {continue}
					for k in row_start ..< min(row_start + cols, len(matches)) {
						entry := emoji_catalog[matches[k]]
						cell_w :=
							single_pane() ? (width - 24 - f32(cols - 1) * 2) / f32(cols) : f32(0)
						picker_cell("PkCell", u32(matches[k]), emoji_tex(entry.emoji), cell_w)
					}
				}
			}
		}
		scrollbar(nendo.id("PickerGrid"), 13) // the panel floats at 12
	}
}

CHIP_FS :: u16(11)
CHIP_PAD :: f32(4) // 2px above and below the label

action_chip :: proc(id_str: string, index: u32, label: string) {
	down := press_down(nendo.id(id_str, index))
	if nendo.box(nendo.id(id_str, index))(
	{
		width = nendo.fit(min = tap_size() ? tap_min() : 0),
		height = nendo.fit(min = tap_size() ? tap_min() : 0),
		padding = {left = 8, right = 8, top = 2 + down, bottom = 2 - down},
		align = {x = .Center, y = .Center},
		color = hovered() ? ACCENT : ROW_BG,
		radius = rr(6),
	},
	) {
		nendo.text(label, {font = FONT_BODY, size = CHIP_FS, color = hovered() ? BG : TEXT_DIM})
	}
}

// How tall an action chip is. Rows that reveal chips on hover reserve
// this much up front, or every row would grow a few px as the pointer
// crossed it.
chip_h :: proc() -> f32 {
	return max(
		tap_size() ? tap_min() : 0,
		rl.MeasureTextLine(FONT_BODY, CHIP_FS, "A", 0).y + CHIP_PAD,
	)
}
