package main

import "core:mem"
import "core:os"
import "core:text/edit"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Only the frame loop accepts actions. Once requested, it renders the lock
// screen instead of dispatching any further work against the old client.
@(private)
lock_now :: proc(ui: ^Ui_State) {
	ui.lock_requested = true
	ui.pal_open = false
	// This environment belongs to startup automation, not reauthentication.
	os.unset_env("WN_VAULT_PW")
}

@(private)
lock_wait_frame :: proc() {
	anim_tick(rl.GetFrameTime())
	clay.SetLayoutDimensions(
		{f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM},
	)
	clay.BeginLayout()
	if clay.UI(clay.ID("LockScreen"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 16,
		},
		backgroundColor = BG,
	},
	) {
		clay.Text(tr("Locking…"), {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})
		clay.Text(
			tr("Closing connections and clearing this session."),
			{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
		)
		busy_bar("LockBusy")
	}
	commands := clay.EndLayout(rl.GetFrameTime())
	rl.BeginDrawing()
	rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
	clay_raylib_render(&commands)
	rl.EndMode2D()
	rl.EndDrawing()
}

@(private = "file")
Session_Stop :: struct {
	client: ^marmot.Client,
	ui:     ^Ui_State,
	live:   ^Live,
}

@(private = "file")
session_stop_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	job := (^Session_Stop)(t.data)
	client, ui, live := job.client, job.ui, job.live
	if ui.lock_requested {vault_relock()}
	local_timing_bind(nil)
	nip46_cancel_all()
	if client != nil {marmot.client_shutdown(client)}
	mem.zero_slice(transmute([]u8)ui.stt.draft)
	stt_stop(ui)
	tts_stop(ui)
	web_disconnect()
	xdc_stop()
	xdc_session_clear()
	save_settings(ui)
	settings_stop(ui)
	auth_stop()
	account_jobs_stop()
	stop_gimg_worker()
	stop_pic_worker()
	contact_import_stop(ui)
	retention_stop()
	for worker in send_threads {thread.join(worker); thread.destroy(worker)}
	delete(send_threads); send_threads = {}
	timeline_stop()
	members_stop()
	group_files_stop()
	export_stop(ui)
	issues_stop(ui)
	search_stop()
	if live.refresh != nil {chat_list_free(live.refresh); free(live.refresh); live.refresh = nil}
	agent_shutdown()
	// These owners publish textures on the render thread; join only here.
	if ui.gif_job != nil && ui.gif_job.worker != nil {thread.join(ui.gif_job.worker)}
	for job in media_jobs {if job.worker != nil {thread.join(job.worker)}}
	for job in sticker_jobs {if job.worker != nil {thread.join(job.worker)}}
	if client != nil {
		if live.worker != nil {
			thread.join(live.worker); thread.destroy(live.worker)
			marmot.chat_list_subscription_free(live.sub)
		}
		if live.events_worker != nil {
			thread.join(live.events_worker); thread.destroy(live.events_worker)
			marmot.events_subscription_free(live.events_sub)
		}
		nip46_stop()
		marmot.client_free(client)
	}
	vault_lock()
}

@(private)
session_stop :: proc(ui: ^Ui_State, client: ^marmot.Client, live: ^Live) {
	job := Session_Stop{client, ui, live}
	worker := thread.create(session_stop_worker)
	worker.data = &job
	thread.start(worker)
	if ui.lock_requested {
		for !thread.is_done(worker) {
			// Consume close events, but do not destroy the window until every
			// client borrower has joined. The gate observes close afterwards.
			rl.WindowShouldClose()
			lock_wait_frame()
		}
	}
	thread.join(worker)
	thread.destroy(worker)
	g_client = nil
	g_ui = nil
	login_pair_clear(ui)
	for change in live.dirty_groups {delete(change.group); delete(change.account)}
	delete(live.dirty_groups); live.dirty_groups = {}
	forward_stop(ui)
	sticker_stop()
	gif_stop(ui)
	media_stop()
}

