package main

import "core:fmt"

import "nendo"
import rl "sdlrl"

@(private = "file")
Settings_Avatar_Preview :: struct {
	label:   string,
	texture: ^rl.Texture2D,
	radius:  f32,
}

@(private)
settings_avatar_choices :: proc(ui: ^Ui_State) {
	key := ui.account_ref
	name := len(ui.profile.name) > 0 ? ui.profile.name : profile_label(nil, key)
	photo := url_pic(ui.my_pic_url)
	generated: [Crop_Shape]^rl.Texture2D
	if len(key) == 64 || len(key) == 32 {
		for prefix, shape in CROP_SHAPE_PREFIX {
			generated[shape] = url_pic(fmt.tprintf("%s:%s", prefix, key))
		}
	}

	photos: [len(AVATAR_SHAPE_NAMES)]Settings_Avatar_Preview
	for label, shape in AVATAR_SHAPE_NAMES {
		mask := shape == .Square ? "square" : shape == .Rounded ? "rounded" : "circle"
		fallback :=
			shape == .Square ? Crop_Shape.Square : shape == .Rounded ? Crop_Shape.Rounded : Crop_Shape.Circle
		photos[int(shape)] = {
			label   = tr(label),
			texture = photo != nil ? shaped_avatar(photo, mask) : generated[fallback],
			radius  = shape == .Square ? 0 : shape == .Rounded ? 14.4 : 36,
		}
	}
	crops: [len(CROP_SHAPE_NAMES)]Settings_Avatar_Preview
	for label, shape in CROP_SHAPE_NAMES {
		crops[int(shape)] = {
			label   = tr(label),
			texture = generated[shape],
			radius  = shape == .Circle ? 36 : shape == .Rounded ? 14.4 : 0,
		}
	}

	width := settings_body_width(ui) - 24
	if nendo.box(nendo.id("AvatarGroup"))(settings_box()) {
		settings_group(tr("Avatars"))
		if nendo.box(nendo.id("RowAvatarShape"))(
		{width = nendo.grow(), direction = .Column, gap = 8, padding = {top = 4, bottom = 8}},
		) {
			row_labels(
				tr("Default avatar shape"),
				tr("Used for profile photos without a published shape."),
			)
			settings_avatar_preview_grid(
				"AvatarShapeChip",
				photos[:],
				int(ui.prefs.avatar_shape),
				key,
				name,
				width,
			)
		}
		if nendo.box(nendo.id("RowCropShape"))(
		{width = nendo.grow(), direction = .Column, gap = 8, padding = {top = 4, bottom = 4}},
		) {
			row_labels(tr("Crop circle shape"), tr("Used for generated user and group avatars."))
			settings_avatar_preview_grid(
				"CropShapeChip",
				crops[:],
				int(ui.prefs.crop_avatar_shape),
				key,
				name,
				width,
			)
		}
	}
}

@(private = "file")
settings_avatar_preview_grid :: proc(
	id: string,
	choices: []Settings_Avatar_Preview,
	selected: int,
	key, name: string,
	available: f32,
) {
	tile_width: f32 = 96
	for choice in choices {
		tile_width = max(tile_width, rl.MeasureTextLine(FONT_BODY, 12, choice.label, 0).x + 40)
	}
	tile_width = min(tile_width, available)
	columns := max(1, int((available + 8) / (tile_width + 8)))
	initials := avatar_initials(name)
	for first := 0; first < len(choices); first += columns {
		if nendo.box(nendo.id_local("AvatarPreviewRow", u32(first)))(
		{width = nendo.grow(), gap = 8},
		) {
			for i in first ..< min(first + columns, len(choices)) {
				choice := choices[i]
				active := selected == i
				if nendo.box(nendo.id(id, u32(i)))(
				{
					width = nendo.fixed(tile_width),
					direction = .Column,
					padding = nendo.pad(10),
					gap = 8,
					align = {x = .Center},
					color = active ? SELECTED : hovered() ? HOVER : {},
					border = kb_focus == fmt.tprintf("%s%d", id, i) ? kb_ring(ACCENT) : nendo.Border{color = active ? ACCENT : FIELD_BORDER, width = {1, 1, 1, 1, 0}},
					radius = rr(8),
				},
				) {
					// These textures already carry the candidate mask. The regular avatar
					// renderer would reapply the current preference or published override.
					if nendo.box(nendo.id_local("AvatarPreviewImage"))(
					{
						width = nendo.fixed(72),
						height = nendo.fixed(72),
						align = {x = .Center, y = .Center},
						image = choice.texture,
						color = choice.texture == nil ? avatar_color(key) : {},
						radius = nendo.radius(choice.radius),
					},
					) {
						if choice.texture == nil {
							nendo.text(
								initials,
								{font = FONT_BODY, size = 28, color = {255, 255, 255, 235}},
							)
						}
					}
					if nendo.box(nendo.id_local("AvatarPreviewLabel"))(
					{width = nendo.grow(), gap = 4, align = {x = .Center, y = .Center}},
					) {
						if nendo.box(nendo.id_local("AvatarPreviewCheck"))(
						{width = nendo.fixed(12), height = nendo.fixed(12)},
						) {
							if active {nendo.text(ICON_CHECK, {font = FONT_ICON, size = 12, color = ACCENT})}
						}
						nendo.text(
							choice.label,
							{
								font = FONT_BODY,
								size = 12,
								color = active ? ACCENT : TEXT,
								align = .Center,
							},
						)
					}
				}
			}
		}
	}
}
