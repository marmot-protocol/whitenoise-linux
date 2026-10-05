package main

import "core:reflect"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
media_outcome_slots :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	msg := Msg_Ui {
		sender = strings.clone("Alice"),
	}
	defer message_free(msg)
	outcomes: [8]marmot.Media_Attachment_Outcome
	for &outcome, i in outcomes {
		outcome.body.accepted = {u32(i), {file_name = "file.bin"}}
		if i == 2 || i == 5 {
			outcome = {
				tag = .REJECTED,
				body = {rejected = {u32(i), {.UNSUPPORTED_FORMAT, "raw detail"}}},
			}
		}
		media_attach(&msg, nil, "account", "group", &outcome, "")
	}
	record := marmot.Timeline_Message_Record {
		media     = raw_data(outcomes[:]),
		media_len = len(outcomes),
	}
	testing.expect_value(t, len(msg.attachments), 8)
	for slot, i in msg.attachments {
		rejected := i == 2 || i == 5
		testing.expect_value(t, slot.state, rejected ? Att_State.Rejected : Att_State.Ready)
		testing.expect_value(t, slot.name, rejected ? "" : "file.bin")
	}
	testing.expect_value(t, msg.attachments[2].rejection, "Unsupported attachment format.")
	for i in ([]int{-1, 2, 5, 8}) {
		testing.expect(t, media_reference(&record, i) == nil)
	}
	testing.expect(t, media_reference(&record, 6) == &outcomes[6].body.accepted.reference)
	testing.expect(t, media_reference(nil, 0) == nil)
	for status in ([]marmot.Status{.MEDIA_ATTACHMENT_REJECTED, .MEDIA_UNFETCHABLE, .MEDIA_DOWNLOAD_FAILED, .USER_BLOCKED}) {
		testing.expect(t, !send_retryable(status))
	}

	tex := rl.Texture2D {
		width  = 40,
		height = 30,
	}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 2000})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}

	ui: Ui_State
	append(&ui.messages, msg)
	defer delete(ui.messages)
	b := strings.builder_make(context.temp_allocator)
	transcript_md(&ui, {}, &b)
	testing.expect(t, strings.contains(strings.to_string(b), tr(msg.attachments[2].rejection)))
	testing.expect(t, !strings.contains(strings.to_string(b), "raw detail"))

	// A reply loads its preview media even when the parent row is absent.
	old_jobs, old_inflight, old_textures := media_jobs, media_inflight, media_textures
	media_jobs, media_inflight, media_textures = {}, {}, {}
	defer {
		delete(media_jobs); delete(media_inflight); delete(media_textures)
		media_jobs, media_inflight, media_textures = old_jobs, old_inflight, old_textures
	}
	preview := marmot.Timeline_Reply_Preview {
		media     = raw_data(outcomes[:]),
		media_len = len(outcomes),
	}
	outcomes[4].body.accepted.reference = {
		file_name        = "reply.png",
		media_type       = "image/png",
		plaintext_sha256 = "reply-test-image",
	}
	job_count := len(media_jobs)
	msg.reply_image = reply_image_load(nil, "account", "group", &preview)
	testing.expect_value(t, msg.reply_image, "reply-test-image")
	testing.expect_value(t, len(media_jobs), job_count + 1)
	duplicate := reply_image_load(nil, "account", "group", &preview)
	delete(duplicate)
	testing.expect_value(t, len(media_jobs), job_count + 1)
	defer {
		media_job_free(media_jobs[job_count])
		ordered_remove(&media_jobs, job_count)
		delete_key(&media_textures, "reply-test-image")
	}
	clay.BeginLayout()
	message_row(1, msg)
	clay.EndLayout(0)
	loading := clay.GetElementData(clay.ID("MsgReplyImage", 1))
	testing.expect(t, loading.found)
	media_textures["reply-test-image"] = &tex
	for dimensions in ([][2]i32{{30, 100}, {100, 30}}) {
		tex.width, tex.height = dimensions[0], dimensions[1]
		clay.BeginLayout()
		message_row(1, msg)
		commands := clay.EndLayout(0)
		image_box := clay.GetElementData(clay.ID("MsgReplyImage", 1)).boundingBox
		testing.expect(t, image_box.width <= 96 && image_box.height <= 64)
		testing.expect_value(
			t,
			image_box.x,
			clay.GetElementData(clay.ID("MsgReplyCol", 1)).boundingBox.x,
		)
		drawn := false
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Image ||
			   command.renderData.image.imageData != &tex {continue}
			if command.id != clay.ID("MsgReplyImage", 1).id {continue}
			drawn = true
			testing.expect(
				t,
				abs(
					command.boundingBox.width / command.boundingBox.height -
					f32(tex.width) / f32(tex.height),
				) <
				0.00001,
			)
		}
		testing.expect(t, drawn, "reply must render the parent image")
	}
	preview.deleted = true
	testing.expect_value(t, reply_image_load(nil, "account", "group", &preview), "")
	preview.deleted = false
	preview.invalidation_status = "invalid"
	testing.expect_value(t, reply_image_load(nil, "account", "group", &preview), "")
}

