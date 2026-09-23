package main

import "core:strings"
import "core:text/edit"
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
	DANGER_SOFT = pack.danger_soft
	DANGER_BORDER = pack.danger_border
	WARNING = pack.warning
	WARNING_SOFT = pack.warning_soft
	WARNING_BORDER = pack.warning_border
	TEXT_VLO = pack.text_vlo
	PANEL = pack.panel
	FIELD_HOVER = pack.field_hover
	CODE_PLATE = pack.code_plate
	CARD_WELL = pack.card_well
	TOP_GLINT = pack.top_glint
	AVATAR_RING = pack.avatar_ring
	ACCENT_HI = pack.accent_hi[slot]
	ACCENT_GLOW = pack.accent_glow[slot]

	OVERLAY = pack.overlay
	OVERLAY_STRONG = pack.overlay_strong
	VIGNETTE = pack.vignette
	SHADOW_CARD = pack.shadow_card
	SHADOW_POPOVER = pack.shadow_popover
	BEVEL_HI = pack.bevel_hi
	BEVEL_LO = pack.bevel_lo

	MEDIA_BACKDROP = pack.media_backdrop
	MEDIA_CHIP_BG = pack.media_chip_bg
	MEDIA_CHIP_FG = pack.media_chip_fg
	MEDIA_CHIP_OUTLINE = pack.media_chip_outline
	MEDIA_CONTROL_BG = pack.media_control_bg

	// Structural metrics + capability flags (retro squares corners and
	// doubles borders; synthwave mounts the grid backdrop).
	R_SCALE = pack.r_scale
	BORDER_W = u16(max(pack.border_w, 1))
	GLOW_R = pack.glow_r
	SHADOW_Y = pack.shadow_y
	BUBBLE_R = pack.bubble_r
	HOVER_DUR = pack.hover_dur
	TRANSITION_DUR = pack.transition_dur
	SYNTH_GRID = pack.synth_grid
	PAPER_DECOR = pack.paper_doodles
	SCANLINES = pack.scanlines
	HARD_SHADOW = pack.hard_shadow
	FOCUS_GLOW = pack.focus_glow
	BEVEL = pack.bevel
	OUTLINE_SURFACES = pack.outline_surfaces
	SELECTED_INVERTS_TEXT = pack.selected_inverts_text
	BRACKET_LABELS = pack.bracket_labels
	MOTION_FAST = pack.motion_fast
	THEME_FONT = pack.font
	BACKDROP = pack.backdrop
	BG_2 = pack.bg_2

	// The legacy per-scene flags still name a backdrop, so the packs
	// written before the token keep their scene.
	if len(BACKDROP) == 0 {
		switch {
		case pack.synth_grid:
			BACKDROP = "synth"
		case pack.paper_doodles:
			BACKDROP = "dust"
		case pack.scanlines:
			BACKDROP = "scan"
		}
	}
}

