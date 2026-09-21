package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import rl "sdlrl"

@(private)
Sticker_Page :: enum {
	Library,
	AddPack,
	Pack,
	Detail,
}

@(private)
Sticker_Control :: enum {
	Normal,
	Selected,
	Primary,
	Danger,
}

@(private)
sticker_control :: proc(id: string, index: u32, label: string, style := Sticker_Control.Normal) {
	if clay.UI(clay.ID(id, index))(
	{
		layout = {
			sizing = {height = clay.SizingFixed(34)},
			padding = {left = 10, right = 10},
			childAlignment = {y = .Center},
		},
		backgroundColor = style == .Primary ? ACCENT : style == .Selected ? SELECTED : hovered() ? HOVER : ROW_BG,
		cornerRadius = rr(7),
	},
	) {
		if hovered() {cursor_raise(.Pointer)}
		clay.Text(
			label,
			{
				fontId = FONT_BODY,
				fontSize = 13,
				textColor = style == .Primary ? ON_ACCENT : style == .Danger ? DANGER : TEXT,
			},
		)
	}
}

@(private)
sticker_copy :: proc(
	id: u32,
	text: string,
	width: f32,
	size: u16 = 14,
	color: clay.Color = TEXT_DIM,
) {
	if clay.UI(clay.ID("StickerCopy", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			layoutDirection = .TopToBottom,
			childGap = 2,
		},
	},
	) {
		for line in wrapped_lines(text, width, size, .Text) {
			clay.Text(
				text[line.start:line.end],
				{fontId = FONT_BODY, fontSize = size, textColor = color, wrapMode = .None},
			)
		}
	}
}

@(private)
sticker_pack_index :: proc(ui: ^Ui_State, coordinate: string) -> int {
	for pack, i in ui.sticker_packs {if pack.coordinate == coordinate {return i}}
	return -1
}

