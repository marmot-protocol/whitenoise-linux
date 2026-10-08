// Appended to grouphero.odin by tests/odin.sh for private queue inspection.
package main

import "base:runtime"
import "core:testing"

photo_test_layout :: proc(ui: ^Ui_State) {
	clay.BeginLayout()
	if clay.UI(clay.ID("PhotoTestRoot"))({layout = {sizing = {width = clay.SizingFixed(320), height = clay.SizingFixed(300)}}}) {
		photo_preview_modal(ui)
	}
	clay.EndLayout(1.0 / 60)
}

// Run alone: SDL_VIDEODRIVER=dummy tests/odin.sh app
// -define:ODIN_TEST_NAMES=photo_preview_flow
@(test)
photo_preview_flow :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "photo_preview_flow" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	rl.InitWindow(320, 300, "Photo preview regression")
	defer rl.CloseWindow()
	defer profile_session_clear()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0); set_locale("en")
	memory: []u8
	init_layout(&memory, 32768, {320, 300})
	defer delete(memory)
	ui := photo_test_ui()
	defer photo_test_free(&ui)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false}
	dir, err := os.make_directory_temp("", "wn-photo-preview", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/photo.webp", dir)
	bytes := photo_test_bytes()
	defer delete(bytes)
	testing.expect(t, os.write_entire_file(path, bytes) == nil)
	old_local := gpic_local
	gpic_local = make(map[string]string)
	defer {
		for key, value in gpic_local {delete(key); delete(value)}
		delete(gpic_local); gpic_local = old_local
		for job in gimg_queue {delete(job.account); delete(job.group_id); delete(job.data)}
		delete(gimg_queue); gimg_queue = {}; gimg_uploads = 0
	}

	for kind in ([]Photo_Kind{.Profile, .Group}) {
		testing.expect(t, photo_pick_begin(&ui, kind))
		photo_pick_complete(&ui, []string{path})
		testing.expect(t, ui.photo.texture.tex != nil && ui.photo.draft.image.data != nil)
		testing.expect(t, !ppic_busy && len(gimg_queue) == 0 && len(gpic_local) == 0, "Staging does not dispatch or change the avatar")
		photo_test_layout(&ui)
		for id in ([]string{"PhotoPreview", "PhotoImage", "PhotoUse", "PhotoCancel"}) {
			box := clay.GetElementData(clay.ID(id))
			testing.expect(t, box.found)
			testing.expect(t, box.boundingBox.y >= 0 && box.boundingBox.y + box.boundingBox.height <= 300)
		}
		captured := photo_input_capture(&ui)
		photo_cancel(&ui)
		testing.expect(t, captured && !photo_input_capture(&ui), "The closing frame retains its input latch")
		testing.expect(t, ui.photo.draft.data == nil && ui.photo.texture.tex == nil)
	}

	// Replacement frees the earlier decoded draft and texture.
	testing.expect(t, photo_pick_begin(&ui, .Group))
	photo_pick_complete(&ui, []string{path})
	testing.expect(t, photo_pick_begin(&ui, .Profile))
	testing.expect(t, ui.photo.draft.image.data == nil && ui.photo.texture.tex == nil)
	photo_pick_complete(&ui, nil)

	testing.expect(t, photo_pick_begin(&ui, .Group))
	photo_pick_complete(&ui, []string{path})
	ppic_busy = true
	testing.expect(t, !photo_can_use(&ui))
	ppic_busy = false
	job := Account_Job{account = "account-a", kind = .Profile}
	old_jobs := account_jobs
	account_jobs = {}
	defer {delete(account_jobs); account_jobs = old_jobs}
	append(&account_jobs, &job)
	testing.expect(t, !photo_can_use(&ui))
	clear(&account_jobs)
	testing.expect(t, photo_can_use(&ui))

	// Real runtime handle; no image worker is started in this queue test.
	client: ^marmot.Client
	if !testing.expect_value(t, marmot.client_new(strings.clone_to_cstring(dir, context.temp_allocator), nil, 0, &client), marmot.Status.OK) {return}
	defer marmot.client_free(client)
	photo_use(&ui, client)
	testing.expect_value(t, len(gimg_queue), 1)
	testing.expect_value(t, gimg_queue[0].account, "account-a")
	testing.expect_value(t, gimg_queue[0].group_id, "group-a")
	testing.expect_value(t, len(gimg_queue[0].data), len(bytes))
	testing.expect(t, ui.photo.draft.data == nil && ui.photo.texture.tex == nil)
	photo_use(&ui, client)
	testing.expect(t, len(gimg_queue) == 1, "Use transfers the draft exactly once")
	// Local cache registration is allowed only after Use.
	testing.expect_value(t, len(gpic_local), 1)
	gimg_uploads = 0

	// Pointer cancellation uses the real modal handler and hit testing.
	testing.expect(t, photo_pick_begin(&ui, .Group))
	photo_pick_complete(&ui, []string{path})
	photo_test_layout(&ui)
	clay.SetPointerState({0, 0}, false)
	forced_release = true
	handle_photo_preview(&ui, client)
	forced_release = false
	testing.expect(t, !photo_input_capture(&ui))
	testing.expect_value(t, len(gimg_queue), 1)

	for action in ([]string{"escape", "cancel"}) {
		testing.expect(t, photo_pick_begin(&ui, .Profile))
		photo_pick_complete(&ui, []string{path})
		photo_test_layout(&ui)
		if action == "escape" {
			rl.PushKey(.ESCAPE, true)
		} else {
			box := clay.GetElementData(clay.ID("PhotoCancel")).boundingBox
			clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
			forced_release = true
		}
		handle_photo_preview(&ui, client)
		rl.PushKey(.ESCAPE, false); forced_release = false
		testing.expect(t, !photo_input_capture(&ui))
		testing.expect_value(t, len(gimg_queue), 1)
	}

	// Profile Use starts exactly one real worker. This disposable runtime has
	// no account, so the upload fails locally rather than contacting relays.
	testing.expect(t, photo_pick_begin(&ui, .Profile))
	photo_pick_complete(&ui, []string{path})
	before := len(send_threads)
	photo_use(&ui, client)
	testing.expect(t, ppic_busy && ui.photo.draft.data == nil)
	testing.expect_value(t, len(send_threads), before + 1)
	photo_use(&ui, client)
	testing.expect_value(t, len(send_threads), before + 1)
	worker := send_threads[before]
	thread.join(worker); thread.destroy(worker)
	ordered_remove(&send_threads, before)
	delete(ui.client_status); ui.client_status = ""
	ui.account_ref = "account-b"
	drain_ppic(&ui)
	testing.expect(t, !ppic_busy && !ui.profile.pic_set && ui.my_pic_url == "")
	ui.account_ref = "account-a"

	testing.expect(t, photo_pick_begin(&ui, .Profile))
	photo_pick_complete(&ui, []string{path})
	locked := Ui_State{photo = ui.photo}
	ui.photo = {}
	lock_scrub_ui(&locked)
	testing.expect(t, !photo_input_capture(&locked))
	testing.expect(t, locked.photo.draft.image.data == nil && locked.photo.texture.tex == nil)
}
