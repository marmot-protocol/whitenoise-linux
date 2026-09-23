// Chat-list row actions: the right-click menu on a rail row (pin,
// mute, mark read/unread, folders, export) plus the folder modal and
// the rail ordering and folder navigation they drive.
//
// marmot's C API exports no per-group pin, mute or mark-unread setter
// (only marmot_set_group_archived and marmot_mark_timeline_message_read),
// so those three live in Prefs, keyed by group id. The local mute is
// folded into the row's `muted` flag in row_to_ui, which is what the
// notification gate already reads.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"


Folder_Mode :: enum {
	Move,
	Create,
	Edit,
}

FOLDER_MARMOT_ICON :: 48
FOLDER_ICONS := [49]string {
	ICON_FOLDER,
	ICON_CODE,
	ICON_PEOPLE,
	ICON_STAR,
	ICON_CHATS,
	ICON_LOCK,
	"\uf0b1",
	"\uf015",
	"\uf004",
	"\uf02d",
	"\uf073",
	"\uf072",
	"\uf001",
	"\uf03e",
	"\uf008",
	"\uf11b",
	"\uf07a",
	"\uf0f5",
	"\uf0f4",
	"\uf21e",
	"\uf0eb",
	"\uf1ea",
	"\uf0c3",
	"\uf06c",
	"\uf1b0",
	"\uf0d6",
	"\uf0ae",
	"\uf046",
	"\uf0e0",
	"\uf0f3",
	"\uf132",
	"\uf084",
	"\uf0ac",
	"\uf041",
	"\uf0ad",
	"\uf1fc",
	"\uf030",
	"\uf019",
	"\uf187",
	"\uf08d",
	"\uf1cd",
	"\uf0c1",
	"\uf0c2",
	"\uf135",
	"\uf024",
	"\uf06b",
	"\uf091",
	"\uf108",
	"", // Marmot uses the bundled artwork instead of a font glyph.
}
FOLDER_ICON_NAMES := [49]string {
	N_("Folder"),
	N_("Code"),
	N_("People"),
	N_("Favorites"),
	N_("Conversations"),
	N_("Private"),
	N_("Work"),
	N_("Home"),
	N_("Family"),
	N_("Study"),
	N_("Calendar"),
	N_("Travel"),
	N_("Music"),
	N_("Photos"),
	N_("Videos"),
	N_("Games"),
	N_("Shopping"),
	N_("Food"),
	N_("Coffee"),
	N_("Fitness"),
	N_("Ideas"),
	N_("News"),
	N_("Science"),
	N_("Nature"),
	N_("Pets"),
	N_("Money"),
	N_("Projects"),
	N_("Tasks"),
	N_("Email"),
	N_("Notifications"),
	N_("Security"),
	N_("Keys"),
	N_("World"),
	N_("Location"),
	N_("Tools"),
	N_("Design"),
	N_("Camera"),
	N_("Downloads"),
	N_("Archive"),
	N_("Pinned"),
	N_("Support"),
	N_("Links"),
	N_("Cloud"),
	N_("Rocket"),
	N_("Flag"),
	N_("Gift"),
	N_("Trophy"),
	N_("Monitor"),
	N_("Marmot"),
}

FOLDER_COLORS := [12]u32 {
	0xEF6B73,
	0xF59E62,
	0xE5B85C,
	0xE8D86B,
	0xA7CE67,
	0x65C890,
	0x62C9B8,
	0x63C9DF,
	0x76A6F0,
	0xA993EF,
	0xE994C4,
	0xA6ADB8,
}
FOLDER_COLOR_NAMES := [12]string {
	N_("Red"),
	N_("Orange"),
	N_("Amber"),
	N_("Yellow"),
	N_("Lime"),
	N_("Green"),
	N_("Teal"),
	N_("Cyan"),
	N_("Blue"),
	N_("Violet"),
	N_("Pink"),
	N_("Gray"),
}

@(private = "file")
folder_rgb :: proc(rgb: u32) -> clay.Color {
	return {f32((rgb >> 16) & 0xff), f32((rgb >> 8) & 0xff), f32(rgb & 0xff), 255}
}

