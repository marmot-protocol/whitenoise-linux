// Automatic folders: each folder may carry rules, and a chat that no one
// has moved by hand files under the first folder, in folder order, whose
// rules match it.
//
//   chat ── placed by hand? ──yes──► that folder
//             │ no
//             ▼
//   folders[0].rules match? ──yes──► folders[0]
//   folders[1].rules match? ──yes──► folders[1]
//   ...                        no ──► Unfiled
//
// Rules are evaluated in their saved order; a folder matches when all of
// them hold, or any one of them, per its Folder_Match.
package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

@(private)
Folder_Rule_Kind :: enum {
	Name_Has, // the chat title contains a word, case-insensitive
	Has_Member, // a pubkey is in the group
	Fewer_Than, // the group has fewer than `count` people
	More_Than, // the group has more than `count` people
	Unread, // the chat has unread messages or a manual unread mark
}

@(private)
Folder_Rule :: struct {
	kind:  Folder_Rule_Kind,
	value: string, // Name_Has: lowercased word; Has_Member: pubkey hex
	count: int, // Fewer_Than / More_Than bound
}

@(private)
Folder_Match :: enum {
	All,
	Any,
}

@(private)
Folder_Rules :: struct {
	match: Folder_Match,
	rules: [dynamic]Folder_Rule,
}

// One editor row: the typed text stays raw until Save parses it.
@(private)
Folder_Rule_Draft :: struct {
	kind:  Folder_Rule_Kind,
	input: [dynamic]u8,
}

// The editor reserves this many rows up front, so the edit state's
// pointer into a row's buffer survives "Add rule".
@(private)
FOLDER_RULES_CAP :: 16

@(private)
FOLDER_RULE_LABELS := [Folder_Rule_Kind]string {
	.Name_Has   = N_("Name includes"),
	.Has_Member = N_("Has member"),
	.Fewer_Than = N_("Fewer than"),
	.More_Than  = N_("More than"),
	.Unread     = N_("Has unread messages"),
}

@(private = "file")
FOLDER_RULE_ICONS := [Folder_Rule_Kind]string {
	.Name_Has   = ICON_PENCIL,
	.Has_Member = ICON_PROFILE,
	.Fewer_Than = ICON_PEOPLE,
	.More_Than  = ICON_PEOPLE,
	.Unread     = ICON_ENVELOPE,
}

// What the rules read about one chat, gathered once per frame.
@(private)
Chat_Facts :: struct {
	title:   string, // lowercased
	unread:  bool,
	members: []string, // pubkey hex, including you
	known:   bool, // members were read; size rules never guess
}

@(private)
folder_rule_holds :: proc(rule: Folder_Rule, facts: Chat_Facts) -> bool {
	switch rule.kind {
	case .Name_Has:
		return strings.contains(facts.title, rule.value)
	case .Has_Member:
		return slice.contains(facts.members, rule.value)
	case .Fewer_Than:
		return facts.known && len(facts.members) < rule.count
	case .More_Than:
		return facts.known && len(facts.members) > rule.count
	case .Unread:
		return facts.unread
	}
	return false
}

// A folder without rules never matches.
@(private)
folder_rules_match :: proc(set: Folder_Rules, facts: Chat_Facts) -> bool {
	if len(set.rules) == 0 {return false}
	for rule in set.rules {
		held := folder_rule_holds(rule, facts)
		if set.match == .Any && held {return true}
		if set.match == .All && !held {return false}
	}
	return set.match == .All
}

// Where a chat files: a hand placement ("" keeps it in Unfiled) into a
// folder that still exists, else the first folder whose rules match,
// else Unfiled (len(folders)).
@(private)
chat_folder_slot :: proc(ui: ^Ui_State, chat: ^Chat_Row_Ui, slots: map[string]int) -> int {
	unfiled := len(ui.prefs.folders)
	if folder, placed := ui.prefs.folder_of[chat.group_id]; placed {
		if folder == "" {return unfiled}
		if slot, found := slots[folder]; found {return slot}
	}
	if len(ui.prefs.folder_rules) == 0 {return unfiled}

	members, known := ui.chat_members[chat.group_id]
	facts := Chat_Facts {
		title   = strings.to_lower(chat.title, context.temp_allocator),
		unread  = chat.unread > 0 || ui.prefs.unread_ids[chat.group_id],
		members = members,
		known   = known,
	}
	for name, i in ui.prefs.folders {
		if folder_rules_match(ui.prefs.folder_rules[name], facts) {return i}
	}
	return unfiled
}

