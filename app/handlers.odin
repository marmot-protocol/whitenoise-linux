package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

handle_login :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || (len(ui.accounts) > 0 && !ui.add_account_open) {
		return
	}
	if auth_job != nil {
		return // a sign-in is in flight; the pane shows its progress
	}

	edit_text(ui, &ui.login_input)

	if ui.add_account_open && rl.IsKeyPressed(.ESCAPE) {
		ui.add_account_open = false
		clear(&ui.login_input)
		return
	}

	if clicked("LoginBackup") {
		ui.picking_backup = true
		rl.OpenFileDialog(false)
		return
	}
	if clicked("LoginImportBtn") {
		ui.login_import = true
		return
	}
	if clicked("LoginBack") {
		ui.login_import = false
		clear(&ui.login_input)
		return
	}

	submitted := ui.login_import && (rl.IsKeyPressed(.ENTER) || clicked("LoginGo"))
	if submitted && len(ui.login_input) > 0 {
		start_auth(ui, client, string(ui.login_input[:]))
	} else if !ui.login_import && clicked("LoginCreate") {
		start_auth(ui, client, "")
	}
}

// Chat selection clicks and the composer.
// ponytail: send_text blocks the UI thread; worker thread comes with
// the subscriptions phase.
// The input buffer that currently receives typed characters.
active_buf :: proc(ui: ^Ui_State) -> ^[dynamic]u8 {
	if ui.issues_open && ui.focus == .Issue_Search {return &ui.issue_search}
	if ui.theme_edit && len(ui.theme_fields) > 0 {
		return &ui.theme_fields[clamp(ui.theme_edit_idx, 0, len(ui.theme_fields) - 1)]
	}
	if ui.new_chat_open {
		return ui.focus == .NC_Name ? &ui.nc_name : &ui.nc_member
	}
	if ui.page == .Profile {
		#partial switch ui.focus {
		case .Relay:
			return &ui.relay_input
		case .About:
			return &ui.about_input
		case .Nip05:
			return &ui.nip05_input
		case .Lud16:
			return &ui.lud16_input
		}
		return &ui.name_input
	}
	if ui.show_members {
		if ui.focus == .Nick {
			return &ui.nick_input
		}
		if ui.focus == .Desc {
			return &ui.desc_input
		}
		return ui.focus == .Rename ? &ui.rename_input : &ui.invite_input
	}
	if ui.search_open {
		return &ui.search_input
	}
	if ui.focus == .Filter {
		return &ui.sidebar_filter
	}
	if ui.focus == .Nick {
		return &ui.nick_input
	}
	if ui.focus == .KP {
		return &ui.kp_input
	}
	if ui.focus == .Inbox {
		return &ui.inbox_input
	}
	if ui.focus == .Fetch {
		return &ui.fetch_input
	}
	if ui.focus == .Client {
		return &ui.client_input
	}
	if ui.focus == .ExportPw {
		return &ui.export_pw
	}
	if ui.focus == .BackupPw {
		return &ui.backup_pw
	}
	if ui.focus == .EmojiName {
		return &ui.emoji_name
	}
	return &ui.compose
}

