use crate::*;

// ─── Forward a message to another chat ──────────────────────────────────────
//
// The message context menu's "Forward" item stashes the source message id on
// the root (`forward-src-id`) and opens the chat picker. Picking a destination
// fires `request-forward(dest_idx)`, handled here:
//
//   1. Resolve the source + destination group hexes (source is the still-active
//      chat behind the picker; destination is the picked index).
//   2. Switch the UI to the destination chat so the re-sent content is visible.
//   3. Off the UI thread, read the source record. Forward its body text as a
//      fresh send, and re-encrypt each attachment for the destination group by
//      downloading+decrypting from the source and re-uploading to the target.
//
// Forwarding never carries the original's reply context, reactions, or effect —
// it re-sends content only, exactly like composing it anew in the target chat.
pub(crate) fn wire_forward(ui: &DarkMatterLinux, cx: &Cx) {
    let Cx {
        backend_cell,
        group_ids,
        pending_state,
        vault_cell,
        ..
    } = cx.clone();

    // The picker's search field: recompute one case-insensitive name-match
    // flag per chat row (the modal overlays these on its own active-chat skip)
    // plus the ordered list of visible chat indices, which the modal's
    // keyboard cursor walks. The picker also fires this on open with the
    // empty query, so both arrays are fresh for the current active chat.
    ui.global::<AppState>().on_forward_filter_changed({
        let weak = ui.as_weak();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let q = query.to_lowercase();
            let active = ui.get_active_chat();
            let mut flags: Vec<bool> = Vec::new();
            let mut visible: Vec<i32> = Vec::new();
            for (idx, c) in ui.get_chats().iter().enumerate() {
                let matches = q.is_empty() || c.name.to_lowercase().contains(&q);
                flags.push(matches);
                if matches && idx as i32 != active {
                    visible.push(idx as i32);
                }
            }
            ui.set_forward_match_flags(model(flags));
            ui.set_forward_visible_rows(model(visible));
        }
    });

    ui.global::<AppState>().on_request_forward({
        let weak = ui.as_weak();
        move |dest_idx| {
            let Some(ui) = weak.upgrade() else { return };
            let dest_idx = dest_idx as usize;
            let src_id = ui.get_forward_src_id().to_string();
            // A still-optimistic (unconfirmed) message has no backend record to
            // forward from; ignore until it lands.
            if src_id.is_empty() || is_temp_id(&src_id) {
                return;
            }
            let src_idx = ui.get_active_chat() as usize;
            let (src_group, dest_group) = {
                let ids = group_ids.lock().unwrap();
                match (ids.get(src_idx).cloned(), ids.get(dest_idx).cloned()) {
                    (Some(s), Some(d)) => (s, d),
                    _ => return,
                }
            };
            // Forwarding into the same thread is a no-op (the picker hides the
            // current chat, but guard anyway).
            if src_group == dest_group {
                return;
            }
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                ui.set_backend_error(error_copy().not_connected.into());
                return;
            };

            // Land the user in the destination so they watch the forward arrive.
            // The optimistic bubbles below reconcile by group hex, so they land
            // in the right chat regardless of this switch's async rebuild.
            ui.global::<AppState>()
                .invoke_chat_selected(dest_idx as i32);

            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            let group_ids = group_ids.clone();
            let pending_state = pending_state.clone();
            let vault_cell = vault_cell.clone();
            let b = backend.clone();
            backend.tokio_handle().spawn(async move {
                // Resolve the source record (sqlite read) off the UI thread.
                let all = b
                    .messages(&src_group, Some(msg_window_for(&src_group)))
                    .unwrap_or_default();
                let Some(rec) = all.iter().find(|m| m.message_id_hex == src_id).cloned() else {
                    return;
                };
                let body = rec.plaintext.trim().to_string();
                let refs = parse_all_media_references(&rec.tags, rec.source_epoch);

                // Plain text (no attachments) → one fresh send.
                if refs.is_empty() {
                    if !body.is_empty() {
                        spawn_text_forward(
                            weak,
                            backend_cell,
                            group_ids,
                            pending_state,
                            vault_cell,
                            dest_group,
                            body,
                        );
                    }
                    return;
                }

                forward_media(
                    weak,
                    backend_cell,
                    group_ids,
                    pending_state,
                    vault_cell,
                    b,
                    src_group,
                    dest_group,
                    body,
                    refs,
                );
            });
        }
    });
}

