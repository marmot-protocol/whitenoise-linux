package main

import pw_sync "core:sync"
import pw_testing "core:testing"

@(test)
vault_change_password_policy :: proc(t: ^pw_testing.T) {
	pw_sync.lock(&clay_test_mutex)
	defer pw_sync.unlock(&clay_test_mutex)
	pw_sync.lock(&test_home_lock)
	defer pw_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-password-policy", context.temp_allocator)
	if !pw_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {vault_delete(); data_home = old_home}
	pw_testing.expect_value(t, vault_create("x"), Vault_Err.None)
	pw_testing.expect_value(t, vault_set("account:test", "secret"), Vault_Err.None)
	ui := Ui_State {
		vault_pw_open = true,
	}
	defer {for field in ui.vault_pw {delete(field)}}
	append(&ui.vault_pw[.Current], "x")
	append(&ui.vault_pw[.New], "Password123!")
	append(&ui.vault_pw[.Confirm], "Password123!")
	vault_pw_apply(&ui)
	pw_testing.expect(t, ui.vault_pw_open)
	pw_testing.expect(t, vault_verify("x"))
	pw_testing.expect(t, !vault_verify("Password123!"))

	strong := "marmot on burrowed time thimble lantern"
	clear(&ui.vault_pw[.New]); append(&ui.vault_pw[.New], strong)
	clear(&ui.vault_pw[.Confirm]); append(&ui.vault_pw[.Confirm], strong)
	vault_pw_apply(&ui)
	pw_testing.expect(t, !ui.vault_pw_open)
	pw_testing.expect(t, !vault_verify("x"))
	pw_testing.expect(t, vault_verify(strong))
	secret, found := vault_get("account:test", context.temp_allocator)
	pw_testing.expect(t, found && secret == "secret")
	for byte in ui.vault_pw_check.sample {pw_testing.expect_value(t, byte, u8(0))}
}
