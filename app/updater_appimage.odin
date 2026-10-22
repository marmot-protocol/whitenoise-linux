#+build linux
package main

import "core:strings"

when ODIN_OS == .Linux {
	@(private)
	Update_Mode :: enum {
		Manual,
		Automatic,
	}

	foreign import wn_appimage {WN_BUILD_DIR + "/libwnappimage.a", "system:pthread"}
	@(private, default_calling_convention = "c")
	foreign wn_appimage {
		wn_appimage_start :: proc(helper, home, version, feed: cstring, automatic: i32) -> i32 ---
		wn_appimage_stop :: proc() ---
		wn_appimage_phase :: proc() -> i32 ---
		wn_appimage_progress :: proc() -> i32 ---
		wn_appimage_version :: proc() -> cstring ---
		wn_appimage_status :: proc() -> i32 ---
		wn_appimage_check :: proc() ---
		wn_appimage_mode :: proc(automatic: i32) ---
		wn_appimage_apply :: proc() -> i32 ---
		wn_appimage_prepare_exit :: proc() -> i32 ---
	}

	@(private)
	appimage_update_start :: proc(test_feed: string, mode: Update_Mode) -> bool {
		started := wn_appimage_start(
			strings.clone_to_cstring(helper_path("wn-appimage-update"), context.temp_allocator),
			strings.clone_to_cstring(data_home, context.temp_allocator),
			strings.clone_to_cstring(APP_VERSION, context.temp_allocator),
			strings.clone_to_cstring(test_feed, context.temp_allocator),
			mode == .Automatic ? 1 : 0,
		)
		return started != 0
	}

	@(private)
	appimage_update_stop :: proc() {wn_appimage_stop()}
	@(private)
	appimage_update_phase :: proc() -> Update_Phase {return Update_Phase(wn_appimage_phase())}
	@(private)
	appimage_update_progress :: proc() -> i32 {return wn_appimage_progress()}
	@(private)
	appimage_update_version :: proc() -> string {return string(wn_appimage_version())}
	@(private)
	appimage_update_status :: proc() -> string {
		switch wn_appimage_status() {
		case 1:
			return N_(
				"Automatic AppImage updates are unavailable with SOCKS5 enabled. Update the AppImage manually.",
			)
		case 2:
			return N_(
				"The AppImage folder is not writable. Move it to a writable folder to enable updates.",
			)
		case 3:
			return N_("Couldn't start the AppImage updater. Please try again.")
		case 4:
			return N_("Couldn't verify the update. Please try again.")
		case 5:
			return N_(
				"The AppImage folder is shared or has unsafe permissions. Move it to a private folder to enable updates.",
			)
		}
		return ""
	}
	@(private)
	appimage_update_check :: proc() {wn_appimage_check()}
	@(private)
	appimage_update_set_mode :: proc(mode: Update_Mode) {wn_appimage_mode(
			mode == .Automatic ? 1 : 0,
		)}
	@(private)
	appimage_update_apply :: proc() -> bool {return wn_appimage_apply() != 0}
	@(private)
	appimage_update_prepare_exit :: proc() -> bool {return wn_appimage_prepare_exit() != 0}
}
