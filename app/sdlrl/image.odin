package sdlrl

import "core:c"

@(private)
IMAGE_BUILD_DIR ::
	"../../build" when #config(WN_TARGET, "") ==
	"" else "../../build/cross/" +
	#config(WN_TARGET, "")
@(private)
IMAGE_HELPER_DEV ::
	#directory + "/" + IMAGE_BUILD_DIR + "/wn-image" + (".exe" when ODIN_OS == .Windows else "")

foreign import image_lib {IMAGE_BUILD_DIR + "/libwndecoder.a"}

@(private, default_calling_convention = "c")
foreign image_lib {
	wn_image_decode :: proc(helper: cstring, data: [^]u8, size, max_dimension: c.int, max_bytes: c.uint, width, height: ^c.int) -> [^]u8 ---
}
