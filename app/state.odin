package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

apply_theme :: proc(theme: int, accent: int) {
	if len(theme_packs) == 0 {
		return
	}
	pack := &theme_packs[clamp(theme, 0, len(theme_packs) - 1)]
	slot := clamp(accent, 0, 4)

	BG = pack.bg
	CARD = pack.elevated
	CARD_BORDER = pack.card_border
	STATUS_BAR = pack.status_bar
	RAIL_BG = pack.elevated
	ROW_BG = pack.field
	FIELD_BORDER = pack.field_border
	HOVER = pack.hover
	SELECTED = pack.accent_surface[slot]
	PLATE = pack.plate
	DIVIDER = pack.divider
	ELEVATED_BORDER = pack.elevated_border
	BORDER_2 = pack.border_2
	ON_ACCENT = pack.on_accent
	ACCENT = pack.accent_base[slot]
	ACCENT_DIM = pack.accent_dim[slot]
	TEXT = pack.text_hi
	TEXT_DIM = pack.text_mid
	TEXT_LO = pack.text_lo
	DANGER = pack.danger

	// Structural metrics + capability flags (retro squares corners and
	// doubles borders; synthwave mounts the grid backdrop).
	R_SCALE = pack.r_scale
	BORDER_W = u16(max(pack.border_w, 1))
	SYNTH_GRID = pack.synth_grid
	PAPER_DECOR = pack.paper_doodles
	SCANLINES = pack.scanlines
}

