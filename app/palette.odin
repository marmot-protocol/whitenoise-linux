// Command palette (Ctrl+P): one list
// of everything the chrome can do, filtered as you type, driven from
// the keyboard. Matching folds case and diacritics, then tries an ordered
// subsequence, so "gtse" finds "Go to settings".
package main

import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

Cmd :: enum {
	Goto_Chats,
	Goto_People,
	Goto_Archive,
	Goto_Settings,
	Goto_Profile,
	New_Chat,
	Notes_To_Self,
	Search_All,
	Toggle_Unread,
	Toggle_Rail,
	Toggle_Members,
	Set_General,
	Set_Network,
	Set_Keys,
	Set_Appearance,
	Set_Notifications,
	Set_Storage,
	Set_Advanced,
	Set_About,
	Next_Theme,
	Next_Accent,
	Toggle_Centered,
	Toggle_Dev,
	Zoom_In,
	Zoom_Out,
	Zoom_Reset,
	Shortcuts,
	Lock_Now,
	Sign_Out,
}

COMMANDS := [Cmd]struct {
	label: string,
	hint:  string,
} {
	.Goto_Chats        = {N_("Go to chats"), N_("Navigate")},
	.Goto_People       = {N_("Go to people"), N_("Navigate")},
	.Goto_Archive      = {N_("Go to archive"), N_("Navigate")},
	.Goto_Settings     = {N_("Go to settings"), N_("Navigate")},
	.Goto_Profile      = {N_("Go to your profile"), N_("Navigate")},
	.New_Chat          = {N_("New chat"), N_("Chats")},
	.Notes_To_Self     = {N_("Notes to self"), N_("Chats")},
	.Search_All        = {N_("Search all chats"), "Ctrl K"},
	.Toggle_Unread     = {N_("Filter unread chats"), N_("Chats")},
	.Toggle_Rail       = {N_("Collapse the chat list"), N_("View")},
	.Toggle_Members    = {N_("Show group members"), N_("View")},
	.Set_General       = {N_("Settings: general"), N_("Settings")},
	.Set_Network       = {N_("Settings: network and relays"), N_("Settings")},
	.Set_Keys          = {N_("Settings: keys and identity"), N_("Settings")},
	.Set_Appearance    = {N_("Settings: appearance"), N_("Settings")},
	.Set_Notifications = {N_("Settings: notifications"), N_("Settings")},
	.Set_Storage       = {N_("Settings: storage"), N_("Settings")},
	.Set_Advanced      = {N_("Settings: advanced"), N_("Settings")},
	.Set_About         = {N_("Settings: about"), N_("Settings")},
	.Next_Theme        = {N_("Next theme"), N_("Appearance")},
	.Next_Accent       = {N_("Next accent color"), N_("Appearance")},
	.Toggle_Centered   = {N_("Center the conversation"), N_("Appearance")},
	.Toggle_Dev        = {N_("Toggle developer mode"), N_("Advanced")},
	.Zoom_In           = {N_("Zoom in"), "Ctrl +"},
	.Zoom_Out          = {N_("Zoom out"), "Ctrl -"},
	.Zoom_Reset        = {N_("Reset zoom"), "Ctrl 0"},
	.Shortcuts         = {N_("Keyboard shortcuts"), N_("Help")},
	.Lock_Now          = {N_("Lock now"), N_("Account")},
	.Sign_Out          = {N_("Sign out"), N_("Account")},
}

PAL_ROWS_MAX :: 9

// Display name of a stored account, falling back to its deterministic alias.
account_label :: proc(ui: ^Ui_State, hex_id: string) -> string {
	for account in ui.accounts {
		if account.id_hex == hex_id {
			return account.name
		}
	}
	return profile_label(nil, hex_id)
}

pal_open_modal :: proc(ui: ^Ui_State) {
	ui.mi_open = false
	ui.pal_open = true
	stagger_arm(nendo.id("PalModal").id)
	ui.focus = .Pal
	ui.pal_sel = 0
	clear(&ui.pal_input)
	pal_refresh(ui)
}

pal_close :: proc(ui: ^Ui_State) {
	ui.pal_open = false
	ui.focus = .Compose
	// The hits stay: the modal is still on screen animating out, and
	// the next open refreshes them anyway.
}

// Rebuild the match list: a folded substring hit ranks above a folded
// subsequence one, declaration order breaks ties.
pal_refresh :: proc(ui: ^Ui_State) {
	clear(&ui.pal_hits)
	needle := gs_fold(strings.trim_space(string(ui.pal_input[:])))

	for tier in 0 ..< 2 {
		for cmd in Cmd {
			if single_pane() && (cmd == .Toggle_Rail || cmd == .Toggle_Centered) {continue}
			if cmd == .Toggle_Members &&
			   (ui.selected < 0 || ui.page != .Chats || selected_chat_is_dm(ui)) {continue}
			hay := gs_fold(fmt.tprintf("%s %s", COMMANDS[cmd].label, COMMANDS[cmd].hint))
			exact := strings.contains(hay, needle)
			if len(needle) == 0 {
				if tier == 0 {
					append(&ui.pal_hits, int(cmd))
				}
				continue
			}
			if tier == 0 && !exact {
				continue
			}
			if tier == 1 && (len(needle) > 4 || exact || !gs_subseq(hay, needle)) {
				continue
			}
			append(&ui.pal_hits, int(cmd))
		}
	}
	ui.pal_sel = clamp(ui.pal_sel, 0, max(len(ui.pal_hits) - 1, 0))
}