@(private)
message_sticker :: proc(ui: ^Ui_State, index: u32, msg: Msg_Ui) {
	tex: ^rl.Texture2D
	for image in msg.images {if msg.att_keys[image.att] == msg.sticker.sha {tex = image.view; break}}
	if tex == nil && ui != nil {
		for item in ui.stickers {
			if item.ref.pack == msg.sticker.pack &&
			   item.ref.code == msg.sticker.code &&
			   item.ref.sha == msg.sticker.sha {tex = sticker_texture(item); break}
		}
	}
	if clay.UI(clay.ID("MessageSticker", index))(
	{layout = {layoutDirection = .TopToBottom, childGap = 4}},
	) {
		if hovered() {cursor_raise(.Pointer)}
		if tex != nil {
			ratio := f32(tex.width) / f32(max(1, tex.height))
			if clay.UI(clay.ID_LOCAL("MessageStickerArt"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(min(att_w(), min(220, 220 * ratio)))},
				},
				aspectRatio = {ratio},
				image = {imageData = tex},
				userData = rawptr(STICKER_IMAGE),
			},
			) {}
		} else {
			clay.Text(
				tr("Sticker unavailable. Click to view options."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		clay.Text(
			msg.sticker.pack == "" ? tr("Save sticker") : tr("View sticker pack"),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
	}
}

@(private)
sticker_show :: proc(ui: ^Ui_State, ref: Sticker_Ref) {
	sticker_library_open(ui)
	ui.picker_open = false
	ui.sticker_open = true
	ui.sticker_page = ref.pack != "" ? .Pack : ref.sha != "" ? .Detail : .Library
	ui.sticker_loading, ui.sticker_installing = false, false
	ui.sticker_error = ""
	sticker_ref_free(ui.sticker_selected)
	ui.sticker_selected = sticker_ref_clone(ref)
	sticker_pack_free(ui.sticker_pack)
	ui.sticker_pack = {}
	for item in ui.sticker_preview {sticker_item_free(item)}
	clear(&ui.sticker_preview)
	clear(&ui.sticker_input); clear(&ui.sticker_name)
	append(&ui.sticker_input, ref.pack)
	append(&ui.sticker_name, ref.code)
	ui.sticker_focus = 0
	if ref.pack != "" {sticker_open_pack(ui, ref.pack, ref.relay)}
}

@(private)
sticker_open_pack :: proc(ui: ^Ui_State, coordinate, relay: string) {
	if !sticker_coordinate(coordinate) {
		ui.sticker_error = N_(
			"Couldn't find that pack. Enter a sticker pack naddr or coordinate.",
		); return
	}
	if ui.sticker_loading {return}
	ui.sticker_page = .Pack
	for item in ui.sticker_preview {sticker_item_free(item)}
	clear(&ui.sticker_preview)
	sticker_pack_free(ui.sticker_pack)
	ui.sticker_pack = {
		coordinate = strings.clone(coordinate),
	}
	ui.sticker_error = ""
	if index := sticker_pack_index(ui, coordinate); index >= 0 {
		pack := ui.sticker_packs[index]
		ui.sticker_pack.title = strings.clone(pack.title)
		ui.sticker_pack.author = strings.clone(pack.author)
		ui.sticker_pack.event = strings.clone(pack.event)
		ui.sticker_pack.relay = strings.clone(pack.relay)
		for item in ui.stickers {if item.ref.pack == coordinate {append(&ui.sticker_preview, sticker_item_clone(item))}}
		return
	}
	ui.sticker_loading = true
	job := sticker_job_add(.Pack)
	job.input = strings.clone(coordinate)
	relays := make([dynamic]string, context.temp_allocator)
	if strings.has_prefix(relay, "wss://") {append(&relays, relay)}
	for url in ui.prefs.fetch_relays {if strings.has_prefix(url, "wss://") && !slice.contains(relays[:], url) {append(&relays, url)}}
	if len(relays) == 0 {append(&relays, ..DEFAULT_FETCH_RELAYS)}
	job.relays = make([]string, min(len(relays), 4))
	for url, i in relays[:len(job.relays)] {job.relays[i] = strings.clone(url)}
}

@(private)
sticker_matches :: proc(ui: ^Ui_State) -> []int {
	indices := make([dynamic]int, context.temp_allocator)
	filter := strings.to_lower(string(ui.picker_filter[:]), context.temp_allocator)
	for item, i in ui.stickers {
		if ui.sticker_filter == "recent" &&
		   !slice.contains(ui.sticker_recent[:], item.ref.sha) {continue}
		if ui.sticker_filter == "personal" && item.ref.pack != "" {continue}
		if sticker_coordinate(ui.sticker_filter) && item.ref.pack != ui.sticker_filter {continue}
		if filter != "" &&
		   !strings.contains(strings.to_lower(item.label, context.temp_allocator), filter) &&
		   !strings.contains(
				   strings.to_lower(item.ref.code, context.temp_allocator),
				   filter,
			   ) {continue}
		append(&indices, i)
	}
	return indices[:]
}

@(private)
Sticker_Tile_State :: enum {
	Normal,
	Focused,
}

@(private)
sticker_tile :: proc(
	id: string,
	index: int,
	item: Sticker_Item,
	state: Sticker_Tile_State,
	size: f32 = 80,
) {
	if clay.UI(clay.ID(id, u32(index)))(
	{
		layout = {
			sizing = {clay.SizingFixed(size), clay.SizingFixed(size)},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 3,
		},
		backgroundColor = state == .Focused ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(6),
	},
	) {
		tex := sticker_texture(item)
		if tex != nil {
			ratio := f32(tex.width) / f32(max(tex.height, 1))
			if clay.UI(clay.ID_LOCAL("StickerArt"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(min(size - 16, (size - 16) * ratio))},
				},
				aspectRatio = {ratio},
				image = {imageData = tex},
				userData = rawptr(STICKER_IMAGE),
			},
			) {}
		} else {clay.Text(
				sticker_requested[item.ref.sha] && item.ref.sha in sticker_textures ? "?" : "…",
				{fontSize = 18, textColor = TEXT_LO},
			)}
		if hovered() {tooltip(item.label); cursor_raise(.Pointer)}
	}
}

