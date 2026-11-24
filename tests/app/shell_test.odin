package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(test)
test_toast_owns_folder :: proc(t: ^testing.T) {
	when ODIN_OS != .OpenBSD && ODIN_PLATFORM_SUBTARGET != .Android {
		file :: "/tmp/white-noise/export.txt"
		path := make([]u8, len(file))
		defer delete(path)
		copy(path, file)

		ui: Ui_State
		set_status(&ui, "Saved", .Info)
		status_reveal_file(&ui, string(path))
		path[5] = 'x'
		banner_tick(&ui)

		defer delete(ui.toast)
		if testing.expect_value(t, ui.toast_reveal, "/tmp/white-noise") {
			delete(ui.toast_reveal)
		}
	}
}

@(test)
test_rail_fits :: proc(t: ^testing.T) {
	for rail_w in ([]int{0, RAIL_W_MIN, RAIL_W_DEFAULT, RAIL_W_MAX, 900}) {
		threshold := f32(clamp(rail_w, RAIL_W_MIN, RAIL_W_MAX)) + GUTTER_W + PAGE_W_MIN
		testing.expect(t, !rail_fits(threshold - 1, rail_w))
		testing.expect(t, rail_fits(threshold, rail_w))
		testing.expect(t, rail_fits(threshold + 1, rail_w))
	}
	testing.expect(
		t,
		rail_fits(f32(1024) / zoom_for_width(1024), RAIL_W_DEFAULT),
		"the default window must show the list at desktop zoom",
	)
	testing.expect(t, rail_fits(1200, RAIL_W_DEFAULT), "restore the list in a wide window")
}

@(test)
test_initial_relay_state :: proc(t: ^testing.T) {
	ui := Ui_State{}
	testing.expect_value(t, net_state(&ui), Net_State.Connecting)
	ui.health_ok = true
	testing.expect_value(t, net_state(&ui), Net_State.Offline)
	ui.health.total_relays = 2
	ui.health.disconnected = 2
	testing.expect_value(t, net_state(&ui), Net_State.Offline)
	ui.health.disconnected = 1
	ui.health.initialized = 1
	testing.expect_value(t, net_state(&ui), Net_State.Connecting)
	ui.health.initialized = 0
	ui.health.connecting = 1
	testing.expect_value(t, net_state(&ui), Net_State.Connecting)
	ui.health.connecting = 0
	ui.health.pending = 1
	testing.expect_value(t, net_state(&ui), Net_State.Connecting)
	ui.health.pending = 0
	ui.health.connected = 1
	testing.expect_value(t, net_state(&ui), Net_State.Online)
	ui.health = {}
	testing.expect_value(t, net_state(&ui), Net_State.Offline)
}

