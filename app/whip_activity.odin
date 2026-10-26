// Only explicit opens and live user input advance recency; observing a terminal does not.
package main

import "core:strings"
import rl "sdlrl"

@(private)
whip_activity_record :: proc(ui: ^Ui_State, dir: string, at: u64) {
	if at == 0 {return}
	folder := whip_avatar_key(dir).folder
	if folder == "" {return}
	previous, found := ui.prefs.whip_activity[folder]
	if at <= previous {return}
	if !found {folder = strings.clone(folder)}
	ui.prefs.whip_activity[folder] = at
	ui.settings_dirty = true
}

@(private)
whip_activity_sync :: proc(ui: ^Ui_State) {
	for project in rl.WhipProjects() {
		whip_activity_record(ui, project.dir, project.activity_at)
	}
}
