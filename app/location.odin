package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "file")
Location_Job :: struct {
	request, generation: u64,
}

@(private = "file")
Location_Done :: struct {
	request, generation: u64,
	pin:                 Geo_Point,
	ok:                  bool,
}

@(private = "file")
location_mutex: sync.Mutex
@(private = "file")
location_done: [dynamic]Location_Done
@(private = "file")
location_generation: u64

// The helper's only success output is two ASCII coordinates. Range checks
// reject NaN and infinities as well as values outside geographic bounds.
@(private)
location_parse :: proc(output: []u8) -> (pin: Geo_Point, ok: bool) {
	if len(output) > 128 {return}
	fields := strings.fields(string(output), context.temp_allocator)
	if len(fields) != 2 {return}
	lat, latitude_ok := strconv.parse_f64(fields[0])
	lon, longitude_ok := strconv.parse_f64(fields[1])
	if !latitude_ok || !longitude_ok {return}
	ok = lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
	if ok {pin = {lat, lon}}
	return
}

// A module generation is independent of Ui_State's counter: locking and
// unlocking can replace Ui_State while an old worker is still winding down.
@(private)
location_cancel :: proc(ui: ^Ui_State) {
	sync.lock(&location_mutex)
	location_generation += 1
	sync.unlock(&location_mutex)
	ui.location_busy = false
}

@(private = "file")
location_current :: proc(generation: u64) -> bool {
	sync.lock(&location_mutex)
	defer sync.unlock(&location_mutex)
	return generation == location_generation
}

@(private = "file")
location_acquire :: proc(generation: u64) -> (pin: Geo_Point, ok: bool) {
	when ODIN_OS == .Linux {
		if !location_current(generation) {return}
		output_read, output_write, pipe_error := os.pipe()
		if pipe_error != nil {return}
		defer os.close(output_read)
		// tool_exec is the curl-only OpenBSD broker contract. This helper
		// is Linux-only and executes directly, exclusively on this worker.
		child, start_error := os.process_start(
			{command = {helper_path("wn-location")}, stdout = output_write},
		)
		os.close(output_write)
		if start_error != nil {return}
		// Check immediately after spawning: Cancel can land during exec.
		// The child handle is never shared with the UI or another worker.
		for location_current(generation) {
			state, wait_error := os.process_wait(child, 50 * time.Millisecond)
			if wait_error == nil {
				if state.success && state.exit_code == 0 && location_current(generation) {
					output: [129]u8
					n, read_error := os.read(output_read, output[:])
					if read_error == nil {
						return location_parse(output[:n])
					}
				}
				return
			}
			if wait_error != os.General_Error.Timeout {return}
		}
		// SIGTERM enters the helper's normal Request.Close/Session.Close
		// cleanup. Bound its grace period; always reap before returning.
		_ = os.process_terminate(child)
		_, wait_error := os.process_wait(child, 1500 * time.Millisecond)
		if wait_error == os.General_Error.Timeout {
			_ = os.process_kill(child)
			_, _ = os.process_wait(child)
		}
	}
	return
}

@(private = "file")
location_worker :: proc(job: Location_Job) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	done := Location_Done {
		request    = job.request,
		generation = job.generation,
	}
	done.pin, done.ok = location_acquire(job.generation)
	sync.lock(&location_mutex)
	append(&location_done, done)
	sync.unlock(&location_mutex)
}

// Permission is requested only by this explicit picker action, never on open.
@(private)
location_start :: proc(ui: ^Ui_State) {
	if !ui.location_open || ui.location_busy {return}
	ui.location_request += 1
	ui.location_error = false
	when ODIN_OS == .Linux {
		ui.location_busy = true
		sync.lock(&location_mutex)
		location_generation += 1
		generation := location_generation
		sync.unlock(&location_mutex)
		append(
			&send_threads,
			thread.create_and_start_with_poly_data(
				Location_Job{request = ui.location_request, generation = generation},
				location_worker,
			),
		)
	} else {
		ui.location_busy = false
		ui.location_error = true
	}
}

// Called at the picker frame boundary. Closing, reopening, or manually
// moving its map invalidates a pending result by advancing location_request.
@(private)
drain_location :: proc(ui: ^Ui_State) {
	sync.lock(&location_mutex)
	done := location_done
	location_done = {}
	generation := location_generation
	sync.unlock(&location_mutex)
	defer delete(done)
	for result in done {
		if !ui.location_open ||
		   result.request != ui.location_request ||
		   result.generation != generation {continue}
		ui.location_busy = false
		ui.location_error = !result.ok
		if result.ok {
			ui.location_pin = result.pin
			ui.location_selected = true
			geo_picker_center(ui, result.pin)
		}
	}
}
