package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

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

// Exercise the shell consumer, not just its fit calculation: after unlocking
// and opening a chat the default window must contain both the list and chat.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rail_default_window
@(test)
rail_default_window :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "rail_default_window" {return}
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
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Compact chat"})
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
		list := clay.GetElementData(clay.ID("ChatList"))
		row := clay.GetElementData(clay.ID("ChatRow", 0))
		rail := clay.GetElementData(clay.ID("Rail")).boundingBox
		testing.expect(
			t,
			list.found && list.boundingBox.width > 0 && list.boundingBox.height > 0,
			"chat list stays visible",
		)
		testing.expect(
			t,
			row.found &&
			row.boundingBox.width > 0 &&
			row.boundingBox.x >= rail.x &&
			row.boundingBox.x + row.boundingBox.width <= rail.x + rail.width + 0.1,
			"chat row remains inside the expanded rail",
		)
		if selected >= 0 {
			for id in ([]string{"ChatPane", "ChatBody", "Composer"}) {
				pane := clay.GetElementData(clay.ID(id))
				testing.expect(
					t,
					pane.found &&
					pane.boundingBox.width > 0 &&
					pane.boundingBox.x >= rail.x + rail.width &&
					pane.boundingBox.x + pane.boundingBox.width <= window_w + 0.1,
					id,
				)
			}
		}
	}
	toggle_rail(&ui)
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	testing.expect(t, ui.prefs.rail_collapsed, "explicit collapse remains respected")
	testing.expect(t, !clay.GetElementData(clay.ID("ChatList")).found)
	toggle_rail(&ui)
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	testing.expect(t, clay.GetElementData(clay.ID("ChatList")).found, "expand restores the list")
	rl.SetWindowSize(720, ui.prefs.window_h)
	UI_ZOOM = zoom_for_width(720) * f32(ui.prefs.zoom_pct) / 100
	refresh_ui_scale()
	clay.SetLayoutDimensions({720 / UI_ZOOM, f32(ui.prefs.window_h) / UI_ZOOM})
	for _ in 0 ..< 3 {
		anim_tick(1.0 / 60)
		build_layout(&ui, 0)
	}
	testing.expect(t, !clay.GetElementData(clay.ID("ChatList")).found)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ChatPane")).found,
		"small windows show the open chat",
	)
	ui.selected = -1
	for _ in 0 ..< 3 {
		anim_tick(1.0 / 60)
		build_layout(&ui, 0)
	}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ChatList")).found,
		"back reveals the single-pane list",
	)
	testing.expect(t, !clay.GetElementData(clay.ID("ChatPane")).found)
}

