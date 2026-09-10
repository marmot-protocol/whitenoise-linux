package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import rl "sdlrl"

import marmot "../marmot"

// Base timeline window; scrolling near the top raises it per chat in
// steps of the same size. Growing one window (instead of before-pagination,
// which marmot also supports) keeps the single-page kind-1009 edit
// aggregation below correct without stitching pages.
TL_PAGE :: 100

tl_limit :: proc(ui: ^Ui_State, group_id: string) -> u32 {
	if limit, ok := ui.tl_limit[group_id]; ok {
		return limit
	}
	return TL_PAGE
}

load_timeline :: proc(client: ^marmot.Client, ui: ^Ui_State, search: string = "") {
	if ui.selected < 0 {
		return
	}

	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator),
		search       = len(search) > 0 ? strings.clone_to_cstring(search, context.temp_allocator) : nil,
		has_limit    = true,
		limit        = tl_limit(ui, ui.chats[ui.selected].group_id),
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {
		ui.client_status = fmt.aprintf("timeline failed: %s", marmot.last_error())
		return
	}
	defer marmot.timeline_page_free(page)
	ui.tl_has_more = page.has_more_before
	agent_collect(client, ui, page)

	// Message textures are owned by the media_textures session cache
	// now (shared across reloads), so rows never free them.
	// Resolve kind-1009 edits, mirroring chatmodel.rs aggregate_edits:
	// only edits whose authenticated sender authored the target count,
	// ordered by (received_at, id), newest wins as the displayed text.
	author_of := make(map[string]string, context.temp_allocator)
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.kind == 9 && record.message_id_hex != nil {
			author_of[string(record.message_id_hex)] = record.sender != nil ? string(record.sender) : ""
		}
	}
	edits := make(map[string][dynamic]Edit_Rec, context.temp_allocator)
	defer {
		for _, versions in edits {
			delete(versions)
		}
	}
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.kind != 1009 || record.plaintext == nil || len(strings.trim_space(string(record.plaintext))) == 0 {
			continue
		}
		target := first_event_ref(record)
		author, known := author_of[target]
		if !known || record.sender == nil || author != string(record.sender) {
			continue
		}
		versions := edits[target]
		append(&versions, Edit_Rec{
			at     = record.received_at,
			id     = record.message_id_hex != nil ? string(record.message_id_hex) : "",
			record = record,
		})
		edits[target] = versions
	}
	for _, &versions in edits {
		slice.sort_by(versions[:], proc(a, b: Edit_Rec) -> bool {
			return a.at == b.at ? a.id < b.id : a.at < b.at
		})
	}

	// Row indices and block ids move with the reload, so a live update
	// invalidates a selection: drop it unless a drag is in progress.
	if !sel_dragging {
		sel_clear(ui)
	}

	ui.scroll_pending = true
	// Ids present before this reload. marmot stores an outgoing message
	// locally before the relay ack, so its record shows up while the
	// send worker is still in flight; the build loop below hides that
	// copy so the grayed pending row stays alone until the ack (slint
	// keeps the overlay until ack too).
	old_times := make(map[string]time.Tick, context.temp_allocator)
	for old in ui.messages {
		old_times[old.id] = old.visible_since
	}
	inflight := make(map[string]int, context.temp_allocator)
	for p in ui.pending {
		if !p.failed && len(p.atts) == 0 && p.group_id == ui.chats[ui.selected].group_id {
			inflight[p.body] += 1
		}
	}
	// NIP-88 votes and thread replies fold into other rows: collected
	// during the walk, applied once every row is built (a vote can sit
	// either side of its poll in the page). Values borrow the page.
	votes := make(map[string]map[string]Poll_Vote, context.temp_allocator) // poll id → sender → latest
	thread_counts := make(map[string]int, context.temp_allocator)

	clear(&ui.messages)
	xdc_collect_begin()
	defer xdc_collect_end()
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		// Edit and delete records act on other rows; they never render
		// as their own message.
		if record.kind == 1009 || record.kind == 5 {
			continue
		}
		if record.kind == AGENT_ACTIVITY || record.kind == AGENT_OPERATION {
			continue
		}
		stream_body: string
		if record.kind == AGENT_STREAM_START {
			visible: bool
			stream_body, visible = agent_body(record)
			if !visible {
				continue
			}
		}

		// A kind-1018 vote folds into its poll's tally; never a row.
		// Latest per sender wins here, per NIP-88.
		if record.kind == KIND_POLL_VOTE {
			poll_vote_collect(&votes, record)
			continue
		}

		id_str := record.message_id_hex != nil ? string(record.message_id_hex) : ""
		sender := record.sender != nil ? string(record.sender) : "?"
		mine := record.direction != nil && string(record.direction) == "sent"

		// "Delete for me": a locally hidden id never builds a row.
		if ui.hidden[id_str] {
			continue
		}

		// Webxdc state updates ride text messages; they feed the
		// running app and never render as rows.
		if session, payload, is_xdc := xdc_decode(string(record.plaintext != nil ? record.plaintext : "")); is_xdc {
			xdc_collect(session, payload)
			continue
		}

		// A kind-1210 group-system row renders as a dim one-line
		// sentence ("Alice added Bob"), no avatar or actions.
		if record.kind == 1210 && record.group_system != nil {
			append(&ui.messages, Msg_Ui{
				id      = strings.clone(id_str),
				body    = strings.clone(system_text(client, record.group_system)),
				at      = format_when(record.timeline_at),
				at_full = format_full(record.timeline_at),
				day     = format_day(record.timeline_at),
				system  = true,
			})
			continue
		}

		// A shared theme rides its own kind: the body is a toml pack,
		// which renders as an offer card rather than as text. An
		// unparseable one is dropped, not shown half-read.
		if record.kind == THEME_EVENT_KIND {
			toml := string(record.plaintext != nil ? record.plaintext : "")
			name := theme_offer_name(toml)
			if len(name) == 0 {
				continue
			}
			info := profile_info(client, sender)
			label := info.name
			if len(label) == 0 {
				label = mine ? "you" : short_hex(sender)
			}
			append(&ui.messages, Msg_Ui{
				id         = strings.clone(id_str),
				sender     = strings.clone(label),
				sender_id  = strings.clone(sender),
				pic_url    = strings.clone(info.pic_url),
				theme_name = strings.clone(name),
				theme_toml = strings.clone(toml),
				theme_swatch = theme_swatches(name, toml),
				at         = format_when(record.timeline_at),
				at_full    = format_full(record.timeline_at),
				day        = format_day(record.timeline_at),
				mine       = mine,
			})
			continue
		}

		// Sender label + picture from the kind-0 cache; hex fallback
		// (or "you") when the profile is unknown.
		info := profile_info(client, sender)
		label := info.name
		if len(label) == 0 {
			label = mine ? "you" : short_hex(sender)
		}

		// A tombstone keeps its place as a placeholder row (sender +
		// stamp only) instead of vanishing, the slint chatmodel path.
		if record.deleted {
			append(&ui.messages, Msg_Ui{
				id        = strings.clone(id_str),
				sender    = strings.clone(label),
				sender_id = strings.clone(sender),
				pic_url   = strings.clone(info.pic_url),
				at        = format_when(record.timeline_at),
				at_full   = format_full(record.timeline_at),
				day       = format_day(record.timeline_at),
				mine      = mine,
				deleted   = true,
			})
			continue
		}

		// An edited message renders the newest edit's content under the
		// original id and row position.
		content := record
		versions, has_edits := edits[id_str]
		if has_edits && len(versions) > 0 {
			content = versions[len(versions) - 1].record
		}
		body := content.plaintext != nil ? string(content.plaintext) : ""
		if record.kind == AGENT_STREAM_START {
			body = stream_body
		}

		// The local copy of an in-flight optimistic send: skip it, the
		// pending row is its visual until the ack lands.
		if mine && !(id_str in old_times) && inflight[body] > 0 {
			inflight[body] -= 1
			continue
		}

		msg := Msg_Ui{
			id        = strings.clone(id_str),
			sender    = strings.clone(label),
			sender_id = strings.clone(sender),
			pic_url   = strings.clone(info.pic_url),
			body      = strings.clone(body),
			at      = format_when(record.timeline_at),
			at_full = format_full(record.timeline_at),
			day     = format_day(record.timeline_at),
			mine   = mine,
			edited = has_edits && len(versions) > 0,
			effect = record_effect(record),
		}
		// A kind-1068 poll renders its question as the body plus the
		// option bars parsed here; a kind-1111 thread message leaves
		// the main timeline for its root's thread panel.
		if record.kind == KIND_POLL {
			poll_parse(client, &msg, record)
		}
		// A kind-1111 thread message, or a poll created inside a
		// thread, references its root as the first e tag and renders
		// only in that thread's view.
		if record.kind == KIND_THREAD || record.kind == KIND_POLL {
			if root := first_event_ref(record); len(root) > 0 {
				msg.thread_of = strings.clone(root)
				thread_counts[msg.thread_of] += 1
			}
		}
		// A burst plays the first time its message is seen, not on every
		// reload (effects.odin keeps the seen set).
		burst_arrive(msg.id, msg.effect, mine)
		if msg.edited {
			original := record.plaintext != nil ? string(record.plaintext) : ""
			append(&msg.history, Edit_Version{at = format_when(record.timeline_at), text = strings.clone(original)})
			for v in versions {
				append(&msg.history, Edit_Version{
					at   = format_when(v.record.timeline_at),
					text = strings.clone(v.record.plaintext != nil ? string(v.record.plaintext) : ""),
				})
			}
		}
		// Edit records and poll questions arrive without parsed content
		// tokens; run the text through marmot's markdown parser so they
		// render like any other body.
		if (msg.edited || record.kind == KIND_POLL) && content.content_tokens.blocks_len == 0 && len(body) > 0 {
			doc: ^marmot.Markdown_Document
			if marmot.parse_markdown(client, strings.clone_to_cstring(body, context.temp_allocator), &doc) == .OK {
				convert_blocks(&msg.blocks, doc.blocks, doc.blocks_len, false)
				marmot.markdown_document_free(doc)
			}
		} else if record.kind != AGENT_STREAM_START {
			convert_blocks(&msg.blocks, content.content_tokens.blocks, content.content_tokens.blocks_len, false)
		}
		for j in 0 ..< record.reactions.by_emoji_len {
			entry := &record.reactions.by_emoji[j]
			mine_reaction := false
			for k in 0 ..< record.reactions.user_reactions_len {
				user := &record.reactions.user_reactions[k]
				if user.sender != nil && string(user.sender) == ui.account_ref && string(user.emoji) == string(entry.emoji) {
					mine_reaction = true
					break
				}
			}
			// Resolve reactor names for the chip's hover tooltip.
			names := make([dynamic]string, context.temp_allocator)
			for s in 0 ..< entry.senders_len {
				if entry.senders[s] != nil {
					append(&names, profile_label(client, string(entry.senders[s])))
				}
			}
			append(&msg.reactions, Reaction_Ui{
				label = fmt.aprintf("%s %d", string(entry.emoji), entry.count),
				emoji = strings.clone(string(entry.emoji)),
				count = fmt.aprintf("%d", entry.count),
				mine  = mine_reaction,
				who   = strings.join(names[:], ", "),
			})
		}

		if record.reply_to_message_id_hex != nil {
			msg.reply_id = strings.clone(string(record.reply_to_message_id_hex))
		}
		if record.reply_preview != nil {
			preview := record.reply_preview
			msg.reply_from = strings.clone(preview.sender != nil ? profile_label(client, string(preview.sender)) : "?")
			msg.reply_text = strings.clone(preview.plaintext != nil ? string(preview.plaintext) : "")
		} else if record.reply_to_message_id_hex != nil {
			// Parent outside the loaded window (or deleted): keep the
			// reply frame with a plain note instead of dropping it.
			msg.reply_text = strings.clone("Original message unavailable")
		}

		// Fetch and decode image attachments; non-images are skipped.
		// A session cache keyed by content hash makes reloads (every
		// live event and every send) free of network work; only the
		// FIRST sight of a blob downloads.
		// ponytail: that first fetch still blocks the frame; worker +
		// encrypted disk cache is the upgrade. Failures cache as nil
		// so a dead blob can't re-freeze every reload.
		for j in 0 ..< record.media_len {
			reference := &record.media[j]

			// 3D models (STL/OBJ) and g-code: same download + session
			// cache shape as images, but the cached value is a parsed
			// view drawn in 3D. Other clients send octet-stream, so
			// match extensions too.
			name := reference.file_name != nil ? string(reference.file_name) : ""
			append(&msg.att_names, strings.clone(len(name) > 0 ? name : "attachment"))
			append(&msg.att_keys, strings.clone(reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name))
			// A custom :shortcode: image riding along with the body.
			// It renders inline as the emoji, never as an attachment.
			if strings.has_prefix(name, EMOJI_ATT_PREFIX) {
				code := emoji_code(name[len(EMOJI_ATT_PREFIX):])
				if _, seen := remote_emoji_tex[code]; !seen {
	if plain, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
						remote_emoji_add(name, plain)
						delete(plain)
					}
				}
				continue
			}

			lower := strings.to_lower(name, context.temp_allocator)
			is_mesh := is_model_name(lower) ||
				(reference.media_type != nil && strings.has_prefix(string(reference.media_type), "model/"))
			is_gcode := strings.has_suffix(lower, ".gcode") || strings.has_suffix(lower, ".gco")
			if is_mesh || is_gcode {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				mesh, mesh_seen := stl_views[key]
				gcode, gcode_seen := gcode_views[key]
				if !mesh_seen && !gcode_seen {
	plain, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference)
					if ok {
						defer delete(plain)
						if is_gcode {
							if segs, ok := parse_gcode(plain); ok {
								gcode = gcode_view_make(segs)
							}
							gcode_views[strings.clone(key)] = gcode
						} else {
							mesh = model_view_make(lower, plain)
							stl_views[strings.clone(key)] = mesh
						}
					} else {
						fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
						if is_gcode {
							gcode_views[strings.clone(key)] = nil
						} else {
							stl_views[strings.clone(key)] = nil
						}
					}
				}

				switch {
				case gcode != nil:
					append(&msg.gcodes, Att_Item(^Gcode_View){gcode, int(j)})
				case mesh != nil:
					append(&msg.models, Att_Item(^Stl_View){mesh, int(j)})
				case:
					msg.media_failed = true
				}
				continue
			}

			// Video embeds: same cache pattern, the view owns an mpv
			// instance playing from the decrypted bytes. GIFs ride the
			// same path in loop mode, which is what animates them.
			is_gif := strings.has_suffix(lower, ".gif") ||
				(reference.media_type != nil && string(reference.media_type) == "image/gif")
			if is_gif || is_video_name(lower) ||
			   (reference.media_type != nil && strings.has_prefix(string(reference.media_type), "video/")) {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := video_views[key]; seen {
					if view != nil {
						append(&msg.videos, Att_Item(^Video_View){view, int(j)})
					} else {
						msg.media_failed = true
					}
					continue
				}

	view: ^Video_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					view = video_view_make(bytes, is_gif ? .Loop : .Clip)
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				video_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.videos, Att_Item(^Video_View){view, int(j)})
				} else {
					msg.media_failed = true
				}
				continue
			}

			// Audio: same mpv view as video, no frames; the tile draws
			// the controls. A failed download falls to the file chip.
			is_audio := strings.has_suffix(lower, ".mp3") || strings.has_suffix(lower, ".ogg") ||
				strings.has_suffix(lower, ".flac") || strings.has_suffix(lower, ".m4a") ||
				strings.has_suffix(lower, ".wav") ||
				(reference.media_type != nil && strings.has_prefix(string(reference.media_type), "audio/"))
			if is_audio {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := video_views[key]; seen {
					if view != nil {
						append(&msg.audios, Att_Item(^Video_View){view, int(j)})
					} else {
						append(&msg.files, int(j))
					}
					continue
				}

	view: ^Video_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					view = video_view_make(bytes, .Audio)
					view.bars = wav_bars(bytes) // nil unless 16-bit PCM WAV
					blob_sizes[strings.clone(key)] = i64(len(bytes))
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				video_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.audios, Att_Item(^Video_View){view, int(j)})
				} else {
					append(&msg.files, int(j))
				}
				continue
			}

			// PDFs: poppler-rendered pages, same cache pattern.
			if strings.has_suffix(lower, ".pdf") ||
			   (reference.media_type != nil && string(reference.media_type) == "application/pdf") {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := pdf_views[key]; seen {
					if view != nil {
						append(&msg.pdfs, Att_Item(^Pdf_View){view, int(j)})
					} else {
						msg.media_failed = true
					}
					continue
				}

	view: ^Pdf_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					defer delete(bytes) // g_bytes_new copied
					view = pdf_view_make(bytes)
					if view.failed {
						free(view)
						view = nil
					}
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				pdf_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.pdfs, Att_Item(^Pdf_View){view, int(j)})
				} else {
					msg.media_failed = true
				}
				continue
			}

			// Webxdc apps: a zip, but identified as an app rather
			// than listed as files.
			if is_xdc_name(lower) {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				view, seen := xdc_views[key]
				if !seen {
					if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
						blob_sizes[strings.clone(key)] = i64(len(bytes))
						view = xdc_view_make(bytes, name)
						if view == nil {
							delete(bytes)
						}
					} else {
						fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
					}
					xdc_views[strings.clone(key)] = view
				}
				if view != nil {
					append(&msg.xdcs, Att_Item(^Xdc_View){view, int(j)})
				} else {
					append(&msg.files, int(j)) // not a webxdc app: plain chip
				}
				continue
			}

			// Archives: libarchive listing, entries preview on click.
			is_arc := strings.has_suffix(lower, ".zip") || strings.has_suffix(lower, ".rar") ||
				strings.has_suffix(lower, ".7z") || strings.has_suffix(lower, ".tar") ||
				strings.has_suffix(lower, ".tgz") || strings.has_suffix(lower, ".txz") ||
				strings.has_suffix(lower, ".tbz2") || strings.contains(lower, ".tar.")
			if is_arc {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := arc_views[key]; seen {
					if view != nil {
						append(&msg.arcs, Att_Item(^Arc_View){view, int(j)})
					} else {
						append(&msg.files, int(j)) // unreadable: plain chip
					}
					continue
				}

	view: ^Arc_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					view = arc_view_make(bytes)
					if view == nil {
						delete(bytes)
					}
					blob_sizes[strings.clone(key)] = i64(len(bytes))
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				arc_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.arcs, Att_Item(^Arc_View){view, int(j)})
				} else {
					append(&msg.files, int(j))
				}
				continue
			}

			// Text and markdown: line-level markdown blocks.
			if strings.has_suffix(lower, ".md") || strings.has_suffix(lower, ".markdown") || strings.has_suffix(lower, ".txt") {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := txt_views[key]; seen {
					if view != nil {
						append(&msg.txts, Att_Item(^Txt_View){view, int(j)})
					} else {
						append(&msg.files, int(j))
					}
					continue
				}

	view: ^Txt_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					defer delete(bytes)
					view = txt_view_make(string(bytes))
					blob_sizes[strings.clone(key)] = i64(len(bytes))
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				txt_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.txts, Att_Item(^Txt_View){view, int(j)})
				} else {
					append(&msg.files, int(j))
				}
				continue
			}

			// Source files: the same tile shape, syntax highlighted.
			if is_code_name(lower) {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := code_views[key]; seen {
					if view != nil {
						append(&msg.codes, Att_Item(^Code_View){view, int(j)})
					} else {
						append(&msg.files, int(j))
					}
					continue
				}

				view: ^Code_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					defer delete(bytes)
					view = code_view_make(lower, string(bytes))
					blob_sizes[strings.clone(key)] = i64(len(bytes))
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				code_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.codes, Att_Item(^Code_View){view, int(j)})
				} else {
					append(&msg.files, int(j))
				}
				continue
			}

			// Fonts: rasterized type specimen.
			if strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") {
				key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : name
				if view, seen := ttf_views[key]; seen {
					if view != nil {
						append(&msg.fonts, Att_Item(^Ttf_View){view, int(j)})
					} else {
						append(&msg.files, int(j))
					}
					continue
				}

	view: ^Ttf_View
				if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
					defer delete(bytes) // specimen texture already built
					view = ttf_view_make(bytes)
					blob_sizes[strings.clone(key)] = i64(len(bytes))
				} else {
					fmt.eprintfln("media: download failed (%s): %s", name, marmot.last_error())
				}

				ttf_views[strings.clone(key)] = view
				if view != nil {
					append(&msg.fonts, Att_Item(^Ttf_View){view, int(j)})
				} else {
					append(&msg.files, int(j))
				}
				continue
			}

			// No renderer for this type: a chip says so and offers
			// the download.
			if reference.media_type == nil || !strings.has_prefix(string(reference.media_type), "image/") {
				append(&msg.files, int(j))
				continue
			}
			key := reference.plaintext_sha256 != nil ? string(reference.plaintext_sha256) : string(reference.file_name)
			if tex, seen := media_textures[key]; seen {
				if tex != nil {
					append(&msg.images, Att_Item(^rl.Texture2D){tex, int(j)})
				} else {
					append(&msg.img_failed, Att_Item(string){strings.clone(key), int(j)})
				}
				continue
			}

	texture: ^rl.Texture2D
			if bytes, ok := media_load(client, account, strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator), reference); ok {
				defer delete(bytes)
				ext := strings.clone_to_cstring(fmt.tprintf(".%s", strings.trim_prefix(string(reference.media_type), "image/")), context.temp_allocator)
				image := rl.LoadImageFromMemory(ext, raw_data(bytes), i32(len(bytes)))
				if image.data != nil {
					texture = new(rl.Texture2D)
					texture^ = rl.LoadTextureFromImage(image)
					rl.UnloadImage(image)
				}
			} else {
				fmt.eprintfln("media: download failed (%s): %s", string(reference.file_name), marmot.last_error())
			}

			media_textures[strings.clone(key)] = texture
			if texture != nil {
				append(&msg.images, Att_Item(^rl.Texture2D){texture, int(j)})
			} else {
				append(&msg.img_failed, Att_Item(string){strings.clone(key), int(j)})
			}
		}
		append(&ui.messages, msg)
	}

	for &msg in ui.messages {
		msg.visible_since = old_times[msg.id]
	}

	// Fold the collected votes and thread reply counts onto their rows.
	for &m in ui.messages {
		if len(m.poll_opts) > 0 {
			poll_tally(&m, votes[m.id], ui.account_ref)
		}
		if n, ok := thread_counts[m.id]; ok {
			m.thread_replies = n
		}
	}

	apply_pending_reacts(ui)
}