handle_chat :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if preview_shown {return}
	// A shared theme is taken only on the tap: adopt_theme writes it
	// under the data dir and returns its slot, which then applies.
	for msg, i in ui.messages {
		if len(msg.theme_name) == 0 || !clicked(fmt.tprintf("ThemeApply%d", u32(i))) {
			continue
		}
		slot := adopt_theme(msg.theme_toml)
		if slot < 0 {
			ui.client_status = strings.clone(
				tr("Couldn't use that theme. It isn't a theme this version reads."),
			)
			return
		}
		ui.theme = slot
		apply_theme(ui.theme, ui.accent)
		save_settings(ui)
		toast(ui, "Theme applied")
		return
	}

	if client == nil || len(ui.accounts) == 0 {
		return
	}

	// The peer popup owns input while open (handle_pages runs it).
	if ui.peer_open {
		return
	}

	// The get-started checklist stands in for the timeline until the
	// account has a chat.
	if ui.selected < 0 && len(ui.chats) == 0 && handle_onboard(ui, client) {
		return
	}

	// New chat flow captures everything while open.
	if clicked("NewChatBtn") {
		ui.new_chat_open = true
		ui.focus = .NC_Member
		return
	}
	if ui.new_chat_open {
		handle_new_chat(ui, client)
		return
	}
	// Forward picker captures everything while open (before the rail
	// row clicks, so a pick can't also select the chat under it).
	if ui.fwd_open {
		handle_forward(ui, client)
		return
	}
	// Openverse image-search modal, same early capture.
	if ui.ov_open {
		handle_openverse(ui, client)
		return
	}
	// Create-poll modal, same early capture.
	if ui.poll_open {
		handle_poll(ui, client)
		return
	}

	// The rail row menu and its folder modal capture everything while
	// open (before the row clicks, so a menu click can't also select
	// the chat under it).
	if ui.row_menu >= 0 {
		handle_row_menu(ui, client)
		return
	}
	if ui.folder_open {
		handle_folder_modal(ui, client)
		return
	}
	if ui.page == .Chats && (rl.IsMouseButtonPressed(.RIGHT) || long_pressed) {
		for _, i in ui.chats {
			if clay.PointerOver(clay.ID("ChatRow", u32(i))) {
				open_row_menu(ui, i)
				return
			}
		}
	}

	if mouse_released() {
		for _, i in ui.chats {
			if clay.PointerOver(clay.ID("ChatMenu", u32(i))) {
				open_row_menu(ui, i)
				return
			}
			if clay.PointerOver(clay.ID("ChatArch", u32(i))) {
				set_archived(ui, client, ui.chats[i].group_id, true)
				return
			}
			if clay.PointerOver(clay.ID("ChatRow", u32(i))) {
				select_chat(ui, client, i)
				break
			}
		}
		// Tap a failed optimistic row to retry the send.
		for &p, i in ui.pending {
			if clay.PointerOver(clay.ID("MessageMore", 0xF00000 + u32(i) * 8)) {
				preview_message(p.body)
				return
			}
			if !pending_can_delete(p, time.tick_now()) {
				continue
			}
			if clay.PointerOver(clay.ID("PendingDelete", u32(i))) ||
			   clay.PointerOver(clay.ID("PendingDeleteEnd", u32(i))) {
				delete_pending(ui, i)
				return
			}
			if p.failed && clay.PointerOver(clay.ID("PendingRow", u32(i))) {
				p.failed = false
				p.attempts = 0 // a manual retry restarts the auto-retry cap
				spawn_send(ui, client, &p)
				return
			}
		}
	}

	// Open edit-history modal captures everything while open.
	if ui.hist_open {
		if rl.IsKeyPressed(.ESCAPE) ||
		   (mouse_released() &&
				   (clicked("HistClose") || !clay.PointerOver(clay.ID("HistModal")))) {
			ui.hist_open = false
		}
		return
	}
	// Open raw-event modal captures everything while open.
	if ui.raw_open {
		if rl.IsKeyPressed(.ESCAPE) ||
		   (mouse_released() && (clicked("RawClose") || !clay.PointerOver(clay.ID("RawModal")))) {
			ui.raw_open = false
			return
		}
		if clicked("RawCopy") {
			copy_text(ui, ui.raw_json)
		}
		return
	}
	// Open encryption-info modal captures everything while open.
	if ui.enc_open {
		if rl.IsKeyPressed(.ESCAPE) ||
		   (mouse_released() && (clicked("EncClose") || !clay.PointerOver(clay.ID("EncModal")))) {
			ui.enc_open = false
			return
		}
		if clicked("EncCopyId") && ui.selected >= 0 {
			copy_text(ui, ui.chats[ui.selected].group_id, "Group id copied")
		}
		return
	}
	// Open mentions inbox captures everything while open.
	if ui.mi_open {
		handle_mi(ui, client)
		return
	}
	// Open message context menu captures everything while open.
	if ui.ctx_open {
		handle_ctx_menu(ui, client)
		return
	}
	if (rl.IsMouseButtonPressed(.RIGHT) || long_pressed) && ui.selected >= 0 {
		for msg, i in ui.messages {
			// A tombstone's only menu row is the dev-mode View raw.
			if msg.deleted && !ui.prefs.dev_mode {
				continue
			}
			if clay.PointerOver(clay.ID("MsgRow", u32(i))) {
				m := rl.GetMousePosition()
				ui.ctx_open = true
				ui.ctx_msg = i
				// ponytail: rough clamp from an estimated panel size;
				// measure the laid-out panel if it ever overflows.
				ui.ctx_x, ui.ctx_y = panel_pos(m.x / UI_ZOOM, m.y / UI_ZOOM, 240, 330)
				return
			}
		}
	}

	if mouse_released() {
		for name, i in ui.prefs.folders {
			if clicked_indexed("FolderFilter", u32(i)) {
				delete(ui.folder_filter)
				ui.folder_filter = strings.clone(name)
				if data := clay.GetScrollContainerData(clay.ID("ChatList")); data.found {
					data.scrollPosition.y = 0
				}
				scroll_residual = {}
				return
			}
		}
	}
	if clicked("FolderAllChip") {
		delete(ui.folder_filter)
		ui.folder_filter = ""
		if data := clay.GetScrollContainerData(clay.ID("ChatList")); data.found {
			data.scrollPosition.y = 0
		}
		scroll_residual = {}
		return
	}
	if clicked("AllPill") {
		ui.unread_only = false
		return
	}
	if clicked("UnreadPill") {
		ui.unread_only = true
		return
	}
	if field_mouse(ui, &ui.sidebar_filter, "FilterBox") {
		ui.focus = .Filter
		return
	}
	if ui.focus == .Filter {
		before := strings.clone(string(ui.sidebar_filter[:]), context.temp_allocator)
		edit_text(ui, &ui.sidebar_filter)
		if rl.IsKeyPressed(.ESCAPE) {
			clear(&ui.sidebar_filter)
			ui.focus = .Compose
		}
		// Body hits are cached, not scanned per frame; recompute only on
		// an actual text change.
		if string(ui.sidebar_filter[:]) != before {
			refresh_filter_hits(client, ui)
		}
	}

	if ui.selected < 0 {
		return
	}

	if clicked("JumpLatest") {
		if ui.tl_has_after {
			timeline_start(client, ui, "")
		}
		ui.scroll_pending = true
		return
	}
	// Infinite scroll: nearing the top of loaded history pulls in the
	// next page. The pagination anchor re-pins the viewport on the old
	// topmost row, so the trigger doesn't re-fire until the user scrolls
	// up through the new page (short content refills until it overflows).
	// A pending jump or bottom snap means the offset isn't settled yet.
	if ui.tl_has_more &&
	   !ui.search_open &&
	   len(ui.jump_id) == 0 &&
	   !ui.scroll_pending &&
	   len(thread_cur(ui)) == 0 {
		if data := clay.GetScrollContainerData(clay.ID("Timeline"));
		   data.found && data.scrollPosition.y > -TL_FETCH_MARGIN {
			timeline_paginate(ui, .Older)
		}
	}
	if ui.tl_has_after && !ui.search_open && len(ui.jump_id) == 0 && !ui.scroll_pending {
		if data := clay.GetScrollContainerData(clay.ID("Timeline"));
		   data.found &&
		   data.contentDimensions.height +
				   data.scrollPosition.y -
				   data.scrollContainerDimensions.height <
			   TL_FETCH_MARGIN {
			timeline_paginate(ui, .Newer)
		}
	}

	if clicked("IssuesBtn") && ui.issue_setting == .Enabled {
		ui.issues_open = !ui.issues_open
		ui.show_members, ui.search_open = false, false
		ui.focus = .Issue_Search
		issues_sync_route(ui, client)
		return
	}
	if clicked("SearchBtn") {ui.issues_open = false; issues_sync_route(ui, client)}
	if ui.issues_open && !ui.show_members {
		if clicked(
			"MembersBtn",
		) {ui.show_members = true; ui.issues_open = false; issues_sync_route(ui, client); load_members(client, ui); return}
		if handle_issues(ui, client) {return}
	}
	// With the webxdc modal open the page owns the keyboard: skip the
	// composer edit, or it drains the typed runes before
	// handle_web_input can forward them.
	if ui.focus != .Filter && !web_modal.open && (ui.stt.file == nil || ui.stt.message != "") {
		buf := active_buf(ui)
		edit_text(ui, buf, buf == &ui.compose)
	}
	// Thread route: back chevron pops one level; Escape does too while
	// the composer holds no draft or edit.
	if len(ui.thread_stack) > 0 {
		if clicked("ThreadBack") {
			thread_back(ui)
			return
		}
		if rl.IsKeyPressed(.ESCAPE) && len(ui.compose) == 0 && len(ui.editing) == 0 {
			thread_back(ui)
			return
		}
	}
	compose_mouse(ui)
	if ui.search_open && field_mouse(ui, &ui.search_input, "SearchBox") {
		ui.focus = .Search
		return
	}

	if ui.stt.file != nil && ui.stt.message == "" {
		if rl.IsKeyPressed(.ESCAPE) {
			stt_stop(ui)
		} else if rl.IsKeyPressed(.ENTER) {
			stt_finish(ui)
		}
		return
	}
	if clicked("DictateBtn") {
		stt_start(ui)
		return
	}
	// Voice recording swallows the composer keys while active.
	if voice.stream != nil {
		if clicked("VoiceSend") || rl.IsKeyPressed(.ENTER) {
			voice_send(ui, client)
		} else if clicked("VoiceCancel") || rl.IsKeyPressed(.ESCAPE) {
			voice_cancel()
		}
		return
	}
	if clicked("MicBtn") {
		voice_start(ui)
		return
	}

	// The effect picker captures everything while open.
	if handle_effects(ui) {
		return
	}
	if clicked("FxBtn") {
		ui.fx_open = !ui.fx_open
		return
	}
	// The effect picker captures everything while open.
	if handle_effects(ui) {
		return
	}
	if clicked("FxBtn") {
		ui.fx_open = !ui.fx_open
		return
	}
	// The effect picker captures everything while open.
	if handle_effects(ui) {
		return
	}
	if clicked("FxBtn") {
		ui.fx_open = !ui.fx_open
		return
	}
	if clicked("EmojiBtn") {
		open_picker(ui, "")
		return
	}
	if clicked("AttachBtn") {
		rl.OpenFileDialog(true)
		return
	}
	if clicked("PollBtn") {
		poll_reset(ui)
		ui.poll_open = true
		return
	}
	for _, i in ui.staged {
		if mouse_released() && clay.PointerOver(clay.ID("StagedX", u32(i))) {
			remove_staged(ui, i)
			return
		}
	}
	if clicked("MlsBadge") {
		delete(ui.enc_epoch)
		ui.enc_epoch = ""
		if ui.selected >= 0 {
			st: ^marmot.Group_Mls_State_Head
			account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
			group := strings.clone_to_cstring(
				ui.chats[ui.selected].group_id,
				context.temp_allocator,
			)
			if marmot.group_mls_state(client, account, group, &st) == .OK {
				ui.enc_epoch = fmt.aprintf("%d", st.epoch)
				marmot.app_group_mls_state_free(st)
			}
		}
		ui.enc_open = true
		return
	}
	if clicked("BellBtn") {
		mi_refresh(ui, client)
		ui.mi_open = true
		// Opening counts as seeing them; the badge clears. Cards keep
		// the unread accent from this refresh.
		for hit in ui.mi_hits {
			mi_mark_read(ui, hit.msg_id)
		}
		save_settings(ui)
		return
	}
	if clicked("MembersBtn") {
		ui.show_members = !ui.show_members
		ui.focus = .Invite
		ui.desc_editing = false
		ui.gpic_menu_open = false
		if ui.show_members {
			load_members(client, ui)
		}
		return
	}
	if clicked("SearchBtn") {
		ui.search_open = !ui.search_open
		ui.focus = ui.search_open ? .Search : .Compose
		if !ui.search_open {
			clear(&ui.search_input)
			load_timeline(client, ui)
		}
		return
	}

	// Pending-invite banner.
	if ui.chats[ui.selected].pending {
		if clicked("InviteAccept") {
			record: ^marmot.App_Group_Record
			account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
			group := strings.clone_to_cstring(
				ui.chats[ui.selected].group_id,
				context.temp_allocator,
			)
			if marmot.accept_group_invite(client, account, group, &record) == .OK {
				marmot.app_group_record_free(record)
				refresh_after_action(ui, client)
			} else {
				ui.client_status = fmt.aprintf("Couldn't accept. %s", marmot.last_error())
			}
			return
		}
		if clicked("InviteDecline") {
			confirm_ask(ui, .Decline_Invite, "", ui.chats[ui.selected].title)
			return
		}
	}

	if ui.show_members {
		handle_members(ui, client)
		return
	}

	if ui.search_open {
		if rl.IsKeyPressed(.ENTER) {
			load_timeline(client, ui, string(ui.search_input[:]))
		}
		if rl.IsKeyPressed(.ESCAPE) {
			ui.search_open = false
			ui.focus = .Compose
			clear(&ui.search_input)
			load_timeline(client, ui)
		}
		return
	}

	// Per-message row actions.
	if mouse_released() {
		for msg, i in ui.messages {
			for &secret, j in msg.secrets {
				if !msg.deleted && clay.PointerOver(clay.ID("MsgReveal", u32(i) * 4096 + u32(j))) {
					secret.open = !secret.open
					ui.messages[i].row_height = 0
					return
				}
				if !secret.open {break}
			}
			if clay.PointerOver(clay.ID("MessageMore", u32(i) * 4096)) {
				preview_message(msg.body, msg.blocks[:])
				return
			}
			if len(msg.id) == 0 {
				continue
			}
			// Any avatar opens its profile: peers get the popup, your
			// own routes to the profile page.
			if clay.PointerOver(clay.ID("MsgAvatar", u32(i))) {
				if msg.mine {
					ui.page = .Profile
					load_profile(client, ui)
				} else {
					open_peer(ui, client, msg.sender_id, msg.sender, msg.pic_url)
				}
				return
			}
			if msg.edited && clay.PointerOver(clay.ID("MsgEdited", u32(i))) {
				ui.hist_open = true
				ui.hist_msg = i
				for v in ui.hist_versions {delete(v.at); delete(v.text)}
				clear(&ui.hist_versions)
				ui.hist_original = false
				ui.hist_ticket = spawn_op(ui, client, .History, msg.id, "")
				return
			}
			// Wave button on a member_added row: greet the new member
			// with a wave emoji plus the composer's mention format.
			if len(msg.sys_added_hex) > 0 && clay.PointerOver(clay.ID("SysWave", u32(i))) {
				if npub := hex_npub(msg.sys_added_hex); len(npub) > 0 {
					queue_send(ui, client, fmt.tprintf("👋 @%s", npub))
				}
				return
			}
			if clay.PointerOver(clay.ID("MsgReact", u32(i))) {
				message_op(ui, client, .React, msg.id, "👍")
				return
			}
			if clay.PointerOver(clay.ID("MsgReply", u32(i))) {
				ui.replying = msg.id
				ui.reply_hint = fmt.aprintf(
					"%s: %s",
					msg.sender,
					msg.body[:min(len(msg.body), 60)],
				)
				return
			}
			if msg.mine && clay.PointerOver(clay.ID("MsgEdit", u32(i))) {
				stash_draft(ui) // the edit borrows the composer; keep the draft
				ed_set(ui, &ui.compose, msg.body)
				ui.editing = msg.id
				return
			}
			if msg.mine && clay.PointerOver(clay.ID("MsgDel", u32(i))) {
				confirm_ask(ui, .Delete_All, msg.id, msg_preview(msg))
				return
			}
			for chip, j in msg.reactions {
				if clay.PointerOver(clay.ID("MsgReactionChip", u32(i) * 1024 + u32(j))) {
					message_op(ui, client, chip.mine ? .Unreact : .React, msg.id, chip.emoji)
					return
				}
			}
			for _, j in msg.poll_opts {
				if clay.PointerOver(clay.ID("PollOptRow", u32(i) * 64 + u32(j))) {
					poll_vote(ui, client, &ui.messages[i], j)
					return
				}
			}
			if clay.PointerOver(clay.ID("MsgThread", u32(i))) ||
			   clay.PointerOver(clay.ID("MsgThreadChip", u32(i))) {
				thread_push(ui, msg.id)
				return
			}
		}
		if clicked("ReplyCancel") {
			ui.replying = ""
			return
		}
	}

	// The @-mention popover consumes Escape/Enter/arrows while open.
	if ui.issues_open && ui.focus != .Compose {return}
	if handle_mention(ui, client) {
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		if len(ui.editing) > 0 {
			// Cancel the edit; bring back the pre-edit draft.
			ui.editing = ""
			ed_set(ui, &ui.compose, ui.drafts[compose_draft_key(ui)])
		} else {
			clear(&ui.compose)
			drop_draft(ui)
		}
		ui.replying = ""
	}

	// Shift+Enter inserts a newline instead of sending.
	if ui.focus == .Compose && rl.IsKeyPressed(.ENTER) && shift_down() {
		ed_insert(ui, &ui.compose, "\n")
	}

	send := (rl.IsKeyPressed(.ENTER) && !shift_down()) || clicked("SendBtn") || test_send_now
	test_send_now = false
	// Staged attachments send on their own only outside an edit (an
	// edit needs text and never sends them, like the slint composer).
	if send && (len(ui.compose) > 0 || (len(ui.staged) > 0 && len(ui.editing) == 0)) {
		// The message leaves the composer rather than appearing above it.
		if len(ui.editing) == 0 && len(ui.compose) > 0 {
			send_arc(ui, string(ui.compose[:]))
		}
		if len(ui.compose) > 0 {
			if len(ui.editing) > 0 {
				queue_edit(ui, client)
				return
			} else {
				// Optimistic path: grayed row now, worker sends,
				// drain_sends settles it.
				queue_send(ui, client, string(ui.compose[:]))
			}
		}
		if len(ui.editing) == 0 {
			queue_staged(ui, client)
			clear(&ui.compose)
			drop_draft(ui)
			// The armed burst plays here and is spent. It never reaches
			// the wire: marmot-c's send_text carries no tags.
			if ui.fx_armed != 0 {
				fx_send_armed(ui)
			}
			// The armed burst plays here and is spent. It never reaches
			// the wire: marmot-c's send_text carries no tags.
			if ui.fx_armed != 0 {
				fx_send_armed(ui)
			}
			// Every send whooshes; an armed burst plays here too and is
			// spent. Effects never reach the wire: marmot-c's send_text
			// carries no tags.
			fx_send_armed(ui)
			play_sound(.Send)
		}
		ui.replying = ""
	}
}

