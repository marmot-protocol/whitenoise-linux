package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

handle_pages :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// Wipe private keys off their page without disarming other settings actions.
	if ui.page != .Settings ||
	   ((ui.settings_section != .Account || settings_index(ui)) &&
			   (ui.keys_nsec != "" ||
					   ui.keys_nsec_show ||
					   ui.keys_npub_show ||
					   keys_reveal_frames > 0)) {
		keys_forget(ui)
	}
	if ui.settings_profile_return && (ui.page != .Profile || !ui.profile.editing) {
		ui.settings_profile_return = false
	}
	if ui.sticker_open {handle_sticker_panel(ui); return}

	if client == nil || ui.account_ref == "" || ui.add_account_open {
		return
	}
	if ui.page == .Settings && mention_hover != "" && mouse_released() {
		handle_mention_click(ui, client)
		return
	}

	if ui.page == .Profile &&
	   ui.profile.editing &&
	   !ui.new_chat_open &&
	   !profile_text_pending(ui) {
		#partial switch ui.focus {
		case .Name, .About, .Nip05, .Lud16:
			edit_text(ui, active_buf(ui), ui.focus == .About)
		}
	}

	// The theme editor and the theme-share picker are raised from
	// Settings, so their capture lives here rather than in handle_chat,
	// which only runs on the Chats page.
	if ui.theme_edit {
		if ui.page == .Settings && !ui.new_chat_open {edit_text(ui, active_buf(ui))}
		handle_theme_edit(ui)
		return
	}
	if ui.fwd_open && ui.fwd_kind == .Theme {
		handle_forward(ui, client)
		return
	}

	// Contact QR modal captures everything while open.
	if ui.qr_open {
		if clicked("QrClose") ||
		   rl.IsKeyPressed(.ESCAPE) ||
		   (mouse_released() && !nendo.pointer_over(nendo.id("QrModal"))) {
			ui.qr_open = false
		}
		return
	}

	// Save before a touch leaves the editor, including Back and navigation.
	if ui.page == .Contacts && !ui.new_chat_open {
		if ui.focus == .Nick &&
		   mouse_released() &&
		   !nendo.pointer_over(nendo.id("NickBox")) {save_nickname(ui)}
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

	// Contacts search stays in the rail; Archive owns its search in the
	// main page. Handle both before the mouse gate so typing lands every frame.
	if (ui.page == .Contacts || ui.page == .Archived) && !ui.new_chat_open {
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

	if ui.page == .Settings {
		if ui.lang_open || ui.shortcuts_open || ui.export_open {
			handle_settings(ui, client) // open modals capture Esc every frame
			return
		}
		settings_fields(ui)
		if ui.settings_section == .Chats &&
		   (ui.board_drag.kind != .None ||
				   nendo.pointer_over(nendo.id("FolderBoard")) ||
				   clicked("SettingsFolderNew")) &&
		   handle_folder_board(ui) {return}
		if !settings_escape(ui) {handle_settings(ui, client)}
		return
	}

	// Profile presses and keys, before the release gate below:
	// field_mouse fires on the press, handle_profile only ever ran on
	// the release, so form clicks used to vanish here.
	if ui.page == .Profile {
		profile_fields(ui, client)
		if ui.page != .Profile {return}
	}

	if !mouse_released() {
		return
	}

	// The rail avatar opens the switcher.
	if clicked("FilterClear") {
		clear(&ui.sidebar_filter)
		refresh_filter_hits(client, ui)
		ui.focus = .Filter
		return
	}
	if clicked("RailAvatar") {
		ui.accounts_open = true
		return
	}

	if ui.page == .Chats {
		ids := #sparse[Chat_Filter]string {
			.Chats  = "AllPill",
			.Unread = "UnreadPill",
			.Groups = "GroupsPill",
		}
		for scope in Chat_Filter {
			if !clicked(ids[scope]) && !(scope == .Chats && clicked("ChatListShowAll")) {continue}
			ui.chat_filter = scope
			ui.chat_folder = ""
			ui.page = .Chats
			clear(&ui.rail_rows)
			if data := nendo.scroll(nendo.id("ChatList")); data.found {
				data.position.y = 0
			}
			return
		}
		if ui.prefs.recent_chats {
			for name, i in ui.prefs.folders {
				if !nendo.pointer_over(nendo.id("FolderPill", u32(i))) {continue}
				ui.chat_filter, ui.chat_folder = .Chats, name
				clear(&ui.rail_rows)
				if data := nendo.scroll(nendo.id("ChatList")); data.found {
					data.position.y = 0
				}
				return
			}
		}
	}

	for page in Page {
		if nendo.pointer_over(nendo.id("Nav", u32(page))) {
			if page == .Settings && ui.page != .Settings {
				settings_enter(ui, client)
				ui.settings_scroll_pending = false // restore the workspace's saved scroll
				return
			}
			if ui.page == page {
				if single_pane() {
					if page == .Chats {
						if !phone_detail(ui) {
							for name in tab_scroll_ids(.Chats) {
								if name == "" {continue}
								if data := nendo.scroll(nendo.id(name));
								   data.found {data.position^ = {}}
							}
							scroll_residual = {}
							fling_vel = {}
						} else {
							if ui.new_chat_open {close_new_chat(ui)}
							phone_back_action(ui)
						}
					} else if page == .Contacts {
						reset_profile_view(ui)
						ui.selected_contact = -1
					}
				} else if page == .Chats && rail_narrow(ui) {
					toggle_rail(ui)
				}
				return
			}
			settings_theme_preview_reset(ui)
			if ui.page == .Settings && ui.settings_section == .Account {keys_forget(ui)}
			clear(&ui.sidebar_filter)
			clear(&ui.filter_hits)
			ui.focus = .Compose
			ui.settings_profile_return = false
			ui.page = page
			#partial switch page {
			case .Contacts:
				load_contacts(client, ui, .Details)
			case .Archived:
				load_archived(client, ui)
			case .Profile:
				load_profile(client, ui)
			}
			return
		}
	}

	// Archive actions live here because handle_chat only runs on Chats.
	if ui.page == .Archived {
		if clicked("ArchiveBack") {
			clear(&ui.sidebar_filter)
			ui.focus = .Compose
			ui.page = .Chats
			return
		}
		if clicked("ArchiveClearSearch") {
			clear(&ui.sidebar_filter)
			ui.focus = .Filter
			return
		}
		for _, i in ui.archived {
			if nendo.pointer_over(nendo.id("ChatUnarch", u32(i))) {
				set_archived(ui, client, ui.archived[i].group_id, false)
				load_archived(client, ui)
				return
			}
			if nendo.pointer_over(nendo.id("ArchivedRow", u32(i))) {
				select_archived_chat(ui, client, i)
				return
			}
		}
	}

	if ui.page == .Profile {
		handle_profile(ui, client)
	}

	if ui.page == .Contacts {
		if clicked("ContactsManage") {ui.contact_tools_open = !ui.contact_tools_open; return}
		if clicked("ContactsAddNpub") {
			if hex := contact_query_hex(ui); hex != "" {add_contact(ui, client, hex)}
			return
		}
		if clicked("ContactsImportBtn") || clicked("NoContactsImport") {
			if ui.contact_import != nil || ui.picking_contacts {return}
			ui.picking_contacts = true
			set_status(ui, tr("Choose a contacts CSV or JSON export to import."), .Info)
			rl.OpenFileDialog(false)
			return
		}
		if clicked("ContactsCsvBtn") {
			export_contacts(ui, .Csv)
			return
		}
		if clicked("ContactsJsonBtn") {
			export_contacts(ui, .Json)
			return
		}
		if clicked("ContactsClearSearch") {
			clear(&ui.sidebar_filter)
			ui.focus = .Filter
			return
		}
		if clicked("ContactsShowList") {
			toggle_rail(ui)
			return
		}
		for contact, i in ui.contacts {
			if nendo.pointer_over(nendo.id("ContactRow", u32(i))) {
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
				copy_text(ui, contact.npub, tr("npub copied"))
				return
			}
			if clicked("ContactScanCard") && len(contact.npub) > 0 {
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
					unblock_account(ui, client, contact.id_hex)
				} else {
					confirm_ask(ui, .Block, contact.id_hex, contact_label(ui, contact))
				}
				return
			}
		}
	}
}

