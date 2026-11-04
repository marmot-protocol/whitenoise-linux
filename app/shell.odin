// Shell chrome: the boot splash, the bottom status bar and its
// dismissible message banner, transient toasts, hover tooltips, the
// draggable gutters, the tray tooltip, and the single-instance lock.
//
// Everything here frames the app rather than belonging to a page, which
// is why it sits in one file instead of being sprinkled through the
// panes.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:sys/windows"

_ :: linux
_ :: windows
_ :: posix

import "nendo"
import rl "sdlrl"

// ── Gutters ─────────────────────────────────────────────────────────

RAIL_W_DEFAULT :: 340
// Total sidebar width, including the persistent navigation column.
// The list needs at least 240px for a name, preview, and row actions.
RAIL_W_MIN :: 300
RAIL_W_MAX :: 560
RAIL_W_COLLAPSED :: 60
// The compact chat header drops its avatar and badge at narrow widths.
// Reserve a usable conversation, not the full-width header: at the default
// 1024-point window and 1.5x zoom the page beside the rail has 337 units.
PAGE_W_MIN :: f32(320)

PANEL_W_DEFAULT :: 280
PANEL_W_MIN :: 220
PANEL_W_MAX :: 460

GUTTER_W :: 6

// Which gutter the pointer is dragging, "" = none. The width follows
// the pointer while held and persists on release.
gutter_drag: string

// A 6px grab strip between two panes; handle_gutters owns which pref
// each id writes.
gutter :: proc(id_str: string) {
	active := gutter_drag == id_str
	if nendo.box(nendo.id(id_str))(
	{width = nendo.fixed(GUTTER_W), height = nendo.grow(), align = {x = .Center, y = .Center}},
	) {
		if nendo.box(nendo.id_local("GutterLine"))(
		{
			width = nendo.fixed(2),
			height = nendo.fixed(40),
			color = active || hovered() ? ACCENT : FIELD_BORDER,
			radius = rr(1),
		},
		) {}
	}
}

// Run the two gutter drags. Called after layout, so nendo's boxes are
// this frame's.
handle_gutters :: proc(ui: ^Ui_State) {
	if rl.IsMouseButtonPressed(.LEFT) {
		if nendo.pointer_over(nendo.id("RailGutter")) {
			gutter_drag = "RailGutter"
		}
	}
	if gutter_drag == "" {
		return
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		gutter_drag = ""
		save_settings(ui)
		return
	}

	mx := rl.GetMousePosition().x / UI_ZOOM
	switch gutter_drag {
	case "RailGutter":
		// The connected sidebar starts at the window's left edge.
		ui.prefs.rail_w = clamp(int(mx), RAIL_W_MIN, RAIL_W_MAX)
	}
}

@(private)
rail_fits :: proc(window_w: f32, rail_w: int) -> bool {
	return window_w - f32(clamp(rail_w, RAIL_W_MIN, RAIL_W_MAX)) - GUTTER_W >= PAGE_W_MIN
}

rail_width :: proc(ui: ^Ui_State) -> f32 {
	// One pane at a time: the sidebar is either the whole window or gone,
	// and neither width is draggable, so the eased path is skipped.
	if single_pane() {
		if phone_detail(ui) {
			return 0
		}
		return f32(rl.GetScreenWidth()) / UI_ZOOM
	}
	// Standalone pages leave the saved sidebar width and animation
	// untouched so returning to another tab restores its layout.
	if ui.page == .Archived || ui.page == .Settings {
		return RAIL_W_COLLAPSED
	}
	// Resize immediately; preserving the pref restores the list when it fits.
	if !ui.rail_peek && !rail_fits(f32(rl.GetScreenWidth()) / UI_ZOOM, ui.prefs.rail_w) {
		anim_set(nendo.id("RailWidth").id, RAIL_W_COLLAPSED)
		return RAIL_W_COLLAPSED
	}
	target := ui.prefs.rail_collapsed ? f32(RAIL_W_COLLAPSED) : rail_full_w(ui)
	// Dragging the gutter must track the pointer exactly; only the
	// collapse toggle animates. Pin the entry too, or release replays
	// the drag from its starting width.
	if gutter_drag != "" {
		anim_set(nendo.id("RailWidth").id, target)
		return target
	}
	return anim_to(nendo.id("RailWidth").id, target, 20)
}

// Width of the open rail. Opened by hand in a window too narrow for the
// saved width beside a full page card, it gives up the excess down to
// its minimum and the page card takes the squeeze.
@(private)
rail_full_w :: proc(ui: ^Ui_State) -> f32 {
	full := f32(clamp(ui.prefs.rail_w, RAIL_W_MIN, RAIL_W_MAX))
	if !ui.rail_peek {
		return full
	}
	room := f32(rl.GetScreenWidth()) / UI_ZOOM - GUTTER_W - PAGE_W_MIN
	return min(full, max(f32(RAIL_W_MIN), room))
}