palette_modal :: proc(ui: ^Ui_State) {
	max_h := modal_h(620)
	if !single_pane() {max_h = min(max_h, max(1, f32(rl.GetScreenHeight()) / UI_ZOOM - 120))}
	if nendo.box(nendo.id("PalModal"))(
	{
		width = nendo.fixed(modal_w(nendo.id("PalModal"), 520)),
		height = nendo.fit(max = max_h),
		direction = .Column,
		padding = nendo.pad(14),
		gap = 8,
		color = CARD,
		radius = rr(14),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 15,
			offset = {0, (single_pane() ? 12 : 90) + rise(nendo.id("PalModal"), 12)},
			attach = {element = .Center_Top, parent = .Center_Top},
		},
	},
	) {
		if nendo.box(nendo.id("PalHeader"))({width = nendo.grow(), gap = 8}) {
			if nendo.box(nendo.id("PalInput"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? tap_min() : 38),
				padding = {left = 12, right = 12},
				gap = 8,
				align = {y = .Center},
				color = ROW_BG,
				radius = rr(9),
				border = {color = ACCENT, width = bw()},
				clip = {x = true},
			},
			) {
				nendo.text("›", {font = FONT_TITLE, size = 16, color = ACCENT})
				field_text(
					ui,
					"PalInput",
					&ui.pal_input,
					tr("Type a command"),
					ui.focus == .Pal,
					14,
					TEXT_LO,
				)
			}
			if tap_size() {
				if nendo.box(nendo.id("PalClose"))(
				{
					width = nendo.fixed(44),
					height = nendo.fixed(44),
					align = {x = .Center, y = .Center},
					color = hovered() ? HOVER : ROW_BG,
					radius = rr(9),
				},
				) {
					nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 14, color = TEXT})
				}
			}
		}
		if nendo.box(nendo.id("PalResults"))(
		{
			width = nendo.grow(),
			height = nendo.fit(max = max(1, max_h - (tap_size() ? 110 : 100))),
			direction = .Column,
			gap = 8,
			clip = {y = true, scroll = true},
		},
		) {
			scrollbar(nendo.id("PalResults"), 16)

			if len(ui.pal_hits) == 0 {
				nendo.text(
					tr("No command matches."),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
			}
			// Only the window around the selection renders: the list is
			// short and nendo has no virtualization.
			first := clamp(
				ui.pal_sel - PAL_ROWS_MAX + 1,
				0,
				max(len(ui.pal_hits) - PAL_ROWS_MAX, 0),
			)
			last := min(first + PAL_ROWS_MAX, len(ui.pal_hits))
			if tap_size() {first, last = 0, len(ui.pal_hits)}
			for i in first ..< last {
				cmd := Cmd(ui.pal_hits[i])
				selected := i == ui.pal_sel
				// Rows cascade in from the top of the visible window.
				arrived := stagger(nendo.id("PalModal").id, i - first)
				if nendo.box(nendo.id("PalRow", u32(i)))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = tap_size() ? tap_min() : 0),
					padding = {left = 12, right = 12, top = 8, bottom = 8},
					gap = 10,
					align = {y = .Center},
					color = fade(selected ? SELECTED : (hovered() ? HOVER : {}), arrived),
					radius = rr(8),
				},
				) {
					nendo.text(
						tr(COMMANDS[cmd].label),
						{
							font = FONT_BODY,
							size = 13,
							color = fade(selected ? ACCENT : TEXT, arrived),
						},
					)
					if !single_pane() {
						if nendo.box(nendo.id("PalRowGap", u32(i)))({width = nendo.grow()}) {}
						nendo.text(
							tr(COMMANDS[cmd].hint),
							{
								font = FONT_MONO,
								size = 10,
								color = fade(TEXT_LO, arrived),
								spacing = 1,
							},
						)
					}
				}
			}
		}

		if nendo.box(nendo.id("PalFoot"))(
		{width = nendo.grow(), gap = 12, padding = {left = 4, top = 2}},
		) {
			if !tap_size() {
				nendo.text(
					tr("↑↓ move   ⏎ run   esc close"),
					{font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 1},
				)
			}
			if nendo.box(nendo.id("PalFootGap"))({width = nendo.grow()}) {}
			if !tap_size() {
				nendo.text(
					fmt.tprintf("%d", len(ui.pal_hits)),
					{font = FONT_MONO, size = 10, color = TEXT_LO},
				)
			}
		}
	}
}