@(test)
status_bar_viewports :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "status_bar_viewports" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-status-viewport-*", context.temp_allocator)
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
	append(&ui.accounts, "Viewport")
	append(&ui.account_ids, "viewport")
	append(&ui.account_pics, "")
	append(&ui.account_npubs, "")
	for i in 0 ..< 12 {append(&ui.chats, Chat_Row_Ui{group_id = fmt.tprintf("group-%d", i), title = fmt.tprintf("Group %d", i)})}
	defer {
		delete(
			ui.accounts,
		); delete(ui.account_ids); delete(ui.account_pics); delete(ui.account_npubs); delete(ui.chats)
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
			clay.SetLayoutDimensions({f32(size[0]) / zoom, f32(size[1]) / zoom})
			for page in ([]Page{.Profile, .Settings}) {
				ui.page = page
				for section in ([]Settings_Section{.Folders, .Appearance}) {
					if page == .Profile && section == .Appearance {continue}
					settings_open(&ui, nil, section)
					ui.page = page
					if page == .Profile {
						if data := clay.GetScrollContainerData(clay.ID("ProfilePage"));
						   data.found {data.scrollPosition^ = {}}
					}
					for _ in 0 ..< 4 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
					viewport := clay.ID(page == .Profile ? "ProfilePage" : "SettingsPage")
					box := clay.GetElementData(viewport).boundingBox
					status := clay.GetElementData(clay.ID("StatusBar")).boundingBox
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
					if page == .Profile {
						avatar := clay.GetElementData(clay.ID("ProfileAvatarPick")).boundingBox
						y := status.y + status.height - 2
						if avatar.y <= y && avatar.y + avatar.height > y {
							commands := build_layout(&ui, 0)
							path := fmt.ctprintf("%s/profile-clip.png", dir)
							rl.BeginDrawing()
							rl.BeginMode2D({zoom = UI_ZOOM})
							clay_raylib_render(&commands)
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
								color := clay_color(STATUS_BAR)
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
					target := clay.ID(page == .Profile ? "SignOutBtn" : "ZoomMinus")
					if page == .Settings && section == .Folders {
						target = clay.ID("BoardChat", 11)
						for id in ([]string{"SettingsPage", "FolderBoard"}) {
							data := clay.GetScrollContainerData(clay.ID(id))
							if data.found {data.scrollPosition.y = min(0, data.scrollContainerDimensions.height - data.contentDimensions.height)}
							for _ in 0 ..< 3 {build_layout(&ui, 0)}
						}
					}
					owner := viewport
					if page == .Settings &&
					   section == .Appearance {owner = appearance_scroll(&ui, target)}
					scroll_into_view(owner, target)
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					control := clay.GetElementData(target)
					b := control.boundingBox
					if page == .Settings && section == .Appearance {
						ui.prefs.zoom_pct = 190
						appearance_activate(&ui, clay.ID("ZoomPlus"))
						clay.SetLayoutDimensions({f32(size[0]) / UI_ZOOM, f32(size[1]) / UI_ZOOM})
						for _ in 0 ..< 2 {
							build_layout(&ui, 0)
							if settings_resolve_scroll(&ui) {build_layout(&ui, 0)}
						}
						control = clay.GetElementData(target)
						b = control.boundingBox
						box = clay.GetElementData(viewport).boundingBox
						status = clay.GetElementData(clay.ID("StatusBar")).boundingBox
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
					clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
					testing.expect(
						t,
						clay.PointerOver(target) && !clay.PointerOver(clay.ID("StatusBar")),
						"Scrolled controls must receive input instead of the status bar",
					)
				}
			}
		}
	}
}

// A two-card window too narrow for the saved rail collapses it on its
// own; the expand toggle must still open the list there, and collapse
// it again. Settings pins the rail shut, so its toggle flips the pref
// without forcing the list open for the Chats page later.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rail_expand_narrow
@(test)
rail_expand_narrow :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "rail_expand_narrow" {return}
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
	toggle_rail(&ui)
	toggle_rail(&ui)
	testing.expect(t, ui.prefs.rail_collapsed, "Settings toggle round-trips the pref")
	testing.expect(t, !ui.rail_peek, "Settings must not force the list open")
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
// hand clay a usable width rather than a negative one.
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
	testing.expect(t, !phone_detail(&ui), "back from the chat shows the list")

	settings_open(&ui, nil, .Appearance, 2)
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
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}

	ui: Ui_State
	defer {
		delete(ui.accounts)
		delete(ui.settings_search)
	}
	append(&ui.accounts, "Test")
	client: marmot.Client
	press_escape :: proc(ui: ^Ui_State, client: ^marmot.Client) {
		rl.PushKey(.ESCAPE, true)
		handle_pages(ui, client)
		rl.PushKey(.ESCAPE, false)
	}

	settings_open(&ui, nil, .Folders)
	press_escape(&ui, &client)
	testing.expect(t, ui.page == .Settings && ui.settings_section == .Home)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.page, Page.Chats)

	settings_open(&ui, nil, .Appearance, 1, level = .Sheet)
	append(&ui.settings_search, "dark")
	ui.focus = .SettingsSearch
	press_escape(&ui, &client)
	testing.expect(t, ui.focus == .Compose && len(ui.settings_search) == 0)
	testing.expect(t, ui.settings_section == .Appearance && ui.settings_level == .Sheet)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.settings_section, Settings_Section.Home)
	press_escape(&ui, &client)
	testing.expect_value(t, ui.page, Page.Chats)
}

@(test)
test_keys_tab_clears_secret :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		settings_section = .Keys,
		settings_tab     = 2,
		keys_nsec        = string(make([]u8, 63)),
		keys_nsec_show   = true,
		keys_confirm     = "RevealNsecBtn",
	}
	defer keys_forget(&ui)

	settings_open(&ui, nil, .Keys, anchor = "NpubRow")
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
		settings_section = .Advanced,
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
