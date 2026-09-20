package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

handle_pages :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// The revealed nsec lives only while the Keys page is on screen.
	if ui.page != .Settings || ui.settings_section != .Keys {
		keys_forget(ui)
	}

	if client == nil || len(ui.accounts) == 0 || ui.add_account_open {
		return
	}

	if (ui.page == .Profile || ui.page == .Settings) && !ui.new_chat_open {
		edit_text(ui, active_buf(ui))
	}

	// The theme editor and the theme-share picker are raised from
	// Settings, so their capture lives here rather than in handle_chat,
	// which only runs on the Chats page.
	if ui.theme_edit {
		// The keystrokes already went to active_buf above; this is the
		// mouse and the two buttons.
		handle_theme_edit(ui)
		return
	}
	if ui.fwd_open && ui.fwd_kind == .Theme {
		handle_forward(ui, client)
		return
	}

	// Contact QR modal captures everything while open.
	if ui.qr_open {
		if rl.IsKeyPressed(.ESCAPE) || (mouse_released() && !clay.PointerOver(clay.ID("QrModal"))) {
			ui.qr_open = false
		}
		return
	}

	// Contact nickname editor: Enter saves (empty clears), Escape drops
	// focus without saving.
	if ui.page == .Contacts && !ui.new_chat_open {
		if field_mouse(ui, &ui.nick_input, "NickBox") {
			ui.focus = .Nick
		}
		if ui.focus == .Nick {
			edit_text(ui, &ui.nick_input)
			if rl.IsKeyPressed(.ENTER) {
				save_nickname(ui)
			}
			if rl.IsKeyPressed(.ESCAPE) {
				ui.focus = .Compose
			}
		}
	}

	// Archive-page sidebar search: same box as the rail filter, handled
	// here because handle_chat only runs on the Chats page. Runs before
	// the mouse gate so typing lands every frame.
	if ui.page == .Archived {
		if field_mouse(ui, &ui.sidebar_filter, "FilterBox") {
			ui.focus = .Filter
		}
		if ui.focus == .Filter {
			edit_text(ui, &ui.sidebar_filter)
			if rl.IsKeyPressed(.ESCAPE) {
				clear(&ui.sidebar_filter)
				ui.focus = .Compose
			}
		}
	}

	// The emoji picker captures everything while open, on whatever page
	// opened it: settings adds a one-tap reaction through it, and the
	// chat page's handler never runs there.
	if ui.picker_open {
		handle_picker(ui, client)
		return
	}

	if ui.page == .Settings {
		settings_fields(ui) // press-phase focus clicks for text boxes
		if ui.lang_open || ui.shortcuts_open || ui.theme_menu_open || ui.export_open {
			handle_settings(ui, client) // open modals capture Esc every frame
			return
		}
	}

	// Profile presses and keys, before the release gate below:
	// field_mouse fires on the press, handle_profile only ever ran on
	// the release, so form clicks used to vanish here.
	if ui.page == .Profile {
		profile_fields(ui, client)
	}

	// Peer-profile popup captures everything while open. Handled here
	// (not handle_chat) so it also swallows nav clicks on every page.
	if ui.peer_open {
		if rl.IsKeyPressed(.ESCAPE) {
			ui.peer_open = false
			return
		}
		if !mouse_released() {
			return
		}
		if clicked("PeerCopyNpub") && len(ui.peer_npub) > 0 {
			copy_text(ui, ui.peer_npub, "npub copied")
			return
		}
		if clicked("PeerViewProfile") {
			view_peer_profile(ui, client)
			return
		}
		if clicked("PeerClose") || !clay.PointerOver(clay.ID("PeerModal")) {
			ui.peer_open = false
		}
		return
	}

	// Accounts switcher modal captures everything while open.
	if ui.accounts_open {
		if rl.IsKeyPressed(.ESCAPE) {
			ui.accounts_open = false
			return
		}
		if !mouse_released() {
			return
		}
		for id, i in ui.account_ids {
			if clay.PointerOver(clay.ID("AccountRow", u32(i))) {
				ui.accounts_open = false
				if id != ui.account_ref {
					switch_account(ui, client, id)
					// Switching wipes ui.profile; refill it if the page
					// behind the modal is showing it.
					if ui.page == .Profile {
						load_profile(client, ui)
					}
				}
				return
			}
		}
		if clicked("AddAccountBtn") {
			ui.accounts_open = false
			ui.add_account_open = true
			clear(&ui.login_input)
			ui.login_error = ""
			return
		}
		if clicked("AcctClose") || clicked("AcctCloseBtn") || !clay.PointerOver(clay.ID("AccountsModal")) {
			ui.accounts_open = false
		}
		return
	}

	if !mouse_released() {
		return
	}

	// The rail avatar opens the switcher.
	if clicked("RailAvatar") {
		ui.accounts_open = true
		return
	}

	for page in Page {
		if clay.PointerOver(clay.ID("Nav", u32(page))) && ui.page != page {
			ui.page = page
			switch page {
			case .Chats:
			case .Contacts:
				load_contacts(client, ui)
			case .Archived:
				load_archived(client, ui)
			case .Settings:
			case .Profile:
				load_profile(client, ui)
			}
			return
		}
	}

	// Unarchive from the archive page's row hover chip. Lives here, not
	// in handle_chat, which only runs on the Chats page.
	if ui.page == .Archived {
		for _, i in ui.archived {
			if clay.PointerOver(clay.ID("ChatUnarch", u32(i))) {
				set_archived(ui, client, ui.archived[i].group_id, false)
				load_archived(client, ui)
				return
			}
		}
	}

	if ui.page == .Settings {
		handle_settings(ui, client)
	}

	if ui.page == .Profile {
		handle_profile(ui, client)
	}

	if ui.page == .Contacts {
		if clicked("ContactsCsvBtn") {
			export_contacts(ui, .Csv)
			return
		}
		if clicked("ContactsJsonBtn") {
			export_contacts(ui, .Json)
			return
		}
		for contact, i in ui.contacts {
			if clay.PointerOver(clay.ID("ContactRow", u32(i))) {
				reset_profile_view(ui)
				ui.selected_contact = i
				probe_key_package(ui, client, contact.id_hex)
				load_contact_relays(ui, client, contact.id_hex)
				// Seed the nickname editor with the stored value.
				ed_set(ui, &ui.nick_input, ui.nicknames[contact.id_hex])
				ui.focus = .Compose
				return
			}
		}
		if contact, found := shown_contact(ui); found {
			if clicked("StartChatBtn") {
				start_dm(ui, client, contact)
				return
			}
			if clicked("CopyNpubBtn") && len(contact.npub) > 0 {
				copy_text(ui, contact.npub, "npub copied")
				return
			}
			if clicked("QrBtn") && len(contact.npub) > 0 {
				show_contact_qr(ui, contact)
				return
			}
			if clicked("RemoveContactBtn") {
				confirm_ask(ui, .Remove_Contact, contact.id_hex, contact_label(ui, contact))
				return
			}
			if clicked("BlockBtn") {
				// Unblocking restores what block hid, so it goes through
				// without asking; blocking is the destructive direction.
				if ui.blocked[contact.id_hex] {
					delete_key(&ui.blocked, contact.id_hex)
					save_settings(ui)
				} else {
					confirm_ask(ui, .Block, contact.id_hex, contact_label(ui, contact))
				}
				return
			}
		}
	}
}

