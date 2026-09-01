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

rail_width :: proc(ui: ^Ui_State) -> f32 {
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

		for hint in ([][2]string{{"Ctrl K", "SEARCH"}, {"Ctrl P", "COMMANDS"}}) {
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
// element's body, guarded by hovered(). It hangs below the
// control: everything using it sits in the top chrome, where above
// would fall off the window.
tooltip :: proc(text: string) {
	if clay.UI(clay.ID_LOCAL("Tip"))(
	{
		layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
		floating = {attachTo = .Parent, zIndex = 18, offset = {0, 6}, attachment = {element = .CenterTop, parent = .CenterBottom}},
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
			layout = {sizing = {width = clay.SizingFixed(360)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(36), childGap = 10, childAlignment = {x = .Center}},
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