@(private)
sticker_picker :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("StickerPacks"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
			childGap = 6,
		},
		clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		sticker_control("StickerAll", 0, tr("All"), ui.sticker_filter == "" ? .Selected : .Normal)
		sticker_control(
			"StickerRecent",
			0,
			tr("Recent"),
			ui.sticker_filter == "recent" ? .Selected : .Normal,
		)
		sticker_control(
			"StickerPersonal",
			0,
			tr("Your stickers"),
			ui.sticker_filter == "personal" ? .Selected : .Normal,
		)
		for pack, i in ui.sticker_packs {sticker_control("StickerPack", u32(i), pack.title, ui.sticker_filter == pack.coordinate ? .Selected : .Normal)}
	}
	if clay.UI(clay.ID("PickerSearch"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
			padding = clay.PaddingAll(8),
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(6),
	},
	) {
		field_text(ui, "PickerSearch", &ui.picker_filter, tr("Search stickers"), true, 13, TEXT_LO)
	}
	if clay.UI(clay.ID("StickerGrid"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 4,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		matches := sticker_matches(ui)
		if len(matches) == 0 {
			clay.Text(
				tr(
					len(ui.picker_filter) > 0 ? N_("No matching stickers.") : N_("No stickers here yet."),
				),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		columns := max(1, int((modal_w(clay.ID("PickerPanel"), 400) - 24) / 84))
		for start := 0; start < len(matches); start += columns {
			if clay.UI(clay.ID("StickerRow", u32(start)))({layout = {childGap = 4}}) {
				for at in start ..< min(start + columns, len(matches)) {sticker_tile("StickerPick", matches[at], ui.stickers[matches[at]], at == ui.sticker_focus ? .Focused : .Normal)}
			}
		}
	}
	scrollbar(clay.ID("StickerGrid"), 13)
	if sticker_coordinate(
		ui.sticker_filter,
	) {sticker_control("StickerViewPack", 0, tr("View sticker pack"))}
}

@(private)
sticker_send :: proc(ui: ^Ui_State, item: Sticker_Item) {
	if ui.selected < 0 || ui.editing != "" || ui.compose_issue != "" {return}
	job := sticker_job_add(.Send)
	job.item = sticker_item_clone(item)
	job.account = strings.clone(ui.account_ref)
	job.group = strings.clone(ui.chats[ui.selected].group_id)
	job.root = strings.clone(thread_cur(ui))
	job.reply = strings.clone(job.root == "" ? ui.replying : "")
	job.effect = ui.fx_armed
	ui.replying = ""
	ui.fx_armed = 0
	ui.picker_open = false
	ui.focus = .Compose
	for sha, i in ui.sticker_recent {if sha == item.ref.sha {delete(sha); ordered_remove(&ui.sticker_recent, i); break}}
	inject_at(&ui.sticker_recent, 0, strings.clone(item.ref.sha))
	if len(ui.sticker_recent) > 24 {delete(pop(&ui.sticker_recent))}
	sticker_save_library(ui)
}

@(private)
handle_sticker_picker :: proc(ui: ^Ui_State) {
	edit_text(ui, &ui.picker_filter)
	field_mouse(ui, &ui.picker_filter, "PickerSearch")
	if clicked_indexed("StickerManage", 0) {sticker_show(ui, {}); return}
	if clicked_indexed("StickerViewPack", 0) {
		ref := Sticker_Ref {
			pack = strings.clone(ui.sticker_filter),
		}
		defer sticker_ref_free(ref)
		sticker_show(ui, ref); return
	}
	if clicked_indexed(
		"StickerPersonal",
		0,
	) {delete(ui.sticker_filter); ui.sticker_filter = strings.clone("personal")}
	if clicked_indexed(
		"StickerRecent",
		0,
	) {delete(ui.sticker_filter); ui.sticker_filter = strings.clone("recent")}
	if clicked_indexed("StickerAll", 0) {delete(ui.sticker_filter); ui.sticker_filter = ""}
	for pack, i in ui.sticker_packs {
		if clicked_indexed(
			"StickerPack",
			u32(i),
		) {delete(ui.sticker_filter); ui.sticker_filter = strings.clone(pack.coordinate)}
	}
	matches := sticker_matches(ui)
	if rl.IsKeyPressed(.LEFT) {ui.sticker_focus -= 1}
	if rl.IsKeyPressed(.RIGHT) {ui.sticker_focus += 1}
	columns := max(1, int((modal_w(clay.ID("PickerPanel"), 400) - 24) / 84))
	if rl.IsKeyPressed(.UP) {ui.sticker_focus -= columns}
	if rl.IsKeyPressed(.DOWN) {ui.sticker_focus += columns}
	if rl.IsKeyPressed(.TAB) &&
	   len(matches) >
		   0 {sticker_show(ui, ui.stickers[matches[clamp(ui.sticker_focus, 0, len(matches) - 1)]].ref); return}
	ui.sticker_focus = clamp(ui.sticker_focus, 0, max(0, len(matches) - 1))
	for index, at in matches {
		if rl.IsMouseButtonPressed(.RIGHT) &&
		   clay.PointerOver(
			   clay.ID("StickerPick", u32(index)),
		   ) {sticker_show(ui, ui.stickers[index].ref); return}
		if clicked_indexed("StickerPick", u32(index)) ||
		   at == ui.sticker_focus &&
			   rl.IsKeyPressed(.ENTER) {sticker_send(ui, ui.stickers[index]); return}
	}
	if rl.IsKeyPressed(.ESCAPE) ||
	   mouse_released() &&
		   !clay.PointerOver(clay.ID("PickerPanel")) {ui.picker_open = false; ui.focus = .Compose}
}

@(private)
sticker_panel :: proc(ui: ^Ui_State) {
	width := modal_w(clay.ID("StickerPanel"), 640)
	if clay.UI(clay.ID("StickerPanel"))(
	{
		layout = {
			sizing = {
				clay.SizingFixed(width),
				clay.SizingFixed(
					modal_h(
						ui.sticker_page == .AddPack ? 300 : ui.sticker_page == .Detail ? 520 : 640,
					),
				),
			},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(16),
			childGap = 16,
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 15,
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("StickerHeader"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			if ui.sticker_page != .Library {sticker_control("StickerBack", 0, tr("Back"))}
			if clay.UI(clay.ID("StickerTitle"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {
				title := tr("Stickers")
				if ui.sticker_page == .AddPack {title = tr("Add pack")}
				if ui.sticker_page ==
				   .Pack {title = ui.sticker_pack.title != "" ? ui.sticker_pack.title : tr("Sticker pack")}
				if ui.sticker_page == .Detail {title = tr("Sticker")}
				if ui.sticker_page == .Pack {
					sticker_copy(6, title, width - 184, 18, TEXT)
				} else {clay.Text(title, {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})}
			}
			sticker_control("StickerClose", 0, tr("Close"))
		}
		if ui.sticker_page == .Library {
			if clay.UI(clay.ID("StickerLibraryActions"))({layout = {childGap = 8}}) {
				sticker_control("StickerImport", 0, tr("Import image"))
				sticker_control("StickerAddPack", 0, tr("Add pack"), .Primary)
			}
		}
		if clay.UI(clay.ID("StickerContent", u32(ui.sticker_page)))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 12,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			switch ui.sticker_page {
			case .Library:
				counts := make([]int, len(ui.sticker_packs), context.temp_allocator)
				covers := make([]^rl.Texture2D, len(ui.sticker_packs), context.temp_allocator)
				pack_indices := make(map[string]int, context.temp_allocator)
				for pack, i in ui.sticker_packs {pack_indices[pack.coordinate] = i}
				for item in ui.stickers {
					if i, found := pack_indices[item.ref.pack]; found {
						counts[i] += 1
						if covers[i] == nil {covers[i] = sticker_texture(item)}
					}
				}
				if !ui.sticker_loaded {clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})}
				if len(ui.sticker_packs) > 0 {eyebrow("YOUR PACKS")}
				for pack, i in ui.sticker_packs {
					if clay.UI(clay.ID("StickerLibraryPack", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = clay.PaddingAll(12),
							childGap = 12,
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() ? HOVER : ROW_BG,
						cornerRadius = rr(8),
					},
					) {
						if hovered() {cursor_raise(.Pointer)}
						cover := covers[i]
						if clay.UI(clay.ID_LOCAL("PackCover"))(
						{
							layout = {
								sizing = {clay.SizingFixed(52), clay.SizingFixed(52)},
								childAlignment = {x = .Center, y = .Center},
							},
						},
						) {
							if cover != nil {
								ratio := f32(cover.width) / f32(max(cover.height, 1))
								if clay.UI(clay.ID_LOCAL("PackCoverArt"))(
								{
									layout = {
										sizing = {width = clay.SizingFixed(min(48, 48 * ratio))},
									},
									aspectRatio = {ratio},
									image = {imageData = cover},
								},
								) {}
							}
						}
						if clay.UI(clay.ID_LOCAL("PackLabel"))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								layoutDirection = .TopToBottom,
								childGap = 6,
							},
						},
						) {
							sticker_copy(0x100 + u32(i), pack.title, width - 156, 15, TEXT)
							clay.Text(
								fmt.tprintf(tr("Stickers: %d"), counts[i]),
								{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
							)
						}
						clay.Text("›", {fontId = FONT_BODY, fontSize = 22, textColor = TEXT_DIM})
					}
				}
				eyebrow("YOUR STICKERS")
				personal := make([dynamic]int, context.temp_allocator)
				for item, i in ui.stickers {if item.ref.pack == "" {append(&personal, i)}}
				if len(personal) ==
				   0 {sticker_copy(0, tr("Import an image to make your first sticker."), width - 40)}
				columns := max(1, int((width - 32) / 112))
				for start := 0; start < len(personal); start += columns {
					if clay.UI(clay.ID("StickerLibraryRow", u32(start)))(
					{layout = {childGap = 8}},
					) {
						for at in start ..< min(start + columns, len(personal)) {sticker_tile("StickerLibraryItem", personal[at], ui.stickers[personal[at]], .Normal, 104)}
					}
				}
			case .AddPack:
				sticker_copy(
					1,
					tr("Paste a pack link to preview its stickers before adding it."),
					width - 40,
					15,
				)
				if clay.UI(clay.ID("StickerInput"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(42)},
						padding = clay.PaddingAll(10),
					},
					backgroundColor = ROW_BG,
					cornerRadius = rr(7),
				},
				) {
					field_text(
						ui,
						"StickerInput",
						&ui.sticker_input,
						tr("Pack link or address"),
						true,
						14,
						TEXT_LO,
					)
				}
			case .Pack:
				if ui.sticker_selected.sha != "" {
					found := false
					for item in ui.sticker_preview {found ||= item.ref.sha == ui.sticker_selected.sha && item.ref.code == ui.sticker_selected.code}
					if !ui.sticker_loading &&
					   !found {sticker_copy(2, tr("This sticker is not in the current pack."), width - 40, 13)}
				}
				if ui.sticker_loading {clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})}
				if len(ui.sticker_preview) > 0 {
					clay.Text(
						fmt.tprintf(tr("Stickers: %d"), len(ui.sticker_preview)),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
					)
					columns := max(1, int((width - 32) / 112))
					for start := 0; start < len(ui.sticker_preview); start += columns {
						if clay.UI(clay.ID("StickerPreviewRow", u32(start)))(
						{layout = {childGap = 8}},
						) {
							for index in start ..< min(start + columns, len(ui.sticker_preview)) {sticker_tile("StickerPreviewTile", index, ui.sticker_preview[index], ui.sticker_preview[index].ref.sha == ui.sticker_selected.sha ? .Focused : .Normal, 104)}
						}
					}
					sticker_copy(3, tr("Click a sticker for a larger preview."), width - 40, 13)
				}
			case .Detail:
				tex := sticker_textures[ui.sticker_selected.sha]
				if tex ==
				   nil {view, _ := media_cached(.Sticker, ui.sticker_selected.sha); tex = (^rl.Texture2D)(view)}
				if clay.UI(clay.ID("StickerPreviewStage"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow(),
							height = clay.SizingFixed(min(280, width - 32)),
						},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = ROW_BG,
					cornerRadius = rr(10),
				},
				) {
					if tex != nil {
						ratio := f32(tex.width) / f32(max(tex.height, 1))
						size := min(240, width - 64)
						if clay.UI(clay.ID("StickerPersonalPreview"))(
						{
							layout = {
								sizing = {width = clay.SizingFixed(min(size, size * ratio))},
							},
							aspectRatio = {ratio},
							image = {imageData = tex},
							userData = rawptr(STICKER_IMAGE),
						},
						) {}
					} else {clay.Text(
							tr("Loading…"),
							{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
						)}
				}
				if ui.sticker_selected.pack == "" {
					clay.Text(
						tr("Sticker name"),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
					)
					if clay.UI(clay.ID("StickerName"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(42)},
							padding = clay.PaddingAll(10),
						},
						backgroundColor = ROW_BG,
						cornerRadius = rr(7),
					},
					) {
						field_text(
							ui,
							"StickerName",
							&ui.sticker_name,
							tr("Sticker name"),
							true,
							14,
							TEXT_LO,
						)
					}
				} else {sticker_copy(4, string(ui.sticker_name[:]), width - 40, 15, TEXT)}
			}
			if ui.sticker_error != "" {
				sticker_copy(5, tr(ui.sticker_error), width - 40, 13, DANGER)
				sticker_control("StickerRetry", 0, tr("Retry"))
			}
		}
		scrollbar(clay.ID("StickerContent", u32(ui.sticker_page)), 16)
		if clay.UI(clay.ID("StickerFooter"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
				childAlignment = {y = .Center},
			},
		},
		) {
			if ui.sticker_page ==
			   .AddPack {sticker_control("StickerLookup", 0, tr("Preview pack"), .Primary)}
			if ui.sticker_page == .Pack ||
			   ui.sticker_page == .Detail && ui.sticker_selected.pack != "" {
				if sticker_pack_index(ui, ui.sticker_pack.coordinate) >= 0 {
					clay.Text(
						tr("Added to your stickers"),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
					)
					if clay.UI(clay.ID("StickerFooterGap"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					sticker_control("StickerRemovePack", 0, tr("Remove pack"), .Danger)
				} else if len(ui.sticker_preview) >
				   0 {sticker_control("StickerInstall", 0, tr(ui.sticker_installing ? N_("Adding…") : N_("Add pack")), .Primary)}
			}
			if ui.sticker_page == .Detail && ui.sticker_selected.pack == "" {
				sticker_control("StickerSave", 0, tr("Save sticker"), .Primary)
				for item in ui.stickers {
					if item.ref.pack == "" && item.ref.sha == ui.sticker_selected.sha {
						sticker_control("StickerRemove", 0, tr("Remove sticker"), .Danger); break
					}
				}
			}
		}
	}
}

