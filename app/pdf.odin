// PDF pages arrive as RGBA from the isolated wn-pdf helper. The parent
// retains only source bytes, the last page pixels and its SDL texture.
package main

import "core:c"
import "core:c/libc"
import "core:path/filepath"
import "core:strings"

import rl "sdlrl"

PDF_TEX_W :: 480 // rendered page width in px; height follows the page
@(private = "file")
PDF_INPUT_MAX :: 128 << 20
@(private = "file")
PDF_DIM_MAX :: 32768

foreign import pdf_decoder {WN_BUILD_DIR + "/libwndecoder.a"}

@(private = "file", default_calling_convention = "c")
foreign pdf_decoder {
	wn_pdf_render :: proc(helper, font_dir: cstring, data: [^]u8, size: c.int, page, width, height: c.uint, pages, out_width, out_height: ^c.uint) -> [^]u8 ---
}

Pdf_View :: struct {
	data:     []u8, // owned source; reparsed only in the helper on each render
	pages:    int,
	page:     int,
	tex:      rl.Texture2D,
	pix:      []u8, // libc-owned RGBA, retained for tests/rebuilds
	w, h:     i32,
	max_size: rl.Vector2, // zero = inline width; otherwise fit these physical pixels
	failed:   bool,
}

pdf_view_make :: proc(data: []u8, phase: Media_Phase = .Present) -> ^Pdf_View {
	view := new(Pdf_View)

	if len(data) == 0 || len(data) > PDF_INPUT_MAX {
		view.failed = true
		return view
	}
	view.data = make([]u8, len(data))
	copy(view.data, data)
	pdf_render_page(view, phase)
	return view
}

// Render the current page on white at inline width or fitted to max_size.
pdf_render_page :: proc(view: ^Pdf_View, phase: Media_Phase = .Present) {
	view.failed = true
	width, height := c.uint(PDF_TEX_W), c.uint(0)
	if view.max_size.x != 0 || view.max_size.y != 0 {
		// Comparisons reject NaN/infinity before float-to-integer conversion.
		if !(view.max_size.x >= 1 &&
			   view.max_size.x <= PDF_DIM_MAX &&
			   view.max_size.y >= 1 &&
			   view.max_size.y <= PDF_DIM_MAX) {return}
		width, height = c.uint(view.max_size.x), c.uint(view.max_size.y)
	}
	if view.page < 0 || view.page >= 10000 {return}
	fonts, err := filepath.join({res_dir(), "fonts"}, context.temp_allocator)
	if err != nil {return}
	pages, w, h: c.uint
	pixels := wn_pdf_render(
		strings.clone_to_cstring(helper_path("wn-pdf"), context.temp_allocator),
		strings.clone_to_cstring(fonts, context.temp_allocator),
		raw_data(view.data),
		c.int(len(view.data)),
		c.uint(view.page),
		width,
		height,
		&pages,
		&w,
		&h,
	)
	if pixels == nil {return}
	libc.free(raw_data(view.pix))
	view.pix = pixels[:int(w) * int(h) * 4]
	view.pages = int(pages)
	view.w, view.h = i32(w), i32(h)
	view.failed = false
	if phase == .Present {
		rl.UnloadTexture(view.tex)
		view.tex = rl.LoadTextureFromImage(
			rl.Image{data = raw_data(view.pix), width = view.w, height = view.h},
		)
	}
}

pdf_view_free :: proc(view: ^Pdf_View) {
	delete(view.data)
	rl.UnloadTexture(view.tex)
	libc.free(raw_data(view.pix))
	free(view)
}

// Page-flip chips: hover recorded during the build, click after it.
pdf_flip_hover: ^Pdf_View
pdf_flip_dir: int

handle_pdf :: proc() {
	// att_hover set = the click is on the download chip, not the nav.
	if pdf_flip_hover == nil || !mouse_released() || att_hover.msg_id != "" {
		return
	}
	view := pdf_flip_hover
	next := clamp(view.page + pdf_flip_dir, 0, view.pages - 1)
	if next != view.page {
		view.page = next
		pdf_render_page(view)
	}
}