// Byte editors own their buffers. Wipe their full capacity, including text
// deleted from the field, before detaching the old Ui_State from the gate.
@(private)
editor_forget :: proc(ui: ^Ui_State) {
	for stack in ([][dynamic]^edit.Undo_State{ui.ed.undo, ui.ed.redo}) {
		for item in stack {
			#no_bounds_check {mem.zero_slice(item.text[:item.len])}
		}
	}
	edit.destroy(&ui.ed)
	ui.ed = {}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.ed.set_clipboard = clip_set
	ui.ed.get_clipboard = clip_get
	ui.ed_view = {}
	ui.ed_target = nil
}

@(private)
lock_scrub_ui :: proc(ui: ^Ui_State) {
	login_pair_clear(ui)
	delete(ui.account_signing); ui.account_signing = {}
	editor_forget(ui)
	keys_forget(ui)
	vault_pw_close(ui)
	for &box in ui.vault_pw {session_buffer_forget(&box)}
	for &box in ui.poll_inputs {session_buffer_forget(&box)}
	delete(ui.poll_inputs); ui.poll_inputs = {}
	for &box in ui.theme_fields {session_buffer_forget(&box)}
	delete(ui.theme_fields); ui.theme_fields = {}
	// These fields are owning editors; borrowed labels and preferences are
	// deliberately not traversed or destroyed.
	for buffer in ([]^[dynamic]u8{&ui.sticker_input, &ui.sticker_name, &ui.name_input, &ui.about_input, &ui.nip05_input, &ui.lud16_input, &ui.relay_input, &ui.compose, &ui.invite_input, &ui.rename_input, &ui.issue_subject, &ui.issue_body, &ui.issue_labels, &ui.issue_search, &ui.desc_input, &ui.ov_input, &ui.fwd_filter, &ui.poll_question, &ui.gs_input, &ui.picker_filter, &ui.sidebar_filter, &ui.nick_input, &ui.folder_input, &ui.folder_search, &ui.folder_color_input, &ui.search_input, &ui.settings_search, &ui.backup_pw, &ui.emoji_name, &ui.kp_input, &ui.inbox_input, &ui.fetch_input, &ui.client_input, &ui.export_pw, &ui.nc_member, &ui.nc_name, &ui.pal_input, &ui.login_input}) {
		session_buffer_forget(buffer)
	}
	for key, text in ui.drafts {mem.zero_slice(transmute([]u8)text); delete(key); delete(text)}
	delete(ui.drafts); ui.drafts = {}
	for key, text in ui.nicknames {delete(key); delete(text)}
	delete(ui.nicknames); ui.nicknames = {}
	for key, text in ui.dm_peer {delete(key); delete(text)}
	delete(ui.dm_peer); ui.dm_peer = {}
	for file in ui.staged {mem.zero_slice(file.data)}
	for _, files in ui.staged_drafts {for file in files {mem.zero_slice(file.data)}}
	mem.zero_slice(ui.backup_blob); delete(ui.backup_blob); ui.backup_blob = nil
	mem.zero_slice(ui.gemoji_pic.data); pic_draft_free(&ui.gemoji_pic)
	mem.zero_slice(ui.nc_pic.data); pic_draft_free(&ui.nc_pic)
	mem.zero_slice(pending_blob); delete(pending_blob); pending_blob = nil
	for text in ([]^string{&pending_save.group, &pending_save.msg_id, &pending_save.name}) {session_string_forget(text)}
	pending_save = {}
	if ui.profile.qr !=
	   nil {rl.UnloadTexture(ui.profile.qr^); free(ui.profile.qr); ui.profile.qr = nil}
	if ui.qr_tex != nil {rl.UnloadTexture(ui.qr_tex^); free(ui.qr_tex); ui.qr_tex = nil}
	for text in ([]^string{&ui.profile.npub, &ui.profile.name, &ui.profile.about, &ui.profile.username, &ui.profile.nip05, &ui.profile.lud16, &ui.profile.nsec}) {session_string_forget(text)}
	session_strings_forget(&ui.profile.nip65)
	session_strings_forget(&ui.profile.inbox)
	ui.profile = {}
	session_contact_forget(&ui.profile_contact)
	for &contact in ui.contacts {session_contact_forget(&contact)}
	delete(ui.contacts); ui.contacts = {}
	for &member in ui.members {
		for text in ([]^string{&member.id_hex, &member.npub, &member.name, &member.pic_url}) {session_string_forget(text)}
	}
	delete(ui.members); ui.members = {}
	for hit in ui.gs_hits {mem.zero_slice(transmute([]u8)hit.snippet); gs_free_hit(hit)}
	delete(ui.gs_hits); ui.gs_hits = {}
	for chat in ui.gs_chats {chat_free(chat)}
	delete(ui.gs_chats); ui.gs_chats = {}
	for buffer in ([]^[dynamic]u8{&ui.gs_sender_input, &ui.gs_since, &ui.gs_until}) {session_buffer_forget(buffer)}
	for text in ([]^string{&ui.gs_group, &ui.gs_sender, &ui.gs_cursor_id, &ui.gs_cursor_group, &ui.gs_error, &ui.gs_account}) {session_string_forget(text)}
	ui.gs_more, ui.gs_loading, ui.gs_append, ui.gs_resume, ui.gs_jump_pending =
		false, false, false, false, false
	ui.gs_attachment, ui.gs_picker, ui.gs_cursor_at = 0, 0, 0
	for hit in ui.mi_hits {mem.zero_slice(transmute([]u8)hit.snippet); mi_free_hit(hit)}
	delete(ui.mi_hits); ui.mi_hits = {}
	for version in ui.hist_versions {
		mem.zero_slice(transmute([]u8)version.text)
		delete(version.at); delete(version.text); blocks_free(version.blocks)
	}
	delete(ui.hist_versions); ui.hist_versions = {}
	for items in ([]^[dynamic]string{&ui.accounts, &ui.account_ids, &ui.account_npubs, &ui.account_pics, &ui.sticker_recent}) {session_strings_forget(items)}
	for item in ui.stickers {mem.zero_slice(transmute([]u8)item.label); sticker_item_free(item)}
	delete(ui.stickers); ui.stickers = {}
	for item in ui.sticker_preview {mem.zero_slice(transmute([]u8)item.label); sticker_item_free(item)}
	delete(ui.sticker_preview); ui.sticker_preview = {}
	for pack in ui.sticker_packs {sticker_pack_free(pack)}
	delete(ui.sticker_packs); ui.sticker_packs = {}
	sticker_pack_free(ui.sticker_pack); ui.sticker_pack = {}
	sticker_ref_free(ui.sticker_selected); ui.sticker_selected = {}
	for text in ([]^string{&ui.account_ref, &ui.raw_json, &ui.reply_hint, &ui.sel_copy, &ui.group_desc, &ui.debug_json, &ui.debug_text, &ui.kp_own_json, &ui.kp_peer_json}) {session_string_forget(text)}
	for &pending in ui.pending {
		mem.zero_slice(transmute([]u8)pending.body)
		for attachment in pending.atts {mem.zero_slice(attachment.data)}
		free_pending(&pending)
	}
	delete(ui.pending); ui.pending = {}
	for done in sends_done {
		delete(done.err)
		for id in done.ids {delete(id)}
		delete(done.ids)
	}
	delete(sends_done); sends_done = {}
}

