package main

import profile_runtime "base:runtime"
import profile_mem "core:mem"
import profile_testing "core:testing"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=compose_profile_ownership
@(test)
compose_profile_ownership :: proc(t: ^profile_testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "compose_profile_ownership" {return}
	context.allocator = profile_runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	rl.InitWindow(1200, 800, "Profile ownership regression")
	defer rl.CloseWindow()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	defer wrap_clear()

	dir, err := os.make_directory_temp("/tmp", "wn-profile-ownership-*", context.temp_allocator)
	if !profile_testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !profile_testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	old_client, old_ui := g_client, g_ui
	defer {g_client, g_ui = old_client, old_ui}
	ui: Ui_State
	g_client, g_ui = client, &ui

	token := "@npub1klkk3vrzme455yh9rl2jshq7rc8dpegj3ndf82c3ks2sk40dxt7qulx3vt"
	id := mention_hex(token)
	profile_testing.expect_value(t, len(id), 64)
	// The renderer's glyph map outlives the profile allocation tracker.
	rl.MeasureTextLine(FONT_TITLE, BODY_FS, fmt.tprintf("@%s", short_hex(id)), 0)

	track: profile_mem.Tracking_Allocator
	profile_mem.tracking_allocator_init(&track, context.allocator)
	defer profile_mem.tracking_allocator_destroy(&track)
	track.bad_free_callback = profile_mem.tracking_allocator_bad_free_callback_add_to_array
	context.allocator = profile_mem.tracking_allocator(&track)

	compose_lines(token)
	profile_testing.expect(
		t,
		profile_pending_ids[id],
		"measuring an unseen mention queues its profile",
	)
	drain_refresh(client, &ui)
	deadline := time.tick_now()
	for profile_batch != nil && time.duration_seconds(time.tick_since(deadline)) < 5 {
		time.sleep(time.Millisecond)
		drain_refresh(client, &ui)
	}
	profile_testing.expect(t, profile_batch == nil, "profile read completes")
	profile_testing.expect(t, !profile_pending_ids[id], "completed profile leaves the pending set")
	profile_reads_stop()
	profile_session_clear()
	for key in refresh_asked {delete(key)}
	delete(refresh_asked); refresh_asked = nil
	for key in refresh_queue {delete(key)}
	delete(refresh_queue); refresh_queue = {}
	delete(profile_cache); profile_cache = nil
	delete(profile_order); profile_order = {}
	profile_checked = -1
	profile_cursor = 0
	refresh_stopping = false
	refresh_client = nil
	profile_testing.expect_value(t, len(track.bad_free_array), 0)
	profile_testing.expect_value(t, len(track.allocation_map), 0)
}