/// The handles every stage of a media forward threads through. Bundled the way
/// `Cx` bundles the wiring handles: the plan → download → dispatch chain hops
/// threads twice and would otherwise pass the same five arguments at each hop.
#[derive(Clone)]
struct ForwardCx {
    weak: slint::Weak<DarkMatterLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
}

/// One optimistic bubble a media forward will produce, planned *before* any
/// download starts.
///
/// The grouping mirrors the composer's staged flush exactly (images chunk into
/// albums of 10, a lone image or any non-image file goes out on its own), so
/// each planned bubble is adopted one-for-one by the send that eventually
/// carries it — the placeholder the user sees on arrival *is* the row that
/// turns into the real message.
struct ForwardBubble {
    temp_id: String,
    refs: Vec<MediaAttachmentReference>,
    is_album: bool,
}

/// Everything needed to re-run one bubble's downloads, stashed under its temp
/// id when they fail. See [`retry_forward_media`].
struct ForwardRetry {
    cx: ForwardCx,
    src_group: String,
    dest_group: String,
    bubble: ForwardBubble,
}

/// Forward bubbles sitting in the red "tap to retry" state because their source
/// attachments couldn't be downloaded.
///
/// A normal failed send retries out of the durable offline queue, which holds
/// its bytes. A forward that never finished downloading has no bytes and so no
/// queue entry, so its retry has to re-enter the *download* instead — this map
/// is where the retry handler finds the inputs to do that.
fn forward_retries() -> &'static Mutex<std::collections::HashMap<String, ForwardRetry>> {
    static R: std::sync::OnceLock<Mutex<std::collections::HashMap<String, ForwardRetry>>> =
        std::sync::OnceLock::new();
    R.get_or_init(Default::default)
}

/// Download+decrypt every attachment on the source message, then re-upload them
/// (re-encrypted for the destination group) as the planned bubbles.
///
/// The destination shows the forward the moment the user picks it: the bubbles
/// are planned and rendered as "sending…" placeholders up front, from the
/// source's `imeta` metadata, and each is adopted by its send once that
/// bubble's attachments have downloaded. A bubble whose downloads fail flips
/// red and stays tappable instead of vanishing. The body text (a caption) is
/// forwarded first so it reads above the media.
#[allow(clippy::too_many_arguments)]
fn forward_media(
    weak: slint::Weak<DarkMatterLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
    backend: Arc<Backend>,
    src_group: String,
    dest_group: String,
    body: String,
    refs: Vec<MediaAttachmentReference>,
) {
    let cx = ForwardCx {
        weak,
        backend_cell,
        group_ids,
        pending_state,
        vault_cell,
    };
    if !body.is_empty() {
        spawn_text_forward(
            cx.weak.clone(),
            cx.backend_cell.clone(),
            cx.group_ids.clone(),
            cx.pending_state.clone(),
            cx.vault_cell.clone(),
            dest_group.clone(),
            body,
        );
    }

    let total = refs.len();
    let bubbles = plan_forward_bubbles(refs);
    // Shared across every bubble so the error banner reports the forward as a
    // whole ("2 of 5") once, rather than once per failing bubble.
    let outstanding = Arc::new(AtomicUsize::new(bubbles.len()));
    let failed = Arc::new(AtomicUsize::new(0));

    for bubble in bubbles {
        render_forward_placeholder(&cx, &dest_group, &bubble);
        run_forward_bubble(
            &cx,
            &backend,
            &src_group,
            &dest_group,
            bubble,
            outstanding.clone(),
            failed.clone(),
            total,
        );
    }
}

/// Group the source references into the bubbles the destination will show,
/// mirroring `on_send_message`'s staged flush so the placeholders match the
/// messages that replace them.
fn plan_forward_bubbles(refs: Vec<MediaAttachmentReference>) -> Vec<ForwardBubble> {
    let (images, others): (Vec<_>, Vec<_>) =
        refs.into_iter().partition(|r| mime_is_image(&r.media_type));
    let mut bubbles: Vec<ForwardBubble> = Vec::new();
    for chunk in images.chunks(10) {
        bubbles.push(ForwardBubble {
            temp_id: next_temp_id(),
            refs: chunk.to_vec(),
            is_album: chunk.len() > 1,
        });
    }
    for r in others {
        bubbles.push(ForwardBubble {
            temp_id: next_temp_id(),
            refs: vec![r],
            is_album: false,
        });
    }
    bubbles
}

