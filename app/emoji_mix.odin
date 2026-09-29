// Emoji group image, ported from Android's GroupEmojiImageRenderer:
// one or two picked emoji side by side on a fixed dark square, encoded
// as the JPEG that becomes the group image. Only the pixels travel; the
// emoji themselves are never stored, so every member sees the same art.
//
//   picker (.Group_Image) ─► ui.gemoji ─► emoji_mix_render ─► ui.gemoji_pic
//                                                                │ Use
//              new-chat form: ui.nc_pic ◄────────────────────────┤
//              group hero:    upload_group_pic ◄─────────────────┘
package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:slice"
import "core:strings"

import stbi "vendor:stb/image"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Android's geometry, kept identical so both platforms produce the
// same layout: 512px square, one 300px glyph or two 210px glyphs with
// a 32px gap, on #3C4043 (a fixed dark neutral, since the image is
// shared with every member and must not follow the creator's theme).
@(private)
EMOJI_MIX_SIDE :: 512
@(private)
EMOJI_MIX_MAX :: 2
@(private = "file")
EMOJI_MIX_ONE :: 300
@(private = "file")
EMOJI_MIX_TWO :: 210
@(private = "file")
EMOJI_MIX_GAP :: 32
@(private)
EMOJI_MIX_BG :: [3]u8{0x3c, 0x40, 0x43}
@(private = "file")
EMOJI_MIX_QUALITY :: 92

// Pseudo-URLs for the picker's live preview and the new-chat form.
@(private = "file")
EMOJI_MIX_PREVIEW :: "gemoji://preview"
@(private = "file")
NC_PIC_URL :: "newchat://pic"

// Where "Use emoji image" sends the render.
Gemoji_Dest :: enum {
	New_Chat, // staged in the new-chat form until Create
	Selected_Group, // uploaded to the open group right away
}

// An image staged for a group: the encoded bytes to upload and the
// decoded pixels for the instant local preview (libc-owned, as
// rl.LoadImage returns them).
Pic_Draft :: struct {
	data:       []u8,
	media_type: string, // a static literal, never freed
	image:      rl.Image,
}

@(private)
pic_draft_free :: proc(draft: ^Pic_Draft) {
	delete(draft.data)
	if draft.image.data != nil {
		rl.UnloadImage(draft.image)
	}
	draft^ = {}
}

// Bilinearly scale an RGBA tile to fit an `edge` px square, keeping its
// aspect (custom emoji need not be square), and straight-alpha blend it
// centered in that square onto an opaque canvas `side` px wide, with
// the square's top-left corner at `at`.
@(private)
blend_tile :: proc(canvas: []u8, side: int, tile: rl.Image, at: [2]int, edge: int) {
	tw, th := int(tile.width), int(tile.height)
	w, h := fit_box(tw, th, edge)
	at := at + {(edge - w) / 2, (edge - h) / 2}
	for y in 0 ..< h {
		for x in 0 ..< w {
			sx := (f32(x) + 0.5) * f32(tw) / f32(w) - 0.5
			sy := (f32(y) + 0.5) * f32(th) / f32(h) - 0.5
			x0 := clamp(int(sx), 0, tw - 1)
			y0 := clamp(int(sy), 0, th - 1)
			x1 := min(x0 + 1, tw - 1)
			y1 := min(y0 + 1, th - 1)
			fx := clamp(sx - f32(x0), 0, 1)
			fy := clamp(sy - f32(y0), 0, 1)

			src := [4]f32{}
			for ch in 0 ..< 4 {
				s00 := f32(tile.data[(y0 * tw + x0) * 4 + ch])
				s10 := f32(tile.data[(y0 * tw + x1) * 4 + ch])
				s01 := f32(tile.data[(y1 * tw + x0) * 4 + ch])
				s11 := f32(tile.data[(y1 * tw + x1) * 4 + ch])
				src[ch] = (s00 * (1 - fx) + s10 * fx) * (1 - fy) + (s01 * (1 - fx) + s11 * fx) * fy
			}

			a := src[3] / 255
			d := ((y + at.y) * side + x + at.x) * 4
			canvas[d + 0] = u8(src[0] * a + f32(canvas[d + 0]) * (1 - a))
			canvas[d + 1] = u8(src[1] * a + f32(canvas[d + 1]) * (1 - a))
			canvas[d + 2] = u8(src[2] * a + f32(canvas[d + 2]) * (1 - a))
		}
	}
}

// A w×h image scaled so its longer side is `edge`: 144×72 in 210 → 210×105.
@(private = "file")
fit_box :: proc(w, h, edge: int) -> (int, int) {
	if w >= h {
		return edge, max(1, edge * h / w)
	}
	return max(1, edge * w / h), edge
}

