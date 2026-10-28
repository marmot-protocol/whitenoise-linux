// The vault's two edges: the marmot secret store it backs, and the
// unlock/create screen that opens it before anything else boots.
//
//   main ──► vault_gate ──► vault_open/create ──► boot_marmot
//                                                     │
//                          marmot_client_new_with_configuration(options.store)
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
import "core:thread"

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
ss_has :: proc "c" (
	user_data: rawptr,
	key: cstring,
	out_present: ^u8,
) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(key)
	defer delete(full)
	out_present^ = vault_has(full) ? 1 : 0
	return .OK
}

@(private = "file")
ss_write :: proc "c" (
	user_data: rawptr,
	label: cstring,
	account_id_hex: cstring,
	secret_key_hex: cstring,
) -> marmot.Secret_Store_Status {
	context = runtime.default_context()
	context.allocator = reload_allocator()

	full := account_key(label)
	defer delete(full)
	return store_status(vault_set(full, string(secret_key_hex)))
}

@(private = "file")
ss_load :: proc "c" (
	user_data: rawptr,
	label: cstring,
	account_id_hex: cstring,
	out_secret_key_hex: ^cstring,
) -> marmot.Secret_Store_Status {
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
ss_remove :: proc "c" (
	user_data: rawptr,
	label: cstring,
	account_id_hex: cstring,
) -> marmot.Secret_Store_Status {
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
gate_reset_done: bool
@(private = "file")
gate_pw_view: Secret_Field_View
@(private = "file")
gate_pw2_view: Secret_Field_View
@(private = "file")
gate_check: Password_Check

// The unlock or create in flight. Argon2id takes ~15 ms at -o:speed on
// a fast desktop, ~55 ms at -o:minimal and far longer on slow CPUs, so
// it runs off the UI thread while the card shows it working. The
// password borrows gate_pw, which gate_input leaves alone meanwhile.
@(private = "file")
Gate_Job :: struct {
	worker:   ^thread.Thread,
	creating: bool,
	password: string,
	err:      Vault_Err,
}
@(private = "file")
gate_job: Gate_Job

@(private = "file")
gate_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	job := (^Gate_Job)(t.data)
	job.err = job.creating ? vault_create(job.password) : vault_open(job.password)
}

@(private = "file")
gate_start :: proc(creating: bool) {
	gate_err = ""
	gate_job = {
		creating = creating,
		password = string(gate_pw[:]),
	}
	gate_job.worker = thread.create(gate_worker)
	gate_job.worker.data = &gate_job
	thread.start(gate_job.worker)
}

// Also the exit path: closing the window mid-unlock waits out the
// derivation before gate_close frees the password it reads.
@(private = "file")
gate_join :: proc() {
	if gate_job.worker == nil {
		return
	}
	thread.join(gate_job.worker)
	thread.destroy(gate_job.worker)
	gate_job.worker = nil
}

// True once the worker opened the vault. A failure lands back on the
// form with its error.
@(private = "file")
gate_poll :: proc() -> bool {
	if !thread.is_done(gate_job.worker) {
		return false
	}
	gate_join()
	switch {
	case gate_job.err == .None:
		return true
	case gate_job.creating:
		gate_err = tr("Couldn't create the vault. Please try again.")
	case gate_job.err == .Wrong_Password:
		gate_err = tr("Couldn't unlock the vault. Double-check the password and try again.")
		mem.zero_slice(gate_pw[:])
		clear(&gate_pw)
	case:
		gate_err = tr("Couldn't read the vault file. Please try again.")
		mem.zero_slice(gate_pw[:])
		clear(&gate_pw)
	}
	gate_reset_armed = false
	return false
}

@(private = "file")
gate_close :: proc() {
	mem.zero_slice(gate_pw[:])
	mem.zero_slice(gate_pw2[:])
	delete(gate_pw)
	delete(gate_pw2)
	gate_pw = nil
	gate_pw2 = nil
	gate_check = {}
	gate_job = {}
}

// Unlock an existing vault, or create one on first run. Runs its own
// frame loop before the runtime boots, because the secret store has to
// be handed to marmot at client construction. False = the user closed
// the window.
vault_gate :: proc(ui: ^Ui_State) -> bool {
	ui.lock_requested = ui.lock_requested || dev_vault_manual_locked()
	// Headless runs (the dmvm harness) have no one to type a password.
	if pw := os.get_env("WN_VAULT_PW", context.temp_allocator); pw != "" && !ui.lock_requested {
		return vault_exists() ? vault_open(pw) == .None : vault_create(pw) == .None
	}
	when #config(WN_DEV, false) {
		if !ui.lock_requested && vault_open("", .Dev_Cache) == .None {return true}
	}

	gate_err = ""
	gate_confirm = false
	gate_reset_armed = false
	gate_reset_done = false
	gate_pw_view = .Masked
	gate_pw2_view = .Masked
	gate_job = {}
	devctl_reset_input()
	defer devctl_reset_input()
	defer editor_forget(ui)
	defer gate_close()
	defer gate_join()
	shot := os.get_env("WN_SHOT", context.temp_allocator) != ""
	previous_height: i32 = -1
	previous_confirm := gate_confirm
	previous_error := gate_err
	previous_reset := gate_reset_armed
	previous_reset_done := gate_reset_done
	for frame := 0; !rl.WindowShouldClose(); frame += 1 {
		when ODIN_OS == .Darwin {macos_update_tick()}
		if dev_reload_poll() {return false}
		defer free_all(context.temp_allocator)
		anim_tick(rl.GetFrameTime()) // the gate runs its own loop, so it steps its own motion
		apply_zoom(ui) // and its own resize response; a no-op unless the width moved

		pointer := transmute(clay.Vector2)rl.GetMousePosition()
		forced_press, forced_release = false, false
		devctl_poll(ui, nil, frame, &pointer)
		pointer.x /= UI_ZOOM
		pointer.y /= UI_ZOOM
		clay.SetPointerState(pointer, rl.IsMouseButtonDown(.LEFT))
		scroll_residual += transmute(clay.Vector2)rl.GetMouseWheelMoveV()
		step := scroll_residual * anim_drain(SCROLL_DRAIN)
		scroll_residual -= step
		clay.UpdateScrollContainers(false, step, rl.GetFrameTime())
		clay.SetLayoutDimensions(
			{f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM},
		)

		clear(&drag_targets)
		render_commands := gate_layout(ui)
		if previous_height != rl.GetScreenHeight() ||
		   previous_confirm != gate_confirm ||
		   previous_error != gate_err ||
		   previous_reset != gate_reset_armed ||
		   previous_reset_done != gate_reset_done {
			target := gate_confirm ? "GatePw2Box" : "GatePwBox"
			if gate_err != "" || previous_height != rl.GetScreenHeight() {
				target = "GateSubmit"
			}
			if gate_reset_armed {
				target = "GateResetConfirm"
			}
			if gate_reset_done != previous_reset_done {
				target = "GateResetNotice"
			}
			onboard_reveal_field("GateCard", target)
			previous_height = rl.GetScreenHeight()
			previous_confirm = gate_confirm
			previous_error = gate_err
			previous_reset = gate_reset_armed
			previous_reset_done = gate_reset_done
			render_commands = gate_layout(ui)
		}
		rl.BeginDrawing()
		rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
		clay_raylib_render(&render_commands)
		rl.EndMode2D()
		devctl_draw()
		// WN_SHOT with no password to type: capture the gate itself and
		// quit, the same contract the main loop honors. Captured before
		// EndDrawing; the backbuffer is undefined after present.
		if shot && frame == 30 {
			rl.TakeScreenshot("wn-odin-shot.png")
			rl.EndDrawing()
			return false
		}
		rl.EndDrawing()
		if gate_job.worker != nil && gate_poll() {
			ui.lock_requested = false
			return true
		}
		update_drag_scroll(ui, false)
		gate_input(ui)
		// Same contract as the main loop: the password box is the only
		// field here, and gate_input's edit_text sets the flag.
		rl.SetTextInput(text_field_live)
		if text_field_live {
			rl.SetTextInputArea(
				i32(caret_box.x * UI_ZOOM),
				i32(caret_box.y * UI_ZOOM),
				i32(max(caret_box.width, 1) * UI_ZOOM),
				i32(caret_box.height * UI_ZOOM),
			)
		}
		text_field_live = false
	}
	return false
}

