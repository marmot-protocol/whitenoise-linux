package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
group_files_filter_history :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		group_file_type("PHOTO.PNG", "application/octet-stream"),
		Group_File_Type.Images,
	)
	testing.expect_value(t, group_file_type("notes.txt", ""), Group_File_Type.Documents)
	for item in ([]struct {
			name, mime: string,
			kind:       Group_File_Type,
		}{{"photo.png", "image/png", .Images}, {"ANIM.GIF", "", .Images}, {"film.mp4", "", .Videos}, {"voice.ogg", "", .Audio}, {"plan.pdf", "", .Documents}, {"notes.txt", "text/plain", .Documents}, {"table.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", .Documents}, {"backup.zip", "", .Archives}, {"part.stl", "", .Models}, {"font.ttf", "", .Fonts}, {"game.xdc", "", .Apps}, {"unknown.bin", "", .Other}}) {testing.expect_value(t, group_file_type(item.name, item.mime), item.kind)}
	media := [?]marmot.Media_Attachment_Outcome {
		{tag = .REJECTED, body = {rejected = {0, {.INVALID_STRUCTURE, "bad"}}}},
		{body = {accepted = {1, {file_name = "photo.png", media_type = "image/png"}}}},
		{body = {accepted = {2, {file_name = "notes.pdf"}}}},
	}
	records := [?]marmot.Timeline_Message_Record {
		{message_id_hex = "old", sender = "alice", timeline_at = 1},
		{message_id_hex = "hidden", sender = "alice", timeline_at = 2},
		{message_id_hex = "deleted", deleted = true},
		{message_id_hex = "invalid", invalidation_status = "invalid"},
		{message_id_hex = "edit", kind = 1009},
		{message_id_hex = "expiry", has_retention_expires_at = true, retention_expires_at = 1},
		{message_id_hex = "new", sender = "bob", timeline_at = 3, kind = 1111},
	}
	for &record in records {record.media, record.media_len = raw_data(media[:]), len(media)}
	job: Group_Files_Job
	defer delete(job.files)
	// Newest page first, then an older page, just like the store cursor.
	newer := marmot.Timeline_Page {
		messages     = &records[1],
		messages_len = len(records) - 1,
	}
	older := marmot.Timeline_Page {
		messages     = &records[0],
		messages_len = 1,
	}
	group_files_collect(&job, &newer)
	group_files_collect(&job, &older)
	testing.expect_value(t, len(job.files), 8)
	testing.expect_value(t, string(job.files[0].record.message_id_hex), "new")
	testing.expect_value(t, string(job.files[7].record.message_id_hex), "old")
	testing.expect_value(t, job.files[0].index, 1)
	testing.expect_value(t, job.files[1].index, 2)
	ui: Ui_State
	ui.hidden["hidden"] = true
	defer delete(ui.hidden)
	for filter in ([]struct {
			kind:   Group_File_Type,
			sender: string,
			count:  int,
		}{{.All, "", 4}, {.Images, "", 2}, {.All, "alice", 2}, {.Documents, "bob", 1}, {.Audio, "bob", 0}, {.All, "former-member", 0}}) {
		ui.group_files_type, ui.group_files_sender = filter.kind, filter.sender
		count := 0
		for file in job.files {if group_file_matches(&ui, file) {count += 1}}
		testing.expect_value(t, count, filter.count)
	}
}

@(test)
group_files_cancel_scope :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	gate: sync.Sema
	job := new(Group_Files_Job)
	job.account, job.group = strings.clone_to_cstring("old"), strings.clone_to_cstring("group")
	job.worker = thread.create(
		proc(t: ^thread.Thread) {sync.sema_wait_with_timeout((^sync.Sema)(t.data), time.Second)},
	)
	job.worker.data = &gate
	thread.start(job.worker)
	group_files_job = job
	defer group_files_stop()
	ui := Ui_State {
		selected           = -1,
		group_files_open   = true,
		group_files_sender = "old-sender",
	}
	group_files_tick(&ui, nil)
	testing.expect(t, sync.atomic_load(&job.cancel))
	testing.expect(t, !thread.is_done(job.worker), "closing must not block on the history worker")
	testing.expect_value(t, ui.group_files_sender, "")
	sync.sema_post(&gate)
	thread.join(job.worker)
	group_files_tick(&ui, nil)
	testing.expect(t, group_files_job == nil && !ui.group_files_open)
}

