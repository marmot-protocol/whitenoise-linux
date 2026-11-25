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
// Every group combines its own children. Exclusion reverses the result
// of one child before its parent combines it with the other children.
package main

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private)
Folder_Rule_Kind :: enum {
	Name_Has, // the chat title contains a word, case-insensitive
	Has_Member, // a pubkey is in the group
	Fewer_Than, // the group has fewer than `count` people
	More_Than, // the group has more than `count` people
	Unread, // the chat has unread messages or a manual unread mark
	Has_Draft, // the chat has unsent composer text saved
	Unread_Mention = 7,
	Pending_Send = 8,
	Direct = 9,
	Group = 10,
	Accepted = 11,
	Muted = 12,
	Pinned = 13,
	Archived = 14,
	Group_Node = 15,
}

@(private)
Folder_Rule :: struct {
	kind:    Folder_Rule_Kind,
	value:   string, // Name_Has: lowercased word; Has_Member: pubkey hex
	count:   int, // Fewer_Than / More_Than bound
	exclude: bool `json:"exclude,omitempty"`,
	nested:  Folder_Rules `json:"nested,omitempty"`,
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
	kind:     Folder_Rule_Kind,
	input:    [dynamic]u8,
	field_id: u32, // stable when a sibling shifts to a different index
	depth:    int,
	exclude:  bool,
	match:    Folder_Match,
}

// The editor reserves this many rows up front, so the edit state's
// pointer into a row's buffer survives "Add rule".
@(private)
FOLDER_RULES_CAP :: 16

@(private)
FOLDER_RULE_LABELS := #sparse[Folder_Rule_Kind]string {
	.Name_Has       = N_("Name includes"),
	.Has_Member     = N_("Has member"),
	.Fewer_Than     = N_("Fewer than"),
	.More_Than      = N_("More than"),
	.Unread         = N_("Has unread messages"),
	.Has_Draft      = N_("Has a draft"),
	.Unread_Mention = N_("Has unread mentions of you"),
	.Pending_Send   = N_("Has pending sends"),
	.Direct         = N_("Is a direct chat"),
	.Group          = N_("Is a group chat"),
	.Accepted       = N_("Is accepted"),
	.Muted          = N_("Is muted"),
	.Pinned         = N_("Is pinned"),
	.Archived       = N_("Is archived"),
	.Group_Node     = "",
}

@(private = "file")
ICON_DRAFT :: "\uf044"

@(private = "file")
FOLDER_RULE_ICONS := #sparse[Folder_Rule_Kind]string {
	.Name_Has       = ICON_PENCIL,
	.Has_Member     = ICON_PROFILE,
	.Fewer_Than     = ICON_PEOPLE,
	.More_Than      = ICON_PEOPLE,
	.Unread         = ICON_ENVELOPE,
	.Has_Draft      = ICON_DRAFT,
	.Unread_Mention = "\uf1fa",
	.Pending_Send   = "\uf017",
	.Direct         = ICON_PROFILE,
	.Group          = ICON_PEOPLE,
	.Accepted       = ICON_CHECK,
	.Muted          = ICON_BELL_OFF,
	.Pinned         = ICON_PIN,
	.Archived       = ICON_ARCHIVE,
	.Group_Node     = "",
}

// What the rules read about one inbox row, gathered once per frame.
@(private)
Chat_Facts :: struct {
	title:                                                           string, // lowercased
	unread:                                                          bool,
	draft:                                                           bool,
	members:                                                         []string, // pubkey hex, including you
	known:                                                           bool, // members were read; size rules never guess
	unread_mention, pending_send, accepted, muted, pinned, archived: bool,
	conversation_kind:                                               marmot.Chat_Conversation_Kind,
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
	case .Has_Draft:
		return facts.draft
	case .Unread_Mention:
		return facts.unread_mention
	case .Pending_Send:
		return facts.pending_send
	case .Direct:
		return facts.conversation_kind == .DIRECT
	case .Group:
		return facts.conversation_kind == .GROUP
	case .Accepted:
		return facts.accepted
	case .Muted:
		return facts.muted
	case .Pinned:
		return facts.pinned
	case .Archived:
		return facts.archived
	case .Group_Node:
		return folder_rules_match(rule.nested, facts)
	}
	return false
}

