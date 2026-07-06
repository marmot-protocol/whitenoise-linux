use crate::*;

pub(crate) fn wire_backup(
    ui: &DarkMatterLinux,
    cx: &Cx,
    h: &Handlers,
    encryption_banner_seen: &Arc<Mutex<std::collections::HashSet<String>>>,
) {
    let Cx {
        notif,
        settings_cell,
        backend_cell,
        vault_cell,
        group_ids,
        archived_group_ids,
        pending_state,
        active_message_watcher,
        ..
    } = cx.clone();
    let Handlers {
        refresh_breadcrumb,
        refresh_storage_size,
        refresh_all_chat_models,
        ..
    } = h.clone();
    // ─── Whole-folder backup & restore ─────────────────────────────────
    // A backup is the entire data dir packed into one file, sealed with the
    // vault password (see backup.rs). Open the create-backup modal.
    ui.on_storage_create_backup({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_create_backup_password(s(""));
            ui.set_create_backup_status(s(""));
            ui.set_create_backup_busy(false);
            ui.set_show_create_backup(true);
        }
    });

    ui.on_create_backup_dismissed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_show_create_backup(false);
            ui.set_create_backup_password(s(""));
            ui.set_create_backup_status(s(""));
        }
    });

    // Confirm vault password → native save dialog → write the encrypted backup.
    // The picker is sync rfd on a plain thread (no backend needed, and never on
    // the UI thread).
    ui.on_create_backup_submit({
        let weak = ui.as_weak();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let password = password.to_string();
            if password.is_empty() {
                ui.set_create_backup_status(s("Enter your password."));
                return;
            }
            ui.set_create_backup_busy(true);
            ui.set_create_backup_status(s(""));
            let weak = weak.clone();
            std::thread::spawn(move || {
                let dest = rfd::FileDialog::new()
                    .set_title("Save backup")
                    .set_file_name(backup::DEFAULT_FILENAME)
                    .save_file();
                let Some(dest) = dest else {
                    // Cancelled — drop the busy state, leave the modal open.
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak.upgrade() {
                            ui.set_create_backup_busy(false);
                        }
                    });
                    return;
                };
                let result = backup::create(&dest, &password);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_create_backup_busy(false);
                    match result {
                        Ok(()) => {
                            ui.set_show_create_backup(false);
                            ui.set_create_backup_password(s(""));
                        }
                        Err(backup::BackupError::WrongPassword) => {
                            ui.set_create_backup_status(s("Wrong password."));
                        }
                        Err(e) => {
                            ui.set_create_backup_status(format!("Backup failed: {e}").into());
                        }
                    }
                });
            });
        }
    });

    // Open the import-backup modal. On a fresh install (no vault) it restores the
    // whole folder; otherwise it merges accounts — the modal copy follows suit.
    ui.on_storage_import_backup({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_import_backup_path(s(""));
            ui.set_import_backup_file(s(""));
            ui.set_import_backup_password(s(""));
            ui.set_import_backup_status(s(""));
            ui.set_import_backup_busy(false);
            ui.set_import_backup_restore_mode(!vault::exists());
            ui.set_show_import_backup(true);
        }
    });

    ui.on_import_backup_dismissed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_show_import_backup(false);
            ui.set_import_backup_path(s(""));
            ui.set_import_backup_password(s(""));
            ui.set_import_backup_status(s(""));
        }
    });

    // Native file picker for the backup file. Sync rfd on a plain thread so it
    // works before the backend exists (first-run restore) and never blocks the UI
    // thread. The chosen path round-trips through a Slint property (Send-safe).
    ui.on_import_backup_pick_file({
        let weak = ui.as_weak();
        move || {
            let weak = weak.clone();
            std::thread::spawn(move || {
                let Some(picked) = rfd::FileDialog::new()
                    .set_title("Import backup")
                    .pick_file()
                else {
                    return;
                };
                let name = picked
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| picked.display().to_string());
                let path = picked.display().to_string();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_import_backup_path(path.into());
                    ui.set_import_backup_file(name.into());
                    ui.set_import_backup_status(s(""));
                });
            });
        }
    });

    // Submit: decrypt the backup, then either restore the whole folder (fresh
    // install) or merge its accounts (running install). The branch is decided by
    // whether a vault already exists.
    ui.on_import_backup_submit({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let vault_cell = vault_cell.clone();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let path = ui.get_import_backup_path().to_string();
            if path.is_empty() {
                ui.set_import_backup_status(s("Choose a backup file first."));
                return;
            }
            if password.is_empty() {
                ui.set_import_backup_status(s("Enter the backup password."));
                return;
            }
            let path = std::path::PathBuf::from(path);
            let password = password.to_string();
            // Act on the mode the modal is actually showing (Restore vs Import),
            // not a freshly-recomputed predicate — the displayed copy and the
            // backend action stay in lockstep. The property was set from
            // `!vault::exists()` when the modal opened.
            let restoring = ui.get_import_backup_restore_mode();
            // `restore_into_home` overwrites the data dir, so re-check vault
            // presence now (not just at open time): a full restore must never
            // clobber an identity that came to exist while the modal was open.
            if restoring && vault::exists() {
                ui.set_import_backup_status(s(
                    "Full restore is only available from the lock screen, before unlocking.",
                ));
                return;
            }
            ui.set_import_backup_busy(true);
            ui.set_import_backup_status(s(""));
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            let vault_cell = vault_cell.clone();
            // Argon2id derive + archive IO — off the UI thread.
            std::thread::spawn(move || {
                if restoring {
                    // Fresh install: extract the whole folder, then unlock the
                    // restored vault with the same password to boot straight in.
                    let result = backup::restore_into_home(&path, &password);
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak.upgrade() else { return };
                        match result {
                            Ok(()) => {
                                ui.set_import_backup_busy(false);
                                ui.set_show_import_backup(false);
                                ui.set_import_backup_password(s(""));
                                // The restored vault.db unlocks with this very
                                // password — reuse the unlock path to boot.
                                ui.invoke_unlock(password.into());
                            }
                            Err(e) => {
                                ui.set_import_backup_busy(false);
                                ui.set_import_backup_status(import_backup_error(&e).into());
                            }
                        }
                    });
                } else {
                    // Running install: pull keys from the backup's vault.db and
                    // re-login the missing accounts.
                    let result = backup::merge_nsecs(&path, &password);
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak.upgrade() else { return };
                        let nsecs = match result {
                            Ok(n) => n,
                            Err(e) => {
                                ui.set_import_backup_busy(false);
                                ui.set_import_backup_status(import_backup_error(&e).into());
                                return;
                            }
                        };
                        let Some(backend) = backend_cell.lock().unwrap().clone() else {
                            ui.set_import_backup_busy(false);
                            ui.set_import_backup_status(s("Backend isn't ready yet."));
                            return;
                        };
                        merge_imported_accounts(&ui, &backend, &vault_cell, nsecs);
                    });
                }
            });
        }
    });

    let go_to_page = {
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let refresh_storage = refresh_storage_size.clone();
        move |page: Page| {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_active_page(page as i32);
            refresh();
            // Settings can land on the Storage tab — make sure the size is fresh.
            if matches!(page, Page::Settings) {
                refresh_storage();
            }
        }
    };

    ui.on_storage_clear_cache({
        let weak = ui.as_weak();
        let refresh_storage = refresh_storage_size.clone();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_storage_clearing(true);
            }
            let weak = weak.clone();
            let refresh_storage = refresh_storage.clone();
            std::thread::spawn(move || {
                media_cache::clear();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = weak.upgrade() {
                        ui.set_storage_clearing(false);
                    }
                });
                // Repopulate the (now ~0) size label.
                refresh_storage();
            });
        }
    });

    ui.on_nav_requested({
        let go = go_to_page.clone();
        move |idx| {
            let page = match idx {
                0 => Page::Chats,
                1 => Page::Contacts,
                2 => Page::Archived,
                3 => Page::Keys,
                4 => Page::Settings,
                _ => Page::Chats,
            };
            go(page);
        }
    });
    ui.on_profile_requested({
        let go = go_to_page.clone();
        move || go(Page::Profile)
    });
    ui.on_new_chat_requested({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_new_chat(true);
            }
        }
    });
    ui.on_modal_dismissed({
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
    ui.on_start_chat({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |name, members_text| {
            let Some(ui) = weak.upgrade() else { return };
            let name = name.to_string();
            let members = parse_member_list(&members_text);
            if members.is_empty() {
                ui.set_new_chat_status(s("Add at least one npub."));
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_new_chat_status(s("Backend not ready."));
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
                ui.set_new_chat_status(s("Can't start a chat with only yourself."));
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
                                    ui.invoke_chat_selected(pos as i32);
                                }
                            });
                            ui.set_new_chat_name(s(""));
                            ui.set_new_chat_members(s(""));
                            ui.set_new_chat_status(s(""));
                            ui.set_show_new_chat(false);
                        }
                        Err(e) => {
                            tracing::warn!(target: "create_group", "{e:#}");
                            ui.set_new_chat_status(friendly_error("create chat", &e).into());
                        }
                    }
                });
            });
        }
    });
    ui.on_chat_selected({
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let active_watcher = active_message_watcher.clone();
        let pending_state = pending_state.clone();
        let banner_seen = encryption_banner_seen.clone();
        let notif = notif.clone();
        let settings_cell = settings_cell.clone();
        move |idx| {
            if let Some(ui) = weak.upgrade() {
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
                ui.set_reply_target_id(s(""));
                ui.set_reply_target_author(s(""));
                ui.set_reply_target_preview(s(""));
                ui.set_reply_target_image(slint::Image::default());
                ui.set_reply_target_has_image(false);
                ui.set_editing_message_id(s(""));
                refresh();
                let Some(backend) = backend_cell.lock().unwrap().clone() else {
                    return;
                };
                let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
                // Reflect this chat's mute state in the header bell.
                ui.set_active_chat_muted(group_hex.as_deref().is_some_and(|g| notif.is_muted(g)));
                trigger_encryption_banner_entrance(&ui, group_hex.as_deref(), &banner_seen);
                if let Some(group_hex) = group_hex {
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
                        st.last_read.insert(group_hex.clone(), now);
                        st.save();
                    }
                    clear_chat_unread_row(&ui, idx as usize);
                    refresh_unread_chrome(&ui);
                    // Re-entering a chat always starts from the default
                    // window — expanded history is per-visit.
                    msg_window_reset(&group_hex);
                    ui.set_show_chat_members(false);
                    push_group_members_to_ui_async(&ui, &backend, &group_hex);
                    // Snapshot read rides the backend runtime (sqlite can
                    // stall behind sync writes or a slow disk); rows are
                    // built back on the UI thread, merged with any pending
                    // overlay so chat switching doesn't drop pending bubbles.
                    let idx = idx as usize;
                    let my_id = backend.account().account_id_hex.clone();
                    let weak = ui.as_weak();
                    let backend_cell = backend_cell.clone();
                    let pending_state = pending_state.clone();
                    let active_watcher = active_watcher.clone();
                    let b = backend.clone();
                    backend.tokio_handle().spawn(async move {
                        // Membership first: the rebuild below resolves mention
                        // chips (name + member "@") from this registration, and
                        // the concurrent members-panel fetch may land later.
                        // Membership first: the rebuild below resolves the
                        // member "@" prefix from this registration, and the
                        // concurrent members-panel fetch may land later.
                        warm_group_mentions(&b, &group_hex);
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
                            tracing::debug!(
                                target: "switch_timing", "chat {idx}: {} records rebuilt in {:?}",
                                msgs.len(),
                                t_switch.elapsed()
                            );
                            // Global affordances only if this chat is still
                            // the active one (rapid switches can supersede
                            // this fetch; the rows above still land in the
                            // right per-chat slot either way).
                            if ui.get_active_chat() as usize == idx {
                                ui.set_messages_has_older(msgs.len() >= MESSAGE_WINDOW);
                                // Opening a chat should land you at the most
                                // recent message, not the top of the history.
                                ui.set_messages_scroll_tick(ui.get_messages_scroll_tick() + 1);
                                // Then attach a live watcher for new arrivals
                                // (after the rebuild, so no echo lands in the
                                // gap and gets overwritten). Abort any
                                // previous one so we don't pile them up.
                                if let Some(prev) = active_watcher.lock().unwrap().take() {
                                    prev.abort();
                                }
                                let handle = install_message_watcher(
                                    &b,
                                    ui.as_weak(),
                                    backend_cell.clone(),
                                    pending_state.clone(),
                                    group_hex,
                                    idx,
                                    my_id,
                                );
                                *active_watcher.lock().unwrap() = Some(handle);
                            }
                        });
                    });
                }
            }
        }
    });
    // "Load earlier messages" at the top of the messages view: grow the
    // active chat's record window one MESSAGE_WINDOW step and rebuild. The
    // Slint side anchors the scroll so the content the user was reading
    // stays put under the newly-prepended history.
    ui.on_messages_request_older({
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
    ui.on_contact_selected({
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        move |idx| {
            if let Some(ui) = weak.upgrade() {
                ui.set_active_contact(idx);
                refresh();
            }
        }
    });
    ui.on_archive_selected({
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
    ui.on_members_toggle_clicked({
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

    ui.on_accept_chat_request({
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
                        ui.set_backend_error(friendly_error("accept", &e).into());
                        return;
                    }
                    refresh();
                });
            });
        }
    });

    ui.on_block_chat_request({
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
                        ui.set_backend_error(friendly_error("block", &e).into());
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
    ui.on_archive_chat({
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
                        ui.set_backend_error(friendly_error("archive", &e).into());
                        refresh_cb();
                    });
                }
            });
        }
    });

    ui.on_unarchive_chat({
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
            // is rendered as "mls:0x<short>", hence the round-trip.
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
                                ui.set_backend_error(friendly_error("unarchive", &e).into());
                                refresh_cb();
                            });
                        }
                    });
                });
            });
        }
    });

    // ─── Command palette wiring ────────────────────────────────────────
    let palette_master = all_palette_actions();

    // Ctrl+K: populate actions for the empty query and open the palette.
    ui.on_palette_requested({
        let weak = ui.as_weak();
        let master = palette_master.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_palette_query(s(""));
            ui.set_palette_actions(model(filter_palette(&master, "")));
            ui.set_show_palette(true);
        }
    });

    ui.on_palette_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_palette(false);
            }
        }
    });

    ui.on_palette_query_changed({
        let weak = ui.as_weak();
        let master = palette_master.clone();
        move |q| {
            if let Some(ui) = weak.upgrade() {
                ui.set_palette_actions(model(filter_palette(&master, q.as_str())));
            }
        }
    });

    ui.on_palette_execute({
        let weak = ui.as_weak();
        let go = go_to_page.clone();
        let settings_cell = settings_cell.clone();
        move |id| {
            let Some(ui) = weak.upgrade() else { return };
            match id.as_str() {
                "nav.chats" => go(Page::Chats),
                "nav.contacts" => go(Page::Contacts),
                "nav.archived" => go(Page::Archived),
                "nav.keys" => go(Page::Keys),
                "nav.settings" => go(Page::Settings),
                "nav.profile" => go(Page::Profile),
                "act.new-chat" => ui.set_show_new_chat(true),
                "act.copy-npub" => {
                    let npub = ui.get_my_npub();
                    copy_to_clipboard_async(npub.to_string(), |result| {
                        if let Err(e) = result {
                            tracing::warn!(target: "clipboard", "copy npub failed: {e}");
                        }
                    });
                }
                "act.toggle-retro" => {
                    let mode = if ui.get_retro_mode() { "dark" } else { "retro" };
                    {
                        let mut s = settings_cell.borrow_mut();
                        s.theme = mode.into();
                        s.save();
                    }
                    apply_theme_mode(&ui, mode);
                }
                _ => {}
            }
        }
    });
}