// The collapse button and palette command. A window too narrow for the
// list beside the page collapses it on its own; expanding there opens
// it anyway (rail_peek) until the user collapses it again. Pages that
// pin the rail shut (one-card, Archived, Settings) render no button and
// only flip the pref, since their rail width says nothing about it.
@(private)
toggle_rail :: proc(ui: ^Ui_State) {
	if single_pane() || ui.page == .Archived || ui.page == .Settings {
		ui.rail_peek = false
		ui.prefs.rail_collapsed = !ui.prefs.rail_collapsed
	} else if rail_narrow(ui) {
		ui.rail_peek = !rail_fits(f32(rl.GetScreenWidth()) / UI_ZOOM, ui.prefs.rail_w)
		ui.prefs.rail_collapsed = false
	} else {
		ui.rail_peek = false
		ui.prefs.rail_collapsed = true
	}
	save_settings(ui)
}

// How open the rail is: 0 collapsed, 1 at its full width. Everything
// inside reads this instead of the pref, so the list leaves with the
// width instead of vanishing the frame the toggle flips.
rail_open :: proc(ui: ^Ui_State) -> f32 {
	full := rail_full_w(ui)
	if full <= RAIL_W_COLLAPSED {
		return 0
	}
	return clamp((rail_width(ui) - RAIL_W_COLLAPSED) / (full - RAIL_W_COLLAPSED), 0, 1)
}

// Past halfway shut: where the rail stops being a list and becomes an
// icon column.
rail_narrow :: proc(ui: ^Ui_State) -> bool {
	return rail_open(ui) < 0.5
}

// Destinations stay in one column whether the conversation list is open
// or collapsed. Existing IDs keep shortcuts and account switching intact.
@(private)
shell_navigation :: proc(ui: ^Ui_State) {
	if single_pane() {return}
	if nendo.box(nendo.id("RailTop"))(
	{
		width = nendo.fixed(RAIL_W_COLLAPSED),
		height = nendo.grow(),
		direction = .Column,
		padding = {top = 14, bottom = 12},
		gap = 8,
		align = {x = .Center},
		color = BG,
		clip = {y = true, scroll = true},
	},
	) {
		avatar(
			"RailAvatar",
			0,
			ui.account_ref,
			profile_label(nil, ui.account_ref),
			36,
			url_pic(ui.my_pic_url),
		)
		if nendo.box(nendo.id("RailDivider"))(
		{width = nendo.fixed(28), height = nendo.fixed(1), color = DIVIDER},
		) {}
		for page in ([3]Page{.Chats, .Contacts, .Archived}) {
			nav_button(page, ui.page == page)
		}
		if !single_pane() && ui.page != .Archived && ui.page != .Settings {
			if nendo.box(nendo.id("RailCollapse"))(
			{
				width = nendo.fixed(42),
				height = nendo.fixed(32),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(10),
			},
			) {
				collapsed := rail_narrow(ui)
				if hovered() {
					tooltip(
						collapsed ? tr("Expand the chat list") : tr("Collapse the chat list"),
						.Right,
					)
				}
				nendo.text(
					collapsed ? "›" : "‹",
					{font = FONT_TITLE, size = 18, color = TEXT_DIM},
				)
			}
		}
		if nendo.box(nendo.id("RailTopGap"))({height = nendo.grow()}) {}
		nav_button(.Profile, ui.page == .Profile)
		nav_button(.Settings, ui.page == .Settings)
		nav_indicator(ui)
	}
	scrollbar(nendo.id("RailTop"))
}

@(private)
phone_navigation :: proc(ui: ^Ui_State) {
	if !single_pane() {return}
	if rl.HasTouch() && touch_field.id != 0 {return}
	if rl.HasTouch() && ui.add_account_open && ui.login_method != .Menu {return}
	// Short windows (a landscape phone, an open keyboard) keep the icons
	// and drop the labels.
	short := f32(rl.GetScreenHeight()) / UI_ZOOM < 420
	label_fs := u16(11 / min(UI_ZOOM, 1) + 0.999)
	label_w := (f32(rl.GetScreenWidth()) / UI_ZOOM - 16) / 5
	for page in Page {
		if rl.MeasureTextLine(FONT_BODY, label_fs, tr(NAV_TIPS[page]), 0).x >
		   label_w {short = true}
	}
	if nendo.box(nendo.id("PhoneNavigation"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(max(short ? 48 : 56, tap_min() + 8)),
		padding = {left = 4, right = 4, top = short ? 2 : 4, bottom = short ? 2 : 4},
		gap = 2,
		color = RAIL_BG,
		border = {color = DIVIDER, width = {top = u16(BORDER_W)}},
	},
	) {
		for page in ([5]Page{.Chats, .Contacts, .Archived, .Profile, .Settings}) {
			active := ui.page == page
			if nendo.box(nendo.id("Nav", u32(page)))(
			{
				width = nendo.grow(),
				height = nendo.grow(),
				direction = .Column,
				gap = 4,
				align = {x = .Center, y = .Center},
				color = active ? SELECTED : hovered() ? HOVER : {},
				radius = rr(8),
			},
			) {
				nendo.text(
					PAGE_ICONS[page],
					{font = FONT_ICON, size = 17, color = active ? ACCENT : TEXT_DIM},
				)
				if short {
					if hovered() {tooltip(tr(NAV_TIPS[page]), .Above)}
				} else {
					nendo.text(
						tr(NAV_TIPS[page]),
						{font = FONT_BODY, size = label_fs, color = active ? TEXT : TEXT_DIM},
					)
				}
			}
		}
	}
}

