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
			if !read_only && message_can_edit(msg) {
				ctx_item("CtxEdit", ICON_PENCIL, tr("Edit message"))
			}
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
			if !msg.unsupported {ctx_item("CtxForward", ICON_FORWARD, tr("Forward"))}
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

PICKER_CELL :: f32(30)
PICKER_GAP :: u16(2)
PICKER_PAD :: u16(8)
PICKER_GUTTER :: f32(14)
@(private = "file")
PICKER_RAIL_INSET :: u16(PICKER_GUTTER) + PICKER_PAD
@(private = "file")
PICKER_RAIL_EXTRA :: f32(2 * PICKER_RAIL_INSET)

@(private)
picker_side :: proc() -> f32 {
	return tap_size() ? tap_min() : PICKER_CELL
}

@(private)
picker_composer :: proc(ui: ^Ui_State) -> bool {
	return ui.picker_mode == .Message && ui.picker_target == ""
}

@(private)
picker_media :: proc(ui: ^Ui_State) -> bool {
	return picker_composer(ui) && (ui.gif_tab || ui.sticker_tab)
}

@(private)
picker_query :: proc(ui: ^Ui_State) -> string {
	return strings.trim(strings.trim_space(string(ui.picker_filter[:])), ":")
}

@(private)
picker_matches :: proc(ui: ^Ui_State) -> []int {
	query := picker_query(ui)
	if query == "" {
		if picker_pack_at(ui.picker_pack, ui.picker_pack_revision) != nil {return nil}
		return emoji_group_rows[ui.picker_group][:]
	}
	filter := strings.to_lower(query, context.temp_allocator)
	shortcode := fmt.tprintf(":%s:", filter)
	exact, partial :=
		make([dynamic]int, context.temp_allocator), make([dynamic]int, context.temp_allocator)
	for entry, i in emoji_catalog {
		if len(entry.pixels) == 0 || !strings.contains(entry.name, filter) {continue}
		name, _, _ := strings.partition(entry.name, " :")
		if name == filter || strings.contains(entry.name, shortcode) {
			append(&exact, i)
		} else {
			append(&partial, i)
		}
	}
	append(&exact, ..partial[:])
	return exact[:]
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

@(private = "file")
picker_cell :: proc(id: nendo.Id, art: Picker_Art, width: f32, ring: nendo.Border = {}) {
	if art.pending {anim_moving += 1}
	side := picker_side()
	tile :=
		art.pending ? PICK_TILE * 0.7 : tap_size() ? 26 : PICK_TILE + PICK_LIFT * picker_lift(id)
	if nendo.box(id)(
	{
		width = nendo.fixed(width),
		height = nendo.fixed(side),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(8),
		border = ring,
		inert = art.pending,
	},
	) {
		if nendo.box(nendo.id_local("PkCellImg"))(
		{
			width = nendo.fixed(tile),
			aspect = 1,
			image = art.tex,
			color = art.pending ? ROW_BG : {},
			radius = rr(4),
		},
		) {}
	}
}

@(private)
PICKER_CATEGORIES := [Emoji_Group]struct {
	icon, label: string,
} {
	.Custom     = {"\uf005", N_("Custom emoji")},
	.Marmot     = {"\uf1b0", N_("Marmot")},
	.Smileys    = {ICON_SMILE, N_("Smileys and emotion")},
	.People     = {"\uf0c0", N_("People and body")},
	.Nature     = {"\uf1b0", N_("Animals and nature")},
	.Food       = {"\uf2e7", N_("Food and drink")},
	.Travel     = {"\uf072", N_("Travel and places")},
	.Activities = {"\uf091", N_("Activities")},
	.Objects    = {"\uf0eb", N_("Objects")},
	.Symbols    = {"\uf292", N_("Symbols")},
	.Flags      = {"\uf024", N_("Flags")},
}

@(private)
PICKER_PACK_START :: int(Emoji_Group.Smileys)

@(private)
picker_category_at :: proc(at, packs: int) -> int {
	if at < PICKER_PACK_START {return at}
	if at < PICKER_PACK_START + packs {return len(PICKER_CATEGORIES) + at - PICKER_PACK_START}
	return at - packs
}

@(private)
emoji_picker :: proc(ui: ^Ui_State) {
	phone := single_pane()
	composer := picker_composer(ui)
	media := picker_media(ui)
	sheet := phone && !media
	screen_w, screen_h := f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM
	width := sheet ? screen_w : fit_w(400)
	height := modal_h(ui.picker_mode == .Group_Image ? 560 : 440)
	compact := sheet && ui.focus == .Picker && touch_field.id != 0 && screen_h < 380
	padding := media ? u16(12) : PICKER_PAD
	pad := f32(padding)
	side := picker_side()
	x, y := ui.picker_x, ui.picker_y
	if sheet {
		if ui.picker_mode != .Group_Image {
			min_rows := compact ? 2 : composer ? 4 : 3
			min_height := f32(min_rows) * (side + pad) + pad
			height = min(
				screen_h,
				compact ? min_height + 12 : clamp(screen_h * 0.57, min_height, 480),
			)
		}
		x, y = 0, max(0, screen_h - (composer ? 0 : sheet_bottom()) - height)
	} else {
		if media {
			width =
				phone ? fit_w(400, 8) : modal_w(nendo.id("PickerPanel"), ui.gif_tab ? 560 : 400)
			height = modal_h(phone ? 480 : ui.gif_tab ? 540 : 440)
			if box := nendo.element(nendo.id("ComposeBox")); (phone || ui.gif_tab) && box.found {
				if phone {height = min(height, max(120, box.rect.y - 16))}
				x, y = box.rect.x + box.rect.width - width, box.rect.y - height - 8
			}
		} else if composer {
			left := f32(8)
			if card := nendo.element(nendo.id("MainCard")); card.found {
				left = card.rect.x + 8
				width = min(width, card.rect.width - 16)
			}
			if anchor := nendo.element(nendo.id("EmojiBtn")); anchor.found {
				x, y =
					max(left, anchor.rect.x + anchor.rect.width - width),
					anchor.rect.y -
					height -
					8
			}
		}
		if ui.picker_mode == .Message {
			if head := nendo.element(nendo.id("ChatHeader")); head.found {
				top := head.rect.y + head.rect.height + 8
				limit := screen_h - 8
				if box := nendo.element(nendo.id("ComposeBox"));
				   composer && box.found {limit = box.rect.y - 8}
				control_h := max(side, 34)
				min_height := side + 4 * pad + (composer ? 2 : 1) * control_h + 22
				height = min(height, max(media ? 220 : min_height, limit - top))
				y = max(top, min(y, limit - height))
			}
		}
		x, y = panel_pos(x, y, width, height)
	}
	docked := sheet && composer
	if nendo.box(nendo.id("PickerPanel"))(
	{
		direction = .Column,
		width = nendo.fixed(width),
		height = nendo.fixed(height),
		padding = nendo.pad(padding),
		gap = PICKER_PAD,
		floating = docked ? {} : {attach_to = .Root, offset = {x, y + rise(nendo.id("PickerPanel"))}, z = 12},
		color = CARD,
		radius = sheet ? {rr(12).top_left, rr(12).top_right, 0, 0} : rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if ui.picker_mode == .Group_Image {emoji_mix_header(ui)}
		if media && tap_size() {
			if nendo.box(nendo.id("PickerHead"))({width = nendo.grow()}) {
				if nendo.box()({width = nendo.grow()}) {}
				micro_button("PickerClose", tr("Close"))
			}
		}
		if composer && !compact {
			if nendo.box(nendo.id("PickerTabs"))(
			{width = nendo.grow(), gap = 6, align = {y = .Center}},
			) {
				sticker_control("PickerEmoji", 0, tr("Emoji"), !media ? .Selected : .Normal)
				sticker_control(
					"PickerStickers",
					0,
					tr("Stickers"),
					ui.sticker_tab ? .Selected : .Normal,
				)
				sticker_control("PickerGifs", 0, tr("GIFs"), ui.gif_tab ? .Selected : .Normal)
			}
			if ui.gif_tab {gif_picker(ui, {width - 2 * pad, height}); return}
			if ui.sticker_tab {sticker_picker(ui, {width - 2 * pad, height}); return}
		}
		if ui.picker_target != "" && !compact {
			nendo.text(tr("Add reaction"), {font = FONT_TITLE, size = 16, color = TEXT})
		}
		if !sheet {picker_search(ui)}
		if nendo.box(nendo.id("PickerBody"))(
		{width = nendo.grow(), height = nendo.grow(), gap = PICKER_PAD},
		) {
			if !sheet {picker_categories(ui)}
			grid_w :=
				width - 2 * pad - (sheet ? 0 : side + PICKER_RAIL_EXTRA + pad) - PICKER_GUTTER
			picker_grid(ui, grid_w, height)
		}
		if sheet {
			picker_search(ui)
			if !compact {picker_categories(ui)}
		}
	}
}

@(private = "file")
picker_categories :: proc(ui: ^Ui_State) {
	sheet := single_pane()
	id := nendo.id("PickerCategories")
	side := picker_side()
	inset := sheet ? 0 : PICKER_RAIL_INSET
	if nendo.box(id)(
	{
		width = sheet ? nendo.grow() : nendo.fixed(side + PICKER_RAIL_EXTRA),
		height = sheet ? nendo.fixed(side) : nendo.grow(),
		direction = sheet ? .Row : .Column,
		gap = PICKER_GAP,
		padding = {left = inset, right = inset},
		clip = {x = sheet, y = !sheet, scroll = true},
	},
	) {
		selected := int(ui.picker_group)
		if picker_pack_at(ui.picker_pack, ui.picker_pack_revision) != nil {
			selected = len(PICKER_CATEGORIES) + ui.picker_pack - 1
		}
		if picker_query(ui) != "" {selected = -1}
		packs := len(picker_emoji_packs)
		for at in 0 ..< len(PICKER_CATEGORIES) + packs {
			index := picker_category_at(at, packs)
			if index >= len(PICKER_CATEGORIES) {
				pack := &picker_emoji_packs[index - len(PICKER_CATEGORIES)]
				picker_category_button(
					index,
					selected,
					"\uf1b2",
					pack.title,
					picker_pack_art(pack.sample),
				)
				continue
			}
			group := Emoji_Group(index)
			category := PICKER_CATEGORIES[group]
			art := group == .Marmot ? picker_shortcode_tex(MARMOT_EMOJI) : Picker_Art{}
			picker_category_button(index, selected, category.icon, tr(category.label), art)
		}
	}
	scrollbar(id, 13)
}

@(private = "file")
picker_category_button :: proc(index, selected: int, glyph, label: string, art: Picker_Art = {}) {
	active := index == selected
	side := picker_side()
	if nendo.box(nendo.id("PickerCategory", u32(index)))(
	{
		width = nendo.fixed(side),
		height = nendo.fixed(side),
		align = {x = .Center, y = .Center},
		color = active ? SELECTED : hovered() ? HOVER : {},
		radius = rr(7),
	},
	) {
		if art.tex != nil || art.pending {
			w, h := f32(16), f32(16)
			if art.tex != nil {
				w, h = f32(art.tex.width), f32(art.tex.height)
				scale := min(side - 12, 26) / max(w, h)
				w, h = w * scale, h * scale
			}
			if nendo.box(nendo.id_local("PickerCategoryArt"))(
			{
				width = nendo.fixed(w),
				height = nendo.fixed(h),
				image = art.tex,
				color = art.pending ? ROW_BG : {},
				radius = rr(4),
			},
			) {}
		} else {
			nendo.text(glyph, {font = FONT_ICON, size = 16, color = active ? ACCENT : TEXT_DIM})
		}
		if hovered() && !rl.TouchActive() {
			pack := index >= len(PICKER_CATEGORIES)
			caption := label
			if pack {
				width := min(280, f32(rl.GetScreenWidth()) / UI_ZOOM - 24)
				height := f32(rl.GetScreenHeight()) / UI_ZOOM - 16
				line_height := max(1, rl.MeasureTextLine(FONT_BODY, 11, "A", 0).y)
				caption = picker_pack_title(
					label,
					width,
					FONT_BODY,
					11,
					clamp(int(height / line_height), 1, 4),
				)
			}
			tooltip(caption, single_pane() ? .Above : pack ? .Right : .Below)
		}
	}
}

@(private = "file")
picker_pack_title :: proc(title: string, width: f32, font, size: u16, line_cap := 0) -> string {
	if rl.MeasureTextLine(font, size, title, 0).x <= width {return title}
	lines := strings.builder_make(context.temp_allocator)
	for at, line := 0, 1; at < len(title); line += 1 {
		if at != 0 {strings.write_byte(&lines, '\n')}
		if line == line_cap {
			strings.write_string(&lines, text_ellipsis(title[at:], width, font, size))
			break
		}
		cut := wrap_break(title, at, len(title), width, size, .Plain, plain_font = font)
		strings.write_string(&lines, title[at:cut])
		at = cut
		if at < len(title) && title[at] == ' ' {at += 1}
	}
	return strings.to_string(lines)
}

@(private = "file")
picker_search :: proc(ui: ^Ui_State) {
	editing :=
		ui.focus == .Picker &&
		ui.picker_selection.id == 0 &&
		(!rl.HasTouch() || touch_field.id != 0)
	if nendo.box(nendo.id("PickerSearchRow"))(
	{width = nendo.grow(), gap = PICKER_PAD, align = {y = .Center}},
	) {
		if nendo.box(nendo.id("PickerSearch"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(tap_size() ? tap_min() : 34),
			padding = {left = 10, right = 10},
			gap = 8,
			align = {y = .Center},
			color = ROW_BG,
			radius = rr(8),
			border = {color = editing ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 12, color = TEXT_LO})
			field_text(
				ui,
				"PickerSearch",
				&ui.picker_filter,
				tr("Search emoji..."),
				editing,
				13,
				TEXT_LO,
			)
		}
		if len(ui.picker_filter) != 0 {
			side := tap_size() ? tap_min() : f32(34)
			if nendo.box(nendo.id("PickerClear"))(
			{
				width = nendo.fixed(side),
				height = nendo.fixed(side),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : ROW_BG,
				radius = rr(8),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 13, color = TEXT_LO})
				if hovered() && !rl.TouchActive() {tooltip(tr("Clear search"))}
			}
		}
		if tap_size() {micro_button("PickerClose", tr("Close"))}
	}
}

@(private = "file")
picker_grid :: proc(ui: ^Ui_State, width, height: f32) {
	grid := nendo.id("PickerGrid")
	query := picker_query(ui)
	query_id := nendo.id(query).id
	restoring := query == "" && query_id != ui.picker_query_id
	custom_row := nendo.id("PkCustomRow")
	if query_id != ui.picker_query_id {
		if ui.picker_query_id == nendo.id("").id {
			ui.picker_browse_scroll = {}
			if scroll := nendo.scroll(grid);
			   scroll.found {ui.picker_browse_scroll.y = scroll.position.y}
			if scroll := nendo.scroll(nendo.id("PkRecentRow"));
			   scroll.found {ui.picker_browse_scroll.x = scroll.position.x}
		}
		if scroll := nendo.scroll(grid); scroll.found {
			scroll.position.y = restoring ? ui.picker_browse_scroll.y : 0
		}
		ui.picker_query_id = query_id
		ui.picker_selection = {}
		if query != "" {
			if scroll := nendo.scroll(custom_row); scroll.found {scroll.position.x = 0}
		}
	}
	matches := picker_matches(ui)
	custom, revision := picker_custom_matches(ui)
	if ui.picker_selection.label == "PkCustom" {
		present := false
		if ui.picker_custom_revision == revision {
			for entry in custom {
				if entry.slot == ui.picker_selection.offset {present = true; break}
			}
		}
		if !present {ui.picker_selection = {}}
	}
	ui.picker_custom_revision = revision
	side := picker_side()
	gap := f32(PICKER_GAP)
	cols := max(1, int((width + gap) / (side + gap)))
	ui.picker_columns = cols
	cell_w := max(side, (width + gap) / f32(cols) - gap)
	grid_custom := query == "" ? len(custom) : 0
	if nendo.box(grid)(
	{
		width = nendo.grow(),
		height = nendo.grow(min = 1, max = height),
		direction = .Column,
		padding = {right = u16(PICKER_GUTTER)},
		gap = PICKER_GAP,
		clip = {y = true, scroll = true},
	},
	) {
		if query == "" {
			if nendo.box(nendo.id("PickerBrowseHead"))(
			{width = nendo.grow(), direction = .Column, gap = 4},
			) {
				pack := picker_pack_at(ui.picker_pack, ui.picker_pack_revision)
				if ui.picker_group == .Custom && pack == nil && len(ui.prefs.recent_emoji) != 0 {
					eyebrow(tr("RECENT"))
					recent_row := nendo.id("PkRecentRow")
					if nendo.box(recent_row)(
					{width = nendo.grow(), gap = PICKER_GAP, clip = {x = true, scroll = true}},
					) {
						if restoring {
							if scroll := nendo.scroll(recent_row);
							   scroll.found {scroll.position.x = ui.picker_browse_scroll.x}
						}
						for recent, i in ui.prefs.recent_emoji {
							if art := picker_emoji_tex(recent); art.tex != nil || art.pending {
								picker_cell(nendo.id("PkRecent", u32(i)), art, side)
							}
						}
					}
					scrollbar(recent_row, 13)
				}
				label :=
					pack != nil ? picker_pack_title(pack.title, width, FONT_TITLE, 14) : text_ellipsis(tr(PICKER_CATEGORIES[ui.picker_group].label), width, FONT_TITLE, 14)
				nendo.text(label, {font = FONT_TITLE, size = 14, color = TEXT, wrap = .Newlines})
			}
		}
		if len(custom) > grid_custom {
			x := nendo.scroll(custom_row)
			picker_custom_row(custom, width, side, x.found ? x.position.x : 0, ui.picker_selection)
		}
		if len(matches) == 0 && len(custom) == 0 {
			nendo.text(
				query == "" ? tr("No emoji available.") : tr("No emoji match your search."),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
		}
		tiles := len(matches) + grid_custom
		count := (tiles + cols - 1) / cols
		rows := nendo.virtual_rows(nendo.id("PickerRows"), count, side, gap = PICKER_GAP)
		for row in rows.first ..< rows.end {
			start := row * cols
			if nendo.box(nendo.id("PkRow", u32(start)))(
			{height = nendo.fixed(side), gap = PICKER_GAP},
			) {
				for at in start ..< min(start + cols, tiles) {
					id: nendo.Id
					art: Picker_Art
					if at < grid_custom {
						slot := custom[at].slot
						id, art = nendo.id("PkCustom", slot), picker_custom_tex(slot)
					} else {
						index := matches[at - grid_custom]
						id, art =
							nendo.id("PkCell", u32(index)),
							picker_emoji_tex(emoji_catalog[index].emoji)
					}
					picker_cell(id, art, cell_w, ui.picker_selection == id ? kb_ring(ACCENT) : {})
				}
			}
		}
	}
	scrollbar(grid, 13)
}

@(private = "file")
picker_custom_row :: proc(
	custom: []Picker_Custom,
	width, side, scroll_x: f32,
	selection: nendo.Id,
) {
	id := nendo.id("PkCustomRow")
	step := side + f32(PICKER_GAP)
	left := clamp(-scroll_x, 0, max(0, f32(len(custom)) * step - f32(PICKER_GAP) - width))
	right := left + width
	if nendo.box(id)({width = nendo.grow(), gap = PICKER_GAP, clip = {x = true, scroll = true}}) {
		if view := nendo.scroll(id); view.found {view.position.x = -left}
		for entry, at in custom {
			x := f32(at) * step
			// Keep the full scroll extent, but do not queue clipped artwork.
			art := x < right && x + side > left ? picker_custom_tex(entry.slot) : Picker_Art{}
			tile := nendo.id("PkCustom", entry.slot)
			picker_cell(tile, art, side, selection == tile ? kb_ring(ACCENT) : {})
		}
	}
	scrollbar(id, 13)
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
