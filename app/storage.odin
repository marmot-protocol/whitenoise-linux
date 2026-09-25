// The Storage settings section: the on-disk media cache (size readout
// + clear), the data-dir readout, and the backup create/import flow.
//
// Encryption at rest: cached attachment bytes are sealed with the
// vault's blob subkey (vault.odin), so nothing decrypted touches the
// disk in the clear. An entry sealed under a previous password reads as
// a miss and is downloaded again.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// ── Media cache ─────────────────────────────────────────────────────

media_cache_dir :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/media-cache", data_home, allocator = allocator)
}

// Blob hashes come off the wire, so a key that isn't a plain sha256
// hex string never becomes a path.
@(private = "file")
cache_key_ok :: proc(sha: string) -> bool {
	if len(sha) != 64 {
		return false
	}
	for c in sha {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

@(private = "file")
cache_path :: proc(sha: string) -> string {
	return fmt.tprintf("%s/%s.bin", media_cache_dir(), sha)
}

// Attachment bytes for a timeline media reference: the disk cache
// first, marmot's download+decrypt otherwise. The returned slice is
// the caller's to keep or delete.
media_load :: proc(
	client: ^marmot.Client,
	account, group: cstring,
	reference: ^marmot.Media_Attachment_Reference,
) -> (
	[]u8,
	bool,
) {
	timing_start := time.tick_now()
	defer local_timing_end(.media_load, timing_start)
	sha := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : ""
	cacheable := cache_key_ok(sha)
	if cacheable {
		// A blob sealed under a previous vault password fails its tag and
		// reads as a miss, which downloads and re-seals it.
		if sealed, read_err := os.read_entire_file(cache_path(sha), context.temp_allocator);
		   read_err == nil {
			if data, opened := vault_open_blob(sealed); opened {
				local_timing_end(.media_cache_read, timing_start)
				return data, true
			}
		}
	}

	result: ^marmot.Media_Download_Result
	if marmot.download_media(client, account, group, reference, &result) != .OK {
		return nil, false
	}
	defer marmot.media_download_result_free(result)

	bytes := make([]u8, result.plaintext_len)
	copy(bytes, result.plaintext[:result.plaintext_len])
	if cacheable {
		if sealed, ok := vault_seal_blob(bytes, context.temp_allocator); ok {
			os.make_directory(media_cache_dir())
			_ = os.write_entire_file(cache_path(sha), sealed, {.Read_User, .Write_User})
		}
	}
	return bytes, true
}

// Sum the cache dir; best-effort, a missing dir reads as 0 B.
cache_scan :: proc(ui: ^Ui_State) {
	ui.cache_scanned = true
	ui.cache_bytes = 0

	files, read_err := os.read_directory_by_path(media_cache_dir(), -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	for file in files {
		ui.cache_bytes += file.size
	}
}

cache_clear :: proc(ui: ^Ui_State) {
	os.remove_all(media_cache_dir())
	cache_scan(ui)
	ui.client_status = tr("Media cache cleared.")
}

// ── Backup flow ─────────────────────────────────────────────────────

Backup_Mode :: enum {
	None,
	Create, // password box, then the save dialog
	Import, // file already read into ui.backup_blob, password box next
}

// Set while a sealed backup is on its way to the save dialog, so the
// receipt only lands once the bytes are actually written.
backup_saving: bool

// The mode the modal renders while it animates out, after the live
// state has gone back to .None.
backup_shown: Backup_Mode

backup_close :: proc(ui: ^Ui_State) {
	ui.backup_mode = .None
	clear(&ui.backup_pw)
	delete(ui.backup_blob)
	ui.backup_blob = nil
	ui.focus = .Compose
}

// Seal the manifest and hand it to the save dialog.
backup_create :: proc(ui: ^Ui_State) {
	plain, packed := backup_pack()
	if !packed {
		ui.client_status = tr("Couldn't create the backup. Please try again.")
		return
	}
	sealed := backup_seal(plain, string(ui.backup_pw[:]))
	defer delete(sealed)

	start_blob_save(BACKUP_FILE_NAME, sealed)
	backup_saving = true // after the call: start_blob_save clears it
	backup_close(ui)
}

// The save dialog wrote the archive: stamp the receipt.
backup_saved :: proc(ui: ^Ui_State) {
	backup_saving = false
	ui.prefs.last_backup = time.time_to_unix(time.now())
	save_settings(ui)
	ui.client_status = tr("Backup created.")
}

// A picked file becomes the import source; the password comes next.
backup_stage :: proc(ui: ^Ui_State, path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		ui.client_status = tr("Couldn't read the backup file. Please try again.")
		return
	}
	delete(ui.backup_blob)
	ui.backup_blob = data
	ui.backup_mode = .Import
	clear(&ui.backup_pw)
	ui.focus = .BackupPw
}

backup_import :: proc(ui: ^Ui_State) {
	plain, opened := backup_open(ui.backup_blob, string(ui.backup_pw[:]))
	if !opened {
		ui.client_status = tr("Couldn't open the backup. Double-check the password and try again.")
		clear(&ui.backup_pw)
		return
	}
	defer delete(plain)

	written, restored := backup_restore(plain)
	if !restored {
		ui.client_status = tr("Couldn't read the backup. Please try again.")
		return
	}
	backup_close(ui)

	load_settings(ui)
	apply_theme(ui.theme, ui.accent)
	set_locale(ui.prefs.locale)
	custom_emoji_scan()
	ui.client_status = fmt.aprintf(tr("Backup imported: %d files restored."), written)
}

// ── Page ────────────────────────────────────────────────────────────

settings_storage :: proc(ui: ^Ui_State) {
	if !ui.cache_scanned {
		cache_scan(ui)
	}

	if clay.UI(clay.ID("StorageCacheGroup"))(settings_box()) {
		settings_group(N_("Media cache"))
		if clay.UI(clay.ID("RowCache"))(settings_row(true)) {
			row_labels(
				"Cached attachments",
				"Images and files kept on this device so they don't download twice, sealed with your vault key.",
			)
			if clay.UI(clay.ID("CacheActions"))(
			{layout = {childGap = 6, childAlignment = {y = .Center}}},
			) {
				clay.Text(
					human_size(ui.cache_bytes),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
				settings_button(
					"CacheClear",
					ui.keys_confirm == "CacheClear" ? tr("Confirm clear") : tr("Clear cache"),
					DANGER,
				)
			}
		}
	}

	if clay.UI(clay.ID("StorageBackupsGroup"))(settings_box()) {
		settings_group(N_("Keys & backups"))
		if clay.UI(clay.ID("RowLocation"))(settings_row(true)) {
			row_labels("Location", data_home)
			if clay.UI(clay.ID("LocationActions"))({layout = {childGap = 6}}) {
				settings_button("LocCopy", "Copy")
				settings_button("LocOpen", "Open folder")
			}
		}
		if clay.UI(clay.ID("RowBackup"))(settings_row()) {
			row_labels(
				"Back up everything",
				"Pack your settings, drafts, custom emoji, and themes into one encrypted file.",
			)
			settings_button("BackupBtn", "Create backup...")
		}
		if clay.UI(clay.ID("RowImport"))(settings_row()) {
			row_labels(
				"Import a backup",
				"Replaces the settings, drafts, custom emoji, and themes on this device.",
			)
			settings_button(
				"ImportBtn",
				ui.keys_confirm == "ImportBtn" ? tr("Confirm import") : tr("Import..."),
				DANGER,
			)
		}
		if clay.UI(clay.ID("RowLastBackup"))(settings_row()) {
			row_labels("Last backup", last_backup_line(ui))
		}
		clay.Text(
			tr(
				"Backups hold what this device stores locally. Your keys and message history live in marmot's own store and are not included.",
			),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
	}
}

@(private = "file")
last_backup_line :: proc(ui: ^Ui_State) -> string {
	if ui.prefs.last_backup == 0 {
		return tr("No backup made from this device yet.")
	}
	stamp := time.unix(i64(local_seconds(u64(ui.prefs.last_backup))), 0)
	year, month, day := time.date(stamp)
	hour, minute, _ := time.clock(stamp)
	return fmt.tprintf("%04d-%02d-%02d · %02d:%02d", year, int(month), day, hour, minute)
}

// ── Interactions ────────────────────────────────────────────────────

handle_storage :: proc(ui: ^Ui_State) {
	if clicked("LocCopy") {
		copy_text(ui, data_home, "Path copied")
		return
	}
	if clicked("LocOpen") {
		spawn_cmd(fmt.tprintf("xdg-open %q", data_home))
		return
	}
	if clicked("CacheClear") {
		if armed(ui, "CacheClear") {
			cache_clear(ui)
		}
		return
	}
	if clicked("BackupBtn") {
		ui.backup_mode = .Create
		clear(&ui.backup_pw)
		ui.focus = .BackupPw
		return
	}
	if clicked("ImportBtn") {
		if armed(ui, "ImportBtn") {
			ui.picking_backup = true
			rl.OpenFileDialog(false)
		}
		return
	}
	ui.keys_confirm = "" // a click anywhere else disarms
}

// The modal owns input while open, on the settings page and on the
// login screen alike.
handle_backup :: proc(ui: ^Ui_State) {
	edit_text(ui, &ui.backup_pw)

	if rl.IsKeyPressed(.ESCAPE) || clicked("BackupClose") || clicked("BackupCancel") {
		backup_close(ui)
		return
	}
	if !clicked("BackupGo") && !rl.IsKeyPressed(.ENTER) {
		if field_mouse(ui, &ui.backup_pw, "BackupPwBox", 14) {
			ui.focus = .BackupPw
		}
		return
	}
	if len(ui.backup_pw) == 0 {
		return
	}
	if ui.backup_mode == .Create {
		backup_create(ui)
	} else {
		backup_import(ui)
	}
}

// ── Modal ───────────────────────────────────────────────────────────

backup_modal :: proc(ui: ^Ui_State) {
	if ui.backup_mode != .None {
		backup_shown = ui.backup_mode
	}
	creating := backup_shown == .Create
	if clay.UI(clay.ID("BackupModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("BackupModal"), 440))},
			padding = clay.PaddingAll(18),
			childGap = 10,
		},
		floating = {
			attachTo = .Root,
			zIndex = 12,
			offset = {0, rise(clay.ID("BackupModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("BackupHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(
				creating ? tr("Create backup") : tr("Import backup"),
				{fontId = FONT_TITLE, fontSize = 17, textColor = TEXT},
			)
			if clay.UI(clay.ID("BackupHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("BackupClose"))(
			{
				layout = {padding = clay.PaddingAll(6)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		blurb :=
			creating ? tr("Pick a password to encrypt the backup with. Without it the file cannot be opened again.") : tr("Enter the password this backup was created with. The settings, drafts, custom emoji, and themes on this device will be replaced.")
		clay.Text(blurb, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})

		eyebrow("PASSWORD")
		if clay.UI(clay.ID("BackupPwBox"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(38)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(9),
			border = {color = ui.focus == .BackupPw ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			if len(ui.backup_pw) == 0 {
				clay.Text(
					tr("Your password"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
				)
			} else {
				clay.Text(
					strings.repeat("*", min(len(ui.backup_pw), 48), context.temp_allocator),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
				)
			}
			if ui.focus == .BackupPw {
				caret(15)
			}
		}

		if clay.UI(clay.ID("BackupBtns"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 8}}},
		) {
			if clay.UI(clay.ID("BackupCancel"))(
			{
				layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text("Cancel", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("BackupBtnsGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("BackupGo"))(
			{
				layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}},
				backgroundColor = creating ? ACCENT : DANGER,
				cornerRadius = rr(9),
			},
			) {
				clay.Text(
					creating ? tr("Create backup") : tr("Import backup"),
					{fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT},
				)
			}
		}
	}
}
