// UI prefs persistence, the settings.rs port: a tiny JSON blob in XDG
// config. All load/save failures are swallowed; defaults keep the app
// booting.
package main

import "core:time"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// The slint settings pages' knobs. Serialized nested under "prefs".
Prefs :: struct {
	// General
	launch_at_login:       bool,
	tts_enabled:           bool,
	stt_enabled:           bool,
	stt_model:             string,
	tts_voice:             int,
	start_in_tray:         bool, // honored at boot (SDL tray icon + hidden window)
	minimize_tray:         bool, // closing the window hides it to the tray
	restore_last_chat:     bool,
	last_chat:             string, // group id to reopen on launch
	notes_group:           string, // group id of the solo "Notes to self" chat
	locale:                string, // en/it/de/ja; catalogs applied via i18n.odin
	hour12:                bool,
	date_format:           int, // index into DATE_FORMATS
	quick_reactions:       [dynamic]string,
	recent_searches:       [dynamic]string, // global search, newest first, max 8
	mention_read:          [dynamic]string, // seen mention message ids, capped
	// Notifications
	notify_desktop:        bool,
	notify_sound:          bool,
	ui_sounds:             bool, // short tones on send, arrival and failure
	notify_preview:        bool,
	// Appearance
	avatar_shape:          Avatar_Shape,
	crop_avatar_shape:     Crop_Shape,
	zoom_pct:              int, // 100 = the default 1.5 render scale
	scroll_speed:          int, // wheel multiplier in percent; 200 = 2x raw
	centered_chat:         bool,
	reduce_motion:         bool, // snaps every transition; nothing animates
	body_font:             int, // message-body px delta; -2/0/+2 = small/default/large
	// Gutters: drag-resized, persisted widths and the collapsed rail.
	rail_w:                int, // chat-list card width
	panel_w:               int, // members/info panel width
	rail_collapsed:        bool, // rail shrinks to the icon nav
	// Chat-list row actions (rowactions.odin). marmot's C API exports
	// no pin/mute/mark-unread setter (only archive and mark-read), so
	// all four are local-only, keyed by group id.
	pinned:                map[string]bool, // sorts above the rest of the rail
	muted_ids:             map[string]bool, // folded into the row's muted flag
	unread_ids:            map[string]bool, // manual unread reminder
	folders:               [dynamic]string, // user-defined folder names
	folder_of:             map[string]string, // group id → folder name
	recent_chats:          bool, // false groups the list by folder
	collapsed_folders:     map[string]bool, // folder name; "" is Unfiled
	folder_icons:          map[string]int, // folder name → FOLDER_ICONS index
	folder_colors:         map[string]u32, // folder name → RGB; absent uses the theme accent
	// Advanced (telemetry/audit toggles live in marmot's shared
	// sqlite, not here)
	trusted_sites:         [dynamic]string,
	disable_link_previews: bool, // zero keeps automatic previews on for older settings
	// Nostr event cards (nevent.odin): where referenced events are
	// pulled from, and the user's own "open in" web client, a URL
	// with {id} standing for the nevent/note token.
	fetch_relays:          [dynamic]string,
	event_client:          string,
	dev_mode:              bool, // shows the Debug / KP inspector sections
	last_backup:           i64, // unix seconds of the last backup written; 0 = never
}

DEFAULT_QUICK_REACTIONS := []string{"👍", "❤️", "😂", "😮", "😢", "🙏"}

// Ceiling on the one-tap row: the message menu strip and the hold fan
// both lay these out on one line.
QUICK_MAX :: 16

default_prefs :: proc() -> Prefs {
	p := Prefs {
		restore_last_chat = true,
		locale            = "en",
		notify_desktop    = true,
		notify_sound      = true,
		ui_sounds         = true,
		notify_preview    = true,
		zoom_pct          = 100,
		scroll_speed      = 200,
		rail_w            = RAIL_W_DEFAULT,
		panel_w           = PANEL_W_DEFAULT,
	}
	for emoji in DEFAULT_QUICK_REACTIONS {
		append(&p.quick_reactions, strings.clone(emoji))
	}
	for relay in DEFAULT_FETCH_RELAYS {
		append(&p.fetch_relays, strings.clone(relay))
	}
	p.event_client = strings.clone(DEFAULT_EVENT_CLIENT)
	return p
}

Settings :: struct {
	theme:      int,
	theme_name: string, // wins over the int; survives user-theme reordering
	accent:     int,
	nicknames:  map[string]string, // account hex → private local nickname
	drafts:     map[string]string, // group id → unsent composer text
	blocked:    [dynamic]string, // account hexes, local-only like slint's blocked_accounts
	prefs:      Prefs,
}

settings_path :: proc(allocator := context.temp_allocator) -> string {
	cfg := os.get_env("XDG_CONFIG_HOME", allocator)
	if cfg == "" {
		cfg = fmt.aprintf("%s/.config", os.get_env("HOME", allocator), allocator = allocator)
	}
	return fmt.aprintf("%s/whitenoise/settings.json", cfg, allocator = allocator)
}

