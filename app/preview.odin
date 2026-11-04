// The preview modal: any (name, bytes) pair shown with the same
// renderers the timeline tiles use. Today it opens from archive
// entries; anything that can hand over bytes can call preview_show.
// The modal owns everything it creates and frees it on close (the
// timeline caches keep their views forever; a modal must not).
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

Preview_Kind :: enum {
	None,
	Image,
	Mesh,
	Gcode,
	Model_Loading,
	Video,
	Pdf,
	Text,
	Message,
	Code,
	Hex,
	Font,
	Slides,
	Unsupported,
}

// Hex fallback: 16 bytes a row, capped so a huge blob can't turn the
// modal into a scrollback dump. Anything unpreviewable can be read
// this way.
HEX_COLS :: 16
HEX_ROWS :: 64

// Share of the window height the modal may take before its body
// starts scrolling, and the header + padding the body sits under.
PV_MAX_HEIGHT :: 0.75
PV_CHROME :: 70
@(private)
PV_TEXT_GUTTER :: u16(12)

// One entry of the lightbox slideshow: an image attachment of the open
// conversation. tex points into the media_textures session cache
// (never freed here); nil = the download failed, the slide is a retry
// target.
Slide :: struct {
	msg_id: string, // owned
	name:   string, // owned
	att:    int, // position in the record's media list
	tex:    ^rl.Texture2D,
	key:    string, // owned; blob key of the full-size original
}

Preview :: struct {
	kind:           Preview_Kind,
	name:           string, // owned
	bytes:          []u8, // owned; also the save source
	tex:            rl.Texture2D, // Image
	mesh:           ^Stl_View,
	gc:             ^Gcode_View,
	vid:            ^Video_View,
	vid_shared:     bool, // timeline cache owns the view and its bytes
	pdf:            ^Pdf_View,
	pdf_fullscreen: bool, // fills the app window without changing desktop fullscreen
	txt:            ^Txt_View,
	message_blocks: [dynamic]Md_Block_Ui,
	code:           ^Code_View,
	font:           ^Ttf_View,
	slides:         [dynamic]Slide, // Slides
	slide:          int, // current slideshow position
	image_zoom:     f32, // 0 = initial readable scale, -1 = fit, positive = scale
	image_scale:    f32, // last rendered scale, for zoom controls
	image_tex_w:    i32, // width image_zoom is relative to; 0 = none drawn yet
	image_drag:     bool,
	image_pointer:  rl.Vector2,
}

// Image tile under the pointer, rebound every build (like att_hover).
Img_Ref :: struct {
	msg_id: string,
	att:    int,
}
img_hover: Img_Ref
// Image-link tile under the pointer (the URL it previews), rebound every
// build. Its slide has no msg_id: the bytes were never kept, so the
// lightbox offers no Copy or Save for it.
img_link_hover: string
@(private)
img_link_cells: []Att_Slot // borrowed from the hovered mosaic for this frame

preview: Preview
preview_shown: bool

// A model the modal is decoding off the UI thread: parse, stand-in and
// face normals take ~230 ms for a 1.2M-triangle STL. The worker owns
// `bytes` (preview.bytes, shared while the modal waits) and `view`
// until done; a load the modal stopped waiting for frees itself.
@(private = "file")
Model_Load :: struct {
	mutex:     sync.Mutex,
	lower:     string, // owned
	bytes:     []u8,
	archive:   ^Arc_View, // texture source, read on the UI thread once done
	// The opener's allocator: whoever finishes with the view frees it.
	// In app builds this is reload_allocator(); tests pass their own.
	allocator: mem.Allocator,
	view:      ^Stl_View,
	done:      bool,
	dropped:   bool,
}

@(private = "file")
model_load: ^Model_Load

@(private = "file")
model_load_worker :: proc(job: ^Model_Load) {
	context.allocator = job.allocator
	defer free_all(context.temp_allocator)
	view := model_view_make(job.lower, job.bytes)
	sync.lock(&job.mutex)
	job.view, job.done = view, true
	dropped := job.dropped
	sync.unlock(&job.mutex)
	if dropped {
		model_load_free(job)
	}
	frame_wake()
}

@(private = "file")
model_load_free :: proc(job: ^Model_Load) {
	if job.view != nil {
		stl_view_free(job.view)
	}
	delete(job.bytes)
	delete(job.lower)
	free(job)
}

// Stop waiting for the load: free it now if it finished, or let the
// worker free it when it does. The job takes preview.bytes with it.
@(private = "file")
model_load_drop :: proc() {
	job := model_load
	model_load = nil
	sync.lock(&job.mutex)
	done := job.done
	job.dropped = true
	sync.unlock(&job.mutex)
	if done {
		model_load_free(job)
	}
}

// Move a finished load into the modal. Texture images come from the
// archive here, on the UI thread that owns it.
@(private)
preview_model_poll :: proc() {
	job := model_load
	if job == nil {
		return
	}
	sync.lock(&job.mutex)
	done := job.done
	sync.unlock(&job.mutex)
	if !done {
		return
	}

	model_load = nil
	preview.kind = .Unsupported
	if job.view != nil {
		fbx_load_textures(&job.view.insp, job.archive, preview.name)
		preview.mesh = job.view
		preview.kind = .Mesh
	}
	delete(job.lower)
	free(job)
}

@(private)
preview_message :: proc(text: string, blocks: []Md_Block_Ui = nil) {
	preview_close()
	preview = {
		kind  = .Message,
		name  = strings.clone(tr("Message")),
		bytes = clone_bytes(transmute([]u8)text),
	}
	for block in blocks {
		owned := block
		owned.text = strings.clone(block.text)
		owned.fonts = strings.clone(block.fonts)
		owned.links = links_clone(block.links[:])
		owned.timestamps = timestamps_clone(block.timestamps[:])
		owned.code_kinds = strings.clone(block.code_kinds)
		owned.alignments = make([]marmot.Markdown_Alignment, len(block.alignments))
		copy(owned.alignments, block.alignments)
		owned.cell_fonts = make([][]string, len(block.cell_fonts))
		for row, r in block.cell_fonts {
			owned.cell_fonts[r] = make([]string, len(row))
			for fonts, c in row {owned.cell_fonts[r][c] = strings.clone(fonts)}
		}
		owned.cells = make([][]string, len(block.cells))
		owned.cell_links = make([][][dynamic]Inline_Link, len(block.cell_links))
		for row, r in block.cell_links {
			owned.cell_links[r] = make([][dynamic]Inline_Link, len(row))
			for links, c in row {owned.cell_links[r][c] = links_clone(links[:])}
		}
		for row, r in block.cells {
			owned.cells[r] = make([]string, len(row))
			for cell, c in row {owned.cells[r][c] = strings.clone(cell)}
		}
		append(&preview.message_blocks, owned)
	}
	preview_shown = true
}

