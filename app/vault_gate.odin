// The vault's two edges: the marmot secret store it backs, and the
// unlock/create screen that opens it before anything else boots.
//
//   main ──► vault_gate ──► vault_open/create ──► boot_marmot
//                                                     │
//                          marmot_client_new_with_secret_store(vtable)
//                                                     │
//   marmot ──► ss_load/write/... ──► g_vault["account:<label>"]
//
// The callbacks may run concurrently, and must never re-enter marmot
// (the account home holds its mutation lock across the call) nor unwind;
// vault_* takes the vault mutex and nothing here calls back into the
// runtime. They also run on whichever thread made the marmot call, the
// UI thread included, so they never free that thread's temp arena.
package main

import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// ── Secret store ────────────────────────────────────────────────────

// marmot keys one credential per account label, and for a local signing
// account the label is the account id hex, so both has_* probes read
// the same entry.
//
// Heap, never the temp allocator: marmot's block_on drives the future on
// the *calling* thread, so a callback runs inside whatever UI call is in
// flight and must not touch that thread's temp arena. Freeing it here
// once recycled a caller's account hex into a Blossom URL.
@(private = "file")
account_key :: proc(label: cstring) -> string {
	return fmt.aprintf("account:%s", string(label))
}

@(private = "file")
store_status :: proc(err: Vault_Err) -> marmot.Secret_Store_Status {
	// A locked vault is recoverable (the runtime retries); anything else
	// is a real write failure.
	return err == .None ? .OK : (err == .Not_Found ? .UNAVAILABLE : .FAILED)
}

@(private = "file")
ss_has :: proc "c" (user_data: rawptr, key: cstring, out_present: ^u8) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(key)
	defer delete(full)
	out_present^ = vault_has(full) ? 1 : 0
	return .OK
}

@(private = "file")
ss_write :: proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring, secret_key_hex: cstring) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(label)
	defer delete(full)
	return store_status(vault_set(full, string(secret_key_hex)))
}

@(private = "file")
ss_load :: proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring, out_secret_key_hex: ^cstring) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(label)
	defer delete(full)
	value, found := vault_get(full)
	if !found {
		return .NOT_FOUND
	}
	defer {
		mem.zero_slice(transmute([]u8)value)
		delete(value)
	}

	// marmot copies the string and hands this buffer straight back to
	// ss_free.
	out_secret_key_hex^ = strings.clone_to_cstring(value)
	return .OK
}

@(private = "file")
ss_remove :: proc "c" (user_data: rawptr, label: cstring, account_id_hex: cstring) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(label)
	defer delete(full)
	return store_status(vault_remove(full))
}

@(private = "file")
ss_free :: proc "c" (user_data: rawptr, secret_key_hex: cstring) {
	context = runtime.default_context()
	context.allocator = reload_allocator()
	if secret_key_hex == nil {
		return
	}

	// Zero before free: delete_cstring frees the pointer, so wiping the
	// bytes first doesn't confuse it about the length.
	raw := transmute([^]u8)secret_key_hex
	mem.zero_slice(raw[:len(string(secret_key_hex))])
	delete(secret_key_hex)
}

// The vtable marmot copies at construction. No destroy: the vault is
// process-global and outlives every client.
vault_secret_store :: proc() -> marmot.Secret_Store {
	return {
		has_secret_for_label = ss_has,
		has_secret_for_account_id = ss_has,
		write_secret = ss_write,
		load_secret = ss_load,
		remove_secret = ss_remove,
		free_secret = ss_free,
	}
}

// ── Gate ────────────────────────────────────────────────────────────

// Masked password boxes; edit_text checks these pointers so a drag
// selection never copies the password out.
gate_pw: [dynamic]u8
gate_pw2: [dynamic]u8

@(private = "file")
gate_confirm: bool // the confirm box has focus
@(private = "file")
gate_err: string
@(private = "file")
gate_reset_armed: bool

@(private = "file")
gate_close :: proc() {
	mem.zero_slice(gate_pw[:])
	mem.zero_slice(gate_pw2[:])
	delete(gate_pw)
	delete(gate_pw2)
	gate_pw = nil
	gate_pw2 = nil
}

// Unlock an existing vault, or create one on first run. Runs its own
// frame loop before the runtime boots, because the secret store has to
// be handed to marmot at client construction. False = the user closed
// the window.
vault_gate :: proc(ui: ^Ui_State) -> bool {
	// Headless runs (the dmvm harness) have no one to type a password.
	if pw := os.get_env("WN_VAULT_PW", context.temp_allocator); pw != "" {
		return vault_exists() ? vault_open(pw) == .None : vault_create(pw) == .None
	}
	when #config(WN_DEV, false) {
		if vault_open("", .Dev_Cache) == .None { return true }
	}

	defer gate_close()
	shot := os.get_env("WN_SHOT", context.temp_allocator) != ""
	for frame := 0; !rl.WindowShouldClose(); frame += 1 {
		if dev_reload_poll() { return false }
		defer free_all(context.temp_allocator)
		anim_tick(rl.GetFrameTime()) // the gate runs its own loop, so it steps its own motion
		apply_zoom(ui) // and its own resize response; a no-op unless the width moved

		pointer := transmute(clay.Vector2)rl.GetMousePosition()
		pointer.x /= UI_ZOOM
		pointer.y /= UI_ZOOM
		clay.SetPointerState(pointer, rl.IsMouseButtonDown(.LEFT))
		clay.SetLayoutDimensions({f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM})

		render_commands := gate_layout(ui)
		rl.BeginDrawing()
		rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
		clay_raylib_render(&render_commands)
		rl.EndMode2D()
		// WN_SHOT with no password to type: capture the gate itself and
		// quit, the same contract the main loop honors. Captured before
		// EndDrawing; the backbuffer is undefined after present.
		if shot && frame == 30 {
			rl.TakeScreenshot("wn-odin-shot.png")
			rl.EndDrawing()
			return false
		}
		rl.EndDrawing()
		if gate_input(ui) {
			return true
		}
		// Same contract as the main loop: the password box is the only
		// field here, and gate_input's edit_text sets the flag.
		rl.SetTextInput(text_field_live)
		text_field_live = false
	}
	return false
}

