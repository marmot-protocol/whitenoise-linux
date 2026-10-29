package main

import gate_runtime "base:runtime"
import gate_sync "core:sync"
import gate_testing "core:testing"
import edit "core:text/edit"

// Submit once and wait out the unlock worker. True when the vault opened.
gate_submit :: proc(ui: ^Ui_State) -> bool {
	gate_input(ui)
	for gate_job.worker != nil {
		if gate_poll() {return true}
	}
	return false
}

@(test)
vault_gate_empty_password_copy :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&clay_test_mutex)
	defer gate_sync.unlock(&clay_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-empty", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {
		vault_delete()
		data_home = old_home
		gate_close()
		gate_confirm = false
		gate_err = ""
		gate_reset_armed = false
	}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui: Ui_State
	clay.BeginLayout()
	clay.EndLayout(0)
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)

	// First-run creation must still ask the user to choose a password.
	gate_input(&ui)
	gate_testing.expect_value(t, gate_err, tr("Pick a password first."))
	gate_testing.expect(t, gate_job.worker == nil)
	gate_testing.expect(t, !vault_exists())

	// The same submit on an existing, locked vault must ask for its password.
	if !gate_testing.expect_value(t, vault_create("right"), Vault_Err.None) {return}
	vault_relock()
	gate_input(&ui)
	gate_testing.expect_value(t, gate_err, tr("Type your password first."))
	gate_testing.expect(t, gate_job.worker == nil)
	gate_testing.expect(t, vault_exists())
	gate_testing.expect(t, !g_vault.unlocked)
	gate_testing.expect_value(t, len(gate_pw), 0)
}

@(test)
vault_gate_password_policy :: proc(t: ^gate_testing.T) {
	// The unlock worker allocates the blob key on the default heap.
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&clay_test_mutex)
	defer gate_sync.unlock(&clay_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-policy", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {vault_delete(); data_home = old_home; gate_close(); gate_confirm = false; gate_err = ""}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui: Ui_State
	clay.BeginLayout()
	clay.EndLayout(0)
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)

	append(&gate_pw, "Password123!")
	append(&gate_pw2, "Password123!")
	gate_confirm = true
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect(t, !vault_exists())

	strong := "marmot on burrowed time thimble lantern"
	clear(&gate_pw); append(&gate_pw, strong)
	gate_testing.expect(t, !gate_submit(&ui)) // confirmation still contains the old password
	gate_testing.expect(t, !vault_exists())
	append(&gate_pw2, strong)
	// Submitting returns at once with the derivation running, so the
	// card can show it working.
	gate_input(&ui)
	gate_testing.expect(t, gate_job.worker != nil)
	gate_testing.expect(t, gate_job.creating)
	for gate_job.worker != nil && !gate_poll() {}
	gate_testing.expect_value(t, gate_job.err, Vault_Err.None)
	gate_testing.expect(t, vault_verify(strong))

	// The policy must never lock users out of an existing weak-password vault.
	vault_delete()
	gate_testing.expect_value(t, vault_create("x"), Vault_Err.None)
	clear(&gate_pw); append(&gate_pw, "y")
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect(t, gate_err != "")
	gate_testing.expect_value(t, len(gate_pw), 0)
	clear(&gate_pw); append(&gate_pw, "x")
	gate_testing.expect(t, gate_submit(&ui))
	gate_testing.expect(t, vault_verify("x"))
}

@(test)
vault_gate_manual_relock :: proc(t: ^gate_testing.T) {
	// Without a reload heap, gate threads own vault data in the default allocator.
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&clay_test_mutex)
	defer gate_sync.unlock(&clay_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-relock", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {vault_delete(); data_home = old_home; gate_close(); gate_confirm = false; gate_err = ""}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.BeginLayout(); clay.EndLayout(0)
	old_password := os.get_env("WN_VAULT_PW", context.temp_allocator)
	os.set_env("WN_VAULT_PW", "right")
	defer {
		if old_password ==
		   "" {os.unset_env("WN_VAULT_PW")} else {os.set_env("WN_VAULT_PW", old_password)}
	}
	gate_testing.expect_value(t, vault_create("right"), Vault_Err.None)
	gate_testing.expect_value(t, vault_set("account:alice", "signing-secret"), Vault_Err.None)
	ui: Ui_State
	lock_now(&ui)
	gate_testing.expect(t, ui.lock_requested)
	gate_testing.expect_value(t, os.get_env("WN_VAULT_PW", context.temp_allocator), "")
	vault_relock()
	gate_testing.expect(t, !g_vault.unlocked)
	gate_testing.expect(t, !vault_has("account:alice"))
	gate_testing.expect_value(t, g_vault.key, [VAULT_KEY_LEN]u8{})
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)
	append(&gate_pw, "wrong")
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect(t, !g_vault.unlocked)
	gate_testing.expect(t, ui.lock_requested)
	append(&gate_pw, "right")
	gate_testing.expect(t, gate_submit(&ui))
	value, found := vault_get("account:alice", context.temp_allocator)
	gate_testing.expect(t, found && value == "signing-secret")
}