@(private)
shown_contact :: proc(ui: ^Ui_State) -> (Contact_Ui, bool) {
	if ui.selected_contact >= 0 {
		if ui.selected_contact >= len(ui.contacts) { return {}, false }
		return ui.contacts[ui.selected_contact], true
	}
	return ui.profile_contact, len(ui.profile_contact.id_hex) > 0
}

@(private)
view_peer_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.peer_open = false
	if ui.peer_hex == ui.account_ref && len(ui.account_ref) > 0 {
		ui.page = .Profile
		load_profile(client, ui)
		return
	}
	ui.page = .Contacts
	ui.selected_contact = -1
	for contact, i in ui.contacts {
		if contact.id_hex == ui.peer_hex { ui.selected_contact = i; break }
	}
	reset_profile_view(ui)
	if ui.selected_contact < 0 {
		ui.profile_contact = {id_hex = strings.clone(ui.peer_hex), name = strings.clone(ui.peer_name), pic_url = strings.clone(ui.peer_pic), npub = strings.clone(ui.peer_npub)}
	}
	probe_key_package(ui, client, ui.peer_hex)
	load_contact_relays(ui, client, ui.peer_hex)
	ed_set(ui, &ui.nick_input, ui.nicknames[ui.peer_hex])
	ui.focus = .Compose
}

@(private = "file")
reset_profile_view :: proc(ui: ^Ui_State) {
	for field in ([]^string{&ui.profile_contact.id_hex, &ui.profile_contact.name, &ui.profile_contact.pic_url, &ui.profile_contact.npub}) { delete(field^) }
	ui.profile_contact = {}
}

// Unfollow a contact without changing shared group memberships.
remove_contact :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	follows: ^marmot.String_List
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	user := strings.clone_to_cstring(hex, context.temp_allocator)
	if marmot.unfollow_user(client, account, user, &follows) != .OK {
		ui.client_status = fmt.aprintf("Couldn't remove the contact. %s", marmot.last_error())
		return
	}
	marmot.string_list_free(follows)

	load_contacts(client, ui)
	if ui.selected_contact >= len(ui.contacts) {
		ui.selected_contact = len(ui.contacts) - 1
	}
}


// Persist the nickname editor for the selected contact: empty clears.
save_nickname :: proc(ui: ^Ui_State) {
	contact, found := shown_contact(ui)
	if !found { return }
	id := contact.id_hex
	nick := strings.trim_space(string(ui.nick_input[:]))
	if len(nick) == 0 {
		delete_key(&ui.nicknames, id)
	} else {
		ui.nicknames[strings.clone(id)] = strings.clone(nick)
	}
	wrap_flush = true
	save_settings(ui)
	ui.focus = .Compose
}

