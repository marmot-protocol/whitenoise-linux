// The preview modal: any (name, bytes) pair shown with the same
// renderers the timeline tiles use. Today it opens from archive
// entries; anything that can hand over bytes can call preview_show.
// The modal owns everything it creates and frees it on close (the
// timeline caches keep their views forever; a modal must not).
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

Preview_Kind :: enum {
	None,
	Image,
	Mesh,
	Gcode,
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

preview: Preview
preview_shown: bool

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
		owned.code_kinds = strings.clone(block.code_kinds)
		owned.alignments = make([]marmot.Markdown_Alignment, len(block.alignments))
		copy(owned.alignments, block.alignments)
		owned.cell_fonts = make([][]string, len(block.cell_fonts))
		for row, r in block.cell_fonts {
			owned.cell_fonts[r] = make([]string, len(row))
			for fonts, c in row {owned.cell_fonts[r][c] = strings.clone(fonts)}
		}
		owned.cells = make([][]string, len(block.cells))
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
		if mesh := model_view_make(lower, bytes); mesh != nil {
			fbx_load_textures(&mesh.insp, archive, name)
			preview.mesh = mesh
			preview.kind = .Mesh
		}
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
			free(pdf)
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
		// Merge loaded and failed images back into attachment order.
		row := make([dynamic]Slide, context.temp_allocator)
		for entry in msg.images {
			append(&row, Slide{msg.id, msg.att_names[entry.att], entry.att, entry.view})
		}
		for entry in msg.img_failed {
			append(&row, Slide{msg.id, msg.att_names[entry.att], entry.att, nil})
		}
		slice.sort_by(row[:], proc(a, b: Slide) -> bool {
			return a.att < b.att
		})
		for s in row {
			if s.msg_id == msg_id && s.att == att {
				preview.slide = len(preview.slides)
			}
			append(
				&preview.slides,
				Slide{strings.clone(s.msg_id), strings.clone(s.name), s.att, s.tex},
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

// Click an image tile: open the lightbox on it; a failed tile retries
// the download instead (matching the slint viewer's failed-cell tap).
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
		name := img_link_hover[strings.last_index_byte(img_link_hover, '/') + 1:]
		append(&preview.slides, Slide{"", strings.clone(name), 0, tex})
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
	from, ok := element_box(clay.ID("MsgImage", u32(index) * 1024 + u32(slide.att)))
	if !ok {
		return
	}
	w := f32(rl.GetScreenWidth()) / UI_ZOOM
	h := f32(rl.GetScreenHeight()) / UI_ZOOM
	side := min(w, h) * LIGHTBOX_SHARE
	to := clay.BoundingBox{(w - side) / 2, (h - side) / 2, side, side}
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
		ui.client_status = fmt.aprintf("couldn't open %s", model_hover.name)
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
		ui.client_status = fmt.aprintf("couldn't open %s", code_hover.name)
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
		ui.client_status = fmt.aprintf(
			tr("Couldn't open %s. Please try again."),
			pdf_full_hover.name,
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

// "Copy image": pipe the original bytes to the system clipboard via
// wl-copy, falling back to xclip (the slint clipboard ladder). A slide
// re-fetches its bytes from the record like save_attachment; the
// in-memory kinds already hold them.
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
			ui.client_status = fmt.aprintf("couldn't copy %s", s.name)
			return
		}
		bytes = result.plaintext[:result.plaintext_len]
		name = s.name
	}
	defer if result != nil {
		marmot.media_download_result_free(result)
	}

	// The helpers read a file, not stdin pipes; stage the bytes in the
	// runtime dir under a fixed name.
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if len(dir) == 0 {
		dir = "/tmp"
	}
	path := fmt.tprintf("%s/wn-clipboard-image", dir)
	mime := image_mime(name)
	if os.write_entire_file(path, bytes) != nil {
		ui.client_status = fmt.aprintf("couldn't copy %s", name)
		return
	}
	cmd := fmt.tprintf(
		"wl-copy -t %s < '%s' 2>/dev/null || xclip -selection clipboard -t %s -i '%s' 2>/dev/null",
		mime,
		path,
		mime,
		path,
	)
	state, out, errout, err := os.process_exec(
		{command = {"sh", "-c", cmd}},
		context.temp_allocator,
	)
	delete(out)
	delete(errout)
	if err != nil || state.exit_code != 0 {
		ui.client_status = "couldn't copy image (is wl-copy or xclip installed?)"
		return
	}
	ui.client_status = fmt.aprintf("copied %s", name)
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
	if preview.vid != nil && !preview.vid_shared {
		video_view_free(preview.vid)
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
	}
	delete(preview.slides)
	blocks_free(preview.message_blocks)
	if !preview.vid_shared {delete(preview.bytes)}
	delete(preview.name)
	if preview.kind == .Video {
		rl.SetFullscreen(false)
	}
	preview = {}
	preview_shown = false
}

// Modal layout, mounted with the other overlays.
preview_modal :: proc(ui: ^Ui_State) {
	full :=
		preview.kind == .Pdf ? preview.pdf_fullscreen : (preview.kind == .Video && rl.IsFullscreen())
	image_view := preview.kind == .Image || preview.kind == .Slides
	image_w := fit_w(f32(rl.GetScreenWidth()) / UI_ZOOM * 0.94, 26)
	// A tall body (a long take list, a big hex dump) must not push the
	// modal past the window: cap it and scroll inside instead.
	max_h := f32(rl.GetScreenHeight()) / UI_ZOOM * PV_MAX_HEIGHT
	if full {
		max_h = f32(rl.GetScreenHeight()) / UI_ZOOM
	}
	if clay.UI(clay.ID("PvModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {
				width = full ? clay.SizingFixed(f32(rl.GetScreenWidth()) / UI_ZOOM) : (image_view ? clay.SizingFixed(image_w + 28) : clay.SizingFit({min = min(f32(360), fit_w(640))})),
				height = full || image_view ? clay.SizingFixed(max_h) : clay.SizingFit({max = max_h}),
			},
			padding = clay.PaddingAll(full ? 0 : 14),
			childGap = full ? 0 : 10,
		},
		floating = {
			attachTo = .Root,
			zIndex = 12,
			offset = {0, full ? 0 : rise(clay.ID("PvModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = full ? clay.Color{0, 0, 0, 255} : CARD,
		cornerRadius = rr(full ? 0 : 12),
		border = {color = ELEVATED_BORDER, width = full ? clay.BorderWidth{} : bw()},
	},
	) {
		slides := preview.kind == .Slides
		if clay.UI(clay.ID("PvHead"))(
		{
			layout = {
				sizing = {width = full ? clay.SizingFit({}) : clay.SizingGrow()},
				padding = clay.PaddingAll(full ? 8 : 0),
				childGap = 10,
				childAlignment = {y = .Center},
			},
			floating = full ? clay.FloatingElementConfig{attachTo = .Parent, zIndex = 15, offset = {-12, 12}, attachment = {element = .RightTop, parent = .RightTop}} : {},
			backgroundColor = full ? clay.Color{0, 0, 0, 150} : {},
		},
		) {
			clay.Text(
				arc_short_name(slides ? preview.slides[preview.slide].name : preview.name),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT},
			)
			if clay.UI(clay.ID("PvHeadPad"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if preview.kind == .Message && ui.prefs.tts_enabled {
				micro_button("PvRead", "Read aloud")
			}
			stored := !slides || preview.slides[preview.slide].msg_id != ""
			if stored &&
			   (preview.kind == .Image || (slides && preview.slides[preview.slide].tex != nil)) {
				if clay.UI(clay.ID("PvCopy"))(
				{
					layout = {padding = {left = 10, right = 10, top = 5, bottom = 5}},
					backgroundColor = hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(8),
				},
				) {
					clay.Text("Copy image", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
				}
			}
			if preview.kind == .Video || preview.kind == .Pdf {
				if clay.UI(clay.ID("PvFull"))(
				{
					layout = {padding = {left = 10, right = 10, top = 5, bottom = 5}},
					backgroundColor = hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(8),
				},
				) {
					clay.Text(
						full ? tr("Exit fullscreen") : tr("Fullscreen"),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
					)
				}
			}
			if stored {
				if clay.UI(clay.ID("PvSave"))(
				{
					layout = {padding = {left = 10, right = 10, top = 5, bottom = 5}},
					backgroundColor = hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(8),
				},
				) {
					clay.Text("Save", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
				}
			}
			if clay.UI(clay.ID("PvClose"))(
			{
				layout = {padding = {left = 10, right = 10, top = 5, bottom = 5}},
				backgroundColor = hovered() ? HOVER : ROW_BG,
				cornerRadius = rr(8),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT})
			}
		}

		if image_view {
			if clay.UI(clay.ID("PvZoomTools"))(
			{layout = {childGap = 8, childAlignment = {y = .Center}}},
			) {
				micro_button("PvZoomOut", "−")
				clay.Text(
					fmt.tprintf("%.0f%%", preview.image_scale * UI_ZOOM * 100),
					{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
				)
				micro_button("PvZoomIn", "+")
				micro_button("PvFit", "Fit")
				micro_button("PvActual", "100%")
				slide_nav()
			}
		}
		if clay.UI(clay.ID("PvScroll"))(
		{
			// Height capped below the modal's own cap, or the fit sizing
			// matches the content and the scrollbar never engages.
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {
					width = image_view ? clay.SizingFixed(image_w) : (full ? clay.SizingGrow() : clay.SizingFit({})),
					height = full || image_view ? clay.SizingGrow() : clay.SizingFit({max = max_h - PV_CHROME}),
				},
				childAlignment = {x = full ? .Center : .Left, y = full ? .Center : .Top},
				childGap = 10,
			},
			clip = {
				horizontal = image_view || preview.kind == .Message,
				vertical = true,
				childOffset = clay.GetScrollOffset(),
			},
		},
		) {
			switch preview.kind {
			case .Image, .Slides:
				tex := slides ? preview.slides[preview.slide].tex : &preview.tex
				if tex != nil && tex.width > 0 && tex.height > 0 {
					h := max(f32(80), max_h - PV_CHROME - 40)
					fit := min(image_w / f32(tex.width), h / f32(tex.height))
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
					if clay.UI(clay.ID("PvImageCanvas"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(max(image_w, w)),
								height = clay.SizingFixed(max(h, ih)),
							},
							childAlignment = {x = .Center, y = .Center},
						},
					},
					) {
						if clay.UI(clay.ID("PvImage"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(w),
									height = clay.SizingFixed(ih),
								},
							},
							image = {imageData = tex},
						},
						) {}
					}
				} else {
					if clay.UI(clay.ID("PvRetry"))(
					{layout = {padding = clay.PaddingAll(20)}, backgroundColor = PLATE},
					) {
						clay.Text(
							tr("Image didn't load. Click to retry."),
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
						)
					}
				}

			case .Video:
				view := preview.vid
				// mpv couldn't decode the bytes; retry rebuilds the view.
				if view.failed {
					if clay.UI(clay.ID("PvVidRetry"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(fit_w(480)),
								height = clay.SizingFixed(220),
							},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hovered() ? HOVER : PLATE,
						cornerRadius = rr(8),
					},
					) {
						clay.Text(
							"Couldn't play video. Click to retry.",
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
						)
					}
					break
				}
				ratio := view.w > 0 && view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
				vw :=
					full ? min(f32(rl.GetScreenWidth()) / UI_ZOOM, max_h * ratio) : min(fit_w(480), max(1, max_h - PV_CHROME - 30) * ratio)
				if clay.UI(clay.ID("PvVideo"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(vw)},
						childAlignment = {x = .Center, y = .Center},
					},
					aspectRatio = {ratio},
					image = {imageData = &view.tex},
					cornerRadius = rr(8),
				},
				) {
					if hovered() {
						video_hover = view
					}
					if view.paused {
						clay.Text(
							"\uf04b",
							{fontId = FONT_ICON, fontSize = 22, textColor = {255, 255, 255, 230}},
						)
					}
					video_scrub_bar(clay.ID("PvVideoBar"), view, vw, 14)
				}
				if !view.looping && !full {
					// "m:ss / m:ss" position readout under the bar.
					if clay.UI(clay.ID("PvVideoMeta"))(
					{layout = {sizing = {width = clay.SizingFixed(vw)}}},
					) {
						clay.Text(
							fmt.tprintf("%s / %s", fmt_clock(view.time), fmt_clock(view.dur)),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
					}
				}

			case .Mesh, .Gcode:
				// A mesh gets the inspector sidebar beside it; g-code has
				// no channels to inspect and keeps the bare tile. Both
				// shrink to whatever the capped modal leaves for the body.
				model_h := min(f32(480), max_h - PV_CHROME)
				if clay.UI(clay.ID("PvModelRow"))({layout = {childGap = 10}}) {
					if clay.UI(clay.ID("PvModel"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(fit_w(480)),
								height = clay.SizingFixed(model_h),
							},
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
					},
					) {
						payload: rawptr =
							preview.kind == .Mesh ? rawptr(preview.mesh) : rawptr(preview.gc)
						if clay.UI(clay.ID("PvModelView"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
							},
							custom = {customData = payload},
						},
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
					bar_id := clay.ID("PvGcodeBar")
					append(&gcode_bars, Gcode_Bar{bar_id, preview.gc})
					if clay.UI(bar_id)(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(fit_w(480)),
								height = clay.SizingFixed(14),
							},
							padding = {left = 2, right = 2},
							childAlignment = {y = .Center},
						},
						backgroundColor = ROW_BG,
						cornerRadius = rr(7),
					},
					) {
						if clay.UI(clay.ID("PvGcodeFill"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(max(10, preview.gc.frac * 476)),
									height = clay.SizingFixed(10),
								},
							},
							backgroundColor = ACCENT,
							cornerRadius = rr(5),
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
				if clay.UI(clay.ID("PvPdf"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(
								full ? min(f32(rl.GetScreenWidth()) / UI_ZOOM, max_h * ratio) : fit_w(480),
							),
						},
						childAlignment = {x = .Center, y = .Bottom},
					},
					aspectRatio = {ratio},
					image = {imageData = &view.tex},
					cornerRadius = rr(8),
				},
				) {
					if view.pages > 1 {
						if clay.UI(clay.ID("PvPdfNav"))(
						{
							layout = {
								padding = {left = 8, right = 8, top = 4, bottom = 4},
								childGap = 10,
								childAlignment = {y = .Center},
							},
							backgroundColor = {0, 0, 0, 140},
							cornerRadius = rr(12),
						},
						) {
							if clay.UI(clay.ID("PvPdfPrev"))(
							{layout = {padding = clay.PaddingAll(4)}},
							) {
								if hovered() {
									pdf_flip_hover = view
									pdf_flip_dir = -1
								}
								clay.Text(
									"<",
									{
										fontId = FONT_TITLE,
										fontSize = 13,
										textColor = {255, 255, 255, 230},
									},
								)
							}
							clay.Text(
								fmt.tprintf("%d / %d", view.page + 1, view.pages),
								{
									fontId = FONT_BODY,
									fontSize = 11,
									textColor = {255, 255, 255, 230},
								},
							)
							if clay.UI(clay.ID("PvPdfNext"))(
							{layout = {padding = clay.PaddingAll(4)}},
							) {
								if hovered() {
									pdf_flip_hover = view
									pdf_flip_dir = 1
								}
								clay.Text(
									">",
									{
										fontId = FONT_TITLE,
										fontSize = 13,
										textColor = {255, 255, 255, 230},
									},
								)
							}
						}
					}
				}

			case .Message:
				clear(&sel_lines)
				if clay.UI(clay.ID("PvMessage"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingFixed(fit_w(640, 32))},
						padding = {right = PV_TEXT_GUTTER},
						childGap = 3,
					},
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
				if clay.UI(clay.ID("PvText"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingFixed(fit_w(480))},
						padding = clay.PaddingAll(10),
						childGap = 6,
					},
					backgroundColor = PLATE,
					cornerRadius = rr(8),
				},
				) {
					shown := min(len(preview.txt.blocks), TXT_MODAL_BLOCKS)
					md_blocks(preview.txt.blocks[:shown], 0x7f000000, wrap_w = fit_w(480) - 20)
					if len(preview.txt.blocks) > shown {
						clay.Text(
							fmt.tprintf("and %d more blocks", len(preview.txt.blocks) - shown),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
					}
				}

			case .Code:
				view := preview.code
				if clay.UI(clay.ID("PvCode"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingFixed(fit_w(600))},
						padding = clay.PaddingAll(10),
						childGap = 1,
					},
					backgroundColor = PLATE,
					cornerRadius = rr(8),
				},
				) {
					code_lines(
						view,
						0,
						CODE_MODAL_LINES,
						fit_w(600) - 20,
						clay.ID("PvScroll"),
						10,
						1,
					)
				}

			case .Hex:
				if clay.UI(clay.ID("PvHexBody"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingFixed(fit_w(600))},
						padding = clay.PaddingAll(10),
						childGap = 1,
					},
					backgroundColor = PLATE,
					cornerRadius = rr(8),
				},
				) {
					hex_rows(preview.bytes)
				}

			case .Font:
				view := preview.font
				ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
				if clay.UI(clay.ID("PvFont"))(
				{
					layout = {sizing = {width = clay.SizingFixed(fit_w(480))}},
					aspectRatio = {ratio},
					image = {imageData = &view.tex},
				},
				) {}

			case .Unsupported, .None:
				if clay.UI(clay.ID("PvNone"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(20),
						childGap = 10,
						childAlignment = {x = .Center},
					},
				},
				) {
					clay.Text(
						"No preview for this file type. Save it, or read the bytes.",
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
					if clay.UI(clay.ID("PvHex"))(
					{
						layout = {padding = {left = 10, right = 10, top = 6, bottom = 6}},
						backgroundColor = hovered() ? HOVER : ROW_BG,
						cornerRadius = rr(8),
					},
					) {
						clay.Text(
							"View as hex",
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
						)
					}
				}
			}
		}
		scrollbar(clay.ID("PvScroll"), 13) // the modal floats at 12
	}
}

