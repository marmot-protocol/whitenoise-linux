package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"
import rl "sdlrl"

@(test)
message_storage_released :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	for _ in 0 ..< 1000 {
		msg := Msg_Ui{id = strings.clone("message"), body = strings.repeat("x", 1024)}
		cells := make([][]string, 1)
		cells[0] = make([]string, 1)
		cells[0][0] = strings.clone("cell")
		append(&msg.blocks, Md_Block_Ui{kind = .Table, cells = cells})
		opt := Poll_Opt_Ui{id = strings.clone("option"), label = strings.clone("label")}
		append(&opt.blocks, Md_Block_Ui{text = strings.clone("option paragraph")})
		append(&msg.poll_opts, opt)
		append(&msg.reactions, Reaction_Ui{label = strings.clone("+ 1"), emoji = strings.clone("+"), count = strings.clone("1"), who = strings.clone("Alice")})
		append(&msg.history, Edit_Version{strings.clone("12:00"), strings.clone("old")})
		append(&msg.att_names, strings.clone("picture.png"))
		append(&msg.att_keys, strings.clone("hash"))
		append(&msg.img_failed, Att_Item(string){strings.clone("hash"), 0})
		append(&msg.media_pending, Media_Pending{1, .Image})
		message_free(msg)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
wrapped_line_cache :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	wrap_clear()
	defer wrap_clear()
	text := "first\n\n日本語\nlast"
	lines := wrapped_lines(text, 0, 14)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0].index, u32(0))
	testing.expect_value(t, lines[1].index, u32(3))
	testing.expect_value(t, text[lines[1].start:lines[1].end], "日本語")
	again := wrapped_lines(text, 0, 14)
	testing.expect(t, raw_data(lines) == raw_data(again))
	wrapped_lines(text, 120, 14)
	wrapped_lines(text, 120, 16)
	testing.expect_value(t, len(wrap_cache), 3)
}

@(test)
message_reuse_guards :: proc(t: ^testing.T) {
	record := marmot.Timeline_Message_Record{kind = 9, sender = "alice", plaintext = "hello", timeline_at = 1000}
	msg := Msg_Ui{body = "hello", sender = "Alice", sender_id = "alice",
		at = format_when(1000), at_full = format_full(1000), day = format_day(1000)}
	defer delete(msg.at); defer delete(msg.at_full); defer delete(msg.day)
	testing.expect(t, message_matches(msg, &record, "Alice", ""))
	testing.expect(t, !message_matches(msg, &record, "Renamed", ""))
	record.deleted = true
	testing.expect(t, !message_matches(msg, &record, "Alice", ""))
	record.deleted = false
	record.reactions.by_emoji_len = 1
	testing.expect(t, !message_matches(msg, &record, "Alice", ""))
	record.reactions.by_emoji_len = 0
	record.plaintext = "edited"
	testing.expect(t, !message_matches(msg, &record, "Alice", ""))
}

@(test)
media_reference_owned :: proc(t: ^testing.T) {
	old_jobs, old_inflight := media_jobs, media_inflight
	media_jobs, media_inflight = {}, nil
	defer {
		for job in media_jobs { media_job_free(job) }
		delete(media_jobs); delete(media_inflight)
		media_jobs, media_inflight = old_jobs, old_inflight
	}
	locator := marmot.Media_Locator{value = "https://example.test/blob"}
	ref := marmot.Media_Attachment_Reference{locators = &locator, locators_len = 1,
		file_name = "picture.png", plaintext_sha256 = "hash", nonce_hex = "nonce", media_type = "image/png"}
	media_enqueue(nil, "account", "group", &ref, .Image, "hash")
	media_enqueue(nil, "account", "group", &ref, .Image, "hash")
	testing.expect_value(t, len(media_jobs), 1)
	job := media_jobs[0]
	testing.expect(t, job.reference.locators != ref.locators)
	testing.expect(t, rawptr(job.reference.nonce_hex) != rawptr(ref.nonce_hex))
	locator.value = "changed"
	testing.expect_value(t, string(job.reference.locators[0].value), "https://example.test/blob")
	items: [dynamic]Att_Item(int)
	defer delete(items)
	media_insert(&items, Att_Item(int){3, 3})
	media_insert(&items, Att_Item(int){1, 1})
	testing.expect_value(t, items[0].att, 1)
}

