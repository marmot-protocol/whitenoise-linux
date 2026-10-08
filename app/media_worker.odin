package main

import "core:fmt"
import "core:time"

import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Media_Phase :: enum {
	Prepare,
	Present,
}
@(private)
Media_Kind :: enum {
	File,
	Image,
	Sticker,
	Emoji,
	Mesh,
	Gcode,
	Video,
	Loop,
	Audio,
	Pdf,
	Xdc,
	Arc,
	Torrent,
	Text,
	Code,
	Font,
	Nes,
	Original, // an image at full size, decoded only for the lightbox
}
@(private)
MEDIA_WORKERS :: 2
// Longest side of a timeline image texture. A 12-megapixel photo uploaded at
// full size costs 48 MB of texture memory and stalls the frame that draws
// it; tiles are at most a few hundred points wide, so 1280 px still covers
// them at 2x density. The lightbox loads .Original for real pixels.
@(private)
TIMELINE_IMAGE_PX :: 1280
@(private)
Media_Key :: struct {
	key:  string,
	kind: Media_Kind,
}

// UI owns the queue and caches. Workers own individual jobs until done;
// only the UI creates textures or publishes views into session caches.
@(private)
Media_Job :: struct {
	mutex:          sync.Mutex,
	done:           bool,
	worker:         ^thread.Thread,
	client:         ^marmot.Client,
	account, group: cstring,
	key:            string,
	reference:      marmot.Media_Attachment_Reference,
	kind:           Media_Kind,
	color:          rl.Color,
	view:           rawptr,
	image:          rl.Image,
	size:           i64,
	queued_at:      time.Tick,
	external_gif:   bool,
	reaction:       bool, // .Emoji: find the reference on the kind-7 naming `key`
}
@(private)
media_jobs: [dynamic]^Media_Job
@(private)
media_inflight: map[Media_Key]bool

@(private)
media_kind :: proc(name, mime: string) -> Media_Kind {
	lower := strings.to_lower(name, context.temp_allocator)
	if is_model_name(lower) || strings.has_prefix(mime, "model/") {return .Mesh}
	if strings.has_suffix(lower, ".gcode") || strings.has_suffix(lower, ".gco") {return .Gcode}
	if strings.has_suffix(lower, ".gif") || mime == "image/gif" {return .Loop}
	// Audio containers such as M4A can arrive with a generic video/mp4 MIME type.
	for ext in ([]string{".mp3", ".ogg", ".flac", ".m4a", ".wav"}) {
		if strings.has_suffix(lower, ext) {return .Audio}
	}
	if is_video_name(lower) || strings.has_prefix(mime, "video/") {return .Video}
	if strings.has_prefix(mime, "audio/") {return .Audio}
	if strings.has_suffix(lower, ".pdf") || mime == "application/pdf" {return .Pdf}
	if is_xdc_name(lower) {
		when ODIN_OS == .OpenBSD {
			return .File
		} else {
			return .Xdc
		}
	}
	for ext in ([]string{".zip", ".rar", ".7z", ".tar", ".tgz", ".txz", ".tbz2"}) {
		if strings.has_suffix(lower, ext) {return .Arc}
	}
	if strings.contains(lower, ".tar.") {return .Arc}
	if strings.has_suffix(lower, ".torrent") ||
	   mime == "application/x-bittorrent" {return .Torrent}
	for ext in ([]string{".md", ".markdown"}) {
		if strings.has_suffix(lower, ext) {return .Text}
	}
	if is_code_name(lower) {return .Code}
	if strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") {return .Font}
	if is_nes_name(lower) {return .Nes}
	if strings.has_prefix(mime, "image/") {return .Image}
	return .File
}