// Exercise the shell consumer, not just its fit calculation: after unlocking
// and opening a chat the default window must contain both the list and chat.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rail_default_window
@(test)
rail_default_window :: proc(t: ^testing.T) {
	if !test_isolated("rail_default_window") {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-rail-default-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", dir)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	defer {
		for value in ui.prefs.quick_reactions {delete(value)}
		delete(ui.prefs.quick_reactions)
		for value in ui.prefs.fetch_relays {delete(value)}
		delete(ui.prefs.fetch_relays)
		delete(ui.prefs.event_client)
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.rail_rows)
		delete(ui.compose)
		wrap_clear()
	}
	ui.prefs.reduce_motion = true
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Compact chat"})
	// A virtual touch device must not switch the desktop to phone layout.
	previous_mouse_touch := os.get_env("SDL_MOUSE_TOUCH_EVENTS", context.temp_allocator)
	os.set_env("SDL_MOUSE_TOUCH_EVENTS", "1")
	defer os.set_env("SDL_MOUSE_TOUCH_EVENTS", previous_mouse_touch)
	rl.InitWindow(i32(ui.prefs.window_w), i32(ui.prefs.window_h), "Default chat list")
	defer rl.CloseWindow()
	UI_ZOOM = zoom_for_width(i32(ui.prefs.window_w)) * f32(ui.prefs.zoom_pct) / 100
	refresh_ui_scale()
	init_fonts()
	window_w := f32(rl.GetScreenWidth()) / UI_ZOOM
	window_h := f32(rl.GetScreenHeight()) / UI_ZOOM
	memory: []u8
	init_layout(&memory, 32768, {window_w, window_h})
	defer delete(memory)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for selected in ([]int{-1, 0}) {
		ui.selected = selected
		for _ in 0 ..< 3 {
			anim_tick(1.0 / 60)
			build_layout(&ui, 0)
		}
		list := nendo.element(nendo.id("ChatList"))
		row := nendo.element(nendo.id("ChatRow", 0))
		rail := nendo.element(nendo.id("Rail")).rect
		testing.expect(
			t,
			list.found && list.rect.width > 0 && list.rect.height > 0,
			"chat list stays visible",
		)
		testing.expect(
			t,
			row.found &&
			row.rect.width > 0 &&
			row.rect.x >= rail.x &&
			row.rect.x + row.rect.width <= rail.x + rail.width + 0.1,
			"chat row remains inside the expanded rail",
		)
		if selected >= 0 {
			for id in ([]string{"ChatPane", "ChatBody", "Composer"}) {
				pane := nendo.element(nendo.id(id))
				testing.expect(
					t,
					pane.found &&
					pane.rect.width > 0 &&
					pane.rect.x >= rail.x + rail.width &&
					pane.rect.x + pane.rect.width <= window_w + 0.1,
					id,
				)
			}
		}
	}
	toggle_rail(&ui)
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	testing.expect(t, ui.prefs.rail_collapsed, "explicit collapse remains respected")
	testing.expect(t, !nendo.element(nendo.id("ChatList")).found)
	toggle_rail(&ui)
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	testing.expect(t, nendo.element(nendo.id("ChatList")).found, "expand restores the list")

	ui.page, ui.focus = .Archived, .Filter
	append(&ui.sidebar_filter, "archive query")
	defer delete(ui.sidebar_filter)
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	nav := nendo.element(nendo.id("Nav", u32(Page.Settings)))
	if testing.expect(t, nav.found, "the archive can open Settings") {
		nendo.set_pointer({nav.rect.x + nav.rect.width / 2, nav.rect.y + nav.rect.height / 2}, .Up)
		forced_release = true
		client: marmot.Client
		handle_pages(&ui, &client)
		forced_release = false
		testing.expect_value(t, ui.page, Page.Settings)
		settings_leave(&ui)
		testing.expect_value(t, ui.page, Page.Archived)
		testing.expect_value(t, ui.focus, Focus.Filter)
		testing.expect_value(t, string(ui.sidebar_filter[:]), "archive query")
	}
	clear(&ui.sidebar_filter)
	ui.page, ui.focus = .Chats, .Compose

	rl.SetWindowSize(720, ui.prefs.window_h)
	UI_ZOOM = zoom_for_width(720) * f32(ui.prefs.zoom_pct) / 100
	refresh_ui_scale()
	nendo.set_dimensions({720 / UI_ZOOM, f32(ui.prefs.window_h) / UI_ZOOM})
	for _ in 0 ..< 3 {
		anim_tick(1.0 / 60)
		build_layout(&ui, 0)
	}
	testing.expect(t, !nendo.element(nendo.id("ChatList")).found)
	testing.expect(
		t,
		nendo.element(nendo.id("ChatPane")).found,
		"small windows show the open chat",
	)
	ui.selected = -1
	for _ in 0 ..< 3 {
		anim_tick(1.0 / 60)
		build_layout(&ui, 0)
	}
	testing.expect(
		t,
		nendo.element(nendo.id("ChatList")).found,
		"back reveals the single-pane list",
	)
	testing.expect(t, !nendo.element(nendo.id("ChatPane")).found)
}