// Blend a tile into its slot. Bilinear sampling skips source pixels
// when shrinking and aliases, so a tile larger than its slot (a
// 512px custom emoji) is first filtered down to size by stb.
@(private = "file")
place_tile :: proc(canvas: []u8, side: int, tile: rl.Image, at: [2]int, edge: int) {
	if int(tile.width) <= edge && int(tile.height) <= edge {
		blend_tile(canvas, side, tile, at, edge)
		return
	}
	w, h := fit_box(int(tile.width), int(tile.height), edge)
	small := make([]u8, w * h * 4, context.temp_allocator)
	ALPHA :: 3
	resized := stbi.resize_uint8_srgb(
		tile.data,
		tile.width,
		tile.height,
		0,
		raw_data(small),
		i32(w),
		i32(h),
		0,
		4,
		ALPHA,
		0,
	)
	if resized == 0 {
		blend_tile(canvas, side, tile, at, edge) // aliased beats missing
		return
	}
	blend_tile(canvas, side, {data = raw_data(small), width = i32(w), height = i32(h)}, at, edge)
}

// stb's JPEG writer calls back per chunk; collect them into one buffer.
@(private = "file")
Jpeg_Sink :: struct {
	ctx: runtime.Context,
	out: ^[dynamic]u8,
}

@(private = "file")
jpeg_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	sink := (^Jpeg_Sink)(ctx)
	context = sink.ctx
	append(sink.out, ..slice.bytes_from_ptr(data, int(size)))
}

// Compose one or two emoji into the group image. `emoji` holds Unicode
// emoji and :code: custom ones (user files and the built-in :marmot: /
// :wn:). ok is false when one has no image or the encode fails.
//
// ponytail: Twemoji ships 72px tiles, so a 300px glyph is a 4x bilinear
// upscale and reads softer than Android's font-rendered emoji. Vendoring
// the SVG set (or a color font) and rasterizing at size is the upgrade.
@(private)
emoji_mix_render :: proc(emoji: []string) -> (draft: Pic_Draft, ok: bool) {
	if len(emoji) == 0 || len(emoji) > EMOJI_MIX_MAX {
		return
	}

	// Catalog tiles live in the pixel pack; custom emoji and anything
	// else (an old recent) are decoded here, and those we then own.
	tiles: [EMOJI_MIX_MAX]rl.Image
	owned: [EMOJI_MIX_MAX]bool
	defer for tile, i in tiles {
		if owned[i] {rl.UnloadImage(tile)}
	}
	for e, i in emoji {
		if pixels := emoji_pixels[e]; len(pixels) > 0 {
			tiles[i] = {
				data   = raw_data(pixels),
				width  = EMOJI_SIDE,
				height = EMOJI_SIDE,
			}
			continue
		}
		if len(e) > 2 && e[0] == ':' && e[len(e) - 1] == ':' {
			tiles[i] = custom_emoji_image(e[1:len(e) - 1])
		} else {
			tiles[i] = emoji_image(e)
		}
		if tiles[i].data == nil {
			return
		}
		owned[i] = true
	}

	side :: EMOJI_MIX_SIDE
	pixels := ([^]u8)(libc.malloc(side * side * 4))
	if pixels == nil {
		return
	}
	canvas := pixels[:side * side * 4]
	for i := 0; i < len(canvas); i += 4 {
		canvas[i + 0], canvas[i + 1], canvas[i + 2] =
			EMOJI_MIX_BG.r, EMOJI_MIX_BG.g, EMOJI_MIX_BG.b
		canvas[i + 3] = 255
	}

	if len(emoji) == 1 {
		off := (side - EMOJI_MIX_ONE) / 2
		place_tile(canvas, side, tiles[0], {off, off}, EMOJI_MIX_ONE)
	} else {
		left := (side - 2 * EMOJI_MIX_TWO - EMOJI_MIX_GAP) / 2
		top := (side - EMOJI_MIX_TWO) / 2
		place_tile(canvas, side, tiles[0], {left, top}, EMOJI_MIX_TWO)
		place_tile(
			canvas,
			side,
			tiles[1],
			{left + EMOJI_MIX_TWO + EMOJI_MIX_GAP, top},
			EMOJI_MIX_TWO,
		)
	}

	jpeg: [dynamic]u8
	sink := Jpeg_Sink{context, &jpeg}
	written := stbi.write_jpg_to_func(jpeg_sink, &sink, side, side, 4, pixels, EMOJI_MIX_QUALITY)
	if written == 0 || len(jpeg) == 0 {
		delete(jpeg)
		libc.free(pixels)
		return
	}
	image := rl.Image {
		data   = pixels,
		width  = side,
		height = side,
	}
	return {data = jpeg[:], media_type = "image/jpeg", image = image}, true
}

// Open the picker to build a group image for `dest`.
open_emoji_mix :: proc(ui: ^Ui_State, dest: Gemoji_Dest) {
	ui.picker_mode = .Group_Image
	ui.gemoji_dest = dest
	open_picker(ui, "")
}

// Drop the picked emoji and their render.
@(private)
gemoji_clear :: proc(ui: ^Ui_State) {
	for e in ui.gemoji {
		delete(e)
	}
	clear(&ui.gemoji)
	pic_draft_free(&ui.gemoji_pic)
}