// One frame of typing and clicks. True once the vault is open.
@(private = "file")
gate_input :: proc(ui: ^Ui_State) -> bool {
	creating := !vault_exists()

	edit_text(ui, gate_confirm && creating ? &gate_pw2 : &gate_pw)
	if clicked("GatePwBox") {
		gate_confirm = false
	}
	if clicked("GatePw2Box") {
		gate_confirm = true
	}

	// No recovery path: forgetting the password means starting over from
	// an nsec, so the reset arms first and acts on the second click.
	if clicked("GateReset") {
		if !gate_reset_armed {
			gate_reset_armed = true
			return false
		}
		gate_reset_armed = false
		vault_delete()
		clear(&gate_pw)
		clear(&gate_pw2)
		gate_err = ""
		return false
	}

	if !clicked("GateGo") && !rl.IsKeyPressed(.ENTER) {
		return false
	}
	password := string(gate_pw[:])
	if len(password) == 0 {
		gate_err = tr("Pick a password first.")
		return false
	}

	// Enter walks from the password to the confirm box (the shim has no
	// Tab key); the second Enter submits.
	if creating && !gate_confirm {
		gate_confirm = true
		return false
	}

	if !creating {
		if err := vault_open(password); err != .None {
			gate_err =
				err == .Wrong_Password \
				? tr("Couldn't unlock the vault. Double-check the password and try again.") \
				: tr("Couldn't read the vault file. Please try again.")
			clear(&gate_pw)
			return false
		}
		return true
	}

	if password != string(gate_pw2[:]) {
		gate_err = tr("The passwords don't match. Type them again.")
		clear(&gate_pw2)
		gate_confirm = true
		return false
	}
	if vault_create(password) != .None {
		gate_err = tr("Couldn't create the vault. Please try again.")
		return false
	}
	return true
}

// Shared with the change-password modal (vault_pw.odin), the other
// place a vault password gets typed.
@(private)
gate_field :: proc(ui: ^Ui_State, id_str: string, buf: ^[dynamic]u8, focused: bool, placeholder: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = clay.SizingGrow({max = 560}), height = clay.SizingFixed(46)}, padding = {left = 14, right = 14}, childAlignment = {y = .Center}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(10),
		border = {color = focused ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		// Every character typed kicks the spring, so the field answers
		// each keystroke with light instead of only growing asterisks.
		pop, _, _ := bump(clay.ID(id_str).id, fmt.tprintf("%d", len(buf)))
		if focused {
			glow(clay.ID(id_str), ACCENT, 0.35 + clamp((pop - 1) * 3, 0, 0.65), 18)
		}
		if len(buf) == 0 {
			clay.Text(tr(placeholder), {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
		} else {
			clay.Text(strings.repeat("*", min(len(buf), 48), context.temp_allocator), {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
		}
		if focused {
			caret(16)
		}
	}
}

// The sign-in card's shape, one step earlier: password before identity.
@(private = "file")
gate_layout :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()
	creating := !vault_exists()

	if clay.UI(clay.ID("Root"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}, backgroundColor = BG},
	) {
		// The unlock screen is the first thing anyone sees, so it gets
		// the synthwave rail fan behind it whatever the saved theme is.
		// It draws from the accent color, so it suits every palette.
		if clay.UI(clay.ID("GateCanvas"))(
		{
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}},
			custom = {customData = &synth_decor},
		},
		) {
			if clay.UI(clay.ID("GateCard"))(
			{
				layout = {sizing = {width = clay.SizingFixed(fit_w(660))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(single_pane() ? 20 : 50), childGap = 14, childAlignment = {x = .Center}},
				backgroundColor = CARD,
				cornerRadius = rr(16),
				border = {color = CARD_BORDER, width = bw()},
			},
			) {
				glow(clay.ID("GateCard"), ACCENT, 0.55, 26)
				clay.Text("///", {fontId = FONT_TITLE, fontSize = 34, textColor = ACCENT})
				clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})
				clay.Text(
					creating ? tr("Pick a password. It encrypts everything in the app, and there is no way to recover it.") : tr("Enter your password to unlock this device's keys."),
					{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
				)
				if clay.UI(clay.ID("GateGapA"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}

				eyebrow("PASSWORD")
				gate_field(ui, "GatePwBox", &gate_pw, !gate_confirm || !creating, "Your password")
				if creating {
					eyebrow("CONFIRM PASSWORD")
					gate_field(ui, "GatePw2Box", &gate_pw2, gate_confirm, "Your password")
				}

				if clay.UI(clay.ID("GateGapB"))({layout = {sizing = {height = clay.SizingFixed(6)}}}) {}
				login_big_button("GateGo", creating ? tr("Continue") : tr("Unlock"), true)
				if !creating {
					micro_button("GateReset", gate_reset_armed ? tr("Confirm: delete this vault") : tr("Use another key"), DANGER)
				}
				if len(gate_err) > 0 {
					clay.Text(gate_err, {fontId = FONT_BODY, fontSize = 14, textColor = DANGER})
				}
			}
		}
	}
	return clay.EndLayout(rl.GetFrameTime())
}
