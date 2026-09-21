package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"

@(private)
system_theme_index := -1
@(private = "file")
system_theme_path: string
@(private = "file")
system_theme_source: string
@(private = "file")
system_theme_pending: []u8
@(private = "file")
system_theme_worker: ^thread.Thread
@(private = "file")
system_theme_next: f64

// Convert the Omarchy palette into a shareable WN snapshot. Require the
// three seeds so a partial write keeps the last working theme.
@(private)
parse_system_theme :: proc(source: string) -> (Theme_Pack, bool) {
	if len(source) > THEME_MAX_BYTES {return {}, false}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "name = \"Omarchy\"\n[colors]")
	for pair, i in ([][2]string{{"background", "bg"}, {"foreground", "text-hi"}, {"accent", "accent-base"}, {"red", "danger"}, {"yellow", "warning"}, {"color1", "danger"}, {"color3", "warning"}}) {
		value := strings.trim_left_space(toml_str_key(source, pair[0]))
		// Accept either TOML quote style and trailing comments.
		value = strings.trim_left(value, "\"'")
		if len(value) < 7 || value[0] != '#' {
			if i < 3 {return {}, false}
			continue
		}
		if len(value) > 7 &&
		   value[7] != '\"' &&
		   value[7] != '\'' &&
		   value[7] != ' ' &&
		   value[7] != '\t' {
			return {}, false
		}
		_, valid := strconv.parse_uint(value[1:7], 16)
		if !valid {return {}, false}
		if i == 2 {
			fmt.sbprintln(&b, "accent-base = [")
			for _ in 0 ..< 5 {fmt.sbprintf(&b, "\"%s\",\n", value[:7])}
			fmt.sbprintln(&b, "]")
		} else {
			fmt.sbprintf(&b, "%s = \"%s\"\n", pair[1], value[:7])
		}
	}
	pack := parse_theme(N_("System"), "@system", strings.to_string(b), default_pack())
	pack.source = strings.clone(strings.to_string(b))
	return pack, true
}

@(private)
load_system_theme :: proc() {
	system_theme_index = -1
	delete(system_theme_path)
	delete(system_theme_source)
	system_theme_path, system_theme_source = "", ""
	home := os.get_env("HOME", context.temp_allocator)
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if len(cfg) == 0 {cfg = fmt.tprintf("%s/.config", home)}
	for path in ([]string{fmt.tprintf("%s/.local/state/omarchy/current/theme/colors.toml", home), fmt.tprintf("%s/omarchy/current/theme/colors.toml", cfg), fmt.tprintf("%s/.config/omarchy/current/theme/colors.toml", home)}) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {continue}
		pack, ok := parse_system_theme(string(data))
		if !ok {continue}
		system_theme_path = strings.clone(path)
		system_theme_source = strings.clone(string(data))
		system_theme_index = len(theme_packs)
		append(&theme_packs, pack)
		return
	}
}

@(private)
poll_system_theme :: proc(ui: ^Ui_State, now: f64) {
	if system_theme_worker != nil {
		if !thread.is_done(system_theme_worker) {return}
		thread.join(system_theme_worker)
		thread.destroy(system_theme_worker)
		system_theme_worker = nil
		pending := system_theme_pending
		defer delete(pending)
		source := string(pending)
		if len(source) > 0 && source != system_theme_source {
			if pack, ok := parse_system_theme(source); ok {
				delete(theme_packs[system_theme_index].source)
				theme_packs[system_theme_index] = pack
				delete(system_theme_source)
				system_theme_source = strings.clone(source)
				if ui.theme == system_theme_index {apply_theme(ui.theme, ui.accent)}
			}
		}
	}
	if system_theme_index < 0 || now < system_theme_next {return}
	// ponytail: one read per second; use inotify if subsecond updates matter.
	system_theme_next = now + 1
	system_theme_worker = thread.create(proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		system_theme_pending, _ = os.read_entire_file(system_theme_path, context.allocator)
	})
	thread.start(system_theme_worker)
}

@(private)
stop_system_theme :: proc() {
	if system_theme_worker == nil {return}
	thread.join(system_theme_worker)
	thread.destroy(system_theme_worker)
	system_theme_worker = nil
	delete(system_theme_pending)
}
