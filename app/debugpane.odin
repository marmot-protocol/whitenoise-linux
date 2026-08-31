// The two developer-mode settings sections (dev_mode gates them in the
// sidebar): Debug, a three-tab JSON dump (state snapshot / raw events /
// key packages) with refresh + copy, and the KP inspector, which reads
// key packages for the active account or for any pubkey typed in.
//
// The dump is one mono clay.Text on the scrolling settings page, so it
// stays capped: raw events show the newest DEBUG_RAW_MAX records.
//
// Gap vs the slint app: marmot-c exports no MLS key-package decoder, so
// the inspector shows the publish metadata marmot hands back
// (ref, event id, size, relays, where it lives), not the ciphersuite /
// capabilities / credential rows the slint KpCard renders. See PORT.md.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

DEBUG_TABS := []string{N_("State"), N_("Raw events"), N_("Key packages")}
DEBUG_EYEBROWS := []string{N_("STATE SNAPSHOT"), N_("RAW EVENTS"), N_("KEY PACKAGES")}

// Newest records dumped on the raw-events tab. The whole page relayouts
// every frame, so the window stays small.
DEBUG_RAW_MAX :: 20

// Spaces, not tabs: the mono font has no tab glyph.
json_opts :: proc() -> json.Marshal_Options {
	return {pretty = true, use_spaces = true, spaces = 2}
}

// ── Debug page ──────────────────────────────────────────────────────

settings_debug :: proc(ui: ^Ui_State) {
	eyebrow(DEBUG_EYEBROWS[clamp(ui.debug_tab, 0, len(DEBUG_EYEBROWS) - 1)])
	if clay.UI(clay.ID("DbgTabs"))({layout = {childGap = 8}}) {
		for label, i in DEBUG_TABS {
			theme_chip_indexed("DbgTab", u32(i), tr(label), ui.debug_tab == i)
		}
	}
	if clay.UI(clay.ID("DbgActions"))({layout = {childGap = 8}}) {
		micro_button("DbgRefresh", "Refresh")
		micro_button("DbgCopy", "Copy JSON")
	}
	if clay.UI(clay.ID("DbgPlate"))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12)}, backgroundColor = PLATE, cornerRadius = rr(8)},
	) {
		clay.Text(len(ui.debug_json) > 0 ? ui.debug_json : tr("(nothing loaded yet, click Refresh)"), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
	}
}

compose_debug_json :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	delete(ui.debug_json)
	switch ui.debug_tab {
	case 0:
		ui.debug_json = debug_state_json(ui)
	case 1:
		ui.debug_json = debug_events_json(ui, client)
	case 2:
		ui.debug_json = debug_kp_json(ui, client)
	case:
		ui.debug_json = ""
	}
}

// The interesting slice of Ui_State: who is signed in, what is open,
// how much is loaded, and the display flags. Ui_State itself holds
// textures and pointers, so the snapshot is a hand-built struct.
debug_state_json :: proc(ui: ^Ui_State) -> string {
	Chat_Dump :: struct {
		group_id, title: string,
		unread:          u64,
		pending:         bool,
	}
	chats := make([dynamic]Chat_Dump, context.temp_allocator)
	for chat in ui.chats {
		append(&chats, Chat_Dump{group_id = chat.group_id, title = chat.title, unread = chat.unread, pending = chat.pending})
	}

	selected_id, selected_title: string
	if ui.selected >= 0 && ui.selected < len(ui.chats) {
		selected_id = ui.chats[ui.selected].group_id
		selected_title = ui.chats[ui.selected].title
	}

	data, err := json.marshal(
		struct {
			account:                                       string,
			accounts:                                      []string,
			page, settings_section, focus:                 string,
			selected_chat, selected_title:                 string,
			chats:                                         []Chat_Dump,
			archived, contacts, messages, pending, members: int,
			theme, accent:                                 int,
			locale:                                        string,
			dev_mode, show_members, unread_only, offline:  bool,
		} {
			account          = ui.account_ref,
			accounts         = ui.account_ids[:],
			page             = fmt.tprintf("%v", ui.page),
			settings_section = fmt.tprintf("%v", ui.settings_section),
			focus            = fmt.tprintf("%v", ui.focus),
			selected_chat    = selected_id,
			selected_title   = selected_title,
			chats            = chats[:],
			archived         = len(ui.archived),
			contacts         = len(ui.contacts),
			messages         = len(ui.messages),
			pending          = len(ui.pending),
			members          = len(ui.members),
			theme            = ui.theme,
			accent           = ui.accent,
			locale           = ui.prefs.locale,
			dev_mode         = ui.prefs.dev_mode,
			show_members     = ui.show_members,
			unread_only      = ui.unread_only,
			offline          = !ui.health_ok,
		},
		json_opts(),
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone(tr("Couldn't serialize the snapshot. Please try again."))
	}
	return strings.clone(string(data))
}

