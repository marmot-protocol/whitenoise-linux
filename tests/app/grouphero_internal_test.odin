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
		// Exercise Crop and Reset through real modal hit testing. Neither may
		// dispatch uploads or replace the source/committed avatar.
		original_data := ui.photo.draft.data
		box := clay.GetElementData(clay.ID("PhotoCrop")).boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		forced_release = true
		handle_photo_preview(&ui, nil)
		forced_release = false
		testing.expect(t, ui.photo.crop.active)
		photo_test_layout(&ui)
		testing.expect(t, clay.GetElementData(clay.ID("PhotoCropBox")).found)
		box = clay.GetElementData(clay.ID("PhotoReset")).boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		forced_release = true
		handle_photo_preview(&ui, nil)
		forced_release = false
		testing.expect(t, !ui.photo.crop.active)
		testing.expect(t, raw_data(ui.photo.draft.data) == raw_data(original_data))
		testing.expect(t, !ppic_busy && len(gimg_queue) == 0 && len(gpic_local) == 0)
		photo_crop_start(&ui.photo)
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
	defer photo_crop_stop()
	// Cancellation wins even if encoding has completed before this frame.
	photo_crop_start(&ui.photo)
	photo_use(&ui, client)
	crop_job := ui.photo.crop_job
	if !testing.expect(t, crop_job != nil) {return}
	thread.join(crop_job.worker)
	photo_test_layout(&ui)
	testing.expect(t, clay.GetElementData(clay.ID("PhotoCropBusy")).found)
	photo_crop_drain(&ui, client, false)
	testing.expect_value(t, len(gimg_queue), 0)
	rl.PushKey(.ESCAPE, true)
	handle_photo_preview(&ui, client)
	rl.PushKey(.ESCAPE, false)
	photo_crop_drain(&ui, client)
	testing.expect(t, !photo_input_capture(&ui) && len(gimg_queue) == 0)

	// A completed crop cannot upload after permission/account/busy changes.
	for invalidation in ([]string{"permission", "account", "busy"}) {
		testing.expect(t, photo_pick_begin(&ui, .Group))
		photo_pick_complete(&ui, []string{path})
		photo_crop_start(&ui.photo)
		photo_use(&ui, client)
		thread.join(ui.photo.crop_job.worker)
		switch invalidation {
		case "permission": ui.members[0].is_admin = false
		case "account": ui.account_ref = "account-b"
		case "busy": ppic_busy = true
		}
		photo_crop_drain(&ui, client)
		testing.expect(t, !photo_input_capture(&ui) && len(gimg_queue) == 0)
		ui.members[0].is_admin = true; ui.account_ref = "account-a"; ppic_busy = false
	}
	// Use runs a real encoder worker, then transfers only the PNG result.
	testing.expect(t, photo_pick_begin(&ui, .Group))
	photo_pick_complete(&ui, []string{path})
	photo_crop_start(&ui.photo)
	photo_use(&ui, client)
	testing.expect(t, ui.photo.crop_job != nil && len(gimg_queue) == 0)
	thread.join(ui.photo.crop_job.worker)
	photo_crop_drain(&ui, client)
	testing.expect_value(t, len(gimg_queue), 1)
	testing.expect_value(t, gimg_queue[0].account, "account-a")
	testing.expect_value(t, gimg_queue[0].group_id, "group-a")
	testing.expect_value(t, gimg_queue[0].media_type, "image/png")
	uploaded := rl.LoadImageFromMemory(".png", raw_data(gimg_queue[0].data), i32(len(gimg_queue[0].data)))
	testing.expect(t, uploaded.data != nil && uploaded.width == 1 && uploaded.height == 1)
	rl.UnloadImage(uploaded)
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
