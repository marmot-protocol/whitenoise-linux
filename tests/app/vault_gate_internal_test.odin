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
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
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
		gate_err = ""
		gate_reset = .Closed
	}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui: Ui_State
	nendo.begin()
	nendo.end(0)
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)

	// Enter leaves the introduction without creating a vault.
	gate_input(&ui)
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Password)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	gate_testing.expect_value(t, len(gate_pw), 0)
	gate_input(&ui)
	gate_testing.expect(t, gate_err != "")
	gate_testing.expect(t, gate_job.worker == nil)
	gate_testing.expect(t, !vault_exists())

	// The same submit on an existing, locked vault must ask for its password.
	if !gate_testing.expect_value(t, vault_create("right"), Vault_Err.None) {return}
	vault_relock()
	gate_input(&ui)
	gate_testing.expect(t, gate_err != "")
	gate_testing.expect(t, gate_job.worker == nil)
	gate_testing.expect(t, vault_exists())
	gate_testing.expect(t, !g_vault.unlocked)
	gate_testing.expect_value(t, len(gate_pw), 0)
}

@(test)
vault_gate_password_policy :: proc(t: ^gate_testing.T) {
	// The unlock worker allocates the blob key on the default heap.
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-policy", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {vault_delete(); data_home = old_home; gate_close(); gate_err = ""}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		vault_setup = .Password,
	}
	nendo.begin()
	nendo.end(0)
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)

	append(&gate_pw, "Password123!")
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Password)
	gate_testing.expect(t, gate_err != "")
	gate_testing.expect(t, !vault_exists())

	strong := "marmot on burrowed time thimble lantern"
	clear(&gate_pw); append(&gate_pw, strong)
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Confirm)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	append(&gate_pw2, "different password")
	gate_testing.expect(t, !gate_submit(&ui))
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Confirm)
	gate_testing.expect(t, gate_err != "")
	gate_testing.expect(t, !vault_exists())
	clear(&gate_pw2)
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
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-relock", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	defer {vault_delete(); data_home = old_home; gate_close(); gate_err = ""}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {nendo.set_context(previous); delete(memory)}
	nendo.begin(); nendo.end(0)
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
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
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
		gate_err = ""
		gate_reset = .Closed
	}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		vault_setup = .Password,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	nendo.begin()
	nendo.end(0)
	rl.PushKey(.ENTER, false)
	for rl.GetCharPressed() != 0 {}

	gate_reset = .Review
	rl.PushChar('x')
	gate_input(&ui)
	gate_testing.expect(t, gate_reset == .Closed, "a keystroke disarms vault deletion")
	gate_testing.expect(t, !vault_exists(), "disarming must not delete the vault")
	gate_testing.expect_value(t, len(gate_pw), 1)

	gate_testing.expect_value(t, vault_create("right"), Vault_Err.None)
	clear(&gate_pw)
	append(&gate_pw, "nope")
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)
	gate_input(&ui)
	gate_testing.expect(t, gate_job.worker != nil)
	gate_reset = .Review
	for gate_job.worker != nil {
		if gate_poll() {
			gate_testing.expect(t, false, "wrong password must not open the vault")
			return
		}
	}
	gate_testing.expect(t, gate_reset == .Closed, "a failed unlock disarms vault deletion")
	gate_testing.expect(t, vault_exists())
}

@(test)
vault_gate_review_blocks_input :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
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
		gate_err = ""
		gate_reset = .Closed
	}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	nendo.begin()
	nendo.end(0)
	rl.PushKey(.ENTER, false)
	for rl.GetCharPressed() != 0 {}

	gate_testing.expect_value(t, vault_create("right"), Vault_Err.None)
	gate_testing.expect_value(t, vault_set("account:alice", "alice-secret"), Vault_Err.None)
	gate_testing.expect_value(t, vault_set("account:bob", "bob-secret"), Vault_Err.None)
	vault_relock()
	append(&gate_pw, "right")
	gate_reset = .Review
	rl.PushKey(.ENTER, true)
	defer rl.PushKey(.ENTER, false)
	gate_input(&ui)
	gate_testing.expect(t, gate_reset == .Review)
	gate_testing.expect(
		t,
		gate_job.worker == nil,
		"Enter cannot unlock or delete behind the review",
	)
	gate_testing.expect(t, vault_exists())
	rl.PushKey(.ENTER, false)
	rl.PushKey(.ESCAPE, true)
	gate_input(&ui)
	rl.PushKey(.ESCAPE, false)
	gate_testing.expect(t, gate_reset != .Review)
	gate_testing.expect_value(t, vault_open("right"), Vault_Err.None)
	alice, a_ok := vault_get("account:alice", context.temp_allocator)
	bob, b_ok := vault_get("account:bob", context.temp_allocator)
	gate_testing.expect(t, a_ok && alice == "alice-secret" && b_ok && bob == "bob-secret")
}