@(test)
performance_media :: proc(t: ^testing.T) {
	when !#config(WN_PERF, false) { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(100, 100, "Media worker regression")
	defer rl.CloseWindow()
	data_home = fmt.aprintf("/tmp/wn-media-worker-%d", time.now()._nsec)
	defer delete(data_home)
	os.make_directory(data_home)
	os.make_directory(media_cache_dir())
	defer os.remove_all(data_home)
	// Only a blob key is needed; avoid networking and password-KDF timing.
	g_vault = Vault{unlocked = true, key = {0 = 1, 1 = 2, 2 = 3}}
	defer g_vault = {}
	ui: Ui_State
	append(&ui.messages, Msg_Ui{id = strings.clone("one")})
	defer { message_free(ui.messages[0]); delete(ui.messages) }
	for i in 0 ..< 5 {
		key := fmt.aprintf("%064d", i)
		name := fmt.aprintf("file-%d.txt", i)
		body := fmt.aprintf("# File %d\n\nWorker text.", i)
		mime: cstring = "text/plain"
		bytes := transmute([]u8)body
		if i >= 3 {
			delete(name); delete(body)
			path := i == 3 ? "twemoji/1f600.png" : "fonts/LiberationSans-Regular.ttf"
			read_err: os.Error
			bytes, read_err = os.read_entire_file(fmt.tprintf("%s/%s", res_dir(), path), context.allocator)
			testing.expect_value(t, read_err, nil)
			body = string(bytes)
			name = strings.clone(i == 3 ? "image.png" : "font.ttf")
			mime = i == 3 ? "image/png" : "font/ttf"
		}
		sealed, ok := vault_seal_blob(bytes)
		testing.expect(t, ok)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.bin", media_cache_dir(), key), sealed) == nil)
		ref := marmot.Media_Attachment_Reference{
			plaintext_sha256 = strings.clone_to_cstring(key), file_name = strings.clone_to_cstring(name), media_type = mime}
		media_attach(&ui.messages[0], nil, "account", "group", &ref, i)
		delete(ref.plaintext_sha256); delete(ref.file_name)
		delete(key); delete(name); delete(body); delete(sealed)
	}
	testing.expect_value(t, len(media_jobs), 5)
	media_drain(&ui)
	active := 0
	for job in media_jobs { if job.worker != nil { active += 1 } }
	testing.expect_value(t, active, MEDIA_WORKERS)
	start := time.tick_now()
	for len(media_jobs) > 0 && time.tick_since(start) < 5 * time.Second {
		rl.Wait(50)
		rl.WindowShouldClose()
		media_drain(&ui)
	}
	testing.expect_value(t, len(media_jobs), 0)
	testing.expect_value(t, len(ui.messages[0].media_pending), 0)
	testing.expect_value(t, len(ui.messages[0].txts), 3)
	testing.expect_value(t, len(ui.messages[0].images), 1)
	testing.expect_value(t, len(ui.messages[0].fonts), 1)
	testing.expect_value(t, ui.messages[0].images[0].view.width, i32(72))
	testing.expect_value(t, ui.messages[0].fonts[0].view.w, i32(640))
	for entry, i in ui.messages[0].txts {
		testing.expect_value(t, entry.att, i)
		testing.expect_value(t, entry.view.blocks[0].text, fmt.tprintf("File %d", i))
	}
	fmt.printf("media workers=%d completed=5 timeline_reloads=0\n", MEDIA_WORKERS)
	media_stop()
	for key, view in txt_views { txt_view_free(view); delete(key) }
	delete(txt_views)
	for key, tex in media_textures { rl.UnloadTexture(tex^); free(tex); delete(key) }
	delete(media_textures)
	for key, view in ttf_views { ttf_view_free(view); delete(key) }
	delete(ttf_views)
	for key in blob_sizes { delete(key) }
	delete(blob_sizes)
	delete(media_jobs); delete(media_inflight)
}

