package main

import "core:strconv"
import "core:strings"
import "core:sync"

@(private)
Location_Done :: struct {
	request, generation: u64,
	pin:                 Geo_Point,
	ok:                  bool,
}

@(private)
location_mutex: sync.Mutex
@(private)
location_done: [dynamic]Location_Done
@(private)
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

when ODIN_OS != .Linux {
	@(private)
	location_start :: proc(ui: ^Ui_State) {
		if !ui.location_open || ui.location_busy {return}
		ui.location_request += 1
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
