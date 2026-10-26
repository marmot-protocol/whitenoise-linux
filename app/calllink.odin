// Call links from other apps, drawn as a card under the body instead of a
// bare URL, so it is clear the call happens outside White Noise.
//
//   https://signal.link/call/#key=rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb
//   https://meet.jit.si/WeeklyStandup
//   https://meet.example.org/WeeklyStandup     (self-hosted Jitsi)
//
// Signal links are recognized from the URL alone. A Jitsi room is any
// one-segment https path, but only meet.jit.si is known to be Jitsi, so
// another host gets one request for /external_api.js, the embed script
// every Jitsi Meet deployment serves. That answer is cached per host for
// the session, and the probe only runs while link previews are on.
//
// Clicking goes through the external-link guard like a text link. When
// the app's desktop client handles its scheme (sgnl://, jitsi-meet://)
// the guard opens the call there; otherwise the browser gets the https
// link.
//
// ponytail: both caches live for the session, so a host that starts
// serving Jitsi or a client installed mid-session needs a restart.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/windows"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"

_ :: windows

@(private)
Call_App :: enum u8 {
	Signal,
	Jitsi,
}

// What a URL names. host and room slice into it; room is "" for Signal.
@(private)
Call_Link :: struct {
	app:  Call_App,
	host: string,
	room: string,
}

// Each app's own colors, not a theme's: the card should look like the
// app that runs the call, the same on every pack.
@(private = "file")
Call_Brand :: struct {
	name:    string, // also the macOS bundle name, "<name>.app"
	scheme:  string, // the desktop client's URL scheme
	glyph:   string,
	color:   clay.Color,
	pressed: clay.Color,
}

@(private = "file")
CALL_BRANDS := [Call_App]Call_Brand {
	.Signal = {"Signal", "sgnl", "\uf075", {58, 118, 240, 255}, {44, 96, 206, 255}},
	.Jitsi  = {"Jitsi Meet", "jitsi-meet", "\uf03d", {23, 102, 196, 255}, {17, 82, 162, 255}},
}

@(private = "file")
CALL_INK :: clay.Color{255, 255, 255, 255}

@(private)
call_link :: proc(url: string) -> (link: Call_Link, ok: bool) {
	if _, signal := signal_call_key(url); signal {
		return {app = .Signal, host = "signal.link"}, true
	}
	host, room, shaped := jitsi_room(url)
	if !shaped {return}
	if !strings.equal_fold(host, JITSI_PUBLIC) && jitsi_hosts[host] != .Yes {return}
	return {app = .Jitsi, host = host, room = room}, true
}

// ---- Signal ----

// Both path spellings Signal's clients accept.
@(private = "file")
SIGNAL_CALL_PREFIXES :: [?]string{"https://signal.link/call/#", "https://signal.link/call#"}

// ringrtc's "consonant base 16": one byte is two of these.
@(private = "file")
SIGNAL_KEY_ALPHABET :: "bcdfghkmnpqrstxz"

// Characters per dash-separated group. v0 keys are 16 bytes in pairs;
// v1 keys append a version byte and a server epoch.
@(private = "file")
SIGNAL_KEY_V0 :: [?]int{4, 4, 4, 4, 4, 4, 4, 4}
@(private = "file")
SIGNAL_KEY_V1 :: [?]int{8, 8, 8, 8, 2, 8}

// The call's root key (a slice of url), or ok = false. The fragment is
// "&"-separated name=value pairs, as Signal parses it; "key" must be
// present once and other names are ignored.
@(private)
signal_call_key :: proc(url: string) -> (key: string, ok: bool) {
	fragment := ""
	prefixes := SIGNAL_CALL_PREFIXES
	for prefix in prefixes {
		if strings.has_prefix(url, prefix) {
			fragment = url[len(prefix):]
			break
		}
	}
	if fragment == "" {return}

	for part in strings.split_iterator(&fragment, "&") {
		name, eq, value := strings.partition(part, "=")
		if name == "" || strings.contains_rune(value, '=') {return "", false}
		if name != "key" {continue}
		if key != "" || eq == "" {return "", false}
		key = value
	}
	v0, v1 := SIGNAL_KEY_V0, SIGNAL_KEY_V1
	if !signal_key_shape(key, v0[:]) && !signal_key_shape(key, v1[:]) {return "", false}
	return key, true
}

// key is exactly `groups` runs of alphabet characters joined by '-'.
@(private = "file")
signal_key_shape :: proc(key: string, groups: []int) -> bool {
	at := 0
	for n, g in groups {
		if g > 0 {
			if at == len(key) || key[at] != '-' {return false}
			at += 1
		}
		if at + n > len(key) {return false}
		for i in at ..< at + n {
			if strings.index_byte(SIGNAL_KEY_ALPHABET, key[i]) < 0 {return false}
		}
		at += n
	}
	return at == len(key)
}

// ---- Jitsi ----