// Create (and open) a direct chat with a contact.
start_dm :: proc(ui: ^Ui_State, client: ^marmot.Client, contact: Contact_Ui) {
	// ponytail: no existing-DM dedupe yet; creates a fresh group.
	group_id: cstring
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	members := []cstring{strings.clone_to_cstring(contact.id_hex, context.temp_allocator)}
	if marmot.create_group(client, account, strings.clone_to_cstring(contact.name, context.temp_allocator), raw_data(members), 1, nil, &group_id) != .OK {
		ui.client_status = fmt.aprintf("Couldn't start the chat. %s", marmot.last_error())
		return
	}
	new_group := strings.clone(string(group_id))
	marmot.string_free(group_id)

	ui.page = .Chats
	load_chat_list(client, ui.account_ref, ui)
	for chat, i in ui.chats {
		if chat.group_id == new_group {
			select_chat(ui, client, i)
			break
		}
	}
}

// Publish the whole edit form as kind-0 and leave edit mode.
publish_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if len(ui.name_input) == 0 {
		return
	}
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	// An empty field clears its kind-0 entry.
	opt :: proc(buf: []u8) -> cstring {
		if len(buf) == 0 {
			return nil
		}
		return strings.clone_to_cstring(string(buf), context.temp_allocator)
	}
	name := strings.clone_to_cstring(string(ui.name_input[:]), context.temp_allocator)
	metadata := marmot.User_Profile_Metadata {
		name         = name,
		display_name = name,
		about        = opt(ui.about_input[:]),
		nip05        = opt(ui.nip05_input[:]),
		lud16        = opt(ui.lud16_input[:]),
	}

	// A kind-0 publish replaces the whole record, so carry over the
	// fields the form doesn't edit.
	cur: ^marmot.User_Profile_Metadata
	if marmot.user_profile(client, account, &cur) == .OK && cur != nil {
		if cur.picture != nil {
			metadata.picture = strings.clone_to_cstring(string(cur.picture), context.temp_allocator)
		}
		if cur.banner != nil {
			metadata.banner = strings.clone_to_cstring(string(cur.banner), context.temp_allocator)
		}
		marmot.user_profile_metadata_free(cur)
	}

	out: ^marmot.User_Profile_Metadata
	if marmot.publish_user_profile(client, account, &metadata, raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), &out) != .OK {
		ui.client_status = fmt.aprintf("Couldn't publish the profile. %s", marmot.last_error())
		return
	}
	marmot.user_profile_metadata_free(out)

	ui.profile.name = strings.clone(string(ui.name_input[:]))
	ui.profile.username = ui.profile.name
	ui.profile.about = strings.clone(string(ui.about_input[:]))
	ui.profile.nip05 = strings.clone(string(ui.nip05_input[:]))
	ui.profile.lud16 = strings.clone(string(ui.lud16_input[:]))
	ui.profile.editing = false
}

// Enter the edit form with drafts seeded from the loaded profile.
edit_profile_start :: proc(ui: ^Ui_State) {
	ui.profile.editing = true
	ed_set(ui, &ui.name_input, ui.profile.name)
	ed_set(ui, &ui.about_input, ui.profile.about)
	ed_set(ui, &ui.nip05_input, ui.profile.nip05)
	ed_set(ui, &ui.lud16_input, ui.profile.lud16)
	ui.focus = .Name
}

// Press-phase half of the Profile page: field focus clicks and the
// edit form's keyboard shortcuts. Runs every frame, ahead of the
// release gate that holds handle_profile back.
profile_fields :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if field_mouse(ui, &ui.name_input, "NameBox", 14) {
		ui.focus = .Name
	}
	if field_mouse(ui, &ui.about_input, "AboutBox", 14) {
		ui.focus = .About
	}
	if field_mouse(ui, &ui.nip05_input, "Nip05Box", 14) {
		ui.focus = .Nip05
	}
	if field_mouse(ui, &ui.lud16_input, "Lud16Box", 14) {
		ui.focus = .Lud16
	}
	if field_mouse(ui, &ui.relay_input, "RelayBox", 14) {
		ui.focus = .Relay
	}

	if !ui.profile.editing {
		return
	}
	if rl.IsKeyPressed(.ESCAPE) {
		ui.profile.editing = false
	}
	if rl.IsKeyPressed(.ENTER) {
		publish_profile(ui, client)
	}
}

