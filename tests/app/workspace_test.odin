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
		{`"window_w":-1,"window_h":0,"settings_section":6,"settings_tab":999`, .Appearance, 0},
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
	data := `{"prefs":{"zoom_pct":125,"page":1,"window_w":1130,"window_h":820,"reduce_motion":true,"folders":["Valid","Retired","Future","Negative"],"folder_of":{"chat":"Retired"},"pinned":{"chat":true},"folder_rules":{"Valid":{"match":0,"rules":[{"kind":0,"value":"work"}]},"Retired":{"match":0,"rules":[{"kind":0,"value":"work"},{"kind":6}]},"Future":{"match":1,"rules":[{"kind":999}]},"Negative":{"match":0,"rules":[{"kind":-1}]}},"unknown_setting":{"nested":[1,2,3]}}}`
	if !testing.expect(
		t,
		os.write_entire_file(settings_path(), transmute([]u8)data) == nil,
	) {return}
	ui: Ui_State
	load_settings(&ui, .Preferences)
	testing.expect_value(t, ui.page, Page.Contacts)
	testing.expect_value(t, ui.prefs.zoom_pct, 125)
	testing.expect_value(t, ui.prefs.window_w, i32(1130))
	testing.expect_value(t, ui.prefs.window_h, i32(820))
	testing.expect(t, ui.prefs.reduce_motion && ui.prefs.pinned["chat"])
	testing.expect_value(t, len(ui.prefs.folders), 4)
	testing.expect_value(t, ui.prefs.folder_of["chat"], "Retired")
	testing.expect_value(t, len(ui.prefs.folder_rules), 1)
	valid, found := ui.prefs.folder_rules["Valid"]
	if !testing.expect(t, found) {return}
	if !testing.expect_value(t, len(valid.rules), 1) {return}
	testing.expect_value(t, valid.rules[0].kind, Folder_Rule_Kind.Name_Has)
	testing.expect_value(t, valid.rules[0].value, "work")
	for name in ([]string{"Retired", "Future", "Negative"}) {
		testing.expect(t, name not_in ui.prefs.folder_rules)
	}
}
