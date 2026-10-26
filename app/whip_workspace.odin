package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:strings"
import rl "sdlrl"

// Preferences own every string. Numeric IDs are usable only together with the
// connected server incarnation; neither saved commands nor SDK pointers persist.
@(private)
Whip_Workspace :: struct {
	account, folder: string,
	session:         [4]u64,
	pane:            u32,
	open:            bool,
	width, height:   f32,
}

@(private)
Whip_Saved_Tab :: struct {
	account, folder: string,
	session:         [4]u64,
	pane, tab:       u32,
}

@(private)
Whip_Saved_Placement :: struct {
	account, group_id, folder: string,
	session:                   [4]u64,
	pane:                      u32,
	bounds:                    clay.BoundingBox,
}

@(private)
whip_workspace_prefs_free :: proc(prefs: ^Prefs) {
	for item in prefs.whip_workspaces {delete(item.account); delete(item.folder)}
	for item in prefs.whip_selected_tabs {delete(item.account); delete(item.folder)}
	for item in prefs.whip_placements {delete(item.account); delete(item.group_id); delete(item.folder)}
	delete(prefs.whip_workspaces); prefs.whip_workspaces = nil
	delete(prefs.whip_selected_tabs); prefs.whip_selected_tabs = nil
	delete(prefs.whip_placements); prefs.whip_placements = nil
}

@(private)
whip_workspace_folder :: proc(project: u32) -> string {
	for item in rl.WhipProjects() {
		if item.id == project {return whip_avatar_key(item.dir).folder}
	}
	return ""
}

@(private)
whip_workspace_index :: proc(ui: ^Ui_State) -> int {
	for item, i in ui.prefs.whip_workspaces {if item.account == ui.account_ref {return i}}
	return -1
}

// A loading/missing identity is not evidence that a saved shell was closed.
@(private)
whip_workspace_match :: proc(
	pane: rl.Whip_Pane,
	session: [4]u64,
	folder, live_folder: string,
) -> (
	live, resolved: bool,
) {
	if pane.id == 0 {return false, true}
	if pane.session == ([4]u64{}) {return false, false}
	return session != ([4]u64{}) &&
		pane.session == session &&
		folder != "" &&
		folder == live_folder,
		true
}

@(private)
whip_workspace_live :: proc(
	pane: u32,
	session: [4]u64,
	folder: string,
) -> (
	info: rl.Whip_Pane,
	live, resolved: bool,
) {
	info, _ = rl.WhipPaneInfo(pane)
	live, resolved = whip_workspace_match(
		info,
		session,
		folder,
		whip_workspace_folder(info.project),
	)
	return info, live, resolved
}

// Consult before the host installs its first fallback. Metadata and tabs belong
// to the same observer projection; never apply that slice after project changes.
@(private)
whip_workspace_tab :: proc(ui: ^Ui_State, project: u32) -> u32 {
	if ui.whip_workspace_loaded || ui.account_ref == "" || project == 0 {return 0}
	folder := whip_workspace_folder(project)
	if folder == "" {return 0}
	for saved in ui.prefs.whip_selected_tabs {
		if saved.account != ui.account_ref || saved.folder != folder {continue}
		info, live, _ := whip_workspace_live(saved.pane, saved.session, saved.folder)
		if live && info.project == project && info.tab == saved.tab {return saved.tab}
	}
	return 0
}

@(private)
whip_workspace_navigation :: proc(ui: ^Ui_State) {
	ui.whip_workspace_pending = false
	ui.whip_return_focus = 0
}

// Arm only after ordinary last-chat restoration has finished. Explicit host
// navigation cancels this one shot while the observer is still connecting.
@(private)
whip_workspace_begin :: proc(ui: ^Ui_State) {
	ui.whip_workspace_pending = ui.prefs.restore_last_chat && ui.account_ref != ""
	ui.whip_workspace_page = ui.page
	ui.whip_workspace_selected = ui.selected
	ui.whip_workspace_project = ui.whip_project
	ui.whip_workspace_open = ui.whip_open
	ui.whip_workspace_filter = ui.chat_filter
	ui.whip_workspace_focus = ui.focus
	ui.whip_workspace_compose_hash = avatar_hash(string(ui.compose[:]))
	ui.whip_workspace_compose_len = len(ui.compose)
}

