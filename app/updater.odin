// Packaged updates: Velopack on Windows, AppImageUpdate on Linux,
// and Sparkle's native controller on macOS.
//
// Setup.exe and the portable zip both install Update.exe beside the app.
// A background worker asks GitHub releases for a newer build, downloads
// it, and marks it ready. The user restarts from the status bar banner,
// or the next launch applies it (vpkc_app_run's auto-apply).
//
//   UI thread                 update worker               Update.exe
//   ─────────                 ─────────────               ──────────
//   update_start ──spawn──▶   check ─▶ download
//                             phase = .Ready
//   banner "Restart now" ──▶  (idle)
//   wait_exit_then_apply ─────────────────────────────▶  waits for exit,
//   push QUIT, normal shutdown                            swaps, relaunches
//
// Other installations leave the phase at .Off and remain system-managed.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private = "file")
UPDATE_REPO :: "https://github.com/marmot-protocol/whitenoise-linux"
@(private = "file")
UPDATE_INTERVAL :: 6 * time.Hour

Update_Phase :: enum u8 {
	Off, // development or system-managed installation: no UI
	Idle, // last check found nothing newer
	Checking,
	Downloading,
	Ready, // downloaded; applies on restart
	Failed,
}

// Worker-owned. The UI thread reads `phase` atomically and `version` only
// after seeing .Ready (the worker writes it first, then stores the phase).
@(private = "file")
Updater :: struct {
	phase:       Update_Phase,
	version:     [64]u8,
	version_len: int,
	dismissed:   bool, // UI thread only: "Later" hides the banner
	wake:        sync.Sema, // "Check now" and shutdown
	stop:        bool,
	worker:      ^thread.Thread,
	manager:     rawptr,
	source:      rawptr,
	info:        rawptr, // ^Vpk_Update_Info on Windows
}

@(private = "file")
updater: Updater

when ODIN_OS == .Windows {
	foreign import velopack "system:velopack_libc_win_x64_msvc.dll.lib"

	@(private = "file")
	Vpk_Asset :: struct {
		package_id, version, type, file_name, sha1, sha256: cstring,
		size:                                               u64,
		notes_markdown, notes_html:                         cstring,
	}

	@(private = "file")
	Vpk_Update_Info :: struct {
		target_full_release: ^Vpk_Asset,
		base_release:        ^Vpk_Asset,
		deltas_to_target:    [^]^Vpk_Asset,
		deltas_count:        uint,
		is_downgrade:        bool,
	}

	@(private = "file")
	VPK_UPDATE_AVAILABLE :: 0
	@(private = "file")
	VPK_NO_UPDATE_AVAILABLE :: 1
	@(private = "file")
	VPK_REMOTE_IS_EMPTY :: 2 // no release on the feed yet: nothing to install

	@(private = "file", default_calling_convention = "c")
	foreign velopack {
		vpkc_app_run :: proc(user_data: rawptr) ---
		vpkc_app_set_auto_apply_on_startup :: proc(auto_apply: bool) ---
		vpkc_new_source_github :: proc(repo_url, access_token: cstring, prerelease: bool) -> rawptr ---
		vpkc_free_source :: proc(source: rawptr) ---
		vpkc_new_source_file :: proc(path: cstring) -> rawptr ---
		vpkc_new_update_manager_with_source :: proc(source, options, locator: rawptr, manager: ^rawptr) -> bool ---
		vpkc_free_update_manager :: proc(manager: rawptr) ---
		vpkc_check_for_updates :: proc(manager: rawptr, update: ^^Vpk_Update_Info) -> i8 ---
		vpkc_download_updates :: proc(manager: rawptr, update: ^Vpk_Update_Info, progress, user_data: rawptr) -> bool ---
		vpkc_free_update_info :: proc(update: ^Vpk_Update_Info) ---
		vpkc_wait_exit_then_apply_updates :: proc(manager: rawptr, asset: ^Vpk_Asset, silent, restart: bool, args: [^]cstring, arg_count: uint) -> bool ---
		vpkc_get_last_error :: proc(buffer: [^]u8, size: uint) -> uint ---
	}

	@(private = "file")
	log_velopack_error :: proc(what: string) {
		buffer: [512]u8
		// n counts the NUL terminator and exceeds the buffer when truncated.
		n := min(int(vpkc_get_last_error(raw_data(buffer[:]), len(buffer))), len(buffer))
		fmt.eprintfln("updater: %s: %s", what, string(buffer[:max(n - 1, 0)]))
	}

	// One check-and-download pass. Returns once there is nothing more to
	// do until the next interval: up to date, ready, or failed.
	@(private = "file")
	update_pass :: proc() {
		sync.atomic_store(&updater.phase, .Checking)
		info: ^Vpk_Update_Info
		switch vpkc_check_for_updates(updater.manager, &info) {
		case VPK_NO_UPDATE_AVAILABLE, VPK_REMOTE_IS_EMPTY:
			sync.atomic_store(&updater.phase, .Idle)
			return
		case VPK_UPDATE_AVAILABLE:
		case:
			log_velopack_error("check")
			sync.atomic_store(&updater.phase, .Failed)
			return
		}
		sync.atomic_store(&updater.phase, .Downloading)
		if !vpkc_download_updates(updater.manager, info, nil, nil) {
			log_velopack_error("download")
			vpkc_free_update_info(info)
			sync.atomic_store(&updater.phase, .Failed)
			return
		}
		version := string(info.target_full_release.version)
		updater.version_len = copy(updater.version[:], version)
		updater.info = info
		sync.atomic_store(&updater.phase, .Ready)
	}

	@(private = "file")
	update_worker :: proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		for !sync.atomic_load(&updater.stop) {
			if sync.atomic_load(&updater.phase) != .Ready {
				update_pass()
			}
			_ = sync.sema_wait_with_timeout(&updater.wake, UPDATE_INTERVAL)
		}
	}
}

