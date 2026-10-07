// Settings Control Panel and compact, immediately applied property pages.
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/windows"

_ :: base64
_ :: windows

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

Settings_Section :: enum {
	Home,
	General,
	Folders,
	Speech,
	Network,
	Keys,
	Appearance,
	Notifications,
	Storage,
	Advanced,
	About,
	Debug, // dev-mode only
	KP, // dev-mode only
}

// A category opens on its menu of tasks and pages; a task or page opens its
// property sheet. Utility sections (About, Debug, KP) have only the sheet.
Settings_Level :: enum {
	Menu,
	Sheet,
}

SETTINGS_SECTIONS := [Settings_Section]struct {
	label: string,
	icon:  string,
} {
	.Home          = {N_("Settings"), ICON_SETTINGS},
	.General       = {N_("General"), ICON_SETTINGS},
	.Folders       = {N_("Folders"), ICON_FOLDER},
	.Speech        = {N_("Speech"), ICON_MIC},
	.Network       = {N_("Network & relays"), ICON_GLOBE},
	.Keys          = {N_("Keys & identity"), ICON_KEY},
	.Appearance    = {N_("Appearance"), ICON_BRUSH},
	.Notifications = {N_("Notifications"), ICON_BELL},
	.Storage       = {N_("Storage"), ICON_ARCHIVE},
	.Advanced      = {N_("Advanced"), ICON_CODE},
	.About         = {N_("About"), ICON_INFO},
	.Debug         = {N_("Debug"), ICON_BUG},
	.KP            = {N_("KP inspector"), ICON_KEY},
}

STUB_STATUS :: "Not available in the odin port yet."

DATE_FORMATS := []string{"Jun 12", "12 Jun", "2026-06-12"}
LOCALES := [][2]string {
	{"en", "English"},
	{"it", "Italiano"},
	{"de", "Deutsch"},
	{"ja", "日本語"},
}

// ── Widgets ─────────────────────────────────────────────────────────

// Full-width settings row plate.
srow :: proc() -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(12),
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
	}
}

// Deliberately separate from srow: profile and other surfaces retain their cards.
settings_row :: proc(stacked: bool = false) -> clay.ElementDeclaration {
	stacked := stacked && (g_ui == nil || settings_body_width(g_ui) < 580)
	return {
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = stacked ? .TopToBottom : .LeftToRight,
			padding = {top = 4, bottom = 4},
			childGap = 12,
			childAlignment = {y = .Center},
		},
	}
}

settings_content_width :: proc(ui: ^Ui_State) -> f32 {
	menu := ui.settings_section == .Home || settings_on_menu(ui)
	return min(
		menu ? 900 : (ui.settings_section == .General ? 560 : 740),
		max(120, settings_main_w(ui) - (settings_main_w(ui) < 560 ? 24 : 48)),
	)
}

@(private)
settings_body_width :: proc(ui: ^Ui_State) -> f32 {
	return max(120, settings_content_width(ui) - (settings_main_w(ui) < 560 ? 16 : 32))
}

@(private)
SETTINGS_PANE_W :: 220

// Beside the page when both fit; narrower windows stack the task boxes.
@(private)
settings_wide :: proc(ui: ^Ui_State) -> bool {
	return page_w(ui) >= 760
}

@(private)
settings_main_w :: proc(ui: ^Ui_State) -> f32 {
	return page_w(ui) - (settings_wide(ui) ? SETTINGS_PANE_W : 0)
}

@(private)
settings_box :: proc() -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {
				width = g_ui == nil ? clay.SizingGrow() : clay.SizingFixed(settings_body_width(g_ui)),
			},
			layoutDirection = .TopToBottom,
			padding = {left = 12, right = 12, top = 18, bottom = 10},
			childGap = 8,
		},
		backgroundColor = PANEL,
		border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
		cornerRadius = rr(2),
	}
}

settings_group :: proc(label: string) {
	width := g_ui == nil ? f32(600) : settings_body_width(g_ui) - 24
	long := rl.MeasureTextLine(FONT_TITLE, 12, label, 0).x > width - 8
	if clay.UI(clay.ID_LOCAL(label))(
	{
		layout = {
			sizing = {width = long ? clay.SizingFixed(width) : clay.SizingFit()},
			padding = {left = 4, right = 4},
		},
		floating = long ? clay.FloatingElementConfig{} : clay.FloatingElementConfig{attachTo = .Parent, clipTo = .AttachedParent, offset = {8, -8}, pointerCaptureMode = .Passthrough},
		backgroundColor = PANEL,
	},
	) {
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
	}
}

// The switches settings_check drew this frame, in layout order: the Tab
// order for the keyboard and the hit list for clicks. A page holds at
// most a handful, so a fixed array covers every page.
@(private)
settings_check_ids: [32]string
@(private)
settings_check_count: int

@(private)
settings_check :: proc(id_str: string, checked: bool, title: string, sub: string) {
	if settings_check_count < len(settings_check_ids) {
		settings_check_ids[settings_check_count] = id_str
		settings_check_count += 1
	}
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 9,
			padding = {left = 4, right = 4, top = 3, bottom = 3}, // room for kb_ring
		},
		backgroundColor = hovered() ? HOVER : {},
		border = kb_focus == id_str ? kb_ring(ACCENT) : {},
		cornerRadius = rr(2),
	},
	) {
		if clay.UI(clay.ID_LOCAL("Check"))(
		{
			layout = {
				sizing = {clay.SizingFixed(16), clay.SizingFixed(16)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = CARD,
			border = {color = hovered() ? ACCENT : FIELD_BORDER, width = {1, 1, 1, 1, 0}},
			cornerRadius = rr(2),
		},
		) {
			if checked {clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})}
		}
		row_labels(title, sub)
	}
}

@(private)
settings_radio_mark :: proc(selected: bool) {
	if clay.UI(clay.ID_LOCAL("Radio"))(
	{
		layout = {
			sizing = {clay.SizingFixed(14), clay.SizingFixed(14)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = CARD,
		border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
		cornerRadius = clay.CornerRadiusAll(7),
	},
	) {
		if selected do if clay.UI(clay.ID_LOCAL("Selected"))({layout = {sizing = {clay.SizingFixed(6), clay.SizingFixed(6)}}, backgroundColor = ACCENT, cornerRadius = clay.CornerRadiusAll(3)}) {}
	}
}

@(private)
settings_option :: proc(id_str: string, index: u32, label: string, selected: bool) {
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {
			padding = {left = 10, right = 10, top = 7, bottom = 7},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? SELECTED : (hovered() ? HOVER : CARD),
		border = {color = selected ? ACCENT : FIELD_BORDER, width = {1, 1, 1, 1, 0}},
		cornerRadius = rr(6),
	},
	) {
		clay.Text(label, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
	}
}

@(private)
settings_button :: proc(id_str: string, label: string, color: clay.Color = {}) {
	down := press_down(clay.ID(id_str))
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingFit({min = 56}), height = clay.SizingFixed(30)},
			padding = {left = 12, right = 12, top = down},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hovered() ? HOVER : CARD,
		border = {color = color.a != 0 ? color : FIELD_BORDER, width = {1, 1, 1, 1, 0}},
		cornerRadius = rr(7),
	},
	) {
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 12, textColor = color.a != 0 ? color : TEXT},
		)
	}
}

// One tab of a property sheet, which the category menu also offers as an icon.
@(private)
Settings_Page :: struct {
	label: string,
	art:   Settings_Art,
}

SETTINGS_GENERAL_TABS := []Settings_Page {
	{N_("Startup"), .Startup},
	{N_("Language"), .Language},
	{N_("Messaging"), .Messaging},
}
SETTINGS_APPEARANCE_TABS := []Settings_Page {
	{N_("Theme"), .Appearance},
	{N_("Interface"), .Interface},
	{N_("Avatars"), .Avatars},
}
SETTINGS_SPEECH_TABS := []Settings_Page {
	{N_("Dictation"), .Speech},
	{N_("Read aloud"), .Read_Aloud},
}
SETTINGS_NETWORK_TABS := []Settings_Page {
	{N_("Relays"), .Network},
	{N_("Linked events"), .Linked_Events},
}
SETTINGS_KEYS_TABS := []Settings_Page {
	{N_("Identity"), .Keys},
	{N_("Key packages"), .Key_Packages},
	{N_("Security"), .Security},
}
SETTINGS_ADVANCED_TABS := []Settings_Page {
	{N_("Privacy"), .Privacy},
	{N_("Audit logs"), .Audit_Logs},
	{N_("Developer"), .Advanced},
}