@(test)
status_bar_viewports :: proc(t: ^testing.T) {
	if !test_isolated("status_bar_viewports") {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("", "wn-status-viewport-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", dir)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	rl.InitWindow(1024, 700, "Status bar viewports")
	defer rl.CloseWindow()
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	ui := Ui_State {
		selected    = -1,
		row_menu    = -1,
		member_menu = -1,
		prefs       = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	ui.account_ref = "viewport"
	append(&ui.accounts, Account_Row_Ui{id_hex = "viewport", name = "Viewport"})
	append(&ui.prefs.folders, "Empty folder")
	for i in 0 ..< 12 {append(&ui.chats, Chat_Row_Ui{group_id = fmt.tprintf("group-%d", i), title = fmt.tprintf("Group %d", i)})}
	defer {
		delete(ui.accounts); delete(ui.chats)
		delete(ui.prefs.folders)
		for value in ui.prefs.quick_reactions {delete(value)}
		delete(ui.prefs.quick_reactions)
		for value in ui.prefs.fetch_relays {delete(value)}
		delete(ui.prefs.fetch_relays); delete(ui.prefs.event_client)
	}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)
	for size in ([][2]i32{{1024, 700}, {780, 520}, {2560, 1080}, {2560, 480}}) {
		rl.SetWindowSize(size[0], size[1])
		for zoom in ([]f32{1.5, 3}) {
			UI_ZOOM = zoom
			refresh_ui_scale()
			nendo.set_dimensions({f32(size[0]) / zoom, f32(size[1]) / zoom})
			for page in ([]Page{.Profile, .Settings}) {
				ui.page = page
				for section in ([]Settings_Section{.Chats, .Appearance}) {
					if page == .Profile && section == .Appearance {continue}
					rail_w, collapsed := ui.prefs.rail_w, ui.prefs.rail_collapsed
					defer ui.prefs.rail_w, ui.prefs.rail_collapsed = rail_w, collapsed
					if page == .Settings {
						ui.prefs.rail_collapsed = section == .Chats
						ui.prefs.rail_w = section == .Chats ? RAIL_W_MIN : RAIL_W_MAX
					}
					settings_open(&ui, nil, section)
					ui.page = page
					if page == .Profile {
						if data := nendo.scroll(nendo.id("ProfilePage"));
						   data.found {data.position^ = {}}
					}
					for _ in 0 ..< 4 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
					if page == .Settings &&
					   section == .Appearance &&
					   settings_resolve_scroll(&ui) {
						build_layout(&ui, 0)
					}
					viewport := nendo.id(page == .Profile ? "ProfilePage" : "SettingsPage")
					box := nendo.element(viewport).rect
					status := nendo.element(nendo.id("StatusBar")).rect
					testing.expectf(
						t,
						box.height > 0 &&
						box.y + box.height <= status.y + 0.1 &&
						status.y + status.height <= f32(size[1]) / zoom + 0.1,
						"Page %v section %v viewport %v must end above status %v",
						page,
						section,
						box,
						status,
					)
					if page == .Settings {
						root := nendo.element(nendo.id("SettingsRoot"))
						width := f32(size[0]) / zoom
						if size[0] == 2560 && size[1] == 1080 && zoom == 1.5 {
							height := f32(size[1]) / zoom
							testing.expectf(
								t,
								root.found &&
								root.rect.x > 0 &&
								root.rect.y > 0 &&
								abs(2 * root.rect.x + root.rect.width - width) <= 0.1 &&
								abs(2 * root.rect.y + root.rect.height - height) <= 0.1,
								"Settings must be centered in the large viewport: %v",
								root.rect,
							)
							testing.expect(t, nendo.element(nendo.id("Rail")).found)
						} else {
							testing.expectf(
								t,
								root.found &&
								abs(root.rect.x) <= 0.1 &&
								abs(root.rect.y) <= 0.1 &&
								abs(root.rect.width - width) <= 0.1 &&
								abs(root.rect.height - status.y) <= 0.1,
								"Settings root %v must fill the logical width %v up to the status bar %v",
								root.rect,
								width,
								status,
							)
							for id in ([]string{"Rail", "RailGutter", "PhoneNavigation"}) {
								testing.expect(t, !nendo.element(nendo.id(id)).found, id)
							}
						}
					}
					if page == .Settings &&
					   section == .Appearance &&
					   size[0] == 1024 &&
					   size[1] == 700 &&
					   zoom == 3 {
						reset := nendo.element(nendo.id("ZoomReset"))
						testing.expectf(
							t,
							reset.found &&
							reset.rect.y >= box.y - 0.1 &&
							reset.rect.y + reset.rect.height <= box.y + box.height + 0.1,
							"At 200%%, ZoomReset %v must fit on entry inside SettingsPage %v above the status bar",
							reset.rect,
							box,
						)
					}
					if page == .Profile {
						avatar := nendo.element(nendo.id("ProfileAvatarPick")).rect
						y := status.y + status.height - 2
						if avatar.y <= y && avatar.y + avatar.height > y {
							commands := build_layout(&ui, 0)
							path := fmt.ctprintf("%s/profile-clip.png", dir)
							rl.BeginDrawing()
							rl.BeginMode2D({zoom = UI_ZOOM})
							render_nendo(commands)
							rl.EndMode2D()
							rl.TakeScreenshot(path)
							rl.EndDrawing()
							image := rl.LoadImage(path)
							if testing.expect(
								t,
								image.data != nil,
								"Profile clipping screenshot must decode",
							) {
								x := int((avatar.x + avatar.width / 2) * UI_ZOOM)
								i := (int(y * UI_ZOOM) * int(image.width) + x) * 4
								color := nendo_color(STATUS_BAR)
								testing.expect(
									t,
									image.data[i] == color.r &&
									image.data[i + 1] == color.g &&
									image.data[i + 2] == color.b,
									"The floating profile avatar must not paint over the status bar",
								)
							}
							rl.UnloadImage(image)
						}
					}
					target := nendo.id(page == .Profile ? "SignOutBtn" : "ZoomMinus")
					if page == .Settings && section == .Chats {
						board := nendo.id("FolderBoard")
						if data := nendo.scroll(viewport); data.found {
							bounds := nendo.element(board).rect
							data.position.y = clamp(
								data.position.y + box.y - bounds.y,
								-max(data.content.height - data.viewport.height, 0),
								0,
							)
						}
						if data := nendo.scroll(board); data.found {data.position.y = 0}
						for _ in 0 ..< 3 {build_layout(&ui, 0)}
						empty := nendo.element(nendo.id("BoardEmpty", 0))
						testing.expect(
							t,
							empty.found &&
							empty.rect.y < status.y &&
							empty.rect.y + empty.rect.height > box.y,
						)
						target = nendo.id("BoardChat", 11)
						for id in ([]string{"SettingsPage", "FolderBoard"}) {
							data := nendo.scroll(nendo.id(id))
							if data.found {data.position.y = min(0, data.viewport.height - data.content.height)}
							for _ in 0 ..< 3 {build_layout(&ui, 0)}
						}
						// Related links can put the page bottom beyond the board's
						// virtualized rows. Scroll back until the final row mounts.
						for _ in 0 ..< 64 {
							if nendo.element(target).found {break}
							data := nendo.scroll(viewport)
							if !data.found {break}
							data.position.y = min(0, data.position.y + 44)
							for _ in 0 ..< 3 {build_layout(&ui, 0)}
						}
					}
					scroll_into_view(viewport, target)
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					control := nendo.element(target)
					b := control.rect
					if page == .Settings && section == .Appearance {
						ui.prefs.zoom_pct = 190
						appearance_activate(&ui, nendo.id("ZoomPlus"))
						nendo.set_dimensions({f32(size[0]) / UI_ZOOM, f32(size[1]) / UI_ZOOM})
						for _ in 0 ..< 2 {
							build_layout(&ui, 0)
							if settings_resolve_scroll(&ui) {build_layout(&ui, 0)}
						}
						control = nendo.element(target)
						b = control.rect
						box = nendo.element(viewport).rect
						status = nendo.element(nendo.id("StatusBar")).rect
					}
					testing.expectf(
						t,
						control.found && b.y >= box.y && b.y + b.height <= status.y + 0.1,
						"Page %v section %v control at %v must fit viewport %v above status %v",
						page,
						section,
						b,
						box,
						status,
					)
					nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
					testing.expectf(
						t,
						nendo.pointer_over(target) && !nendo.pointer_over(nendo.id("StatusBar")),
						"%v/%v at %v scale %v must receive input instead of the status bar",
						page,
						section,
						size,
						zoom,
					)
				}
			}
		}
	}
	settings_modal_reflow(t, &ui)
}

@(private)
settings_modal_reflow :: proc(t: ^testing.T, ui: ^Ui_State) {
	resize :: proc(ui: ^Ui_State, width, height: i32) {
		rl.SetWindowSize(width, height)
		UI_ZOOM = 1.5
		refresh_ui_scale()
		nendo.set_dimensions({f32(width) / UI_ZOOM, f32(height) / UI_ZOOM})
		for _ in 0 ..< 3 {
			anim_tick(1.0 / 60)
			build_layout(ui, 0)
			if settings_resolve_scroll(ui) {build_layout(ui, 0)}
		}
	}
	ui.page, ui.focus = .Chats, .Compose
	ui.settings_return_page = nil
	ui.selected = 0
	resize(ui, 1600, 1000)
	settings_open(ui, nil, .Composer)
	resize(ui, 1600, 1000)
	preview_files := composer_action_id(.Files, .Preview)
	chat_files := composer_action_id(.Files, .Chat)
	if testing.expect(t, nendo.element(preview_files).found && nendo.element(chat_files).found) {
		settings_test_point(preview_files)
		testing.expect(t, nendo.pointer_over(preview_files) && !nendo.pointer_over(chat_files))
		forced_press = true
		testing.expect(t, handle_composer_drag(ui))
		forced_press = false
		testing.expect_value(t, ui.composer_editor.drag.source, Composer_Action.Files)
		ui.composer_editor.drag = {}
	}
	settings_open(ui, nil, .Language)
	resize(ui, 1600, 1000)
	testing.expect(t, nendo.element(nendo.id("ChatPane")).found, "The conversation stays visible")
	settings_test_point(nendo.id("Nav", u32(Page.Contacts)))
	testing.expect(
		t,
		!nendo.pointer_over(nendo.id("Nav", u32(Page.Contacts))),
		"The backdrop blocks the rail",
	)
	settings_test_point(nendo.id("LangChange"))
	settings_test_release(ui)
	resize(ui, 1600, 1000)
	testing.expect(t, ui.lang_open)
	settings_test_point(nendo.id("SettingsExit"))
	testing.expect(
		t,
		!nendo.pointer_over(nendo.id("SettingsExit")),
		"A child dialog blocks Settings",
	)
	rl.PushKey(.ESCAPE, true)
	handle_settings(ui, nil)
	rl.PushKey(.ESCAPE, false)
	testing.expect(t, !ui.lang_open)
	resize(ui, 780, 700)
	testing.expect(
		t,
		!nendo.element(nendo.id("ChatPane")).found,
		"Small windows use full-page Settings",
	)
	testing.expect(t, nendo.element(nendo.id("RowLang")).found)
	resize(ui, 1600, 1000)
	testing.expect(
		t,
		nendo.element(nendo.id("RowLang")).found,
		"Resizing preserves the selected settings section",
	)
	rl.PushKey(.ESCAPE, true)
	settings_escape(ui)
	rl.PushKey(.ESCAPE, false)
	resize(ui, 1600, 1000)
	testing.expect(
		t,
		ui.page == .Chats && ui.selected == 0 && nendo.element(nendo.id("ChatPane")).found,
	)
	testing.expect(t, !nendo.element(nendo.id("SettingsRoot")).found, "Escape closes the dialog")

	ui.stt.file = wn_ipc_create(4)
	if !testing.expect(t, ui.stt.file != nil) {return}
	defer stt_stop(ui)
	ui.stt.purpose = .Download
	ui.prefs.stt_enabled, ui.prefs.stt_model = true, STT_MODELS[0].name
	settings_open(ui, nil, .Language, "SttCancel")
	resize(ui, 1600, 1000)
	cancel := nendo.id("SttCancel")
	settings_test_point(cancel)
	testing.expect(
		t,
		settings_modal(ui) && nendo.pointer_over(cancel),
		"Cancel is visible in the Settings dialog",
	)
	forced_release = true
	defer {forced_release = false}
	ui.lang_open = true
	testing.expect(t, !handle_shell_foreground(ui, false), "A child dialog owns the release")
	ui.lang_open = false
	testing.expect(t, !handle_shell_foreground(ui, true), "A captured release stays consumed")
	testing.expect(t, ui.stt.file != nil)
	testing.expect(t, handle_shell_foreground(ui, false), "Settings can cancel the download")
	testing.expect(t, ui.stt.file == nil)
}

// A two-card window too narrow for the saved rail collapses it on its
// own; the expand toggle must still open the list there, and collapse
// it again. A rail command in Settings must not change the chat layout.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rail_expand_narrow
@(test)
rail_expand_narrow :: proc(t: ^testing.T) {
	if !test_isolated("rail_expand_narrow") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 700, "Rail expand")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	home :: "/tmp/wn-odin-rail-test"
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	defer os.remove_all(home)

	ui: Ui_State
	ui.page = .Chats
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	g_prefs = &ui.prefs
	defer g_prefs = nil
	width :: proc(ui: ^Ui_State) -> f32 {
		anim_frame += 1
		return rail_width(ui)
	}

	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
	toggle_rail(&ui)
	testing.expect_value(t, width(&ui), f32(RAIL_W_MIN))
	testing.expect(t, !rail_narrow(&ui), "expanded list must render its rows")
	toggle_rail(&ui)
	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
	testing.expect(t, ui.prefs.rail_collapsed)

	ui.page = .Settings
	ui.rail_peek = true
	toggle_rail(&ui)
	testing.expect(
		t,
		ui.prefs.rail_collapsed,
		"Settings must not change the saved rail preference",
	)
	testing.expect(t, ui.rail_peek, "Settings must not change the transient rail state")
	ui.page = .Chats
	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
}

