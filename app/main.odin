// Entry point: boots the marmot-c runtime, opens the window, and runs
// the clay layout/render loop.
//
// renderer.odin started as clay's official Odin raylib renderer and now
// draws through sdlrl, the SDL3 shim that kept raylib's call shapes.
//
// Usage: app [home-dir]   (default: $XDG_DATA_HOME/whitenoise)
// Env: WN_SHOT=1 captures wn-odin-shot.png after a few frames and exits.
//      WN_VAULT_PW unlocks (or creates) the vault without the gate.
//      WN_TEST_PREVIEW=<path> opens the preview modal on a local file.
//      WN_TEST_WEB=<url> opens the webxdc modal on a URL.
//      WN_TEST_XDC=<file.xdc> unpacks and runs a webxdc app.
//
// Secrets: everything sealed goes through $home/vault.db (vault.odin),
// unlocked by vault_gate before the runtime boots. Marmot's own account
// signing keys ride the same file through the marmot-c secret-store
// vtable (vault_gate.odin), so nothing lands in an OS keychain.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:time"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"


@(private)
layout_overflow: bool

@(private)
init_layout :: proc(memory: ^[]u8, count: i32, dimensions: clay.Dimensions) {
	clay.SetCurrentContext(nil)
	delete(memory^)
	clay.SetMaxElementCount(count)
	memory^ = make([]u8, int(clay.MinMemorySize()))
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory^)), raw_data(memory^)), dimensions, {handler = error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)
	layout_overflow = false
}

FONT_BODY :: 0
FONT_TITLE :: 1
FONT_MONO :: 2
FONT_ICON :: 3

// Nerd Font (Font Awesome range) codepoints for the nav and chrome.
ICON_CHATS :: "\uf075"
ICON_PEOPLE :: "\uf0c0"
ICON_ARCHIVE :: "\uf187"
ICON_SETTINGS :: "\uf013"
ICON_PROFILE :: "\uf007"
ICON_SEARCH :: "\uf002"
ICON_CHECK :: "\uf00c"
ICON_CLIP :: "\uf0c6"
ICON_LOCK :: "\uf023"
ICON_BELL :: "\uf0f3"
ICON_SMILE :: "\uf118"
ICON_MIC :: "\uf130"
ICON_REPLY :: "\uf112"
ICON_FORWARD :: "\uf064"
ICON_COPY :: "\uf0c5"
ICON_TRASH :: "\uf014"
ICON_PENCIL :: "\uf040"
ICON_BAN :: "\uf05e"
ICON_CODE :: "\uf121"
ICON_CLOSE :: "\uf00d"
ICON_DOWN :: "\uf063"
ICON_INFO :: "\uf05a"
ICON_GLOBE :: "\uf0ac"
ICON_KEY :: "\uf084"
ICON_BRUSH :: "\uf1fc"
ICON_BUG :: "\uf188"
ICON_DOWNLOAD :: "\uf019"
ICON_PIN :: "\uf08d"
ICON_BELL_OFF :: "\uf1f6"
ICON_ENVELOPE :: "\uf0e0"
ICON_ENVELOPE_OPEN :: "\uf2b6"
ICON_FOLDER :: "\uf07b"
ICON_STAR :: "\uf005"
ICON_POLL :: "\uf080" // bar chart, the create-poll chip
ICON_COMMENTS :: "\uf086" // stacked bubbles, thread affordances

// Nerd Font private-use codepoints (ICON_CODEPOINTS below), so there is
// no system fallback: without one of these the icons render as blanks,
// which is why a packaged build bundles the font.
ICON_CANDIDATES := []cstring {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/truetype/nerd-fonts/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/jetbrains-mono-nerd/JetBrainsMonoNerdFont-Regular.ttf",
}
ICON_CODEPOINTS := []rune {
	0xF075,
	0xF0C0,
	0xF187,
	0xF013,
	0xF007,
	0xF002,
	0xF00C,
	0xF0C6,
	0xF023,
	0xF0F3,
	0xF118,
	0xF130,
	0xF112,
	0xF064,
	0xF0C5,
	0xF014,
	0xF040,
	0xF05E,
	0xF121,
	0xF00D,
	0xF005,
}