handle_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	// The Profile rail (panes.odin): switch account, add one, or jump to
	// the settings sections that own the rest of an identity.
	if ui.page == .Profile {
		for id, i in ui.account_ids {
			if clay.PointerOver(clay.ID("PrAcct", u32(i))) {
				if id != ui.account_ref {
					switch_account(ui, client, id)
					load_profile(client, ui)
				}
				return
			}
		}
		if clicked("PrAddAccount") {
			ui.add_account_open = true
			clear(&ui.login_input)
			ui.login_error = ""
			return
		}
		if clicked("PrKeys") || clicked("PrNetwork") {
			keys := clicked("PrKeys")
			ui.page = .Settings
			ui.settings_section = keys ? .Keys : .Network
			load_profile(client, ui)
			if keys {
				fetch_key_packages(ui, client)
			}
			return
		}
	}

	if clicked("EditProfileBtn") {
		if ui.profile.editing {
			ui.profile.editing = false
		} else {
			edit_profile_start(ui)
		}
		return
	}
	if clicked("ProfileCopyNpub") && len(ui.profile.npub) > 0 {
		copy_text(ui, ui.profile.npub, "npub copied")
		return
	}

	// A viewer row is a shortcut into the form, focused on its field.
	if !ui.profile.editing {
		kv_focus := [4]Focus{.Name, .Nip05, .Lud16, .Name}
		for focus, i in kv_focus {
			if clay.PointerOver(clay.ID("ProfileKv", u32(i))) {
				edit_profile_start(ui)
				ui.focus = focus
				return
			}
		}
	}

	if clicked("RevealNsec") {
		nsec: cstring
		if marmot.reveal_nsec(client, account, &nsec) == .OK && nsec != nil {
			ui.profile.nsec = strings.clone(string(nsec))
			marmot.string_free(nsec)
		}
	}

	if ui.profile.editing && (clicked("ChangePicBtn") || clicked("ProfileAvatarPick")) && !ppic_busy {
		ui.picking_ppic = true
		rl.OpenFileDialog(false)
	}

	if clicked("PublishProfileBtn") {
		publish_profile(ui, client)
	}

	if clicked("AddRelayBtn") && len(ui.relay_input) > 0 {
		relays := make([dynamic]cstring, context.temp_allocator)
		for relay in ui.profile.nip65 {
			append(&relays, strings.clone_to_cstring(relay, context.temp_allocator))
		}
		append(&relays, strings.clone_to_cstring(string(ui.relay_input[:]), context.temp_allocator))
		set_relays(ui, client, relays[:])
		clear(&ui.relay_input)
		return
	}
	for relay, i in ui.profile.nip65 {
		if clay.PointerOver(clay.ID("RelayRemove", u32(i))) {
			confirm_ask(ui, .Remove_Relay, relay, relay, i)
			return
		}
	}

	if clicked("SignOutBtn") {
		confirm_ask(ui, .Sign_Out, ui.account_ref, account_label(ui, ui.account_ref))
	}
}

set_relays :: proc(ui: ^Ui_State, client: ^marmot.Client, relays: []cstring) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	lists: ^marmot.Account_Relay_Lists
	if marmot.set_account_nip65_relays(client, account, raw_data(relays), uint(len(relays)), raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), &lists) != .OK {
		ui.client_status = fmt.aprintf("Couldn't update relays. %s", marmot.last_error())
		return
	}
	marmot.account_relay_lists_free(lists)
	reload_profile(ui, client)
}

// Truncate an id-like string for display.
short_hex :: proc(s: string) -> string {
	if len(s) <= 12 {
		return s
	}
	return fmt.tprintf("%s...", s[:12])
}

// The user's timezone, loaded once from the system tz database; nil
// means UTC (no database found, or TZ=UTC).
@(private = "file")
local_tz: ^datetime.TZ_Region
@(private = "file")
local_tz_once: sync.Once

// Epoch seconds (or millis) shifted to local wall-clock seconds, so the
// UTC-shaped field math in the formatters below reads local values.
// DST-correct: the offset comes from the tz record covering the instant.
local_seconds :: proc(at: u64) -> u64 {
	seconds := at > 100_000_000_000 ? at / 1000 : at
	sync.once_do(&local_tz_once, proc() {
		// The shared cache must outlive any caller's temporary or test allocator.
		context.allocator = runtime.default_context().allocator
		local_tz, _ = timezone.region_load("local", reload_allocator())
	})
	if local_tz == nil {
		return seconds
	}
	dt, dok := time.time_to_datetime(time.unix(i64(seconds), 0))
	if !dok {
		return seconds
	}
	local, lok := timezone.datetime_to_tz(dt, local_tz)
	if !lok {
		return seconds
	}
	// Reading the local wall-clock fields back as if they were UTC
	// yields the shifted epoch the formatters below expect.
	local.tz = nil
	shifted, sok := time.datetime_to_time(local)
	if !sok {
		return seconds
	}
	return u64(time.time_to_unix(shifted))
}

// HH:MM local time from a timeline timestamp (seconds or millis).
format_when :: proc(at: u64) -> string {
	seconds := local_seconds(at)
	minutes_of_day := (seconds / 60) % (24 * 60)
	hour := minutes_of_day / 60
	if g_prefs != nil && g_prefs.hour12 {
		suffix := hour < 12 ? "AM" : "PM"
		display := hour % 12
		if display == 0 {
			display = 12
		}
		return fmt.aprintf("%d:%02d %s", display, minutes_of_day % 60, suffix)
	}
	return fmt.aprintf("%02d:%02d", hour, minutes_of_day % 60)
}

MONTH_ABBREV := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// Full stamp for the timestamp hover tooltip: "Aug 25, 2026 · 09:14".
format_full :: proc(at: u64) -> string {
	seconds := local_seconds(at)
	stamp := time.unix(i64(seconds), 0)
	year, month, day := time.date(stamp)
	when_str := format_when(at)
	defer delete(when_str)
	return fmt.aprintf("%s %d, %04d · %s", MONTH_ABBREV[int(month) - 1], day, year, when_str)
}