@(private)
whip_workspace_forget :: proc(ui: ^Ui_State, account: string, pane: u32, session: [4]u64) {
	for i := len(ui.prefs.whip_placements) - 1; i >= 0; i -= 1 {
		item := ui.prefs.whip_placements[i]
		if item.account != account || item.pane != pane || item.session != session {continue}
		delete(item.account); delete(item.group_id); delete(item.folder)
		ordered_remove(&ui.prefs.whip_placements, i)
		ui.settings_dirty = true
	}
}

@(private)
whip_workspace_save_placement :: proc(ui: ^Ui_State, item: Whip_Attachment) {
	info, live := rl.WhipPaneInfo(item.pane)
	if !live || info.session == ([4]u64{}) || info.session != item.session {return}
	folder := whip_workspace_folder(info.project)
	if folder == "" {return}
	for &saved in ui.prefs.whip_placements {
		if saved.account != item.account ||
		   saved.pane != item.pane ||
		   saved.session != item.session {continue}
		if saved.group_id == item.group_id &&
		   saved.bounds == item.bounds &&
		   saved.folder == folder {return}
		if saved.group_id !=
		   item.group_id {delete(saved.group_id); saved.group_id = strings.clone(item.group_id)}
		if saved.folder != folder {delete(saved.folder); saved.folder = strings.clone(folder)}
		saved.bounds = item.bounds
		ui.settings_dirty = true
		return
	}
	append(
		&ui.prefs.whip_placements,
		Whip_Saved_Placement {
			account = strings.clone(item.account),
			group_id = strings.clone(item.group_id),
			folder = strings.clone(folder),
			session = item.session,
			pane = item.pane,
			bounds = item.bounds,
		},
	)
	ui.settings_dirty = true
}

// Called by the existing settings snapshot. Warm frames compare POD and
// existing strings only; drag motion neither allocates nor schedules writes.
@(private)
whip_workspace_remember :: proc(ui: ^Ui_State) {
	if !ui.whip_workspace_loaded ||
	   ui.account_ref == "" ||
	   ui.whip_workspace_account != ui.account_ref {return}
	if ui.whip_attach_drag == 0 && ui.whip_attach_resize == 0 {
		for item in ui.whip_attachments {whip_workspace_save_placement(ui, item)}
	}
	i := whip_workspace_index(ui)
	if i < 0 {
		if !ui.whip_open &&
		   len(ui.whip_attachments) == 0 &&
		   ui.whip_dock_width == 0 &&
		   ui.whip_dock_height == 0 {return}
		append(&ui.prefs.whip_workspaces, Whip_Workspace{account = strings.clone(ui.account_ref)})
		i = len(ui.prefs.whip_workspaces) - 1
		ui.settings_dirty = true
	}
	workspace := &ui.prefs.whip_workspaces[i]
	if !ui.whip_dock_drag &&
	   !ui.whip_dock_release &&
	   (workspace.width != ui.whip_dock_width || workspace.height != ui.whip_dock_height) {
		workspace.width, workspace.height = ui.whip_dock_width, ui.whip_dock_height
		ui.settings_dirty = true
	}
	if workspace.open != ui.whip_open {workspace.open = ui.whip_open; ui.settings_dirty = true}
	if !ui.whip_open {return}
	folder := whip_workspace_folder(ui.whip_project)
	chosen := ui.whip_tabs[ui.whip_project]
	anchor: rl.Whip_Pane
	for pane in rl.WhipPanes() {
		if pane.project != ui.whip_project ||
		   pane.tab != chosen ||
		   pane.session == ([4]u64{}) ||
		   folder == "" {continue}
		if anchor.id == 0 || pane.focused {anchor = pane}
		if pane.focused {break}
	}
	if pane := anchor; pane.id != 0 {
		if workspace.folder != folder ||
		   workspace.session != pane.session ||
		   workspace.pane != pane.id {
			if workspace.folder !=
			   folder {delete(workspace.folder); workspace.folder = strings.clone(folder)}
			workspace.session, workspace.pane = pane.session, pane.id
			ui.settings_dirty = true
		}
		for &saved in ui.prefs.whip_selected_tabs {
			if saved.account != ui.account_ref || saved.folder != folder {continue}
			if saved.session != pane.session || saved.pane != pane.id || saved.tab != chosen {
				saved.session, saved.pane, saved.tab = pane.session, pane.id, chosen
				ui.settings_dirty = true
			}
			return
		}
		append(
			&ui.prefs.whip_selected_tabs,
			Whip_Saved_Tab {
				account = strings.clone(ui.account_ref),
				folder = strings.clone(folder),
				session = pane.session,
				pane = pane.id,
				tab = chosen,
			},
		)
		ui.settings_dirty = true
		return
	}
}

