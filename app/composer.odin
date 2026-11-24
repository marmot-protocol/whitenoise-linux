package main

import "core:strings"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(private)
Composer_Action :: enum {
	None,
	More,
	Files,
	Emoji,
	Voice,
	Paste, // Retired. Keep its name and value to decode existing settings.
	Effect,
	Poll,
	Location,
	GM,
	Dictate,
	Stickers,
	Timestamp,
}

@(private)
Composer_Slot :: enum {
	Menu,
	Left,
	Right,
	Send,
	Off,
}

@(private)
Composer_Layout :: enum {
	Automatic,
	Expanded,
}

@(private)
Composer_Surface :: enum {
	Chat,
	Preview,
}

@(private)
Composer_Config :: struct {
	order:  [int(max(Composer_Action))]Composer_Action,
	slots:  [Composer_Action]Composer_Slot,
	layout: Composer_Layout,
}

@(private)
COMPOSER_SHORTCUT_COUNT :: int(max(Composer_Action)) - 1

@(private = "file")
COMPOSER_DEFAULT := Composer_Config {
	order = {
		.More,
		.Files,
		.Emoji,
		.Voice,
		.Effect,
		.Poll,
		.Location,
		.GM,
		.Dictate,
		.Stickers,
		.Timestamp,
		.None,
	},
	slots = #partial{
		.More = .Left,
		.Files = .Left,
		.Emoji = .Right,
		.Voice = .Send,
		.Timestamp = .Right,
	},
}

@(private)
COMPOSER_ACTIONS := #partial [Composer_Action]struct {
	id, icon, name: string,
} {
	.More      = {"ComposeMoreBtn", "+", N_("More tools")},
	.Files     = {"AttachBtn", ICON_CLIP, N_("Attach a file")},
	.Emoji     = {"EmojiBtn", ICON_SMILE, N_("Emoji")},
	.Voice     = {"MicBtn", ICON_MIC, N_("Voice message")},
	.Effect    = {"FxBtn", ICON_FX, N_("Send with an effect")},
	.Poll      = {"PollBtn", ICON_POLL, N_("Create a poll")},
	.Location  = {"LocationBtn", ICON_LOCATION, N_("Send location")},
	.GM        = {"GmBtn", "GM", N_("Say GM (once a day)")},
	.Dictate   = {"DictateBtn", ICON_MIC, N_("Dictate")},
	.Stickers  = {"ComposeStickerBtn", "\U000f136e", N_("Stickers")},
	.Timestamp = {"ComposeTimestampBtn", TIMESTAMP_ICON, N_("Insert timestamp")},
}

@(private)
composer_config :: proc(prefs: ^Prefs) -> ^Composer_Config {
	return prefs.composer.order[0] == .None ? &COMPOSER_DEFAULT : &prefs.composer
}

@(private)
composer_slots :: proc(action: Composer_Action) -> bit_set[Composer_Slot] {
	#partial switch action {
	case .More:
		return {.Left, .Right}
	case .Voice:
		return {.Left, .Right, .Send, .Off}
	case:
		return {.Menu, .Left, .Right}
	}
}

@(private)
composer_config_load :: proc(config: ^Composer_Config) -> bool {
	if config.layout < min(Composer_Layout) || config.layout > max(Composer_Layout) {return false}
	seen: bit_set[Composer_Action]
	order: [len(config.order)]Composer_Action
	count := 0
	for action in config.order {
		if action == .Paste || action == .None {continue}
		if action <= .None || action > max(Composer_Action) || action in seen {return false}
		slot := config.slots[action]
		if slot < min(Composer_Slot) ||
		   slot > max(Composer_Slot) ||
		   slot not_in composer_slots(action) {
			return false
		}
		seen += {action}
		order[count] = action
		count += 1
	}
	if count == COMPOSER_SHORTCUT_COUNT - 1 && .Timestamp not_in seen {
		order[count] = .Timestamp
		config.slots[.Timestamp] = .Menu
		count += 1
	}
	if count != COMPOSER_SHORTCUT_COUNT {return false}
	config.order = order
	config.slots[.Paste] = .Menu
	return true
}

