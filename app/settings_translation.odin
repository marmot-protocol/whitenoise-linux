package main

import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"

// Shared with message controls. Download percentages describe the current
// asset, never the total; model loading and inference have no measured fraction.
@(private)
translation_progress :: proc(ui: ^Ui_State, id: string) {
	if ui.translation.status == 'D' {
		label :=
			ui.translation.model == 0 ? tr("Downloading translation model: %d%%") : tr("Downloading language detector: %d%%")
		nendo.text(
			fmt.tprintf(label, int(ui.translation.percent)),
			{font = FONT_BODY, size = 11, color = TEXT_DIM},
		)
		if nendo.box(nendo.id(id))(
		{width = nendo.grow(), height = nendo.fixed(4), color = PLATE, radius = rr(2)},
		) {
			if ui.translation.percent > 0 {
				if nendo.box(nendo.id(id, 1))(
				{
					width = nendo.percent(clamp(f32(ui.translation.percent) / 100, 0, 1)),
					height = nendo.grow(),
					color = ACCENT,
					radius = rr(2),
				},
				) {}
			}
		}
	} else {
		nendo.text(
			tr("Progress is indeterminate."),
			{font = FONT_BODY, size = 11, color = TEXT_DIM},
		)
		if nendo.box(nendo.id(id))(
		{width = nendo.grow(), height = nendo.fixed(4), clip = {x = true}},
		) {
			busy_bar(fmt.tprintf("%sBusy", id))
		}
	}
}

