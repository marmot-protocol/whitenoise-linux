package main

import "core:sync"
import "core:testing"
import "core:time"
import "nendo"

@(test)
pending_layout_balanced :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	memory := make([]u8, int(nendo.min_memory_size()))
	defer {
		nendo.set_context(previous)
		delete(memory)
	}
	errors: int
	nendo.init(memory, {800, 600}, {
		handler = proc(error: nendo.Error) {(^int)(error.user_data)^ += 1},
		user_data = &errors,
	})
	nendo.set_measure_text(measure_text, nil)
	ui: Ui_State
	nendo.begin()
	if nendo.box(nendo.id("TestRoot"))({}) {
		if nendo.box(nendo.id("TestTimeline"))({}) {
			pending_row(0, &ui, Pending_Send{body = "Sending", sending_since = time.tick_now()})
		}
	}
	testing.expect(t, errors == 0, "Pending buttons must not close unopened layout elements")
	if errors > 0 {
		return // A corrupt tree can loop indefinitely in EndLayout.
	}
	nendo.end(0)
	testing.expect_value(t, errors, 0)
}