settings_tabs :: proc(section: Settings_Section) -> []Settings_Page {
	#partial switch section {
	case .General:
		return SETTINGS_GENERAL_TABS
	case .Appearance:
		return SETTINGS_APPEARANCE_TABS
	case .Speech:
		return SETTINGS_SPEECH_TABS
	case .Network:
		return SETTINGS_NETWORK_TABS
	case .Keys:
		return SETTINGS_KEYS_TABS
	case .Advanced:
		return SETTINGS_ADVANCED_TABS
	case:
		return nil
	}
}

settings_target_tab :: proc(section: Settings_Section, anchor: string) -> int {
	#partial switch section {
	case .General:
		switch anchor {
		case "RowLang", "LangChange", "RowTimeFmt", "TimeFmt", "RowDateFmt", "DateFmt":
			return 1
		case "RowQuick",
		     "RowQuickReset",
		     "QuickAdd",
		     "QuickReset",
		     "RowEmoji",
		     "EmojiAdd",
		     "EmojiNameBox",
		     "RowGm",
		     "GmBox",
		     "RowShortcuts",
		     "ShortcutsView":
			return 2
		}
	case .Appearance:
		switch anchor {
		case "RowZoom",
		     "ZoomMinus",
		     "ZoomPlus",
		     "ZoomReset",
		     "RowBodyFont",
		     "BodyFontChip",
		     "RowEmojiSet",
		     "EmojiSetChip",
		     "RowScroll",
		     "ScrollChip",
		     "RowMotion",
		     "TgMotion",
		     "RowCentered",
		     "TgCentered",
		     "RowMessageLines",
		     "MessageLinesMinus",
		     "MessageLinesPlus",
		     "MessageLinesReset":
			return 1
		case "RowAvatarShape", "AvatarShapeChip", "RowCropShape", "CropShapeChip":
			return 2
		}
	case .Speech:
		switch anchor {
		case "RowTts", "TgTts", "TtsModel", "TtsVoice":
			return 1
		}
	case .Network:
		switch anchor {
		case "AddFetchRow",
		     "FetchBox",
		     "AddFetchBtn",
		     "NetworkFetchGroup",
		     "ClientBox",
		     "NetworkClientGroup":
			return 1
		}
	case .Keys:
		switch anchor {
		case "KpStatus", "KpPublish", "KpRefresh", "RowRotate", "RotateBtn":
			return 1
		case "RowVaultPw", "VaultPwBtn", "RowReveal", "RevealNsecBtn", "RowExport", "ExportBtn":
			return 2
		}
	case .Advanced:
		switch anchor {
		case "RowAudit", "TgAudit", "AuditRefresh", "AdvancedAuditGroup":
			return 1
		case "RowDevMode", "TgDevMode", "AdvancedDeveloperGroup":
			return 2
		}
	case:
	}
	return 0
}

settings_tab_strip :: proc(ui: ^Ui_State) {
	tabs := settings_tabs(ui.settings_section)
	if len(tabs) == 0 {return}
	if clay.UI(clay.ID("SettingsTabs"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 2,
			childAlignment = {y = .Bottom},
		},
	},
	) {
		for page, i in tabs {
			selected := ui.settings_tab == i
			if clay.UI(clay.ID("SettingsTab", u32(i)))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({max = 120}),
						height = clay.SizingFixed(selected ? 32 : 29),
					},
					padding = {left = 8, right = 8},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = selected ? PANEL : (hovered() ? HOVER : ROW_BG),
				cornerRadius = {topLeft = 3 * R_SCALE, topRight = 3 * R_SCALE},
				border = {
					color = FIELD_BORDER,
					width = {
						left = 1,
						right = 1,
						top = selected ? 2 : 1,
						bottom = selected ? 0 : 1,
					},
				},
			},
			) {
				clay.Text(
					tr(page.label),
					{fontId = FONT_TITLE, fontSize = 12, textColor = selected ? ACCENT : TEXT_DIM},
				)
			}
		}
		if clay.UI(clay.ID("SettingsTabEdge"))(
		{
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}},
			backgroundColor = FIELD_BORDER,
		},
		) {}
	}
}

// Left half of a row: title over a dim sublabel, then the implicit
// grow pushes the caller's control to the right edge.
row_labels :: proc(title: string, sub: string, title_color: clay.Color = {}) {
	color := title_color
	if color.a == 0 {
		color = TEXT
	}
	if clay.UI(clay.ID_LOCAL("RowLabels"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 3,
		},
	},
	) {
		clay.Text(title, {fontId = FONT_TITLE, fontSize = 13, textColor = color})
		if len(sub) > 0 {
			clay.Text(sub, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}
	}
}

// On/off pill.
toggle :: proc(id_str: string, on: bool) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(34), height = clay.SizingFixed(18)},
			padding = clay.PaddingAll(2),
			childAlignment = {x = on ? .Right : .Left, y = .Center},
		},
		backgroundColor = on ? ACCENT : ROW_BG,
		cornerRadius = rr(9),
		border = on ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID_LOCAL("Knob"))(
		{
			layout = {sizing = {width = clay.SizingFixed(14), height = clay.SizingFixed(14)}},
			backgroundColor = on ? ON_ACCENT : TEXT_DIM,
			cornerRadius = rr(7),
		},
		) {}
	}
}

// ── Pane dispatch ───────────────────────────────────────────────────

settings_description :: proc(section: Settings_Section) -> string {
	switch section {
	case .Home:
		return ""
	case .General:
		return N_("Make White Noise work your way.")
	case .Folders:
		return N_("Organize your conversations.")
	case .Speech:
		return N_("Dictate and listen on this device.")
	case .Network:
		return N_("Manage connections and published relay lists.")
	case .Keys:
		return N_("Your identity, key packages, and device security.")
	case .Appearance:
		return N_("Choose how your conversations look and feel.")
	case .Notifications:
		return N_("Choose when and how White Noise alerts you.")
	case .Storage:
		return N_("Manage local files and encrypted backups.")
	case .Advanced:
		return N_("Privacy, diagnostics, and developer tools.")
	case .About:
		return N_("White Noise and this session.")
	case .Debug:
		return N_("Inspect application state and events.")
	case .KP:
		return N_("Inspect published MLS key packages.")
	}
	return ""
}

