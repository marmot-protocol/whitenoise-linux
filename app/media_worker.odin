package main

import "core:strings"
import "core:slice"
import "core:sync"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"
import rl "sdlrl"

@(private)
Media_Phase :: enum { Prepare, Present }
@(private)
Media_Kind :: enum { File, Image, Emoji, Mesh, Gcode, Video, Loop, Audio, Pdf, Xdc, Arc, Text, Code, Font }
@(private)
MEDIA_WORKERS :: 2
@(private)
Media_Key :: struct { key: string, kind: Media_Kind }
@(private)
Media_Pending :: struct { index: int, kind: Media_Kind }

// UI owns the queue and caches. Workers own individual jobs until done;
// only the UI creates textures or publishes views into session caches.
@(private)
Media_Job :: struct {
	mutex: sync.Mutex,
	done: bool,
	worker: ^thread.Thread,
	client: ^marmot.Client,
	account, group: cstring,
	key: string,
	reference: marmot.Media_Attachment_Reference,
	kind: Media_Kind,
	color: rl.Color,
	view: rawptr,
	image: rl.Image,
	size: i64,
}
@(private)
media_jobs: [dynamic]^Media_Job
@(private)
media_inflight: map[Media_Key]bool

@(private)
media_kind :: proc(name, mime: string) -> Media_Kind {
	if strings.has_prefix(name, EMOJI_ATT_PREFIX) { return .Emoji }
	lower := strings.to_lower(name, context.temp_allocator)
	if is_model_name(lower) || strings.has_prefix(mime, "model/") { return .Mesh }
	if strings.has_suffix(lower, ".gcode") || strings.has_suffix(lower, ".gco") { return .Gcode }
	if strings.has_suffix(lower, ".gif") || mime == "image/gif" { return .Loop }
	if is_video_name(lower) || strings.has_prefix(mime, "video/") { return .Video }
	if strings.has_prefix(mime, "audio/") { return .Audio }
	for ext in ([]string{".mp3", ".ogg", ".flac", ".m4a", ".wav"}) {
		if strings.has_suffix(lower, ext) { return .Audio }
	}
	if strings.has_suffix(lower, ".pdf") || mime == "application/pdf" { return .Pdf }
	if is_xdc_name(lower) { return .Xdc }
	for ext in ([]string{".zip", ".rar", ".7z", ".tar", ".tgz", ".txz", ".tbz2"}) {
		if strings.has_suffix(lower, ext) { return .Arc }
	}
	if strings.contains(lower, ".tar.") { return .Arc }
	for ext in ([]string{".md", ".markdown"}) {
		if strings.has_suffix(lower, ext) { return .Text }
	}
	if is_code_name(lower) { return .Code }
	if strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") { return .Font }
	if strings.has_prefix(mime, "image/") { return .Image }
	return .File
}

@(private)
media_cached :: proc(kind: Media_Kind, key: string) -> (rawptr, bool) {
	switch kind {
	case .Image: v, ok := media_textures[key]; return v, ok
	case .Emoji: v, ok := remote_emoji_tex[key]; return v, ok
	case .Mesh: v, ok := stl_views[key]; return v, ok
	case .Gcode: v, ok := gcode_views[key]; return v, ok
	case .Video, .Loop, .Audio: v, ok := video_views[key]; return v, ok
	case .Pdf: v, ok := pdf_views[key]; return v, ok
	case .Xdc: v, ok := xdc_views[key]; return v, ok
	case .Arc: v, ok := arc_views[key]; return v, ok
	case .Text: v, ok := txt_views[key]; return v, ok
	case .Code: v, ok := code_views[key]; return v, ok
	case .Font: v, ok := ttf_views[key]; return v, ok
	case .File: return nil, true
	}
	return nil, false
}

@(private)
media_rejection_text :: proc(kind: marmot.Media_Rejection_Kind) -> string {
	if kind == .UNSUPPORTED_FORMAT {
		return N_("Unsupported attachment format.")
	}
	return N_("Invalid attachment.")
}