@(private)
settings_translation :: proc(ui: ^Ui_State) {
	when TRANSLATION_AVAILABLE {
		if nendo.box(nendo.id("TranslationGroup"))(settings_box()) {
			settings_group(tr("Message translation"))
			if nendo.box(nendo.id("RowTranslation"))(settings_row()) {
				settings_check(
					"TgTranslation",
					ui.prefs.translation_enabled,
					tr("Enable local translation"),
					tr(
						"Messages stay on your device. Downloads about 2.5 GB on first translation. Enabling accepts the Gemma terms and prohibited use policy.",
					),
				)
			}
			if nendo.box(nendo.id("TranslationTermsRow"))(settings_row(true)) {
				row_labels(tr("Gemma terms"), "")
				settings_translation_register("TranslationTerms")
				settings_button("TranslationTerms", external_link_action())
			}
			if nendo.box(nendo.id("TranslationPolicyRow"))(settings_row(true)) {
				row_labels(tr("Gemma prohibited use policy"), "")
				settings_translation_register("TranslationPolicy")
				settings_button("TranslationPolicy", external_link_action())
			}
			if !ui.prefs.translation_enabled {return}
			if nendo.box(nendo.id("RowTranslationAuto"))(settings_row()) {
				settings_check(
					"TgTranslationAuto",
					ui.prefs.translation_auto,
					tr("Translate received messages automatically"),
					tr(
						"Translates received messages as you read them. The first translation downloads the local model.",
					),
				)
			}
			settings_translation_language(
				ui,
				1,
				"RowTranslationSource",
				"TranslationSource",
				tr("Source language"),
				ui.prefs.translation_source,
			)
			settings_translation_language(
				ui,
				2,
				"RowTranslationTarget",
				"TranslationTarget",
				tr("Translate into"),
				ui.prefs.translation_target,
			)
			nendo.text(
				tr("Translations can be inaccurate. The original message is always available."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
			if nendo.box(nendo.id("TranslationModel"))(
			{width = nendo.grow(), direction = .Column, gap = 6},
			) {
				row_labels(TRANSLATION_MODEL_NAME, human_size(TRANSLATION_MODEL_BYTES))
				status := translation_status(ui)
				if status !=
				   "" {nendo.text(status, {font = FONT_BODY, size = 11, color = TEXT_DIM})}
				if ui.translation.file != nil {translation_progress(ui, "TranslationProgress")}
			}
		}
	} else {
		if nendo.box(nendo.id("TranslationGroup"))(settings_box()) {
			settings_group(tr("Message translation"))
			nendo.text(
				tr("Message translation is available in native Linux builds."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
		}
	}
}

@(private)
settings_translation_register :: proc(id: string) {
	if settings_check_count < len(settings_check_ids) {
		settings_check_ids[settings_check_count] = id
		settings_check_count += 1
	}
}

@(private)
settings_translation_label :: proc(ui: ^Ui_State, menu: int, code: string) -> string {
	if code == "" {
		if menu == 1 {return tr("Detect automatically")}
		for language in TRANSLATION_LANGUAGES {
			if language.code ==
			   translation_target(
				   ui,
			   ) {return fmt.tprintf(tr("Interface language (%s)"), tr(language.name))}
		}
		return tr("Interface language (English)")
	}
	for language in TRANSLATION_LANGUAGES {
		if language.code == code {return tr(language.name)}
	}
	return code
}

@(private)
settings_translation_language :: proc(ui: ^Ui_State, menu: int, row, id, title, code: string) {
	column := settings_row()
	column.direction = .Column
	column.gap = 6
	if nendo.box(nendo.id(row))(column) {
		row_labels(title, "")
		settings_translation_register(id)
		if nendo.box(nendo.id(id))(
		{
			width = nendo.grow(),
			padding = nendo.pad(8),
			gap = 8,
			color = hovered() ? HOVER : CARD,
			border = kb_focus == id ? kb_ring(ACCENT) : nendo.Border{color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
			radius = rr(6),
		},
		) {
			if nendo.box(nendo.id_local("Label"))({width = nendo.grow()}) {
				nendo.text(
					settings_translation_label(ui, menu, code),
					{font = FONT_BODY, size = 12, color = TEXT},
				)
			}
			nendo.text(
				ui.translation.language_menu == menu ? "▴" : "▾",
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
		}
		if ui.translation.language_menu != menu {return}
		list_height := min(
			f32(180),
			max(f32(48), nendo.element(nendo.id("SettingsPage")).rect.height - 24),
		)
		if nendo.box(nendo.id("TranslationLanguageList"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(list_height),
			direction = .Column,
			clip = {y = true, scroll = true},
			color = CARD,
			border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
		},
		) {
			for i in 0 ..= len(TRANSLATION_LANGUAGES) {
				option_code := i == 0 ? "" : TRANSLATION_LANGUAGES[i - 1].code
				option_id := fmt.tprintf("TranslationLanguage%d", i)
				if nendo.box(nendo.id(option_id))(
				{
					width = nendo.grow(),
					padding = nendo.pad(8),
					gap = 8,
					color = code == option_code ? SELECTED : (hovered() ? HOVER : CARD),
					border = ui.translation.language_choice == i ? kb_ring(ACCENT) : nendo.Border{},
				},
				) {
					settings_radio_mark(code == option_code)
					nendo.text(
						settings_translation_label(ui, menu, option_code),
						{font = FONT_BODY, size = 12, color = TEXT},
					)
				}
			}
		}
		scrollbar(nendo.id("TranslationLanguageList"))
	}
}

@(private)
settings_translation_action :: proc(ui: ^Ui_State, id: string) -> bool {
	when !TRANSLATION_AVAILABLE {return false}
	if ui.settings_section != .General || ui.settings_tab != 1 {return false}
	switch id {
	case "TgTranslation":
		ui.prefs.translation_enabled = !ui.prefs.translation_enabled
		translation_clear(ui)
		ui.translation.language_menu = 0
		save_settings(ui)
	case "TgTranslationAuto":
		if !ui.prefs.translation_enabled {return false}
		ui.prefs.translation_auto = !ui.prefs.translation_auto
		translation_clear(ui)
		save_settings(ui)
	case "TranslationTerms":
		open_external("https://ai.google.dev/gemma/terms")
	case "TranslationPolicy":
		open_external("https://ai.google.dev/gemma/prohibited_use_policy")
	case "TranslationSource", "TranslationTarget":
		if !ui.prefs.translation_enabled {return false}
		menu := id == "TranslationSource" ? 1 : 2
		ui.translation.language_menu = ui.translation.language_menu == menu ? 0 : menu
		ui.focus = .Compose
		kb_focus = id
		if ui.translation.language_menu != 0 {
			code := menu == 1 ? ui.prefs.translation_source : ui.prefs.translation_target
			index := 0
			for language, i in TRANSLATION_LANGUAGES {if language.code == code {index = i + 1; break}}
			ui.translation.language_choice = index
			ui.settings_anchor = "TranslationLanguageList"
			ui.settings_scroll_pending = true
		} else {
			settings_translation_close(ui, menu)
		}
	case:
		return false
	}
	return true
}

@(private)
settings_translation_select :: proc(ui: ^Ui_State, index: int) {
	menu := ui.translation.language_menu
	code := index == 0 ? "" : TRANSLATION_LANGUAGES[index - 1].code
	pref := menu == 1 ? &ui.prefs.translation_source : &ui.prefs.translation_target
	if pref^ != code {
		translation_clear(ui)
		delete(pref^)
		pref^ = strings.clone(code)
		save_settings(ui)
	}
	settings_translation_close(ui, menu)
}

@(private)
settings_translation_close :: proc(ui: ^Ui_State, menu: int) {
	ui.translation.language_menu = 0
	kb_focus = menu == 1 ? "TranslationSource" : "TranslationTarget"
	ui.settings_anchor = menu == 1 ? "RowTranslationSource" : "RowTranslationTarget"
	ui.settings_scroll_pending = true
}

@(private)
settings_translation_keys :: proc(ui: ^Ui_State) -> bool {
	when !TRANSLATION_AVAILABLE {return false}
	if !ui.prefs.translation_enabled ||
	   ui.settings_section != .General ||
	   ui.settings_tab != 1 ||
	   ui.translation.language_menu == 0 {return false}
	index := ui.translation.language_choice
	if rl.IsKeyPressed(.ENTER) ||
	   rl.IsKeyPressed(.SPACE) {settings_translation_select(ui, index); return true}
	if rl.IsKeyPressed(
		.TAB,
	) {settings_translation_close(ui, ui.translation.language_menu); return false}
	if rl.IsKeyPressed(
		.UP,
	) {index = max(0, index - 1)} else if rl.IsKeyPressed(.DOWN) {index = min(len(TRANSLATION_LANGUAGES), index + 1)} else if rl.IsKeyPressed(.HOME) {index = 0} else if rl.IsKeyPressed(.END) {index = len(TRANSLATION_LANGUAGES)} else {return false}
	ui.translation.language_choice = index
	scroll_into_view(
		nendo.id("TranslationLanguageList"),
		nendo.id(fmt.tprintf("TranslationLanguage%d", index)),
	)
	return true
}

@(private)
handle_settings_translation :: proc(ui: ^Ui_State) -> bool {
	when !TRANSLATION_AVAILABLE {return false}
	if ui.settings_tab != 1 {return false}
	for id in ([]string{"TranslationSource", "TranslationTarget", "TranslationTerms", "TranslationPolicy"}) {
		if clicked(id) {return settings_translation_action(ui, id)}
	}
	if ui.prefs.translation_enabled && ui.translation.language_menu != 0 {
		for i in 0 ..= len(TRANSLATION_LANGUAGES) {
			if clicked(
				fmt.tprintf("TranslationLanguage%d", i),
			) {settings_translation_select(ui, i); return true}
		}
		if !nendo.pointer_over(
			nendo.id("TranslationLanguageList"),
		) {ui.translation.language_menu = 0}
	}
	return false
}