// Unblocking restores what block hid: their messages show inline again
// and in rail previews, and a DM with them gets its composer back.
@(private)
unblock_account :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	key, _ := delete_key(&ui.blocked, hex)
	delete(key)
	save_settings(ui)
	refresh_after_action(ui, client)
}

@(private)
shown_contact :: proc(ui: ^Ui_State) -> (Contact_Ui, bool) {
	if ui.selected_contact >= 0 {
		if ui.selected_contact >= len(ui.contacts) {return {}, false}
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
		if contact.id_hex == ui.peer_hex {ui.selected_contact = i; break}
	}
	reset_profile_view(ui)
	if ui.selected_contact < 0 {
		ui.profile_contact = {
			id_hex  = strings.clone(ui.peer_hex),
			name    = strings.clone(ui.peer_name),
			pic_url = strings.clone(ui.peer_pic),
			npub    = strings.clone(ui.peer_npub),
		}
		account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
		for chat in ui.chats {
			members: ^marmot.Group_Member_Record_List
			group := strings.clone_to_cstring(chat.group_id, context.temp_allocator)
			if marmot.group_members(client, account, group, &members) != .OK {continue}
			if members == nil {continue}
			for member in members.items[:members.len] {
				if member.member_id_hex != nil && string(member.member_id_hex) == ui.peer_hex {
					append(
						&ui.profile_contact.groups,
						Common_Group {
							strings.clone(chat.group_id),
							strings.clone(chat.title),
							len(members.items[:members.len]),
						},
					)
					break
				}
			}
			marmot.app_group_member_record_list_free(members)
		}
	}
	probe_key_package(ui, client, ui.peer_hex)
	load_contact_relays(ui, client, ui.peer_hex)
	ed_set(ui, &ui.nick_input, ui.nicknames[ui.peer_hex])
	ui.focus = .Compose
}

@(private)
reset_profile_view :: proc(ui: ^Ui_State) {
	for group in ui.profile_contact.groups {delete(group.id); delete(group.title)}
	delete(ui.profile_contact.groups)
	for field in ([]^string{&ui.profile_contact.id_hex, &ui.profile_contact.name, &ui.profile_contact.pic_url, &ui.profile_contact.npub}) {delete(field^)}
	ui.profile_contact = {}
}

@(private)
add_contact :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	if hex == "" || hex == ui.account_ref || contact_saved(ui, hex) {return}
	job := account_job_new(ui, client, .Follow); if job == nil {return}
	job.target = strings.clone(hex)
	account_job_start(job)
}

// Unfollow a contact without changing shared group memberships.
remove_contact :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	job := account_job_new(ui, client, .Unfollow); if job == nil {return}
	job.target = strings.clone(hex); account_job_start(job)
}


// Persist the nickname editor for the selected contact: empty clears.
save_nickname :: proc(ui: ^Ui_State) {
	contact, found := shown_contact(ui)
	if !found {return}
	id := contact.id_hex
	nick := strings.trim_space(string(ui.nick_input[:]))
	if nick == ui.nicknames[id] {ui.focus = .Compose; return}
	old_key, old_value := delete_key(&ui.nicknames, id)
	delete(old_key); delete(old_value)
	if len(nick) > 0 {
		ui.nicknames[strings.clone(id)] = strings.clone(nick)
	}
	wrap_flush = true
	save_settings(ui)
	ui.focus = .Compose
}

// Reuse a direct chat with this person, or create an unnamed pair.
start_dm :: proc(ui: ^Ui_State, client: ^marmot.Client, contact: Contact_Ui) {
	job := account_job_new(ui, client, .Open_DM); if job == nil {return}
	job.target = strings.clone(contact.id_hex)
	job.chat_list = {
		client           = client,
		account          = strings.clone_to_cstring(ui.account_ref),
		include_archived = true,
	}
	chat_list_snapshot(&job.chat_list, ui)
	ui.peer_open = false
	account_job_start(job)
}

@(private)
profile_dirty :: proc(ui: ^Ui_State) -> bool {
	return(
		string(ui.name_input[:]) != ui.profile.name ||
		string(ui.about_input[:]) != ui.profile.about ||
		string(ui.nip05_input[:]) != ui.profile.nip05 ||
		string(ui.lud16_input[:]) != ui.profile.lud16 \
	)
}

// Both optional identifiers are addresses, not URLs. Reject spaces,
// missing labels and punctuation that cannot be a DNS host name.
@(private)
profile_addr_valid :: proc(value: string) -> bool {
	if value == "" {return true}
	at := strings.index_byte(value, '@')
	if at <= 0 || at >= len(value) - 1 {return false}
	for c in value[:at] {
		if !(c >= 'a' && c <= 'z') &&
		   !(c >= 'A' && c <= 'Z') &&
		   !(c >= '0' && c <= '9') &&
		   c != '_' &&
		   c != '-' &&
		   c != '.' &&
		   c != '+' {return false}
	}
	domain := value[at + 1:]
	if strings.index_byte(domain, '.') <= 0 {return false}
	label := 0
	for c, i in domain {
		if c == '.' {
			if label == 0 || domain[i - 1] == '-' {return false}
			label = 0
			continue
		}
		if !(c >= 'a' && c <= 'z') &&
		   !(c >= 'A' && c <= 'Z') &&
		   !(c >= '0' && c <= '9') &&
		   c != '-' {return false}
		if c == '-' && label == 0 {return false}
		label += 1
		if label > 63 {return false}
	}
	return label > 0 && domain[len(domain) - 1] != '-'
}

@(private)
profile_ready :: proc(ui: ^Ui_State) -> bool {
	return(
		(!ppic_busy || profile_pic_owner() != ui.account_ref) &&
		!profile_text_pending(ui) &&
		profile_dirty(ui) &&
		strings.trim_space(string(ui.name_input[:])) != "" &&
		profile_addr_valid(string(ui.nip05_input[:])) &&
		profile_addr_valid(string(ui.lud16_input[:])) \
	)
}

@(private)
profile_cancel :: proc(ui: ^Ui_State) {
	if profile_text_pending(ui) {
		return
	}
	if profile_dirty(ui) {confirm_ask(ui, .Discard_Profile, ""); return}
	ui.focus = .Compose
	profile_edit_finish(ui)
}

@(private)
profile_edit_finish :: proc(ui: ^Ui_State) {
	ui.profile.editing = false
	if !ui.settings_profile_return {return}
	ui.settings_profile_return = false
	if ui.page != .Profile {return}
	ui.page, ui.focus = .Settings, .Compose
	if ui.settings_search_return == .Home {
		settings_return_results(ui)
		return
	}
	ui.settings_anchor = "RowEditProfile"
	ui.settings_target_focus = "SettingsEditProfile"
	ui.settings_scroll_pending = true
}

@(private)
profile_text_pending :: proc(ui: ^Ui_State) -> bool {
	for job in account_jobs {
		if job.kind == .Profile && job.account == ui.account_ref {
			return true
		}
	}
	return false
}

@(private = "file")
profile_actions_need_scroll :: proc() -> bool {
	view := publication_view(nendo.id("ProfilePage"))
	actions := nendo.element(nendo.id("ProfileFormActions"))
	return actions.found && actions.rect.height > view.height
}