// Overlay the in-flight reactions onto the rows just built. An add
// that the reload already confirmed just loses its ghost; an unreact
// still on the wire fades the chip it is about to remove.
apply_pending_reacts :: proc(ui: ^Ui_State) {
	for p in ui.react_pending {
		for &msg in ui.messages {
			if msg.id != p.msg_id {
				continue
			}
			hit := false
			for &chip in msg.reactions {
				if chip.emoji != p.emoji {
					continue
				}
				hit = true
				chip.ghost = !p.remove || chip.mine
			}
			if !hit && !p.remove {
				append(&msg.reactions, Reaction_Ui{
					label = fmt.aprintf("%s 1", p.emoji),
					emoji = strings.clone(p.emoji),
					count = strings.clone("1"),
					mine  = true,
					ghost = true,
				})
			}
			break
		}
	}
}

// The system-line sentence for a kind-1210 record, the slint
// system_event_text templates; marmot's own fallback text covers the
// types not phrased here (disappearing-timer change). Temp-allocated.
system_text :: proc(client: ^marmot.Client, ev: ^marmot.Group_System_Event) -> string {
	actor, subject: string
	if ev.actor_account_id_hex != nil && len(string(ev.actor_account_id_hex)) > 0 {
		actor = profile_label(client, string(ev.actor_account_id_hex))
	}
	if ev.subject_account_id_hex != nil && len(string(ev.subject_account_id_hex)) > 0 {
		subject = profile_label(client, string(ev.subject_account_id_hex))
	}
	kind := ev.system_type != nil ? string(ev.system_type) : ""
	name := ev.name != nil ? string(ev.name) : ""

	switch {
	case kind == "member_added" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf("%s added %s", actor, subject)
	case kind == "member_removed" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf("%s removed %s", actor, subject)
	case kind == "member_left" && len(subject) > 0:
		return fmt.tprintf("%s left the group", subject)
	case kind == "admin_added" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf("%s made %s an admin", actor, subject)
	case kind == "admin_removed" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf("%s dismissed %s as admin", actor, subject)
	case kind == "group_renamed" && len(actor) > 0 && len(name) > 0:
		return fmt.tprintf("%s renamed the group to %s", actor, name)
	case kind == "group_avatar_changed" && len(actor) > 0:
		return fmt.tprintf("%s changed the group photo", actor)
	}
	return ev.text != nil ? string(ev.text) : ""
}

