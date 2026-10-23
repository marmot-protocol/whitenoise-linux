package main

import "core:fmt"
import "core:os"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Whip_Payload :: struct {
	kind: Model_Kind,
	pane: u32,
}

@(private)
whip_pane_work: bool

@(private)
Whip_Tab_Op :: enum {
	None,
	New,
	Close,
}

@(private)
whip_controls :: proc(ui: ^Ui_State) {
	control := rl.WhipControlPoll()
	switch control.work {
	case .New_Tab:
		ui.whip_tab_op, ui.whip_tab_project = .New, ui.whip_project
	case .New_Project:
		ui.whip_creating = true
	case .New_Pane:
		whip_pane_work = true
	case .Complete:
		ui.whip_tab_op, ui.whip_creating = .None, false
		whip_pane_work = false
	case .None:
	}
	if control.selection {
		ui.whip_project, ui.whip_detail = control.project, true
		if control.tab != 0 {ui.whip_tabs[control.project] = control.tab}
	}
	if control.sidebar {toggle_rail(ui)}
	if control.projects {
		if single_pane() {ui.whip_detail = false} else if rail_narrow(ui) {toggle_rail(ui)}
	}
	if control.detach {ui.page = .Chats}
	if ui.page != .Whip {whip_pane_work = false}
}

@(private)
whip_sync_tabs :: proc(ui: ^Ui_State) {
	tabs := rl.WhipTabs()
	if len(tabs) == 0 {return}
	chosen := ui.whip_tabs[ui.whip_project]
	next := tabs[0].id
	for tab in tabs {
		if tab.id == chosen {return}
		if tab.active {next = tab.id}
	}
	ui.whip_tabs[ui.whip_project] = next
}

@(private)
whip_tabbar :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("WhipTabBar"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
			childAlignment = {y = .Center},
			childGap = 6,
			padding = clay.PaddingAll(6),
		},
		backgroundColor = PANEL,
		border = {color = DIVIDER, width = {bottom = u16(BORDER_W)}},
	},
	) {
		if clay.UI(clay.ID("WhipTabs"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, childGap = 4},
			clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for tab, i in rl.WhipTabs() {
				active := tab.id == ui.whip_tabs[ui.whip_project]
				if clay.UI(clay.ID("WhipTab", tab.id))(
				{
					layout = {
						sizing = {
							width = clay.SizingFit({max = 220}),
							height = clay.SizingFixed(32),
						},
						padding = {left = 10, right = 6},
						childGap = 8,
						childAlignment = {y = .Center},
					},
					backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
					cornerRadius = rr(6),
				},
				) {
					if hovered() {cursor_raise(.Pointer)}
					if clay.UI(clay.ID("WhipTabLabel", tab.id))({clip = {horizontal = true}}) {
						clay.Text(
							fmt.tprintf("%d  %s", i + 1, tab.name),
							{
								fontId = FONT_TITLE,
								fontSize = 13,
								textColor = active ? ACCENT : TEXT_DIM,
								wrapMode = .None,
							},
						)
					}
					if ui.whip_tab_op == .None {
						if clay.UI(clay.ID("WhipTabClose", tab.id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(22),
									height = clay.SizingFixed(24),
								},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = hovered() ? HOVER : {},
							cornerRadius = rr(4),
						},
						) {
							clay.Text(
								"×",
								{fontId = FONT_BODY, fontSize = 16, textColor = TEXT_DIM},
							)
							if hovered() {tooltip(tr("Close tab"))}
						}
					}
					unread_badge(clay.ID("WhipTabBadge", tab.id), u64(tab.waiting))
				}
			}
		}
		if ui.whip_tab_op == .None {micro_button("WhipNewTab", tr("New tab"))}
	}
	if ui.whip_tab_op != .None {
		clay.Text(
			ui.whip_tab_op == .New ? tr("Creating tab…") : tr("Closing tab…"),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar("WhipTabBusy")
	}
}

