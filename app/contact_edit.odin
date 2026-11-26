package main

import "core:mem"
import "core:strings"
import "nendo"
import rl "sdlrl"

@(private)
Contact_Edit :: struct {
	owner, peer: string,
	note:        [dynamic]u8,
	change:      Contact_Photo_Change,
	photo:       []u8,
	preview:     rl.Texture2D,
	loading:     bool,
	saving:      bool,
	failed:      bool,
}

@(private)
contact_edit_target :: proc(ui: ^Ui_State) -> string {
	draft := &ui.contact_edit
	if draft.peer == "" ||
	   ui.account_ref != draft.owner ||
	   ui.page != .Contacts ||
	   ui.add_account_open ||
	   account_departing(draft.owner) ||
	   account_revoked(ui, draft.owner) {
		return ""
	}
	contact, found := shown_contact(ui)
	return found && contact.id_hex == draft.peer ? draft.peer : ""
}

@(private)
contact_edit_close :: proc(ui: ^Ui_State) {
	draft := &ui.contact_edit
	if draft.peer == "" {return}
	if ui.photo.kind == .Contact {photo_cancel(ui)}
	if ui.ed_target == &draft.note {editor_forget(ui)}
	if text_drag == &draft.note {text_drag = nil}
	if ui.focus == .ContactNote {
		ui.focus = .Compose
		touch_field = {}
		compose_keyboard = false
	}
	if compose_cache.mode == .Plain {compose_cache_forget()}
	session_buffer_forget(&draft.note)
	mem.zero_slice(draft.photo); delete(draft.photo)
	rl.UnloadTexture(draft.preview)
	delete(draft.owner); delete(draft.peer)
	draft^ = {}
	kb_focus = ""
}

@(private)
contact_edit_tick :: proc(ui: ^Ui_State) {
	owner := ui.account_ref
	if account_departing(owner) || account_revoked(ui, owner) {owner = ""}
	contact_store_select(owner)
	draft := &ui.contact_edit
	peer := contact_edit_target(ui)
	if contact_store_drain(draft.saving ? peer : "") {
		set_status(ui, tr("Couldn't save your private note and photo. Please try again."), .Error)
	}
	if peer == "" {
		contact_edit_close(ui)
		return
	}
	if draft.loading {
		if record := contact_store_entry(owner, draft.peer); record != nil && !record.saving {
			ed_set(ui, &draft.note, record.note)
			draft.loading = false
		}
	}
	if draft.saving {
		if done, ok := contact_store_result(owner, draft.peer); done {
			if ok {contact_edit_close(ui); return}
			draft.saving, draft.failed = false, true
		}
	}
}

@(private)
contact_edit_photo :: proc(ui: ^Ui_State, picked: Pic_Draft) {
	picked := picked
	draft := &ui.contact_edit
	preview := rl.LoadTextureFromImage(picked.image)
	if preview.tex != nil {
		rl.UnloadTexture(draft.preview)
		mem.zero_slice(draft.photo); delete(draft.photo)
		draft.preview, draft.photo = preview, picked.data
		draft.change, draft.failed = .Replace, false
		picked.data = nil
	} else {
		set_status(ui, tr("Couldn't preview the picture. Please try again."), .Error)
	}
	mem.zero_slice(picked.data)
	mem.zero_slice(picked.image.data[:int(picked.image.width) * int(picked.image.height) * 4])
	pic_draft_free(&picked)
}

@(private = "file")
contact_edit_actions :: proc(
	draft: ^Contact_Edit,
	record: ^Contact_Record,
) -> (
	ids: [5]string,
	count: int,
) {
	ids[0], ids[1] = "ComposeBox", "PrivateContactPick"
	count = 2
	if draft.change == .Replace ||
	   (draft.change == .Keep && record != nil && (record.has_photo || record.unreadable)) {
		ids[count] = "PrivateContactRemove"
		count += 1
	}
	ids[count], ids[count + 1] = "PrivateContactCancel", "PrivateContactSave"
	count += 2
	return
}

