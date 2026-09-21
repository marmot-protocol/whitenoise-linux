package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:sync"
import "core:testing"

@(test)
system_theme_layout :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous := clay.GetCurrentContext()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}
	errors: int
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{1200, 2000},
		{
			handler = proc "c" (error: clay.ErrorData) {(^int)(error.userData)^ += 1},
			userData = &errors,
		},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	saved_packs := theme_packs
	saved_index := system_theme_index
	theme_packs = make([dynamic]Theme_Pack)
	append(&theme_packs, default_pack(), default_pack())
	system_theme_index = 1
	defer {
		delete(theme_packs)
		theme_packs = saved_packs
		system_theme_index = saved_index
	}
	for index in 0 ..< 2 {
		ui := Ui_State {
			theme = index,
		}
		clay.BeginLayout()
		if clay.UI(clay.ID("SystemTestRoot"))({}) {
			settings_appearance(&ui)
		}
		testing.expect_value(t, errors, 0)
		if errors > 0 {return} 	// EndLayout cannot traverse an unbalanced tree.
		clay.EndLayout(0)
		testing.expect_value(t, errors, 0)
		testing.expect_value(
			t,
			clay.GetElementData(clay.ID("RowAccent")).found,
			index != system_theme_index,
		)
	}
}