// Run alone to render the large list at desktop and narrow widths.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=group_files_layout
@(test)
group_files_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "group_files_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1000, 800, "Group files")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	for label in ([]string{"Short.png", "日本語の長いファイル名.png", "Mountain marmot.png"}) {
		width := rl.MeasureTextLine(FONT_TITLE, 12, label, 0).x / 2
		short := group_file_label(label, width, FONT_TITLE, 12)
		testing.expect(t, strings.has_suffix(short, "…"))
		testing.expect(t, rl.MeasureTextLine(FONT_TITLE, 12, short, 0).x <= width)
		testing.expect(t, strings.has_prefix(label, strings.trim_suffix(short, "…")))
	}
	load_themes()
	apply_theme(0, 0)
	clay.SetMaxElementCount(32768)
	memory := make([]u8, int(clay.MinMemorySize()))
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{1000, 800},
		{
			handler = proc "c" (err: clay.ErrorData) {
				context = runtime.default_context()
				testing.expect(
					(^testing.T)(err.userData),
					false,
					string(err.errorText.chars[:err.errorText.length]),
				)
			},
			userData = t,
		},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	defer delete(memory)
	ui := Ui_State {
		show_members     = false,
		group_files_open = true,
		member_menu      = -1,
		member_nick      = -1,
		row_menu         = -1,
	}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "Workshop"})
	defer {delete(ui.accounts); delete(ui.chats)}
	photo := #load("assets/marmot.png")
	decoded := rl.LoadImageFromMemory("", raw_data(photo), i32(len(photo)))
	tex := rl.LoadTextureFromImage(decoded)
	rl.UnloadImage(decoded)
	media_textures["fixture-photo"] = &tex
	defer {delete_key(&media_textures, "fixture-photo"); rl.UnloadTexture(tex)}
	media := [?]marmot.Media_Attachment_Outcome {
		{
			body = {
				accepted = {
					0,
					{
						file_name = "Mountain marmot.png",
						media_type = "image/png",
						plaintext_sha256 = "fixture-photo",
					},
				},
			},
		},
		{
			body = {
				accepted = {0, {file_name = "Project notes.pdf", media_type = "application/pdf"}},
			},
		},
		{body = {accepted = {0, {file_name = "white-noise-diagnostic-logs.zip"}}}},
		{body = {accepted = {0, {file_name = "Design review.wav", media_type = "audio/wav"}}}},
	}
	records: [len(media)]marmot.Timeline_Message_Record
	for &record, i in records {record = {
			message_id_hex = "file",
			sender         = "alice",
			media          = &media[i],
			media_len      = 1,
			timeline_at    = 1790070000,
		}}
	job := Group_Files_Job {
		account = "account",
		group   = "group",
	}
	for i in 0 ..< 600 {
		j := i % len(records)
		ref := &media[j].body.accepted.reference
		append(
			&job.files,
			Group_File {
				&records[j],
				0,
				group_file_type(string(ref.file_name), string(ref.media_type)),
			},
		)
	}
	append(&job.senders, "alice")
	group_files_job = &job
	defer {group_files_job = nil; delete(job.files); delete(job.senders)}
	ui.nicknames["alice"] = "Alice"
	defer delete(ui.nicknames)
	for width in ([]f32{1000, 400}) {
		rl.SetWindowSize(i32(width), 800)
		clay.SetLayoutDimensions({width, 800})
		if data := clay.GetScrollContainerData(clay.ID("GroupFilesList"));
		   data.found {data.scrollPosition.y = 0}
		for _ in 0 ..< 3 {build_layout(&ui, 0)}
		data := clay.GetScrollContainerData(clay.ID("GroupFilesList"))
		testing.expect(t, data.found)
		card := clay.GetElementData(clay.ID("GroupFile", 0)).boundingBox
		columns := max(
			1,
			int(
				(data.scrollContainerDimensions.width + GROUP_FILE_GAP) /
				(card.width + GROUP_FILE_GAP),
			),
		)
		testing.expect_value(
			t,
			data.contentDimensions.height,
			f32(((600 + columns - 1) / columns) * (GROUP_FILE_CARD_H + GROUP_FILE_GAP)),
		)
		for fraction in ([]f32{0, 0.5, 1}) {
			data.scrollPosition.y =
				-fraction * (data.contentDimensions.height - data.scrollContainerDimensions.height)
			commands := build_layout(&ui, 0)
			mounted := 0
			for _, i in job.files {if clay.GetElementData(clay.ID("GroupFile", u32(i))).found {mounted += 1}}
			testing.expect(t, mounted > 0 && mounted < 50)
			testing.expect(t, !layout_overflow)
			box := clay.GetElementData(clay.ID("GroupFilesPanel")).boundingBox
			testing.expect(t, box.x + box.width <= width + 0.01)
			if fraction == 0 {
				rl.BeginDrawing(); clay_raylib_render(&commands)
				rl.TakeScreenshot(
					width == 1000 ? "/tmp/wn-group-files-wide.png" : "/tmp/wn-group-files-narrow.png",
				)
				rl.EndDrawing()
			}
		}
		testing.expect(t, clay.GetElementData(clay.ID("GroupFile", 599)).found)
		list_y := clay.GetElementData(clay.ID("GroupFilesList")).boundingBox.y
		ui.group_files_menu = .Sender
		build_layout(&ui, 0)
		testing.expect(
			t,
			abs(clay.GetElementData(clay.ID("GroupFilesList")).boundingBox.y - list_y) <= 1,
		)
		testing.expect(t, clay.GetElementData(clay.ID("GroupFilesOption", 1)).found)
		menu := clay.GetElementData(clay.ID("GroupFilesOptions")).boundingBox
		testing.expect(t, menu.x >= 0 && menu.x + menu.width <= width)
		ui.group_files_menu = .None
	}
	press :: proc(ui: ^Ui_State, key: rl.KeyboardKey) {
		rl.PushKey(key, true)
		handle_group_files(ui)
		rl.PushKey(key, false)
	}
	press(&ui, .TAB)
	testing.expect_value(t, ui.group_files_menu, Group_File_Menu.Type)
	press(&ui, .DOWN)
	press(&ui, .ENTER)
	testing.expect_value(t, ui.group_files_type, Group_File_Type.Images)
	build_layout(&ui, 0)
	testing.expect(t, clay.GetElementData(clay.ID("GroupFile", 0)).found)
	testing.expect(t, !clay.GetElementData(clay.ID("GroupFile", 1)).found)
	press(&ui, .TAB)
	press(&ui, .TAB)
	press(&ui, .DOWN)
	press(&ui, .ENTER)
	testing.expect_value(t, ui.group_files_sender, "alice")
	build_layout(&ui, 0)
	card := clay.GetElementData(clay.ID("GroupFilePreview", 0)).boundingBox
	clay.SetPointerState({card.x + card.width / 2, card.y + card.height / 2}, false)
	rl.PushMouseButton(.LEFT, false)
	handle_group_files(&ui)
	testing.expect(t, preview_shown && preview.kind == .Slides)
	testing.expect_value(t, len(preview.slides), 1)
	preview_close()
	clay.SetPointerState({-100, -100}, false)
	press(&ui, .ESCAPE)
	testing.expect(t, !ui.group_files_open)
}
