// Settings → Network & relays: the two published relay lists
// (NIP-65 outbox, kind-10050 inbox) plus the relay-pool health
// counters marmot exposes.
//
// ponytail: every marmot call here runs on the UI thread, like the
// rest of the port. A frame stalls for the round trip; move to the
// worker pool when the stall gets noticed.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// Health is polled on the frame loop, not pushed by marmot.
HEALTH_REFRESH_SECS :: 5.0

@(private = "file")
health_last: f64 = -1

// ── Render ──────────────────────────────────────────────────────────

settings_network :: proc(ui: ^Ui_State) {
	eyebrow("STATUS")
	if clay.UI(clay.ID("RowNetStatus"))(srow()) {
		dot := ui.health_ok && ui.health.connected > 0 ? ACCENT : TEXT_DIM
		if clay.UI(clay.ID("NetDot"))({layout = {sizing = {width = clay.SizingFixed(7), height = clay.SizingFixed(7)}}, backgroundColor = dot, cornerRadius = rr(4)}) {}
		row_labels(health_line(ui), health_detail(ui))
		micro_button("NetRefresh", "Refresh")
	}
	if clay.UI(clay.ID("RowReconnect"))(srow()) {
		// marmot-c exports no reconnect entry point, so this keeps the
		// slint row's look and surfaces the stub status on use.
		row_labels("Reconnect now", "Drops idle relay sockets and dials them again.")
		micro_button("ReconnectBtn", "Reconnect")
	}

	eyebrow("OUTBOX RELAYS (NIP-65)")
	clay.Text(tr("Where you publish."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	if clay.UI(clay.ID("AddRelayRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
		input_box(ui, "RelayBox", &ui.relay_input, "wss://relay.example.com", ui.focus == .Relay, 300)
		login_button("AddRelayBtn", "Add")
	}
	if len(ui.profile.nip65) == 0 {
		clay.Text(tr("No relay list published."), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
	}
	for relay, i in ui.profile.nip65 {
		relay_row("RelayRow", "RelayRemove", u32(i), relay)
	}

	eyebrow("INBOX RELAYS")
	clay.Text(tr("Where peers reach you."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	if clay.UI(clay.ID("AddInboxRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
		input_box(ui, "InboxBox", &ui.inbox_input, "wss://relay.example.com", ui.focus == .Inbox, 300)
		login_button("AddInboxBtn", "Add")
	}
	if len(ui.profile.inbox) == 0 {
		clay.Text(tr("No inbox relays."), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
	}
	for relay, i in ui.profile.inbox {
		relay_row("InboxRow", "InboxRemove", u32(i), relay)
	}

	eyebrow("EVENT FETCH RELAYS")
	clay.Text(tr("Where linked Nostr events (nevent, note) are pulled from. Your chats never touch these."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	if clay.UI(clay.ID("AddFetchRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
		input_box(ui, "FetchBox", &ui.fetch_input, "wss://relay.example.com", ui.focus == .Fetch, 300)
		login_button("AddFetchBtn", "Add")
	}
	for relay, i in ui.prefs.fetch_relays {
		relay_row("FetchRow", "FetchRemove", u32(i), relay)
	}

	eyebrow("OPEN EVENTS IN")
	clay.Text(tr("The web client an event card opens, with {id} in place of the event. For example https://primal.net/e/{id}."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	input_box(ui, "ClientBox", &ui.client_input, DEFAULT_EVENT_CLIENT, ui.focus == .Client, 300)

	eyebrow("SYNC")
	if clay.UI(clay.ID("RowRepublish"))(srow()) {
		row_labels("Republish relay lists", "Re-broadcasts your outbox and inbox relay lists. Use this if peers can't find you.")
		micro_button("RepublishBtn", "Republish")
	}
}

relay_row :: proc(row_id: string, remove_id: string, index: u32, relay: string) {
	if clay.UI(clay.ID(row_id, index))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12), childGap = 8, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : ROW_BG, cornerRadius = rr(8)},
	) {
		clay.Text(relay, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
		if clay.UI(clay.ID_LOCAL("Gap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if hovered() {
			if clay.UI(clay.ID(remove_id, index))(
			{layout = {padding = clay.PaddingAll(5)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
			) {
				clay.Text(ICON_TRASH, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM})
			}
		}
	}
}

// "5 of 6 connected", or the pre-poll placeholder.
health_line :: proc(ui: ^Ui_State) -> string {
	if !ui.health_ok {
		return tr("Relay status unavailable")
	}
	return fmt.tprintf(tr("%d of %d connected"), ui.health.connected, ui.health.total_relays)
}

health_detail :: proc(ui: ^Ui_State) -> string {
	if !ui.health_ok {
		return tr("Aggregate connection counter from the relay pool.")
	}
	h := ui.health
	return fmt.tprintf(
		tr("%d connecting, %d pending, %d disconnected, %d sleeping."),
		h.connecting, h.pending, h.disconnected, h.sleeping,
	)
}

// ── Actions ─────────────────────────────────────────────────────────

health_refresh :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil {
		return
	}
	out: ^marmot.Relay_Health
	if marmot.relay_health(client, &out) != .OK || out == nil {
		ui.health_ok = false
		return
	}
	ui.health = out^
	ui.health_ok = true
	marmot.relay_health_free(out)
}

// Frame-loop poll; the Network page's Refresh button forces one. Runs
// everywhere because the rail's relay counter reads the same numbers.
health_tick :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil {
		return
	}
	now := rl.GetTime()
	if health_last >= 0 && now - health_last < HEALTH_REFRESH_SECS {
		return
	}
	health_last = now
	health_refresh(ui, client)
}

// Replace and publish the kind-10050 inbox list, then re-read both
// lists (the setter returns them, but load_profile is the one path
// that owns ui.profile).
set_inbox_relays :: proc(ui: ^Ui_State, client: ^marmot.Client, relays: []cstring) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	lists: ^marmot.Account_Relay_Lists
	if marmot.set_account_inbox_relays(client, account, raw_data(relays), uint(len(relays)), raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), &lists) != .OK {
		ui.client_status = fmt.aprintf("Couldn't update inbox relays. %s", marmot.last_error())
		return
	}
	marmot.account_relay_lists_free(lists)
	reload_profile(ui, client)
}

reload_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.profile.loaded = false
	clear(&ui.profile.nip65)
	clear(&ui.profile.inbox)
	load_profile(client, ui)
}

// ── Clicks ──────────────────────────────────────────────────────────

handle_network :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("NetRefresh") {
		health_refresh(ui, client)
		reload_profile(ui, client)
		return
	}
	if clicked("ReconnectBtn") {
		ui.client_status = STUB_STATUS // no marmot-c reconnect export
		return
	}
	if clicked("RepublishBtn") {
		republish_relay_lists(ui, client)
		return
	}
	if clicked("AddInboxBtn") && len(ui.inbox_input) > 0 {
		relays := make([dynamic]cstring, context.temp_allocator)
		for relay in ui.profile.inbox {
			append(&relays, strings.clone_to_cstring(relay, context.temp_allocator))
		}
		append(&relays, strings.clone_to_cstring(string(ui.inbox_input[:]), context.temp_allocator))
		set_inbox_relays(ui, client, relays[:])
		clear(&ui.inbox_input)
		return
	}
	for relay, i in ui.profile.inbox {
		if clay.PointerOver(clay.ID("InboxRemove", u32(i))) {
			confirm_ask(ui, .Remove_Inbox, relay, relay, i)
			return
		}
	}
	// Fetch relays and the client template are local prefs, so no
	// confirm and no relay round trip: edit, save, done.
	if clicked("AddFetchBtn") && len(ui.fetch_input) > 0 {
		append(&ui.prefs.fetch_relays, strings.clone(string(ui.fetch_input[:])))
		clear(&ui.fetch_input)
		save_settings(ui)
		return
	}
	for i in 0 ..< len(ui.prefs.fetch_relays) {
		if clicked_indexed("FetchRemove", u32(i)) {
			delete(ui.prefs.fetch_relays[i])
			ordered_remove(&ui.prefs.fetch_relays, i)
			save_settings(ui)
			return
		}
	}
	if string(ui.client_input[:]) != ui.prefs.event_client {
		delete(ui.prefs.event_client)
		ui.prefs.event_client = strings.clone(string(ui.client_input[:]))
		save_settings(ui)
	}
	handle_profile(ui, client) // outbox add/remove lives with the profile clicks
}

republish_relay_lists :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.publish_relay_lists(client, account, raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS))) != .OK {
		ui.client_status = fmt.aprintf("Couldn't republish the relay lists. %s", marmot.last_error())
		return
	}
	ui.client_status = "Relay lists republished."
}

// Rail/status-bar counter: live connected-of-total once a health call
// has landed, the configured relay count before that.
relay_counter :: proc(ui: ^Ui_State) -> string {
	if ui.health_ok {
		return fmt.tprintf("%d/%d RELAYS", ui.health.connected, ui.health.total_relays)
	}
	return fmt.tprintf("%d/%d RELAYS", 0, len(DEFAULT_RELAYS))
}
