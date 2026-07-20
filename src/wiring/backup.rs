use crate::*;

/// Push the "Last backup" receipt from persisted settings into the Storage
/// pane. An absent path leaves both properties empty, which is what keeps the
/// row unmounted on an install that has never written a backup; the stamp is
/// formatted here (not in Slint) so it honors the user's date/time preferences
/// like every other visible timestamp.
pub(crate) fn publish_last_backup(ui: &DarkMatterLinux, settings: &Settings) {
    let path = settings.last_backup_path.clone().unwrap_or_default();
    let stamp = settings
        .last_backup_at
        .filter(|_| !path.is_empty())
        .map(|secs| format_full_stamp(secs.max(0) as u64))
        .unwrap_or_default();
    ui.set_storage_last_backup_path(path.into());
    ui.set_storage_last_backup_at(stamp.into());
}

pub(crate) fn wire_backup(ui: &DarkMatterLinux, cx: &Cx, h: &Handlers) {
    let Cx {
        backend_cell,
        vault_cell,
        settings_cell,
        ..
    } = cx.clone();
    let Handlers {
        refresh_storage_size,
        ..
    } = h.clone();
    // ─── Whole-folder backup & restore ─────────────────────────────────
    // A backup is the entire data dir packed into one file, sealed with the
    // vault password (see backup.rs). Open the create-backup modal.
    ui.global::<AppState>().on_storage_create_backup({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_create_backup_password(s(""));
            ui.set_create_backup_status(s(""));
            ui.set_create_backup_busy(false);
            ui.set_show_create_backup(true);
        }
    });

    ui.global::<AppState>().on_create_backup_dismissed({
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
    ui.global::<AppState>().on_create_backup_submit({
        let weak = ui.as_weak();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let password = password.to_string();
            if password.is_empty() {
                ui.set_create_backup_status(error_copy().enter_password.into());
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
                            // Closing the modal is all the old success arm did,
                            // which looks exactly like a cancel. Say the write
                            // happened and name where it landed, then record it
                            // so the Storage pane keeps the receipt after the
                            // toast has faded.
                            let dest = dest.display().to_string();
                            set_status_feedback(
                                &ui,
                                tmpl(&error_copy().backup_saved, &[&dest]),
                                false,
                            );
                            ui.global::<AppState>()
                                .invoke_storage_backup_written(dest.into());
                        }
                        Err(backup::BackupError::WrongPassword) => {
                            ui.set_create_backup_status(error_copy().wrong_password.into());
                        }
                        Err(e) => {
                            ui.set_create_backup_status(
                                tmpl(&error_copy().backup_failed, &[&e.to_string()]).into(),
                            );
                        }
                    }
                });
            });
        }
    });

    // Persist the destination of a backup that just succeeded and republish the
    // Storage pane's row. Reached only from the write's completion hop, which
    // runs on the UI thread but can't carry `settings_cell` (an `Rc`) through
    // `invoke_from_event_loop` — routing through a callback keeps the cell here,
    // the shape `on_import_backup_submit` already uses to re-enter `unlock`.
    ui.global::<AppState>().on_storage_backup_written({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |dest| {
            let Some(ui) = weak.upgrade() else { return };
            {
                let mut st = settings_cell.borrow_mut();
                st.last_backup_path = Some(dest.to_string());
                st.last_backup_at = Some(now_unix_secs() as i64);
                st.save();
            }
            publish_last_backup(&ui, &settings_cell.borrow());
        }
    });

    // Open the import-backup modal. On a fresh install (no vault) it restores the
    // whole folder; otherwise it merges accounts — the modal copy follows suit.
    ui.global::<AppState>().on_storage_import_backup({
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

    ui.global::<AppState>().on_import_backup_dismissed({
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
    ui.global::<AppState>().on_import_backup_pick_file({
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
    ui.global::<AppState>().on_import_backup_submit({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let vault_cell = vault_cell.clone();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let path = ui.get_import_backup_path().to_string();
            if path.is_empty() {
                ui.set_import_backup_status(error_copy().choose_backup_file.into());
                return;
            }
            if password.is_empty() {
                ui.set_import_backup_status(error_copy().enter_backup_password.into());
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
                ui.set_import_backup_status(error_copy().restore_lock_only.into());
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
                                ui.global::<AppState>().invoke_unlock(password.into());
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
                            ui.set_import_backup_status(error_copy().backend_not_ready_yet.into());
                            return;
                        };
                        merge_imported_accounts(&ui, &backend, &vault_cell, nsecs);
                    });
                }
            });
        }
    });

    ui.global::<AppState>().on_storage_clear_cache({
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
}