// Indices remain source imeta positions, including rejected attachments.
@(private)
media_reference :: proc(record: ^marmot.Timeline_Message_Record, index: int) -> ^marmot.Media_Attachment_Reference {
	if record == nil || index < 0 || index >= int(record.media_len) || record.media[index].tag != .ACCEPTED {
		return nil
	}
	return &record.media[index].body.accepted.reference
}

@(private)
reply_image_load :: proc(client: ^marmot.Client, account, group: cstring, preview: ^marmot.Timeline_Reply_Preview) -> string {
	if preview.deleted || preview.invalidation_status != nil { return "" }
	for &outcome in preview.media[:preview.media_len] {
		if outcome.tag != .ACCEPTED { continue }
		ref := &outcome.body.accepted.reference
		name := ref.file_name != nil ? string(ref.file_name) : ""
		mime := ref.media_type != nil ? string(ref.media_type) : ""
		if media_kind(name, mime) != .Image { continue }
		key := ref.plaintext_sha256 != nil ? string(ref.plaintext_sha256) : name
		if _, seen := media_cached(.Image, key); !seen {
			media_enqueue(client, account, group, ref, .Image, key)
		}
		return strings.clone(key)
	}
	return ""
}

@(private)
media_attach :: proc(msg: ^Msg_Ui, client: ^marmot.Client, account, group: cstring, outcome: ^marmot.Media_Attachment_Outcome) {
	if outcome.tag == .REJECTED {
		index := int(outcome.body.rejected.attachment_index)
		resize(&msg.att_names, index + 1)
		resize(&msg.att_keys, index + 1)
		msg.att_rejected[index] = media_rejection_text(outcome.body.rejected.rejection.kind)
		return
	}
	index := int(outcome.body.accepted.attachment_index)
	ref := &outcome.body.accepted.reference
	name := ref.file_name != nil ? string(ref.file_name) : ""
	key := ref.plaintext_sha256 != nil ? string(ref.plaintext_sha256) : name
	resize(&msg.att_names, index + 1)
	resize(&msg.att_keys, index + 1)
	msg.att_names[index] = strings.clone(name != "" ? name : "attachment")
	msg.att_keys[index] = strings.clone(key)
	kind := media_kind(name, ref.media_type != nil ? string(ref.media_type) : "")
	if kind == .Emoji { key = emoji_code(name[len(EMOJI_ATT_PREFIX):]) }
	view, seen := media_cached(kind, key)
	if !seen {
		media_enqueue(client, account, group, ref, kind, key)
		if kind != .Emoji { append(&msg.media_pending, Media_Pending{index, kind}) }
		return
	}
	media_ready(msg, kind, key, index, view)
}

@(private)
media_ready :: proc(msg: ^Msg_Ui, kind: Media_Kind, key: string, index: int, view: rawptr) {
	if kind == .Emoji { return }
	if view == nil {
		#partial switch kind {
		case .Image: media_insert(&msg.img_failed, Att_Item(string){strings.clone(key), index})
		case .Mesh, .Gcode, .Video, .Loop, .Pdf: msg.media_failed = true
		case:
			append(&msg.files, index)
			slice.sort(msg.files[:])
		}
		return
	}
	switch kind {
	case .Image: media_insert(&msg.images, Att_Item(^rl.Texture2D){(^rl.Texture2D)(view), index})
	case .Mesh: media_insert(&msg.models, Att_Item(^Stl_View){(^Stl_View)(view), index})
	case .Gcode: media_insert(&msg.gcodes, Att_Item(^Gcode_View){(^Gcode_View)(view), index})
	case .Video, .Loop: media_insert(&msg.videos, Att_Item(^Video_View){(^Video_View)(view), index})
	case .Audio: media_insert(&msg.audios, Att_Item(^Video_View){(^Video_View)(view), index})
	case .Pdf: media_insert(&msg.pdfs, Att_Item(^Pdf_View){(^Pdf_View)(view), index})
	case .Xdc: media_insert(&msg.xdcs, Att_Item(^Xdc_View){(^Xdc_View)(view), index})
	case .Arc: media_insert(&msg.arcs, Att_Item(^Arc_View){(^Arc_View)(view), index})
	case .Text: media_insert(&msg.txts, Att_Item(^Txt_View){(^Txt_View)(view), index})
	case .Code: media_insert(&msg.codes, Att_Item(^Code_View){(^Code_View)(view), index})
	case .Font: media_insert(&msg.fonts, Att_Item(^Ttf_View){(^Ttf_View)(view), index})
	case .File, .Emoji:
	}
}

