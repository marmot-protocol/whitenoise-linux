package sdlrl

import "core:c"
import "core:fmt"

import sdl "vendor:sdl3"

@(private = "file")
SANDBOX_BUILD_DIR ::
	"../../build" when #config(WN_TARGET, "") ==
	"" else "../../build/cross/" +
	#config(WN_TARGET, "")

foreign import sandbox_tools {SANDBOX_BUILD_DIR + "/libwnsandbox.a"}

@(private = "file", default_calling_convention = "c")
foreign sandbox_tools {
	wn_tools_dialog :: proc(save, multiple: c.int, name: cstring, callback: sdl.DialogFileCallback, userdata: rawptr) -> c.int ---
}

@(private)
Confined_Dialog_Kind :: enum {
	Open_One,
	Open_Many,
	Save,
}

@(private)
confined_dialog :: proc(
	kind: Confined_Dialog_Kind,
	name: cstring,
	callback: sdl.DialogFileCallback,
) {
	if error := wn_tools_dialog(
		c.int(kind == .Save),
		c.int(kind == .Open_Many),
		name,
		callback,
		nil,
	); error != 0 {
		fmt.eprintfln("OpenBSD confined file dialog: error %d", error)
		callback(nil, nil, -error)
	}
}
