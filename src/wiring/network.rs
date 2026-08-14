use crate::*;

// The Network & relays settings pane plus the Keys page's key-package
// actions. Split out of `wire_panes` (same chaptering convention as the rest
// of `src/wiring/`) to keep `panes.rs` under the 2000-line limit; `wire_panes`
// calls this at the point in its body the sections originally occupied.
pub(crate) fn wire_network(ui: &WhiteNoiseLinux, cx: &Cx, boot_backend: &BootFn) {
    let Cx {
        backend_cell,
        vault_cell,
        active_message_watcher,
        chats_watcher,
        ..
    } = cx.clone();
    // ─── Network & relays pane ─────────────────────────────────────────
    // The on-disk list (`backend::load_relays`) is the source of truth and
    // what we mutate from the UI. `backend.booted_relays()` is what the
    // running runtime was started with — when they diverge the pane shows a
    // "reconnect" banner. MarmotApp has no `set_relays` API, so applying a
    // change still means re-booting the whole runtime — but `reconnect_relays`
    // below does that in place, reusing the already-unlocked vault, instead of
    // requiring the user to quit the app and unlock it again.
    //
    // `network-status` is the transient line under the list — error text on
    // bad input or save failures, brief confirmation on success.

    // Initial population — the on-disk list always exists (possibly empty)
    // even before the backend boots; booted-relays + health stay empty until
    // backend ready, then we re-push.
    {
        // Routes through push_network_relays so suggested-relay chips are seeded too.
        let initial = backend::load_relays();
        push_network_relays(ui, &initial);
        push_network_inbox_relays(ui, &backend::load_inbox_relays());
        ui.set_network_booted_relays(ModelRc::new(VecModel::from(Vec::<SharedString>::new())));
        ui.set_network_connected(0);
        ui.set_network_total(0);
        ui.set_network_status(s(""));
        ui.set_network_republish_busy(false);
        ui.set_network_refresh_busy(false);
    }

    // Re-boot the runtime against the current on-disk relay list, in place.
    // `boot_backend` re-derives the nsec from the still-unlocked vault (no
    // password re-entry), tears down nothing itself, and on success replaces
    // `backend_cell` + reinstalls the chat watcher — so any watcher left over
    // from the runtime we're replacing must be aborted first, or it keeps
    // delivering updates from a backend nothing else references anymore.
    // Shows the boot splash for the duration (`AppState.booting`), which is
    // why call sites gate this behind either the empty first-run state or an
    // explicit user action rather than firing it on every keystroke.
    let reconnect_relays: Rc<dyn Fn()> = {
        let weak = ui.as_weak();
        let boot = boot_backend.clone();
        let vault_cell = vault_cell.clone();
        let active_message_watcher = active_message_watcher.clone();
        let chats_watcher = chats_watcher.clone();
        Rc::new(move || {
            let Some(ui) = weak.upgrade() else { return };
            // Avoid racing a boot already in flight.
            if !ui.get_backend_ready() || ui.get_booting() {
                return;
            }
            let Some(vault) = vault_cell.lock().unwrap().clone() else {
                return;
            };
            let Some(nsec) = vault.lock().unwrap().nsec() else {
                return;
            };
            if let Some(h) = active_message_watcher.lock().unwrap().take() {
                h.abort();
            }
            if let Some(h) = chats_watcher.lock().unwrap().take() {
                h.abort();
            }
            boot(nsec, vault, None);
        })
    };

    ui.global::<AppState>().on_network_reconnect_relays({
        let reconnect = reconnect_relays.clone();
        move || reconnect()
    });

    // Add/remove for both lists share validate+dedupe+persist logic via
    // relays::add_relay_to_list / remove_relay_from_list; only the model,
    // save fn, error field, and (outbox-only) reboot trigger vary here.
    ui.global::<AppState>().on_network_add_relay({
        let weak = ui.as_weak();
        let reboot = reconnect_relays.clone();
        // Returns whether the relay was accepted — the add-relay fields keep
        // their draft on a rejection so the user can correct it in place.
        move |raw| {
            let Some(ui) = weak.upgrade() else {
                return false;
            };
            let mut list = vec_string_from_model(&ui.get_network_relays());
            match add_relay_to_list(&raw, &mut list, backend::save_relays) {
                Ok(()) => {
                    ui.set_network_add_error(SharedString::default());
                    push_network_relays(&ui, &list);
                    show_network_status(&ui, error_copy().relay_added, StatusKind::Ok);
                    // Reconnect immediately so the live transport picks up the
                    // change right away, instead of waiting on the "Reconnect
                    // now" banner.
                    reboot();
                    true
                }
                Err(msg) => {
                    ui.set_network_add_error(msg.into());
                    ui.set_network_status(SharedString::default());
                    false
                }
            }
        }
    });

    ui.global::<AppState>().on_network_remove_relay({
        let weak = ui.as_weak();
        let reboot = reconnect_relays.clone();
        move |url| {
            let Some(ui) = weak.upgrade() else { return };
            let mut list = vec_string_from_model(&ui.get_network_relays());
            match remove_relay_from_list(&url, &mut list, backend::save_relays) {
                Ok(true) => {
                    push_network_relays(&ui, &list);
                    show_network_status(&ui, error_copy().relay_removed, StatusKind::Ok);
                    // Re-boot so the live transport drops the removed relay
                    // right away.
                    reboot();
                }
                Ok(false) => {}
                Err(msg) => show_network_status(&ui, msg, StatusKind::Error),
            }
        }
    });

    // Not part of the connect pool, so unlike the outbox pair above these
    // never trigger a reboot — they only change what we declare, not what
    // we're connected to.
    ui.global::<AppState>().on_network_add_inbox_relay({
        let weak = ui.as_weak();
        move |raw| {
            let Some(ui) = weak.upgrade() else {
                return false;
            };
            let mut list = vec_string_from_model(&ui.get_network_inbox_relays());
            match add_relay_to_list(&raw, &mut list, backend::save_inbox_relays) {
                Ok(()) => {
                    ui.set_network_inbox_add_error(SharedString::default());
                    push_network_inbox_relays(&ui, &list);
                    show_network_status(&ui, error_copy().relay_added, StatusKind::Ok);
                    true
                }
                Err(msg) => {
                    ui.set_network_inbox_add_error(msg.into());
                    ui.set_network_status(SharedString::default());
                    false
                }
            }
        }
    });

    ui.global::<AppState>().on_network_remove_inbox_relay({
        let weak = ui.as_weak();
        move |url| {
            let Some(ui) = weak.upgrade() else { return };
            let mut list = vec_string_from_model(&ui.get_network_inbox_relays());
            match remove_relay_from_list(&url, &mut list, backend::save_inbox_relays) {
                Ok(true) => {
                    push_network_inbox_relays(&ui, &list);
                    show_network_status(&ui, error_copy().relay_removed, StatusKind::Ok);
                }
                Ok(false) => {}
                Err(msg) => show_network_status(&ui, msg, StatusKind::Error),
            }
        }
    });

    ui.global::<AppState>().on_network_refresh_health({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let allow_status_update = !ui.get_network_republish_busy();
            ui.set_network_refresh_busy(true);
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            spawn_ui(
                weak,
                move || {
                    // Clone the handle, drop the lock, then poll — the UI thread
                    // must never find this mutex held across a relay query.
                    let b = backend_cell.lock().unwrap().clone();
                    b.map(|b| b.relay_health())
                },
                move |ui, snapshot| {
                    ui.set_network_refresh_busy(false);
                    match snapshot {
                        Some((connected, total)) => {
                            ui.set_network_connected(connected as i32);
                            ui.set_network_total(total as i32);
                            // We just polled the relay pool — that's a real sync.
                            ui.set_sync_secs(0);
                        }
                        None if allow_status_update && !ui.get_network_republish_busy() => {
                            show_network_status(&ui, error_copy().not_connected, StatusKind::Error)
                        }
                        None => {}
                    }
                },
            );
            if allow_status_update {
                ui.set_network_status(s(""));
            }
        }
    });

    ui.global::<AppState>().on_network_republish_relay_list({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_network_republish_busy() {
                return;
            }
            show_network_status(&ui, error_copy().republishing, StatusKind::Pending);
            ui.set_network_republish_busy(true);
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            spawn_ui(
                weak,
                move || {
                    // Same handle-clone dance: never hold the cell lock across
                    // the relay publish.
                    let b = backend_cell.lock().unwrap().clone();
                    match b {
                        None => Err(error_copy().not_connected),
                        Some(b) => b
                            .republish_relay_lists()
                            .map_err(|e| friendly_error(ErrorOp::Republish, &e)),
                    }
                },
                move |ui, result| {
                    ui.set_network_republish_busy(false);
                    match result {
                        Ok((outbox, inbox)) => show_network_status(
                            &ui,
                            format!(
                                "Republished — {outbox} outbox relay{}, {inbox} inbox relay{}.",
                                if outbox == 1 { "" } else { "s" },
                                if inbox == 1 { "" } else { "s" }
                            ),
                            StatusKind::Ok,
                        ),
                        Err(e) => show_network_status(&ui, e, StatusKind::Error),
                    }
                },
            );
        }
    });

    // ─── Keys page: KP publish / rotate / refresh ──────────────────────
    // All three call into the marmot runtime, which blocks on its tokio
    // executor — so we hop onto a worker thread first, then back to the
    // Slint event loop with the results. Each op sets its own `kp-*-busy` /
    // `kp-*-status` pair for the round-trip, so triggering one doesn't make
    // an unrelated action look busy too.

    fn set_kp_busy(ui: &WhiteNoiseLinux, op_kind: &str, busy: bool) {
        match op_kind {
            "rotate" => ui.set_kp_rotate_busy(busy),
            "refresh" => ui.set_kp_refresh_busy(busy),
            _ => ui.set_kp_publish_busy(busy),
        }
    }

    fn set_kp_status(ui: &WhiteNoiseLinux, op_kind: &str, status: String) {
        match op_kind {
            "rotate" => ui.set_kp_rotate_status(status.into()),
            "refresh" => ui.set_kp_refresh_status(status.into()),
            _ => ui.set_kp_publish_status(status.into()),
        }
    }

    let kp_run = {
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        // op_kind: "publish" | "rotate" | "refresh"
        Rc::new(move |op_kind: &'static str| {
            let Some(ui) = weak.upgrade() else { return };
            set_kp_busy(&ui, op_kind, true);
            let copy = error_copy();
            set_kp_status(
                &ui,
                op_kind,
                match op_kind {
                    "rotate" => copy.kp_rotating,
                    "refresh" => copy.kp_refreshing,
                    _ => copy.kp_publishing,
                },
            );
            let weak = weak.clone();
            // Clone the backend handle and drop the lock before the relay
            // round-trip — other callbacks keep locking this cell freely.
            let b = backend_cell.lock().unwrap().clone();
            spawn_ui(
                weak,
                move || {
                    let result: Result<String, String> = {
                        match b.as_deref() {
                            None => Err(error_copy().not_connected),
                            Some(b) => match op_kind {
                                // NOTE: the SDK returns the key-package size in bytes,
                                // not a relay-ack count — so we don't surface the number
                                // (it was being shown as a nonsensical "N relay acks").
                                "publish" => b
                                    .publish_key_package()
                                    .map(|_| error_copy().kp_published)
                                    .map_err(|e| friendly_error(ErrorOp::KpPublish, &e)),
                                "rotate" => b
                                    .rotate_key_package()
                                    .map(|_| error_copy().kp_rotated)
                                    .map_err(|e| friendly_error(ErrorOp::KpRotate, &e)),
                                "refresh" => b
                                    .key_packages_fetch()
                                    .map(|recs| {
                                        let copy = error_copy();
                                        let form = if recs.len() == 1 {
                                            copy.kp_fetched_one
                                        } else {
                                            copy.kp_fetched_many
                                        };
                                        tmpl(&form, &[&recs.len().to_string()])
                                    })
                                    .map_err(|e| friendly_error(ErrorOp::KpRefresh, &e)),
                                _ => Err(error_copy().generic),
                            },
                        }
                    };
                    // The post-op snapshot for "refresh" hits relays too — pull
                    // the rows here on the worker, never in the event-loop
                    // completion (that closure runs on the UI thread).
                    let rows: Option<Vec<KeyPackageInfo>> = b.as_deref().and_then(|b| {
                        if op_kind == "refresh" {
                            b.key_packages_fetch()
                                .ok()
                                .map(|recs| recs.iter().map(kp_to_ui).collect())
                        } else {
                            None
                        }
                    });
                    (result, rows, b)
                },
                move |ui, (result, rows, b)| {
                    set_kp_busy(&ui, op_kind, false);
                    match result {
                        Ok(status) => set_kp_status(&ui, op_kind, status),
                        Err(e) => set_kp_status(&ui, op_kind, e),
                    }
                    // Refresh from local state regardless of op outcome; for
                    // "refresh" we additionally surface the relay snapshot.
                    if let Some(b) = b.as_ref() {
                        if let Some(rows) = rows {
                            ui.set_key_packages(ModelRc::new(VecModel::from(rows)));
                        } else {
                            refresh_kp_local_async(&ui, b);
                        }
                    }
                },
            );
        })
    };

    ui.global::<AppState>().on_kp_publish_clicked({
        let kp_run = kp_run.clone();
        move || kp_run("publish")
    });
    ui.global::<AppState>().on_kp_rotate_clicked({
        let kp_run = kp_run.clone();
        move || kp_run("rotate")
    });
    ui.global::<AppState>().on_kp_refresh_clicked({
        let kp_run = kp_run.clone();
        move || kp_run("refresh")
    });
}