// Staged attachments now go out through queue_staged (optimistic
// pending rows + upload worker); see the optimistic-send plumbing.

// Extension → MIME, the same guesses the slint app gets from
// mime_guess. Values are literals; Staged_File never frees them.
media_type_for :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {
		return "application/octet-stream"
	}
	switch strings.to_lower(name[dot:], context.temp_allocator) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".ogg":
		return "audio/ogg"
	case ".wav":
		return "audio/wav"
	case ".stl":
		return "model/stl"
	case ".obj":
		return "model/obj"
	case ".fbx":
		return "model/fbx"
	case ".gcode", ".gco":
		return "text/x-gcode"
	case ".pdf":
		return "application/pdf"
	case ".txt":
		return "text/plain"
	}
	return "application/octet-stream"
}

// Read one picked file into the staged row; images also decode a
// thumbnail texture (reused as the send's dim).
stage_file :: proc(ui: ^Ui_State, path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		ui.client_status = fmt.aprintf("couldn't read %s", path)
		return
	}

	base := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		base = path[slash + 1:]
	}
	stage_bytes(ui, base, data)
}

// Stage bytes already in memory (a picked file's, or a pasted
// picture's). Takes ownership of data; images also decode a thumbnail
// texture, reused as the send's dim.
stage_bytes :: proc(ui: ^Ui_State, base: string, data: []u8) {
	f := Staged_File {
		name       = strings.clone(base),
		media_type = media_type_for(base),
		data       = data,
	}
	if strings.has_prefix(f.media_type, "image/") {
		ext := strings.clone_to_cstring(
			fmt.tprintf(".%s", strings.trim_prefix(f.media_type, "image/")),
			context.temp_allocator,
		)
		image := rl.LoadImageFromMemory(ext, raw_data(data), i32(len(data)))
		if image.data != nil {
			f.tex = new(rl.Texture2D)
			f.tex^ = rl.LoadTextureFromImage(image)
			rl.UnloadImage(image)
		}
	}
	append(&ui.staged, f)
}