@(private)
Composer_Action_Set :: bit_set[Composer_Action]

@(private)
Composer_Plan :: struct {
	config:        ^Composer_Config,
	pinned, menu:  Composer_Action_Set,
	size:          f32,
	gap:           u16,
	has_text:      bool,
	send_label:    string,
	primary_width: f32,
	inline_width:  f32,
}

@(private = "file")
COMPOSER_SEND_FS :: 13

@(private)
composer_has_text :: proc(ui: ^Ui_State) -> bool {
	return strings.trim_space(string(ui.compose[:])) != ""
}

@(private)
composer_plan :: proc(
	ui: ^Ui_State,
	config: ^Composer_Config,
	width: f32,
	surface: Composer_Surface = .Chat,
) -> Composer_Plan {
	p := Composer_Plan {
		config = config,
		size   = tap_size() ? tap_min() : 28,
		gap    = tap_size() ? 2 : 4,
	}
	p.primary_width = p.size
	if surface == .Chat {
		p.has_text = composer_has_text(ui)
		if !ui.poll_open && ui.editing == "" && (p.has_text || len(ui.staged) > 0) {
			p.send_label = tr("Send")
			p.primary_width = max(
				p.size,
				20 + rl.MeasureTextLine(FONT_TITLE, COMPOSER_SEND_FS, p.send_label, 0).x,
			)
		}
	}
	pitch := p.size + f32(p.gap)
	// More and Send always fit; any additional shortcuts spill back into More.
	p.inline_width = width - p.primary_width - f32(p.gap) - pitch
	draft_min: f32
	if surface == .Chat &&
	   config.layout == .Automatic &&
	   !ui.poll_open &&
	   single_pane() &&
	   short_conversation(ui) &&
	   p.inline_width >= COMPOSER_TEXT_MIN {
		draft_min = COMPOSER_TEXT_MIN
	}
	p.pinned = {.More}
	for action in p.config.order[:COMPOSER_SHORTCUT_COUNT] {
		if action == .More ||
		   (p.has_text && action in Composer_Action_Set{.GM, .Voice}) ||
		   (surface == .Chat &&
				   ui.search_open &&
				   action in Composer_Action_Set{.Poll, .Timestamp}) ||
		   (action == .Dictate && !ui.prefs.stt_enabled) ||
		   (surface == .Chat &&
				   ui.editing != "" &&
				   action in Composer_Action_Set{.Poll, .Location, .GM, .Voice, .Stickers}) {
			continue
		}
		switch p.config.slots[action] {
		case .Send, .Off:
		case .Menu:
			p.menu += {action}
		case .Left, .Right:
			if p.inline_width >= draft_min + pitch {
				p.pinned += {action}
				p.inline_width -= pitch
			} else {
				p.menu += {action}
			}
		}
	}
	return p
}

@(private)
COMPOSER_TEXT_MIN :: f32(96)

@(private)
composer_tools :: proc(ui: ^Ui_State, plan: Composer_Plan, side: Composer_Slot) {
	for action in plan.config.order[:COMPOSER_SHORTCUT_COUNT] {
		if action in plan.pinned && plan.config.slots[action] == side {
			composer_button(ui, action, plan.size)
		}
	}
}

