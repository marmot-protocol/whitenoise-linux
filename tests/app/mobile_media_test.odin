package main

import "core:testing"

@(test)
mobile_nes_viewport_fit :: proc(t: ^testing.T) {
	for width in ([]f32{320, 360, 390, 430, 780}) {
		for height in ([]f32{180, 260, 360, 844}) {
			for zoom in ([]f32{1, 1.5, 2}) {
				w, h := nes_fit_bounds(width, height, zoom, .Touch)
				testing.expect(t, w > 0 && h > 0)
				testing.expect(t, w <= max(1, width - NES_MARGIN) + 0.001)
				testing.expect(t, h <= max(1, height - NES_MARGIN - 190) + 0.001)
				testing.expect(t, abs(w / h - f32(NES_W) / NES_H) < 0.0001)
			}
		}
	}
	w, h := nes_fit_bounds(1280, 900, 1, .Keyboard)
	testing.expect(t, w <= 1280 - NES_MARGIN && h <= 900 - NES_MARGIN - NES_CHROME)
	testing.expect(
		t,
		w / NES_W == f32(int(w / NES_W)) && h / NES_H == f32(int(h / NES_H)),
		"desktop pixels retain integer scaling",
	)
}

@(test)
mobile_image_search_grid :: proc(t: ^testing.T) {
	for width in ([]f32{120, 272, 296, 336, 366, 406, 448}) {
		columns, cell := ov_grid(width)
		testing.expect(t, columns >= 1 && columns <= OV_COLS)
		testing.expect(t, cell > 0 && cell <= OV_CELL)
		testing.expect(t, f32(columns) * cell + f32(columns - 1) * 8 + 40 <= width + 0.001)
	}
}
