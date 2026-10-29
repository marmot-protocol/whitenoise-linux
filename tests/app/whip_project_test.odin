package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
whip_project_identity :: proc(t: ^testing.T) {
	prefs: Prefs
	defer whip_project_prefs_free(&prefs)
	previous := [4]u64{1, 2, 3, 4}
	current := [4]u64{5, 6, 7, 8}
	append(
		&prefs.whip_projects,
		Whip_Project_Meta {
			project = 7,
			session = previous,
			source = strings.clone("/work/source"),
			name = strings.clone("Project"),
			folder = strings.clone("/work/root"),
		},
	)
	projects := [2]rl.Whip_Project {
		{id = 7, session = previous, source_dir = "/work/changed-cwd"},
		{id = 9, session = previous, source_dir = "/work/unrelated"},
	}
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), 0)
	projects[0].session = current
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), -1)
	projects[0].source_dir = "/work/source"
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), 0)
	projects[1].source_dir = "/work/source"
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), -1)
	projects[1].source_dir = "/work/unrelated"
	append(
		&prefs.whip_projects,
		Whip_Project_Meta {
			project = 12,
			session = previous,
			source = strings.clone("/work/source"),
			name = strings.clone("Other"),
			folder = strings.clone("/work/other-root"),
		},
	)
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), -1)
	projects[0].session = {}
	testing.expect_value(t, whip_project_meta_index(&prefs, projects[:], projects[0]), -1)
}

@(test)
whip_project_path_validation :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("/tmp", "wn-project-path-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer {os.remove_all(home); delete(home)}
	job := Whip_Project_Job {
		name = "Project",
		path = fmt.tprintf("%s/./", home),
	}
	whip_project_validate(&job)
	testing.expect_value(t, job.error, "")
	testing.expect_value(t, job.folder, home)
	delete(job.folder); delete(job.detail)
	job = {
		name = "Project",
		path = "relative/path",
	}
	whip_project_validate(&job)
	testing.expect(
		t,
		job.error != "" && job.folder == "",
		"a relative root cannot resolve against the launch directory",
	)
	delete(job.detail)
	job = {
		name = "Project",
		path = fmt.tprintf("%s/missing", home),
	}
	whip_project_validate(&job)
	testing.expect(
		t,
		job.error != "" && job.folder == "",
		"a missing directory cannot become project metadata",
	)
	delete(job.detail)
	job = {
		name = "Project",
		path = "~",
	}
	whip_project_validate(&job)
	expected, home_err := os.user_home_dir(context.temp_allocator)
	if testing.expect_value(t, home_err, nil) {
		testing.expect_value(t, job.error, "")
		testing.expect_value(t, job.folder, expected)
	}
	delete(job.folder); delete(job.detail)
}

@(test)
whip_project_root_migration :: proc(t: ^testing.T) {
	// The avatar key cache is process-global, like the layout caches.
	if #config(ODIN_TEST_NAMES, "") != "whip_project_root_migration" {return}
	ui: Ui_State
	defer whip_avatar_stop(&ui)
	defer whip_workspace_prefs_free(&ui.prefs)
	defer {
		for key in ui.prefs.pinned {delete(key)}
		for key, value in ui.prefs.folder_of {delete(key); delete(value)}
		for key, value in ui.prefs.whip_avatars {delete(key); delete(value)}
		for key in ui.prefs.whip_activity {delete(key)}
		delete(ui.prefs.pinned); delete(ui.prefs.folder_of)
		delete(ui.prefs.whip_avatars); delete(ui.prefs.whip_activity)
	}
	old, next := "/work/inferred-mobile", "/work/project"
	ui.prefs.pinned[strings.clone(inbox_terminal_key(old))] = true
	ui.prefs.folder_of[strings.clone(inbox_terminal_key(old))] = strings.clone("Work")
	ui.prefs.whip_avatars[strings.clone(old)] = strings.clone("local-avatar.img")
	ui.prefs.whip_activity[strings.clone(old)] = 120
	ui.prefs.whip_activity[strings.clone(next)] = 240
	append(
		&ui.prefs.whip_selected_tabs,
		Whip_Saved_Tab {
			account = strings.clone("account-a"),
			folder = strings.clone(old),
			session = {1, 2, 3, 4},
			pane = 5,
			tab = 8,
		},
	)
	ui.prefs.whip_selected_tabs[0].order[8] = 1
	append(
		&ui.prefs.whip_placements,
		Whip_Saved_Placement {
			account = strings.clone("account-b"),
			group_id = strings.clone("chat"),
			folder = strings.clone(old),
			session = {1, 2, 3, 4},
			pane = 5,
		},
	)
	append(
		&ui.prefs.whip_workspaces,
		Whip_Workspace {
			account = strings.clone("account-a"),
			folder = strings.clone(old),
			session = {1, 2, 3, 4},
			pane = 5,
		},
	)
	whip_project_migrate(&ui, rl.Whip_Project{id = 7, session = {1, 2, 3, 4}}, old, next)
	testing.expect(t, ui.prefs.pinned[inbox_terminal_key(next)])
	testing.expect(t, !(inbox_terminal_key(old) in ui.prefs.pinned))
	testing.expect_value(t, ui.prefs.folder_of[inbox_terminal_key(next)], "Work")
	testing.expect_value(t, ui.prefs.whip_avatars[next], "local-avatar.img")
	testing.expect_value(t, ui.prefs.whip_activity[next], u64(240))
	testing.expect_value(t, ui.prefs.whip_selected_tabs[0].folder, next)
	testing.expect_value(t, ui.prefs.whip_selected_tabs[0].order[8], 1)
	testing.expect_value(t, ui.prefs.whip_placements[0].folder, next)
	testing.expect_value(t, ui.prefs.whip_workspaces[0].folder, next)
}