// Only the explicit button publishes public kind-0 data.
publish_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !ui.profile.editing {return}
	if len(strings.trim_space(string(ui.name_input[:]))) == 0 {
		ui.focus = .Name
		scroll_into_view(nendo.id("ProfilePage"), nendo.id("NameBox"))
		ui.banner_seen = ""
		set_status(ui, tr("A display name is required."), .Error)
		return
	}
	if !profile_ready(ui) {
		return
	}
	if !ui.profile.disclosure_seen {
		ui.focus = .Profile_Disclosure
		reveal_publication(ui, nendo.id("ProfilePage"), nendo.id("ProfilePublishDisclosure"))
		return
	}
	job := account_job_new(ui, client, .Profile); if job == nil {return}
	job.fields[0] = strings.clone(
		string(ui.name_input[:]),
	); job.fields[1] = strings.clone(string(ui.about_input[:])); job.fields[2] = strings.clone(string(ui.nip05_input[:])); job.fields[3] = strings.clone(string(ui.lud16_input[:]))
	account_job_start(job)
}

// Enter the edit form with drafts seeded from the loaded profile.
edit_profile_start :: proc(ui: ^Ui_State) {
	ui.focus = .Name
	if ui.profile.editing {return}
	ui.profile.editing = true
	ui.profile.disclosure_seen = false
	ed_set(ui, &ui.name_input, ui.profile.name)
	ed_set(ui, &ui.about_input, ui.profile.about)
	ed_set(ui, &ui.nip05_input, ui.profile.nip05)
	ed_set(ui, &ui.lud16_input, ui.profile.lud16)
}

settings_edit_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || ui.account_ref == "" {return}
	keys_forget(ui)
	load_profile(client, ui)
	ui.settings_profile_return = true
	ui.page = .Profile
	edit_profile_start(ui)
}

// Press-phase half of the Profile page: field focus clicks and the
// edit form's keyboard shortcuts. Runs every frame, ahead of the
// release gate that holds handle_profile back.
profile_fields :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !ui.profile.editing || profile_text_pending(ui) {
		return
	}
	if fully_in_scroll_view(nendo.id("ProfilePage"), nendo.id("ProfilePublishDisclosure")) {
		ui.profile.disclosure_seen = true
	}
	if ui.focus == .Profile_Publish && mouse_pressed() {
		ui.focus = .Name
	}
	if field_mouse(ui, &ui.name_input, "NameBox", 14) {
		ui.focus = .Name
	}
	compose_mouse(ui, &ui.about_input, .About)
	if field_mouse(ui, &ui.nip05_input, "Nip05Box", 14) {
		ui.focus = .Nip05
	}
	if field_mouse(ui, &ui.lud16_input, "Lud16Box", 14) {
		ui.focus = .Lud16
	}
	if field_mouse(ui, &ui.relay_input, "RelayBox", 14) {
		ui.focus = .Relay
	}

	if ui.focus == .Profile_Disclosure {
		switch tab_step() {
		case -1:
			ui.focus = .Lud16
			scroll_into_view(nendo.id("ProfilePage"), nendo.id("Lud16Box"))
			return
		case 1:
			if ui.profile.disclosure_seen {
				ui.focus = .Profile_Publish
				reveal_publication(ui, nendo.id("ProfilePage"), nendo.id("PublishProfileBtn"))
			} else {
				reveal_publication(
					ui,
					nendo.id("ProfilePage"),
					nendo.id("ProfilePublishDisclosure"),
				)
			}
			return
		}
	}
	fields := [?]Focus{.Name, .About, .Nip05, .Lud16, .Profile_Publish}
	boxes := [?]string{"NameBox", "ComposeBox", "Nip05Box", "Lud16Box", "ProfileFormActions"}
	if at, moved := tab_focus(fields[:], &ui.focus); moved {
		box := boxes[at]
		if ui.focus == .Profile_Publish && profile_actions_need_scroll() {
			if ui.profile.disclosure_seen {
				box = "PublishProfileBtn"
			} else {
				ui.focus = .Profile_Disclosure
				box = "ProfilePublishDisclosure"
			}
		}
		scroll_into_view(nendo.id("ProfilePage"), nendo.id(box))
		return
	}
	if rl.IsKeyPressed(.ESCAPE) {
		profile_cancel(ui)
		return
	}
	if ui.focus == .Profile_Disclosure {
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
			reveal_publication(ui, nendo.id("ProfilePage"), nendo.id("ProfilePublishDisclosure"))
		}
		return
	}
	if ui.focus == .Profile_Publish {
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
			publish_profile(ui, client)
		}
		return
	}
	if rl.IsKeyPressed(.ENTER) {
		for field, i in fields {
			if ui.focus == field && field != .Lud16 {
				ui.focus = fields[i + 1]
				scroll_into_view(nendo.id("ProfilePage"), nendo.id(boxes[i + 1]))
				break
			}
		}
	}
}

@(private = "file")
open_add_account :: proc(ui: ^Ui_State) {
	ui.add_account_open = ui.account_ref != ""
	ui.login_method = .Menu
	login_clear_form(ui)
}

handle_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	// The Profile rail (panes.odin): switch account, add one, or jump to
	// the settings sections that own the rest of an identity.
	if ui.page == .Profile {
		for account, i in ui.accounts {
			id := account.id_hex
			if nendo.pointer_over(nendo.id("PrAcct", u32(i))) {
				if id != ui.account_ref {
					switch_account(ui, client, id)
				}
				return
			}
		}
		if clicked("PrAddAccount") {
			open_add_account(ui)
			return
		}
		if clicked("PrKeys") || clicked("PrNetwork") {
			keys := clicked("PrKeys")
			ui.settings_profile_return = false
			settings_open(ui, client, keys ? .Account : .Connection)
			return
		}
	}

	if clicked("EditProfileBtn") {
		if ui.profile.editing {
			profile_cancel(ui)
		} else {
			edit_profile_start(ui)
		}
		return
	}
	if clicked("ProfileAccounts") {ui.accounts_open = true; return}
	if clicked("ProfileScanCard") && ui.profile.npub != "" {
		show_contact_qr(ui, Contact_Ui{npub = ui.profile.npub})
		return
	}
	if clicked("ProfileCopyNpub") && len(ui.profile.npub) > 0 {
		copy_text(ui, ui.profile.npub, tr("npub copied"))
		return
	}

	if clicked("RevealNsec") && account_local(ui) {
		nsec: cstring
		if marmot.reveal_nsec(client, account, &nsec) == .OK && nsec != nil {
			ui.profile.nsec = strings.clone(string(nsec))
			marmot.string_free(nsec)
		}
	}

	if ui.profile.editing &&
	   (clicked("ChangePicBtn") || clicked("ProfileAvatarPick")) &&
	   !ppic_busy &&
	   !profile_text_pending(ui) {
		if photo_pick_begin(ui, .Profile) {rl.OpenFileDialog(false); return}
	}

	if clicked("PublishProfileBtn") {
		publish_profile(ui, client)
	}

	if clicked("AddRelayBtn") {
		if strings.trim_space(string(ui.relay_input[:])) == "" {
			ui.focus = .Relay
			ui.banner_seen = ""
			set_status(ui, tr("Enter a relay URL before adding it."), .Error)
			return
		}
		if relay_list_contains(ui.profile.nip65[:], ui.relay_input[:]) {
			ui.focus = .Relay
			ui.banner_seen = ""
			set_status(ui, tr("This relay is already in your list."), .Info)
			return
		}
		relays := make([dynamic]cstring, context.temp_allocator)
		for relay in ui.profile.nip65 {
			append(&relays, strings.clone_to_cstring(relay, context.temp_allocator))
		}
		append(
			&relays,
			strings.clone_to_cstring(string(ui.relay_input[:]), context.temp_allocator),
		)
		set_relays(ui, client, relays[:])
		if ui.page != .Settings {clear(&ui.relay_input)}
		return
	}
	for relay, i in ui.profile.nip65 {
		if nendo.pointer_over(nendo.id("RelayRemove", u32(i))) {
			confirm_ask(ui, .Remove_Relay, relay, relay, i)
			return
		}
	}

	if clicked("SignOutBtn") {
		confirm_ask(
			ui,
			.Sign_Out,
			ui.account_ref,
			account_label(ui, ui.account_ref),
			account_local(ui) ? 0 : 1,
		)
	}
	if clicked("SignOutWipeBtn") {
		profile := device_current(ui)
		linked :=
			profile == nil ||
			.Roster not_in profile.known ||
			(profile.view.roster != nil && profile.view.roster.len != 0)
		confirm_ask(
			ui,
			.Wipe_Account,
			ui.account_ref,
			account_label(ui, ui.account_ref),
			int(linked),
		)
	}
}