handle_palette :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) || clicked("PalClose") {
		pal_close(ui)
		return
	}
	if key_hit(.DOWN) && len(ui.pal_hits) > 0 {
		ui.pal_sel = (ui.pal_sel + 1) % len(ui.pal_hits)
	}
	if key_hit(.UP) && len(ui.pal_hits) > 0 {
		ui.pal_sel = (ui.pal_sel + len(ui.pal_hits) - 1) % len(ui.pal_hits)
	}
	if rl.IsKeyPressed(.ENTER) && len(ui.pal_hits) > 0 {
		cmd := Cmd(ui.pal_hits[ui.pal_sel])
		pal_close(ui)
		run_command(ui, client, cmd)
		return
	}

	before := strings.clone(string(ui.pal_input[:]), context.temp_allocator)
	edit_text(ui, &ui.pal_input)
	if string(ui.pal_input[:]) != before {
		ui.pal_sel = 0
		pal_refresh(ui)
	}

	if field_mouse(ui, &ui.pal_input, "PalInput", 14) {
		ui.focus = .Pal
		return
	}
	if !mouse_released() {
		return
	}
	for i in 0 ..< len(ui.pal_hits) {
		if nendo.pointer_over(nendo.id("PalRow", u32(i))) {
			cmd := Cmd(ui.pal_hits[i])
			pal_close(ui)
			run_command(ui, client, cmd)
			return
		}
	}
	if !nendo.pointer_over(nendo.id("PalModal")) {
		pal_close(ui)
	}
}

// Every palette action, in one place. Page loads mirror what the nav
// clicks do (handle_pages).
run_command :: proc(ui: ^Ui_State, client: ^marmot.Client, cmd: Cmd) {
	goto_page :: proc(ui: ^Ui_State, client: ^marmot.Client, page: Page) {
		whip_workspace_navigation(ui)
		ui.page = page
		switch page {
		case .Chats:
		case .Contacts:
			load_contacts(client, ui, .Details)
		case .Archived:
			load_archived(client, ui)
		case .Settings:
			settings_open(
				ui,
				client,
				ui.settings_section,
				tab = ui.settings_tab,
				level = ui.settings_level,
			)
		case .Profile:
			load_profile(client, ui)
		}
	}

	switch cmd {
	case .Goto_Chats:
		goto_page(ui, client, .Chats)
	case .Goto_People:
		goto_page(ui, client, .Contacts)
	case .Goto_Archive:
		goto_page(ui, client, .Archived)
	case .Goto_Settings:
		goto_page(ui, client, .Settings)
	case .Goto_Profile:
		goto_page(ui, client, .Profile)
	case .New_Chat:
		ui.page = .Chats
		open_new_chat(ui, client)
	case .Notes_To_Self:
		open_notes(ui, client)
	case .Search_All:
		gs_open_modal(ui)
	case .Toggle_Unread:
		ui.page = .Chats
		ui.chat_filter = ui.chat_filter == .Unread ? .Chats : .Unread
		ui.chat_folder = ""
	case .Toggle_Rail:
		toggle_rail(ui)
	case .Toggle_Members:
		if ui.selected >= 0 {
			if ui.show_members {
				close_group_info(ui)
			} else {
				open_group_info(ui, client, .Members)
			}
		}
	case .Set_General:
		settings_open(ui, client, .General)
	case .Set_Network:
		settings_open(ui, client, .Network)
	case .Set_Keys:
		settings_open(ui, client, .Keys)
	case .Set_Appearance:
		settings_open(ui, client, .Appearance)
	case .Set_Notifications:
		settings_open(ui, client, .Notifications)
	case .Set_Storage:
		settings_open(ui, client, .Storage)
	case .Set_Advanced:
		settings_open(ui, client, .Advanced)
	case .Set_About:
		settings_open(ui, client, .About)
	case .Next_Theme:
		theme_switch(ui, (ui.theme + 1) % max(len(theme_packs), 1), ui.accent)
		toast(ui, tr(theme_packs[ui.theme].name))
	case .Next_Accent:
		theme_switch(ui, ui.theme, (ui.accent + 1) % len(active_pack(ui).accent_names))
		toast(ui, active_pack(ui).accent_names[ui.accent])
	case .Toggle_Centered:
		flip(ui, &ui.prefs.centered_chat)
	case .Toggle_Dev:
		flip(ui, &ui.prefs.dev_mode)
		toast(ui, ui.prefs.dev_mode ? tr("Developer mode on") : tr("Developer mode off"))
	case .Zoom_In, .Zoom_Out, .Zoom_Reset:
		ui.prefs.zoom_pct =
			cmd == .Zoom_Reset ? 100 : ui.prefs.zoom_pct + (cmd == .Zoom_In ? 10 : -10)
		apply_zoom(ui)
		save_settings(ui)
	case .Shortcuts:
		ui.shortcuts_open = true
	case .Sign_Out:
		confirm_ask(ui, .Sign_Out, ui.account_ref, account_label(ui, ui.account_ref))
	case .Lock_Now:
		lock_now(ui)
	}
}