settings_pane :: proc(ui: ^Ui_State) {
	wide := settings_wide(ui)
	if clay.UI(clay.ID("SettingsRoot"))(
	{layout = {sizing = {clay.SizingFixed(page_w(ui)), clay.SizingGrow()}}},
	) {
		if wide {
			if clay.UI(clay.ID("SettingsTaskPane"))(
			{
				layout = {
					sizing = {clay.SizingFixed(SETTINGS_PANE_W), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(12),
					childGap = 14,
				},
				backgroundColor = STATUS_BAR,
				border = {color = DIVIDER, width = {right = 1}},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				settings_nav_box(ui)
				settings_related_boxes(ui)
			}
			scrollbar(clay.ID("SettingsTaskPane"))
		}
		if clay.UI(clay.ID("SettingsMain"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
			},
		},
		) {
			if ui.settings_section != .Home {settings_banner(ui)}
			if clay.UI(clay.ID("SettingsPage"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(settings_main_w(ui) < 560 ? 12 : 24),
					childAlignment = {x = .Center},
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				if clay.UI(clay.ID("SettingsContent"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(settings_content_width(ui))},
						layoutDirection = .TopToBottom,
						childGap = 0,
					},
				},
				) {
					if !wide {
						if clay.UI(clay.ID("SettingsTaskStack"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								layoutDirection = .TopToBottom,
								padding = {bottom = 18},
								childGap = 12,
							},
						},
						) {
							settings_nav_box(ui)
						}
					}
					tabs := settings_tabs(ui.settings_section)
					on_menu := settings_on_menu(ui)
					if ui.settings_section != .Home && !on_menu {
						settings_tab_strip(ui)
					}
					if ui.settings_section == .Home {
						settings_home(ui)
					} else if on_menu {
						settings_category_menu(ui)
					} else if clay.UI(clay.ID("SettingsSheet"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(settings_main_w(ui) < 560 ? 8 : 16),
							childGap = 18,
						},
						backgroundColor = len(tabs) > 0 ? PANEL : {},
						border = len(tabs) > 0 ? clay.BorderElementConfig{color = FIELD_BORDER, width = {left = 1, right = 1, bottom = 1}} : {},
						cornerRadius = {bottomLeft = 3 * R_SCALE, bottomRight = 3 * R_SCALE},
					},
					) {
						#partial switch ui.settings_section {
						case .General:
							settings_general(ui)
						case .Folders:
							settings_folders(ui)
						case .Speech:
							settings_speech(ui)
						case .Network:
							settings_network(ui)
						case .Keys:
							settings_keys(ui)
						case .Appearance:
							settings_appearance(ui)
						case .Notifications:
							settings_notifications(ui)
						case .Storage:
							settings_storage(ui)
						case .Advanced:
							settings_advanced(ui)
						case .About:
							settings_about(ui)
						case .Debug:
							settings_debug(ui)
						case .KP:
							settings_kp(ui)
						}
					}
					// Related links follow the page when the pane can't sit beside it.
					if !wide {
						if clay.UI(clay.ID("SettingsRelatedStack"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								layoutDirection = .TopToBottom,
								padding = {top = 24},
								childGap = 12,
							},
						},
						) {
							settings_related_boxes(ui)
						}
					}
				}
			}
			scrollbar(clay.ID("SettingsPage"))
		}
	}

	if open_now(clay.ID("ThemeEdit"), ui.theme_edit) {
		theme_edit_modal(ui)
	}
	// The destination picker is shared with message forwarding, which
	// mounts it in the chat pane; a theme share is raised from here.
	if open_now(clay.ID("FwdModal"), ui.fwd_open && ui.fwd_kind == .Theme) {
		forward_modal(ui)
	}
	if open_now(clay.ID("LangModal"), ui.lang_open) {
		lang_modal(ui)
	}
	if open_now(clay.ID("ShortModal"), ui.shortcuts_open) {
		shortcuts_modal(ui)
	}
	if open_now(clay.ID("ExportModal"), ui.export_open) {
		export_modal(ui)
	}
	if open_now(clay.ID("BackupModal"), ui.backup_mode != .None) {
		backup_modal(ui)
	}
	if open_now(clay.ID("VaultPwModal"), ui.vault_pw_open) {
		vault_pw_modal(ui)
	}
}

@(private)
settings_folders :: proc(ui: ^Ui_State) {
	box := settings_box()
	if clay.UI(clay.ID("FoldersGroup"))(box) {
		settings_group(tr("Folders"))
		if clay.UI(clay.ID("SettingsFolderActions"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = settings_body_width(ui) < 360 ? .TopToBottom : .LeftToRight,
				childGap = 12,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("FolderDescription"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 4,
				},
			},
			) {
				clay.Text(
					tr(
						"Drag a chat onto a folder to keep it there, or drag a folder to reorder it.",
					),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
				)
				clay.Text(
					tr(
						"A checked box means you placed the chat by hand. Clear it to let folder rules decide.",
					),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
			}
			settings_button("SettingsFolderNew", tr("New folder"), ACCENT)
		}
		folder_board(ui)
	}
}

@(private)
settings_tts_download :: proc(ui: ^Ui_State, model: int) {
	ready := ui.tts.ready[model]
	size := TTS_MODEL_SIZES[model]
	active := int(ui.tts.model) == model
	if model == 0 {
		ready = true
		size = 0
		for bytes, i in TTS_MODEL_SIZES {
			size += bytes
			ready = ready && ui.tts.ready[i]
		}
		active = true
	}
	label := ready ? tr("Downloaded") : tr("Not downloaded")
	fraction := f32(ui.tts.percent) / 100
	if active && ui.tts.status == 'D' {
		if model == 0 {
			bytes := f32(TTS_MODEL_SIZES[ui.tts.model]) * fraction
			for i in 0 ..< int(ui.tts.model) {
				bytes += f32(TTS_MODEL_SIZES[i])
			}
			fraction = bytes / f32(size)
		}
		label = fmt.tprintf(tr("Downloading: %d%%"), int(fraction * 100))
		if ui.tts.percent == 100 {
			label = tr("Verifying download...")
		}
	} else if active && ui.tts.status == 'F' {
		label = tr("Couldn't download speech files. Please try again.")
	}
	if clay.UI(clay.ID_LOCAL("DownloadStatus"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 5,
		},
	},
	) {
		clay.Text(
			fmt.tprintf("%s · %.1f MB", label, f64(size) / 1_000_000),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
		if active && ui.tts.status == 'D' {
			if clay.UI(clay.ID_LOCAL("DownloadTrack"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)}},
				backgroundColor = PLATE,
				cornerRadius = rr(2),
			},
			) {
				if fraction > 0 {
					if clay.UI(clay.ID_LOCAL("DownloadFill"))(
					{
						layout = {
							sizing = {
								width = clay.SizingPercent(fraction),
								height = clay.SizingGrow(),
							},
						},
						backgroundColor = ACCENT,
						cornerRadius = rr(2),
					},
					) {}
				}
			}
		}
	}
}

// ── General ─────────────────────────────────────────────────────────

