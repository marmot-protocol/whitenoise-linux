// Command palette (Ctrl+P), the slint fuzzy action launcher: one list
// of everything the chrome can do, filtered as you type, driven from
// the keyboard. Matching reuses the global search's fold + subsequence
// pair, so "gtse" finds "Go to settings".
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
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
	Sign_Out,
}

COMMANDS := [Cmd]struct {
	label: string,
	hint:  string,
} {
	.Goto_Chats        = {N_("Go to chats"), "Navigate"},
	.Goto_People       = {N_("Go to people"), "Navigate"},
	.Goto_Archive      = {N_("Go to archive"), "Navigate"},
	.Goto_Settings     = {N_("Go to settings"), "Navigate"},
	.Goto_Profile      = {N_("Go to your profile"), "Navigate"},
	.New_Chat          = {N_("New chat"), "Chats"},
	.Notes_To_Self     = {N_("Notes to self"), "Chats"},
	.Search_All        = {N_("Search all chats"), "Ctrl K"},
	.Toggle_Unread     = {N_("Filter unread chats"), "Chats"},
	.Toggle_Rail       = {N_("Collapse the chat list"), "View"},
	.Toggle_Members    = {N_("Show group members"), "View"},
	.Set_General       = {N_("Settings: general"), "Settings"},
	.Set_Network       = {N_("Settings: network and relays"), "Settings"},
	.Set_Keys          = {N_("Settings: keys and identity"), "Settings"},
	.Set_Appearance    = {N_("Settings: appearance"), "Settings"},
	.Set_Notifications = {N_("Settings: notifications"), "Settings"},
	.Set_Storage       = {N_("Settings: storage"), "Settings"},
	.Set_Advanced      = {N_("Settings: advanced"), "Settings"},
	.Set_About         = {N_("Settings: about"), "Settings"},
	.Next_Theme        = {N_("Next theme"), "Appearance"},
	.Next_Accent       = {N_("Next accent color"), "Appearance"},
	.Toggle_Centered   = {N_("Center the conversation"), "Appearance"},
	.Toggle_Dev        = {N_("Toggle developer mode"), "Advanced"},
	.Zoom_In           = {N_("Zoom in"), "Ctrl +"},
	.Zoom_Out          = {N_("Zoom out"), "Ctrl -"},
	.Zoom_Reset        = {N_("Reset zoom"), "Ctrl 0"},
	.Shortcuts         = {N_("Keyboard shortcuts"), "Help"},
	.Sign_Out          = {N_("Sign out"), "Account"},
}

PAL_ROWS_MAX :: 9

// Display name of a stored account, falling back to its short hex.
account_label :: proc(ui: ^Ui_State, hex_id: string) -> string {
	for id, i in ui.account_ids {
		if id == hex_id {
			return ui.accounts[i]
		}
	}
	return short_hex(hex_id)
}

pal_open_modal :: proc(ui: ^Ui_State) {
	ui.pal_open = true
	stagger_arm(clay.ID("PalModal").id)
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
			if tier == 1 && (exact || !gs_subseq(hay, needle)) {
				continue
			}
			append(&ui.pal_hits, int(cmd))
		}
	}
	ui.pal_sel = clamp(ui.pal_sel, 0, max(len(ui.pal_hits) - 1, 0))
}