// Day-marker label: "Today" for the current local date, else per the
// General-settings date format.
format_day :: proc(at: u64) -> string {
	seconds := local_seconds(at)
	stamp := time.unix(i64(seconds), 0)
	year, month, day := time.date(stamp)

	now := u64(time.now()._nsec) / 1_000_000_000
	now_y, now_m, now_d := time.date(time.unix(i64(local_seconds(now)), 0))
	if year == now_y && month == now_m && day == now_d {
		return strings.clone("Today")
	}
	format := g_prefs != nil ? g_prefs.date_format : 2
	switch format {
	case 0:
		return fmt.aprintf("%s %d", MONTH_ABBREV[int(month) - 1], day)
	case 1:
		return fmt.aprintf("%d %s", day, MONTH_ABBREV[int(month) - 1])
	}
	return fmt.aprintf("%04d-%02d-%02d", year, int(month), day)
}

// Register an nsec with marmot. Blocks on the relay round trip, so the
// UI calls it through the sign-in worker (workers.odin); the returned
// hex and error are cloned into `allocator` for the UI thread to adopt.
import_identity_blocking :: proc(client: ^marmot.Client, identity: string, allocator := context.allocator) -> (hex: string, err: string) {
	summary: ^marmot.Account_Summary
	id := strings.clone_to_cstring(identity, context.temp_allocator)
	if marmot.login(client, id, raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), &summary) != .OK {
		return "", fmt.aprintf("Couldn't log in. %s", marmot.last_error(), allocator = allocator)
	}
	defer marmot.account_summary_free(summary)
	return strings.clone(string(summary.account_id_hex), allocator), ""
}

// Mint a fresh identity and seed its starter profile on the wire. Same
// blocking contract as import_identity_blocking; `pic_url` is what the
// local seed registers the face under.
create_identity_blocking :: proc(client: ^marmot.Client, allocator := context.allocator) -> (hex: string, pic_url: string, err: string) {
	summary: ^marmot.Account_Summary
	if marmot.create_identity(client, raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), &summary) != .OK {
		return "", "", fmt.aprintf("Couldn't create an identity. %s", marmot.last_error(), allocator = allocator)
	}
	hex = strings.clone(string(summary.account_id_hex), allocator)
	marmot.account_summary_free(summary)
	return hex, publish_starter_profile(client, hex, allocator), ""
}

// UI-thread tail of a sign-in: register the starter face (fresh
// identities only) and land on the account just added.
finish_auth :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string, pic_url: string, seed: Auth_Seed) {
	if seed == .Starter_Face {
		seed_starter_local(client, hex, pic_url)
	}
	after_login(ui, client, hex)
}

// Synchronous create, for the WN_TEST_CREATE boot hook: the harness
// screenshots a few frames in and can't wait on the worker.
do_create_identity :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	hex, pic_url, err := create_identity_blocking(client, context.temp_allocator)
	if len(err) > 0 {
		ui.login_error = strings.clone(err)
		return
	}
	finish_auth(ui, client, hex, pic_url, .Starter_Face)
}

// Re-snapshot accounts and chats after a successful login/create.
// `active` is the account to land on (the one just added); empty falls
// back to the first row, which is what boot and sign-out want.
after_login :: proc(ui: ^Ui_State, client: ^marmot.Client, active := "") {
	timing_start := time.tick_now()
	defer local_timing_end(.account_load, timing_start)
	clear(&ui.accounts)
	clear(&ui.account_ids)
	clear(&ui.account_npubs)
	clear(&ui.account_pics)
	clear(&ui.login_input)
	ui.login_error = ""

	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) == .OK {
		first: string
		for i in 0 ..< accounts.len {
			hex := string(accounts.items[i].account_id_hex)
			restore_starter_pic(ui, client, hex)
			if i == 0 || hex == active {
				delete(first)
				first = strings.clone(hex)
			}
			append(&ui.account_ids, strings.clone(hex))
			append(&ui.accounts, strings.clone(profile_label(client, hex)))
			append(&ui.account_pics, strings.clone(profile_info(client, hex).pic_url))
			npub: cstring
			row_npub := ""
			if marmot.npub(client, strings.clone_to_cstring(hex, context.temp_allocator), &npub) == .OK && npub != nil {
				row_npub = strings.clone(string(npub))
				marmot.string_free(npub)
			}
			append(&ui.account_npubs, row_npub)
		}
		marmot.account_summary_list_free(accounts)
		if len(first) > 0 {
			ui.account_ref = first
			load_chat_list(client, first, ui)
		}
	}
	ui.add_account_open = false
	ui.profile = {}
}

// Activate another already-stored account and reload everything.
switch_account :: proc(ui: ^Ui_State, client: ^marmot.Client, account_id: string) {
	timing_start := time.tick_now()
	defer local_timing_end(.account_switch, timing_start)
	summary: ^marmot.Account_Summary
	account := strings.clone_to_cstring(account_id, context.temp_allocator)
	if marmot.sign_in_account(client, account, &summary) != .OK {
		ui.client_status = fmt.aprintf("Couldn't switch account. %s", marmot.last_error())
		return
	}
	marmot.account_summary_free(summary)

	ui.account_ref = strings.clone(account_id)
	ui.selected = -1
	ui.show_members = false
	ui.profile = {}
	reset_profile_view(ui)
	clear(&ui.contacts)
	load_chat_list(client, account_id, ui)
}