/// Build the pending overlay entry for a planned bubble from the source's
/// `imeta` metadata. Sizes are `None` — the tag doesn't carry one and the bytes
/// aren't downloaded yet — and previews are `None` until they are.
fn placeholder_send(bubble: &ForwardBubble) -> PendingSend {
    PendingSend {
        temp_id: bubble.temp_id.clone(),
        text: String::new(),
        failed: false,
        reply_to: None,
        effect: 0,
        media: bubble
            .refs
            .iter()
            .map(|r| PendingMedia {
                file_name: r.file_name.clone(),
                media_type: r.media_type.clone(),
                size_bytes: None,
                is_image: mime_is_image(&r.media_type),
                is_video: mime_is_video(&r.media_type),
                is_audio: mime_is_audio(&r.media_type),
                local_preview: None,
            })
            .collect(),
    }
}

/// Render a planned bubble in the destination straight away, so the chat the
/// user just landed in shows the forward in flight instead of nothing.
fn render_forward_placeholder(cx: &ForwardCx, dest_group: &str, bubble: &ForwardBubble) {
    let cx = cx.clone();
    let dest_group = dest_group.to_string();
    let send = placeholder_send(bubble);
    let _ = slint::invoke_from_event_loop(move || {
        let Some(ui) = cx.weak.upgrade() else { return };
        let Some(idx) = cx
            .group_ids
            .lock()
            .unwrap()
            .iter()
            .position(|g| g == &dest_group)
        else {
            return;
        };
        let guard = cx.backend_cell.lock().unwrap();
        let Some(backend) = guard.as_ref() else {
            return;
        };
        cx.pending_state
            .lock()
            .unwrap()
            .add_send(&dest_group, send.clone());
        let my_id = backend.account().account_id_hex.clone();
        let my_label = my_avatar_label(backend, &my_id);
        let row = pending_chat_message(&send, &my_id, &my_label);
        with_inner_messages(&ui.get_chats_messages(), idx, |vm| {
            push_message_grouped(vm, row)
        });
        ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
    });
}

/// Download one bubble's attachments concurrently, then hand the bytes to the
/// send that adopts its placeholder — or, if any of them failed, flip the
/// placeholder red and stash the inputs a retry needs.
///
/// A partial album is treated as a failure of the whole bubble: shipping the
/// images that happened to arrive would silently drop the rest, which is the
/// behaviour this replaces.
#[allow(clippy::too_many_arguments)]
fn run_forward_bubble(
    cx: &ForwardCx,
    backend: &Arc<Backend>,
    src_group: &str,
    dest_group: &str,
    bubble: ForwardBubble,
    outstanding: Arc<AtomicUsize>,
    failed: Arc<AtomicUsize>,
    total: usize,
) {
    let n = bubble.refs.len();
    // Order-preserving slots so a multi-image album keeps its original order.
    let slots: Arc<Mutex<Vec<Option<StagedFile>>>> =
        Arc::new(Mutex::new((0..n).map(|_| None).collect()));
    let remaining = Arc::new(AtomicUsize::new(n));
    let bubble = Arc::new(bubble);

    for (i, reference) in bubble.refs.iter().cloned().enumerate() {
        let cx = cx.clone();
        let slots = slots.clone();
        let remaining = remaining.clone();
        let outstanding = outstanding.clone();
        let failed = failed.clone();
        let bubble = bubble.clone();
        let src_group = src_group.to_string();
        let dest_group = dest_group.to_string();
        let dl_src_group = src_group.clone();
        backend.download_media_async(&dl_src_group, reference, move |result| {
            match result {
                Ok(dl) => {
                    let is_image = mime_is_image(&dl.media_type);
                    slots.lock().unwrap()[i] = Some(StagedFile {
                        file_name: dl.file_name,
                        media_type: dl.media_type,
                        bytes: dl.plaintext,
                        is_image,
                        preview: None,
                        thumb: None,
                    });
                }
                Err(e) => {
                    tracing::warn!(target: "forward", "attachment {i} download failed: {e:#}");
                }
            }
            // Last download of this bubble in → dispatch it or fail it.
            if remaining.fetch_sub(1, AtomicOrdering::SeqCst) != 1 {
                return;
            }
            let slots = std::mem::take(&mut *slots.lock().unwrap());
            let missing = slots.iter().filter(|s| s.is_none()).count();
            if missing == 0 {
                dispatch_forward_bubble(
                    &cx,
                    &dest_group,
                    &bubble,
                    slots.into_iter().flatten().collect(),
                );
            } else {
                failed.fetch_add(missing, AtomicOrdering::SeqCst);
                fail_forward_bubble(&cx, &src_group, &dest_group, &bubble);
            }
            // Last bubble of the forward resolved → report the total damage
            // once, on the same banner the text-forward path already uses.
            if outstanding.fetch_sub(1, AtomicOrdering::SeqCst) == 1 {
                let failed = failed.load(AtomicOrdering::SeqCst);
                if failed > 0 {
                    report_forward_failure(&cx, failed, total);
                }
            }
        });
    }
}