@(private = "file")
JITSI_PUBLIC :: "meet.jit.si"

@(private)
Jitsi_Host :: enum u8 {
	Unknown,
	Probing,
	No,
	Yes,
}

// host → what its /external_api.js said. Keys are owned.
@(private)
jitsi_hosts: map[string]Jitsi_Host
@(private = "file")
jitsi_mutex: sync.Mutex
@(private = "file")
jitsi_fresh: [dynamic]struct {
	host: string, // the jitsi_hosts key
	yes:  bool,
}

// "https://host/Room" with nothing after the room but a query or
// fragment. A dot in the room rules out files (/favicon.ico), and
// userinfo ("https://a@b/") is refused so the card names the real host.
@(private)
jitsi_room :: proc(url: string) -> (host, room: string, ok: bool) {
	if !strings.has_prefix(url, "https://") {return}
	rest := url[len("https://"):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 {return}
	host = rest[:slash]
	room = rest[slash + 1:]
	if cut := strings.index_any(room, "?#"); cut >= 0 {room = room[:cut]}
	if room == "" || len(room) > 256 || !strings.contains_rune(host, '.') {return "", "", false}
	for c in transmute([]u8)host {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', ':':
		case:
			return "", "", false
		}
	}
	for c in transmute([]u8)room {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '%':
		case:
			return "", "", false
		}
	}
	return host, room, true
}

// Ask a room link's host whether it runs Jitsi, once per session.
@(private)
jitsi_probe :: proc(url: string) {
	host, _, ok := jitsi_room(url)
	if !ok || strings.equal_fold(host, JITSI_PUBLIC) || host in jitsi_hosts {return}
	owned := strings.clone(host)
	jitsi_hosts[owned] = .Probing
	append(&send_threads, thread.create_and_start_with_poly_data(owned, jitsi_worker))
}

@(private = "file")
jitsi_worker :: proc(host: string) {
	context.allocator = reload_allocator()
	defer frame_wake()
	url := fmt.aprintf("https://%s/external_api.js", host)
	defer delete(url)
	state, out, errs, err := tool_exec(
		{command = {curl_path(), "-sf", "--max-time", "10", "--max-filesize", "4194304", url}},
		context.allocator,
	)
	defer delete(out)
	defer delete(errs)
	yes :=
		err == nil && state.exit_code == 0 && strings.contains(string(out), "JitsiMeetExternalAPI")
	sync.lock(&jitsi_mutex)
	append(&jitsi_fresh, struct {
		host: string,
		yes:  bool,
	}{host, yes})
	sync.unlock(&jitsi_mutex)
}

// Frame-loop drain. A new Jitsi host turns already-wrapped link rows
// into card rows, so the wrap cache has to go.
@(private)
drain_jitsi :: proc() {
	sync.lock(&jitsi_mutex)
	defer sync.unlock(&jitsi_mutex)
	for fresh in jitsi_fresh {
		jitsi_hosts[fresh.host] = fresh.yes ? .Yes : .No
		if fresh.yes {wrap_flush = true}
	}
	clear(&jitsi_fresh)
}

// ---- Desktop clients ----

// Whether each app's desktop client handles its scheme here, probed the
// first time one of its cards is drawn. Until then clicks use https.
@(private)
Call_Client :: enum u8 {
	Unknown,
	Probing,
	Missing,
	Installed,
}

@(private)
call_clients: [Call_App]Call_Client

@(private = "file")
call_client_probe :: proc(app: Call_App) {
	if sync.atomic_load(&call_clients[app]) != .Unknown {return}
	sync.atomic_store(&call_clients[app], Call_Client.Probing)
	when ODIN_OS == .OpenBSD {
		// No exec promise: links are only ever copied.
		sync.atomic_store(&call_clients[app], Call_Client.Missing)
	} else when ODIN_OS == .Windows {
		// Installers register the scheme under HKCR\<scheme>.
		key: windows.HKEY
		scheme := windows.utf8_to_wstring(CALL_BRANDS[app].scheme)
		found :=
			windows.RegOpenKeyExW(windows.HKEY_CLASSES_ROOT, scheme, 0, windows.KEY_READ, &key) ==
			0
		if found {windows.RegCloseKey(key)}
		sync.atomic_store(&call_clients[app], found ? Call_Client.Installed : .Missing)
	} else when ODIN_OS == .Darwin {
		// ponytail: only the two Applications folders; ask LaunchServices
		// (LSCopyDefaultApplicationURLForURL) if that misses installs.
		bundle := fmt.tprintf("Applications/%s.app", CALL_BRANDS[app].name)
		home := os.get_env("HOME", context.temp_allocator)
		found :=
			os.exists(fmt.tprintf("/%s", bundle)) ||
			(home != "" && os.exists(fmt.tprintf("%s/%s", home, bundle)))
		sync.atomic_store(&call_clients[app], found ? Call_Client.Installed : .Missing)
	} else {
		// xdg-mime is a shell script; keep it off the UI thread.
		append(&send_threads, thread.create_and_start_with_poly_data(app, call_client_worker))
	}
}

