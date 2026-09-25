// PDF attachments rendered inline with poppler-glib (already on the
// system for every GNOME/GTK document viewer) through a cairo image
// surface, page by page, from memory. The tile shows one page with
// prev/next controls when there are more.
package main

import "core:c"

import rl "sdlrl"

PDF_TEX_W :: 480 // rendered page width in px; height follows the page
CAIRO_FORMAT_ARGB32 :: 0

foreign import ppl "system:poppler-glib"
foreign import gobj "system:gobject-2.0"
foreign import glib "system:glib-2.0"
foreign import cr_lib "system:cairo"

@(default_calling_convention = "c")
foreign glib {
	g_bytes_new :: proc(data: rawptr, size: c.size_t) -> rawptr ---
	g_bytes_unref :: proc(bytes: rawptr) ---
}

@(default_calling_convention = "c")
foreign gobj {
	g_object_unref :: proc(obj: rawptr) ---
}

@(default_calling_convention = "c")
foreign ppl {
	poppler_document_new_from_bytes :: proc(bytes: rawptr, password: cstring, error: rawptr) -> rawptr ---
	poppler_document_get_n_pages :: proc(doc: rawptr) -> c.int ---
	poppler_document_get_page :: proc(doc: rawptr, index: c.int) -> rawptr ---
	poppler_page_get_size :: proc(page: rawptr, width, height: ^f64) ---
	poppler_page_render :: proc(page: rawptr, cr: rawptr) ---
}

@(default_calling_convention = "c")
foreign cr_lib {
	cairo_image_surface_create :: proc(format: c.int, w, h: c.int) -> rawptr ---
	cairo_image_surface_get_data :: proc(surface: rawptr) -> [^]u8 ---
	cairo_image_surface_get_stride :: proc(surface: rawptr) -> c.int ---
	cairo_surface_flush :: proc(surface: rawptr) ---
	cairo_surface_destroy :: proc(surface: rawptr) ---
	cairo_create :: proc(surface: rawptr) -> rawptr ---
	cairo_destroy :: proc(cr: rawptr) ---
	cairo_scale :: proc(cr: rawptr, sx, sy: f64) ---
	cairo_set_source_rgb :: proc(cr: rawptr, r, g, b: f64) ---
	cairo_paint :: proc(cr: rawptr) ---
}

Pdf_View :: struct {
	doc:      rawptr, // PopplerDocument, holds its own ref to the bytes
	pages:    int,
	page:     int,
	tex:      rl.Texture2D,
	pix:      []u8, // last rendered page, RGBA (kept for tests/rebuilds)
	w, h:     i32,
	max_size: rl.Vector2, // zero = inline width; otherwise fit these physical pixels
	failed:   bool,
}

pdf_view_make :: proc(data: []u8, phase: Media_Phase = .Present) -> ^Pdf_View {
	view := new(Pdf_View)

	bytes := g_bytes_new(raw_data(data), c.size_t(len(data)))
	view.doc = poppler_document_new_from_bytes(bytes, nil, nil)
	g_bytes_unref(bytes) // the document keeps its own reference
	if view.doc == nil {
		view.failed = true
		return view
	}

	view.pages = int(poppler_document_get_n_pages(view.doc))
	if view.pages <= 0 {
		view.failed = true
		return view
	}
	pdf_render_page(view, phase)
	return view
}

// Render the current page on white at inline width or fitted to max_size.
// Swizzle cairo's premultiplied BGRA to RGBA; the background is opaque.
pdf_render_page :: proc(view: ^Pdf_View, phase: Media_Phase = .Present) {
	page := poppler_document_get_page(view.doc, c.int(view.page))
	if page == nil {
		view.failed = true
		return
	}
	defer g_object_unref(page)

	wpt, hpt: f64
	poppler_page_get_size(page, &wpt, &hpt)
	if wpt <= 0 || hpt <= 0 {
		view.failed = true
		return
	}
	scale := f64(PDF_TEX_W) / wpt
	if view.max_size.x > 0 && view.max_size.y > 0 {
		scale = min(f64(view.max_size.x) / wpt, f64(view.max_size.y) / hpt)
	}
	w := max(c.int(1), c.int(wpt * scale + 0.5))
	h := max(c.int(1), c.int(hpt * scale + 0.5))

	surface := cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)
	defer cairo_surface_destroy(surface)
	cr := cairo_create(surface)
	cairo_set_source_rgb(cr, 1, 1, 1)
	cairo_paint(cr)
	cairo_scale(cr, scale, scale)
	poppler_page_render(page, cr)
	cairo_destroy(cr)
	cairo_surface_flush(surface)

	src := cairo_image_surface_get_data(surface)
	stride := int(cairo_image_surface_get_stride(surface))
	delete(view.pix)
	view.pix = make([]u8, int(w) * int(h) * 4)
	for row in 0 ..< int(h) {
		for col in 0 ..< int(w) {
			at := row * stride + col * 4 // B,G,R,A in memory (LE ARGB32)
			out := (row * int(w) + col) * 4
			view.pix[out] = src[at + 2]
			view.pix[out + 1] = src[at + 1]
			view.pix[out + 2] = src[at]
			view.pix[out + 3] = 255
		}
	}

	view.w, view.h = i32(w), i32(h)
	if phase == .Present {
		rl.UnloadTexture(view.tex)
		view.tex = rl.LoadTextureFromImage(
			rl.Image{data = raw_data(view.pix), width = view.w, height = view.h},
		)
	}
}

pdf_view_free :: proc(view: ^Pdf_View) {
	if view.doc != nil {
		g_object_unref(view.doc)
	}
	rl.UnloadTexture(view.tex)
	delete(view.pix)
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