@(private)
media_enqueue :: proc(client: ^marmot.Client, account, group: cstring, ref: ^marmot.Media_Attachment_Reference, kind: Media_Kind, key: string) {
	if media_inflight[Media_Key{key, kind}] { return }
	job := new(Media_Job)
	job^ = {client = client, account = strings.clone_to_cstring(string(account)),
		group = strings.clone_to_cstring(string(group)), key = strings.clone(key),
		reference = ref^, kind = kind, color = clay_color(TEXT)}
	r := &job.reference
	for field in ([]^cstring{&r.ciphertext_sha256, &r.plaintext_sha256, &r.nonce_hex,
		&r.file_name, &r.media_type, &r.dim, &r.thumbhash}) {
		if field^ != nil { field^ = strings.clone_to_cstring(string(field^)) }
	}
	locators := make([]marmot.Media_Locator, r.locators_len)
	copy(locators, r.locators[:r.locators_len])
	for &locator in locators {
		locator.kind = strings.clone_to_cstring(string(locator.kind))
		locator.value = strings.clone_to_cstring(string(locator.value))
	}
	r.locators = raw_data(locators)
	media_inflight[Media_Key{job.key, kind}] = true
	append(&media_jobs, job)
}

@(private)
media_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Media_Job)(t.data)
	defer free_all(context.temp_allocator)
	defer {
		sync.lock(&job.mutex)
		job.done = true
		sync.unlock(&job.mutex)
		frame_wake()
	}
	bytes, ok := media_load(job.client, job.account, job.group, &job.reference)
	if !ok { return }
	job.size = i64(len(bytes))
	defer delete(bytes)
	name := strings.to_lower(string(job.reference.file_name), context.temp_allocator)
	switch job.kind {
	case .Image, .Emoji:
		job.image = rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes)))
	case .Font:
		job.image = rl.FontSpecimen(bytes, SPECIMEN_LINES, SPECIMEN_SIZES, job.color, 640)
	case .Mesh: job.view = model_view_make(name, bytes)
	case .Gcode:
		if segs, parsed := parse_gcode(bytes); parsed { job.view = gcode_view_make(segs) }
	case .Video, .Loop, .Audio:
		mode: Video_Mode = job.kind == .Audio ? .Audio : (job.kind == .Loop ? .Loop : .Clip)
		job.view = video_view_make(bytes, mode, .Prepare)
		bytes = nil // the view owns the stream
	case .Pdf: job.view = pdf_view_make(bytes, .Prepare)
	case .Xdc:
		job.view = xdc_view_make(bytes, string(job.reference.file_name), .Prepare)
		if job.view != nil { bytes = nil }
	case .Arc:
		job.view = arc_view_make(bytes)
		if job.view != nil { bytes = nil }
	case .Text: job.view = txt_view_make(string(bytes))
	case .Code: job.view = code_view_make(name, string(bytes))
	case .File:
	}
}

