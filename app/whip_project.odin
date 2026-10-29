package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import rl "sdlrl"

// Local overrides own their strings; native projection strings remain borrowed.
@(private)
Whip_Project_Meta :: struct {
	project:              u32,
	session:              [4]u64,
	source, name, folder: string,
}

@(private)
Whip_Project_Job :: struct {
	worker:             ^thread.Thread,
	project:            u32,
	session:            [4]u64,
	name, path, folder: string,
	error:              string, // untranslated worker message, translated on the UI thread
	detail:             string,
	discard:            bool, // UI-thread only; closing never waits for filesystem I/O
}

@(private = "file")
Whip_Project_Binding :: struct {
	project: u32,
	session: [4]u64,
	source:  string,
	index:   int,
}

@(private = "file")
whip_project_bindings: [dynamic]Whip_Project_Binding
@(private = "file")
whip_project_bindings_owner: ^Prefs
@(private = "file")
whip_project_bindings_dirty: bool

@(private = "file")
whip_project_bindings_free :: proc() {
	for binding in whip_project_bindings {delete(binding.source)}
	delete(whip_project_bindings); whip_project_bindings = nil
	whip_project_bindings_owner = nil
	whip_project_bindings_dirty = false
}

@(private)
whip_project_prefs_free :: proc(prefs: ^Prefs) {
	if whip_project_bindings_owner == prefs {whip_project_bindings_free()}
	for item in prefs.whip_projects {
		// Discarding an unrelated unmarshalled Prefs must not clear live overrides.
		for &project in rl.WhipProjects() {
			if item.name != "" && raw_data(project.name) == raw_data(item.name) {
				project.name = project.source_name
			}
			if item.folder != "" && raw_data(project.dir) == raw_data(item.folder) {
				project.dir = project.source_dir
			}
		}
		delete(item.source); delete(item.name); delete(item.folder)
	}
	delete(prefs.whip_projects)
	prefs.whip_projects = nil
}

// A server incarnation and project ID are the primary identity. Restart rebinding
// requires a one-to-one raw directory match; IDs alone never inherit overrides.
@(private)
whip_project_meta_index :: proc(
	prefs: ^Prefs,
	projects: []rl.Whip_Project,
	project: rl.Whip_Project,
) -> int {
	if project.session == ([4]u64{}) {return -1}
	index := -1
	for item, i in prefs.whip_projects {
		if item.project != project.id || item.session != project.session {continue}
		if index >= 0 {return -1}
		index = i
	}
	if index >= 0 || project.source_dir == "" {return index}
	for live in projects {
		if live.source_dir == project.source_dir &&
		   (live.id != project.id || live.session != project.session) {return -1}
	}
	for item, i in prefs.whip_projects {
		if item.source != project.source_dir {continue}
		if index >= 0 {return -1}
		index = i
	}
	if index < 0 {return -1}
	item := prefs.whip_projects[index]
	if item.session == ([4]u64{}) || item.session == project.session {return -1}
	// An exact live owner takes precedence even if another incarnation appears.
	for live in projects {
		if live.id == item.project && live.session == item.session {return -1}
	}
	return index
}