@(private)
media_cached :: proc(kind: Media_Kind, key: string) -> (rawptr, bool) {
	switch kind {
	case .Image:
		if v, ok := video_views[key]; ok && v != nil {return &v.tex, true}
		v, ok := media_textures[key]; return v, ok
	case .Sticker:
		v, ok := media_textures[fmt.tprintf("sticker:%s", key)]; return v, ok
	case .Emoji:
		v, ok := remote_emoji_tex[key]; return v, ok
	case .Mesh:
		v, ok := stl_views[key]; return v, ok
	case .Gcode:
		v, ok := gcode_views[key]; return v, ok
	case .Video, .Loop, .Audio:
		v, ok := video_views[key]; return v, ok
	case .Pdf:
		v, ok := pdf_views[key]; return v, ok
	case .Xdc:
		v, ok := xdc_views[key]; return v, ok
	case .Arc:
		v, ok := arc_views[key]; return v, ok
	case .Torrent:
		v, ok := tor_views[key]; return v, ok
	case .Text:
		v, ok := txt_views[key]; return v, ok
	case .Code:
		v, ok := code_views[key]; return v, ok
	case .Font:
		v, ok := ttf_views[key]; return v, ok
	case .Nes:
		v, ok := nes_views[key]; return v, ok
	case .Original:
		v, ok := original_textures[key]; return v, ok
	case .File:
		return nil, true
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
media_reference :: proc(
	record: ^marmot.Timeline_Message_Record,
	index: int,
) -> ^marmot.Media_Attachment_Reference {
	if record == nil ||
	   index < 0 ||
	   index >= int(record.media_len) ||
	   record.media[index].tag != .ACCEPTED {
		return nil
	}
	return &record.media[index].body.accepted.reference
}

@(private)
reply_image_load :: proc(
	client: ^marmot.Client,
	account, group: cstring,
	preview: ^marmot.Timeline_Reply_Preview,
) -> string {
	if preview.deleted || preview.invalidation_status != nil {return ""}
	for &outcome in preview.media[:preview.media_len] {
		if outcome.tag != .ACCEPTED {continue}
		ref := &outcome.body.accepted.reference
		name := ref.file_name != nil ? string(ref.file_name) : ""
		mime := ref.media_type != nil ? string(ref.media_type) : ""
		if media_kind(name, mime) != .Image {continue}
		// ponytail: previews carry no tags, so a NIP-30 emoji image is
		// recognized by the :stem: of its filename in the preview text.
		// Upgrade: have marmot project the parent's tags into the preview.
		if preview.plaintext != nil &&
		   strings.contains(
			   string(preview.plaintext),
			   fmt.tprintf(":%s:", emoji_code(name)),
		   ) {continue}
		key := ref.plaintext_sha256 != nil ? string(ref.plaintext_sha256) : name
		if _, seen := media_cached(.Image, key); !seen {
			media_enqueue(client, account, group, ref, .Image, key)
		}
		return strings.clone(key)
	}
	return ""
}

@(private)
media_attach :: proc(
	msg: ^Msg_Ui,
	client: ^marmot.Client,
	account, group: cstring,
	outcome: ^marmot.Media_Attachment_Outcome,
	emoji: string, // NIP-30 shortcode this attachment defines, "" otherwise
) {
	// marmot lists outcomes in imeta order with attachment_index equal to
	// the position, so appending keeps slot index = source index.
	if outcome.tag == .REJECTED {
		assert(int(outcome.body.rejected.attachment_index) == len(msg.attachments))
		append(
			&msg.attachments,
			Att_Slot {
				state = .Rejected,
				rejection = media_rejection_text(outcome.body.rejected.rejection.kind),
			},
		)
		return
	}
	assert(int(outcome.body.accepted.attachment_index) == len(msg.attachments))
	ref := &outcome.body.accepted.reference
	name := ref.file_name != nil ? string(ref.file_name) : ""
	key := ref.plaintext_sha256 != nil ? string(ref.plaintext_sha256) : name
	kind := media_kind(name, ref.media_type != nil ? string(ref.media_type) : "")
	if key == msg.sticker.sha && msg.sticker.sha != "" {kind = .Sticker}
	// A NIP-30 emoji asset caches under its shortcode and is drawn by it,
	// never in the row, so its slot needs no loading state.
	cache_key := key
	if emoji != "" {kind, cache_key = .Emoji, emoji}
	append(
		&msg.attachments,
		Att_Slot {
			name = strings.clone(name != "" ? name : "attachment"),
			key = strings.clone(key),
			kind = kind,
		},
	)
	view, seen := media_cached(kind, cache_key)
	if !seen {media_enqueue(client, account, group, ref, kind, cache_key)}
	if !seen && kind != .Emoji {return}
	media_ready(&msg.attachments[len(msg.attachments) - 1], view)
}

// Resolve a slot from its cache entry. A nil view is a failed download
// or decode; kinds with nothing to decode stay ready without a view.
@(private)
media_ready :: proc(slot: ^Att_Slot, view: rawptr) {
	slot.state = .Ready
	if slot.kind == .File || slot.kind == .Emoji {return}
	if view == nil {
		slot.state = .Failed
		return
	}
	if slot.kind == .Image {
		if animation := video_views[slot.key]; animation != nil {
			slot.kind, slot.view = .Loop, animation
			return
		}
	}
	switch slot.kind {
	case .Image, .Sticker:
		slot.view = (^rl.Texture2D)(view)
	case .Mesh:
		slot.view = (^Stl_View)(view)
	case .Gcode:
		slot.view = (^Gcode_View)(view)
	case .Video, .Loop, .Audio:
		slot.view = (^Video_View)(view)
	case .Pdf:
		slot.view = (^Pdf_View)(view)
	case .Xdc:
		slot.view = (^Xdc_View)(view)
	case .Arc:
		slot.view = (^Arc_View)(view)
	case .Torrent:
		slot.view = (^Tor_View)(view)
	case .Text:
		slot.view = (^Txt_View)(view)
	case .Code:
		slot.view = (^Code_View)(view)
	case .Font:
		slot.view = (^Ttf_View)(view)
	case .Nes:
		slot.view = (^Nes_View)(view)
	case .File, .Emoji, .Original:
	}
}

@(private)
media_enqueue :: proc(
	client: ^marmot.Client,
	account, group: cstring,
	ref: ^marmot.Media_Attachment_Reference,
	kind: Media_Kind,
	key: string,
) {
	if media_inflight[Media_Key{key, kind}] {return}
	job := new(Media_Job)
	job^ = {
		queued_at = time.tick_now(),
		client    = client,
		account   = strings.clone_to_cstring(string(account)),
		group     = strings.clone_to_cstring(string(group)),
		key       = strings.clone(key),
		reference = media_ref_clone(ref),
		kind      = kind,
		color     = clay_color(TEXT),
	}
	media_inflight[Media_Key{job.key, kind}] = true
	append(&media_jobs, job)
}

// A reaction chip showing a :code: this device can't draw fetches the
// image its kind-7 carries (NIP-30 emoji tag + imeta). One attempt per
// shortcode per session; see remote_emoji_missed.
@(private)
reaction_emoji_enqueue :: proc(client: ^marmot.Client, account, group: cstring, code: string) {
	if code in remote_emoji_tex || code in remote_emoji_missed {return}
	if media_inflight[Media_Key{code, .Emoji}] {return}
	job := new(Media_Job)
	job^ = {
		queued_at = time.tick_now(),
		client    = client,
		account   = strings.clone_to_cstring(string(account)),
		group     = strings.clone_to_cstring(string(group)),
		key       = strings.clone(code),
		kind      = .Emoji,
		reaction  = true,
	}
	media_inflight[Media_Key{job.key, .Emoji}] = true
	append(&media_jobs, job)
}

// Deep copy, so a job outlives the timeline page or list it came from.
// media_job_free releases it.
@(private = "file")
media_ref_clone :: proc(
	ref: ^marmot.Media_Attachment_Reference,
) -> marmot.Media_Attachment_Reference {
	r := ref^
	for field in ([]^cstring{&r.ciphertext_sha256, &r.plaintext_sha256, &r.nonce_hex, &r.file_name, &r.media_type, &r.dim, &r.thumbhash}) {
		if field^ != nil {field^ = strings.clone_to_cstring(string(field^))}
	}
	locators := make([]marmot.Media_Locator, r.locators_len)
	copy(locators, r.locators[:r.locators_len])
	for &locator in locators {
		locator.kind = strings.clone_to_cstring(string(locator.kind))
		locator.value = strings.clone_to_cstring(string(locator.value))
	}
	r.locators = raw_data(locators)
	return r
}

// Point a reaction job at its image: the group's kind-7 whose emoji tag
// names job.key, then the attachment marmot parsed from that event's
// imeta with the tag's url.
// ponytail: scans the group's retained reactions and media. Use an id
// lookup when marmot-c exposes one.
@(private = "file")
reaction_emoji_ref :: proc(job: ^Media_Job) -> bool {
	kinds := [1]u64{7}
	reactions: ^marmot.App_Message_List
	if marmot.messages(job.client, job.account, job.group, 0, 0, &kinds[0], 1, &reactions) !=
		   .OK ||
	   reactions == nil {
		return false
	}
	defer marmot.app_message_list_free(reactions)

	id, url: string
	for record in reactions.items[:reactions.len] {
		if record.invalidated {continue}
		for tag in record.tags[:record.tags_len] {
			if tag.values_len >= 3 &&
			   string(tag.values[0]) == "emoji" &&
			   string(tag.values[1]) == job.key {
				id, url = string(record.message_id_hex), string(tag.values[2])
			}
		}
	}
	if url == "" {return false}

	media: ^marmot.Media_Record_List
	if marmot.list_media(job.client, job.account, job.group, 0, 0, &media) != .OK || media == nil {
		return false
	}
	defer marmot.media_record_list_free(media)
	for &record in media.items[:media.len] {
		if string(record.message_id_hex) != id {continue}
		ref := &record.reference
		for locator in ref.locators[:ref.locators_len] {
			if string(locator.value) == url {
				job.reference = media_ref_clone(ref)
				return true
			}
		}
	}
	return false
}

@(private)
media_worker :: proc(t: ^thread.Thread) {
	timing_start := time.tick_now()
	defer local_timing_end(.media_prepare, timing_start)
	context.allocator = reload_allocator()
	job := (^Media_Job)(t.data)
	local_timing_end(.media_queue_wait, job.queued_at)
	defer free_all(context.temp_allocator)
	defer {
		sync.lock(&job.mutex)
		job.done = true
		sync.unlock(&job.mutex)
		frame_wake()
	}
	bytes: []u8
	if job.external_gif {
		buffer := make([]u8, GIF_BYTES_LIMIT, context.temp_allocator)
		n := wn_https_get(
			strings.clone_to_cstring(job.key, context.temp_allocator),
			raw_data(buffer),
			uint(len(buffer)),
			HTTPS_TIMEOUT_MS,
		)
		if n <= 0 || !gif_valid(buffer[:n]) {return}
		bytes = slice.clone(buffer[:n])
	} else {
		ok: bool
		if job.reaction && !reaction_emoji_ref(job) {return}
		bytes, ok = media_load(job.client, job.account, job.group, &job.reference)
		if !ok {return}
	}
	decode_start := time.tick_now()
	defer local_timing_end(.media_decode, decode_start)
	job.size = i64(len(bytes))
	defer delete(bytes)
	name := strings.to_lower(string(job.reference.file_name), context.temp_allocator)
	switch job.kind {
	case .Sticker:
		job.image = image_fit(sticker_image(bytes, string(job.reference.media_type)), STICKER_PX)
	case .Image:
		// Animated WebP cannot use the still-image decoder.
		if len(bytes) >= 30 &&
		   string(bytes[:4]) == "RIFF" &&
		   string(bytes[8:16]) == "WEBPVP8X" &&
		   bytes[20] & 2 != 0 {
			job.view = video_view_make(bytes, .Loop, .Prepare)
			bytes = nil
			break
		}
		job.image = image_fit(
			rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes))),
			TIMELINE_IMAGE_PX,
		)
	case .Emoji, .Original:
		job.image = rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes)))
	case .Font:
		job.image = rl.FontSpecimen(bytes, SPECIMEN_LINES, SPECIMEN_SIZES, job.color, 640)
	case .Mesh:
		job.view = model_view_make(name, bytes)
	case .Gcode:
		if segs, parsed := parse_gcode(bytes); parsed {job.view = gcode_view_make(segs)}
	case .Video, .Loop, .Audio:
		mode: Video_Mode = job.kind == .Audio ? .Audio : (job.kind == .Loop ? .Loop : .Clip)
		job.view = video_view_make(bytes, mode, .Prepare)
		bytes = nil // the view owns the stream
	case .Pdf:
		job.view = pdf_view_make(bytes, .Prepare)
	case .Xdc:
		job.view = xdc_view_make(bytes, string(job.reference.file_name), .Prepare)
		if job.view != nil {bytes = nil}
	case .Arc:
		arc := arc_view_make(bytes)
		if arc != nil {
			arc.nes = nes_from_arc(arc)
			bytes = nil
		}
		job.view = arc
	case .Torrent:
		job.view = tor_view_make(bytes)
	case .Text:
		job.view = txt_view_make(string(bytes))
	case .Code:
		job.view = code_view_make(name, string(bytes))
	case .Nes:
		job.view = nes_view_make(bytes)
		if job.view != nil {bytes = nil}
	case .File:
	}
}

