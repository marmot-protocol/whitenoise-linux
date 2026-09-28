package main

import "core:c"
import "core:os"

@(private = "file")
WN_TARGET :: #config(WN_TARGET, "")
@(private = "file")
WN_BUILD_DIR :: "../build" when WN_TARGET == "" else "../build/cross/" + WN_TARGET
@(private = "file")
WN_CXX_LIBRARY :: "system:stdc++" when ODIN_OS == .Linux else "system:c++"
when ODIN_OS == .OpenBSD {
	foreign import renderer {WN_BUILD_DIR + "/libwnmath.a", WN_BUILD_DIR + "/microtex/lib/libmicrotex.a", "system:cairo", "system:c++", "system:c++abi", "system:m"}
} else {
	foreign import renderer {WN_BUILD_DIR + "/libwnmath.a", WN_BUILD_DIR + "/microtex/lib/libmicrotex.a", "system:cairo", WN_CXX_LIBRARY, "system:m"}
}
@(default_calling_convention = "c", private = "file")
foreign renderer {
	wn_math_run :: proc(font: ^u8, length: c.ulong) -> c.int ---
}

// Trusted TeX Gyre DejaVu math outlines are embedded, never opened at runtime.
@(private = "file")
MATH_FONT := #load("../vendor/microtex/res/tex-gyre/texgyredejavu-math.clm2")

main :: proc() {
	os.exit(int(wn_math_run(raw_data(MATH_FONT), c.ulong(len(MATH_FONT)))))
}