// One frame of typing and clicks; submitting starts the unlock worker.
@(private = "file")
gate_input :: proc(ui: ^Ui_State) {
	if gate_job.worker != nil {
		return
	}
	creating := !vault_exists()

	focus := gate_confirm
	buf := gate_confirm && creating ? &gate_pw2 : &gate_pw
	// Track editor revisions instead of copying a secret just to detect edits.
	previous_len := len(buf)
	previous_edit := ui.ed.last_edit_time
	previous_undo := ui.ed_target == buf ? len(ui.ed.undo) : 0
	previous_redo := ui.ed_target == buf ? len(ui.ed.redo) : 0
	edit_text(ui, buf)
	edited :=
		len(buf) != previous_len ||
		ui.ed.last_edit_time != previous_edit ||
		len(ui.ed.undo) != previous_undo ||
		len(ui.ed.redo) != previous_redo
	if edited {
		gate_err = ""
	}
	if clicked("GatePwShow") {
		gate_pw_view = gate_pw_view == .Masked ? .Plain : .Masked
	}
	if clicked("GatePw2Show") {
		gate_pw2_view = gate_pw2_view == .Masked ? .Plain : .Masked
	}
	if clicked("GatePwBox") {
		gate_confirm = false
	}
	if clicked("GatePw2Box") {
		gate_confirm = true
	}
	if creating {
		tab_focus([]bool{false, true}, &gate_confirm)
	}
	// Typing, switching fields, or submitting an unlock is not the
	// delete. Any of those drops the armed state.
	other :=
		clicked("GatePwBox") ||
		clicked("GatePw2Box") ||
		clicked("GateGo") ||
		rl.IsKeyPressed(.ENTER) ||
		gate_confirm != focus
	if edited || clicked("GatePwShow") || clicked("GatePw2Show") || clicked("GateResetCancel") {
		other = true
	}

	// No recovery path: forgetting the password means starting over from
	// an nsec, so the reset arms first and acts on the second click.
	if clicked("GateReset") {
		if other {
			gate_reset_armed = false
			return
		}
		if !gate_reset_armed {
			gate_reset_armed = true
			return
		}
		gate_reset_armed = false
		vault_stores_quiesce()
		vault_delete()
		mem.zero_slice(gate_pw[:])
		mem.zero_slice(gate_pw2[:])
		clear(&gate_pw)
		clear(&gate_pw2)
		gate_confirm = false
		gate_pw_view = .Masked
		gate_pw2_view = .Masked
		gate_reset_done = true
		gate_check = {}
		gate_err = ""
		return
	}
	if other {
		gate_reset_armed = false
	}

	if !clicked("GateGo") && !rl.IsKeyPressed(.ENTER) {
		return
	}
	password := string(gate_pw[:])
	if len(password) == 0 {
		gate_err = creating ? tr("Pick a password first.") : tr("Type your password first.")
		return
	}
	if creating && password_bits(password, &gate_check) < PASSWORD_MIN_BITS {
		gate_err = tr(
			"This password is too easy to guess. Use unrelated words or a password-manager password.",
		)
		return
	}

	// Enter walks from the password to the confirm box; the second Enter
	// submits.
	if creating && !gate_confirm && !clicked("GateGo") {
		gate_confirm = true
		return
	}

	if creating && password != string(gate_pw2[:]) {
		gate_err = tr("The passwords don't match. Type them again.")
		clear(&gate_pw2)
		gate_confirm = true
		return
	}
	gate_start(creating)
}