settings_general :: proc(ui: ^Ui_State) {
	switch ui.settings_tab {
	case 0:
		if clay.UI(clay.ID("StartupGroup"))(settings_box()) {
			settings_group(tr("Startup"))
			when ODIN_OS != .OpenBSD {
				if clay.UI(clay.ID("RowLaunch"))(settings_row()) {
					settings_check("TgLaunch", ui.prefs.launch_at_login, tr("Launch at login"), "")
				}
			}
			if clay.UI(clay.ID("RowTray"))(settings_row()) {
				settings_check(
					"TgTray",
					ui.prefs.start_in_tray,
					tr("Start minimized to tray"),
					tr("Takes effect on the next launch."),
				)
			}
			if clay.UI(clay.ID("RowMinTray"))(settings_row()) {
				settings_check(
					"TgMinTray",
					ui.prefs.minimize_tray,
					tr("Close to tray"),
					tr(
						"Closing the window hides it. The tray icon shows your unread total and brings it back.",
					),
				)
			}
			if clay.UI(clay.ID("RowRestore"))(settings_row()) {
				settings_check(
					"TgRestore",
					ui.prefs.restore_last_chat,
					tr("Restore last selected chat on launch"),
					"",
				)
			}
		}

	case 1:
		if clay.UI(clay.ID("LanguageGroup"))(settings_box()) {
			settings_group(tr("Language"))
			column := settings_row()
			column.layout.layoutDirection = .TopToBottom
			column.layout.childGap = 8
			if clay.UI(clay.ID("RowLang"))(column) {
				row_labels(tr("Interface language"), "")
				settings_button(
					"LangChange",
					fmt.tprintf("%s  ▾", locale_label(ui.prefs.locale)),
				)
			}
			if clay.UI(clay.ID("RowTimeFmt"))(column) {
				row_labels(tr("Time format"), "")
				if clay.UI(clay.ID("TimeFmtCol"))({layout = {childGap = 6}}) {
					settings_option("TimeFmt", 0, "14:30", !ui.prefs.hour12)
					settings_option("TimeFmt", 1, "2:30 PM", ui.prefs.hour12)
				}
			}
			if clay.UI(clay.ID("RowDateFmt"))(column) {
				row_labels(tr("Date format"), "")
				if clay.UI(clay.ID("DateFmtCol"))({layout = {childGap = 6}}) {
					for label, i in DATE_FORMATS {
						settings_option("DateFmt", u32(i), label, ui.prefs.date_format == i)
					}
				}
			}
		}

	case 2:
		if clay.UI(clay.ID("ReactionsGroup"))(settings_box()) {
			settings_group(tr("Quick reactions"))
			row := settings_row()
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("RowQuick"))(row) {
				row_labels(
					tr("One-tap reactions"),
					tr("Shown on the message menu. Tap one to remove it. Up to 16."),
				)
				columns := max(1, int((settings_body_width(ui) - 24) / 32))
				for first := 0; first < len(ui.prefs.quick_reactions); first += columns {
					if clay.UI(clay.ID("QuickChoiceRow", u32(first)))({layout = {childGap = 8}}) {
						for i in first ..< min(first + columns, len(ui.prefs.quick_reactions)) {
							emoji := ui.prefs.quick_reactions[i]
							if clay.UI(clay.ID("QuickChip", u32(i)))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(24),
										height = clay.SizingFixed(24),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = hovered() ? HOVER : {},
								cornerRadius = rr(6),
							},
							) {
								if tex := emoji_tex(emoji); tex != nil {
									if clay.UI(clay.ID("QuickChipImg", u32(i)))(
									{
										layout = {sizing = {width = clay.SizingFixed(16)}},
										aspectRatio = {1},
										image = {imageData = tex},
									},
									) {}
								} else {
									clay.Text(
										emoji,
										{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
									)
								}
							}
						}
					}
				}
				if len(ui.prefs.quick_reactions) < QUICK_MAX do if clay.UI(clay.ID("QuickAdd"))({layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)}) {
					clay.Text("+", {fontId = FONT_BODY, fontSize = 14, textColor = TEXT})
				}
			}
			if clay.UI(clay.ID("RowQuickReset"))(settings_row()) {
				row_labels(tr("Restore the default reactions"), "")
				settings_button("QuickReset", tr("Reset"))
			}
		}

		if clay.UI(clay.ID("CustomEmojiGroup"))(settings_box()) {
			settings_group(tr("Custom emoji"))
			row := settings_row()
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("RowEmoji"))(row) {
				row_labels(tr("Uploaded emoji"), tr("Tap one to remove it."))
				for name, i in custom_emoji_names {
					if clay.UI(clay.ID("EmojiChip", u32(i)))(
					{
						layout = {
							padding = {left = 6, right = 8, top = 3, bottom = 3},
							childGap = 5,
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() ? HOVER : ROW_BG,
						cornerRadius = rr(6),
					},
					) {
						if tex := custom_emoji_texture(name); tex != nil {
							if clay.UI(clay.ID("EmojiChipImg", u32(i)))(
							{
								layout = {sizing = {width = clay.SizingFixed(18)}},
								aspectRatio = {1},
								image = {imageData = tex},
							},
							) {}
						}
						clay.Text(
							fmt.tprintf(":%s:", emoji_code(name)),
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
						)
					}
				}
				if clay.UI(clay.ID("EmojiAdd"))(
				{
					layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text("+", {fontId = FONT_BODY, fontSize = 14, textColor = TEXT})
				}
			}
			if len(ui.emoji_staged) > 0 {
				clay.Text(
					tr("Name the shortcode. Type it in messages as :name:."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
				// Fixed-size input first: this clay build drops a fixed sibling
				// declared after a grow sibling (see PORT.md quirks).
				if clay.UI(clay.ID("RowEmojiName"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 10,
						childAlignment = {y = .Center},
					},
				},
				) {
					settings_input(
						ui,
						"EmojiNameBox",
						&ui.emoji_name,
						"party_parrot",
						ui.focus == .EmojiName,
						min(220, settings_body_width(ui) - 200),
					)
					settings_button("EmojiSave", tr("Save"))
					settings_button("EmojiCancel", tr("Cancel"))
				}
			}
		}

		if clay.UI(clay.ID("GmGroup"))(settings_box()) {
			settings_group(tr("GM button"))
			row := settings_row()
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("RowGm"))(row) {
				row_labels(
					tr("Your GM"),
					tr("What the GM button sends. You can use it once a day in each chat."),
				)
				settings_input(ui, "GmBox", &ui.gm_input, GM_DEFAULT, ui.focus == .Gm)
			}
		}

		if clay.UI(clay.ID("ShortcutsGroup"))(settings_box()) {
			settings_group(tr("Help"))
			if clay.UI(clay.ID("RowShortcuts"))(settings_row()) {
				row_labels(tr("Keyboard shortcuts"), "")
				settings_button("ShortcutsView", tr("View"))
			}
		}
	}
}

locale_label :: proc(code: string) -> string {
	for pair in LOCALES {
		if pair[0] == code {
			return pair[1]
		}
	}
	return "English"
}

// ── Appearance ──────────────────────────────────────────────────────

SCROLL_SPEEDS := []int{100, 150, 200, 300}
SCROLL_SPEED_LABELS := []string{"1x", "1.5x", "2x", "3x"}

BODY_FONT_DELTAS := []int{-2, 0, 2}
BODY_FONT_LABELS := []string{N_("Small"), N_("Default"), N_("Large")}

// Sample conversation rendered with the active theme and actual text-size preference.
// It never replaces the user's theme with a canned palette.
settings_conversation_preview :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("SettingsConversationPreview"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(8),
			childGap = 4,
			childAlignment = {x = ui.prefs.centered_chat ? .Center : .Left},
		},
		backgroundColor = PANEL,
		border = {color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(4),
	},
	) {
		clay.Text(
			tr("Conversation preview"),
			{fontId = FONT_TITLE, fontSize = 11, textColor = TEXT_DIM},
		)
		if clay.UI(clay.ID("SettingsPreviewReceived"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({max = ui.prefs.centered_chat ? 620 : 900})},
				layoutDirection = .TopToBottom,
				childGap = 3,
				padding = clay.PaddingAll(6),
			},
			backgroundColor = PLATE,
			cornerRadius = rr(BUBBLE_R),
		},
		) {
			if clay.UI(clay.ID("SettingsPreviewAuthor"))(
			{layout = {childGap = 8, childAlignment = {y = .Center}}},
			) {
				avatar("SettingsPreviewAvatar", 0, "settings-preview", tr("A friend"), 20)
				clay.Text(tr("A friend"), {fontId = FONT_TITLE, fontSize = 11, textColor = ACCENT})
			}
			clay.Text(
				tr("A little more room for conversation."),
				{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT},
			)
		}
		if clay.UI(clay.ID("SettingsPreviewSent"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({max = ui.prefs.centered_chat ? 620 : 900})},
				padding = clay.PaddingAll(6),
				childAlignment = {x = .Right},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(BUBBLE_R),
		},
		) {
			clay.Text(
				tr("That feels right."),
				{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT},
			)
		}
	}
}

