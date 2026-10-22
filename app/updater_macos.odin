#+build darwin
package main

import "core:c/libc"
import "core:strings"
import rl "sdlrl"

when ODIN_OS == .Darwin {
	when !#config(WN_RELOAD, false) {
		foreign import sparkle_bridge {WN_BUILD_DIR + "/libwnsparkle.a", "system:Cocoa.framework", "system:objc"}

		@(private, default_calling_convention = "c")
		foreign sparkle_bridge {
			wn_sparkle_start :: proc(home: cstring) ---
			wn_sparkle_stop :: proc() ---
			wn_sparkle_available :: proc() -> bool ---
			wn_sparkle_can_check :: proc() -> bool ---
			wn_sparkle_check :: proc() ---
			wn_sparkle_auto :: proc() -> bool ---
			wn_sparkle_set_auto :: proc(enabled: bool) ---
			wn_sparkle_take_quit :: proc() -> bool ---
			wn_sparkle_relaunch_home :: proc() -> cstring ---
			wn_sparkle_status :: proc() -> cstring ---
		}
	}

	@(private)
	macos_update_start :: proc() {
		when !#config(WN_RELOAD, false) {
			wn_sparkle_start(strings.clone_to_cstring(data_home, context.temp_allocator))
		}
	}

	@(private)
	macos_update_stop :: proc() {
		when !#config(WN_RELOAD, false) {wn_sparkle_stop()}
	}

	@(private)
	macos_update_available :: proc() -> bool {
		when !#config(WN_RELOAD, false) {return wn_sparkle_available()} else {return false}
	}

	@(private)
	macos_update_can_check :: proc() -> bool {
		when !#config(WN_RELOAD, false) {return wn_sparkle_can_check()} else {return false}
	}

	@(private)
	macos_update_check :: proc() {
		when !#config(WN_RELOAD, false) {wn_sparkle_check()}
	}

	@(private)
	macos_update_auto :: proc() -> bool {
		when !#config(WN_RELOAD, false) {return wn_sparkle_auto()} else {return false}
	}

	@(private)
	macos_update_set_auto :: proc(enabled: bool) {
		when !#config(WN_RELOAD, false) {wn_sparkle_set_auto(enabled)}
	}

	@(private)
	macos_update_tick :: proc() {
		when !#config(WN_RELOAD, false) {
			if wn_sparkle_take_quit() {rl.RequestQuit()}
		}
	}

	// Sparkle 2 relaunches without arguments. Consume the one-shot resolved
	// data root before choosing the default; never replay a consumed deep link.
	@(private)
	macos_update_relaunch_home :: proc() -> string {
		when !#config(WN_RELOAD, false) {
			home := wn_sparkle_relaunch_home()
			if home == nil {return ""}
			defer libc.free(rawptr(home))
			return strings.clone(string(home))
		} else {return ""}
	}

	@(private)
	macos_update_status :: proc() -> string {
		when !#config(WN_RELOAD, false) {
			status := string(wn_sparkle_status())
			switch status {
			case "The bundled Sparkle updater could not be loaded.":
				return N_("Couldn't load the updater. Please try again.")
			case "The bundled Sparkle updater is misconfigured.":
				return N_("Couldn't start the updater. Please try again.")
			}
			// Mark native bridge fallbacks for gettext; NSError descriptions
			// are already localized by AppKit/Sparkle and pass through unchanged.
			messages := [?]string {
				N_("Automatic updates require the installed macOS app bundle."),
				N_(
					"Updates are disabled while a SOCKS5 proxy is configured. Sparkle cannot safely use the app's explicit proxy. Disable the proxy and restart to update, or install an authenticated release manually.",
				),
			}
			for message in messages {
				if status == message {return message}
			}
			return status
		} else {return N_("Automatic updates are disabled in development builds.")}
	}
}
