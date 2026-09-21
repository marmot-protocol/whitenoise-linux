package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -o:speed -define:ODIN_TEST_NAMES=hidden_message_perf
@(test)
hidden_message_perf :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "hidden_message_perf" { return }
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-secret-perf-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) { return }
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(t, marmot.client_new_with_secret_store(strings.clone_to_cstring(dir, context.temp_allocator), nil, 0, &store, &client), marmot.Status.OK) { return }
	defer marmot.client_free(client)
	rl.InitWindow(1200, 800, "Hidden payload regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	ui := Ui_State{row_menu = -1, member_menu = -1, selected_contact = -1}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	g_ui, g_prefs, g_client = &ui, &ui.prefs, client
	append(&ui.accounts, "Test")
	defer { delete(ui.accounts); delete(ui.chats); delete(ui.messages); wrap_clear(); g_ui, g_prefs, g_client = nil, nil, nil }
	plain := strings.repeat("**secret** text ", 3000, context.temp_allocator)
	cases := []string{
		fmt.aprintf("🦂%s", secret_fixture(plain)),
		fmt.aprintf("🦂%s", secret_fixture(fmt.tprintf("🔒%s", secret_fixture("**nested**")))),
	}
	defer { for body in cases { delete(body) } }
	for body, kind in cases {
		last := marmot.Chat_List_Message_Preview{plaintext = strings.clone_to_cstring(body, context.temp_allocator), sender = "peer", kind = 9}
		row := marmot.Presented_Chat_Row{row = {group_id_hex = "test", last_message = &last}}
		row.presentation.title = {tag = .Literal, body = {literal = "Hidden payload"}}
		start := time.tick_now()
		chat := row_to_ui(client, &row, "self")
		cover, secret := hidden_message(body)
		msg := Msg_Ui{id = strings.clone("secret"), body = strings.clone(body), sender = strings.clone("Peer"),
			blocks = parse_md_text(cover), secrets = secret_layers(client, secret)}
		fmt.printf("hidden kind=%d bytes=%d load_ms=%.3f\n", kind, len(body), time.duration_milliseconds(time.tick_since(start)))
		append(&ui.chats, chat); append(&ui.messages, msg)
		for opened in 0 ..< 2 {
			for &layer in ui.messages[0].secrets { layer.open = opened == 1 }
			ui.messages[0].row_height = 0
			samples: [7]f64
			for frame in 0 ..< 9 {
				start := time.tick_now()
				commands := build_layout(&ui, 0)
				rl.BeginDrawing(); draw_frame(&commands)
				ms := time.duration_milliseconds(time.tick_since(start))
				rl.EndDrawing()
				if frame >= 2 { samples[frame - 2] = ms }
				testing.expect(t, !layout_overflow)
				free_all(context.temp_allocator)
			}
			slice.sort(samples[:])
			fmt.printf("hidden kind=%d open=%d median_ms=%.3f max_ms=%.3f\n", kind, opened, samples[3], samples[6])
		}
		chat_free(chat); message_free(msg)
		clear(&ui.chats); clear(&ui.messages); wrap_clear()
	}
}
