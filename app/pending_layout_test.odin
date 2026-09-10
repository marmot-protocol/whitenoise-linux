package main

import "core:sync"
import "core:testing"
import "core:time"
import clay "../vendor/clay/bindings/odin/clay-odin"

@(test)
pending_layout_balanced :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	errors: int
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {800, 600}, {
		handler = proc "c" (error: clay.ErrorData) { (^int)(error.userData)^ += 1 },
		userData = &errors,
	})
	clay.SetMeasureTextFunction(measure_text, nil)
	ui: Ui_State
	clay.BeginLayout()
	if clay.UI(clay.ID("TestRoot"))({}) {
		if clay.UI(clay.ID("TestTimeline"))({}) {
			pending_row(0, &ui, Pending_Send{body = "Sending", sending_since = time.tick_now()})
		}
	}
	testing.expect(t, errors == 0, "Pending buttons must not close unopened layout elements")
	if errors > 0 {
		return // A corrupt tree can loop indefinitely in EndLayout.
	}
	clay.EndLayout(0)
	testing.expect_value(t, errors, 0)
}