// The two width rules the narrow layout hangs on. Both are pure, so
// the phone breakpoints are checked without a window: 360 points is a
// Librem 5 at scale 2, 612 a Fairphone 5, 1024 the default desktop.
@(test)
test_zoom_for_width :: proc(t: ^testing.T) {
	// Before the window exists GetScreenWidth is 0. Deriving a zoom
	// from that renders the vault gate at 1/360 scale, i.e. black.
	testing.expect_value(t, zoom_for_width(0), f32(1.5))
	testing.expect_value(t, zoom_for_width(1024), f32(1.5)) // desktop unchanged
	testing.expect_value(t, zoom_for_width(360), f32(1.0)) // 360 points -> 360 units
	testing.expect_value(t, zoom_for_width(612), f32(1.5)) // 612 points -> 408 units

	// Whatever the scale, a phone-width window lands under the
	// one-card breakpoint and above the rail's minimum.
	for w in ([]i32{360, 540, 612, 720}) {
		units := f32(w) / zoom_for_width(w)
		testing.expect(t, units < PHONE_W, "phone width must be one-card")
		testing.expect(t, units >= MIN_UNITS, "phone width must clear the rail minimum")
	}
	testing.expect(t, f32(1024) / zoom_for_width(1024) >= PHONE_W, "desktop must stay two-card")
}

