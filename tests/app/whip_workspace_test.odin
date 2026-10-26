package main

import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
whip_session_match :: proc(t: ^testing.T) {
	session := [4]u64{11, 22, 33, 44}
	pane := rl.Whip_Pane {
		id      = 7,
		project = 9,
		tab     = 12,
		session = session,
	}
	live, resolved := whip_workspace_match(pane, session, "/work/project", "/work/project")
	testing.expect(t, live && resolved, "a live same-session shell retains its placement")
	pane.session[0] += 1
	live, resolved = whip_workspace_match(pane, session, "/work/project", "/work/project")
	testing.expect(t, !live && resolved, "a new server cannot inherit a dock by reusing pane IDs")
	pane.session = session
	live, resolved = whip_workspace_match(pane, session, "/work/project", "/other/project")
	testing.expect(t, !live && resolved, "reused project IDs do not cross canonical folders")
	pane.session = {}
	live, resolved = whip_workspace_match(pane, session, "/work/project", "/work/project")
	testing.expect(
		t,
		!live && !resolved,
		"unavailable peer identity cannot restore or erase saved state",
	)
	pane = {}
	live, resolved = whip_workspace_match(pane, session, "/work/project", "")
	testing.expect(t, !live && resolved, "a complete catalog can identify a truly closed pane")
}

@(test)
whip_saved_return :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-a",
		focus       = .Whip,
		whip_focus  = 7,
	}
	defer whip_workspace_prefs_free(&ui.prefs)
	session := [4]u64{1, 2, 3, 4}
	for account in ([2]string{"account-a", "account-b"}) {
		append(
			&ui.prefs.whip_placements,
			Whip_Saved_Placement {
				account = strings.clone(account),
				group_id = strings.clone("chat-a"),
				folder = strings.clone("/work/project"),
				session = session,
				pane = 7,
				bounds = {40, 50, 620, 380},
			},
		)
	}
	attach :: proc(ui: ^Ui_State, session: [4]u64) {
		append(
			&ui.whip_attachments,
			Whip_Attachment {
				pane = 7,
				session = session,
				account = strings.clone("account-a"),
				group_id = strings.clone("chat-a"),
				bounds = {40, 50, 620, 380},
			},
		)
	}
	attach(&ui, session)
	ui.whip_workspace_account = strings.clone("account-a")
	ui.whip_workspace_loaded = true
	whip_attach_clear(&ui)
	testing.expect_value(t, len(ui.whip_attachments), 0)
	testing.expect_value(t, len(ui.prefs.whip_placements), 2)
	testing.expect_value(t, ui.prefs.whip_placements[0].group_id, "chat-a")
	testing.expect_value(t, ui.whip_workspace_account, "")
	testing.expect(
		t,
		!ui.settings_dirty,
		"relock/reload cleanup does not write placement removals",
	)
	attach(&ui, session)
	whip_attach_return(&ui, 7)
	testing.expect_value(t, len(ui.prefs.whip_placements), 1)
	testing.expect_value(t, ui.prefs.whip_placements[0].account, "account-b")
	testing.expect(
		t,
		ui.settings_dirty,
		"explicit Return persists removal for only its owning account",
	)
	ui.settings_dirty = false
	whip_workspace_forget(&ui, "account-b", 7, [4]u64{5, 6, 7, 8})
	testing.expect_value(t, len(ui.prefs.whip_placements), 1)
	testing.expect(
		t,
		!ui.settings_dirty,
		"a stale incarnation cannot remove another shell's binding",
	)
	whip_attach_clear(&ui)
}