// A proportional sans for body text with bold titles; mono stays for
// code plates and eyebrow-style captions. Each stack is tried in order
// and misses are skipped, so a packaged build finds its own bundled
// copy first and a source build falls through to the system font. The
// system paths cover the three common layouts: Arch (flat, by family),
// Debian/Ubuntu (truetype/<family>), and Fedora (<family>-<style>).
FONT_CANDIDATES := []cstring {
	"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
}
TITLE_CANDIDATES := []cstring {
	"/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf",
	"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
}
MONO_CANDIDATES := []cstring {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

Chat_Row_Ui :: struct {
	group_id:     string, // group_id_hex, the chat's stable key
	title:        string,
	preview:      string,
	at:           string, // last-activity HH:MM
	unread:       u64,
	pending:      bool, // invite awaiting accept/decline
	stable:       bool, // MLS lifecycle stable (session established)
	tick:         marmot.Delivery_State,
	first_unread: string, // first unread message id, "" = none
	avatar_url:   string, // chat picture URL, "" = none
	avatar_key:   string, // peer public key for a DM, otherwise group id
	image_hash:   string, // encrypted-Blossom avatar hash, "" = none
	muted:        bool, // marmot's per-chat mute, suppresses notifications
	last_id:      string, // latest message id, "" = none (notification dedupe)
	last_kind:    u64, // latest message's event kind
	last_mine:    bool, // latest message is an own send
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
	who:   string, // reactor names, comma-joined, for the hover tooltip
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
	at:     string, // HH:MM
	text:   string,
	blocks: [dynamic]Md_Block_Ui,
}

// Which input box receives typed characters.
Focus :: enum {
	Issue_Search,
	Issue_Subject,
	Issue_Body,
	Issue_Labels,
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
	Fetch, // settings event-fetch-relay box
	Client, // settings event web-client box
	ExportPw, // export-ncryptsec password box
	BackupPw, // backup create/import password box
	EmojiName, // custom-emoji shortcode box
	Folder, // folder-modal name box
	Pal, // command-palette query box
	PollQ, // poll-modal question box
	PollOpt, // poll-modal option box, index in ui.poll_focus
	ThemeSeed, // theme-editor seed box, index in ui.theme_edit_idx
}

// The create-poll modal grows one option row at a time up to this cap
// (Discord's), starting from two.
POLL_OPTS_CAP :: 10
POLL_OPTS_MIN :: 2

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
	Image, // text = image url; only event cards (nevent.odin) mint these
	Math,
}

Md_Block_Ui :: struct {
	kind:               Md_Kind,
	text:               string,
	blank_lines_before: u8,
	fonts:              string, // owned font id and style flags per UTF-8 byte
	level:              int, // heading level
	marker_len:         int, // list marker bytes, including the trailing space
	indent:             u16,
	quote_depth:        u16,
	quote_starts:       u16, // quote containers beginning at this row
	alignments:         []marmot.Markdown_Alignment,
	code_kinds:         string, // owned token kind per UTF-8 byte
	cells:              [][]string, // table rows, row 0 = header
	cell_fonts:         [][]string,
}

Msg_Ui :: struct {
	excerpt:             Excerpt,
	sticker:             Sticker_Ref,
	row_height, row_top: f32,
	row_measure:         [4]f32, // width, pixel scale, corner scale, action height
	visible_since:       time.Tick, // live observation until first presented row
	id:                  string, // message_id_hex
	sender:              string, // display label: kind-0 name, else short hex / "you"
	sender_id:           string, // account hex
	pic_url:             string, // sender's kind-0 picture, "" = none
	body:                string, // plaintext fallback when blocks is empty
	secrets:             [dynamic]Secret_Ui, // decoded layers, each revealed separately
	blocks:              [dynamic]Md_Block_Ui,
	reactions:           [dynamic]Reaction_Ui,
	reply_from:          string, // sender of the replied-to message, "" = not a reply
	reply_text:          string,
	reply_image:         string, // first parent image's session cache key
	reply_id:            string, // parent message id, the preview's jump target
	images:              [dynamic]Att_Item(^rl.Texture2D), // downloaded attachments, heap ptrs for clay
	models:              [dynamic]Att_Item(^Stl_View), // STL attachments, owned by the stl_views cache
	videos:              [dynamic]Att_Item(^Video_View), // video attachments, owned by the video_views cache
	audios:              [dynamic]Att_Item(^Video_View), // audio attachments, same cache (mpv plays, no frames)
	gcodes:              [dynamic]Att_Item(^Gcode_View), // g-code attachments, owned by the gcode_views cache
	pdfs:                [dynamic]Att_Item(^Pdf_View), // pdf attachments, owned by the pdf_views cache
	arcs:                [dynamic]Att_Item(^Arc_View), // archive attachments, owned by the arc_views cache
	xdcs:                [dynamic]Att_Item(^Xdc_View), // webxdc apps, owned by the xdc_views cache
	txts:                [dynamic]Att_Item(^Txt_View), // text/markdown attachments, owned by the txt_views cache
	codes:               [dynamic]Att_Item(^Code_View), // source attachments, owned by the code_views cache
	fonts:               [dynamic]Att_Item(^Ttf_View), // font attachments, owned by the ttf_views cache
	att_names:           [dynamic]string, // every media reference by index, for the ctx-menu save rows
	att_keys:            [dynamic]string, // cache key (plaintext sha256) per media index
	att_rejected:        map[int]string, // source index to static, translatable rejection text
	files:               [dynamic]int, // att_names indices with no inline renderer (chip rows)
	img_failed:          [dynamic]Att_Item(string), // failed image cells: cache key + media index
	at:                  string, // HH:MM
	at_full:             string, // full date + time, the stamp's hover tooltip
	day:                 string, // YYYY-MM-DD or "Today", for day markers
	mine:                bool,
	system:              bool, // kind-1210 group-system line; body holds the sentence
	sys_text:            string, // system sentence with profile references for mention chips
	sys_added_hex:       string, // member_added row: subject hex, "" = not an add
	theme_name:          string, // a shared theme's name, "" = not a theme offer
	theme_toml:          string, // its pack source, applied only on the tap
	theme_swatch:        [THEME_SWATCHES]clay.Color, // parsed once at load, drawn every frame
	deleted:             bool, // tombstone: placeholder row, no body/actions
	edited:              bool, // kind-1009 edits applied; body holds the latest
	media_failed:        bool, // an image attachment failed to download
	media_pending:       [dynamic]Media_Pending,
	effect:              int, // ["effect", key] burst id from the event tags, 0 = none
	history:             [dynamic]Edit_Version,
	poll_opts:           [dynamic]Poll_Opt_Ui, // kind-1068 options + tally; empty = not a poll
	poll_multi:          bool, // polltype multiplechoice
	poll_total:          int, // distinct voters counted
	poll_ends:           u64, // endsAt unix seconds, 0 = open-ended
	thread_of:           string, // kind-1111: root message id; "" = main timeline
	thread_replies:      int, // thread messages under this root
}

