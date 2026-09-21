package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"
import clay "../vendor/clay/bindings/odin/clay-odin"
import marmot "../marmot"
import rl "sdlrl"

@(private)
hidden_fixture :: proc(bits: string) -> string {
	text, _ := strings.replace_all(bits, "0", "\u200c", context.temp_allocator)
	text, _ = strings.replace_all(text, "1", "\u200d", context.temp_allocator)
	text, _ = strings.replace_all(text, " ", "\u200b", context.temp_allocator)
	return text
}

@(private)
secret_fixture :: proc(text: string) -> string {
	units := make([]u16, len(text), context.temp_allocator)
	n := utf16.encode_string(units, text)
	bits: strings.Builder
	strings.builder_init(&bits, context.temp_allocator)
	for unit, i in units[:n] {
		if i > 0 { strings.write_byte(&bits, ' ') }
		strings.write_string(&bits, fmt.tprintf("%016b", unit))
	}
	return hidden_fixture(strings.to_string(bits))
}

@(test)
hidden_message_decode :: proc(t: ^testing.T) {
	// Exact 16-bit groups from the reported 2,450-byte scorpion message.
	sample := hidden_fixture("0000000001010100 0000000001101000 0000000001101001 0000000001110011 0000000000100000 0000000001101001 0000000001110011 0000000000100000 0000000001100001 0000000000100000 0000000001101000 0000000001101001 0000000001100100 0000000001100100 0000000001100101 0000000001101110 0000000000100000 0000000001101101 0000000001100101 0000000001110011 0000000001110011 0000000001100001 0000000001100111 0000000001100101 0000000000101110 0000000000100000 0000000001001100 0000000001100101 0000000001110100 0000000000100111 0000000001110011 0000000000100000 0000000001100010 0000000001110010 0000000001100101 0000000001100001 0000000001101011 0000000000100000 0000000001110100 0000000001101000 0000000001101001 0000000001101110 0000000001100111 0000000001110011 0000000000101110 0000000000100000 1101100000111101 1101111000001000")
	cover, secret := hidden_message(fmt.tprintf("🦂%s\n", sample))
	testing.expect_value(t, cover, "🦂\n")
	testing.expect_value(t, secret, "This is a hidden message. Let's break things. 😈")
	a := hidden_fixture("0000000001000001")
	for text in ([]string{"", "🦂", "👩🏽‍💻", "می\u200cروم", "a\u200bb", a[:len(a) - 3], fmt.tprintf("%s\u200c", a), fmt.tprintf("%s\u200b", a), fmt.tprintf("\u200b%s", a),
		hidden_fixture("0000000000000000"), hidden_fixture("1101100000111101"), hidden_fixture("1101111000001000"),
		hidden_fixture("1101100000111101 0000000001000001"), hidden_fixture("0000000001000001 1101111000001000"),
		hidden_fixture("0000000001000001 000000000100000")}) {
		cover, secret := hidden_message(text)
		testing.expect_value(t, cover, text)
		testing.expect_value(t, secret, "")
	}
	covers := []string{"", "🦂", "👩🏽‍💻  tail", " middle "}
	for text, i in ([]string{a, fmt.tprintf("🦂%s", a), fmt.tprintf("👩🏽‍💻 %s tail", a), fmt.tprintf("%s middle %s", a, a)}) {
		cover, secret := hidden_message(text)
		testing.expect_value(t, cover, covers[i])
		testing.expect_value(t, secret, i == 3 ? "A\nA" : "A")
	}
	cover, secret = hidden_message(fmt.tprintf("🦂%s\n", hidden_fixture("1101100000111101 1101111000001000")))
	testing.expect_value(t, cover, "🦂\n")
	testing.expect_value(t, secret, "😈")
	inner := fmt.tprintf("🔒%s", secret_fixture("**Nested**"))
	cover, secret = hidden_message(fmt.tprintf("🦂%s", secret_fixture(inner)))
	testing.expect_value(t, cover, "🦂")
	testing.expect_value(t, secret, inner)
	cover, secret = hidden_message(secret)
	testing.expect_value(t, cover, "🔒")
	testing.expect_value(t, secret, "**Nested**")
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=hidden_message_layout
@(test)
hidden_message_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "hidden_message_layout" { return }
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-secret-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) { return }
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(t, marmot.client_new_with_secret_store(strings.clone_to_cstring(dir, context.temp_allocator), nil, 0, &store, &client), marmot.Status.OK) { return }
	defer marmot.client_free(client)
	rl.InitWindow(600, 240, "Hidden message")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 240})
	defer delete(memory)
	ui := Ui_State{selected = 0, row_menu = -1, focus = .Compose}
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{})
	nested := fmt.tprintf("# Secret\n\n**Bold** and *italic*.\n\n🗝️%s", secret_fixture("- Nested **markdown**"))
	secrets := secret_layers(client, nested)
	testing.expect_value(t, len(secrets), 2)
	testing.expect_value(t, secrets[0].blocks[0].kind, Md_Kind.Heading)
	testing.expect_value(t, secrets[0].blocks[1].text, "Bold and italic.")
	testing.expect_value(t, secrets[0].blocks[1].fonts[0], u8(FONT_TITLE))
	testing.expect_value(t, secrets[1].blocks[0].kind, Md_Kind.List_Item)
	append(&ui.messages, Msg_Ui{sender = strings.clone("Sender"), mine = true, secrets = secrets, blocks = parse_md_text("🦂")})
	append(&ui.messages, Msg_Ui{sender = strings.clone("Neighbor"), mine = true, blocks = parse_md_text("Neighbor 😀")})
	defer {
		for msg in ui.messages { message_free(msg) }
		delete(ui.messages); delete(ui.accounts); delete(ui.chats); delete(ui.compose)
		g_ui, g_prefs = nil, nil
		forced_release = false
		wrap_clear(); delete(sel_lines); sel_lines = nil
	}
	for width in ([]i32{600, 320}) {
		rl.SetWindowSize(width, 240)
		clay.SetLayoutDimensions({f32(width), 240})
		for state in 0 ..< 5 {
			for frame in 0 ..< 3 {
				clear(&sel_lines)
				clay.BeginLayout()
				if clay.UI(clay.ID("HiddenTest"))({layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}, padding = clay.PaddingAll(16)}, backgroundColor = BG}) {
					for msg, i in ui.messages { message_row(u32(i), msg) }
				}
				commands := clay.EndLayout(0)
				if frame < 2 { continue }
				found_inner := false
				for line in sel_lines { if strings.contains(line.text, "Nested") { found_inner = true } }
				testing.expect_value(t, found_inner, state == 2)
				testing.expect(t, !preview_shown)
				neighbor := clay.GetElementData(clay.ID("BodyLine", (4096 + 1) * 8)).boundingBox
				testing.expect(t, neighbor.y >= clay.GetElementData(clay.ID("MsgRow", 1)).boundingBox.y)
				data := clay.GetElementData(clay.ID("MsgReveal", 0))
				testing.expect(t, data.found && data.boundingBox.width == 44 && data.boundingBox.height == 44)
				testing.expect_value(t, clay.GetElementData(clay.ID("MsgReveal", 1)).found, state > 0 && state < 4)
				rl.BeginDrawing()
				clay_raylib_render(&commands)
				rl.TakeScreenshot(strings.clone_to_cstring(fmt.tprintf("/tmp/wn-hidden-%d-%d.png", width, state), context.temp_allocator))
				rl.EndDrawing()
				if state < 4 {
					if state == 1 || state == 2 { data = clay.GetElementData(clay.ID("MsgReveal", 1)) }
					testing.expect_value(t, data.boundingBox.height, f32(44))
					clay.SetPointerState({data.boundingBox.x + 12, data.boundingBox.y + 12}, false)
					forced_release = true
					handle_chat(&ui, client)
					forced_release = false
					testing.expect_value(t, ui.messages[0].secrets[0].open, state != 3)
					testing.expect_value(t, ui.messages[0].secrets[1].open, state == 1)
				}
			}
		}
	}
}