@(private)
whip_project_sync :: proc(ui: ^Ui_State) {
	if len(ui.prefs.whip_projects) == 0 {return}
	projects := rl.WhipProjects()
	rebuild :=
		whip_project_bindings_dirty ||
		whip_project_bindings_owner != &ui.prefs ||
		len(whip_project_bindings) != len(projects)
	if !rebuild {
		for project, i in projects {
			binding := whip_project_bindings[i]
			if binding.project != project.id ||
			   binding.session != project.session ||
			   binding.source != project.source_dir {
				rebuild = true
				break
			}
		}
	}
	if rebuild {
		whip_project_bindings_free()
		whip_project_bindings_owner = &ui.prefs
		for project in projects {
			append(
				&whip_project_bindings,
				Whip_Project_Binding {
					project = project.id,
					session = project.session,
					source = strings.clone(project.source_dir),
					index = whip_project_meta_index(&ui.prefs, projects, project),
				},
			)
		}
	}
	for &project, at in projects {
		i := whip_project_bindings[at].index
		if i < 0 {continue}
		meta := &ui.prefs.whip_projects[i]
		if meta.project != project.id || meta.session != project.session {
			meta.project, meta.session = project.id, project.session
			ui.settings_dirty = true
		}
		if meta.source != project.source_dir {
			previous := meta.source
			meta.source = strings.clone(project.source_dir)
			delete(previous)
			// A changed source may resolve another saved record's ambiguity.
			whip_project_bindings_dirty = true
			ui.settings_dirty = true
		}
		project.name, project.dir = meta.name, meta.folder
	}
}

@(private)
whip_project_edit_open :: proc(ui: ^Ui_State, project: u32) {
	for item in rl.WhipProjects() {
		if item.id != project || item.session == ([4]u64{}) {continue}
		if ui.whip_edit_job != nil {ui.whip_edit_job.discard = true}
		ed_set(ui, &ui.whip_edit_name, item.name)
		ed_set(ui, &ui.whip_edit_path, item.dir)
		delete(ui.whip_edit_error); ui.whip_edit_error = ""
		ui.whip_edit_project, ui.whip_edit_session = item.id, item.session
		ui.whip_edit_open = true
		ui.focus = .WhipProjectName
		kb_focus = ""
		return
	}
}

@(private)
whip_project_edit_close :: proc(ui: ^Ui_State) {
	ui.whip_edit_open = false
	if ui.whip_edit_job != nil {ui.whip_edit_job.discard = true}
	ui.focus = .Compose
	kb_focus = ""
}

// Runs only on a worker (or directly in isolated tests), never in modal input.
@(private)
whip_project_validate :: proc(job: ^Whip_Project_Job) {
	path := job.path
	if strings.trim_space(job.name) == "" {
		job.error = N_("Enter a project name.")
		return
	}
	if path == "~" || strings.has_prefix(path, "~/") {
		home, err := os.user_home_dir(context.temp_allocator)
		if err != nil {
			job.error = N_(
				"Couldn't find your home folder. Enter an absolute project folder path.",
			)
			job.detail = fmt.aprintf("%v", err)
			return
		}
		path = path == "~" ? home : fmt.tprintf("%s/%s", home, path[2:])
	}
	if path == "" || !filepath.is_abs(path) {
		job.error = N_("Enter an absolute project folder path, or a path starting with ~/.")
		return
	}
	folder, clean_err := filepath.clean(path, context.allocator)
	if clean_err != nil {
		job.error = N_("Couldn't normalize the project folder. Check the path and try again.")
		job.detail = fmt.aprintf("%v", clean_err)
		return
	}
	info, err := os.stat(folder, context.temp_allocator)
	if err != nil {
		delete(folder)
		job.error = N_(
			"Couldn't open the project folder. Check that it exists and you have permission to access it.",
		)
		job.detail = fmt.aprintf("%v", err)
		return
	}
	if info.type != .Directory {
		delete(folder)
		job.error = N_("That path is not a folder. Choose an existing project folder.")
		return
	}
	job.folder = folder
}

@(private)
whip_project_save :: proc(ui: ^Ui_State) {
	if !ui.whip_edit_open || ui.whip_edit_job != nil {return}
	delete(ui.whip_edit_error); ui.whip_edit_error = ""
	job := new(Whip_Project_Job)
	job.project, job.session = ui.whip_edit_project, ui.whip_edit_session
	job.name = strings.clone(strings.trim_space(string(ui.whip_edit_name[:])))
	job.path = strings.clone(string(ui.whip_edit_path[:]))
	job.worker = thread.create(proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		defer free_all(context.temp_allocator)
		defer frame_wake()
		whip_project_validate((^Whip_Project_Job)(t.data))
	})
	if job.worker == nil {
		whip_project_job_free(job)
		ui.whip_edit_error = strings.clone(
			tr("Couldn't check the project folder. Please try again."),
		)
		return
	}
	job.worker.data = job
	ui.whip_edit_job = job
	thread.start(job.worker)
}