folder_color :: proc(ui: ^Ui_State, name: string) -> clay.Color {
	if name != "" {
		if rgb, ok := ui.prefs.folder_colors[name]; ok {return folder_rgb(rgb)}
	}
	return ACCENT
}

// Blank selects the theme default; zero is a valid custom RGB value.
@(private = "file")
folder_color_draft :: proc(ui: ^Ui_State) -> (rgb: u32, custom, valid: bool) {
	text := strings.trim_space(string(ui.folder_color_input[:]))
	if text == "" {return 0, false, true}
	if len(text) != 7 || text[0] != '#' {return 0, true, false}
	for c in text[1:] {
		digit: u32
		switch {
		case c >= '0' && c <= '9':
			digit = u32(c - '0')
		case c >= 'a' && c <= 'f':
			digit = u32(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			digit = u32(c - 'A') + 10
		case:
			return 0, true, false
		}
		rgb = (rgb << 4) | digit
	}
	return rgb, true, true
}

folder_icon :: proc(ui: ^Ui_State, name: string, size: u16) {
	index := name == "" ? 0 : clamp(ui.prefs.folder_icons[name], 0, len(FOLDER_ICONS) - 1)
	folder_icon_draw(index, size, folder_color(ui, name))
}

@(private = "file")
folder_icon_draw :: proc(index: int, size: u16, color: clay.Color) {
	index := clamp(index, 0, len(FOLDER_ICONS) - 1)
	if index != FOLDER_MARMOT_ICON {
		clay.Text(FOLDER_ICONS[index], {fontId = FONT_ICON, fontSize = size, textColor = color})
		return
	}
	if clay.UI(clay.ID_LOCAL("FolderMarmot"))(
	{
		layout = {sizing = {clay.SizingFixed(f32(size) + 4), clay.SizingFixed(f32(size) + 4)}},
		image = {imageData = builtin_tex_by_code("marmot")},
		backgroundColor = fade(color, 0.2),
		cornerRadius = rr(4),
		border = {color = color, width = bw()},
	},
	) {}
}
// Rail order: pinned chats first, each half keeping marmot's activity
// order. Returns indices into `chats`.
rail_order :: proc(
	chats: []Chat_Row_Ui,
	pinned: map[string]bool,
	allocator := context.temp_allocator,
) -> [dynamic]int {
	order := make([dynamic]int, 0, len(chats), allocator)
	for chat, i in chats {
		if pinned[chat.group_id] {
			append(&order, i)
		}
	}
	for chat, i in chats {
		if !pinned[chat.group_id] {
			append(&order, i)
		}
	}
	return order
}

// Flip a group id in a local set; returns the new state. The removed
// key's clone is left to the process, like the other local sets here.
toggle_flag :: proc(set: ^map[string]bool, group_id: string) -> bool {
	if set[group_id] {
		delete_key(set, group_id)
		return false
	}
	set[strings.clone(group_id)] = true
	return true
}

// Right-click menu for a rail row, the slint chat-list row menu.
// The row a menu was opened on. It outlives the close (which sets the
// index to -1), so the menu can finish animating out over the chat it
// belongs to.
row_menu_shown: int

// The row the menu is showing, live while open and remembered while it
// closes.
row_menu_index :: proc(ui: ^Ui_State) -> int {
	if ui.row_menu >= 0 {
		row_menu_shown = ui.row_menu
	}
	return row_menu_shown
}

chat_row_menu :: proc(ui: ^Ui_State) {
	chat := ui.chats[row_menu_index(ui)]

	if clay.UI(clay.ID("RowMenu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFit({min = 210})},
			padding = clay.PaddingAll(4),
			childGap = 1,
		},
		floating = {
			attachTo = .Root,
			offset = {ui.row_menu_x, ui.row_menu_y + rise(clay.ID("RowMenu"))},
			zIndex = 10,
		},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		ctx_item("RowPin", ICON_PIN, ui.prefs.pinned[chat.group_id] ? "Unpin" : "Pin to top")
		ctx_item("RowMute", ICON_BELL_OFF, ui.prefs.muted_ids[chat.group_id] ? "Unmute" : "Mute")
		ctx_item("RowRead", ICON_ENVELOPE_OPEN, "Mark read")
		ctx_item("RowUnread", ICON_ENVELOPE, "Mark unread")
		ctx_item("RowFolder", ICON_FOLDER, "Move to folder")
		ctx_item("RowExportHtml", ICON_DOWNLOAD, "Export as HTML")
		ctx_item("RowExportMd", ICON_DOWNLOAD, "Export as Markdown")
	}
}

// Folder menus float at the root so the rail's scroll clip cannot cut them off.
folder_menu :: proc(ui: ^Ui_State) {
	width: f32 = 210
	height: f32 = ui.folder_menu_name == "" ? 40 : 73
	if data := clay.GetElementData(clay.ID("FolderMenu")); data.found {
		width = max(width, data.boundingBox.width)
	}
	x, y := panel_pos(ui.folder_menu_x - width, ui.folder_menu_y, width, height)
	if clay.UI(clay.ID("FolderMenu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFit({min = 210})},
			padding = clay.PaddingAll(4),
			childGap = 1,
		},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 10},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if ui.folder_menu_name == "" {
			ctx_item("FolderCreate", ICON_FOLDER, "New folder")
		} else {
			ctx_item("FolderMenuEdit", ICON_PENCIL, N_("Edit folder"))
			ctx_item("FolderMenuDelete", ICON_TRASH, "Delete")
		}
	}
}

