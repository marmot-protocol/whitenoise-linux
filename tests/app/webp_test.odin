package main

import "core:encoding/base64"
import "core:testing"
import rl "sdlrl"

@(test)
webp_image_decode :: proc(t: ^testing.T) {
	bytes, err := base64.decode("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
	testing.expect(t, err == nil)
	defer delete(bytes)
	image := rl.LoadImageFromMemory(".img", raw_data(bytes), i32(len(bytes)))
	defer rl.UnloadImage(image)
	testing.expect(t, image.data != nil)
	testing.expect_value(t, image.width, 1)
	testing.expect_value(t, image.height, 1)
	bad := rl.LoadImageFromMemory(".img", raw_data(bytes), 12)
	testing.expect(t, bad.data == nil)
}
