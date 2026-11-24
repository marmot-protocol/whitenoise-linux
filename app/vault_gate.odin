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

import "nendo"
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

@(private)
Vault_Setup :: enum {
	Welcome,
	Password,
	Confirm,
}
@(private = "file")
gate_err: string
@(private = "file")
gate_weak_warned: bool // a weak password was submitted; "Use this password anyway" shows
@(private = "file")
gate_weak_accepted: bool
// The forgot-password steps. Help explains that no reset exists and has
// no delete control; only Review renders one, so reading help or backing
// out never arms the deletion.
@(private = "file")
Gate_Reset :: enum {
	Closed,
	Help,
	Review,
}
@(private = "file")
gate_reset: Gate_Reset
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
	gate_reset = .Closed
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
	gate_reset = .Closed
	gate_weak_warned, gate_weak_accepted = false, false
	gate_reset_done = false
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
	ui.vault_setup = .Welcome
	gate_weak_warned = false
	gate_weak_accepted = false
	gate_reset = .Closed
	gate_reset_done = false
	gate_pw_view = .Masked
	gate_pw2_view = .Masked
	gate_job = {}
	stagger_arm(nendo.id("OnboardSteps").id)
	stagger_arm(nendo.id("GateContentArrival").id)
	devctl_reset_input()
	defer devctl_reset_input()
	defer editor_forget(ui)
	defer gate_close()
	defer gate_join()
	shot := os.get_env("WN_SHOT", context.temp_allocator) != ""
	previous_height: i32 = -1
	previous_setup := ui.vault_setup
	previous_error := gate_err
	previous_reset := gate_reset
	previous_reset_done := gate_reset_done
	for frame := 0; !rl.WindowShouldClose(); frame += 1 {
		when ODIN_OS == .Darwin {macos_update_tick()}
		if dev_reload_poll() {return false}
		defer free_all(context.temp_allocator)
		poll_system_theme(ui, rl.GetTime())
		anim_tick(rl.GetFrameTime()) // the gate runs its own loop, so it steps its own motion
		apply_zoom(ui) // and its own resize response; a no-op unless the width moved

		pointer := transmute(nendo.Vector2)rl.GetMousePosition()
		forced_press, forced_release = false, false
		devctl_poll(ui, nil, frame, &pointer)
		pointer.x /= UI_ZOOM
		pointer.y /= UI_ZOOM
		nendo.set_pointer(pointer, (rl.IsMouseButtonDown(.LEFT)) ? .Down : .Up)
		scroll_thumb_tick()
		scroll_residual += transmute(nendo.Vector2)rl.GetMouseWheelMoveV()
		step := scroll_residual * anim_drain(SCROLL_DRAIN)
		scroll_residual -= step
		nendo.update_scroll(.Off, step, rl.GetFrameTime())
		nendo.set_dimensions(
			{f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM},
		)

		clear(&drag_targets)
		if previous_setup != ui.vault_setup || previous_reset != gate_reset {
			stagger_arm(nendo.id("GateContentArrival").id)
		}
		render_commands := gate_layout(ui)
		if previous_height != rl.GetScreenHeight() ||
		   previous_setup != ui.vault_setup ||
		   previous_error != gate_err ||
		   previous_reset != gate_reset ||
		   previous_reset_done != gate_reset_done {
			// The first frame opens at the top, so the setup map and copy are
			// read before the form; later resizes (an on-screen keyboard)
			// keep the error and action in view.
			resized := previous_height != -1 && previous_height != rl.GetScreenHeight()
			target := ui.vault_setup == .Confirm && !vault_exists() ? "GatePw2Box" : "GatePwBox"
			if gate_err != "" || resized {
				target = "GateSubmit"
			}
			if previous_height < 0 {target = "GateScope"}
			if !vault_exists() && ui.vault_setup == .Welcome {target = "GateIntroGo"}
			switch gate_reset {
			case .Closed:
			case .Help:
				target = "GateHelpIntro"
			case .Review:
				target = "GateResetWarning"
			}
			if gate_reset_done != previous_reset_done {
				target = "GateResetNotice"
			}
			onboard_reveal_field(gate_reset == .Review ? "GateResetBody" : "GateCard", target)
			previous_height = rl.GetScreenHeight()
			previous_setup = ui.vault_setup
			previous_error = gate_err
			previous_reset = gate_reset
			previous_reset_done = gate_reset_done
			render_commands = gate_layout(ui)
		}
		// A hidden window would block the present until it shows again;
		// skip the frame and poll the unlock job at 4 Hz instead.
		if rl.IsWindowVisible() {
			rl.BeginDrawing()
			rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
			render_nendo(render_commands)
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
		} else {
			rl.Wait(IDLE_REFRESH_MS)
		}
		if gate_job.worker != nil && gate_poll() {
			ui.lock_requested = false
			return true
		}
		update_drag_scroll(ui, false)
		// The first-run close action is the window close, made visible.
		if clicked("GateQuit") {return false}
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
	if gate_job.worker != nil {return}
	creating := !vault_exists()
	if gate_reset == .Review && (clicked("GateResetCancel") || rl.IsKeyPressed(.ESCAPE)) {
		gate_reset = .Closed
		return
	}
	if gate_reset == .Closed && !creating && clicked("GateForgot") {
		gate_reset = .Help
		gate_pw_view = .Masked
		editor_forget(ui)
		return
	}
	if gate_reset == .Help {
		for rl.GetCharPressed() != 0 {}
		if !creating && clicked("GateHelpReview") {
			gate_reset = .Review
		} else if clicked("GateHelpClose") || rl.IsKeyPressed(.ESCAPE) {
			gate_reset = .Closed
		}
		return
	}
	if gate_reset == .Closed && creating && clicked("GateAbout") {
		gate_reset = .Help
		gate_pw_view, gate_pw2_view = .Masked, .Masked
		editor_forget(ui)
		return
	}
	if gate_reset == .Closed && creating && clicked("GateBack") {
		ui.vault_setup = ui.vault_setup == .Confirm ? .Password : .Welcome
		gate_pw_view, gate_pw2_view = .Masked, .Masked
		gate_err = ""
		gate_weak_warned, gate_weak_accepted = false, false
		editor_forget(ui)
		return
	}
	if gate_reset == .Closed && creating && ui.vault_setup == .Welcome {
		for rl.GetCharPressed() != 0 {}
		if clicked("GateIntroGo") || rl.IsKeyPressed(.ENTER) {
			ui.vault_setup = .Password
			editor_forget(ui)
		}
		return
	}

	confirming := creating && ui.vault_setup == .Confirm
	buf := confirming ? &gate_pw2 : &gate_pw
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
		gate_weak_warned = false
		if !confirming {gate_weak_accepted = false}
	}
	// Editing disarms deletion. The review otherwise owns input: Enter
	// and clicks on the covered form never submit or delete.
	if gate_reset == .Review {
		if edited {
			gate_reset = .Closed
			return
		}
		if !clicked("GateResetDelete") || rl.IsKeyPressed(.ENTER) {return}
		gate_reset = .Closed
		vault_stores_quiesce()
		vault_delete()
		mem.zero_slice(gate_pw[:])
		mem.zero_slice(gate_pw2[:])
		clear(&gate_pw)
		clear(&gate_pw2)
		ui.vault_setup = .Welcome
		gate_pw_view, gate_pw2_view = .Masked, .Masked
		gate_reset_done = true
		gate_check = {}
		gate_err = ""
		gate_weak_warned, gate_weak_accepted = false, false
		editor_forget(ui)
		return
	}
	when ODIN_PLATFORM_SUBTARGET == .Android {
		if clicked(confirming ? "GatePw2Box" : "GatePwBox") {rl.ReopenTextInput()}
	}
	if clicked("GatePwShow") {
		gate_pw_view = gate_pw_view == .Masked ? .Plain : .Masked
	}
	if clicked("GatePw2Show") {
		gate_pw2_view = gate_pw2_view == .Masked ? .Plain : .Masked
	}
	other :=
		edited ||
		clicked("GateGo") ||
		rl.IsKeyPressed(.ENTER) ||
		clicked("GatePwBox") ||
		clicked("GatePw2Box") ||
		clicked("GatePwShow") ||
		clicked("GatePw2Show")
	accept_weak := gate_weak_warned && !other && clicked("GateWeakOk")
	if !clicked("GateGo") && !accept_weak && !rl.IsKeyPressed(.ENTER) {return}
	gate_weak_warned = false
	password := string(gate_pw[:])
	if len(password) == 0 {
		gate_err = creating ? tr("Pick a password first.") : tr("Type your password first.")
		return
	}
	if creating && confirming && password != string(gate_pw2[:]) {
		gate_err = tr("The passwords don't match. Type them again.")
		mem.zero_slice(gate_pw2[:])
		clear(&gate_pw2)
		return
	}
	if creating &&
	   !accept_weak &&
	   !gate_weak_accepted &&
	   password_bits(password, &gate_check) < PASSWORD_MIN_BITS {
		gate_err = tr(
			"This password is easy to guess. Someone with this device could guess it and open the vault.",
		)
		gate_weak_warned = true
		return
	}
	if creating && !confirming {
		gate_weak_accepted = accept_weak
		ui.vault_setup = .Confirm
		gate_err = ""
		gate_pw_view = .Masked
		editor_forget(ui)
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
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(max = 560),
		height = nendo.fixed(46),
		padding = {left = 14, right = 14},
		align = {y = .Center},
		color = ROW_BG,
		radius = rr(10),
		border = {color = focused ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		// Every character typed kicks the spring, so the field answers
		// each keystroke with light instead of only growing asterisks.
		pop, _, _ := bump(nendo.id(id_str).id, fmt.tprintf("%d", len(buf)))
		if focused {
			glow(nendo.id(id_str), ACCENT, 0.35 + clamp((pop - 1) * 3, 0, 0.65), 18)
		}
		// Clip text inside the frame, never the frame's fractional-pixel border.
		if nendo.box(nendo.id(fmt.tprintf("%sTextClip", id_str)))(
		{width = nendo.grow(), height = nendo.fixed(30), align = {y = .Center}, clip = {x = true}},
		) {
			if view == .Plain {
				field_text(ui, id_str, buf, placeholder, focused, 15)
			} else if len(buf) == 0 {
				// Caret before the hint, where typing will start.
				if focused {
					caret(16)
				}
				nendo.text(placeholder, {font = FONT_BODY, size = 15, color = TEXT_DIM})
			} else {
				count := min(len(buf), 48)
				if box := nendo.element(nendo.id(id_str)); box.found {
					star_w := max(rl.MeasureTextLine(FONT_BODY, 15, "*", 0).x, 1)
					count = min(count, max(1, int((box.rect.width - 40) / star_w)))
				}
				nendo.text(
					strings.repeat("*", count, context.temp_allocator),
					{font = FONT_BODY, size = 15, color = TEXT},
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
gate_layout :: proc(ui: ^Ui_State) -> []nendo.Render_Command {
	nendo.begin()
	// A create in flight writes vault.db, so the file can't say which
	// form this is until the job ends.
	busy := gate_job.worker != nil
	creating := busy ? gate_job.creating : !vault_exists()
	card_h := clamp(f32(rl.GetScreenHeight()) / UI_ZOOM - 12, 1, 1200)
	compact := single_pane() || card_h < 500
	short := card_h < 240
	pad_y := u16(short ? 8 : compact ? 16 : 28)
	arrived := stagger(nendo.id("GateContentArrival").id, 0)

	if nendo.box(nendo.id("Root"))(
	{width = nendo.grow(), height = nendo.grow(), direction = .Column, color = BG},
	) {
		// The unlock screen is the first thing anyone sees, so it gets
		// the synthwave rail fan behind it whatever the saved theme is.
		// It draws from the accent color, so it suits every palette.
		if nendo.box(nendo.id("GateCanvas"))(
		{
			width = nendo.grow(),
			height = nendo.grow(),
			align = {x = .Center, y = .Center},
			custom = motion_on() ? &synth_decor : nil,
		},
		) {
			if nendo.box(nendo.id("GateCard"))(
			{
				width = nendo.fixed(fit_w(420)),
				height = nendo.fit(max = card_h),
				direction = .Column,
				padding = {
					left = compact ? 20 : 28,
					right = compact ? 20 : 28,
					top = pad_y,
					bottom = pad_y,
				},
				gap = short ? 6 : 16,
				align = {x = .Left},
				color = CARD,
				radius = rr(16),
				border = {
					color = mix_color(CARD_BORDER, ACCENT, (1 - arrived) * 0.1),
					width = bw(),
				},
				clip = {y = true, scroll = true},
			},
			) {
				scrollbar(nendo.id("GateCard"))
				if creating {onboard_steps(.Protect)}
				if nendo.box(nendo.id("GateScope"))({width = nendo.grow()}) {
					nendo.text(
						gate_reset == .Help ? tr("About this password") : !creating ? tr("Unlock your vault") : ui.vault_setup == .Welcome ? tr("First, protect your saved keys.") : ui.vault_setup == .Password ? tr("Choose a vault password") : tr("Confirm your password"),
						{
							font = FONT_TITLE,
							size = creating && ui.vault_setup == .Welcome ? 18 : 22,
							color = fade(TEXT, 0.85 + 0.15 * arrived),
						},
					)
				}
				if creating && gate_reset_done && ui.vault_setup == .Welcome {
					if nendo.box(nendo.id("GateResetNotice"))({width = nendo.grow()}) {
						nendo.text(
							tr(
								"Pick a new password to start a new vault. This does not recover your previous chats or pending sends.",
							),
							{font = FONT_BODY, size = 14, color = TEXT_DIM},
						)
					}
				}
				if gate_reset == .Help {
					if nendo.box(nendo.id("GateHelpBody"))(
					{width = nendo.grow(), direction = .Column, gap = 14},
					) {
						if nendo.box(nendo.id("GateHelpIntro"))({width = nendo.grow()}) {
							nendo.text(
								creating ? tr("This password protects sensitive local data. It is not a service login or a password to share with contacts. Save it in your password manager.") : tr("If you forgot this password, you can try again or close White Noise without deleting anything. Starting over deletes the vault and its protected local data, including chats and pending sends. Review the deletion before deciding."),
								{font = FONT_BODY, size = 14, color = TEXT},
							)
						}
						nendo.text(
							tr(
								"White Noise cannot reset this password to unlock your existing vault.",
							),
							{font = FONT_BODY, size = 14, color = TEXT_DIM},
						)
						nendo.text(
							tr(
								"A backup-file password opens only that backup file. Your identity key or remote signer cannot unlock this vault.",
							),
							{font = FONT_BODY, size = 14, color = TEXT_DIM},
						)
						if !creating {
							nendo.text(
								tr(
									"To use the same identity after starting over, you need its secret key saved elsewhere or access to its remote signer. The signer's private key stays with that signer. Without either, you cannot sign in to that identity. Signing in again does not restore this device's chats. A settings backup does not contain account keys or message history.",
								),
								{font = FONT_BODY, size = 14, color = TEXT_DIM},
							)
						}
						micro_button(
							"GateHelpClose",
							creating ? tr("Back") : tr("Try again"),
							TEXT,
						)
						if !creating {micro_button("GateHelpReview", tr("Review local data deletion"), TEXT_DIM)}
					}
				} else if creating && ui.vault_setup == .Welcome {
					login_big_button("GateIntroGo", tr("Continue"), true)
					micro_button("GateAbout", tr("About this password"), TEXT_DIM)
				} else {
					confirming := creating && ui.vault_setup == .Confirm
					nendo.text(
						!creating ? tr("Enter your password to unlock your local vault on this device.") : confirming ? tr("Type it again to protect your local vault.") : tr("Save this password in your password manager. White Noise cannot reset it to unlock this device's vault."),
						{font = FONT_BODY, size = 14, color = fade(TEXT_DIM, 0.9 + 0.1 * arrived)},
					)
					if nendo.box(nendo.id("GatePwLabel"))(
					{
						width = nendo.grow(),
						height = nendo.fixed(28),
						align = {y = .Center},
						gap = 8,
					},
					) {
						eyebrow(confirming ? tr("CONFIRM PASSWORD") : tr("PASSWORD"))
						if confirming {
							matches :=
								len(gate_pw2) > 0 && string(gate_pw[:]) == string(gate_pw2[:])
							confirmed := anim_to(
								nendo.id("GatePasswordMatch").id,
								matches ? 1 : 0,
								HOVER_RATE,
							)
							if nendo.box(nendo.id("GatePasswordMatch"))(
							{
								width = nendo.fixed(16),
								height = nendo.fixed(16),
								align = {x = .Center, y = .Center},
							},
							) {
								// A changed entry loses its tick immediately, even during the fade.
								if matches {
									glow(
										nendo.id("GatePasswordMatch"),
										ACCENT,
										confirmed * (1 - confirmed) * 0.5,
										6,
									)
									nendo.text(
										ICON_CHECK,
										{
											font = FONT_ICON,
											size = 12,
											color = fade(ACCENT, confirmed),
										},
									)
								}
							}
						}
						if nendo.box(nendo.id("GatePwLabelSpace"))({width = nendo.grow()}) {}
						if !busy {
							view := confirming ? gate_pw2_view : gate_pw_view
							micro_button(
								confirming ? "GatePw2Show" : "GatePwShow",
								view == .Masked ? tr("Show") : tr("Hide"),
								TEXT_DIM,
							)
						}
					}
					gate_field(
						ui,
						confirming ? "GatePw2Box" : "GatePwBox",
						confirming ? &gate_pw2 : &gate_pw,
						!busy && gate_reset != .Review,
						confirming ? tr("Type your password again") : tr("Your password"),
						confirming ? gate_pw2_view : gate_pw_view,
					)
					if creating && !confirming {
						password_bits(string(gate_pw[:]), &gate_check)
						password_hint(&gate_check)
					}
					if nendo.box(nendo.id("GateSubmit"))(
					{width = nendo.grow(), direction = .Column, gap = 12},
					) {
						if gate_err != "" {
							nendo.text(gate_err, {font = FONT_BODY, size = 14, color = DANGER})
						}
						if gate_weak_warned {
							micro_button("GateWeakOk", tr("Use this password anyway"), DANGER)
						}
						ready := !creating || (confirming ? len(gate_pw2) > 0 : len(gate_pw) > 0)
						login_big_button(
							"GateGo",
							busy ? (creating ? tr("Creating your vault…") : tr("Unlocking…")) : !creating ? tr("Unlock") : confirming ? tr("Create vault") : tr("Continue"),
							true,
							busy ? .Busy : ready ? .Enabled : .Disabled,
						)
						if busy {
							busy_bar("GateBusy")
							nendo.text(
								creating ? tr("Deriving an encryption key from your password.") : tr("Checking your password and decrypting your local vault."),
								{font = FONT_BODY, size = 12, color = TEXT_LO},
							)
						}
					}
					if !busy {
						if creating {
							if nendo.box(nendo.id("GateNavigation"))(
							{width = nendo.grow(), gap = 12},
							) {
								micro_button("GateBack", tr("Back"), TEXT_DIM)
								if nendo.box(nendo.id("GateNavigationSpace"))(
								{width = nendo.grow()},
								) {}
								if !confirming {micro_button("GateAbout", tr("About this password"), TEXT_DIM)}
							}
						} else {
							micro_button("GateForgot", tr("Forgot password?"), TEXT_DIM)
						}
					}
				}
			}
		}
		if open_now(nendo.id("ModalVeil"), gate_reset == .Review) {
			modal_backdrop()
		}
		if gate_reset == .Review {
			narrow := fit_w(640) < 500
			if nendo.box(nendo.id("GateResetReview"))(
			{
				width = nendo.fixed(fit_w(640)),
				height = nendo.fit(max = modal_h(1200)),
				direction = .Column,
				color = CARD,
				radius = rr(18),
				border = {color = ELEVATED_BORDER, width = bw()},
				floating = {
					attach_to = .Root,
					z = 16,
					attach = {element = .Center_Center, parent = .Center_Center},
				},
			},
			) {
				if nendo.box(nendo.id("GateResetBody"))(
				{
					width = nendo.grow(),
					height = nendo.fit(max = max(1, modal_h(1200) - 72)),
					direction = .Column,
					padding = nendo.pad(narrow ? 16 : 28),
					gap = 20,
					clip = {y = true, scroll = true},
				},
				) {
					scrollbar(nendo.id("GateResetBody"), 17)
					if nendo.box(nendo.id("GateResetHeading"))(
					{width = nendo.grow(), gap = 16, align = {y = .Center}},
					) {
						if nendo.box(nendo.id("GateResetEmblem"))(
						{
							width = nendo.fixed(48),
							height = nendo.fixed(48),
							align = {x = .Center, y = .Center},
							color = fade(DANGER, 0.10),
							border = {color = fade(DANGER, 0.3), width = bw()},
							radius = rr(14),
						},
						) {nendo.text(ICON_TRASH, {font = FONT_ICON, size = 24, color = DANGER})}
						if nendo.box(nendo.id("GateResetHeadingText"))(
						{width = nendo.grow(), direction = .Column, gap = 6},
						) {
							nendo.text(
								tr("START OVER"),
								{font = FONT_TITLE, size = 10, color = DANGER, spacing = 2},
							)
							nendo.text(
								tr("Delete this device's vault?"),
								{font = FONT_TITLE, size = narrow ? 20 : 24, color = TEXT},
							)
						}
					}
					if nendo.box(nendo.id("GateResetScope"))(
					{width = nendo.grow(), gap = 10, align = {y = .Center}},
					) {
						nendo.text(ICON_PEOPLE, {font = FONT_ICON, size = 14, color = TEXT_DIM})
						nendo.text(
							tr("Every account in this vault. This computer only."),
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
					}
					cards := [4]struct {
						icon, title, detail: string,
					} {
						{
							ICON_KEY,
							N_("Account access"),
							N_(
								"Account keys stored here, remote signer sessions and the local encryption key.",
							),
						},
						{ICON_ENVELOPE, N_("Pending sends"), N_("Messages waiting to be sent.")},
						{
							ICON_FOLDER,
							N_("Cached media"),
							N_("Attachments, avatars, transcripts and map tiles."),
						},
						{ICON_SMILE, N_("Saved collections"), N_("Your saved stickers and GIFs.")},
					}
					if nendo.box(nendo.id("GateResetInventory"))(
					{width = nendo.grow(), direction = .Column, gap = 10},
					) {
						nendo.text(
							tr("WILL BE DELETED"),
							{font = FONT_TITLE, size = 10, color = TEXT_LO, spacing = 1},
						)
						columns := narrow ? 1 : 2
						for row in 0 ..< len(cards) / columns {
							if nendo.box(nendo.id("GateResetCardRow", u32(row)))(
							{width = nendo.grow(), gap = 10},
							) {
								for column in 0 ..< columns {
									i := row * columns + column
									card := cards[i]
									if nendo.box(nendo.id("GateResetCard", u32(i)))(
									{
										width = nendo.grow(),
										height = nendo.fit(min = narrow ? 76 : 96),
										padding = nendo.pad(14),
										gap = 12,
										color = ROW_BG,
										border = {color = FIELD_BORDER, width = bw()},
										radius = rr(10),
									},
									) {
										nendo.text(
											card.icon,
											{font = FONT_ICON, size = 20, color = DANGER},
										)
										if nendo.box(nendo.id("GateResetCardText", u32(i)))(
										{width = nendo.grow(), direction = .Column, gap = 6},
										) {
											nendo.text(
												tr(card.title),
												{font = FONT_TITLE, size = 14, color = TEXT},
											)
											nendo.text(
												tr(card.detail),
												{font = FONT_BODY, size = 12, color = TEXT_DIM},
											)
										}
									}
								}
							}
						}
					}
					if nendo.box(nendo.id("GateResetWarning"))(
					{
						width = nendo.grow(),
						padding = nendo.pad(14),
						gap = 12,
						color = fade(DANGER, 0.07),
						border = {color = fade(DANGER, 0.5), width = {left = 3}},
						radius = rr(8),
					},
					) {
						nendo.text(ICON_BAN, {font = FONT_ICON, size = 18, color = DANGER})
						if nendo.box(nendo.id("GateResetWarningText"))(
						{width = nendo.grow(), direction = .Column, gap = 5},
						) {
							nendo.text(
								tr("This can't be undone."),
								{font = FONT_TITLE, size = 14, color = DANGER},
							)
							nendo.text(
								tr(
									"Settings backups do not include these stores and cannot restore them.",
								),
								{font = FONT_BODY, size = 12, color = TEXT_DIM},
							)
						}
					}
					if nendo.box(nendo.id("GateResetUnchanged"))(
					{width = nendo.grow(), gap = 10},
					) {
						nendo.text(ICON_GLOBE, {font = FONT_ICON, size = 14, color = ACCENT})
						nendo.text(
							tr(
								"Other devices, public profiles and group membership are unchanged.",
							),
							{font = FONT_BODY, size = 12, color = TEXT_DIM},
						)
					}
					nendo.text(
						tr(
							"A separate secret key or signer lets you use an identity again. It does not restore chats, pending sends or saved collections.",
						),
						{font = FONT_BODY, size = 12, color = TEXT_LO},
					)
				}
				// The safe exit stays visible even when the inventory needs scrolling.
				if nendo.box(nendo.id("GateResetActions"))(
				{
					width = nendo.grow(),
					padding = nendo.pad(12),
					gap = 8,
					border = {color = FIELD_BORDER, width = {top = 1}},
				},
				) {
					for action, i in ([2]struct {
							id, label, icon: string,
						}{{"GateResetCancel", tr("Keep vault"), ICON_REPLY}, {"GateResetDelete", tr("Delete vault"), ICON_TRASH}}) {
						if nendo.box(nendo.id(action.id))(
						{
							width = nendo.grow(),
							height = nendo.fit(min = 44),
							padding = {left = 12, right = 12, top = 12, bottom = 12},
							gap = 8,
							align = {x = .Center, y = .Center},
							color = i == 0 ? (hovered() ? ACCENT_DIM : ACCENT) : (hovered() ? fade(DANGER, 0.16) : fade(DANGER, 0.05)),
							border = {color = i == 0 ? ACCENT : fade(DANGER, 0.6), width = bw()},
							radius = rr(9),
						},
						) {
							if hovered() {cursor_raise(.Pointer)}
							if !narrow {
								nendo.text(
									action.icon,
									{
										font = FONT_ICON,
										size = 13,
										color = i == 0 ? ON_ACCENT : DANGER,
									},
								)
							}
							nendo.text(
								action.label,
								{
									font = FONT_TITLE,
									size = 13,
									color = i == 0 ? ON_ACCENT : DANGER,
									align = .Center,
								},
							)
						}
					}
				}
			}
		}
	}
	return nendo.end(rl.GetFrameTime())
}

// Reveal only on a field or viewport change, never while the user scrolls
// to an action. Password buffers remain masked and out of the clipboard.
@(private)
onboard_reveal_field :: proc(container, field: string) {
	data := nendo.scroll(nendo.id(container))
	row := nendo.element(nendo.id(field))
	viewport := nendo.element(nendo.id(container))
	if !data.found || !row.found || !viewport.found {return}
	b, r := viewport.rect, row.rect
	delta := min(r.y - b.y - 8, 0) + max(r.y + r.height - b.y - b.height + 8, 0)
	data.position.y = clamp(
		data.position.y - delta,
		-max(data.content.height - data.viewport.height, 0),
		0,
	)
}