@(private = "file")
composer_button :: proc(ui: ^Ui_State, action: Composer_Action, size: f32) {
	tool := COMPOSER_ACTIONS[action]
	sent := action == .GM && gm_sent_today(ui)
	selected := action == .More && ui.compose_more
	if nendo.box(nendo.id(tool.id))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = selected ? SELECTED : (hovered() ? HOVER : {}),
		radius = rr(6),
	},
	) {
		if !selected && ui.composer_editor.drag.source == .None && hovered() {
			tooltip(sent ? tr("You said GM here today") : tr(tool.name))
		}
		if action == .Effect && ui.fx_armed != 0 {
			if tex := emoji_tex(effect_emoji(ui.fx_armed)); tex != nil {
				if nendo.box(nendo.id("FxBtnArmed"))(
				{width = nendo.fixed(16), aspect = 1, image = tex},
				) {}
				return
			}
		}
		text_icon := action == .More || action == .GM
		color := action == .GM && sent || action == .Effect && ui.fx_armed != 0 ? ACCENT : TEXT_LO
		nendo.text(
			tool.icon,
			{
				font = text_icon ? FONT_TITLE : FONT_ICON,
				size = action == .More ? 22 : (text_icon ? 12 : 14),
				color = color,
			},
		)
	}
}

@(private)
composer_primary :: proc(ui: ^Ui_State, plan: Composer_Plan, surface: Composer_Surface = .Chat) {
	size := plan.size
	if surface == .Chat && (ui.search_open || ui.stt.file != nil && ui.stt.message == "") {
		if nendo.box(nendo.id("ComposePrimaryGap"))({width = nendo.fixed(plan.primary_width)}) {}
		return
	}
	preview := surface == .Preview
	poll := !preview && ui.poll_open
	editing := !preview && ui.editing != ""
	if !poll &&
	   plan.config.slots[.Voice] == .Send &&
	   (preview || (!plan.has_text && len(ui.staged) == 0 && !editing)) {
		composer_button(ui, .Voice, size)
		return
	}
	ready :=
		poll ? ui.poll_ticket == 0 && poll_input_error(ui) == .None : preview || stage_files_ready(ui) && (plan.has_text || len(ui.staged) > 0 && !editing)
	if nendo.box(nendo.id("SendBtn"))(
	{
		width = nendo.fixed(plan.primary_width),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = ready ? (hovered() ? ACCENT_DIM : ACCENT) : ROW_BG,
		radius = rr(8),
	},
	) {
		if ui.composer_editor.drag.source == .None && hovered() {
			if poll {
				tooltip(tr("Create poll"))
			} else if editing {
				tooltip(tap_size() ? tr("Save") : tr("Enter to save. Shift+Enter for a new line."))
			} else {
				tooltip(tap_size() ? tr("Send") : tr("Enter to send. Shift+Enter for a new line."))
			}
		}
		color := ready ? ON_ACCENT : TEXT_LO
		if plan.send_label != "" {
			nendo.text(
				plan.send_label,
				{font = FONT_TITLE, size = COMPOSER_SEND_FS, color = color, wrap = .None},
			)
		} else {
			nendo.text(
				editing ? ICON_CHECK : "\uf1d8",
				{font = FONT_ICON, size = 14, color = color},
			)
		}
	}
}

