package main

import "base:runtime"
import "core:testing"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
mobile_back_keeps_draft :: proc(t: ^testing.T) {
	ui := Ui_State {
		page     = .Chats,
		selected = 0,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "first"})
	append(&ui.compose, "unsent draft")
	append(&ui.staged, Staged_File{name = "attachment.txt"})
	defer {
		delete(ui.chats)
		delete(ui.compose)
		for key, value in ui.drafts {delete(key); delete(value)}
		delete(ui.drafts)
		for key, value in ui.staged_drafts {delete(key); delete(value)}
		delete(ui.staged_drafts)
	}
	phone_back_action(&ui)
	testing.expect_value(t, ui.selected, -1)
	testing.expect_value(t, ui.drafts["first"], "unsent draft")
	testing.expect_value(t, len(ui.staged), 0)
	staged := ui.staged_drafts["first"]
	if testing.expect_value(
		t,
		len(staged),
		1,
	) {testing.expect_value(t, staged[0].name, "attachment.txt")}
}

@(test)
mobile_shell_viewports :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_shell_viewports" {return}
	context.allocator = runtime.default_context().allocator
	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Mobile")
	append(
		&ui.chats,
		Chat_Row_Ui {
			group_id = "phone-chat",
			title = "A conversation with a long title that must not hide actions",
		},
	)
	rl.InitWindow(390, 740, "Mobile shell")
	defer rl.CloseWindow()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {390, 740})
	defer delete(memory)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for size in ([][2]i32{{320, 568}, {360, 640}, {390, 740}, {430, 860}, {390, 360}, {740, 390}}) {
		rl.SetWindowSize(size[0], size[1])
		UI_ZOOM = zoom_for_width(size[0])
		refresh_ui_scale()
		width, height := f32(size[0]) / UI_ZOOM, f32(size[1]) / UI_ZOOM
		clay.SetLayoutDimensions({width, height})
		for selected in ([]int{-1, 0}) {
			ui.page, ui.selected = .Chats, selected
			for _ in 0 ..< 4 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
			navigation := clay.GetElementData(clay.ID("PhoneNavigation"))
			nav := navigation.boundingBox
			bottom :=
				navigation.found ? nav.y : clay.GetElementData(clay.ID("StatusBar")).boundingBox.y
			if !navigation.found &&
			   !clay.GetElementData(clay.ID("StatusBar")).found {bottom = height}
			if selected < 0 || height >= 320 {
				testing.expect(
					t,
					nav.width <= width && nav.y + nav.height <= height + 0.1,
					"navigation remains inside phone viewport",
				)
				for page in Page {
					box := clay.GetElementData(clay.ID("Nav", u32(page))).boundingBox
					testing.expect(
						t,
						box.width >= 44 &&
						box.height >= 44 &&
						box.x >= 0 &&
						box.x + box.width <= width + 0.1,
						"destinations remain touch-sized and visible",
					)
				}
			}
			if selected < 0 {
				list := clay.GetElementData(clay.ID("ChatList")).boundingBox
				testing.expect(
					t,
					list.width >= width - 32 && list.height > 0,
					"phone inbox uses the full width without a desktop rail",
				)
				continue
			}
			for id in ([]string{"ChatPane", "ChatBody", "Composer", "ChatBack"}) {
				data := clay.GetElementData(clay.ID(id))
				box := data.boundingBox
				testing.expect(
					t,
					data.found &&
					box.x >= 0 &&
					box.y >= 0 &&
					box.width > 0 &&
					box.height > 0 &&
					box.x + box.width <= width + 0.1 &&
					box.y + box.height <= bottom + 0.1,
					id,
				)
			}
		}
	}
	rl.SetWindowSize(390, 740)
	UI_ZOOM = zoom_for_width(390)
	clay.SetLayoutDimensions({390 / UI_ZOOM, 740 / UI_ZOOM})
	ui.selected, ui.page = 0, .Chats
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	forced_release = true
	defer forced_release = false
	box := clay.GetElementData(clay.ID("Nav", u32(Page.Chats))).boundingBox
	clay.SetPointerState({box.x + 2, box.y + 2}, false)
	// Current-destination taps return to the inbox instead of doing nothing.
	client: marmot.Client
	handle_pages(&ui, &client)
	testing.expect_value(t, ui.selected, -1)
	ui.page = .Settings
	ui.settings_section = .Appearance
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	box = clay.GetElementData(clay.ID("Nav", u32(Page.Settings))).boundingBox
	clay.SetPointerState({box.x + 2, box.y + 2}, false)
	handle_pages(&ui, &client)
	testing.expect_value(t, ui.settings_section, Settings_Section.Home)

	// Inbox rows scrolled under the navigation bar sit outside the page's
	// clip, so a tap on a destination reaches the bar, not the row.
	for _ in 0 ..< 20 {append(&ui.chats, Chat_Row_Ui{group_id = "more", title = "More"})}
	ui.page, ui.selected = .Chats, -1
	for _ in 0 ..< 4 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	box = clay.GetElementData(clay.ID("Nav", u32(Page.Contacts))).boundingBox
	centre := clay.Vector2{box.x + box.width / 2, box.y + box.height / 2}
	clay.SetPointerState(centre, false)
	under := false
	for i in 0 ..< len(ui.chats) {
		row := clay.GetElementData(clay.ID("ChatRow", u32(i)))
		r := row.boundingBox
		if !row.found || centre.y < r.y || centre.y > r.y + r.height {continue}
		under = true
		testing.expect(t, !clay.PointerOver(clay.ID("ChatRow", u32(i))), "hidden row takes no tap")
	}
	testing.expect(t, under, "a row is laid out beneath the navigation bar")
	testing.expect(t, clay.PointerOver(clay.ID("Nav", u32(Page.Contacts))), "the bar takes it")
}
