use crate::*;

// Shared attachment/album send spawners. Called from the messaging,
// forward, and offline-queue (extra.rs) wiring sections, so they live in
// their own chapter rather than at the bottom of one caller.

// Called by `on_send_message` for each staged attachment: insert the
// optimistic pending bubble, run the encrypted Blossom upload + kind-9
// publish, reconcile the bubble when the round-trip resolves.
//
// Thread-safety: `ModelRc` is `!Send`, so we never carry it across the
// tokio boundary — every closure that hops back to the UI re-fetches
// the model via `ui.get_chats_messages()`.
// `replay_temp_id` is `None` for a fresh send (allocate an id, render the
// pending bubble, persist a durable queue entry) and `Some(id)` when the
// reconnect flush re-dispatches an already-queued attachment using bytes read
// back from disk — in which case the overlay entry/bubble may already
// exist and the durable entry is already on disk.
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_attachment_send(
    weak: slint::Weak<DarkMatterLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
    group_hex: String,
    file_name: String,
    media_type: String,
    bytes: Vec<u8>,
    is_image: bool,
    local_preview: Option<PicturePixels>,
    replay_temp_id: Option<String>,
) {
    let size_bytes = bytes.len() as u64;
    let weak2 = weak;
    let backend_cell2 = backend_cell;
    let group_ids2 = group_ids;
    let pending_state2 = pending_state;
    let group_hex2 = group_hex;
    let file_name_u = file_name.clone();
    let media_type_u = media_type.clone();
    let bytes_for_queue = bytes.clone();
    let _ = slint::invoke_from_event_loop(move || {
        let Some(ui) = weak2.upgrade() else { return };
        let chats_messages = ui.get_chats_messages();
        let ids = group_ids2.lock().unwrap();
        let Some(idx) = ids.iter().position(|g| g == &group_hex2) else {
            return;
        };
        drop(ids);
        let guard = backend_cell2.lock().unwrap();
        let Some(backend) = guard.as_ref() else {
            return;
        };

        let is_replay = replay_temp_id.is_some();
        let temp_id = replay_temp_id.unwrap_or_else(next_temp_id);
        let send = PendingSend {
            temp_id: temp_id.clone(),
            text: String::new(),
            failed: false,
            reply_to: None,
            effect: 0,
            media: vec![PendingMedia {
                file_name: file_name_u.clone(),
                media_type: media_type_u.clone(),
                size_bytes,
                is_image,
                is_video: mime_is_video(&media_type_u),
                is_audio: mime_is_audio(&media_type_u),
                local_preview: local_preview.clone(),
            }],
        };
        // Render the pending bubble + insert the overlay entry only if it isn't
        // already present (a replay of an in-session offline failure keeps its
        // existing bubble; a boot replay has none yet).
        let already_present = pending_state2
            .lock()
            .unwrap()
            .find_send(&group_hex2, &temp_id)
            .is_some();
        if !already_present {
            {
                let mut overlay = pending_state2.lock().unwrap();
                overlay.add_send(&group_hex2, send.clone());
            }
            let my_id = backend.account().account_id_hex.clone();
            let my_label = my_avatar_label(backend, &my_id);
            let pending_row = pending_chat_message(&send, &my_id, &my_label);
            with_inner_messages(&chats_messages, idx, |vm| {
                push_message_grouped(vm, pending_row)
            });
            ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
        }
        // Durably queue this attachment on first send so it survives a restart.
        if !is_replay {
            let my_id = backend.account().account_id_hex.clone();
            offline_persist(
                &vault_cell,
                &offline_queue::QueuedSend {
                    temp_id: temp_id.clone(),
                    account_id_hex: my_id,
                    group_hex: group_hex2.clone(),
                    kind: offline_queue::QueuedKind::Attachment(offline_queue::QueuedMedia {
                        file_name: file_name_u.clone(),
                        media_type: media_type_u.clone(),
                        bytes: bytes_for_queue,
                        is_image,
                    }),
                    enqueued_at: offline_queue::now_secs(),
                },
            );
        }
        offline_inflight_insert(&temp_id);

        let weak3 = weak2.clone();
        let backend_cell3 = backend_cell2.clone();
        let group_ids3 = group_ids2.clone();
        let pending_state3 = pending_state2.clone();
        let group_hex3 = group_hex2.clone();
        let temp_id3 = temp_id.clone();
        let local_preview_done = local_preview.clone();
        backend.upload_media_async(
            &group_hex2,
            file_name,
            media_type,
            bytes,
            None,
            move |result| {
                let weak = weak3.clone();
                let backend_cell = backend_cell3.clone();
                let group_ids = group_ids3.clone();
                let pending_state = pending_state3.clone();
                let group_hex = group_hex3.clone();
                let temp_id = temp_id3.clone();
                let local_preview = local_preview_done.clone();
                // This upload has resolved — drop the in-flight guard.
                offline_inflight_remove(&temp_id);
                // Tokio worker — read the refreshed window HERE
                // so the invoke closure never touches sqlite. On failure also
                // poll connectivity so an offline failure stays queued + pending
                // rather than flipping the bubble red.
                let (all, online): (Vec<AppMessageRecord>, bool) = if result.is_ok() {
                    let all = backend_cell
                        .lock()
                        .unwrap()
                        .as_ref()
                        .map(|b| {
                            b.messages(&group_hex, Some(msg_window_for(&group_hex)))
                                .unwrap_or_default()
                        })
                        .unwrap_or_default();
                    (all, true)
                } else {
                    let online = backend_cell
                        .lock()
                        .unwrap()
                        .as_ref()
                        .map(|b| b.relay_health().0 > 0)
                        .unwrap_or(false);
                    (Vec::new(), online)
                };
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    let chats_messages = ui.get_chats_messages();
                    let ids = group_ids.lock().unwrap();
                    let Some(idx) = ids.iter().position(|g| g == &group_hex) else {
                        return;
                    };
                    drop(ids);

                    match result {
                        Ok(upload) => {
                            pending_state
                                .lock()
                                .unwrap()
                                .drop_send(&group_hex, &temp_id);
                            offline_queue::remove(&temp_id);
                            let guard = backend_cell.lock().unwrap();
                            let Some(backend) = guard.as_ref() else {
                                return;
                            };
                            let real_id = upload
                                .sent
                                .as_ref()
                                .and_then(|s| s.message_ids.first().cloned());
                            if let Some(id) = real_id.as_ref() {
                                // The uploader knows the plaintext size; the
                                // imeta tag doesn't carry one, so seed the
                                // session size cache before the confirmed row
                                // is built below.
                                attachment_size_put(id, size_bytes);
                            }
                            if let (Some(id), Some(p)) = (real_id.as_ref(), local_preview.as_ref())
                                && is_image
                            {
                                attachment_image_cache_put(id.clone(), p.clone());
                            }
                            let confirmed_row: Option<ChatMessage> =
                                real_id.as_deref().and_then(|id| {
                                    let rec =
                                        all.iter().find(|m| m.message_id_hex == id).cloned()?;
                                    let overlay = pending_state.lock().unwrap();
                                    let my_id = backend.account().account_id_hex.clone();
                                    let my_label = my_avatar_label(backend, &my_id);
                                    Some(build_one_message_row(
                                        &rec, &all, &my_id, &my_label, &group_hex, &overlay,
                                        backend,
                                    ))
                                });
                            let swapped = with_inner_messages(&chats_messages, idx, |vm| {
                                let Some(pos) = find_message_row(vm, &temp_id) else {
                                    return false;
                                };
                                if let Some(mut row) = confirmed_row {
                                    preserve_grouping_flags(vm, pos, &mut row);
                                    vm.set_row_data(pos, row);
                                } else {
                                    vm.remove(pos);
                                }
                                true
                            });
                            if swapped != Some(true) {
                                let overlay = pending_state.lock().unwrap();
                                rebuild_chat_messages_from(
                                    backend,
                                    &overlay,
                                    &chats_messages,
                                    idx,
                                    &group_hex,
                                    &all,
                                );
                            }
                        }
                        Err(e) => {
                            tracing::warn!(target: "attach", "upload: {e:#}");
                            if !online {
                                // Offline: keep the bubble pending + the entry
                                // queued for the reconnect flush.
                                tracing::warn!(target: "attach", "offline — left queued for flush");
                                return;
                            }
                            let mut overlay = pending_state.lock().unwrap();
                            overlay.mark_send_failed(&group_hex, &temp_id);
                            let failed = overlay.find_send(&group_hex, &temp_id);
                            drop(overlay);
                            if let Some(failed) = failed {
                                let guard = backend_cell.lock().unwrap();
                                let Some(backend) = guard.as_ref() else {
                                    return;
                                };
                                let my_id = backend.account().account_id_hex.clone();
                                let my_label = my_avatar_label(backend, &my_id);
                                let _ = with_inner_messages(&chats_messages, idx, |vm| {
                                    if let Some(pos) = find_message_row(vm, &temp_id) {
                                        vm.set_row_data(
                                            pos,
                                            pending_chat_message(&failed, &my_id, &my_label),
                                        );
                                    }
                                });
                            }
                        }
                    }
                });
            },
        );
    });
}