@(test)
whip_restore_loading :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-a",
		selected = -1,
		prefs = {restore_last_chat = true},
	}
	defer whip_workspace_prefs_free(&ui.prefs)
	append(
		&ui.prefs.whip_workspaces,
		Whip_Workspace {
			account = strings.clone("account-a"),
			folder = strings.clone("/work/project"),
			session = {1, 2, 3, 4},
			pane = 7,
			open = true,
			width = 390,
			height = 230,
		},
	)
	append(
		&ui.prefs.whip_selected_tabs,
		Whip_Saved_Tab {
			account = strings.clone("account-a"),
			folder = strings.clone("/work/project"),
			session = {1, 2, 3, 4},
			pane = 7,
			tab = 12,
		},
	)
	whip_workspace_remember(&ui)
	testing.expect(
		t,
		ui.prefs.whip_workspaces[0].open,
		"a cold observer cannot overwrite the saved terminal selection",
	)
	testing.expect_value(t, ui.prefs.whip_workspaces[0].width, f32(390))
	testing.expect_value(t, ui.prefs.whip_workspaces[0].height, f32(230))
	testing.expect_value(t, ui.prefs.whip_selected_tabs[0].tab, u32(12))
	testing.expect(t, !ui.settings_dirty, "cold/loading snapshots do not schedule writes")
	whip_workspace_begin(&ui)
	testing.expect(t, ui.whip_workspace_pending)
	whip_workspace_navigation(&ui)
	testing.expect(
		t,
		!ui.whip_workspace_pending,
		"explicit navigation outranks deferred selection",
	)
	ui.prefs.restore_last_chat = false
	whip_workspace_begin(&ui)
	testing.expect(
		t,
		!ui.whip_workspace_pending,
		"the existing preference gates terminal auto-selection",
	)
}

@(test)
whip_restore_interaction :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-a",
		selected = -1,
		focus = .Compose,
		prefs = {restore_last_chat = true},
	}
	defer delete(ui.compose)
	append(&ui.compose, "draft")
	whip_workspace_begin(&ui)
	whip_workspace_guard(&ui)
	testing.expect(
		t,
		ui.whip_workspace_pending,
		"an untouched workspace can await its live catalog",
	)
	ui.compose[0] = 'D'
	whip_workspace_guard(&ui)
	testing.expect(
		t,
		!ui.whip_workspace_pending,
		"same-length draft edits prevent late terminal auto-open",
	)
	whip_workspace_begin(&ui)
	ui.focus = .Filter
	whip_workspace_guard(&ui)
	testing.expect(
		t,
		!ui.whip_workspace_pending,
		"keyboard navigation to another input wins over restore",
	)
	ui.focus = .Compose
	whip_workspace_begin(&ui)
	ui.page = .Settings
	whip_workspace_guard(&ui)
	testing.expect(
		t,
		!ui.whip_workspace_pending,
		"direct page changes cancel the deferred selection",
	)
}

@(test)
whip_saved_dock_sizes :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-a",
	}
	defer {whip_attach_clear(&ui); whip_workspace_prefs_free(&ui.prefs)}
	for account, i in ([2]string{"account-a", "account-b"}) {
		append(
			&ui.prefs.whip_workspaces,
			Whip_Workspace {
				account = strings.clone(account),
				width = f32(390 + i * 10),
				height = f32(230 + i * 20),
			},
		)
	}
	whip_workspace_prepare(&ui)
	testing.expect_value(t, ui.whip_dock_width, f32(390))
	testing.expect_value(t, ui.whip_dock_height, f32(230))
	ui.whip_workspace_loaded = true
	whip_workspace_remember(&ui)
	testing.expect(t, !ui.settings_dirty, "warm snapshots do not dirty unchanged sizes")
	ui.whip_dock_width = 440
	ui.whip_dock_drag = true
	whip_workspace_remember(&ui)
	testing.expect_value(t, ui.prefs.whip_workspaces[0].width, f32(390))
	testing.expect(t, !ui.settings_dirty, "drag motion does not save every mouse movement")
	ui.whip_dock_drag = false
	ui.whip_dock_release = true
	whip_workspace_remember(&ui)
	testing.expect(
		t,
		!ui.settings_dirty,
		"an interrupted drag waits for release before snapshotting",
	)
	ui.whip_dock_release = false
	whip_workspace_remember(&ui)
	testing.expect_value(t, ui.prefs.whip_workspaces[0].width, f32(440))
	testing.expect_value(t, ui.prefs.whip_workspaces[0].height, f32(230))
	testing.expect(t, ui.settings_dirty, "completed resize persists only the changed axis")
	ui.settings_dirty = false
	whip_workspace_remember(&ui)
	testing.expect(t, !ui.settings_dirty, "the committed size does not remain dirty")
	ui.whip_open, ui.whip_project = true, 9
	ui.account_ref = "account-b"
	whip_workspace_prepare(&ui)
	testing.expect(
		t,
		!ui.whip_open && ui.whip_project == 0,
		"a switched account does not inherit visible terminal selection",
	)
	testing.expect_value(t, ui.whip_dock_width, f32(400))
	testing.expect_value(t, ui.whip_dock_height, f32(250))
	testing.expect_value(t, ui.prefs.whip_workspaces[0].width, f32(440))
}
