// Native photo picks keep their original target until Use or Cancel.
// All draft/texture ownership and transitions run on the frame thread.
package main

import marmot "../marmot"
import "core:strings"
import "nendo"
import rl "sdlrl"

@(private)
Photo_Kind :: enum {
	None,
	Profile,
	Group,
	Whip,
}
@(private)
Photo_Preview :: struct {
	kind:                   Photo_Kind,
	account, group, folder: string,
	pending:                bool, // stays armed even after invalidation, until the callback drains
	draft:                  Pic_Draft,
	texture:                rl.Texture2D,
	crop:                   Photo_Crop,
	crop_job:               ^Photo_Crop_Job,
	crop_drag:              bool,
	crop_pointer:           rl.Vector2,
	crop_origin:            Photo_Crop,
	crop_corner:            int, // 0 moves; 1..4 resize top-left, top-right, bottom-left, bottom-right
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
	delete(ui.photo.folder)
	ui.photo = {
		pending = pending,
	}
}

@(private)
photo_target_valid :: proc(ui: ^Ui_State) -> bool {
	p := &ui.photo
	if p.kind == .Whip {return whip_avatar_valid(p.folder)}
	if p.kind == .None ||
	   p.account == "" ||
	   p.account != ui.account_ref ||
	   account_departing(p.account) {return false}
	found := false
	for account in ui.accounts {if account.id_hex == p.account {found = true; break}}
	if !found {return false}
	if p.kind == .Group {
		if ui.selected < 0 ||
		   ui.selected >= len(ui.chats) ||
		   ui.chats[ui.selected].group_id != p.group {return false}
		if !self_is_admin(ui) {return false}
		for job in account_jobs {
			if job.account == p.account &&
			   job.group == p.group &&
			   (job.kind == .Leave || job.kind == .Decline) {return false}
		}
	}
	return true
}

@(private)
photo_can_use :: proc(ui: ^Ui_State) -> bool {
	if !photo_target_valid(ui) ||
	   ui.photo.pending ||
	   ui.photo.draft.image.data == nil {return false}
	if ui.photo.kind == .Whip {return ui.whip_avatar_job == nil}
	if ui.photo.kind == .Group && members_job != nil {return false}
	for job in account_jobs {if job.account == ui.photo.account || job.kind == .Switch {return false}}
	if signer := nip46_find(ui.photo.account);
	   signer != nil && (signer.attach != nil || !signer.registered) {return false}
	return !ppic_busy && !gimg_writes_pending()
}