remove_staged :: proc(ui: ^Ui_State, index: int) {
	f := &ui.staged[index]
	if f.tex != nil {
		rl.UnloadTexture(f.tex^)
		free(f.tex)
	}
	delete(f.data)
	delete(f.name)
	ordered_remove(&ui.staged, index)
}

// Ctrl+V in the composer: a picture or files copied elsewhere stage as
// attachments instead of pasting bytes as text. False when the
// clipboard holds neither, so the caller pastes text as usual.
PASTE_IMAGES := [?]struct {
	mime: cstring,
	name: string,
} {
	{"image/png", "pasted.png"},
	{"image/jpeg", "pasted.jpg"},
	{"image/gif", "pasted.gif"},
	{"image/webp", "pasted.webp"},
}

paste_clipboard_files :: proc(ui: ^Ui_State) -> bool {
	for m in PASTE_IMAGES {
		data := rl.GetClipboardBytes(m.mime)
		if len(data) == 0 {
			delete(data)
			continue
		}
		stage_bytes(ui, m.name, data)
		return true
	}

	// A file-manager copy offers paths instead: one percent-encoded
	// "file:///home/me/a%20b.png" URI per line.
	uris := rl.GetClipboardBytes("text/uri-list", context.temp_allocator)
	staged := false
	for line in strings.split_lines(string(uris), context.temp_allocator) {
		uri := strings.trim_space(line)
		if !strings.has_prefix(uri, "file://") {
			continue
		}
		stage_file(ui, uri_unescape(uri[len("file://"):]))
		staged = true
	}
	return staged
}

