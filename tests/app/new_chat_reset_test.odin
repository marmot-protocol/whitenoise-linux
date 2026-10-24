package main

import "base:runtime"
import "core:os"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:strings"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

// Run separately: SDL_VIDEODRIVER=dummy tests/odin.sh app
// -define:ODIN_TEST_NAMES=new_chat_reset_dispatch
@(test)
new_chat_reset_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "new_chat_reset_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp(
		os.get_env("TMPDIR", context.temp_allocator),
		"wn-new-chat-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
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
	rl.InitWindow(1280, 800, "New chat reset")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1280, 800})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		prefs            = default_prefs(),
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs.reduce_motion = true
	// No signed-in account: the real opener cannot start a contact worker.
	append(&ui.accounts, "Offline fixture")
	append(&ui.chats, Chat_Row_Ui{group_id = "fixture", title = "Fixture chat"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false}


	layout :: proc(ui: ^Ui_State) {

		for _ in 0 ..< 3 {build_layout(ui, 0)}
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, id: clay.ElementId) {

		data := clay.GetElementData(id)
		if !testing.expect(t, data.found, "navigation control must exist") {return}
		box := data.boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		forced_release = true
		handle_pages(ui, client)
		if ui.page == .Chats {handle_chat(ui, client)}
		// Same frame-end dismissal used by main after page dispatch.
		if ui.new_chat_open && ui.page != .Chats {close_new_chat(ui)}
		forced_release = false
		clay.SetPointerState({0, 0}, false)
	}
	for cancel in ([]bool{false, true}) {
		layout(&ui)
		click(t, &ui, client, clay.ID("NewChatBtn"))
		testing.expect(t, ui.new_chat_open)
		layout(&ui)
		click(t, &ui, client, clay.ID("NCGroup"))
		testing.expect(t, ui.nc_page == .Group)
		ed_insert(&ui, &ui.nc_name, "Abandoned group")

		testing.expect_value(t, string(ui.nc_name[:]), "Abandoned group")
		layout(&ui)
		if cancel {
			click(t, &ui, client, clay.ID("NCCancel"))
		} else {
			click(t, &ui, client, clay.ID("Nav", u32(Page.Settings)))
			testing.expect_value(t, ui.page, Page.Settings)
		}
		testing.expect(t, !ui.new_chat_open)
		if !cancel {
			layout(&ui)
			click(t, &ui, client, clay.ID("Nav", u32(Page.Chats)))
		}
		layout(&ui)
		click(t, &ui, client, clay.ID("NewChatBtn"))
		testing.expect(t, len(ui.nc_name) == 0, "a fresh form must not retain the abandoned name")
		layout(&ui)
		click(t, &ui, client, clay.ID("NCGroup"))
		testing.expect(t, len(ui.nc_name) == 0, "group field starts empty")
		layout(&ui)
		click(t, &ui, client, clay.ID("NCCancel"))
	}
	// The intentional DM-to-group prefill is applied after the fresh reset.
	peer := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	ui.chats[0].conversation_kind = .DIRECT
	ui.chats[0].peer_hex = peer
	ui.show_members = true
	ui.info_tab = .Members
	ed_set(&ui, &ui.nc_name, "Old group")
	layout(&ui)
	click(t, &ui, client, clay.ID("DmStartGroup"))
	testing.expect(t, ui.new_chat_open && ui.nc_page == .Group)
	testing.expect_value(t, string(ui.nc_member[:]), peer)
	testing.expect(t, len(ui.nc_name) == 0)
	testing.expect(t, ui.focus == .NC_Name)
}