// ── Narrow windows ──────────────────────────────────────────────────
//
// A phone panel reports anywhere from 360 to 720 points wide depending
// on the scale its compositor picked, and none of that says how big
// the glass physically is. So nothing here asks what device this is:
// both rules key off the window's own width, which means a desktop
// window dragged narrow behaves identically and the phone layout is
// testable without a phone.

// Fewest nendo units the layout ever runs at. A phone at 360 points
// would otherwise get 240 units at the desktop zoom, less than the
// rail alone, so below this zoom is traded for units. Both a Librem 5
// (360 points over 65mm) and a Fairphone 5 (612 over 73mm) land near
// 5.5 units per mm this way, which is the density a phone UI is read
// at: the compositor already put the physical size into its scale.
MIN_UNITS :: f32(360)

// Under this the rail (RAIL_W_MIN, 300) and the page card cannot both
// fit, so the shell shows one at a time.
PHONE_W :: f32(560)

// Base magnification for a window this many points wide, before the
// user's zoom pref multiplies it. Pure, so the breakpoints are
// testable without a window.
zoom_for_width :: proc(win_w: i32) -> f32 {
	if win_w <= 0 {
		return 1.5 // no window yet; nothing to fit to
	}
	return min(1.5, f32(win_w) / MIN_UNITS)
}

// Width for a card that has a fixed design width, capped so a window
// narrower than the card never gets clipped content. `margin` is the
// breathing room left on each side.
fit_w :: proc(w: f32, margin: f32 = 12) -> f32 {
	// Floored: a window narrower than the margins would otherwise hand
	// nendo a negative fixed size.
	return min(w, max(f32(rl.GetScreenWidth()) / UI_ZOOM - margin * 2, 120))
}

// Match the actual shell allocation, including the draggable separator.
page_w :: proc(ui: ^Ui_State) -> f32 {
	if ui.chat_preview_w > 0 {return ui.chat_preview_w}
	if ui.whip_chat_width > 0 {return ui.whip_chat_width}
	width := f32(rl.GetScreenWidth()) / UI_ZOOM
	if single_pane() {
		return phone_detail(ui) ? width : 0
	}
	return width - rail_width(ui) - (rail_narrow(ui) ? 0 : GUTTER_W)
}

// Narrowest window that still has room for the status bar's shortcut
// hints after the pills.
HINTS_W :: f32(760)

// Top-left corner for a floating panel of this size, kept inside the
// window. A window narrower than the panel pins it to the left edge:
// the old `screen - panel` alone goes negative there and pushed the
// panel off the side it was meant to be held on.
panel_pos :: proc(x, y, w, h: f32) -> (f32, f32) {
	sw := f32(rl.GetScreenWidth()) / UI_ZOOM
	sh := f32(rl.GetScreenHeight()) / UI_ZOOM
	return clamp(x, 8, max(8, sw - w)), clamp(y, 8, max(8, sh - h))
}

// Controls sized for a finger rather than a pointer: a one-card window
// (which is a phone in every case that produces one), or any window on
// a machine with a touch screen, since a Fairphone in landscape is
// still a Fairphone.
tap_size :: proc() -> bool {
	return single_pane() || rl.HasTouch()
}

// Touch targets retain 44 window pixels when a narrow window zooms out.
@(private)
tap_min :: proc() -> f32 {
	return 44 / min(UI_ZOOM, 1)
}

@(private)
tab_scrolls: map[u64]nendo.Vector2
@(private)
tab_previous: Page
@(private)
tab_restore: bool
@(private)
tab_was_detail: bool

@(private)
tab_scroll_ids :: proc(page: Page) -> [3]string {
	switch page {
	case .Chats:
		return {"RailContent", "ChatList", ""}
	case .Contacts:
		return {"RailContent", "ContactList", "ContactPage"}
	case .Archived:
		return {"ArchivedPage", "ArchivedList", ""}
	case .Settings:
		return {"SettingsPage", "SettingsTaskPane", ""}
	case .Profile:
		return {"ProfilePage", "", ""}
	}
	return {}
}