// The pinned Odin binding omits C's HashMapCapacityExceeded.
@(private)
CLAY_HASH_MAP_CAPACITY :: u32(9)

// Capacity errors request a larger arena; other layout errors are logged.
error_handler :: proc "c" (errorData: clay.ErrorData) {
	context = runtime.default_context()
	if errorData.errorType == .ElementsCapacityExceeded || errorData.errorType == .TextMeasurementCapacityExceeded || u32(errorData.errorType) == CLAY_HASH_MAP_CAPACITY {
		layout_overflow = true
		return
	}
	fmt.eprintfln("clay: %v: %s", errorData.errorType, string(errorData.errorText.chars[:errorData.errorText.length]))
}

// Keep font metadata beside visible text, so selection copies no markup.
extract_inlines :: proc(builder: ^strings.Builder, inlines: [^]marmot.Markdown_Inline, count: uint, fonts: ^strings.Builder = nil, font: u8 = FONT_BODY) {
	for i in 0 ..< count {
		node := &inlines[i]
		start := strings.builder_len(builder^)
		switch node.tag {
		case .TEXT:
			strings.write_string(builder, string(node.body.text.content))
		case .CODE:
			strings.write_string(builder, string(node.body.code.content))
		case .SOFT_BREAK, .HARD_BREAK:
			strings.write_rune(builder, ' ')
		case .EMPH:
			extract_inlines(builder, node.body.emph.children, node.body.emph.children_len, fonts, font == FONT_TITLE || font == FONT_BOLD_ITALIC ? FONT_BOLD_ITALIC : FONT_ITALIC)
			continue
		case .STRONG:
			extract_inlines(builder, node.body.strong.children, node.body.strong.children_len, fonts, font == FONT_ITALIC || font == FONT_BOLD_ITALIC ? FONT_BOLD_ITALIC : FONT_TITLE)
			continue
		case .STRIKETHROUGH:
			extract_inlines(builder, node.body.strikethrough.children, node.body.strikethrough.children_len, fonts, font)
			continue
		case .LINK:
			extract_inlines(builder, node.body.link.children, node.body.link.children_len, fonts, font)
			continue
		case .AUTOLINK:
			strings.write_string(builder, string(node.body.autolink.url))
		case .MATH:
			strings.write_string(builder, string(node.body.math.content))
		case .IMAGE:
			// The url itself: a link in a body, an inline image when an
			// event card splits its paragraphs (nevent.odin).
			strings.write_string(builder, string(node.body.image.dest))
		case .NOSTR_MENTION, .NOSTR_URI:
			strings.write_string(builder, string(node.body.nostr_mention.entity.bech32))
		}
		if fonts != nil {
			for _ in start ..< strings.builder_len(builder^) { strings.write_byte(fonts, font) }
		}
	}
}

inline_text :: proc(inlines: [^]marmot.Markdown_Inline, count: uint, fonts: ^string = nil, font: u8 = FONT_BODY) -> string {
	builder := strings.builder_make(context.temp_allocator)
	styles := strings.builder_make(context.temp_allocator)
	extract_inlines(&builder, inlines, count, fonts != nil ? &styles : nil, font)
	if fonts != nil && len(strings.trim(strings.to_string(styles), "\x00")) > 0 {
		fonts^ = strings.clone(strings.to_string(styles))
	}
	return strings.clone(strings.to_string(builder))
}

