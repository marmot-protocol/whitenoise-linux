package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
staged_file_draft_ownership :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	dir, err := os.make_directory_temp("/tmp", "wn-staged-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/file with spaces.txt", dir)
	if !testing.expect_value(t, os.write_entire_file(path, "original bytes"), nil) {return}
	ui := Ui_State {
		selected = 0,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "original"})
	defer {
		stage_files_stop()
		for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
		delete(ui.staged)
		for key, files in ui.staged_drafts {
			ui.staged = files
			for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
			delete(ui.staged); delete(key)
		}
		delete(ui.staged_drafts); delete(ui.chats)
	}
	stage_file(&ui, path)
	testing.expect(t, !stage_files_ready(&ui), "preparation must block sending")
	testing.expect_value(t, ui.staged[0].name, "file with spaces.txt")
	worker := ui.staged[0].load.worker
	stash_staged(&ui)
	// A second draft may be edited while the original file is being prepared.
	stage_file(&ui, path)
	removed := ui.staged[0].load.worker
	remove_staged(&ui, 0)
	thread.join(removed)
	thread.join(worker)
	stage_files_tick(&ui)
	testing.expect(t, len(ui.staged) == 0, "removed file must not reappear")
	files := ui.staged_drafts["original"]
	if testing.expect_value(t, len(files), 1) {
		testing.expect_value(t, string(files[0].data), "original bytes")
		testing.expect_value(t, files[0].media_type, "text/plain")
		testing.expect(t, files[0].load == nil)
	}
}

@(test)
staged_file_read_outcomes :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	dir, err := os.make_directory_temp("/tmp", "wn-staged-errors-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/empty.txt", dir)
	if !testing.expect_value(t, os.write_entire_file(path, nil), nil) {return}
	ui: Ui_State
	defer {
		stage_files_stop()
		for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
		delete(ui.staged); delete(ui.client_status)
	}
	stage_file(&ui, path)
	stage_file(&ui, fmt.tprintf("%s/missing.txt", dir))
	for file in ui.staged {thread.join(file.load.worker)}
	stage_files_tick(&ui)
	if testing.expect_value(t, len(ui.staged), 1) {
		testing.expect_value(t, ui.staged[0].name, "empty.txt")
		testing.expect_value(t, len(ui.staged[0].data), 0)
	}
	testing.expect(t, stage_files_ready(&ui), "empty files are ready, not pending")
	testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
	testing.expect(t, strings.contains(ui.client_status, "missing.txt"))
	// Shutdown joins outstanding work and prevents its result from resurfacing.
	stage_file(&ui, path)
	stage_files_stop()
	stage_files_tick(&ui)
	testing.expect_value(t, len(ui.staged), 1)
}
