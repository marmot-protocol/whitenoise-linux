// Poppler pipeline check on a minimal handcrafted PDF.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
pdf_render :: proc(t: ^testing.T) {
	// One blank 200x100pt page, xref offsets computed as we build.
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	offsets: [4]int
	obj :: proc(b: ^strings.Builder, offsets: ^[4]int, n: int, body: string) {
		offsets[n - 1] = strings.builder_len(b^)
		fmt.sbprintf(b, "%d 0 obj\n%s\nendobj\n", n, body)
	}

	strings.write_string(&b, "%PDF-1.4\n")
	obj(&b, &offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")
	obj(&b, &offsets, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
	obj(&b, &offsets, 3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >>")

	xref := strings.builder_len(b)
	strings.write_string(&b, "xref\n0 4\n0000000000 65535 f \n")
	for off in offsets[:3] {
		fmt.sbprintf(&b, "%010d 00000 n \n", off)
	}
	fmt.sbprintf(&b, "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", xref)

	view := pdf_view_make(b.buf[:])
	defer pdf_view_free(view)
	testing.expect(t, !view.failed)
	testing.expect_value(t, view.pages, 1)
	testing.expect_value(t, view.w, i32(PDF_TEX_W))
	testing.expect_value(t, view.h, i32(PDF_TEX_W / 2)) // 200x100pt page

	// Blank page renders as the white background.
	testing.expect(t, len(view.pix) > 0 && view.pix[0] == 255 && view.pix[3] == 255)

	view.max_size = {1600, 900}
	pdf_render_page(view)
	testing.expect_value(t, view.w, i32(1600))
	testing.expect_value(t, view.h, i32(800))

	view.max_size = {1, 1}
	pdf_render_page(view)
	testing.expect_value(t, view.w, i32(1))
	testing.expect_value(t, view.h, i32(1))

	view.max_size = {}
	pdf_render_page(view)
	testing.expect_value(t, view.w, i32(PDF_TEX_W))
	testing.expect_value(t, view.h, i32(PDF_TEX_W / 2))
}