// px above the top of loaded history at which scrolling up fetches the
// next page (handle_chat).
TL_FETCH_MARGIN :: f32(300)

// Raise this chat's window by one page and reload, then re-anchor the
// viewport on the previously-topmost message via the jump/centering
// path (which also cancels the bottom jump).
load_earlier :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	if ui.selected < 0 {
		return
	}
	gid := ui.chats[ui.selected].group_id
	raised := tl_limit(ui, gid) + TL_PAGE
	if gid in ui.tl_limit {
		ui.tl_limit[gid] = raised
	} else {
		ui.tl_limit[strings.clone(gid)] = raised
	}

	anchor: string
	if len(ui.messages) > 0 {
		anchor = strings.clone(ui.messages[0].id)
	}
	load_timeline(client, ui)
	delete(ui.jump_id)
	ui.jump_id = anchor
}

// Raw-event JSON for the View raw modal (dev mode). marmot-c has no
// accessor for the outer signed wire event, so this re-queries the
// timeline window and pretty-prints the record's projection of the
// inner app event (id, kind, tags, sender, timestamps, ...).
raw_event_json :: proc(client: ^marmot.Client, ui: ^Ui_State, msg_id: string) -> string {
	if ui.selected < 0 {
		return ""
	}
	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator),
		has_limit    = true,
		limit        = 200,
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {
		return fmt.aprintf("Couldn't load the event. %s", marmot.last_error())
	}
	defer marmot.timeline_page_free(page)

	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.message_id_hex == nil || string(record.message_id_hex) != msg_id {
			continue
		}
		return record_json(record)
	}
	return fmt.aprintf("No record with id %s in this chat's window.", msg_id)
}