// Destination preferences win collisions. Clone before removing owned source
// keys/values, and retain shared source state for any other live project.
@(private = "file")
Whip_Project_Sharing :: enum {
	Unique,
	Shared,
}

@(private = "file")
whip_project_migrate_strings :: proc(
	values: ^map[string]string,
	old, next: string,
	sharing: Whip_Project_Sharing,
) {
	value, found := values^[old]
	if !found {return}
	if _, exists := values^[next]; !exists {values^[strings.clone(next)] = strings.clone(value)}
	if sharing == .Unique {
		key, owned := delete_key(values, old)
		delete(key); delete(owned)
	}
}

@(private = "file")
whip_project_pane_owned :: proc(project: rl.Whip_Project, pane: u32, session: [4]u64) -> bool {
	info, live := rl.WhipPaneInfo(pane)
	return(
		live &&
		info.project == project.id &&
		info.session == session &&
		session == project.session \
	)
}

@(private)
whip_project_migrate :: proc(ui: ^Ui_State, project: rl.Whip_Project, old_root, new_root: string) {
	old := whip_avatar_key(old_root).folder
	next := whip_avatar_key(new_root).folder
	if old == next {return}
	shared := false
	for live in rl.WhipProjects() {
		if live.id == project.id && live.session == project.session {continue}
		if whip_avatar_key(live.dir).folder == old {shared = true; break}
	}
	old_key, next_key := inbox_terminal_key(old), inbox_terminal_key(next)
	if value, found := ui.prefs.pinned[old_key]; found {
		if _, exists := ui.prefs.pinned[next_key];
		   !exists {ui.prefs.pinned[strings.clone(next_key)] = value}
		if !shared {key, _ := delete_key(&ui.prefs.pinned, old_key); delete(key)}
	}
	sharing: Whip_Project_Sharing = shared ? .Shared : .Unique
	whip_project_migrate_strings(&ui.prefs.folder_of, old_key, next_key, sharing)
	whip_project_migrate_strings(&ui.prefs.whip_avatars, old, next, sharing)
	if value, found := ui.prefs.whip_activity[old]; found {
		previous, exists := ui.prefs.whip_activity[next]
		if !exists {ui.prefs.whip_activity[strings.clone(next)] = value} else if value > previous {ui.prefs.whip_activity[next] = value}
		if !shared {key, _ := delete_key(&ui.prefs.whip_activity, old); delete(key)}
	}
	for &saved in ui.prefs.whip_workspaces {
		if saved.folder != old ||
		   shared && !whip_project_pane_owned(project, saved.pane, saved.session) {continue}
		delete(saved.folder); saved.folder = strings.clone(next)
	}
	for i := len(ui.prefs.whip_selected_tabs) - 1; i >= 0; i -= 1 {
		saved := &ui.prefs.whip_selected_tabs[i]
		if saved.folder != old ||
		   shared && !whip_project_pane_owned(project, saved.pane, saved.session) {continue}
		conflict := false
		for &target in ui.prefs.whip_selected_tabs {
			if target.account != saved.account || target.folder != next {continue}
			// Tab IDs are valid only in the same server incarnation.
			if target.session == saved.session {
				for tab, order in saved.order {
					if _, exists := target.order[tab]; !exists {target.order[tab] = order}
				}
			}
			conflict = true
			break
		}
		if conflict {
			if shared {continue}
			delete(saved.account); delete(saved.folder); delete(saved.order)
			ordered_remove(&ui.prefs.whip_selected_tabs, i)
		} else if shared {
			copy := saved^
			copy.account, copy.folder = strings.clone(saved.account), strings.clone(next)
			copy.order = make(map[u32]int)
			for tab, order in saved.order {copy.order[tab] = order}
			append(&ui.prefs.whip_selected_tabs, copy)
		} else {
			delete(saved.folder); saved.folder = strings.clone(next)
		}
	}
	for &saved in ui.prefs.whip_placements {
		if saved.folder != old ||
		   shared && !whip_project_pane_owned(project, saved.pane, saved.session) {continue}
		delete(saved.folder); saved.folder = strings.clone(next)
	}
	// These targets store only a folder/key, not a project ID. Shared roots are
	// deliberately left attached to the remaining project rather than guessed.
	if !shared {
		if ui.folder_gid ==
		   old_key {delete(ui.folder_gid); ui.folder_gid = strings.clone(next_key)}
		if ui.photo.kind == .Whip && ui.photo.folder == old {
			delete(ui.photo.folder); ui.photo.folder = strings.clone(next)
		}
		// Avatar workers never access folder; it is their UI-owned commit target.
		if job := ui.whip_avatar_job; job != nil && job.folder == old {
			delete(job.folder); job.folder = strings.clone(next)
		}
	}
}