@(private)
composer_menu :: proc(ui: ^Ui_State, plan: Composer_Plan) {
	anchor, ok := element_box(nendo.id("ComposeMoreBtn"))
	if !ok {return}
	box, box_ok := element_box(nendo.id("ComposeBox"))
	if !box_ok {return}
	width := fit_w(250)
	x, _ := panel_pos(anchor.x, 0, width + 8, 0)
	height := f32(rl.GetScreenHeight()) / UI_ZOOM
	above := box.y - 12
	below := height - box.y - box.height - 12
	open_above := above >= min(220, max(96, below))
	limit := open_above ? above : below
	y := open_above ? box.y - 6 : box.y + box.height + 6
	if limit < 64 {
		// A short window can have no room beside the composer. The menu scrolls from the top.
		open_above, y, limit = false, 8, height - 16
	}
	id := nendo.id("ComposeMoreMenu")
	if nendo.box(id)(
	{
		width = nendo.fixed(width),
		height = nendo.fit(max = limit),
		direction = .Column,
		padding = nendo.pad(4),
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			attach = {element = open_above ? .Left_Bottom : .Left_Top},
			offset = {x, y},
			z = 12,
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		for action in plan.config.order[:COMPOSER_SHORTCUT_COUNT] {
			if action not_in plan.menu {continue}
			tool := COMPOSER_ACTIONS[action]
			sent := action == .GM && gm_sent_today(ui)
			ctx_item(
				tool.id,
				action == .GM ? "" : tool.icon,
				sent ? tr("You said GM here today") : tr(tool.name),
				sent ? ACCENT_DIM : {},
			)
		}
		ctx_item("ComposeCustomize", ICON_SETTINGS, tr("Customize composer"))
	}
	scrollbar(id, 13)
}

@(private)
handle_composer_menu :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if composer_clicked("ComposeMoreBtn") {
		ui.compose_more = !ui.compose_more
		return true
	}
	if !ui.compose_more {return false}
	if rl.IsKeyPressed(.ESCAPE) {
		ui.compose_more = false
		return true
	}
	if !mouse_released() {return false}
	ui.compose_more = false
	if nendo.pointer_over(nendo.id("ComposeMoreMenu")) {
		if composer_clicked("ComposeCustomize") {
			settings_open(ui, client, .General, anchor = "ComposerSettings")
			ui.composer_settings_from_chat = true
		} else {
			handle_composer_action(ui)
		}
	}
	return true
}

@(private = "file")
composer_press: u32

@(private)
composer_capture_press :: proc(ui: ^Ui_State) {
	// The hit list belongs to the last displayed layout, before tools move.
	composer_press = 0
	if !nendo.pointer_over(nendo.id("ComposeTools")) &&
	   !nendo.pointer_over(nendo.id("ComposeMoreMenu")) {return}
	for name in ([2]string{"SendBtn", "ComposeCustomize"}) {
		id := nendo.id(name)
		if nendo.pointer_over(id) {
			composer_press = id.id
			return
		}
	}
	for action in composer_config(&ui.prefs).order[:COMPOSER_SHORTCUT_COUNT] {
		id := nendo.id(COMPOSER_ACTIONS[action].id)
		if nendo.pointer_over(id) {
			composer_press = id.id
			return
		}
	}
}

@(private)
composer_clicked :: proc(name: string) -> bool {
	if !mouse_released() || composer_press == 0 {return false}
	id := nendo.id(name)
	return composer_press == id.id && nendo.pointer_over(id)
}

@(private)
handle_composer_action :: proc(ui: ^Ui_State) -> bool {
	if !mouse_released() {return false}
	for action in composer_config(&ui.prefs).order[:COMPOSER_SHORTCUT_COUNT] {
		if action == .More || !composer_clicked(COMPOSER_ACTIONS[action].id) {continue}
		if (action == .GM || action == .Voice) && composer_has_text(ui) {return true}
		perform_composer_action(ui, action)
		return true
	}
	return false
}

@(private)
perform_composer_action :: proc(ui: ^Ui_State, action: Composer_Action) {
	if thread_send_paused(ui) {return}
	#partial switch action {
	case .Files:
		rl.OpenFileDialog(true)
	case .Emoji:
		ui.sticker_tab, ui.gif_tab = false, false
		open_picker(ui, "")
	case .Stickers:
		ui.sticker_tab, ui.gif_tab = true, false
		ui.sticker_focus = 0
		open_picker(ui, "")
	case .Voice:
		voice_start(ui)
	case .Effect:
		ui.fx_open = true
	case .Poll:
		poll_reset(ui)
	case .Location:
		geo_picker_open(ui)
	case .Timestamp:
		timestamp_picker_open(ui)
	case .Dictate:
		stt_start(ui)
	case .GM:
		if gm_sent_today(ui) {
			toast(ui, tr("You said GM here today."))
		} else {
			text := strings.trim_space(ui.prefs.gm_text)
			confirm_ask(
				ui,
				.Say_GM,
				ui.chats[ui.selected].group_id,
				text == "" ? GM_DEFAULT : text,
			)
		}
	}
}
