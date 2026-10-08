// Native photo picks keep their original target until Use or Cancel.
// All draft/texture ownership and transitions run on the frame thread.
package main

import "core:strings"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"
import marmot "../marmot"

@(private)
Photo_Kind :: enum {None, Profile, Group}
@(private)
Photo_Preview :: struct {
	kind: Photo_Kind,
	account, group: string,
	pending: bool, // stays armed even after invalidation, until the callback drains
	draft: Pic_Draft,
	texture: rl.Texture2D,
	crop: Photo_Crop,
	crop_job: ^Photo_Crop_Job,
	crop_drag: bool,
	crop_pointer: rl.Vector2,
	crop_origin: [2]i32,
}

@(private)
photo_input_capture :: proc(ui: ^Ui_State) -> bool {
	return ui.photo.pending || ui.photo.kind != .None
}

// Invalidation retains a tombstone for the untagged native callback. A late
// result must be discarded, never fall through to composer attachments.
@(private)
photo_cancel :: proc(ui: ^Ui_State) {
	pending := ui.photo.pending
	if ui.photo.texture.tex != nil {rl.UnloadTexture(ui.photo.texture)}
	pic_draft_free(&ui.photo.draft)
	delete(ui.photo.account); delete(ui.photo.group)
	ui.photo = {pending = pending}
}

@(private)
photo_target_valid :: proc(ui: ^Ui_State) -> bool {
	p := &ui.photo
	if p.kind == .None || p.account == "" || p.account != ui.account_ref || account_departing(p.account) {return false}
	found := false
	for account in ui.account_ids {if account == p.account {found = true; break}}
	if !found {return false}
	if p.kind == .Group {
		if ui.selected < 0 || ui.selected >= len(ui.chats) || ui.chats[ui.selected].group_id != p.group {return false}
		if !self_is_admin(ui) {return false}
		for job in account_jobs {
			if job.account == p.account && job.group == p.group && (job.kind == .Leave || job.kind == .Decline) {return false}
		}
	}
	return true
}

@(private)
photo_can_use :: proc(ui: ^Ui_State) -> bool {
	if !photo_target_valid(ui) || ui.photo.pending || ui.photo.draft.image.data == nil {return false}
	if ui.photo.kind == .Group && members_job != nil {return false}
	for job in account_jobs {if job.account == ui.photo.account || job.kind == .Switch {return false}}
	if signer := nip46_find(ui.photo.account); signer != nil && (signer.attach != nil || !signer.registered) {return false}
	return !ppic_busy && !gimg_writes_pending()
}

// Capture before opening SDL's dialog. No other outstanding open dialog may
// share its untagged queue, and pending photo input is captured by main.
@(private)
photo_pick_begin :: proc(ui: ^Ui_State, kind: Photo_Kind) -> bool {
	if rl.FileDialogPending() || ui.photo.pending {
		set_status(ui, strings.clone(tr("Couldn't choose a photo. Close your open file picker and try again.")), .Info)
		return false
	}
	photo_cancel(ui)
	ui.photo.kind = kind
	ui.photo.account = strings.clone(ui.account_ref)
	if kind == .Group && ui.selected >= 0 && ui.selected < len(ui.chats) {
		ui.photo.group = strings.clone(ui.chats[ui.selected].group_id)
	}
	if !photo_target_valid(ui) {photo_cancel(ui); return false}
	ui.photo.pending = true
	return true
}

// The completion route consumes even empty, invalidated or undecodable picks.
// It neither registers a local avatar nor queues any network work.
@(private)
photo_pick_complete :: proc(ui: ^Ui_State, paths: []string) {
	if !ui.photo.pending {return}
	ui.photo.pending = false
	if len(paths) == 0 || !photo_target_valid(ui) {photo_cancel(ui); return}
	draft, ok := load_pic_draft(ui, paths[0])
	if !ok {photo_cancel(ui); return}
	texture := rl.LoadTextureFromImage(draft.image)
	if texture.tex == nil {
		pic_draft_free(&draft)
		photo_cancel(ui)
		set_status(ui, strings.clone(tr("Couldn't preview the picture. Please try again.")), .Error)
		return
	}
	ui.photo.draft, ui.photo.texture = draft, texture
}

@(private)
photo_check_target :: proc(ui: ^Ui_State) {
	if ui.photo.kind != .None && !photo_target_valid(ui) {photo_cancel(ui)}
}