// %XX → byte, for the file:// URIs on the clipboard.
uri_unescape :: proc(uri: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(uri); i += 1 {
		if uri[i] == '%' && i + 2 < len(uri) {
			if v, ok := strconv.parse_uint(uri[i + 1:i + 3], 16); ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, uri[i])
	}
	return strings.to_string(b)
}

// Open the picker anchored near the pointer, clamped on-window.
open_picker :: proc(ui: ^Ui_State, target: string) {
	m := rl.GetMousePosition()
	ui.picker_open = true
	ui.picker_target = target
	// Typing in the picker filter steals the shared edit state, so
	// remember where in the composer the pick should land.
	_, _, head := field_sel(ui, &ui.compose)
	ui.picker_return = head
	ui.focus = .Picker
	clear(&ui.picker_filter)
	ui.picker_x, ui.picker_y = panel_pos(m.x / UI_ZOOM - 200, m.y / UI_ZOOM - 452, 408, 448)
}

// Insert into the composer or react to the target, then close.
pick_emoji :: proc(ui: ^Ui_State, client: ^marmot.Client, emoji: string) {
	// Move to the front of the session recents, capped at 8.
	for recent, i in ui.recent_emoji {
		if recent == emoji {
			ordered_remove(&ui.recent_emoji, i)
			break
		}
	}
	inject_at(&ui.recent_emoji, 0, strings.clone(emoji))
	if len(ui.recent_emoji) > 8 {
		resize(&ui.recent_emoji, 8)
	}

	ui.picker_open = false
	ui.focus = .Compose
	// Settings "one-tap reactions" add: the pick lands in prefs, not
	// the composer.
	if ui.adding_quick {
		ui.adding_quick = false
		if len(ui.prefs.quick_reactions) < QUICK_MAX {
			append(&ui.prefs.quick_reactions, strings.clone(emoji))
		}
		save_settings(ui)
		return
	}
	if len(ui.picker_target) > 0 {
		message_op(ui, client, .React, ui.picker_target, emoji)
		return
	}
	// Insert at the composer caret saved when the picker opened.
	ed_begin(ui, &ui.compose)
	at := rune_snap(string(ui.compose[:]), ui.picker_return)
	ui.ed.selection = {at, at}
	edit.input_text(&ui.ed, emoji)
	ed_end(ui, &ui.compose)
}

handle_picker :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		ui.picker_open = false
		ui.focus = .Compose
		return
	}
	edit_text(ui, &ui.picker_filter)
	if field_mouse(ui, &ui.picker_filter, "PickerSearch") {
		ui.focus = .Picker
		return
	}
	if !mouse_released() {
		return
	}
	if clay.PointerOver(clay.ID("PickerSearch")) {
		return
	}
	for recent, i in ui.recent_emoji {
		if clay.PointerOver(clay.ID("PkRecent", u32(i))) {
			pick_emoji(ui, client, recent)
			return
		}
	}
	for code, i in picker_custom(ui) {
		if clay.PointerOver(clay.ID("PkCustom", u32(i))) {
			pick_emoji(ui, client, fmt.tprintf(":%s:", code))
			return
		}
	}
	for index in picker_matches(ui) {
		if clay.PointerOver(clay.ID("PkCell", u32(index))) {
			pick_emoji(ui, client, emoji_catalog[index].emoji)
			return
		}
	}
	if !clay.PointerOver(clay.ID("PickerPanel")) {
		ui.picker_open = false
		ui.focus = .Compose
	}
}