// Pretty-print one record's projection of the inner app event.
// Shared by the View raw modal and the HTML transcript export.
record_json :: proc(record: ^marmot.Timeline_Message_Record, allocator := context.allocator) -> string {
	str :: proc(c: cstring) -> string {
		return c != nil ? string(c) : ""
	}
	tags := make([dynamic][]string, context.temp_allocator)
	for j in 0 ..< record.tags_len {
		tag := &record.tags[j]
		values := make([]string, tag.values_len, context.temp_allocator)
		for k in 0 ..< tag.values_len {
			values[k] = str(tag.values[k])
		}
		append(&tags, values)
	}
	// Spaces, not tabs: the mono font has no tab glyph.
	data, err := json.marshal(
		struct {
			message_id_hex, source_message_id_hex:      string,
			kind:                                       u64,
			direction, group_id_hex, sender, plaintext: string,
			tags:                                       [][]string,
			timeline_at, received_at:                   u64,
			reply_to_message_id_hex:                    string,
			media_json:                                 string,
			deleted:                                    bool,
			deleted_by_message_id_hex:                  string,
			invalidation_status:                        string,
		} {
			message_id_hex            = str(record.message_id_hex),
			source_message_id_hex     = str(record.source_message_id_hex),
			kind                      = record.kind,
			direction                 = str(record.direction),
			group_id_hex              = str(record.group_id_hex),
			sender                    = str(record.sender),
			plaintext                 = str(record.plaintext),
			tags                      = tags[:],
			timeline_at               = record.timeline_at,
			received_at               = record.received_at,
			reply_to_message_id_hex   = str(record.reply_to_message_id_hex),
			media_json                = str(record.media_json),
			deleted                   = record.deleted,
			deleted_by_message_id_hex = str(record.deleted_by_message_id_hex),
			invalidation_status       = str(record.invalidation_status),
		},
		json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone("Couldn't serialize the event. Please try again.", allocator)
	}
	return strings.clone(string(data), allocator)
}