// "Delete for me" hidden message ids, a JSON array in a sibling file
// so settings.json keeps the slint settings.rs shape. Local-only,
// never touches the network.
hidden_path :: proc(allocator := context.temp_allocator) -> string {
	path := settings_path(allocator)
	return fmt.aprintf(
		"%s/hidden.json",
		path[:len(path) - len("/settings.json")],
		allocator = allocator,
	)
}

load_hidden :: proc(ui: ^Ui_State) {
	data, read_err := os.read_entire_file(hidden_path(), context.temp_allocator)
	if read_err != nil {
		return
	}
	ids: [dynamic]string
	if json.unmarshal(data, &ids) != nil {
		return
	}
	for id in ids {
		ui.hidden[id] = true // unmarshal allocated the strings; adopt as map keys
	}
	delete(ids)
}

save_hidden :: proc(ui: ^Ui_State) {
	path := hidden_path()
	os.make_directory(path[:len(path) - len("/hidden.json")])

	ids := make([dynamic]string, context.temp_allocator)
	for id in ui.hidden {
		append(&ids, id)
	}
	data, err := json.marshal(ids[:], allocator = context.temp_allocator)
	if err != nil {
		return
	}
	_ = os.write_entire_file(path, data)
}

load_settings :: proc(ui: ^Ui_State) {
	ui.prefs = default_prefs()
	load_hidden(ui)

	data, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
	if read_err != nil {
		return
	}
	settings: Settings
	if json.unmarshal(data, &settings) != nil {
		return
	}
	ui.theme = clamp(settings.theme, 0, max(len(theme_packs) - 1, 0))
	// The name wins when it still resolves: a user theme's index moves
	// when files come and go, the name doesn't.
	for pack, i in theme_packs {
		if pack.name == settings.theme_name {
			ui.theme = i
			break
		}
	}
	delete(settings.theme_name)
	ui.accent = clamp(settings.accent, 0, 4)
	ui.nicknames = settings.nicknames // unmarshal allocated on the heap; adopt as-is
	ui.drafts = settings.drafts
	for hex in settings.blocked {
		ui.blocked[hex] = true
	}
	delete(settings.blocked)

	// zoom_pct 0 marks a pre-prefs settings.json (or a fresh one):
	// keep the defaults instead of adopting a zeroed struct.
	if settings.prefs.zoom_pct != 0 {
		delete(ui.prefs.quick_reactions)
		delete(ui.prefs.fetch_relays)
		ui.prefs = settings.prefs
	}
	// Fields added after prefs shipped: 0 means an older settings.json.
	if ui.prefs.scroll_speed == 0 {
		ui.prefs.scroll_speed = 200
	}
	if ui.prefs.rail_w == 0 {
		ui.prefs.rail_w = RAIL_W_DEFAULT
	}
	if ui.prefs.panel_w == 0 {
		ui.prefs.panel_w = PANEL_W_DEFAULT
	}
	ui.prefs.avatar_shape = Avatar_Shape(
		clamp(int(ui.prefs.avatar_shape), 0, int(Avatar_Shape.Square)),
	)
	ui.prefs.crop_avatar_shape = Crop_Shape(
		clamp(int(ui.prefs.crop_avatar_shape), 0, int(Crop_Shape.Rounded)),
	)
	// ponytail: an empty list reads as "older settings.json", so the
	// defaults come back; a user who wants no fetch relays at all
	// cannot have that yet.
	if len(ui.prefs.fetch_relays) == 0 {
		for relay in DEFAULT_FETCH_RELAYS {
			append(&ui.prefs.fetch_relays, strings.clone(relay))
		}
	}
	if len(ui.prefs.event_client) == 0 {
		ui.prefs.event_client = strings.clone(DEFAULT_EVENT_CLIENT)
	}
}

save_settings :: proc(ui: ^Ui_State) {
	timing_start := time.tick_now()
	defer local_timing_end(.settings_save, timing_start)
	path := settings_path()
	dir := fmt.tprintf("%s", path[:len(path) - len("/settings.json")])
	os.make_directory(dir)

	blocked := make([dynamic]string, context.temp_allocator)
	for hex in ui.blocked {
		append(&blocked, hex)
	}
	data, err := json.marshal(
		Settings {
			theme = ui.theme,
			theme_name = len(theme_packs) > 0 ? theme_packs[clamp(ui.theme, 0, len(theme_packs) - 1)].name : "",
			accent = ui.accent,
			nicknames = ui.nicknames,
			drafts = ui.drafts,
			blocked = blocked,
			prefs = ui.prefs,
		},
		allocator = context.temp_allocator,
	)
	if err != nil {
		return
	}
	_ = os.write_entire_file(path, data)
}