@(private)
tab_scroll_save :: proc(ui: ^Ui_State) {
	for name in tab_scroll_ids(tab_previous) {
		if name == "" {continue}
		id := nendo.id(name)
		if data := nendo.scroll(id); data.found {
			tab_scrolls[u64(tab_previous) << 32 | u64(id.id)] = data.position^
		}
	}
	if tab_previous != ui.page || (tab_was_detail && !phone_detail(ui)) {
		tab_previous = ui.page
		tab_restore = true
	}
	tab_was_detail = phone_detail(ui)
}

@(private)
tab_scroll_restore :: proc(ui: ^Ui_State) {
	if !tab_restore {return}
	for name in tab_scroll_ids(ui.page) {
		if name == "" {continue}
		id := nendo.id(name)
		if data := nendo.scroll(id); data.found {
			data.position^ = tab_scrolls[u64(ui.page) << 32 | u64(id.id)]
		}
	}
	tab_restore = false
	scroll_jumped = true
}

// Too narrow for the rail beside the page card.
single_pane :: proc() -> bool {
	return(
		f32(rl.GetScreenWidth()) / UI_ZOOM < PHONE_W ||
		(rl.HasTouch() && f32(rl.GetScreenHeight()) / UI_ZOOM < 480) \
	)
}

// Which half a one-card window is showing: the rail is the list, the
// page card is the detail a list row opens. Standalone pages always
// occupy the detail; Settings owns its category home and breadcrumbs.
phone_detail :: proc(ui: ^Ui_State) -> bool {
	if ui.new_chat_open || ui.add_account_open {
		return true
	}
	switch ui.page {
	case .Chats:
		return ui.whip_open || ui.selected >= 0
	case .Contacts:
		return ui.selected_contact >= 0 || len(ui.profile_contact.id_hex) > 0
	case .Settings, .Archived, .Profile:
		return true
	}
	return false
}

// Back chip above the page card, the only way out of the detail when
// there is no rail on screen to click.
phone_back :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("PhoneHeader"))(
	{width = nendo.grow(), align = {y = .Center}, padding = {right = 12}},
	) {
		if nendo.box(nendo.id("PhoneBack"))(
		{
			height = nendo.fixed(tap_min()),
			padding = {left = 12, right = 14, top = 8, bottom = 8},
			gap = 6,
			align = {y = .Center},
			color = hovered() ? HOVER : {},
			radius = rr(9),
		},
		) {
			nendo.text("‹", {font = FONT_TITLE, size = 16, color = TEXT_DIM})
			nendo.text(tr("Back"), {font = FONT_TITLE, size = 13, color = TEXT_DIM})
		}
	}
}

// Close whatever the detail was showing, which puts the rail back.
phone_back_action :: proc(ui: ^Ui_State) {
	touch_field = {}
	compose_keyboard = false
	if ui.picker_open {close_picker(ui); return}
	if ui.poll_open {poll_close(ui); return}
	if ui.location_open {
		geo_picker_close(ui)
		return
	}
	if ui.new_chat_open {
		close_new_chat(ui)
		return
	}
	if ui.add_account_open {
		if ui.socks5_login_open {ui.socks5_login_open = false; return}
		if auth_job == nil && ui.login_method != .Menu {
			ui.login_method = .Menu
			clear(&ui.login_input)
			ui.login_error = ""
			return
		}
		auth_cancel(ui)
		ui.add_account_open = false
		return
	}
	switch ui.page {
	case .Chats:
		if ui.show_members {close_group_info(ui); return}
		if ui.group_files_open {ui.group_files_open = false; return}
		if ui.search_open {
			ui.search_open = false
			clear(&ui.search_input)
			ui.focus = .Compose
			return
		}
		if len(ui.thread_stack) > 0 {thread_back(ui); return}
		if ui.selected >= 0 && ui.selected < len(ui.chats) {
			stash_draft(ui)
			stash_staged(ui)
			ui.settings_dirty = true
			if ui.chats[ui.selected].archived {ui.page = .Archived}
		}
		compose_keyboard = false
		touch_field = {}
		ui.chat_head_menu = false
		ui.whip_open = false
		ui.selected = -1
	case .Contacts:
		if ui.focus == .Nick {save_nickname(ui)}
		reset_profile_view(ui)
		ui.selected_contact = -1
	case .Settings:
		settings_back(ui)
	case .Archived, .Profile:
		ui.page = .Chats // no list half of their own to fall back to
	}
}

// ── Status bar ──────────────────────────────────────────────────────

Net_State :: enum {
	Offline,
	Connecting,
	Online,
}

// Last live chat-list update, for the SYNCING/SYNCED ticker.
sync_at: f64

SYNCING_SECS :: 1.5

net_state :: proc(ui: ^Ui_State) -> Net_State {
	if !ui.health_ok {
		return .Connecting // no poll has landed yet
	}
	if ui.health.connected > 0 {
		return .Online
	}
	if ui.health.initialized > 0 || ui.health.connecting > 0 || ui.health.pending > 0 {
		return .Connecting
	}
	return .Offline
}

