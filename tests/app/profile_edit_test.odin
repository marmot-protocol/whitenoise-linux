package main

import "base:runtime"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Run in its own process, like the other SDL layout regressions.
@(test)
profile_edit_summary :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "profile_edit_summary" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1100, 1100, "Profile edit summary")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	memory: []u8
	init_layout(&memory, 32768, {1100, 1100})
	defer delete(memory)
	ui := Ui_State {
		page = .Profile,
		profile = {
			name = "Original name",
			username = "original",
			about = "Original about",
			nip05 = "original@example.invalid",
			lud16 = "original@wallet.invalid",
		},
	}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false}
	defer {
		delete(ui.name_input); delete(ui.about_input)
		delete(ui.nip05_input); delete(ui.lud16_input)
	}
	check := proc(t: ^testing.T, ui: ^Ui_State, editing: bool) {
		for _ in 0 ..< 3 {
			clay.SetPointerState({-100, -100}, false)
			clay.BeginLayout()
			profile_pane(ui)
			clay.EndLayout(0)
		}
		testing.expect(t, clay.GetElementData(clay.ID("ProfileForm")).found == editing)
		testing.expect(
			t,
			clay.GetElementData(clay.ID("ProfileEyebrow")).found == !editing,
			"the PROFILE heading is only present in view mode",
		)
		testing.expect(
			t,
			clay.GetElementData(clay.ID("ProfileCard")).found == !editing,
			"the stale read-only summary must be absent while editing",
		)
		testing.expect(
			t,
			clay.GetElementData(clay.ID("ProfileIdCard")).found,
			"identity remains visible in either mode",
		)
		if editing {
			for id in ([]string{"NameBox", "Nip05Box", "Lud16Box", "ChangePicBtn", "PublishProfileBtn"}) {
				testing.expect(t, clay.GetElementData(clay.ID(id)).found, id)
			}
		}
	}
	check(t, &ui, false)
	edit_profile_start(&ui)
	ed_set(&ui, &ui.name_input, "Draft name")
	ed_set(&ui, &ui.nip05_input, "draft@example.invalid")
	check(t, &ui, true)
	// Cancel through the actual header action, preserving committed values.
	box := clay.GetElementData(clay.ID("EditProfileBtn")).boundingBox
	clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
	forced_release = true
	handle_profile(&ui, nil)
	forced_release = false
	testing.expect(t, ui.profile.editing)
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.Discard_Profile)
	run_confirm(&ui, nil)
	testing.expect(t, !ui.profile.editing)
	testing.expect_value(t, ui.profile.name, "Original name")
	testing.expect_value(t, ui.profile.nip05, "original@example.invalid")
	check(t, &ui, false)
	// Model the completed-publish state after a profile reload, without
	// dispatching network work in this layout regression.
	edit_profile_start(&ui)
	check(t, &ui, true)
	ui.profile.nip05 = "saved@example.invalid"
	ui.profile.editing = false
	check(t, &ui, false)
	clay.BeginLayout()
	profile_pane(&ui)
	commands := clay.EndLayout(0)
	found_saved := false
	for command in commands.internalArray[:commands.length] {
		if command.commandType != .Text {continue}
		text := command.renderData.text.stringContents
		if string(text.chars[:text.length]) == "saved@example.invalid" {found_saved = true}
	}
	testing.expect(t, found_saved, "the restored summary renders the reloaded value")
}

@(test)
profile_empty_fields :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "profile_empty_fields" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1100, 1100, "Empty profile fields")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	memory: []u8
	init_layout(&memory, 32768, {1100, 1100})
	defer delete(memory)
	ui := Ui_State {
		page = .Profile,
	}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer {
		delete(ui.name_input); delete(ui.about_input)
		delete(ui.nip05_input); delete(ui.lud16_input)
	}
	for stage in 0 ..< 3 {
		if stage == 1 {edit_profile_start(&ui)}
		if stage == 2 {ed_set(&ui, &ui.name_input, "Draft name")}
		commands: clay.ClayArray(clay.RenderCommand)
		for _ in 0 ..< 3 {
			clay.SetPointerState({-100, -100}, false)
			clay.BeginLayout()
			profile_pane(&ui)
			commands = clay.EndLayout(0)
		}
		if stage > 0 {
			for id in ([]string{"NameBox", "ComposeBox", "Nip05Box", "Lud16Box"}) {
				box := clay.GetElementData(clay.ID(id)).boundingBox
				found_text := false
				for command in commands.internalArray[:commands.length] {
					if command.commandType != .Text {continue}
					bounds := command.boundingBox
					if bounds.x < box.x ||
					   bounds.y < box.y ||
					   bounds.x + bounds.width > box.x + box.width ||
					   bounds.y + bounds.height > box.y + box.height {continue}
					found_text = true
					typed := stage == 2 && id == "NameBox"
					testing.expect(
						t,
						command.renderData.text.textColor == (typed ? TEXT : TEXT_DIM),
						"empty hints and typed profile values must remain visually distinct",
					)
				}
				testing.expect(t, found_text, "each editable field renders a value or hint")
			}
		}
		testing.expect(
			t,
			len(ui.about_input) == 0 && len(ui.nip05_input) == 0 && len(ui.lud16_input) == 0,
			"hints must never become profile values",
		)
		if stage < 2 {
			testing.expect_value(t, len(ui.name_input), 0)
		} else {
			testing.expect_value(t, string(ui.name_input[:]), "Draft name")
		}
	}
}