// Apply account ownership before layout/input, not after a new account's first
// click. Switching identities must not carry a previously visible shell along.
@(private)
whip_workspace_prepare :: proc(ui: ^Ui_State) {
	if ui.whip_workspace_account == ui.account_ref {return}
	had_account := ui.whip_workspace_account != ""
	pending := ui.whip_workspace_pending && !had_account
	whip_attach_clear(ui)
	if had_account {
		delete(ui.whip_tabs); ui.whip_tabs = nil
		ui.whip_open, ui.whip_project = false, 0
	}
	if ui.account_ref == "" {return}
	ui.whip_workspace_account = strings.clone(ui.account_ref)
	ui.whip_workspace_pending = pending
	if i := whip_workspace_index(ui); i >= 0 {
		ui.whip_dock_width = max(ui.prefs.whip_workspaces[i].width, 0)
		ui.whip_dock_height = max(ui.prefs.whip_workspaces[i].height, 0)
	}
}

// Compare the startup snapshot only while waiting; typing into an already
// focused composer counts as explicit interaction without copying its draft.
@(private)
whip_workspace_guard :: proc(ui: ^Ui_State) {
	if ui.whip_workspace_pending &&
	   (ui.page != ui.whip_workspace_page ||
			   ui.selected != ui.whip_workspace_selected ||
			   ui.whip_project != ui.whip_workspace_project ||
			   ui.whip_open != ui.whip_workspace_open ||
			   ui.focus != ui.whip_workspace_focus ||
			   ui.chat_filter != ui.whip_workspace_filter) {
		ui.whip_workspace_pending = false
	}
	if ui.whip_workspace_pending &&
	   (len(ui.compose) != ui.whip_workspace_compose_len ||
			   avatar_hash(string(ui.compose[:])) != ui.whip_workspace_compose_hash) {
		ui.whip_workspace_pending = false
	}
}

// Run after observer projection and native controls. Only a complete catalog
// can prune durable entries; hidden views, relocks and failed connections cannot.
@(private)
whip_workspace_sync :: proc(ui: ^Ui_State) {
	whip_workspace_guard(ui)
	if ui.account_ref == "" {return}
	whip_workspace_prepare(ui)
	state := rl.WhipState()
	if state != .Ready && state != .Missing {return}
	whip_attach_validate(ui)
	unresolved := false
	for i := len(ui.prefs.whip_selected_tabs) - 1; i >= 0; i -= 1 {
		saved := ui.prefs.whip_selected_tabs[i]
		if saved.account != ui.account_ref {continue}
		info, live, resolved := whip_workspace_live(saved.pane, saved.session, saved.folder)
		if !resolved {unresolved = true; continue}
		if !live || info.tab != saved.tab {
			delete(saved.account); delete(saved.folder)
			ordered_remove(&ui.prefs.whip_selected_tabs, i)
			ui.settings_dirty = true
		} else if !ui.whip_workspace_loaded && ui.whip_tabs[info.project] == 0 {
			ui.whip_tabs[info.project] = saved.tab
		}
	}
	for i := len(ui.prefs.whip_placements) - 1; i >= 0; i -= 1 {
		saved := ui.prefs.whip_placements[i]
		if saved.account != ui.account_ref {continue}
		_, live, resolved := whip_workspace_live(saved.pane, saved.session, saved.folder)
		if !resolved {unresolved = true; continue}
		if !live {
			delete(saved.account); delete(saved.group_id); delete(saved.folder)
			ordered_remove(&ui.prefs.whip_placements, i)
			ui.settings_dirty = true
		} else if !ui.whip_workspace_loaded && whip_attach_index(ui, saved.pane) < 0 {
			item := Whip_Attachment {
				pane     = saved.pane,
				session  = saved.session,
				bounds   = saved.bounds,
				account  = strings.clone(saved.account),
				group_id = strings.clone(saved.group_id),
			}
			whip_attach_clamp(&item.bounds)
			append(&ui.whip_attachments, item)
		}
	}
	if ui.whip_workspace_pending {
		if i := whip_workspace_index(ui); i >= 0 {
			saved := ui.prefs.whip_workspaces[i]
			info, live, resolved := whip_workspace_live(saved.pane, saved.session, saved.folder)
			if !resolved {return}
			if live && saved.open && ui.prefs.restore_last_chat && ui.page == .Chats {
				whip_open_project(ui, info.project, .Restore)
				ui.whip_return_focus = info.id
			}
		}
		ui.whip_workspace_pending = false
	}
	ui.whip_workspace_loaded = !unresolved
}
