package main

import "core:fmt"
import "core:os"
import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Whip_Payload :: struct {
	kind:      Model_Kind,
	pane:      u32,
	input_top: f32,
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
Whip_Open_Intent :: enum {
	User,
	Restore,
}

@(private)
whip_open_project :: proc(ui: ^Ui_State, id: u32, intent: Whip_Open_Intent = .User) {
	if !rl.WhipAvailable() || id == 0 {return}
	if intent == .User {whip_workspace_navigation(ui)}
	if !ui.whip_open {
		reading_remember(ui)
		stash_draft(ui)
		stash_staged(ui)
		thread_clear(ui)
		ui.selected = -1
		ui.editing = ""
		ui.show_members, ui.group_files_open, ui.search_open, ui.issues_open =
			false, false, false, false
		ui.row_menu = -1
	}
	ui.page, ui.whip_open, ui.whip_project = .Chats, true, id
	ui.focus = .Compose
	if ui.chat_filter == .Groups {ui.chat_filter = .Chats}
	folder := ""
	rows := inbox_rows(ui, nil, []u32{id})
	sections, _ := inbox_sections(ui, rows)
	for section, i in sections {
		if section.count > 0 && i < len(ui.prefs.folders) {folder = ui.prefs.folders[i]; break}
	}
	if ui.prefs.collapsed_folders[folder] {
		ui.prefs.collapsed_folders[folder] = false
		ui.settings_dirty = true
	}
}

@(private)
whip_new_project :: proc(ui: ^Ui_State) -> bool {
	if !rl.WhipAvailable() || ui.whip_picking_project || ui.whip_creating {return false}
	whip_workspace_navigation(ui)
	if rl.FileDialogPending() || photo_input_capture(ui) {
		set_status(
			ui,
			tr("Couldn't choose a folder. Close your open file picker and try again."),
			.Info,
		)
		return false
	}
	ui.page = .Chats
	if single_pane() && phone_detail(ui) {
		stash_draft(ui)
		stash_staged(ui)
		phone_back_action(ui)
	}
	ui.whip_picking_project = true
	rl.OpenFolderDialog()
	return true
}

@(private)
whip_rail_matches :: proc(ui: ^Ui_State) -> []u32 {
	if !rl.WhipAvailable() || ui.chat_filter == .Groups {return nil}
	projects := rl.WhipProjects()
	matched := make([]u32, len(projects), context.temp_allocator)
	query := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
	count := 0
	for project in projects {
		if ui.chat_filter == .Unread && project.waiting == 0 {continue}
		if query != "" &&
		   !strings.contains(strings.to_lower(project.name, context.temp_allocator), query) &&
		   !strings.contains(
				   strings.to_lower(project.dir, context.temp_allocator),
				   query,
			   ) {continue}
		matched[count] = project.id
		count += 1
	}
	return matched[:count]
}

@(private)
whip_visibility :: proc(ui: ^Ui_State) -> rl.Whip_Visibility {
	if !rl.WhipAvailable() ||
	   len(ui.accounts) == 0 ||
	   ui.page != .Chats ||
	   ui.add_account_open ||
	   ui.new_chat_open ||
	   modal_open(ui) {return .Hidden}
	if ui.whip_open {return ui.focus == .Filter || ui.focus == .Whip || ui.whip_tab_drag.tab != 0 ? .Unfocused : .Visible}
	if ui.selected < 0 && ui.focus != .Filter {
		for project in rl.WhipProjects() {if project.navigating {return .Navigation}}
	}
	return .Projects
}

@(private)
whip_focus_restore :: proc(ui: ^Ui_State) {
	if ui.whip_return_focus != 0 {
		pane, live := rl.WhipPaneInfo(ui.whip_return_focus)
		// Surface ownership changes in WhipFrame before native focus can move.
		if live &&
		   ui.whip_open &&
		   ui.focus == .Compose &&
		   pane.project == ui.whip_project &&
		   pane.tab == ui.whip_tabs[ui.whip_project] {
			rl.WhipPaneAct(.Focus, pane.id)
		}
		ui.whip_return_focus = 0
	}
}

@(private)
whip_controls :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	control := rl.WhipControlPoll()
	if control.focused && !ui.whip_edit_open {
		if i := whip_attach_index(ui, control.pane); i >= 0 {
			if whip_attach_visible(
				ui,
				ui.whip_attachments[i],
			) {ui.whip_focus, ui.focus = control.pane, .Whip}
		} else {whip_attach_release_focus(ui); ui.focus = .Compose}
	}
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
	if ui.whip_edit_open {return}
	if control.selection {
		whip_open_project(ui, control.project)
		if control.tab != 0 {ui.whip_tabs[control.project] = control.tab}
	}
	if control.project_step != 0 {
		inbox_cycle(ui, client, control.project_step)
	}
	if control.sidebar {toggle_rail(ui)}
	if control.projects {
		if single_pane() {ui.whip_open = false} else if rail_narrow(ui) {toggle_rail(ui)}
	}
	if control.detach {ui.whip_open = false}
	if !ui.whip_open {whip_pane_work = false}
}