// Archived chats: same call as the rail with include_archived, kept
// to only the archived rows.
load_archived :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	rows: ^marmot.Chat_List_Row_List
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.chat_list(client, account, true, &rows) != .OK {
		return
	}
	defer marmot.chat_list_row_list_free(rows)

	clear(&ui.archived)
	for i in 0 ..< rows.len {
		row := &rows.items[i]
		if !row.archived {
			continue
		}
		append(&ui.archived, row_to_ui(client, row, ui.account_ref))
	}
}

// Contacts: every non-local member across the account's groups,
// deduplicated, with directory display names when known.
// Contacts sorted case-insensitively by name for the sidebar; key is
// the lowercased name (also the filter haystack), idx the ui.contacts
// position. Temp-allocated, rebuilt per frame.
Contact_Order :: struct {
	key: string,
	idx: int,
}

// Local nickname when set, else the published/directory name.
contact_label :: proc(ui: ^Ui_State, c: Contact_Ui) -> string {
	if nick, ok := ui.nicknames[c.id_hex]; ok && len(nick) > 0 {
		return nick
	}
	return c.name
}

contact_order :: proc(ui: ^Ui_State) -> []Contact_Order {
	rows := make([]Contact_Order, len(ui.contacts), context.temp_allocator)
	for contact, i in ui.contacts {
		rows[i] = {strings.to_lower(contact_label(ui, contact), context.temp_allocator), i}
	}
	slice.sort_by(rows, proc(a, b: Contact_Order) -> bool {
		return a.key < b.key
	})
	return rows
}

