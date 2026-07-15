use crate::*;

// Shared send-completion reconciler. Every send path — text (`main.rs`),
// forward (`wiring/forward.rs`), attachment and album (`wiring/attach.rs`) —
// ended with the same ~70-line `on_done` handler: read the refreshed window on
// the tokio worker, hop to the event loop, swap the optimistic pending row for
// the confirmed one (falling back to a full rebuild if the model isn't shaped
// as expected), or on failure branch offline-versus-failed. The copies differed
// only in the log label, whether they surface a friendly-error banner, and the
// attachment cache seeding done before the confirmed row is built. This module
// is the single source of truth for that reconciliation; the seeding rides in
// through a per-call hook.

/// The shared captures every send path threads into [`apply_send_result`].
pub(crate) struct SendReconcileCtx {
    pub(crate) weak: slint::Weak<DarkMatterLinux>,
    pub(crate) backend_cell: BackendCell,
    pub(crate) group_ids: Arc<Mutex<Vec<String>>>,
    pub(crate) pending_state: Arc<Mutex<PendingState>>,
    pub(crate) group_hex: String,
    pub(crate) temp_id: String,
    /// Log label identifying the send path (`"send"`, `"forward"`, `"attach"`,
    /// `"album"`); recorded as the `path` field on the `send` tracing target.
    pub(crate) label: &'static str,
    /// `Some(op)` surfaces a friendly-error banner on an online failure (text +
    /// forward); `None` leaves the banner untouched (attachment + album only
    /// flip the bubble red). Reproduces each path's existing behavior.
    pub(crate) error_op: Option<ErrorOp>,
}

/// Reconcile the optimistic bubble once a send resolves.
///
/// Runs on the tokio worker: on success it reads the refreshed message window
/// here (the invoke closure below never touches sqlite); on failure it polls
/// connectivity so an offline failure stays queued + pending rather than
/// flipping the bubble red. It then hops to the event loop and, on the
/// confirmed row, swaps the single pending row in place (keeping its grouping),
/// falling back to a full rebuild if the model isn't shaped as expected.
///
/// `result` is the flattened outcome: `Ok(Some(id))` confirmed with a real
/// message id, `Ok(None)` confirmed with none (remove the placeholder; the
/// watcher appends the real row when it echoes), `Err` a send failure.
/// `seed_cache` runs on the UI thread just before the confirmed row is built,
/// given the real id — the one pre-swap hook that varies between paths (the
/// attachment size/preview caches). Pass a no-op for text and forward sends.
pub(crate) fn apply_send_result<F>(
    ctx: SendReconcileCtx,
    result: anyhow::Result<Option<String>>,
    seed_cache: F,
) where
    F: FnOnce(&str) + Send + 'static,
{
    let SendReconcileCtx {
        weak,
        backend_cell,
        group_ids,
        pending_state,
        group_hex,
        temp_id,
        label,
        error_op,
    } = ctx;

    // This send has resolved — drop the in-flight guard so the reconnect flush
    // won't re-dispatch it concurrently.
    offline_inflight_remove(&temp_id);

    // Worker thread: on a failure, decide here (where a blocking `relay_health`
    // poll is fine) whether we're offline. An offline failure keeps the bubble
    // *pending* and the durable entry queued for the reconnect flush; an online
    // failure is a real error and flips the bubble red.
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
        let ids = group_ids.lock().unwrap();
        let Some(idx) = ids.iter().position(|g| g == &group_hex) else {
            return;
        };
        drop(ids);
        let chats_messages = ui.get_chats_messages();

        match result {
            Ok(real_id) => {
                // Surgical reconciliation: find the pending row, build the
                // confirmed row from the backend record, and swap that single
                // row. Siblings don't remount.
                pending_state
                    .lock()
                    .unwrap()
                    .drop_send(&group_hex, &temp_id);
                // Confirmed — drop the durable queue entry.
                offline_queue::remove(&temp_id);

                let guard = backend_cell.lock().unwrap();
                let Some(backend) = guard.as_ref() else {
                    return;
                };
                if let Some(id) = real_id.as_deref() {
                    seed_cache(id);
                }
                let confirmed_row: Option<ChatMessage> = real_id.as_deref().and_then(|id| {
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
                        // Keep the grouping the pending row had so a confirmed
                        // send doesn't pop its avatar back.
                        preserve_grouping_flags(vm, pos, &mut row);
                        vm.set_row_data(pos, row);
                    } else {
                        // No real id came back — just remove the pending
                        // placeholder; the watcher will append the real row
                        // when it echoes.
                        vm.remove(pos);
                    }
                    true
                });

                // Fallback: if the model wasn't shaped how we expected, do a
                // full rebuild rather than silently lose the pending row.
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
                tracing::warn!(target: "send", path = label, "{e:#}");
                if !online {
                    // Offline: leave the bubble pending ("sending…") and the
                    // durable entry queued. The reconnect flush re-dispatches it.
                    tracing::warn!(target: "send", path = label, "offline — left queued for flush");
                    return;
                }
                if let Some(op) = error_op {
                    ui.set_backend_error(friendly_error(op, &e).into());
                }
                // Online failure: a real error. Mark failed in place — the
                // bubble flips to red without disturbing its neighbours.
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
                            let mut row = pending_chat_message(&failed, &my_id, &my_label);
                            preserve_grouping_flags(vm, pos, &mut row);
                            vm.set_row_data(pos, row);
                        }
                    });
                }
            }
        }
    });
}