// No window in a test run, so GetScreenWidth is 0: the cap must still
// hand nendo a usable width rather than a negative one.
@(test)
test_fit_w_floor :: proc(t: ^testing.T) {
	testing.expect(t, fit_w(660) > 0, "a fixed width must never go negative")
	testing.expect(t, fit_w(660) <= 660, "the cap must never widen a card")
	testing.expect(t, fit_w(80) == 80, "a card narrower than the floor is left alone")
}

@(test)
test_phone_detail :: proc(t: ^testing.T) {
	ui: Ui_State
	ui.selected = -1
	ui.selected_contact = -1

	ui.page = .Chats
	testing.expect(t, !phone_detail(&ui), "no chat picked shows the list")
	ui.selected = 0
	testing.expect(t, phone_detail(&ui), "a picked chat shows the page card")

	// Back cancels location without leaving its conversation or consuming
	// the composer state that was behind the picker.
	append(&ui.compose, "unsent draft")
	append(&ui.staged, Staged_File{name = "attachment.txt"})
	append(&ui.thread_stack, "thread")
	defer {delete(ui.compose); delete(ui.staged); delete(ui.thread_stack)}
	ui.replying = "reply"
	ui.location_open, ui.location_busy = true, true
	ui.location_request = 7
	testing.expect(t, modal_open(&ui), "location is a modal")
	phone_back_action(&ui)
	testing.expect(t, !ui.location_open && !ui.location_busy, "back closes location")
	testing.expect_value(t, ui.location_request, u64(8))
	testing.expect_value(t, ui.selected, 0)
	testing.expect_value(t, string(ui.compose[:]), "unsent draft")
	testing.expect_value(t, len(ui.staged), 1)
	testing.expect_value(t, ui.staged[0].name, "attachment.txt")
	testing.expect_value(t, ui.replying, "reply")
	testing.expect_value(t, thread_cur(&ui), "thread")

	// Back closes exactly one level, and the innermost first.
	ui.new_chat_open = true
	testing.expect(t, phone_detail(&ui), "the new-chat pane is a detail")
	phone_back_action(&ui)
	testing.expect(t, ui.selected == 0, "the chat under the new-chat pane survives")
	phone_back_action(&ui)
	testing.expect(t, ui.selected == 0 && thread_cur(&ui) == "", "back leaves the thread first")
	phone_back_action(&ui)
	testing.expect(t, !phone_detail(&ui), "back from the chat shows the list")

	settings_open(&ui, nil, .Appearance)
	testing.expect(t, phone_detail(&ui), "settings uses the page rather than a second sidebar")
	phone_back_action(&ui)
	testing.expect(
		t,
		ui.page == .Settings && ui.settings_section == .Home,
		"back returns to the category home",
	)
	testing.expect(t, phone_detail(&ui), "the category home remains reachable at narrow widths")
	phone_back_action(&ui)
	testing.expect(
		t,
		ui.page == .Chats && !phone_detail(&ui),
		"back from settings returns to the chat list",
	)
}