palette_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PalModal"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("PalModal"), 520))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(14),
			childGap = 8,
		},
		backgroundColor = CARD,
		cornerRadius = rr(14),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 15,
			offset = {0, 90 + rise(clay.ID("PalModal"), 12)},
			attachment = {element = .CenterTop, parent = .CenterTop},
		},
	},
	) {
		if clay.UI(clay.ID("PalInput"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(38)},
				padding = {left = 12, right = 12},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(9),
			border = {color = ACCENT, width = bw()},
		},
		) {
			clay.Text("›", {fontId = FONT_TITLE, fontSize = 16, textColor = ACCENT})
			field_text(
				ui,
				"PalInput",
				&ui.pal_input,
				"Type a command",
				ui.focus == .Pal,
				14,
				TEXT_LO,
			)
		}

		if len(ui.pal_hits) == 0 {
			clay.Text(
				tr("No command matches."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		// Only the window around the selection renders: the list is
		// short and clay has no virtualization.
		first := clamp(ui.pal_sel - PAL_ROWS_MAX + 1, 0, max(len(ui.pal_hits) - PAL_ROWS_MAX, 0))
		for i in first ..< min(first + PAL_ROWS_MAX, len(ui.pal_hits)) {
			cmd := Cmd(ui.pal_hits[i])
			selected := i == ui.pal_sel
			// Rows cascade in from the top of the visible window.
			arrived := stagger(clay.ID("PalModal").id, i - first)
			if clay.UI(clay.ID("PalRow", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = {left = 12, right = 12, top = 8, bottom = 8},
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = fade(selected ? SELECTED : (hovered() ? HOVER : {}), arrived),
				cornerRadius = rr(8),
			},
			) {
				clay.Text(
					tr(COMMANDS[cmd].label),
					{
						fontId = FONT_BODY,
						fontSize = 13,
						textColor = fade(selected ? ACCENT : TEXT, arrived),
					},
				)
				if clay.UI(clay.ID("PalRowGap", u32(i)))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				clay.Text(
					COMMANDS[cmd].hint,
					{
						fontId = FONT_MONO,
						fontSize = 10,
						textColor = fade(TEXT_LO, arrived),
						letterSpacing = 1,
					},
				)
			}
		}

		if clay.UI(clay.ID("PalFoot"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 12,
				padding = {left = 4, top = 2},
			},
		},
		) {
			clay.Text(
				"↑↓ move   ⏎ run   esc close",
				{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 1},
			)
			if clay.UI(clay.ID("PalFootGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			clay.Text(
				fmt.tprintf("%d", len(ui.pal_hits)),
				{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO},
			)
		}
	}
}

handle_palette :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
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
		if clay.PointerOver(clay.ID("PalRow", u32(i))) {
			cmd := Cmd(ui.pal_hits[i])
			pal_close(ui)
			run_command(ui, client, cmd)
			return
		}
	}
	if !clay.PointerOver(clay.ID("PalModal")) {
		pal_close(ui)
	}
}

// Every palette action, in one place. Page loads mirror what the nav
// clicks do (handle_pages).
run_command :: proc(ui: ^Ui_State, client: ^marmot.Client, cmd: Cmd) {
	goto_page :: proc(ui: ^Ui_State, client: ^marmot.Client, page: Page) {
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
	}
	goto_section :: proc(ui: ^Ui_State, client: ^marmot.Client, section: Settings_Section) {
		ui.page = .Settings
		ui.settings_section = section
		switch section {
		case .Network, .Keys:
			load_profile(client, ui)
			if section == .Keys {
				fetch_key_packages(ui, client)
			}
		case .Advanced:
			load_advanced(ui, client)
		case .General, .Speech, .Appearance, .Notifications, .Storage, .About, .Debug, .KP:
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
		ui.new_chat_open = true
		ui.focus = .NC_Member
	case .Notes_To_Self:
		open_notes(ui, client)
	case .Search_All:
		gs_open_modal(ui)
	case .Toggle_Unread:
		ui.page = .Chats
		ui.unread_only = !ui.unread_only
	case .Toggle_Rail:
		flip(ui, &ui.prefs.rail_collapsed)
	case .Toggle_Members:
		if ui.selected >= 0 {
			ui.group_files_open = false
			ui.show_members = !ui.show_members
			if ui.show_members {
				load_members(client, ui)
			}
		}
	case .Set_General:
		goto_section(ui, client, .General)
	case .Set_Network:
		goto_section(ui, client, .Network)
	case .Set_Keys:
		goto_section(ui, client, .Keys)
	case .Set_Appearance:
		goto_section(ui, client, .Appearance)
	case .Set_Notifications:
		goto_section(ui, client, .Notifications)
	case .Set_Storage:
		goto_section(ui, client, .Storage)
	case .Set_Advanced:
		goto_section(ui, client, .Advanced)
	case .Set_About:
		goto_section(ui, client, .About)
	case .Next_Theme:
		theme_switch(ui, (ui.theme + 1) % max(len(theme_packs), 1), ui.accent)
		toast(ui, theme_packs[ui.theme].name)
	case .Next_Accent:
		theme_switch(ui, ui.theme, (ui.accent + 1) % len(ACCENT_NAMES))
		toast(ui, ACCENT_NAMES[ui.accent])
	case .Toggle_Centered:
		flip(ui, &ui.prefs.centered_chat)
	case .Toggle_Dev:
		flip(ui, &ui.prefs.dev_mode)
		toast(ui, ui.prefs.dev_mode ? "Developer mode on" : "Developer mode off")
	case .Zoom_In, .Zoom_Out, .Zoom_Reset:
		ui.prefs.zoom_pct =
			cmd == .Zoom_Reset ? 100 : ui.prefs.zoom_pct + (cmd == .Zoom_In ? 10 : -10)
		apply_zoom(ui)
		save_settings(ui)
	case .Shortcuts:
		ui.page = .Settings
		ui.shortcuts_open = true
	case .Sign_Out:
		confirm_ask(ui, .Sign_Out, ui.account_ref, account_label(ui, ui.account_ref))
	}
}
