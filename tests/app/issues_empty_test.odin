package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// Exercise the chat header and empty-state controls through real layout hit
// testing and chat dispatch. Run separately with SDL_VIDEODRIVER=dummy.
@(test)
issues_empty_state :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "issues_empty_state" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp(
		os.get_env("TMPDIR", context.temp_allocator),
		"wn-issues-*",
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
	defer timeline_stop()
	rl.InitWindow(1280, 800, "Issues empty state")
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
		issue_setting    = .Enabled,
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "Project discussion"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; issue_page = nil; forced_release = false}

	layout :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		commands: clay.ClayArray(clay.RenderCommand)
		for frame in 0 ..< 3 {commands = build_layout(ui, 0)}
		return commands
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, id: string) {
		data := clay.GetElementData(clay.ID(id))
		testing.expect(t, data.found, id)
		if !data.found {return}
		box := data.boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		forced_release = true
		handle_chat(ui, client)
		forced_release = false
		clay.SetPointerState({0, 0}, false)
	}
	for locale in ([]string{"en", "it", "de", "ja"}) {
		set_locale(locale)
		for width in ([]i32{1280, 420}) {
			rl.SetWindowSize(width, 800)
			clay.SetLayoutDimensions({f32(width), 800})
			ui.issues_open, ui.issue_new = false, false
			ui.issue_selected = ""
			layout(&ui)
			click(t, &ui, client, "IssuesBtn")
			testing.expect(t, ui.issues_open, "header opens Issues")
			commands := layout(&ui)
			for id in ([]string{"IssueNoIssues", "IssueNew", "IssueClose"}) {
				data := clay.GetElementData(clay.ID(id))
				testing.expect(t, data.found, id)
				if data.found {
					box := data.boundingBox
					testing.expect(
						t,
						box.width > 0 &&
						box.height > 0 &&
						box.x >= 0 &&
						box.x + box.width <= f32(width) + 1,
						id,
					)
				}
			}
			for id in ([]string{"IssueSidebar", "IssueSearch", "IssueFilterToggle", "IssueEmptyList", "IssueEmpty"}) {
				testing.expect(t, !clay.GetElementData(clay.ID(id)).found, id)
			}
			// Optional captures use the actual application renderer, not a mockup.
			if dir := os.get_env("WN_ISSUES_CAPTURE_DIR", context.temp_allocator); dir != "" {
				rl.BeginDrawing(); draw_frame(&commands)
				rl.TakeScreenshot(fmt.ctprintf("%s/empty-%s-%d.png", dir, locale, width))
				rl.EndDrawing()
			}
			click(t, &ui, client, "IssueNew")
			testing.expect(t, ui.issue_new, "empty-state action opens composer")
			testing.expect_value(t, ui.focus, Focus.Issue_Subject)
			layout(&ui)
			testing.expect(t, clay.GetElementData(clay.ID("IssueForm")).found)
			click(t, &ui, client, "IssueBack")
			testing.expect(t, !ui.issue_new)
			layout(&ui)
			testing.expect(t, clay.GetElementData(clay.ID("IssueNoIssues")).found)
			click(t, &ui, client, "IssueClose")
			testing.expect(t, !ui.issues_open, "empty state returns to chat")
		}
	}
	// Existing issues hidden by search or status are not an empty group.
	set_locale("en")
	rl.SetWindowSize(1280, 800)
	clay.SetLayoutDimensions({1280, 800})
	root := strings.repeat("a", 64, context.temp_allocator)
	author := strings.repeat("b", 64, context.temp_allocator)
	values := []cstring{"subject", "Report"}
	tags := []marmot.Message_Tag{{raw_data(values), uint(len(values))}}
	records := []marmot.App_Message_Record {
		{
			message_id_hex = strings.clone_to_cstring(root, context.temp_allocator),
			sender = strings.clone_to_cstring(author, context.temp_allocator),
			group_id_hex = "group",
			plaintext = "Body",
			kind = 1621,
			recorded_at = 1,
			tags = raw_data(tags),
			tags_len = uint(len(tags)),
		},
	}
	page := marmot.App_Message_List{raw_data(records), uint(len(records))}
	issue_page = &page
	ui.issues, ui.issue_index = issues_project(records, "group", 10)
	defer issues_rows_free(ui.issues, ui.issue_index)
	ui.issues_open = true
	for filtered in 0 ..< 2 {
		clear(&ui.issue_search)
		ui.issue_filter = filtered == 0 ? 0 : 2
		if filtered == 0 {append(&ui.issue_search, "no match")}
		layout(&ui)
		testing.expect(t, !clay.GetElementData(clay.ID("IssueNoIssues")).found)
		for id in ([]string{"IssueSidebar", "IssueSearch", "IssueFilterToggle", "IssueEmptyList"}) {
			testing.expect(t, clay.GetElementData(clay.ID(id)).found, id)
		}
	}
}