@(test)
vault_gate_confirmation_dispatch :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
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
		gate_err = ""
		gate_reset = .Closed
		rl.PushKey(.ENTER, false)
		forced_press, forced_release = false, false
	}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	nendo.set_measure_text(
		proc(text: string, config: ^nendo.Text_Style, user: rawptr) -> nendo.Dimensions {
			return {f32(len(text)) * f32(config.size) / 2, f32(config.size)}
		},
		nil,
	)
	defer {nendo.set_context(previous); delete(memory)}
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	rl.PushKey(.ENTER, false)
	nendo.set_pointer({-100, -100}, .Up)

	click_action :: proc(t: ^gate_testing.T, ui: ^Ui_State, id: string) -> bool {
		gate_layout(ui)
		onboard_reveal_field("GateCard", id)
		gate_layout(ui)
		data := nendo.element(nendo.id(id))
		if !gate_testing.expect(t, data.found && data.rect.width > 0, id) {return false}
		box := data.rect
		point := nendo.Vector2{box.x + box.width / 2, box.y + box.height / 2}
		nendo.set_pointer(point, .Down)
		rl.PushMouseButton(.LEFT, true)
		gate_layout(ui)
		gate_input(ui)
		nendo.set_pointer(point, .Up)
		rl.PushMouseButton(.LEFT, false)
		gate_layout(ui)
		gate_input(ui)
		if id == "GateBack" {
			gate_testing.expect(t, ui.ed_target == nil && gate_err == "")
		}
		nendo.set_pointer({-100, -100}, .Up)
		gate_layout(ui)
		return true
	}
	strong := "marmot on burrowed time thimble lantern"
	for rl.GetCharPressed() != 0 {}
	for r in "hidden password" {rl.PushChar(r)}
	gate_input(&ui)
	gate_testing.expect_value(t, len(gate_pw), 0)
	gate_testing.expect_value(t, len(gate_pw2), 0)
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Welcome)
	gate_layout(&ui)
	gate_testing.expect(t, !nendo.element(nendo.id("GatePwBox")).found)
	gate_testing.expect(t, !nendo.element(nendo.id("GatePw2Box")).found)
	if !click_action(t, &ui, "GateIntroGo") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Password)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	gate_testing.expect(t, nendo.element(nendo.id("GatePwBox")).found)
	gate_testing.expect(t, !nendo.element(nendo.id("GatePw2Box")).found)
	append(&gate_pw, "Password123!")
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(
		t,
		ui.vault_setup == .Password && gate_job.worker == nil && !vault_exists(),
		"weak passwords need an explicit opt-in before confirmation",
	)
	rl.PushChar('x')
	gate_input(&ui)
	gate_layout(&ui)
	gate_testing.expect(
		t,
		gate_err == "" && !nendo.element(nendo.id("GateWeakOk")).found,
		"editing withdraws the weak-password opt-in",
	)
	clear(&gate_pw)
	for r in strong {rl.PushChar(r)}
	gate_input(&ui)
	gate_testing.expect(
		t,
		gate_err == "",
		"correcting strength clears the stale rejection without submitting",
	)
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Confirm)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	gate_testing.expect(t, !nendo.element(nendo.id("GatePwBox")).found)
	gate_testing.expect(t, nendo.element(nendo.id("GatePw2Box")).found)
	for r in "different password" {rl.PushChar(r)}
	gate_input(&ui)
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists() && gate_err != "")
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
	if !click_action(t, &ui, "GateBack") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Password)
	gate_testing.expect_value(t, string(gate_pw[:]), strong)
	gate_testing.expect(t, gate_err == "" && gate_job.worker == nil && !vault_exists())
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Confirm)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	clear(&gate_pw2)
	for r in strong {rl.PushChar(r)}
	gate_input(&ui)
	gate_testing.expect_value(t, string(gate_pw2[:]), strong)
	match_visible :: proc(ui: ^Ui_State) -> bool {
		commands := gate_layout(ui)
		box := nendo.element(nendo.id("GatePasswordMatch")).rect
		for command in commands {
			if command.kind != .Text || command.text.font != FONT_ICON {continue}
			text := command.text.text
			bounds := command.rect
			if text == ICON_CHECK &&
			   command.text.color.a > 0 &&
			   bounds.x + bounds.width / 2 >= box.x &&
			   bounds.x + bounds.width / 2 <= box.x + box.width &&
			   bounds.y + bounds.height / 2 >= box.y &&
			   bounds.y + bounds.height / 2 <= box.y + box.height {
				return true
			}
		}
		return false
	}
	// The success signal must not linger after an edit, even within the same frame.
	anim_set(nendo.id("GatePasswordMatch").id, 1)
	gate_testing.expect(t, match_visible(&ui))
	last := len(gate_pw2) - 1
	gate_pw2[last] ~= 1
	gate_testing.expect(t, !match_visible(&ui))
	gate_pw2[last] ~= 1
	if !click_action(t, &ui, "GatePw2Show") {return}
	gate_testing.expect_value(t, gate_pw2_view, Secret_Field_View.Plain)
	gate_pw_view = .Plain
	if !click_action(t, &ui, "GateBack") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Password)
	gate_testing.expect_value(t, string(gate_pw[:]), strong)
	gate_testing.expect_value(t, string(gate_pw2[:]), strong)
	gate_testing.expect_value(t, gate_pw_view, Secret_Field_View.Masked)
	gate_testing.expect_value(t, gate_pw2_view, Secret_Field_View.Masked)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	if !click_action(t, &ui, "GateBack") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Welcome)
	gate_testing.expect_value(t, string(gate_pw[:]), strong)
	if !click_action(t, &ui, "GateIntroGo") {return}
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Confirm)
	gate_testing.expect(t, gate_job.worker == nil && !vault_exists())
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(
		t,
		gate_job.worker != nil && gate_job.creating,
		"only a valid confirmation starts vault creation",
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
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(t, gate_job.worker != nil && !gate_job.creating)
	for gate_job.worker != nil && !gate_poll() {}
	gate_testing.expect(t, vault_verify("x"))

	// Weak-password consent advances to confirmation, never directly to creation.
	vault_delete()
	ui.vault_setup = .Password
	clear(&gate_pw)
	clear(&gate_pw2)
	append(&gate_pw, "x")
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(t, gate_weak_warned && !vault_exists())
	rl.PushKey(.ENTER, true)
	gate_input(&ui)
	gate_input(&ui)
	rl.PushKey(.ENTER, false)
	gate_testing.expect(
		t,
		ui.vault_setup == .Password && gate_job.worker == nil && !vault_exists(),
		"repeated Enter cannot accept a weak password",
	)
	if !click_action(t, &ui, "GateWeakOk") {return}
	gate_testing.expect(t, ui.vault_setup == .Confirm && gate_job.worker == nil && !vault_exists())
	for r in "x" {rl.PushChar(r)}
	gate_input(&ui)
	if !click_action(t, &ui, "GateGo") {return}
	gate_testing.expect(t, gate_job.worker != nil && gate_job.creating)
	for gate_job.worker != nil && !gate_poll() {}
	gate_testing.expect(t, vault_verify("x"))

	click_at :: proc(ui: ^Ui_State, point: nendo.Vector2) {
		nendo.set_pointer(point, .Down)
		rl.PushMouseButton(.LEFT, true)
		gate_layout(ui)
		gate_input(ui)
		nendo.set_pointer(point, .Up)
		rl.PushMouseButton(.LEFT, false)
		gate_layout(ui)
		gate_input(ui)
	}
	centre :: proc(ui: ^Ui_State, id: string) -> nendo.Vector2 {
		onboard_reveal_field(gate_reset == .Review ? "GateResetBody" : "GateCard", id)
		gate_layout(ui)
		box := nendo.element(nendo.id(id)).rect
		return {box.x + box.width / 2, box.y + box.height / 2}
	}
	vault_relock()
	gate_layout(&ui)
	trigger := centre(&ui, "GateForgot")
	click_at(&ui, trigger)
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateHelpReview"))
	gate_testing.expect(t, gate_reset == .Review && vault_exists())
	gate_layout(&ui)
	gate_testing.expect(t, nendo.element(nendo.id("GateResetReview")).found)
	click_at(&ui, trigger)
	gate_testing.expect(t, vault_exists(), "a repeat click at the trigger cannot delete the vault")
	gate_testing.expect(t, gate_reset == .Review)
	click_at(&ui, centre(&ui, "GateResetCancel"))
	gate_testing.expect(t, gate_reset != .Review && vault_exists())

	// Seed every vault-bound path, including work shared by multiple identities.
	gate_testing.expect_value(t, vault_open("x"), Vault_Err.None)
	gate_testing.expect_value(t, vault_set("account:alice", "alice-secret"), Vault_Err.None)
	gate_testing.expect_value(t, vault_set("account:bob", "bob-secret"), Vault_Err.None)
	paths := []string {
		offline_path(),
		media_cache_dir(),
		fmt.tprintf("%s/stickers", data_home),
		fmt.tprintf("%s/gifs", data_home),
	}
	gate_testing.expect_value(t, os.write_entire_file(paths[0], "pending sends"), os.ERROR_NONE)
	for path in paths[1:] {
		gate_testing.expect_value(t, os.make_directory(path), os.ERROR_NONE)
		gate_testing.expect_value(
			t,
			os.write_entire_file(fmt.tprintf("%s/saved.bin", path), "saved content"),
			os.ERROR_NONE,
		)
	}
	vault_relock()
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateForgot"))
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateHelpReview"))
	click_at(&ui, centre(&ui, "GateResetCancel"))
	for path in paths {gate_testing.expect(t, os.exists(path), "cancel preserves local stores")}
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateForgot"))
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateHelpReview"))
	gate_layout(&ui)
	click_at(&ui, centre(&ui, "GateResetDelete"))
	gate_testing.expect(t, !vault_exists() && gate_reset != .Review && gate_reset_done)
	for path in paths {gate_testing.expect(t, !os.exists(path), "confirmed reset removes local stores")}
	gate_testing.expect_value(t, len(gate_pw), 0)
	gate_layout(&ui)
	gate_testing.expect_value(t, ui.vault_setup, Vault_Setup.Welcome)
	gate_testing.expect(t, nendo.element(nendo.id("GateIntroGo")).found)
	gate_testing.expect(t, !nendo.element(nendo.id("GatePwBox")).found)
	gate_testing.expect(t, !nendo.element(nendo.id("GatePw2Box")).found)
}