// The open chat's timeline as marmot hands it back, newest first. The
// records are already-serialized JSON, so the envelope is written by
// hand rather than marshalled.
debug_events_json :: proc(ui: ^Ui_State, client: ^marmot.Client) -> string {
	if ui.selected < 0 || ui.selected >= len(ui.chats) {
		return strings.clone(tr("No chat is open. Select one and refresh."))
	}
	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator),
		has_limit    = true,
		limit        = 200,
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {
		return fmt.aprintf(tr("Couldn't load the timeline. %s"), marmot.last_error())
	}
	defer marmot.timeline_page_free(page)

	total := int(page.messages_len)
	shown := min(total, DEBUG_RAW_MAX)

	// Braces stay out of the format string: Odin's fmt reads "{" as a
	// verb and prints %!(MISSING CLOSE BRACE).
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	fmt.sbprintf(
		&b,
		"  \"group_id\": \"%s\",\n  \"shown\": %d,\n  \"total\": %d,\n  \"truncated\": %t,\n  \"events\": [\n",
		ui.chats[ui.selected].group_id,
		shown,
		total,
		shown < total,
	)
	// marmot returns oldest first; walk back from the end.
	for n in 0 ..< shown {
		if n > 0 {
			strings.write_string(&b, ",\n")
		}
		strings.write_string(&b, record_json(&page.messages[total - 1 - n], context.temp_allocator))
	}
	strings.write_string(&b, "\n  ]\n}")
	return strings.to_string(b)
}

debug_kp_json :: proc(ui: ^Ui_State, client: ^marmot.Client) -> string {
	if !ui.kp_fetched {
		fetch_key_packages(ui, client)
	}
	return kp_json(ui.kp_list[:])
}

// Shared by the Debug tab and the inspector's Raw JSON plate.
kp_json :: proc(rows: []Kp_Row) -> string {
	Kp_Dump :: struct {
		owner, id, key_package_ref, published_at: string,
		bytes:                                    u64,
		local, relay:                             bool,
		relays:                                   []string,
	}
	dumps := make([dynamic]Kp_Dump, context.temp_allocator)
	for row in rows {
		append(
			&dumps,
			Kp_Dump {
				owner = row.owner,
				id = row.id,
				key_package_ref = row.kp_ref,
				published_at = row.at,
				bytes = row.bytes,
				local = row.local,
				relay = row.relay,
				relays = row.relay_urls,
			},
		)
	}
	data, err := json.marshal(dumps[:], json_opts(), context.temp_allocator)
	if err != nil {
		return strings.clone(tr("Couldn't serialize the key packages. Please try again."))
	}
	return strings.clone(string(data))
}

// ── KP inspector page ───────────────────────────────────────────────