// A folder without rules never matches.
@(private)
folder_rules_match :: proc(set: Folder_Rules, facts: Chat_Facts) -> bool {
	if len(set.rules) == 0 {return false}
	for rule in set.rules {
		held := folder_rule_holds(rule, facts) != rule.exclude
		if set.match == .Any && held {return true}
		if set.match == .All && !held {return false}
	}
	return set.match == .All
}

@(private)
folder_rule_count :: proc(set: Folder_Rules) -> int {
	count := 0
	for rule in set.rules {
		count += rule.kind == .Group_Node ? folder_rule_count(rule.nested) : 1
	}
	return count
}

// Reject a saved set as a whole: dropping a child could broaden a match.
@(private)
folder_rules_valid :: proc(set: Folder_Rules, value: json.Value) -> bool {
	object, ok := value.(json.Object)
	if !ok {return false}
	if set.match != .All && set.match != .Any {
		return false
	}
	if mode, found := object["match"]; found && !folder_enum_token(mode, set.match) {
		return false
	}
	if len(set.rules) == 0 {return true}
	nodes, is_array := object["rules"].(json.Array)
	if !is_array || len(nodes) != len(set.rules) {return false}
	for rule, i in set.rules {
		node, is_object := nodes[i].(json.Object)
		if !is_object {return false}
		if kind, found := node["kind"]; !found || !folder_enum_token(kind, rule.kind) {
			return false
		}
		if rule.kind == .Group_Node {
			if len(rule.nested.rules) == 0 || !folder_rules_valid(rule.nested, node["nested"]) {
				return false
			}
		} else if rule.kind < .Name_Has ||
		   rule.kind > max(Folder_Rule_Kind) ||
		   FOLDER_RULE_LABELS[rule.kind] == "" ||
		   len(rule.nested.rules) != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
folder_enum_token :: proc(
	token: json.Value,
	decoded: $T,
) -> bool where intrinsics.type_is_enum(T) {
	#partial switch value in token {
	case json.Integer:
		return value == i64(decoded)
	case json.String:
		return value == fmt.tprintf("%v", decoded)
	}
	return false
}

// Where a chat files: a hand placement ("" keeps it in Unfiled) into a
// folder that still exists, else the first folder whose rules match,
// else Unfiled (len(folders)).
@(private)
chat_folder_slot :: proc(ui: ^Ui_State, chat: ^Chat_Row_Ui, lookup: Folder_Lookup) -> int {
	unfiled := len(ui.prefs.folders)
	if folder, placed := ui.prefs.folder_of[chat.group_id]; placed {
		if folder == "" {return unfiled}
		if slot, found := lookup.slots[folder]; found {return slot}
	}
	if len(ui.prefs.folder_rules) == 0 {return unfiled}

	member_index := chat.archived ? ui.archive_members : ui.chat_members
	members, known := member_index[chat.group_id]
	facts := Chat_Facts {
		title             = strings.to_lower(chat.title, context.temp_allocator),
		unread            = chat.unread > 0 || ui.prefs.unread_ids[chat.group_id],
		draft             = draft_key(ui.account_ref, chat.group_id) in ui.drafts,
		members           = members,
		known             = known,
		unread_mention    = chat.unread_mention && chat.unread > 0 && !chat.pending,
		pending_send      = chat.pending_send || lookup.pending[chat.group_id],
		conversation_kind = chat.conversation_kind,
		accepted          = chat.accepted,
		muted             = ui.prefs.muted_ids[chat.group_id] || (chat.native_muted && (!chat.has_muted_until || chat.muted_until > lookup.now_ms)),
		pinned            = ui.prefs.pinned[chat.group_id],
		archived          = chat.archived,
	}
	for name, i in ui.prefs.folders {
		if folder_rules_match(ui.prefs.folder_rules[name], facts) {return i}
	}
	return unfiled
}

// Membership costs one marmot read per chat, so the chat list asks for
// it only while some rule looks at members.
@(private = "file")
folder_group_needs_members :: proc(set: Folder_Rules) -> bool {
	for rule in set.rules {
		if rule.kind == .Group_Node ? folder_group_needs_members(rule.nested) : rule.kind == .Has_Member || rule.kind == .Fewer_Than || rule.kind == .More_Than {
			return true
		}
	}
	return false
}

@(private)
folder_rules_need_members :: proc(prefs: Prefs) -> bool {
	for _, set in prefs.folder_rules {
		if folder_group_needs_members(set) {
			return true
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
	for rule in set.rules {
		delete(rule.value)
		folder_rules_free(rule.nested)
	}
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
	return kind <= .More_Than
}

@(private = "file")
folder_rule_counts :: proc(kind: Folder_Rule_Kind) -> bool {
	return kind == .Fewer_Than || kind == .More_Than
}

@(private = "file")
folder_rule_box_id :: proc(field_id: u32) -> string {
	return fmt.tprintf("FolderRuleBox%d", field_id)
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
	ui.folder_rule_next_id = 0
	ui.folder_match = .All
	if name == "" {return}
	set := ui.prefs.folder_rules[name]
	ui.folder_match = set.match
	folder_group_load(ui, set, 0)
}

@(private = "file")
folder_group_load :: proc(ui: ^Ui_State, set: Folder_Rules, depth: int) {
	for rule in set.rules {
		draft := Folder_Rule_Draft {
			kind     = rule.kind,
			depth    = depth,
			field_id = ui.folder_rule_next_id,
			exclude  = rule.exclude,
			match    = rule.nested.match,
		}
		ui.folder_rule_next_id += 1
		if rule.kind == .Group_Node {
			append(&ui.folder_rules, draft)
			folder_group_load(ui, rule.nested, depth + 1)
			continue
		}
		#partial switch rule.kind {
		case .Name_Has:
			append(&draft.input, rule.value)
		case .Has_Member:
			npub := hex_npub(rule.value)
			append(&draft.input, npub)
			delete(npub)
		case .Fewer_Than, .More_Than:
			append(&draft.input, fmt.tprintf("%d", rule.count))
		}
		append(&ui.folder_rules, draft)
	}
}

// Parse the editor rows. Blank rows are skipped. On a row that doesn't
// parse, `bad` is its index and `why` the toast; the set is then empty.
@(private)
folder_rules_parse :: proc(ui: ^Ui_State) -> (set: Folder_Rules, bad: int, why: string) {
	set.match = ui.folder_match
	index := 0
	bad, why = folder_group_parse(&set, ui.folder_rules[:], &index, 0)
	if bad >= 0 {
		folder_rules_free(set)
		return {}, bad, why
	}
	return set, -1, ""
}

@(private = "file")
folder_group_parse :: proc(
	set: ^Folder_Rules,
	drafts: []Folder_Rule_Draft,
	index: ^int,
	depth: int,
) -> (
	int,
	string,
) {
	for index^ < len(drafts) && drafts[index^].depth == depth {
		i := index^
		index^ += 1
		draft := &drafts[i]
		if draft.kind == .Group_Node {
			append(
				&set.rules,
				Folder_Rule {
					kind = .Group_Node,
					exclude = draft.exclude,
					nested = {match = draft.match},
				},
			)
			nested := &set.rules[len(set.rules) - 1].nested
			bad, why := folder_group_parse(nested, drafts, index, depth + 1)
			if bad >= 0 {
				return bad, why
			}
			if len(nested.rules) == 0 {
				delete(nested.rules)
				pop(&set.rules)
			}
			continue
		}
		text := strings.trim_space(string(draft.input[:]))
		rule := Folder_Rule {
			kind    = draft.kind,
			exclude = draft.exclude,
		}
		#partial switch draft.kind {
		case .Name_Has:
			if text == "" {continue}
			rule.value = strings.to_lower(text)
		case .Has_Member:
			if text == "" {continue}
			hex := mention_hex(text)
			if hex == "" {
				return i, tr("Enter the member as an npub and try again.")
			}
			rule.value = strings.clone(hex)
		case .Fewer_Than, .More_Than:
			if text == "" {
				return i, tr("Enter a number of people.")
			}
			count, ok := strconv.parse_int(text, 10)
			if !ok || count < 0 {
				return i, tr("Enter the number of people as a whole number and try again.")
			}
			if draft.kind == .Fewer_Than && count < 2 {
				return i, tr("Enter at least 2 people. Counts include you.")
			}
			rule.count = count
		}
		append(&set.rules, rule)
	}
	return -1, ""
}

@(private)
folder_rules_editor :: proc(ui: ^Ui_State) {
	eyebrow(tr("RULES"))
	nendo.text(
		tr(
			"Chats that match file here automatically. People counts include you. Anything you move by hand stays where you put it.",
		),
		{font = FONT_BODY, size = 12, color = TEXT_LO},
	)
	next := 0
	folder_group_editor(ui, &next, -1, 0, ui.folder_match)
}

@(private = "file")
folder_tree_id :: proc(base: string, index: int) -> string {
	return index < 0 ? base : fmt.tprintf("%s%d", base, index)
}

@(private = "file")
folder_group_editor :: proc(ui: ^Ui_State, next: ^int, index, depth: int, mode: Folder_Match) {
	if index >= 0 || len(ui.folder_rules) > 1 {
		id := nendo.id(folder_tree_id("FolderMatch", index))
		if nendo.box(id)(settings_choices(id)) {
			folder_match_chip(
				folder_tree_id("FolderMatchAll", index),
				tr("Match all rules"),
				mode == .All,
			)
			folder_match_chip(
				folder_tree_id("FolderMatchAny", index),
				tr("Match any rule"),
				mode == .Any,
			)
		}
	}
	for next^ < len(ui.folder_rules) && ui.folder_rules[next^].depth == depth {
		i := next^
		next^ += 1
		draft := &ui.folder_rules[i]
		if draft.kind != .Group_Node {
			folder_rule_row(ui, draft, i)
			continue
		}
		if nendo.box(nendo.id("FolderRuleGroup", u32(i)))(
		{
			width = nendo.grow(),
			direction = .Column,
			gap = 8,
			padding = {left = 7},
			border = {color = FIELD_BORDER, width = {left = bw().left}},
		},
		) {
			if nendo.box(nendo.id("FolderGroupHead", u32(i)))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
			) {
				nendo.text(tr("Rule group"), {font = FONT_TITLE, size = 13, color = TEXT})
				folder_node_actions(draft, i)
			}
			folder_group_editor(ui, next, i, depth + 1, draft.match)
		}
	}
	if len(ui.folder_rules) < FOLDER_RULES_CAP {
		id := nendo.id(folder_tree_id("FolderAdd", index))
		if nendo.box(id)(settings_choices(id)) {
			folder_action(folder_tree_id("FolderRuleAdd", index), tr("Add rule"))
			folder_action(folder_tree_id("FolderGroupAdd", index), tr("Add group"))
		}
	}
}