// Album send: all the images go out as ONE kind-9 message (multiple imeta
// tags) so the confirmed bubble renders a grid. Optimistic pending bubble
// shows the grid immediately from local previews; on ack we seed the
// attachment cache (per image, under `real_id#index`) so the confirmed grid
// shows the same pixels without a re-download, then swap the row. Mirrors
// `spawn_attachment_send`'s reconcile, generalized to N images.
// `replay_temp_id`: see `spawn_attachment_send` — `Some(id)` re-dispatches an
// already-queued album from disk on reconnect.
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_album_send(
    weak: slint::Weak<DarkMatterLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
    group_hex: String,
    files: Vec<StagedFile>,
    replay_temp_id: Option<String>,
) {
    let _ = slint::invoke_from_event_loop(move || {
        let Some(ui) = weak.upgrade() else { return };
        let chats_messages = ui.get_chats_messages();
        let Some(idx) = group_ids
            .lock()
            .unwrap()
            .iter()
            .position(|g| g == &group_hex)
        else {
            return;
        };
        let guard = backend_cell.lock().unwrap();
        let Some(backend) = guard.as_ref() else {
            return;
        };

        let is_replay = replay_temp_id.is_some();
        let temp_id = replay_temp_id.unwrap_or_else(next_temp_id);
        let media: Vec<PendingMedia> = files
            .iter()
            .map(|f| PendingMedia {
                file_name: f.file_name.clone(),
                media_type: f.media_type.clone(),
                size_bytes: f.bytes.len() as u64,
                is_image: true,
                is_video: false,
                is_audio: false,
                local_preview: f.preview.clone(),
            })
            .collect();
        let send = PendingSend {
            temp_id: temp_id.clone(),
            text: String::new(),
            failed: false,
            reply_to: None,
            media,
            effect: 0,
        };
        let already_present = pending_state
            .lock()
            .unwrap()
            .find_send(&group_hex, &temp_id)
            .is_some();
        if !already_present {
            pending_state
                .lock()
                .unwrap()
                .add_send(&group_hex, send.clone());
            let my_id = backend.account().account_id_hex.clone();
            let my_label = my_avatar_label(backend, &my_id);
            let pending_row = pending_chat_message(&send, &my_id, &my_label);
            with_inner_messages(&chats_messages, idx, |vm| {
                push_message_grouped(vm, pending_row)
            });
            ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
        }
        // Durably queue the album on first send (one entry, all images' bytes).
        if !is_replay {
            let my_id = backend.account().account_id_hex.clone();
            let queued_media: Vec<offline_queue::QueuedMedia> = files
                .iter()
                .map(|f| offline_queue::QueuedMedia {
                    file_name: f.file_name.clone(),
                    media_type: f.media_type.clone(),
                    bytes: f.bytes.clone(),
                    is_image: true,
                })
                .collect();
            offline_persist(
                &vault_cell,
                &offline_queue::QueuedSend {
                    temp_id: temp_id.clone(),
                    account_id_hex: my_id,
                    group_hex: group_hex.clone(),
                    kind: offline_queue::QueuedKind::Album(queued_media),
                    enqueued_at: offline_queue::now_secs(),
                },
            );
        }
        offline_inflight_insert(&temp_id);

        // Previews (kept in image order) seed the cache under the real id on
        // ack; `items` carry the dim "WxH" so receivers lay out the grid.
        let previews: Vec<Option<PicturePixels>> =
            files.iter().map(|f| f.preview.clone()).collect();
        let items: Vec<(String, String, Vec<u8>, Option<String>)> = files
            .into_iter()
            .map(|f| {
                let dim = f.preview.as_ref().map(|p| format!("{}x{}", p.w, p.h));
                (f.file_name, f.media_type, f.bytes, dim)
            })
            .collect();

        let weak3 = weak.clone();
        let backend_cell3 = backend_cell.clone();
        let group_ids3 = group_ids.clone();
        let pending_state3 = pending_state.clone();
        let group_hex3 = group_hex.clone();
        let temp_id3 = temp_id.clone();
        backend.upload_album_async(&group_hex, items, move |result| {
            let weak = weak3.clone();
            let backend_cell = backend_cell3.clone();
            let group_ids = group_ids3.clone();
            let pending_state = pending_state3.clone();
            let group_hex = group_hex3.clone();
            let temp_id = temp_id3.clone();
            offline_inflight_remove(&temp_id);
            let (all, online): (Vec<AppMessageRecord>, bool) = if result.is_ok() {
                let all = backend_cell
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|b| {
                        b.messages(&group_hex, Some(msg_window_for(&group_hex)))
                            .unwrap_or_default()
                    })
                    .unwrap_or_default();
                (all, true)
            } else {
                let online = backend_cell
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|b| b.relay_health().0 > 0)
                    .unwrap_or(false);
                (Vec::new(), online)
            };
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ui) = weak.upgrade() else { return };
                let chats_messages = ui.get_chats_messages();
                let Some(idx) = group_ids
                    .lock()
                    .unwrap()
                    .iter()
                    .position(|g| g == &group_hex)
                else {
                    return;
                };
                match result {
                    Ok(upload) => {
                        pending_state
                            .lock()
                            .unwrap()
                            .drop_send(&group_hex, &temp_id);
                        offline_queue::remove(&temp_id);
                        let guard = backend_cell.lock().unwrap();
                        let Some(backend) = guard.as_ref() else {
                            return;
                        };
                        let real_id = upload
                            .sent
                            .as_ref()
                            .and_then(|s| s.message_ids.first().cloned());
                        if let Some(id) = real_id.as_ref() {
                            for (i, p) in previews.iter().enumerate() {
                                if let Some(px) = p {
                                    attachment_image_cache_put(att_key(id, i), px.clone());
                                }
                            }
                        }
                        let confirmed_row: Option<ChatMessage> =
                            real_id.as_deref().and_then(|id| {
                                let rec = all.iter().find(|m| m.message_id_hex == id).cloned()?;
                                let overlay = pending_state.lock().unwrap();
                                let my_id = backend.account().account_id_hex.clone();
                                let my_label = my_avatar_label(backend, &my_id);
                                Some(build_one_message_row(
                                    &rec, &all, &my_id, &my_label, &group_hex, &overlay, backend,
                                ))
                            });
                        let swapped = with_inner_messages(&chats_messages, idx, |vm| {
                            let Some(pos) = find_message_row(vm, &temp_id) else {
                                return false;
                            };
                            if let Some(mut row) = confirmed_row {
                                preserve_grouping_flags(vm, pos, &mut row);
                                vm.set_row_data(pos, row);
                            } else {
                                vm.remove(pos);
                            }
                            true
                        });
                        if swapped != Some(true) {
                            let overlay = pending_state.lock().unwrap();
                            rebuild_chat_messages_from(
                                backend,
                                &overlay,
                                &chats_messages,
                                idx,
                                &group_hex,
                                &all,
                            );
                        }
                    }
                    Err(e) => {
                        tracing::warn!(target: "album", "upload: {e:#}");
                        if !online {
                            tracing::warn!(target: "album", "offline — left queued for flush");
                            return;
                        }
                        let mut overlay = pending_state.lock().unwrap();
                        overlay.mark_send_failed(&group_hex, &temp_id);
                        let failed = overlay.find_send(&group_hex, &temp_id);
                        drop(overlay);
                        if let Some(failed) = failed {
                            let guard = backend_cell.lock().unwrap();
                            let Some(backend) = guard.as_ref() else {
                                return;
                            };
                            let my_id = backend.account().account_id_hex.clone();
                            let my_label = my_avatar_label(backend, &my_id);
                            let _ = with_inner_messages(&chats_messages, idx, |vm| {
                                if let Some(pos) = find_message_row(vm, &temp_id) {
                                    vm.set_row_data(
                                        pos,
                                        pending_chat_message(&failed, &my_id, &my_label),
                                    );
                                }
                            });
                        }
                    }
                }
            });
        });
    });
}