// Click/keyboard handling for the open message context menu. Mirrors
// the slint MessageContextMenu actions; anything unhandled closes it
// (the backdrop dismiss).
handle_ctx_menu :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.ctx_msg < 0 || ui.ctx_msg >= len(ui.messages) || rl.IsKeyPressed(.ESCAPE) {
		ui.ctx_open = false
		return
	}
	if rl.IsMouseButtonPressed(.RIGHT) && !clay.PointerOver(clay.ID("CtxMenu")) {
		ui.ctx_open = false
		return
	}
	if !mouse_released() {
		return
	}
	msg := ui.messages[ui.ctx_msg]
	ui.ctx_open = false

	for emoji, i in ui.prefs.quick_reactions {
		if clay.PointerOver(clay.ID("CtxQuick", u32(i))) {
			message_op(ui, client, .React, msg.id, emoji)
			return
		}
	}
	if clay.PointerOver(clay.ID("CtxReply")) {
		ui.replying = msg.id
		ui.reply_hint = fmt.aprintf("%s: %s", msg.sender, msg.body[:min(len(msg.body), 60)])
		return
	}
	if clay.PointerOver(clay.ID("CtxThread")) {
		thread_push(ui, msg.id)
		return
	}
	for att_name, i in msg.att_names {
		if i in msg.att_rejected {
			continue
		}
		if clay.PointerOver(clay.ID(fmt.tprintf("CtxSave%d", i))) {
			start_att_save({ui.chats[ui.selected].group_id, msg.id, i, att_name})
			return
		}
	}
	if clay.PointerOver(clay.ID("CtxCopy")) {
		copy_text(ui, msg.body, "Message copied")
		return
	}
	if ui.prefs.tts_enabled && clay.PointerOver(clay.ID("CtxRead")) {
		tts_read(ui, msg.body)
		return
	}
	if msg.mine && clay.PointerOver(clay.ID("CtxEdit")) {
		stash_draft(ui) // the edit borrows the composer; keep the draft
		ed_set(ui, &ui.compose, msg.body)
		ui.editing = msg.id
		return
	}
	if msg.mine && clay.PointerOver(clay.ID("CtxDelAll")) {
		confirm_ask(ui, .Delete_All, msg.id, msg_preview(msg))
		return
	}
	if clay.PointerOver(clay.ID("CtxDelMe")) {
		confirm_ask(ui, .Delete_Me, msg.id, msg_preview(msg))
		return
	}
	if ui.prefs.dev_mode && clay.PointerOver(clay.ID("CtxRaw")) {
		delete(ui.raw_json)
		ui.raw_json = raw_event_json(client, ui, msg.id)
		ui.raw_open = true
		return
	}
	if clay.PointerOver(clay.ID("CtxReact")) || clay.PointerOver(clay.ID("CtxQuickPlus")) {
		open_picker(ui, msg.id)
		return
	}
	if clay.PointerOver(clay.ID("CtxForward")) {
		ui.fwd_open = true
		ui.fwd_kind = .Message
		ui.fwd_msg = ui.ctx_msg
		clear(&ui.fwd_filter)
		ui.focus = .Fwd
		return
	}
}

// Stash the composer as the selected chat's draft (whitespace-only
// drops it). Skipped while an edit borrows the composer, so edit text
// never masquerades as a draft.
stash_draft :: proc(ui: ^Ui_State) {
	if ui.selected < 0 || len(ui.editing) > 0 {
		return
	}
	gid := compose_draft_key(ui)
	if len(strings.trim_space(string(ui.compose[:]))) == 0 {
		delete_key(&ui.drafts, gid)
		return
	}
	ui.drafts[strings.clone(gid)] = strings.clone(string(ui.compose[:]))
}

// Forget the selected chat's persisted draft (it was sent or cleared),
// so it can't resurrect on the next switch back or restart.
drop_draft :: proc(ui: ^Ui_State) {
	if ui.selected < 0 {
		return
	}
	gid := compose_draft_key(ui)
	if gid in ui.drafts {
		delete_key(&ui.drafts, gid)
		save_settings(ui)
	}
}

// Select a chat, load its timeline, and clear the unread badge by
// marking the newest message read.
select_chat :: proc(ui: ^Ui_State, client: ^marmot.Client, index: int) {
	stash_draft(ui)
	stash_staged(ui)
	ui.issues_open = false
	delete(ui.compose_issue); ui.compose_issue = ""
	thread_clear(ui) // thread roots belong to the chat being left
	ui.selected = index
	ui.staged = ui.staged_drafts[compose_draft_key(ui)]
	if compose_draft_key(ui) in ui.staged_drafts {ui.staged_drafts[compose_draft_key(ui)] = {}}
	ui.search_open = false
	ui.show_members = false
	// Stale members would feed the @-mention popover; reload lazily.
	clear(&ui.members)
	ui.focus = .Compose
	// Restore this chat's saved draft (empty if none). A switch also
	// abandons any in-progress edit; it targeted the old chat.
	ui.editing = ""
	ed_set(ui, &ui.compose, ui.drafts[ui.chats[index].group_id])
	// Snapshot the NEW MESSAGES anchor now: the mark-as-read below
	// clears the row's first_unread on the chat-list reload.
	delete(ui.unread_mark_id)
	ui.unread_mark_id = strings.clone(ui.chats[index].first_unread)
	load_timeline(client, ui)
	if !ui.timeline_loading {edit_restore(ui)}

	// Remember for "Restore last selected chat on launch".
	if ui.prefs.last_chat != ui.chats[index].group_id {
		delete(ui.prefs.last_chat)
		ui.prefs.last_chat = strings.clone(ui.chats[index].group_id)
		save_settings(ui)
	}

	ui.member_count = 0
	members: ^marmot.Group_Member_Record_List
	account_c := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group_c := strings.clone_to_cstring(ui.chats[index].group_id, context.temp_allocator)
	if marmot.group_members(client, account_c, group_c, &members) == .OK {
		ui.member_count = int(members.len)
		marmot.app_group_member_record_list_free(members)
	}

	if len(ui.messages) > 0 {
		last := ui.messages[len(ui.messages) - 1]
		row: ^marmot.Chat_List_Row
		account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
		group := strings.clone_to_cstring(ui.chats[index].group_id, context.temp_allocator)
		if marmot.mark_timeline_message_read(
			   client,
			   account,
			   group,
			   strings.clone_to_cstring(last.id, context.temp_allocator),
			   &row,
		   ) ==
		   .OK {
			marmot.chat_list_row_free(row)
			load_chat_list(client, ui.account_ref, ui)
			ui.selected = index
		}
	}
}