@(private)
handle_contact_edit :: proc(ui: ^Ui_State) -> bool {
	draft := &ui.contact_edit
	if draft.peer == "" {
		if !clicked("PrivateContactEdit") {return false}
		contact, found := shown_contact(ui)
		if !found ||
		   contact.id_hex == ui.account_ref ||
		   account_departing(ui.account_ref) {return true}
		draft.owner, draft.peer = strings.clone(ui.account_ref), strings.clone(contact.id_hex)
		draft.loading = true
		kb_focus = ""
		return true
	}
	if contact_edit_target(ui) == "" || draft.saving {return false}
	if rl.IsKeyPressed(.ESCAPE) || clicked("PrivateContactCancel") {
		contact_edit_close(ui)
		return true
	}
	if draft.loading {return false}

	record := contact_store_entry(draft.owner, draft.peer)
	ids, count := contact_edit_actions(draft, record)
	note_click :=
		nendo.pointer_over(nendo.id("ComposeClip")) &&
		(mouse_pressed() || rl.IsMouseButtonPressed(.MIDDLE))
	if ui.focus == .Nick && (note_click || tab_step() != 0) {save_nickname(ui)}
	compose_mouse(ui, &draft.note, .ContactNote)
	if mouse_pressed() && nendo.pointer_over(nendo.id("ComposeClip")) {kb_focus = "ComposeBox"}
	key := control_keys(ids[:count])
	if key == .Moved {
		ui.focus = kb_focus == "ComposeBox" ? .ContactNote : .Compose
		scroll_into_view(nendo.id("ContactPage"), nendo.id(kb_focus))
		return true
	}
	if clicked("PrivateContactPick") || (key == .Pressed && kb_focus == "PrivateContactPick") {
		if photo_pick_begin(ui, .Contact) {rl.OpenFileDialog(false)}
		return true
	}
	if clicked("PrivateContactRemove") || (key == .Pressed && kb_focus == "PrivateContactRemove") {
		rl.UnloadTexture(draft.preview); draft.preview = {}
		mem.zero_slice(draft.photo); delete(draft.photo); draft.photo = nil
		draft.change, draft.failed = .Remove, false
		if kb_focus == "PrivateContactRemove" {kb_focus = "PrivateContactPick"}
		return true
	}
	if key == .Pressed && kb_focus == "PrivateContactCancel" {
		contact_edit_close(ui)
		return true
	}
	if clicked("PrivateContactSave") || (key == .Pressed && kb_focus == "PrivateContactSave") {
		note := strings.trim_space(string(draft.note[:]))
		if len(note) <= CONTACT_NOTE_MAX {
			draft.saving = contact_store_save(
				draft.owner,
				draft.peer,
				note,
				draft.photo,
				draft.change,
			)
			draft.failed = !draft.saving
			if draft.saving {
				ui.focus = .Compose
				touch_field = {}
				compose_keyboard = false
			}
		}
		return true
	}
	if ui.focus == .ContactNote {
		edit_text(ui, &draft.note, true)
		if rl.IsKeyPressed(.ENTER) {ed_insert(ui, &draft.note, "\n")}
	}
	return false
}

@(private)
contact_private_panel :: proc(ui: ^Ui_State, contact: Contact_Ui) {
	owner, peer := ui.account_ref, contact.id_hex
	if owner == "" ||
	   peer == owner ||
	   account_departing(owner) ||
	   account_revoked(ui, owner) {return}
	record := contact_store_entry(owner, peer)
	draft := &ui.contact_edit
	editing := draft.owner == owner && contact_edit_target(ui) == peer
	if nendo.box(nendo.id("PrivateContact"))(
	{
		width = nendo.grow(),
		direction = .Column,
		gap = 8,
		padding = nendo.pad(12),
		color = ROW_BG,
		radius = rr(10),
	},
	) {
		eyebrow(tr("PRIVATE NOTE AND PHOTO"))
		nendo.text(
			tr("Only you can see these on this device."),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		if !editing {
			micro_button("PrivateContactEdit", tr("Edit private note and photo"))
			if record != nil && record.note != "" {
				nendo.text(record.note, {font = FONT_BODY, size = 13, color = TEXT})
			}
			return
		}
		if draft.loading || draft.saving {
			nendo.text(
				tr(
					draft.loading ? N_("Loading your private note and photo…") : N_("Saving your private note and photo…"),
				),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
			nendo.text(
				tr("Progress is indeterminate."),
				{font = FONT_BODY, size = 12, color = TEXT_LO},
			)
			busy_bar("PrivateContactBusy")
			if draft.loading {micro_button("PrivateContactCancel", tr("Cancel"))}
			return
		}

		multiline_field(ui, &draft.note, .ContactNote, tr("Private note"), 64)
		if len(strings.trim_space(string(draft.note[:]))) > CONTACT_NOTE_MAX {
			nendo.text(
				tr("Shorten your private note."),
				{font = FONT_BODY, size = 12, color = DANGER},
			)
		} else if draft.failed {
			nendo.text(
				tr("Couldn't save your private note and photo. Please try again."),
				{font = FONT_BODY, size = 12, color = DANGER},
			)
		} else if record != nil && record.unreadable && draft.change == .Keep {
			nendo.text(
				tr(
					"Couldn't read your saved private details. Replace or remove your private photo.",
				),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
		}

		texture: ^rl.Texture2D
		switch draft.change {
		case .Keep:
			if record != nil {texture = record.photo}
		case .Replace:
			texture = &draft.preview
		case .Remove:
		}
		if texture != nil {
			if nendo.box(nendo.id("PrivateContactPhoto"))(
			{width = nendo.fixed(56), height = nendo.fixed(56), image = texture},
			) {}
		}
		ids, count := contact_edit_actions(draft, record)
		if nendo.box(nendo.id("PrivatePhotoActions"))(
		{width = nendo.grow(), direction = single_pane() ? .Column : .Row, gap = 6},
		) {
			micro_button(
				"PrivateContactPick",
				texture == nil ? tr("Choose photo") : tr("Change photo"),
				kb_focus == "PrivateContactPick" ? ACCENT : {},
			)
			if count == len(ids) {
				micro_button(
					"PrivateContactRemove",
					tr("Remove private photo"),
					kb_focus == "PrivateContactRemove" ? ACCENT : {},
				)
			}
		}
		if nendo.box(nendo.id("PrivateContactActions"))({gap = 8}) {
			micro_button(
				"PrivateContactCancel",
				tr("Cancel"),
				kb_focus == "PrivateContactCancel" ? ACCENT : {},
			)
			micro_button(
				"PrivateContactSave",
				tr("Save"),
				kb_focus == "PrivateContactSave" ? ACCENT : {},
			)
		}
	}
}