// NIP-88 polls and Discord-style threads ride the group as custom
// events; loaders folds votes/thread rows, timeline renders them.
KIND_POLL :: 1068 // NIP-88 poll: content = question, option tags
KIND_POLL_VOTE :: 1018 // NIP-88 response: ["e", poll] + ["response", id]
KIND_THREAD :: 1111 // thread message: ["e", root], text in content

Poll_Opt_Ui :: struct {
	id:     string, // option id from the ["option", id, label] tag
	label:  string,
	blocks: [dynamic]Md_Block_Ui, // label parsed as markdown; empty = render label plain
	count:  int, // votes after per-sender latest-wins dedup
	mine:   bool, // own latest vote includes this option
}

Page :: enum {
	Chats,
	Contacts,
	Archived,
	Settings,
	Profile,
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
	id:      string,
	title:   string,
	members: int,
}

Contact_Ui :: struct {
	id_hex:  string,
	name:    string, // display name or truncated id
	pic_url: string, // kind-0 picture, "" = none
	npub:    string,
	groups:  [dynamic]Common_Group, // chats shared with this contact
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
	gif_tab, gif_saved, gif_loaded:                        bool,
	gif_hits, gif_library:                                 [dynamic]Gif_Item,
	gif_job:                                               ^Gif_Job,
	gif_view:                                              ^Video_View,
	gif_selected:                                          Gif_Item,
	gif_error:                                             string,
	gif_focus:                                             int,
	gif_page:                                              int,
	gif_more:                                              bool,
	gif_filter:                                            string,
	gif_due:                                               f64,
	gif_hover:                                             int,
	gif_hover_at:                                          f64,
	stickers:                                              [dynamic]Sticker_Item,
	sticker_packs:                                         [dynamic]Sticker_Pack,
	sticker_recent:                                        [dynamic]string,
	sticker_preview:                                       [dynamic]Sticker_Item,
	sticker_pack:                                          Sticker_Pack,
	sticker_selected:                                      Sticker_Ref,
	sticker_input:                                         [dynamic]u8,
	sticker_name:                                          [dynamic]u8,
	sticker_filter:                                        string,
	sticker_error:                                         string,
	sticker_open:                                          bool,
	sticker_tab:                                           bool,
	sticker_loaded:                                        bool,
	sticker_loading:                                       bool,
	sticker_installing:                                    bool,
	picking_sticker:                                       bool,
	sticker_focus:                                         int,
	sticker_page:                                          Sticker_Page,
	timeline_metric:                                       [4]f32,
	messages_group, messages_account:                      string,
	account_ref:                                           string, // active account's full hex; "" when logged out
	account_ids:                                           [dynamic]string, // full hex per switcher row
	accounts:                                              [dynamic]string, // kind-0 name (else truncated hex) per row
	account_npubs:                                         [dynamic]string, // npub per row, for the switcher sublabels
	account_pics:                                          [dynamic]string, // kind-0 picture URL per row, "" = none
	accounts_open:                                         bool, // the Accounts switcher modal
	peer_open:                                             bool, // peer-profile popup (any avatar click)
	peer_hex:                                              string,
	peer_name:                                             string,
	peer_pic:                                              string, // kind-0 picture URL, "" = none
	peer_npub:                                             string, // derived from peer_hex, "" if malformed
	profile_contact:                                       Contact_Ui, // viewed profile outside the saved contacts list
	add_account_open:                                      bool, // show the login pane to add another account
	scroll_pending:                                        bool, // jump timeline scroll to newest after reload
	selected_contact:                                      int, // index into contacts, -1 = none
	name_input:                                            [dynamic]u8, // profile display name draft
	about_input:                                           [dynamic]u8, // profile about draft
	nip05_input:                                           [dynamic]u8, // profile NIP-05 draft
	lud16_input:                                           [dynamic]u8, // profile lightning-address draft
	relay_input:                                           [dynamic]u8, // profile add-relay draft
	page:                                                  Page,
	chats:                                                 [dynamic]Chat_Row_Ui,
	archived:                                              [dynamic]Chat_Row_Ui,
	contacts:                                              [dynamic]Contact_Ui,
	profile:                                               Profile_Ui,
	theme:                                                 int, // index into theme_packs
	accent:                                                int,
	selected:                                              int, // index into chats, -1 = none
	rail_rows:                                             [dynamic]int, // chat indices as rendered in the rail, for Ctrl+Tab cycling
	messages:                                              [dynamic]Msg_Ui, // selected chat's timeline
	pending:                                               [dynamic]Pending_Send, // optimistic sends awaiting ack
	react_pending:                                         [dynamic]Pending_React, // optimistic reactions awaiting ack
	compose:                                               [dynamic]u8,
	// One shared caret/selection/undo state, targeting whichever input
	// buffer was edited last (ed_target). ed_view temporarily wraps the
	// target [dynamic]u8 as the strings.Builder core:text/edit works on.
	ed:                                                    edit.State,
	ed_view:                                               strings.Builder,
	ed_target:                                             rawptr,
	picker_return:                                         int, // composer caret to insert at when the picker closes
	editing:                                               string, // message id being edited, "" = composing new
	edit_ticket:                                           int, // outstanding edit; keep the composer until its ack
	replying:                                              string, // message id being replied to
	reply_hint:                                            string, // preview text for the reply banner
	show_members:                                          bool,
	group_files_open:                                      bool,
	group_files_type:                                      Group_File_Type,
	group_files_sender:                                    string, // borrowed from the completed file job
	group_files_menu:                                      Group_File_Menu,
	group_files_option:                                    int,
	members:                                               [dynamic]Member_Ui,
	members_scroll_y:                                      f32, // scroll offset used by the previous layout
	member_nick:                                           int, // member-row nickname editor, -1 = closed
	member_menu:                                           int, // member-row "⋯" action menu, -1 = closed
	member_menu_x:                                         f32, // its anchor, layout coords
	member_menu_y:                                         f32,
	invite_input:                                          [dynamic]u8,
	rename_input:                                          [dynamic]u8,
	group_desc:                                            string, // selected group's description snapshot
	issue_setting:                                         Issue_Setting,
	issue_admin, issues_open, issue_new:                   bool,
	issues:                                                [dynamic]Issue_Row,
	issue_index:                                           map[string]int,
	issue_selected:                                        string,
	compose_issue:                                         string, // issue owning the shared composer; empty for chat
	staged_drafts:                                         map[string][dynamic]Staged_File,
	issue_blocks:                                          [dynamic]Md_Block_Ui,
	issue_subject, issue_body, issue_labels, issue_search: [dynamic]u8,
	issue_filter_open:                                     bool,
	issue_filter:                                          int, // 0 = all, 1..3 = status
	issue_ticket:                                          int,
	issue_action:                                          Issue_Action,
	group_retention:                                       u64, // disappearing-message timer in seconds, 0 = off
	desc_input:                                            [dynamic]u8, // hero description editor
	desc_editing:                                          bool,
	gpic_menu_open:                                        bool, // hero "Change photo" chooser row
	picking_gpic:                                          bool, // route the next picked file to the group photo
	picking_ppic:                                          bool, // route the next picked file to the profile picture
	ov_open:                                               bool, // Openverse image-search modal
	ov_input:                                              [dynamic]u8, // its query box
	focus:                                                 Focus,
	search_open:                                           bool,
	ctx_open:                                              bool, // message context menu
	ctx_msg:                                               int, // index into messages
	ctx_x:                                                 f32, // panel anchor, layout coords
	ctx_y:                                                 f32,
	hist_versions:                                         [dynamic]Edit_Version,
	hist_ticket:                                           int,
	hist_original:                                         bool,
	hist_open:                                             bool, // edit-history modal
	hist_msg:                                              int, // index into messages
	raw_open:                                              bool, // view-raw-event modal (dev mode)
	raw_json:                                              string, // its pretty-printed record JSON
	enc_open:                                              bool, // encryption-info modal (MLS badge)
	enc_epoch:                                             string, // its MLS epoch, "" when the lookup failed
	fwd_open:                                              bool, // destination-chat picker
	fwd_kind:                                              Fwd_Kind, // what the pick sends
	fwd_msg:                                               int, // index into messages (.Message only)
	fwd_filter:                                            [dynamic]u8, // its chat filter box
	poll_open:                                             bool, // create-poll modal
	poll_question:                                         [dynamic]u8,
	poll_inputs:                                           [dynamic][dynamic]u8, // option drafts, blanks skipped
	poll_focus:                                            int, // which option input has the caret (focus == .PollOpt)
	poll_multi_in:                                         bool, // modal's multiple-choice toggle
	theme_edit:                                            bool, // theme-editor modal
	theme_fields:                                          [dynamic][dynamic]u8, // one box per THEME_FIELDS entry; empty = derive
	theme_flags:                                           [dynamic]bool, // one per THEME_FLAGS entry
	theme_backdrop:                                        string, // picked scene name, "" = none
	theme_edit_idx:                                        int, // which box has the caret (focus == .ThemeSeed)
	theme_slot:                                            int, // the live working pack in theme_packs
	theme_prev:                                            int, // theme to restore if the edit is cancelled
	theme_last:                                            string, // last previewed toml, so a still frame reparses nothing
	thread_stack:                                          [dynamic]string, // open thread route, last = current root
	gs_open:                                               bool, // global cross-chat search modal
	gs_input:                                              [dynamic]u8, // its query box
	gs_hits:                                               [dynamic]Gs_Hit, // its result cards
	jump_id:                                               string, // message id to center after next layout
	tl_has_more:                                           bool, // last timeline page had older messages beyond the limit
	tl_has_after:                                          bool,
	timeline_loading, timeline_paging:                     bool,
	unread_mark_id:                                        string, // NEW MESSAGES divider anchor, snapshotted at select
	// time (mark-as-read clears the row's first_unread)
	mention_active:                                        bool, // composer @-autocomplete popover
	mention_at_b:                                          int, // byte offset of the active "@"
	mention_sel:                                           int, // selected candidate row
	mention_cands:                                         [dynamic]int, // candidate indices into members
	mention_dismissed:                                     int, // "@" offset Escaped away, -1 = none
	mi_open:                                               bool, // mentions inbox dropdown
	mi_account:                                            string, // account owning the displayed mentions
	mi_hits:                                               [dynamic]Mention_Hit, // its cards, newest first
	picker_open:                                           bool, // emoji picker
	picker_target:                                         string, // message id to react to; "" = insert in composer
	picker_x:                                              f32, // panel anchor, layout coords
	picker_y:                                              f32,
	picker_filter:                                         [dynamic]u8,
	recent_emoji:                                          [dynamic]string,
	sidebar_filter:                                        [dynamic]u8, // rail chat filter
	filter_hits:                                           [dynamic]bool, // per-chat body match for sidebar_filter
	staged:                                                [dynamic]Staged_File, // picked attachments, not yet sent
	my_pic_url:                                            string, // own kind-0 picture, "" = none
	nicknames:                                             map[string]string, // account hex → local nickname (settings.json)
	drafts:                                                map[string]string, // group id → unsent composer text (settings.json)
	blocked:                                               map[string]bool, // account hex → locally blocked (settings.json)
	hidden:                                                map[string]bool, // message id → "Delete for me" hide (hidden.json)
	dm_peer:                                               map[string]string, // 1:1 group id → peer hex, from load_contacts
	nick_input:                                            [dynamic]u8, // contact-page nickname editor
	qr_open:                                               bool, // contact QR modal
	qr_tex:                                                ^rl.Texture2D,
	qr_npub:                                               string,
	unread_only:                                           bool, // rail "Unread" pill filter
	row_menu:                                              int, // right-clicked rail chat index, -1 = closed
	row_menu_x:                                            f32, // its panel anchor, layout coords
	row_menu_y:                                            f32,
	folder_open:                                           bool, // folder modal (rowactions.odin)
	folder_gid:                                            string, // the chat it assigns, snapshotted at open
	folder_input:                                          [dynamic]u8, // its create/rename name box
	folder_rename:                                         int, // folder index being renamed, -1 = creating
	folder_filter:                                         string, // active folder chip, "" = every chat
	search_input:                                          [dynamic]u8,
	settings_section:                                      Settings_Section,
	prefs:                                                 Prefs, // the slint settings knobs (settings.odin)
	tts:                                                   Tts_State,
	stt:                                                   Stt_State,
	lang_open:                                             bool, // interface-language modal
	shortcuts_open:                                        bool, // keyboard-shortcuts modal
	theme_menu_open:                                       bool, // Appearance theme dropdown
	picking_emoji:                                         bool, // route the next picked file to custom emoji
	picking_backup:                                        bool, // route the next picked file to the backup import
	backup_mode:                                           Backup_Mode, // "" = closed; else the password modal
	backup_pw:                                             [dynamic]u8, // its password box (masked)
	backup_blob:                                           []u8, // the picked .wnbk awaiting its password
	vault_pw_open:                                         bool, // change-vault-password modal
	vault_pw:                                              [Vault_Pw_Field][dynamic]u8, // its three boxes (masked)
	vault_pw_focus:                                        Vault_Pw_Field, // which of them takes the typing
	vault_pw_err:                                          string, // in-modal failure line, "" = none
	cache_bytes:                                           i64, // media-cache size, from cache_scan
	cache_scanned:                                         bool,
	emoji_staged:                                          string, // picked emoji file awaiting its shortcode
	emoji_name:                                            [dynamic]u8, // its shortcode box
	adding_quick:                                          bool, // emoji picker adds a one-tap reaction
	kp_input:                                              [dynamic]u8, // KP-inspector pubkey box
	inbox_input:                                           [dynamic]u8, // settings inbox-relay box
	fetch_input:                                           [dynamic]u8, // settings event-fetch-relay box
	client_input:                                          [dynamic]u8, // settings event web-client box, mirrors prefs.event_client
	health:                                                marmot.Relay_Health, // relay-pool counters (network.odin)
	health_ok:                                             bool, // a relay_health call has succeeded
	export_open:                                           bool, // export-ncryptsec modal
	export_pw:                                             [dynamic]u8, // its password box (masked)
	export_result:                                         string, // "" = password step, else the ncryptsec
	kp_list:                                               [dynamic]Kp_Row, // the account's MLS key packages
	kp_fetched:                                            bool, // read from marmot at least once
	kp_own_json:                                           string, // kp_list serialized, the inspector's raw plate
	kp_peer:                                               [dynamic]Kp_Row, // KP-inspector result for another pubkey
	kp_peer_owner:                                         string, // that pubkey in hex, "" = nothing inspected
	kp_peer_json:                                          string, // kp_peer serialized
	keys_nsec:                                             string, // revealed nsec; wiped when the page closes
	keys_nsec_show:                                        bool, // its unmask toggle
	keys_confirm:                                          string, // armed danger button id ("" = none)
	audit_enabled:                                         bool, // marmot audit_log_settings.enabled
	telemetry_enabled:                                     bool, // marmot relay_telemetry_settings.export_enabled
	audit_files:                                           [dynamic]Audit_File, // audit-*.jsonl on disk
	audit_scanned:                                         bool,
	debug_tab:                                             int, // 0 = state, 1 = raw events, 2 = key packages
	debug_text:                                            string, // timing names spaced for wrapping; Copy keeps the original JSON
	debug_json:                                            string, // composed snapshot shown on the Debug page
	new_chat_open:                                         bool,
	// A one-card window shows the settings section list or one section,
	// never both. Set by the section change detector in build_layout,
	// cleared by the back chip; ignored at desktop widths.
	sett_open:                                             bool,
	nc_member:                                             [dynamic]u8, // npub/hex/NIP-05 for a DM; empty = own group
	nip05_ticket:                                          int,
	nc_name:                                               [dynamic]u8,
	client_status:                                         string,
	// ── Shell chrome (shell.odin, palette.odin, confirm.odin,
	// linkguard.odin) ────────────────────────────────────────────────
	banner:                                                string, // status/error strip over the status bar; "" = none
	banner_error:                                          bool, // tint it danger
	banner_seen:                                           string, // client_status already routed to the banner
	toast:                                                 string, // transient confirmation ("Copied")
	toast_until:                                           f64, // rl.GetTime() deadline; 0 = no toast
	pal_open:                                              bool, // command palette (Ctrl+P)
	pal_input:                                             [dynamic]u8,
	pal_sel:                                               int, // highlighted row in pal_hits
	pal_hits:                                              [dynamic]int, // indices into COMMANDS
	confirm:                                               Confirm, // pending destructive action; .kind None = closed
	link_open:                                             bool, // external-link guard modal
	link_url:                                              string, // the URL it asks about
	link_trust:                                            bool, // its "always open this site" checkbox
	// Message-body selection (bodysel.odin), scoped to one text block.
	sel_on:                                                bool,
	sel_block:                                             u32, // body_text id base of the block being selected
	sel_a:                                                 int, // anchor byte offset inside that block
	sel_b:                                                 int, // drag head
	sel_unit:                                              Selection_Unit,
	sel_wa:                                                int, // anchor word/sentence bounds for drag selection
	sel_wb:                                                int,
	sel_copy:                                              string, // the selected text, refreshed as the drag moves
	// Message effects (effects.odin): the composer's armed burst.
	fx_open:                                               bool, // effect picker popover
	fx_armed:                                              int, // catalog id armed for the next send; 0 = none
	login_input:                                           [dynamic]u8, // nsec being typed/pasted
	login_import:                                          bool, // sign-in card: false = menu, true = nsec form
	login_error:                                           string,
}

// Same fleet the slint app uses (src/relays.rs DISCOVERY_RELAYS).
DEFAULT_RELAYS := []cstring{"wss://relay.eu.whitenoise.chat", "wss://relay.us.whitenoise.chat"}

// Live-update plumbing: a worker thread blocks on the chat-list
// subscription (a chat's row also changes when it gets a message, so
// one stream signals both the rail and the open timeline) and marks
// what changed; the frame loop drains the flags and re-snapshots.