set_archived :: proc(ui: ^Ui_State, client: ^marmot.Client, group_id: string, archived: bool) {
	record: ^marmot.App_Group_Record
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(group_id, context.temp_allocator)
	if marmot.set_group_archived(client, account, group, archived, &record) != .OK {
		ui.client_status = fmt.aprintf(
			archived ? "Couldn't archive. %s" : "Couldn't unarchive. %s",
			marmot.last_error(),
		)
		return
	}
	marmot.app_group_record_free(record)
	ui.selected = -1
	refresh_after_action(ui, client)
}

refresh_after_action :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	selected_group: string
	if ui.selected >= 0 {
		selected_group = ui.chats[ui.selected].group_id
	}
	load_chat_list(client, ui.account_ref, ui)
	ui.selected = -1
	for chat, i in ui.chats {
		if chat.group_id == selected_group {
			ui.selected = i
			break
		}
	}
}

NOTES_TITLE :: "Notes to self"

// Select the chat with this group id. False when it isn't in the rail.
select_by_id :: proc(ui: ^Ui_State, client: ^marmot.Client, group_id: string) -> bool {
	for chat, i in ui.chats {
		if chat.group_id == group_id {
			select_chat(ui, client, i)
			return true
		}
	}
	return false
}

// Create a group and refresh the rail. `member` empty makes a solo
// group. Returns the new group id (cloned, owned by the caller) or "".
create_chat :: proc(ui: ^Ui_State, client: ^marmot.Client, name, member: string) -> string {
	group_id: cstring
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	members: []cstring
	if len(member) > 0 {
		members = []cstring{strings.clone_to_cstring(member, context.temp_allocator)}
	}

	if marmot.create_group(
		   client,
		   account,
		   strings.clone_to_cstring(name, context.temp_allocator),
		   raw_data(members),
		   uint(len(members)),
		   nil,
		   &group_id,
	   ) !=
	   .OK {
		ui.client_status = fmt.aprintf("Couldn't create the chat. %s", marmot.last_error())
		return ""
	}
	new_group := strings.clone(string(group_id))
	marmot.string_free(group_id)

	load_chat_list(client, ui.account_ref, ui)
	return new_group
}

// The user's own notepad. It is not an optional chat the user opts into:
// the rail always has one, so boot makes it when it is missing (a fresh
// account, or a vault reset) and remembers it by id, which survives a
// rename. Pinned, so it leads the rail.
ensure_notes :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 {
		return
	}
	// The id is the identity, but settings.json is best-effort (every
	// load/save failure is swallowed), and losing it must not mean a
	// second notepad every boot. So adopt a chat still carrying the
	// default title before creating anything.
	found := ""
	for chat in ui.chats {
		if chat.group_id == ui.prefs.notes_group {
			return
		}
		if chat.title == NOTES_TITLE && len(found) == 0 {
			found = chat.group_id
		}
	}
	id := len(found) > 0 ? strings.clone(found) : create_chat(ui, client, NOTES_TITLE, "")
	if len(id) == 0 {
		return
	}
	delete(ui.prefs.notes_group)
	ui.prefs.notes_group = id
	ui.prefs.pinned[strings.clone(id)] = true
	save_settings(ui)
}

open_notes :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ensure_notes(ui, client)
	ui.new_chat_open = false
	ui.focus = .Compose
	ui.page = .Chats
	select_by_id(ui, client, ui.prefs.notes_group)
}

// New-chat form: field focus, create, cancel.
handle_new_chat :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	edit_text(ui, active_buf(ui))

	if field_mouse(ui, &ui.nc_member, "NCMember", 14) {
		ui.focus = .NC_Member
	}
	if field_mouse(ui, &ui.nc_name, "NCName", 14) {
		ui.focus = .NC_Name
	}
	if clicked("NCCancel") || rl.IsKeyPressed(.ESCAPE) {
		ui.new_chat_open = false
		ui.focus = .Compose
		return
	}

	if clicked("NCCreate") || rl.IsKeyPressed(.ENTER) {
		name := len(ui.nc_name) > 0 ? string(ui.nc_name[:]) : "New group"

		member := strings.trim_space(string(ui.nc_member[:]))
		// A pasted marmot:// profile link reduces to its bare reference.
		if ref := marmot_link_ref(member); len(ref) > 0 {
			member = ref
		}

		id := create_chat(ui, client, name, member)
		if len(id) == 0 {
			return
		}

		clear(&ui.nc_member)
		clear(&ui.nc_name)
		ui.new_chat_open = false
		ui.focus = .Compose
		ui.page = .Chats
		select_by_id(ui, client, id)
	}
}

