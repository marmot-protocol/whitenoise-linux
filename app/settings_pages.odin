// The slint settings shell: section sidebar + row-grammar pages
// (ui/settings/ in the slint tree). Sections mirror the slint list;
// rows whose backing feature isn't in marmot-c yet keep the exact
// look and surface "Not available in the odin port yet." on use.
package main

import "core:fmt"
import "core:os"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

Settings_Section :: enum {
	General,
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
	.General       = {N_("General"), ICON_SETTINGS},
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

// Page header: icon plate + title + caps sub-line.
settings_header :: proc(icon: string, title: string, sub: string) {
	if clay.UI(clay.ID("SettingsHead"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 12,
			childAlignment = {y = .Center},
			padding = {bottom = 8},
		},
	},
	) {
		if clay.UI(clay.ID("SettingsHeadIcon"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(36), height = clay.SizingFixed(36)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = SELECTED,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(icon, {fontId = FONT_ICON, fontSize = 15, textColor = ACCENT})
		}
		if clay.UI(clay.ID("SettingsHeadCol"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 3}},
		) {
			clay.Text(tr(title), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
			if len(sub) > 0 {
				clay.Text(
					tr(sub),
					{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2},
				)
			}
		}
	}
}

// ── Pane dispatch ───────────────────────────────────────────────────

settings_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("SettingsPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 10,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		switch ui.settings_section {
		case .General:
			settings_header(ICON_SETTINGS, "General", "")
			settings_general(ui)
		case .Speech:
			settings_header(ICON_MIC, "Speech", "")
			settings_speech(ui)
		case .Network:
			settings_header(ICON_GLOBE, "Network & relays", "WHERE YOUR MESSAGES LAND")
			settings_network(ui)
		case .Keys:
			settings_header(ICON_KEY, "Keys & identity", "MLS · YOUR KEY MATERIAL")
			settings_keys(ui)
		case .Appearance:
			settings_header(ICON_BRUSH, "Appearance", "")
			settings_appearance(ui)
		case .Notifications:
			settings_header(ICON_BELL, "Notifications", "DESKTOP ALERTS")
			settings_notifications(ui)
		case .Storage:
			settings_header(ICON_ARCHIVE, "Storage", "ON THIS DEVICE")
			settings_storage(ui)
		case .Advanced:
			settings_header(ICON_CODE, "Advanced", "PRIVACY & DEVELOPER FLAGS")
			settings_advanced(ui)
		case .About:
			settings_header(ICON_INFO, "About", "WHAT THIS IS, LIVE")
			settings_about(ui)
		case .Debug:
			settings_header(ICON_BUG, "Debug", "STATE / EVENTS / KEYS / TIMINGS")
			settings_debug(ui)
		case .KP:
			settings_header(ICON_KEY, "KP inspector", "DECODED MLS KEY PACKAGES")
			settings_kp(ui)
		}
	}
	scrollbar(clay.ID("SettingsPage"))

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

// Speech