set_relays :: proc(ui: ^Ui_State, client: ^marmot.Client, relays: []cstring) {
	account_relays_start(ui, client, relays, .Outbox)
}

// Truncate an id-like string for display.
short_hex :: proc(s: string) -> string {
	if len(s) <= 12 {
		return s
	}
	return fmt.tprintf("%s...", s[:12])
}

// Register an nsec with marmot. Blocks on the relay round trip, so the
// UI calls it through the sign-in worker (workers.odin).
import_identity_blocking :: proc(
	client: ^marmot.Client,
	identity: string,
	relays := ONBOARDING_RELAYS,
) -> (
	hex: string,
	status: marmot.Status,
	detail: string,
) {
	summary: ^marmot.Account_Summary
	id := strings.clone_to_cstring(identity, context.temp_allocator)
	defer mem.zero_slice(transmute([]u8)string(id))
	status = marmot.login(
		client,
		id,
		raw_data(relays),
		uint(len(relays)),
		raw_data(relays),
		uint(len(relays)),
		nil,
		0,
		&summary,
	)
	if status != .OK {
		return "", status, marmot.last_error()
	}
	defer marmot.account_summary_free(summary)
	return strings.clone(string(summary.account_id_hex)), status, ""
}

finish_auth :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	after_login(ui, client, hex)
	remember_account(ui, ui.account_ref)
}

// Store the account the user chose last; boot_marmot opens on it.
@(private = "file")
remember_account :: proc(ui: ^Ui_State, hex: string) {
	if ui.prefs.last_account == hex {
		return
	}
	delete(ui.prefs.last_account)
	ui.prefs.last_account = strings.clone(hex)
	ui.settings_dirty = true
}

// WN_TEST_CREATE confirms the generated name and lands before the first frame.
do_create_identity :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	job := new(Auth_Job)
	defer auth_job_free(job)
	job.client = client
	prepare_starter(job)
	if job.err == "" {create_starter(job)}
	if job.err != "" {
		ui.login_error = strings.clone(job.err)
		return
	}
	finish_starter(ui, job)
}

@(private)
accounts_adopt :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	accounts: ^marmot.Account_Summary_List,
) {
	revision := ui.accounts_revision + 1
	ui.accounts_revision = revision
	cleared_unlinked := false
	if accounts != nil {
		for summary in accounts.items[:accounts.len] {
			hex := string(summary.account_id_hex)
			if hex == "" {continue}
			if summary.signed_out && summary.unlinked {
				devices_mark_unlinked(ui, hex, string(summary.label))
				continue
			}
			// MDK can omit unreadable records and report stopped workers when
			// its worker lock is busy. Only a running replacement clears the fence.
			profile := ui.devices.profiles[hex]
			if profile == nil ||
			   !(profile.unlink_check || profile.revoked) ||
			   !summary.running ||
			   summary.signed_out {continue}
			profile.revoked, profile.unlink_check, profile.unlink_notice_seen = false, false, false
			delete(profile.unlink_label, reload_allocator()); profile.unlink_label = ""
			cleared_unlinked = true
			if ui.devices.panel_account == hex &&
			   (ui.devices.panel == .Unlinked || ui.devices.panel == .Auth_Unlinked) {
				devices_close(ui)
			}
		}
	}
	old, old_signed_out := ui.accounts, ui.signed_out_accounts
	previous := make(
		map[string]^Account_Row_Ui,
		len(old) + len(old_signed_out),
		context.temp_allocator,
	)
	for &row in old {previous[row.id_hex] = &row}
	for &row in old_signed_out {previous[row.id_hex] = &row}
	ui.accounts, ui.signed_out_accounts = {}, {}
	if accounts != nil {
		for summary in accounts.items[:accounts.len] {
			hex := string(summary.account_id_hex)
			if hex == "" {continue}
			// A signed-out account with its key in the vault can sign back in
			// from the list. A remote signer reconnects from the sign-in card.
			if summary.signed_out &&
			   (summary.unlinked || !summary.local_signing || summary.external_signing) {continue}
			if device := ui.devices.profiles[hex];
			   device != nil && (device.revoked || device.unlink_check) {continue}
			row: Account_Row_Ui
			if prev, ok := previous[hex]; ok {
				row, prev^ = prev^, {}
			} else {
				if !summary.signed_out {restore_starter_pic(ui, client, hex)}
				row.id_hex = strings.clone(hex)
				row.name = strings.clone(profile_label(client, hex))
				row.pic_url = strings.clone(profile_info(client, hex).pic_url)
				npub: cstring
				if marmot.npub(client, summary.account_id_hex, &npub) == .OK && npub != nil {
					row.npub = strings.clone(string(npub))
					marmot.string_free(npub)
				}
			}
			row.local, row.external = summary.local_signing, summary.external_signing
			append(summary.signed_out ? &ui.signed_out_accounts : &ui.accounts, row)
		}
	}
	for row in old {account_row_free(row)}
	for row in old_signed_out {account_row_free(row)}
	delete(old); delete(old_signed_out)
	devices_seed(ui)
	if cleared_unlinked &&
	   ui.account_ref == "" &&
	   auth_job == nil &&
	   !accounts_have_tombstones(ui) {
		ui.accounts_open = len(ui.accounts) != 0
	}
}

@(private)
account_revoked :: proc(ui: ^Ui_State, account: string) -> bool {
	profile := ui.devices.profiles[account]
	return profile != nil && profile.revoked
}

@(private)
account_signed_in :: proc(ui: ^Ui_State, account: string) -> bool {
	if account == "" {return false}
	if profile := ui.devices.profiles[account];
	   profile != nil && (profile.revoked || profile.unlink_check) {return false}
	for row in ui.accounts {if row.id_hex == account {return true}}
	return false
}

@(private)
accounts_have_tombstones :: proc(ui: ^Ui_State) -> bool {
	for _, profile in ui.devices.profiles {if profile.revoked || profile.unlink_check {return true}}
	return false
}

@(private)
account_signed_out :: proc(ui: ^Ui_State, account: string) -> bool {
	for row in ui.signed_out_accounts {if row.id_hex == account {return true}}
	return false
}

@(private)
account_row_free :: proc(row: Account_Row_Ui) {
	delete(row.id_hex); delete(row.name); delete(row.pic_url); delete(row.npub)
}

@(private)
account_departed :: proc(ui: ^Ui_State, client: ^marmot.Client, account: string) {
	if account == "" {return}
	activation_departed(ui, account)
	active := ui.account_ref == account
	if ui.prefs.last_account == account {remember_account(ui, "")}
	for row, i in ui.accounts {
		if row.id_hex != account {continue}
		account_row_free(row)
		ordered_remove(&ui.accounts, i)
		ui.accounts_revision += 1
		break
	}
	devices_seed(ui)
	if !active {return}
	confirm_close(ui)
	account_workspace_clear(ui)
	delete(ui.account_ref); ui.account_ref = ""
	devices_select(ui)
	gs_check_account(ui)
	ui.page = .Chats
	ui.add_account_open = false
	ui.accounts_open = len(ui.accounts) != 0 && auth_job == nil && !accounts_have_tombstones(ui)
}