// Dispatch by extension, mirroring the timeline branches. bytes
// ownership transfers here.
preview_show :: proc(name: string, bytes: []u8, archive: ^Arc_View = nil) {
	preview_close()
	lower := strings.to_lower(name, context.temp_allocator)
	has :: strings.has_suffix

	preview = {
		kind  = .Unsupported,
		name  = strings.clone(name),
		bytes = bytes,
	}
	switch {
	case has(lower, ".gif"):
		preview.vid = video_view_make(clone_bytes(bytes), .Loop)
		preview.kind = .Video
	case is_video_name(lower):
		preview.vid = video_view_make(clone_bytes(bytes), .Clip)
		preview.kind = .Video
	case is_model_name(lower):
		model_load = new(Model_Load)
		model_load^ = {
			lower     = strings.clone(lower),
			bytes     = bytes,
			archive   = archive,
			allocator = context.allocator,
		}
		append(
			&send_threads,
			thread.create_and_start_with_poly_data(model_load, model_load_worker),
		)
		preview.kind = .Model_Loading
	case has(lower, ".gcode") || has(lower, ".gco"):
		if segs, ok := parse_gcode(bytes); ok {
			preview.gc = gcode_view_make(segs)
			preview.kind = .Gcode
		}
	case has(lower, ".md") || has(lower, ".markdown"):
		preview.txt = txt_view_make(string(bytes))
		preview.kind = .Text
	case is_code_name(lower):
		preview.code = code_view_make(lower, string(bytes))
		preview.kind = .Code
	case has(lower, ".ttf") || has(lower, ".otf"):
		if font := ttf_view_make(bytes); font != nil {
			preview.font = font
			preview.kind = .Font
		}
	case has(lower, ".pdf"):
		pdf := pdf_view_make(bytes)
		if pdf.failed {
			pdf_view_free(pdf)
		} else {
			preview.pdf = pdf
			preview.kind = .Pdf
		}
	case:
		image := rl.LoadImageFromMemory(".png", raw_data(bytes), i32(len(bytes)))
		if image.data != nil {
			// stbi sniffs the actual format; the ext hint is unused.
			preview.tex = rl.LoadTextureFromImage(image)
			rl.UnloadImage(image)
			preview.kind = .Image
		}
	}
	preview_shown = true
}

@(private = "file")
clone_bytes :: proc(bytes: []u8) -> []u8 {
	out := make([]u8, len(bytes))
	copy(out, bytes)
	return out
}

// Open the preview as a whole-conversation slideshow: every image
// attachment of the open chat in message order, positioned on the
// clicked one.
preview_show_slides :: proc(ui: ^Ui_State, msg_id: string, att: int) {
	preview_close()
	for msg in ui.messages {
		// Loaded and failed images alike, in attachment order.
		for slot, i in msg.attachments {
			if slot.kind != .Image && slot.kind != .Sticker {continue}
			if slot.state != .Ready && slot.state != .Failed {continue}
			if msg.id == msg_id && i == att {
				preview.slide = len(preview.slides)
			}
			tex, ready := slot.view.(^rl.Texture2D)
			append(
				&preview.slides,
				Slide {
					strings.clone(msg.id),
					strings.clone(slot.name),
					i,
					tex,
					strings.clone(ready ? slot.key : ""),
				},
			)
		}
	}
	if len(preview.slides) == 0 {
		preview = {}
		return
	}
	preview.kind = .Slides
	preview_shown = true
}

// Timeline textures are capped at TIMELINE_IMAGE_PX, so a slide whose
// texture reaches the cap may have more pixels in its original.
@(private = "file")
slide_downscaled :: proc(s: Slide) -> bool {
	return s.tex != nil && s.key != "" && max(s.tex.width, s.tex.height) >= TIMELINE_IMAGE_PX
}

// The texture to draw for a slide: its full-size original once decoded,
// the timeline texture until then. loading while the original is on its way.
@(private = "file")
slide_texture :: proc(s: Slide) -> (tex: ^rl.Texture2D, loading: bool) {
	if !slide_downscaled(s) {return s.tex, false}
	if full := original_textures[s.key]; full != nil {return full, false}
	return s.tex, media_inflight[{s.key, .Original}]
}

// Queue the full-size decode for the slide on screen, once per lightbox.
@(private = "file")
slide_original_request :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	s := preview.slides[preview.slide]
	if !slide_downscaled(s) || client == nil || ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}
	if _, seen := original_textures[s.key]; seen || media_inflight[{s.key, .Original}] {return}
	group := ui.chats[ui.selected].group_id
	page := timeline_page
	if timeline_job == nil ||
	   string(timeline_job.group) != group ||
	   string(timeline_job.account) != ui.account_ref {page = nil}
	reference, _ := page_media_ref(page, s.msg_id, s.att)
	if reference == nil {reference = group_file_ref(ui, group, s.msg_id, s.att)}
	if reference == nil {return}
	media_enqueue(
		client,
		strings.clone_to_cstring(ui.account_ref, context.temp_allocator),
		strings.clone_to_cstring(group, context.temp_allocator),
		reference,
		.Original,
		s.key,
	)
}

// Click an image tile: open the lightbox on it; a failed tile retries
// the download instead.
handle_img_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if (img_hover.msg_id == "" && img_link_hover == "") ||
	   preview_shown ||
	   !mouse_released() ||
	   att_hover.msg_id != "" ||
	   drag_moved {
		return
	}
	if img_link_hover != "" {
		tex := nev_img(img_link_hover)
		if tex == nil {return}
		preview_close()
		preview.kind = .Slides
		cells := img_link_cells
		if len(cells) == 0 {cells = []Att_Slot{{key = img_link_hover, view = tex}}}
		for cell in cells {
			image := cell.view.(^rl.Texture2D) or_continue
			if cell.key == img_link_hover {preview.slide = len(preview.slides)}
			name := cell.key[strings.last_index_byte(cell.key, '/') + 1:]
			append(&preview.slides, Slide{"", strings.clone(name), 0, image, ""})
		}
		preview_shown = true
		return
	}
	preview_show_slides(ui, img_hover.msg_id, img_hover.att)
	lightbox_fly(ui)
}