@(private = "file")
open_folder_menu :: proc(ui: ^Ui_State, name: string = "", index: int = -1) {
	delete(ui.folder_menu_name)
	ui.folder_menu_name = strings.clone(name)
	anchor := index < 0 ? clay.ID("ChatsMenuBtn") : clay.ID("FolderMenuBtn", u32(index))
	if data := clay.GetElementData(anchor); data.found {
		box := data.boundingBox
		ui.folder_menu_x = box.x + box.width
		ui.folder_menu_y = box.y + box.height + 4
	}
	ui.folder_menu_open = true
}

// Capture menu dismissal as well as actions, never passing a release to a chat.
handle_folder_navigation :: proc(ui: ^Ui_State) -> bool {
	if ui.folder_menu_open {
		if rl.IsKeyPressed(.ESCAPE) ||
		   (rl.IsMouseButtonPressed(.RIGHT) && !clay.PointerOver(clay.ID("FolderMenu"))) {
			ui.folder_menu_open = false
			return true
		}
		if mouse_released() {
			ui.folder_menu_open = false
			if ui.folder_menu_name == "" {
				if clay.PointerOver(clay.ID("FolderCreate")) {
					open_folder_modal(ui)
				}
			} else {
				for name, i in ui.prefs.folders {
					if name != ui.folder_menu_name {continue}
					if clay.PointerOver(clay.ID("FolderMenuEdit")) {
						open_folder_modal(ui, rename = i)
					} else if clay.PointerOver(clay.ID("FolderMenuDelete")) {
						delete_folder(ui, i)
					}
					break
				}
			}
		}
		return true
	}
	if ui.page != .Chats {return false}
	if clicked("ChatsMenuBtn") {
		open_folder_menu(ui)
		return true
	}
	if clicked("ChatViewBtn") {
		ui.prefs.recent_chats = !ui.prefs.recent_chats
		if data := clay.GetScrollContainerData(clay.ID("ChatList")); data.found {
			data.scrollPosition.y = 0
		}
		scroll_residual = {}
		save_settings(ui)
		return true
	}
	if !ui.prefs.recent_chats && mouse_released() {
		for i in 0 ..= len(ui.prefs.folders) {
			name := i < len(ui.prefs.folders) ? ui.prefs.folders[i] : ""
			// A nested menu button must win over its section header.
			if i < len(ui.prefs.folders) && clay.PointerOver(clay.ID("FolderMenuBtn", u32(i))) {
				open_folder_menu(ui, name, i)
				return true
			}
			if clay.PointerOver(clay.ID("FolderHeader", u32(i))) {
				toggle_flag(&ui.prefs.collapsed_folders, name)
				save_settings(ui)
				return true
			}
		}
	}
	return false
}

