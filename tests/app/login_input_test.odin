package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:time"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// SDL and nendo have process globals; run this in its own test invocation.
@(test)
login_input_required :: proc(t: ^testing.T) {
	if !test_isolated("login_input_required") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Import key validation")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		selected    = -1,
		row_menu    = -1,
		member_menu = -1,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		forced_release = false
		rl.PushKey(.ENTER, false)
		delete(ui.login_error)
		delete(ui.login_input)
	}
	// Rejected input must never dereference the opaque runtime handle.
	client: marmot.Client
	frame :: proc(ui: ^Ui_State) -> []nendo.Render_Command {
		nendo.set_pointer({-100, -100}, .Up)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, name: string) {
		data := nendo.element(nendo.id(name))
		if !testing.expect(t, data.found, "button exists") {return}
		b := data.rect
		nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
		if !testing.expect(t, nendo.pointer_over(nendo.id(name)), "button is reachable") {return}
		forced_release = true
		handle_login(ui, client)
		forced_release = false
	}
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, &client, "LoginImportBtn")
	testing.expect_value(t, ui.login_method, Login_Method.Import)
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, &client, "LoginGo")
	testing.expect_value(t, ui.login_error, "Enter your nsec to continue.")
	testing.expect(t, auth_job == nil)
	commands := frame(&ui)
	visible := false
	for command in commands {
		if command.kind != .Text {continue}
		text := command.text.text
		if text == "Enter your nsec to continue." {visible = true}
	}
	testing.expect(t, visible, "required-key feedback is rendered on the next frame")
	// Keyboard submission takes the same path, including repeated attempts.
	delete(ui.login_error); ui.login_error = ""
	rl.PushKey(.ENTER, true)
	handle_login(&ui, &client)
	rl.PushKey(.ENTER, false)
	testing.expect_value(t, ui.login_error, "Enter your nsec to continue.")
	testing.expect(t, auth_job == nil)
	// Accounts uses the same form while another identity is already selected.
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})
	defer delete(ui.accounts)
	ui.add_account_open = true
	for language in ([]string{"en", "it", "de", "ja", "ko"}) {
		set_locale(language)
		rl.PushKey(.ENTER, true)
		handle_login(&ui, &client)
		rl.PushKey(.ENTER, false)
		testing.expect_value(t, ui.login_error, tr("Enter your nsec to continue."))
		testing.expect(t, auth_job == nil)
	}
	set_locale("en")
	// A nonempty malformed key retains the existing correction, without auth.
	delete(ui.login_error); ui.login_error = ""
	append(&ui.login_input, "not-an-nsec")
	frame(&ui)
	click(t, &ui, &client, "LoginGo")
	testing.expect_value(
		t,
		ui.login_error,
		"That key isn't an nsec. Double-check it and try again.",
	)
	testing.expect(t, auth_job == nil)
	// Both sign-in surfaces submit through the real Bunker button and Enter.
	for adding in ([]bool{false, true}) {
		ui.add_account_open = adding
		ui.account_ref = adding ? "offline-fixture" : ""
		if !adding {clear(&ui.accounts)} else {append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})}
		ui.login_method = .Menu
		for _ in 0 ..< 3 {frame(&ui)}
		click(t, &ui, &client, "LoginBunkerBtn")
		testing.expect_value(t, ui.login_method, Login_Method.Bunker)
		for language in ([]string{"en", "it", "de", "ja", "ko"}) {
			set_locale(language)
			for input in ([]string{"", " 	\r\n", "\u00a0\u2003"}) {
				clear(&ui.login_input)
				append(&ui.login_input, ..transmute([]u8)input)
				for keyboard in ([]bool{false, true}) {
					delete(ui.login_error); ui.login_error = ""
					for _ in 0 ..< 3 {frame(&ui)}
					if keyboard {
						rl.PushKey(.ENTER, true)
						handle_login(&ui, &client)
						rl.PushKey(.ENTER, false)
					} else {click(t, &ui, &client, "LoginGo")}
					if !testing.expect_value(
						t,
						ui.login_error,
						tr("Enter your bunker link to continue."),
					) {return}
					testing.expect(t, auth_job == nil)
					testing.expect_value(t, string(ui.login_input[:]), input)
					commands := frame(&ui)
					visible := false
					for command in commands {
						if command.kind != .Text {continue}
						text := command.text.text
						if text == tr("Enter your bunker link to continue.") {visible = true}
					}
					testing.expect(
						t,
						visible,
						"required-link feedback is rendered on the next frame",
					)
				}
			}
		}
	}
	set_locale("en")
	// Pair retains its existing empty-input behavior, without Bunker feedback.
	clear(&ui.login_input)
	delete(ui.login_error); ui.login_error = ""
	ui.login_method = .Pair
	rl.PushKey(.ENTER, true)
	handle_login(&ui, &client)
	rl.PushKey(.ENTER, false)
	testing.expect_value(t, ui.login_error, "")
	testing.expect(t, auth_job == nil)

	home, err := os.make_directory_temp("", "wn-starter-review", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	previous_home := data_home
	data_home = home
	defer {vault_lock(); data_home = previous_home}
	if !testing.expect_value(t, vault_create("disposable-test-password"), Vault_Err.None) {return}
	deployment: ^marmot.Deployment
	if !testing.expect_value(t, restore_test_deployment(&deployment), marmot.Status.OK) {return}
	defer marmot.deployment_free(deployment)
	local_relays := []cstring{"wss://127.0.0.1:9"}
	previous_relays := DEFAULT_RELAYS
	DEFAULT_RELAYS = local_relays
	defer DEFAULT_RELAYS = previous_relays
	runtime_client: ^marmot.Client
	store := vault_secret_store()
	status := marmot.client_new_with_configuration(
		strings.clone_to_cstring(home, context.temp_allocator),
		raw_data(local_relays),
		uint(len(local_relays)),
		&marmot.Client_Options{store = &store, relay_policy = 1},
		deployment,
		&runtime_client,
	)
	if !testing.expect_value(t, status, marmot.Status.OK) {return}
	defer marmot.client_free(runtime_client)
	defer auth_stop()

	ui.account_ref, ui.add_account_open, ui.login_method = "", false, .Menu
	clear(&ui.accounts)
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, runtime_client, "LoginCreate")
	started := time.tick_now()
	for auth_job != nil &&
	    auth_job.starter_phase == .Prepare &&
	    time.tick_since(started) < 5 * time.Second {
		time.sleep(time.Millisecond)
		drain_auth(&ui, runtime_client)
	}
	if !testing.expect(
		t,
		auth_job != nil && auth_job.starter_phase == .Review,
		ui.login_error,
	) {return}
	for size in ([2][2]i32{{1024, 700}, {390, 740}}) {
		rl.SetWindowSize(size[0], size[1])
		nendo.set_dimensions({f32(size[0]), f32(size[1])})
		for _ in 0 ..< 2 {frame(&ui)}
		picture := nendo.element(nendo.id("LoginStarterPicture"))
		publish := nendo.element(nendo.id("LoginCreatePublish"))
		testing.expect(t, picture.found && publish.found && picture.rect.y < publish.rect.y)
	}
	publish := nendo.element(nendo.id("LoginCreatePublish")).rect
	x, y := publish.x + publish.width / 2, publish.y + publish.height / 2
	rl.InjectFinger(.Down, x, y)
	rl.InjectFinger(.Up, x, y)
	_ = rl.WindowShouldClose()
	nendo.set_pointer({x, y}, .Up)
	handle_login(&ui, runtime_client)
	_ = rl.WindowShouldClose()
	if !testing.expect(
		t,
		auth_job != nil && auth_job.starter_phase == .Review,
		"queued input cannot authorize a newly drawn button",
	) {return}

	if !testing.expect(t, len(ui.login_input) > 0, "review shows a generated name") {return}
	input := nendo.element(nendo.id("LoginInput")).rect
	nendo.set_pointer({input.x + input.width / 2, input.y + input.height / 2}, .Down)
	rl.UseMouse()
	before := len(ui.login_input)
	rl.PushChar('x')
	forced_press = true
	handle_login(&ui, runtime_client)
	forced_press = false
	text_drag = nil
	testing.expect_value(t, len(ui.login_input), before + 1)
	rl.PushKey(.ENTER, true)
	handle_login(&ui, runtime_client)
	rl.PushKey(.ENTER, false)
	if !testing.expect(
		t,
		auth_job != nil && auth_job.starter_phase == .Review,
		"Enter in the name field must not publish",
	) {return}
	picture := nendo.element(nendo.id("LoginStarterPicture")).rect
	rl.InjectFinger(.Down, picture.x + picture.width / 2, picture.y + picture.height / 2)
	rl.InjectFinger(.Up, x, y)
	_ = rl.WindowShouldClose()
	nendo.set_pointer({x, y}, .Up)
	if !testing.expect(
		t,
		mouse_released() && nendo.pointer_over(nendo.id("LoginCreatePublish")),
		"the batched release reached the consent button",
	) {return}
	handle_login(&ui, runtime_client)
	_ = rl.WindowShouldClose()
	rl.UseMouse()
	if !testing.expect(
		t,
		auth_job != nil && auth_job.starter_phase == .Review,
		"a coalesced press outside the button must not authorize publication",
	) {return}

	rl.SetWindowSize(320, 220)
	nendo.set_dimensions({320, 220})
	for _ in 0 ..< 3 {frame(&ui)}
	card := nendo.element(nendo.id("LoginCard")).rect
	field := nendo.element(nendo.id("LoginInput")).rect
	testing.expect(
		t,
		field.y >= card.y && field.y + field.height <= card.y + card.height,
		"focused name stays visible above the keyboard",
	)
	rl.PushKey(.TAB, true)
	handle_login(&ui, runtime_client)
	rl.PushKey(.TAB, false)
	rl.PushKey(.ENTER, true)
	handle_login(&ui, runtime_client)
	rl.PushKey(.ENTER, false)
	testing.expect(t, auth_job == nil && ui.account_ref == "")
	frame(&ui)
	testing.expect(t, nendo.element(nendo.id("LoginImportBtn")).found)
	accounts: ^marmot.Account_Summary_List
	if testing.expect_value(
		   t,
		   marmot.list_accounts(runtime_client, &accounts),
		   marmot.Status.OK,
	   ) &&
	   accounts != nil {
		defer marmot.account_summary_list_free(accounts)
		testing.expect_value(t, accounts.len, uint(0))
	}
}