settings_appearance :: proc(ui: ^Ui_State) {
	if ui.settings_tab != 2 {settings_conversation_preview(ui)}
	switch ui.settings_tab {
	case 0:
		if clay.UI(clay.ID("ThemeGroup"))(settings_box()) {
			settings_group(tr("Theme"))
			if clay.UI(clay.ID("RowTheme"))(settings_row(true)) {
				row_labels(tr("Theme"), tr("Pick the whole app's look."))
				if clay.UI(clay.ID("ThemeDrop"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFit({min = 160}),
							height = clay.SizingFixed(30),
						},
						padding = {left = 8, right = 8},
						childGap = 8,
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? HOVER : CARD,
					cornerRadius = rr(7),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					if clay.UI(clay.ID("ThemeDropSwatch"))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(12), height = clay.SizingFixed(12)},
						},
						backgroundColor = active_pack(ui).bg,
						cornerRadius = rr(4),
						border = {color = FIELD_BORDER, width = bw()},
					},
					) {}
					clay.Text(
						tr(active_pack(ui).name),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
					)
					clay.Text("▾", {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})

					if open_now(clay.ID("ThemeMenu"), ui.theme_menu_open) {
						menu_w := fit_w(172, 8)
						menu_h := min(f32(240), f32(rl.GetScreenHeight()) / UI_ZOOM - 16)
						anchor, _ := element_box(clay.ID("ThemeDrop"))
						x, y := panel_pos(
							anchor.x + anchor.width - menu_w,
							anchor.y + anchor.height + rise(clay.ID("ThemeMenu")),
							menu_w,
							menu_h,
						)
						if clay.UI(clay.ID("ThemeMenu"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(menu_w),
									height = clay.SizingFit({max = menu_h}),
								},
								layoutDirection = .TopToBottom,
								padding = clay.PaddingAll(6),
								childGap = 2,
							},
							floating = {attachTo = .Root, zIndex = 12, offset = {x, y}},
							backgroundColor = CARD,
							cornerRadius = rr(2),
							clip = {vertical = true, childOffset = clay.GetScrollOffset()},
							border = {color = ELEVATED_BORDER, width = bw()},
						},
						) {
							for _, n in theme_packs {
								i := n
								if system_theme_index >= 0 {
									i =
										n == 0 ? system_theme_index : (n <= system_theme_index ? n - 1 : n)
								}
								pack := theme_packs[i]
								if clay.UI(clay.ID("ThemeOpt", u32(i)))(
								{
									layout = {
										sizing = {width = clay.SizingGrow()},
										padding = clay.PaddingAll(8),
										childGap = 8,
										childAlignment = {y = .Center},
									},
									backgroundColor = ui.theme == i ? SELECTED : (hovered() ? HOVER : {}),
									cornerRadius = rr(2),
								},
								) {
									if clay.UI(clay.ID("ThemeOptSwatch", u32(i)))(
									{
										layout = {
											sizing = {
												width = clay.SizingFixed(12),
												height = clay.SizingFixed(12),
											},
										},
										backgroundColor = pack.bg,
										cornerRadius = rr(4),
										border = {color = FIELD_BORDER, width = bw()},
									},
									) {}
									clay.Text(
										tr(pack.name),
										{
											fontId = FONT_BODY,
											fontSize = 13,
											textColor = ui.theme == i ? ACCENT : TEXT,
										},
									)
								}
							}
						}
					}
				}
			}
			if ui.theme != system_theme_index {
				if clay.UI(clay.ID("RowAccent"))(settings_row(true)) {
					row_labels(tr("Accent color"), "")
					clay.Text(
						tr(ACCENT_NAMES[ui.accent]),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
					if clay.UI(clay.ID("AccentChoices"))({layout = {childGap = 10}}) {
						for _, i in ACCENT_NAMES {
							if clay.UI(clay.ID("AccentDot", u32(i)))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(18),
										height = clay.SizingFixed(18),
									},
								},
								backgroundColor = active_pack(ui).accent_base[i],
								cornerRadius = rr(2),
								border = ui.accent == i ? clay.BorderElementConfig{color = TEXT, width = {2, 2, 2, 2, 0}} : {},
							},
							) {}
						}
					}
				}
			}
			if clay.UI(clay.ID("RowThemeShare"))(settings_row(true)) {
				row_labels(
					tr("Share this theme"),
					tr("Pick a chat to send it to. They choose whether to use it."),
				)
				if clay.UI(clay.ID("ThemeShareActions"))({layout = {childGap = 8}}) {
					settings_button("ThemeShareBtn", tr("Share to chat"))
					settings_button("ThemeEditBtn", tr("Edit"))
					if active_pack(ui).custom {
						settings_button("ThemeDeleteBtn", tr("Delete"), DANGER)
					}
				}
			}

		}
	case 2:
		settings_avatar_choices(ui)

	case 1:
		if clay.UI(clay.ID("InterfaceGroup"))(settings_box()) {
			settings_group(tr("Interface"))
			if clay.UI(clay.ID("RowZoom"))(settings_row(true)) {
				row_labels(tr("Interface zoom"), tr("Also Ctrl + / - / 0."))
				if clay.UI(clay.ID("ZoomChoices"))(
				{layout = {childGap = 8, childAlignment = {y = .Center}}},
				) {
					clay.Text(
						fmt.tprintf("%d%%", ui.prefs.zoom_pct),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
					settings_button("ZoomMinus", "-")
					settings_button("ZoomPlus", "+")
					settings_button("ZoomReset", tr("Reset"))
				}
			}
			if clay.UI(clay.ID("RowBodyFont"))(settings_row(true)) {
				row_labels(
					tr("Message text size"),
					tr("Applies to message bodies and the composer."),
				)
				if clay.UI(clay.ID("BodyFontChoices"))({layout = {childGap = 6}}) {
					for label, i in BODY_FONT_LABELS {
						settings_option(
							"BodyFontChip",
							u32(i),
							tr(label),
							ui.prefs.body_font == BODY_FONT_DELTAS[i],
						)
					}
				}
			}
			if clay.UI(clay.ID("RowEmojiSet"))(settings_row(true)) {
				row_labels(
					tr("Emoji style"),
					tr("Applies to the picker, reactions and emoji in messages."),
				)
				if clay.UI(clay.ID("EmojiSetChoices"))({layout = {childGap = 6}}) {
					for name, set in EMOJI_SET_NAMES {
						settings_option("EmojiSetChip", u32(set), name, ui.prefs.emoji_set == set)
					}
				}
			}
			if clay.UI(clay.ID("RowScroll"))(settings_row(true)) {
				row_labels(tr("Scroll speed"), tr("How far the mouse wheel moves the view."))
				if clay.UI(clay.ID("ScrollChoices"))({layout = {childGap = 6}}) {
					for label, i in SCROLL_SPEED_LABELS {
						settings_option(
							"ScrollChip",
							u32(i),
							label,
							ui.prefs.scroll_speed == SCROLL_SPEEDS[i],
						)
					}
				}
			}
		}

		if clay.UI(clay.ID("LayoutGroup"))(settings_box()) {
			settings_group(tr("Layout"))
			if clay.UI(clay.ID("RowMotion"))(settings_row()) {
				settings_check(
					"TgMotion",
					ui.prefs.reduce_motion,
					tr("Reduce motion"),
					tr(
						"Turn off animated transitions, flights and effects. State still changes, nothing moves.",
					),
				)
			}
			if clay.UI(clay.ID("RowCentered"))(settings_row()) {
				settings_check(
					"TgCentered",
					ui.prefs.centered_chat,
					tr("Centred conversation"),
					tr(
						"Keep the open conversation on a comfortable reading measure instead of filling the width.",
					),
				)
			}
			if clay.UI(clay.ID("RowMessageLines"))(settings_row(true)) {
				row_labels(
					tr("Message line limit"),
					tr(
						"Collapse messages and event cards after this many lines. Set to 0 to never collapse.",
					),
				)
				if clay.UI(clay.ID("MessageLinesChoices"))(
				{layout = {childGap = 12, childAlignment = {y = .Center}}},
				) {
					if clay.UI(clay.ID("MessageLinesStepper"))(
					{
						layout = {padding = clay.PaddingAll(2), childAlignment = {y = .Center}},
						backgroundColor = CARD,
						border = {color = FIELD_BORDER, width = bw()},
						cornerRadius = rr(7),
					},
					) {
						for id, i in ([3]string{"MessageLinesMinus", "MessageLinesValue", "MessageLinesPlus"}) {
							action := i == 2 || i == 0 && ui.prefs.message_lines > 0
							if clay.UI(clay.ID(id))(
							{
								layout = {
									sizing = {
										width = clay.SizingFit({min = i == 1 ? 44 : 28}),
										height = clay.SizingFixed(28),
									},
									padding = {
										left = 6,
										right = 6,
										top = action ? press_down(clay.ID(id)) : 0,
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = action && hovered() ? HOVER : {},
								cornerRadius = rr(4),
							},
							) {
								label :=
									i == 1 ? fmt.tprintf("%d", ui.prefs.message_lines) : i == 0 ? "-" : "+"
								clay.Text(
									label,
									{
										fontId = FONT_BODY,
										fontSize = i == 1 ? 13 : 16,
										textColor = i == 1 ? TEXT : action ? TEXT_DIM : TEXT_LO,
									},
								)
							}
						}
					}
					if clay.UI(clay.ID("MessageLinesReset"))(
					{
						layout = {
							padding = {left = 6, right = 6},
							sizing = {height = clay.SizingFixed(32)},
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(4),
					},
					) {clay.Text(tr("Reset"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})}
				}
			}
		}
	}
}

// ── Notifications ───────────────────────────────────────────────────

settings_notifications :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("NotificationsGroup"))(settings_box()) {
		settings_group(tr("Incoming messages"))
		if clay.UI(clay.ID("RowNotify"))(settings_row()) {
			settings_check(
				"TgNotify",
				ui.prefs.notify_desktop,
				tr("Desktop notifications"),
				tr("Get an alert when a message arrives in a chat you're not viewing."),
			)
		}
		if clay.UI(clay.ID("RowSound"))(settings_row()) {
			settings_check("TgSound", ui.prefs.notify_sound, tr("Play a sound"), "")
		}
		if clay.UI(clay.ID("RowUiSounds"))(settings_row()) {
			settings_check(
				"TgUiSounds",
				ui.prefs.ui_sounds,
				tr("Interface sounds"),
				tr("Short tones when a message leaves, arrives, or fails to send."),
			)
		}
		if clay.UI(clay.ID("RowPreview"))(settings_row()) {
			settings_check(
				"TgPreview",
				ui.prefs.notify_preview,
				tr("Show message preview"),
				tr("Off shows only \"New message\" without the text."),
			)
		}
		if clay.UI(clay.ID("RowNotifyTest"))(settings_row()) {
			row_labels(
				tr("Send a test notification"),
				tr("See and hear it with today's sound and preview settings."),
			)
			settings_button("NotifyTest", tr("Send test"))
		}
	}
}

