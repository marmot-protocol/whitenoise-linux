package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import sdl "vendor:sdl3"

@(private)
System_Appearance :: struct {
	tone:                         enum {
		Unknown,
		Dark,
		Light,
	},
	reduce_motion, high_contrast: bool,
	motion_known, contrast_known: bool,
}

@(private = "file")
system_appearance, pending_appearance: System_Appearance

@(private)
reduce_motion_enabled :: proc(prefs: ^Prefs) -> bool {
	if prefs == nil {return system_appearance.reduce_motion}
	if prefs.motion_override || prefs.reduce_motion {return prefs.reduce_motion}
	return system_appearance.reduce_motion
}

@(private)
high_contrast_enabled :: proc(prefs: ^Prefs) -> bool {
	if prefs != nil && prefs.contrast_override {return prefs.high_contrast}
	return system_appearance.high_contrast
}

@(private)
system_theme_index := -1
@(private = "file")
system_theme_path: string
@(private = "file")
system_theme_din: bool
@(private = "file")
system_theme_source: string
@(private = "file")
system_theme_pending: []u8
@(private = "file")
system_theme_worker: ^thread.Thread
@(private = "file")
system_theme_next: f64
@(private = "file")
system_theme_cancel: rawptr

@(private = "file")
system_accent :: proc(b: ^strings.Builder, value: string) {
	fmt.sbprintln(b, "accent-base = [")
	for _ in 0 ..< 5 {fmt.sbprintf(b, "\"%s\",\n", value)}
	fmt.sbprintln(b, "]")
}

@(private = "file")
system_pack :: proc(source: string) -> Theme_Pack {
	pack := parse_theme(N_("System"), "@system", source, default_pack())
	pack.source = strings.clone(source)
	pack.collection = .System
	return pack
}

// Convert Omarchy's palette into a shareable White Noise snapshot. Require the
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
			system_accent(&b, value[:7])
		} else {
			fmt.sbprintf(&b, "%s = \"%s\"\n", pair[1], value[:7])
		}
	}
	return system_pack(strings.to_string(b)), true
}

// Din writes the resolved native palette before any user CSS. Read only its
// marked block, not CSS overrides or the duplicate GTK 4 variables.
@(private)
parse_din_theme :: proc(source: string) -> (Theme_Pack, bool) {
	START :: "/* Din's colors: Din rewrites this block when its theme changes. Add your own below it. */"
	END :: "/* End of Din's colors */"
	block := strings.trim_space(source)
	if !strings.has_prefix(block, START) {return {}, false}
	end := strings.index(block, END)
	if end < 0 {return {}, false}
	block = block[len(START):end]

	colors := make(map[string]string, allocator = context.temp_allocator)
	for line in strings.split_lines_iterator(&block) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] != "@define-color" {continue}
		if len(fields) != 3 || fields[1] in colors {return {}, false}
		if len(fields[2]) != 8 || fields[2][0] != '#' || fields[2][7] != ';' {
			return {}, false
		}
		hex := fields[2][:7]
		for c in hex[1:] {
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return {}, false
			}
		}
		colors[fields[1]] = hex
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "name = \"Din\"\n[colors]")
	for pair in ([][2]string{{"window_bg_color", "bg"}, {"window_fg_color", "text-hi"}, {"sidebar_bg_color", "panel"}, {"sidebar_fg_color", "sidebar-text"}, {"card_bg_color", "elevated"}, {"card_fg_color", "card-text"}, {"view_bg_color", "field"}, {"headerbar_bg_color", "status-bar"}, {"headerbar_fg_color", "header-text"}, {"popover_bg_color", "tooltip"}, {"popover_fg_color", "popover-text"}, {"sidebar_border_color", "card-border"}, {"headerbar_border_color", "divider"}, {"destructive_bg_color", "danger"}}) {
		value, ok := colors[pair[0]]
		if !ok {return {}, false}
		fmt.sbprintf(&b, "%s = \"%s\"\n", pair[1], value)
	}
	accent, has_accent := colors["accent_bg_color"]
	ink, has_ink := colors["accent_fg_color"]
	if !has_accent || !has_ink {return {}, false}
	system_accent(&b, accent)
	// Keep Din's button ink when it meets normal-text contrast.
	if theme_contrast(parse_hex_color(accent), parse_hex_color(ink)) >= 4.5 {
		fmt.sbprintf(&b, "on-accent = \"%s\"\n", ink)
	}
	pack := system_pack(strings.to_string(b))
	// Match Din's profile theme cutoff, not White Noise's gallery cutoff.
	pack.tone = theme_luminance(pack.bg) < 0.2 ? .Dark : .Light
	return pack, true
}

@(private = "file")
read_system_theme :: proc(path: string, allocator: mem.Allocator) -> []u8 {
	file, err := os.open(path)
	if err != nil {return nil}
	defer os.close(file)
	// Bound reads even when gtk.css contains a large user stylesheet.
	buffer: [THEME_MAX_BYTES + 1]u8
	n, read_err := os.read_full(file, buffer[:])
	if read_err != nil && read_err != .EOF {return nil}
	return slice.clone(buffer[:n], allocator)
}

