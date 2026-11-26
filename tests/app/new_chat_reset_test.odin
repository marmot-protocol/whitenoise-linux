package main

import "base:runtime"
import "core:fmt"
import "core:os"

import marmot "../marmot"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "nendo"
import rl "sdlrl"

// Run separately: SDL_VIDEODRIVER=dummy tests/odin.sh app
// -define:ODIN_TEST_NAMES=new_chat_reset_dispatch
@(test)
new_chat_reset_dispatch :: proc(t: ^testing.T) {
	if !test_isolated("new_chat_reset_dispatch") {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp(
		os.get_env("TMPDIR", context.temp_allocator),
		"wn-new-chat-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	settings_test_dir = dir
	defer settings_test_dir = ""
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	rl.InitWindow(1024, 700, "New chat reset")
	defer rl.CloseWindow()
	defer profile_session_clear()
	defer account_jobs_stop()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		prefs            = default_prefs(),
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs.reduce_motion = true
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})
	append(&ui.chats, Chat_Row_Ui{group_id = "fixture", title = "Fixture chat"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_drag = nil}


	layout :: proc(ui: ^Ui_State) {

		for _ in 0 ..< 3 {build_layout(ui, 0)}
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, id: nendo.Id) {

		data := nendo.element(id)
		if !testing.expect(t, data.found, "navigation control must exist") {return}
		box := data.rect
		point := [2]f32{box.x + box.width / 2, box.y + box.height / 2}
		text_drag = nil
		nendo.set_pointer(point, .Down)
		forced_press = true
		handle_pages(ui, client)
		if ui.page == .Chats {handle_chat(ui, client)}
		forced_press = false
		nendo.set_pointer(point, .Up)
		forced_release = true
		handle_pages(ui, client)
		if ui.page == .Chats {handle_chat(ui, client)}
		// Same frame-end dismissal used by main after page dispatch.
		if ui.new_chat_open && ui.page != .Chats {close_new_chat(ui)}
		forced_release = false
		nendo.set_pointer({0, 0}, .Up)
	}
	// The header has one Back chip: on the group page it returns to the
	// contact picker (NCBack), and there it dismisses the form (NCCancel).
	back_out :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client) {
		click(t, ui, client, nendo.id("NCBack"))
		testing.expect(t, ui.new_chat_open && ui.nc_page == .Contacts)
		layout(ui)
		click(t, ui, client, nendo.id("NCCancel"))
	}
	account := ui.account_ref
	settings_open(&ui, nil, .Privacy)
	layout(&ui)
	click(t, &ui, client, nendo.id("DefaultRetention3"))
	save_settings(&ui)
	load_settings(&ui)
	ui.account_ref = "other-account"
	open_new_chat(&ui, nil)
	testing.expect_value(t, ui.nc_retention, 0)
	close_new_chat(&ui)
	settings_flip(&ui, client, "DefaultRetention1")
	save_settings(&ui)
	load_settings(&ui)
	open_new_chat(&ui, nil)
	testing.expect_value(t, ui.nc_retention, 3600)
	close_new_chat(&ui)
	ui.account_ref = account
	ui.page = .Chats
	for notes in ([]bool{false, true}) {
		ui.new_chat_open, ui.nc_page = true, .Group
		ui.nc_created.id = strings.clone("abandoned-group")
		if notes {open_notes(&ui, nil)}
		open_new_chat(&ui, nil)
		layout(&ui)
		testing.expect(t, nendo.element(nendo.id("NCSearch")).found)
		testing.expect(t, !nendo.element(nendo.id("NCRetryOpen")).found)
		close_new_chat(&ui)
	}
	for cancel in ([]bool{false, true}) {
		layout(&ui)
		click(t, &ui, client, nendo.id("NewChatBtn"))
		testing.expect(t, ui.new_chat_open)
		layout(&ui)
		click(t, &ui, client, nendo.id("NCGroup"))
		testing.expect(t, ui.nc_page == .Group)
		testing.expect_value(t, ui.nc_retention, 604800)
		ed_insert(&ui, &ui.nc_name, "Abandoned group")

		testing.expect_value(t, string(ui.nc_name[:]), "Abandoned group")
		layout(&ui)
		if cancel {
			back_out(t, &ui, client)
		} else {
			click(t, &ui, client, nendo.id("Nav", u32(Page.Settings)))
			testing.expect_value(t, ui.page, Page.Settings)
		}
		testing.expect(t, !ui.new_chat_open)
		if !cancel {
			layout(&ui)
			click(t, &ui, client, nendo.id("SettingsExit"))
			testing.expect_value(t, ui.page, Page.Chats)
			testing.expect_value(t, ui.focus, Focus.Compose)
			testing.expect(t, !ui.new_chat_open)
		}
		layout(&ui)
		click(t, &ui, client, nendo.id("NewChatBtn"))
		testing.expect(t, len(ui.nc_name) == 0, "a fresh form must not retain the abandoned name")
		layout(&ui)
		click(t, &ui, client, nendo.id("NCGroup"))
		testing.expect(t, len(ui.nc_name) == 0, "group field starts empty")
		layout(&ui)
		back_out(t, &ui, client)
	}
	// The intentional DM-to-group prefill is applied after the fresh reset.
	peer :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	ui.chats[0].conversation_kind = .DIRECT
	ui.chats[0].peer_hex = peer
	ui.show_members = true
	ui.info_tab = .Members
	ed_set(&ui, &ui.nc_name, "Old group")
	layout(&ui)
	click(t, &ui, client, nendo.id("DmStartGroup"))
	testing.expect(t, ui.new_chat_open && ui.nc_page == .Group)
	testing.expect_value(t, nc_group_targets(&ui), peer)
	testing.expect_value(t, string(ui.nc_member[:]), "")
	testing.expect(t, len(ui.nc_name) == 0)
	testing.expect(t, ui.focus == .NC_Name)

	second :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	third :: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	bea_pic :: "test://group-picker-bea"
	casey_pic :: "test://group-picker-casey"
	pixels: [16][4]u8
	for &pixel in pixels {pixel = {70, 160, 220, 255}}
	image := rl.Image {
		data   = cast([^]u8)raw_data(pixels[:]),
		width  = 4,
		height = 4,
	}
	register_local_pic(bea_pic, image)
	for &pixel in pixels {pixel = {210, 100, 60, 255}}
	register_starter_pic(third, "Casey", casey_pic, image)
	append(
		&ui.nc_contacts,
		Contact_Ui {
			id_hex = strings.clone(second),
			name = strings.clone("Bea"),
			pic_url = strings.clone(bea_pic),
		},
	)
	append(
		&ui.nc_contacts,
		Contact_Ui {
			id_hex = strings.clone(third),
			name = strings.clone("Casey"),
			pic_url = strings.clone(bea_pic),
		},
	)
	for key in ([2]string{"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}) {
		append(
			&ui.nc_contacts,
			Contact_Ui{id_hex = strings.clone(key), name = strings.clone("Extra")},
		)
	}
	defer nc_contacts_free(&ui.nc_contacts)
	layout(&ui)
	click(t, &ui, client, nendo.id("NCMember"))
	layout(&ui)
	options := nendo.scroll(nendo.id("NCMemberOptions"))
	if !testing.expect(t, options.found) {return}
	options.position.y = -NC_MEMBER_H
	layout(&ui)
	rl.PushKey(.ENTER, true)
	handle_chat(&ui, client)
	rl.PushKey(.ENTER, false)
	rl.WindowShouldClose()
	testing.expect_value(t, nc_group_targets(&ui), peer)
	layout(&ui)
	for i in 0 ..< 24 {
		nc_member_add(&ui, fmt.tprintf("%064x", i + 1), "Extra invitee")
	}
	layout(&ui)
	pane := nendo.scroll(nendo.id("NewChatPane"))
	pane.position.y = pane.viewport.height - pane.content.height
	layout(&ui)
	option := nendo.element(nendo.id("NCMemberOption", 0)).rect
	view := nendo.element(nendo.id("NewChatPane")).rect
	if !testing.expect(
		t,
		option.y + option.height < view.y,
		fmt.tprintf("suggestion %v must be above pane %v at %v", option, view, pane.position^),
	) {return}
	rl.PushKey(.ENTER, true)
	handle_chat(&ui, client)
	rl.PushKey(.ENTER, false)
	rl.WindowShouldClose()
	if !testing.expect_value(t, len(ui.nc_members), 25) {return}
	pane.position.y = 0
	form := nendo.scroll(nendo.id("NCForm"))
	if form.found {form.position.y = 0}
	layout(&ui)
	click(t, &ui, client, nendo.id("NCName"))
	if !testing.expect_value(t, ui.focus, Focus.NC_Name) {return}
	layout(&ui)
	rl.PushKey(.LEFT_SHIFT, true)
	for _ in 0 ..< len(NC_RETENTION_KEYS) + 2 {
		rl.PushKey(.TAB, true)
		handle_chat(&ui, client)
		rl.PushKey(.TAB, false)
		rl.WindowShouldClose()
		layout(&ui)
	}
	rl.PushKey(.LEFT_SHIFT, false)
	rl.WindowShouldClose()
	layout(&ui)
	last_remove := nendo.element(nendo.id("NCMemberRemove", 24)).rect
	view = nendo.element(nendo.id("NewChatPane")).rect
	testing.expect(
		t,
		i32(last_remove.y + last_remove.height) <= i32(view.y + view.height),
		fmt.tprintf(
			"Tab reveals the last removal control: focus %v, button %v, viewport %v",
			ui.focus,
			last_remove,
			view,
		),
	)
	pane.position.y = 0
	layout(&ui)
	rl.PushKey(.ENTER, true)
	handle_chat(&ui, client)
	rl.PushKey(.ENTER, false)
	rl.WindowShouldClose()
	if !testing.expect_value(t, len(ui.nc_members), 25) {return}
	for member in ui.nc_members[1:] {delete(member.hex); delete(member.label); delete(member.pic_url)}
	resize(&ui.nc_members, 1)
	pane.position.y = 0
	layout(&ui)
	click(t, &ui, client, nendo.id("NCMember"))
	layout(&ui)
	click(t, &ui, client, nendo.id("NCMemberOption", 0))
	layout(&ui)
	click(t, &ui, client, nendo.id("NCMemberOption", 1))
	testing.expect_value(t, nc_group_targets(&ui), peer + "\n" + second + "\n" + third)
	nc_contacts_free(&ui.nc_contacts)
	layout(&ui)
	commands := build_layout(&ui, 0)
	for url, i in ([]string{bea_pic, casey_pic}) {
		avatar := nendo.id("NCMemberPickedAvatar", u32(i + 1))
		image_id := nendo.id("AvatarImage", avatar.id).id
		want := shaped_avatar(local_pic(url), "circle")
		shown := false
		for command in commands {
			if command.kind == .Image && command.id == image_id && command.image.image == want {
				shown = true
				break
			}
		}
		testing.expect(t, shown, "selected member renders their profile photo")
	}
	third_remove := nendo.id("NCMemberRemove", 2)
	box := nendo.element(third_remove).rect
	nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
	testing.expect(
		t,
		nendo.pointer_over(third_remove),
		"third invitee is visible without scrolling",
	)
	nendo.set_pointer({0, 0}, .Up)
	for key in ([4]rl.KeyboardKey{.TAB, .TAB, .TAB, .ENTER}) {
		rl.PushKey(key, true)
		handle_chat(&ui, client)
		rl.PushKey(key, false)
		rl.WindowShouldClose()
		layout(&ui)
	}
	testing.expect_value(t, nc_group_targets(&ui), peer + "\n" + second)
	ed_set(&ui, &ui.nc_name, "Weekend plans")
	ed_set(&ui, &ui.nc_description, "Meet at the station")
	account_jobs_stop()
	layout(&ui)
	scroll_into_view(nendo.id("NCForm"), nendo.id(NC_RETENTION_KEYS[1]))
	layout(&ui)
	click(t, &ui, client, nendo.id(NC_RETENTION_KEYS[1]))
	layout(&ui)
	click(t, &ui, client, nendo.id("NCCreate"))
	if testing.expect_value(t, len(account_jobs), 1) {
		testing.expect_value(t, account_jobs[0].kind, Account_Operation.Create_Chat)
		testing.expect_value(t, account_jobs[0].target, peer + "\n" + second)
		testing.expect_value(t, account_jobs[0].retention, 3600)
		testing.expect_value(t, account_jobs[0].description, "Meet at the station")
	}
	testing.expect_value(t, ui.prefs.default_retention[account], 604800)
	account_jobs_stop()
	layout(&ui)
	back_out(t, &ui, client)
	testing.expect_value(t, nc_group_targets(&ui), "")

	rl.SetWindowSize(360, 320)
	nendo.set_dimensions({360, 320})
	open_new_chat(&ui, nil)
	ui.nc_page, ui.focus = .Group, .NC_Name
	layout(&ui)
	for name in ([2]string{"NCForm", "NewChatPane"}) {
		if scroll := nendo.scroll(nendo.id(name)); scroll.found {scroll.position.y = 0}
	}
	layout(&ui)
	rl.PushKey(.LEFT_SHIFT, true)
	rl.PushKey(.TAB, true)
	handle_chat(&ui, client)
	rl.PushKey(.TAB, false)
	rl.PushKey(.LEFT_SHIFT, false)
	rl.WindowShouldClose()
	layout(&ui)
	last_chip := nendo.id("NCRetention4")
	chip := nendo.element(last_chip)
	if !testing.expect(t, chip.found) {return}
	box = chip.rect
	nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
	testing.expect(t, nendo.pointer_over(last_chip), "Shift+Tab reveals 4w through both panes")
	nendo.set_pointer({0, 0}, .Up)
	rl.PushKey(.SPACE, true)
	handle_chat(&ui, client)
	rl.PushKey(.SPACE, false)
	rl.WindowShouldClose()
	testing.expect_value(t, ui.nc_retention, 2419200)
	close_new_chat(&ui)
}
