package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
vault_lock_scrubs_state :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	ui: Ui_State
	ui.lock_requested = true
	ui.profile = {
		name  = strings.clone("Private profile"),
		about = strings.clone("Private notes"),
		nsec  = strings.clone("signing-key"),
	}
	append(&ui.profile.inbox, strings.clone("wss://private.example"))
	groups := make([dynamic]Common_Group)
	append(
		&groups,
		Common_Group{id = strings.clone("group"), title = strings.clone("Private group")},
	)
	append(
		&ui.contacts,
		Contact_Ui {
			id_hex = strings.clone("contact"),
			name = strings.clone("Private contact"),
			groups = groups,
		},
	)
	append(&ui.login_input, "private-login-secret")
	append(&ui.compose, "private draft")
	ui.drafts[strings.clone("group")] = strings.clone("private draft")
	ui.client_status = "Borrowed status label"
	append(&ui.prefs.recent_emoji, strings.clone("🐙"))
	preference_storage := raw_data(ui.prefs.recent_emoji)
	lock_scrub_ui(&ui)
	testing.expect_value(t, ui.profile.nsec, "")
	testing.expect_value(t, ui.profile.about, "")
	testing.expect(t, raw_data(ui.profile.inbox) == nil)
	testing.expect(t, raw_data(ui.contacts) == nil)
	testing.expect(t, raw_data(ui.login_input) == nil)
	testing.expect(t, raw_data(ui.compose) == nil)
	testing.expect_value(t, len(ui.drafts), 0)
	testing.expect_value(t, ui.client_status, "Borrowed status label")
	testing.expect(t, raw_data(ui.prefs.recent_emoji) == preference_storage)
	for emoji in ui.prefs.recent_emoji {delete(emoji)}
	delete(ui.prefs.recent_emoji)
}

@(test)
vault_lock_settings_isolation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-locked-settings", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	os.make_directory(fmt.tprintf("%s/whitenoise", home))
	if !testing.expect(
		t,
		os.write_entire_file(
			settings_path(),
			transmute([]u8)string(
				`{"nicknames":{"person":"Private nickname"},"drafts":{"group":"Private draft"},"blocked":["person"],"prefs":{"zoom_pct":110,"recent_emoji":["🐙"]}}`,
			),
		) ==
		nil,
	) {return}
	ui: Ui_State
	load_settings(&ui, .Preferences)
	testing.expect_value(t, len(ui.drafts), 0)
	testing.expect_value(t, len(ui.nicknames), 0)
	testing.expect_value(t, len(ui.blocked), 0)
	emoji_storage := raw_data(ui.prefs.recent_emoji)
	load_session_settings(&ui)
	testing.expect_value(t, ui.drafts["group"], "Private draft")
	testing.expect_value(t, ui.nicknames["person"], "Private nickname")
	testing.expect(t, ui.blocked["person"])
	testing.expect(
		t,
		raw_data(ui.prefs.recent_emoji) == emoji_storage,
		"unlock must not replace preference ownership",
	)
}

@(test)
vault_lock_discards_auth :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	// The worker can finish just before lock, leaving its nsec-owning job
	// waiting for frame-boundary adoption. Relock must discard that job.
	if !testing.expect(t, auth_job == nil) {return}
	auth_job = new(Auth_Job)
	auth_job.nsec = strings.clone("completed-sign-in-secret")
	auth_job.hex = strings.clone("completed-account")
	auth_stop()
	testing.expect(t, auth_job == nil, "a locked session cannot adopt an old sign-in result")
}