@(private)
whip_rail :: proc(ui: ^Ui_State) {
	projects := rl.WhipProjects()
	if clay.UI(clay.ID("WhipRailHead"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(32)},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		clay.Text(tr("Projects"), {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
		clay.Text(
			fmt.tprintf("%d", len(projects)),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
		)
		if clay.UI(clay.ID("WhipRailHeadGap"))(
		{layout = {sizing = {width = clay.SizingGrow()}}},
		) {}
		if !ui.whip_picking_project && !ui.whip_creating {
			micro_button("WhipNewProject", tr("New project"))
		}
	}
	if ui.whip_picking_project || ui.whip_creating {
		clay.Text(
			ui.whip_picking_project ? tr("Choose a project folder.") : tr("Creating project…"),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar("WhipCreateBusy")
	}
	if ui.whip_avatar_job != nil {
		clay.Text(
			ui.whip_avatar_job.loading ? tr("Preparing project photo…") : tr("Saving project photo…"),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar("WhipAvatarBusy")
	}
	if clay.UI(clay.ID("WhipProjects"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 2,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		if len(projects) == 0 {
			status := rl.WhipState()
			if status == .Failed {
				clay.Text(
					tr("Couldn't open Whip. Please try again."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
				micro_button("WhipRailRetry", tr("Try again"))
			} else if status == .Ready || status == .Missing {
				clay.Text(
					tr("No projects yet"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			} else {
				clay.Text(
					tr("Opening Whip…"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
				clay.Text(
					tr("Progress is indeterminate."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
				)
				busy_bar("WhipRailBusy")
			}
		}
		home := os.get_env("HOME", context.temp_allocator)
		for project in projects {
			active := project.id == ui.whip_project
			if clay.UI(clay.ID("WhipProject", project.id))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(60)},
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
				cornerRadius = rr(6),
				border = project.navigating ? kb_ring(ACCENT) : clay.BorderElementConfig{},
			},
			) {
				if hovered() {cursor_raise(.Pointer)}
				if clay.UI(clay.ID("WhipProjectBar", project.id))(
				{
					layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}},
					backgroundColor = active ? ACCENT : {},
					cornerRadius = rr(2),
				},
				) {}
				whip_project_avatar(ui, project.id, project.dir, project.name, 36)
				if clay.PointerOver(clay.ID("WhipProjectAvatar", project.id)) {
					tooltip(tr("Change project avatar"))
				}
				if clay.UI(clay.ID("WhipProjectLabels", project.id))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 4,
					},
					clip = {horizontal = true},
				},
				) {
					clay.Text(
						project.name,
						{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
					)
					dir := project.dir
					if home != "" &&
					   strings.has_prefix(dir, home) &&
					   (len(dir) == len(home) || dir[len(home)] == '/') {
						dir = fmt.tprintf("~%s", dir[len(home):])
					}
					clay.Text(
						dir,
						{
							fontId = FONT_BODY,
							fontSize = 11,
							textColor = TEXT_DIM,
							wrapMode = .None,
						},
					)
				}
				if clay.UI(clay.ID("WhipProjectCount", project.id))(
				{layout = {padding = {right = 10}}},
				) {
					if project.waiting > 0 {
						unread_badge(clay.ID("WhipProjectBadge", project.id), u64(project.waiting))
					} else {
						clay.Text(
							fmt.tprintf("%d", project.tabs),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
						)
					}
				}
			}
		}
	}
	scrollbar(clay.ID("WhipProjects"))
}

@(private)
whip_pane :: proc(ui: ^Ui_State) {
	anim_moving += 1
	status := rl.WhipState()
	if ui.whip_project == 0 && status == .Ready {
		centered_note("WhipPickProject", tr("Select a project"), "")
		return
	}
	if ui.whip_project != 0 && status != .Missing {whip_tabbar(ui)}
	if whip_pane_work {
		clay.Text(tr("Opening Whip…"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar("WhipPaneBusy")
	}
	if clay.UI(clay.ID("WhipPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 12,
		},
		clip = {horizontal = true, vertical = true},
	},
	) {
		if status == .Ready {whip_pane_tree(); return}
		clay.Text("Whip", {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
		if status == .Missing {
			clay.Text(
				tr("This project is no longer available."),
				{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
			)
		} else if status == .Failed {
			clay.Text(
				tr("Couldn't open Whip. Please try again."),
				{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
			)
			micro_button("WhipRetry", tr("Try again"))
		} else {
			clay.Text(
				tr("Opening Whip…"),
				{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
			)
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			busy_bar("WhipBusy")
		}
	}
}