// "npub136lfe...gfasl4" tail for tight row corners.
npub_tail :: proc(npub: string) -> string {
	if len(npub) <= 24 {
		return npub
	}
	return fmt.tprintf("%s...%s", npub[:10], npub[len(npub) - 6:])
}

load_contacts :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	clear(&ui.contacts)
	clear(&ui.dm_peer)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	for chat in ui.chats {
		members: ^marmot.Group_Member_Record_List
		group := strings.clone_to_cstring(chat.group_id, context.temp_allocator)
		if marmot.group_members(client, account, group, &members) != .OK {
			continue
		}
		defer marmot.app_group_member_record_list_free(members)

		for i in 0 ..< members.len {
			member := &members.items[i]
			if member.local || member.member_id_hex == nil {
				continue
			}
			id := string(member.member_id_hex)
			// Remember the peer of each 1:1 chat so the rail can hide
			// conversations with locally blocked contacts.
			if members.len == 2 {
				ui.dm_peer[strings.clone(chat.group_id)] = strings.clone(id)
			}
			if seen[id] {
				for &existing in ui.contacts {
					if existing.id_hex == id {
						append(&existing.groups, Common_Group{strings.clone(chat.title), int(members.len)})
						break
					}
				}
				continue
			}
			seen[strings.clone(id, context.temp_allocator)] = true

			name := short_hex(id)
			resolved: cstring
			if marmot.display_name(client, member.member_id_hex, &resolved) == .OK && resolved != nil {
				name = string(resolved)
			}
			npub_str: string
			npub_c: cstring
			if marmot.npub(client, member.member_id_hex, &npub_c) == .OK && npub_c != nil {
				npub_str = strings.clone(string(npub_c))
				marmot.string_free(npub_c)
			}
			contact := Contact_Ui{
				id_hex  = strings.clone(id),
				name    = strings.clone(name),
				pic_url = strings.clone(profile_info(client, id).pic_url),
				npub    = npub_str,
			}
			append(&contact.groups, Common_Group{strings.clone(chat.title), int(members.len)})
			append(&ui.contacts, contact)
			marmot.string_free(resolved)
		}
	}

	load_follows(client, ui, seen)
}

