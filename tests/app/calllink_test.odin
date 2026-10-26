package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import rl "sdlrl"

@(private = "file")
SIGNAL_V0 :: "rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb"
@(private = "file")
SIGNAL_V1 :: "rxqbhxff-pkqxcxxt-bcpdxnmx-szgzctzb-bc-bbbbbbbc"
@(private = "file")
SIGNAL_URL :: "https://signal.link/call/#key=" + SIGNAL_V0
@(private = "file")
JITSI_URL :: "https://meet.jit.si/WeeklyStandup"
@(private = "file")
SELF_HOSTED :: "https://meet.example.org/WeeklyStandup"

@(test)
signal_call_links :: proc(t: ^testing.T) {
	for c in ([]struct {
			url, key: string,
		}{{SIGNAL_URL, SIGNAL_V0}, {"https://signal.link/call#key=" + SIGNAL_V0, SIGNAL_V0}, {"https://signal.link/call/#key=" + SIGNAL_V1, SIGNAL_V1}, {"https://signal.link/call/#epk=abc&key=" + SIGNAL_V1, SIGNAL_V1}, {"https://signal.link/call/#key=" + SIGNAL_V0 + "&flag", SIGNAL_V0}}) {
		key, ok := signal_call_key(c.url)
		testing.expect(t, ok, c.url)
		testing.expect_value(t, key, c.key)
	}
	for url in ([]string{"http://signal.link/call/#key=" + SIGNAL_V0, "https://signal.link.evil/call/#key=" + SIGNAL_V0, "https://evil.example/https://signal.link/call/#key=" + SIGNAL_V0, "https://signal.link/call/?key=" + SIGNAL_V0, "https://signal.link/call/#", "https://signal.link/call/#key", "https://signal.link/call/#key=", "https://signal.link/call/#other=" + SIGNAL_V0, "https://signal.link/call/#key=" + SIGNAL_V0 + "-", "https://signal.link/call/#key=rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz", "https://signal.link/call/#key=rxqbhxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb", "https://signal.link/call/#key=axqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb", "https://signal.link/call/#key=RXQB-HXFF-PKQX-CXXT-BCPD-XNMX-SZGZ-CTZB", "https://signal.link/call/#key=" + SIGNAL_V0 + "&key=" + SIGNAL_V0, "https://signal.link/call/#key=" + SIGNAL_V0 + "&&a=1", "https://signal.link/call/#key=" + SIGNAL_V0 + "=x"}) {
		_, ok := signal_call_key(url)
		testing.expect(t, !ok, url)
	}
}

// meet.jit.si is a call on sight; any other host only once its probe said
// yes, and only for a one-segment room path.
@(test)
jitsi_call_links :: proc(t: ^testing.T) {
	// Literal keys: nothing here probes, so the map owns no strings.
	defer {delete(jitsi_hosts); jitsi_hosts = nil}
	for c in ([]struct {
			url, host, room: string,
		}{{JITSI_URL, "meet.jit.si", "WeeklyStandup"}, {JITSI_URL + "#config.startWithVideoMuted=true", "meet.jit.si", "WeeklyStandup"}, {"https://MEET.JIT.SI/a-b_c%20d?lang=de", "MEET.JIT.SI", "a-b_c%20d"}}) {
		link, ok := call_link(c.url)
		testing.expect(t, ok && link.app == .Jitsi, c.url)
		testing.expect_value(t, link.host, c.host)
		testing.expect_value(t, link.room, c.room)
	}
	for url in ([]string{"http://meet.jit.si/Room", "https://meet.jit.si/", "https://meet.jit.si/static/Room", "https://meet.jit.si/favicon.ico", "https://user@meet.jit.si/Room", "https://localhost/Room", "https://meet.jit.si/Ro~om"}) {
		_, ok := call_link(url)
		testing.expect(t, !ok, url)
	}

	_, ok := call_link(SELF_HOSTED)
	testing.expect(t, !ok, "unprobed host")
	for answer in ([]Jitsi_Host{.Probing, .No}) {
		jitsi_hosts["meet.example.org"] = answer
		_, ok = call_link(SELF_HOSTED)
		testing.expect(t, !ok, "host that is not Jitsi")
	}
	jitsi_hosts["meet.example.org"] = .Yes
	link: Call_Link
	link, ok = call_link(SELF_HOSTED)
	testing.expect(t, ok && link.app == .Jitsi && link.room == "WeeklyStandup", SELF_HOSTED)
	_, ok = call_link("https://meet.example.org/a/b")
	testing.expect(t, !ok, "nested path on a Jitsi host")

	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	text := "Join " + SIGNAL_URL + " or " + SELF_HOSTED + ". Then\n" + JITSI_URL
	for width in ([]f32{0, 120, 1200}) {
		cards := 0
		for line in wrapped_lines(text, width, 14, .Cards) {
			if _, call := call_link(text[line.start:line.end]); call {cards += 1}
		}
		testing.expect_value(t, cards, 3)
	}
}