@(private = "file")
folder_match_chip :: proc(id, label: string, selected: bool) {
	if nendo.box(nendo.id(id))(
	{
		height = nendo.fixed(settings_tap_size(32)),
		padding = {left = 12, right = 12},
		align = {y = .Center},
		color = selected ? SELECTED : (hovered() ? HOVER : ROW_BG),
		border = {color = selected ? ACCENT : FIELD_BORDER, width = bw()},
		radius = rr(8),
	},
	) {
		nendo.text(label, {font = FONT_TITLE, size = 13, color = TEXT})
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private = "file")
folder_node_actions :: proc(draft: ^Folder_Rule_Draft, index: int) {
	folder_match_chip(folder_tree_id("FolderExclude", index), tr("Exclude"), draft.exclude)
	if nendo.box(nendo.id("FolderRuleRemove", u32(index)))(
	{
		width = nendo.fixed(settings_tap_size(30)),
		height = nendo.fixed(settings_tap_size(30)),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(7),
	},
	) {
		nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
		if hovered() {
			tooltip(draft.kind == .Group_Node ? tr("Remove group") : tr("Remove rule"))
			cursor_raise(.Pointer)
		}
	}
}

@(private = "file")
folder_rule_row :: proc(ui: ^Ui_State, draft: ^Folder_Rule_Draft, index: int) {
	menu_open := ui.folder_rule_menu == index
	if nendo.box(nendo.id("FolderRule", u32(index)))(
	{
		width = nendo.grow(),
		height = nendo.fit(),
		direction = .Column,
		gap = 8,
		padding = nendo.pad(8),
		border = {color = FIELD_BORDER, width = bw()},
		radius = rr(9),
	},
	) {
		if nendo.box(nendo.id("FolderRuleHead", u32(index)))(
		{width = nendo.grow(), gap = 8, align = {y = .Center}},
		) {
			if nendo.box(nendo.id("FolderRuleKind", u32(index)))(
			{
				width = nendo.grow(),
				height = nendo.fixed(settings_tap_size(36)),
				padding = {left = 10, right = 10},
				gap = 8,
				align = {y = .Center},
				color = menu_open ? SELECTED : (hovered() ? HOVER : ROW_BG),
				border = {color = menu_open ? ACCENT : FIELD_BORDER, width = bw()},
				radius = rr(9),
			},
			) {
				nendo.text(
					FOLDER_RULE_ICONS[draft.kind],
					{font = FONT_ICON, size = 12, color = TEXT_DIM},
				)
				nendo.text(
					tr(FOLDER_RULE_LABELS[draft.kind]),
					{font = FONT_TITLE, size = 13, color = TEXT},
				)
				nendo.text("\u2304", {font = FONT_TITLE, size = 13, color = TEXT_DIM})
				if hovered() && !menu_open {
					tooltip(tr("Change rule type"))
					cursor_raise(.Pointer)
				}
				if menu_open {
					folder_rule_menu(index)
				}
			}
			folder_node_actions(draft, index)
		}
		if folder_rule_typed(draft.kind) {
			if nendo.box(nendo.id("FolderRuleValue", u32(index)))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
			) {
				focused := ui.focus == .FolderRule && ui.folder_rule_focus == index
				id := folder_rule_box_id(draft.field_id)
				counts := folder_rule_counts(draft.kind)
				if nendo.box(nendo.id(id))(
				{
					width = nendo.grow(),
					height = nendo.fixed(settings_tap_size(36)),
					padding = {left = 12, right = 12},
					align = {y = .Center},
					color = ROW_BG,
					radius = rr(9),
					border = {color = focused ? ACCENT : FIELD_BORDER, width = bw()},
				},
				) {
					placeholder :=
						draft.kind == .Has_Member ? "npub1..." : (counts ? tr("Number") : tr("Word"))
					field_text(ui, id, &draft.input, placeholder, focused, 13, TEXT_LO)
				}
				if counts {
					nendo.text(tr("people"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
				}
			}
		}
	}
}

// Floats outside the editor's scroll clip and stays within the viewport.
@(private = "file")
folder_rule_menu :: proc(index: int) {
	chip := nendo.element(nendo.id("FolderRuleKind", u32(index)))
	menu := nendo.element(nendo.id("FolderRuleMenu"))
	height: f32 = menu.found ? menu.rect.height : 250
	width := fit_w(280)
	x, y := panel_pos(
		chip.rect.x,
		chip.rect.y + chip.rect.height + 4,
		width,
		min(height, modal_h(1200)),
	)
	if nendo.box(nendo.id("FolderRuleMenu"))(
	{
		direction = .Column,
		width = nendo.fixed(width),
		height = nendo.fit(max = modal_h(1200)),
		padding = nendo.pad(4),
		gap = 1,
		floating = {
			attach_to = .Root,
			offset = {x, y},
			attach = {element = .Left_Top, parent = .Left_Top},
			z = 14,
		},
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		for kind in Folder_Rule_Kind {
			if FOLDER_RULE_LABELS[kind] == "" {continue}
			ctx_item(
				folder_rule_pick_id(kind),
				FOLDER_RULE_ICONS[kind],
				tr(FOLDER_RULE_LABELS[kind]),
			)
		}
	}
	scrollbar(nendo.id("FolderRuleMenu"), 15)
}

@(private = "file")
focus_rule :: proc(ui: ^Ui_State, index: int) {
	ui.focus = .FolderRule
	ui.folder_rule_focus = index
	if rl.HasTouch() {touch_field = nendo.id(folder_rule_box_id(ui.folder_rules[index].field_id))}
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
		if FOLDER_RULE_LABELS[kind] == "" ||
		   !nendo.pointer_over(nendo.id(folder_rule_pick_id(kind))) ||
		   kind == draft.kind {continue}
		draft.kind = kind
		clear(&draft.input)
		if folder_rule_typed(kind) {
			focus_rule(ui, index)
		} else if ui.focus == .FolderRule && ui.folder_rule_focus == index {
			ui.focus = .Folder
		}
		break
	}
	return true
}

// Rule-row input inside the editor; true when the event was consumed.
@(private)
handle_folder_rules :: proc(ui: ^Ui_State) -> bool {
	for &draft, i in ui.folder_rules {
		if !folder_rule_typed(draft.kind) {continue}
		if field_mouse(ui, &draft.input, folder_rule_box_id(draft.field_id)) {
			focus_rule(ui, i)
			return true
		}
	}
	if !mouse_released() {return false}
	for &draft, i in ui.folder_rules {
		if nendo.pointer_over(nendo.id("FolderRuleKind", u32(i))) {
			ui.folder_rule_menu = i
			return true
		}
		if clicked(folder_tree_id("FolderExclude", i)) {
			draft.exclude = !draft.exclude
			return true
		}
		if nendo.pointer_over(nendo.id("FolderRuleRemove", u32(i))) {
			end := folder_subtree_end(ui.folder_rules[:], i)
			for child in i ..< end {
				delete(ui.folder_rules[child].input)
			}
			copy(ui.folder_rules[i:], ui.folder_rules[end:])
			resize(&ui.folder_rules, len(ui.folder_rules) - (end - i))
			ui.ed_target = nil
			if ui.focus == .FolderRule {ui.focus = .Folder}
			return true
		}
		if draft.kind == .Group_Node && click_folder_group(ui, i, &draft.match) {
			return true
		}
	}
	return click_folder_group(ui, -1, &ui.folder_match)
}

@(private = "file")
folder_subtree_end :: proc(drafts: []Folder_Rule_Draft, index: int) -> int {
	depth := drafts[index].depth
	end := index + 1
	for end < len(drafts) && drafts[end].depth > depth {
		end += 1
	}
	return end
}

@(private = "file")
click_folder_group :: proc(ui: ^Ui_State, index: int, mode: ^Folder_Match) -> bool {
	if clicked(folder_tree_id("FolderMatchAll", index)) {
		mode^ = .All
		return true
	}
	if clicked(folder_tree_id("FolderMatchAny", index)) {
		mode^ = .Any
		return true
	}
	if len(ui.folder_rules) >= FOLDER_RULES_CAP {
		return false
	}
	group := clicked(folder_tree_id("FolderGroupAdd", index))
	if !group && !clicked(folder_tree_id("FolderRuleAdd", index)) {
		return false
	}
	depth, at := 0, len(ui.folder_rules)
	if index >= 0 {
		depth = ui.folder_rules[index].depth + 1
		at = folder_subtree_end(ui.folder_rules[:], index)
	}
	inject_at(
		&ui.folder_rules,
		at,
		Folder_Rule_Draft {
			depth = depth,
			field_id = ui.folder_rule_next_id,
			kind = group ? .Group_Node : .Name_Has,
		},
	)
	ui.folder_rule_next_id += 1
	ui.ed_target = nil // Insertions can move the text buffer's owner.
	if !group {
		focus_rule(ui, at)
	} else if ui.focus == .FolderRule {
		ui.focus = .Folder
	}
	return true
}