@(private = "file")
whip_project_job_free :: proc(job: ^Whip_Project_Job) {
	delete(job.name); delete(job.path); delete(job.folder); delete(job.detail)
	free(job)
}

@(private)
whip_project_poll :: proc(ui: ^Ui_State) {
	job := ui.whip_edit_job
	if job == nil || !thread.is_done(job.worker) {return}
	thread.join(job.worker); thread.destroy(job.worker)
	ui.whip_edit_job = nil
	defer whip_project_job_free(job)
	if job.discard ||
	   !ui.whip_edit_open ||
	   ui.whip_edit_project != job.project ||
	   ui.whip_edit_session != job.session {return}
	delete(ui.whip_edit_error); ui.whip_edit_error = ""
	if job.error != "" {
		ui.whip_edit_error =
			job.detail == "" ? strings.clone(tr(job.error)) : fmt.aprintf("%s\n%s", tr(job.error), job.detail)
		return
	}
	for &project in rl.WhipProjects() {
		if project.id != job.project || project.session != job.session {continue}
		whip_project_migrate(ui, project, project.dir, job.folder)
		index := -1
		for item, i in ui.prefs.whip_projects {
			if item.project == job.project && item.session == job.session {index = i; break}
		}
		meta := Whip_Project_Meta {
			project = job.project,
			session = job.session,
			source  = strings.clone(project.source_dir),
			name    = job.name,
			folder  = job.folder,
		}
		job.name, job.folder = "", ""
		previous: Whip_Project_Meta
		if index <
		   0 {append(&ui.prefs.whip_projects, meta)} else {previous = ui.prefs.whip_projects[index]; ui.prefs.whip_projects[index] = meta}
		// Replace every borrowed pointer before freeing the previous owned data.
		whip_project_bindings_free()
		whip_project_sync(ui)
		delete(previous.source); delete(previous.name); delete(previous.folder)
		ui.settings_dirty = true
		whip_project_edit_close(ui)
		return
	}
	ui.whip_edit_error = strings.clone(
		tr(
			"This project is no longer available. Close this editor and reopen it from the current project.",
		),
	)
}

@(private)
whip_project_stop :: proc(ui: ^Ui_State) {
	whip_project_edit_close(ui)
	whip_project_bindings_free()
	if job := ui.whip_edit_job; job != nil {
		thread.join(job.worker); thread.destroy(job.worker)
		whip_project_job_free(job)
		ui.whip_edit_job = nil
	}
	delete(ui.whip_edit_name); ui.whip_edit_name = nil
	delete(ui.whip_edit_path); ui.whip_edit_path = nil
	delete(ui.whip_edit_error); ui.whip_edit_error = ""
	ui.whip_edit_project, ui.whip_edit_session = 0, {}
}