// Shared with the change-password modal and proxy credentials.
@(private)
Secret_Field_View :: enum {
	Masked,
	Plain,
}

@(private)
gate_field :: proc(
	ui: ^Ui_State,
	id_str: string,
	buf: ^[dynamic]u8,
	focused: bool,
	placeholder: string,
	view: Secret_Field_View = .Masked,
) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({max = 560}), height = clay.SizingFixed(46)},
			padding = {left = 14, right = 14},
			childAlignment = {y = .Center},
		},
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
		// Clip text inside the frame, never the frame's fractional-pixel border.
		if clay.UI(clay.ID(fmt.tprintf("%sTextClip", id_str)))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(30)},
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		},
		) {
			if view == .Plain {
				field_text(ui, id_str, buf, placeholder, focused, 15)
			} else if len(buf) == 0 {
				// Caret before the hint, where typing will start.
				if focused {
					caret(16)
				}
				clay.Text(placeholder, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			} else {
				count := min(len(buf), 48)
				if box := clay.GetElementData(clay.ID(id_str)); box.found {
					star_w := max(rl.MeasureTextLine(FONT_BODY, 15, "*", 0).x, 1)
					count = min(count, max(1, int((box.boundingBox.width - 40) / star_w)))
				}
				clay.Text(
					strings.repeat("*", count, context.temp_allocator),
					{fontId = FONT_BODY, fontSize = 15, textColor = TEXT},
				)
				if focused {
					caret(16)
				}
			}
		}
	}
}

