// Settings Control Panel and compact, immediately applied property pages.
package main

import "core:fmt"
import "core:os"
import "core:strings"

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
	return min(
		ui.settings_section == .Home ? 900 : (ui.settings_section == .General ? 560 : 740),
		max(120, page_w(ui) - (page_w(ui) < 560 ? 24 : 48)),
	)
}

@(private)
settings_body_width :: proc(ui: ^Ui_State) -> f32 {
	return max(120, settings_content_width(ui) - (page_w(ui) < 560 ? 16 : 32))
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
	label := tr(label)
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

@(private)
settings_check :: proc(id_str: string, checked: bool, title: string, sub: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 9,
			padding = {top = 3, bottom = 3},
		},
		backgroundColor = hovered() ? HOVER : {},
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
			tr(label),
			{fontId = FONT_BODY, fontSize = 12, textColor = color.a != 0 ? color : TEXT},
		)
	}
}

SETTINGS_GENERAL_TABS := []string{N_("Startup"), N_("Language"), N_("Messaging")}
SETTINGS_APPEARANCE_TABS := []string{N_("Theme"), N_("Interface"), N_("Avatars")}
SETTINGS_SPEECH_TABS := []string{N_("Dictation"), N_("Read aloud")}
SETTINGS_NETWORK_TABS := []string{N_("Relays"), N_("Linked events")}
SETTINGS_KEYS_TABS := []string{N_("Identity"), N_("Key packages"), N_("Security")}
SETTINGS_ADVANCED_TABS := []string{N_("Privacy"), N_("Audit logs"), N_("Developer")}