@(test)
vault_gate_reset_disarms :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&clay_test_mutex)
	defer gate_sync.unlock(&clay_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-disarm", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {
		vault_delete()
		data_home = old_home
		gate_close()
		gate_confirm = false
		gate_err = ""
		gate_reset_armed = false
	}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	clay.BeginLayout()
	clay.EndLayout(0)
	rl.PushKey(.ENTER, false)
	for rl.GetCharPressed() != 0 {}

	gate_reset_armed = true
	rl.PushChar('x')
	gate_input(&ui)
	gate_testing.expect(t, !gate_reset_armed, "a keystroke disarms vault deletion")
	gate_testing.expect(t, !vault_exists(), "disarming must not delete the vault")
	gate_testing.expect_value(t, len(gate_pw), 1)

	gate_testing.expect_value(t, vault_create("right"), Vault_Err.None)
	clear(&gate_pw)
	append(&gate_pw, "nope")
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)
	gate_input(&ui)
	gate_testing.expect(t, gate_job.worker != nil)
	gate_reset_armed = true
	for gate_job.worker != nil {
		if gate_poll() {
			gate_testing.expect(t, false, "wrong password must not open the vault")
			return
		}
	}
	gate_testing.expect(t, !gate_reset_armed, "a failed unlock disarms vault deletion")
	gate_testing.expect(t, vault_exists())
}

@(test)
vault_gate_confirmation_dispatch :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&clay_test_mutex)
	defer gate_sync.unlock(&clay_test_mutex)
	rl.InitWindow(1024, 700, "Vault confirmation")
	defer rl.CloseWindow()
	old_zoom := UI_ZOOM
	UI_ZOOM = 1
	defer {UI_ZOOM = old_zoom}
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-confirm", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {
		gate_join()
		vault_delete()
		data_home = old_home
		gate_close()
		gate_confirm = false
		gate_err = ""
		gate_reset_armed = false
		rl.PushKey(.ENTER, false)
		forced_press, forced_release = false, false
	}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	clay.SetMeasureTextFunction(
		proc "c" (
			text: clay.StringSlice,
			config: ^clay.TextElementConfig,
			user: rawptr,
		) -> clay.Dimensions {
			return {f32(text.length) * f32(config.fontSize) / 2, f32(config.fontSize)}
		},
		nil,
	)
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	rl.PushKey(.ENTER, false)
	clay.SetPointerState({-100, -100}, false)

	click_go :: proc(ui: ^Ui_State) {
		gate_layout(ui)
		box := clay.GetElementData(clay.ID("GateGo")).boundingBox
		point := clay.Vector2{box.x + box.width / 2, box.y + box.height / 2}
		clay.SetPointerState(point, true)
		rl.PushMouseButton(.LEFT, true)
		gate_layout(ui)
		gate_input(ui)
		clay.SetPointerState(point, false)
		rl.PushMouseButton(.LEFT, false)
		gate_layout(ui)
		gate_input(ui)
		clay.SetPointerState({-100, -100}, false)
	}
	strong := "marmot on burrowed time thimble lantern"
	append(&gate_pw, "Password123!")
	append(&gate_pw2, "Password123!")
	click_go(&ui)
	gate_testing.expect(
		t,
		gate_job.worker == nil && !vault_exists(),
		"weak passwords cannot create a vault",
	)
	clear(&gate_pw)
	append(&gate_pw, strong)
	gate_input(&ui)
	gate_testing.expect(
		t,
		gate_err == "",
		"correcting strength clears the stale rejection without submitting",
	)
	gate_confirm = false
	click_go(&ui)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	gate_testing.expect(t, gate_confirm)
	mismatch_error := gate_err
	gate_input(&ui)
	gate_testing.expect(
		t,
		gate_err == mismatch_error,
		"a strong password must not clear an unrelated rejection",
	)

	// An idle frame cannot launch a job after a rejected click.
	gate_input(&ui)
	gate_testing.expect(t, gate_job.worker == nil)
	clear(&gate_pw2)
	gate_confirm = false
	rl.PushKey(.ENTER, true)
	gate_input(&ui)
	rl.PushKey(.ENTER, false)
	gate_testing.expect(
		t,
		gate_confirm && gate_job.worker == nil,
		"first-field Enter still focuses confirmation",
	)
	for r in strong {rl.PushChar(r)}
	gate_input(&ui)
	gate_testing.expect_value(t, string(gate_pw2[:]), strong)
	gate_confirm = false
	click_go(&ui)
	gate_testing.expect(
		t,
		gate_job.worker != nil,
		"mouse submit must start creation even while the first field has focus",
	)
	for gate_job.worker != nil && !gate_poll() {}
	gate_testing.expect(t, vault_verify(strong))

	// Existing vaults must remain unlockable with their original weak password.
	vault_delete()
	gate_testing.expect_value(t, vault_create("x"), Vault_Err.None)
	vault_relock()
	clear(&gate_pw)
	append(&gate_pw, "x")
	clear(&gate_pw2)
	click_go(&ui)
	gate_testing.expect(t, gate_job.worker != nil && !gate_job.creating)
	for gate_job.worker != nil && !gate_poll() {}
	gate_testing.expect(t, vault_verify("x"))
}