@(private = "file")
session_buffer_forget :: proc(buffer: ^[dynamic]u8) {
	mem.zero_slice(raw_data(buffer^)[:cap(buffer^)])
	delete(buffer^)
	buffer^ = {}
}

@(private)
session_string_forget :: proc(text: ^string) {
	mem.zero_slice(transmute([]u8)text^)
	delete(text^)
	text^ = ""
}

@(private = "file")
session_strings_forget :: proc(items: ^[dynamic]string) {
	for &text in items^ {session_string_forget(&text)}
	delete(items^)
	items^ = {}
}

@(private = "file")
session_contact_forget :: proc(contact: ^Contact_Ui) {
	for text in ([]^string{&contact.id_hex, &contact.name, &contact.pic_url, &contact.npub}) {session_string_forget(text)}
	for &group in contact.groups {
		session_string_forget(&group.id)
		session_string_forget(&group.title)
	}
	delete(contact.groups)
	contact^ = {}
}

@(private = "file")
xdc_session_clear :: proc() {
	for text in ([]^string{&xdc.session, &xdc.group_id, &xdc.self_addr, &xdc.self_name, &xdc.token}) {session_string_forget(text)}
	for items in ([]^[dynamic]string{&xdc.updates, &xdc.outbox, &xdc.staging, &xdc.pending}) {session_strings_forget(items)}
	xdc.view = nil
	xdc.serving = false
	xdc.port = 0
}