// Land on the signed-in profile selected by boot or authentication.
after_login :: proc(ui: ^Ui_State, client: ^marmot.Client, active := "") {
	// Discard the empty-pool snapshot taken while account setup was running.
	ui.health_ok = false
	health_refresh(ui, client)
	if ui.location_open {geo_picker_close(ui)}
	poll_close(ui)
	keys_forget(ui); close_export(ui); session_string_forget(&ui.profile.nsec)
	kp_rows_free(&ui.kp_list); ui.kp_fetched = false
	delete(ui.kp_own_json); ui.kp_own_json = ""
	timing_start := time.tick_now()
	defer local_timing_end(.account_load, timing_start)
	clear(&ui.login_input)
	ui.login_method = .Menu
	ui.login_error = ""

	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) == .OK {
		accounts_adopt(ui, client, accounts)
		marmot.account_summary_list_free(accounts)
		account_land(ui, client, active)
	}
	ui.add_account_open = false
	ui.settings_profile_return = false
	ui.profile = {}
}

@(private = "file")
account_land :: proc(ui: ^Ui_State, client: ^marmot.Client, active: string) {
	if account_signed_in(ui, active) {
		finish_account_switch(ui, client, active)
		ui.accounts_open = false
	} else if ui.account_ref == "" {
		ui.accounts_open = len(ui.accounts) != 0 && !accounts_have_tombstones(ui)
	}
}

@(private)
handle_peer_modal :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		ui.peer_open = false
		return
	}
	if !mouse_released() {return}
	if (clicked("PeerCopyNpub") || clicked("PeerCopyNpubKey")) && len(ui.peer_npub) > 0 {
		copy_text(ui, ui.peer_npub, tr("npub copied"))
		return
	}
	if clicked("PeerViewProfile") {
		view_peer_profile(ui, client)
		return
	}
	if clicked("PeerAddContact") {add_contact(ui, client, ui.peer_hex); return}
	if clicked("PeerMessage") && ui.peer_hex != ui.account_ref {
		start_dm(
			ui,
			client,
			Contact_Ui{id_hex = ui.peer_hex, name = ui.peer_name, npub = ui.peer_npub},
		)
		return
	}
	if clicked("PeerClose") || !nendo.pointer_over(nendo.id("PeerModal")) {
		ui.peer_open = false
	}
}

@(private)
handle_accounts :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {ui.accounts_open = false; return}
	if !mouse_released() {return}
	for row, i in ui.accounts {
		if !nendo.pointer_over(nendo.id("AccountRow", u32(i))) {continue}
		ui.accounts_open = false
		if row.id_hex != ui.account_ref {switch_account(ui, client, row.id_hex)}
		return
	}
	// The modal stays open so the row can show the sign-in running;
	// landing on the account closes it.
	for row, i in ui.signed_out_accounts {
		if !nendo.pointer_over(nendo.id("AccountRow", u32(len(ui.accounts) + i))) {continue}
		if account_signing_in() == "" {
			account_job_start(account_job_new(ui, client, .Sign_In, row.id_hex))
		}
		return
	}
	if clicked("AddAccountBtn") {
		ui.accounts_open = false
		open_add_account(ui)
		return
	}
	if clicked("AcctClose") ||
	   clicked("AcctCloseBtn") ||
	   !nendo.pointer_over(nendo.id("AccountsModal")) {
		ui.accounts_open = false
	}
}

// Activate another already-stored account and reload everything.
switch_account :: proc(ui: ^Ui_State, client: ^marmot.Client, account_id: string) -> bool {
	if !account_signed_in(ui, account_id) {return false}
	job := account_job_new(ui, client, .Switch, account_id)
	if job == nil {return false}
	account_job_start(job)
	return true
}

@(private)
finish_account_switch :: proc(ui: ^Ui_State, client: ^marmot.Client, account_id: string) {
	if profile := ui.devices.profiles[account_id];
	   profile != nil && (profile.revoked || profile.unlink_check) {return}
	selected := strings.clone(account_id)
	account_workspace_clear(ui)
	delete(ui.account_ref)
	ui.account_ref = selected
	devices_select(ui)
	devices_refresh_reads(ui)
	remember_account(ui, selected)
	gs_check_account(ui)
	if client != nil {load_chat_list(client, selected, ui)}
}

@(private = "file")
account_workspace_clear :: proc(ui: ^Ui_State) {
	event_data_close(&ui.event_data)
	if ui.location_open {geo_picker_close(ui)}
	poll_close(ui)
	close_group_info(ui)
	if account_revoked(ui, ui.account_ref) {
		staged_files_free(ui.staged)
		ui.staged = {}
	} else if ui.account_ref != "" && ui.selected >= 0 && ui.selected < len(ui.chats) {
		stash_draft(ui)
		stash_staged(ui)
	}
	timeline_retire()
	append(&retired_messages, ..ui.messages[:]); clear(&ui.messages)
	messages_rebind(ui); sel_clear(ui)
	delete(ui.timeline_error); ui.timeline_error = ""
	ui.timeline_loading, ui.timeline_paging = false, false
	ui.tl_has_more, ui.tl_has_after = false, false
	thread_clear(ui)
	chat_list_revision += 1
	chats_replace(&ui.chats, {}); chats_replace(&ui.archived, {})
	clear(&ui.rail_rows)
	chat_members_free(&ui.chat_members); ui.chat_members_read = false
	members_clear(ui)
	ui.selected, ui.row_menu, ui.member_menu, ui.selected_contact = -1, -1, -1, -1
	ui.show_members, ui.group_files_open, ui.search_open, ui.chat_head_menu =
		false, false, false, false
	ui.ctx_open, ui.hist_open, ui.raw_open, ui.enc_open = false, false, false, false
	ui.peer_open, ui.qr_open, ui.fwd_open, ui.picker_open, ui.sticker_open =
		false, false, false, false, false
	ui.folder_open, ui.folder_menu_open, ui.mi_open, ui.pal_open = false, false, false, false
	ui.compose_more, ui.fx_open = false, false
	ui.composer_settings_from_chat = false
	ui.settings_profile_return = false
	ui.settings_return_page = nil
	ui.settings_return_focus = .Compose
	if ui.gs_open {gs_close(ui)}
	if ui.new_chat_open {close_new_chat(ui)}
	if preview_shown {preview_close()}
	web_close()
	nes_close()
	voice_cancel(); editor_forget(ui); session_buffer_forget(&ui.compose)
	touch_field = {}
	compose_keyboard = false
	ui.focus = .Compose
	ui.editing, ui.replying = "", ""
	photo_cancel(ui)
	keys_forget(ui); close_export(ui)
	session_string_forget(&ui.profile.nsec)
	kp_rows_free(&ui.kp_list); ui.kp_fetched = false
	delete(ui.kp_own_json); ui.kp_own_json = ""

	ui.profile = {}
	reset_profile_view(ui)
	clear(&ui.contacts)
}

// Capacity errors request a larger arena; other layout errors are logged.
error_handler :: proc(errorData: nendo.Error) {
	if errorData.kind == .Elements_Capacity_Exceeded ||
	   errorData.kind == .Text_Measurement_Capacity_Exceeded ||
	   errorData.kind == .Hash_Map_Capacity_Exceeded {
		layout_overflow = true
		return
	}
	fmt.eprintfln("nendo: %v: %s", errorData.kind, errorData.text)
}