// ── Modals ──────────────────────────────────────────────────────────

lang_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("LangModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("LangModal"), 280))},
			padding = clay.PaddingAll(16),
			childGap = 6,
		},
		floating = {
			attachTo = .Root,
			zIndex = 11,
			offset = {0, rise(clay.ID("LangModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("LangHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(
				tr("Interface language"),
				{fontId = FONT_TITLE, fontSize = 16, textColor = TEXT},
			)
			if clay.UI(clay.ID("LangHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("LangClose"))(
			{
				layout = {padding = clay.PaddingAll(6)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		for pair, i in LOCALES {
			active := ui.prefs.locale == pair[0]
			if clay.UI(clay.ID("LangOpt", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(10),
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
				cornerRadius = rr(8),
			},
			) {
				clay.Text(
					pair[1],
					{fontId = FONT_BODY, fontSize = 13, textColor = active ? ACCENT : TEXT},
				)
				if active {
					clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 11, textColor = ACCENT})
				}
			}
		}
	}
}

SHORTCUTS := [][2]string {
	{"Enter", N_("Send the message")},
	{"Shift + Enter", N_("Insert a new line")},
	{"↑", N_("Edit your last message (empty composer)")},
	{"Esc", N_("Cancel edit / reply, close panels")},
	{"Ctrl + K", N_("Search everywhere")},
	{"Ctrl + P", N_("Command palette")},
	{"Ctrl + Tab / Shift + Tab", N_("Next / previous chat")},
	{"Ctrl + / - / 0", N_("Zoom in / out / reset")},
	{"← / →", N_("Previous / next in the media viewer")},
	{N_("Right click"), N_("Message menu")},
}

shortcuts_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ShortModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("ShortModal"), 340))},
			padding = clay.PaddingAll(16),
			childGap = 8,
		},
		floating = {
			attachTo = .Root,
			zIndex = 11,
			offset = {0, rise(clay.ID("ShortModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("ShortHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(
				tr("Keyboard shortcuts"),
				{fontId = FONT_TITLE, fontSize = 16, textColor = TEXT},
			)
			if clay.UI(clay.ID("ShortHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("ShortClose"))(
			{
				layout = {padding = clay.PaddingAll(6)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		for pair, i in SHORTCUTS {
			if clay.UI(clay.ID("ShortRow", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 10,
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(tr(pair[0]), {fontId = FONT_MONO, fontSize = 12, textColor = ACCENT})
				if clay.UI(clay.ID("ShortRowGap", u32(i)))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				clay.Text(tr(pair[1]), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			}
		}
	}
}

human_size :: proc(n: i64) -> string {
	switch {
	case n >= 1_000_000:
		return fmt.tprintf("%.1f MB", f64(n) / 1_000_000)
	case n >= 1_000:
		return fmt.tprintf("%.1f KB", f64(n) / 1_000)
	}
	return fmt.tprintf("%d B", n)
}

// ── System hooks ────────────────────────────────────────────────────

// Shell text is internal code; user-controlled arguments always go through
// shell_quote or spawn_argv, not the language's string-literal formatter.
@(private)
shell_quote :: proc(value: string) -> string {
	replacement := "'\\''"
	when ODIN_OS == .Windows {replacement = "''"}
	escaped, _ := strings.replace_all(value, "'", replacement, context.temp_allocator)
	return fmt.tprintf("'%s'", escaped)
}

@(private)
spawn_cmd :: proc(cmdline: string) {
	when ODIN_OS == .Windows {
		wide := windows.utf8_to_utf16(cmdline)
		encoded := base64.encode(
			([^]u8)(raw_data(wide))[:len(wide) * 2],
			allocator = context.temp_allocator,
		)
		params := windows.utf8_to_wstring(
			fmt.tprintf("-NoProfile -NonInteractive -EncodedCommand %s", encoded),
		)
		windows.ShellExecuteW(nil, nil, windows.utf8_to_wstring("powershell.exe"), params, nil, 0)
	} else {
		state, out, errout, _ := os.process_exec(
			{command = {"sh", "-c", fmt.tprintf("%s >/dev/null 2>&1 &", cmdline)}},
			context.temp_allocator,
		)
		_ = state
		delete(out)
		delete(errout)
	}
}

@(private)
spawn_argv :: proc(args: []string) {
	command := strings.builder_make(context.temp_allocator)
	when ODIN_OS == .Windows {strings.write_string(&command, "& ")}
	for arg, i in args {
		if i > 0 {strings.write_byte(&command, ' ')}
		strings.write_string(&command, shell_quote(arg))
	}
	spawn_cmd(strings.to_string(command))
}

@(private)
open_external :: proc(target: string) {
	when ODIN_OS == .Windows {
		windows.ShellExecuteW(nil, nil, windows.utf8_to_wstring(target), nil, nil, 1)
	} else when ODIN_OS == .Darwin {
		spawn_argv({"open", "--", target})
	} else {
		spawn_argv({"xdg-open", target})
	}
}

// Use each desktop's user-level launch-at-login mechanism. Relocating an
// unpacked app requires toggling this setting again.
apply_autostart :: proc(on: bool) {
	exe := executable_path()
	if exe == "" {return}
	when ODIN_OS == .Windows {
		key := `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`
		if on {
			spawn_cmd(
				fmt.tprintf(
					"New-Item -Path %s -Force | Out-Null; Set-ItemProperty -Path %s -Name WhiteNoise -Value %s",
					shell_quote(key),
					shell_quote(key),
					shell_quote(fmt.tprintf("\"%s\"", exe)),
				),
			)
		} else {
			spawn_cmd(
				fmt.tprintf(
					"Remove-ItemProperty -Path %s -Name WhiteNoise -ErrorAction SilentlyContinue",
					shell_quote(key),
				),
			)
		}
	} else when ODIN_OS == .Darwin {
		home, err := os.user_home_dir(context.temp_allocator)
		if err != nil {return}
		dir := fmt.tprintf("%s/Library/LaunchAgents", home)
		path := fmt.tprintf("%s/org.whitenoise.desktop.plist", dir)
		if !on {os.remove(path); return}
		os.make_directory_all(dir)
		entry := fmt.tprintf(
			"<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>Label</key><string>org.whitenoise.desktop</string><key>ProgramArguments</key><array><string>%s</string></array><key>RunAtLoad</key><true/></dict></plist>",
			html_esc(exe),
		)
		_ = os.write_entire_file(path, transmute([]u8)entry)
	} else {
		cfg, err := os.user_config_dir(context.temp_allocator)
		if err != nil {return}
		dir := fmt.tprintf("%s/autostart", cfg)
		path := fmt.tprintf("%s/whitenoise.desktop", dir)
		if !on {os.remove(path); return}
		os.make_directory_all(dir)
		// Desktop Entry Exec uses its own quoting, not shell quoting.
		escaped, _ := strings.replace_all(exe, "\\", "\\\\", context.temp_allocator)
		for ch in ([]string{"\"", "`", "$"}) {
			escaped, _ = strings.replace_all(
				escaped,
				ch,
				fmt.tprintf("\\%s", ch),
				context.temp_allocator,
			)
		}
		escaped, _ = strings.replace_all(escaped, "%", "%%", context.temp_allocator)
		entry := fmt.tprintf(
			"[Desktop Entry]\nType=Application\nName=White Noise\nExec=\"%s\"\n",
			escaped,
		)
		_ = os.write_entire_file(path, transmute([]u8)entry)
	}
}

// Message-body text size, the default 14px plus the prefs delta.
BODY_FS: u16 = 14

apply_zoom :: proc(ui: ^Ui_State) {
	ui.prefs.zoom_pct = clamp(ui.prefs.zoom_pct, 50, 200)
	// The base is the window's, not a constant: a phone-width window
	// magnifies less so the layout still gets MIN_UNITS across. The
	// pref stays a multiplier on top, so 100% means "this window's
	// natural size" everywhere.
	zoom := zoom_for_width(rl.GetScreenWidth()) * f32(ui.prefs.zoom_pct) / 100
	changed := zoom != UI_ZOOM
	UI_ZOOM = zoom
	// A zoom change is a geometry discontinuity: re-bake glyphs at the
	// new density, re-measure text, and drop eased values so nothing
	// glides in from coordinates that no longer exist. Skipped at boot
	// (app_started == 0): the window and clay aren't up yet, and the
	// boot path sets the scale itself.
	if changed && app_started != 0 {
		refresh_ui_scale()
		anim_snap_all()
		clay.ResetMeasureTextCache()
	}
	BODY_FS = u16(14 + clamp(ui.prefs.body_font, -4, 8))
}

// ── Interactions ────────────────────────────────────────────────────

flip :: proc(ui: ^Ui_State, flag: ^bool) {
	flag^ = !flag^
	save_settings(ui)
}

// Flips the settings switch drawn as `id`, from a click or the keyboard.
@(private)
settings_flip :: proc(ui: ^Ui_State, client: ^marmot.Client, id: string) {
	switch id {
	case "TgStt":
		flip(ui, &ui.prefs.stt_enabled)
		if !ui.prefs.stt_enabled {
			stt_stop(ui)
		}
	case "TgTts":
		flip(ui, &ui.prefs.tts_enabled)
		if !ui.prefs.tts_enabled {
			tts_stop(ui)
		}
	case "TgLaunch":
		when ODIN_OS != .OpenBSD {
			flip(ui, &ui.prefs.launch_at_login)
			apply_autostart(ui.prefs.launch_at_login)
		}
	case "TgTray":
		flip(ui, &ui.prefs.start_in_tray)
	case "TgMinTray":
		flip(ui, &ui.prefs.minimize_tray)
		apply_tray(ui)
	case "TgRestore":
		flip(ui, &ui.prefs.restore_last_chat)
	case "TgMotion":
		flip(ui, &ui.prefs.reduce_motion)
	case "TgCentered":
		flip(ui, &ui.prefs.centered_chat)
	case "TgNotify":
		flip(ui, &ui.prefs.notify_desktop)
	case "TgSound":
		flip(ui, &ui.prefs.notify_sound)
	case "TgUiSounds":
		flip(ui, &ui.prefs.ui_sounds)
		// Play the thing being turned on, so the toggle answers.
		if ui.prefs.ui_sounds {
			play_sound(.Receive)
		}
	case "TgPreview":
		flip(ui, &ui.prefs.notify_preview)
	case "TgLinkPreviews":
		flip(ui, &ui.prefs.disable_link_previews)
	case "TgMaps":
		flip(ui, &ui.prefs.map_consent)
	case "TgTelemetry":
		set_telemetry(ui, client, !ui.telemetry_enabled)
	case "TgAudit":
		set_audit(ui, client, !ui.audit_enabled)
	case "TgDevMode":
		flip(ui, &ui.prefs.dev_mode)
	}
}

// Tab and Shift+Tab walk the page's switches, Space or Enter flips the
// focused one. Not while a settings text box has focus, so Space still
// types into it. Runs before the release gate in handle_pages.
@(private)
settings_switch_keys :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	FIELDS :: bit_set[Focus] {
		.Relay,
		.Inbox,
		.Fetch,
		.Client,
		.Gm,
		.KP,
		.EmojiName,
		.SettingsSearch,
	}
	if ui.focus in FIELDS {
		return false
	}
	switch control_keys(settings_check_ids[:settings_check_count]) {
	case .None:
		return false
	case .Moved:
		scroll_into_view(clay.ID("SettingsPage"), clay.ID(kb_focus))
	case .Pressed:
		settings_flip(ui, client, kb_focus)
	}
	return true
}

handle_settings :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !custom_emoji_scanned {
		custom_emoji_scan()
	}

	// Open modals capture everything while open.
	if ui.export_open {
		if field_mouse(ui, &ui.export_pw, "ExportPwBox", 14) {
			ui.focus = .ExportPw
		}
		if rl.IsKeyPressed(.ESCAPE) {
			close_export(ui)
			return
		}
		// Enter submits the password step.
		if len(ui.export_result) == 0 && rl.IsKeyPressed(.ENTER) && len(ui.export_pw) > 0 {
			do_export(ui, client)
			return
		}
		if !mouse_released() {
			return
		}
		if clicked("ExportGo") && len(ui.export_result) == 0 && len(ui.export_pw) > 0 {
			do_export(ui, client)
			return
		}
		if clicked("ExportSave") && len(ui.export_result) > 0 {
			start_blob_save("nostr-key.ncryptsec", transmute([]u8)ui.export_result)
			return
		}
		if clicked("ExportCopy") && len(ui.export_result) > 0 {
			copy_text(ui, ui.export_result, tr("Encrypted key copied"))
			return
		}
		if clicked("ExportClose") ||
		   clicked("ExportCancel") ||
		   clicked("ExportDone") ||
		   !clay.PointerOver(clay.ID("ExportModal")) {
			close_export(ui)
		}
		return
	}
	if ui.lang_open {
		if mouse_released() {
			for pair, i in LOCALES {
				if clay.PointerOver(clay.ID("LangOpt", u32(i))) {
					delete(ui.prefs.locale)
					ui.prefs.locale = strings.clone(pair[0])
					set_locale(ui.prefs.locale)
					save_settings(ui)
					ui.lang_open = false
					return
				}
			}
			if clicked("LangClose") || !clay.PointerOver(clay.ID("LangModal")) {
				ui.lang_open = false
			}
		}
		if rl.IsKeyPressed(.ESCAPE) {
			ui.lang_open = false
		}
		return
	}
	if ui.shortcuts_open {
		if rl.IsKeyPressed(.ESCAPE) ||
		   (mouse_released() &&
				   (clicked("ShortClose") || !clay.PointerOver(clay.ID("ShortModal")))) {
			ui.shortcuts_open = false
		}
		return
	}
	if ui.theme_menu_open {
		if mouse_released() {
			for _, i in theme_packs {
				if clay.PointerOver(clay.ID("ThemeOpt", u32(i))) {
					theme_switch(ui, i, ui.accent)
					break
				}
			}
			ui.theme_menu_open = false
		}
		if rl.IsKeyPressed(.ESCAPE) {
			ui.theme_menu_open = false
		}
		return
	}

	if settings_handle_navigation(ui, client) {return}

	if !mouse_released() {
		return
	}

	for _, i in settings_tabs(ui.settings_section) {
		if clay.PointerOver(clay.ID("SettingsTab", u32(i))) && ui.settings_tab != i {
			if ui.settings_section == .Keys {
				keys_forget(ui)
			} else {
				ui.keys_confirm = ""
			}
			ui.settings_tab = i
			ui.settings_anchor = ""
			ui.settings_scroll_pending = true
			ui.focus = .Compose
			if scroll := clay.GetScrollContainerData(clay.ID("SettingsPage")); scroll.found {
				scroll.scrollPosition^ = {}
			}
			return
		}
	}

	for id in settings_check_ids[:settings_check_count] {
		if clicked(id) {
			settings_flip(ui, client, id)
			return
		}
	}

	switch ui.settings_section {
	case .Home:
		return
	case .Folders:
		// handle_folder_board took every click on this page.
		return
	case .Speech:
		if ui.prefs.stt_enabled {
			for model, i in STT_MODELS {
				if clay.PointerOver(clay.ID("SttModel", u32(i))) {
					if clicked("SttCancel") {return}
					stt_stop(ui)
					delete(ui.prefs.stt_model)
					ui.prefs.stt_model = strings.clone(model.name)
					save_settings(ui)
					stt_start(ui, purpose = .Download)
					return
				}
			}
		}
		if ui.prefs.tts_enabled {
			for _, i in TTS_VOICES {
				if clicked(fmt.tprintf("TtsPreview%d", i)) {
					ui.prefs.tts_voice = i
					save_settings(ui)
					tts_read(ui, TTS_LANGUAGES[tts_language(ui, "")].preview)
					return
				}
				if clay.PointerOver(clay.ID("TtsVoice", u32(i))) {
					tts_stop(ui)
					ui.prefs.tts_voice = i
					save_settings(ui)
					return
				}
			}
		}

	case .General:
		if clicked("LangChange") {
			ui.lang_open = true
			return
		}
		for i in 0 ..< 2 {
			if clay.PointerOver(clay.ID("TimeFmt", u32(i))) {
				ui.prefs.hour12 = i == 1
				save_settings(ui)
				return
			}
		}
		for _, i in DATE_FORMATS {
			if clay.PointerOver(clay.ID("DateFmt", u32(i))) {
				ui.prefs.date_format = i
				save_settings(ui)
				return
			}
		}
		for _, i in ui.prefs.quick_reactions {
			if clay.PointerOver(clay.ID("QuickChip", u32(i))) {
				delete(ui.prefs.quick_reactions[i])
				ordered_remove(&ui.prefs.quick_reactions, i)
				save_settings(ui)
				return
			}
		}
		if clicked("QuickAdd") {
			ui.picker_mode = .Quick_Reaction
			open_picker(ui, "") // focuses and clears the search box
			return
		}
		if clicked("QuickReset") {
			for emoji in ui.prefs.quick_reactions {
				delete(emoji)
			}
			clear(&ui.prefs.quick_reactions)
			for emoji in DEFAULT_QUICK_REACTIONS {
				append(&ui.prefs.quick_reactions, strings.clone(emoji))
			}
			save_settings(ui)
			return
		}
		for name, i in custom_emoji_names {
			if clay.PointerOver(clay.ID("EmojiChip", u32(i))) {
				os.remove(fmt.tprintf("%s/%s", emoji_dir(), name))
				custom_emoji_scan()
				return
			}
		}
		if clicked("EmojiAdd") {
			ui.picking_emoji = true
			rl.OpenFileDialog(true)
			return
		}
		if clicked("EmojiSave") && len(ui.emoji_name) > 0 {
			save_staged_emoji(ui)
			return
		}
		if clicked("EmojiCancel") {
			cancel_staged_emoji(ui)
			return
		}
		if clicked("ShortcutsView") {
			ui.shortcuts_open = true
			return
		}

	case .Network:
		handle_network(ui, client)

	case .Keys:
		handle_keys(ui, client)

	case .Appearance:
		if clicked("MessageLinesMinus") ||
		   clicked("MessageLinesPlus") ||
		   clicked("MessageLinesReset") {
			lines := ui.prefs.message_lines
			if clicked("MessageLinesMinus") {lines = max(lines - 1, 0)}
			if clicked("MessageLinesPlus") && lines < max(int) {lines += 1}
			if clicked("MessageLinesReset") {lines = DEFAULT_MESSAGE_LINES}
			ui.prefs.message_lines = lines
			for &msg in ui.messages {msg.excerpt = {}; msg.row_height = 0}
			for &pending in ui.pending {pending.excerpt = {}}
			for _, &card in nev_cards {card.excerpt = {}}
			save_settings(ui)
			return
		}
		for _, shape in AVATAR_SHAPE_NAMES {
			if clay.PointerOver(clay.ID("AvatarShapeChip", u32(shape))) {
				ui.prefs.avatar_shape = shape
				save_settings(ui)
				return
			}
		}
		for _, shape in CROP_SHAPE_NAMES {
			if clay.PointerOver(clay.ID("CropShapeChip", u32(shape))) {
				ui.prefs.crop_avatar_shape = shape
				save_settings(ui)
				return
			}
		}
		if clicked("ThemeDrop") {
			ui.theme_menu_open = true
			return
		}
		for _, i in ACCENT_NAMES {
			if clay.PointerOver(clay.ID("AccentDot", u32(i))) {
				theme_switch(ui, ui.theme, i)
				return
			}
		}
		for _, i in BODY_FONT_DELTAS {
			if clay.PointerOver(clay.ID("BodyFontChip", u32(i))) {
				ui.prefs.body_font = BODY_FONT_DELTAS[i]
				apply_zoom(ui)
				save_settings(ui)
				return
			}
		}
		for _, i in SCROLL_SPEEDS {
			if clay.PointerOver(clay.ID("ScrollChip", u32(i))) {
				ui.prefs.scroll_speed = SCROLL_SPEEDS[i]
				save_settings(ui)
				return
			}
		}
		for _, set in EMOJI_SET_NAMES {
			if clay.PointerOver(clay.ID("EmojiSetChip", u32(set))) {
				ui.prefs.emoji_set = set
				emoji_set_load(set)
				save_settings(ui)
				return
			}
		}
		if clicked("ZoomMinus") {
			ui.prefs.zoom_pct -= 10
			apply_zoom(ui)
			save_settings(ui)
			return
		}
		if clicked("ZoomPlus") {
			ui.prefs.zoom_pct += 10
			apply_zoom(ui)
			save_settings(ui)
			return
		}
		if clicked("ZoomReset") {
			ui.prefs.zoom_pct = 100
			apply_zoom(ui)
			save_settings(ui)
			return
		}
		if clicked("ThemeShareBtn") {
			if len(ui.chats) == 0 {
				set_status(ui, strings.clone(tr("No chats to share with yet.")), .Info)
				return
			}
			ui.fwd_open = true
			ui.fwd_kind = .Theme
			clear(&ui.fwd_filter)
			ui.focus = .Fwd
			return
		}
		if clicked("ThemeEditBtn") {
			theme_edit_open(ui)
			return
		}
		if clicked("ThemeDeleteBtn") && theme_packs[ui.theme].custom {
			confirm_ask(ui, .Delete_Theme, "", theme_packs[ui.theme].name, ui.theme)
			return
		}
		if clicked("ThemeDeleteBtn") && active_pack(ui).custom {
			confirm_ask(ui, .Delete_Theme, "", active_pack(ui).name, active_theme(ui))
			return
		}

	case .Notifications:
		if clicked("NotifyTest") {
			do_notify(
				ui,
				tr("Test notification"),
				tr("This is what a message alert looks like."),
				.Always,
			)
			return
		}

	case .Storage:
		handle_storage(ui)

	case .Advanced:
		handle_advanced(ui, client)
		return

	case .About:
	// static

	case .Debug:
		handle_debug(ui, client)

	case .KP:
		handle_kp(ui, client)
	}
}

// Focus clicks for the settings text boxes run on press, not release;
// the frame loop calls this before the release-gated handler.
settings_fields :: proc(ui: ^Ui_State) {
	settings_search_field(ui)
	if ui.settings_section == .Network {
		if field_mouse(ui, &ui.relay_input, "RelayBox", 14) {
			ui.focus = .Relay
		}
		if field_mouse(ui, &ui.inbox_input, "InboxBox", 14) {
			ui.focus = .Inbox
		}
		if field_mouse(ui, &ui.fetch_input, "FetchBox", 14) {
			ui.focus = .Fetch
		}
		if field_mouse(ui, &ui.client_input, "ClientBox", 14) {
			ui.focus = .Client
		}
	}
	if ui.settings_section == .KP {
		if field_mouse(ui, &ui.kp_input, "KpBox", 14) {
			ui.focus = .KP
		}
	}
	if ui.settings_section == .General && ui.settings_tab == 2 {
		if field_mouse(ui, &ui.gm_input, "GmBox", 14) {
			ui.focus = .Gm
		}
		// Commits every keystroke; the frame loop writes it in the background.
		if string(ui.gm_input[:]) != ui.prefs.gm_text {
			delete(ui.prefs.gm_text)
			ui.prefs.gm_text = strings.clone(string(ui.gm_input[:]))
			ui.settings_dirty = true
		}
	}
	if ui.settings_section == .General && ui.settings_tab == 2 && len(ui.emoji_staged) > 0 {
		if field_mouse(ui, &ui.emoji_name, "EmojiNameBox", 14) {
			ui.focus = .EmojiName
		}
		// Runs every frame (the release-gated handler would miss keys):
		// Enter saves the shortcode; settings_escape drops the staged file.
		if ui.focus == .EmojiName && rl.IsKeyPressed(.ENTER) && len(ui.emoji_name) > 0 {
			save_staged_emoji(ui)
		}
	}
}
