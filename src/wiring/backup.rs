use crate::*;

pub(crate) fn wire_backup(ui: &DarkMatterLinux, cx: &Cx, h: &Handlers) {
    let Cx {
        backend_cell,
        vault_cell,
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
                            ui.set_import_backup_status(s("Backend isn't ready yet."));
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