// Membership costs one marmot read per chat, so the chat list asks for
// it only while some rule looks at members.
@(private)
folder_rules_need_members :: proc(prefs: Prefs) -> bool {
	for _, set in prefs.folder_rules {
		for rule in set.rules {
			if rule.kind == .Has_Member || rule.kind == .Fewer_Than || rule.kind == .More_Than {
				return true
			}
		}
	}
	return false
}

// Worker side: every row's member pubkeys, keyed by group id. A group
// whose read fails is left out and its size rules stay false.
@(private)
chat_members_fetch :: proc(
	client: ^marmot.Client,
	account: cstring,
	rows: ^marmot.Presented_Chat_List,
	out: ^map[string][]string,
) {
	for i in 0 ..< rows.rows_len {
		group := rows.rows[i].row.group_id_hex
		list: ^marmot.Group_Member_Record_List
		if marmot.group_members(client, account, group, &list) != .OK {continue}
		ids := make([]string, list.len)
		for member, j in list.items[:list.len] {
			ids[j] = strings.clone(string(member.member_id_hex))
		}
		marmot.app_group_member_record_list_free(list)
		out[strings.clone(string(group))] = ids
	}
}

@(private)
chat_members_free :: proc(members: ^map[string][]string) {
	for group, ids in members {
		for id in ids {delete(id)}
		delete(ids)
		delete(group)
	}
	delete(members^)
	members^ = nil
}

@(private)
folder_rules_free :: proc(set: Folder_Rules) {
	for rule in set.rules {delete(rule.value)}
	delete(set.rules)
}

// Keep a chat in `name` by hand; "" keeps it in Unfiled.
@(private)
folder_place :: proc(ui: ^Ui_State, group_id, name: string) {
	if folder, placed := &ui.prefs.folder_of[group_id]; placed {
		delete(folder^)
		folder^ = strings.clone(name)
		return
	}
	ui.prefs.folder_of[strings.clone(group_id)] = strings.clone(name)
}

// Drop a hand placement, handing the chat back to folder rules.
@(private)
folder_unplace :: proc(ui: ^Ui_State, group_id: string) {
	if group_id not_in ui.prefs.folder_of {return}
	key, folder := delete_key(&ui.prefs.folder_of, group_id)
	delete(key)
	delete(folder)
}

// True when a chat sits where it is because someone put it there.
@(private)
folder_placed :: proc(ui: ^Ui_State, group_id: string) -> bool {
	folder, placed := ui.prefs.folder_of[group_id]
	return placed && (folder == "" || slice.contains(ui.prefs.folders[:], folder))
}

// Drop a folder's rules, key included.
@(private)
folder_rules_drop :: proc(ui: ^Ui_State, name: string) {
	if name not_in ui.prefs.folder_rules {return}
	key, set := delete_key(&ui.prefs.folder_rules, name)
	folder_rules_free(set)
	delete(key)
}

// Store a parsed rule set under `name`; an empty set removes the entry.
@(private)
folder_rules_store :: proc(ui: ^Ui_State, name: string, set: Folder_Rules) {
	folder_rules_drop(ui, name)
	if len(set.rules) == 0 {
		folder_rules_free(set)
		return
	}
	ui.prefs.folder_rules[strings.clone(name)] = set
}

@(private = "file")
folder_rule_typed :: proc(kind: Folder_Rule_Kind) -> bool {
	return kind != .Unread
}

@(private = "file")
folder_rule_counts :: proc(kind: Folder_Rule_Kind) -> bool {
	return kind == .Fewer_Than || kind == .More_Than
}

@(private = "file")
folder_rule_box_id :: proc(index: int) -> string {
	return fmt.tprintf("FolderRuleBox%d", index)
}

@(private = "file")
folder_rule_pick_id :: proc(kind: Folder_Rule_Kind) -> string {
	return fmt.tprintf("FolderRulePick%d", int(kind))
}

@(private = "file")
folder_rules_clear :: proc(ui: ^Ui_State) {
	for draft in ui.folder_rules {delete(draft.input)}
	clear(&ui.folder_rules)
	reserve(&ui.folder_rules, FOLDER_RULES_CAP)
}

// Fill the editor rows from a folder's saved rules ("" = a new folder).
@(private)
folder_rules_load :: proc(ui: ^Ui_State, name: string) {
	folder_rules_clear(ui)
	ui.folder_rule_focus = 0
	ui.folder_rule_menu = -1
	ui.folder_match = .All
	if name == "" {return}
	set := ui.prefs.folder_rules[name]
	ui.folder_match = set.match
	for rule in set.rules[:min(len(set.rules), FOLDER_RULES_CAP)] {
		draft := Folder_Rule_Draft {
			kind = rule.kind,
		}
		switch rule.kind {
		case .Name_Has:
			append(&draft.input, rule.value)
		case .Has_Member:
			npub := hex_npub(rule.value)
			append(&draft.input, npub)
			delete(npub)
		case .Fewer_Than, .More_Than:
			append(&draft.input, fmt.tprintf("%d", rule.count))
		case .Unread:
		}
		append(&ui.folder_rules, draft)
	}
}