// Quick-reaction strip (the slint QuickReact.list): vendored Twemoji
// 72px tiles, drawn as textures since no installed font rasterizes
// color emoji.
QUICK_REACT := [6]struct {
	emoji: string,
	png:   []u8,
} {
	{"👍", #load("assets/1f44d.png")},
	{"❤️", #load("assets/2764.png")},
	{"😂", #load("assets/1f602.png")},
	{"😮", #load("assets/1f62e.png")},
	{"😢", #load("assets/1f622.png")},
	{"🙏", #load("assets/1f64f.png")},
}
quick_react_tex: [6]rl.Texture2D

// Tile for a one-tap reaction: staged twemoji first, bundled default
// tiles as fallback, nil = draw the text glyph.
build_layout :: proc(ui: ^Ui_State, frame_time: f32) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	page_advance(ui)

	logged_in := len(ui.accounts) > 0

	if clay.UI(clay.ID("Root"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		// clay emits an element's Custom command before its own fill, so
		// a washed pack leaves the fill out and lets the gradient be the
		// page: it covers the window opaquely either way.
		backgroundColor = BG_2.a > 0 ? clay.Color{} : BG,
		custom = {customData = wash_payload()},
	},
	) {
		// Logged out: the sign-in card alone on the canvas, like the slint
		// login gate (no sidebar, no status bar).
		if !logged_in {
			if clay.UI(clay.ID("LoginCanvas"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					childAlignment = {x = .Center, y = .Center},
				},
			},
			) {
				login_pane(ui)
			}
		} else {
			if clay.UI(clay.ID("CardsRow"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .LeftToRight,
					padding = {left = 10, right = 10, top = 10},
					childGap = 4,
				},
			},
			) {
				// Left card: the slint bento card holding nav + chat list.
				// A window too narrow for both cards hides one of them by
				// giving it no width and clipping what is inside, rather
				// than skipping the subtree: clay's element close is
				// hides the one it is not showing. The subtree is skipped
				// outright rather than sized to zero: clay grows a fixed
				// box back up to its children's minimum, so a zero-width
				// card still draws an icon column.
				hide_rail := single_pane() && phone_detail(ui)
				if !hide_rail {
					if clay.UI(clay.ID("Rail"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(rail_width(ui)),
								height = clay.SizingGrow(),
							},
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(12),
							childGap = 6,
						},
						// Only while it is moving: a list that no longer fits slides
						// out of view instead of spilling over the card.
						clip = {horizontal = rail_open(ui) > 0 && rail_open(ui) < 1},
						backgroundColor = CARD,
						cornerRadius = rr(16),
						border = {color = CARD_BORDER, width = bw()},
					},
					) {
						// Top strip: account avatar + horizontal nav, like the
						// slint icon rail (text stand-ins until an icon font).
						if logged_in {
							// Collapsed, the strip stacks so the rail is one icon
							// column; expanded it stays the horizontal slint nav.
							collapsed := rail_narrow(ui)
							if clay.UI(clay.ID("RailTop"))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									layoutDirection = collapsed ? .TopToBottom : .LeftToRight,
									childGap = 8,
									childAlignment = {x = collapsed ? .Center : .Left, y = .Center},
								},
							},
							) {
								avatar(
									"RailAvatar",
									0,
									ui.account_ref,
									short_hex(ui.account_ref),
									30,
									url_pic(ui.my_pic_url),
								)
								for page in Page {
									nav_button(page, ui.page == page)
								}
								nav_indicator(ui)
								if !collapsed {
									if clay.UI(clay.ID("RailTopGap"))(
									{layout = {sizing = {width = clay.SizingGrow()}}},
									) {}
								}
								// Fit-sized (padding), never fixed: this clay pushes a
								// fixed sibling declared after the grow spacer past
								// the card edge (PORT.md Quirks).
								// Gone on a one-card window: there is no second card
								// to give the space to, and the strip needs it for
								// finger-sized nav buttons.
								if !single_pane() {
									if clay.UI(clay.ID("RailCollapse"))(
									{
										layout = {
											padding = {left = 7, right = 7, top = 4, bottom = 4},
											childAlignment = {x = .Center, y = .Center},
										},
										backgroundColor = hovered() ? HOVER : {},
										cornerRadius = rr(7),
									},
									) {
										if hovered() {
											tooltip(
												collapsed ? "Expand the chat list" : "Collapse the chat list",
											)
										}
										clay.Text(
											collapsed ? "›" : "‹",
											{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT_DIM},
										)
									}
								}
							}
							if !collapsed {
								if clay.UI(clay.ID("RailDivider"))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow(),
											height = clay.SizingFixed(1),
										},
									},
									backgroundColor = DIVIDER,
								},
								) {}

								// Settings and Profile swap the chat rail for their own
								// sidebar: the slint settings sections, and the accounts
								// on this device.
								if ui.page == .Profile {
									profile_rail(ui)
								} else if ui.page == .Settings {
									if clay.UI(clay.ID("SettingsNavHead"))(
									{layout = {padding = {left = 4, top = 6, bottom = 4}}},
									) {
										clay.Text(
											tr("SETTINGS"),
											{
												fontId = FONT_MONO,
												fontSize = 12,
												textColor = TEXT_DIM,
												letterSpacing = 2,
											},
										)
									}
									for s in Settings_Section {
										// Debug pages only exist in developer mode.
										if (s == .Debug || s == .KP) && !ui.prefs.dev_mode {
											continue
										}
										active := ui.settings_section == s
										if clay.UI(clay.ID("SettingsNav", u32(s)))(
										{
											layout = {
												sizing = {width = clay.SizingGrow()},
												padding = {left = 12, right = 12, top = 9, bottom = 9},
												childGap = 10,
												childAlignment = {y = .Center},
											},
											backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
											cornerRadius = rr(9),
										},
										) {
											clay.Text(
												SETTINGS_SECTIONS[s].icon,
												{
													fontId = FONT_ICON,
													fontSize = 13,
													textColor = active ? ACCENT : TEXT_DIM,
												},
											)
											clay.Text(
												tr(SETTINGS_SECTIONS[s].label),
												{
													fontId = FONT_TITLE,
													fontSize = 13,
													textColor = active ? TEXT : TEXT_DIM,
												},
											)
										}
									}
								} else {
									// Section header: CHATS/CONTACTS count + new-chat button.
									if clay.UI(clay.ID("RailHead"))(
									{
										layout = {
											sizing = {width = clay.SizingGrow()},
											childGap = 8,
											childAlignment = {y = .Center},
											padding = {top = 4, bottom = 2},
										},
									},
									) {
										head := fmt.tprintf("CHATS   %d", len(ui.chats))
										if ui.page == .Contacts {
											head = fmt.tprintf("CONTACTS   %d", len(ui.contacts))
										} else if ui.page == .Archived {
											head = fmt.tprintf("ARCHIVED   %d", len(ui.archived))
										}
										clay.Text(
											head,
											{
												fontId = FONT_MONO,
												fontSize = 12,
												textColor = TEXT_DIM,
												letterSpacing = 2,
											},
										)
										// Unread filter pill + accent plus, pinned right like the
										// slint rail head. Fit-sized (padding), never fixed: this
										// clay drops fixed siblings after the grow spacer.
										if clay.UI(clay.ID("RailHeadGap"))(
										{layout = {sizing = {width = clay.SizingGrow()}}},
										) {}
										if ui.page == .Chats {
											// All/Unread filter tabs, the slint chat-list tabs.
											for label, t in ([2]string{"All", "Unread"}) {
												active := ui.unread_only == (t == 1)
												if clay.UI(clay.ID(t == 0 ? "AllPill" : "UnreadPill"))(
												{
													layout = {
														padding = {
															left = 14,
															right = 14,
															top = 5,
															bottom = 5,
														},
													},
													backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
													cornerRadius = rr(8),
													border = {color = FIELD_BORDER, width = bw()},
												},
												) {
													clay.Text(
														label,
														{
															fontId = FONT_BODY,
															fontSize = 12,
															textColor = active ? ACCENT : TEXT_DIM,
														},
													)
												}
											}
										}
										// Global-search chip, also on Ctrl+K.
										if clay.UI(clay.ID("GSearchBtn"))(
										{
											layout = {
												padding = {left = 8, right = 8, top = 5, bottom = 5},
												childAlignment = {x = .Center, y = .Center},
											},
											backgroundColor = hovered() ? HOVER : {},
											cornerRadius = rr(7),
										},
										) {
											clay.Text(
												ICON_SEARCH,
												{
													fontId = FONT_ICON,
													fontSize = 12,
													textColor = TEXT_DIM,
												},
											)
										}
										if clay.UI(clay.ID("NewChatBtn"))(
										{
											layout = {
												padding = {left = 8, right = 8, top = 3, bottom = 3},
												childAlignment = {x = .Center, y = .Center},
											},
											backgroundColor = hovered() ? HOVER : {},
											cornerRadius = rr(7),
										},
										) {
											clay.Text(
												"+",
												{
													fontId = FONT_TITLE,
													fontSize = 18,
													textColor = ACCENT,
												},
											)
										}
									}

									// Chat filter.
									if clay.UI(clay.ID("FilterBox"))(
									{
										layout = {
											sizing = {
												width = clay.SizingGrow(),
												height = clay.SizingFixed(34),
											},
											padding = {left = 12, right = 12},
											childGap = 8,
											childAlignment = {y = .Center},
										},
										backgroundColor = ROW_BG,
										cornerRadius = rr(10),
										border = {color = FIELD_BORDER, width = bw()},
									},
									) {
										clay.Text(
											ICON_SEARCH,
											{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO},
										)
										field_text(
											ui,
											"FilterBox",
											&ui.sidebar_filter,
											ui.page == .Contacts ? "Search contacts..." : ui.page == .Archived ? "Search archived..." : "Search messages...",
											ui.focus == .Filter,
											13,
											TEXT_LO,
										)
									}
									// Folder chips, once the row menu has made a folder.
									if ui.page == .Chats && len(ui.prefs.folders) > 0 {
										folder_chips(ui)
									}
								}
							}
						}

						if ui.page == .Contacts && logged_in && !rail_narrow(ui) {
							if len(ui.contacts) == 0 {
								clay.Text(
									tr("No contacts yet"),
									{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
								)
							} else {
								if clay.UI(clay.ID("ContactsExportRow"))(
								{layout = {childGap = 8, padding = {left = 4, bottom = 2}}},
								) {
									micro_button("ContactsCsvBtn", "Export CSV")
									micro_button("ContactsJsonBtn", "Export JSON")
								}
							}
							if clay.UI(clay.ID("ContactList"))(
							{
								layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 6},
								clip = {vertical = true, childOffset = clay.GetScrollOffset()},
							},
							) {
								// Alphabetical with letter section headers and a name
								// filter, the slint contacts rail. Rows keep their
								// ui.contacts index in the clay ID so clicks stay stable.
								filter := strings.to_lower(
									string(ui.sidebar_filter[:]),
									context.temp_allocator,
								)
								last_letter: u8 = 0
								for order in contact_order(ui) {
									contact := ui.contacts[order.idx]
									if len(filter) > 0 && !strings.contains(order.key, filter) {
										continue
									}

									letter: u8 = '#'
									if len(order.key) > 0 && order.key[0] >= 'a' && order.key[0] <= 'z' {
										letter = order.key[0] - 32
									}
									if letter != last_letter {
										last_letter = letter
										if clay.UI(clay.ID("ContactLetter", u32(order.idx)))(
										{layout = {padding = {left = 10, top = 6, bottom = 2}}},
										) {
											clay.Text(
												fmt.tprintf("%c", letter),
												{
													fontId = FONT_MONO,
													fontSize = 11,
													textColor = TEXT_LO,
													letterSpacing = 2,
												},
											)
										}
									}

									selected := ui.selected_contact == order.idx
									if clay.UI(clay.ID("ContactRow", u32(order.idx)))(
									{
										layout = {
											sizing = {width = clay.SizingGrow()},
											padding = clay.PaddingAll(10),
											childGap = 10,
											childAlignment = {y = .Center},
										},
										backgroundColor = selected ? SELECTED : (hovered() ? HOVER : {}),
										cornerRadius = rr(12),
									},
									) {
										if selected {
											if clay.UI(clay.ID("ContactRowBar", u32(order.idx)))(
											{
												layout = {
													sizing = {
														width = clay.SizingFixed(3),
														height = clay.SizingFixed(18),
													},
												},
												backgroundColor = ACCENT,
												cornerRadius = rr(2),
											},
											) {}
										}
										avatar(
											"ContactAvatar",
											u32(order.idx),
											contact.id_hex,
											contact.name,
											30,
											url_pic(contact.pic_url),
										)
										clay.Text(
											contact_label(ui, contact),
											{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
										)
										if selected && len(contact.npub) > 0 {
											if clay.UI(clay.ID("ContactRowGap", u32(order.idx)))(
											{layout = {sizing = {width = clay.SizingGrow()}}},
											) {}
											clay.Text(
												npub_tail(contact.npub),
												{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO},
											)
										}
									}
								}
							}
							scrollbar(clay.ID("ContactList"))
						}

						if ui.page == .Chats && logged_in && !rail_narrow(ui) {
							if clay.UI(clay.ID("ChatList"))(
							{
								layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 6},
								clip = {vertical = true, childOffset = clay.GetScrollOffset()},
							},
							) {
								if len(ui.chats) == 0 {
									clay.Text(
										tr("No chats yet"),
										{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
									)
								}
								filter := strings.to_lower(
									string(ui.sidebar_filter[:]),
									context.temp_allocator,
								)
								// Pinned chats lead the rail; the rest keep marmot's
								// activity order.
								clear(&ui.rail_rows) // rebuilt below; Ctrl+Tab cycles it
								for i in rail_order(ui.chats[:], ui.prefs.pinned) {
									chat := ui.chats[i]
									if !in_folder(ui.prefs.folder_of, chat.group_id, ui.folder_filter) {
										continue
									}
									// A chat stays visible on a title match or a cached
									// message-body hit (refresh_filter_hits).
									if len(filter) > 0 &&
									   !strings.contains(
											   strings.to_lower(chat.title, context.temp_allocator),
											   filter,
										   ) &&
									   !(i < len(ui.filter_hits) && ui.filter_hits[i]) {
										continue
									}
									if ui.unread_only &&
									   chat.unread == 0 &&
									   !ui.prefs.unread_ids[chat.group_id] {
										continue
									}
									// A blocked contact's 1:1 chat leaves the rail, the
									// slint contact-block behavior (local, reversible).
									if peer, is_dm := ui.dm_peer[chat.group_id];
									   is_dm && ui.blocked[peer] {
										continue
									}
									append(&ui.rail_rows, i)
									chat_row(u32(i), chat, ui.selected == i, .Archive)
								}
							}
							scrollbar(clay.ID("ChatList"))
						}

						// Footer: relay/sync status pinned under the list. Collapsed,
						// the dot alone carries the connection state.
						if logged_in {
							if (ui.page != .Chats && ui.page != .Contacts) || rail_narrow(ui) {
								if clay.UI(clay.ID("RailFill"))(
								{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
								) {}
							}
							if clay.UI(clay.ID("RailFoot"))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									childGap = 8,
									childAlignment = {
										x = rail_narrow(ui) ? .Center : .Left,
										y = .Center,
									},
									padding = {top = 6},
								},
							},
							) {
								if clay.UI(clay.ID("RailFootDot"))(
								{
									layout = {
										sizing = {
											width = clay.SizingFixed(7),
											height = clay.SizingFixed(7),
										},
									},
									backgroundColor = net_color(net_state(ui)),
									cornerRadius = rr(4),
								},
								) {}
								if !rail_narrow(ui) {
									clay.Text(
										relay_counter(ui),
										{
											fontId = FONT_MONO,
											fontSize = 11,
											textColor = TEXT_LO,
											letterSpacing = 2,
										},
									)
									if clay.UI(clay.ID("RailFootGap"))(
									{layout = {sizing = {width = clay.SizingGrow()}}},
									) {}
									clay.Text(
										rl.GetTime() - sync_at < SYNCING_SECS ? "· SYNCING" : "· SYNCED",
										{
											fontId = FONT_MONO,
											fontSize = 11,
											textColor = TEXT_LO,
											letterSpacing = 2,
										},
									)
								}
							}
						}
					}
				}

				// Drag handle between the rail and the page card. A collapsed
				// rail has no width to drag, so the strip goes away and the page
				// card takes the space.
				if !rail_narrow(ui) && !single_pane() {
					gutter("RailGutter")
				}

				// Right card: the active page. On a one-card window it is
				// the detail half, so the rail's list stands in its place
				// until a row opens (hidden the same way as the rail).
				hide_main := single_pane() && !phone_detail(ui)
				if !hide_main {
					if clay.UI(clay.ID("MainCard"))(
					{
						// Switching page or chat: the new content rises the last few
						// pixels into place under a veil in the card's own color, so
						// the swap reads as a transition instead of a cut.
						layout = {
							sizing = {
								width = hide_main ? clay.SizingFixed(0) : clay.SizingGrow(),
								height = clay.SizingGrow(),
							},
							layoutDirection = .TopToBottom,
							padding = {top = u16((1 - page_t) * PAGE_SLIDE)},
						},
						clip = {horizontal = hide_main},
						backgroundColor = hide_main ? {} : CARD,
						cornerRadius = rr(16),
						border = hide_main ? {} : clay.BorderElementConfig{color = CARD_BORDER, width = bw()},
					},
					) {
						// No rail on screen to click back to.
						if single_pane() {
							phone_back(ui)
						}
						if !logged_in || ui.add_account_open {
							if clay.UI(clay.ID("Main"))(
							{
								layout = {
									sizing = {clay.SizingGrow(), clay.SizingGrow()},
									layoutDirection = .TopToBottom,
									childAlignment = {x = .Center, y = .Center},
									childGap = 12,
								},
							},
							) {
								login_pane(ui)
							}
						} else if ui.new_chat_open {
							new_chat_pane(ui)
						} else {
							switch ui.page {
							case .Chats:
								if ui.selected >= 0 {
									chat_pane(ui)
								} else if len(ui.chats) == 0 {
									get_started_pane(ui)
								} else {
									centered_note("PickChat", "Select a chat", ui.client_status)
								}
							case .Contacts:
								contacts_pane(ui)
							case .Archived:
								archived_pane(ui)
							case .Settings:
								settings_pane(ui)
							case .Profile:
								profile_pane(ui)
							}
						}
					}
				}
			}

			// Message banner + status bar, the slint shell's bottom strip.
			status_bar(ui)

			// One backdrop for every centered modal, whichever pane drew it.
			if open_now(clay.ID("ModalVeil"), modal_open(ui)) {
				modal_backdrop()
			}

			if open_now(clay.ID("PalModal"), ui.pal_open) {
				palette_modal(ui)
			}
			if open_now(clay.ID("ConfirmModal"), ui.confirm.kind != .None) {
				confirm_modal(ui)
			}
			if open_now(clay.ID("LinkModal"), ui.link_open) {
				link_modal(ui)
			}
			// No close animation: web_close tears down the child process, so
			// nothing may draw the modal after it.
			if web_modal.open {
				web_modal_draw(ui)
			}
			toast_layer(ui)

			// Root level, not the chat pane: settings opens it too.
			if open_now(clay.ID("PickerPanel"), ui.picker_open) {
				emoji_picker(ui)
			}

			if open_now(clay.ID("RowMenu"), ui.row_menu >= 0) &&
			   row_menu_index(ui) < len(ui.chats) {
				chat_row_menu(ui)
			}
			if open_now(clay.ID("MemberMenu"), ui.member_menu >= 0) &&
			   member_menu_index(ui) < len(ui.members) {
				member_menu(ui)
			}
			if open_now(clay.ID("FolderModal"), ui.folder_open) {
				folder_modal(ui)
			}
			if open_now(clay.ID("AccountsModal"), ui.accounts_open) {
				accounts_modal(ui)
			}
			if open_now(clay.ID("PeerModal"), ui.peer_open) {
				peer_modal(ui)
			}
			if open_now(clay.ID("GsModal"), ui.gs_open) {
				gsearch_modal(ui)
			}
			// The reaction fan and the flights cross everything, so they are
			// declared last.
			fan_layer(ui)
			fly_layer()
		}
	}

	commands := clay.EndLayout(frame_time)
	timeline_measure(ui)
	return commands
}

