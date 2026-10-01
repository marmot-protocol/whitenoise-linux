package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

@(test)
recent_emoji_survives_restart :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-emoji-settings", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}

	ui: Ui_State
	load_settings(&ui)
	for entry, i in QUICK_REACT {
		testing.expect_value(t, ui.prefs.recent_emoji[i], entry.emoji)
	}
	picks := []string {
		"🐙",
		"🦊",
		"🦀",
		"🐝",
		"🐢",
		"🦉",
		"🐋",
		"🦔",
		"🦦",
		"🐙",
	}
	for emoji in picks {
		ui.picker_mode = .Quick_Reaction
		pick_emoji(&ui, nil, emoji)
	}
	// Picking a borrowed recent string must move it, not duplicate or free it.
	ui.picker_mode = .Quick_Reaction
	pick_emoji(&ui, nil, ui.prefs.recent_emoji[3])
	settings_stop(&ui)

	reopened: Ui_State
	load_settings(&reopened)
	expected := []string{"🐋", "🐙", "🦦", "🦔", "🦉", "🐢", "🐝", "🦀"}
	testing.expect_value(t, len(reopened.prefs.recent_emoji), len(expected))
	for emoji, i in expected {
		if i < len(reopened.prefs.recent_emoji) {
			testing.expect_value(t, reopened.prefs.recent_emoji[i], emoji)
		}
	}
}

@(test)
recent_emoji_legacy_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-emoji-migration", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	path := settings_path()
	os.make_directory(fmt.tprintf("%s/whitenoise", home))
	if !testing.expect(
		t,
		os.write_entire_file(path, `{"prefs":{"zoom_pct":125,"recent_searches":["retained"]}}`) ==
		nil,
	) {return}
	ui: Ui_State
	load_settings(&ui)
	testing.expect_value(t, ui.prefs.zoom_pct, 125)
	testing.expect_value(t, ui.prefs.recent_searches[0], "retained")
	for entry, i in QUICK_REACT {
		testing.expect_value(t, ui.prefs.recent_emoji[i], entry.emoji)
	}
}