@(private)
load_system_theme :: proc() {
	system_theme_index = -1
	delete(system_theme_path)
	delete(system_theme_source)
	system_theme_path, system_theme_source = "", ""
	system_theme_next = 0
	system_theme_din = false
	system_appearance = {}
	cfg, cfg_err := os.user_config_dir(context.temp_allocator)
	if cfg_err != nil {return}
	when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
		din_session := os.get_env("DIN_DESKTOP_SESSION", context.temp_allocator) == "1"
		din_socket := os.get_env("DIN_SOCKET", context.temp_allocator) != ""
		// Native app launches can carry only DIN_SOCKET. Require Din's
		// palette or a DinOS installation, since Din can run elsewhere too.
		if din_session || din_socket {
			path := fmt.tprintf("%s/gtk-4.0/gtk.css", cfg)
			data := read_system_theme(path, context.temp_allocator)
			pack, ok := parse_din_theme(string(data))
			if ok || din_session || os.exists("/etc/dinos/features.json") {
				if !ok {
					// Preserve System while Din starts exporting its palette.
					pack = system_fallback_pack(.Dark)
				} else {
					system_theme_source = strings.clone(string(data))
				}
				system_theme_din = true
				system_theme_path = strings.clone(path)
				system_theme_index = len(theme_packs)
				append(&theme_packs, pack)
				return
			}
		}
	}
	home, home_err := os.user_home_dir(context.temp_allocator)
	if home_err != nil {return}
	for path in ([3]string{fmt.tprintf("%s/.local/state/omarchy/current/theme/colors.toml", home), fmt.tprintf("%s/omarchy/current/theme/colors.toml", cfg), fmt.tprintf("%s/.config/omarchy/current/theme/colors.toml", home)}) {
		data := read_system_theme(path, context.temp_allocator)
		pack, ok := parse_system_theme(string(data))
		if !ok {continue}
		system_theme_path = strings.clone(path)
		system_theme_source = strings.clone(string(data))
		system_theme_index = len(theme_packs)
		append(&theme_packs, pack)
		return
	}
}

@(private = "file")
system_fallback_pack :: proc(tone: Theme_Tone) -> Theme_Pack {
	pack := theme_packs[tone == .Light ? 1 : 0]
	pack.name, pack.mode, pack.collection = N_("System"), "@system", .System
	pack.source = strings.clone(pack.source)
	return pack
}

@(private)
poll_system_theme :: proc(ui: ^Ui_State, now: f64) {
	if system_theme_worker != nil {
		if !thread.is_done(system_theme_worker) {
			when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
				if system_theme_cancel != nil && now >= system_theme_next + 1 {
					g_cancellable_cancel(system_theme_cancel)
				}
			}
			return
		}
		join_system_theme()
		pending := system_theme_pending
		system_theme_pending = nil
		defer delete(pending)
		source := string(pending)
		live_theme := ui.theme_preview_active ? ui.theme_preview : ui.theme
		reapply := false
		if system_theme_din {
			before := reduce_motion_enabled(&ui.prefs)
			reapply = high_contrast_enabled(&ui.prefs)
			if pending_appearance.motion_known {
				system_appearance.reduce_motion = pending_appearance.reduce_motion
			}
			if pending_appearance.contrast_known {
				system_appearance.high_contrast = pending_appearance.high_contrast
			}
			if pending_appearance.tone != .Unknown {
				system_appearance.tone = pending_appearance.tone
			} else {
				switch sdl.GetSystemTheme() {
				case .UNKNOWN:
				case .DARK:
					system_appearance.tone = .Dark
				case .LIGHT:
					system_appearance.tone = .Light
				}
			}
			reapply = reapply != high_contrast_enabled(&ui.prefs)
			if !before && reduce_motion_enabled(&ui.prefs) {anim_snap_all()}
		}
		current := &theme_packs[system_theme_index]
		if system_theme_din && system_theme_source == "" && system_appearance.tone != .Unknown {
			tone: Theme_Tone = system_appearance.tone == .Light ? .Light : .Dark
			if current.tone != tone {
				delete(current.source)
				current^ = system_fallback_pack(tone)
				reapply ||= live_theme == system_theme_index
			}
		}
		if len(source) > 0 && source != system_theme_source {
			parse := system_theme_din ? parse_din_theme : parse_system_theme
			if pack, ok := parse(source); ok {
				delete(system_theme_source)
				system_theme_source = strings.clone(source)
				if current.source == pack.source {
					delete(pack.source)
				} else {
					delete(current.source)
					current^ = pack
					reapply ||= live_theme == system_theme_index
				}
			}
		}
		if reapply {apply_theme(live_theme, ui.accent)}
	}
	if system_theme_index < 0 || now < system_theme_next {return}
	// ponytail: one read per second. For subsecond updates, watch the
	// directory so Din's atomic replacement of gtk.css is visible too.
	system_theme_next = now + 1
	when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
		if system_theme_din {system_theme_cancel = g_cancellable_new()}
	}
	system_theme_worker = thread.create(proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		system_theme_pending = read_system_theme(system_theme_path, context.allocator)
		when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
			if system_theme_din {pending_appearance = read_din_appearance(system_theme_cancel)}
		}
	})
	thread.start(system_theme_worker)
}

@(private = "file")
join_system_theme :: proc() {
	thread.join(system_theme_worker)
	thread.destroy(system_theme_worker)
	system_theme_worker = nil
	when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
		if system_theme_cancel != nil {
			g_object_unref(system_theme_cancel)
			system_theme_cancel = nil
		}
	}
}

@(private)
stop_system_theme :: proc() {
	if system_theme_worker == nil {return}
	when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
		if system_theme_cancel != nil {g_cancellable_cancel(system_theme_cancel)}
	}
	join_system_theme()
	delete(system_theme_pending)
	system_theme_pending = nil
}