@(private)
settings_speech :: proc(ui: ^Ui_State) {
	eyebrow("SPEECH TO TEXT")
	if clay.UI(clay.ID("RowStt"))(srow()) {
		row_labels(
			"Speech to text",
			"Dictate drafts and transcribe audio messages on your device.",
		)
		toggle("TgStt", ui.prefs.stt_enabled)
	}
	if ui.prefs.stt_enabled {
		eyebrow("TRANSCRIPTION MODEL")
		clay.Text(
			tr("Select a model to download it for dictation and audio messages."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
		for model, i in STT_MODELS {
			selected := stt_model(ui.prefs.stt_model) == i
			row := srow()
			row.backgroundColor = selected ? SELECTED : ROW_BG
			row.layout.layoutDirection = .TopToBottom
			if clay.UI(clay.ID("SttModel", u32(i)))(row) {
				active := selected && ui.stt.file != nil && ui.stt.purpose == .Download
				label := ui.stt.ready[i] ? tr("Downloaded") : tr("Not downloaded")
				fraction: f32
				if active {
					bytes := f32(model.sizes[ui.stt.model]) * f32(ui.stt.percent) / 100
					for j in 0 ..< int(ui.stt.model) {bytes += f32(model.sizes[j])}
					fraction = bytes / f32(model.bytes)
					label =
						ui.stt.status == 'D' ? fmt.tprintf(tr("Downloading: %d%%"), int(fraction * 100)) : tr("Verifying download...")
				}
				if clay.UI(clay.ID_LOCAL("SttModelHeading"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 8,
						childAlignment = {y = .Center},
					},
				},
				) {
					row_labels(
						model.label,
						fmt.tprintf("%s · %s", human_size(model.bytes), label),
					)
					if selected {
						clay.Text(
							ICON_CHECK,
							{fontId = FONT_ICON, fontSize = 12, textColor = ACCENT},
						)
						clay.Text(
							tr("Selected"),
							{fontId = FONT_BODY, fontSize = 11, textColor = ACCENT},
						)
					}
				}
				clay.Text(
					tr(model.languages),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
				if active {
					if clay.UI(clay.ID_LOCAL("SttDownloadTrack"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)},
						},
						backgroundColor = PLATE,
						cornerRadius = rr(2),
					},
					) {
						if fraction > 0 {
							if clay.UI(clay.ID_LOCAL("SttDownloadFill"))(
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
					micro_button("SttCancel", "Cancel")
				}
			}
		}
	}
	eyebrow("READ ALOUD")
	if clay.UI(clay.ID("RowTts"))(srow()) {
		row_labels(
			"Read aloud",
			"Read messages on your device in 31 languages. Downloads about 145 MB on first use.",
		)
		toggle("TgTts", ui.prefs.tts_enabled)
	}
	if ui.prefs.tts_enabled {
		if clay.UI(clay.ID("TtsModel"))(srow()) {
			row_labels(
				"Speech model",
				"Shared by all ten voices and 31 languages. Downloads once.",
			)
			settings_tts_download(ui, 0)
		}
		for voice, i in TTS_VOICES {
			selected := clamp(ui.prefs.tts_voice, 0, len(TTS_VOICES) - 1) == i
			row := srow()
			row.layout.layoutDirection = .TopToBottom
			row.backgroundColor = selected ? SELECTED : ROW_BG
			if clay.UI(clay.ID("TtsVoice", u32(i)))(row) {
				_ = hovered()
				if clay.UI(clay.ID_LOCAL("VoiceTitle"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 10,
						childAlignment = {y = .Center},
					},
				},
				) {
					row_labels(voice, TTS_DESCRIPTIONS[i])
					if selected {
						clay.Text(
							ICON_CHECK,
							{fontId = FONT_ICON, fontSize = 12, textColor = ACCENT},
						)
						clay.Text(
							tr("Selected"),
							{fontId = FONT_BODY, fontSize = 11, textColor = ACCENT},
						)
					}
				}
				if clay.UI(clay.ID_LOCAL("VoiceDownload"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 12,
						childAlignment = {y = .Center},
					},
				},
				) {
					settings_tts_download(ui, 6)
					micro_button(fmt.tprintf("TtsPreview%d", i), "Preview")
				}
			}
		}
	}
}

// ── General ─────────────────────────────────────────────────────────