// Flatten the FFI block tree into owned Md_Block_Ui rows.
convert_blocks :: proc(out: ^[dynamic]Md_Block_Ui, blocks: [^]marmot.Markdown_Block, count: uint, quoted: bool, gaps: []u8 = nil) {
	for i in 0 ..< count {
		first := len(out^)
		defer {
			if first < len(out^) && i < uint(len(gaps)) {
				out^[first].blank_lines_before = u8(min(u16(out^[first].blank_lines_before) + u16(gaps[i]), u16(MD_BLANK_MAX)))
			}
		}
		block := &blocks[i]
		switch block.tag {
		case .PARAGRAPH:
			kind := quoted ? Md_Kind.Quote : Md_Kind.Para
			row := Md_Block_Ui{kind = kind}
			row.text = inline_text(block.body.paragraph.inlines, block.body.paragraph.inlines_len, &row.fonts)
			append(out, row)
		case .HEADING:
			row := Md_Block_Ui{kind = .Heading, level = int(block.body.heading.level)}
			row.text = inline_text(block.body.heading.inlines, block.body.heading.inlines_len, &row.fonts, FONT_TITLE)
			append(out, row)
		case .CODE_BLOCK:
			append(out, Md_Block_Ui{kind = .Code, text = strings.clone(strings.trim_right(string(block.body.code_block.content), "\n"))})
		case .BLOCK_QUOTE:
			quote := &block.body.block_quote
			convert_blocks(out, quote.blocks, quote.blocks_len, true, ([^]u8)(quote.blank_lines_before)[:quote.blank_lines_before_len])
		case .LIST_BLOCK:
			list := &block.body.list_block
			for j in 0 ..< list.items_len {
				item := &list.items[j]
				prefix: string
				if item.has_checked {
					prefix = item.checked ? "[x] " : "[ ] "
				} else if list.kind.tag == 1 {
					prefix = fmt.tprintf("%d%s ", list.kind.body.ordered.start + u32(j), string(list.kind.body.ordered.delimiter))
				} else {
					prefix = "• "
				}

				// One row from the item's first paragraph; nested
				// blocks flatten after it.
				body_text: string
				fonts: string
				if item.blocks_len > 0 && item.blocks[0].tag == .PARAGRAPH {
					body_text = inline_text(item.blocks[0].body.paragraph.inlines, item.blocks[0].body.paragraph.inlines_len, &fonts)
				}
				if len(fonts) > 0 {
					body_fonts := fonts
					fonts = strings.concatenate({strings.repeat("\x00", len(prefix), context.temp_allocator), body_fonts})
					delete(body_fonts)
				}
				gap := j > 0 && !list.tight ? u8(1) : 0
				if item.blank_lines_before_len > 0 { gap = max(gap, item.blank_lines_before^) }
				append(out, Md_Block_Ui{kind = .List_Item, text = strings.clone(fmt.tprintf("%s%s", prefix, body_text)), fonts = fonts, marker_len = len(prefix), blank_lines_before = gap})
				delete(body_text)
				if item.blocks_len > 1 {
					gaps := ([^]u8)(item.blank_lines_before)[:item.blank_lines_before_len]
					convert_blocks(out, item.blocks[1:], item.blocks_len - 1, quoted, gaps[min(1, len(gaps)):])
				}
			}
		case .THEMATIC_BREAK:
			append(out, Md_Block_Ui{kind = .Rule})
		case .TABLE:
			t := &block.body.table
			cells := make([][]string, int(t.rows_len) + 1)
			fonts := make([][]string, len(cells))
			hdr := make([]string, int(t.header_len))
			fonts[0] = make([]string, len(hdr))
			for j in 0 ..< t.header_len {
				hdr[j] = inline_text(t.header[j].inlines, t.header[j].inlines_len, &fonts[0][j], FONT_TITLE)
			}
			cells[0] = hdr
			for r in 0 ..< t.rows_len {
				row := make([]string, int(t.rows[r].cells_len))
				fonts[r + 1] = make([]string, len(row))
				for j in 0 ..< t.rows[r].cells_len {
					row[j] = inline_text(t.rows[r].cells[j].inlines, t.rows[r].cells[j].inlines_len, &fonts[r + 1][j])
				}
				cells[int(r) + 1] = row
			}
			append(out, Md_Block_Ui{kind = .Table, cells = cells, cell_fonts = fonts})
		case .MATH_BLOCK:
			append(out, Md_Block_Ui{kind = .Code, text = strings.clone(string(block.body.math_block.content))})
		}
	}
}

boot_marmot :: proc(home: string, ui: ^Ui_State) -> ^marmot.Client {
	timing_start := time.tick_now()
	defer local_timing_end(.runtime_boot, timing_start)
	os.make_directory(home)
	relays := DEFAULT_RELAYS

	// The account signing keys land in the vault (vault_gate.odin), not
	// the platform keychain: the store is copied here and its callbacks
	// run for the client's whole life.
	store := vault_secret_store()

	client: ^marmot.Client
	if marmot.client_new_with_secret_store(strings.clone_to_cstring(home), raw_data(relays), len(relays), &store, &client) != .OK {
		ui.client_status = fmt.aprintf("runtime failed: %s", marmot.last_error())
		return nil
	}

	// Configure the destination before startup restores the saved consent.
	local_timing_bind(client)
	apply_observability(ui, client)

	if marmot.client_start(client) != .OK {
		ui.client_status = fmt.aprintf("started offline: %s", marmot.last_error())
	} else {
		ui.client_status = "runtime running"
	}

	// Same snapshot as every later account change; a second hand-rolled
	// loop here once missed the npub/pic arrays and crashed the switcher.
	after_login(ui, client)

	return client
}

// Whether this plaintext is a webxdc state update, which feeds the
// running app and never renders (timeline or preview).
@(private = "file")
is_xdc_blob :: proc(text: string) -> bool {
	return strings.has_prefix(strings.trim_space(text), XDC_SENTINEL)
}

