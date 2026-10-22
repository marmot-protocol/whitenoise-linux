package main

import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"

// Inspect the modal's actual draw commands, including the untouched form.
// Create must be recognizable before any input or pointer interaction.
@(test)
poll_modal_action_hierarchy :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	// Keep font metrics independent of SDL's shared font/pixel-scale state.
	clay.SetMeasureTextFunction(
		proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
			return {f32(text.length) * f32(config.fontSize) / 2, f32(config.fontSize)}
		},
		nil,
	)
	defer {clay.SetCurrentContext(previous); delete(memory)}
	defer clay.SetPointerState({-1, -1}, false)

	ui := Ui_State{}
	poll_reset(&ui)
	defer {
		delete(ui.poll_question)
		for input in ui.poll_inputs {delete(input)}
		delete(ui.poll_inputs)
	}

	// Test both the empty form and an edited form. Styling must not depend
	// on whether a poll can be submitted yet.
	for populated in ([]bool{false, true}) {
		if populated {
			append(&ui.poll_question, "Where?")
			append(&ui.poll_inputs[0], "Here")
			append(&ui.poll_inputs[1], "There")
		}
		for target in ([]string{"", "PollCreate", "PollCancel"}) {
			clay.SetPointerState({-1, -1}, false)
			clay.BeginLayout()
			poll_modal(&ui)
			clay.EndLayout(0)
			if target != "" {
				box := clay.GetElementData(clay.ID(target)).boundingBox
				clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
			}
			clay.BeginLayout()
			poll_modal(&ui)
			commands := clay.EndLayout(0)
			create_box := clay.GetElementData(clay.ID("PollCreate")).boundingBox
			cancel_box := clay.GetElementData(clay.ID("PollCancel")).boundingBox
			inside :: proc(inner, outer: clay.BoundingBox) -> bool {
				return inner.x >= outer.x && inner.y >= outer.y &&
				       inner.x + inner.width <= outer.x + outer.width &&
				       inner.y + inner.height <= outer.y + outer.height
			}
			create_found, cancel_found, create_text_found, cancel_text_found := false, false, false, false
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .Rectangle {
					color := command.renderData.rectangle.backgroundColor
					if command.id == clay.ID("PollCreate").id {
						create_found = true
						testing.expect_value(t, color, ACCENT)
					}
					if command.id == clay.ID("PollCancel").id {
						cancel_found = true
						testing.expect_value(t, color, target == "PollCancel" ? ACCENT : ROW_BG)
					}
				}
				if command.commandType == .Text {
					data := command.renderData.text
					label := string(data.stringContents.chars[:data.stringContents.length])
					// A wrapped "Create poll" heading also emits "Create".
					// Only the label inside the action belongs to that button.
					if label == tr("Create") && inside(command.boundingBox, create_box) {
						create_text_found = true
						testing.expect_value(t, data.textColor, ON_ACCENT)
					}
					if label == tr("Cancel") && inside(command.boundingBox, cancel_box) {
						cancel_text_found = true
						testing.expect_value(t, data.textColor, target == "PollCancel" ? BG : TEXT)
					}
				}
			}
			testing.expect(t, create_found && cancel_found && create_text_found && cancel_text_found)
		}
	}
}