// One message mixes every slot shape while downloads finish out of source
// order. A second message borrows the same text download.
//
//   0 file  1 img-a  2 img-b  3 rejected  4 img-a  5 audio  6 text
//   7 img-d (never finishes)  8 sticker  9 emoji asset
@(test)
media_slots_mixed :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_jobs, old_inflight := media_jobs, media_inflight
	old_textures, old_videos, old_txts := media_textures, video_views, txt_views
	old_sizes, old_seen, old_bars := blob_sizes, msg_seen, video_bars
	media_jobs, media_inflight = {}, {}
	media_textures, video_views, txt_views = {}, {}, {}
	blob_sizes, msg_seen, video_bars = {}, {}, {}
	defer {
		for job in media_jobs {
			thread.join(job.worker)
			thread.destroy(job.worker)
			media_job_free(job)
		}
		delete(media_jobs); delete(media_inflight)
		for key in media_textures {delete(key)}
		for key in video_views {delete(key)}
		for key in txt_views {delete(key)}
		for key in blob_sizes {delete(key)}
		for key in msg_seen {delete(key)}
		delete(media_textures); delete(video_views); delete(txt_views)
		delete(blob_sizes); delete(msg_seen); delete(video_bars)
		media_jobs, media_inflight = old_jobs, old_inflight
		media_textures, video_views, txt_views = old_textures, old_videos, old_txts
		blob_sizes, msg_seen, video_bars = old_sizes, old_seen, old_bars
	}
	tex := rl.Texture2D {
		width  = 40,
		height = 30,
	}
	audio: Video_View
	text: Txt_View
	media_textures[strings.clone("img-a")] = &tex
	media_textures[strings.clone("sticker:stk")] = &tex
	video_views[strings.clone("aud")] = &audio

	ui: Ui_State
	defer {for msg in ui.messages {message_free(msg)}; delete(ui.messages)}
	append(&ui.messages, Msg_Ui{id = strings.clone("mixed"), sender = strings.clone("Alice")})
	append(&ui.messages, Msg_Ui{id = strings.clone("other"), sender = strings.clone("Bob")})
	msg, other := &ui.messages[0], &ui.messages[1]
	msg.sticker.sha = strings.clone("stk")
	attach :: proc(msg: ^Msg_Ui, index: int, name, key, mime, emoji: string) {
		outcome := marmot.Media_Attachment_Outcome {
			body = {
				accepted = {
					u32(index),
					{
						file_name = strings.clone_to_cstring(name, context.temp_allocator),
						plaintext_sha256 = strings.clone_to_cstring(key, context.temp_allocator),
						media_type = strings.clone_to_cstring(mime, context.temp_allocator),
					},
				},
			},
		}
		media_attach(msg, nil, "account", "group", &outcome, emoji)
	}
	attach(msg, 0, "notes.bin", "file", "", "")
	attach(msg, 1, "a.png", "img-a", "image/png", "")
	attach(msg, 2, "b.png", "img-b", "image/png", "")
	rejected := marmot.Media_Attachment_Outcome {
		tag = .REJECTED,
		body = {rejected = {3, {.UNSUPPORTED_FORMAT, "raw detail"}}},
	}
	media_attach(msg, nil, "account", "group", &rejected, "")
	attach(msg, 4, "c.png", "img-a", "image/png", "")
	attach(msg, 5, "voice.mp3", "aud", "", "")
	attach(msg, 6, "readme.md", "txt", "", "")
	attach(msg, 7, "d.png", "img-d", "image/png", "")
	attach(msg, 8, "s.webp", "stk", "image/webp", "")
	attach(msg, 9, "party.png", "party-sha", "image/png", "party")
	attach(other, 0, "readme.md", "txt", "", "")

	Expect :: struct {
		kind:  Media_Kind,
		state: Att_State,
	}
	for want, i in ([]Expect{{.File, .Ready}, {.Image, .Ready}, {.Image, .Loading}, {.File, .Rejected}, {.Image, .Ready}, {.Audio, .Ready}, {.Text, .Loading}, {.Image, .Loading}, {.Sticker, .Ready}, {.Emoji, .Ready}}) {
		testing.expect_value(t, msg.attachments[i].state, want.state)
		if want.state != .Rejected {testing.expect_value(t, msg.attachments[i].kind, want.kind)}
	}
	// Duplicate cache keys borrow the cache's one texture.
	testing.expect(t, msg.attachments[1].view == msg.attachments[4].view)
	testing.expect(t, msg.attachments[4].view.(^rl.Texture2D) == &tex)
	// img-b, txt (shared by both rows), img-d and the emoji asset.
	testing.expect_value(t, len(media_jobs), 4)
	for job in media_jobs {job.worker = thread.create_and_start(proc() {})}
	finish :: proc(key: string, view: rawptr) {
		for job in media_jobs {
			if job.key != key {continue}
			sync.lock(&job.mutex)
			job.view, job.done = view, true
			sync.unlock(&job.mutex)
		}
	}

	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 3000})
	old_ui := g_ui
	g_ui = &ui
	defer {
		g_ui = old_ui
		att_hover, img_hover, img_retry_hover = {}, {}, ""
		clay.SetPointerState({-1, -1}, false)
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	layout :: proc(msg: Msg_Ui) {
		clay.BeginLayout()
		message_row(0, msg)
		clay.EndLayout(0)
	}
	box :: proc(name: string, att: u32) -> clay.ElementData {
		return clay.GetElementData(clay.ID(name, att))
	}
	center :: proc(name: string, att: u32) -> [2]f32 {
		b := box(name, att).boundingBox
		return {b.x + b.width / 2, b.y + b.height / 2}
	}

	// A loading slot splits the image run.
	layout(msg^)
	testing.expect(t, box("MsgAlbum", 1).found && box("MediaLoading", 2).found)
	testing.expect(t, box("MsgAlbum", 4).found && box("MediaLoading", 6).found)

	// The text at slot 6 finishes before the image at slot 2.
	finish("txt", &text)
	media_drain(&ui)
	testing.expect_value(t, msg.attachments[2].state, Att_State.Loading)
	for slot in ([]Att_Slot{msg.attachments[6], other.attachments[0]}) {
		testing.expect_value(t, slot.state, Att_State.Ready)
		testing.expect(t, slot.view.(^Txt_View) == &text)
	}
	finish("img-b", nil)
	media_drain(&ui)
	testing.expect_value(t, msg.attachments[2].state, Att_State.Failed)
	testing.expect_value(t, msg.attachments[7].state, Att_State.Loading)

	// Slots 1-2 form one album, the rejection ends it, and slot 4 starts
	// another. Every slot keeps its source position.
	layout(msg^)
	testing.expect(t, !box("MsgAlbum", 2).found)
	testing.expect_value(t, box("MsgImgFail", 2).boundingBox.y, box("MsgImage", 1).boundingBox.y)
	last_bottom: f32
	Element :: struct {
		name: string,
		att:  u32,
	}
	for element in ([]Element{{"MsgFile", 0}, {"MsgImage", 1}, {"MediaRejected", 3}, {"MsgImage", 4}, {"MsgAudio", 5}, {"MsgTxt", 6}, {"MediaLoading", 7}}) {
		data := box(element.name, element.att)
		testing.expect(t, data.found, element.name)
		testing.expect(t, data.boundingBox.y >= last_bottom, element.name)
		last_bottom = data.boundingBox.y + data.boundingBox.height
	}
	// The sticker draws once above the slots; the emoji asset not at all.
	testing.expect(t, box("MessageSticker", 0).found)
	for name in ([]string{"MsgImage", "MsgFile", "MediaLoading"}) {
		testing.expect(t, !box(name, 8).found && !box(name, 9).found, name)
	}

	// Save, lightbox and retry actions name the source slot.
	att_hover.index = -1
	clay.SetPointerState(center("MsgFile", 0), false)
	layout(msg^)
	testing.expect_value(t, att_hover.index, 0)
	clay.SetPointerState(center("MsgImage", 4), false)
	layout(msg^)
	testing.expect_value(t, img_hover.att, 4)
	clay.SetPointerState(center("MsgImgFail", 2), false)
	layout(msg^)
	testing.expect_value(t, img_retry_hover, "img-b")

	// The lightbox keeps the failed image in place between its siblings.
	preview_show_slides(&ui, "mixed", 4)
	defer preview_close()
	testing.expect(t, len(preview.slides) >= 3)
	if len(preview.slides) >= 3 {
		testing.expect_value(t, preview.slide, 2)
		want := [3]int{1, 2, 4}
		for slide, i in preview.slides[:3] {
			testing.expect_value(t, slide.att, want[i])
		}
		testing.expect(t, preview.slides[0].tex == &tex && preview.slides[0].key == "img-a")
		testing.expect(t, preview.slides[1].tex == nil && preview.slides[1].key == "")
	}
}