settings_kp :: proc(ui: ^Ui_State) {
	eyebrow("YOUR KEY PACKAGES")
	if clay.UI(clay.ID("KpMineRow"))({layout = {childGap = 8}}) {
		micro_button("KpMineRefresh", "Decode own")
	}
	kp_cards(ui, "KpMine", ui.kp_list[:], ui.kp_fetched ? tr("No key package on this device or its relays.") : tr("Not loaded yet. Click Decode own."))

	eyebrow("INSPECT SOMEONE ELSE'S")
	if clay.UI(clay.ID("KpInspectRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
		input_box(ui, "KpBox", &ui.kp_input, "npub or hex pubkey", ui.focus == .KP, 300)
		login_button("KpInspect", "Inspect")
	}
	if len(ui.kp_peer_owner) > 0 {
		clay.Text(ui.kp_peer_owner, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM})
		kp_cards(ui, "KpPeer", ui.kp_peer[:], tr("No key package published for that pubkey."))
	}

	clay.Text(tr("marmot exposes publish metadata only. Ciphersuite, capabilities, and credential decoding are not available in this build."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
}

// One labeled row per decoded field, then the raw JSON plate.
kp_cards :: proc(ui: ^Ui_State, prefix: string, rows: []Kp_Row, empty: string) {
	if len(rows) == 0 {
		clay.Text(empty, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		return
	}
	for row, i in rows {
		where_at := row.local && row.relay ? tr("local + relay") : (row.local ? tr("local only") : tr("relay"))
		kp_kv(prefix, u32(i * 10 + 0), "Owner", len(row.owner) > 0 ? row.owner : tr("(unknown)"))
		kp_kv(prefix, u32(i * 10 + 1), "Key package ref", len(row.kp_ref) > 0 ? row.kp_ref : tr("(none)"))
		kp_kv(prefix, u32(i * 10 + 2), "Event id", len(row.id) > 0 ? row.id : tr("(unpublished)"))
		kp_kv(prefix, u32(i * 10 + 3), "Published", row.at)
		kp_kv(prefix, u32(i * 10 + 4), "Where", where_at)
		kp_kv(prefix, u32(i * 10 + 5), "Size", fmt.tprintf("%d bytes", row.bytes))
		kp_kv(prefix, u32(i * 10 + 6), "Relays", len(row.relay_urls) > 0 ? strings.join(row.relay_urls, ", ", context.temp_allocator) : tr("(none)"))
	}
	if clay.UI(clay.ID(fmt.tprintf("%sRawPlate", prefix)))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12)}, backgroundColor = PLATE, cornerRadius = rr(8)},
	) {
		clay.Text(kp_json_cached(ui, prefix, rows), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
	}
}

kp_kv :: proc(prefix: string, index: u32, label: string, value: string) {
	if clay.UI(clay.ID(fmt.tprintf("%sKv", prefix), index))(srow()) {
		clay.Text(tr(label), {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT_DIM})
		if clay.UI(clay.ID(fmt.tprintf("%sKvVal", prefix), index))({layout = {sizing = {width = clay.SizingGrow()}}}) {
			clay.Text(value, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
		}
	}
}

// The plate re-renders every frame; serialize once per fetch instead.
kp_json_cached :: proc(ui: ^Ui_State, prefix: string, rows: []Kp_Row) -> string {
	cached := prefix == "KpPeer" ? &ui.kp_peer_json : &ui.kp_own_json
	if len(cached^) == 0 {
		cached^ = kp_json(rows)
	}
	return cached^
}

// Any account reference marmot can resolve: npub or hex.
inspect_peer_key_packages :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	kp_rows_free(&ui.kp_peer)
	delete(ui.kp_peer_json)
	ui.kp_peer_json = ""
	delete(ui.kp_peer_owner)
	ui.kp_peer_owner = ""

	ref := strings.clone_to_cstring(string(ui.kp_input[:]), context.temp_allocator)
	hex: cstring
	if marmot.account_id_hex(client, ref, &hex) != .OK || hex == nil {
		ui.client_status = tr("Couldn't read that pubkey. Double-check it and try again.")
		return
	}
	defer marmot.string_free(hex)

	ui.kp_peer_owner = strings.clone(string(hex))
	if !kp_rows(client, ui.kp_peer_owner, &ui.kp_peer) {
		ui.client_status = fmt.aprintf(tr("Couldn't read their key packages. %s"), marmot.last_error())
	}
}

// ── Interactions ────────────────────────────────────────────────────

handle_debug :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for _, i in DEBUG_TABS {
		if clay.PointerOver(clay.ID("DbgTab", u32(i))) {
			ui.debug_tab = i
			compose_debug_json(ui, client)
			return
		}
	}
	if clicked("DbgRefresh") {
		// The key-packages tab re-queries the relays on demand.
		if ui.debug_tab == 2 {
			ui.kp_fetched = false
		}
		compose_debug_json(ui, client)
		return
	}
	if clicked("DbgCopy") && len(ui.debug_json) > 0 {
		copy_text(ui, ui.debug_json)
	}
}

handle_kp :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("KpMineRefresh") {
		fetch_key_packages(ui, client)
		delete(ui.kp_own_json)
		ui.kp_own_json = ""
		return
	}
	if clicked("KpInspect") && len(ui.kp_input) > 0 {
		inspect_peer_key_packages(ui, client)
	}
}