settings_general :: proc(ui: ^Ui_State) {
	eyebrow("STARTUP")
	if clay.UI(clay.ID("RowLaunch"))(srow()) {
		row_labels("Launch at login", "")
		toggle("TgLaunch", ui.prefs.launch_at_login)
	}
	if clay.UI(clay.ID("RowTray"))(srow()) {
		row_labels("Start minimized to tray", "Takes effect on the next launch.")
		toggle("TgTray", ui.prefs.start_in_tray)
	}
	if clay.UI(clay.ID("RowMinTray"))(srow()) {
		row_labels(
			"Close to tray",
			"Closing the window hides it. The tray icon shows your unread total and brings it back.",
		)
		toggle("TgMinTray", ui.prefs.minimize_tray)
	}
	if clay.UI(clay.ID("RowRestore"))(srow()) {
		row_labels("Restore last selected chat on launch", "")
		toggle("TgRestore", ui.prefs.restore_last_chat)
	}

	eyebrow("LANGUAGE")
	if clay.UI(clay.ID("RowLang"))(srow()) {
		row_labels("Interface language", "")
		clay.Text(
			locale_label(ui.prefs.locale),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		micro_button("LangChange", "Change")
	}
	if clay.UI(clay.ID("RowTimeFmt"))(srow()) {
		row_labels("Time format", "")
		if clay.UI(clay.ID("TimeFmtCol"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 4}},
		) {
			theme_chip_indexed("TimeFmt", 0, "24-hour", !ui.prefs.hour12)
			theme_chip_indexed("TimeFmt", 1, "12-hour", ui.prefs.hour12)
		}
	}
	if clay.UI(clay.ID("RowDateFmt"))(srow()) {
		row_labels("Date format", "")
		if clay.UI(clay.ID("DateFmtCol"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 4}},
		) {
			for label, i in DATE_FORMATS {
				theme_chip_indexed("DateFmt", u32(i), label, ui.prefs.date_format == i)
			}
		}
	}

	eyebrow("QUICK REACTIONS")
	if clay.UI(clay.ID("RowQuick"))(srow()) {
		row_labels(
			"One-tap reactions",
			"Shown on the message menu. Tap one to remove it. Up to 16.",
		)
		for emoji, i in ui.prefs.quick_reactions {
			if clay.UI(clay.ID("QuickChip", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(24), height = clay.SizingFixed(24)},
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
					clay.Text(emoji, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
				}
			}
		}
		if len(ui.prefs.quick_reactions) < QUICK_MAX do if clay.UI(clay.ID("QuickAdd"))({layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)}) {
			clay.Text("+", {fontId = FONT_BODY, fontSize = 14, textColor = TEXT})
		}
	}
	if clay.UI(clay.ID("RowQuickReset"))(srow()) {
		row_labels("Restore the default reactions", "")
		micro_button("QuickReset", "Reset")
	}

	eyebrow("CUSTOM EMOJI")
	if clay.UI(clay.ID("RowEmoji"))(srow()) {
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
			input_box(
				ui,
				"EmojiNameBox",
				&ui.emoji_name,
				"party_parrot",
				ui.focus == .EmojiName,
				220,
			)
			micro_button("EmojiSave", "Save")
			micro_button("EmojiCancel", "Cancel")
		}
	}

	eyebrow("HELP")
	if clay.UI(clay.ID("RowShortcuts"))(srow()) {
		row_labels("Keyboard shortcuts", "")
		micro_button("ShortcutsView", "View")
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

settings_appearance :: proc(ui: ^Ui_State) {
	eyebrow("THEME")
	if clay.UI(clay.ID("RowThemeShare"))(srow()) {
		row_labels("Share this theme", "Pick a chat to send it to. They choose whether to use it.")
		micro_button("ThemeShareBtn", "Share to chat")
		micro_button("ThemeEditBtn", "Edit")
		if theme_packs[ui.theme].custom {
			micro_button("ThemeDeleteBtn", "Delete", DANGER)
		}
		if active_pack(ui).custom {
			micro_button("ThemeDeleteBtn", "Delete", DANGER)
		}
	}
	if clay.UI(clay.ID("RowTheme"))(srow()) {
		row_labels("Theme", "Pick the whole app's look.")
		if clay.UI(clay.ID("ThemeDrop"))(
		{
			layout = {
				padding = {left = 12, right = 12, top = 7, bottom = 7},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(8),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if clay.UI(clay.ID("ThemeDropSwatch"))(
			{
				layout = {sizing = {width = clay.SizingFixed(12), height = clay.SizingFixed(12)}},
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
				if clay.UI(clay.ID("ThemeMenu"))(
				{
					layout = {
						sizing = {height = clay.SizingFit({max = 240})},
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(6),
						childGap = 2,
					},
					floating = {
						attachTo = .Parent,
						zIndex = 12,
						offset = {0, rise(clay.ID("ThemeMenu"))},
						attachment = {element = .RightTop, parent = .RightBottom},
					},
					backgroundColor = CARD,
					cornerRadius = rr(10),
					clip = {vertical = true, childOffset = clay.GetScrollOffset()},
					border = {color = ELEVATED_BORDER, width = bw()},
				},
				) {
					for _, n in theme_packs {
						i := n
						if system_theme_index >= 0 {
							i = n == 0 ? system_theme_index : (n <= system_theme_index ? n - 1 : n)
						}
						pack := theme_packs[i]
						if clay.UI(clay.ID("ThemeOpt", u32(i)))(
						{
							layout = {
								sizing = {width = clay.SizingFixed(160)},
								padding = clay.PaddingAll(8),
								childGap = 8,
								childAlignment = {y = .Center},
							},
							backgroundColor = ui.theme == i ? SELECTED : (hovered() ? HOVER : {}),
							cornerRadius = rr(6),
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
		if clay.UI(clay.ID("RowAccent"))(srow()) {
			row_labels("Accent color", "")
			clay.Text(
				ACCENT_NAMES[ui.accent],
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			for _, i in ACCENT_NAMES {
				if clay.UI(clay.ID("AccentDot", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(18), height = clay.SizingFixed(18)},
					},
					backgroundColor = active_pack(ui).accent_base[i],
					cornerRadius = rr(9),
					border = ui.accent == i ? clay.BorderElementConfig{color = TEXT, width = {2, 2, 2, 2, 0}} : {},
				},
				) {}
			}
		}
	}

	eyebrow("AVATARS")
	if clay.UI(clay.ID("RowAvatarShape"))(srow()) {
		row_labels("Default avatar shape", "Used for profile photos without a published shape.")
		for label, shape in AVATAR_SHAPE_NAMES {
			theme_chip_indexed(
				"AvatarShapeChip",
				u32(shape),
				tr(label),
				ui.prefs.avatar_shape == shape,
			)
		}
	}
	if clay.UI(clay.ID("RowCropShape"))(srow()) {
		row_labels("Crop circle shape", "Used for generated user and group avatars.")
		for label, shape in CROP_SHAPE_NAMES {
			theme_chip_indexed(
				"CropShapeChip",
				u32(shape),
				tr(label),
				ui.prefs.crop_avatar_shape == shape,
			)
		}
	}

	eyebrow("ZOOM")
	if clay.UI(clay.ID("RowZoom"))(srow()) {
		row_labels("Interface zoom", "Also Ctrl + / - / 0.")
		clay.Text(
			fmt.tprintf("%d%%", ui.prefs.zoom_pct),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		micro_button("ZoomMinus", "-")
		micro_button("ZoomPlus", "+")
		micro_button("ZoomReset", "Reset")
	}

	eyebrow("TEXT SIZE")
	if clay.UI(clay.ID("RowBodyFont"))(srow()) {
		row_labels("Message text size", "Applies to message bodies and the composer.")
		for label, i in BODY_FONT_LABELS {
			theme_chip_indexed(
				"BodyFontChip",
				u32(i),
				label,
				ui.prefs.body_font == BODY_FONT_DELTAS[i],
			)
		}
	}

	eyebrow("SCROLLING")
	if clay.UI(clay.ID("RowScroll"))(srow()) {
		row_labels("Scroll speed", "How far the mouse wheel moves the view.")
		for label, i in SCROLL_SPEED_LABELS {
			theme_chip_indexed(
				"ScrollChip",
				u32(i),
				label,
				ui.prefs.scroll_speed == SCROLL_SPEEDS[i],
			)
		}
	}

	eyebrow("MOTION")
	if clay.UI(clay.ID("RowMotion"))(srow()) {
		row_labels(
			"Reduce motion",
			"Turn off animated transitions, flights and effects. State still changes, nothing moves.",
		)
		toggle("TgMotion", ui.prefs.reduce_motion)
	}

	eyebrow("LAYOUT")
	if clay.UI(clay.ID("RowCentered"))(srow()) {
		row_labels(
			"Centred conversation",
			"Keep the open conversation on a comfortable reading measure instead of filling the width.",
		)
		toggle("TgCentered", ui.prefs.centered_chat)
	}
}

// ── Notifications ───────────────────────────────────────────────────

settings_notifications :: proc(ui: ^Ui_State) {
	eyebrow("INCOMING MESSAGES")
	if clay.UI(clay.ID("RowNotify"))(srow()) {
		row_labels(
			"Desktop notifications",
			"Get an alert when a message arrives in a chat you're not viewing.",
		)
		toggle("TgNotify", ui.prefs.notify_desktop)
	}
	if clay.UI(clay.ID("RowSound"))(srow()) {
		row_labels("Play a sound", "")
		toggle("TgSound", ui.prefs.notify_sound)
	}
	if clay.UI(clay.ID("RowUiSounds"))(srow()) {
		row_labels(
			"Interface sounds",
			"Short tones when a message leaves, arrives, or fails to send.",
		)
		toggle("TgUiSounds", ui.prefs.ui_sounds)
	}
	if clay.UI(clay.ID("RowPreview"))(srow()) {
		row_labels("Show message preview", "Off shows only \"New message\" without the text.")
		toggle("TgPreview", ui.prefs.notify_preview)
	}
	if clay.UI(clay.ID("RowNotifyTest"))(srow()) {
		row_labels(
			"Send a test notification",
			"See and hear it with today's sound and preview settings.",
		)
		micro_button("NotifyTest", "Send test")
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

	if !mouse_released() {
		return
	}

	// Section nav.
	for s in Settings_Section {
		if clay.PointerOver(clay.ID("SettingsNav", u32(s))) && ui.settings_section != s {
			ui.settings_section = s
			// Network/Keys read npub, relay lists, and nsec state.
			if s == .Network || s == .Keys {
				load_profile(client, ui)
			}
			// ponytail: blocks the nav click while marmot queries the
			// bootstrap relays; move to a worker if it ever drags.
			if s == .Keys {
				fetch_key_packages(ui, client)
			}
			if s == .Debug {
				compose_debug_json(ui, client)
			}
			if s == .Advanced {
				load_advanced(ui, client)
			}
			return
		}
	}

	switch ui.settings_section {
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
	if ui.settings_section == .General && len(ui.emoji_staged) > 0 {
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