// Keep font metadata beside visible text, so selection copies no markup.
extract_inlines :: proc(
	builder: ^strings.Builder,
	inlines: [^]marmot.Markdown_Inline,
	count: uint,
	fonts: ^strings.Builder = nil,
	font: u8 = FONT_BODY,
	links: ^[dynamic]Inline_Link = nil,
	timestamps: ^[dynamic]Md_Timestamp = nil,
	timestamp_row: int = -1,
	timestamp_cell: int = 0,
) {
	for i in 0 ..< count {
		node := &inlines[i]
		start := strings.builder_len(builder^)
		style := font
		switch node.tag {
		case .TEXT:
			strings.write_string(builder, string(node.body.text.content))
		case .CODE:
			strings.write_string(builder, string(node.body.code.content))
			style = FONT_MONO | TEXT_CODE | (font & TEXT_STRIKE)
		case .SOFT_BREAK, .HARD_BREAK:
			// Chat messages keep the sender's line breaks, including soft breaks.
			strings.write_rune(builder, '\n')
		case .EMPH:
			extract_inlines(
				builder,
				node.body.emph.children,
				node.body.emph.children_len,
				fonts,
				((font & TEXT_FONT_MASK) == FONT_TITLE || (font & TEXT_FONT_MASK) == FONT_BOLD_ITALIC ? FONT_BOLD_ITALIC : FONT_ITALIC) |
				(font & ~TEXT_FONT_MASK),
				links,
				timestamps,
				timestamp_row,
				timestamp_cell,
			)
			continue
		case .STRONG:
			extract_inlines(
				builder,
				node.body.strong.children,
				node.body.strong.children_len,
				fonts,
				((font & TEXT_FONT_MASK) == FONT_ITALIC || (font & TEXT_FONT_MASK) == FONT_BOLD_ITALIC ? FONT_BOLD_ITALIC : FONT_TITLE) |
				(font & ~TEXT_FONT_MASK),
				links,
				timestamps,
				timestamp_row,
				timestamp_cell,
			)
			continue
		case .STRIKETHROUGH:
			extract_inlines(
				builder,
				node.body.strikethrough.children,
				node.body.strikethrough.children_len,
				fonts,
				font | TEXT_STRIKE,
				links,
				timestamps,
				timestamp_row,
				timestamp_cell,
			)
			continue
		case .LINK:
			extract_inlines(
				builder,
				node.body.link.children,
				node.body.link.children_len,
				fonts,
				font,
				links,
				timestamps,
				timestamp_row,
				timestamp_cell,
			)
			dest := string(node.body.link.dest)
			if _, _, ok := url_at(dest, 0);
			   links != nil && ok && strings.builder_len(builder^) > start {
				append(
					links,
					Inline_Link {
						start = start,
						end = strings.builder_len(builder^),
						url = strings.clone(dest),
					},
				)
			}
			continue
		case .AUTOLINK:
			strings.write_string(builder, string(node.body.autolink.url))
		case .MATH:
			strings.write_string(builder, string(node.body.math.content))
			style = FONT_MONO | TEXT_MATH | (font & TEXT_STRIKE)
		case .IMAGE:
			// Preserve the destination for clickable links and optional previews.
			strings.write_string(builder, string(node.body.image.dest))
		case .NOSTR_MENTION, .NOSTR_URI:
			strings.write_string(builder, string(node.body.nostr_mention.entity.bech32))
		case .TIMESTAMP:
			stamp := node.body.timestamp
			if timestamps == nil {
				strings.write_string(
					builder,
					timestamp_label(
						stamp.unix_seconds,
						stamp.style,
						time.time_to_unix(time.now()),
					),
				)
			} else {
				strings.write_string(builder, timestamp_token(stamp.unix_seconds, stamp.style))
				append(
					timestamps,
					Md_Timestamp {
						start,
						strings.builder_len(builder^),
						stamp.unix_seconds,
						stamp.style,
						timestamp_row,
						timestamp_cell,
					},
				)
			}
		}
		if fonts != nil {
			for _ in start ..< strings.builder_len(builder^) {strings.write_byte(fonts, style)}
		}
	}
}

inline_text :: proc(
	inlines: [^]marmot.Markdown_Inline,
	count: uint,
	fonts: ^string = nil,
	font: u8 = FONT_BODY,
	links: ^[dynamic]Inline_Link = nil,
	timestamps: ^[dynamic]Md_Timestamp = nil,
	timestamp_row: int = -1,
	timestamp_cell: int = 0,
) -> string {
	builder := strings.builder_make(context.temp_allocator)
	styles := strings.builder_make(context.temp_allocator)
	extract_inlines(
		&builder,
		inlines,
		count,
		fonts != nil ? &styles : nil,
		font,
		links,
		timestamps,
		timestamp_row,
		timestamp_cell,
	)
	if fonts != nil && len(strings.trim(strings.to_string(styles), "\x00")) > 0 {
		fonts^ = strings.clone(strings.to_string(styles))
	}
	return strings.clone(strings.to_string(builder))
}

// Flatten the FFI block tree into owned Md_Block_Ui rows.
convert_blocks :: proc(
	out: ^[dynamic]Md_Block_Ui,
	blocks: [^]marmot.Markdown_Block,
	count: uint,
	quoted: bool,
	gaps: []u8 = nil,
) {
	for i in 0 ..< count {
		first := len(out^)
		defer {
			if first < len(out^) && i < uint(len(gaps)) {
				out^[first].blank_lines_before = u8(
					min(u16(out^[first].blank_lines_before) + u16(gaps[i]), u16(MD_BLANK_MAX)),
				)
			}
		}
		block := &blocks[i]
		switch block.tag {
		case .PARAGRAPH:
			kind := quoted ? Md_Kind.Quote : Md_Kind.Para
			row := Md_Block_Ui {
				kind = kind,
			}
			row.text = inline_text(
				block.body.paragraph.inlines,
				block.body.paragraph.inlines_len,
				&row.fonts,
				links = &row.links,
				timestamps = &row.timestamps,
			)
			append(out, row)
		case .HEADING:
			row := Md_Block_Ui {
				kind  = .Heading,
				level = int(block.body.heading.level),
			}
			row.text = inline_text(
				block.body.heading.inlines,
				block.body.heading.inlines_len,
				&row.fonts,
				FONT_TITLE,
				&row.links,
				&row.timestamps,
			)
			append(out, row)
		case .CODE_BLOCK:
			append(
				out,
				Md_Block_Ui {
					kind = .Code,
					text = strings.clone(
						strings.trim_right(string(block.body.code_block.content), "\n"),
					),
				},
			)
			out^[len(out^) - 1].code_kinds = md_code_kinds(
				string(block.body.code_block.info),
				out^[len(out^) - 1].text,
			)
		case .BLOCK_QUOTE:
			quote := &block.body.block_quote
			convert_blocks(
				out,
				quote.blocks,
				quote.blocks_len,
				true,
				([^]u8)(quote.blank_lines_before)[:quote.blank_lines_before_len],
			)
			for &row in out^[first:] {row.quote_depth += 1}
			if first < len(out^) {out^[first].quote_starts += 1}
		case .LIST_BLOCK:
			list := &block.body.list_block
			for j in 0 ..< list.items_len {
				item := &list.items[j]
				prefix: string
				if item.has_checked {
					prefix = item.checked ? "[x] " : "[ ] "
				} else if list.kind.tag == 1 {
					prefix = fmt.tprintf(
						"%d%s ",
						list.kind.body.ordered.start + u32(j),
						string(list.kind.body.ordered.delimiter),
					)
				} else {
					prefix = "• "
				}

				// One row from the item's first paragraph; nested
				// blocks flatten after it.
				body_text: string
				fonts: string
				links: [dynamic]Inline_Link
				timestamps: [dynamic]Md_Timestamp
				body_start := uint(0)
				if item.blocks_len > 0 && item.blocks[0].tag == .PARAGRAPH {
					body_start = 1
					body_text = inline_text(
						item.blocks[0].body.paragraph.inlines,
						item.blocks[0].body.paragraph.inlines_len,
						&fonts,
						links = &links,
						timestamps = &timestamps,
					)
				}
				for &link in links {link.start += len(prefix); link.end += len(prefix)}
				for &stamp in timestamps {stamp.start += len(prefix); stamp.end += len(prefix)}
				if len(fonts) > 0 {
					body_fonts := fonts
					fonts = strings.concatenate(
						{strings.repeat("\x00", len(prefix), context.temp_allocator), body_fonts},
					)
					delete(body_fonts)
				}
				gap := j > 0 && !list.tight ? u8(1) : 0
				if item.blank_lines_before_len > 0 {gap = max(gap, item.blank_lines_before^)}
				append(
					out,
					Md_Block_Ui {
						kind = .List_Item,
						text = strings.clone(fmt.tprintf("%s%s", prefix, body_text)),
						fonts = fonts,
						links = links,
						timestamps = timestamps,
						marker_len = len(prefix),
						blank_lines_before = gap,
					},
				)
				delete(body_text)
				if item.blocks_len > body_start {
					nested_start := len(out^)
					gaps := ([^]u8)(item.blank_lines_before)[:item.blank_lines_before_len]
					convert_blocks(
						out,
						item.blocks[body_start:],
						item.blocks_len - body_start,
						quoted,
						gaps[min(int(body_start), len(gaps)):],
					)
					for &row in out^[nested_start:] {row.indent += 24}
				}
			}
		case .THEMATIC_BREAK:
			append(out, Md_Block_Ui{kind = .Rule})
		case .TABLE:
			t := &block.body.table
			timestamps: [dynamic]Md_Timestamp
			cells := make([][]string, int(t.rows_len) + 1)
			fonts := make([][]string, len(cells))
			links := make([][][dynamic]Inline_Link, len(cells))
			hdr := make([]string, int(t.header_len))
			fonts[0] = make([]string, len(hdr))
			links[0] = make([][dynamic]Inline_Link, len(hdr))
			for j in 0 ..< t.header_len {
				hdr[j] = inline_text(
					t.header[j].inlines,
					t.header[j].inlines_len,
					&fonts[0][j],
					FONT_TITLE,
					&links[0][j],
					&timestamps,
					0,
					int(j),
				)
			}
			cells[0] = hdr
			for r in 0 ..< t.rows_len {
				row := make([]string, int(t.rows[r].cells_len))
				fonts[r + 1] = make([]string, len(row))
				links[r + 1] = make([][dynamic]Inline_Link, len(row))
				for j in 0 ..< t.rows[r].cells_len {
					row[j] = inline_text(
						t.rows[r].cells[j].inlines,
						t.rows[r].cells[j].inlines_len,
						&fonts[r + 1][j],
						links = &links[r + 1][j],
						timestamps = &timestamps,
						timestamp_row = int(r) + 1,
						timestamp_cell = int(j),
					)
				}
				cells[int(r) + 1] = row
			}
			alignments := make([]marmot.Markdown_Alignment, int(t.alignments_len))
			copy(alignments, t.alignments[:t.alignments_len])
			append(
				out,
				Md_Block_Ui {
					kind = .Table,
					cells = cells,
					cell_fonts = fonts,
					cell_links = links,
					timestamps = timestamps,
					alignments = alignments,
				},
			)
		case .MATH_BLOCK:
			append(
				out,
				Md_Block_Ui {
					kind = .Math,
					text = strings.clone(string(block.body.math_block.content)),
				},
			)
		}
	}
}