@(private)
open_folder_modal :: proc(ui: ^Ui_State, gid: string = "", rename: int = -1) {
	delete(ui.folder_gid)
	ui.folder_gid = strings.clone(gid)
	ui.folder_rename = rename
	ui.folder_icon = 0
	ui.folder_mode = gid != "" ? .Move : .Create
	ed_set(ui, &ui.folder_input, "")
	ed_set(ui, &ui.folder_search, "")
	ed_set(ui, &ui.folder_color_input, "")
	if rename >= 0 && rename < len(ui.prefs.folders) {
		ui.folder_mode = .Edit
		name := ui.prefs.folders[rename]
		ed_set(ui, &ui.folder_input, name)
		ui.folder_icon = clamp(ui.prefs.folder_icons[name], 0, len(FOLDER_ICONS) - 1)
		if rgb, ok := ui.prefs.folder_colors[name]; ok {
			ed_set(ui, &ui.folder_color_input, fmt.tprintf("#%06X", rgb))
		}
	}
	if data := clay.GetScrollContainerData(clay.ID("FolderList")); data.found {
		data.scrollPosition.y = 0
	}
	if data := clay.GetScrollContainerData(clay.ID("FolderEditorBody")); data.found {
		data.scrollPosition.y = 0
	}
	ui.folder_menu_open = false
	ui.folder_open = true
	ui.focus = .Folder
}

