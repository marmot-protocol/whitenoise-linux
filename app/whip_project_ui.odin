package main

import "nendo"
import rl "sdlrl"

@(private)
whip_project_modal :: proc(ui: ^Ui_State) {
	busy := ui.whip_edit_job != nil
	if nendo.box(nendo.id("WhipProjectModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("WhipProjectModal"), 480)),
		padding = nendo.pad(20),
		gap = 16,
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("WhipProjectModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		nendo.text(tr("Edit project"), {font = FONT_TITLE, size = 20, color = TEXT})
		if nendo.box(nendo.id("WhipProjectBody"))(
		{
			direction = .Column,
			width = nendo.grow(),
			height = nendo.fit(max = max(60, modal_h(540) - 132 - (busy ? 74 : 0))),
			gap = 10,
			padding = {right = 6, bottom = 4},
			clip = {y = true, scroll = true},
		},
		) {
			nendo.text(tr("Project name"), {font = FONT_TITLE, size = 13, color = TEXT_DIM})
			settings_input(
				ui,
				"WhipProjectName",
				&ui.whip_edit_name,
				tr("Project name"),
				!busy && ui.focus == .WhipProjectName,
			)
			nendo.text(tr("Root folder"), {font = FONT_TITLE, size = 13, color = TEXT_DIM})
			settings_input(
				ui,
				"WhipProjectPath",
				&ui.whip_edit_path,
				tr("e.g. ~/Work/project"),
				!busy && ui.focus == .WhipProjectPath,
			)
			nendo.text(
				tr("This changes White Noise project metadata, not running shells."),
				{font = FONT_BODY, size = 13, color = TEXT_LO},
			)
			if ui.whip_edit_error != "" {
				nendo.text(ui.whip_edit_error, {font = FONT_BODY, size = 13, color = DANGER})
			}
		}
		scrollbar(nendo.id("WhipProjectBody"), 14)
		if busy {
			if nendo.box(nendo.id("WhipProjectProgress"))(
			{direction = .Column, width = nendo.grow(), gap = 6},
			) {
				nendo.text(
					tr("Checking project folder..."),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
				nendo.text(
					tr("Progress is indeterminate."),
					{font = FONT_BODY, size = 12, color = TEXT_LO},
				)
				busy_bar("WhipProjectBusy")
			}
		}
		if nendo.box(nendo.id("WhipProjectActions"))({width = nendo.grow(), gap = 10}) {
			if nendo.box(nendo.id("WhipProjectActionsGap"))({width = nendo.grow()}) {}
			folder_action("WhipProjectCancel", tr("Cancel"))
			if busy {
				if nendo.box(nendo.id("WhipProjectSave"))(
				{
					height = nendo.fixed(36),
					padding = {left = 14, right = 14},
					align = {x = .Center, y = .Center},
					color = ROW_BG,
					radius = rr(9),
				},
				) {
					nendo.text(tr("Save"), {font = FONT_TITLE, size = 13, color = TEXT_LO})
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
	   (mouse_released() && !nendo.pointer_over(nendo.id("WhipProjectModal"))) {
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
		scroll_into_view(nendo.id("WhipProjectBody"), nendo.id(id))
	}
	buf := ui.focus == .WhipProjectPath ? &ui.whip_edit_path : &ui.whip_edit_name
	edit_text(ui, buf)
	if clicked("WhipProjectSave") || rl.IsKeyPressed(.ENTER) {
		whip_project_save(ui)
	}
}