// Runtime construction and start. Both do disk I/O over every
// account's stores, so boot_marmot runs them here while the UI thread
// keeps the splash moving. `ui` is read by apply_observability only;
// the UI thread leaves it alone meanwhile.
@(private = "file")
Boot_Job :: struct {
	home:   string,
	client: ^marmot.Client,
	status: marmot.Status,
	error:  string, // marmot's last_error is per thread
}

@(private = "file")
boot_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	job := (^Boot_Job)(t.data)
	relays := DEFAULT_RELAYS

	// The account signing keys land in the vault (vault_gate.odin), not
	// the platform keychain: the store is copied here and its callbacks
	// run for the client's whole life.
	store := vault_secret_store()

	// Every constructor requires a deployment. Keep White Noise's services;
	// construction copies the deployment.
	deployment: ^marmot.Deployment
	job.status = marmot.deployment_white_noise(&deployment)
	if job.status != .OK {
		job.error = marmot.last_error()
		return
	}
	defer marmot.deployment_free(deployment)
	options := marmot.Client_Options {
		client_name = "whitenoise",
		store       = &store,
	}
	when DEVICE_PLATFORM != "" {
		options.device_platform = DEVICE_PLATFORM
	}
	job.status = marmot.client_new_with_configuration(
		strings.clone_to_cstring(job.home),
		raw_data(relays),
		len(relays),
		&options,
		deployment,
		&job.client,
	)
	if job.status != .OK {
		job.client = nil
		job.error = marmot.last_error()
		return
	}

	// Configure the destination before startup restores the saved consent.
	local_timing_bind(job.client)
	apply_observability(job.client)

	job.status = marmot.client_start(job.client)
	if job.status != .OK {
		job.error = marmot.last_error()
	}
	// Startup restored MDK-owned signer sessions; take handles to them.
	nip46_restore(job.client)
}

boot_marmot :: proc(home: string, ui: ^Ui_State) -> ^marmot.Client {
	timing_start := time.tick_now()
	defer local_timing_end(.runtime_init, timing_start)
	os.make_directory(home)

	job := Boot_Job {
		home = home,
	}
	worker := thread.create(boot_worker)
	worker.data = &job
	thread.start(worker)
	// A close request stays latched for the main loop to act on.
	for !thread.is_done(worker) {
		_ = rl.WindowShouldClose()
		// Without a present to pace it, a hidden window polls at 4 Hz.
		if !rl.IsWindowVisible() {rl.Wait(IDLE_REFRESH_MS)}
		splash_frame(0)
	}
	thread.join(worker)
	thread.destroy(worker)

	client := job.client
	defer delete(job.error)
	switch {
	case client == nil:
		set_status(ui, fmt.aprintf(tr("Runtime failed: %s"), job.error), .Error)
		return nil
	case job.status != .OK:
		set_status(ui, fmt.aprintf(tr("Started offline: %s"), job.error), .Info)
	case:
		set_status(ui, tr("Runtime running"), .Info)
	}

	// Same snapshot as every later account change; a second hand-rolled
	// loop here once missed the npub/pic arrays and crashed the switcher.
	// It creates avatar textures, so it stays on this thread.
	splash_frame(1)

	// Open on the account chosen last. A remote-signer account can't act
	// until its signer attaches, so boot lands on a local account and
	// nip46_tick switches over once the attach completes.
	boot_active := ""
	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) == .OK {
		for row in accounts.items[:accounts.len] {
			if row.signed_out {
				continue
			}
			hex := string(row.account_id_hex)
			last := hex == ui.prefs.last_account
			local := row.local_signing && !row.external_signing
			if last && !local {
				if item := nip46_find(hex); item != nil {
					item.switch_requested = true
				}
			}
			if local && last {
				boot_active = strings.clone(hex, context.temp_allocator)
			}
		}
		accounts_adopt(ui, client, accounts)
		marmot.account_summary_list_free(accounts)
		account_land(ui, client, boot_active)
	}
	ui.health_ok = false
	health_refresh(ui, client)

	return client
}

@(private)
CHAT_ATTACHMENT_AUDIO :: i32(2) // MarmotChatListAttachmentKind::Audio

// Snapshot the account's chat list into UI-owned strings.
// Match Android's absent-name test after unsafe controls/formatting are
// stripped. ZWJ/ZWNJ remain meaningful in shaping and emoji sequences.
@(private)
chat_name_is_unnamed :: proc(name: string) -> bool {
	for r in name {
		if r == 0x200c || r == 0x200d {return false}
		if unicode.is_space(r) || unicode.is_control(r) {continue}
		stripped := false
		for span in ([][2]rune{{0xad, 0xad}, {0x34f, 0x34f}, {0x600, 0x605}, {0x61c, 0x61c}, {0x6dd, 0x6dd}, {0x70f, 0x70f}, {0x890, 0x891}, {0x8e2, 0x8e2}, {0x180e, 0x180e}, {0x200b, 0x200f}, {0x202a, 0x202e}, {0x2060, 0x2064}, {0x2066, 0x206f}, {0xfeff, 0xfeff}, {0xfff9, 0xfffb}, {0x110bd, 0x110bd}, {0x110cd, 0x110cd}, {0x13430, 0x13455}, {0x1bca0, 0x1bca3}, {0x1d173, 0x1d17a}, {0xe0000, 0xe007f}, {0xe0100, 0xe01ef}}) {
			if r >= span[0] && r <= span[1] {stripped = true; break}
		}
		if !stripped {return false}
	}
	return true
}

