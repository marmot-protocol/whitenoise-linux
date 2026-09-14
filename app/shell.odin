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

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// ── Gutters ─────────────────────────────────────────────────────────

RAIL_W_DEFAULT :: 340
// The narrowest rail that still fits its top strip: avatar (30), five
// 32px nav buttons, the collapse chip, the gaps between them, and the
// card padding. Narrower and this clay pushes the last sibling past the
// card edge, or drops it (PORT.md Quirks).
RAIL_W_MIN :: 300
RAIL_W_MAX :: 560
RAIL_W_COLLAPSED :: 60
PAGE_W_MIN :: f32(560) // Room for the conversation and its header controls.

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
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = clay.SizingFixed(GUTTER_W), height = clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}},
	},
	) {
		if clay.UI(clay.ID_LOCAL("GutterLine"))(
		{layout = {sizing = {width = clay.SizingFixed(2), height = clay.SizingFixed(40)}}, backgroundColor = active || hovered() ? ACCENT : FIELD_BORDER, cornerRadius = rr(1)},
		) {}
	}
}

// Run the two gutter drags. Called after layout, so clay's boxes are
// this frame's.
handle_gutters :: proc(ui: ^Ui_State) {
	if rl.IsMouseButtonPressed(.LEFT) {
		if clay.PointerOver(clay.ID("RailGutter")) {
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
		// The rail card starts at the CardsRow padding (10px).
		ui.prefs.rail_w = clamp(int(mx) - 10, RAIL_W_MIN, RAIL_W_MAX)
	}
}

@(private)
rail_fits :: proc(window_w: f32, rail_w: int) -> bool {
	return window_w - f32(clamp(rail_w, RAIL_W_MIN, RAIL_W_MAX)) - 40 >= PAGE_W_MIN
}

rail_width :: proc(ui: ^Ui_State) -> f32 {
	// One card at a time: the rail is either the whole window or gone,
	// and neither width is draggable, so the eased path is skipped.
	if single_pane() {
		if phone_detail(ui) {
			return 0
		}
		return f32(rl.GetScreenWidth()) / UI_ZOOM - CARDS_PAD
	}
	// Resize immediately; preserving the pref restores the list when it fits.
	if !rail_fits(f32(rl.GetScreenWidth()) / UI_ZOOM, ui.prefs.rail_w) {
		anim_set(clay.ID("RailWidth").id, RAIL_W_COLLAPSED)
		return RAIL_W_COLLAPSED
	}
	target := ui.prefs.rail_collapsed ? f32(RAIL_W_COLLAPSED) : f32(clamp(ui.prefs.rail_w, RAIL_W_MIN, RAIL_W_MAX))
	// Dragging the gutter must track the pointer exactly; only the
	// collapse toggle animates. Pin the entry too, or release replays
	// the drag from its starting width.
	if gutter_drag != "" {
		anim_set(clay.ID("RailWidth").id, target)
		return target
	}
	return anim_to(clay.ID("RailWidth").id, target, 20)
}

// How open the rail is: 0 collapsed, 1 at its full width. Everything
// inside reads this instead of the pref, so the list leaves with the
// width instead of vanishing the frame the toggle flips.
rail_open :: proc(ui: ^Ui_State) -> f32 {
	full := f32(clamp(ui.prefs.rail_w, RAIL_W_MIN, RAIL_W_MAX))
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

// ── Narrow windows ──────────────────────────────────────────────────
//
// A phone panel reports anywhere from 360 to 720 points wide depending
// on the scale its compositor picked, and none of that says how big
// the glass physically is. So nothing here asks what device this is:
// both rules key off the window's own width, which means a desktop
// window dragged narrow behaves identically and the phone layout is
// testable without a phone.

// The CardsRow left+right padding, the width a card does not get.
CARDS_PAD :: f32(20)

// Fewest clay units the layout ever runs at. A phone at 360 points
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
	// clay a negative fixed size.
	return min(w, max(f32(rl.GetScreenWidth()) / UI_ZOOM - margin * 2, 120))
}

// How wide the page card gets: the window less the rail and the
// padding around and between the two cards. Three call sites measured
// this themselves before; the header's badge is the fourth.
page_w :: proc(ui: ^Ui_State) -> f32 {
	return f32(rl.GetScreenWidth()) / UI_ZOOM - rail_width(ui) - 40
}

// Narrowest page card that still fits the chat header's badge beside
// the title and the three chips. Under it the badge goes.
HEAD_BADGE_W :: f32(420)

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

// Too narrow for the rail beside the page card.
single_pane :: proc() -> bool {
	return f32(rl.GetScreenWidth()) / UI_ZOOM < PHONE_W
}

// Which half a one-card window is showing: the rail is the list, the
// page card is the detail a list row opens. Archive is its own list
// and Profile's rail is the account switcher (which the accounts modal
// also reaches), so both of those pages are always the detail.
phone_detail :: proc(ui: ^Ui_State) -> bool {
	if ui.new_chat_open || ui.add_account_open {
		return true
	}
	switch ui.page {
	case .Chats:
		return ui.selected >= 0
	case .Contacts:
		return ui.selected_contact >= 0
	case .Settings:
		return ui.sett_open
	case .Archived, .Profile:
		return true
	}
	return false
}

// Back chip above the page card, the only way out of the detail when
// there is no rail on screen to click.
phone_back :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PhoneBack"))(
	{
		layout = {padding = {left = 12, right = 14, top = 8, bottom = 8}, childGap = 6, childAlignment = {y = .Center}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(9),
	},
	) {
		clay.Text("‹", {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT_DIM})
		clay.Text(tr("Back"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
	}
}

// Close whatever the detail was showing, which puts the rail back.
phone_back_action :: proc(ui: ^Ui_State) {
	if ui.new_chat_open {
		ui.new_chat_open = false
		return
	}
	if ui.add_account_open {
		ui.add_account_open = false
		return
	}
	switch ui.page {
	case .Chats:
		ui.selected = -1
	case .Contacts:
		ui.selected_contact = -1
	case .Settings:
		ui.sett_open = false
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
	if ui.health.connecting > 0 || ui.health.pending > 0 {
		return .Connecting
	}
	return .Offline
}

net_color :: proc(state: Net_State) -> clay.Color {
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
status_pill :: proc(id_str: string, label: string, color: clay.Color, dot := true) {
	if clay.UI(clay.ID(id_str))({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if dot {
			if clay.UI(clay.ID_LOCAL("PillDot"))(
			{layout = {sizing = {width = clay.SizingFixed(7), height = clay.SizingFixed(7)}}, backgroundColor = color, cornerRadius = rr(4)},
			) {}
		}
		clay.Text(label, {fontId = FONT_MONO, fontSize = 10, textColor = color, letterSpacing = 2})
	}
}

status_bar :: proc(ui: ^Ui_State) {
	if ui.stt.file != nil {
		if clay.UI(clay.ID("SttBar"))({layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(6), childGap = 12, childAlignment = {y = .Center}}, backgroundColor = STATUS_BAR}) {
			micro_button("SttCancel", "Cancel dictation")
			if ui.stt.status == 'R' {
				micro_button("SttFinish", "Finish dictation")
			}
			clay.Text(stt_status(ui), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		}
	}
	if ui.tts.file != nil {
		if clay.UI(clay.ID("TtsBar"))({layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(6), childGap = 12, childAlignment = {y = .Center}}, backgroundColor = STATUS_BAR}) {
			micro_button("TtsStopGlobal", "Stop reading")
			clay.Text(tts_status(ui), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		}
	}
	if len(ui.banner) > 0 {
		banner_bar(ui)
	}
	if clay.UI(clay.ID("StatusBar"))(
	{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(28)}, padding = {left = 14, right = 14}, childGap = 12, childAlignment = {y = .Center}}, backgroundColor = STATUS_BAR},
	) {
		state := net_state(ui)
		status_pill("NetPill", state == .Online ? "ONLINE" : state == .Connecting ? "CONNECTING" : "OFFLINE", net_color(state))
		if clay.UI(clay.ID("StatusGapL"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}

		syncing := rl.GetTime() - sync_at < SYNCING_SECS
		status_pill("RelayPill", relay_counter(ui), TEXT_LO, false)
		status_pill("SyncPill", syncing ? "SYNCING" : "SYNCED", syncing ? ACCENT : TEXT_LO, false)
		if clay.UI(clay.ID("StatusGapR"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}

		// Shortcut hints are the first thing to go when the bar cannot
		// hold everything: they are the only part of it that is not
		// live state, and a one-card window rarely has the keys.
		for hint in ([][2]string{{"Ctrl K", "SEARCH"}, {"Ctrl P", "COMMANDS"}}) {
			if f32(rl.GetScreenWidth()) / UI_ZOOM < HINTS_W {
				break
			}
			clay.Text(hint[0], {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_DIM, letterSpacing = 1})
			clay.Text(hint[1], {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2})
		}
	}
}

// ── Message banner ──────────────────────────────────────────────────

// Route a new client_status into the banner. Errors keep the recovery
// wording they were written with; this only decides the tint.
// ponytail: prefix sniffing instead of a typed status; give
// client_status a severity field if a message ever lands in the wrong
// color.
banner_tick :: proc(ui: ^Ui_State) {
	if ui.client_status == ui.banner_seen {
		return
	}
	ui.banner_seen = ui.client_status
	if len(ui.client_status) == 0 {
		return
	}
	ui.banner = ui.client_status
	ui.banner_error =
		strings.has_prefix(ui.client_status, "Couldn't") ||
		strings.contains(ui.client_status, "failed") ||
		strings.contains(ui.client_status, "couldn't")
}

banner_bar :: proc(ui: ^Ui_State) {
	color := ui.banner_error ? DANGER : ACCENT
	if clay.UI(clay.ID("Banner"))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 14, right = 10, top = 8, bottom = 8}, childGap = 10, childAlignment = {y = .Center}},
		backgroundColor = {color.r, color.g, color.b, 38},
	},
	) {
		if clay.UI(clay.ID("BannerBar"))({layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingFixed(16)}}, backgroundColor = color, cornerRadius = rr(2)}) {}
		clay.Text(ui.banner, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
		if clay.UI(clay.ID("BannerGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if clay.UI(clay.ID("BannerClose"))(
		{layout = {padding = clay.PaddingAll(6)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
		) {
			clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM})
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
		ui.hist_open ||
		ui.raw_open ||
		ui.enc_open ||
		ui.fwd_open ||
		ui.ov_open ||
		ui.qr_open ||
		ui.lang_open ||
		ui.shortcuts_open ||
		ui.export_open ||
		ui.folder_open ||
		ui.theme_edit ||
		ui.backup_mode != .None ||
		ui.vault_pw_open ||
		preview_shown ||
		web_modal.open \
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
	if clay.UI(clay.ID("ModalVeil"))(
	{
		layout = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)}},
		floating = {attachTo = .Root, zIndex = 9, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = OVERLAY,
	},
	) {}
}

// ── Toast ───────────────────────────────────────────────────────────

TOAST_SECS :: 1.8

// Transient confirmation for actions with no visible result of their
// own (copy chips, mostly).
toast :: proc(ui: ^Ui_State, text: string) {
	delete(ui.toast)
	ui.toast = strings.clone(text)
	ui.toast_until = rl.GetTime() + TOAST_SECS
}

// Copy chips have no visible result of their own, so every one of them
// goes through here and gets the toast.
copy_text :: proc(ui: ^Ui_State, text: string, label := "Copied") {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	toast(ui, tr(label))
}

toast_layer :: proc(ui: ^Ui_State) {
	if len(ui.toast) == 0 || rl.GetTime() > ui.toast_until {
		return
	}
	if clay.UI(clay.ID("Toast"))(
	{
		layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}},
		floating = {attachTo = .Root, zIndex = 20, offset = {0, -52}, attachment = {element = .CenterBottom, parent = .CenterBottom}},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		clay.Text(ui.toast, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
	}
}

// ── Tooltip ─────────────────────────────────────────────────────────

// Hover label for an icon-only control. Call inside the hovered
// element's body, guarded by hovered(). Defaults to hanging below
// the control (the top-chrome callers, where above would fall off
// the window); .Above suits anything near the bottom edge.
Tip_Side :: enum {
	Below,
	Above,
}

tooltip :: proc(text: string, side: Tip_Side = .Below) {
	attach := side == .Below ? clay.FloatingAttachPoints{element = .CenterTop, parent = .CenterBottom} : clay.FloatingAttachPoints{element = .CenterBottom, parent = .CenterTop}
	if clay.UI(clay.ID_LOCAL("Tip"))(
	{
		layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
		floating = {attachTo = .Parent, zIndex = 18, offset = {0, side == .Below ? 6 : -6}, attachment = attach},
		backgroundColor = CARD,
		cornerRadius = rr(6),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		clay.Text(tr(text), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT})
	}
}

// ── Boot splash ─────────────────────────────────────────────────────

BOOT_PHASES := []string{N_("Starting the runtime"), N_("Loading your accounts"), N_("Connecting to relays")}

// One rendered frame of the splash before a blocking boot step, so the
// window shows what it is waiting on instead of staying black. Phases
// are announced before the work they name.
splash_frame :: proc(step: int) {
	clay.SetLayoutDimensions({f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM})
	clay.BeginLayout()
	if clay.UI(clay.ID("SplashRoot"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = BG},
	) {
		if clay.UI(clay.ID("SplashCard"))(
		{
			layout = {sizing = {width = clay.SizingFixed(fit_w(360))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(single_pane() ? 20 : 36), childGap = 10, childAlignment = {x = .Center}},
			backgroundColor = CARD,
			cornerRadius = rr(16),
			border = {color = CARD_BORDER, width = bw()},
		},
		) {
			clay.Text("///", {fontId = FONT_TITLE, fontSize = 34, textColor = ACCENT})
			clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 22, textColor = TEXT})
			if clay.UI(clay.ID("SplashGap"))({layout = {sizing = {height = clay.SizingFixed(6)}}}) {}
			clay.Text(tr(BOOT_PHASES[clamp(step, 0, len(BOOT_PHASES) - 1)]), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
			// One pip per phase; filled up to the running one.
			if clay.UI(clay.ID("SplashPips"))({layout = {childGap = 6, padding = {top = 6}}}) {
				for _, i in BOOT_PHASES {
					if clay.UI(clay.ID("SplashPip", u32(i)))(
					{layout = {sizing = {width = clay.SizingFixed(46), height = clay.SizingFixed(3)}}, backgroundColor = i <= step ? ACCENT : ROW_BG, cornerRadius = rr(2)},
					) {}
				}
			}
		}
	}
	commands := clay.EndLayout(0)

	rl.BeginDrawing()
	rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
	clay_raylib_render(&commands)
	rl.EndMode2D()
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
	rl.InitTray("White Noise", abgr, "Show", "Quit")
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
	label := total == 0 ? "White Noise" : fmt.tprintf("White Noise · %d unread", total)
	rl.SetTrayTooltip(strings.clone_to_cstring(label, context.temp_allocator))
}

// ── Single instance + directory permissions ─────────────────────────

// Held for the process's life: closing the file drops the lock.
@(private = "file")
lock_file: ^os.File

// Exclusive flock on <home>/.lock. false means another instance already
// owns the data dir; two runtimes over one sqlite store corrupt it.
instance_lock :: proc(home: string) -> bool {
	file, err := os.open(fmt.tprintf("%s/.lock", home), {.Read, .Write, .Create}, os.perm(0o600))
	if err != nil {
		return true // can't lock, don't block the user
	}
	if linux.flock(linux.Fd(os.fd(file)), {.EX, .NB}) != .NONE {
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
