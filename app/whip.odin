package main

import "core:fmt"
import "core:os"
import "core:strings"

import marmot "../marmot"
import "nendo"
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
		ui.show_members, ui.group_files_open, ui.search_open = false, false, false
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
		if nendo.pointer_over(nendo.id("WhipProjectAvatar", project.id)) {
			if photo_pick_begin(ui, .Whip, project.dir) {rl.OpenFileDialog(false)}
			return true
		}
		if nendo.pointer_over(nendo.id("WhipProject", project.id)) {
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
			if nendo.pointer_over(nendo.id("WhipTabClose", tab.id)) {
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
		if nendo.pointer_over(nendo.id("WhipTab", tab.id)) {
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
	if nendo.box(nendo.id("WhipTabBar"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(tap_size() ? 48 : 32),
		align = {y = .Center},
		padding = {left = 8, right = 8},
		gap = 6,
		color = RAIL_BG,
		border = {color = DIVIDER, width = {bottom = 1}},
	},
	) {
		if nendo.box(nendo.id("WhipWorkspaceIdentity"))(
		{
			width = single_pane() ? nendo.fixed(22) : nendo.grow(max = 144),
			gap = 6,
			align = {y = .Center},
			clip = {x = true},
		},
		) {
			if nendo.box(nendo.id("WhipWorkspaceIcon"))(
			{align = {y = .Center}},
			) {nendo.text("\ue795", {font = FONT_ICON, size = 14, color = TEXT_DIM})}
			if nendo.box(nendo.id("WhipWorkspaceLabels"))(
			{width = nendo.grow(), clip = {x = true}},
			) {
				nendo.text(
					project_name,
					{font = FONT_TITLE, size = 13, color = TEXT, wrap = .None},
				)
			}
			if hovered() {
				cursor_raise(.Pointer)
				tooltip(fmt.tprintf("%s\n%s", project_name, project_dir))
			}
		}
		if nendo.box(nendo.id("WhipTabs"))(
		{width = nendo.grow(), gap = 2, align = {y = .Center}, clip = {x = true, scroll = true}},
		) {
			for tab, i in rl.WhipTabs() {
				active := tab.id == ui.whip_tabs[ui.whip_project]
				drag := ui.whip_tab_drag
				moving := drag.active && drag.tab == tab.id
				before := drag.active && drag.slot == i
				after :=
					drag.active && drag.slot == len(rl.WhipTabs()) && i == len(rl.WhipTabs()) - 1
				if nendo.box(nendo.id("WhipTab", tab.id))(
				{
					width = single_pane() ? nendo.fixed(180) : nendo.fit(max = 180),
					height = nendo.fixed(tap_size() ? tap_min() : 26),
					padding = {left = 8, right = 4},
					gap = 5,
					align = {y = .Center},
					color = active || moving ? SELECTED : (hovered() ? HOVER : {}),
					radius = rr(6),
					border = {
						color = active || before || after ? ACCENT : nendo.Color{},
						width = {
							bottom = 2,
							left = before ? u16(2) : 0,
							right = after ? u16(2) : 0,
						},
					},
				},
				) {
					if drag.active {cursor_raise(.Grabbing)} else if hovered() {cursor_raise(.Pointer)}
					if nendo.box(nendo.id("WhipTabLabel", tab.id))(
					{width = nendo.grow(), clip = {x = true}},
					) {
						nendo.text(
							fmt.tprintf("%d  %s", i + 1, tab.name),
							{
								font = FONT_TITLE,
								size = 12,
								color = active ? TEXT : TEXT_DIM,
								wrap = .None,
							},
						)
					}
					if ui.whip_tab_op == .None {
						if nendo.box(nendo.id("WhipTabClose", tab.id))(
						{
							width = nendo.fixed(tap_size() ? tap_min() : 16),
							height = nendo.fixed(tap_size() ? tap_min() : 18),
							align = {x = .Center, y = .Center},
							color = hovered() ? HOVER : {},
							radius = rr(4),
						},
						) {
							nendo.text(
								"×",
								{
									font = FONT_BODY,
									size = 13,
									color = hovered() ? DANGER : TEXT_LO,
								},
							)
							if hovered() {tooltip(tr("Close tab"))}
						}
					}
					unread_badge(nendo.id("WhipTabBadge", tab.id), u64(tab.waiting))
				}
			}
		}
		if ui.whip_tab_op == .None {
			if nendo.box(nendo.id("WhipNewTab"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 28),
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : ROW_BG,
				radius = rr(8),
			},
			) {
				nendo.text("+", {font = FONT_BODY, size = 16, color = TEXT})
				if hovered() {
					cursor_raise(.Pointer)
					tooltip(tr("New tab"))
				}
			}
		}
		if ui.whip_tab_op != .None || whip_pane_work {
			if nendo.box(nendo.id("WhipWorkspaceBusy"))(
			{
				width = nendo.fixed(min(240, max(page_w(ui) - 16, 0))),
				height = nendo.fit(),
				direction = .Column,
				padding = nendo.pad(10),
				gap = 6,
				floating = {
					attach_to = .Parent,
					z = 9,
					pointer = .Passthrough,
					offset = {-8, 4},
					attach = {element = .Right_Top, parent = .Right_Bottom},
				},
				color = PANEL,
				radius = rr(6),
				border = {color = DIVIDER, width = bw()},
			},
			) {
				nendo.text(
					ui.whip_tab_op == .None ? tr("Opening Whip…") : (ui.whip_tab_op == .New ? tr("Creating tab…") : tr("Closing tab…")),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
				nendo.text(
					tr("Progress is indeterminate."),
					{font = FONT_BODY, size = 11, color = TEXT_LO},
				)
				busy_bar("WhipTabBusy")
			}
		}
	}
	scrollbar(nendo.id("WhipTabs"))
}

@(private)
whip_inbox_progress :: proc(ui: ^Ui_State) {
	if !rl.WhipAvailable() {return}
	if status := rl.WhipState(); status == .Idle || status == .Starting {
		nendo.text(tr("Opening Whip…"), {font = FONT_BODY, size = 12, color = TEXT_DIM})
		nendo.text(
			tr("Progress is indeterminate."),
			{font = FONT_BODY, size = 11, color = TEXT_LO},
		)
		busy_bar("WhipInboxBusy")
	} else if status == .Failed {
		nendo.text(
			tr("Couldn't open Whip. Please try again."),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		micro_button("WhipRailRetry", tr("Try again"))
	}
	if ui.whip_picking_project || ui.whip_creating {
		nendo.text(
			ui.whip_picking_project ? tr("Choose a project folder.") : tr("Creating project…"),
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
		nendo.text(
			tr("Progress is indeterminate."),
			{font = FONT_BODY, size = 11, color = TEXT_LO},
		)
		busy_bar("WhipCreateBusy")
	}
	if ui.whip_avatar_job != nil {
		nendo.text(
			ui.whip_avatar_job.loading ? tr("Preparing project photo…") : tr("Saving project photo…"),
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
		nendo.text(
			tr("Progress is indeterminate."),
			{font = FONT_BODY, size = 11, color = TEXT_LO},
		)
		busy_bar("WhipAvatarBusy")
	}
}

@(private)
whip_project_row :: proc(ui: ^Ui_State, project: rl.Whip_Project) {
	home := os.get_env("HOME", context.temp_allocator)
	active := ui.whip_open && project.id == ui.whip_project
	if nendo.box(nendo.id("WhipProject", project.id))(
	{
		width = nendo.grow(),
		height = nendo.fixed(chat_row_height()),
		gap = 8,
		align = {y = .Center},
		padding = {right = 8},
		color = active ? SELECTED : (hovered() ? HOVER : {}),
		radius = rr(6),
		border = project.navigating ? kb_ring(ACCENT) : nendo.Border{},
	},
	) {
		if hovered() {cursor_raise(.Pointer)}
		if nendo.box(nendo.id("WhipProjectBar", project.id))(
		{
			width = nendo.fixed(3),
			height = nendo.grow(),
			color = active ? ACCENT : {},
			radius = rr(2),
		},
		) {}
		whip_project_avatar(ui, project.id, project.dir, project.name, 36)
		if nendo.pointer_over(nendo.id("WhipProjectAvatar", project.id)) {
			tooltip(tr("Change project avatar"))
		}
		if nendo.box(nendo.id("WhipProjectLabels", project.id))(
		{
			width = nendo.grow(),
			direction = .Column,
			gap = 4,
			padding = {left = 2},
			clip = {x = true},
		},
		) {
			if nendo.box(nendo.id("WhipProjectTitle", project.id))(
			{gap = 6, align = {y = .Center}},
			) {
				nendo.text(
					project.name,
					{font = FONT_TITLE, size = 14, color = TEXT, wrap = .None},
				)
				if nendo.box(nendo.id("WhipProjectIcon", project.id))({}) {
					nendo.text("\ue795", {font = FONT_ICON, size = 11, color = TEXT_DIM})
					if hovered() {tooltip(tr("Terminal"))}
				}
				if ui.prefs.pinned[inbox_terminal_key(project.dir)] {
					nendo.text(ICON_PIN, {font = FONT_ICON, size = 10, color = TEXT_LO})
				}
			}
			dir := project.dir
			if home != "" &&
			   strings.has_prefix(dir, home) &&
			   (len(dir) == len(home) || dir[len(home)] == '/') {
				dir = fmt.tprintf("~%s", dir[len(home):])
			}
			nendo.text(dir, {font = FONT_BODY, size = 11, color = TEXT_DIM, wrap = .None})
		}
		if nendo.box(nendo.id("WhipProjectCount", project.id))(
		{direction = .Column, gap = 4, padding = {right = 4}},
		) {
			nendo.text(
				fmt.tprintf(
					tr(project.tabs == 1 ? N_("%d terminal") : N_("%d terminals")),
					project.tabs,
				),
				{font = FONT_BODY, size = 11, color = TEXT_LO},
			)
			if project.waiting > 0 {
				nendo.text(
					fmt.tprintf(tr("%d waiting"), project.waiting),
					{font = FONT_BODY, size = 11, color = WARNING},
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
	if nendo.box(nendo.id("WhipPage"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		align = {x = .Center, y = .Center},
		gap = 12,
		padding = nendo.pad(3),
		color = BG,
		clip = {x = true, y = true},
	},
	) {
		if status == .Ready {
			whip_pane_tree(ui)
		} else if status == .Missing {
			nendo.text(
				tr("This project is no longer available."),
				{font = FONT_BODY, size = 14, color = TEXT_DIM},
			)
		} else if status == .Failed {
			nendo.text(
				tr("Couldn't open Whip. Please try again."),
				{font = FONT_BODY, size = 14, color = TEXT_DIM},
			)
			micro_button("WhipRetry", tr("Try again"))
		} else {
			nendo.text(tr("Opening Whip…"), {font = FONT_BODY, size = 14, color = TEXT_DIM})
			nendo.text(
				tr("Progress is indeterminate."),
				{font = FONT_BODY, size = 12, color = TEXT_LO},
			)
			busy_bar("WhipBusy")
		}
	}
}