// Capture before opening SDL's dialog. No other outstanding open dialog may
// share its untagged queue, and pending photo input is captured by main.
@(private)
photo_pick_begin :: proc(ui: ^Ui_State, kind: Photo_Kind, folder := "") -> bool {
	if kind == .Whip && ui.whip_avatar_job != nil {return false}
	if rl.FileDialogPending() || ui.photo.pending {
		set_status(
			ui,
			strings.clone(
				tr("Couldn't choose a photo. Close your open file picker and try again."),
			),
			.Info,
		)
		return false
	}
	photo_cancel(ui)
	ui.photo.kind = kind
	if kind == .Whip {
		ui.photo.folder = strings.clone(whip_avatar_key(folder).folder)
	} else {
		ui.photo.account = strings.clone(ui.account_ref)
	}
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
	if ui.photo.kind == .Whip {whip_avatar_load(ui, paths[0]); return}
	draft, ok := load_pic_draft(ui, paths[0])
	if !ok {photo_cancel(ui); return}
	texture := rl.LoadTextureFromImage(draft.image)
	if texture.tex == nil {
		pic_draft_free(&draft)
		photo_cancel(ui)
		set_status(
			ui,
			strings.clone(tr("Couldn't preview the picture. Please try again.")),
			.Error,
		)
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
	if (client == nil && ui.photo.kind != .Whip) || !photo_can_use(ui) {
		photo_check_target(ui)
		set_status(
			ui,
			strings.clone(tr("Couldn't use the picture. Wait a moment and try again.")),
			.Error,
		)
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
	case .Profile:
		upload_profile_pic(client, p.account, draft)
	case .Group:
		upload_group_pic_for(client, p.account, p.group, draft)
	case .Whip:
		whip_avatar_save(ui, p.folder, draft)
	case .None:
	}
	photo_cancel(ui)
}

@(private)
handle_photo_preview :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// A native pick has no in-app actions until it has completed.
	if ui.photo.pending {return}
	if rl.IsKeyPressed(.ESCAPE) ||
	   clicked("PhotoCancel") ||
	   (mouse_released() && !ui.photo.crop_drag && !nendo.pointer_over(nendo.id("PhotoPreview"))) {
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
	if clicked("PhotoOriginal") {
		ui.photo.crop = {}; ui.photo.crop_drag = false
		return
	}
	if clicked("PhotoReset") &&
	   ui.photo.kind == .Whip &&
	   photo_target_valid(ui) &&
	   ui.whip_avatar_job == nil {
		whip_avatar_reset(ui, ui.photo.folder)
		photo_cancel(ui)
		return
	}
	if rl.IsKeyPressed(.ENTER) || clicked("PhotoUse") {
		photo_use(ui, client)
	}
}

@(private)
photo_preview_modal :: proc(ui: ^Ui_State) {
	image := photo_image(&ui.photo)
	if image.data == nil {return}
	width := min(f32(400), max(f32(160), f32(rl.GetScreenWidth()) / UI_ZOOM - 24))
	edge := max(f32(24), min(width - 40, modal_h(600) - (tap_size() ? 320 : 230)))
	scale := edge / f32(max(image.width, image.height))
	if nendo.box(nendo.id("PhotoPreview"))(
	{
		width = nendo.fixed(width),
		height = nendo.fit(max = modal_h(600)),
		direction = .Column,
		padding = nendo.pad(20),
		gap = 12,
		align = {x = .Center},
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 20,
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		nendo.text(tr("Use this photo?"), {font = FONT_TITLE, size = 18, color = TEXT})
		if nendo.box(nendo.id("PhotoImage"))(
		{
			width = nendo.fixed(f32(image.width) * scale),
			height = nendo.fixed(f32(image.height) * scale),
			image = &ui.photo.texture,
		},
		) {
			if ui.photo.crop.active {
				crop := ui.photo.crop
				x, y, side := f32(crop.x) * scale, f32(crop.y) * scale, f32(crop.side) * scale
				w, h := f32(image.width) * scale, f32(image.height) * scale
				// Four non-overlapping shades leave the selected pixels untouched.
				for shade, i in ([4][4]f32{{0, 0, w, y}, {0, y + side, w, h - y - side}, {0, y, x, side}, {x + side, y, w - x - side, side}}) {
					if shade[2] <= 0 || shade[3] <= 0 {continue}
					if nendo.box(nendo.id("PhotoCropShade", u32(i)))(
					{
						width = nendo.fixed(shade[2]),
						height = nendo.fixed(shade[3]),
						color = {0, 0, 0, 140},
						floating = {
							attach_to = .Parent,
							pointer = .Passthrough,
							z = 21,
							offset = {shade[0], shade[1]},
							attach = {element = .Left_Top, parent = .Left_Top},
						},
					},
					) {}
				}
				if nendo.box(nendo.id("PhotoCropBox"))(
				{
					width = nendo.fixed(side),
					height = nendo.fixed(side),
					border = {color = ACCENT, width = {left = 2, right = 2, top = 2, bottom = 2}},
					floating = {
						attach_to = .Parent,
						pointer = .Passthrough,
						z = 21,
						offset = {x, y},
						attach = {element = .Left_Top, parent = .Left_Top},
					},
				},
				) {}
				for corner, i in ([4][2]f32{{x, y}, {x + side, y}, {x, y + side}, {x + side, y + side}}) {
					// Keep the visible grip and its hit area centered on the corner.
					hit_size := tap_size() ? tap_min() : 24
					if nendo.box(nendo.id("PhotoCropHandle", u32(i + 1)))(
					{
						width = nendo.fixed(hit_size),
						height = nendo.fixed(hit_size),
						align = {x = .Center, y = .Center},
						floating = {
							attach_to = .Parent,
							pointer = .Passthrough,
							z = 22,
							offset = {corner[0] - hit_size / 2, corner[1] - hit_size / 2},
							attach = {element = .Left_Top, parent = .Left_Top},
						},
					},
					) {
						if nendo.box(nendo.id("PhotoCropGrip", u32(i + 1)))(
						{
							width = nendo.fixed(12),
							height = nendo.fixed(12),
							color = {255, 255, 255, 255},
							radius = rr(2),
							border = {
								color = ACCENT,
								width = {left = 2, right = 2, top = 2, bottom = 2},
							},
						},
						) {}
					}
				}
			}
		}
		if ui.photo.crop_job != nil {
			nendo.text(
				tr("Preparing the cropped picture…"),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
			nendo.text(
				tr("Progress is indeterminate."),
				{font = FONT_BODY, size = 12, color = TEXT_LO},
			)
			busy_bar("PhotoCropBusy")
		} else {
			if nendo.box(nendo.id("PhotoCropActions"))({gap = 8}) {
				if ui.photo.crop.active {
					micro_button("PhotoOriginal", tr("Use original"))
				} else {
					micro_button("PhotoCrop", tr("Crop"))
				}
			}
			if ui.photo.crop.active {
				nendo.text(
					tr("Drag inside to move. Drag a corner to resize."),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
			if ui.photo.kind == .Whip && ui.whip_avatar_job == nil {
				micro_button("PhotoReset", tr("Use crop circle"))
			}
		}
		if nendo.box(nendo.id("PhotoActions"))({width = nendo.grow(), gap = 10}) {
			micro_button("PhotoCancel", tr("Cancel"))
			if nendo.box(nendo.id("PhotoGap"))({width = nendo.grow()}) {}
			if ui.photo.crop_job == nil {micro_button("PhotoUse", tr("Use"))}
		}
	}
	scrollbar(nendo.id("PhotoPreview"), 21)
}
