use crate::*;

/// Live state of the in-conversation search bar. `matches` holds the message
/// ids of every hit, newest first (so `pos` 1 is the most recent match — the
/// counter reads "1/N" when a search lands). Guarded by a generation counter
/// so a scan that returns after the user kept typing (or closed the bar) is
/// dropped instead of clobbering the newer state.
#[derive(Default)]
struct MsgSearchState {
    group_hex: String,
    matches: Vec<String>,
    pos: usize,
}

pub(crate) fn wire_chats(ui: &DarkMatterLinux, cx: &Cx, h: &Handlers) {
    let Cx {
        notif,
        settings_cell,
        backend_cell,
        group_ids,
        archived_group_ids,
        pending_state,
        active_message_watcher,
        ..
    } = cx.clone();
    let Handlers {
        refresh_breadcrumb,
        refresh_all_chat_models,
        ..
    } = h.clone();
    // Live chat-list filter: recompute one case-insensitive match flag per chat
    // row as the user types in the header search field (Slint has no substring
    // match). Matches on the chat name only. The flags are only consulted while
    // the query is non-empty, so the empty-query case (which shows everything)
    // needn't clear the array.
    ui.global::<AppState>().on_chat_search_changed({
        let weak = ui.as_weak();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let q = query.trim().to_lowercase();
            if q.is_empty() {
                ui.set_chat_match_flags(model(Vec::<bool>::new()));
                return;
            }
            let flags: Vec<bool> = ui
                .get_chats()
                .iter()
                .map(|c| c.name.to_lowercase().contains(&q))
                .collect();
            ui.set_chat_match_flags(model(flags));
        }
    });
    ui.global::<AppState>().on_new_chat_requested({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_new_chat(true);
            }
        }
    });
    ui.global::<AppState>().on_modal_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_new_chat(false);
                ui.set_new_chat_name(s(""));
                ui.set_new_chat_members(s(""));
                ui.set_new_chat_status(s(""));
                ui.set_new_chat_busy(false);
            }
        }
    });
    ui.global::<AppState>().on_start_chat({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |name, members_text| {
            let Some(ui) = weak.upgrade() else { return };
            let name = name.to_string();
            let members = parse_member_list(&members_text);
            if members.is_empty() {
                ui.set_new_chat_status(error_copy().add_npub.into());
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_new_chat_status(error_copy().backend_not_ready.into());
                return;
            };
            // Skip the creator's own npub if it leaked into the input —
            // marmot rejects self-invites.
            let me_npub = npub_for_account_id(&b.account().account_id_hex).ok();
            let members: Vec<String> = members
                .into_iter()
                .filter(|m| {
                    me_npub
                        .as_deref()
                        .map(|n| !m.eq_ignore_ascii_case(n))
                        .unwrap_or(true)
                })
                .collect();
            if members.is_empty() {
                ui.set_new_chat_status(error_copy().only_yourself.into());
                return;
            }
            ui.set_new_chat_busy(true);
            ui.set_new_chat_status(s(""));
            let group_name = if name.trim().is_empty() && members.len() == 1 {
                String::new()
            } else if name.trim().is_empty() {
                "New group".to_string()
            } else {
                name.trim().to_string()
            };
            // `create_group` fetches key packages and publishes welcomes —
            // relay round-trips, so a worker does them while the busy state
            // paints.
            let weak = weak.clone();
            let group_ids = group_ids.clone();
            std::thread::spawn(move || {
                let result = b.create_group(&group_name, &members);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_new_chat_busy(false);
                    match result {
                        Ok(group_id) => {
                            let group_hex = hex::encode(group_id.as_slice());
                            // Select the freshly-created chat in the continuation,
                            // once the refreshed snapshot is applied. The runtime
                            // appends it to the visible-chats projection
                            // synchronously after create_group resolves, so it
                            // should be present.
                            refresh_chats_async(&ui, &b, &group_ids, move |ui, _b, snap| {
                                let pos = snap
                                    .records
                                    .iter()
                                    .position(|r| r.group_id_hex.eq_ignore_ascii_case(&group_hex));
                                if let Some(pos) = pos {
                                    ui.set_active_chat(pos as i32);
                                    ui.global::<AppState>().invoke_chat_selected(pos as i32);
                                }
                            });
                            ui.set_new_chat_name(s(""));
                            ui.set_new_chat_members(s(""));
                            ui.set_new_chat_status(s(""));
                            ui.set_show_new_chat(false);
                        }
                        Err(e) => {
                            tracing::warn!(target: "create_group", "{e:#}");
                            ui.set_new_chat_status(friendly_error(ErrorOp::CreateChat, &e).into());
                        }
                    }
                });
            });
        }
    });
    // One-shot target used by the global mentions inbox. The normal chat
    // selection path consumes it, scans that chat off the UI thread, then asks
    // Slint to render a MESSAGE_WINDOW-sized slice around the target row.
    let pending_message_jump: Arc<Mutex<Option<(String, String)>>> = Arc::new(Mutex::new(None));
    let chat_load_generation = Arc::new(AtomicUsize::new(0));
    ui.global::<AppState>().on_chat_selected({
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let active_watcher = active_message_watcher.clone();
        let pending_state = pending_state.clone();
        let notif = notif.clone();
        let settings_cell = settings_cell.clone();
        let pending_message_jump = pending_message_jump.clone();
        let chat_load_generation = chat_load_generation.clone();
        move |idx| {
            let generation =
                chat_load_generation.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            let identity_epoch = account_epoch();
            if let Some(ui) = weak.upgrade() {
                // Search state is per-conversation: switching threads closes
                // the bar. A same-chat re-select (the off-window match jump
                // re-fires chat_selected on the active chat) keeps it open.
                if ui.get_active_chat() != idx && ui.get_msg_search_open() {
                    ui.set_msg_search_open(false);
                    ui.global::<AppState>().invoke_msg_search_closed();
                }
                // Persist the outgoing chat's half-written draft before the
                // switch, so it's there when the user comes back (and, via the
                // settings file, after a restart). Skipped while editing — the
                // composer then holds an in-progress edit, not a draft.
                if ui.get_editing_message_id().is_empty() {
                    let prev_idx = ui.get_active_chat();
                    let prev_hex = group_ids.lock().unwrap().get(prev_idx as usize).cloned();
                    if let Some(prev_hex) = prev_hex {
                        let mut st = settings_cell.borrow_mut();
                        if st.set_draft(&prev_hex, &ui.get_composer_draft()) {
                            st.save();
                        }
                    }
                }
                ui.set_active_chat(idx);
                // Reply targets and an in-progress edit are per-chat; switching
                // threads should not leak a stale "Replying to …" / "Editing …"
                // banner across conversations (and the abandoned edit must clear
                // so the restored draft below isn't masked by it).
                clear_reply_target(&ui);
                ui.set_editing_message_id(s(""));
                refresh();
                let Some(backend) = backend_cell.lock().unwrap().clone() else {
                    return;
                };
                let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
                // Reflect this chat's mute state in the header bell.
                ui.set_active_chat_muted(group_hex.as_deref().is_some_and(|g| notif.is_muted(g)));
                if let Some(group_hex) = group_hex {
                    let jump_message_id = {
                        let mut pending = pending_message_jump.lock().unwrap();
                        if pending
                            .as_ref()
                            .is_some_and(|(group, _)| group.eq_ignore_ascii_case(&group_hex))
                        {
                            pending.take().map(|(_, message)| message)
                        } else {
                            None
                        }
                    };
                    ui.set_messages_loading(true);
                    ui.set_messages_has_older(false);
                    let t_switch = std::time::Instant::now();
                    // Restore this chat's saved draft (empty if none), so a
                    // half-written message reappears exactly where it was left.
                    ui.set_composer_draft(s(settings_cell.borrow().draft(&group_hex)));
                    // Mark the chat read: advance its read marker to now, clear
                    // its unread, persist the marker (so backlog that arrives
                    // while the app is closed surfaces as unread next launch),
                    // and clear the row's badge optimistically. Persisting on
                    // open is what makes the read state authoritative.
                    let now = now_unix_secs() as i64;
                    unread_state().set_marker(&group_hex, now);
                    unread_state().set_count(&group_hex, 0);
                    {
                        let mut st = settings_cell.borrow_mut();
                        st.last_selected_chat = Some(group_hex.clone());
                        st.last_read.insert(group_hex.clone(), now);
                        st.save();
                    }
                    clear_chat_unread_row(&ui, idx as usize);
                    refresh_unread_chrome(&ui);
                    // Re-entering a normal chat starts from the default window.
                    // A mention jump deliberately scans full history so even an
                    // old target can be centered without repeated pagination.
                    if jump_message_id.is_none() {
                        msg_window_reset(&group_hex);
                    }
                    ui.set_show_chat_members(false);
                    push_group_members_to_ui_async(&ui, &backend, &group_hex);
                    // Snapshot read rides the backend runtime (sqlite can
                    // stall behind sync writes or a slow disk); rows are
                    // built back on the UI thread, merged with any pending
                    // overlay so chat switching doesn't drop pending bubbles.
                    let my_id = backend.account().account_id_hex.clone();
                    let weak = ui.as_weak();
                    let backend_cell = backend_cell.clone();
                    let pending_state = pending_state.clone();
                    let active_watcher = active_watcher.clone();
                    let current_group_ids = group_ids.clone();
                    let chat_load_generation = chat_load_generation.clone();
                    let b = backend.clone();
                    backend.tokio_handle().spawn(async move {
                        // The rebuild resolves mention chips and member "@"
                        // prefixes from this registration; the concurrent
                        // members-panel fetch may land later.
                        warm_group_mentions(&b, &group_hex);
                        let limit = jump_message_id
                            .as_ref()
                            .map_or_else(|| Some(msg_window_for(&group_hex)), |_| None);
                        let result = b.messages(&group_hex, limit);
                        let _ = slint::invoke_from_event_loop(move || {
                            let Some(ui) = weak.upgrade() else { return };
                            if chat_load_generation.load(AtomicOrdering::Relaxed) != generation
                                || account_epoch() != identity_epoch
                                || !b.account().account_id_hex.eq_ignore_ascii_case(&my_id)
                            {
                                return;
                            }
                            let current_idx = current_group_ids
                                .lock()
                                .unwrap()
                                .iter()
                                .position(|group| group.eq_ignore_ascii_case(&group_hex));
                            let Some(current_idx) = current_idx else { return };
                            if ui.get_active_chat() as usize != current_idx {
                                return;
                            }
                            let mut msgs = match result {
                                Ok(msgs) => msgs,
                                Err(error) => {
                                    tracing::warn!(target: "mentions", %group_hex, "mention target load failed: {error:#}");
                                    let chats_messages = ui.get_chats_messages();
                                    with_inner_messages(&chats_messages, current_idx, |messages| {
                                        messages.set_vec(Vec::new());
                                    });
                                    ui.set_messages_loading(false);
                                    return;
                                }
                            };
                            let deleted_messages = aggregate_deletes(&msgs);
                            let mut jump_target_exists = jump_message_id.as_ref().is_some_and(|id| {
                                msgs.iter().any(|message| {
                                    message.message_id_hex.eq_ignore_ascii_case(id)
                                        && is_visible_chat_message(message)
                                        && !deleted_messages.contains(&message.message_id_hex)
                                })
                            });
                            if let Some(message_id) = jump_message_id.as_ref().filter(|_| jump_target_exists) {
                                if let Some((window, recent_limit)) =
                                    mention_navigation_window(&msgs, message_id, MESSAGE_WINDOW)
                                {
                                    msg_window_set(&group_hex, recent_limit);
                                    msgs = window;
                                } else {
                                    jump_target_exists = false;
                                }
                            }
                            let chats_messages = ui.get_chats_messages();
                            {
                                let overlay = pending_state.lock().unwrap();
                                rebuild_chat_messages_from(
                                    &b,
                                    &overlay,
                                    &chats_messages,
                                    current_idx,
                                    &group_hex,
                                    &msgs,
                                );
                            }
                            spawn_message_avatar_fetches(&ui, &b, &msgs);
                            tracing::debug!(
                                target: "switch_timing", "chat {current_idx}: {} records rebuilt in {:?}",
                                msgs.len(),
                                t_switch.elapsed()
                            );
                            ui.set_messages_loading(false);
                            ui.set_messages_has_older(
                                jump_message_id.is_none() && msgs.len() >= MESSAGE_WINDOW,
                            );
                            if jump_target_exists {
                                let message_id = jump_message_id.as_ref().unwrap();
                                // Row index within the freshly built row model:
                                // the virtualized list scrolls near it first,
                                // then centers exactly once the row
                                // instantiates. Indexing the rows (not the
                                // records) keeps visibility filtering and
                                // pending-overlay rows accounted for.
                                let jump_index = ui
                                    .get_chats_messages()
                                    .row_data(current_idx)
                                    .and_then(|rows| {
                                        rows.iter().position(|row| {
                                            row.message_id.eq_ignore_ascii_case(message_id)
                                        })
                                    })
                                    .map(|idx| idx as i32)
                                    .unwrap_or(-1);
                                ui.set_message_jump_index(jump_index);
                                ui.set_message_jump_id(s(message_id));
                                ui.set_message_jump_tick(ui.get_message_jump_tick() + 1);
                            } else {
                                if let Some(message_id) = jump_message_id.as_ref() {
                                    tracing::warn!(target: "mentions", %group_hex, %message_id, "mention target no longer exists");
                                }
                                // Normal opens and stale mention targets land on
                                // the most recent message.
                                ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
                            }
                            // Attach a live watcher after the rebuild. Abort the
                            // previous one so rapid switches cannot stack them.
                            if let Some(prev) = active_watcher.lock().unwrap().take() {
                                prev.abort();
                            }
                            let handle = install_message_watcher(
                                &b,
                                ui.as_weak(),
                                backend_cell.clone(),
                                pending_state.clone(),
                                group_hex,
                                current_idx,
                                my_id,
                            );
                            *active_watcher.lock().unwrap() = Some(handle);
                        });
                    });
                } else {
                    ui.set_messages_loading(false);
                }
            }
        }
    });

    // Refresh on demand when the popup opens. Keeping this lazy avoids one
    // full-history query per chat during normal message traffic.
    ui.global::<AppState>().on_mention_inbox_opened({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                ui.set_mention_inbox_loading(false);
                return;
            };
            crate::mentions::refresh_mention_inbox_async(&ui, &backend, &group_ids);
        }
    });

    ui.global::<AppState>().on_mention_inbox_selected({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let pending_message_jump = pending_message_jump.clone();
        move |group_id, message_id| {
            let Some(ui) = weak.upgrade() else { return };
            let group_id = group_id.to_string();
            let message_id = message_id.to_string();
            let idx = group_ids
                .lock()
                .unwrap()
                .iter()
                .position(|group| group.eq_ignore_ascii_case(&group_id));
            let Some(idx) = idx else {
                tracing::warn!(target: "mentions", %group_id, "mention target chat is no longer visible");
                return;
            };
            *pending_message_jump.lock().unwrap() = Some((group_id, message_id));
            ui.set_message_jump_id(s(""));
            ui.set_active_page(Page::Chats as i32);
            ui.global::<AppState>().invoke_chat_selected(idx as i32);
        }
    });

    // ─── In-conversation search ────────────────────────────────────────
    // Fuzzy full-history search within the open chat (whitenoise-style
    // forward-order token matching, see msg_search.rs). Each query edit
    // rescans off the UI thread; stepping re-fires the message-jump
    // machinery, and a match outside the loaded window goes through the
    // same pending-jump + window-recenter path the mentions inbox uses.
    let msg_search: Arc<Mutex<MsgSearchState>> = Arc::new(Mutex::new(Default::default()));
    let msg_search_generation = Arc::new(AtomicUsize::new(0));
    // Center a match: direct jump when the row is in the loaded window,
    // otherwise reload the chat with a window centered on the target.
    // Captures no UI handle, so the async query path can carry it across
    // threads and call it back on the event loop.
    let msg_search_jump: MessageJumpFn = {
        let pending_message_jump = pending_message_jump.clone();
        Arc::new(
            move |ui: &DarkMatterLinux, group_hex: &str, message_id: &str| {
                let chats_messages = ui.get_chats_messages();
                let idx = ui.get_active_chat();
                let row = with_inner_messages(&chats_messages, idx as usize, |vm| {
                    find_message_row(vm, message_id)
                })
                .flatten();
                if let Some(row) = row {
                    ui.set_message_jump_index(row as i32);
                    ui.set_message_jump_id(s(message_id));
                    ui.set_message_jump_tick(ui.get_message_jump_tick() + 1);
                } else {
                    *pending_message_jump.lock().unwrap() =
                        Some((group_hex.to_string(), message_id.to_string()));
                    ui.set_message_jump_id(s(""));
                    ui.global::<AppState>().invoke_chat_selected(idx);
                }
            },
        )
    };

    ui.global::<AppState>().on_msg_search_query_changed({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let msg_search = msg_search.clone();
        let msg_search_generation = msg_search_generation.clone();
        let msg_search_jump = msg_search_jump.clone();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let generation = msg_search_generation.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            let tokens = query_tokens(&query);
            if tokens.is_empty() {
                *msg_search.lock().unwrap() = Default::default();
                ui.set_msg_search_count(0);
                ui.set_msg_search_pos(0);
                ui.set_message_jump_id(s(""));
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            let weak = ui.as_weak();
            let group_ids = group_ids.clone();
            let msg_search = msg_search.clone();
            let msg_search_generation = msg_search_generation.clone();
            let msg_search_jump = msg_search_jump.clone();
            let b = backend.clone();
            backend.tokio_handle().spawn(async move {
                // Full-history scan (like the mentions inbox) so even an old
                // match is steppable without manual pagination. Edits replace
                // the original text; deleted messages never match.
                let records = b.messages(&group_hex, None).unwrap_or_default();
                let edits = aggregate_edits(&records);
                let deletes = aggregate_deletes(&records);
                let matches: Vec<String> = records
                    .iter()
                    .filter(|m| is_visible_chat_message(m))
                    .filter(|m| !deletes.contains(&m.message_id_hex))
                    .filter(|m| {
                        let text = edits
                            .get(&m.message_id_hex)
                            .filter(|edit| edit.count() > 0)
                            .map(|edit| edit.text().to_string())
                            .unwrap_or_else(|| m.plaintext.clone());
                        matches_tokens(&text, &tokens)
                    })
                    // Newest first: position 1 is the most recent match.
                    .rev()
                    .map(|m| m.message_id_hex.clone())
                    .collect();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    if msg_search_generation.load(AtomicOrdering::Relaxed) != generation {
                        return;
                    }
                    // The chat may have switched while the scan ran.
                    let still_active = group_ids
                        .lock()
                        .unwrap()
                        .get(ui.get_active_chat() as usize)
                        .is_some_and(|g| g.eq_ignore_ascii_case(&group_hex));
                    if !still_active {
                        return;
                    }
                    let count = matches.len();
                    let first = matches.first().cloned();
                    *msg_search.lock().unwrap() = MsgSearchState {
                        group_hex: group_hex.clone(),
                        matches,
                        pos: if count > 0 { 1 } else { 0 },
                    };
                    ui.set_msg_search_count(count as i32);
                    ui.set_msg_search_pos(if count > 0 { 1 } else { 0 });
                    if let Some(id) = first {
                        msg_search_jump(&ui, &group_hex, &id);
                    } else {
                        ui.set_message_jump_id(s(""));
                    }
                });
            });
        }
    });

    ui.global::<AppState>().on_msg_search_step({
        let weak = ui.as_weak();
        let msg_search = msg_search.clone();
        let msg_search_jump = msg_search_jump.clone();
        move |newer| {
            let Some(ui) = weak.upgrade() else { return };
            let (id, pos, group_hex) = {
                let mut st = msg_search.lock().unwrap();
                let len = st.matches.len();
                if len == 0 {
                    return;
                }
                // Matches are newest-first, so "newer" walks toward position
                // 1 and "older" away from it; both directions wrap.
                st.pos = if newer {
                    if st.pos <= 1 { len } else { st.pos - 1 }
                } else if st.pos >= len {
                    1
                } else {
                    st.pos + 1
                };
                (st.matches[st.pos - 1].clone(), st.pos, st.group_hex.clone())
            };
            ui.set_msg_search_pos(pos as i32);
            msg_search_jump(&ui, &group_hex, &id);
        }
    });

    ui.global::<AppState>().on_msg_search_closed({
        let weak = ui.as_weak();
        let msg_search = msg_search.clone();
        let msg_search_generation = msg_search_generation.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            // Invalidate any in-flight scan before dropping the state.
            msg_search_generation.fetch_add(1, AtomicOrdering::Relaxed);
            *msg_search.lock().unwrap() = Default::default();
            ui.set_msg_search_open(false);
            ui.set_msg_search_count(0);
            ui.set_msg_search_pos(0);
            ui.set_message_jump_id(s(""));
        }
    });

    // "Load earlier messages" at the top of the messages view: grow the
    // active chat's record window one MESSAGE_WINDOW step and rebuild. The
    // Slint side anchors the scroll so the content the user was reading
    // stays put under the newly-prepended history.
    ui.global::<AppState>().on_messages_request_older({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let pending_state = pending_state.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            let new_window = msg_window_expand(&group_hex);
            // Expanded-window read on the backend runtime; rows built back on
            // the UI thread. The Slint side anchors the scroll, so the rows
            // landing a beat later keeps the content under the user.
            let weak = ui.as_weak();
            let pending_state = pending_state.clone();
            let b = backend.clone();
            backend.tokio_handle().spawn(async move {
                let msgs = b
                    .messages(&group_hex, Some(msg_window_for(&group_hex)))
                    .unwrap_or_default();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    let chats_messages = ui.get_chats_messages();
                    {
                        let overlay = pending_state.lock().unwrap();
                        rebuild_chat_messages_from(
                            &b,
                            &overlay,
                            &chats_messages,
                            idx,
                            &group_hex,
                            &msgs,
                        );
                    }
                    spawn_message_avatar_fetches(&ui, &b, &msgs);
                    if ui.get_active_chat() as usize == idx {
                        // Fewer records than asked for → the full history is
                        // loaded.
                        ui.set_messages_has_older(msgs.len() >= new_window);
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_archive_selected({
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let backend_cell = backend_cell.clone();
        let archived_group_ids = archived_group_ids.clone();
        move |idx| {
            if let Some(ui) = weak.upgrade() {
                ui.set_active_archived(idx);
                refresh();
                let Some(backend) = backend_cell.lock().unwrap().clone() else {
                    return;
                };
                let hex = archived_group_ids
                    .lock()
                    .unwrap()
                    .get(idx as usize)
                    .cloned();
                if let Some(group_hex) = hex {
                    push_group_members_to_ui_async(&ui, &backend, &group_hex);
                }
            }
        }
    });
    ui.global::<AppState>().on_members_toggle_clicked({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_chat_members(!ui.get_show_chat_members());
            }
        }
    });

    // ─── Chat-request + archive actions ───────────────────────────────
    // Resolve the active chat's group hex from `group_ids` + active-chat,
    // run a backend op, then refresh both chat lists. Active-archived is
    // resolved via the archived snapshot so the index doesn't have to align
    // with `group_ids`.
    let active_chat_group_hex = {
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        move || -> Option<String> {
            let ui = weak.upgrade()?;
            let idx = ui.get_active_chat() as usize;
            group_ids.lock().unwrap().get(idx).cloned()
        }
    };

    ui.global::<AppState>().on_accept_chat_request({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let resolve = active_chat_group_hex.clone();
        let refresh = refresh_all_chat_models.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(group_hex) = resolve() else { return };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_backend_error(error_copy().not_connected.into());
                return;
            };
            // Accepting publishes to relays — worker; `refresh` captures only
            // Send handles, so a clone rides into the completion.
            let weak = weak.clone();
            let refresh = refresh.clone();
            std::thread::spawn(move || {
                let result = b.accept_group_invite(&group_hex);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    if let Err(e) = result {
                        tracing::warn!(target: "accept", "{e:#}");
                        ui.set_backend_error(friendly_error(ErrorOp::Accept, &e).into());
                        return;
                    }
                    refresh();
                });
            });
        }
    });

    ui.global::<AppState>().on_block_chat_request({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let resolve = active_chat_group_hex.clone();
        let refresh = refresh_all_chat_models.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(group_hex) = resolve() else { return };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_backend_error(error_copy().not_connected.into());
                return;
            };
            let weak = weak.clone();
            let refresh = refresh.clone();
            std::thread::spawn(move || {
                let result = b.decline_group_invite(&group_hex);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    if let Err(e) = result {
                        tracing::warn!(target: "block", "{e:#}");
                        ui.set_backend_error(friendly_error(ErrorOp::Block, &e).into());
                        return;
                    }
                    refresh();
                });
            });
        }
    });

    // ─── Archive / unarchive (optimistic) ──────────────────────────────
    //
    // `set_group_archived` is local-only (no relay traffic), but it still
    // sat behind a full chat-list rebuild — which scans every group and its
    // latest-message preview. On a busy account that's a perceptible hitch.
    // We do the visible work first: pull the row out of the chats model and
    // its parallel `group_ids` list, append an `ArchivedChat` entry to the
    // archived model, then let the backend catch up. On failure we put it
    // back where it was.
    ui.global::<AppState>().on_archive_chat({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let resolve = active_chat_group_hex.clone();
        let group_ids = group_ids.clone();
        let refresh = refresh_all_chat_models.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(group_hex) = resolve() else { return };

            // Locate the row in the chats model.
            let chats = ui.get_chats();
            let mut ids = group_ids.lock().unwrap();
            let Some(pos) = ids.iter().position(|g| g == &group_hex) else {
                return;
            };
            let Some(chats_vm) = chats.as_any().downcast_ref::<VecModel<ChatMeta>>() else {
                return;
            };
            let Some(removed_meta) = chats_vm.row_data(pos) else {
                return;
            };

            // 1. Optimistic UI mutation. Drop the chat row + its parallel
            //    messages model + its id. Append an `ArchivedChat` shaped
            //    from the existing ChatMeta so the archive page reflects it
            //    without waiting on a backend snapshot.
            chats_vm.remove(pos);
            let chats_messages = ui.get_chats_messages();
            if let Some(outer_vm) = chats_messages
                .as_any()
                .downcast_ref::<VecModel<ModelRc<ChatMessage>>>()
                && pos < outer_vm.row_count()
            {
                outer_vm.remove(pos);
            }
            ids.remove(pos);
            let archived_row = ArchivedChat {
                name: removed_meta.name.clone(),
                last_msg: removed_meta.preview.clone(),
                last_date: removed_meta.stamp.clone(),
                av_a: removed_meta.av_a,
                av_b: removed_meta.av_b,
                av_initials: removed_meta.av_initials.clone(),
                members: 0,
                group_id: removed_meta.npub.clone(),
                picture: removed_meta.picture.clone(),
                has_picture: removed_meta.has_picture,
            };
            if let Some(archived_vm) = ui
                .get_archived_chats()
                .as_any()
                .downcast_ref::<VecModel<ArchivedChat>>()
            {
                archived_vm.push(archived_row);
            }
            let new_len = chats_vm.row_count() as i32;
            if ui.get_active_chat() >= new_len {
                ui.set_active_chat((new_len - 1).max(0));
            }
            drop(ids);

            // 2. Commit on a worker thread — `set_group_archived` is a
            //    synchronous disk write. Posting it off the UI thread is
            //    the difference between "instant" and the perceptible hitch
            //    Danny saw. On failure we hop back, surface the error, and
            //    fall back to a full refresh to reconcile.
            let weak_cb = weak.clone();
            let backend_cell = backend_cell.clone();
            let group_hex_cb = group_hex.clone();
            let refresh_cb = refresh.clone();
            std::thread::spawn(move || {
                let res = {
                    let guard = backend_cell.lock().unwrap();
                    guard
                        .as_ref()
                        .map(|b| b.set_group_archived(&group_hex_cb, true))
                };
                if let Some(Err(e)) = res {
                    tracing::warn!(target: "archive", "{e:#}");
                    let refresh_cb = refresh_cb.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak_cb.upgrade() else { return };
                        ui.set_backend_error(friendly_error(ErrorOp::Archive, &e).into());
                        refresh_cb();
                    });
                }
            });
        }
    });

    ui.global::<AppState>().on_unarchive_chat({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let refresh = refresh_all_chat_models.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_archived() as usize;
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_backend_error(error_copy().not_connected.into());
                return;
            };

            // Resolve the real group id via the backend's archived snapshot
            // (a sqlite read — runtime, not UI thread). ArchivedChat.group_id
            // is `mls_row_key(group_id_hex)`, not the full hex, hence the round-trip.
            let weak = weak.clone();
            let group_ids = group_ids.clone();
            let refresh = refresh.clone();
            let backend_cell = backend_cell.clone();
            let b2 = b.clone();
            b.tokio_handle().spawn(async move {
                let Ok(records) = b2.archived_chats() else {
                    return;
                };
                let Some(record) = records.get(idx).cloned() else {
                    return;
                };
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    let my_id = b2.account().account_id_hex.clone();
                    // Unread starts at 0 on the optimistic unarchive row (no
                    // UI-thread message scan); the next chat-list snapshot
                    // recomputes it from the read marker.
                    let meta_from_record = chat_meta_from(&record, None, &my_id, &b2, 0);
                    let group_hex = record.group_id_hex.clone();

                    // 1. Optimistic: pop the archived row, push the chat back
                    //    into the chats model.
                    let archived_model = ui.get_archived_chats();
                    if let Some(vm) = archived_model
                        .as_any()
                        .downcast_ref::<VecModel<ArchivedChat>>()
                        && idx < vm.row_count()
                    {
                        vm.remove(idx);
                    }
                    if let Some(chats_vm) =
                        ui.get_chats().as_any().downcast_ref::<VecModel<ChatMeta>>()
                    {
                        chats_vm.push(meta_from_record);
                    }
                    if let Some(outer_vm) = ui
                        .get_chats_messages()
                        .as_any()
                        .downcast_ref::<VecModel<ModelRc<ChatMessage>>>()
                    {
                        outer_vm.push(ModelRc::new(VecModel::from(Vec::<ChatMessage>::new())));
                    }
                    {
                        let mut ids = group_ids.lock().unwrap();
                        ids.push(group_hex.clone());
                    }
                    let alen = archived_model.row_count() as i32;
                    if ui.get_active_archived() >= alen {
                        ui.set_active_archived((alen - 1).max(0));
                    }

                    // 2. Commit on a worker thread; reconcile with a full
                    //    refresh on failure.
                    let weak_cb = weak.clone();
                    let backend_cell = backend_cell.clone();
                    let group_hex_cb = group_hex.clone();
                    let refresh_cb = refresh.clone();
                    std::thread::spawn(move || {
                        let res = {
                            let guard = backend_cell.lock().unwrap();
                            guard
                                .as_ref()
                                .map(|b| b.set_group_archived(&group_hex_cb, false))
                        };
                        if let Some(Err(e)) = res {
                            tracing::warn!(target: "unarchive", "{e:#}");
                            let refresh_cb = refresh_cb.clone();
                            let _ = slint::invoke_from_event_loop(move || {
                                let Some(ui) = weak_cb.upgrade() else { return };
                                ui.set_backend_error(friendly_error(ErrorOp::Unarchive, &e).into());
                                refresh_cb();
                            });
                        }
                    });
                });
            });
        }
    });
}