@(private)
chat_conversation_kind :: proc(
	kind: marmot.Chat_Conversation_Kind,
	name: string,
	member_count: int,
) -> marmot.Chat_Conversation_Kind {
	if kind != .UNKNOWN {return kind}
	if !chat_name_is_unnamed(name) {return .GROUP}
	// A failed/unresolved roster is not evidence of a two-member DM.
	return member_count == 2 ? .DIRECT : .GROUP
}

@(private)
chat_row_identity :: proc(
	presented: ^marmot.Presented_Chat_Row,
	account: string,
	members: map[string][]string,
) -> (
	kind: marmot.Chat_Conversation_Kind,
	peer: string,
) {
	row := &presented.row
	ids, have_members := members[string(row.group_id_hex)]
	count := -1
	if have_members {
		count = len(ids)
	} else if title := presented.presentation.title;
	   title.tag == .Unnamed_Group && title.body.unnamed_group.has_member_count {
		count = int(title.body.unnamed_group.member_count)
	}
	kind = chat_conversation_kind(row.conversation_kind, string(row.group_name), count)
	if kind != .DIRECT || row.pending_confirmation {return kind, ""}
	if have_members {
		for id in ids {if id != "" && !strings.equal_fold(id, account) {return kind, id}}
		return kind, ""
	}
	peer = string(presented.presentation.peer_id)
	if strings.equal_fold(peer, account) {peer = ""}
	return
}

// One marmot chat-list row into a UI row; shared by the rail
// (load_chat_list) and the archive page (load_archived) so both render
// identically (avatar, time, "You:" prefix, delivery tick).
row_to_ui :: proc(
	client: ^marmot.Client,
	presented: ^marmot.Presented_Chat_Row,
	account_ref: string,
	previews: map[string]^marmot.Timeline_Page = nil,
	reading_previews: map[string]string = nil,
	members: map[string][]string = nil,
) -> Chat_Row_Ui {
	row := &presented.row
	presentation := &presented.presentation
	kind, peer := chat_row_identity(presented, account_ref, members)
	avatar_key := string(row.group_id_hex)
	if kind == .DIRECT {
		if row.pending_confirmation &&
		   presentation.peer_id != nil {avatar_key = string(presentation.peer_id)}
		if peer != "" {avatar_key = peer}
	}
	title: string
	switch presentation.title.tag {
	case .Literal:
		title = string(presentation.title.body.literal)
	case .Unnamed_Group:
		title = tr("Unnamed group")
	case .Unavailable_Conversation:
		title = tr("Unavailable conversation")
	}
	// MDK presents a DM under its peer's name; your nickname for them wins.
	if kind == .DIRECT && g_ui != nil {
		if nick := g_ui.nicknames[avatar_key]; len(nick) > 0 {title = nick}
	}
	avatar_url, image_hash: string
	switch presentation.avatar.tag {
	case .Remote_Image:
		if kind == .DIRECT || presentation.avatar_source == .Group {
			avatar_url = string(presentation.avatar.body.remote.url)
		}
	case .Encrypted_Group_Image:
		image_hash = string(presentation.avatar.body.encrypted.image.image_hash_hex)
	case .Placeholder:
	}

	preview: string
	mine, blocked: bool
	if row.last_message != nil {
		mine = message_is_mine(nil, row.last_message.sender, account_ref)
		blocked =
			!mine &&
			row.last_message.sender != nil &&
			g_ui != nil &&
			g_ui.blocked[string(row.last_message.sender)]
	}
	if prepared, read := reading_previews[string(row.group_id_hex)]; read {
		preview = prepared
	} else {
		blocked_senders: map[string]bool
		if g_ui != nil {blocked_senders = g_ui.blocked}
		preview, _ = chat_row_preview(
			client,
			row,
			account_ref,
			blocked_senders,
			previews[string(row.group_id_hex)],
		)
	}
	if kind == .GROUP &&
	   !mine &&
	   !blocked &&
	   preview != "" &&
	   row.last_message != nil &&
	   row.last_message.sender != nil &&
	   record_class(row.last_message.kind, string(row.last_message.plaintext)) == .Message {
		// A group row names who sent its last message, when that is a message.
		if sender := sender_label(string(row.last_message.sender)); sender != "" {
			preview = fmt.tprintf(tr("%s: %s"), sender, preview)
		}
	}

	tick := marmot.Delivery_State.NOT_APPLICABLE
	if row.last_message != nil {
		tick = row.last_message.delivery_state
	}

	return Chat_Row_Ui {
		group_id            = strings.clone(string(row.group_id_hex)),
		conversation_kind   = kind,
		group_read_activity = row.conversation_kind ==
			.GROUP || strings.trim(string(row.group_name), " ") != "",
		peer_hex            = strings.clone(peer),
		title               = strings.clone(title),
		preview             = strings.clone(preview),
		at                  = format_activity(row.activity_sort_at),
		activity_at         = row.activity_sort_at,
		unread              = row.unread_count,
		archived            = row.archived,
		pending             = row.pending_confirmation,
		stable              = row.lifecycle_state == .STABLE,
		tick                = tick,
		first_unread        = strings.clone(
			row.first_unread_message_id_hex != nil ? string(row.first_unread_message_id_hex) : "",
		),
		avatar_url          = strings.clone(avatar_url),
		avatar_key          = strings.clone(avatar_key),
		image_hash          = strings.clone(image_hash),
		// marmot's mute OR the local one from the row menu (its C API
		// has no mute setter); the notification gate reads this flag.
		muted               = row.muted || (g_prefs != nil && g_prefs.muted_ids[string(row.group_id_hex)]),
		last_id             = strings.clone(
			row.last_message != nil && row.last_message.message_id_hex != nil ? string(row.last_message.message_id_hex) : "",
		),
		last_kind           = row.last_message != nil ? row.last_message.kind : 0,
		last_mine           = mine,
		last_blocked        = blocked,
	}
}

load_chat_list :: proc(client: ^marmot.Client, account_ref: string, ui: ^Ui_State) -> bool {
	chat_list_revision += 1 // an older background read cannot replace this explicit refresh
	job := Chat_List_Work {
		client  = client,
		account = strings.clone_to_cstring(account_ref),
	}
	defer chat_list_free(&job)
	chat_list_snapshot(&job, ui)
	chat_list_read(&job)
	chat_list_apply(ui, &job)
	return job.err == "" && job.rows != nil
}

@(private)
chat_list_apply :: proc(ui: ^Ui_State, job: ^Chat_List_Work) {
	// Adopt the job's member lists even on failure: the flag records that
	// they were asked for, so a failing read isn't retried every frame.
	chat_members_free(&ui.chat_members)
	ui.chat_members = job.members
	job.members = nil
	ui.chat_members_read = job.read_members
	if job.err != "" {
		set_status(ui, fmt.aprintf(tr("Chat list failed: %s"), job.err), .Error)
		return
	}
	rows := job.rows
	if rows == nil {return}
	selected_group: string
	search_only := false
	if ui.selected >= 0 && ui.selected < len(ui.chats) {
		selected := &ui.chats[ui.selected]
		selected_group = selected.group_id
		search_only = selected.search_only
	}
	fresh := make([dynamic]Chat_Row_Ui, 0, int(rows.rows_len))
	for i in 0 ..< rows.rows_len {
		append(
			&fresh,
			row_to_ui(
				job.client,
				&rows.rows[i],
				string(job.account),
				job.previews,
				job.reading_previews,
				ui.chat_members,
			),
		)
	}
	chats_replace(&ui.chats, fresh)
	if search_only {
		gs_keep_open_chat(ui, selected_group)
	}
	ui.selected = -1
	if selected_group != "" {
		for chat, i in ui.chats {
			if chat.group_id == selected_group {
				ui.selected = i
				break
			}
		}
	}
	ui.my_pic_url = profile_info(job.client, string(job.account)).pic_url
	queue_group_pics(ui, job.client)

	// Keep the rail-filter flags aligned with the fresh row set.
	refresh_filter_hits(job.client, ui)
}
