// Rail ordering and folder filtering for the chat-list row actions.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"
import "core:sync"

import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"

@(test)
rail_order_pins_first :: proc(t: ^testing.T) {
	chats := []Chat_Row_Ui{{group_id = "a"}, {group_id = "b"}, {group_id = "c"}, {group_id = "d"}}

	// No pins: marmot's activity order, untouched.
	none: map[string]bool
	defer delete(none)
	plain := rail_order(chats, none, context.allocator)
	defer delete(plain)
	testing.expect_value(t, len(plain), 4)
	for i in 0 ..< 4 {
		testing.expect_value(t, plain[i], i)
	}

	// Pinned rows lead, and both halves keep their relative order.
	pinned: map[string]bool
	pinned["c"] = true
	pinned["b"] = true
	defer delete(pinned)
	order := rail_order(chats, pinned, context.allocator)
	defer delete(order)
	testing.expect_value(t, len(order), 4)
	testing.expect_value(t, order[0], 1) // b
	testing.expect_value(t, order[1], 2) // c
	testing.expect_value(t, order[2], 0) // a
	testing.expect_value(t, order[3], 3) // d
}

@(test)
folder_filter :: proc(t: ^testing.T) {
	folder_of: map[string]string
	folder_of["a"] = "Work"
	folder_of["b"] = "Family"
	defer delete(folder_of)

	// No chip: every chat, assigned or not.
	testing.expect(t, in_folder(folder_of, "a", ""))
	testing.expect(t, in_folder(folder_of, "z", ""))

	testing.expect(t, in_folder(folder_of, "a", "Work"))
	testing.expect(t, !in_folder(folder_of, "b", "Work"))
	testing.expect(t, !in_folder(folder_of, "z", "Work"))
}

@(test)
folder_chip_clicks :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)

	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {600, 400}, {})
	clay.SetMeasureTextFunction(proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, data: rawptr) -> clay.Dimensions {
		return {f32(text.length) * 6, 12}
	}, nil)

	ui := Ui_State{selected = -1, row_menu = -1}
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "a"})
	append(&ui.prefs.folders, "Work", "Family")
	defer delete(ui.accounts)
	defer delete(ui.chats)
	defer delete(ui.prefs.folders)
	defer delete(ui.folder_filter)

	clay.BeginLayout()
	folder_chips(&ui)
	clay.EndLayout(0)
	client: marmot.Client // The filter path must not call the runtime.
	forced_release = true
	defer forced_release = false
	for name, i in ui.prefs.folders {
		box := clay.GetElementData(clay.ID("FolderFilter", u32(i))).boundingBox
		clay.SetPointerState({box.x + 1, box.y + 1}, false)
		handle_chat(&ui, &client)
		testing.expect_value(t, ui.folder_filter, name)
	}
	box := clay.GetElementData(clay.ID("FolderAllChip")).boundingBox
	clay.SetPointerState({box.x + 1, box.y + 1}, false)
	handle_chat(&ui, &client)
	testing.expect_value(t, ui.folder_filter, "")
}
