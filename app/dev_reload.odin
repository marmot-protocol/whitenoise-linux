package main

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"

_ :: runtime
_ :: c
_ :: os

@(private)
reload_heap: mem.Tracking_Allocator
@(private)
reload_requested: bool
@(private)
reload_generation: int

// Worker contexts start with the runtime allocator. Give each worker the
// same tracked heap so leftovers can be released once every thread joins.
@(private)
reload_allocator :: proc() -> mem.Allocator {
	when #config(WN_RELOAD, false) { return mem.tracking_allocator(&reload_heap) }
	return context.allocator
}

when #config(WN_RELOAD, false) {
	@(private = "file")
	Dev_Reload_Gate :: enum c.int { Busy, Ready }
	@(private = "file")
	Dev_Reload_Action :: enum c.int { Keep_Running, Reload_App, Stop_App }
	foreign {
		@(private)
		wn_dev_reload :: proc "c" (gate: Dev_Reload_Gate) -> Dev_Reload_Action ---
	}

	@(export, private)
	wn_app_run :: proc "c" (argc: c.int, argv: [^]cstring, generation: c.int) -> c.int {
		context = runtime.default_context()
		reload_generation = int(generation)
		backing := context.allocator
		mem.tracking_allocator_init(&reload_heap, backing)
		context.allocator = mem.tracking_allocator(&reload_heap)
		os.args = make([]string, int(argc))
		for i in 0..<int(argc) { os.args[i] = string(argv[i]) }
		app_main()
		free_all(context.temp_allocator)
		// No pointers into this heap survive the module. External handles
		// and threads have already been closed by app_main.
		for ptr in reload_heap.allocation_map { free(ptr, backing) }
		mem.tracking_allocator_destroy(&reload_heap)
		runtime.default_temp_allocator_destroy((^runtime.Default_Temp_Allocator)(context.temp_allocator.data))
		return reload_requested ? 1 : 0
	}
}

@(private)
dev_reload_poll :: proc(ui: ^Ui_State = nil) -> bool {
	when #config(WN_RELOAD, false) {
		gate := Dev_Reload_Gate.Ready
		// Let writes settle and keep unsent attachments/edits in the live UI.
		// Ordinary compose text is already persisted by stash_draft.
		if ui != nil {
			if len(ui.staged) > 0 || ui.editing != "" || reload_jobs_busy() || gimg_writes_pending() { gate = .Busy }
			if len(ui.issue_subject) + len(ui.issue_body) + len(ui.issue_labels) > 0 || ui.issue_ticket != 0 { gate = .Busy }
			for _, files in ui.staged_drafts { if len(files) > 0 { gate = .Busy; break } }
			for p in ui.pending {
				if !p.dismissed && !p.queued && !p.failed { gate = .Busy; break }
			}
		}
		request := wn_dev_reload(gate)
		reload_requested = request == .Reload_App
		return request != .Keep_Running
	}
	return false
}
