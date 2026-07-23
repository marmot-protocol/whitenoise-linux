use crate::*;

// Shared attachment/album send spawners. Called from the messaging,
// forward, and offline-queue (extra.rs) wiring sections, so they live in
// their own chapter rather than at the bottom of one caller.

/// Why a spawner is being handed an existing temp id instead of allocating one.
///
/// Both variants reuse the id (and so adopt any bubble already rendered under
/// it) — they differ only in whether the durable queue entry is already on disk:
///
/// * [`Replay`](PendingReuse::Replay) — the reconnect flush or a manual retry
///   re-dispatching an entry read back from the queue. Already persisted; a
///   second write would duplicate it.
/// * [`Placeholder`](PendingReuse::Placeholder) — the forward flow adopting the
///   "forwarding…" bubble it rendered before the source attachments finished
///   downloading. Never persisted (there were no bytes yet), so this send still
///   owes the queue its entry.
#[derive(Clone, Debug)]
pub(crate) enum PendingReuse {
    Replay(String),
    Placeholder(String),
}

impl PendingReuse {
    fn into_temp_id(self) -> String {
        match self {
            PendingReuse::Replay(id) | PendingReuse::Placeholder(id) => id,
        }
    }

    /// True when the durable queue already holds this send.
    fn already_queued(&self) -> bool {
        matches!(self, PendingReuse::Replay(_))
    }
}

// Called by `on_send_message` for each staged attachment: insert the
// optimistic pending bubble, run the encrypted Blossom upload + kind-9
// publish, reconcile the bubble when the round-trip resolves.
//
// Thread-safety: `ModelRc` is `!Send`, so we never carry it across the
// tokio boundary — every closure that hops back to the UI re-fetches
// the model via `ui.get_chats_messages()`.
// `reuse` is `None` for a fresh send (allocate an id, render the pending
// bubble, persist a durable queue entry) and `Some(..)` when an id is being
// adopted — see [`PendingReuse`] for the two cases and what each implies for
// the overlay entry, the bubble, and the durable queue.
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_attachment_send(
    weak: slint::Weak<WhiteNoiseLinux>,
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
    reuse: Option<PendingReuse>,
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

        let already_queued = reuse.as_ref().is_some_and(PendingReuse::already_queued);
        let temp_id = reuse.map_or_else(next_temp_id, PendingReuse::into_temp_id);
        let send = PendingSend {
            temp_id: temp_id.clone(),
            text: String::new(),
            failed: false,
            reply_to: None,
            effect: 0,
            media: vec![PendingMedia {
                file_name: file_name_u.clone(),
                media_type: media_type_u.clone(),
                size_bytes: Some(size_bytes),
                is_image,
                is_video: mime_is_video(&media_type_u),
                is_audio: mime_is_audio(&media_type_u),
                local_preview: local_preview.clone(),
            }],
        };
        // Render the pending bubble + insert the overlay entry only if it isn't
        // already present (a replay of an in-session offline failure, and a
        // forward adopting its placeholder, both keep the existing bubble; a
        // boot replay has none yet).
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
        if !already_queued {
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

        let ctx = SendReconcileCtx {
            weak: weak2.clone(),
            backend_cell: backend_cell2.clone(),
            group_ids: group_ids2.clone(),
            pending_state: pending_state2.clone(),
            group_hex: group_hex2.clone(),
            temp_id: temp_id.clone(),
            label: "attach",
            error_op: None,
        };
        backend.upload_media_async(
            &group_hex2,
            file_name,
            media_type,
            bytes,
            None,
            move |result| {
                apply_send_result(
                    ctx,
                    result.map(|u| u.sent.as_ref().and_then(|s| s.message_ids.first().cloned())),
                    move |id| {
                        // The uploader knows the plaintext size; the imeta tag
                        // doesn't carry one, so seed the session size cache (and
                        // the local preview) before the confirmed row is built.
                        attachment_size_put(id, size_bytes);
                        if is_image && let Some(p) = local_preview.as_ref() {
                            attachment_image_cache_put(id.to_string(), p.clone());
                        }
                    },
                );
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
// `reuse`: see `spawn_attachment_send` and [`PendingReuse`] — an album is
// re-dispatched from disk on reconnect, or adopts a forward's placeholder.
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_album_send(
    weak: slint::Weak<WhiteNoiseLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
    group_hex: String,
    files: Vec<StagedFile>,
    reuse: Option<PendingReuse>,
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

        let already_queued = reuse.as_ref().is_some_and(PendingReuse::already_queued);
        let temp_id = reuse.map_or_else(next_temp_id, PendingReuse::into_temp_id);
        let media: Vec<PendingMedia> = files
            .iter()
            .map(|f| PendingMedia {
                file_name: f.file_name.clone(),
                media_type: f.media_type.clone(),
                size_bytes: Some(f.bytes.len() as u64),
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
        if !already_queued {
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

        let ctx = SendReconcileCtx {
            weak: weak.clone(),
            backend_cell: backend_cell.clone(),
            group_ids: group_ids.clone(),
            pending_state: pending_state.clone(),
            group_hex: group_hex.clone(),
            temp_id: temp_id.clone(),
            label: "album",
            error_op: None,
        };
        backend.upload_album_async(&group_hex, items, move |result| {
            apply_send_result(
                ctx,
                result.map(|u| u.sent.as_ref().and_then(|s| s.message_ids.first().cloned())),
                move |id| {
                    // Seed each image's preview under the real id (per-index
                    // `att_key`) so the confirmed grid shows the same pixels
                    // without a re-download.
                    for (i, p) in previews.iter().enumerate() {
                        if let Some(px) = p {
                            attachment_image_cache_put(att_key(id, i), px.clone());
                        }
                    }
                },
            );
        });
    });
}