// Velopack's install, update, and uninstall hooks run the app with
// special arguments and exit inside this call, so it must run before any
// other startup work (the vault, the instance lock, the window).
update_hooks :: proc() {
	when ODIN_OS == .Windows {
		vpkc_app_set_auto_apply_on_startup(true)
		vpkc_app_run(nil)
	}
}

// Start the background checker. A build that was not installed by
// Velopack (a dev build, an unpacked archive) has no Update.exe; the
// manager refuses it and the phase stays .Off. test_feed is the harness's
// WN_TEST_UPDATE_FEED: a local feed directory, so a full check, download,
// and apply cycle runs without GitHub.
update_start :: proc(test_feed: string) {
	when ODIN_OS == .Windows {
		if test_feed != "" {
			updater.source = vpkc_new_source_file(fmt.ctprintf("%s", test_feed))
		} else {
			updater.source = vpkc_new_source_github(UPDATE_REPO, nil, false)
		}
		if updater.source == nil {
			log_velopack_error("source")
			return
		}
		if !vpkc_new_update_manager_with_source(updater.source, nil, nil, &updater.manager) {
			vpkc_free_source(updater.source)
			updater.source = nil
			return
		}
		updater.phase = .Idle
		updater.worker = thread.create(update_worker)
		thread.start(updater.worker)
	} else when ODIN_OS == .Linux {
		mode: Update_Mode = .Manual
		if g_prefs != nil && g_prefs.auto_updates {mode = .Automatic}
		appimage_update_start(test_feed, mode)
	} else when ODIN_OS == .Darwin {
		macos_update_start()
	}
}

update_stop :: proc() {
	when ODIN_OS == .Windows {
		if updater.worker == nil {
			return
		}
		sync.atomic_store(&updater.stop, true)
		sync.sema_post(&updater.wake)
		thread.join(updater.worker)
		thread.destroy(updater.worker)
		if updater.info != nil {vpkc_free_update_info((^Vpk_Update_Info)(updater.info))}
		vpkc_free_update_manager(updater.manager)
		vpkc_free_source(updater.source)
		updater = {}
	} else when ODIN_OS == .Linux {
		when !#config(WN_RELOAD, false) {appimage_update_prepare_exit()}
		appimage_update_stop()
	} else when ODIN_OS == .Darwin {
		macos_update_stop()
	}
}

update_phase :: proc() -> Update_Phase {
	when ODIN_OS == .Linux {
		return appimage_update_phase()
	} else when ODIN_OS == .Darwin {
		return macos_update_available() || macos_update_status() != "" ? .Idle : .Off
	}
	return sync.atomic_load(&updater.phase)
}

@(private = "file")
update_version :: proc() -> string {
	when ODIN_OS == .Linux {return appimage_update_version()}
	// Velopack spells the revision "-build.N" (see cross-package.sh); show
	// the app's own "YYYY.M.D+N" form, as About does.
	version := string(updater.version[:updater.version_len])
	if i := strings.index(version, "-build."); i >= 0 {
		return fmt.tprintf("%s+%s", version[:i], version[i + len("-build."):])
	}
	return version
}

// Hand the downloaded release to Update.exe, which waits for this process
// to exit, swaps the files, and relaunches. The QUIT runs the normal
// shutdown so the vault and drafts are saved first.
@(private = "file")
update_apply :: proc() {
	when ODIN_OS == .Windows {
		info := (^Vpk_Update_Info)(updater.info)
		if !vpkc_wait_exit_then_apply_updates(
			updater.manager,
			info.target_full_release,
			true,
			true,
			nil,
			0,
		) {
			log_velopack_error("apply")
			sync.atomic_store(&updater.phase, .Failed)
			return
		}
	} else when ODIN_OS == .Linux {
		if !appimage_update_apply() {return}
	} else {
		return
	}
	rl.RequestQuit()
}

