package sdlrl

import "core:c"
import "core:c/libc"

foreign import webp "system:webp"

@(private = "file", default_calling_convention = "c")
foreign webp {
	WebPGetInfo :: proc(data: [^]u8, size: c.size_t, width, height: ^c.int) -> c.int ---
	WebPDecodeRGBAInto :: proc(data: [^]u8, size: c.size_t, output: [^]u8, output_size: c.size_t, stride: c.int) -> [^]u8 ---
}

@(private)
decode_webp :: proc(data: [^]u8, size: i32) -> Image {
	w, h: c.int
	if WebPGetInfo(data, c.size_t(size), &w, &h) == 0 || w <= 0 || h <= 0 { return {} }
	bytes := i64(w) * i64(h) * 4
	// Bound decoded allocations from remote image headers to 256 MiB.
	if bytes > 256 * 1024 * 1024 { return {} }
	// stb's image_free uses libc too; every Image keeps one release path.
	pixels := ([^]u8)(libc.malloc(c.size_t(bytes)))
	if pixels == nil { return {} }
	if WebPDecodeRGBAInto(data, c.size_t(size), pixels, c.size_t(bytes), w * 4) == nil {
		libc.free(pixels)
		return {}
	}
	return {data = pixels, width = i32(w), height = i32(h)}
}
