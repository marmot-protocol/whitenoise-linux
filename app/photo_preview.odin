// Native photo picks keep their original target until Use or Cancel.
// All draft/texture ownership and transitions run on the frame thread.
package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:strings"
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
	for account in ui.account_ids {if account == p.account {found = true; break}}
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
	if clay.UI(clay.ID("PhotoPreview"))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(width),
				height = clay.SizingFit({max = modal_h(600)}),
			},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 12,
			childAlignment = {x = .Center},
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 20,
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		clay.Text(tr("Use this photo?"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
		if clay.UI(clay.ID("PhotoImage"))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(f32(image.width) * scale),
					height = clay.SizingFixed(f32(image.height) * scale),
				},
			},
			image = {imageData = &ui.photo.texture},
		},
		) {
			if ui.photo.crop.active {
				crop := ui.photo.crop
				x, y, side := f32(crop.x) * scale, f32(crop.y) * scale, f32(crop.side) * scale
				w, h := f32(image.width) * scale, f32(image.height) * scale
				// Four non-overlapping shades leave the selected pixels untouched.
				for shade, i in ([4][4]f32{{0, 0, w, y}, {0, y + side, w, h - y - side}, {0, y, x, side}, {x + side, y, w - x - side, side}}) {
					if shade[2] <= 0 || shade[3] <= 0 {continue}
					if clay.UI(clay.ID("PhotoCropShade", u32(i)))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(shade[2]),
								height = clay.SizingFixed(shade[3]),
							},
						},
						backgroundColor = {0, 0, 0, 140},
						floating = {
							attachTo = .Parent,
							pointerCaptureMode = .Passthrough,
							zIndex = 21,
							offset = {shade[0], shade[1]},
							attachment = {element = .LeftTop, parent = .LeftTop},
						},
					},
					) {}
				}
				if clay.UI(clay.ID("PhotoCropBox"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(side), height = clay.SizingFixed(side)},
					},
					border = {color = ACCENT, width = {left = 2, right = 2, top = 2, bottom = 2}},
					floating = {
						attachTo = .Parent,
						pointerCaptureMode = .Passthrough,
						zIndex = 21,
						offset = {x, y},
						attachment = {element = .LeftTop, parent = .LeftTop},
					},
				},
				) {}
				for corner, i in ([4][2]f32{{x, y}, {x + side, y}, {x, y + side}, {x + side, y + side}}) {
					// A 24px hit area surrounds each visible 12px handle.
					if clay.UI(clay.ID("PhotoCropHandle", u32(i + 1)))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(tap_size() ? 44 : 24),
								height = clay.SizingFixed(tap_size() ? 44 : 24),
							},
							childAlignment = {x = .Center, y = .Center},
						},
						floating = {
							attachTo = .Parent,
							pointerCaptureMode = .Passthrough,
							zIndex = 22,
							offset = {corner[0] - 12, corner[1] - 12},
							attachment = {element = .LeftTop, parent = .LeftTop},
						},
					},
					) {
						if clay.UI(clay.ID("PhotoCropGrip", u32(i + 1)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(12),
									height = clay.SizingFixed(12),
								},
							},
							backgroundColor = {255, 255, 255, 255},
							cornerRadius = rr(2),
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
			clay.Text(
				tr("Preparing the cropped picture…"),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			busy_bar("PhotoCropBusy")
		} else {
			if clay.UI(clay.ID("PhotoCropActions"))({layout = {childGap = 8}}) {
				if ui.photo.crop.active {
					micro_button("PhotoOriginal", tr("Use original"))
				} else {
					micro_button("PhotoCrop", tr("Crop"))
				}
			}
			if ui.photo.crop.active {
				clay.Text(
					tr("Drag inside to move. Drag a corner to resize."),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
			}
			if ui.photo.kind == .Whip && ui.whip_avatar_job == nil {
				micro_button("PhotoReset", tr("Use crop circle"))
			}
		}
		if clay.UI(clay.ID("PhotoActions"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}},
		) {
			micro_button("PhotoCancel", tr("Cancel"))
			if clay.UI(clay.ID("PhotoGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if ui.photo.crop_job == nil {micro_button("PhotoUse", tr("Use"))}
		}
	}
	scrollbar(clay.ID("PhotoPreview"), 21)
}
