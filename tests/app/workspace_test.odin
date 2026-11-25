package main

import "core:encoding/json"
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

	fresh: Ui_State
	load_settings(&fresh, .Preferences)
	testing.expect_value(t, fresh.prefs.crop_avatar_shape, Crop_Shape.Circle)

	seeds := []struct {
		prefs:    string,
		category: Settings_Section,
	} {
		{`"settings_section":0`, .Home},
		{`"settings_section":1`, .Advanced},
		{`"settings_section":1,"settings_tab":0`, .Advanced},
		{`"settings_section":1,"settings_tab":1`, .Language},
		{`"settings_section":1,"settings_tab":2`, .Chats},
		{`"settings_section":1,"settings_tab":3`, .Chats},
		{`"settings_section":1,"settings_tab":999`, .Advanced},
		{`"settings_section":2`, .Chats},
		{`"settings_section":3`, .Language},
		{`"window_w":0,"window_h":-1,"settings_section":4,"settings_tab":-1`, .Connection},
		{`"settings_section":5`, .Account},
		{`"window_w":-1,"window_h":0,"settings_section":6,"settings_tab":999`, .Appearance},
		{`"settings_section":7`, .Notifications},
		{`"settings_section":8`, .Privacy},
		{`"settings_section":9,"settings_tab":0,"settings_level":0`, .Advanced},
		{`"settings_section":9,"settings_tab":0,"settings_level":1`, .Privacy},
		{`"settings_section":9,"settings_tab":1,"settings_level":1`, .Advanced},
		{`"settings_section":9,"settings_tab":0,"settings_level":999`, .Advanced},
		{`"settings_section":10`, .Help},
		{`"settings_section":11,"settings_tab":3,"dev_mode":false`, .Home},
		{`"settings_section":11,"dev_mode":true`, .Advanced},
		{`"settings_section":12`, .Home},
		{`"settings_section":12,"dev_mode":true`, .Advanced},
		{`"settings_section":13`, .Advanced},
		{`"settings_section":14`, .Account},
		{`"settings_section":-1`, .Home},
		{`"settings_section":999,"settings_tab":3`, .Home},
		{`"settings_category":0,"settings_section":6`, .Home},
		{`"settings_category":"Notifications","settings_section":6`, .Notifications},
		{`"settings_category":-1,"settings_section":6`, .Home},
		{`"settings_category":999,"settings_section":6`, .Home},
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
		testing.expect_value(t, ui.settings_section, seed.category, value_expr = seed.prefs)
		testing.expect_value(t, ui.prefs.settings_category, seed.category, value_expr = seed.prefs)
		testing.expect_value(t, ui.prefs.window_w, i32(1024))
		testing.expect_value(t, ui.prefs.window_h, i32(700))
	}
	for seed in ([]struct {
			prefs:  string,
			page:   Page,
			filter: Chat_Filter,
		}{{`"chat_filter":3`, .Archived, .Chats}, {`"chat_filter":4`, .Chats, .Chats}, {`"page":1,"chat_filter":3`, .Contacts, .Chats}, {`"chat_filter":999`, .Chats, .Chats}}) {
		data := strings.concatenate({`{"prefs":{"zoom_pct":125,`, seed.prefs, `}}`})
		if !testing.expect(
			t,
			os.write_entire_file(settings_path(), transmute([]u8)data) == nil,
		) {return}
		ui: Ui_State
		load_settings(&ui, .Preferences)
		testing.expect_value(t, ui.page, seed.page)
		testing.expect_value(t, ui.chat_filter, seed.filter)
		testing.expect_value(t, ui.prefs.zoom_pct, 125)
	}
	for seed in ([]struct {
			stored: int,
			shape:  Crop_Shape,
			saved:  int,
		}{{0, .Circle, 2}, {1, .Square, 1}, {2, .Circle, 2}, {3, .Rounded, 3}, {-1, .Circle, 2}, {999, .Circle, 2}}) {
		data := strings.concatenate(
			{
				`{"prefs":{"zoom_pct":100,"crop_avatar_shape":`,
				fmt.tprintf("%d", seed.stored),
				`}}`,
			},
		)
		if !testing.expect_value(
			t,
			os.write_entire_file(settings_path(), transmute([]u8)data),
			nil,
		) {return}
		ui: Ui_State
		load_settings(&ui, .Preferences)
		testing.expect_value(t, ui.prefs.crop_avatar_shape, seed.shape)
		ui.prefs.zoom_pct = 125
		save_settings(&ui)
		loaded, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
		if !testing.expect_value(t, read_err, nil) {return}
		saved: struct {
			prefs: struct {
				crop_avatar_shape, zoom_pct: int,
			},
		}
		if !testing.expect_value(t, json.unmarshal(loaded, &saved), nil) {return}
		testing.expect_value(t, saved.prefs.crop_avatar_shape, seed.saved)
		testing.expect_value(t, saved.prefs.zoom_pct, 125)
	}
	data := `{"prefs":{"zoom_pct":125,"page":1,"settings_section":4,"window_w":1130,"window_h":820,"reduce_motion":true,"folders":["Valid","Retired","Future","Negative","Null child","Unknown mode","Bad type","Duplicate key"],"folder_of":{"chat":"Retired"},"pinned":{"chat":true},"folder_rules":{
		"Valid":{"match":0,"rules":[{"kind":0,"value":"work"}]},
		"Retired":{"match":0,"rules":[{"kind":0,"value":"work"},{"kind":6}]},
		"Future":{"match":1,"rules":[{"kind":999}]},
		"Negative":{"match":0,"rules":[{"kind":-1}]},
		"Null child":{"rules":[{"kind":15,"nested":{"match":1,"rules":[null]}}]},
		"Unknown mode":{"rules":[{"kind":15,"nested":{"match":"None","rules":[{"kind":4}]}}]},
		"Bad type":{"rules":[{"kind":15,"nested":{"match":true,"rules":[{"kind":4}]}}]},
		"Duplicate key":{"rules":[{"kind":15,"nested":{"match":0,"match":1,"rules":[{"kind":4}]}}]}
	}},"unknown_setting":{"nested":[1,2,3]}}`
	if !testing.expect(
		t,
		os.write_entire_file(settings_path(), transmute([]u8)data) == nil,
	) {return}
	ui: Ui_State
	load_settings(&ui, .Preferences)
	testing.expect_value(t, ui.page, Page.Contacts)
	testing.expect_value(t, ui.settings_section, Settings_Section.Connection)
	testing.expect_value(t, ui.prefs.zoom_pct, 125)
	testing.expect_value(t, ui.prefs.window_w, i32(1130))
	testing.expect_value(t, ui.prefs.window_h, i32(820))
	testing.expect(t, ui.prefs.reduce_motion && ui.prefs.pinned["chat"])
	testing.expect_value(t, len(ui.prefs.folders), 8)
	testing.expect_value(t, ui.prefs.folder_of["chat"], "Retired")
	testing.expect_value(t, len(ui.prefs.folder_rules), 1)
	valid, found := ui.prefs.folder_rules["Valid"]
	if !testing.expect(t, found) {return}
	if !testing.expect_value(t, len(valid.rules), 1) {return}
	testing.expect_value(t, valid.rules[0].kind, Folder_Rule_Kind.Name_Has)
	testing.expect_value(t, valid.rules[0].value, "work")
	for name in ([]string{"Retired", "Future", "Negative", "Null child", "Unknown mode", "Bad type", "Duplicate key"}) {
		testing.expect(t, name not_in ui.prefs.folder_rules)
	}

	for route in ([]struct {
			section, category: Settings_Section,
		}{{.Composer, .Chats}, {.Devices, .Account}, {.Agents, .Advanced}, {.Debug, .Advanced}, {.KP, .Advanced}, {.Mute, .Help}}) {
		testing.expect_value(t, settings_category(route.section), route.category)
	}

	ui.settings_section = .Devices
	save_settings(&ui)
	testing.expect_value(t, ui.prefs.settings_category, Settings_Section.Account)
	ui.settings_section = .Home
	save_settings(&ui)
	testing.expect_value(t, ui.prefs.settings_category, Settings_Section.Account)
	loaded, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	saved := string(loaded)
	testing.expect(t, strings.contains(saved, `"settings_category"`))
	for legacy_field in ([]string{`"settings_section"`, `"settings_tab"`, `"settings_level"`}) {
		testing.expect(t, !strings.contains(saved, legacy_field))
	}
	reopened: Ui_State
	load_settings(&reopened, .Preferences)
	testing.expect_value(t, reopened.settings_section, Settings_Section.Account)
	testing.expect_value(t, reopened.prefs.settings_category, Settings_Section.Account)
	testing.expect_value(t, reopened.page, Page.Contacts)
	testing.expect_value(t, reopened.prefs.zoom_pct, 125)
	testing.expect(t, reopened.prefs.reduce_motion && reopened.prefs.pinned["chat"])
}
