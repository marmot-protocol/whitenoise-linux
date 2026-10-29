package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
whip_project_modal :: proc(ui: ^Ui_State) {
	busy := ui.whip_edit_job != nil
	if clay.UI(clay.ID("WhipProjectModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("WhipProjectModal"), 480))},
			padding = clay.PaddingAll(20),
			childGap = 16,
		},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("WhipProjectModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text(tr("Edit project"), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
		if clay.UI(clay.ID("WhipProjectBody"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {
					width = clay.SizingGrow(),
					height = clay.SizingFit({max = max(60, modal_h(540) - 132 - (busy ? 74 : 0))}),
				},
				childGap = 10,
				padding = {right = 6, bottom = 4},
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			clay.Text(
				tr("Project name"),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM},
			)
			settings_input(
				ui,
				"WhipProjectName",
				&ui.whip_edit_name,
				tr("Project name"),
				!busy && ui.focus == .WhipProjectName,
			)
			clay.Text(
				tr("Root folder"),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM},
			)
			settings_input(
				ui,
				"WhipProjectPath",
				&ui.whip_edit_path,
				tr("e.g. ~/Work/project"),
				!busy && ui.focus == .WhipProjectPath,
			)
			clay.Text(
				tr("This changes White Noise project metadata, not running shells."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
			)
			if ui.whip_edit_error != "" {
				clay.Text(
					ui.whip_edit_error,
					{fontId = FONT_BODY, fontSize = 13, textColor = DANGER},
				)
			}
		}
		scrollbar(clay.ID("WhipProjectBody"), 14)
		if busy {
			if clay.UI(clay.ID("WhipProjectProgress"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow()},
					childGap = 6,
				},
			},
			) {
				clay.Text(
					tr("Checking project folder..."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
				clay.Text(
					tr("Progress is indeterminate."),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
				)
				busy_bar("WhipProjectBusy")
			}
		}
		if clay.UI(clay.ID("WhipProjectActions"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}},
		) {
			if clay.UI(clay.ID("WhipProjectActionsGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			folder_action("WhipProjectCancel", tr("Cancel"))
			if busy {
				if clay.UI(clay.ID("WhipProjectSave"))(
				{
					layout = {
						sizing = {height = clay.SizingFixed(36)},
						padding = {left = 14, right = 14},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = ROW_BG,
					cornerRadius = rr(9),
				},
				) {
					clay.Text(
						tr("Save"),
						{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_LO},
					)
				}
			} else {
				folder_action("WhipProjectSave", tr("Save"), true)
			}
		}
	}
}

@(private)
whip_project_input :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) ||
	   clicked("WhipProjectCancel") ||
	   (mouse_released() && !clay.PointerOver(clay.ID("WhipProjectModal"))) {
		whip_project_edit_close(ui)
		return
	}
	if ui.whip_edit_job != nil {
		for rl.GetCharPressed() != 0 {}
		return
	}
	if field_mouse(ui, &ui.whip_edit_name, "WhipProjectName", 14) {ui.focus = .WhipProjectName}
	if field_mouse(ui, &ui.whip_edit_path, "WhipProjectPath", 14) {ui.focus = .WhipProjectPath}
	if _, moved := tab_focus([]Focus{.WhipProjectName, .WhipProjectPath}, &ui.focus); moved {
		id := ui.focus == .WhipProjectPath ? "WhipProjectPath" : "WhipProjectName"
		scroll_into_view(clay.ID("WhipProjectBody"), clay.ID(id))
	}
	buf := ui.focus == .WhipProjectPath ? &ui.whip_edit_path : &ui.whip_edit_name
	edit_text(ui, buf)
	if clicked("WhipProjectSave") || rl.IsKeyPressed(.ENTER) {
		whip_project_save(ui)
	}
}