// Prev / "n / N" / next pill, riding the bottom of the slide.
@(private = "file")
slide_nav :: proc() {
	if len(preview.slides) <= 1 {
		return
	}
	if clay.UI(clay.ID("PvSlideNav"))(
	{
		layout = {
			padding = {left = 8, right = 8, top = 4, bottom = 4},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = {0, 0, 0, 140},
		cornerRadius = rr(12),
	},
	) {
		if clay.UI(clay.ID("PvSlidePrev"))({layout = {padding = clay.PaddingAll(4)}}) {
			clay.Text("<", {fontId = FONT_TITLE, fontSize = 13, textColor = {255, 255, 255, 230}})
		}
		clay.Text(
			fmt.tprintf("%d / %d", preview.slide + 1, len(preview.slides)),
			{fontId = FONT_BODY, fontSize = 11, textColor = {255, 255, 255, 230}},
		)
		if clay.UI(clay.ID("PvSlideNext"))({layout = {padding = clay.PaddingAll(4)}}) {
			clay.Text(">", {fontId = FONT_TITLE, fontSize = 13, textColor = {255, 255, 255, 230}})
		}
	}
}

// Esc or the header buttons; runs after layout. Slides add prev/next
// (arrow keys or the pill), retry, and copy.
handle_preview :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !preview_shown {
		return
	}
	if rl.IsKeyPressed(.ESCAPE) {
		preview_close()
		return
	}
	if preview.kind == .Pdf && clicked("PvFull") {
		preview.pdf_fullscreen = !preview.pdf_fullscreen
		if data := clay.GetScrollContainerData(clay.ID("PvScroll")); data.found {
			data.scrollPosition^ = {}
		}
		return
	}
	if preview.kind == .Message && clicked("PvRead") {
		tts_read(ui, string(preview.bytes))
		return
	}
	if preview.kind == .Image || preview.kind == .Slides {
		point := rl.GetMousePosition()
		if rl.IsMouseButtonPressed(.LEFT) &&
		   clay.PointerOver(clay.ID("PvScroll")) &&
		   !clay.PointerOver(clay.ID("ScrollThumb", clay.ID("PvScroll").id)) {
			preview.image_drag = true
			preview.image_pointer = point
			scroll_residual = {}
		}
		if !rl.IsMouseButtonDown(.LEFT) {preview.image_drag = false}
		if preview.image_drag {
			if data := clay.GetScrollContainerData(clay.ID("PvScroll")); data.found {
				delta := rl.Vector2 {
					(point.x - preview.image_pointer.x) / UI_ZOOM,
					(point.y - preview.image_pointer.y) / UI_ZOOM,
				}
				data.scrollPosition.x = clamp(
					data.scrollPosition.x + delta.x,
					min(
						f32(0),
						data.scrollContainerDimensions.width - data.contentDimensions.width,
					),
					0,
				)
				data.scrollPosition.y = clamp(
					data.scrollPosition.y + delta.y,
					min(
						f32(0),
						data.scrollContainerDimensions.height - data.contentDimensions.height,
					),
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
			if data := clay.GetScrollContainerData(clay.ID("PvScroll"));
			   data.found {data.scrollPosition^ = {}}
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
		if rl.IsKeyPressed(.LEFT) || clicked("PvSlidePrev") {
			preview.slide = max(preview.slide - 1, 0)
		}
		if rl.IsKeyPressed(.RIGHT) || clicked("PvSlideNext") {
			preview.slide = min(preview.slide + 1, len(preview.slides) - 1)
		}
		if previous != preview.slide {
			preview.image_zoom = 0
			if data := clay.GetScrollContainerData(clay.ID("PvScroll"));
			   data.found {data.scrollPosition^ = {}}
		}
		if clicked("PvRetry") {
			retry_failed_images(ui, client)
			return
		}
	}
	if !mouse_released() {
		return
	}
	if clay.PointerOver(clay.ID("PvClose")) {
		preview_close()
		return
	}
	if preview.kind == .Slides && preview.slides[preview.slide].msg_id == "" {
		return
	}
	if clay.PointerOver(clay.ID("PvCopy")) {
		copy_preview_image(ui, client)
		return
	}
	if clay.PointerOver(clay.ID("PvSave")) {
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

		if clay.UI(clay.ID("PvHexRow", u32(row)))({layout = {childGap = 8}}) {
			clay.Text(
				fmt.tprintf("%08x", at),
				{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO, wrapMode = .None},
			)
			clay.Text(
				fmt.tprintf("%-49s", strings.to_string(hex)),
				{fontId = FONT_MONO, fontSize = 11, textColor = TEXT, wrapMode = .None},
			)
			clay.Text(
				strings.to_string(ascii),
				{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
			)
		}
	}
	if len(bytes) > rows * HEX_COLS {
		clay.Text(
			fmt.tprintf("and %s more", arc_size_label(i64(len(bytes) - rows * HEX_COLS))),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
	}
}