/// Hand a fully downloaded bubble to the send that adopts its placeholder.
fn dispatch_forward_bubble(
    cx: &ForwardCx,
    dest_group: &str,
    bubble: &ForwardBubble,
    files: Vec<StagedFile>,
) {
    let reuse = Some(PendingReuse::Placeholder(bubble.temp_id.clone()));
    if bubble.is_album {
        spawn_album_send(
            cx.weak.clone(),
            cx.backend_cell.clone(),
            cx.group_ids.clone(),
            cx.pending_state.clone(),
            cx.vault_cell.clone(),
            dest_group.to_string(),
            files,
            reuse,
        );
        return;
    }
    let Some(f) = files.into_iter().next() else {
        return;
    };
    spawn_attachment_send(
        cx.weak.clone(),
        cx.backend_cell.clone(),
        cx.group_ids.clone(),
        cx.pending_state.clone(),
        cx.vault_cell.clone(),
        dest_group.to_string(),
        f.file_name,
        f.media_type,
        f.bytes,
        f.is_image,
        f.preview,
        reuse,
    );
}

/// Flip a bubble whose downloads failed to the red "tap to retry" state and
/// stash what a retry needs to re-enter the download.
fn fail_forward_bubble(cx: &ForwardCx, src_group: &str, dest_group: &str, bubble: &ForwardBubble) {
    forward_retries().lock().unwrap().insert(
        bubble.temp_id.clone(),
        ForwardRetry {
            cx: cx.clone(),
            src_group: src_group.to_string(),
            dest_group: dest_group.to_string(),
            bubble: ForwardBubble {
                temp_id: bubble.temp_id.clone(),
                refs: bubble.refs.clone(),
                is_album: bubble.is_album,
            },
        },
    );
    // No in-flight guard to drop and no durable entry to remove: this bubble
    // never reached the uploader, which is what owns both.
    mark_forward_row_failed(cx, dest_group, &bubble.temp_id);
}

/// Repaint one forward bubble as failed, in place, keeping its grouping —
/// the same surgical flip `apply_send_result` does for a failed send.
fn mark_forward_row_failed(cx: &ForwardCx, dest_group: &str, temp_id: &str) {
    let cx = cx.clone();
    let dest_group = dest_group.to_string();
    let temp_id = temp_id.to_string();
    let _ = slint::invoke_from_event_loop(move || {
        let Some(ui) = cx.weak.upgrade() else { return };
        let Some(idx) = cx
            .group_ids
            .lock()
            .unwrap()
            .iter()
            .position(|g| g == &dest_group)
        else {
            return;
        };
        let mut overlay = cx.pending_state.lock().unwrap();
        overlay.mark_send_failed(&dest_group, &temp_id);
        let failed = overlay.find_send(&dest_group, &temp_id);
        drop(overlay);
        let Some(failed) = failed else { return };
        let guard = cx.backend_cell.lock().unwrap();
        let Some(backend) = guard.as_ref() else {
            return;
        };
        let my_id = backend.account().account_id_hex.clone();
        let my_label = my_avatar_label(backend, &my_id);
        let _ = with_inner_messages(&ui.get_chats_messages(), idx, |vm| {
            if let Some(pos) = find_message_row(vm, &temp_id) {
                let mut row = pending_chat_message(&failed, &my_id, &my_label);
                preserve_grouping_flags(vm, pos, &mut row);
                vm.set_row_data(pos, row);
            }
        });
    });
}

