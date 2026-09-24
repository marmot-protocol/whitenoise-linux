package main

import "core:fmt"

import clay "../vendor/clay/bindings/odin/clay-odin"
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
	name := len(ui.profile.name) > 0 ? ui.profile.name : short_hex(key)
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
	if clay.UI(clay.ID("AvatarGroup"))(settings_box()) {
		settings_group(N_("Avatars"))
		if clay.UI(clay.ID("RowAvatarShape"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 8,
				padding = {top = 4, bottom = 8},
			},
		},
		) {
			row_labels(
				"Default avatar shape",
				"Used for profile photos without a published shape.",
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
		if clay.UI(clay.ID("RowCropShape"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 8,
				padding = {top = 4, bottom = 4},
			},
		},
		) {
			row_labels("Crop circle shape", "Used for generated user and group avatars.")
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
		if clay.UI(clay.ID_LOCAL("AvatarPreviewRow", u32(first)))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
		) {
			for i in first ..< min(first + columns, len(choices)) {
				choice := choices[i]
				active := selected == i
				if clay.UI(clay.ID(id, u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(tile_width)},
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(10),
						childGap = 8,
						childAlignment = {x = .Center},
					},
					backgroundColor = active ? SELECTED : hovered() ? HOVER : {},
					border = {color = active ? ACCENT : FIELD_BORDER, width = {1, 1, 1, 1, 0}},
					cornerRadius = rr(8),
				},
				) {
					// These textures already carry the candidate mask. The regular avatar
					// renderer would reapply the current preference or published override.
					if clay.UI(clay.ID_LOCAL("AvatarPreviewImage"))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(72), height = clay.SizingFixed(72)},
							childAlignment = {x = .Center, y = .Center},
						},
						image = {imageData = choice.texture},
						backgroundColor = choice.texture == nil ? avatar_color(key) : {},
						cornerRadius = clay.CornerRadiusAll(choice.radius),
					},
					) {
						if choice.texture == nil {
							clay.Text(
								initials,
								{
									fontId = FONT_BODY,
									fontSize = 28,
									textColor = {255, 255, 255, 235},
								},
							)
						}
					}
					if clay.UI(clay.ID_LOCAL("AvatarPreviewLabel"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							childGap = 4,
							childAlignment = {x = .Center, y = .Center},
						},
					},
					) {
						if clay.UI(clay.ID_LOCAL("AvatarPreviewCheck"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(12),
									height = clay.SizingFixed(12),
								},
							},
						},
						) {
							if active {clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})}
						}
						clay.Text(
							choice.label,
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = active ? ACCENT : TEXT,
								textAlignment = .Center,
							},
						)
					}
				}
			}
		}
	}
}