// Only a call link, and only with its client installed, is handed to the
// app: Signal on the canonical /call/ path with its whole fragment,
// Jitsi with the host and room as written.
@(test)
call_app_links :: proc(t: ^testing.T) {
	old := call_clients
	defer {call_clients = old}
	call_clients = {
		.Signal = .Installed,
		.Jitsi  = .Installed,
	}
	for c in ([]struct {
			url, target, app: string,
		}{{SIGNAL_URL, "sgnl://signal.link/call/#key=" + SIGNAL_V0, "Signal"}, {"https://signal.link/call#epk=abc&key=" + SIGNAL_V1, "sgnl://signal.link/call/#epk=abc&key=" + SIGNAL_V1, "Signal"}, {JITSI_URL + "#config.prejoinPageEnabled=false", "jitsi-meet://meet.jit.si/WeeklyStandup#config.prejoinPageEnabled=false", "Jitsi Meet"}, {"https://signal.link/call/#key=bad", "", ""}, {"https://example.com/#key=" + SIGNAL_V0, "", ""}}) {
		target, app := call_app_link(c.url)
		testing.expect_value(t, target, c.target)
		testing.expect_value(t, app, c.app)
	}
	for state in ([]Call_Client{.Unknown, .Probing, .Missing}) {
		call_clients = {
			.Signal = state,
			.Jitsi  = state,
		}
		for url in ([]string{SIGNAL_URL, JITSI_URL}) {
			target, _ := call_app_link(url)
			testing.expect_value(t, target, "")
		}
	}
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=call_layout
@(test)
call_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "call_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(820, 640, "Call cards")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {820, 640})
	defer delete(memory)
	defer wrap_clear()
	ui: Ui_State
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	gh_cards_on = true
	defer {gh_cards_on = false}
	jitsi_hosts["meet.example.org"] = .Yes
	defer {delete_key(&jitsi_hosts, "meet.example.org")}
	old := call_clients
	defer {call_clients = old}
	for theme in ([]int{0, 1}) {
		apply_theme(theme, 0)
		for width in ([]f32{240, 360}) {
			for frame in 0 ..< 3 {
				// Installed on the left, missing on the right.
				clay.SetPointerState({-1, -1}, false)
				link_hover = ""
				clay.BeginLayout()
				if clay.UI(clay.ID("Page"))(
				{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, backgroundColor = BG},
				) {
					for column in 0 ..< 2 {
						call_clients =
							column == 0 ? {.Signal = .Installed, .Jitsi = .Installed} : {.Signal = .Missing, .Jitsi = .Missing}
						if clay.UI(clay.ID("Timeline", u32(column)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(width + 78),
									height = clay.SizingGrow(),
								},
								layoutDirection = .TopToBottom,
								padding = clay.PaddingAll(20),
								childGap = 16,
							},
							backgroundColor = CARD,
						},
						) {
							base := u32(column * 10)
							body_line(base + 1, SIGNAL_URL, 14, TEXT, {5, 15})
							body_line(base + 2, JITSI_URL, 14, TEXT, {5, 15})
							body_line(base + 3, SELF_HOSTED, 14, TEXT, {5, 15})
						}
					}
				}
				commands := clay.EndLayout(0)
				if frame < 2 {continue}
				for id in ([]u32{1, 2, 3, 11, 12, 13}) {
					data := clay.GetElementData(clay.ID("CallCard", id * 128))
					testing.expect(t, data.found)
					testing.expect(t, data.boundingBox.width <= width)
				}
				rl.BeginDrawing()
				clay_raylib_render(&commands)
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-call-%d-%d.png", theme, int(width)))
				rl.EndDrawing()
			}
		}
	}
}