// Member admin actions and the invite box.
handle_members :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// Member-row nickname editor: Enter saves (empty clears), Escape
	// drops it without saving. load_members refreshes the row name.
	if ui.member_nick >= 0 && ui.member_nick < len(ui.members) && ui.focus == .Nick {
		if rl.IsKeyPressed(.ENTER) {
			id := ui.members[ui.member_nick].id_hex
			nick := strings.trim_space(string(ui.nick_input[:]))
			if len(nick) == 0 {
				delete_key(&ui.nicknames, id)
			} else {
				ui.nicknames[strings.clone(id)] = strings.clone(nick)
			}
			save_settings(ui)
			ui.focus = .Compose
			load_members(client, ui)
			return
		}
		if rl.IsKeyPressed(.ESCAPE) {
			ui.member_nick = -1
			ui.focus = .Compose
			return
		}
	}

	// The open "⋯" menu owns the click; anything outside it closes it.
	if ui.member_menu >= 0 {
		if handle_member_menu(ui) {
			return
		}
	}

	if handle_hero(ui, client) {
		return
	}
	if mouse_released() {
		for member, i in ui.members {
			if clay.PointerOver(clay.ID("MemberMenuBtn", u32(i))) {
				open_member_menu(ui, i)
				return
			}
			if clay.PointerOver(clay.ID("MemberRow", u32(i))) {
				if member.is_self {
					ui.page = .Profile
					load_profile(client, ui)
				} else {
					open_peer(ui, client, member.id_hex, member.name, member.pic_url)
				}
				return
			}
		}
		if clay.PointerOver(clay.ID("MembersClose")) {
			ui.show_members = false
			return
		}
	}

	if field_mouse(ui, &ui.invite_input, "InviteBox") {
		ui.focus = .Invite
	}
	if ui.member_nick >= 0 && field_mouse(ui, &ui.nick_input, "MemberNickBox") {
		ui.focus = .Nick
	}
	if field_mouse(ui, &ui.rename_input, "RenameBox") {
		ui.focus = .Rename
	}

	if clicked("LeaveBtn") {
		confirm_ask(ui, .Leave_Group, "", ui.chats[ui.selected].title)
		return
	}

	if clicked("RenameBtn") && len(ui.rename_input) > 0 {
		start_rename(ui, client)
		return
	}

	if clicked("IssueToggle") &&
	   ui.issue_admin &&
	   ui.issue_setting != .Unavailable &&
	   ui.issue_ticket == 0 {
		ui.issue_action = .Setting
		ui.issue_ticket = spawn_op(
			ui,
			client,
			.Issue_Setting,
			"",
			"",
			ui.issue_setting == .Enabled ? 0 : 1,
		)
		return
	}
	if clicked("IssueRetry") {issues_refresh(); return}
	for secs, i in RETENTION_SECS {
		if !clicked(fmt.tprintf("RetChip%d", i)) || ui.group_retention == secs {
			continue
		}
		// Optimistic: the chip flips now, the relay commit runs on the
		// op worker; drain_ops reloads the timeline on the ack (the
		// timer-change system row) and re-snapshots on failure.
		ui.group_retention = secs
		spawn_op(ui, client, .Retention, "", "", secs)
		return
	}

	// Transcript exports; the save dialog picks the destination.
	if clicked("ExportHtmlBtn") {
		export_chat(ui, client, .Html)
		return
	}
	if clicked("ExportMdBtn") {
		export_chat(ui, client, .Markdown)
		return
	}

	if (rl.IsKeyPressed(.ENTER) || clicked("InviteBtn")) &&
	   ui.focus == .Invite &&
	   len(ui.invite_input) > 0 {
		admin_op(ui, client, "invite", string(ui.invite_input[:]))
		clear(&ui.invite_input)
	}
	if rl.IsKeyPressed(.ENTER) && ui.focus == .Rename && len(ui.rename_input) > 0 {
		start_rename(ui, client)
	}
}

// Admin commits are relay round trips; they run on the op worker and
// the member list reloads when drain_ops adopts the ack.
admin_op :: proc(ui: ^Ui_State, client: ^marmot.Client, op: string, member_ref: string) {
	kind: Msg_Op
	switch op {
	case "invite":
		kind = .Invite
	case "remove":
		kind = .Remove
	case "promote":
		kind = .Promote
	case "demote":
		kind = .Demote
	}
	spawn_op(ui, client, kind, member_ref, "")
}

// Optimistic rename: the rail row and header flip now, the commit runs
// on the op worker, and drain_ops re-snapshots either way.
start_rename :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	name := string(ui.rename_input[:])
	chat := &ui.chats[ui.selected]
	delete(chat.title)
	chat.title = strings.clone(name)
	spawn_op(ui, client, .Rename, name, "")
	clear(&ui.rename_input)
}

Msg_Op :: enum {
	React,
	Unreact,
	Delete,
	Edit,
	History,
	Issue,
	Issue_Setting,
	Custom, // app-defined kind + tags (polls, votes, thread messages)
	Retention, // disappearing-timer change; the seconds ride Op_Job.secs
	Rename, // group rename; the new name rides Op_Job.target
	Invite, // member ops: the member ref rides Op_Job.target
	Remove,
	Promote,
	Demote,
}

// Fire and forget onto the op worker: the round trip is a relay's
// worth of latency, and the frame must not wait for it. The local
// feedback plays now; drain_ops reloads the timeline on the ack.
message_op :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	op: Msg_Op,
	message_id: string,
	emoji: string,
) {
	if op == .React {
		react_burst(message_id, emoji)
		react_fly(ui, message_id, emoji)
	}
	ticket := spawn_op(ui, client, op, message_id, emoji)
	if op == .React || op == .Unreact {
		append(
			&ui.react_pending,
			Pending_React {
				ticket = ticket,
				msg_id = strings.clone(message_id),
				emoji = strings.clone(emoji),
				remove = op == .Unreact,
			},
		)
		apply_pending_reacts(ui) // the ghost is on screen this frame
	}
}

// First "e"-tag value of a record: the edit/delete target message id.
first_event_ref :: proc(record: ^marmot.Timeline_Message_Record) -> string {
	for t in 0 ..< record.tags_len {
		tag := &record.tags[t]
		if tag.values_len >= 2 && string(tag.values[0]) == "e" {
			return string(tag.values[1])
		}
	}
	return ""
}

// One kind-1009 edit awaiting application, ordered by (at, id).
Edit_Rec :: struct {
	at:     u64,
	id:     string,
	record: ^marmot.Timeline_Message_Record,
}

// Per-chat message-body hits for the rail filter: one limit-1 search
// query per chat on a worker; the frame loop only reads cached flags.
refresh_filter_hits :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	resize(&ui.filter_hits, len(ui.chats))
	for &hit in ui.filter_hits {hit = false}
	search_request(ui, client, .Sidebar)
}

// Snapshot the selected chat's timeline into UI-owned strings.