// Status bar strip shown once a downloaded update is waiting.
update_bar :: proc() {
	phase := update_phase()
	busy := false
	when ODIN_OS == .Linux {busy = phase == .Checking || phase == .Downloading}
	if !busy && (phase != .Ready || updater.dismissed) {
		return
	}
	if clay.UI(clay.ID("UpdateBar"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(6),
			childGap = 12,
			childAlignment = {y = .Center},
		},
		backgroundColor = STATUS_BAR,
	},
	) {
		if busy {
			clay.Text(
				update_status(phase),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			update_feedback("UpdateBarProgress", phase)
		} else {
			micro_button("UpdateRestart", tr("Restart now"), ACCENT)
			micro_button("UpdateLater", tr("Later"))
			clay.Text(
				fmt.tprintf(tr("White Noise %s is ready to install."), update_version()),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
		}
	}
}

@(private = "file")
update_status :: proc(phase: Update_Phase) -> string {
	when ODIN_OS == .Linux {
		if phase == .Failed {return tr(appimage_update_status())}
		if phase == .Idle {return tr("Check for a newer version.")}
	}
	switch phase {
	case .Off, .Idle:
		return tr("You have the latest version.")
	case .Checking:
		return tr("Checking for updates.")
	case .Downloading:
		return tr("Downloading an update.")
	case .Ready:
		return fmt.tprintf(tr("White Noise %s is ready to install."), update_version())
	case .Failed:
		return tr("Couldn't check for updates. Please try again.")
	}
	return ""
}

@(private = "file")
update_feedback :: proc(id: string, phase: Update_Phase) {
	progress: i32 = -1
	when ODIN_OS == .Linux {
		if phase == .Downloading {progress = appimage_update_progress()}
	}
	if progress < 0 {
		busy_bar(id)
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		return
	}
	if clay.UI(clay.ID(id))(
	{
		layout = {sizing = {clay.SizingFixed(180), clay.SizingFixed(4)}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(2),
	},
	) {
		if clay.UI(clay.ID(id, 1))(
		{
			layout = {
				sizing = {
					clay.SizingPercent(f32(clamp(progress, 0, 100)) / 100),
					clay.SizingFixed(4),
				},
			},
			backgroundColor = ACCENT,
			cornerRadius = rr(2),
		},
		) {}
	}
	clay.Text(
		fmt.tprintf("%d%%", progress),
		{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
	)
}

// Settings → About row: current state plus a manual check.
update_settings_row :: proc() {
	phase := update_phase()
	if phase == .Off {
		return
	}
	if clay.UI(clay.ID("AboutUpdateGroup"))(settings_box()) {
		settings_group(tr("Updates"))
		when ODIN_OS == .Darwin {
			if status := macos_update_status(); status != "" {
				clay.Text(tr(status), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
			}
			if macos_update_available() {
				settings_check(
					"TgUpdates",
					macos_update_auto(),
					tr("Automatically check for updates"),
					tr("Sparkle manages update checks and downloads."),
				)
				if macos_update_can_check() {settings_button("UpdateCheck", tr("Check now"))}
			}
			return
		} else when ODIN_OS == .Linux {
			if g_prefs != nil {
				settings_check(
					"TgUpdates",
					g_prefs.auto_updates,
					tr("Automatically download updates"),
					tr(
						"Check every six hours and download signed updates. Restart when you choose.",
					),
				)
			}
		}
		if clay.UI(clay.ID("AboutUpdateRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 12,
				childAlignment = {y = .Center},
			},
		},
		) {
			clay.Text(update_status(phase), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
			if clay.UI(clay.ID("AboutUpdateGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if phase == .Ready {
				settings_button("UpdateRestart", tr("Restart now"), ACCENT)
			} else if phase == .Idle || phase == .Failed {
				settings_button("UpdateCheck", tr("Check now"))
			}
		}
		if phase == .Checking ||
		   phase == .Downloading {update_feedback("UpdateSettingsProgress", phase)}
	}
}

update_handle :: proc() {
	if clicked("UpdateRestart") {
		update_apply()
	}
	if clicked("UpdateLater") {
		updater.dismissed = true
	}
	if clicked("UpdateCheck") {
		updater.dismissed = false
		when ODIN_OS == .Linux {
			appimage_update_check()
		} else when ODIN_OS == .Darwin {
			if macos_update_can_check() {macos_update_check()}
		} else when ODIN_OS == .Windows {
			sync.atomic_store(&updater.phase, .Checking)
			sync.sema_post(&updater.wake)
		}
	}
}
