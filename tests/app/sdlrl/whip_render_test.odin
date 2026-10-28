package sdlrl

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"
import gh "whip:ghostty"
import whip "whip:gui"
import proto "whip:proto"

when #config(WN_WHIP, false) {
	@(private)
	whip_test_text :: proc(pane: u32) -> string {
		for _, pv in whip_mounts[pane].view.panes {
			if pv.term == nil {continue}
			formatter: gh.Formatter
			options := gh.Formatter_Terminal_Options {
				size = size_of(gh.Formatter_Terminal_Options),
				emit = .Plain,
				unwrap = true,
				trim = true,
				extra = {
					size = size_of(gh.Formatter_Terminal_Extra),
					screen = {size = size_of(gh.Formatter_Screen_Extra)},
				},
			}
			assert(gh.formatter_terminal_new(nil, &formatter, pv.term, options) == .Success)
			defer gh.formatter_free(formatter)
			buffer: [^]u8
			length: c.size_t
			assert(gh.formatter_format_alloc(formatter, nil, &buffer, &length) == .Success)
			defer gh.free(nil, buffer, length)
			return strings.clone(string(buffer[:length]), context.allocator)
		}
		panic("missing terminal replica")
	}

	@(test)
	whip_close_pending :: proc(t: ^testing.T) {
		if #config(ODIN_TEST_NAMES, "") != "whip_close_pending" {return}
		sync.lock(&sdl_test_mutex)
		defer sync.unlock(&sdl_test_mutex)
		context.allocator = runtime.default_context().allocator
		InitWindow(480, 320, "Whip pending input close")
		defer CloseWindow()
		whip_input_enabled = true
		defer {whip_input_enabled = false}
		old_hide, old_swallow := hide_on_close, swallow_quit
		defer {hide_on_close, swallow_quit = old_hide, old_swallow}
		hide_on_close = true
		event := sdl.Event {
			type = .TEXT_INPUT,
		}
		event.text.windowID = sdl.GetWindowID(state.window)
		event.text.text = "pending input"
		assert(sdl.PushEvent(&event))
		event = {
			type = .WINDOW_CLOSE_REQUESTED,
		}
		event.window.windowID = sdl.GetWindowID(state.window)
		assert(sdl.PushEvent(&event))
		WindowShouldClose()
		testing.expect(
			t,
			.HIDDEN in sdl.GetWindowFlags(state.window),
			"hide-to-tray remains available while input waits",
		)
		hide_on_close, swallow_quit = false, false
		event = {
			type = .QUIT,
		}
		assert(sdl.PushEvent(&event))
		testing.expect(
			t,
			WindowShouldClose(),
			"closing remains responsive before the terminal mounts",
		)
	}

	@(test)
	whip_render_cache :: proc(t: ^testing.T) {
		if #config(ODIN_TEST_NAMES, "") != "whip_render_cache" || !WhipAvailable() {return}
		sync.lock(&sdl_test_mutex)
		defer sync.unlock(&sdl_test_mutex)
		context.allocator = runtime.default_context().allocator
		home, err := os.make_directory_temp("/tmp", "wn-whip-render-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return}
		defer {os.remove_all(home); delete(home)}
		keys := [?]string {
			"XDG_RUNTIME_DIR",
			"XDG_CONFIG_HOME",
			"XDG_STATE_HOME",
			"XDG_DATA_HOME",
			"ANDROID_AVD_HOME",
			"SHELL",
		}
		previous: [len(keys)]string
		for key, i in keys {previous[i] = os.get_env(key, context.allocator)}
		defer {for key, i in keys {os.set_env(key, previous[i]); delete(previous[i])}}
		for key in keys[:len(keys) - 1] {os.set_env(key, home)}
		os.set_env("SHELL", "/bin/sh")
		cli :: proc(args: []string) {
			command := make([dynamic]string, context.temp_allocator)
			append(&command, #config(WN_WHIP_EXE, "")); append(&command, ..args)
			result, output, errors, err := os.process_exec(
				{command = command[:]},
				context.allocator,
			)
			defer {delete(output); delete(errors)}
			assert(err == nil && result.success, string(errors))
		}
		defer cli({"server", "stop", "default"})
		InitWindow(960, 540, "Whip render cache")
		defer CloseWindow()
		defer WhipClose()
		frame :: proc(project, tab: u32, zoom: f32 = 1) {
			free_all(context.temp_allocator)
			WindowShouldClose()
			BeginDrawing()
			// Supply absolute physical scale: any display density is included,
			// not another multiplier for the embedded terminal to apply.
			sdl.SetRenderScale(state.renderer, zoom, zoom)
			panes := WhipPanes()
			for pane, i in panes {DrawWhipPane(pane.id, f32(i) * 960 / f32(len(panes)) / zoom, 0, 960 / f32(len(panes)) / zoom, 540 / zoom)}
			EndDrawing()
			WhipFrame(.Visible, project, tab)
			WhipControlPoll()
			time.sleep(16 * time.Millisecond)
		}
		mouse :: proc(kind: sdl.EventType, button: MouseButton, x, y: f32) {
			e := sdl.Event {
				type = kind,
			}
			if kind == .MOUSE_MOTION {
				e.motion.windowID = sdl.GetWindowID(state.window)
				e.motion.timestamp = sdl.GetTicksNS()
				e.motion.x, e.motion.y = x, y
			} else {
				e.button.windowID = sdl.GetWindowID(state.window)
				e.button.timestamp = sdl.GetTicksNS()
				e.button.button = button == .RIGHT ? 3 : 1
				e.button.down = kind == .MOUSE_BUTTON_DOWN
				e.button.x, e.button.y = x, y
			}
			assert(sdl.PushEvent(&e))
		}
		for _ in 0 ..< 180 {
			WhipFrame(.Projects, 0, 0)
			if len(WhipProjects()) > 0 {break}
			time.sleep(16 * time.Millisecond)
		}
		if !testing.expect(t, len(WhipProjects()) > 0) {return}
		project := WhipProjects()[0].id
		WhipFrame(.Visible, project, 0)
		if !testing.expect(t, len(WhipTabs()) > 0) {return}
		tab := WhipTabs()[0].id
		for _ in 0 ..< 30 {frame(project, tab)}
		if !testing.expect_value(t, len(WhipPanes()), 1) {return}
		pane := WhipPanes()[0].id
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				"printf '\\033[?25l\\033[H\\033[2Jselection sample\\n'",
				"--enter",
			},
		)
		for _ in 0 ..< 30 {frame(project, tab)}
		ui := whip_mounts[pane]
		if !testing.expect(t, ui != nil && ui.texture != nil) {return}
		baseline := make([]u8, len(ui.pixels))
		copy(baseline, ui.pixels)
		defer delete(baseline)
		// With no AVD installed, the shortcut must still open a visible error
		// panel beside the terminal, then return its space when toggled off.
		device_key := sdl.Event {
			type = .KEY_DOWN,
		}
		device_key.key.windowID = sdl.GetWindowID(state.window)
		device_key.key.down = true
		device_key.key.scancode, device_key.key.key = .A, 'a'
		device_key.key.mod = sdl.KMOD_CTRL | sdl.KMOD_ALT
		full_width := ui.view.geom.main.w
		whip_event(device_key)
		for _ in 0 ..< 30 {frame(project, tab)}
		testing.expect(
			t,
			whip.device_visible(ui.view),
			"Ctrl+Alt+A opens the embedded Android panel",
		)
		testing.expect(
			t,
			ui.view.device.state == .Failed &&
			strings.contains(ui.view.device.status, "No AVD found"),
		)
		testing.expect(
			t,
			ui.view.geom.device.w > 0 && ui.view.geom.main.w < full_width,
			"the Android panel reserves space beside the terminal",
		)
		testing.expect(t, !slice.equal(baseline, ui.pixels), "the Android error panel is painted")
		panel := ui.view.geom.device
		testing.expect_value(
			t,
			whip.hit_test(ui.view, panel.x + panel.w / 2, panel.y + panel.h / 2).kind,
			whip.Hit_Kind.Device,
		)
		testing.expect_value(
			t,
			whip.hit_test(ui.view, panel.x, panel.y + panel.h / 2).kind,
			whip.Hit_Kind.Device_Edge,
		)
		whip_event(device_key)
		for _ in 0 ..< 5 {frame(project, tab)}
		testing.expect(t, !whip.device_visible(ui.view) && ui.view.geom.device.w == 0)
		testing.expect_value(t, ui.view.geom.main.w, full_width)
		revision := ui.frame_revision
		m := ui.view.fonts.metrics
		x, y: f32
		for _, pv in ui.view.panes {
			if pv.term == nil {continue}
			x = f32(pv.view.origin.x) + f32(m.cell_w) * 0.5
			y = f32(pv.view.origin.y) + f32(m.cell_h) * 0.5
			break
		}
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, x, y + f32(m.cell_h) * 5)
		mouse(.MOUSE_BUTTON_UP, .LEFT, x, y + f32(m.cell_h) * 5)
		for _ in 0 ..< 5 {frame(project, tab)}
		testing.expect(
			t,
			ui.frame_revision == revision,
			"an unchanged click reuses the published terminal frame",
		)
		testing.expect(t, slice.equal(baseline, ui.pixels), "a cached click preserves its pixels")
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, x, y)
		frame(project, tab)
		mouse(.MOUSE_MOTION, .LEFT, x + f32(m.cell_w) * 9, y)
		frame(project, tab)
		mouse(.MOUSE_BUTTON_UP, .LEFT, x + f32(m.cell_w) * 9, y)
		frame(project, tab)
		testing.expect(
			t,
			!slice.equal(baseline, ui.pixels),
			"drag selection repaints its highlight",
		)
		testing.expect(
			t,
			strings.contains(string(GetPrimaryText()), "selection"),
			"selection release still copies the selected text",
		)
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, x, y + f32(m.cell_h) * 5)
		mouse(.MOUSE_BUTTON_UP, .LEFT, x, y + f32(m.cell_h) * 5)
		for _ in 0 ..< 3 {frame(project, tab)}
		testing.expect(
			t,
			slice.equal(baseline, ui.pixels),
			"clearing selection repaints the original terminal",
		)
		mouse(.MOUSE_BUTTON_DOWN, .RIGHT, x + f32(m.cell_w) * 4, y + f32(m.cell_h) * 5)
		mouse(.MOUSE_BUTTON_UP, .RIGHT, x + f32(m.cell_w) * 4, y + f32(m.cell_h) * 5)
		frame(project, tab)
		testing.expect(
			t,
			ui.view.mouse.menu.open && !slice.equal(baseline, ui.pixels),
			"right-click menus still paint",
		)
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, 900, 500)
		mouse(.MOUSE_BUTTON_UP, .LEFT, 900, 500)
		frame(project, tab)
		testing.expect(
			t,
			!ui.view.mouse.menu.open && slice.equal(baseline, ui.pixels),
			"closing a menu restores the terminal",
		)
		pv := ui.view.panes[proto.Pane_Id(pane)]
		base_scale, base_px := ui.view.scale, ui.view.fonts.size_px
		base_grid := pv.requested
		base_size := ui.view.config.font_size
		testing.expect(
			t,
			base_scale == 1,
			"absolute renderer scale is not multiplied by display DPI",
		)
		testing.expect_value(t, base_px, base_size * 96 / 72)
		for _ in 0 ..< 30 {frame(project, tab, 2)}
		testing.expect_value(t, ui.view.scale, base_scale * 2)
		testing.expect_value(t, ui.view.fonts.size_px, base_px * 2)
		testing.expect(
			t,
			ui.view.fonts.metrics.cell_h > m.cell_h,
			"host zoom rerasterizes larger glyphs",
		)
		testing.expect(
			t,
			pv.requested.cols < base_grid.cols,
			"fixed physical bounds contain fewer columns at 200%",
		)
		testing.expect_value(t, ui.view.config.font_size, base_size)
		zoom_metrics := ui.view.fonts.metrics
		zx := f32(pv.view.origin.x) + f32(zoom_metrics.cell_w) * 0.5
		zy := f32(pv.view.origin.y) + f32(zoom_metrics.cell_h) * 0.5
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, zx, zy)
		frame(project, tab, 2)
		mouse(.MOUSE_MOTION, .LEFT, zx + f32(zoom_metrics.cell_w) * 9, zy)
		frame(project, tab, 2)
		mouse(.MOUSE_BUTTON_UP, .LEFT, zx + f32(zoom_metrics.cell_w) * 9, zy)
		frame(project, tab, 2)
		testing.expect(
			t,
			strings.contains(string(GetPrimaryText()), "selection"),
			"selection hit testing follows rerasterized cells",
		)
		mouse(.MOUSE_BUTTON_DOWN, .LEFT, zx, zy + f32(zoom_metrics.cell_h) * 5)
		mouse(.MOUSE_BUTTON_UP, .LEFT, zx, zy + f32(zoom_metrics.cell_h) * 5)
		for _ in 0 ..< 5 {frame(project, tab, 2)}
		zoom_revision := ui.frame_revision
		for _ in 0 ..< 5 {frame(project, tab, 2)}
		testing.expect_value(t, ui.frame_revision, zoom_revision)
		// Native font shortcuts remain a point delta, independent of host zoom.
		font_key := sdl.Event {
			type = .KEY_DOWN,
		}
		font_key.key.windowID = sdl.GetWindowID(state.window)
		font_key.key.down = true
		font_key.key.key, font_key.key.mod = '=', sdl.KMOD_CTRL
		whip.event(ui.view, font_key)
		for _ in 0 ..< 30 {frame(project, tab, 2)}
		testing.expect_value(t, pv.font_delta, f32(1))
		testing.expect(
			t,
			pv.fonts != nil && pv.fonts.size_px > base_px * 2,
			"manual terminal font zoom survives host zoom",
		)
		display_event := sdl.Event {
			type = .WINDOW_DISPLAY_SCALE_CHANGED,
		}
		display_event.window.windowID = sdl.GetWindowID(state.window)
		whip.event(ui.view, display_event)
		frame(project, tab, 2)
		testing.expect_value(t, ui.view.scale, base_scale * 2)
		font_key.key.key = '-'
		whip.event(ui.view, font_key)
		for _ in 0 ..< 30 {frame(project, tab)}
		testing.expect_value(t, ui.view.scale, base_scale)
		testing.expect_value(t, ui.view.fonts.size_px, base_px)
		testing.expect_value(t, ui.view.fonts.metrics.cell_w, m.cell_w)
		testing.expect_value(t, ui.view.fonts.metrics.cell_h, m.cell_h)
		testing.expect_value(t, pv.requested.cols, base_grid.cols)
		testing.expect_value(t, pv.font_delta, f32(0))
		pointer := sdl.Event {
			type = .MOUSE_BUTTON_DOWN,
		}
		pointer.button.windowID = sdl.GetWindowID(state.window)
		pointer.button.button = 1
		// Both shared→local and local→shared font changes keep the old font
		// set until an already-owned selection gesture releases normally.
		for delta in ([?]f32{1, 0}) {
			old_fonts, old_scale := pv.fonts, ui.view.scale
			metrics := pv.fonts != nil ? pv.fonts.metrics : ui.view.fonts.metrics
			pointer.type, pointer.button.down = .MOUSE_BUTTON_DOWN, true
			pointer.button.timestamp = sdl.GetTicksNS()
			pointer.button.x = f32(pv.view.origin.x) + f32(metrics.cell_w) * 0.5
			pointer.button.y = f32(pv.view.origin.y) + f32(metrics.cell_h) * 0.5
			testing.expect(t, whip_event(pointer), "the terminal owns the initial selection press")
			testing.expect(t, ui.view.mouse.drag != .None)
			font_key.key.key = delta == 1 ? '=' : '-'
			whip_event(font_key)
			target_scale: f32 = delta == 1 ? 2 : 1
			frame(project, tab, target_scale)
			testing.expect_value(t, pv.font_delta, delta)
			testing.expect_value(t, pv.fonts, old_fonts)
			testing.expect_value(t, ui.view.scale, old_scale)
			testing.expect(
				t,
				ui.view.fonts_pending,
				"active drags defer font resource replacement",
			)
			pointer.type, pointer.button.down = .MOUSE_BUTTON_UP, false
			testing.expect(t, whip_event(pointer), "the real release remains terminal-owned")
			testing.expect(t, ui.view.mouse.drag == .None)
			for _ in 0 ..< 30 {frame(project, tab, target_scale)}
			testing.expect_value(t, ui.view.scale, target_scale)
		}
		// A TUI would report an ordinary mouse press to its PTY. A retained
		// scaling frame instead consumes the complete gesture without reporting.
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				"printf '\\033[?1000h\\033[?1006h'",
				"--enter",
			},
		)
		for _ in 0 ..< 5 {frame(project, tab)}
		frame(project, tab, 2)
		testing.expect(t, ui.scale_pending)
		pointer.type, pointer.button.down = .MOUSE_BUTTON_DOWN, true
		testing.expect(t, whip_event(pointer), "a pending frame cannot leak a press to host chat")
		testing.expect(
			t,
			ui.view.mouse.drag == .None && ui.view.mouse.buttons == 0,
			"pending cells do not start a TUI mouse report",
		)
		testing.expect(t, whip_blocked_buttons != 0)
		for _ in 0 ..< 30 {frame(project, tab, 2)}
		pointer.type, pointer.button.down = .MOUSE_BUTTON_UP, false
		pointer.button.x, pointer.button.y = 2000, 2000
		testing.expect(
			t,
			whip_event(pointer),
			"the matching outside release stays terminal-owned after publication",
		)
		testing.expect_value(t, whip_blocked_buttons, u32(0))
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				"printf '\\033[?1000l\\033[?1006l'",
				"--enter",
			},
		)
		for _ in 0 ..< 30 {frame(project, tab)}
		for _ in 0 ..< 30 {frame(project, tab, 1.25)}
		testing.expect_value(t, ui.view.scale, base_scale * 1.25)
		testing.expect_value(t, ui.view.fonts.size_px, base_px * 1.25)
		for _ in 0 ..< 30 {frame(project, tab)}
		testing.expect_value(t, ui.view.fonts.size_px, base_px)
		testing.expect_value(t, pv.requested.cols, base_grid.cols)
		cli({"pane", "split", fmt.tprintf("%d", pane), "right"})
		cli({"pane", "split", fmt.tprintf("%d", pane), "right"})
		for _ in 0 ..< 120 {
			WhipFrame(.Visible, project, tab)
			if len(WhipPanes()) == 3 {break}
			time.sleep(16 * time.Millisecond)
		}
		if !testing.expect_value(t, len(WhipPanes()), 3) {return}
		testing.expect_value(t, len(whip_mounts), 1)
		// The last leaf is deliberately cold, after another cold leaf in paint order.
		focused := WhipPanes()[2].id
		WhipPaneAct(.Focus, focused)
		frame(project, tab)
		early := sdl.Event {
			type = .TEXT_INPUT,
		}
		early.text.windowID = sdl.GetWindowID(state.window)
		early.text.text = "printf 'focus_early_input\\n'"
		assert(sdl.PushEvent(&early))
		early = {
			type = .KEY_DOWN,
		}
		early.key.windowID = sdl.GetWindowID(state.window)
		early.key.scancode, early.key.key, early.key.down = .RETURN, sdl.K_RETURN, true
		assert(sdl.PushEvent(&early))
		early.type, early.key.down = .KEY_UP, false
		assert(sdl.PushEvent(&early))
		testing.expect(
			t,
			len(whip_mounts) == 2,
			"only one cold native mount is initialized per frame",
		)
		frame(project, tab)
		testing.expect(t, len(whip_mounts) == 3, "pending mounts continue on subsequent frames")
		for _ in 0 ..< 30 {frame(project, tab)}
		for _, mount in whip_mounts {testing.expect(t, mount.texture != nil, "every pending terminal eventually renders")}
		focused_text, previous_text := whip_test_text(focused), whip_test_text(pane)
		defer {delete(focused_text); delete(previous_text)}
		testing.expect(
			t,
			strings.contains(focused_text, "\nfocus_early_input\n"),
			"early input executes in the focused cold split",
		)
		testing.expect(
			t,
			!strings.contains(previous_text, "focus_early_input"),
			"early input never reaches the previous split",
		)
		for expected in 1 ..= 3 {
			frame(project, tab, 2)
			refreshed := 0
			for _, mount in whip_mounts {
				if mount.view.scale == base_scale * 2 {refreshed += 1}
				testing.expect(
					t,
					mount.texture != nil,
					"queued zoom refreshes retain valid textures",
				)
			}
			testing.expect(
				t,
				refreshed == expected,
				"only one mounted font set refreshes per frame",
			)
		}
		for _ in 0 ..< 30 {frame(project, tab)}
		WhipPaneAct(.Focus, pane)
		for _ in 0 ..< 5 {frame(project, tab)}
		untouched := whip_mounts[WhipPanes()[2].id]
		untouched_revision := untouched.frame_revision
		old_size := ui.view.config.font_size
		if !os.is_dir(fmt.tprintf("%s/whip", home)) {
			assert(os.make_directory_all(fmt.tprintf("%s/whip", home)) == nil)
		}
		assert(
			os.write_entire_file(
				fmt.tprintf("%s/whip/config", home),
				transmute([]u8)fmt.tprintf("font-size = %g\n", old_size + 3),
			) ==
			nil,
		)
		WhipPaneAct(.Focus, WhipPanes()[1].id)
		for _ in 0 ..< 5 {frame(project, tab)}
		WhipPaneAct(.Focus, pane)
		for _ in 0 ..< 5 {frame(project, tab)}
		testing.expect(
			t,
			untouched.frame_revision == untouched_revision,
			"focus broadcasts do not repaint an unrelated terminal",
		)
		testing.expect(
			t,
			ui.view.config.font_size == old_size,
			"pane-to-pane focus does not reread configuration",
		)
		e := sdl.Event {
			type = .WINDOW_FOCUS_GAINED,
		}
		e.window.windowID = sdl.GetWindowID(state.window)
		assert(sdl.PushEvent(&e))
		for _ in 0 ..< 30 {frame(project, tab, 2)}
		for _, mount in whip_mounts {testing.expect(t, mount.view.config.font_size == old_size + 3, "host window activation refreshes each mounted configuration")}
		for _, mount in whip_mounts {
			testing.expect_value(t, mount.view.scale, base_scale * 2)
			testing.expect_value(
				t,
				mount.view.fonts.size_px,
				(old_size + 3) * 96 / 72 * base_scale * 2,
			)
		}
		for _ in 0 ..< 30 {frame(project, tab)}
		// Reattach a long-lived shell, not an empty terminal. Its complete
		// history must survive loading while new input and output continue.
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				fmt.tprintf(
					"i=0; while [ $i -lt 60000 ]; do printf 'history_%%05d abcdef0123456789 abcdef0123456789\\n' $i; i=$((i+1)); done; printf ready > '%s/history-ready'",
					home,
				),
				"--enter",
			},
		)
		for _ in 0 ..< 600 {
			frame(project, tab)
			if os.is_file(fmt.tprintf("%s/history-ready", home)) {break}
		}
		if !testing.expect(
			t,
			os.is_file(fmt.tprintf("%s/history-ready", home)),
			"the deep-history workload finished",
		) {return}
		WhipClose()
		for _ in 0 ..< 300 {
			frame(project, tab)
			mount := whip_mounts[pane]
			if mount != nil && mount.texture != nil {break}
		}
		ui = whip_mounts[pane]
		if !testing.expect(
			t,
			ui != nil && ui.texture != nil,
			"the restored terminal publishes its first screen",
		) {return}
		cli({"pane", "send", fmt.tprintf("%d", pane), "printf 'live_after_restore\\n'", "--enter"})
		for _ in 0 ..< 300 {frame(project, tab)}
		history := whip_test_text(pane)
		defer delete(history)
		testing.expect_value(t, strings.count(history, "\nhistory_"), 60000)
		testing.expect(
			t,
			strings.contains(history, "history_00000 abcdef") &&
			strings.contains(history, "history_59999 abcdef"),
			"both ends of the original scrollback remain available",
		)
		testing.expect(
			t,
			strings.contains(history, "\nlive_after_restore\n"),
			"live output continues during history restoration",
		)
		WhipClose()
		pending := false
		for _ in 0 ..< 300 {
			frame(project, tab)
			if whip_catalog == nil {continue}
			for _, pv in whip_catalog.view.panes {
				if u32(pv.id) == pane && pv.snapshot_job != nil {pending = true}
			}
			if pending {break}
		}
		if !testing.expect(
			t,
			pending,
			"the deep snapshot is queued for background decoding",
		) {return}
		whip.send_resize(whip_catalog.view, proto.Pane_Id(pane), {83, 37, 8, 16})
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				"printf '\\033[H\\033[2J\\033[3Jafter_clear\\n'",
				"--enter",
			},
		)
		for _ in 0 ..< 60 {frame(project, tab)}
		cleared := whip_test_text(pane)
		defer delete(cleared)
		testing.expect_value(t, strings.count(cleared, "history_"), 0)
		testing.expect(
			t,
			strings.contains(cleared, "after_clear"),
			"resize and history-clearing output remain ordered after the snapshot",
		)
		cli(
			{
				"pane",
				"send",
				fmt.tprintf("%d", pane),
				fmt.tprintf(
					"i=0; while [ $i -lt 30000 ]; do printf 'shutdown_%%05d abcdef0123456789\\n' $i; i=$((i+1)); done; printf ready > '%s/shutdown-ready'",
					home,
				),
				"--enter",
			},
		)
		for _ in 0 ..< 600 {frame(project, tab); if os.is_file(fmt.tprintf("%s/shutdown-ready", home)) {break}}
		WhipClose()
		pending = false
		for _ in 0 ..< 300 {
			frame(project, tab)
			if whip_catalog == nil {continue}
			for _, pv in whip_catalog.view.panes {if u32(pv.id) == pane && pv.snapshot_job != nil {pending = true}}
			if pending {break}
		}
		if !testing.expect(t, pending, "shutdown runs with a pending snapshot") {return}
		frame(project, tab)
		WhipClose()
		for _ in 0 ..< 300 {frame(project, tab); if mount := whip_mounts[pane]; mount != nil && mount.texture != nil {break}}
		if !testing.expect(
			t,
			whip_mounts[pane] != nil && whip_mounts[pane].texture != nil,
		) {return}
		resumed := whip_test_text(pane)
		defer delete(resumed)
		testing.expect_value(t, strings.count(resumed, "\nshutdown_"), 30000)
	}
}
