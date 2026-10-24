package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL and Clay own process globals; run this separately in the canonical suite.
@(test)
group_files_refresh_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "group_files_refresh_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp(
		os.get_env("TMPDIR", context.temp_allocator),
		"wn-files-*",
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
	rl.InitWindow(1024, 700, "Group files refresh")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		page             = .Chats,
		selected         = 0,
		group_files_open = true,
		row_menu         = -1,
		member_menu      = -1,
		audit_scanned    = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	append(&ui.chats, Chat_Row_Ui{group_id = "offline-chat", title = "Example chat"})
	defer {delete(ui.accounts); delete(ui.chats)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; cursor_want = .Default}

	gate: sync.Sema
	job := Group_Files_Job {
		account = "",
		group   = "offline-chat",
	}
	job.worker = thread.create(proc(t: ^thread.Thread) {sync.sema_wait((^sync.Sema)(t.data))})
	job.worker.data = &gate
	thread.start(job.worker)
	group_files_job = &job
	defer {
		if job.worker != nil {
			sync.sema_post(&gate)
			thread.join(job.worker)
			thread.destroy(job.worker)
		}
		group_files_job = nil
	}
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		cursor_want = .Default
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	hover :: proc(
		t: ^testing.T,
		ui: ^Ui_State,
		name: string,
	) -> clay.ClayArray(clay.RenderCommand) {
		box := clay.GetElementData(clay.ID(name))
		testing.expect(t, box.found)
		b := box.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		testing.expect(t, clay.PointerOver(clay.ID(name)))
		return frame(ui)
	}
	check :: proc(t: ^testing.T, commands: clay.ClayArray(clay.RenderCommand), ready: bool) {
		found := false
		highlight := false
		loading := false
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Rectangle && command.id == clay.ID("GroupFilesRefresh").id {
				highlight = command.renderData.rectangle.backgroundColor == HOVER
			}
			if command.commandType != .Text {continue}
			data := command.renderData.text
			text := string(data.stringContents.chars[:data.stringContents.length])
			if text == tr("Loading…") {loading = true}
			if text == tr("Refresh") {
				found = true
				testing.expect_value(t, data.textColor, ready ? TEXT_DIM : TEXT_LO)
			}
		}
		testing.expect(t, found, "Refresh label is rendered")
		testing.expect_value(t, highlight, ready)
		testing.expect_value(
			t,
			cursor_want,
			ready ? rl.Cursor_Shape.Pointer : rl.Cursor_Shape.Default,
		)
		testing.expect_value(t, loading, !ready)
	}
	clay.SetPointerState({-100, -100}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	check(t, hover(t, &ui, "GroupFilesRefresh"), false)
	forced_release = true
	handle_chat(&ui, client)
	forced_release = false
	testing.expect(t, group_files_job == &job && job.worker != nil)
	testing.expect(t, !sync.atomic_load(&job.cancel), "a busy click must not restart the scan")

	// Back remains reachable while a scan is in flight.
	hover(t, &ui, "GroupFilesBack")
	forced_release = true
	handle_chat(&ui, client)
	forced_release = false
	testing.expect(t, !ui.group_files_open)
	ui.group_files_open = true

	// Completion is consumed by the real lifecycle tick before rendering.
	sync.sema_post(&gate)
	thread.join(job.worker)
	group_files_tick(&ui, nil)
	testing.expect(t, job.worker == nil)
	for _ in 0 ..< 3 {frame(&ui)}
	check(t, hover(t, &ui, "GroupFilesRefresh"), true)
	forced_release = true
	handle_chat(&ui, client)
	forced_release = false
	testing.expect(t, sync.atomic_load(&job.cancel), "completed scan can be refreshed")

	// A failed scan must still offer a usable retry.
	sync.atomic_store(&job.cancel, false)
	job.err = "Couldn't load files. Please try again."
	frame(&ui)
	check(t, hover(t, &ui, "GroupFilesRefresh"), true)
	forced_release = true
	handle_chat(&ui, client)
	forced_release = false
	testing.expect(t, sync.atomic_load(&job.cancel), "error can be retried through chat dispatch")
}