@(test)
vault_gate_help_navigation :: proc(t: ^gate_testing.T) {
	context.allocator = gate_runtime.default_context().allocator
	gate_sync.lock(&nendo_test_mutex)
	defer gate_sync.unlock(&nendo_test_mutex)
	gate_sync.lock(&test_home_lock)
	defer gate_sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-gate-help", context.temp_allocator)
	if !gate_testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_home := data_home
	data_home = home
	rl.InitWindow(1024, 700, "Vault help navigation")
	defer rl.CloseWindow()
	old_zoom := UI_ZOOM
	UI_ZOOM = 1
	defer {UI_ZOOM = old_zoom}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	nendo.set_measure_text(
		proc(text: string, config: ^nendo.Text_Style, user: rawptr) -> nendo.Dimensions {
			return {f32(len(text)) * f32(config.size) / 2, f32(config.size)}
		},
		nil,
	)
	defer {nendo.set_context(previous); delete(memory)}
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer {
		gate_join()
		vault_delete()
		data_home = old_home
		gate_close()
		gate_reset = .Closed
		gate_err = ""
		rl.PushKey(.ENTER, false)
		rl.PushMouseButton(.LEFT, false)
		forced_press, forced_release = false, false
	}
	rl.PushKey(.ENTER, false)
	nendo.set_pointer({-100, -100}, .Up)
	if !gate_testing.expect_value(t, vault_create("right"), Vault_Err.None) {return}
	if !gate_testing.expect_value(t, vault_set("account:alice", "secret"), Vault_Err.None) {return}
	vault_relock()

	click_action :: proc(t: ^gate_testing.T, ui: ^Ui_State, id: string) -> bool {
		gate_layout(ui)
		onboard_reveal_field("GateCard", id)
		gate_layout(ui)
		data := nendo.element(nendo.id(id))
		if !gate_testing.expect(t, data.found, id) {return false}
		box := data.rect
		point := nendo.Vector2{box.x + box.width / 2, box.y + box.height / 2}
		nendo.set_pointer(point, .Down)
		rl.PushMouseButton(.LEFT, true)
		gate_layout(ui)
		gate_input(ui)
		nendo.set_pointer(point, .Up)
		rl.PushMouseButton(.LEFT, false)
		gate_layout(ui)
		gate_input(ui)
		nendo.set_pointer({-100, -100}, .Up)
		return true
	}
	if !click_action(t, &ui, "GateForgot") {return}
	gate_testing.expect(t, gate_reset != .Review, "reading help must not arm deletion")
	gate_layout(&ui)
	gate_testing.expect(t, !nendo.element(nendo.id("GateResetDelete")).found)
	if !click_action(t, &ui, "GateHelpClose") {return}
	gate_testing.expect(t, gate_reset != .Help && gate_reset != .Review && vault_exists())
	if !click_action(t, &ui, "GateForgot") {return}
	rl.PushKey(.ESCAPE, true)
	gate_input(&ui)
	rl.PushKey(.ESCAPE, false)
	gate_testing.expect(t, gate_reset != .Help && gate_reset != .Review && vault_exists())

	if !click_action(t, &ui, "GateForgot") {return}
	if !click_action(t, &ui, "GateHelpReview") {return}
	gate_testing.expect(t, gate_reset == .Review && vault_exists())
	if !click_action(t, &ui, "GateResetCancel") {return}
	gate_testing.expect(t, gate_reset != .Review && vault_exists())

	// Retry stays available after help and after a canceled deletion review.
	append(&gate_pw, "wrong")
	rl.PushKey(.ENTER, true)
	gate_testing.expect(t, !gate_submit(&ui))
	rl.PushKey(.ENTER, false)
	gate_testing.expect(t, !g_vault.unlocked && vault_exists())
	gate_testing.expect_value(t, len(gate_pw), 0)
	// A damaged file also returns to retry, never to a destructive recovery path.
	sealed, read_err := os.read_entire_file(vault_path(), context.temp_allocator)
	if !gate_testing.expect_value(t, read_err, os.ERROR_NONE) {return}
	gate_testing.expect_value(
		t,
		os.write_entire_file(vault_path(), "invalid vault"),
		os.ERROR_NONE,
	)
	append(&gate_pw, "right")
	rl.PushKey(.ENTER, true)
	gate_testing.expect(t, !gate_submit(&ui))
	rl.PushKey(.ENTER, false)
	gate_testing.expect_value(t, gate_job.err, Vault_Err.Corrupt)
	gate_testing.expect(t, gate_reset != .Help && gate_reset != .Review && !g_vault.unlocked)
	gate_testing.expect(t, vault_exists())
	gate_testing.expect_value(t, len(gate_pw), 0)
	gate_testing.expect_value(t, os.write_entire_file(vault_path(), sealed), os.ERROR_NONE)
	append(&gate_pw, "right")
	rl.PushKey(.ENTER, true)
	gate_testing.expect(t, gate_submit(&ui))
	rl.PushKey(.ENTER, false)
	secret, found := vault_get("account:alice", context.temp_allocator)
	gate_testing.expect(t, found && secret == "secret", "help and cancel preserve the vault")
}
