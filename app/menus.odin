package main

import "core:fmt"
import "core:math"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

ctx_item :: proc(id_str: string, glyph: string, label: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(32)}, padding = {left = 10, right = 16}, childGap = 9, childAlignment = {y = .Center}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(6),
	},
	) {
		if clay.UI(clay.ID_LOCAL("CtxGlyph"))({layout = {sizing = {width = clay.SizingFixed(16)}, childAlignment = {x = .Center}}}) {
			clay.Text(glyph, {fontId = FONT_ICON, fontSize = 13, textColor = hovered() ? TEXT : TEXT_DIM})
		}
		clay.Text(tr(label), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
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
	member := ui.members[member_menu_index(ui)]

	if clay.UI(clay.ID("MemberMenu"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFit({min = 190})}, padding = clay.PaddingAll(4), childGap = 1},
		floating = {attachTo = .Root, offset = {ui.member_menu_x, ui.member_menu_y + rise(clay.ID("MemberMenu"))}, zIndex = 10},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if member.is_self {
			if member.is_admin {
				ctx_item("MemberStepDown", ICON_BAN, "Step down")
			}
			return
		}
		ctx_item(member.is_admin ? "MemberDemote" : "MemberPromote", ICON_STAR, member.is_admin ? "Demote" : "Promote")
		ctx_item("MemberRemove", ICON_TRASH, "Remove")
		ctx_item("MemberNick", ICON_PENCIL, "Nickname")
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
	index := ui.member_menu
	member := ui.members[index]
	ui.member_menu = -1

	if member.is_self {
		if member.is_admin && clay.PointerOver(clay.ID("MemberStepDown")) {
			confirm_ask(ui, .Step_Down, member.id_hex, member.name)
		}
		return true
	}
	if clay.PointerOver(clay.ID(member.is_admin ? "MemberDemote" : "MemberPromote")) {
		confirm_ask(ui, member.is_admin ? .Demote : .Promote, member.id_hex, member.name)
		return true
	}
	if clay.PointerOver(clay.ID("MemberRemove")) {
		confirm_ask(ui, .Remove_Member, member.id_hex, member.name)
		return true
	}
	if clay.PointerOver(clay.ID("MemberNick")) {
		ui.member_nick = index
		ed_set(ui, &ui.nick_input, ui.nicknames[member.id_hex])
		ui.focus = .Nick
	}
	return true
}

// Right-click context menu for a message, the slint MessageContextMenu:
// quick-reaction strip, divider, then the gated action rows.
context_menu :: proc(ui: ^Ui_State) {
	msg := ui.messages[ui.ctx_msg]

	// The open-time clamp in handlers.odin guesses the height; re-clamp
	// against the box clay actually laid out, so a tall menu (own message,
	// attachments, dev mode) never runs past the window bottom.
	y := ui.ctx_y
	if box, laid_out := element_box(clay.ID("CtxMenu")); laid_out {
		y = min(y, f32(rl.GetScreenHeight()) / UI_ZOOM - box.height - 8)
	}

	if clay.UI(clay.ID("CtxMenu"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFit({min = 200})}, padding = clay.PaddingAll(4), childGap = 1},
		floating = {attachTo = .Root, offset = {ui.ctx_x, y + rise(clay.ID("CtxMenu"))}, zIndex = 10},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if !msg.deleted {
		if clay.UI(clay.ID("CtxStrip"))({layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}, childGap = 1}}) {
			for emoji, i in ui.prefs.quick_reactions {
				if clay.UI(clay.ID("CtxQuick", u32(i)))(
				{layout = {sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(8)},
				) {
					if tex := quick_tile(emoji); tex != nil {
						if clay.UI(clay.ID("CtxQuickImg", u32(i)))(
						{layout = {sizing = {width = clay.SizingFixed(18)}}, aspectRatio = {1}, image = {imageData = tex}},
						) {}
					} else {
						clay.Text(emoji, {fontId = FONT_BODY, fontSize = 14, textColor = TEXT})
					}
				}
			}
			if clay.UI(clay.ID("CtxQuickPlus"))(
			{layout = {sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(8)},
			) {
				clay.Text("+", {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
			}
		}

		// Divider band under the strip.
		if clay.UI(clay.ID("CtxDivBand"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(7)}, padding = {left = 6, right = 6, top = 3}}}) {
			if clay.UI(clay.ID("CtxDivLine"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = BORDER_2}) {}
		}

		// Same rows and gating as wiring/extra.rs builds (no text
		// selection here). A tombstone offers no action rows.
		ctx_item("CtxReact", ICON_SMILE, "Add reaction")
		if len(msg.thread_of) == 0 {
			ctx_item("CtxReply", ICON_REPLY, "Reply")
		}
		ctx_item("CtxThread", ICON_COMMENTS, "Reply in thread")
		ctx_item("CtxForward", ICON_FORWARD, "Forward")
		if len(msg.body) > 0 {
			ctx_item("CtxCopy", ICON_COPY, "Copy text")
		}
		for att_name, i in msg.att_names {
			ctx_item(fmt.tprintf("CtxSave%d", i), ICON_DOWNLOAD, fmt.tprintf("Save %s", att_name))
		}
		ctx_item("CtxDelMe", ICON_TRASH, "Delete for me")
		if msg.mine {
			ctx_item("CtxEdit", ICON_PENCIL, "Edit message")
			ctx_item("CtxDelAll", ICON_BAN, "Delete for everyone")
		}
		}
		if ui.prefs.dev_mode {
			ctx_item("CtxRaw", ICON_CODE, "View raw event")
		}
	}
}