// Parse the editor rows. Blank rows are skipped. On a row that doesn't
// parse, `bad` is its index and `why` the toast; the set is then empty.
@(private)
folder_rules_parse :: proc(ui: ^Ui_State) -> (set: Folder_Rules, bad: int, why: string) {
	set.match = ui.folder_match
	for draft, i in ui.folder_rules {
		text := strings.trim_space(string(draft.input[:]))
		rule := Folder_Rule {
			kind = draft.kind,
		}
		switch draft.kind {
		case .Name_Has:
			if text == "" {continue}
			rule.value = strings.to_lower(text)
		case .Has_Member:
			if text == "" {continue}
			hex := mention_hex(text)
			if hex == "" {
				folder_rules_free(set)
				return {}, i, tr("Enter the member as an npub and try again.")
			}
			rule.value = strings.clone(hex)
		case .Fewer_Than, .More_Than:
			if text == "" {continue}
			count, ok := strconv.parse_int(text, 10)
			if !ok || count < 0 {
				folder_rules_free(set)
				return {}, i, tr("Enter the number of people as a whole number and try again.")
			}
			rule.count = count
		case .Unread:
		}
		append(&set.rules, rule)
	}
	return set, -1, ""
}

// RULES section of the folder editor: one row per rule (type menu,
// value box, remove), the all/any toggle, and "Add rule".
@(private)
folder_rules_editor :: proc(ui: ^Ui_State) {
	eyebrow(tr("RULES"))
	clay.Text(
		tr(
			"Chats that match file here automatically. People counts include you. A chat you move by hand stays where you put it.",
		),
		{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
	)
	if len(ui.folder_rules) > 1 {
		if clay.UI(clay.ID("FolderMatch"))({layout = {childGap = 8}}) {
			folder_match_chip("FolderMatchAll", tr("Match all rules"), ui.folder_match == .All)
			folder_match_chip("FolderMatchAny", tr("Match any rule"), ui.folder_match == .Any)
		}
	}
	for &draft, i in ui.folder_rules {
		folder_rule_row(ui, &draft, i)
	}
	if len(ui.folder_rules) < FOLDER_RULES_CAP {
		folder_action("FolderRuleAdd", tr("Add rule"))
	}
}

@(private = "file")
folder_match_chip :: proc(id, label: string, selected: bool) {
	if clay.UI(clay.ID(id))(
	{
		layout = {
			sizing = {height = clay.SizingFixed(32)},
			padding = {left = 12, right = 12},
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? SELECTED : (hovered() ? HOVER : ROW_BG),
		border = {color = selected ? ACCENT : FIELD_BORDER, width = bw()},
		cornerRadius = rr(8),
	},
	) {
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private = "file")
folder_rule_row :: proc(ui: ^Ui_State, draft: ^Folder_Rule_Draft, index: int) {
	menu_open := ui.folder_rule_menu == index
	if clay.UI(clay.ID("FolderRule", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID("FolderRuleKind", u32(index)))(
		{
			layout = {
				sizing = {height = clay.SizingFixed(36)},
				padding = {left = 10, right = 10},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = menu_open ? SELECTED : (hovered() ? HOVER : ROW_BG),
			border = {color = menu_open ? ACCENT : FIELD_BORDER, width = bw()},
			cornerRadius = rr(9),
		},
		) {
			clay.Text(
				FOLDER_RULE_ICONS[draft.kind],
				{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM},
			)
			clay.Text(
				tr(FOLDER_RULE_LABELS[draft.kind]),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
			)
			clay.Text("\u2304", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
			if hovered() && !menu_open {
				tooltip(tr("Change rule type"))
				cursor_raise(.Pointer)
			}
			if menu_open {
				folder_rule_menu(index)
			}
		}
		if folder_rule_typed(draft.kind) {
			focused := ui.focus == .FolderRule && ui.folder_rule_focus == index
			id := folder_rule_box_id(index)
			counts := folder_rule_counts(draft.kind)
			if clay.UI(clay.ID(id))(
			{
				layout = {
					sizing = {
						width = counts ? clay.SizingFixed(72) : clay.SizingGrow(),
						height = clay.SizingFixed(36),
					},
					padding = {left = 12, right = 12},
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(9),
				border = {color = focused ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				placeholder := draft.kind == .Has_Member ? "npub1..." : (counts ? "0" : tr("Word"))
				field_text(ui, id, &draft.input, placeholder, focused, 13, TEXT_LO)
			}
			if counts {
				clay.Text(tr("people"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
			}
		}
		// Word and npub boxes fill the row; the rest push remove to the end.
		if !folder_rule_typed(draft.kind) || folder_rule_counts(draft.kind) {
			if clay.UI(clay.ID("FolderRuleGap", u32(index)))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
		}
		if clay.UI(clay.ID("FolderRuleRemove", u32(index)))(
		{
			layout = {
				sizing = {clay.SizingFixed(30), clay.SizingFixed(30)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(7),
		},
		) {
			clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			if hovered() {
				tooltip(tr("Remove rule"))
				cursor_raise(.Pointer)
			}
		}
	}
}

// Floats under the type chip, outside the editor's scroll clip, or above
// it when the window has no room below.
@(private = "file")
folder_rule_menu :: proc(index: int) {
	chip := clay.GetElementData(clay.ID("FolderRuleKind", u32(index)))
	menu := clay.GetElementData(clay.ID("FolderRuleMenu"))
	height: f32 = menu.found ? menu.boundingBox.height : 250
	bottom := chip.boundingBox.y + chip.boundingBox.height + 4 + height
	below := !chip.found || bottom <= f32(rl.GetScreenHeight()) / UI_ZOOM
	under := clay.FloatingAttachPoints {
		element = .LeftTop,
		parent  = .LeftBottom,
	}
	over := clay.FloatingAttachPoints {
		element = .LeftBottom,
		parent  = .LeftTop,
	}
	if clay.UI(clay.ID("FolderRuleMenu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFit({min = 200})},
			padding = clay.PaddingAll(4),
			childGap = 1,
		},
		floating = {
			attachTo = .Parent,
			offset = {0, below ? 4 : -4},
			attachment = below ? under : over,
			zIndex = 14,
		},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		for kind in Folder_Rule_Kind {
			ctx_item(
				folder_rule_pick_id(kind),
				FOLDER_RULE_ICONS[kind],
				tr(FOLDER_RULE_LABELS[kind]),
			)
		}
	}
}

@(private = "file")
focus_rule :: proc(ui: ^Ui_State, index: int) {
	ui.focus = .FolderRule
	ui.folder_rule_focus = index
}

// The open type menu captures every event until a release picks a type
// or dismisses it. Runs before the modal's own outside-click dismissal,
// since the menu can hang past the modal's bottom edge.
@(private)
handle_folder_rule_menu :: proc(ui: ^Ui_State) -> bool {
	index := ui.folder_rule_menu
	if index < 0 {return false}
	if rl.IsKeyPressed(.ESCAPE) {
		ui.folder_rule_menu = -1
		return true
	}
	if !mouse_released() {return true}
	ui.folder_rule_menu = -1
	if index >= len(ui.folder_rules) {return true}
	draft := &ui.folder_rules[index]
	for kind in Folder_Rule_Kind {
		if !clay.PointerOver(clay.ID(folder_rule_pick_id(kind))) || kind == draft.kind {continue}
		draft.kind = kind
		clear(&draft.input)
		if folder_rule_typed(kind) {focus_rule(ui, index)}
		break
	}
	return true
}

// Rule-row input inside the editor; true when the event was consumed.
@(private)
handle_folder_rules :: proc(ui: ^Ui_State) -> bool {
	for &draft, i in ui.folder_rules {
		if !folder_rule_typed(draft.kind) {continue}
		if field_mouse(ui, &draft.input, folder_rule_box_id(i)) {
			focus_rule(ui, i)
			return true
		}
	}
	if !mouse_released() {return false}
	for i in 0 ..< len(ui.folder_rules) {
		if clay.PointerOver(clay.ID("FolderRuleKind", u32(i))) {
			ui.folder_rule_menu = i
			return true
		}
		if clay.PointerOver(clay.ID("FolderRuleRemove", u32(i))) {
			delete(ui.folder_rules[i].input)
			ordered_remove(&ui.folder_rules, i)
			// Rows shifted under the shared edit state; start it fresh.
			ui.ed_target = nil
			if ui.focus == .FolderRule {ui.focus = .Folder}
			return true
		}
	}
	if clay.PointerOver(clay.ID("FolderMatchAll")) {
		ui.folder_match = .All
		return true
	}
	if clay.PointerOver(clay.ID("FolderMatchAny")) {
		ui.folder_match = .Any
		return true
	}
	if clay.PointerOver(clay.ID("FolderRuleAdd")) && len(ui.folder_rules) < FOLDER_RULES_CAP {
		append(&ui.folder_rules, Folder_Rule_Draft{kind = .Name_Has})
		focus_rule(ui, len(ui.folder_rules) - 1)
		return true
	}
	return false
}