// The tile expands into the lightbox: the picture flies from where it
// sits in the timeline to where the modal is about to open, so the two
// read as one image moving rather than one closing and another opening.
LIGHTBOX_SHARE :: f32(0.62) // of the shorter window side, near enough to the modal

@(private = "file")
lightbox_fly :: proc(ui: ^Ui_State) {
	if preview.slide >= len(preview.slides) {
		return
	}
	slide := preview.slides[preview.slide]
	if slide.tex == nil {
		return
	}
	index := -1
	for msg, i in ui.messages {
		if msg.id == slide.msg_id {
			index = i
			break
		}
	}
	if index < 0 {
		return
	}
	// The cell id the album builds (timeline.odin): row index, attachment.
	from, ok := element_box(nendo.id("MsgImage", msg_slot_id(u32(index), slide.att)))
	if !ok {
		return
	}
	w := f32(rl.GetScreenWidth()) / UI_ZOOM
	h := f32(rl.GetScreenHeight()) / UI_ZOOM
	side := min(w, h) * LIGHTBOX_SHARE
	to := nendo.Rect{(w - side) / 2, (h - side) / 2, side, side}
	fly(from, to, slide.tex, "", {}, shape = .Card)
}

// Click a model tile: open the same file in the preview modal, where
// the inspector lives. A press that turned into an orbit drag is not
// a click, so rotating the tile never opens the modal.
handle_model_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if model_hover.msg_id == "" || preview_shown || !mouse_released() || orbit_moved {
		return
	}
	if att_hover.msg_id != "" || ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}

	result, ok := fetch_attachment(
		ui,
		client,
		ui.chats[ui.selected].group_id,
		model_hover.msg_id,
		model_hover.att,
	)
	if !ok {
		set_status(
			ui,
			fmt.aprintf(tr("Couldn't open %s. Please try again."), model_hover.name),
			.Error,
		)
		return
	}
	defer marmot.media_download_result_free(result)
	// preview_show takes ownership, and the result is freed here.
	preview_show(model_hover.name, clone_bytes(result.plaintext[:result.plaintext_len]))
}

// Click a source tile: the full file in the preview modal, which
// scrolls where the tile truncates.
code_hover: Model_Ref

handle_code_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if code_hover.msg_id == "" || preview_shown || !mouse_released() {
		return
	}
	if att_hover.msg_id != "" || ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}

	result, ok := fetch_attachment(
		ui,
		client,
		ui.chats[ui.selected].group_id,
		code_hover.msg_id,
		code_hover.att,
	)
	if !ok {
		set_status(
			ui,
			fmt.aprintf(tr("Couldn't open %s. Please try again."), code_hover.name),
			.Error,
		)
		return
	}
	defer marmot.media_download_result_free(result)
	preview_show(code_hover.name, clone_bytes(result.plaintext[:result.plaintext_len]))
}

@(private)
pdf_full_hover: Model_Ref
@(private)
pdf_full_page: int

@(private)
handle_pdf_full :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if pdf_full_hover.msg_id == "" || preview_shown || !mouse_released() || drag_moved {
		return
	}
	if att_hover.msg_id != "" || ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}
	result, ok := fetch_attachment(
		ui,
		client,
		ui.chats[ui.selected].group_id,
		pdf_full_hover.msg_id,
		pdf_full_hover.att,
	)
	if !ok {
		set_status(
			ui,
			fmt.aprintf(tr("Couldn't open %s. Please try again."), pdf_full_hover.name),
			.Error,
		)
		return
	}
	defer marmot.media_download_result_free(result)
	preview_show(pdf_full_hover.name, clone_bytes(result.plaintext[:result.plaintext_len]))
	if preview.kind != .Pdf {return}
	preview.pdf.page = clamp(pdf_full_page, 0, preview.pdf.pages - 1)
	preview.pdf_fullscreen = true
}

// Drop every failed (nil) entry from the image session cache and
// reload the timeline, so the downloads run again. An open slideshow
// is rebuilt in place, keeping its position.
retry_failed_images :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	stale := make([dynamic]string, context.temp_allocator)
	for key, tex in media_textures {
		if tex == nil {
			append(&stale, key)
		}
	}
	for key in stale {
		k, _ := delete_key(&media_textures, key)
		delete(k)
	}

	cur_id: string
	cur_att: int
	rebuild := preview_shown && preview.kind == .Slides
	if rebuild {
		cur_id = strings.clone(preview.slides[preview.slide].msg_id, context.temp_allocator)
		cur_att = preview.slides[preview.slide].att
	}
	load_timeline(client, ui)
	if rebuild {
		preview_show_slides(ui, cur_id, cur_att)
	}
}

// SDL owns the clipboard offer on every desktop. Keep the bytes alive until
// its cleanup callback instead of writing decrypted images to a temp file.
@(private = "file")
copy_preview_image :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	bytes := preview.bytes
	name := preview.name
	result: ^marmot.Media_Download_Result
	if preview.kind == .Slides {
		s := &preview.slides[preview.slide]
		if s.tex == nil || ui.selected < 0 || ui.selected >= len(ui.chats) {
			return
		}
		ok: bool
		result, ok = fetch_attachment(ui, client, ui.chats[ui.selected].group_id, s.msg_id, s.att)
		if !ok {
			toast(ui, fmt.tprintf(tr("Couldn't copy %s. Please try again."), s.name))
			return
		}
		bytes = result.plaintext[:result.plaintext_len]
		name = s.name
	}
	defer if result != nil {
		marmot.media_download_result_free(result)
	}

	offer := new(Clipboard_Image)
	offer.allocator = context.allocator
	offer.bytes = make([]u8, len(bytes))
	copy(offer.bytes, bytes)
	mime := strings.clone_to_cstring(image_mime(name), context.temp_allocator)
	if !sdl.SetClipboardData(clipboard_image_data, clipboard_image_free, offer, &mime, 1) {
		// SDL takes ownership before invoking the platform backend, even
		// when that backend fails. Clearing runs its cleanup exactly once.
		_ = sdl.ClearClipboardData()
		toast(ui, tr("Couldn't copy the image to the clipboard. Please try again."))
		return
	}
	toast(ui, fmt.tprintf(tr("Copied %s."), name))
}