// The account's NIP-02 follows, merged into the contact list: someone
// followed but never chatted with is still a contact, and only a
// followed contact can be removed (sharing a group is not something
// unfollowing can undo).
@(private = "file")
load_follows :: proc(client: ^marmot.Client, ui: ^Ui_State, seen: map[string]bool) {
	follows: ^marmot.String_List
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.account_follows(client, account, &follows) != .OK || follows == nil {
		return
	}
	defer marmot.string_list_free(follows)

	for i in 0 ..< follows.len {
		if follows.items[i] == nil {
			continue
		}
		id := string(follows.items[i])
		if id == ui.account_ref {
			continue // following yourself is not a contact
		}
		if seen[id] {
			for &existing in ui.contacts {
				if existing.id_hex == id {
					existing.followed = true
					break
				}
			}
			continue
		}

		name := short_hex(id)
		resolved: cstring
		if marmot.display_name(client, follows.items[i], &resolved) == .OK && resolved != nil {
			name = string(resolved)
		}
		npub_str: string
		npub_c: cstring
		if marmot.npub(client, follows.items[i], &npub_c) == .OK && npub_c != nil {
			npub_str = strings.clone(string(npub_c))
			marmot.string_free(npub_c)
		}
		append(
			&ui.contacts,
			Contact_Ui {
				id_hex = strings.clone(id),
				name = strings.clone(name),
				pic_url = strings.clone(profile_info(client, id).pic_url),
				npub = npub_str,
				followed = true,
			},
		)
		marmot.string_free(resolved)
	}
}