settings_tabs :: proc(ui: ^Ui_State) -> []string {
	#partial switch ui.settings_section {
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
		     "RowScroll",
		     "ScrollChip",
		     "RowMotion",
		     "TgMotion",
		     "RowCentered",
		     "TgCentered":
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
	tabs := settings_tabs(ui)
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
		for label, i in tabs {
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
					tr(label),
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
		clay.Text(tr(title), {fontId = FONT_TITLE, fontSize = 13, textColor = color})
		if len(sub) > 0 {
			clay.Text(tr(sub), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}
	}
}

// On/off pill, the slint toggle.
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

// Illustrated identity remains quiet so the controls own the property page.
settings_header :: proc(section: Settings_Section, title: string, sub: string) {
	if clay.UI(clay.ID("SettingsHead"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 10,
			childAlignment = {y = .Center},
			padding = {bottom = 12},
		},
	},
	) {
		settings_illustration("SettingsHeadArt", section, 40)
		if clay.UI(clay.ID("SettingsHeadCol"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 4,
			},
		},
		) {
			clay.Text(tr(title), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
			if len(sub) > 0 {
				clay.Text(tr(sub), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
		}
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
	if clay.UI(clay.ID("SettingsRoot"))(
	{
		layout = {
			sizing = {clay.SizingFixed(page_w(ui)), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
	},
	) {
		settings_navigation(ui)
		if clay.UI(clay.ID("SettingsPage"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(page_w(ui) < 560 ? 12 : 24),
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
				if ui.settings_section != .Home {
					section := SETTINGS_SECTIONS[ui.settings_section]
					settings_header(
						ui.settings_section,
						section.label,
						settings_description(ui.settings_section),
					)
					settings_tab_strip(ui)
				}
				if ui.settings_section == .Home {
					settings_home(ui)
				} else if clay.UI(clay.ID("SettingsSheet"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(page_w(ui) < 560 ? 8 : 16),
						childGap = 18,
					},
					backgroundColor = len(settings_tabs(ui)) > 0 ? PANEL : {},
					border = len(settings_tabs(ui)) > 0 ? clay.BorderElementConfig{color = FIELD_BORDER, width = {left = 1, right = 1, bottom = 1}} : {},
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
			}
		}
		scrollbar(clay.ID("SettingsPage"))
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
	box.layout.sizing.width = clay.SizingFixed(min(580, settings_body_width(ui)))
	if clay.UI(clay.ID("FoldersGroup"))(box) {
		settings_group(N_("Folders"))
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
					tr("Create folders to organize your chats."),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
				)
				clay.Text(
					tr("Deleting a folder doesn't delete your chats."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
			}
			settings_button("SettingsFolderNew", "New folder", ACCENT)
		}
		// Short lists fit their contents; long lists retain a bounded scroll viewport.
		list_height := max(60, f32(rl.GetScreenHeight()) / UI_ZOOM - 240)
		page := clay.GetElementData(clay.ID("SettingsPage"))
		actions := clay.GetElementData(clay.ID("SettingsFolderActions"))
		if page.found && actions.found {
			page_scroll := clay.GetScrollContainerData(clay.ID("SettingsPage"))
			offset := page_scroll.found ? page_scroll.scrollPosition.y : 0
			used :=
				actions.boundingBox.y + actions.boundingBox.height - page.boundingBox.y - offset
			list_height = max(60, page.boundingBox.height - used - 30)
		}
		list_height = min(list_height, max(0, f32(len(ui.prefs.folders) * 40 - 4)))
		if clay.UI(clay.ID("SettingsFolderList"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(list_height)},
				layoutDirection = .TopToBottom,
				childGap = 4,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			view := clay.GetScrollContainerData(clay.ID("SettingsFolderList"))
			height :=
				view.found ? view.scrollContainerDimensions.height : f32(rl.GetScreenHeight()) / UI_ZOOM
			offset := view.found ? -view.scrollPosition.y : 0
			first := clamp(int(offset / 40) - 2, 0, len(ui.prefs.folders))
			last := clamp(int((offset + height) / 40) + 3, first, len(ui.prefs.folders))
			if first > 0 {
				if clay.UI(clay.ID("SettingsFoldersBefore"))(
				{layout = {sizing = {height = clay.SizingFixed(f32(first) * 40 - 4)}}},
				) {}
			}
			for i in first ..< last {
				name := ui.prefs.folders[i]
				row := settings_row()
				row.layout.sizing.height = clay.SizingFixed(36)
				row.backgroundColor =
					clay.PointerOver(clay.ID("SettingsFolder", u32(i))) ? HOVER : {}
				row.border = {
					color = FIELD_BORDER,
					width = {bottom = 1},
				}
				if clay.UI(clay.ID("SettingsFolder", u32(i)))(row) {
					folder_icon(ui, name, 17)
					if clay.UI(clay.ID("SettingsFolderName", u32(i)))(
					{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
					) {
						clay.Text(
							name,
							{
								fontId = FONT_TITLE,
								fontSize = 13,
								textColor = TEXT,
								wrapMode = .None,
							},
						)
					}
					if clay.UI(clay.ID("SettingsFolderOrder", u32(i)))({layout = {childGap = 2}}) {
						for direction in 0 ..< 2 {
							id := direction == 0 ? "SettingsFolderUp" : "SettingsFolderDown"
							enabled := direction == 0 ? i > 0 : i + 1 < len(ui.prefs.folders)
							if clay.UI(clay.ID(id, u32(i)))(
							{
								layout = {
									sizing = {clay.SizingFixed(26), clay.SizingFixed(26)},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = enabled && hovered() ? HOVER : {},
								cornerRadius = rr(6),
							},
							) {
								clay.Text(
									direction == 0 ? "\uf062" : ICON_DOWN,
									{
										fontId = FONT_ICON,
										fontSize = 12,
										textColor = enabled ? TEXT_DIM : fade(TEXT_LO, 0.4),
									},
								)
								if hovered() {
									tooltip(direction == 0 ? N_("Move up") : N_("Move down"))
									if enabled {cursor_raise(.Pointer)}
								}
							}
						}
					}
					for action in 0 ..< 2 {
						id := action == 0 ? "SettingsFolderEdit" : "SettingsFolderDelete"
						if clay.UI(clay.ID(id, u32(i)))(
						{
							layout = {
								sizing = {clay.SizingFixed(26), clay.SizingFixed(26)},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = hovered() ? HOVER : {},
							cornerRadius = rr(6),
						},
						) {
							clay.Text(
								action == 0 ? ICON_PENCIL : ICON_TRASH,
								{
									fontId = FONT_ICON,
									fontSize = 14,
									textColor = action == 0 ? TEXT_DIM : DANGER,
								},
							)
							if hovered() {
								tooltip(action == 0 ? N_("Edit folder") : N_("Delete"))
								cursor_raise(.Pointer)
							}
						}
					}
				}
			}
			if last < len(ui.prefs.folders) {
				if clay.UI(clay.ID("SettingsFoldersAfter"))(
				{
					layout = {
						sizing = {
							height = clay.SizingFixed(f32(len(ui.prefs.folders) - last) * 40 - 4),
						},
					},
				},
				) {}
			}
		}
		scrollbar(clay.ID("SettingsFolderList"))
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
			settings_group(N_("Startup"))
			if clay.UI(clay.ID("RowLaunch"))(settings_row()) {
				settings_check("TgLaunch", ui.prefs.launch_at_login, "Launch at login", "")
			}
			if clay.UI(clay.ID("RowTray"))(settings_row()) {
				settings_check(
					"TgTray",
					ui.prefs.start_in_tray,
					"Start minimized to tray",
					"Takes effect on the next launch.",
				)
			}
			if clay.UI(clay.ID("RowMinTray"))(settings_row()) {
				settings_check(
					"TgMinTray",
					ui.prefs.minimize_tray,
					"Close to tray",
					"Closing the window hides it. The tray icon shows your unread total and brings it back.",
				)
			}
			if clay.UI(clay.ID("RowRestore"))(settings_row()) {
				settings_check(
					"TgRestore",
					ui.prefs.restore_last_chat,
					"Restore last selected chat on launch",
					"",
				)
			}
		}

	case 1:
		if clay.UI(clay.ID("LanguageGroup"))(settings_box()) {
			settings_group(N_("Language"))
			column := settings_row()
			column.layout.layoutDirection = .TopToBottom
			column.layout.childGap = 8
			if clay.UI(clay.ID("RowLang"))(column) {
				row_labels("Interface language", "")
				settings_button(
					"LangChange",
					fmt.tprintf("%s  ▾", locale_label(ui.prefs.locale)),
				)
			}
			if clay.UI(clay.ID("RowTimeFmt"))(column) {
				row_labels("Time format", "")
				if clay.UI(clay.ID("TimeFmtCol"))({layout = {childGap = 6}}) {
					settings_option("TimeFmt", 0, "14:30", !ui.prefs.hour12)
					settings_option("TimeFmt", 1, "2:30 PM", ui.prefs.hour12)
				}
			}
			if clay.UI(clay.ID("RowDateFmt"))(column) {
				row_labels("Date format", "")
				if clay.UI(clay.ID("DateFmtCol"))({layout = {childGap = 6}}) {
					for label, i in DATE_FORMATS {
						settings_option("DateFmt", u32(i), label, ui.prefs.date_format == i)
					}
				}
			}
		}

	case 2:
		if clay.UI(clay.ID("ReactionsGroup"))(settings_box()) {
			settings_group(N_("Quick reactions"))
			row := settings_row()
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("RowQuick"))(row) {
				row_labels(
					"One-tap reactions",
					"Shown on the message menu. Tap one to remove it. Up to 16.",
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
				row_labels("Restore the default reactions", "")
				settings_button("QuickReset", "Reset")
			}
		}

		if clay.UI(clay.ID("CustomEmojiGroup"))(settings_box()) {
			settings_group(N_("Custom emoji"))
			row := settings_row()
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("RowEmoji"))(row) {
				row_labels("Uploaded emoji", "Tap one to remove it.")
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
					"Name the shortcode. Type it in messages as :name:.",
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
					settings_button("EmojiSave", "Save")
					settings_button("EmojiCancel", "Cancel")
				}
			}
		}

		if clay.UI(clay.ID("ShortcutsGroup"))(settings_box()) {
			settings_group(N_("Help"))
			if clay.UI(clay.ID("RowShortcuts"))(settings_row()) {
				row_labels("Keyboard shortcuts", "")
				settings_button("ShortcutsView", "View")
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
BODY_FONT_LABELS := []string{"Small", "Default", "Large"}

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
			settings_group(N_("Theme"))
			if clay.UI(clay.ID("RowTheme"))(settings_row(true)) {
				row_labels("Theme", "Pick the whole app's look.")
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
					row_labels("Accent color", "")
					clay.Text(
						ACCENT_NAMES[ui.accent],
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
					"Share this theme",
					"Pick a chat to send it to. They choose whether to use it.",
				)
				if clay.UI(clay.ID("ThemeShareActions"))({layout = {childGap = 8}}) {
					settings_button("ThemeShareBtn", "Share to chat")
					settings_button("ThemeEditBtn", "Edit")
					if active_pack(ui).custom {
						settings_button("ThemeDeleteBtn", "Delete", DANGER)
					}
				}
			}

		}
	case 2:
		settings_avatar_choices(ui)

	case 1:
		if clay.UI(clay.ID("InterfaceGroup"))(settings_box()) {
			settings_group(N_("Interface"))
			if clay.UI(clay.ID("RowZoom"))(settings_row(true)) {
				row_labels("Interface zoom", "Also Ctrl + / - / 0.")
				if clay.UI(clay.ID("ZoomChoices"))(
				{layout = {childGap = 8, childAlignment = {y = .Center}}},
				) {
					clay.Text(
						fmt.tprintf("%d%%", ui.prefs.zoom_pct),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
					settings_button("ZoomMinus", "-")
					settings_button("ZoomPlus", "+")
					settings_button("ZoomReset", "Reset")
				}
			}
			if clay.UI(clay.ID("RowBodyFont"))(settings_row(true)) {
				row_labels("Message text size", "Applies to message bodies and the composer.")
				if clay.UI(clay.ID("BodyFontChoices"))({layout = {childGap = 6}}) {
					for label, i in BODY_FONT_LABELS {
						settings_option(
							"BodyFontChip",
							u32(i),
							label,
							ui.prefs.body_font == BODY_FONT_DELTAS[i],
						)
					}
				}
			}
			if clay.UI(clay.ID("RowScroll"))(settings_row(true)) {
				row_labels("Scroll speed", "How far the mouse wheel moves the view.")
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
			settings_group(N_("Layout"))
			if clay.UI(clay.ID("RowMotion"))(settings_row()) {
				settings_check(
					"TgMotion",
					ui.prefs.reduce_motion,
					"Reduce motion",
					"Turn off animated transitions, flights and effects. State still changes, nothing moves.",
				)
			}
			if clay.UI(clay.ID("RowCentered"))(settings_row()) {
				settings_check(
					"TgCentered",
					ui.prefs.centered_chat,
					"Centred conversation",
					"Keep the open conversation on a comfortable reading measure instead of filling the width.",
				)
			}
		}
	}
}

// ── Notifications ───────────────────────────────────────────────────

settings_notifications :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("NotificationsGroup"))(settings_box()) {
		settings_group(N_("Incoming messages"))
		if clay.UI(clay.ID("RowNotify"))(settings_row()) {
			settings_check(
				"TgNotify",
				ui.prefs.notify_desktop,
				"Desktop notifications",
				"Get an alert when a message arrives in a chat you're not viewing.",
			)
		}
		if clay.UI(clay.ID("RowSound"))(settings_row()) {
			settings_check("TgSound", ui.prefs.notify_sound, "Play a sound", "")
		}
		if clay.UI(clay.ID("RowUiSounds"))(settings_row()) {
			settings_check(
				"TgUiSounds",
				ui.prefs.ui_sounds,
				"Interface sounds",
				"Short tones when a message leaves, arrives, or fails to send.",
			)
		}
		if clay.UI(clay.ID("RowPreview"))(settings_row()) {
			settings_check(
				"TgPreview",
				ui.prefs.notify_preview,
				"Show message preview",
				"Off shows only \"New message\" without the text.",
			)
		}
		if clay.UI(clay.ID("RowNotifyTest"))(settings_row()) {
			row_labels(
				"Send a test notification",
				"See and hear it with today's sound and preview settings.",
			)
			settings_button("NotifyTest", "Send test")
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
	{"Esc", N_("Cancel edit / reply, close panels")},
	{"Ctrl + K", N_("Search everywhere")},
	{"Ctrl + P", N_("Command palette")},
	{"Ctrl + Tab / Shift + Tab", N_("Next / previous chat")},
	{"Ctrl + / - / 0", N_("Zoom in / out / reset")},
	{"← / →", N_("Previous / next in the media viewer")},
	{"Right click", N_("Message menu")},
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
				clay.Text(pair[0], {fontId = FONT_MONO, fontSize = 12, textColor = ACCENT})
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

// Fire-and-forget shell command; the shell backgrounds and reaps it.
spawn_cmd :: proc(cmdline: string) {
	state, out, errout, _ := os.process_exec(
		{command = {"sh", "-c", fmt.tprintf("%s >/dev/null 2>&1 &", cmdline)}},
		context.temp_allocator,
	)
	_ = state
	delete(out)
	delete(errout)
}

// XDG autostart entry for "Launch at login".
// ponytail: Exec uses argv[0] as launched; a relocated binary needs
// the toggle flipped off and on again.
apply_autostart :: proc(on: bool) {
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {
		cfg = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	dir := fmt.tprintf("%s/autostart", cfg)
	path := fmt.tprintf("%s/whitenoise.desktop", dir)
	if !on {
		os.remove(path)
		return
	}
	os.make_directory(dir)
	entry := fmt.tprintf(
		"[Desktop Entry]\nType=Application\nName=White Noise\nExec=%s\n",
		os.args[0],
	)
	_ = os.write_entire_file(path, transmute([]u8)entry)
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
			copy_text(ui, ui.export_result, "Encrypted key copied")
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

	for _, i in settings_tabs(ui) {
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

	switch ui.settings_section {
	case .Home:
		return
	case .Folders:
		if clicked("SettingsFolderNew") {
			open_folder_modal(ui)
			return
		}
		for _, i in ui.prefs.folders {
			up := clay.PointerOver(clay.ID("SettingsFolderUp", u32(i)))
			down := clay.PointerOver(clay.ID("SettingsFolderDown", u32(i)))
			if up || down {
				destination := i + (up ? -1 : 1)
				if destination >= 0 && destination < len(ui.prefs.folders) {
					ui.prefs.folders[i], ui.prefs.folders[destination] =
						ui.prefs.folders[destination], ui.prefs.folders[i]
					save_settings(ui)
				}
				return
			}
			if clay.PointerOver(clay.ID("SettingsFolderDelete", u32(i))) {
				delete_folder(ui, i)
				return
			}
			if clay.PointerOver(clay.ID("SettingsFolder", u32(i))) {
				open_folder_modal(ui, rename = i)
				return
			}
		}
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
		if clicked("TgStt") {
			flip(ui, &ui.prefs.stt_enabled)
			if !ui.prefs.stt_enabled {
				stt_stop(ui)
			}
			return
		}
		if clicked("TgTts") {
			flip(ui, &ui.prefs.tts_enabled)
			if !ui.prefs.tts_enabled {
				tts_stop(ui)
			}
			return
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
		if clay.PointerOver(clay.ID("TgLaunch")) {
			flip(ui, &ui.prefs.launch_at_login)
			apply_autostart(ui.prefs.launch_at_login)
			return
		}
		if clay.PointerOver(clay.ID("TgTray")) {
			flip(ui, &ui.prefs.start_in_tray)
			return
		}
		if clay.PointerOver(clay.ID("TgMinTray")) {
			flip(ui, &ui.prefs.minimize_tray)
			apply_tray(ui)
			return
		}
		if clay.PointerOver(clay.ID("TgRestore")) {
			flip(ui, &ui.prefs.restore_last_chat)
			return
		}
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
			ui.adding_quick = true
			ui.picker_open = true
			ui.picker_target = ""
			ui.picker_x = 200
			ui.picker_y = 120
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
				ui.client_status = strings.clone(tr("No chats to share with yet."))
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
		if clay.PointerOver(clay.ID("TgMotion")) {
			flip(ui, &ui.prefs.reduce_motion)
			return
		}
		if clay.PointerOver(clay.ID("TgCentered")) {
			flip(ui, &ui.prefs.centered_chat)
			return
		}

	case .Notifications:
		if clay.PointerOver(clay.ID("TgNotify")) {
			flip(ui, &ui.prefs.notify_desktop)
			return
		}
		if clay.PointerOver(clay.ID("TgSound")) {
			flip(ui, &ui.prefs.notify_sound)
			return
		}
		if clay.PointerOver(clay.ID("TgUiSounds")) {
			flip(ui, &ui.prefs.ui_sounds)
			// Play the thing being turned on, so the toggle answers.
			if ui.prefs.ui_sounds {
				play_sound(.Receive)
			}
			return
		}
		if clay.PointerOver(clay.ID("TgPreview")) {
			flip(ui, &ui.prefs.notify_preview)
			return
		}
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
	if ui.settings_section == .General && ui.settings_tab == 2 && len(ui.emoji_staged) > 0 {
		if field_mouse(ui, &ui.emoji_name, "EmojiNameBox", 14) {
			ui.focus = .EmojiName
		}
		// Runs every frame (the release-gated handler would miss keys):
		// Enter saves the shortcode, Escape drops the staged file.
		if ui.focus == .EmojiName {
			if rl.IsKeyPressed(.ENTER) && len(ui.emoji_name) > 0 {
				save_staged_emoji(ui)
			} else if rl.IsKeyPressed(.ESCAPE) {
				cancel_staged_emoji(ui)
			}
		}
	}
}