// Optimistic row: the confirmed row's shape in dim colors with
// "sending…" for a stamp (the slint pending overlay renders at 0.62
// opacity); a failed send goes danger and the row is a retry target.
// Integer from a test-hook env string, falling back when it isn't one.
parse_int_or :: proc(text: string, fallback: int) -> int {
	value, ok := strconv.parse_int(text)
	return ok ? value : fallback
}

WIN_TITLE :: "White Noise"

// Unread total in the window title, so a minimized window still says
// how much is waiting: "(3) White Noise". Same count the rail
// badges show. Set only when it changes, since the title is a window
// manager round trip and this runs every frame.
@(private = "file")
title_unread := -1

@(private = "file")
update_title :: proc(ui: ^Ui_State) {
	total := 0
	for chat in ui.chats {
		total += int(chat.unread)
	}
	if total == title_unread {
		return
	}
	title_unread = total

	if total == 0 {
		rl.SetWindowTitle(WIN_TITLE)
		return
	}
	rl.SetWindowTitle(
		strings.clone_to_cstring(fmt.tprintf("(%d) %s", total, WIN_TITLE), context.temp_allocator),
	)
}

main :: proc() {
	home: string
	link: string
	if len(os.args) > 1 {
		// The OS scheme handler passes the deep link as the sole
		// argument (Exec=… %u); anything else is the home-dir arg.
		if is_marmot_url(os.args[1]) {
			link = os.args[1]
		} else {
			home = os.args[1]
		}
	}
	if len(home) == 0 {
		// XDG_DATA_HOME first: a Flatpak points it at the app's own
		// ~/.var/app/<id>/data, the only writable home the sandbox has.
		data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if len(data) == 0 {
			data = fmt.tprintf("%s/.local/share", os.get_env("HOME", context.temp_allocator))
		}
		home = fmt.aprintf("%s/whitenoise", data)
	}

	ui: Ui_State
	ui.selected = -1
	ui.selected_contact = -1
	ui.mention_dismissed = -1
	ui.member_nick = -1
	ui.member_menu = -1
	ui.row_menu = -1
	ui.folder_rename = -1
	edit.init(&ui.ed, context.allocator, context.allocator)
	// Grapheme motion/deletion is done in edit_text via prev/next_grapheme;
	// the stdlib's translate_by_grapheme is broken for wide (CJK) chars.
	ui.ed.set_clipboard = clip_set
	ui.ed.get_clipboard = clip_get
	data_home = home // before load_themes: user themes live in <home>/themes
	os.make_directory(home) // the vault writes here before marmot boots
	harden_perms(home)
	// Two runtimes over one sqlite store corrupt it, so a second
	// instance stops here instead of booting.
	if !instance_lock(home) {
		fmt.eprintfln("White Noise is already running on %s", home)
		return
	}
	load_themes()
	defer stop_system_theme()
	load_settings(&ui)
	append(&ui.client_input, ..transmute([]u8)ui.prefs.event_client)
	set_locale(ui.prefs.locale)
	g_prefs = &ui.prefs
	apply_theme(ui.theme, ui.accent)

	// Headroom over clay's defaults (8192 elements): per-letter effect
	// runs, burst particles and the pre-wrapped body lines all spend
	// elements, and clay treats an exceeded capacity as an error
	// callback, not a stop.
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)

	win_w, win_h := i32(1024), i32(700)
	if tw := os.get_env("WN_TEST_WINDOW", context.temp_allocator); tw != "" {
		if x := strings.index_byte(tw, 'x'); x > 0 {
			w, _ := strconv.parse_int(tw[:x])
			h, _ := strconv.parse_int(tw[x + 1:])
			win_w = i32(w)
			win_h = i32(h)
		}
	}
	rl.InitWindow(win_w, win_h, WIN_TITLE)
	// After the window, never before: the zoom is derived from the
	// window's width, and there is no window to ask until now. The
	// vault gate runs its own frames before the main loop, so getting
	// this wrong renders the gate at a zoom of 1/360 and the app opens
	// on a black screen.
	apply_zoom(&ui)
	app_started = rl.GetTime()
	start_pic_worker()
	start_gimg_worker()
	rl.SetTargetFPS(60)
	refresh_ui_scale()
	init_fonts()

	for entry, i in QUICK_REACT {
		img := rl.LoadImageFromMemory(".png", raw_data(entry.png), i32(len(entry.png)))
		quick_react_tex[i] = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		rl.SetTextureFilter(quick_react_tex[i], .BILINEAR)
		append(&ui.recent_emoji, entry.emoji)
	}
	load_emoji_catalog()

	// Every secret lives in $home/vault.db, marmot's account keys
	// included, so the vault opens before the runtime does; closing the
	// window at the gate quits.
	if !vault_gate(&ui) {
		rl.CloseWindow()
		return
	}
	// Tray icon for either tray pref; start-in-tray also hides the
	// window, honored at boot only, after the unlock.
	apply_tray(&ui)
	if ui.prefs.start_in_tray {
		rl.HideWindow()
	}

	ready_started := time.tick_now()
	splash_frame(0)
	client := boot_marmot(home, &ui)
	splash_frame(1)
	// The boot line already showed on the splash; don't repeat it as a
	// banner over the first screen.
	ui.banner_seen = ui.client_status
	g_ui = &ui
	g_client = client
	if client != nil && len(ui.account_ref) > 0 {
		load_offline(&ui) // restore queued sends; first flush_queued tick retries them
	}

	shot := os.get_env("WN_SHOT", context.allocator) != ""
	debug_size := os.get_env("WN_DEBUG_SIZE", context.allocator) != ""
	frame := 0

	// WN_TEST_RESIZE="WxH@N" or "WxH@N~M": resize the window at frame N,
	// stepped over M frames (a compositor drag delivers a stream of
	// sizes, not one jump), for headless checks that content tracks a
	// live resize.
	test_resize_w, test_resize_h, test_resize_frame := i32(0), i32(0), -1
	test_resize_ramp := 1
	if tr_env := os.get_env("WN_TEST_RESIZE", context.allocator); tr_env != "" {
		if x := strings.index_byte(tr_env, 'x'); x > 0 {
			if at := strings.index_byte(tr_env, '@'); at > x {
				rest := tr_env[at + 1:]
				if tilde := strings.index_byte(rest, '~'); tilde > 0 {
					m, _ := strconv.parse_int(rest[tilde + 1:])
					test_resize_ramp = max(m, 1)
					rest = rest[:tilde]
				}
				w, _ := strconv.parse_int(tr_env[:x])
				h, _ := strconv.parse_int(tr_env[x + 1:at])
				n, _ := strconv.parse_int(rest)
				test_resize_w, test_resize_h, test_resize_frame = i32(w), i32(h), n
			}
		}
	}
	test_resize_from_w, test_resize_from_h := i32(0), i32(0)

	// Automation hooks for headless runs: create an identity when none
	// exists; create a group when none exists; send a message; select
	// the first chat so the screenshot shows the timeline.
	if client != nil &&
	   len(ui.accounts) == 0 &&
	   os.get_env("WN_TEST_CREATE", context.allocator) != "" {
		do_create_identity(&ui, client)
	}
	if client != nil &&
	   len(ui.accounts) > 0 &&
	   len(ui.chats) == 0 &&
	   os.get_env("WN_TEST_GROUP", context.allocator) != "" {
		group_id: cstring
		account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
		if marmot.create_group(
			   client,
			   account,
			   "Notes to self",
			   nil,
			   0,
			   "test group",
			   &group_id,
		   ) !=
		   .OK {
			ui.client_status = fmt.aprintf("create group failed: %s", marmot.last_error())
		} else {
			marmot.string_free(group_id)
			load_chat_list(client, ui.account_ref, &ui)
		}
	}
	// WN_TEST_SEND fires inside the frame loop (after the subscription
	// is armed) with no manual reload, so the rendered message proves
	// the live-update path.
	// Any pack by its mode name ("light", "nixie", "paravion"), so a
	// screenshot run can land on one directly.
	if tt := os.get_env("WN_TEST_THEME", context.allocator); tt != "" {
		for pack, i in theme_packs {
			if pack.mode == tt {
				ui.theme = i
				break
			}
		}
		apply_theme(ui.theme, ui.accent)
		save_settings(&ui)
	}
	if client != nil && len(ui.accounts) > 0 {
		switch os.get_env("WN_TEST_PAGE", context.allocator) {
		case "contacts":
			ui.page = .Contacts
			load_contacts(client, &ui)
		case "archived":
			ui.page = .Archived
			load_archived(client, &ui)
		case "members":
			if len(ui.chats) > 0 {
				ui.selected = 0
				load_timeline(client, &ui)
				ui.show_members = true
				load_members(client, &ui)
			}
		case "settings":
			ui.page = .Settings
		case "debug", "kp":
			// Both are dev-mode only; the harness forces the flag on.
			ui.page = .Settings
			ui.prefs.dev_mode = true
			ui.settings_section =
				os.get_env("WN_TEST_PAGE", context.temp_allocator) == "kp" ? .KP : .Debug
			if ui.settings_section == .Debug {
				compose_debug_json(&ui, client)
			}
		case "fx":
			// Arms the first catalog effect, so WN_TEST_COMPOSE's send
			// exercises the tagged path.
			ui.fx_armed = 1
		case "about":
			ui.page = .Settings
			ui.settings_section = .About
		case "palette":
			pal_open_modal(&ui)
		case "advanced":
			ui.page = .Settings
			ui.settings_section = .Advanced
			load_advanced(&ui, client)
		case "network":
			ui.page = .Settings
			ui.settings_section = .Network
		case "profile":
			ui.page = .Profile
			load_profile(client, &ui)
		case "profile-edit":
			ui.page = .Profile
			load_profile(client, &ui)
			edit_profile_start(&ui)
		case "accounts":
			ui.accounts_open = true
		case "gsearch":
			gs_open_modal(&ui)
		case "peer":
			if len(ui.chats) > 0 {
				ui.selected = 0
				load_timeline(client, &ui)
				for msg in ui.messages {
					if !msg.mine && len(msg.sender_id) > 0 {
						open_peer(&ui, client, msg.sender_id, msg.sender, msg.pic_url)
						break
					}
				}
			}
			if !ui.peer_open {
				// Single-account test home: render the popup on self.
				open_peer(&ui, client, ui.account_ref, ui.accounts[0], ui.my_pic_url)
			}
		}
	}

	// Deep link from the OS scheme handler: open the profile once
	// booted (own account routes to the profile page, like a mention
	// click). A second running instance is not detected; the link
	// opens in this fresh instance.
	if client != nil && len(ui.account_ref) > 0 && len(link) > 0 {
		if hx := deeplink_hex(marmot_link_ref(link)); len(hx) > 0 {
			if hx == ui.account_ref {
				ui.page = .Profile
				load_profile(client, &ui)
			} else {
				info := profile_info(client, hx)
				open_peer(
					&ui,
					client,
					hx,
					len(info.name) > 0 ? info.name : short_hex(hx),
					info.pic_url,
				)
			}
		}
	}

	ensure_notes(&ui, client) // the rail always has the user's own notepad

	test_send := os.get_env("WN_TEST_SEND", context.allocator)

	// Shot waits out the click sequence: 25 frames per extra pair.
	shot_frame := test_send != "" ? 300 : 30
	if test_click := os.get_env("WN_TEST_CLICK", context.allocator); test_click != "" {
		pairs := (strings.count(test_click, ",") + 1) / 2
		shot_frame += max(pairs - 1, 0) * 25
	}
	if sf := os.get_env("WN_SHOT_FRAME", context.allocator); sf != "" {
		shot_frame = parse_int_or(sf, shot_frame)
	}
	burst_lo, burst_hi := 0, 0
	if bf := os.get_env("WN_SHOT_BURST", context.allocator); bf != "" {
		if dash := strings.index_byte(bf, '-'); dash > 0 {
			burst_lo = parse_int_or(bf[:dash], 0)
			burst_hi = parse_int_or(bf[dash + 1:], 0)
		}
	}
	// WN_TEST_TYPE="N:text": inject the runes as typed input at frame
	// N, for headless checks of whoever holds the keyboard.
	test_type_frame, test_type_text := -1, ""
	if tt := os.get_env("WN_TEST_TYPE", context.allocator); tt != "" {
		if colon := strings.index_byte(tt, ':'); colon > 0 {
			test_type_frame = parse_int_or(tt[:colon], -1)
			test_type_text = tt[colon + 1:]
		}
	}
	if client != nil &&
	   len(ui.chats) > 0 &&
	   os.get_env("WN_TEST_SELECT", context.allocator) != "" {
		ui.selected = 0
		load_timeline(client, &ui)
		// Open the thread panel on the newest main-timeline message,
		// for headless shots of the thread view.
		if os.get_env("WN_TEST_THREAD", context.allocator) != "" {
			for i := len(ui.messages) - 1; i >= 0; i -= 1 {
				if len(ui.messages[i].thread_of) == 0 && !ui.messages[i].system {
					thread_push(&ui, ui.messages[i].id)
					break
				}
			}
		}
	}

	// Reopen the last chat, the General-settings startup toggle.
	if client != nil &&
	   ui.prefs.restore_last_chat &&
	   len(ui.prefs.last_chat) > 0 &&
	   ui.selected < 0 {
		select_by_id(&ui, client, ui.prefs.last_chat)
	}

	// Last splash beat: the relay pool is polled once here so the status
	// bar opens with a real count instead of the pre-poll placeholder.
	splash_frame(2)
	health_refresh(&ui, client)

	live: Live
	sett_was := ui.settings_section
	tl_container_was: [2]f32
	tl_at_bottom: bool
	win_was: [2]i32
	foreground_started: time.Tick
	focused_was: bool
	tl_restore: bool
	tl_offset: f32

	frame_input: bool
	for !rl.WindowShouldClose(&frame_input) {
		defer free_all(context.temp_allocator)
		defer messages_collect()
		defer { if wrap_flush { wrap_clear() } }
		poll_system_theme(&ui, rl.GetTime())

		focused := rl.IsWindowFocused()
		if focused && !focused_was {
			foreground_started = time.tick_now()
		}
		focused_was = focused

		anim_tick(rl.GetFrameTime())
		frame_deadline = rl.GetTime() + f64(IDLE_REFRESH_MS) / 1000

		// A monitor change can bring a new pixel density; glyphs baked
		// for the old one would draw scaled. Cheap check, rare hit.
		if max(rl.GetWindowScaleDPI().x, 1) * UI_ZOOM != UI_SCALE {
			refresh_ui_scale()
		}

		win_now := [2]i32{rl.GetScreenWidth(), rl.GetScreenHeight()}
		if win_now != win_was {
			// Zoom is derived from the width (zoom_for_width), so a
			// resize or a rotation can change it. apply_zoom only pays
			// for a re-bake when the value actually moves.
			apply_zoom(&ui)
			if debug_size {
				fmt.eprintfln("size: frame %d win %dx%d density %.4f", frame, win_now.x, win_now.y, rl.GetWindowScaleDPI().x)
			}
			win_was = win_now
		}

		start_live(&live, client, ui.account_ref) // no-op once running
		live_tick(&live, &ui, client) // poll fallback when the stream stalls
		drain_live(&live, &ui, client)
		media_drain(&ui)
		agent_tick(&ui, tl_at_bottom ? .Follow : .Hold)
		drain_sends(&ui, client)
		tts_tick(&ui)
		drain_ops(&ui, client)
		web_tick() // webxdc modal: run WebKit, take its pixels
		xdc_drain(&ui, client) // webxdc sendUpdate() becomes a group message
		drain_auth(&ui, client) // a finished sign-in lands on the UI thread
		flush_queued(&ui, client)
		mi_tick(&ui, client) // periodic mentions-inbox badge refresh
		health_tick(&ui, client) // relay-pool counters, Network page only
		retention_tick(&ui, client) // prune disappeared messages
		banner_tick(&ui) // a new client_status becomes the shell banner
		tray_tick(&ui) // unread total in the tray tooltip

		// Interface zoom shortcuts (Ctrl + / - / 0), the slint bindings.
		if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
			if rl.IsKeyPressed(.EQUAL) {
				ui.prefs.zoom_pct += 10
				apply_zoom(&ui)
				save_settings(&ui)
			}
			if rl.IsKeyPressed(.MINUS) {
				ui.prefs.zoom_pct -= 10
				apply_zoom(&ui)
				save_settings(&ui)
			}
			if rl.IsKeyPressed(.ZERO) {
				ui.prefs.zoom_pct = 100
				apply_zoom(&ui)
				save_settings(&ui)
			}
			// Ctrl+Tab / Ctrl+Shift+Tab cycles chats in the rail's
			// rendered order (last frame's rows), wrapping.
			if rl.IsKeyPressed(.TAB) && len(ui.rail_rows) > 0 {
				step := shift_down() ? -1 : 1
				at := 0 // selection not in the rail: start at the first row
				for idx, pos in ui.rail_rows {
					if idx == ui.selected {
						at = pos + step
						break
					}
				}
				n := len(ui.rail_rows)
				select_chat(&ui, client, ui.rail_rows[(at + n) %% n])
			}
		}

		// Synthetic click injection for headless tests: "x,y[,x,y...]",
		// one click per pair, released every 25 frames from frame 20.
		forced_release = false
		forced_press = false
		pointer := transmute(clay.Vector2)rl.GetMousePosition()
		if test_click := os.get_env("WN_TEST_CLICK", context.temp_allocator);
		   test_click != "" && frame >= 15 {
			parts := strings.split(test_click, ",", context.temp_allocator)
			step := min(int(frame - 15) / 25, len(parts) / 2 - 1)
			if len(parts) >= 2 && step >= 0 {
				px, _ := strconv.parse_f64(parts[step * 2])
				py, _ := strconv.parse_f64(parts[step * 2 + 1])
				pointer.x = f32(px)
				pointer.y = f32(py)
				test_pointer = {f32(px), f32(py)}
				test_pointer_on = true
				forced_press = int(frame) == 18 + step * 25
				forced_release = int(frame) == 20 + step * 25
			}
		}
		if test_type_frame >= 0 && int(frame) == test_type_frame {
			for r in test_type_text {
				rl.PushChar(r)
			}
		}
		// After the forced_press reset and the WN_TEST_CLICK block, so a
		// devctl click owns the same hooks, and before the pointer is
		// scaled and handed to clay.
		devctl_poll(&ui, client, int(frame), &pointer)
		pointer.x /= UI_ZOOM
		pointer.y /= UI_ZOOM
		clay.SetPointerState(pointer, rl.IsMouseButtonDown(.LEFT))

		// End a thumb drag one frame AFTER release so mouse_released()
		// can still see it and swallow the ending click.
		if !rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonReleased(.LEFT) {
			scroll_drag = {}
		}
		// A drag-selection ending with text selected feeds the primary
		// selection (select-to-copy), except from the masked nsec field.
		if rl.IsMouseButtonReleased(.LEFT) && text_drag != nil {
			if text_drag != &ui.login_input &&
			   ui.ed_target == text_drag &&
			   ui.ed.selection[0] != ui.ed.selection[1] {
				buf := (^[dynamic]u8)(text_drag)
				lo, hi, _ := field_sel(&ui, buf)
				rl.SetPrimaryText(
					strings.clone_to_cstring(string(buf[lo:hi]), context.temp_allocator),
				)
			}
			text_drag = nil
		}

		if os.get_env("WN_DEBUG_INPUT", context.temp_allocator) != "" {
			if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonReleased(.LEFT) {
				fmt.eprintfln(
					"input: pos=%v down=%v pressed=%v released=%v over_nav1=%v",
					rl.GetMousePosition(),
					rl.IsMouseButtonDown(.LEFT),
					rl.IsMouseButtonPressed(.LEFT),
					rl.IsMouseButtonReleased(.LEFT),
					clay.PointerOver(clay.ID("Nav", 1)),
				)
			}
		}
		// Wheel over a 3D tile (hover from last frame's build) zooms
		// the model instead of scrolling the timeline.
		wheel := rl.GetMouseWheelMoveV()
		// Ctrl + wheel zooms the interface; the wheel is consumed so
		// it doesn't also scroll.
		if ctrl_down() && wheel.y != 0 {
			ui.prefs.zoom_pct += wheel.y > 0 ? 10 : -10
			apply_zoom(&ui)
			save_settings(&ui)
			wheel = {}
		}
		wheel.x *= f32(ui.prefs.scroll_speed) / 100
		wheel.y *= f32(ui.prefs.scroll_speed) / 100
		if orbit_hover != nil {
			wheel = {}
		}
		// Wheel notches land in a residual that drains a fraction per
		// frame, so a scroll glides to a stop instead of stepping. What
		// the residual can't spend (already at a bound) becomes
		// overscroll, sprung back by the timeline's own padding.
		scroll_residual += transmute(clay.Vector2)wheel
		// The chat list follows wheel input immediately.
		drain := clay.PointerOver(clay.ID("ChatList")) ? f32(1) : anim_drain(SCROLL_DRAIN)
		step := clay.Vector2{scroll_residual.x * drain, scroll_residual.y * drain}
		scroll_residual -= step
		if abs(scroll_residual.x) < 0.01 {
			scroll_residual.x = 0
		}
		if abs(scroll_residual.y) < 0.01 {
			scroll_residual.y = 0
		}
		if scroll_residual != {} {
			anim_moving += 1
		}
		update_overscroll(step.y)
		update_scroll_vel()
		clay.UpdateScrollContainers(false, step, rl.GetFrameTime())
		clay.SetLayoutDimensions(
			{f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM},
		)

		orbit_hover = nil // rebound by the build when a tile is hovered
		link_hover = ""
		clear(&sel_lines) // body lines re-register during the build
		video_hover = nil
		stt_hover = {}
		att_hover = {}
		arc_hover = {}
		arc_more_hover = nil
		xdc_hover = {}
		img_hover = {}
		model_hover = {}
		code_hover = {}
		pdf_flip_hover = nil
		img_retry_hover = ""
		media_retry_hover = false
		reply_jump_hover = ""
		mention_hover = ""
		clear(&drag_targets)
		clear(&gcode_bars)
		clear(&video_bars)
		clear(&anim_bars)
		advance_videos() // pull decoded frames into the video textures
		voice_poll() // drain the mic stream while recording
		build_start := time.tick_now()
		if !tl_restore {
			if data := clay.GetScrollContainerData(clay.ID("Timeline")); data.found {
				tl_offset = data.scrollPosition.y
			}
		}
		render_commands := build_layout(&ui, rl.GetFrameTime())
		if tl_restore && !layout_overflow {
			if data := clay.GetScrollContainerData(clay.ID("Timeline")); data.found {
				data.scrollPosition.y = tl_offset
				render_commands = build_layout(&ui, rl.GetFrameTime())
			}
			tl_restore = false
		}

		// A relayout (window resize, rail drag, the rewrap they cause)
		// moves the bottom out from under a bottom-pinned view. Re-pin
		// and lay out AGAIN in the same frame: rendering first and
		// correcting next frame shows one wrong-scroll frame per size
		// step, which a continuous resize turns into a visible bounce.
		// A view the user scrolled away from is left alone. Container
		// size is the relayout tell; a new message only grows the
		// content, so the arrival glide below keeps its motion. The
		// second build is safe: per-frame anim steps are idempotent.
		if data := clay.GetScrollContainerData(clay.ID("Timeline")); data.found && !layout_overflow {
			overflow := max(
				data.contentDimensions.height - data.scrollContainerDimensions.height,
				0,
			)
			container := [2]f32 {
				data.scrollContainerDimensions.width,
				data.scrollContainerDimensions.height,
			}
			if container != tl_container_was && tl_at_bottom {
				data.scrollPosition.y = -overflow
				scroll_jumped = true
				render_commands = build_layout(&ui, rl.GetFrameTime())
				data = clay.GetScrollContainerData(clay.ID("Timeline"))
				overflow = max(
					data.contentDimensions.height - data.scrollContainerDimensions.height,
					0,
				)
				data.scrollPosition.y = -overflow
				// The rebuild can itself move the container a hair (chrome
				// that measures against the previous layout). Store the
				// post-rebuild size, or the next frame sees "changed"
				// again and the pin oscillates between the two layouts.
				container = {
					data.scrollContainerDimensions.width,
					data.scrollContainerDimensions.height,
				}
			}
			tl_container_was = container
			tl_at_bottom = data.scrollPosition.y <= -overflow + 1
		}

		// A failed layout contains only Clay's error screen. Grow its arena
		// and retry next frame, before rendering or handling message clicks.
		if layout_overflow {
			init_layout(&memory, clay.GetMaxElementCount() * 2, {f32(rl.GetScreenWidth()) / UI_ZOOM, f32(rl.GetScreenHeight()) / UI_ZOOM})
			tl_restore = true
			continue
		}

		// Models register during the build and are posed before the
		// renderer walks the commands, so a playing take advances only
		// while its tile is actually mounted.
		advance_models(rl.GetFrameTime())

		// Jump to the newest message AFTER layout, so the content
		// height includes rows appended this frame (an optimistic
		// pending row would otherwise sit below the scroll fold for
		// the whole send).
		// Center a global-search hit: the correction is relative to this
		// frame's laid-out row box, so the current offset doesn't matter.
		// ponytail: best effort, one attempt; a hit older than the loaded
		// page (limit 100) isn't in ui.messages and falls back to the
		// bottom jump. Paged loading with an anchor is the upgrade.
		if len(ui.jump_id) > 0 {
			for msg, i in ui.messages {
				if msg.id != ui.jump_id {
					continue
				}
				row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
				tl := clay.GetElementData(clay.ID("Timeline"))
				scroll_data := clay.GetScrollContainerData(clay.ID("Timeline"))
				if row.found && tl.found && scroll_data.found {
					overflow := max(
						scroll_data.contentDimensions.height -
						scroll_data.scrollContainerDimensions.height,
						0,
					)
					delta :=
						(row.boundingBox.y + row.boundingBox.height / 2) -
						(tl.boundingBox.y + tl.boundingBox.height / 2)
					scroll_data.scrollPosition.y = clamp(
						scroll_data.scrollPosition.y - delta,
						-overflow,
						0,
					)
					scroll_jumped = true // a teleport, not velocity
					ui.scroll_pending = false
				}
				break
			}
			delete(ui.jump_id)
			ui.jump_id = ""
		}
		if ui.scroll_pending {
			scroll_data := clay.GetScrollContainerData(clay.ID("Timeline"))
			if scroll_data.found {
				overflow :=
					scroll_data.contentDimensions.height -
					scroll_data.scrollContainerDimensions.height
				target := overflow > 0 ? -overflow : 0
				// No glide: the chat box does not animate. Arrivals and
				// chat opens both snap to the bottom.
				scroll_data.scrollPosition.y = target
				scroll_jumped = true // a teleport, not velocity
				ui.scroll_pending = false
			}
		}
		video_dbg_build = max(video_dbg_build, f32(time.duration_milliseconds(time.tick_since(build_start))))

		draw_start := time.tick_now()
		rl.BeginDrawing()
		shake_x, shake_y := shake_offset()
		rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM, offset = {shake_x, shake_y}})
		draw_frame(&render_commands)
		rl.EndMode2D()
		// Before EndDrawing: the backbuffer is undefined after present,
		// and reading it back then crashes inside Mesa on a frame whose
		// window was just resized.
		if shot && burst_hi == 0 && frame + 1 == shot_frame {
			rl.TakeScreenshot("wn-odin-shot.png")
			rl.EndDrawing()
			break
		}
		// WN_SHOT_BURST="A-B": one shot per frame across the range, then
		// exit. One run yields a whole animation timeline.
		if burst_hi > 0 && frame + 1 >= burst_lo {
			if frame + 1 <= burst_hi {
				rl.TakeScreenshot(fmt.ctprintf("wn-odin-burst-%04d.png", frame + 1))
			}
			if frame + 1 >= burst_hi {
				rl.EndDrawing()
				break
			}
		}
		devctl_draw()
		rl.EndDrawing()
		if ready_started != {} && rl.IsWindowFocused() {
			timing_record(client, .Splash_Ready, ready_started)
			ready_started = {}
		}
		if foreground_started != {} && focused {
			timing_record(client, .Foreground_Local_Ready, foreground_started)
			foreground_started = {}
		}
		timings_presented(&ui, client)
		video_dbg_draw = max(video_dbg_draw, f32(time.duration_milliseconds(time.tick_since(draw_start))))

		// Profile pictures fetched by the curl worker decode here (the
		// render thread owns texture creation).
		drain_pics()
		drain_kp()
		drain_relays(&ui, client)
		update_title(&ui)
		drain_refresh(client, &ui)
		drain_gimg(&ui, client)
		drain_ppic(&ui)
		drain_ov()
		drain_gh()
		drain_nev()

		// Files picked in the async SDL dialog land here; they become
		// composer chips, custom emoji when the settings "+" asked, or
		// the group photo when the hero chooser asked.
		picked := rl.PickedFiles()
		for path in picked {
			if ui.picking_backup {
				backup_stage(&ui, path)
			} else if ui.picking_emoji {
				stage_emoji(&ui, path)
			} else if ui.picking_gpic {
				set_group_pic(&ui, client, path)
			} else if ui.picking_ppic {
				set_profile_pic(&ui, client, path)
			} else {
				stage_file(&ui, path)
			}
			delete(path)
		}
		if len(picked) > 0 {
			ui.picking_emoji = false
			ui.picking_gpic = false
			ui.picking_ppic = false
			ui.picking_backup = false
		}
		delete(picked)

		if tc := os.get_env("WN_TEST_COMPOSE", context.temp_allocator); tc != "" {
			// Semicolon-separated "N:text" entries. Text lands in the
			// focused input; on the Chats page it also sends.
			for entry in strings.split(tc, ";", context.temp_allocator) {
				if colon := strings.index_byte(entry, ':');
				   colon > 0 && frame == parse_int_or(entry[:colon], -1) {
					ed_set(&ui, active_buf(&ui), entry[colon + 1:])
					test_send_now = ui.page == .Chats
				}
			}
		}

		long_press_tick() // before any handler reads long_pressed
		handle_gutters(&ui)
		if clicked("SttCancel") {
			stt_stop(&ui)
		}
		if clicked("SttFinish") {
			stt_finish(&ui)
		}
		if clicked("TtsStopGlobal") {
			tts_stop(&ui)
		}
		if clicked("BannerClose") {
			ui.banner = "" // borrowed from client_status; never freed here
		}
		if clicked("RailCollapse") {
			flip(&ui, &ui.prefs.rail_collapsed)
		}
		if clicked("PhoneBack") {
			phone_back_action(&ui)
		}
		// Settings has no "nothing picked" state of its own, so a
		// one-card window treats a section change as the open. Watched
		// here rather than set at each assignment, because the palette
		// and the profile jump rows land on a section too.
		if ui.settings_section != sett_was {
			sett_was = ui.settings_section
			ui.sett_open = true
		}

		// Modal capture order: a confirm sits over everything, then the
		// link guard, then the palette, then the older modals. Global
		// search opens on Ctrl+K, the palette on Ctrl+P.
		if ui.confirm.kind != .None {
			handle_confirm(&ui, client)
		} else if ui.link_open {
			handle_link_modal(&ui)
		} else if ui.pal_open {
			handle_palette(&ui, client)
		} else if len(ui.accounts) > 0 &&
		   !ui.add_account_open &&
		   ctrl_down() &&
		   rl.IsKeyPressed(.P) {
			pal_open_modal(&ui)
		} else if ui.backup_mode != .None {
			handle_backup(&ui)
		} else if ui.vault_pw_open {
			handle_vault_pw(&ui)
		} else if ui.gs_open {
			handle_gsearch(&ui, client)
		} else if len(ui.accounts) > 0 &&
		   !ui.add_account_open &&
		   ((ctrl_down() && rl.IsKeyPressed(.K)) || clicked("GSearchBtn")) {
			gs_open_modal(&ui)
		} else {
			handle_login(&ui, client)
			handle_pages(&ui, client)
			if ui.page == .Chats && !ui.add_account_open {
				handle_chat(&ui, client)
			}
		}
		// Body text selection and the link guard share the pointer over
		// message bodies: a drag that selected something swallows the
		// release, so dragging across a link doesn't open it.
		if !ui.pal_open && !ui.link_open && !ui.gs_open && ui.confirm.kind == .None {
			handle_body_sel(&ui)
			handle_body_copy(&ui)
			// A press that missed a body drags the timeline instead, and
			// a drag that moved is not a click on whatever is under it.
			handle_react_fan(&ui, client)
			update_drag_scroll(
				&ui,
				sel_dragging || orbit_hover != nil || modal_open(&ui) || fan_open(),
			)
			if len(ui.sel_copy) == 0 && !drag_moved {
				handle_link_click(&ui)
			}
		}
		// Text input follows the field, not the window: it drives the
		// IME and it is what raises and dismisses a phone's on-screen
		// keyboard. The area points the compositor at the caret.
		// ponytail: a chat opens with the composer focused, so on a
		// phone the keyboard comes up with the chat. TODO: confirm on
		// hardware (phosh/squeekboard) whether that reads as helpful or
		// as in the way; if it is in the way, the fix is a focus state
		// that starts empty on a tap_size() window and fills on a tap.
		rl.SetTextInput(text_field_live)
		if text_field_live {
			rl.SetTextInputArea(
				i32(caret_box.x * UI_ZOOM),
				i32(caret_box.y * UI_ZOOM),
				i32(max(caret_box.width, 1) * UI_ZOOM),
				i32(caret_box.height * UI_ZOOM),
			)
		}
		text_field_live = false
		handle_orbit()
		handle_gcode_bar()
		handle_anim_bar()
		if mouse_released() && stt_hover.message != "" {
			if stt_hover.action == .Toggle {
				stt_hover.view.transcript_open = !stt_hover.view.transcript_open
			} else if stt_hover.action == .Cancel {
				stt_stop(&ui)
			} else {
				stt_start(&ui, stt_hover.message, stt_hover.attachment)
			}
		}
		handle_video()
		handle_video_bar()
		handle_pdf()
		handle_preview(&ui, client)
		handle_arc_click(&ui)
		handle_xdc_click(&ui, client)
		handle_web_input(&ui)
		handle_att_click(&ui)
		handle_img_click(&ui, client)
		handle_model_click(&ui, client)
		handle_code_click(&ui, client)
		handle_mention_click(&ui, client)
		handle_img_retry(&ui, client)
		handle_media_retry(&ui, client)
		handle_reply_jump(&ui)
		// Drain after input: Enter finishing dictation must not send its result.
		stt_tick(&ui)

		// Destination chosen in the save dialog: fetch and write.
		saved := rl.SavedFiles()
		for path in saved {
			save_attachment(&ui, client, path)
			if backup_saving {
				backup_saved(&ui)
			}
			delete(path)
		}
		delete(saved)

		cursor_apply() // every raise for this frame is in by now

		// Present handler changes on the next frame before sleeping. Input
		// and worker events wake immediately; timers poll at most 4 Hz.
		if !shot && !frame_input && frame_idle() {
			rl.Wait(u32(clamp((frame_deadline - rl.GetTime()) * 1000, 1, f64(IDLE_REFRESH_MS))))
		}

		frame += 1
		if test_resize_frame >= 0 && frame >= test_resize_frame && frame < test_resize_frame + test_resize_ramp {
			if frame == test_resize_frame {
				test_resize_from_w, test_resize_from_h = rl.GetScreenWidth(), rl.GetScreenHeight()
			}
			t := f32(frame - test_resize_frame + 1) / f32(test_resize_ramp)
			w := test_resize_from_w + i32(f32(test_resize_w - test_resize_from_w) * t)
			h := test_resize_from_h + i32(f32(test_resize_h - test_resize_from_h) * t)
			rl.SetWindowSize(w, h)
		}
		if test_send != "" && frame == 10 && client != nil && len(ui.chats) > 0 {
			summary: ^marmot.Send_Summary
			account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
			group := strings.clone_to_cstring(ui.chats[0].group_id, context.temp_allocator)
			if marmot.send_text(
				   client,
				   account,
				   group,
				   strings.clone_to_cstring(test_send, context.temp_allocator),
				   &summary,
			   ) ==
			   .OK {
				marmot.send_summary_free(summary)
			}
		}
		if frame == 10 && ui.selected >= 0 {
			if media_path := os.get_env("WN_TEST_MEDIA", context.allocator); media_path != "" {
				data, read_err := os.read_entire_file(media_path, context.temp_allocator)
				if read_err == nil {
					attachment := marmot.Media_Upload_Attachment_Request {
						file_name     = strings.clone_to_cstring(
							media_path,
							context.temp_allocator,
						),
						media_type    = "image/png",
						plaintext     = raw_data(data),
						plaintext_len = len(data),
					}
					request := marmot.Media_Upload_Request {
						attachments     = &attachment,
						attachments_len = 1,
						caption         = "attachment test",
						send            = true,
					}
					result: ^marmot.Media_Upload_Result
					account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
					group := strings.clone_to_cstring(
						ui.chats[ui.selected].group_id,
						context.temp_allocator,
					)
					if marmot.upload_media(client, account, group, &request, &result) != .OK {
						fmt.eprintfln("media: upload failed: %s", marmot.last_error())
					} else {
						fmt.eprintfln("media: uploaded %d attachment(s)", result.attachments_len)
						marmot.media_upload_result_free(result)
						load_timeline(client, &ui)
					}
				}
			}
		}
		if frame == 5 && ui.selected >= 0 {
			if seed := os.get_env("WN_TEST_COMPOSE", context.allocator); seed != "" {
				ed_set(&ui, &ui.compose, seed)
				ui.ed_target = &ui.compose
				mid := rune_snap(seed, len(seed) / 2)
				ui.ed.selection = {mid, mid}
			}
		}
		if frame == 22 &&
		   ui.selected >= 0 &&
		   os.get_env("WN_TEST_PICKER", context.temp_allocator) != "" {
			open_picker(&ui, "")
		}
		// WN_TEST_PREVIEW=<path> opens the preview modal on a local
		// file, the only way to reach the model inspector headlessly
		// (the modal otherwise opens from an attachment).
		// Frame 12, before WN_TEST_CLICK's release at 20, so a click can
		// land on the modal.
		// WN_TEST_WEB=<url> opens the webxdc modal on any URL, and
		// WN_TEST_XDC=<file.xdc> takes the whole path a real
		// attachment takes (unpack, serve, run). Both exist because
		// the modal otherwise opens only from a chat.
		// WN_TEST_LINK=<url> raises the external-link guard on a URL.
		if frame == 12 {
			if url := os.get_env("WN_TEST_LINK", context.temp_allocator); url != "" {
				open_link(&ui, url)
			}
		}
		if frame == 12 && !web_modal.open {
			if url := os.get_env("WN_TEST_WEB", context.temp_allocator); url != "" {
				web_open(url, "test")
			}
			if path := os.get_env("WN_TEST_XDC", context.temp_allocator); path != "" {
				if bytes, err := os.read_entire_file(path, context.allocator); err == nil {
					if view := xdc_view_make(bytes, path); view != nil {
						xdc_launch(&ui, client, view, "test-session", "test-group")
					} else {
						fmt.eprintfln("webxdc: %s is not a webxdc app", path)
					}
				}
			}
		}
		if frame == 12 && !preview_shown {
			if path := os.get_env("WN_TEST_PREVIEW", context.temp_allocator); path != "" {
				if bytes, err := os.read_entire_file(path, context.allocator); err == nil {
					preview_show(path, bytes) // the extension is what dispatches
				}
			}
		}
		if frame == 22 && os.get_env("WN_TEST_HIST", context.temp_allocator) != "" {
			for msg, i in ui.messages {
				if msg.edited {
					ui.hist_open = true
					ui.hist_msg = i
					break
				}
			}
		}
		if frame == 20 &&
		   ui.selected >= 0 &&
		   len(ui.messages) > 0 &&
		   os.get_env("WN_TEST_CTX", context.temp_allocator) != "" {
			ui.ctx_open = true
			ui.ctx_msg = len(ui.messages) - 1
			ui.ctx_x = 400
			ui.ctx_y = 120
		}
		if frame == 12 && ui.selected >= 0 && len(ui.messages) > 0 {
			if os.get_env("WN_TEST_REACT", context.allocator) != "" {
				message_op(&ui, client, .React, ui.messages[len(ui.messages) - 1].id, "👍")
			}
			if edit_to := os.get_env("WN_TEST_EDIT", context.allocator); edit_to != "" {
				for msg in ui.messages {
					if msg.mine {
						clear(&ui.compose)
						append(&ui.compose, edit_to)
						ui.editing = msg.id
						break
					}
				}
				if len(ui.editing) > 0 {
					summary: ^marmot.Send_Summary
					account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
					group := strings.clone_to_cstring(
						ui.chats[ui.selected].group_id,
						context.temp_allocator,
					)
					target := strings.clone_to_cstring(ui.editing, context.temp_allocator)
					if marmot.edit_message(
						   client,
						   account,
						   group,
						   target,
						   strings.clone_to_cstring(edit_to, context.temp_allocator),
						   &summary,
					   ) ==
					   .OK {
						marmot.send_summary_free(summary)
					}
					ui.editing = ""
					clear(&ui.compose)
					load_timeline(client, &ui)
				}
			}
		}
	}

	// Persist the open chat's half-written draft across restarts.
	messages_collect()
	stt_stop(&ui)
	tts_stop(&ui)
	stash_draft(&ui)
	save_settings(&ui)

	// Shutdown order matters: closing the runtime makes the blocking
	// subscription read return CLOSED (worker exits), then the sub is
	// freed before the client that created it.
	if client != nil {
		marmot.client_shutdown(client)
		media_stop()
		agent_shutdown()
		if live.worker != nil {
			thread.join(live.worker)
			thread.destroy(live.worker)
			marmot.chat_list_subscription_free(live.sub)
		}
		if live.events_worker != nil {
			thread.join(live.events_worker)
			thread.destroy(live.events_worker)
			marmot.events_subscription_free(live.events_sub)
		}
		marmot.client_free(client)
	}
	delete(live.account)
	for msg in ui.messages { message_free(msg) }
	delete(ui.messages)
	delete(ui.messages_group)
	delete(ui.messages_account)
	wrap_clear()
	delete(wrap_cache)
	rl.CloseWindow()
}
