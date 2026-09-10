package main

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"

@(private)
clay_test_mutex: sync.Mutex

@(test)
pending_delete_clicks :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous_home := data_home
	data_home = "/tmp/wn-pending-click-test"
	defer { data_home = previous_home }

	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	ui := Ui_State{selected = -1, row_menu = -1}
	append(&ui.accounts, "Test")
	defer delete(ui.accounts)
	defer delete(ui.pending)
	client: marmot.Client
	forced_release = true
	defer forced_release = false
	buttons := []string{"PendingDelete", "PendingDeleteEnd"}
	started := time.tick_now()
	fresh := Pending_Send{sending_since = started}
	testing.expect(t, pending_can_delete(Pending_Send{failed = true}, started))
	testing.expect(t, pending_can_delete(Pending_Send{queued = true}, started))
	testing.expect(t, !pending_can_delete(fresh, time.tick_add(started, PENDING_DELETE_DELAY - time.Nanosecond)))
	testing.expect(t, pending_can_delete(fresh, time.tick_add(started, PENDING_DELETE_DELAY)))
	clay.BeginLayout()
	pending_row(0, &ui, fresh)
	clay.EndLayout(0)
	for button in buttons {
		testing.expect(t, !clay.GetElementData(clay.ID(button, 0)).found)
	}
	for button in buttons {
		for state in 0 ..< 3 {
			append(&ui.pending, Pending_Send{ticket = 1, body = strings.clone("stuck"), failed = state == 0, queued = state == 1, sending_since = time.tick_add(started, -PENDING_DELETE_DELAY)})
			clay.BeginLayout()
			pending_row(0, &ui, ui.pending[0])
			clay.EndLayout(0)
			data := clay.GetElementData(clay.ID(button, 0))
			testing.expect(t, data.found)
			clay.SetPointerState({data.boundingBox.x + 1, data.boundingBox.y + 1}, false)
			handle_chat(&ui, &client)
			if state == 2 {
				testing.expect(t, ui.pending[0].dismissed)
				clay.BeginLayout()
				pending_row(0, &ui, ui.pending[0])
				clay.EndLayout(0)
				testing.expect(t, !clay.GetElementData(clay.ID("PendingRow", 0)).found)
				append(&sends_done, Send_Done{ticket = 1, status = .PUBLISH, err = strings.clone("too large")})
				drain_sends(&ui, nil)
			}
			testing.expect_value(t, len(ui.pending), 0)
		}
	}
}

@(test)
layout_arena_grows :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)

	previous := clay.GetCurrentContext()
	previous_overflow := layout_overflow
	memory: []u8
	defer {
		clay.SetCurrentContext(nil)
		clay.SetMaxElementCount(32768)
		clay.SetCurrentContext(previous)
		layout_overflow = previous_overflow
		delete(memory)
	}
	ui: Ui_State
	body := strings.repeat("x\n", 32769)
	defer delete(body)
	p := Pending_Send{body = body, failed = true}

	init_layout(&memory, 32768, {800, 600})
	clay.BeginLayout()
	pending_row(0, &ui, p)
	clay.EndLayout(0)
	testing.expect(t, layout_overflow)

	init_layout(&memory, clay.GetMaxElementCount() * 2, {800, 600})
	clay.BeginLayout()
	pending_row(0, &ui, p)
	clay.EndLayout(0)
	testing.expect(t, !layout_overflow)
	testing.expect(t, clay.GetElementData(clay.ID("PendingDelete", 0)).found)
}