@(private = "file")
Clipboard_Image :: struct {
	bytes:     []u8,
	allocator: mem.Allocator,
}

@(private = "file")
clipboard_image_data :: proc "c" (userdata: rawptr, mime: cstring, size: ^uint) -> rawptr {
	if mime == nil || size == nil {return nil}
	offer := (^Clipboard_Image)(userdata)
	size^ = uint(len(offer.bytes))
	return raw_data(offer.bytes)
}

@(private = "file")
clipboard_image_free :: proc "c" (userdata: rawptr) {
	context = runtime.default_context()
	offer := (^Clipboard_Image)(userdata)
	allocator := offer.allocator
	delete(offer.bytes, allocator)
	free(offer, allocator)
}

// Clipboard MIME from the attachment name; the helpers advertise it to
// paste targets.
@(private = "file")
image_mime :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".jpg") || strings.has_suffix(lower, ".jpeg"):
		return "image/jpeg"
	case strings.has_suffix(lower, ".webp"):
		return "image/webp"
	case strings.has_suffix(lower, ".bmp"):
		return "image/bmp"
	}
	return "image/png"
}

preview_close :: proc() {
	if !preview_shown && preview.name == "" {
		return
	}
	if preview.vid != nil {
		if preview.vid_shared {
			preview.vid.max_width = 0
			preview.vid.sized = false
		} else {
			video_view_free(preview.vid)
		}
	}
	if preview.mesh != nil {
		stl_view_free(preview.mesh)
	}
	if preview.gc != nil {
		gcode_view_free(preview.gc)
	}
	if preview.pdf != nil {
		pdf_view_free(preview.pdf)
	}
	if preview.txt != nil {
		txt_view_free(preview.txt)
	}
	if preview.code != nil {
		code_view_free(preview.code)
	}
	if preview.font != nil {
		ttf_view_free(preview.font)
	}
	rl.UnloadTexture(preview.tex)
	for s in preview.slides {
		delete(s.msg_id)
		delete(s.name)
		delete(s.key)
	}
	delete(preview.slides)
	// Full-size textures are large; keep them only while the lightbox is open.
	for key, tex in original_textures {
		if tex != nil {rl.UnloadTexture(tex^); free(tex)}
		delete(key)
	}
	clear(&original_textures)
	blocks_free(preview.message_blocks)
	if model_load != nil {
		model_load_drop()
	} else if !preview.vid_shared {
		delete(preview.bytes)
	}
	delete(preview.name)
	if preview.kind == .Video {
		rl.SetFullscreen(false)
	}
	preview = {}
	preview_shown = false
}