@(private)
media_publish :: proc(job: ^Media_Job) {
	timing_start := time.tick_now()
	defer local_timing_end(.media_apply, timing_start)
	// A sticker's display finish must not replace an ordinary photo's texture.
	key := job.kind == .Sticker ? fmt.aprintf("sticker:%s", job.key) : strings.clone(job.key)
	switch job.kind {
	case .Image, .Sticker, .Emoji, .Font, .Original:
		if job.kind == .Image && job.view != nil {
			view := (^Video_View)(job.view)
			view.tex = rl.CreateStreamTexture(view.w, view.h)
			video_views[key] = view
			break
		}
		tex :=
			job.kind == .Sticker ? sticker_texture_load(job.image) : rl.LoadTextureFromImage(job.image)
		if job.kind == .Font {
			view: ^Ttf_View
			if tex.width > 0 {view = new(Ttf_View); view^ = {tex, tex.width, tex.height}}
			ttf_views[key] = view
			delete(([^]u8)(job.image.data)[:job.image.width * job.image.height * 4])
		} else {
			view: ^rl.Texture2D
			if tex.width > 0 {view = new(rl.Texture2D); view^ = tex}
			switch {
			case job.reaction && view == nil:
				remote_emoji_missed[key] = true
			case job.kind == .Emoji:
				remote_emoji_tex[key] = view
			case job.kind == .Original:
				original_textures[key] = view
			case:
				media_textures[key] = view
			}
			rl.UnloadImage(job.image)
		}
	case .Mesh:
		stl_views[key] = (^Stl_View)(job.view)
	case .Gcode:
		gcode_views[key] = (^Gcode_View)(job.view)
	case .Video, .Loop, .Audio:
		view := (^Video_View)(job.view)
		if view != nil {view.tex = rl.CreateStreamTexture(view.w, view.h)}
		video_views[key] = view
	case .Pdf:
		view := (^Pdf_View)(job.view)
		if view != nil && view.failed {pdf_view_free(view); view = nil}
		if view !=
		   nil {view.tex = rl.LoadTextureFromImage(rl.Image{data = raw_data(view.pix), width = view.w, height = view.h})}
		pdf_views[key] = view
	case .Xdc:
		view := (^Xdc_View)(job.view)
		if view != nil && view.icon_image.data != nil {
			view.icon = rl.LoadTextureFromImage(view.icon_image)
			rl.UnloadImage(view.icon_image)
			view.icon_image = {}
		}
		xdc_views[key] = view
	case .Arc:
		arc_views[key] = (^Arc_View)(job.view)
	case .Torrent:
		tor_views[key] = (^Tor_View)(job.view)
	case .Text:
		txt_views[key] = (^Txt_View)(job.view)
	case .Code:
		code_views[key] = (^Code_View)(job.view)
	case .Nes:
		nes_views[key] = (^Nes_View)(job.view)
	case .File:
	}
	if _, exists := blob_sizes[job.key]; !exists {blob_sizes[strings.clone(job.key)] = job.size}
}