// The sign-in card's shape, one step earlier: password before identity.
@(private = "file")
gate_layout :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()
	// A create in flight writes vault.db, so the file can't say which
	// form this is until the job ends.
	busy := gate_job.worker != nil
	creating := busy ? gate_job.creating : !vault_exists()
	compact := single_pane() || modal_h(1200) < 500

	if clay.UI(clay.ID("Root"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = BG,
	},
	) {
		// The unlock screen is the first thing anyone sees, so it gets
		// the synthwave rail fan behind it whatever the saved theme is.
		// It draws from the accent color, so it suits every palette.
		if clay.UI(clay.ID("GateCanvas"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				childAlignment = {x = .Center, y = .Center},
			},
			custom = {customData = motion_on() ? &synth_decor : nil},
		},
		) {
			if clay.UI(clay.ID("GateCard"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(fit_w(660)),
						height = clay.SizingFit({max = modal_h(1200)}),
					},
					layoutDirection = .TopToBottom,
					padding = {
						left = compact ? 20 : 50,
						right = compact ? 20 : 50,
						top = compact ? 16 : creating ? 24 : 50,
						bottom = compact ? 16 : creating ? 24 : 50,
					},
					childGap = creating ? 8 : 14,
					childAlignment = {x = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = rr(16),
				border = {color = CARD_BORDER, width = bw()},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				glow(clay.ID("GateCard"), ACCENT, 0.55, 26)
				scrollbar(clay.ID("GateCard"))
				logo_mark()
				clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})
				clay.Text(
					creating ? tr("Pick a password. It encrypts everything in the app, and there is no way to recover it.") : tr("Enter your password to unlock this device's keys."),
					{
						fontId = FONT_BODY,
						fontSize = 15,
						textColor = TEXT_DIM,
						textAlignment = .Center,
					},
				)
				if creating && gate_reset_done {
					if clay.UI(clay.ID("GateResetNotice"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {
						clay.Text(
							tr(
								"Your account keys and chats were deleted from this device. Pick a new password to start over.",
							),
							{
								fontId = FONT_BODY,
								fontSize = 14,
								textColor = TEXT,
								textAlignment = .Center,
							},
						)
					}
				}
				if clay.UI(clay.ID("GateGapA"))(
				{layout = {sizing = {height = clay.SizingFixed(10)}}},
				) {}

				if clay.UI(clay.ID("GatePwLabel"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
						childAlignment = {y = .Center},
						childGap = 8,
					},
				},
				) {
					eyebrow(tr("PASSWORD"))
					if clay.UI(clay.ID("GatePwLabelSpace"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					if !busy {
						micro_button(
							"GatePwShow",
							gate_pw_view == .Masked ? tr("Show") : tr("Hide"),
							TEXT_DIM,
						)
					}
				}
				gate_field(
					ui,
					"GatePwBox",
					&gate_pw,
					!busy && (!gate_confirm || !creating),
					tr("Your password"),
					gate_pw_view,
				)
				if creating {
					password_hint(password_bits(string(gate_pw[:]), &gate_check))
					if clay.UI(clay.ID("GatePw2Label"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
							childAlignment = {y = .Center},
							childGap = 8,
						},
					},
					) {
						eyebrow(tr("CONFIRM PASSWORD"))
						if clay.UI(clay.ID("GatePw2LabelSpace"))(
						{layout = {sizing = {width = clay.SizingGrow()}}},
						) {}
						if !busy {
							micro_button(
								"GatePw2Show",
								gate_pw2_view == .Masked ? tr("Show") : tr("Hide"),
								TEXT_DIM,
							)
						}
					}
					gate_field(
						ui,
						"GatePw2Box",
						&gate_pw2,
						!busy && gate_confirm,
						tr("Type your password again"),
						gate_pw2_view,
					)
				}

				// Reveal the error and action together on short keyboard-height windows.
				if clay.UI(clay.ID("GateSubmit"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 8,
					},
				},
				) {
					if clay.UI(clay.ID("GateError"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow(),
								height = clay.SizingFit({min = 68}),
							},
						},
					},
					) {
						if gate_err != "" {
							clay.Text(
								gate_err,
								{fontId = FONT_BODY, fontSize = 14, textColor = DANGER},
							)
						}
					}
					ready :=
						!creating ||
						(password_bits(string(gate_pw[:]), &gate_check) >= PASSWORD_MIN_BITS &&
								string(gate_pw[:]) == string(gate_pw2[:]))
					if busy {
						login_big_button(
							"GateGo",
							creating ? tr("Creating your vault…") : tr("Unlocking…"),
							true,
							.Busy,
						)
						busy_bar("GateBusy")
						clay.Text(
							creating ? tr("Deriving an encryption key from your password.") : tr("Checking your password and decrypting your keys."),
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
						)
					} else {
						login_big_button(
							"GateGo",
							creating ? tr("Continue") : tr("Unlock"),
							true,
							ready ? .Enabled : .Disabled,
						)
					}
				}
				if !creating && !busy {
					if clay.UI(clay.ID("GateResetGap"))(
					{layout = {sizing = {height = clay.SizingFixed(24)}}},
					) {}
					if gate_reset_armed {
						if clay.UI(clay.ID("GateResetConfirm"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								layoutDirection = .TopToBottom,
								childGap = 12,
							},
						},
						) {
							clay.Text(
								tr(
									"This deletes every account key and all chats on this device. You can only sign in again if you have a backup of your secret key.",
								),
								{fontId = FONT_BODY, fontSize = 14, textColor = DANGER},
							)
							micro_button("GateResetCancel", tr("Keep your keys and chats"), TEXT)
							micro_button("GateReset", tr("Delete keys and chats"), DANGER)
						}
					} else {
						micro_button("GateReset", tr("Forgot password? Start over"), TEXT_DIM)
					}
				}
			}
		}
	}
	return clay.EndLayout(rl.GetFrameTime())
}

// Reveal only on a field or viewport change, never while the user scrolls
// to an action. Password buffers remain masked and out of the clipboard.
@(private)
onboard_reveal_field :: proc(container, field: string) {
	data := clay.GetScrollContainerData(clay.ID(container))
	row := clay.GetElementData(clay.ID(field))
	viewport := clay.GetElementData(clay.ID(container))
	if !data.found || !row.found || !viewport.found {return}
	b, r := viewport.boundingBox, row.boundingBox
	delta := min(r.y - b.y - 8, 0) + max(r.y + r.height - b.y - b.height + 8, 0)
	data.scrollPosition.y = clamp(
		data.scrollPosition.y - delta,
		-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0),
		0,
	)
}