@(private)
whip_inbox_input :: proc(ui: ^Ui_State) -> bool {
	if ui.page != .Chats ||
	   ui.new_chat_open ||
	   ui.add_account_open ||
	   ui.row_menu >= 0 ||
	   ui.folder_menu_open ||
	   modal_open(ui) {ui.whip_tab_drag = {}; return false}
	if whip_tab_input(ui) {return true}
	if !mouse_released() {return false}
	if clicked("WhipRetry") || clicked("WhipRailRetry") {rl.WhipClose(); return true}
	for project in rl.WhipProjects() {
		if clay.PointerOver(clay.ID("WhipProjectAvatar", project.id)) {
			if photo_pick_begin(ui, .Whip, project.dir) {rl.OpenFileDialog(false)}
			return true
		}
		if clay.PointerOver(clay.ID("WhipProject", project.id)) {
			whip_open_project(ui, project.id)
			return true
		}
	}
	if !ui.whip_open {return false}
	if clicked("WhipWorkspaceIdentity") {whip_project_edit_open(ui, ui.whip_project); return true}
	if ui.whip_tab_op == .None {
		if clicked("WhipNewTab") && rl.WhipTabChange(.New, ui.whip_project) {
			whip_workspace_navigation(ui)
			ui.whip_tab_op, ui.whip_tab_project = .New, ui.whip_project
			ui.focus = .Compose
			return true
		}
		for tab in rl.WhipTabs() {
			if clay.PointerOver(clay.ID("WhipTabClose", tab.id)) {
				whip_workspace_navigation(ui)
				if rl.WhipTabChange(
					.Close,
					tab.id,
				) {ui.whip_tab_op, ui.whip_tab_project = .Close, ui.whip_project; ui.focus = .Compose}
				return true
			}
		}
	}
	for tab in rl.WhipTabs() {
		if clay.PointerOver(clay.ID("WhipTab", tab.id)) {
			whip_workspace_navigation(ui)
			ui.whip_tabs[ui.whip_project] = tab.id
			ui.focus = .Compose
			return true
		}
	}
	return false
}

@(private)
whip_sync_tabs :: proc(ui: ^Ui_State) {
	state := rl.WhipState()
	if state != .Ready && state != .Missing {return}
	whip_tab_order(ui)
	tabs := rl.WhipTabs()
	if len(tabs) == 0 {return}
	chosen := ui.whip_tabs[ui.whip_project]
	if chosen == 0 {
		if saved := whip_workspace_tab(ui, ui.whip_project); saved != 0 {
			ui.whip_tabs[ui.whip_project] = saved
			return
		}
	}
	next := tabs[0].id
	for tab in tabs {
		if tab.id == chosen {return}
		if tab.active {next = tab.id}
	}
	ui.whip_tabs[ui.whip_project] = next
}

