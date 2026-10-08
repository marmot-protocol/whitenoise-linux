// Settings → Network & relays: the two published relay lists
// (NIP-65 outbox, kind-10050 inbox) plus the relay-pool health
// counters marmot exposes.
//
// ponytail: every marmot call here runs on the UI thread, like the
// rest of the port. A frame stalls for the round trip; move to the
// worker pool when the stall gets noticed.
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:unicode/utf8"

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
		settings_socks5(ui)
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
				settings_button("NetRefresh", tr("Refresh"))
			}
			clay.Text(health_detail(ui), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}

		if clay.UI(clay.ID("NetworkOutboxGroup"))(settings_box()) {
			settings_group(tr("Published outbox relays (NIP-65)"))
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
				settings_button("AddRelayBtn", tr("Add"))
			}
		}

		if clay.UI(clay.ID("NetworkInboxGroup"))(settings_box()) {
			settings_group(tr("Published inbox relays"))
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
				settings_button("AddInboxBtn", tr("Add"))
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
					tr("Republish relay lists"),
					tr(
						"Re-broadcasts your outbox and inbox relay lists. Use this if peers can't find you.",
					),
				)
				settings_button("RepublishBtn", tr("Republish"))
			}
		}
	} else {
		if clay.UI(clay.ID("NetworkFetchGroup"))(settings_box()) {
			settings_group(tr("Event fetch relays"))
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
				settings_button("AddFetchBtn", tr("Add"))
			}
		}

		if clay.UI(clay.ID("NetworkClientGroup"))(settings_box()) {
			settings_group(tr("Open events in"))
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

// Match the SDK's SocketAddr syntax without DNS lookups or accepting credentials.
@(private)
socks5_proxy_valid :: proc(endpoint: string) -> bool {
	if len(endpoint) == 0 {return false}
	host, port_text: string
	if endpoint[0] == '[' {
		end := strings.last_index(endpoint, "]:")
		if end < 2 {return false}
		host, port_text = endpoint[1:end], endpoint[end + 2:]
		for ch in host {
			if !(ch >= '0' && ch <= '9') &&
			   !(ch >= 'a' && ch <= 'f') &&
			   !(ch >= 'A' && ch <= 'F') &&
			   ch != ':' &&
			   ch != '.' {return false}
		}
		_, ok := net.parse_ip6_address(host)
		if !ok {return false}
		if strings.contains(host, ".") {
			last := strings.last_index(host, ":")
			if last < 0 || !socks5_ipv4_valid(host[last + 1:]) {return false}
		}
	} else {
		if strings.count(endpoint, ":") != 1 {return false}
		end := strings.last_index(endpoint, ":")
		host, port_text = endpoint[:end], endpoint[end + 1:]
		if !socks5_ipv4_valid(host) {return false}
	}
	if len(port_text) == 0 {return false}
	port := 0
	for ch in port_text {
		if ch < '0' || ch > '9' {return false}
		port = port * 10 + int(ch - '0')
		if port > 65535 {return false}
	}
	return port > 0
}

@(private = "file")
socks5_ipv4_valid :: proc(host: string) -> bool {
	// Rust SocketAddr rejects ambiguous leading zeros, even in decimal octets.
	start := 0
	pieces := 0
	for i in 0 ..= len(host) {
		if i < len(host) && host[i] != '.' {continue}
		piece := host[start:i]
		if len(piece) == 0 || len(piece) > 3 || (len(piece) > 1 && piece[0] == '0') {return false}
		value := 0
		for ch in piece {
			if ch < '0' || ch > '9' {return false}
			value = value * 10 + int(ch - '0')
		}
		if value > 255 {return false}
		pieces += 1
		start = i + 1
	}
	return pieces == 4
}

@(private)
settings_socks5 :: proc(ui: ^Ui_State) {
	if !ui.socks5_initialized {
		ui.socks5_enabled = ui.prefs.socks5_proxy != ""
		ui.socks5_auth = ui.prefs.socks5_auth
		address := ui.socks5_enabled ? ui.prefs.socks5_proxy : "127.0.0.1:9050"
		append(&ui.socks5_input, ..transmute([]u8)address)
		if ui.socks5_auth {
			credentials, ok := socks5_load_auth()
			ui.socks5_load_error = !ok
			if ok {
				append(&ui.socks5_username, ..transmute([]u8)credentials.username)
				append(&ui.socks5_password, ..transmute([]u8)credentials.password)
			}
			for value in ([2]string{credentials.username, credentials.password}) {mem.zero_slice(transmute([]u8)value)}
		}
		ui.socks5_initialized = true
	}
	if clay.UI(clay.ID("NetworkProxyGroup"))(settings_box()) {
		settings_group(tr("SOCKS5 proxy"))
		settings_check(
			"TgSocks5",
			ui.socks5_enabled,
			tr("Use a SOCKS5 proxy"),
			tr("Save changes, then restart White Noise to apply them."),
		)
		if ui.socks5_enabled {
			settings_input(
				ui,
				"Socks5Box",
				&ui.socks5_input,
				"127.0.0.1:9050",
				ui.focus == .Socks5,
			)
			clay.Text(
				tr(
					"Numeric IP and port only: 127.0.0.1:9050 or [::1]:9050. No URLs or hostnames.",
				),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			settings_check(
				"TgSocks5Auth",
				ui.socks5_auth,
				tr("Use username and password"),
				tr("Your proxy credentials are stored in your encrypted vault."),
			)
			if ui.socks5_auth {
				if clay.UI(clay.ID("Socks5Credentials"))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10}},
				) {
					gate_field(
						ui,
						"Socks5UserBox",
						&ui.socks5_username,
						ui.focus == .Socks5User,
						tr("Username"),
						.Plain,
					)
					gate_field(
						ui,
						"Socks5PasswordBox",
						&ui.socks5_password,
						ui.focus == .Socks5Password,
						tr("Password"),
					)
				}
			}
		}
		valid := socks5_form_valid(ui)
		settings_button("SaveSocks5", tr("Save"), valid && ui.socks5_job == nil ? TEXT : TEXT_DIM)
		clay.Text(
			tr("Press Enter to save; Escape returns to the switches."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
		status := tr("Changes require a restart; the current connection is unchanged.")
		if ui.socks5_job != nil {
			status = tr("Saving your proxy settings and encrypted credentials.")
			busy_bar("Socks5SaveProgress")
		} else if ui.socks5_save_error {
			status = tr("Couldn't save proxy credentials. Please try again.")
		} else if ui.socks5_load_error {
			status = tr("Couldn't load proxy credentials. Enter them again and save.")
		} else if ui.socks5_enabled && !socks5_proxy_valid(string(ui.socks5_input[:])) {
			status = tr(
				"Enter a numeric IPv4 or bracketed IPv6 address with a port from 1 to 65535.",
			)
		} else if !valid {
			status = tr("Enter a username and password, each between 1 and 255 UTF-8 bytes.")
		} else if ui.socks5_saved &&
		   (ui.socks5_enabled ? string(ui.socks5_input[:]) : "") == ui.prefs.socks5_proxy {
			status = tr("Saved. Restart White Noise to apply this connection setting.")
		}
		clay.Text(status, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		clay.Text(
			tr(
				"Relay names are resolved by your proxy. Media host checks still use your local DNS.",
			),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
		external_note: string
		when ODIN_OS == .Windows {
			external_note = tr(
				"External browsers, other apps, and Windows app updates do not use this setting.",
			)
		} else {
			external_note = tr("External browsers and other apps do not use this setting.")
		}
		clay.Text(external_note, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	}
}

@(private)
save_socks5 :: proc(ui: ^Ui_State) {
	if ui.socks5_job != nil || !socks5_form_valid(ui) {return}
	job := new(Socks5_Work)
	job.address = strings.clone(ui.socks5_enabled ? string(ui.socks5_input[:]) : "")
	job.auth = ui.socks5_enabled && ui.socks5_auth
	if job.auth {
		credentials := Socks5_Credentials {
			string(ui.socks5_username[:]),
			string(ui.socks5_password[:]),
		}
		data, err := json.marshal(credentials)
		if err != nil {
			delete(job.address); free(job)
			ui.socks5_save_error = true
			return
		}
		job.credentials = data
	}
	job.worker = thread.create(proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		defer free_all(context.temp_allocator)
		job := (^Socks5_Work)(t.data)
		job.err =
			job.auth ? vault_set(SOCKS5_VAULT_KEY, string(job.credentials)) : vault_remove(SOCKS5_VAULT_KEY)
		frame_wake()
	})
	job.worker.data = job
	ui.socks5_job = job
	ui.socks5_saved = false
	ui.socks5_save_error = false
	thread.start(job.worker)
}

@(private = "file")
SOCKS5_VAULT_KEY :: "network:socks5"

@(private)
SOCKS5_FIELDS :: bit_set[Focus]{.Socks5, .Socks5User, .Socks5Password}

@(private = "file")
Socks5_Credentials :: struct {
	username, password: string,
}

@(private)
Socks5_Work :: struct {
	worker:      ^thread.Thread,
	address:     string,
	credentials: []u8,
	auth:        bool,
	err:         Vault_Err,
}

@(private)
socks5_auth_valid :: proc(username, password: string) -> bool {
	for value in ([2]string{username, password}) {
		if len(value) < 1 ||
		   len(value) > 255 ||
		   strings.contains(value, "\x00") ||
		   !utf8.valid_string(value) {return false}
	}
	return true
}

@(private = "file")
socks5_form_valid :: proc(ui: ^Ui_State) -> bool {
	if !ui.socks5_enabled {return true}
	return(
		socks5_proxy_valid(string(ui.socks5_input[:])) &&
		(!ui.socks5_auth ||
				socks5_auth_valid(string(ui.socks5_username[:]), string(ui.socks5_password[:]))) \
	)
}

@(private = "file")
socks5_load_auth :: proc() -> (credentials: Socks5_Credentials, ok: bool) {
	data, found := vault_get(SOCKS5_VAULT_KEY, context.temp_allocator)
	defer mem.zero_slice(transmute([]u8)data)
	if !found {return}
	if json.unmarshal(transmute([]u8)data, &credentials, allocator = context.temp_allocator) !=
	   nil {return}
	ok = socks5_auth_valid(credentials.username, credentials.password)
	return
}

// Freeze credentials once per process, after unlock and before network workers.
@(private)
socks5_configure :: proc(ui: ^Ui_State) -> bool {
	credentials: Socks5_Credentials
	defer {for value in ([2]string{credentials.username, credentials.password}) {mem.zero_slice(transmute([]u8)value)}}
	if ui.prefs.socks5_proxy != "" && ui.prefs.socks5_auth {
		ok: bool
		credentials, ok = socks5_load_auth()
		if !ok {
			ui.login_error = strings.clone(
				tr("Couldn't load proxy credentials. Enter them again and save."),
			)
			return false
		}
	}
	keys := [2]string{"WN_SOCKS5_USERNAME", "WN_SOCKS5_PASSWORD"}
	values := [2]string{credentials.username, credentials.password}
	for key, i in keys {
		if os.set_env(key, values[i]) != nil {return false}
		when ODIN_OS == .Windows {
			if set_c_env(
				   strings.clone_to_cstring(key, context.temp_allocator),
				   strings.clone_to_cstring(values[i], context.temp_allocator),
			   ) !=
			   0 {return false}
		}
	}
	return true
}

@(private)
socks5_drain :: proc(ui: ^Ui_State) {
	job := ui.socks5_job
	if job == nil || !thread.is_done(job.worker) {return}
	thread.join(job.worker)
	thread.destroy(job.worker)
	ui.socks5_save_error = job.err != .None
	if job.err == .None {
		delete(ui.prefs.socks5_proxy)
		ui.prefs.socks5_proxy, job.address = job.address, ""
		ui.prefs.socks5_auth = job.auth
		ui.socks5_saved = true
		ui.socks5_load_error = false
		ui.settings_dirty = true
	}
	mem.zero_slice(job.credentials)
	delete(job.credentials)
	delete(job.address)
	free(job)
	ui.socks5_job = nil
}

@(private)
socks5_stop :: proc(ui: ^Ui_State) {
	if ui.socks5_job == nil {return}
	thread.join(ui.socks5_job.worker)
	socks5_drain(ui)
}

@(private)
socks5_fields :: proc(ui: ^Ui_State) {
	if ui.socks5_job != nil || !ui.socks5_enabled {return}
	if field_mouse(ui, &ui.socks5_input, "Socks5Box", 14) {ui.focus = .Socks5}
	if !ui.socks5_auth {return}
	if field_mouse(ui, &ui.socks5_username, "Socks5UserBox", 15) {ui.focus = .Socks5User}
	if clicked("Socks5PasswordBox") {ui.focus = .Socks5Password}
	if ui.focus in
	   SOCKS5_FIELDS {tab_focus([]Focus{.Socks5, .Socks5User, .Socks5Password}, &ui.focus)}
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
				tooltip(tr("Remove"))
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
	account_relays_start(ui, client, relays, .Inbox)
}

reload_profile :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// load_profile only writes fields the cache has, so a field removed
	// upstream must be emptied here or the old value would stay.
	p := &ui.profile
	delete(p.npub); delete(p.name); delete(p.username)
	delete(p.about); delete(p.nip05); delete(p.lud16)
	p.npub, p.name, p.username, p.about, p.nip05, p.lud16 = "", "", "", "", "", ""
	p.pic_set = false
	p.loaded = false
	clear(&p.nip65)
	clear(&p.inbox)
	load_profile(client, ui)
}

// ── Clicks ──────────────────────────────────────────────────────────

handle_network :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("SaveSocks5") {
		save_socks5(ui)
		return
	}
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
	account_job_start(account_job_new(ui, client, .Relays))
}

// Rail/status-bar counter: live connected-of-total once a health call
// has landed, the configured relay count before that.
relay_counter :: proc(ui: ^Ui_State) -> string {
	if ui.health_ok {
		return fmt.tprintf(tr("%d/%d RELAYS"), ui.health.connected, ui.health.total_relays)
	}
	return fmt.tprintf(tr("%d/%d RELAYS"), 0, len(DEFAULT_RELAYS))
}
