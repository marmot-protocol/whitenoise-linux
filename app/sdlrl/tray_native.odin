package sdlrl

import "core:c"
import sdl "vendor:sdl3"

@(private)
NATIVE_TRAY :: ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android

when NATIVE_TRAY {
	@(private = "file")
	TRAY_BUILD_DIR ::
		"../../build" when #config(WN_TARGET, "") ==
		"" else "../../build/cross/" +
		#config(WN_TARGET, "")

	foreign import tray_lib {TRAY_BUILD_DIR + "/libwntray.a", "system:gio-2.0", "system:gobject-2.0", "system:glib-2.0"}

	@(private)
	Tray_Actions :: bit_set[enum {
		Show,
		Quit,
	};c.uint]

	@(private)
	foreign tray_lib {
		wn_tray_start :: proc "c" (rgba: rawptr, w, h: c.int, title, show, quit: cstring, wake: proc "c" ()) ---
		wn_tray_tooltip :: proc "c" (title: cstring) ---
		wn_tray_status :: proc "c" () -> Tray_Status ---
		wn_tray_actions :: proc "c" (token: ^cstring) -> Tray_Actions ---
		wn_tray_stop :: proc "c" () ---
		g_free :: proc "c" (p: rawptr) ---
	}

	@(private)
	native_tray_running: bool

	@(private)
	tray_wake :: proc "c" () {
		event := sdl.Event {
			type = .USER,
		}
		_ = sdl.PushEvent(&event)
	}
}