// Escape on a settings page lets go of a focused box first, then steps
// back one level per press, out to the chat list.
@(test)
test_settings_escape :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		nendo.set_context(previous)
		delete(memory)
	}

	ui: Ui_State
	defer {
		delete(ui.accounts)
		delete(ui.settings_search)
		delete(ui.pal_hits)
		delete(ui.sidebar_filter)
		delete(ui.filter_hits)
		delete(ui.chats)
		delete(ui.compose)
		delete(ui.staged)
	}
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	client: marmot.Client
	press_escape :: proc(ui: ^Ui_State, client: ^marmot.Client) {
		rl.PushKey(.ESCAPE, true)
		handle_pages(ui, client)
		rl.PushKey(.ESCAPE, false)
	}

	settings_open(&ui, nil, .Chats)
	press_escape(&ui, &client)
	testing.expect(t, ui.page == .Settings && ui.settings_section == .Home)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.page, Page.Chats)

	settings_open(&ui, nil, .Appearance)
	append(&ui.settings_search, "dark")
	ui.focus = .SettingsSearch
	press_escape(&ui, &client)
	testing.expect(t, ui.focus == .Compose && len(ui.settings_search) == 0)
	testing.expect_value(t, ui.settings_section, Settings_Section.Appearance)
	settings_gallery_open(&ui)
	testing.expect(t, ui.settings_gallery)
	press_escape(&ui, &client)
	testing.expect(t, ui.settings_section == .Appearance && !ui.settings_gallery)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.settings_section, Settings_Section.Home)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.page, Page.Chats)

	ui.page, ui.focus = .Contacts, .Filter
	ui.selected, ui.selected_contact = 0, 2
	append(&ui.sidebar_filter, "people query")
	append(&ui.filter_hits, true)
	append(&ui.chats, Chat_Row_Ui{group_id = "open-chat"})
	append(&ui.compose, "unsent draft")
	append(&ui.staged, Staged_File{name = "attachment.txt"})
	ui.replying = "pending-reply"
	pal_open_modal(&ui)
	run_command(&ui, nil, .Goto_Settings)
	testing.expect_value(t, ui.page, Page.Settings)
	testing.expect(t, !ui.pal_open)
	settings_open(&ui, nil, .Appearance, "ZoomReset")
	press_escape(&ui, &client)
	testing.expect(t, ui.page == .Settings && ui.settings_section == .Home)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.page, Page.Contacts)
	testing.expect_value(t, ui.focus, Focus.Filter)
	testing.expect_value(t, ui.selected_contact, 2)
	testing.expect_value(t, string(ui.sidebar_filter[:]), "people query")
	testing.expect(t, len(ui.filter_hits) == 1 && ui.filter_hits[0])
	testing.expect(t, ui.settings_return_page == nil, "leave consumes the captured origin")

	ui.page, ui.focus = .Chats, .Compose
	pal_open_modal(&ui)
	run_command(&ui, nil, .Set_Notifications)
	settings_open(&ui, nil, .Appearance, "ZoomReset")
	phone_back_action(&ui)
	phone_back_action(&ui)
	testing.expect_value(t, ui.page, Page.Chats)
	if testing.expect_value(t, ui.selected, 0) {
		testing.expect_value(t, ui.chats[ui.selected].group_id, "open-chat")
	}
	testing.expect_value(t, string(ui.compose[:]), "unsent draft")
	testing.expect_value(t, ui.replying, "pending-reply")
	if testing.expect_value(t, len(ui.staged), 1) {
		testing.expect_value(t, ui.staged[0].name, "attachment.txt")
	}
	testing.expect_value(t, len(ui.drafts), 0)
	testing.expect_value(t, len(ui.staged_drafts), 0)
}

