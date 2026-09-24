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
	narrow := settings_body_width(ui) < 400
	if ui.settings_tab == 0 {
		if clay.UI(clay.ID("NetworkStatusGroup"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 3,
			},
		},
		) {
			status := settings_row()
			status.layout.layoutDirection = narrow ? .TopToBottom : .LeftToRight
			if clay.UI(clay.ID("RowNetStatus"))(status) {
				if clay.UI(clay.ID("NetworkConnectionSummary"))(
				{layout = {childGap = 8, childAlignment = {y = .Center}}},
				) {
					dot := ui.health_ok && ui.health.connected > 0 ? ACCENT : TEXT_DIM
					if clay.UI(clay.ID("NetDot"))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(7), height = clay.SizingFixed(7)},
						},
						backgroundColor = dot,
						cornerRadius = rr(4),
					},
					) {}
					clay.Text(
						health_line(ui),
						{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT},
					)
				}
				settings_button("NetRefresh", "Refresh")
			}
			clay.Text(health_detail(ui), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}

		if clay.UI(clay.ID("NetworkOutboxGroup"))(settings_box()) {
			settings_group(N_("Published outbox relays (NIP-65)"))
			clay.Text(
				tr("Where you publish."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			if len(ui.profile.nip65) == 0 {
				clay.Text(
					tr("No relay list published."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}
			for relay, i in ui.profile.nip65 {
				relay_row("RelayRow", "RelayRemove", u32(i), relay)
			}
			if clay.UI(clay.ID("AddRelayRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = narrow ? .TopToBottom : .LeftToRight,
					childGap = 6,
					childAlignment = {y = .Center},
				},
			},
			) {
				settings_input(
					ui,
					"RelayBox",
					&ui.relay_input,
					"wss://relay.example.com",
					ui.focus == .Relay,
				)
				settings_button("AddRelayBtn", "Add")
			}
		}

		if clay.UI(clay.ID("NetworkInboxGroup"))(settings_box()) {
			settings_group(N_("Published inbox relays"))
			clay.Text(
				tr("Where peers reach you."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			if len(ui.profile.inbox) == 0 {
				clay.Text(
					tr("No inbox relays."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}
			for relay, i in ui.profile.inbox {
				relay_row("InboxRow", "InboxRemove", u32(i), relay)
			}
			if clay.UI(clay.ID("AddInboxRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = narrow ? .TopToBottom : .LeftToRight,
					childGap = 6,
					childAlignment = {y = .Center},
				},
			},
			) {
				settings_input(
					ui,
					"InboxBox",
					&ui.inbox_input,
					"wss://relay.example.com",
					ui.focus == .Inbox,
				)
				settings_button("AddInboxBtn", "Add")
			}
		}

		if clay.UI(clay.ID("NetworkSyncGroup"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, padding = {top = 8}},
			border = {color = FIELD_BORDER, width = {top = 1}},
		},
		) {
			recovery := settings_row()
			recovery.layout.layoutDirection = .TopToBottom
			recovery.layout.childGap = 8
			if clay.UI(clay.ID("RowRepublish"))(recovery) {
				row_labels(
					"Republish relay lists",
					"Re-broadcasts your outbox and inbox relay lists. Use this if peers can't find you.",
				)
				settings_button("RepublishBtn", "Republish")
			}
		}
	} else {
		if clay.UI(clay.ID("NetworkFetchGroup"))(settings_box()) {
			settings_group(N_("Event fetch relays"))
			clay.Text(
				tr(
					"Where linked Nostr events (nevent, note) are pulled from. Your chats never touch these.",
				),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			for relay, i in ui.prefs.fetch_relays {
				relay_row("FetchRow", "FetchRemove", u32(i), relay)
			}
			if clay.UI(clay.ID("AddFetchRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = narrow ? .TopToBottom : .LeftToRight,
					childGap = 6,
					childAlignment = {y = .Center},
				},
			},
			) {
				settings_input(
					ui,
					"FetchBox",
					&ui.fetch_input,
					"wss://relay.example.com",
					ui.focus == .Fetch,
				)
				settings_button("AddFetchBtn", "Add")
			}
		}

		if clay.UI(clay.ID("NetworkClientGroup"))(settings_box()) {
			settings_group(N_("Open events in"))
			clay.Text(
				tr(
					"The web client an event card opens, with {id} in place of the event. For example https://primal.net/e/{id}.",
				),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			settings_input(
				ui,
				"ClientBox",
				&ui.client_input,
				DEFAULT_EVENT_CLIENT,
				ui.focus == .Client,
			)
		}
	}
}

// Shared compact field; preserve input sizing and focus behavior across settings pages.
settings_input :: proc(
	ui: ^Ui_State,
	id: string,
	buf: ^[dynamic]u8,
	placeholder: string,
	active: bool,
	width: f32 = 0,
) {
	if clay.UI(clay.ID(id))(
	{
		layout = {
			sizing = {
				width = width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(),
				height = clay.SizingFixed(30),
			},
			padding = {left = 8, right = 8},
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(6),
		border = active ? focus_border(true) : {color = FIELD_BORDER, width = bw()},
	},
	) {
		field_text(ui, id, buf, placeholder, active, 14)
	}
}

relay_row :: proc(row_id: string, remove_id: string, index: u32, relay: string) {
	row := settings_row()
	row.layout.childGap = 8
	row.border = {
		color = FIELD_BORDER,
		width = {bottom = 1},
	}
	if clay.UI(clay.ID(row_id, index))(row) {
		if clay.UI(clay.ID_LOCAL("RelayAddress"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(30)},
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		},
		) {
			clay.Text(
				relay,
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT, wrapMode = .None},
			)
			if hovered() {
				tooltip(relay)
			}
		}
		if clay.UI(clay.ID(remove_id, index))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(30)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(6),
		},
		) {
			if hovered() {
				tooltip(N_("Remove"))
				cursor_raise(.Pointer)
			}
			clay.Text(
				ICON_TRASH,
				{fontId = FONT_ICON, fontSize = 13, textColor = hovered() ? DANGER : TEXT_DIM},
			)
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
		h.connecting,
		h.pending,
		h.disconnected,
		h.sleeping,
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
	if marmot.set_account_inbox_relays(
		   client,
		   account,
		   raw_data(relays),
		   uint(len(relays)),
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   &lists,
	   ) !=
	   .OK {
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
	if clicked("RepublishBtn") {
		republish_relay_lists(ui, client)
		return
	}
	if clicked("AddInboxBtn") && len(ui.inbox_input) > 0 {
		relays := make([dynamic]cstring, context.temp_allocator)
		for relay in ui.profile.inbox {
			append(&relays, strings.clone_to_cstring(relay, context.temp_allocator))
		}
		append(
			&relays,
			strings.clone_to_cstring(string(ui.inbox_input[:]), context.temp_allocator),
		)
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
	if marmot.publish_relay_lists(
		   client,
		   account,
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
	   ) !=
	   .OK {
		ui.client_status = fmt.aprintf(
			"Couldn't republish the relay lists. %s",
			marmot.last_error(),
		)
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
