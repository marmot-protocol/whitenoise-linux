use crate::*;

/// One cross-chat search hit, collected on the backend runtime before the
/// UI-thread row build joins chat metadata and avatar colors.
struct GlobalHit {
    group_id: String,
    message_id: String,
    sender_id: String,
    text: String,
    recorded_at: u64,
}

// Hits shown under the chat list; the scan itself is unbounded but only the
// newest hits render (Slint gets a plain capped model, and 50 cards is
// already ~5 panel-heights of scroll).
const GLOBAL_HIT_LIMIT: usize = 50;

/// Cross-chat message search behind the chat-list search field. Each edit
/// bumps the generation and schedules a debounced full-history scan of every
/// visible chat on the backend runtime (same shape as the mentions-inbox
/// refresh); the newest `GLOBAL_HIT_LIMIT` fuzzy matches come back as
/// mention-card rows. Selecting a hit rides the mention-inbox navigation
/// path (pending jump + chat select), which centers the target message even
/// when it's outside the loaded window.
pub(crate) fn wire_search(ui: &DarkMatterLinux, cx: &Cx) {
    let Cx {
        backend_cell,
        group_ids,
        ..
    } = cx.clone();

    static GLOBAL_SEARCH_GENERATION: AtomicUsize = AtomicUsize::new(0);

    ui.global::<AppState>().on_msg_global_query_changed({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let generation = GLOBAL_SEARCH_GENERATION.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            let tokens = query_tokens(&query);
            if tokens.is_empty() {
                ui.set_msg_global_results(model(Vec::<SearchHit>::new()));
                ui.set_msg_global_searching(false);
                return;
            }
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            ui.set_msg_global_searching(true);
            let identity_epoch = account_epoch();
            let account_id = backend.account().account_id_hex.clone();
            let ids = group_ids.lock().unwrap().clone();
            let current_group_ids = group_ids.clone();
            let weak = ui.as_weak();
            let b = backend.clone();
            backend.tokio_handle().spawn(async move {
                // Debounce: a full-history scan of every chat is too heavy to
                // run per keystroke, so only the edit that survives a typing
                // pause scans; superseded generations return here.
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                if GLOBAL_SEARCH_GENERATION.load(AtomicOrdering::Relaxed) != generation {
                    return;
                }
                let mut hits: Vec<GlobalHit> = Vec::new();
                for group_hex in &ids {
                    let records = match b.messages(group_hex, None) {
                        Ok(records) => records,
                        Err(error) => {
                            tracing::warn!(target: "search", %group_hex, "global search read failed: {error:#}");
                            continue;
                        }
                    };
                    let edits = aggregate_edits(&records);
                    let deletes = aggregate_deletes(&records);
                    for m in records.iter().filter(|m| is_visible_chat_message(m)) {
                        if deletes.contains(&m.message_id_hex) {
                            continue;
                        }
                        let text = edits
                            .get(&m.message_id_hex)
                            .filter(|edit| edit.count() > 0)
                            .map(|edit| edit.text().to_string())
                            .unwrap_or_else(|| m.plaintext.clone());
                        if matches_tokens(&text, &tokens) {
                            hits.push(GlobalHit {
                                group_id: group_hex.clone(),
                                message_id: m.message_id_hex.clone(),
                                sender_id: m.sender.clone(),
                                text,
                                recorded_at: m.recorded_at,
                            });
                        }
                    }
                }
                hits.sort_by(|a, b| b.recorded_at.cmp(&a.recorded_at));
                hits.truncate(GLOBAL_HIT_LIMIT);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    if GLOBAL_SEARCH_GENERATION.load(AtomicOrdering::Relaxed) != generation
                        || account_epoch() != identity_epoch
                        || !b.account().account_id_hex.eq_ignore_ascii_case(&account_id)
                    {
                        return;
                    }
                    // Join chat metadata by stable group id on the UI thread
                    // (a chat that vanished mid-scan just drops its hits).
                    let current_ids = current_group_ids.lock().unwrap().clone();
                    let chats = ui.get_chats();
                    // Senders whose profile picture isn't cached yet: fetched
                    // below after the rows land, then bound in place by
                    // sender id (same shape as the bubble-avatar pipeline).
                    let mut pending_fetches: HashMap<String, String> = HashMap::new();
                    let items: Vec<SearchHit> = hits
                        .into_iter()
                        .filter_map(|hit| {
                            let chat_index = current_ids
                                .iter()
                                .position(|group| group.eq_ignore_ascii_case(&hit.group_id))?;
                            let chat = chats.row_data(chat_index)?;
                            let (sender_name, picture_url) =
                                b.account_name_and_picture(&hit.sender_id);
                            let (sender_a, sender_b, sender_initials) = avatar_for(&sender_name);
                            let (picture, has_picture) =
                                bind_cached_picture(picture_url.as_deref());
                            if !has_picture {
                                if let Some(url) =
                                    picture_url.as_deref().map(str::trim).filter(|u| !u.is_empty())
                                {
                                    pending_fetches
                                        .entry(hit.sender_id.clone())
                                        .or_insert_with(|| url.to_string());
                                }
                            }
                            let (text_pre, text_match, text_post) =
                                snippet_parts(&hit.text, &tokens);
                            Some(SearchHit {
                                group_id: s(&hit.group_id),
                                message_id: s(&hit.message_id),
                                sender_id: s(&hit.sender_id),
                                chat_name: chat.name,
                                sender_name: s(&sender_name),
                                sender_initials: s(&sender_initials),
                                sender_a,
                                sender_b,
                                picture,
                                has_picture,
                                text_pre: s(&text_pre),
                                text_match: s(&text_match),
                                text_post: s(&text_post),
                                stamp: s(&format_date_unix(hit.recorded_at)),
                            })
                        })
                        .collect();
                    ui.set_msg_global_results(model(items));
                    ui.set_msg_global_searching(false);
                    // Fetch the missing pictures and bind each onto every hit
                    // row from that sender once decoded.
                    for (sender_id, url) in pending_fetches {
                        spawn_picture_fetch(
                            ui.as_weak(),
                            b.tokio_handle(),
                            url,
                            move |ui, pixels| {
                                bind_picture_to_rows(
                                    &ui.get_msg_global_results(),
                                    pixels,
                                    false,
                                    |row: &SearchHit| row.sender_id.as_str() == sender_id,
                                    |row, img| {
                                        row.picture = img;
                                        row.has_picture = true;
                                    },
                                );
                            },
                        );
                    }
                });
            });
        }
    });

    ui.global::<AppState>().on_msg_global_result_selected({
        let weak = ui.as_weak();
        move |group_id, message_id| {
            let Some(ui) = weak.upgrade() else { return };
            // Same navigation as a mention-inbox click: stash the pending
            // jump, switch to the chat, and center the target message.
            ui.global::<AppState>()
                .invoke_mention_inbox_selected(group_id, message_id);
        }
    });
}