// Edit-history modal, the slint edit-history pane: original first,
// each edit after, current highlighted.
edit_history_modal :: proc(ui: ^Ui_State) {
	msg := ui.messages[ui.hist_msg]

	if clay.UI(clay.ID("HistModal"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("HistModal"), 420))}, padding = clay.PaddingAll(16), childGap = 10},
		floating = {attachTo = .Root, zIndex = 11, offset = {0, rise(clay.ID("HistModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("HistHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text(tr("Edit history"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
			if clay.UI(clay.ID("HistHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("HistClose"))(
			{layout = {padding = clay.PaddingAll(6)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		edit_count := len(msg.history) - 1
		clay.Text(fmt.tprintf("%d edit%s", edit_count, edit_count == 1 ? "" : "s"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})

		for version, i in msg.history {
			current := i == len(msg.history) - 1
			if clay.UI(clay.ID("HistRow", u32(i)))(
			{
				layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(10), childGap = 4},
				backgroundColor = ROW_BG,
				cornerRadius = rr(10),
				border = current ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				if clay.UI(clay.ID("HistRowHead", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
					label := i == 0 ? "Original" : (current ? "Current" : fmt.tprintf("Edit %d", i))
					clay.Text(label, {fontId = FONT_TITLE, fontSize = 12, textColor = current ? ACCENT : TEXT})
					if clay.UI(clay.ID("HistRowGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
					clay.Text(version.at, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
				}
				if i == 0 {
					body_text(0xD0000 + u32(i) * 8, version.text, 13, TEXT, wrap_w = EDIT_DIFF_WRAP)
				} else {
					diff_chips(u32(i), msg.history[i - 1].text, version.text)
				}
			}
		}
	}
}

// Horizontal budget for a diff line: modal width minus card and row
// padding.
EDIT_DIFF_WRAP :: f32(360)

// Word diff against the previous revision, flowing as wrapped word
// chips: removed words on a danger-tinted plate in dim text, added on
// the accent surface (no strikethrough in this renderer, color plates
// carry the meaning).
diff_chips :: proc(version: u32, prev, next: string) {
	runs := diff_words(prev, next)
	if len(runs) == 0 {
		body_text(0xD0000 + version * 8, next, 13, TEXT, wrap_w = EDIT_DIFF_WRAP)
		return
	}

	// A single word wider than the line budget (a pasted token) splits
	// into rune-fit fragments so its chips wrap instead of overflowing.
	split := make([dynamic]Diff_Run, context.temp_allocator)
	for run in runs {
		at := 0
		for at < len(run.text) {
			cut := rune_fit(run.text, at, len(run.text), EDIT_DIFF_WRAP - 16, 13)
			append(&split, Diff_Run{run.kind, run.text[at:cut]})
			at = cut
		}
	}
	runs = split

	i := 0
	for line := u32(0); i < len(runs); line += 1 {
		if clay.UI(clay.ID("DiffLine", version * 64 + line))({layout = {childGap = 4, childAlignment = {y = .Center}}}) {
			w: f32
			for ; i < len(runs); i += 1 {
				run := runs[i]
				pad := run.kind == .Same ? f32(0) : 8
				cw := rl.MeasureTextLine(FONT_BODY, 13, run.text, 0).x + pad
				if w > 0 && w + cw > EDIT_DIFF_WRAP {
					break
				}
				w += cw + 4

				if run.kind == .Same {
					clay.Text(run.text, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
					continue
				}
				added := run.kind == .Added
				plate := added ? SELECTED : clay.Color{DANGER.r, DANGER.g, DANGER.b, 46}
				if clay.UI(clay.ID("DiffChip", version * 1024 + u32(i)))(
				{layout = {padding = {left = 4, right = 4, top = 1, bottom = 1}}, backgroundColor = plate, cornerRadius = rr(4)},
				) {
					clay.Text(run.text, {fontId = FONT_BODY, fontSize = 13, textColor = added ? ACCENT : TEXT_LO})
				}
			}
		}
	}
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
		clay.Text(rest[:cut], {fontId = FONT_MONO, fontSize = RAW_FS, textColor = TEXT, wrapMode = .None})
		rest = rest[cut:]
	}
}

// View-raw-event modal (dev mode): the record's JSON in mono, a
// scrollable plate, Copy. Esc/backdrop closes (handle_input).
raw_event_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("RawModal"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("RawModal"), RAW_MODAL_W)), height = clay.SizingFixed(modal_h(480))}, padding = clay.PaddingAll(16), childGap = 10},
		floating = {attachTo = .Root, zIndex = 11, offset = {0, rise(clay.ID("RawModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("RawHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text(tr("Raw event"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
			if clay.UI(clay.ID("RawHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("RawClose"))(
			{layout = {padding = clay.PaddingAll(6)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("RawScroll"))(
		{
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(10)},
			backgroundColor = PLATE,
			cornerRadius = rr(8),
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			// A blossom URL or the escaped media_json is one unbroken
			// token, and clay wraps on words only, so every line is
			// hard-chunked to the plate width and drawn on its own.
			cw := rl.MeasureTextLine(FONT_MONO, RAW_FS, "0", 0).x
			cols := max(8, int((fit_w(RAW_MODAL_W) - RAW_PLATE_PAD) / max(cw, 1)))
			rest := ui.raw_json
			for line in strings.split_lines_iterator(&rest) {
				raw_line(line, cols)
			}
		}
		scrollbar(clay.ID("RawScroll"), 12) // the modal floats at 11

		if clay.UI(clay.ID("RawActions"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
			micro_button("RawCopy", "Copy")
		}
	}
}

// The "what is this?" explainer opened by tapping the MLS badge in the
// chat header, the slint encryption-info modal: what end-to-end MLS
// encryption means in plain language, plus the chat's MLS group id with
// a Copy button and the current MLS epoch.
encryption_modal :: proc(ui: ^Ui_State, chat: Chat_Row_Ui) {
	if clay.UI(clay.ID("EncModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("EncModal"), 440))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("EncModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("EncHead"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
			clay.Text(ICON_LOCK, {fontId = FONT_ICON, fontSize = 16, textColor = ACCENT})
			clay.Text(tr("End-to-end encrypted"), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			if clay.UI(clay.ID("EncHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("EncClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		clay.Text(tr("Whatever you send in this chat is encrypted on your device with MLS before it goes out. The relays that pass it along can't read it, and neither can anyone else."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})

		eyebrow("GROUP ID")
		if clay.UI(clay.ID("EncIdChip"))(
		{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)}, backgroundColor = ROW_BG, cornerRadius = rr(8), border = {color = FIELD_BORDER, width = bw()}},
		) {
			clay.Text(chat.group_id, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
		}

		if len(ui.enc_epoch) > 0 {
			eyebrow("EPOCH")
			clay.Text(ui.enc_epoch, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
		}

		if clay.UI(clay.ID("EncActions"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
			micro_button("EncCopyId", "Copy")
		}
	}
}

// Cap on rendered picker cells; clay elements aren't virtualized, so
// the grid shows the first matches and search narrows the rest.
// ponytail: port ListView-style virtualization if the cap ever hurts.
PICKER_MAX_CELLS :: 396
PICKER_CELL_W :: f32(30 + 2) // cell plus the row's childGap

// Columns that fit the panel at this window width. The flat 11 assumed
// the full 400px panel, which a window narrower than that never gets,
// so the last columns fell outside the panel. Measured from the
// unanimated width: sizing off modal_w would reshuffle the grid every
// frame of the open.
picker_cols :: proc() -> int {
	inner := fit_w(400) - 24 - 13 // panel padding, then the scrollbar
	return clamp(int(inner / PICKER_CELL_W), 4, 11)
}

// Indices into emoji_catalog matching the picker search, capped.
picker_matches :: proc(ui: ^Ui_State) -> [dynamic]int {
	matches := make([dynamic]int, context.temp_allocator)
	filter := strings.to_lower(string(ui.picker_filter[:]), context.temp_allocator)
	for entry, i in emoji_catalog {
		if len(filter) > 0 && !strings.contains(entry.name, filter) {
			continue
		}
		if emoji_tex(entry.emoji) == nil {
			continue
		}
		append(&matches, i)
		if len(matches) >= PICKER_MAX_CELLS {
			break
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
picker_lift :: proc(id: clay.ElementId) -> f32 {
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

picker_cell :: proc(id_str: string, index: u32, tex: ^rl.Texture2D) {
	id := clay.ID(id_str, index)
	tile := PICK_TILE + PICK_LIFT * picker_lift(id)
	if clay.UI(id)(
	{layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(30)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(8)},
	) {
		if clay.UI(clay.ID_LOCAL("PkCellImg"))(
		{layout = {sizing = {width = clay.SizingFixed(tile)}}, aspectRatio = {1}, image = {imageData = tex}},
		) {}
	}
}

// Emoji picker, the slint EmojiPicker: recents, search, Twemoji grid.
emoji_picker :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PickerPanel"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("PickerPanel"), 400)), height = clay.SizingFixed(modal_h(440))}, padding = clay.PaddingAll(12), childGap = 8},
		floating = {attachTo = .Root, offset = {ui.picker_x, ui.picker_y + rise(clay.ID("PickerPanel"))}, zIndex = 12},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		eyebrow("RECENT")
		if clay.UI(clay.ID("PkRecentRow"))({layout = {childGap = 2}}) {
			for recent, i in ui.recent_emoji {
				if tex := emoji_tex(recent); tex != nil {
					picker_cell("PkRecent", u32(i), tex)
				}
			}
		}

		if clay.UI(clay.ID("PickerSearch"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)}, padding = {left = 10, right = 10}, childGap = 4, childAlignment = {y = .Center}},
			backgroundColor = ROW_BG,
			cornerRadius = rr(8),
			border = {color = ui.focus == .Picker ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(ui, "PickerSearch", &ui.picker_filter, "search...", ui.focus == .Picker, 13, TEXT_LO)
		}

		if clay.UI(clay.ID("PickerGrid"))(
		{
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			// Custom :shortcode: emoji lead the grid; the search box
			// matches their codes too.
			// ponytail: one unwrapped row; wrap it if the set grows.
			custom := picker_custom(ui)
			if len(custom) > 0 {
				if clay.UI(clay.ID("PkCustomRow"))({layout = {childGap = 2}}) {
					for code, k in custom {
						picker_cell("PkCustom", u32(k), custom_tex_by_code(code))
					}
				}
			}
			matches := picker_matches(ui)
			cols := picker_cols()
			for row_start := 0; row_start < len(matches); row_start += cols {
				if clay.UI(clay.ID("PkRow", u32(row_start)))({layout = {childGap = 2}}) {
					for k in row_start ..< min(row_start + cols, len(matches)) {
						entry := emoji_catalog[matches[k]]
						picker_cell("PkCell", u32(matches[k]), emoji_tex(entry.emoji))
					}
				}
			}
		}
		scrollbar(clay.ID("PickerGrid"), 13) // the panel floats at 12
	}
}

CHIP_FS :: u16(11)
CHIP_PAD :: f32(4) // 2px above and below the label

action_chip :: proc(id_str: string, index: u32, label: string) {
	down := press_down(clay.ID(id_str, index))
	if clay.UI(clay.ID(id_str, index))(
	{layout = {padding = {left = 8, right = 8, top = 2 + down, bottom = 2 - down}}, backgroundColor = hovered() ? ACCENT : ROW_BG, cornerRadius = rr(6)},
	) {
		clay.Text(label, {fontId = FONT_BODY, fontSize = CHIP_FS, textColor = hovered() ? BG : TEXT_DIM})
	}
}

// How tall an action chip is. Rows that reveal chips on hover reserve
// this much up front, or every row would grow a few px as the pointer
// crossed it.
chip_h :: proc() -> f32 {
	return rl.MeasureTextLine(FONT_BODY, CHIP_FS, "A", 0).y + CHIP_PAD
}