@(private)
session_textures_clear :: proc(textures: ^map[string]^rl.Texture2D) {
	for key, texture in textures^ {
		if texture != nil {
			forget_avatar(texture)
			rl.UnloadTexture(texture^)
			free(texture)
		}
		delete(key)
	}
	clear(textures)
}

@(private)
session_media_clear :: proc() {
	for _, view in video_views {if view != nil {video_view_free(view)}}
	for _, view in stl_views {if view != nil {stl_view_free(view)}}
	for _, view in pdf_views {
		if view != nil {mem.zero_slice(view.data); mem.zero_slice(view.pix); pdf_view_free(view)}
	}
	for _, view in tor_views {if view != nil {tor_view_free(view)}}
	for _, view in gcode_views {if view != nil {gcode_view_free(view)}}
	for _, view in arc_views {if view != nil {session_arc_free(view)}}
	for _, view in txt_views {if view != nil {txt_view_free(view)}}
	for _, view in code_views {if view != nil {mem.zero_slice(transmute([]u8)view.src); code_view_free(view)}}
	for _, view in ttf_views {if view != nil {ttf_view_free(view)}}
	for _, view in nes_views {if view != nil {mem.zero_slice(view.rom); delete(view.rom); free(view)}}
	for _, view in xdc_views {
		if view == nil {continue}
		session_arc_free(view.arc)
		delete(view.name)
		if view.has_icon {rl.UnloadTexture(view.icon)}
		free(view)
	}
	clear(&video_views); clear(&stl_views); clear(&pdf_views); clear(&tor_views)
	clear(&gcode_views); clear(&arc_views); clear(&txt_views); clear(&code_views)
	clear(&ttf_views); clear(&nes_views); clear(&xdc_views)
	session_textures_clear(&media_textures)
	session_textures_clear(&original_textures)
	session_textures_clear(&remote_emoji_tex)
	profile_session_clear()
	clear(&blob_sizes)
	orbit_hover, orbit_drag = nil, nil
	video_hover = nil
	video_full_hover = {}
	pdf_flip_hover = nil
	pdf_full_hover = {}
	arc_hover = {}
	arc_more_hover = nil
	tor_open_hover, tor_magnet_hover, tor_hash_hover = nil, nil, nil
	model_hover, code_hover = {}, {}
	img_hover = {}
	xdc_hover = {}
	nes_hover = {}
	stt_hover = {}
	att_hover = {}
	mention_hover, link_hover, img_link_hover = "", "", ""
}

@(private = "file")
session_arc_free :: proc(view: ^Arc_View) {
	if view.nes != nil {
		mem.zero_slice(view.nes.rom)
		delete(view.nes.rom); free(view.nes)
	}
	mem.zero_slice(view.data)
	arc_view_free(view)
}
