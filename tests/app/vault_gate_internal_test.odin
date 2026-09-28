package main

import gate_sync "core:sync"
import gate_testing "core:testing"

@(test)
vault_gate_password_policy :: proc(t: ^gate_testing.T) {
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
	gate_testing.expect(t, !gate_input(&ui))
	gate_testing.expect(t, !vault_exists())

	strong := "marmot on burrowed time thimble lantern"
	clear(&gate_pw); append(&gate_pw, strong)
	gate_testing.expect(t, !gate_input(&ui)) // confirmation still contains the old password
	gate_testing.expect(t, !vault_exists())
	append(&gate_pw2, strong)
	gate_testing.expect(t, gate_input(&ui))
	gate_testing.expect(t, vault_verify(strong))

	// The policy must never lock users out of an existing weak-password vault.
	vault_delete()
	gate_testing.expect_value(t, vault_create("x"), Vault_Err.None)
	clear(&gate_pw); append(&gate_pw, "x")
	gate_testing.expect(t, gate_input(&ui))
	gate_testing.expect(t, vault_verify("x"))
}
