package main

import "core:strings"
import "core:text/edit"

import "nendo"
import rl "sdlrl"

@(private = "file")
SHRUG :: "¯\\_(ツ)_/¯"

@(private = "file")
Slash_Id :: enum u8 {
	Poll,
	Attach,
	Effect,
	Emoji,
	GM,
	Location,
	Shrug,
	Stickers,
	Time,
}

@(private = "file")
Slash_Trigger :: enum {
	Pick,
	Exact,
}

@(private = "file")
Slash_Command :: struct {
	name:    string,
	action:  Composer_Action,
	trigger: Slash_Trigger,
	insert:  string,
	preview: string,
}

@(private = "file")
SLASH_COMMANDS := [Slash_Id]Slash_Command {
	.Poll = {name = "/poll", action = .Poll, trigger = .Exact},
	.Attach = {name = "/attach", action = .Files},
	.Effect = {name = "/effect", action = .Effect},
	.Emoji = {name = "/emoji", action = .Emoji},
	.GM = {name = "/gm", action = .GM},
	.Location = {name = "/location", action = .Location},
	.Shrug = {name = "/shrug", insert = `¯\\\_(ツ)\_/¯`, preview = SHRUG},
	.Stickers = {name = "/stickers", action = .Stickers},
	.Time = {name = "/time", action = .Timestamp, trigger = .Exact},
}

@(private)
Slash_Menu :: struct {
	rows:                       [len([Slash_Id]u8)]Slash_Id,
	count, query_len, selected: int,
	dismissed:                  bool,
}

@(private)
slash_open :: proc(ui: ^Ui_State) -> bool {
	return(
		ui.slash.count > 0 &&
		!ui.slash.dismissed &&
		!ui.poll_open &&
		ui.focus == .Compose &&
		ui.editing == "" &&
		!ui.search_open &&
		!ui.show_members &&
		!ui.ctx_open &&
		!ui.compose_more &&
		!ui.fx_open &&
		!ui.picker_open &&
		len(rl.Preedit()) == 0 &&
		!modal_open(ui) \
	)
}

@(private = "file")
slash_matches :: proc(draft: string) -> (menu: Slash_Menu) {
	if !strings.has_prefix(draft, "/") {
		return
	}
	for command, i in SLASH_COMMANDS {
		if len(draft) <= len(command.name) &&
		   strings.equal_fold(draft, command.name[:len(draft)]) {
			menu.rows[menu.count] = i
			menu.count += 1
		}
	}
	menu.query_len = menu.count > 0 ? len(draft) : 0
	return
}

@(private = "file")
slash_pick :: proc(ui: ^Ui_State, row: Slash_Id) {
	command := SLASH_COMMANDS[row]
	ui.slash = {}
	if command.insert != "" {
		ed_begin(ui, &ui.compose)
		ui.ed.selection = {len(ui.compose), 0}
		// Keep the backslash and underscores literal in Markdown.
		edit.input_text(&ui.ed, command.insert)
		ed_end(ui, &ui.compose)
		return
	}
	if thread_send_paused(ui) {return}
	ed_set(ui, &ui.compose, "")
	drop_draft(ui)
	perform_composer_action(ui, command.action)
}

@(private)
handle_slash_menu :: proc(ui: ^Ui_State, typed_len: int) -> bool {
	menu := &ui.slash
	was_dismissed := menu.dismissed
	next := slash_matches(string(ui.compose[:]))
	if next.query_len != menu.query_len || next.rows != menu.rows || next.count != menu.count {
		menu^ = next
		if scroll := nendo.scroll(nendo.id("SlashMenu")); scroll.found {
			scroll.position.y = 0
		}
	}
	if !slash_open(ui) {
		return false
	}
	if rl.IsKeyPressed(.ESCAPE) {
		menu.dismissed = true
		return true
	}
	if !shortcut_down() && !shift_down() {
		if !was_dismissed && menu.query_len == typed_len && menu.count == 1 {
			command := SLASH_COMMANDS[menu.rows[0]]
			if command.trigger == .Exact && menu.query_len == len(command.name) {
				slash_pick(ui, menu.rows[0])
				return true
			}
		}
		step := int(key_hit(.DOWN)) - int(key_hit(.UP))
		if step != 0 {
			menu.selected = (menu.selected + step + menu.count) % menu.count
			row := u32(menu.rows[menu.selected])
			scroll_into_view(nendo.id("SlashMenu"), nendo.id("SlashRow", row))
			return true
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.TAB) {
			slash_pick(ui, menu.rows[menu.selected])
			return true
		}
	}
	if mouse_released() {
		for row in menu.rows[:menu.count] {
			id := nendo.id("SlashRow", u32(row))
			if menu_press == id && nendo.pointer_over(id) {
				slash_pick(ui, row)
				return true
			}
		}
	}
	return false
}

@(private)
slash_popover :: proc(ui: ^Ui_State) {
	box, box_ok := element_box(nendo.id("ComposeBox"))
	field, field_ok := element_box(nendo.id("ComposeClip"))
	if !box_ok || !field_ok {
		return
	}
	id := nendo.id("SlashMenu")
	width := fit_w(320, 8)
	x, _ := panel_pos(field.x, 0, width + 8, 0)
	row_h := tap_size() ? tap_min() : 26
	y := box.y - 6
	limit := min(260, max(row_h + 8, y - 8))
	if nendo.box(id)(
	{
		width = nendo.fixed(width),
		height = nendo.fit(max = limit),
		direction = .Column,
		padding = nendo.pad(4),
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			attach = {element = .Left_Bottom},
			offset = {x, max(y, limit + 8)},
			z = 12,
		},
	},
	) {
		for row, i in ui.slash.rows[:ui.slash.count] {
			command := SLASH_COMMANDS[row]
			row_id := nendo.id("SlashRow", u32(row))
			menu_press_mark(row_id)
			if nendo.box(row_id)(
			{
				width = nendo.grow(),
				height = nendo.fixed(row_h),
				padding = {left = 8, right = 8},
				gap = 8,
				align = {y = .Center},
				color = i == ui.slash.selected ? SELECTED : (hovered() ? HOVER : {}),
				radius = rr(6),
			},
			) {
				desc :=
					command.preview != "" ? command.preview : tr(COMPOSER_ACTIONS[command.action].name)
				name_w := rl.MeasureTextLine(FONT_MONO, 14, command.name, 0).x
				nendo.text(command.name, {font = FONT_MONO, size = 14, color = TEXT, wrap = .None})
				nendo.text(
					text_ellipsis(desc, max(0, width - 40 - name_w), FONT_BODY, 12),
					{font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None},
				)
			}
		}
	}
	scrollbar(id, 13)
}