// Modal layout, mounted with the other overlays.
preview_modal :: proc(ui: ^Ui_State) {
	narrow := single_pane()
	full :=
		preview.kind == .Pdf ? preview.pdf_fullscreen : (preview.kind == .Video && rl.IsFullscreen())
	image_view := preview.kind == .Image || preview.kind == .Slides
	image_w := fit_w(f32(rl.GetScreenWidth()) / UI_ZOOM * 0.94, 26)
	// A tall body (a long take list, a big hex dump) must not push the
	// modal past the window: cap it and scroll inside instead.
	max_h :=
		narrow ? modal_h(f32(rl.GetScreenHeight()) / UI_ZOOM) : f32(rl.GetScreenHeight()) / UI_ZOOM * PV_MAX_HEIGHT
	if full {
		max_h = f32(rl.GetScreenHeight()) / UI_ZOOM
	}
	if nendo.box(nendo.id("PvModal"))(
	{
		direction = .Column,
		width = full ? nendo.fixed(f32(rl.GetScreenWidth()) / UI_ZOOM) : (narrow ? nendo.fixed(fit_w(640)) : (image_view ? nendo.fixed(image_w + 28) : nendo.fit(min = min(f32(360), fit_w(640))))),
		height = full || image_view || narrow ? nendo.fixed(max_h) : nendo.fit(max = max_h),
		padding = nendo.pad(full ? 0 : 14),
		gap = full ? 0 : 10,
		clip = {y = narrow, scroll = true},
		floating = {
			attach_to = .Root,
			z = 12,
			offset = {0, full ? 0 : rise(nendo.id("PvModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = full ? MEDIA_BACKDROP : CARD,
		radius = rr(full ? 0 : 12),
		border = {color = ELEVATED_BORDER, width = full ? nendo.Border_Width{} : bw()},
	},
	) {
		slides := preview.kind == .Slides
		if nendo.box(nendo.id("PvHead"))(
		{
			width = full && !narrow ? nendo.fit() : nendo.grow(),
			padding = nendo.pad(full ? 8 : 0),
			gap = 10,
			align = {y = .Center},
			floating = full ? nendo.Floating{attach_to = .Parent, z = 15, offset = {narrow ? 0 : -12, narrow ? 0 : 12}, attach = {element = .Right_Top, parent = .Right_Top}} : {},
			color = full ? MEDIA_CHIP_BG : {},
		},
		) {
			if !narrow {
				nendo.text(
					arc_short_name(slides ? preview.slides[preview.slide].name : preview.name),
					{font = FONT_TITLE, size = 13, color = full ? MEDIA_CHIP_FG : TEXT},
				)
			}
			if nendo.box(nendo.id("PvHeadActions"))(
			{
				width = nendo.grow(),
				gap = 10,
				align = {y = .Center},
				clip = {x = narrow, scroll = true},
			},
			) {
				if nendo.box(nendo.id("PvHeadPad"))({width = nendo.grow()}) {}
				if preview.kind == .Message && ui.prefs.tts_enabled {
					micro_button("PvRead", tr("Read aloud"))
				}
				if preview.kind == .Code {
					micro_button("PvCopyCode", tr("Copy"))
				}
				stored := !slides || preview.slides[preview.slide].msg_id != ""
				if stored &&
				   (preview.kind == .Image ||
						   (slides && preview.slides[preview.slide].tex != nil)) {
					if nendo.box(nendo.id("PvCopy"))(
					{
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 10, right = 10, top = 5, bottom = 5},
						align = {y = .Center},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(tr("Copy image"), {font = FONT_BODY, size = 12, color = TEXT})
					}
				}
				if preview.kind == .Video || preview.kind == .Pdf {
					if nendo.box(nendo.id("PvFull"))(
					{
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 10, right = 10, top = 5, bottom = 5},
						align = {y = .Center},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(
							full ? tr("Exit fullscreen") : tr("Fullscreen"),
							{font = FONT_BODY, size = 12, color = TEXT},
						)
					}
				}
				if stored {
					if nendo.box(nendo.id("PvSave"))(
					{
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 10, right = 10, top = 5, bottom = 5},
						align = {y = .Center},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(tr("Save"), {font = FONT_BODY, size = 12, color = TEXT})
					}
				}
			}
			if nendo.box(nendo.id("PvClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 32),
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : ROW_BG,
				radius = rr(8),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT})
			}
		}

		if image_view {
			if nendo.box(nendo.id("PvZoomTools"))(
			{
				width = nendo.grow(),
				gap = 8,
				align = {y = .Center},
				clip = {x = true, scroll = true},
			},
			) {
				micro_button("PvZoomOut", "\u2212")
				nendo.text(
					fmt.tprintf("%.0f%%", preview.image_scale * UI_ZOOM * 100),
					{font = FONT_MONO, size = 11, color = TEXT_DIM},
				)
				micro_button("PvZoomIn", "+")
				micro_button("PvFit", tr("Fit"))
				micro_button("PvActual", "100%")
				slide_nav()
				if slides {
					if _, loading := slide_texture(preview.slides[preview.slide]); loading {
						nendo.text(
							tr("Loading full resolution\u2026"),
							{font = FONT_BODY, size = 11, color = TEXT_DIM},
						)
						busy_bar("PvOriginalBar")
					}
				}
			}
		}
		if nendo.box(nendo.id("PvScroll"))(
		{
			// Height capped below the modal's own cap, or the fit sizing
			// matches the content and the scrollbar never engages.
			direction = .Column,
			width = narrow || full ? nendo.grow() : (image_view ? nendo.fixed(image_w) : nendo.fit()),
			height = full || image_view || narrow ? nendo.grow(min = 44) : nendo.fit(max = max(1, max_h - PV_CHROME)),
			align = {x = full ? .Center : .Left, y = full ? .Center : .Top},
			gap = 10,
			clip = {x = true, y = true, scroll = true},
		},
		) {
			if narrow && !full {
				if nendo.box(nendo.id("PvFileName"))({width = nendo.grow(), clip = {x = true}}) {
					nendo.text(
						arc_short_name(slides ? preview.slides[preview.slide].name : preview.name),
						{font = FONT_TITLE, size = 13, color = TEXT, wrap = .None},
					)
				}
			}
			switch preview.kind {
			case .Image, .Slides:
				tex := &preview.tex
				if slides {tex, _ = slide_texture(preview.slides[preview.slide])}
				if tex != nil && tex.width > 0 && tex.height > 0 {
					h := max(f32(80), max_h - PV_CHROME - 40)
					fit := min(image_w / f32(tex.width), h / f32(tex.height))
					// The original replacing its downscaled texture keeps the
					// on-screen size: zoom is relative to texture pixels.
					if preview.image_tex_w > 0 && preview.image_zoom > 0 {
						preview.image_zoom *= f32(preview.image_tex_w) / f32(tex.width)
					}
					preview.image_tex_w = tex.width
					if preview.image_zoom == 0 {
						preview.image_zoom = min(fit, 1)
						if tex.width >
						   3 *
							   tex.height {preview.image_zoom = max(preview.image_zoom, min(1, 160 / f32(tex.height)))}
						if tex.height >
						   3 *
							   tex.width {preview.image_zoom = max(preview.image_zoom, min(1, 160 / f32(tex.width)))}
					}
					preview.image_scale = preview.image_zoom < 0 ? fit : preview.image_zoom
					w, ih :=
						f32(tex.width) * preview.image_scale, f32(tex.height) * preview.image_scale
					if nendo.box(nendo.id("PvImageCanvas"))(
					{
						width = nendo.fixed(max(image_w, w)),
						height = nendo.fixed(max(h, ih)),
						align = {x = .Center, y = .Center},
					},
					) {
						if nendo.box(nendo.id("PvImage"))(
						{width = nendo.fixed(w), height = nendo.fixed(ih), image = tex},
						) {}
					}
				} else {
					if nendo.box(nendo.id("PvRetry"))({padding = nendo.pad(20), color = PLATE}) {
						nendo.text(
							tr("Image didn't load. Click to retry."),
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
					}
				}

			case .Video:
				view := preview.vid
				// mpv couldn't decode the bytes; retry rebuilds the view.
				if view.failed {
					if nendo.box(nendo.id("PvVidRetry"))(
					{
						width = nendo.fixed(fit_w(480)),
						height = nendo.fixed(220),
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : PLATE,
						radius = rr(8),
					},
					) {
						nendo.text(
							tr("Couldn't play video. Click to retry."),
							{font = FONT_BODY, size = 12, color = TEXT_DIM},
						)
					}
					break
				}
				ratio := view.dw > 0 && view.dh > 0 ? f32(view.dw) / f32(view.dh) : 16.0 / 9.0
				vw :=
					full ? min(f32(rl.GetScreenWidth()) / UI_ZOOM, max_h * ratio) : min(fit_w(480), max(1, max_h - PV_CHROME - 30) * ratio)
				width := max(1, i32(vw * UI_SCALE + 0.5))
				if view.max_width != width {
					view.max_width = width
					view.sized = false // repaint even when playback is paused
				}
				if nendo.box(nendo.id("PvVideo"))(
				{
					width = nendo.fixed(vw),
					align = {x = .Center, y = .Center},
					aspect = ratio,
					image = &view.tex,
					radius = rr(8),
				},
				) {
					if hovered() {
						video_hover = view
					}
					if view.paused {
						nendo.text(
							"\uf04b",
							{font = FONT_ICON, size = 22, color = {255, 255, 255, 230}},
						)
					}
					video_scrub_bar(nendo.id("PvVideoBar"), view, vw, 14)
				}
				if !view.looping && !full {
					// "m:ss / m:ss" position readout under the bar.
					if nendo.box(nendo.id("PvVideoMeta"))({width = nendo.fixed(vw)}) {
						nendo.text(
							fmt.tprintf("%s / %s", fmt_clock(view.time), fmt_clock(view.dur)),
							{font = FONT_BODY, size = 11, color = TEXT_DIM},
						)
					}
				}

			case .Model_Loading:
				// The model tile plus the inspector beside it, so the
				// modal keeps its size when the decode lands.
				if nendo.box(nendo.id("PvModelLoading"))(
				{
					width = nendo.fixed(narrow ? fit_w(480, 26) : fit_w(480) + 10 + INSP_WIDTH),
					height = nendo.fixed(max(1, min(f32(480), max_h - PV_CHROME))),
					direction = .Column,
					gap = 10,
					align = {x = .Center, y = .Center},
					color = PLATE,
					radius = rr(8),
				},
				) {
					nendo.text(
						tr("Reading the model\u2026"),
						{font = FONT_BODY, size = 13, color = TEXT},
					)
					nendo.text(
						tr("Progress is indeterminate."),
						{font = FONT_BODY, size = 12, color = TEXT_LO},
					)
					busy_bar("PvModelBusy")
				}

			case .Mesh, .Gcode:
				if tap_size() {
					if nendo.box(nendo.id("PvModelTools"))({gap = 8}) {
						micro_button("PvModelZoomOut", "−")
						micro_button("PvModelZoomIn", "+")
						micro_button("PvModelFit", tr("Fit"))
					}
				}
				// A mesh gets the inspector sidebar beside it; g-code has
				// no channels to inspect and keeps the bare tile. Both
				// shrink to whatever the capped modal leaves for the body.
				model_h := max(1, min(f32(480), max_h - PV_CHROME))
				if nendo.box(nendo.id("PvModelRow"))(
				{direction = narrow ? .Column : .Row, gap = 10},
				) {
					if nendo.box(nendo.id("PvModel"))(
					{
						width = nendo.fixed(narrow ? fit_w(480, 26) : fit_w(480)),
						height = nendo.fixed(model_h),
						color = PLATE,
						radius = rr(8),
					},
					) {
						payload: rawptr =
							preview.kind == .Mesh ? rawptr(preview.mesh) : rawptr(preview.gc)
						if nendo.box(nendo.id("PvModelView"))(
						{width = nendo.grow(), height = nendo.grow(), custom = payload},
						) {
							if hovered() {
								orbit_hover =
									preview.kind == .Mesh ? &preview.mesh.orbit : &preview.gc.orbit
							}
						}
					}
					if preview.kind == .Mesh {
						inspector_panel(preview.mesh, model_h)
						if preview.mesh.insp.playing {
							append(&playing_models, preview.mesh)
						}
					}
				}
				if preview.kind == .Gcode {
					bar_id := nendo.id("PvGcodeBar")
					append(&gcode_bars, Gcode_Bar{bar_id, preview.gc})
					if nendo.box(bar_id)(
					{
						width = nendo.fixed(fit_w(480)),
						height = nendo.fixed(tap_size() ? tap_min() : 14),
						padding = {left = 2, right = 2},
						align = {y = .Center},
						color = ROW_BG,
						radius = rr(7),
					},
					) {
						if nendo.box(nendo.id("PvGcodeFill"))(
						{
							width = nendo.fixed(max(10, preview.gc.frac * (fit_w(480) - 4))),
							height = nendo.fixed(10),
							color = ACCENT,
							radius = rr(5),
						},
						) {}
					}
				}

			case .Pdf:
				view := preview.pdf
				dpi := rl.GetWindowScaleDPI()
				size :=
					full ? rl.Vector2{f32(rl.GetScreenWidth()) * dpi.x, f32(rl.GetScreenHeight()) * dpi.y} : rl.Vector2{}
				if view.max_size != size {
					view.max_size = size
					pdf_render_page(view)
				}
				ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 0.77
				if nendo.box(nendo.id("PvPdf"))(
				{
					width = nendo.fixed(
						full ? min(f32(rl.GetScreenWidth()) / UI_ZOOM, max_h * ratio) : fit_w(480),
					),
					align = {x = .Center, y = .Bottom},
					aspect = ratio,
					image = &view.tex,
					radius = rr(8),
				},
				) {
					if view.pages > 1 {
						if nendo.box(nendo.id("PvPdfNav"))(
						{
							padding = {left = 8, right = 8, top = 4, bottom = 4},
							gap = 10,
							align = {y = .Center},
							color = {0, 0, 0, 140},
							radius = rr(12),
						},
						) {
							if nendo.box(nendo.id("PvPdfPrev"))(
							{
								width = nendo.fit(min = tap_size() ? tap_min() : 0),
								height = nendo.fit(min = tap_size() ? tap_min() : 0),
								padding = nendo.pad(4),
								align = {x = .Center, y = .Center},
							},
							) {
								if view.page > 0 && hovered() {
									pdf_flip_hover = view
									pdf_flip_dir = -1
								}
								nendo.text(
									"<",
									{
										font = FONT_TITLE,
										size = 13,
										color = {255, 255, 255, view.page > 0 ? 230 : 80},
									},
								)
							}
							nendo.text(
								fmt.tprintf("%d / %d", view.page + 1, view.pages),
								{font = FONT_BODY, size = 11, color = {255, 255, 255, 230}},
							)
							if nendo.box(nendo.id("PvPdfNext"))(
							{
								width = nendo.fit(min = tap_size() ? tap_min() : 0),
								height = nendo.fit(min = tap_size() ? tap_min() : 0),
								padding = nendo.pad(4),
								align = {x = .Center, y = .Center},
							},
							) {
								if view.page < view.pages - 1 && hovered() {
									pdf_flip_hover = view
									pdf_flip_dir = 1
								}
								nendo.text(
									">",
									{
										font = FONT_TITLE,
										size = 13,
										color = {
											255,
											255,
											255,
											view.page < view.pages - 1 ? 230 : 80,
										},
									},
								)
							}
						}
					}
				}

			case .Message:
				clear(&sel_lines)
				if nendo.box(nendo.id("PvMessage"))(
				{
					direction = .Column,
					width = nendo.fixed(fit_w(640, 32)),
					padding = {right = PV_TEXT_GUTTER},
					gap = 3,
				},
				) {
					if len(preview.message_blocks) > 0 {
						md_blocks(
							preview.message_blocks[:],
							0x7f000000,
							true,
							fit_w(640, 32) - f32(PV_TEXT_GUTTER),
						)
					} else {
						body_text(
							0x7f000000,
							string(preview.bytes),
							BODY_FS,
							TEXT,
							true,
							fit_w(640, 32) - f32(PV_TEXT_GUTTER),
						)
					}
				}

			case .Text:
				if nendo.box(nendo.id("PvText"))(
				{
					direction = .Column,
					width = nendo.fixed(fit_w(480, narrow ? 26 : 12)),
					padding = nendo.pad(10),
					gap = 6,
					color = PLATE,
					radius = rr(8),
				},
				) {
					shown := min(len(preview.txt.blocks), TXT_MODAL_BLOCKS)
					md_blocks(
						preview.txt.blocks[:shown],
						0x7f000000,
						wrap_w = fit_w(480, narrow ? 26 : 12) - 20,
					)
					if len(preview.txt.blocks) > shown {
						nendo.text(
							fmt.tprintf(tr("and %d more blocks"), len(preview.txt.blocks) - shown),
							{font = FONT_BODY, size = 11, color = TEXT_DIM},
						)
					}
				}

			case .Code:
				view := preview.code
				if nendo.box(nendo.id("PvCode"))(
				{
					direction = .Column,
					width = nendo.fixed(fit_w(600, narrow ? 26 : 12)),
					padding = nendo.pad(10),
					gap = 1,
					color = PLATE,
					radius = rr(8),
				},
				) {
					code_lines(
						view,
						0,
						CODE_MODAL_LINES,
						fit_w(600, narrow ? 26 : 12) - 20,
						nendo.id("PvScroll"),
						10,
						1,
					)
				}

			case .Hex:
				if nendo.box(nendo.id("PvHexBody"))(
				{
					direction = .Column,
					width = nendo.fixed(fit_w(600)),
					padding = nendo.pad(10),
					gap = 1,
					color = PLATE,
					radius = rr(8),
				},
				) {
					hex_rows(preview.bytes)
				}

			case .Font:
				view := preview.font
				ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
				if nendo.box(nendo.id("PvFont"))(
				{width = nendo.fixed(fit_w(480)), aspect = ratio, image = &view.tex},
				) {}

			case .Unsupported, .None:
				if nendo.box(nendo.id("PvNone"))(
				{direction = .Column, padding = nendo.pad(20), gap = 10, align = {x = .Center}},
				) {
					nendo.text(
						tr("No preview for this file type. Save it, or read the bytes."),
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
					if nendo.box(nendo.id("PvHex"))(
					{
						padding = {left = 10, right = 10, top = 6, bottom = 6},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(tr("View as hex"), {font = FONT_BODY, size = 12, color = TEXT})
					}
				}
			}
		}
		scrollbar(nendo.id("PvScroll"), 13) // the modal floats at 12
		scrollbar(nendo.id("PvHeadActions"), 16)
		if image_view {scrollbar(nendo.id("PvZoomTools"), 13)}
	}
	if narrow {scrollbar(nendo.id("PvModal"), 13)}
}

// Prev / "n / N" / next pill, riding the bottom of the slide.
@(private = "file")
slide_nav :: proc() {
	if len(preview.slides) <= 1 {
		return
	}
	if nendo.box(nendo.id("PvSlideNav"))(
	{
		padding = {left = 8, right = 8, top = 4, bottom = 4},
		gap = 10,
		align = {y = .Center},
		color = {0, 0, 0, 140},
		radius = rr(12),
	},
	) {
		if nendo.box(nendo.id("PvSlidePrev"))(
		{
			width = nendo.fixed(tap_size() ? tap_min() : 16),
			height = nendo.fixed(tap_size() ? tap_min() : 24),
			align = {x = .Center, y = .Center},
		},
		) {
			nendo.text(
				"<",
				{
					font = FONT_TITLE,
					size = 13,
					color = {255, 255, 255, preview.slide > 0 ? 230 : 80},
				},
			)
		}
		nendo.text(
			fmt.tprintf("%d / %d", preview.slide + 1, len(preview.slides)),
			{font = FONT_BODY, size = 11, color = {255, 255, 255, 230}},
		)
		if nendo.box(nendo.id("PvSlideNext"))(
		{
			width = nendo.fixed(tap_size() ? tap_min() : 16),
			height = nendo.fixed(tap_size() ? tap_min() : 24),
			align = {x = .Center, y = .Center},
		},
		) {
			nendo.text(
				">",
				{
					font = FONT_TITLE,
					size = 13,
					color = {255, 255, 255, preview.slide < len(preview.slides) - 1 ? 230 : 80},
				},
			)
		}
	}
}

// Esc or the header buttons; runs after layout. Slides add prev/next
// (arrow keys or the pill), retry, and copy.
handle_preview :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !preview_shown {
		return
	}
	preview_model_poll()
	if rl.IsKeyPressed(.ESCAPE) {
		preview_close()
		return
	}
	if preview.kind == .Slides {slide_original_request(ui, client)}
	if preview.kind == .Pdf && clicked("PvFull") {
		preview.pdf_fullscreen = !preview.pdf_fullscreen
		if data := nendo.scroll(nendo.id("PvScroll")); data.found {
			data.position^ = {}
		}
		return
	}
	if preview.kind == .Message && clicked("PvRead") {
		tts_read(ui, string(preview.bytes))
		return
	}
	if preview.kind == .Code && clicked("PvCopyCode") {
		// The original bytes: the view's source has its tabs expanded.
		copy_text(ui, string(preview.bytes), tr("Copied"))
		return
	}
	if preview.kind == .Mesh || preview.kind == .Gcode {
		orbit := preview.kind == .Mesh ? &preview.mesh.orbit : &preview.gc.orbit
		if clicked(
			"PvModelZoomOut",
		) {orbit.zoom = max(STL_ZOOM_MIN, orbit.zoom / STL_ZOOM_STEP); orbit.dirty = true; return}
		if clicked(
			"PvModelZoomIn",
		) {orbit.zoom = min(STL_ZOOM_MAX, orbit.zoom * STL_ZOOM_STEP); orbit.dirty = true; return}
		if clicked("PvModelFit") {orbit.zoom = 1; orbit.dirty = true; return}
	}
	if preview.kind == .Image || preview.kind == .Slides {
		point := rl.GetMousePosition()
		if rl.IsMouseButtonPressed(.LEFT) &&
		   nendo.pointer_over(nendo.id("PvScroll")) &&
		   !nendo.pointer_over(nendo.id("ScrollThumb", nendo.id("PvScroll").id)) {
			preview.image_drag = true
			preview.image_pointer = point
			scroll_residual = {}
		}
		if !rl.IsMouseButtonDown(.LEFT) {preview.image_drag = false}
		if preview.image_drag {
			if data := nendo.scroll(nendo.id("PvScroll")); data.found {
				delta := rl.Vector2 {
					(point.x - preview.image_pointer.x) / UI_ZOOM,
					(point.y - preview.image_pointer.y) / UI_ZOOM,
				}
				data.position.x = clamp(
					data.position.x + delta.x,
					min(f32(0), data.viewport.width - data.content.width),
					0,
				)
				data.position.y = clamp(
					data.position.y + delta.y,
					min(f32(0), data.viewport.height - data.content.height),
					0,
				)
			}
			preview.image_pointer = point
		}
		changed := true
		switch {
		case clicked("PvZoomIn"):
			preview.image_zoom = clamp(preview.image_scale * 1.25, 0.01, 8)
		case clicked("PvZoomOut"):
			preview.image_zoom = clamp(preview.image_scale / 1.25, 0.01, 8)
		case clicked("PvFit"):
			preview.image_zoom = -1
		case clicked("PvActual"):
			preview.image_zoom = 1 / UI_ZOOM
		case:
			changed = false
		}
		if changed {
			if data := nendo.scroll(nendo.id("PvScroll")); data.found {data.position^ = {}}
		}
	}
	if preview.kind == .Video {
		if clicked("PvFull") {
			if preview.vid_shared && rl.IsFullscreen() {preview_close(); return}
			rl.SetFullscreen(!rl.IsFullscreen())
			return
		}
		if preview.vid.failed && clicked("PvVidRetry") {
			mode := preview.vid.looping ? Video_Mode.Loop : Video_Mode.Clip
			if preview.vid_shared {
				preview.bytes = clone_bytes(preview.bytes)
				preview.vid_shared = false
			} else {
				video_view_free(preview.vid)
			}
			preview.vid = video_view_make(clone_bytes(preview.bytes), mode)
			return
		}
	}
	if preview.kind == .Mesh {
		handle_inspector(preview.mesh)
	}
	if clicked("PvHex") {
		preview.kind = .Hex
		return
	}
	if preview.kind == .Slides {
		previous := preview.slide
		if preview.slide > 0 && (rl.IsKeyPressed(.LEFT) || clicked("PvSlidePrev")) {
			preview.slide -= 1
		}
		if preview.slide < len(preview.slides) - 1 &&
		   (rl.IsKeyPressed(.RIGHT) || clicked("PvSlideNext")) {
			preview.slide += 1
		}
		if previous != preview.slide {
			preview.image_zoom = 0
			preview.image_tex_w = 0
			if data := nendo.scroll(nendo.id("PvScroll")); data.found {data.position^ = {}}
		}
		if clicked("PvRetry") {
			retry_failed_images(ui, client)
			return
		}
	}
	if !mouse_released() {
		return
	}
	if nendo.pointer_over(nendo.id("PvClose")) {
		preview_close()
		return
	}
	if preview.kind == .Slides && preview.slides[preview.slide].msg_id == "" {
		return
	}
	if nendo.pointer_over(nendo.id("PvCopy")) {
		copy_preview_image(ui, client)
		return
	}
	if nendo.pointer_over(nendo.id("PvSave")) {
		if preview.kind == .Slides {
			if ui.selected >= 0 && ui.selected < len(ui.chats) {
				s := &preview.slides[preview.slide]
				start_att_save(
					{
						group = ui.chats[ui.selected].group_id,
						msg_id = s.msg_id,
						index = s.att,
						name = s.name,
					},
				)
			}
		} else {
			start_blob_save(preview.name, preview.bytes)
		}
	}
}

// Hex dump rows: "offset  16 bytes  |ascii|", the shape every hex
// viewer uses, built per frame from the preview bytes (a capped
// number of rows, so the formatting cost is bounded).
@(private = "file")
hex_rows :: proc(bytes: []u8) {
	rows := min((len(bytes) + HEX_COLS - 1) / HEX_COLS, HEX_ROWS)
	for row in 0 ..< rows {
		at := row * HEX_COLS
		chunk := bytes[at:min(at + HEX_COLS, len(bytes))]

		hex := strings.builder_make(context.temp_allocator)
		ascii := strings.builder_make(context.temp_allocator)
		for b, i in chunk {
			fmt.sbprintf(&hex, i == HEX_COLS / 2 - 1 ? "%02x  " : "%02x ", b)
			// Printable ASCII only; everything else reads as a dot.
			strings.write_byte(&ascii, b >= 0x20 && b < 0x7f ? b : '.')
		}

		if nendo.box(nendo.id("PvHexRow", u32(row)))({gap = 8}) {
			nendo.text(
				fmt.tprintf("%08x", at),
				{font = FONT_MONO, size = 11, color = TEXT_LO, wrap = .None},
			)
			nendo.text(
				fmt.tprintf("%-49s", strings.to_string(hex)),
				{font = FONT_MONO, size = 11, color = TEXT, wrap = .None},
			)
			nendo.text(
				strings.to_string(ascii),
				{font = FONT_MONO, size = 11, color = TEXT_DIM, wrap = .None},
			)
		}
	}
	if len(bytes) > rows * HEX_COLS {
		nendo.text(
			fmt.tprintf(tr("and %s more"), arc_size_label(i64(len(bytes) - rows * HEX_COLS))),
			{font = FONT_BODY, size = 11, color = TEXT_DIM},
		)
	}
}