@(private)
media_publish :: proc(job: ^Media_Job) {
	key := strings.clone(job.key)
	switch job.kind {
	case .Image, .Emoji, .Font:
		tex := rl.LoadTextureFromImage(job.image)
		if job.kind == .Font {
			view: ^Ttf_View
			if tex.width > 0 { view = new(Ttf_View); view^ = {tex, tex.width, tex.height} }
			ttf_views[key] = view
			delete(([^]u8)(job.image.data)[:job.image.width * job.image.height * 4])
		} else {
			view: ^rl.Texture2D
			if tex.width > 0 { view = new(rl.Texture2D); view^ = tex }
			if job.kind == .Emoji { remote_emoji_tex[key] = view } else { media_textures[key] = view }
			rl.UnloadImage(job.image)
		}
	case .Mesh: stl_views[key] = (^Stl_View)(job.view)
	case .Gcode: gcode_views[key] = (^Gcode_View)(job.view)
	case .Video, .Loop, .Audio:
		view := (^Video_View)(job.view)
		if view != nil { view.tex = rl.CreateStreamTexture(view.w, view.h) }
		video_views[key] = view
	case .Pdf:
		view := (^Pdf_View)(job.view)
		if view != nil && view.failed { pdf_view_free(view); view = nil }
		if view != nil { view.tex = rl.LoadTextureFromImage(rl.Image{data = raw_data(view.pix), width = view.w, height = view.h}) }
		pdf_views[key] = view
	case .Xdc:
		view := (^Xdc_View)(job.view)
		if view != nil && view.icon_image.data != nil {
			view.icon = rl.LoadTextureFromImage(view.icon_image)
			rl.UnloadImage(view.icon_image)
			view.icon_image = {}
		}
		xdc_views[key] = view
	case .Arc: arc_views[key] = (^Arc_View)(job.view)
	case .Text: txt_views[key] = (^Txt_View)(job.view)
	case .Code: code_views[key] = (^Code_View)(job.view)
	case .File:
	}
	if _, exists := blob_sizes[job.key]; !exists { blob_sizes[strings.clone(job.key)] = job.size }
}

@(private)
media_job_free :: proc(job: ^Media_Job) {
	r := &job.reference
	for value in ([]cstring{job.account, job.group, r.ciphertext_sha256, r.plaintext_sha256,
		r.nonce_hex, r.file_name, r.media_type, r.dim, r.thumbhash}) { delete(value) }
	for locator in r.locators[:r.locators_len] {
		delete(locator.kind)
		delete(locator.value)
	}
	delete(r.locators[:r.locators_len])
	delete_key(&media_inflight, Media_Key{job.key, job.kind})
	delete(job.key)
	free(job)
}

@(private)
media_drain :: proc(ui: ^Ui_State) {
	at_bottom := false
	if ui.selected >= 0 && ui.selected < len(ui.chats) && clay.GetCurrentContext() != nil {
		if data := clay.GetScrollContainerData(clay.ID("Timeline")); data.found {
			at_bottom = data.scrollPosition.y <= -max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0) + 1
		}
	}
	active := 0
	for i := len(media_jobs) - 1; i >= 0; i -= 1 {
		job := media_jobs[i]
		if job.worker == nil { continue }
		sync.lock(&job.mutex)
		done := job.done
		sync.unlock(&job.mutex)
		if !done { active += 1; continue }
		thread.join(job.worker)
		thread.destroy(job.worker)
		media_publish(job)
		view, _ := media_cached(job.kind, job.key)
		for &msg in ui.messages {
			if job.kind == .Image && msg.reply_image == job.key {
				msg.row_height = 0
				ui.scroll_pending ||= at_bottom
			}
			for j := len(msg.media_pending) - 1; j >= 0; j -= 1 {
				p := msg.media_pending[j]
				if p.kind != job.kind || msg.att_keys[p.index] != job.key { continue }
				media_ready(&msg, p.kind, job.key, p.index, view)
				ordered_remove(&msg.media_pending, j)
				msg.row_height = 0
				ui.scroll_pending ||= at_bottom
			}
		}
		media_job_free(job)
		ordered_remove(&media_jobs, i)
	}
	for job in media_jobs {
		if active >= MEDIA_WORKERS { break }
		if job.worker != nil { continue }
		job.worker = thread.create(media_worker)
		job.worker.data = job
		thread.start(job.worker)
		active += 1
	}
}

// Called after runtime shutdown aborts downloads, before freeing its client.
@(private)
media_stop :: proc() {
	for job in media_jobs {
		if job.worker != nil {
			thread.join(job.worker)
			thread.destroy(job.worker)
			media_publish(job)
		}
		media_job_free(job)
	}
	clear(&media_jobs)
}

@(private)
media_insert :: proc(items: ^[dynamic]Att_Item($T), entry: Att_Item(T)) {
	append(items, entry)
	for i := len(items^) - 1; i > 0 && items^[i - 1].att > items^[i].att; i -= 1 {
		items^[i - 1], items^[i] = items^[i], items^[i - 1]
	}
}