load_profile :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	if ui.profile.loaded {
		return
	}
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	npub: cstring
	if marmot.npub(client, account, &npub) == .OK && npub != nil {
		ui.profile.npub = strings.clone(string(npub))
		marmot.string_free(npub)
	}
	name: cstring
	if marmot.display_name(client, account, &name) == .OK && name != nil {
		ui.profile.name = strings.clone(string(name))
		marmot.string_free(name)
	}

	// Full kind-0 metadata for the viewer rows (handle, nip05, lud16).
	meta: ^marmot.User_Profile_Metadata
	if marmot.user_profile(client, account, &meta) == .OK && meta != nil {
		if meta.name != nil {
			ui.profile.username = strings.clone(string(meta.name))
		}
		if meta.about != nil {
			ui.profile.about = strings.clone(string(meta.about))
		}
		if meta.nip05 != nil {
			ui.profile.nip05 = strings.clone(string(meta.nip05))
		}
		if meta.lud16 != nil {
			ui.profile.lud16 = strings.clone(string(meta.lud16))
		}
		ui.profile.pic_set = meta.picture != nil && len(string(meta.picture)) > 0
		marmot.user_profile_metadata_free(meta)
	}

	// Own deep-link QR, shown inline on the profile page. Kept across
	// soft reloads (npub never changes); account switches zero the
	// struct, so a fresh one is cut then.
	if ui.profile.qr == nil && len(ui.profile.npub) > 0 {
		ui.profile.qr = qr_texture(ui.profile.npub)
	}

	relays: ^marmot.String_List
	if marmot.account_nip65_relays(client, account, &relays) == .OK {
		for i in 0 ..< relays.len {
			append(&ui.profile.nip65, strings.clone(string(relays.items[i])))
		}
		marmot.string_list_free(relays)
	}
	inbox: ^marmot.String_List
	if marmot.account_inbox_relays(client, account, &inbox) == .OK {
		for i in 0 ..< inbox.len {
			append(&ui.profile.inbox, strings.clone(string(inbox.items[i])))
		}
		marmot.string_list_free(inbox)
	}
	ui.profile.loaded = true
}

// Nav clicks, settings chips, profile actions, account switching.