@(private)
photo_use :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || !photo_can_use(ui) {
		photo_check_target(ui)
		set_status(ui, strings.clone(tr("Couldn't use the picture. Wait a moment and try again.")), .Error)
		return
	}
	p := &ui.photo
	if p.crop.active {
		photo_crop_begin(p)
		return
	}
	draft := p.draft
	p.draft = {} // moved once; cleanup owns only the preview texture now
	switch p.kind {
	case .Profile: upload_profile_pic(client, p.account, draft)
	case .Group: upload_group_pic_for(client, p.account, p.group, draft)
	case .None:
	}
	photo_cancel(ui)
}

@(private)
handle_photo_preview :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// A native pick has no in-app actions until it has completed.
	if ui.photo.pending {return}
	if rl.IsKeyPressed(.ESCAPE) || clicked("PhotoCancel") ||
	   (mouse_released() && !ui.photo.crop_drag && !clay.PointerOver(clay.ID("PhotoPreview"))) {
		photo_cancel(ui)
		return
	}
	photo_crop_drain(ui, client)
	if ui.photo.kind == .None || ui.photo.crop_job != nil {return}
	was_dragging := ui.photo.crop_drag
	photo_crop_input(&ui.photo)
	if was_dragging || ui.photo.crop_drag {return}
	if clicked("PhotoCrop") {
		photo_crop_start(&ui.photo)
		return
	}
	if clicked("PhotoReset") {
		ui.photo.crop = {}; ui.photo.crop_drag = false
		return
	}
	if clicked("PhotoSmaller") {photo_crop_resize(&ui.photo, 0.9); return}
	if clicked("PhotoLarger") {photo_crop_resize(&ui.photo, 1.1); return}
	if rl.IsKeyPressed(.ENTER) || clicked("PhotoUse") {
		photo_use(ui, client)
	}
}

@(private)
photo_preview_modal :: proc(ui: ^Ui_State) {
	image := photo_image(&ui.photo)
	if image.data == nil {return}
	width := min(f32(400), max(f32(160), f32(rl.GetScreenWidth()) / UI_ZOOM - 24))
	edge := max(f32(24), min(width - 40, f32(rl.GetScreenHeight()) / UI_ZOOM - 230))
	scale := edge / f32(max(image.width, image.height))
	if clay.UI(clay.ID("PhotoPreview"))({
		layout = {sizing = {width = clay.SizingFixed(width)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12, childAlignment = {x = .Center}},
		backgroundColor = CARD, cornerRadius = rr(16), border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 20, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	}) {
		clay.Text(tr("Use this photo?"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
		if clay.UI(clay.ID("PhotoImage"))({layout = {sizing = {width = clay.SizingFixed(f32(image.width) * scale), height = clay.SizingFixed(f32(image.height) * scale)}}, image = {imageData = &ui.photo.texture}}) {
			if ui.photo.crop.active {
				crop := ui.photo.crop
				if clay.UI(clay.ID("PhotoCropBox"))({
					layout = {sizing = {width = clay.SizingFixed(f32(crop.side) * scale), height = clay.SizingFixed(f32(crop.side) * scale)}},
					border = {color = ACCENT, width = {left = 2, right = 2, top = 2, bottom = 2}},
					floating = {attachTo = .Parent, pointerCaptureMode = .Passthrough, zIndex = 21, offset = {f32(crop.x) * scale, f32(crop.y) * scale}, attachment = {element = .LeftTop, parent = .LeftTop}},
				}) {}
			}
		}
		if ui.photo.crop_job != nil {
			clay.Text(tr("Preparing the cropped picture…"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			clay.Text(tr("Progress is indeterminate."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
			busy_bar("PhotoCropBusy")
		} else {
			if clay.UI(clay.ID("PhotoCropActions"))({layout = {childGap = 8}}) {
				if ui.photo.crop.active {
					micro_button("PhotoReset", tr("Reset"))
					micro_button("PhotoSmaller", "−")
					micro_button("PhotoLarger", "+")
				} else {
					micro_button("PhotoCrop", tr("Crop"))
				}
			}
			if ui.photo.crop.active {
				clay.Text(tr("Drag to move. Scroll to resize."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		if clay.UI(clay.ID("PhotoActions"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}}) {
			micro_button("PhotoCancel", tr("Cancel"))
			if clay.UI(clay.ID("PhotoGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if ui.photo.crop_job == nil {micro_button("PhotoUse", tr("Use"))}
		}
	}
}