@(test)
test_key_navigation_clears_secret :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		settings_section = .Account,
		keys_nsec        = string(make([]u8, 63)),
		keys_nsec_show   = true,
		keys_confirm     = "RevealNsecBtn",
	}
	defer keys_forget(&ui)

	settings_open(&ui, nil, .Account, "NpubRow")
	testing.expect(
		t,
		len(ui.keys_nsec) == 0 && !ui.keys_nsec_show && ui.keys_confirm == "",
		"Leaving private-key controls must discard the revealed key and confirmation",
	)

	ui.keys_nsec = string(make([]u8, 63))
	ui.keys_nsec_show = true
	ui.settings_section = .Advanced
	handle_pages(&ui, nil)
	testing.expect(
		t,
		len(ui.keys_nsec) == 0 && !ui.keys_nsec_show,
		"Frame cleanup must still wipe a private key outside its settings page",
	)
}

@(test)
test_confirm_survives_frame :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		settings_section = .Connection,
		keys_confirm     = "TrustForgetAll",
	}
	handle_pages(&ui, nil)
	testing.expect(
		t,
		ui.keys_confirm == "TrustForgetAll",
		"An idle frame must preserve a pending settings confirmation",
	)
	settings_open(&ui, nil, .Home)
	testing.expect(t, ui.keys_confirm == "", "Leaving settings controls must disarm them")
}

// A hold that stays put fires once; one that travels never does.
@(test)
test_long_press :: proc(t: ^testing.T) {
	s: Long_Press
	testing.expect(t, !lp_step(&s, true, true, 0, 100, 100), "the press itself is not a hold")
	testing.expect(t, !lp_step(&s, false, true, 0.4, 100, 100), "under the threshold")
	testing.expect(t, lp_step(&s, false, true, 0.6, 100, 100), "past the threshold")
	testing.expect(t, !lp_step(&s, false, true, 0.9, 100, 100), "one menu per press")

	// A drag disqualifies the press, and stays disqualified after it
	// comes back to where it started.
	d: Long_Press
	testing.expect(t, !lp_step(&d, true, true, 0, 100, 100), "")
	testing.expect(t, !lp_step(&d, false, true, 0.1, 100, 120), "travel cancels the hold")
	testing.expect(t, !lp_step(&d, false, true, 0.9, 100, 100), "and does not un-cancel")
}