// media_ready is the one place a kind picks its view variant; a nil
// cache entry fails every kind that has a view.
@(test)
media_ready_variants :: proc(t: ^testing.T) {
	dummy: u8
	for kind in Media_Kind {
		want: typeid
		switch kind {
		case .Image, .Sticker:
			want = ^rl.Texture2D
		case .Mesh:
			want = ^Stl_View
		case .Gcode:
			want = ^Gcode_View
		case .Video, .Loop, .Audio:
			want = ^Video_View
		case .Pdf:
			want = ^Pdf_View
		case .Xdc:
			want = ^Xdc_View
		case .Arc:
			want = ^Arc_View
		case .Torrent:
			want = ^Tor_View
		case .Text:
			want = ^Txt_View
		case .Code:
			want = ^Code_View
		case .Font:
			want = ^Ttf_View
		case .Nes:
			want = ^Nes_View
		case .File, .Emoji, .Original:
		}
		slot := Att_Slot {
			kind = kind,
		}
		media_ready(&slot, &dummy)
		testing.expect_value(t, reflect.union_variant_typeid(slot.view), want)
		testing.expect_value(t, slot.state, Att_State.Ready)
		if want == nil {continue}
		failed := Att_Slot {
			kind = kind,
		}
		media_ready(&failed, nil)
		testing.expect_value(t, failed.state, Att_State.Failed)
		testing.expect(t, failed.view == nil)
	}
}
