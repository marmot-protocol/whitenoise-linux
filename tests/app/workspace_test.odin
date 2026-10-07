package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
workspace_load_boundaries :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-workspace-settings", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	os.make_directory(fmt.tprintf("%s/whitenoise", home))

	seeds := []struct {
		prefs:   string,
		section: Settings_Section,
		tab:     int,
	} {
		{
			`"window_w":-1,"window_h":0,"settings_section":6,"settings_tab":999`,
			.Appearance,
			len(SETTINGS_APPEARANCE_TABS) - 1,
		},
		{`"window_w":0,"window_h":-1,"settings_section":4,"settings_tab":-1`, .Network, 0},
		{`"settings_section":11,"settings_tab":3,"dev_mode":false`, .Home, 0},
		{`"settings_section":999,"settings_tab":3`, .Home, 0},
	}
	for seed in seeds {
		data := strings.concatenate({`{"prefs":{"zoom_pct":100,`, seed.prefs, `}}`})
		if !testing.expect(
			t,
			os.write_entire_file(settings_path(), transmute([]u8)data) == nil,
		) {return}
		ui: Ui_State
		load_settings(&ui, .Preferences)
		testing.expect_value(t, ui.page, Page.Chats)
		testing.expect_value(t, ui.settings_section, seed.section)
		testing.expect_value(t, ui.settings_tab, seed.tab)
		testing.expect_value(t, ui.settings_level, Settings_Level.Menu)
		testing.expect_value(t, ui.prefs.window_w, i32(1024))
		testing.expect_value(t, ui.prefs.window_h, i32(700))
	}
}
