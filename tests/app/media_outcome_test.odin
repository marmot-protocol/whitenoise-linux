package main

import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

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
		media_attach(&msg, nil, "account", "group", &outcome)
	}
	record := marmot.Timeline_Message_Record {
		media     = raw_data(outcomes[:]),
		media_len = len(outcomes),
	}
	testing.expect_value(t, len(msg.att_names), 8)
	testing.expect(t, slice.equal(msg.files[:], []int{0, 1, 3, 4, 6, 7}))
	testing.expect_value(t, msg.att_rejected[2], "Unsupported attachment format.")
	for i in ([]int{-1, 2, 5, 8}) {
		testing.expect(t, media_reference(&record, i) == nil)
	}
	testing.expect(t, media_reference(&record, 6) == &outcomes[6].body.accepted.reference)
	testing.expect(t, media_reference(nil, 0) == nil)
	for status in ([]marmot.Status{.MEDIA_ATTACHMENT_REJECTED, .MEDIA_UNFETCHABLE, .MEDIA_DOWNLOAD_FAILED, .USER_BLOCKED}) {
		testing.expect(t, !send_retryable(status))
	}

	// Render mixed ready, rejected, and loading slots in their source order.
	clear(&msg.files)
	append(&msg.files, 0)
	text_view: Txt_View
	append(&msg.txts, Att_Item(^Txt_View){&text_view, 6})
	tex := rl.Texture2D {
		width  = 40,
		height = 30,
	}
	for i in ([]int{1, 3, 4}) {
		append(&msg.images, Att_Item(^rl.Texture2D){&tex, i})
	}
	append(&msg.media_pending, Media_Pending{7, .Image})
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 2000})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	clay.BeginLayout()
	message_row(0, msg)
	clay.EndLayout(0)
	last_bottom: f32
	for id in ([]clay.ElementId{clay.ID("MsgFile", 0), clay.ID("MsgImage", 1), clay.ID("MediaRejected", 2), clay.ID("MsgImage", 3), clay.ID("MediaRejected", 5), clay.ID("MsgTxt", 0), clay.ID("MediaLoading", 7)}) {
		data := clay.GetElementData(id)
		testing.expect(t, data.found)
		testing.expect(t, data.boundingBox.y >= last_bottom)
		last_bottom = data.boundingBox.y + data.boundingBox.height
	}
	testing.expect_value(
		t,
		clay.GetElementData(clay.ID("MsgImage", 3)).boundingBox.y,
		clay.GetElementData(clay.ID("MsgImage", 4)).boundingBox.y,
	)

	ui: Ui_State
	append(&ui.messages, msg)
	defer delete(ui.messages)
	b := strings.builder_make(context.temp_allocator)
	transcript_md(&ui, {}, &b)
	testing.expect(t, strings.contains(strings.to_string(b), tr(msg.att_rejected[2])))
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
