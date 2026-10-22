package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"

import rl "sdlrl"

// The draft entry owns its job. Removed entries leave their job in this flat
// registry until it finishes; shutdown also uses it to join every worker.
@(private)
Stage_Load :: struct {
	worker:                    ^thread.Thread,
	path, media_type:          string,
	data:                      []u8,
	image:                     rl.Image,
	failed, detached, stopped: bool,
	index:                     int,
}

@(private)
stage_loads: [dynamic]^Stage_Load

@(private)
stage_file_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Stage_Load)(t.data)
	read_error: os.Error
	job.data, read_error = os.read_entire_file(job.path, context.allocator)
	job.failed = read_error != nil
	if !job.failed && strings.has_prefix(job.media_type, "image/") {
		job.image = rl.LoadImageFromMemory("", raw_data(job.data), i32(len(job.data)))
	}
}

// Only called once the worker has been joined and destroyed.
@(private)
stage_load_free :: proc(job: ^Stage_Load) {
	index := job.index
	unordered_remove(&stage_loads, index)
	if index < len(stage_loads) {stage_loads[index].index = index}
	if len(stage_loads) == 0 {delete(stage_loads); stage_loads = {}}
	rl.UnloadImage(job.image)
	delete(job.data)
	delete(job.path)
	free(job)
}

@(private)
stage_files_ready :: proc(ui: ^Ui_State) -> bool {
	for file in ui.staged {if file.load != nil {return false}}
	return true
}

@(private = "file")
stage_files_drain :: proc(ui: ^Ui_State, files: ^[dynamic]Staged_File) {
	for i := len(files^) - 1; i >= 0; i -= 1 {
		file := &files^[i]
		job := file.load
		if job == nil {continue}
		if job.worker != nil {
			if !thread.is_done(job.worker) {continue}
			thread.join(job.worker)
			thread.destroy(job.worker)
			job.worker = nil
		}
		if job.failed || job.stopped {
			if !job.stopped {
				set_status(
					ui,
					fmt.aprintf(tr("Couldn't read %s. Please try again."), job.path),
					.Error,
				)
			}
			delete(file.name)
			ordered_remove(files, i)
		} else {
			file.data = job.data
			job.data = nil
			if job.image.data != nil {
				file.tex = new(rl.Texture2D)
				file.tex^ = rl.LoadTextureFromImage(job.image)
			}
			file.load = nil
		}
		stage_load_free(job)
	}
}

@(private)
stage_files_tick :: proc(ui: ^Ui_State) {
	if len(stage_loads) == 0 {return}
	stage_files_drain(ui, &ui.staged)
	for key, files in ui.staged_drafts {
		draft := files
		stage_files_drain(ui, &draft)
		ui.staged_drafts[key] = draft
	}
	for i := len(stage_loads) - 1; i >= 0; i -= 1 {
		job := stage_loads[i]
		if !job.detached {continue}
		if job.worker != nil {
			if !thread.is_done(job.worker) {continue}
			thread.join(job.worker)
			thread.destroy(job.worker)
			job.worker = nil
		}
		stage_load_free(job)
	}
}

// Runs before lock scrubbing or unload. Referenced jobs stay alive until their
// staged entries are removed; no decoded result may reappear after a lock.
@(private)
stage_files_stop :: proc() {
	for job in stage_loads {
		if job.worker != nil {
			thread.join(job.worker)
			thread.destroy(job.worker)
			job.worker = nil
		}
		mem.zero_slice(job.data)
		delete(job.data); job.data = nil
		rl.UnloadImage(job.image); job.image = {}
		job.stopped = true
	}
	for i := len(stage_loads) - 1; i >= 0; i -= 1 {
		if job := stage_loads[i]; job.detached {stage_load_free(job)}
	}
}