// A pick in Group_Image mode: append it (tap order, left first) and
// re-render. The picker stays open so a second emoji is one tap away.
// pick_emoji has already enforced EMOJI_MIX_MAX.
@(private)
gemoji_add :: proc(ui: ^Ui_State, emoji: string) {
	append(&ui.gemoji, strings.clone(emoji))
	gemoji_render(ui)
}

// Re-render the preview from ui.gemoji. A pick that can't be rendered
// is dropped again, so the preview always matches the chips.
@(private = "file")
gemoji_render :: proc(ui: ^Ui_State) {
	pic_draft_free(&ui.gemoji_pic)
	if len(ui.gemoji) == 0 {
		return
	}
	draft, ok := emoji_mix_render(ui.gemoji[:])
	if !ok {
		set_status(
			ui,
			strings.clone(tr("Couldn't render that emoji. Choose another one.")),
			.Error,
		)
		delete(pop(&ui.gemoji))
		gemoji_render(ui)
		return
	}
	ui.gemoji_pic = draft
	register_local_pic(EMOJI_MIX_PREVIEW, draft.image)
}

// Stage a group image in the new-chat form, replacing any earlier one.
// Takes ownership of `draft`.
@(private)
nc_pic_set :: proc(ui: ^Ui_State, draft: Pic_Draft) {
	pic_draft_free(&ui.nc_pic)
	ui.nc_pic = draft
	register_local_pic(NC_PIC_URL, draft.image)
}

// The new-chat form's preview texture; nil when nothing is staged.
@(private)
nc_pic_tex :: proc(ui: ^Ui_State) -> ^rl.Texture2D {
	return len(ui.nc_pic.data) > 0 ? local_pic(NC_PIC_URL) : nil
}

// Picker header in Group_Image mode: live preview, the picked emoji as
// removable chips, then Use/Cancel. The emoji grid below feeds it.
emoji_mix_header :: proc(ui: ^Ui_State) {
	eyebrow(tr("EMOJI GROUP IMAGE"))
	if clay.UI(clay.ID("GemojiRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 12,
			childAlignment = {y = .Center},
		},
	},
	) {
		preview := len(ui.gemoji) > 0 ? local_pic(EMOJI_MIX_PREVIEW) : nil
		avatar("GemojiPreview", 0, "", "", 56, preview)
		if clay.UI(clay.ID("GemojiSide"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 6,
			},
		},
		) {
			if len(ui.gemoji) == 0 {
				clay.Text(
					tr("No emoji selected"),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
				)
			}
			if clay.UI(clay.ID("GemojiChips"))({layout = {childGap = 6}}) {
				for e, i in ui.gemoji {
					gemoji_chip(u32(i), e)
				}
			}
			clay.Text(
				tr("Choose one or two emoji. Every member sees the same image."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
		}
	}
	if clay.UI(clay.ID("GemojiActions"))({layout = {childGap = 8}}) {
		micro_button("GemojiUse", tr("Use emoji image"), len(ui.gemoji) > 0 ? ACCENT : TEXT_LO)
		micro_button("GemojiCancel", tr("Cancel"))
	}
}

// A picked emoji with its remove mark; clicking anywhere on it removes it.
@(private = "file")
gemoji_chip :: proc(index: u32, emoji: string) {
	if clay.UI(clay.ID("GemojiChip", index))(
	{
		layout = {
			padding = {left = 6, right = 8, top = 2, bottom = 2},
			childGap = 4,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : ROW_BG,
		cornerRadius = rr(6),
	},
	) {
		if clay.UI(clay.ID_LOCAL("GemojiChipImg"))(
		{
			layout = {sizing = {width = clay.SizingFixed(20)}},
			aspectRatio = {1},
			image = {imageData = emoji_tex(emoji)},
		},
		) {}
		clay.Text("×", {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
	}
}

// Header clicks; true when the frame's input was consumed.
handle_emoji_mix :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if clicked("GemojiCancel") {
		close_picker(ui)
		return true
	}
	if clicked("GemojiUse") {
		if len(ui.gemoji_pic.data) > 0 {
			gemoji_apply(ui, client)
		}
		return true
	}
	for _, i in ui.gemoji {
		if clicked_indexed("GemojiChip", u32(i)) {
			delete(ui.gemoji[i])
			ordered_remove(&ui.gemoji, i)
			gemoji_render(ui)
			return true
		}
	}
	return false
}

// "Use emoji image": hand the render to its destination and close.
@(private = "file")
gemoji_apply :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	draft := ui.gemoji_pic
	ui.gemoji_pic = {}
	switch ui.gemoji_dest {
	case .New_Chat:
		nc_pic_set(ui, draft)
	case .Selected_Group:
		if ui.selected >= 0 && ui.selected < len(ui.chats) {
			upload_group_pic(ui, client, ui.chats[ui.selected].group_id, draft)
		} else {
			pic_draft_free(&draft)
		}
	}
	close_picker(ui)
}