@(private)
media_job_free :: proc(job: ^Media_Job) {
	r := &job.reference
	for value in ([]cstring{job.account, job.group, r.ciphertext_sha256, r.plaintext_sha256, r.nonce_hex, r.file_name, r.media_type, r.dim, r.thumbhash}) {delete(value)}
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
			at_bottom =
				data.scrollPosition.y <=
				-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0) + 1
		}
	}
	active := 0
	// A full-size photo's texture upload costs several milliseconds, so publish
	// one finished job per frame and wake the next frame for the rest.
	published := false
	for i := len(media_jobs) - 1; i >= 0; i -= 1 {
		job := media_jobs[i]
		if job.worker == nil {continue}
		sync.lock(&job.mutex)
		done := job.done
		sync.unlock(&job.mutex)
		if !done {active += 1; continue}
		if published {
			active += 1
			frame_wake()
			continue
		}
		published = true
		thread.join(job.worker)
		thread.destroy(job.worker)
		media_publish(job)
		view, _ := media_cached(job.kind, job.key)
		for &msg in ui.messages {
			if job.external_gif && giphy_message_url(msg.body) == job.key {
				msg.row_height = 0
				ui.scroll_pending ||= at_bottom
			}
			if job.kind == .Image && msg.reply_image == job.key {
				msg.row_height = 0
				ui.scroll_pending ||= at_bottom
			}
			// Several slots, in one message or many, can borrow one view.
			for &slot in msg.attachments {
				if slot.state != .Loading ||
				   slot.kind != job.kind ||
				   slot.key != job.key {continue}
				media_ready(&slot, view)
				msg.row_height = 0
				ui.scroll_pending ||= at_bottom
			}
		}
		media_job_free(job)
		ordered_remove(&media_jobs, i)
	}
	for job in media_jobs {
		if active >= MEDIA_WORKERS {break}
		if job.worker != nil {continue}
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