// The handler xdg-open would pick. Inside a Flatpak xdg-mime is absent
// or sees only the sandbox, so the answer is Missing and https still
// works.
@(private = "file")
call_client_worker :: proc(app: Call_App) {
	context.allocator = reload_allocator()
	defer frame_wake()
	mime := fmt.aprintf("x-scheme-handler/%s", CALL_BRANDS[app].scheme)
	defer delete(mime)
	state, out, errs, err := os.process_exec(
		{command = {"xdg-mime", "query", "default", mime}},
		context.allocator,
	)
	defer delete(out)
	defer delete(errs)
	found := err == nil && state.exit_code == 0 && strings.trim_space(string(out)) != ""
	sync.atomic_store(&call_clients[app], found ? Call_Client.Installed : .Missing)
}

// The desktop client's form of a call link and the client's name, or
// "" when url is no call link or the browser has to take it.
//
//   https://signal.link/call/#key=…  →  sgnl://signal.link/call/#key=…
//   https://meet.example.org/Room    →  jitsi-meet://meet.example.org/Room
@(private)
call_app_link :: proc(url: string) -> (target, name: string) {
	link, ok := call_link(url)
	if !ok || sync.atomic_load(&call_clients[link.app]) != .Installed {return}
	switch link.app {
	case .Signal:
		_, _, fragment := strings.partition(url, "#")
		target = fmt.tprintf("sgnl://signal.link/call/#%s", fragment)
	case .Jitsi:
		target = fmt.tprintf("jitsi-meet://%s", url[len("https://"):])
	}
	return target, CALL_BRANDS[link.app].name
}

// ---- Card ----

// Styled after the app that runs the call: its icon tile and a join
// button in its color, with a caption saying where the click goes.
//
//   +-----------------------------------------------+
//   |  [##]  Jitsi Meet call                        |
//   |  [##]  WeeklyStandup . meet.example.org       |
//   |  +-----------------------------------------+  |
//   |  |         [cam]  Join in Jitsi Meet       |  |  brand color
//   |  +-----------------------------------------+  |
//   |  Opens Jitsi Meet, outside White Noise.       |
//   +-----------------------------------------------+
@(private)
call_card :: proc(id: u32, url: string, link: Call_Link) {
	call_client_probe(link.app)
	brand := CALL_BRANDS[link.app]
	installed := sync.atomic_load(&call_clients[link.app]) == .Installed

	title, meta := tr("Signal call"), link.host
	if link.app == .Jitsi {
		title, meta = tr("Jitsi Meet call"), fmt.tprintf("%s · %s", link.room, link.host)
	}

	icon, action, caption: string
	switch {
	case ODIN_OS == .OpenBSD:
		icon, action = ICON_COPY, external_link_action()
		caption = tr("The call runs outside White Noise.")
	case installed:
		icon, action = "\uf03d", fmt.tprintf(tr("Join in %s"), brand.name)
		caption = fmt.tprintf(tr("Opens %s, outside White Noise."), brand.name)
	case link.app == .Signal:
		icon, action = ICON_GLOBE, external_link_action()
		caption = tr("Opens signal.link in your browser. You need the Signal app to join.")
	case:
		icon, action = ICON_GLOBE, tr("Join in browser")
		caption = fmt.tprintf(tr("Opens %s in your browser, outside White Noise."), link.host)
	}

	if clay.UI(clay.ID("CallCard", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(att_w(360))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(14),
			childGap = 12,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(14),
		border = {color = hovered() ? fade(brand.color, 0.7) : CARD_BORDER, width = bw()},
	},
	) {
		card_hover := hovered()
		if card_hover {
			link_hover = url
			cursor_raise(.Pointer)
		}

		if clay.UI(clay.ID("CallCardHead", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 12,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("CallCardTile", id))(
			{
				layout = {
					sizing = {clay.SizingFixed(44), clay.SizingFixed(44)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = brand.color,
				cornerRadius = rr(12),
			},
			) {
				clay.Text(brand.glyph, {fontId = FONT_ICON, fontSize = 21, textColor = CALL_INK})
			}
			if clay.UI(clay.ID("CallCardName", id))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 4,
				},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					title,
					{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT, wrapMode = .None},
				)
				clay.Text(
					meta,
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
				)
			}
		}

		if clay.UI(clay.ID("CallCardJoin", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 12, right = 12, top = 10, bottom = 10},
				childGap = 8,
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = card_hover ? brand.pressed : brand.color,
			cornerRadius = rr(10),
		},
		) {
			clay.Text(icon, {fontId = FONT_ICON, fontSize = 13, textColor = CALL_INK})
			clay.Text(
				action,
				{fontId = FONT_TITLE, fontSize = 13, textColor = CALL_INK, wrapMode = .None},
			)
		}

		clay.Text(caption, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	}
}