// A proportional sans for body text with bold titles; mono stays for
// code plates and eyebrow-style captions. Each stack is tried in order
// and misses are skipped, so a packaged build finds its own bundled
// copy first and a source build falls through to the system font. The
// system paths cover the three common layouts: Arch (flat, by family),
// Debian/Ubuntu (truetype/<family>), and Fedora (<family>-<style>).
FONT_CANDIDATES := []cstring{
	"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
}
TITLE_CANDIDATES := []cstring{
	"/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf",
	"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
}
MONO_CANDIDATES := []cstring{
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

Chat_Row_Ui :: struct {
	group_id: string, // group_id_hex, the chat's stable key
	title:    string,
	preview:  string,
	at:       string, // last-activity HH:MM
	unread:   u64,
	pending:  bool, // invite awaiting accept/decline
	stable:   bool, // MLS lifecycle stable (session established)
	tick:     marmot.Delivery_State,
	first_unread: string, // first unread message id, "" = none
	avatar_url: string, // chat picture URL, "" = none
	image_hash: string, // encrypted-Blossom avatar hash, "" = none
	muted:    bool, // marmot's per-chat mute, suppresses notifications
	last_id:  string, // latest message id, "" = none (notification dedupe)
	last_kind: u64, // latest message's event kind
	last_mine: bool, // latest message is an own send
}

// One picked-but-unsent attachment, shown as a chip above the composer
// (the slint staged_files row). Images carry a decoded thumbnail that
// also provides the send's "WxH" dim.
Staged_File :: struct {
	name:       string,
	media_type: string, // static literal from media_type_for, never freed
	data:       []u8,
	tex:        ^rl.Texture2D, // nil for non-images
}

Reaction_Ui :: struct {
	label: string, // text fallback when no twemoji tile, e.g. "👍 2"
	emoji: string,
	count: string,
	mine:  bool, // clicking toggles: unreact when mine, react otherwise
	ghost: bool, // optimistic: the op is still in flight, drawn faded
}

// A react/unreact still on the wire, overlaid onto the timeline so the
// chip appears the instant it is clicked. Dropped by drain_ops on the
// ack; a reload in between re-applies whatever is still pending.
Pending_React :: struct {
	ticket: int,
	msg_id: string,
	emoji:  string,
	remove: bool, // an unreact: fade the existing chip instead of adding one
}

// One entry of an edited message's history: the original, then each
// applied edit in order (last = current text).
Edit_Version :: struct {
	at:   string, // HH:MM
	text: string,
}

// Which input box receives typed characters.
Focus :: enum {
	Compose,
	Search,
	Invite,
	Rename,
	Desc, // group hero description editor
	Ov, // Openverse image-search query box
	NC_Member,
	NC_Name,
	Filter, // sidebar chat filter
	Picker, // emoji-picker search box
	Name, // profile display name
	About, // profile about box
	Nip05, // profile NIP-05 box
	Lud16, // profile lightning-address box
	Relay, // profile add-relay box
	Nick, // contact nickname box
	Fwd, // forward-picker filter box
	GSearch, // global-search modal box
	KP, // KP-inspector pubkey box
	Inbox, // settings inbox-relay box
	ExportPw, // export-ncryptsec password box
	BackupPw, // backup create/import password box
	EmojiName, // custom-emoji shortcode box
	Folder, // folder-modal name box
	Pal, // command-palette query box
}

// One rendered block of a message body, converted out of the FFI
// markdown tree into UI-owned strings at load time.
Md_Kind :: enum {
	Para,
	Heading,
	Code,
	Quote,
	List_Item,
	Rule,
	Table,
}

Md_Block_Ui :: struct {
	kind:  Md_Kind,
	text:  string,
	level: int, // heading level
	cells: [][]string, // table rows, row 0 = header
}

Msg_Ui :: struct {
	id:        string, // message_id_hex
	sender:    string, // display label: kind-0 name, else short hex / "you"
	sender_id: string, // account hex
	pic_url:   string, // sender's kind-0 picture, "" = none
	body:      string, // plaintext fallback when blocks is empty
	blocks:    [dynamic]Md_Block_Ui,
	reactions:  [dynamic]Reaction_Ui,
	reply_from: string, // sender of the replied-to message, "" = not a reply
	reply_text: string,
	reply_id:   string, // parent message id, the preview's jump target
	images:    [dynamic]Att_Item(^rl.Texture2D), // downloaded attachments, heap ptrs for clay
	models:    [dynamic]Att_Item(^Stl_View), // STL attachments, owned by the stl_views cache
	videos:    [dynamic]Att_Item(^Video_View), // video attachments, owned by the video_views cache
	audios:    [dynamic]Att_Item(^Video_View), // audio attachments, same cache (mpv plays, no frames)
	gcodes:    [dynamic]Att_Item(^Gcode_View), // g-code attachments, owned by the gcode_views cache
	pdfs:      [dynamic]Att_Item(^Pdf_View), // pdf attachments, owned by the pdf_views cache
	arcs:      [dynamic]Att_Item(^Arc_View), // archive attachments, owned by the arc_views cache
	xdcs:      [dynamic]Att_Item(^Xdc_View), // webxdc apps, owned by the xdc_views cache
	txts:      [dynamic]Att_Item(^Txt_View), // text/markdown attachments, owned by the txt_views cache
	codes:     [dynamic]Att_Item(^Code_View), // source attachments, owned by the code_views cache
	fonts:     [dynamic]Att_Item(^Ttf_View), // font attachments, owned by the ttf_views cache
	att_names: [dynamic]string, // every media reference by index, for the ctx-menu save rows
	att_keys:  [dynamic]string, // cache key (plaintext sha256) per media index
	files:     [dynamic]int, // att_names indices with no inline renderer (chip rows)
	img_failed: [dynamic]Att_Item(string), // failed image cells: cache key + media index
	at:        string, // HH:MM
	at_full:   string, // full date + time, the stamp's hover tooltip
	day:       string, // YYYY-MM-DD or "Today", for day markers
	mine:      bool,
	system:    bool, // kind-1210 group-system line; body holds the sentence
	deleted:   bool, // tombstone: placeholder row, no body/actions
	edited:    bool, // kind-1009 edits applied; body holds the latest
	media_failed: bool, // an image attachment failed to download
	effect:    int, // ["effect", key] burst id from the event tags, 0 = none
	history:   [dynamic]Edit_Version,
}

Page :: enum {
	Chats,
	Contacts,
	Archived,
	Settings,
	Profile,
}

PAGE_LABELS := [Page]string{
	.Chats    = "Chat",
	.Contacts = "Ppl",
	.Archived = "Arc",
	.Settings = "Set",
	.Profile  = "Me",
}

Member_Ui :: struct {
	id_hex:   string,
	npub:     string, // bech32 of id_hex, the row's subline
	name:     string,
	pic_url:  string, // kind-0 picture, "" = none
	is_admin: bool,
	is_self:  bool,
}

// One chat shared with a contact, for the GROUPS IN COMMON section.
Common_Group :: struct {
	title:   string,
	members: int,
}

Contact_Ui :: struct {
	id_hex:   string,
	name:     string, // display name or truncated id
	pic_url:  string, // kind-0 picture, "" = none
	npub:     string,
	followed: bool, // on the account's NIP-02 list
	groups:   [dynamic]Common_Group, // chats shared with this contact
}

Profile_Ui :: struct {
	npub:     string,
	name:     string, // display name
	about:    string, // kind-0 `about`
	username: string, // kind-0 `name` handle
	nip05:    string,
	lud16:    string,
	pic_set:  bool, // kind-0 has a picture URL
	nip65:    [dynamic]string,
	inbox:    [dynamic]string,
	nsec:     string, // revealed on demand, "" otherwise
	loaded:   bool,
	editing:  bool, // profile page shows the edit form
	qr:       ^rl.Texture2D, // own marmot:// deep link, page-inline
}

Ui_State :: struct {
	account_ref:   string, // active account's full hex; "" when logged out
	account_ids:   [dynamic]string, // full hex per switcher row
	accounts:      [dynamic]string, // kind-0 name (else truncated hex) per row
	account_npubs: [dynamic]string, // npub per row, for the switcher sublabels
	account_pics:  [dynamic]string, // kind-0 picture URL per row, "" = none
	accounts_open: bool, // the Accounts switcher modal
	peer_open:     bool, // peer-profile popup (any avatar click)
	peer_hex:      string,
	peer_name:     string,
	peer_pic:      string, // kind-0 picture URL, "" = none
	peer_npub:     string, // derived from peer_hex, "" if malformed
	peer_contact:  bool, // peer is in the contacts list
	add_account_open: bool, // show the login pane to add another account
	member_count:  int, // selected chat's member count
	scroll_pending: bool, // jump timeline scroll to newest after reload
	selected_contact: int, // index into contacts, -1 = none
	name_input:    [dynamic]u8, // profile display name draft
	about_input:   [dynamic]u8, // profile about draft
	nip05_input:   [dynamic]u8, // profile NIP-05 draft
	lud16_input:   [dynamic]u8, // profile lightning-address draft
	relay_input:   [dynamic]u8, // profile add-relay draft
	page:          Page,
	chats:         [dynamic]Chat_Row_Ui,
	archived:      [dynamic]Chat_Row_Ui,
	contacts:      [dynamic]Contact_Ui,
	profile:       Profile_Ui,
	theme:         int, // index into theme_packs
	accent:        int,
	selected:      int, // index into chats, -1 = none
	messages:      [dynamic]Msg_Ui, // selected chat's timeline
	pending:       [dynamic]Pending_Send, // optimistic sends awaiting ack
	react_pending: [dynamic]Pending_React, // optimistic reactions awaiting ack
	compose:       [dynamic]u8,
	// One shared caret/selection/undo state, targeting whichever input
	// buffer was edited last (ed_target). ed_view temporarily wraps the
	// target [dynamic]u8 as the strings.Builder core:text/edit works on.
	ed:            edit.State,
	ed_view:       strings.Builder,
	ed_target:     rawptr,
	picker_return: int, // composer caret to insert at when the picker closes
	editing:       string, // message id being edited, "" = composing new
	replying:      string, // message id being replied to
	reply_hint:    string, // preview text for the reply banner
	show_members:  bool,
	members:       [dynamic]Member_Ui,
	member_nick:   int, // member-row nickname editor, -1 = closed
	member_menu:   int, // member-row "⋯" action menu, -1 = closed
	member_menu_x: f32, // its anchor, layout coords
	member_menu_y: f32,
	invite_input:  [dynamic]u8,
	rename_input:  [dynamic]u8,
	group_desc:    string, // selected group's description snapshot
	desc_input:    [dynamic]u8, // hero description editor
	desc_editing:  bool,
	gpic_menu_open: bool, // hero "Change photo" chooser row
	picking_gpic:  bool, // route the next picked file to the group photo
	picking_ppic:  bool, // route the next picked file to the profile picture
	ov_open:       bool, // Openverse image-search modal
	ov_input:      [dynamic]u8, // its query box
	focus:         Focus,
	search_open:   bool,
	ctx_open:      bool, // message context menu
	ctx_msg:       int, // index into messages
	ctx_x:         f32, // panel anchor, layout coords
	ctx_y:         f32,
	hist_open:     bool, // edit-history modal
	hist_msg:      int, // index into messages
	raw_open:      bool, // view-raw-event modal (dev mode)
	raw_json:      string, // its pretty-printed record JSON
	enc_open:      bool, // encryption-info modal (MLS badge)
	fwd_open:      bool, // forward destination picker
	fwd_msg:       int, // index into messages
	fwd_filter:    [dynamic]u8, // its chat filter box
	gs_open:       bool, // global cross-chat search modal
	gs_input:      [dynamic]u8, // its query box
	gs_hits:       [dynamic]Gs_Hit, // its result cards
	jump_id:       string, // message id to center after next layout
	tl_has_more:   bool, // last timeline page had older messages beyond the limit
	tl_limit:      map[string]u32, // group id → raised page limit ("Load earlier")
	unread_mark_id: string, // NEW MESSAGES divider anchor, snapshotted at select
	                        // time (mark-as-read clears the row's first_unread)
	mention_active: bool, // composer @-autocomplete popover
	mention_at_b:  int, // byte offset of the active "@"
	mention_sel:   int, // selected candidate row
	mention_cands: [dynamic]int, // candidate indices into members
	mention_dismissed: int, // "@" offset Escaped away, -1 = none
	mi_open:       bool, // mentions inbox dropdown
	mi_hits:       [dynamic]Mention_Hit, // its cards, newest first
	picker_open:   bool, // emoji picker
	picker_target: string, // message id to react to; "" = insert in composer
	picker_x:      f32, // panel anchor, layout coords
	picker_y:      f32,
	picker_filter: [dynamic]u8,
	recent_emoji:  [dynamic]string,
	sidebar_filter: [dynamic]u8, // rail chat filter
	filter_hits:   [dynamic]bool, // per-chat body match for sidebar_filter
	staged:        [dynamic]Staged_File, // picked attachments, not yet sent
	my_pic_url:    string, // own kind-0 picture, "" = none
	nicknames:     map[string]string, // account hex → local nickname (settings.json)
	drafts:        map[string]string, // group id → unsent composer text (settings.json)
	blocked:       map[string]bool, // account hex → locally blocked (settings.json)
	hidden:        map[string]bool, // message id → "Delete for me" hide (hidden.json)
	dm_peer:       map[string]string, // 1:1 group id → peer hex, from load_contacts
	nick_input:    [dynamic]u8, // contact-page nickname editor
	qr_open:       bool, // contact QR modal
	qr_tex:        ^rl.Texture2D,
	qr_npub:       string,
	unread_only:   bool, // rail "Unread" pill filter
	row_menu:      int, // right-clicked rail chat index, -1 = closed
	row_menu_x:    f32, // its panel anchor, layout coords
	row_menu_y:    f32,
	folder_open:   bool, // folder modal (rowactions.odin)
	folder_gid:    string, // the chat it assigns, snapshotted at open
	folder_input:  [dynamic]u8, // its create/rename name box
	folder_rename: int, // folder index being renamed, -1 = creating
	folder_filter: string, // active folder chip, "" = every chat
	search_input:  [dynamic]u8,
	settings_section: Settings_Section,
	prefs:          Prefs, // the slint settings knobs (settings.odin)
	lang_open:      bool, // interface-language modal
	shortcuts_open: bool, // keyboard-shortcuts modal
	theme_menu_open: bool, // Appearance theme dropdown
	picking_emoji:  bool, // route the next picked file to custom emoji
	picking_backup: bool, // route the next picked file to the backup import
	backup_mode:    Backup_Mode, // "" = closed; else the password modal
	backup_pw:      [dynamic]u8, // its password box (masked)
	backup_blob:    []u8, // the picked .wnbk awaiting its password
	cache_bytes:    i64, // media-cache size, from cache_scan
	cache_scanned:  bool,
	emoji_staged:   string, // picked emoji file awaiting its shortcode
	emoji_name:     [dynamic]u8, // its shortcode box
	adding_quick:   bool, // emoji picker adds a one-tap reaction
	kp_input:       [dynamic]u8, // KP-inspector pubkey box
	inbox_input:    [dynamic]u8, // settings inbox-relay box
	health:         marmot.Relay_Health, // relay-pool counters (network.odin)
	health_ok:      bool, // a relay_health call has succeeded
	export_open:    bool, // export-ncryptsec modal
	export_pw:      [dynamic]u8, // its password box (masked)
	export_result:  string, // "" = password step, else the ncryptsec
	kp_list:        [dynamic]Kp_Row, // the account's MLS key packages
	kp_fetched:     bool, // read from marmot at least once
	kp_own_json:    string, // kp_list serialized, the inspector's raw plate
	kp_peer:        [dynamic]Kp_Row, // KP-inspector result for another pubkey
	kp_peer_owner:  string, // that pubkey in hex, "" = nothing inspected
	kp_peer_json:   string, // kp_peer serialized
	keys_nsec:      string, // revealed nsec; wiped when the page closes
	keys_nsec_show: bool, // its unmask toggle
	keys_confirm:   string, // armed danger button id ("" = none)
	audit_enabled:     bool, // marmot audit_log_settings.enabled
	telemetry_enabled: bool, // marmot relay_telemetry_settings.export_enabled
	audit_files:       [dynamic]Audit_File, // audit-*.jsonl on disk
	audit_scanned:     bool,
	debug_tab:      int, // 0 = state, 1 = raw events, 2 = key packages
	debug_json:     string, // composed snapshot shown on the Debug page
	new_chat_open: bool,
	nc_member:     [dynamic]u8, // npub/hex for a DM; empty = own group
	nc_name:       [dynamic]u8,
	client_status: string,
	// ── Shell chrome (shell.odin, palette.odin, confirm.odin,
	// linkguard.odin) ────────────────────────────────────────────────
	banner:        string, // status/error strip over the status bar; "" = none
	banner_error:  bool, // tint it danger
	banner_seen:   string, // client_status already routed to the banner
	toast:         string, // transient confirmation ("Copied")
	toast_until:   f64, // rl.GetTime() deadline; 0 = no toast
	pal_open:      bool, // command palette (Ctrl+P)
	pal_input:     [dynamic]u8,
	pal_sel:       int, // highlighted row in pal_hits
	pal_hits:      [dynamic]int, // indices into COMMANDS
	confirm:       Confirm, // pending destructive action; .kind None = closed
	link_open:     bool, // external-link guard modal
	link_url:      string, // the URL it asks about
	link_trust:    bool, // its "always open this site" checkbox
	// Message-body selection (bodysel.odin), scoped to one text block.
	sel_on:        bool,
	sel_block:     u32, // body_text id base of the block being selected
	sel_a:         int, // anchor byte offset inside that block
	sel_b:         int, // drag head
	sel_word:      bool, // double-click word mode
	sel_wa:        int, // the anchor word's bounds, for word-mode extend
	sel_wb:        int,
	sel_copy:      string, // the selected text, refreshed as the drag moves
	// Message effects (effects.odin): the composer's armed burst.
	fx_open:       bool, // effect picker popover
	fx_armed:      int, // catalog id armed for the next send; 0 = none
	login_input:   [dynamic]u8, // nsec being typed/pasted
	login_import:  bool, // sign-in card: false = menu, true = nsec form
	login_error:   string,
}

// Same fleet the slint app uses (src/relays.rs DISCOVERY_RELAYS).
DEFAULT_RELAYS := []cstring{"wss://relay.eu.whitenoise.chat", "wss://relay.us.whitenoise.chat"}

// Live-update plumbing: a worker thread blocks on the chat-list
// subscription (a chat's row also changes when it gets a message, so
// one stream signals both the rail and the open timeline) and marks
// what changed; the frame loop drains the flags and re-snapshots.