@(private)
sticker_finish_install :: proc(ui: ^Ui_State) {
	for item in ui.sticker_preview {if !(item.ref.sha in sticker_textures) {return}}
	ui.sticker_installing = false
	added := 0
	for item in ui.sticker_preview {
		if sticker_textures[item.ref.sha] == nil {continue}
		sticker_add_item(ui, item); added += 1
	}
	if added ==
	   0 {ui.sticker_error = N_("Couldn't add the pack. No supported stickers are available."); return}
	p := ui.sticker_pack
	append(
		&ui.sticker_packs,
		Sticker_Pack {
			strings.clone(p.coordinate),
			strings.clone(p.title),
			strings.clone(p.author),
			strings.clone(p.event),
			strings.clone(p.relay),
		},
	)
	sticker_save_library(ui)
}

@(private)
handle_sticker_panel :: proc(ui: ^Ui_State) {
	if clicked_indexed("StickerBack", 0) ||
	   rl.IsKeyPressed(.ESCAPE) && ui.sticker_page != .Library {
		if ui.sticker_page == .Detail &&
		   ui.sticker_selected.pack != "" {ui.sticker_page = .Pack} else {sticker_show(ui, {})}
		return
	}
	if rl.IsKeyPressed(.ESCAPE) ||
	   clicked_indexed("StickerClose", 0) ||
	   mouse_released() && !clay.PointerOver(clay.ID("StickerPanel")) {
		ui.sticker_open =
			false; ui.sticker_installing = false; ui.picking_sticker = false; ui.focus = .Compose; return
	}
	if !ui.sticker_loaded {
		if clicked_indexed("StickerRetry", 0) {ui.sticker_error = ""; sticker_library_open(ui)}
		return
	}
	if clicked_indexed("StickerAddPack", 0) {ui.sticker_page = .AddPack; return}
	for pack, i in ui.sticker_packs {
		if clicked_indexed(
			"StickerLibraryPack",
			u32(i),
		) {sticker_show(ui, {pack = pack.coordinate}); return}
	}
	items := ui.sticker_page == .Pack ? ui.sticker_preview[:] : ui.stickers[:]
	for item, i in items {
		id := ui.sticker_page == .Pack ? "StickerPreviewTile" : "StickerLibraryItem"
		if !clicked_indexed(id, u32(i)) {continue}
		sticker_ref_free(ui.sticker_selected)
		ui.sticker_selected = sticker_ref_clone(item.ref)
		clear(&ui.sticker_name); append(&ui.sticker_name, item.label)
		ui.sticker_page = .Detail
		return
	}
	if ui.sticker_page == .AddPack ||
	   ui.sticker_page == .Detail && ui.sticker_selected.pack == "" {
		buf := ui.sticker_page == .AddPack ? &ui.sticker_input : &ui.sticker_name
		id := ui.sticker_page == .AddPack ? "StickerInput" : "StickerName"
		edit_text(ui, buf); field_mouse(ui, buf, id)
	}
	if clicked_indexed("StickerImport", 0) {ui.picking_sticker = true; rl.OpenFileDialog(false)}
	if clicked_indexed("StickerLookup", 0) ||
	   rl.IsKeyPressed(.ENTER) && ui.sticker_page == .AddPack {
		coordinate, relay := sticker_pack_input(string(ui.sticker_input[:]))
		sticker_open_pack(ui, coordinate, relay)
	}
	if clicked_indexed("StickerInstall", 0) &&
	   !ui.sticker_installing &&
	   sticker_pack_index(ui, ui.sticker_pack.coordinate) < 0 {
		ui.sticker_installing = true
		for item in ui.sticker_preview {sticker_texture(item)}
	}
	if clicked_indexed("StickerRemovePack", 0) {
		coordinate := ui.sticker_pack.coordinate
		for i := len(ui.stickers) - 1; i >= 0; i -= 1 {
			if ui.stickers[i].ref.pack ==
			   coordinate {sticker_item_free(ui.stickers[i]); ordered_remove(&ui.stickers, i)}
		}
		if index := sticker_pack_index(ui, coordinate);
		   index >=
		   0 {sticker_pack_free(ui.sticker_packs[index]); ordered_remove(&ui.sticker_packs, index)}
		sticker_save_library(ui)
	}
	if clicked_indexed("StickerRemove", 0) {
		for i := len(ui.stickers) - 1; i >= 0; i -= 1 {
			if ui.stickers[i].ref.sha == ui.sticker_selected.sha &&
			   ui.stickers[i].ref.pack ==
				   "" {sticker_item_free(ui.stickers[i]); ordered_remove(&ui.stickers, i)}
		}
		sticker_save_library(ui); sticker_show(ui, {}); return
	}
	if clicked_indexed("StickerSave", 0) {
		label := strings.trim_space(string(ui.sticker_name[:]))
		if len(label) == 0 ||
		   utf8.rune_count_in_string(label) >
			   64 {ui.sticker_error = N_("Enter a sticker name of 1 to 64 characters."); return}
		for &item in ui.stickers {
			if item.ref.sha == ui.sticker_selected.sha && item.ref.pack == "" {
				delete(item.label); delete(item.ref.code)
				item.label, item.ref.code = strings.clone(label), strings.clone(label)
				sticker_save_library(ui); sticker_show(ui, {}); return
			}
		}
		for msg in ui.messages {
			if msg.sticker.sha != ui.sticker_selected.sha {continue}
			for key, i in msg.att_keys {
				if key != ui.sticker_selected.sha {continue}
				job := sticker_job_add(.Receive)
				job.item = {
					ref = {sha = strings.clone(key), code = strings.clone(label)},
					label = strings.clone(label),
					mime = strings.clone(media_type_for(msg.att_names[i])),
				}
				return
			}
		}
		ui.sticker_error = N_(
			"Couldn't save the sticker. Wait for its image to load and try again.",
		)
	}
	if clicked_indexed("StickerRetry", 0) {
		ui.sticker_error = ""
		if ui.sticker_pack.coordinate != "" && len(ui.sticker_preview) == 0 {
			coordinate := strings.clone(ui.sticker_pack.coordinate); defer delete(coordinate)
			sticker_open_pack(ui, coordinate, ui.sticker_selected.relay)
		} else {
			for item in ui.sticker_preview {
				if tex, seen := sticker_textures[item.ref.sha]; seen && tex == nil {
					key, _ := delete_key(&sticker_textures, item.ref.sha); delete(key)
					key, _ = delete_key(&sticker_requested, item.ref.sha); delete(key)
				}
			}
			sticker_save_library(ui)
		}
	}
}