@(private = "file")
folder_destination :: proc(ui: ^Ui_State, name: string, index: int, active: bool) {
	if clay.UI(clay.ID("FolderDestination", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
			padding = {left = 12, right = 12},
			childGap = 12,
			childAlignment = {y = .Center},
		},
		backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(9),
	},
	) {
		folder_icon(ui, name, 16)
		if clay.UI(clay.ID("FolderDestinationName", u32(index)))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				name == "" ? tr("Unfiled") : name,
				{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT, wrapMode = .None},
			)
		}
		if active {
			clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 13, textColor = ACCENT})
		}
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private)
folder_action :: proc(id, label: string, primary: bool = false) {
	if clay.UI(clay.ID(id))(
	{
		layout = {
			sizing = {height = clay.SizingFixed(36)},
			padding = {left = 14, right = 14},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = primary ? (hovered() ? ACCENT_DIM : ACCENT) : (hovered() ? HOVER : ROW_BG),
		cornerRadius = rr(9),
		border = primary ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		clay.Text(
			label,
			{fontId = FONT_TITLE, fontSize = 13, textColor = primary ? ON_ACCENT : TEXT_DIM},
		)
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private = "file")
folder_editor_focus :: proc(ui: ^Ui_State, focus: Focus) {
	ui.focus = focus
	body := clay.GetElementData(clay.ID("FolderEditorBody")).boundingBox
	field :=
		clay.GetElementData(clay.ID(focus == .FolderColor ? "FolderColorBox" : "FolderBox")).boundingBox
	scroll := clay.GetScrollContainerData(clay.ID("FolderEditorBody"))
	if scroll.found {
		if field.y < body.y {scroll.scrollPosition.y += body.y - field.y}
		if field.y + field.height > body.y + body.height {
			scroll.scrollPosition.y -= field.y + field.height - body.y - body.height
		}
	}
}

@(private = "file")
folder_editor :: proc(ui: ^Ui_State, width: f32) {
	rgb, custom, valid := folder_color_draft(ui)
	preview := custom && valid ? folder_rgb(rgb) : ACCENT
	columns := clamp(int((width - 40 + 8) / 50), 4, 8)
	if clay.UI(clay.ID("FolderEditorBody"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {
				width = clay.SizingGrow(),
				height = clay.SizingFixed(max(60, modal_h(620) - 144)),
			},
			childGap = 12,
			padding = {right = 6, bottom = 4},
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		clay.Text(tr("Folder name"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
		if clay.UI(clay.ID("FolderBox"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(40)},
				padding = {left = 12, right = 12},
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(9),
			border = {color = ui.focus == .Folder ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			folder_icon_draw(ui.folder_icon, 17, preview)
			field_text(
				ui,
				"FolderBox",
				&ui.folder_input,
				tr("Folder name"),
				ui.focus == .Folder,
				14,
				TEXT_LO,
			)
		}
		eyebrow(N_("COLOR"))
		if clay.UI(clay.ID("FolderColorDefault"))(
		{
			layout = {
				sizing = {height = clay.SizingFixed(32)},
				padding = {left = 10, right = 10},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = !custom ? SELECTED : (hovered() ? HOVER : ROW_BG),
			border = {color = !custom ? ACCENT : FIELD_BORDER, width = bw()},
			cornerRadius = rr(8),
		},
		) {
			clay.Text(ICON_FOLDER, {fontId = FONT_ICON, fontSize = 13, textColor = ACCENT})
			clay.Text(tr("Default"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			if hovered() {cursor_raise(.Pointer)}
		}
		for row in 0 ..< 2 {
			if clay.UI(clay.ID("FolderColorRow", u32(row)))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
			) {
				for column in 0 ..< 6 {
					i := row * 6 + column
					selected := custom && valid && rgb == FOLDER_COLORS[i]
					if clay.UI(clay.ID("FolderColor", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = selected ? SELECTED : (hovered() ? HOVER : ROW_BG),
						border = {color = selected ? ACCENT : FIELD_BORDER, width = bw()},
						cornerRadius = rr(8),
					},
					) {
						if clay.UI(clay.ID("FolderColorSwatch", u32(i)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(20),
									height = clay.SizingFixed(20),
								},
							},
							backgroundColor = folder_rgb(FOLDER_COLORS[i]),
							cornerRadius = rr(10),
						},
						) {}
						if hovered() {
							tooltip(FOLDER_COLOR_NAMES[i])
							cursor_raise(.Pointer)
						}
					}
				}
			}
		}
		clay.Text(tr("Custom color"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
		if clay.UI(clay.ID("FolderColorBox"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(9),
			border = {color = ui.focus == .FolderColor ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(
				ui,
				"FolderColorBox",
				&ui.folder_color_input,
				"#RRGGBB",
				ui.focus == .FolderColor,
				13,
				TEXT_LO,
			)
		}
		clay.Text(
			tr("Enter a color as #RRGGBB."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
		)
		eyebrow(N_("ICON"))
		if clay.UI(clay.ID("FolderIconGrid"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
			},
		},
		) {
			for row in 0 ..< (len(FOLDER_ICONS) + columns - 1) / columns {
				if clay.UI(clay.ID("FolderIconRow", u32(row)))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
				) {
					for column in 0 ..< columns {
						i := row * columns + column
						if i >= len(FOLDER_ICONS) {
							if clay.UI(clay.ID("FolderIconGap", u32(i)))(
							{layout = {sizing = {width = clay.SizingGrow()}}},
							) {}
							continue
						}
						selected := ui.folder_icon == i
						if clay.UI(clay.ID("FolderIcon", u32(i)))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow(),
									height = clay.SizingFixed(42),
								},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = selected ? SELECTED : (hovered() ? HOVER : ROW_BG),
							border = {color = selected ? ACCENT : FIELD_BORDER, width = bw()},
							cornerRadius = rr(9),
						},
						) {
							folder_icon_draw(i, 20, preview)
							if hovered() {
								tooltip(FOLDER_ICON_NAMES[i])
								cursor_raise(.Pointer)
							}
						}
					}
				}
			}
		}
	}
	scrollbar(clay.ID("FolderEditorBody"), 14)
}

// A destination picker and a separate, compact folder editor share one shell.
folder_modal :: proc(ui: ^Ui_State) {
	moving := ui.folder_mode == .Move
	width := modal_w(clay.ID("FolderModal"), moving ? 440 : 480)
	if clay.UI(clay.ID("FolderModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(width)},
			padding = clay.PaddingAll(20),
			childGap = 16,
		},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("FolderModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("FolderHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 12,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("FolderTitle"))({layout = {sizing = {width = clay.SizingGrow()}}}) {
				title :=
					moving ? tr("Move to folder") : (ui.folder_mode == .Edit ? tr("Edit folder") : tr("New folder"))
				clay.Text(title, {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			}
			if clay.UI(clay.ID("FolderClose"))(
			{
				layout = {padding = clay.PaddingAll(7)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(7),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
				if hovered() {cursor_raise(.Pointer)}
			}
		}
		if moving {
			clay.Text(
				tr("Choose a destination for this chat."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("FolderSearchBox"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(40)},
					padding = {left = 12, right = 12},
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(9),
				border = {color = ui.focus == .Folder ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 13, textColor = TEXT_LO})
				field_text(
					ui,
					"FolderSearchBox",
					&ui.folder_search,
					tr("Search folders..."),
					ui.focus == .Folder,
					13,
					TEXT_LO,
				)
			}
			query := strings.to_lower(
				strings.trim_space(string(ui.folder_search[:])),
				context.temp_allocator,
			)
			current := ui.prefs.folder_of[ui.folder_gid]
			has_current := false
			destinations := make([]int, len(ui.prefs.folders), context.temp_allocator)
			matches := 0
			for name, i in ui.prefs.folders {
				has_current = has_current || (ui.folder_gid != "" && name == current)
				if query != "" &&
				   !strings.contains(
						   strings.to_lower(name, context.temp_allocator),
						   query,
					   ) {continue}
				destinations[matches] = i
				matches += 1
			}
			if clay.UI(clay.ID("FolderList"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFit({max = max(44, min(264, modal_h(580) - 290))}),
					},
					childGap = 4,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				view := clay.GetScrollContainerData(clay.ID("FolderList"))
				height := view.found ? view.scrollContainerDimensions.height : 264
				offset := view.found ? -view.scrollPosition.y : 0
				first := clamp(int(offset / 48) - 2, 0, matches)
				last := clamp(int((offset + height) / 48) + 3, first, matches)
				if first > 0 {
					if clay.UI(clay.ID("FolderDestinationsBefore"))(
					{layout = {sizing = {height = clay.SizingFixed(f32(first) * 48 - 4)}}},
					) {}
				}
				for i in destinations[first:last] {
					name := ui.prefs.folders[i]
					folder_destination(ui, name, i, ui.folder_gid != "" && name == current)
				}
				if last < matches {
					if clay.UI(clay.ID("FolderDestinationsAfter"))(
					{
						layout = {
							sizing = {height = clay.SizingFixed(f32(matches - last) * 48 - 4)},
						},
					},
					) {}
				}
				if matches == 0 && query != "" {
					clay.Text(
						tr("No folders match your search."),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
					)
				}
			}
			scrollbar(clay.ID("FolderList"), 14)
			// Keep Unfiled reachable even while searching or scrolling a long list.
			folder_destination(ui, "", len(ui.prefs.folders), ui.folder_gid != "" && !has_current)
		} else {
			folder_editor(ui, width)
		}
		if clay.UI(clay.ID("FolderActions"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}},
		) {
			if moving {
				folder_action("FolderNew", tr("New folder"))
			}
			if clay.UI(clay.ID("FolderActionsGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			folder_action("FolderCancel", tr("Cancel"))
			if !moving {
				folder_action(
					"FolderSave",
					ui.folder_mode == .Edit ? tr("Save") : tr("Create folder"),
					true,
				)
			}
		}
	}
}

// Open the row menu at the pointer, clamped like the message one
// (ponytail: rough clamp from an estimated panel size).
open_row_menu :: proc(ui: ^Ui_State, index: int) {
	m := rl.GetMousePosition()
	ui.row_menu = index
	ui.row_menu_x, ui.row_menu_y = panel_pos(m.x / UI_ZOOM, m.y / UI_ZOOM, 230, 250)
}

// Clicks in the open row menu; anything unhandled closes it.
handle_row_menu :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.row_menu < 0 || ui.row_menu >= len(ui.chats) || rl.IsKeyPressed(.ESCAPE) {
		ui.row_menu = -1
		return
	}
	if rl.IsMouseButtonPressed(.RIGHT) && !clay.PointerOver(clay.ID("RowMenu")) {
		ui.row_menu = -1
		return
	}
	if !mouse_released() {
		return
	}
	index := ui.row_menu
	gid := ui.chats[index].group_id
	ui.row_menu = -1

	if clay.PointerOver(clay.ID("RowFolder")) {
		open_folder_modal(ui, gid)
		return
	}
	if clay.PointerOver(clay.ID("RowPin")) {
		toggle_flag(&ui.prefs.pinned, gid)
		save_settings(ui)
		return
	}
	if clay.PointerOver(clay.ID("RowMute")) {
		toggle_flag(&ui.prefs.muted_ids, gid)
		save_settings(ui)
		refresh_after_action(ui, client) // row_to_ui folds the flag back in
		return
	}
	if clay.PointerOver(clay.ID("RowRead")) {
		mark_chat_read(ui, client, index)
		return
	}
	if clay.PointerOver(clay.ID("RowUnread")) {
		ui.prefs.unread_ids[strings.clone(gid)] = true
		save_settings(ui)
		return
	}
	if clay.PointerOver(clay.ID("RowExportHtml")) {
		export_chat(ui, client, .Html, index)
		return
	}
	if clay.PointerOver(clay.ID("RowExportMd")) {
		export_chat(ui, client, .Markdown, index)
		return
	}
}

// Clear a chat's badge without opening it: drop the manual reminder
// and tell marmot the latest message was read.
mark_chat_read :: proc(ui: ^Ui_State, client: ^marmot.Client, index: int) {
	chat := ui.chats[index]
	if chat.group_id in ui.prefs.unread_ids {
		delete_key(&ui.prefs.unread_ids, chat.group_id)
		save_settings(ui)
	}
	if len(chat.last_id) == 0 {
		return
	}

	row: ^marmot.Chat_List_Row
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(chat.group_id, context.temp_allocator)
	message := strings.clone_to_cstring(chat.last_id, context.temp_allocator)
	if marmot.mark_timeline_message_read(client, account, group, message, &row) != .OK {
		ui.client_status = fmt.aprintf("Couldn't mark the chat read. %s", marmot.last_error())
		return
	}
	ui.chats[index].unread = row.unread_count
	delete(ui.chats[index].first_unread)
	ui.chats[index].first_unread = strings.clone(string(row.first_unread_message_id_hex))
	marmot.chat_list_row_free(row)
}

@(private = "file")
close_folder_modal :: proc(ui: ^Ui_State) {
	// Keep the mode and field contents intact while the modal animates away.
	ui.folder_open = false
	ui.focus = .Compose
}

// The outer modal dispatcher consumes every click, including dismissal.
handle_folder_modal :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("FolderClose") || (mouse_released() && !clay.PointerOver(clay.ID("FolderModal"))) {
		close_folder_modal(ui)
		return
	}
	if rl.IsKeyPressed(.ESCAPE) || clicked("FolderCancel") {
		if ui.folder_mode == .Create && ui.folder_gid != "" {
			ui.folder_mode = .Move
			ui.focus = .Folder
		} else {
			close_folder_modal(ui)
		}
		return
	}

	if ui.folder_mode == .Move {
		edit_text(ui, &ui.folder_search)
		if field_mouse(ui, &ui.folder_search, "FolderSearchBox") {
			ui.focus = .Folder
			return
		}
		if clicked("FolderNew") {
			ui.folder_mode = .Create
			ui.focus = .Folder
			return
		}
		if mouse_released() {
			for name, i in ui.prefs.folders {
				if clay.PointerOver(clay.ID("FolderDestination", u32(i))) {
					assign_folder(ui, name)
					return
				}
			}
			if clay.PointerOver(clay.ID("FolderDestination", u32(len(ui.prefs.folders)))) {
				assign_folder(ui, "")
			}
		}
		return
	}

	if ui.focus == .FolderColor {
		edit_text(ui, &ui.folder_color_input)
	} else {
		edit_text(ui, &ui.folder_input)
	}
	if field_mouse(ui, &ui.folder_color_input, "FolderColorBox") {
		ui.focus = .FolderColor
		return
	}
	if field_mouse(ui, &ui.folder_input, "FolderBox", 14) {
		ui.focus = .Folder
		return
	}
	if rl.IsKeyPressed(.TAB) {
		folder_editor_focus(ui, ui.focus == .FolderColor ? .Folder : .FolderColor)
	}
	if clicked("FolderColorDefault") {
		ed_set(ui, &ui.folder_color_input, "")
		return
	}
	if mouse_released() {
		for color, i in FOLDER_COLORS {
			if clay.PointerOver(clay.ID("FolderColor", u32(i))) {
				ed_set(ui, &ui.folder_color_input, fmt.tprintf("#%06X", color))
				return
			}
		}
		for _, i in FOLDER_ICONS {
			if clay.PointerOver(clay.ID("FolderIcon", u32(i))) {
				ui.folder_icon = i
				return
			}
		}
	}
	if clicked("FolderSave") || rl.IsKeyPressed(.ENTER) {
		name := strings.trim_space(string(ui.folder_input[:]))
		if name == "" {return}
		for folder, i in ui.prefs.folders {
			if folder == name && (ui.folder_mode != .Edit || i != ui.folder_rename) {
				toast(ui, tr("Folder names must be unique. Choose a different name."))
				return
			}
		}
		rgb, custom, valid := folder_color_draft(ui)
		if !valid {
			toast(ui, tr("Enter a color as #RRGGBB."))
			folder_editor_focus(ui, .FolderColor)
			return
		}
		if ui.folder_mode == .Edit {
			if ui.folder_rename < 0 || ui.folder_rename >= len(ui.prefs.folders) {return}
			old := ui.prefs.folders[ui.folder_rename]
			if old != name {
				for gid, folder in ui.prefs.folder_of {
					if folder == old {
						ui.prefs.folder_of[gid] = strings.clone(name)
					}
				}
				if collapsed, ok := ui.prefs.collapsed_folders[old]; ok {
					ui.prefs.collapsed_folders[strings.clone(name)] = collapsed
				}
				delete_key(&ui.prefs.collapsed_folders, old)
				delete_key(&ui.prefs.folder_icons, old)
				delete_key(&ui.prefs.folder_colors, old)
				ui.prefs.folders[ui.folder_rename] = strings.clone(name)
			}
		} else {
			append(&ui.prefs.folders, strings.clone(name))
		}
		ui.prefs.folder_icons[strings.clone(name)] = clamp(
			ui.folder_icon,
			0,
			len(FOLDER_ICONS) - 1,
		)
		if custom {
			ui.prefs.folder_colors[strings.clone(name)] = rgb
		} else {
			delete_key(&ui.prefs.folder_colors, name)
		}
		if ui.folder_mode == .Create && ui.folder_gid != "" {
			assign_folder(ui, name)
			return
		}
		save_settings(ui)
		close_folder_modal(ui)
	}
}

// Remove only organization metadata; the chats themselves are untouched.
@(private)
delete_folder :: proc(ui: ^Ui_State, index: int) {
	name := ui.prefs.folders[index]
	orphans := make([dynamic]string, context.temp_allocator)
	for gid, folder in ui.prefs.folder_of {
		if folder == name {
			append(&orphans, gid)
		}
	}
	for gid in orphans {
		delete_key(&ui.prefs.folder_of, gid)
	}
	delete_key(&ui.prefs.collapsed_folders, name)
	delete_key(&ui.prefs.folder_icons, name)
	delete_key(&ui.prefs.folder_colors, name)
	ordered_remove(&ui.prefs.folders, index)
	if ui.folder_rename == index {
		ui.folder_rename = -1
		clear(&ui.folder_input)
		clear(&ui.folder_color_input)
	} else if ui.folder_rename > index {
		ui.folder_rename -= 1
	}
	save_settings(ui)
}

// Put the modal's chat in `name` ("" takes it out of every folder).
@(private = "file")
assign_folder :: proc(ui: ^Ui_State, name: string) {
	if ui.folder_gid == "" {return}
	if len(name) == 0 {
		delete_key(&ui.prefs.folder_of, ui.folder_gid)
	} else {
		ui.prefs.folder_of[strings.clone(ui.folder_gid)] = strings.clone(name)
	}
	save_settings(ui)
	close_folder_modal(ui)
}