@(private)
whip_tabbar :: proc(ui: ^Ui_State) {
	project_name, project_dir: string
	for project in rl.WhipProjects() {
		if project.id != ui.whip_project {continue}
		project_name, project_dir = project.name, project.dir
		break
	}
	if clay.UI(clay.ID("WhipTabBar"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(32)},
			childAlignment = {y = .Center},
			padding = {left = 8, right = 8},
			childGap = 6,
		},
		backgroundColor = RAIL_BG,
		border = {color = DIVIDER, width = {bottom = 1}},
	},
	) {
		if clay.UI(clay.ID("WhipWorkspaceIdentity"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({max = 144})},
				childGap = 6,
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		},
		) {
			if clay.UI(clay.ID("WhipWorkspaceIcon"))(
			{layout = {childAlignment = {y = .Center}}},
			) {clay.Text("\ue795", {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM})}
			if clay.UI(clay.ID("WhipWorkspaceLabels"))(
			{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
			) {
				clay.Text(
					project_name,
					{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
				)
			}
			if hovered() {
				cursor_raise(.Pointer)
				tooltip(fmt.tprintf("%s\n%s", project_name, project_dir))
			}
		}
		if clay.UI(clay.ID("WhipTabs"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 2,
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for tab, i in rl.WhipTabs() {
				active := tab.id == ui.whip_tabs[ui.whip_project]
				drag := ui.whip_tab_drag
				moving := drag.active && drag.tab == tab.id
				before := drag.active && drag.slot == i
				after :=
					drag.active && drag.slot == len(rl.WhipTabs()) && i == len(rl.WhipTabs()) - 1
				if clay.UI(clay.ID("WhipTab", tab.id))(
				{
					layout = {
						sizing = {
							width = clay.SizingFit({max = 180}),
							height = clay.SizingFixed(26),
						},
						padding = {left = 8, right = 4},
						childGap = 5,
						childAlignment = {y = .Center},
					},
					backgroundColor = active || moving ? SELECTED : (hovered() ? HOVER : {}),
					cornerRadius = rr(6),
					border = {
						color = active || before || after ? ACCENT : clay.Color{},
						width = {
							bottom = 2,
							left = before ? u16(2) : 0,
							right = after ? u16(2) : 0,
						},
					},
				},
				) {
					if drag.active {cursor_raise(.Grabbing)} else if hovered() {cursor_raise(.Pointer)}
					if clay.UI(clay.ID("WhipTabLabel", tab.id))({clip = {horizontal = true}}) {
						clay.Text(
							fmt.tprintf("%d  %s", i + 1, tab.name),
							{
								fontId = FONT_TITLE,
								fontSize = 12,
								textColor = active ? TEXT : TEXT_DIM,
								wrapMode = .None,
							},
						)
					}
					if ui.whip_tab_op == .None {
						if clay.UI(clay.ID("WhipTabClose", tab.id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(16),
									height = clay.SizingFixed(18),
								},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = hovered() ? HOVER : {},
							cornerRadius = rr(4),
						},
						) {
							clay.Text(
								"×",
								{
									fontId = FONT_BODY,
									fontSize = 13,
									textColor = hovered() ? DANGER : TEXT_LO,
								},
							)
							if hovered() {tooltip(tr("Close tab"))}
						}
					}
					unread_badge(clay.ID("WhipTabBadge", tab.id), u64(tab.waiting))
				}
			}
		}
		if ui.whip_tab_op == .None {
			if clay.UI(clay.ID("WhipNewTab"))(
			{
				layout = {
					sizing = {clay.SizingFixed(28), clay.SizingFixed(26)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : ROW_BG,
				cornerRadius = rr(8),
			},
			) {
				clay.Text("+", {fontId = FONT_BODY, fontSize = 16, textColor = TEXT})
				if hovered() {
					cursor_raise(.Pointer)
					tooltip(tr("New tab"))
				}
			}
		}
		if ui.whip_tab_op != .None || whip_pane_work {
			if clay.UI(clay.ID("WhipWorkspaceBusy"))(
			{
				layout = {
					sizing = {
						clay.SizingFixed(min(240, max(page_w(ui) - 16, 0))),
						clay.SizingFit(),
					},
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(10),
					childGap = 6,
				},
				floating = {
					attachTo = .Parent,
					zIndex = 9,
					pointerCaptureMode = .Passthrough,
					offset = {-8, 4},
					attachment = {element = .RightTop, parent = .RightBottom},
				},
				backgroundColor = PANEL,
				cornerRadius = rr(6),
				border = {color = DIVIDER, width = bw()},
			},
			) {
				clay.Text(
					ui.whip_tab_op == .None ? tr("Opening Whip…") : (ui.whip_tab_op == .New ? tr("Creating tab…") : tr("Closing tab…")),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
				clay.Text(
					tr("Progress is indeterminate."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
				)
				busy_bar("WhipTabBusy")
			}
		}
	}
}

@(private)
whip_inbox_progress :: proc(ui: ^Ui_State) {
	if !rl.WhipAvailable() {return}
	if status := rl.WhipState(); status == .Idle || status == .Starting {
		clay.Text(tr("Opening Whip…"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar("WhipInboxBusy")
	} else if status == .Failed {
		clay.Text(
			tr("Couldn't open Whip. Please try again."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		micro_button("WhipRailRetry", tr("Try again"))
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
}

@(private)
whip_project_row :: proc(ui: ^Ui_State, project: rl.Whip_Project) {
	home := os.get_env("HOME", context.temp_allocator)
	active := ui.whip_open && project.id == ui.whip_project
	if clay.UI(clay.ID("WhipProject", project.id))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(chat_row_height())},
			childGap = 10,
			childAlignment = {y = .Center},
			padding = {right = 8},
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
			if clay.UI(clay.ID("WhipProjectTitle", project.id))(
			{layout = {childGap = 6, childAlignment = {y = .Center}}},
			) {
				clay.Text(
					project.name,
					{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT, wrapMode = .None},
				)
				if clay.UI(clay.ID("WhipProjectIcon", project.id))({}) {
					clay.Text("\ue795", {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM})
					if hovered() {tooltip(tr("Terminal"))}
				}
				if ui.prefs.pinned[inbox_terminal_key(project.dir)] {
					clay.Text(ICON_PIN, {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_LO})
				}
			}
			dir := project.dir
			if home != "" &&
			   strings.has_prefix(dir, home) &&
			   (len(dir) == len(home) || dir[len(home)] == '/') {
				dir = fmt.tprintf("~%s", dir[len(home):])
			}
			clay.Text(
				dir,
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
			)
		}
		if clay.UI(clay.ID("WhipProjectCount", project.id))({layout = {padding = {right = 10}}}) {
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

@(private)
whip_pane :: proc(ui: ^Ui_State) {
	anim_moving += 1
	status := rl.WhipState()
	if ui.whip_project == 0 && status == .Ready {
		centered_note("WhipPickProject", tr("Select a project"), "")
		return
	}
	if ui.whip_project != 0 && status != .Missing {whip_tabbar(ui)}
	if clay.UI(clay.ID("WhipPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 12,
			padding = clay.PaddingAll(3),
		},
		backgroundColor = BG,
		clip = {horizontal = true, vertical = true},
	},
	) {
		if status == .Ready {
			whip_pane_tree(ui)
		} else if status == .Missing {
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