/// Surface the forward's failed-attachment count on the error banner — the same
/// surface the text-forward path reports on via `ErrorOp::Forward`.
fn report_forward_failure(cx: &ForwardCx, failed: usize, total: usize) {
    let weak = cx.weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        let Some(ui) = weak.upgrade() else { return };
        let copy = error_copy();
        ui.set_backend_error(
            tmpl(
                &copy.forward_media,
                &[&failed.to_string(), &total.to_string()],
            )
            .into(),
        );
    });
}

/// Retry a forward bubble whose source attachments failed to download.
///
/// Returns `false` when `temp_id` isn't such a bubble, leaving the caller to
/// fall through to its normal durable-queue replay.
pub(crate) fn retry_forward_media(temp_id: &str) -> bool {
    let Some(entry) = forward_retries().lock().unwrap().remove(temp_id) else {
        return false;
    };
    let ForwardRetry {
        cx,
        src_group,
        dest_group,
        bubble,
    } = entry;
    let guard = cx.backend_cell.lock().unwrap();
    let Some(backend) = guard.as_ref().cloned() else {
        return false;
    };
    drop(guard);
    let total = bubble.refs.len();
    run_forward_bubble(
        &cx,
        &backend,
        &src_group,
        &dest_group,
        bubble,
        Arc::new(AtomicUsize::new(1)),
        Arc::new(AtomicUsize::new(0)),
        total,
    );
    true
}

/// Text analog of [`spawn_attachment_send`]: insert an optimistic bubble in the
/// destination chat, durably queue the send, dispatch it in the background, and
/// reconcile the row by group hex on ack (or flip it red on an online failure /
/// leave it pending while offline). Used only by the forward flow — the normal
/// composer send owns its own optimistic block inline.
pub(crate) fn spawn_text_forward(
    weak: slint::Weak<DarkMatterLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    pending_state: Arc<Mutex<PendingState>>,
    vault_cell: VaultCell,
    group_hex: String,
    text: String,
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
        let Some(backend) = backend_cell.lock().unwrap().clone() else {
            return;
        };

        let temp_id = next_temp_id();
        let send = PendingSend {
            temp_id: temp_id.clone(),
            text: text.clone(),
            failed: false,
            reply_to: None,
            media: Vec::new(),
            effect: 0,
        };
        {
            let mut overlay = pending_state.lock().unwrap();
            overlay.add_send(&group_hex, send.clone());
        }
        let my_id = backend.account().account_id_hex.clone();
        let my_label = my_avatar_label(&backend, &my_id);
        offline_persist(
            &vault_cell,
            &offline_queue::QueuedSend {
                temp_id: temp_id.clone(),
                account_id_hex: my_id.clone(),
                group_hex: group_hex.clone(),
                kind: offline_queue::QueuedKind::Text {
                    text: text.clone(),
                    reply_to: None,
                    effect: 0,
                },
                enqueued_at: offline_queue::now_secs(),
            },
        );
        let pending_row = pending_chat_message(&send, &my_id, &my_label);
        with_inner_messages(&chats_messages, idx, |vm| {
            push_message_grouped(vm, pending_row)
        });
        ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
        offline_inflight_insert(&temp_id);

        // Dispatch + reconcile by group hex (mirrors main.rs `dispatch_send`).
        let ctx = SendReconcileCtx {
            weak: weak.clone(),
            backend_cell: backend_cell.clone(),
            group_ids: group_ids.clone(),
            pending_state: pending_state.clone(),
            group_hex: group_hex.clone(),
            temp_id: temp_id.clone(),
            label: "forward",
            error_op: Some(ErrorOp::Forward),
        };
        let on_done = move |result: anyhow::Result<marmot_app::SendSummary>| {
            apply_send_result(
                ctx,
                result.map(|s| s.message_ids.first().cloned()),
                |_id| {},
            );
        };
        backend.send_text_async(&group_hex, &text, on_done);
    });
}