// The rail preview for a chat whose newest record can't speak for
// itself: a kind-1210 system payload (raw JSON) or a webxdc state
// blob. Re-reads the newest window (a local query) and phrases the
// newest displayable record the way the timeline does, skipping what
// the timeline skips. Temp-allocated; "" when nothing qualifies.
@(private = "file")
window_preview :: proc(client: ^marmot.Client, account_ref: string, row: ^marmot.Chat_List_Row) -> string {
	if client == nil {
		return ""
	}
	query := marmot.Timeline_Message_Query {
		group_id_hex = row.group_id_hex,
		has_limit    = true,
		limit        = 16,
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {
		return ""
	}
	defer marmot.timeline_page_free(page)

	for i := int(page.messages_len) - 1; i >= 0; i -= 1 {
		record := &page.messages[i]
		if record.kind == 1009 || record.kind == 5 || record.kind == KIND_POLL_VOTE {
			continue
		}
		if record.kind == 1210 {
			if record.group_system != nil {
				// system_text can hand back ev.text, which borrows the
				// page freed on return; copy before it goes.
				return strings.clone(system_text(client, record.group_system), context.temp_allocator)
			}
			continue
		}
		text := record.plaintext != nil ? string(record.plaintext) : ""
		if len(text) == 0 || is_xdc_blob(text) {
			continue
		}
		if record.direction != nil && string(record.direction) == "sent" {
			return fmt.tprintf("You: %s", text)
		}
		return strings.clone(text, context.temp_allocator) // text borrows the page
	}
	return ""
}

@(private)
CHAT_ATTACHMENT_AUDIO :: i32(2) // MarmotChatListAttachmentKind::Audio

// Snapshot the account's chat list into UI-owned strings.
// One marmot chat-list row into a UI row; shared by the rail
// (load_chat_list) and the archive page (load_archived) so both render
// identically (avatar, time, "You:" prefix, delivery tick).
row_to_ui :: proc(client: ^marmot.Client, presented: ^marmot.Presented_Chat_Row, account_ref: string) -> Chat_Row_Ui {
	row := &presented.row
	presentation := &presented.presentation
	title: string
	switch presentation.title.tag {
	case .Literal: title = string(presentation.title.body.literal)
	case .Unnamed_Group: title = tr("Unnamed group")
	case .Unavailable_Conversation: title = tr("Unavailable conversation")
	}
	avatar_url, image_hash: string
	switch presentation.avatar.tag {
	case .Remote_Image: avatar_url = string(presentation.avatar.body.remote.url)
	case .Encrypted_Group_Image: image_hash = string(presentation.avatar.body.encrypted.image.image_hash_hex)
	case .Placeholder:
	}

	preview: string
	mine: bool
	if row.last_message != nil {
		mine = row.last_message.sender != nil && string(row.last_message.sender) == account_ref
		if row.last_message.plaintext != nil {
			preview = string(row.last_message.plaintext)
		}
		if strings.trim_space(preview) == "" && !row.last_message.deleted &&
			row.last_message.has_attachment_kind && row.last_message.attachment_kind == CHAT_ATTACHMENT_AUDIO {
			preview = tr("Audio message")
		}
		if mine && strings.trim_space(preview) != "" {
			preview = fmt.tprintf(tr("You: %s"), preview)
		}
		// A kind-1210 payload or a webxdc state blob can't speak for
		// itself; show the newest displayable record instead (already
		// phrased, so no "You:" prefix on top).
		xdc := is_xdc_blob(row.last_message.plaintext != nil ? string(row.last_message.plaintext) : "")
		if row.last_message.kind == 1210 || xdc {
			phrased := window_preview(client, account_ref, row)
			if len(phrased) > 0 {
				preview = phrased
			} else if xdc {
				preview = "" // never the raw blob
			}
		}
	}

	tick := marmot.Delivery_State.NOT_APPLICABLE
	if row.last_message != nil {
		tick = row.last_message.delivery_state
	}

	return Chat_Row_Ui{
		group_id = strings.clone(string(row.group_id_hex)),
		title    = strings.clone(title),
		preview  = strings.clone(chat_preview(preview)),
		at       = format_when(row.activity_sort_at),
		unread   = row.unread_count,
		pending  = row.pending_confirmation,
		stable   = row.lifecycle_state == .STABLE,
		tick     = tick,
		first_unread = strings.clone(row.first_unread_message_id_hex != nil ? string(row.first_unread_message_id_hex) : ""),
		avatar_url = strings.clone(avatar_url),
		avatar_key = strings.clone(row.conversation_kind == .DIRECT && presentation.peer_id != nil ? string(presentation.peer_id) : string(row.group_id_hex)),
		image_hash = strings.clone(image_hash),
		// marmot's mute OR the local one from the row menu (its C API
		// has no mute setter); the notification gate reads this flag.
		muted    = row.muted || (g_prefs != nil && g_prefs.muted_ids[string(row.group_id_hex)]),
		last_id  = strings.clone(row.last_message != nil && row.last_message.message_id_hex != nil ? string(row.last_message.message_id_hex) : ""),
		last_kind = row.last_message != nil ? row.last_message.kind : 0,
		last_mine = mine,
	}
}

load_chat_list :: proc(client: ^marmot.Client, account_ref: string, ui: ^Ui_State) {
	timing_start := time.tick_now()
	defer local_timing_end(.chat_list_load, timing_start)
	rows: ^marmot.Presented_Chat_List
	if marmot.presented_chat_list(client, strings.clone_to_cstring(account_ref, context.temp_allocator), false, &rows) != .OK {
		ui.client_status = fmt.aprintf("chat list failed: %s", marmot.last_error())
		return
	}
	defer marmot.presented_chat_list_free(rows)

	fresh := make([dynamic]Chat_Row_Ui, 0, int(rows.rows_len))
	for i in 0 ..< rows.rows_len {
		append(&fresh, row_to_ui(client, &rows.rows[i], account_ref))
	}
	chats_replace(&ui.chats, fresh)
	ui.my_pic_url = profile_info(client, account_ref).pic_url
	queue_group_pics(ui, client)

	// Keep the rail-filter flags aligned with the fresh row set.
	refresh_filter_hits(client, ui)
}