// Run separately so SDL and the global font/layout state have one owner:
// SDL_VIDEODRIVER=dummy odin test app -o:speed -define:ODIN_TEST_NAMES=performance_layout -define:WN_PERF=true
@(test)
performance_layout :: proc(t: ^testing.T) {
	when !#config(WN_PERF, false) { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Performance regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 131072, {1200, 800})
	defer delete(memory)
	ui := Ui_State{row_menu = -1, member_menu = -1, selected_contact = -1}
	g_ui, g_prefs = &ui, &ui.prefs
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Timeline"})
	for i in 0 ..< 1000 {
		append(&ui.messages, Msg_Ui{id = fmt.aprintf("message-%d", i),
			sender = strings.clone("Alice"), body = fmt.aprintf("Message %d. A paragraph with several words to wrap across the conversation pane.", i)})
	}
	defer {
		for msg in ui.messages { message_free(msg) }
		delete(ui.messages)
		delete(ui.chats)
		delete(ui.accounts)
		wrap_clear()
		g_ui, g_prefs = nil, nil
	}
	for _ in 0 ..< 3 { anim_tick(1.0 / 60); build_layout(&ui, 1.0 / 60) }
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	testing.expect(t, data.found)
	data.scrollPosition.y = -(data.contentDimensions.height - data.scrollContainerDimensions.height)
	full, windowed: [7]f64
	full_height: f32
	for pass in 0 ..< 2 {
		for sample in 0 ..< 7 {
			if pass == 0 { for &msg in ui.messages { msg.row_height = 0 } }
			anim_tick(1.0 / 60)
			start := time.tick_now()
			build_layout(&ui, 1.0 / 60)
			ms := time.duration_milliseconds(time.tick_since(start))
			if pass == 0 { full[sample] = ms } else { windowed[sample] = ms }
			testing.expect(t, !layout_overflow)
		}
		if pass == 0 { full_height = clay.GetScrollContainerData(clay.ID("Timeline")).contentDimensions.height }
	}
	real := 0
	for _, i in ui.messages { if clay.GetElementData(clay.ID("MsgHead", u32(i))).found { real += 1 } }
	testing.expect(t, real > 0 && real < 100, "Only the viewport and overscan should build message bodies")
	testing.expect(t, abs(clay.GetScrollContainerData(clay.ID("Timeline")).contentDimensions.height - full_height) < 1)
	testing.expect(t, clay.GetElementData(clay.ID("MsgHead", 999)).found)
	slice.sort(full[:]); slice.sort(windowed[:])
	fmt.printf("layout rows=1000 mounted=%d median_ms full=%.3f windowed=%.3f\n", real, full[3], windowed[3])
	commands := build_layout(&ui, 0)
	rl.BeginDrawing()
	draw_frame(&commands)
	rl.TakeScreenshot("/tmp/wn-performance-layout.png")
	rl.EndDrawing()
	// A direct jump and a width change must rebuild previously hidden content.
	ui.jump_id = strings.clone("message-0")
	build_layout(&ui, 0)
	testing.expect(t, clay.GetElementData(clay.ID("MsgHead", 0)).found)
	delete(ui.jump_id); ui.jump_id = ""
	ui.timeline_metric.x -= 100
	testing.expect(t, !timeline_skip(&ui, ui.messages[0]))
	// Scroll to the middle, then grow content above it without moving the reader.
	data.scrollPosition.y = -full_height / 2
	build_layout(&ui, 0)
	anchor := -1
	for msg, i in ui.messages {
		if msg.row_top + data.scrollPosition.y >= 0 { anchor = i; break }
	}
	testing.expect(t, anchor > 0)
	testing.expect(t, clay.GetElementData(clay.ID("MsgHead", u32(anchor))).found)
	anchor_y := ui.messages[anchor].row_top + data.scrollPosition.y
	delete(ui.messages[0].body)
	ui.messages[0].body = strings.clone("A newly decoded attachment.\nLine two.\nLine three.\nLine four.")
	ui.messages[0].row_height = 0
	build_layout(&ui, 0)
	build_layout(&ui, 0)
	testing.expect(t, abs(ui.messages[anchor].row_top + data.scrollPosition.y - anchor_y) < 1,
		"Growing a row above the viewport must preserve the reading position")
	// Thread completion wakes a sleeping UI and leaves the event queued.
	rl.WindowShouldClose()
	worker := thread.create(proc(_: ^thread.Thread) { time.sleep(20 * time.Millisecond); frame_wake() })
	thread.start(worker)
	start := time.tick_now()
	rl.Wait(1000)
	ms := time.duration_milliseconds(time.tick_since(start))
	thread.join(worker); thread.destroy(worker)
	input: bool
	rl.WindowShouldClose(&input)
	testing.expect(t, input && ms < 500, "Worker completion must interrupt the idle wait")
	fmt.printf("idle worker_wake_ms=%.3f fallback_max_hz=4\n", ms)
	// Unrelated accounts cannot dirty the selected timeline.
	live := Live{}
	append(&live.dirty_groups, Live_Change{account = strings.clone("other"), group = strings.clone("test")})
	drain_live(&live, &ui, nil)
	delete(live.dirty_groups)
	testing.expect_value(t, ui.selected, 0)
	_ = marmot.Runtime_Event{} // compile the scoped event mirror with this check
}