net_color :: proc(state: Net_State) -> nendo.Color {
	switch state {
	case .Online:
		return ACCENT
	case .Connecting:
		return ACCENT_DIM
	case .Offline:
		return DANGER
	}
	return TEXT_LO
}

// Small caps chip with a leading dot, the status bar's unit.
status_pill :: proc(id_str: string, label: string, color: nendo.Color, dot := true) {
	if nendo.box(nendo.id(id_str))({gap = 6, align = {y = .Center}}) {
		if dot {
			if nendo.box(nendo.id_local("PillDot"))(
			{width = nendo.fixed(7), height = nendo.fixed(7), color = color, radius = rr(4)},
			) {}
		}
		nendo.text(label, {font = FONT_MONO, size = 10, color = color, spacing = 2})
	}
}

status_bar :: proc(ui: ^Ui_State) {
	account_pending_ui(ui)
	if ui.stt.file != nil && ui.stt.message == "" && ui.stt.purpose != .Download {
		if nendo.box(nendo.id("SttBar"))(
		{
			width = nendo.grow(),
			padding = nendo.pad(6),
			gap = 12,
			align = {y = .Center},
			color = STATUS_BAR,
		},
		) {
			micro_button("SttCancel", tr("Cancel"))
			if ui.stt.status == 'R' {
				micro_button("SttFinish", tr("Finish dictation"))
			}
			nendo.text(stt_status(ui), {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}
	}
	if ui.tts.file != nil {
		if nendo.box(nendo.id("TtsBar"))(
		{
			width = nendo.grow(),
			padding = nendo.pad(6),
			gap = 12,
			align = {y = .Center},
			color = STATUS_BAR,
		},
		) {
			micro_button("TtsStopGlobal", tr("Stop reading"))
			nendo.text(tts_status(ui), {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}
	}
	update_bar()
	if ui.translation.file != nil {
		if nendo.box(nendo.id("TranslationBar"))(
		{
			width = nendo.grow(),
			direction = .Column,
			padding = nendo.pad(6),
			gap = 4,
			color = STATUS_BAR,
		},
		) {
			if nendo.box(nendo.id("TranslationBarActions"))({gap = 12, align = {y = .Center}}) {
				micro_button("TranslationStopGlobal", tr("Cancel translation"))
				nendo.text(translation_status(ui), {font = FONT_BODY, size = 12, color = TEXT_DIM})
			}
			translation_progress(ui, "TranslationGlobalProgress")
		}
	}
	if len(ui.banner) > 0 {
		banner_bar(ui)
	}
	if single_pane() &&
	   f32(rl.GetScreenHeight()) / UI_ZOOM < 320 &&
	   ui.page == .Chats &&
	   ui.selected >= 0 &&
	   !ui.new_chat_open &&
	   !ui.show_members {return}
	state := net_state(ui)
	// Reserve the same strip online and offline, so the composer stays put.
	if nendo.box(nendo.id("StatusBar"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(single_pane() ? 24 : tap_size() ? tap_min() : 28),
		padding = {left = 10, right = 10},
		gap = single_pane() ? 6 : 12,
		align = {y = .Center},
		color = STATUS_BAR,
	},
	) {
		status_pill(
			"NetPill",
			state == .Online ? tr("ONLINE") : state == .Connecting ? tr("CONNECTING") : tr("OFFLINE"),
			net_color(state),
		)
		if nendo.box(nendo.id("StatusGapL"))({width = nendo.grow()}) {}

		syncing := rl.GetTime() - sync_at < SYNCING_SECS
		if !single_pane() {
			status_pill("RelayPill", relay_counter(ui), TEXT_LO, false)
			status_pill(
				"SyncPill",
				syncing ? tr("SYNCING") : tr("SYNCED"),
				syncing ? ACCENT : TEXT_LO,
				false,
			)
		}
		if nendo.box(nendo.id("StatusGapR"))({width = nendo.grow()}) {}
		if !single_pane() {micro_button("LockNow", tr("Lock now"))}

		// Shortcut hints are the first thing to go when the bar cannot
		// hold everything: they are the only part of it that is not
		// live state, and a one-card window rarely has the keys.
		for hint in ([][2]string{{"Ctrl K", tr("SEARCH")}, {"Ctrl P", tr("COMMANDS")}}) {
			if f32(rl.GetScreenWidth()) / UI_ZOOM < HINTS_W {
				break
			}
			nendo.text(hint[0], {font = FONT_MONO, size = 10, color = TEXT_DIM, spacing = 1})
			nendo.text(hint[1], {font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 2})
		}
	}
}

// ── Message banner ──────────────────────────────────────────────────

Status_Kind :: enum {
	Info,
	Error,
}

// The one way to post a banner message. The kind travels with the
// text because the text is already translated, so its wording can't
// tell an error from a notice.
set_status :: proc(ui: ^Ui_State, text: string, kind: Status_Kind) {
	if ui.client_status == text {ui.banner_seen = ""}
	ui.client_status = text
	ui.client_status_kind = kind
}

// Route a new client_status into the banner.
banner_tick :: proc(ui: ^Ui_State) {
	if ui.client_status == ui.banner_seen {
		return
	}
	ui.banner_seen = ui.client_status
	ui.banner = ""
	if len(ui.client_status) == 0 {
		return
	}
	if ui.client_status_kind == .Info {
		toast(ui, ui.client_status)
		return
	}
	ui.toast_until = 0
	ui.banner = ui.client_status
	ui.banner_kind = ui.client_status_kind
}

banner_bar :: proc(ui: ^Ui_State) {
	color := ui.banner_kind == .Error ? DANGER : ACCENT
	if nendo.box(nendo.id("Banner"))(
	{
		width = nendo.grow(),
		padding = {left = 14, right = 10, top = 8, bottom = 8},
		gap = 10,
		align = {y = .Center},
		color = {color.r, color.g, color.b, 38},
	},
	) {
		if nendo.box(nendo.id("BannerBar"))(
		{width = nendo.fixed(3), height = nendo.fixed(16), color = color, radius = rr(2)},
		) {}
		nendo.text(ui.banner, {font = FONT_BODY, size = 12, color = TEXT})
		if nendo.box(nendo.id("BannerGap"))({width = nendo.grow()}) {}
		if nendo.box(nendo.id("BannerCopy"))(
		{
			width = nendo.fixed(tap_size() ? tap_min() : 24),
			height = nendo.fixed(tap_size() ? tap_min() : 24),
			align = {x = .Center, y = .Center},
			color = hovered() ? HOVER : {},
			radius = rr(6),
		},
		) {
			nendo.text(ICON_COPY, {font = FONT_ICON, size = 11, color = TEXT_DIM})
			if hovered() {
				tooltip(tr("Copy"))
			}
		}
		if nendo.box(nendo.id("BannerClose"))(
		{
			width = nendo.fixed(tap_size() ? tap_min() : 24),
			height = nendo.fixed(tap_size() ? tap_min() : 24),
			align = {x = .Center, y = .Center},
			color = hovered() ? HOVER : {},
			radius = rr(6),
		},
		) {
			nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 11, color = TEXT_DIM})
		}
	}
}

// ── Modal backdrop ──────────────────────────────────────────────────

// Is a centered modal on screen? Anchored popovers (the emoji picker,
// the message and row menus, the mentions inbox) are deliberately not
// modal and keep the page readable behind them.
modal_open :: proc(ui: ^Ui_State) -> bool {
	return(
		ui.accounts_open ||
		ui.peer_open ||
		ui.gs_open ||
		ui.pal_open ||
		ui.link_open ||
		ui.confirm.kind != .None ||
		photo_input_capture(ui) ||
		ui.hist_open ||
		ui.raw_open ||
		ui.enc_open ||
		ui.fwd_open ||
		ui.sticker_open ||
		ui.ov_open ||
		ui.poll_open ||
		ui.location_open ||
		ui.qr_open ||
		ui.lang_open ||
		ui.shortcuts_open ||
		ui.export_open ||
		ui.folder_open ||
		ui.whip_edit_open ||
		ui.theme_edit ||
		ui.backup_mode != .None ||
		ui.vault_pw_open ||
		preview_shown ||
		web_modal.open ||
		nes_player.open \
	)
}

// Glass behind a modal. The page itself is blurred by the renderer
// (renderer.odin splits the frame at this element), so all that is left
// here is the dim: a veil that pushes the page down a stop without
// hiding it. The layer's own fade-in belongs to the renderer too, which
// is why nothing below ramps with open_t.
modal_backdrop :: proc() {
	w := f32(rl.GetScreenWidth()) / UI_ZOOM
	h := f32(rl.GetScreenHeight()) / UI_ZOOM
	if nendo.box(nendo.id("ModalVeil"))(
	{
		width = nendo.fixed(w),
		height = nendo.fixed(h),
		floating = {
			attach_to = .Root,
			z = 9,
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = OVERLAY,
	},
	) {}
}

// ── Toast ───────────────────────────────────────────────────────────

TOAST_SECS :: 4.0

// Transient confirmation for actions with no visible result of their
// own (copy chips, mostly).
toast :: proc(ui: ^Ui_State, text: string) {
	delete(ui.toast)
	ui.toast = strings.clone(text)
	ui.toast_until = rl.GetTime() + TOAST_SECS
}

// Copy chips have no visible result of their own, so every one of them
// goes through here and gets the toast.
copy_text :: proc(ui: ^Ui_State, text: string, label: string) {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	toast(ui, label)
}

toast_layer :: proc(ui: ^Ui_State) {
	if len(ui.toast) == 0 || rl.GetTime() > ui.toast_until {
		return
	}
	frame_deadline = min(frame_deadline, ui.toast_until)
	bottom: f32 = 60
	if ui.page == .Chats &&
	   ui.selected >= 0 &&
	   !ui.show_members &&
	   !ui.group_files_open &&
	   !ui.add_account_open {
		if composer := nendo.element(nendo.id("Composer")); composer.found {
			bottom = max(bottom, f32(rl.GetScreenHeight()) / UI_ZOOM - composer.rect.y + 8)
		}
	}
	if nendo.box(nendo.id("Toast"))(
	{
		width = nendo.fit(max = fit_w(420)),
		padding = {left = 16, right = 16, top = 9, bottom = 9},
		floating = {
			attach_to = .Root,
			z = 20,
			offset = {0, -bottom},
			attach = {element = .Center_Bottom, parent = .Center_Bottom},
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		nendo.text(ui.toast, {font = FONT_BODY, size = 12, color = TEXT})
	}
}

// ── Tooltip ─────────────────────────────────────────────────────────

// Hover label for an icon-only control. Call inside the hovered
// element's body, guarded by hovered(). Defaults to hanging below
// the control (the top-chrome callers, where above would fall off
// the window); .Above suits bottom controls, .Right the navigation rail.
Tip_Side :: enum {
	Below,
	Above,
	Right,
}

tooltip :: proc(text: string, side: Tip_Side = .Below, shift_x: f32 = 0) {
	if rl.TouchActive() {return}
	parent := nendo.element(nendo.Id{id = nendo.open_id()}).rect
	width := min(
		rl.MeasureTextLine(FONT_BODY, 11, text, 0).x + 16,
		f32(rl.GetScreenWidth()) / UI_ZOOM - 8,
	)
	height: f32 = 22
	offset := nendo.Vector2{parent.x + (parent.width - width) / 2, parent.y + parent.height + 6}
	switch side {
	case .Below:
	case .Above:
		offset.y = parent.y - height - 6
	case .Right:
		offset = {parent.x + parent.width + 8, parent.y + (parent.height - height) / 2}
	}
	offset.x += shift_x
	offset.x = clamp(offset.x, 4, max(4, f32(rl.GetScreenWidth()) / UI_ZOOM - width - 4))
	offset.y = clamp(offset.y, 4, max(4, f32(rl.GetScreenHeight()) / UI_ZOOM - height - 4))
	if nendo.box(nendo.id_local("Tip"))(
	{
		width = nendo.fixed(width),
		padding = {left = 8, right = 8, top = 4, bottom = 4},
		floating = {attach_to = .Root, z = 18, offset = offset, pointer = .Passthrough},
		color = CARD,
		radius = rr(6),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		nendo.text(
			text_ellipsis(text, width - 16, FONT_BODY, 11),
			{font = FONT_BODY, size = 11, color = TEXT},
		)
	}
}

// ── Boot splash ─────────────────────────────────────────────────────

// The logomark (assets/svg/logo.svg) as white on transparent, tinted
// with ACCENT at draw time so it follows the theme. Rasterized at 3x
// its 39x30 layout size, so it stays sharp at the default 1.5 zoom on
// a 2x display.
@(private = "file")
LOGO_PNG := #load("assets/logo.png")
@(private = "file")
logo_tex: ^rl.Texture2D

// Above the app name on the splash, vault gate and login cards.
@(private)
logo_mark :: proc() {
	if logo_tex == nil {
		img := rl.LoadImageFromMemory(".png", raw_data(LOGO_PNG), i32(len(LOGO_PNG)))
		if img.data == nil {
			return
		}
		logo_tex = new(rl.Texture2D)
		logo_tex^ = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		rl.SetTextureFilter(logo_tex^, .BILINEAR)
	}

	if nendo.box(nendo.id_local("Logo"))(
	{width = nendo.fixed(39), height = nendo.fixed(30), image = logo_tex, overlay = ACCENT},
	) {}
}

BOOT_PHASES := []string {
	N_("Starting the runtime"),
	N_("Loading your accounts"),
	N_("Connecting to relays"),
}

// One rendered frame of the splash: before a blocking boot step, or
// every frame while one runs on a worker, so the window shows what it
// is waiting on and keeps moving. Phases are announced before the work
// they name. The last phase's frame is held for the warp that opens
// onto the chats. A window the compositor isn't showing skips the frame:
// its vsync present would block until the window shows again.
splash_frame :: proc(step: int) {
	if !rl.IsWindowVisible() {
		return
	}
	nendo.set_dimensions({f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM})
	nendo.begin()
	if nendo.box(nendo.id("SplashRoot"))(
	{width = nendo.grow(), height = nendo.grow(), align = {x = .Center, y = .Center}, color = BG},
	) {
		if nendo.box(nendo.id("SplashCard"))(
		{
			width = nendo.fixed(fit_w(360)),
			direction = .Column,
			padding = nendo.pad(single_pane() ? 20 : 36),
			gap = 10,
			align = {x = .Center},
			color = CARD,
			radius = rr(16),
			border = {color = CARD_BORDER, width = bw()},
		},
		) {
			logo_mark()
			nendo.text("White Noise", {font = FONT_TITLE, size = 22, color = TEXT})
			if nendo.box(nendo.id("SplashGap"))({height = nendo.fixed(6)}) {}
			nendo.text(
				tr(BOOT_PHASES[clamp(step, 0, len(BOOT_PHASES) - 1)]),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
			// One pip per phase; filled up to the running one.
			if nendo.box(nendo.id("SplashPips"))({gap = 6, padding = {top = 6}}) {
				for _, i in BOOT_PHASES {
					if nendo.box(nendo.id("SplashPip", u32(i)))(
					{
						width = nendo.fixed(46),
						height = nendo.fixed(3),
						color = i <= step ? ACCENT : ROW_BG,
						radius = rr(2),
					},
					) {}
				}
			}
			busy_bar("SplashBusy")
		}
	}
	commands := nendo.end(0)

	rl.BeginDrawing()
	rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
	render_nendo(commands)
	rl.EndMode2D()
	if step == len(BOOT_PHASES) - 1 {
		w := f32(rl.GetScreenWidth()) / UI_ZOOM
		h := f32(rl.GetScreenHeight()) / UI_ZOOM
		reveal_capture({w / 2, h / 2}, .Warp)
	}
	rl.EndDrawing()
}

// ── Tray ────────────────────────────────────────────────────────────

// Create the tray (once) and point the window-close route at it. Both
// tray prefs need the icon: one to start hidden, one to hide on close.
apply_tray :: proc(ui: ^Ui_State) {
	if !ui.prefs.start_in_tray && !ui.prefs.minimize_tray {
		rl.SetHideOnClose(false)
		return
	}
	// Accent square with Show/Quit; a missing StatusNotifier host means
	// no icon appears, so closing must still quit.
	abgr := u32(0xff) << 24 | u32(ACCENT[2]) << 16 | u32(ACCENT[1]) << 8 | u32(ACCENT[0])
	rl.InitTray(
		"White Noise",
		abgr,
		strings.clone_to_cstring(tr("Show"), context.temp_allocator),
		strings.clone_to_cstring(tr("Quit"), context.temp_allocator),
	)
	rl.SetHideOnClose(ui.prefs.minimize_tray)
}

@(private = "file")
tray_unread: u64 = max(u64) // forces the first tooltip write

// Unread total in the tray tooltip, rewritten only when it moves.
tray_tick :: proc(ui: ^Ui_State) {
	if !ui.prefs.start_in_tray && !ui.prefs.minimize_tray {
		return
	}
	total: u64
	for chat in ui.chats {
		total += chat.unread
	}
	if total == tray_unread {
		return
	}
	tray_unread = total
	label := total == 0 ? "White Noise" : fmt.tprintf(tr("White Noise · %d unread"), total)
	rl.SetTrayTooltip(strings.clone_to_cstring(label, context.temp_allocator))
}

// ── Single instance + directory permissions ─────────────────────────

// Held for the process's life: closing the file drops the lock.
@(private = "file")
lock_file: ^os.File

@(private)
instance_unlock :: proc() {
	if lock_file != nil {os.close(lock_file); lock_file = nil}
}

// Nonblocking exclusive lock on <home>/.lock. A failure must stop startup;
// two runtimes over one sqlite store can corrupt it.
instance_lock :: proc(home: string) -> bool {
	file, err := os.open(fmt.tprintf("%s/.lock", home), {.Read, .Write, .Create}, os.perm(0o600))
	if err != nil {
		return false
	}
	locked: bool
	when ODIN_OS == .Linux {
		locked = linux.flock(linux.Fd(os.fd(file)), {.EX, .NB}) == .NONE
	} else when ODIN_OS == .Windows {
		overlap: windows.OVERLAPPED
		locked = bool(
			windows.LockFileEx(
				windows.HANDLE(os.fd(file)),
				windows.LOCKFILE_EXCLUSIVE_LOCK | windows.LOCKFILE_FAIL_IMMEDIATELY,
				0,
				1,
				0,
				&overlap,
			),
		)
	} else {
		lock := posix.flock {
			l_type = .WRLCK,
		}
		locked = posix.fcntl(posix.FD(os.fd(file)), .SETLK, &lock) == 0
	}
	if !locked {
		os.close(file)
		return false
	}
	lock_file = file
	return true
}

// The data dir holds the vault, the sealed media cache, and marmot's
// store; keep it owner-only even though every file inside is 0600.
harden_perms :: proc(home: string) {
	os.chmod(home, os.perm(0o700))
	os.chmod(media_cache_dir(context.temp_allocator), os.perm(0o700))
}
