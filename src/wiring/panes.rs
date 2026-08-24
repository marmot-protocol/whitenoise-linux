use crate::*;

pub(crate) fn wire_panes(
    ui: &WhiteNoiseLinux,
    cx: &Cx,
    h: &Handlers,
    boot_backend: &BootFn,
    pending_generated: &Arc<Mutex<Option<String>>>,
    pending_profile_seed: &Arc<Mutex<Option<String>>>,
    pending_profile_name: &Arc<Mutex<Option<String>>>,
) {
    let Cx {
        notif,
        settings_cell,
        backend_cell,
        vault_cell,
        group_ids,
        archived_group_ids,
        pending_state,
        staged_files,
        active_message_watcher,
        chats_watcher,
        ..
    } = cx.clone();
    let Handlers {
        refresh_breadcrumb,
        refresh_storage_size,
        ..
    } = h.clone();
    // ─── Account switching ─────────────────────────────────────────────
    // Swap the displayed account: stop the per-account watchers, drop the
    // optimistic overlay and all per-account models *synchronously* (so a
    // stray send can't resolve an index against the previous account's group
    // list), then rebuild everything from the new account's snapshots. All
    // accounts keep their background sessions — this is a view change, not a
    // re-login. `Arc<dyn Fn + Send + Sync>` (not `Rc`) so the add-account
    // completion — which hops through a tokio worker before
    // `invoke_from_event_loop` — can carry a handle; it is only ever
    // *invoked* on the UI thread.
    let do_switch_account: Arc<dyn Fn(String) + Send + Sync> = {
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let vault_cell = vault_cell.clone();
        let group_ids = group_ids.clone();
        let archived_group_ids = archived_group_ids.clone();
        let pending_state = pending_state.clone();
        let staged_files = staged_files.clone();
        let active_message_watcher = active_message_watcher.clone();
        let chats_watcher = chats_watcher.clone();
        let notif = notif.clone();
        Arc::new(move |account_id: String| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            if backend
                .account()
                .account_id_hex
                .eq_ignore_ascii_case(&account_id)
            {
                ui.set_show_account_switcher(false);
                return;
            }
            let summary = match backend.set_active_account(&account_id) {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!(target: "accounts", "switch failed: {e:#}");
                    show_backend_error(&ui, friendly_error(ErrorOp::SwitchAccount, &e));
                    return;
                }
            };
            advance_account_epoch();
            // Remember the choice for the next unlock.
            if let Some(vault) = vault_cell.lock().unwrap().clone() {
                vault_set_async(
                    &vault,
                    vault::ACTIVE_ACCOUNT_KEY.to_string(),
                    summary.account_id_hex.to_ascii_lowercase(),
                );
            }
            // Stop the previous account's streams before the models change
            // under them, and drop its optimistic overlay outright.
            if let Some(h) = active_message_watcher.lock().unwrap().take() {
                h.abort();
            }
            if let Some(h) = chats_watcher.lock().unwrap().take() {
                h.abort();
            }
            *pending_state.lock().unwrap() = PendingState::default();
            // Point the "delete for me" renderer at the new account's hidden set
            // before any rows rebuild, so hides don't leak across the switch.
            hidden_set_account(&summary.account_id_hex);
            // Clear every per-account model + selection synchronously so
            // nothing can act on stale rows while the rebuild is in flight.
            group_ids.lock().unwrap().clear();
            archived_group_ids.lock().unwrap().clear();
            if let Some(vm) = ui.get_chats().as_any().downcast_ref::<VecModel<ChatMeta>>() {
                vm.set_vec(Vec::new());
            }
            if let Some(vm) = ui
                .get_chats_messages()
                .as_any()
                .downcast_ref::<VecModel<ModelRc<ChatMessage>>>()
            {
                vm.set_vec(Vec::new());
            }
            if let Some(vm) = ui
                .get_contacts()
                .as_any()
                .downcast_ref::<VecModel<Contact>>()
            {
                vm.set_vec(Vec::new());
            }
            if let Some(vm) = ui
                .get_archived_chats()
                .as_any()
                .downcast_ref::<VecModel<ArchivedChat>>()
            {
                vm.set_vec(Vec::new());
            }
            ui.set_active_chat(0);
            ui.set_active_contact(0);
            ui.set_active_archived(0);
            ui.set_mention_inbox_items(model(Vec::<MentionInboxItem>::new()));
            ui.set_mention_inbox_loading(false);
            ui.set_message_jump_id(s(""));
            ui.set_active_page(0);
            ui.set_show_chat_members(false);
            ui.set_messages_has_older(false);
            ui.set_messages_loading(false);
            ui.set_composer_draft(s(""));
            staged_files.lock().unwrap().clear();
            refresh_staged_ui(&ui, &[]);
            clear_reply_target(&ui);
            ui.set_editing_message_id(s(""));
            if let Ok(mut slot) = active_group_slot().lock() {
                slot.clear();
            }
            // Identity-bound chrome for the new account.
            if let Ok(npub) = npub_for_account_id(&summary.account_id_hex) {
                ui.set_my_qr(qr_image(&deeplink::profile_qr_url(&npub)));
                ui.set_my_npub(npub.into());
            }
            // Reset the avatar to the new account's deterministic fallback;
            // populate_profile_async upgrades it once the profile loads.
            ui.set_my_av_has_picture(false);
            ui.set_my_av_picture(slint::Image::default());
            ui.set_my_av_load_failed(false);
            set_my_avatar(&ui, &backend);
            refresh_breadcrumb_now(&ui);
            // Rebuild from the new account's snapshots and re-subscribe.
            populate_models_for_active(&ui, &backend, &group_ids, &archived_group_ids);
            // Backfill the built-in "Saved Messages" chat for accounts that have
            // never had one (off-thread; pins itself in once created).
            ensure_self_chat_async(&ui, &backend, &group_ids);
            install_chat_watcher(
                &backend,
                ui.as_weak(),
                group_ids.clone(),
                backend_cell.clone(),
                notif.clone(),
                now_unix_secs(),
                &chats_watcher,
            );
            refresh_accounts_model(&ui, &backend);
            ui.set_show_account_switcher(false);
        })
    };

    wire!(ui, on_account_switcher_requested [backend_cell], |ui| {
        let Some(b) = backend_cell.lock().unwrap().clone() else {
            return;
        };
        refresh_accounts_model(&ui, &b);
        ui.set_show_account_switcher(true);
    });

    ui.global::<AppState>().on_switch_account({
        let do_switch = do_switch_account.clone();
        move |id| do_switch(id.to_string())
    });

    // Sign out of a single account and take its key off the device: marmot drops
    // the account's group state and (via VaultSecretStore) its signing secret,
    // then we delete the app-written nsec backup so it can't be re-imported at
    // boot. Removing the active account switches to a survivor; removing the
    // last account falls back to the first-run screen, mirroring reset-vault.
    wire!(ui, on_remove_account [backend_cell, vault_cell, do_switch_account], |ui, id| {
        let Some(backend) = backend_cell.lock().unwrap().clone() else {
            return;
        };
        let id = id.to_string();
        let was_active = backend.account().account_id_hex.eq_ignore_ascii_case(&id);
        if let Err(e) = backend.remove_account(&id) {
            tracing::warn!(target: "accounts", "remove failed: {e:#}");
            show_backend_error(&ui, friendly_error(ErrorOp::RemoveAccount, &e));
            return;
        }
        // marmot doesn't know about the app's `nsec:<hex>` backup, so drop it
        // explicitly — otherwise `import_nsecs_from_bytes` re-imports the
        // account on the next unlock.
        if let Some(vault) = vault_cell.lock().unwrap().clone()
            && let Ok(mut v) = vault.lock()
        {
            let _ = v.remove(&vault::nsec_key_for(&id));
        }
        let survivors = backend.accounts();
        if survivors.is_empty() {
            // Nothing left to unlock into. Wipe the vault and return to the
            // first-run choose screen, the same path "Use another key" takes.
            if let Err(e) = vault::delete() {
                tracing::warn!(target: "accounts", "vault delete after last account: {e}");
            }
            offline_queue::clear();
            ui.set_show_account_switcher(false);
            ui.set_logged_in(false);
            ui.set_password_input(s(""));
            ui.set_password_confirm(s(""));
            ui.set_login_error(s(""));
            ui.set_login_mode(0);
            return;
        }
        if was_active {
            // The active pointer still names the removed account; switch to a
            // survivor, which rebuilds every model, rewrites the persisted
            // active-account hint, and closes the switcher.
            do_switch_account(survivors[0].account_id_hex.clone());
        } else {
            // Active account is untouched — just rebuild the roster in place
            // so the removed row drops out and the switcher stays open.
            refresh_accounts_model(&ui, &backend);
        }
    });

    wire!(ui, on_add_account_requested [], |ui| {
        ui.set_show_account_switcher(false);
        ui.set_add_account_nsec(s(""));
        ui.set_add_account_status(s(""));
        ui.set_add_account_generated(false);
        ui.set_add_account_busy(false);
        ui.set_show_add_account(true);
    });

    wire!(ui, on_add_account_dismissed [], |ui| {
        ui.set_show_add_account(false);
        ui.set_add_account_nsec(s(""));
        ui.set_add_account_generated(false);
        ui.set_add_account_status(s(""));
    });

    wire!(ui, on_generate_add_account_key [], |ui| {
        let keys = Keys::generate();
        match keys.secret_key().to_bech32() {
            Ok(nsec) => {
                ui.set_add_account_nsec(nsec.into());
                ui.set_add_account_generated(true);
                ui.set_add_account_status(s(""));
            }
            Err(e) => ui.set_add_account_status(
                tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into(),
            ),
        }
    });

    wire!(ui, on_add_account_nsec_edited [], |ui| {
        ui.set_add_account_generated(false);
    });

    wire!(ui, on_add_account [backend_cell, vault_cell, do_switch_account], |ui, nsec_input| {
        let raw = nsec_input.trim().to_string();
        let Ok(keys) = Keys::parse(&raw) else {
            ui.set_add_account_status(error_copy().invalid_nsec.into());
            return;
        };
        let Some(backend) = backend_cell.lock().unwrap().clone() else {
            ui.set_add_account_status(error_copy().backend_not_ready_yet.into());
            return;
        };
        // Canonical bech32 form for vault storage, whatever was pasted.
        let nsec = match keys.secret_key().to_bech32() {
            Ok(n) => n,
            Err(e) => {
                ui.set_add_account_status(
                    tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into(),
                );
                return;
            }
        };
        let account_id = keys.public_key().to_hex();
        // A key generated in this dialog can't have a profile yet; a
        // pasted one may — only generated keys get a random starter name.
        let generated = ui.get_add_account_generated();
        ui.set_add_account_busy(true);
        ui.set_add_account_status(s(""));
        let weak = ui.as_weak();
        let vault_cell = vault_cell.clone();
        let do_switch = do_switch_account.clone();
        let backend_for_seed = backend.clone();
        backend.add_account_async(nsec.clone(), move |result| {
            ui_update!(weak, move |ui| {
                ui.set_add_account_busy(false);
                match result {
                    Ok(summary) => {
                        // Seal the new key into the session vault so the
                        // account survives restarts (marmot's own secret
                        // landed there too, via VaultSecretStore).
                        if let Some(vault) = vault_cell.lock().unwrap().clone() {
                            vault_set_async(
                                &vault,
                                vault::nsec_key_for(&account_id),
                                nsec.clone(),
                            );
                        }
                        ui.set_show_add_account(false);
                        ui.set_add_account_nsec(s(""));
                        ui.set_add_account_generated(false);
                        if generated {
                            publish_random_profile_async(
                                &backend_for_seed,
                                summary.label.clone(),
                                summary.account_id_hex.clone(),
                                None,
                                ui.as_weak(),
                                || {},
                            );
                        }
                        do_switch(summary.account_id_hex);
                    }
                    Err(e) => {
                        tracing::warn!(target: "add_account", "{e:#}");
                        ui.set_add_account_status(
                            friendly_error(ErrorOp::AddAccount, &e).into(),
                        );
                    }
                }
            });
        });
    });

    // There is no silent auto-login anymore: secrets live in a password-encrypted
    // vault. If a vault exists, open on the Unlock screen (mode 3); otherwise the
    // first-run "choose" screen (mode 0). The vault is only decrypted once the
    // user supplies the password.
    if vault::exists() {
        ui.set_login_mode(3);
    } else {
        ui.set_login_mode(0);
    }

    // Mirror the vault-password gate into the UI so the primary action can be
    // disabled until the password + confirm are valid, without duplicating the
    // rules in Slint. Returns true when `validate_new_password` accepts them.
    ui.global::<AppState>()
        .on_login_password_valid(|password, confirm| {
            validate_new_password(password.as_str(), confirm.as_str()).is_ok()
        });

    // First run, existing nsec: validate the key + new password, create the vault,
    // seal the nsec into it, then boot.
    ui.global::<AppState>().on_login_with_nsec({
        let weak = ui.as_weak();
        let boot = boot_backend.clone();
        move |input, password, confirm| {
            let Some(ui) = weak.upgrade() else { return };
            let trimmed = input.trim().to_string();
            let password = password.to_string();
            // Cheap validation stays here so typos fail instantly; the
            // Argon2id KDF inside `Vault::create` is deliberately slow, so it
            // runs on a worker thread and the busy state gets a frame to paint.
            if let Err(err) = validate_new_password(&password, confirm.as_str()) {
                ui.set_login_error(err.into());
                return;
            }
            let Ok(keys) = Keys::parse(&trimmed) else {
                ui.set_login_error(error_copy().invalid_nsec.into());
                return;
            };
            ui.set_login_busy(true);
            let weak = weak.clone();
            let boot = boot.clone();
            spawn_ui(
                weak,
                move || -> Result<(String, String, Arc<Mutex<Vault>>), String> {
                    let npub = keys.public_key().to_bech32().map_err(|e| e.to_string())?;
                    let nsec = keys.secret_key().to_bech32().map_err(|e| e.to_string())?;
                    let mut v = Vault::create(&password).map_err(|e| format!("save key: {e}"))?;
                    v.set(vault::NSEC_KEY, &nsec)
                        .map_err(|e| format!("seal nsec: {e}"))?;
                    Ok((npub, nsec, Arc::new(Mutex::new(v))))
                },
                move |ui, result| {
                    ui.set_login_busy(false);
                    match result {
                        Ok((npub, nsec, vault)) => {
                            ui.set_login_error(s(""));
                            ui.set_my_qr(qr_image(&deeplink::profile_qr_url(&npub)));
                            ui.set_my_npub(npub.into());
                            ui.set_login_nsec_input(s(""));
                            ui.set_password_input(s(""));
                            ui.set_password_confirm(s(""));
                            ui.set_logged_in(true);
                            boot(nsec, vault, None);
                        }
                        Err(err) => {
                            ui.set_login_error(err.into());
                        }
                    }
                },
            );
        }
    });

    // Unlock an existing vault: decrypt with the password, pull the nsec, boot.
    ui.global::<AppState>().on_unlock({
        let weak = ui.as_weak();
        let boot = boot_backend.clone();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let password = password.to_string();
            ui.set_login_busy(true);
            // `Vault::open` re-derives the Argon2id key — worker thread, so
            // the unlock spinner actually spins while it grinds.
            let weak = weak.clone();
            let boot = boot.clone();
            type UnlockOutcome =
                Result<(String, String, Arc<Mutex<Vault>>, Option<String>), String>;
            spawn_ui(
                weak,
                move || -> UnlockOutcome {
                    let v = Vault::open(&password).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        other => format!("{other}"),
                    })?;
                    let nsec = v.nsec().ok_or_else(|| error_copy().no_key_stored)?;
                    let keys = Keys::parse(&nsec).map_err(|_| error_copy().stored_key_invalid)?;
                    let npub = keys.public_key().to_bech32().map_err(|e| e.to_string())?;
                    // The account the user last had active — boot displays it
                    // instead of the primary when it still exists.
                    let active = v.get(vault::ACTIVE_ACCOUNT_KEY).map(|s| s.to_string());
                    Ok((npub, nsec, Arc::new(Mutex::new(v)), active))
                },
                move |ui, result| {
                    ui.set_login_busy(false);
                    match result {
                        Ok((npub, nsec, vault, active)) => {
                            ui.set_login_error(s(""));
                            ui.set_password_input(s(""));
                            ui.set_my_qr(qr_image(&deeplink::profile_qr_url(&npub)));
                            ui.set_my_npub(npub.into());
                            ui.set_logged_in(true);
                            boot(nsec, vault, active);
                        }
                        Err(err) => {
                            ui.set_login_error(err.into());
                        }
                    }
                },
            );
        }
    });

    // "Reset & use another key" on the unlock screen. No password recovery exists,
    // so this deletes the vault and returns to first-run choose.
    wire!(ui, on_reset_vault [], |ui| {
        if let Err(e) = vault::delete() {
            tracing::warn!(target: "login", "vault reset failed: {e}");
        }
        // Queued sends were sealed under the old vault key — unreadable now.
        offline_queue::clear();
        ui.set_password_input(s(""));
        ui.set_password_confirm(s(""));
        ui.set_login_error(s(""));
        ui.set_login_mode(0);
    });

    wire!(ui, on_generate_key_requested [pending_generated, pending_profile_name], |ui| {
        tracing::debug!(target: "login", "generate_key_requested fired");
        let keys = Keys::generate();
        let nsec = match keys.secret_key().to_bech32() {
            Ok(v) => v,
            Err(e) => {
                ui.set_login_error(
                    tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into(),
                );
                return;
            }
        };
        let npub = match keys.public_key().to_bech32() {
            Ok(v) => v,
            Err(e) => {
                ui.set_login_error(
                    tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into(),
                );
                return;
            }
        };
        *pending_generated.lock().unwrap() = Some(nsec.clone());
        let name = random_profile_name();
        *pending_profile_name.lock().unwrap() = Some(name.clone());
        ui.set_generated_display_name(name.clone().into());
        if let Some(img) = local_animal_avatar_image(&npub, &name) {
            ui.set_generated_avatar(img);
            ui.set_generated_has_avatar(true);
        } else {
            ui.set_generated_has_avatar(false);
        }
        ui.set_generated_nsec(nsec.into());
        ui.set_generated_npub(npub.into());
        ui.set_login_error(s(""));
        ui.set_login_status(s(""));
        ui.set_login_mode(2);
    });

    ui.global::<AppState>().on_confirm_saved_key({
        let weak = ui.as_weak();
        let pending = pending_generated.clone();
        let pending_seed = pending_profile_seed.clone();
        let boot = boot_backend.clone();
        move |password, confirm| {
            tracing::debug!(target: "login", "confirm_saved_key fired");
            let Some(ui) = weak.upgrade() else { return };
            let Some(nsec) = pending.lock().unwrap().clone() else {
                tracing::warn!(target: "login", "no pending generated key");
                ui.set_login_error(error_copy().no_generated_key.into());
                ui.set_login_mode(0);
                return;
            };
            let password = password.to_string();
            ui.set_login_status(s(""));
            ui.set_login_busy(true);
            // Vault creation runs the Argon2id KDF — off the UI thread.
            let weak = weak.clone();
            let boot = boot.clone();
            let pending = pending.clone();
            let pending_seed = pending_seed.clone();
            // `boot` in the completion consumes `nsec` too; give the worker its own copy.
            let nsec_for_seal = nsec.clone();
            spawn_ui(
                weak,
                move || -> Result<(String, String, Arc<Mutex<Vault>>), String> {
                    let nsec = nsec_for_seal;
                    validate_new_password(&password, confirm.as_str())?;
                    let keys = Keys::parse(&nsec).map_err(|e| format!("parse: {e}"))?;
                    let npub = keys
                        .public_key()
                        .to_bech32()
                        .map_err(|e| format!("npub encode: {e}"))?;
                    let id_hex = keys.public_key().to_hex();
                    let mut v = Vault::create(&password).map_err(|e| format!("save key: {e}"))?;
                    v.set(vault::NSEC_KEY, &nsec)
                        .map_err(|e| format!("seal nsec: {e}"))?;
                    Ok((npub, id_hex, Arc::new(Mutex::new(v))))
                },
                move |ui, result| {
                    ui.set_login_busy(false);
                    match result {
                        Ok((npub, id_hex, vault)) => {
                            tracing::debug!(target: "login", "sealed nsec into vault, logging in as {npub}");
                            *pending.lock().unwrap() = None;
                            // Freshly generated key: have boot seed a random
                            // starter profile once it comes up.
                            *pending_seed.lock().unwrap() = Some(id_hex);
                            ui.set_login_error(s(""));
                            ui.set_my_qr(qr_image(&deeplink::profile_qr_url(&npub)));
                            ui.set_my_npub(npub.into());
                            ui.set_generated_nsec(s(""));
                            ui.set_generated_npub(s(""));
                            ui.set_generated_display_name(s(""));
                            ui.set_generated_has_avatar(false);
                            ui.set_password_input(s(""));
                            ui.set_password_confirm(s(""));
                            ui.set_logged_in(true);
                            boot(nsec, vault, None);
                        }
                        Err(err) => {
                            tracing::warn!(target: "login", "save failed: {err}");
                            ui.set_login_error(err.into());
                        }
                    }
                },
            );
        }
    });

    ui.global::<AppState>().on_copy_nsec({
        let weak = ui.as_weak();
        move |nsec| {
            let weak = weak.clone();
            copy_secret_to_clipboard_async(nsec.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => {
                        ui.set_login_error(s(""));
                        ui.set_login_status(error_copy().nsec_copied.into());
                        set_status_feedback(&ui, error_copy().nsec_copied, false);
                    }
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy nsec failed: {e}");
                        let msg: SharedString = error_copy().clipboard_failed_nsec.into();
                        ui.set_login_status(s(""));
                        ui.set_login_error(msg.clone());
                        set_status_feedback(&ui, msg, true);
                    }
                }
            });
        }
    });

    ui.global::<AppState>().on_copy_npub({
        let weak = ui.as_weak();
        move |npub| {
            let weak = weak.clone();
            copy_to_clipboard_async(npub.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => {
                        ui.set_login_error(s(""));
                        ui.set_login_status(error_copy().npub_copied.into());
                        set_status_feedback(&ui, error_copy().npub_copied, false);
                    }
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy npub failed: {e}");
                        let msg: SharedString = error_copy().clipboard_failed.into();
                        ui.set_login_status(s(""));
                        ui.set_login_error(msg.clone());
                        set_status_feedback(&ui, msg, true);
                    }
                }
            });
        }
    });

    // ─── Debug pane ────────────────────────────────────────────────────
    // Settings persist the toggle across launches. The pane itself is gated
    // behind that toggle; when off, the sidebar entry doesn't even render.
    ui.set_debug_enabled(settings_cell.borrow().debug_enabled);

    wire!(ui, on_change_language_clicked [], |ui| {
        ui.set_show_language_picker(true);
    });

    wire!(ui, on_locale_selected [settings_cell], |ui, code| {
        let locale = normalize_locale(code.as_str()).to_string();
        apply_locale(&locale);
        {
            let mut s = settings_cell.borrow_mut();
            s.locale = locale.clone();
            s.save();
        }
        ui.set_locale(s(&locale));
        ui.set_locale_display(s(locale_display(&locale)));
        ui.set_show_language_picker(false);
        // Re-snapshot the now-localized error/status copy for worker threads.
        refresh_error_copy(&ui);
        refresh_time_copy(&ui);
        refresh_system_copy(&ui);
    });

    wire!(ui, on_theme_mode_selected [settings_cell], |ui, mode| {
        let mode = normalize_theme_mode(mode.as_str()).to_string();
        {
            let mut s = settings_cell.borrow_mut();
            s.theme = mode.clone();
            s.save();
        }
        apply_theme_mode(&ui, &mode);
    });

    // The window root pushes `Theme.body-fs` here on every theme change (and
    // once at init). Message text is wrapped in Rust against that size, so
    // record it for the next build and re-wrap what is already on screen.
    wire!(ui, on_body_fs_changed [], |ui, px| {
        if !set_body_fs(px) {
            return;
        }
        rewrap_all_message_lines(&ui);
    });

    // Debounced push from `messages.slint` whenever the chat pane's content
    // width settles — window resize, the members panel opening, or the
    // centred-conversation toggle all move it. Message text is wrapped in
    // Rust against a fixed per-direction cap that assumes a wide-enough pane
    // (see `clamp_bubble_max`), so a narrower live width needs the clamp and
    // every already-built row's lines refreshed together.
    wire!(ui, on_chat_pane_width_changed [], |ui, px| {
        if !set_bubble_budget(px) {
            return;
        }
        rewrap_all_message_lines_for_pane_width(&ui);
    });

    wire!(ui, on_accent_selected [settings_cell], |ui, idx| {
        let color = accent_color_name(idx);
        {
            let mut s = settings_cell.borrow_mut();
            s.accent_color = color.to_string();
            s.save();
        }
        set_accent_index(&ui, accent_color_idx(color));
    });

    ui.global::<AppState>().on_debug_toggled({
        let settings_cell = settings_cell.clone();
        move |on| {
            let mut s = settings_cell.borrow_mut();
            s.debug_enabled = on;
            s.save();
        }
    });

    ui.global::<AppState>().on_outgoing_on_right_toggled({
        let settings_cell = settings_cell.clone();
        move |on| {
            let mut s = settings_cell.borrow_mut();
            s.outgoing_on_right = on;
            s.save();
        }
    });

    // Chat-shell bento column widths: persist the dragged sizes so the layout
    // survives restarts.
    ui.global::<AppState>().on_shell_widths_changed({
        let settings_cell = settings_cell.clone();
        move |chats_w, info_w| {
            let mut s = settings_cell.borrow_mut();
            s.shell_chats_width = chats_w;
            s.shell_info_width = info_w;
            s.save();
        }
    });

    ui.global::<AppState>().on_shell_centered_toggled({
        let settings_cell = settings_cell.clone();
        move |on| {
            let mut s = settings_cell.borrow_mut();
            s.centered_conversation = on;
            s.save();
        }
    });

    wire!(ui, on_launch_at_login_toggled [settings_cell], |ui, on| {
        if let Err(e) = startup::set_launch_at_login(on) {
            tracing::warn!(target: "startup", on, "set launch-at-login failed: {e}");
            ui.set_launch_at_login(!on);
            return;
        }
        let mut s = settings_cell.borrow_mut();
        s.launch_at_login = on;
        s.save();
    });

    ui.global::<AppState>().on_start_minimized_to_tray_toggled({
        let settings_cell = settings_cell.clone();
        move |on| {
            let mut s = settings_cell.borrow_mut();
            s.start_minimized_to_tray = on;
            s.save();
        }
    });

    wire!(ui, on_restore_last_selected_chat_toggled [settings_cell, group_ids], |ui, on| {
        let current = group_ids
            .lock()
            .unwrap()
            .get(ui.get_active_chat() as usize)
            .cloned();
        let mut s = settings_cell.borrow_mut();
        s.restore_last_selected_chat = on;
        if on && current.is_some() {
            s.last_selected_chat = current;
        }
        s.save();
    });

    ui.global::<AppState>().on_notifications_toggled({
        let settings_cell = settings_cell.clone();
        let notif = notif.clone();
        move |on| {
            notif
                .enabled
                .store(on, std::sync::atomic::Ordering::Relaxed);
            let mut s = settings_cell.borrow_mut();
            s.notifications_enabled = on;
            s.save();
        }
    });
    ui.global::<AppState>().on_notification_sound_toggled({
        let settings_cell = settings_cell.clone();
        let notif = notif.clone();
        move |on| {
            notif.sound.store(on, std::sync::atomic::Ordering::Relaxed);
            let mut s = settings_cell.borrow_mut();
            s.notification_sound = on;
            s.save();
        }
    });
    ui.global::<AppState>().on_notification_preview_toggled({
        let settings_cell = settings_cell.clone();
        let notif = notif.clone();
        move |on| {
            notif
                .preview
                .store(on, std::sync::atomic::Ordering::Relaxed);
            let mut s = settings_cell.borrow_mut();
            s.notification_preview = on;
            s.save();
        }
    });
    ui.global::<AppState>().on_send_test_notification({
        let notif = notif.clone();
        move || {
            let preview = notif.preview.load(std::sync::atomic::Ordering::Relaxed);
            let sound = notif.sound.load(std::sync::atomic::Ordering::Relaxed);
            let body = if preview {
                "This is a preview of what your notifications look like."
            } else {
                "New message"
            };
            // dbus IO — keep it off the UI thread, mirroring the chat watcher.
            std::thread::spawn(move || {
                notify::show("White Noise", body, sound);
            });
        }
    });

    // Mute / unmute the currently-open chat (header bell). Flips the live
    // NotifState set + the persisted settings, and updates the header.
    wire!(ui, on_toggle_mute_chat [group_ids, settings_cell, notif], |ui| {
        let idx = ui.get_active_chat();
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let now_muted = !notif.is_muted(&group_hex);
        notif.set_muted(&group_hex, now_muted);
        {
            let mut s = settings_cell.borrow_mut();
            if now_muted {
                s.muted_chats.insert(group_hex);
            } else {
                s.muted_chats.remove(&group_hex);
            }
            s.save();
        }
        ui.set_active_chat_muted(now_muted);
        set_chat_row_muted(&ui, idx, now_muted);
    });

    // Right-click a rail chat row: resolve the row's group id, read its live
    // pin + mute state (Rust owns both sets), and open the context menu at the
    // cursor. The menu itself is Slint; only the state lookup needs Rust.
    wire!(ui, on_request_chat_context [group_ids, notif, backend_cell], |ui, idx, ax, ay| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let (can_leave, is_self_chat) = backend_cell
            .lock()
            .unwrap()
            .as_ref()
            .map(|b| {
                let is_group = b.group_member_count(&group_hex) > 2;
                let is_admin = b.is_group_admin(&group_hex);
                let is_self = b.find_self_chat().as_deref() == Some(group_hex.as_str());
                (chat_context_can_leave_group(is_group, is_admin), is_self)
            })
            .unwrap_or((false, false));
        ui.set_chat_ctx_idx(idx);
        ui.set_chat_ctx_x(ax);
        ui.set_chat_ctx_y(ay);
        ui.set_chat_ctx_pinned(is_pinned(&group_hex));
        ui.set_chat_ctx_muted(notif.is_muted(&group_hex));
        ui.set_chat_ctx_unread(
            !ui.get_chats()
                .row_data(idx as usize)
                .is_some_and(|r| r.read),
        );
        ui.set_chat_ctx_can_leave(can_leave);
        // The self-chat is permanently pinned to the top; drop the Pin/Unpin
        // item so it doesn't present a control that reorders nothing.
        ui.set_chat_ctx_can_pin(!is_self_chat);
        ui.set_chat_ctx_open(true);
    });

    // Pin / unpin a chat to the top of the rail. Flips the live pinned set +
    // the persisted settings, then re-sorts the chat list — keeping whatever
    // chat is currently open selected across the reorder.
    wire!(ui, on_toggle_pin_chat [group_ids, settings_cell, backend_cell], |ui, idx| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let now_pinned = toggle_pinned(&group_hex);
        {
            let mut s = settings_cell.borrow_mut();
            if now_pinned {
                s.pinned_chats.insert(group_hex.clone());
            } else {
                s.pinned_chats.remove(&group_hex);
            }
            s.save();
        }
        let Some(backend) = backend_cell.lock().unwrap().clone() else {
            return;
        };
        // Re-order in place (preserving loaded messages + the open chat),
        // rather than a full refresh which would blank the conversation.
        reorder_chats_by_pin_async(&ui, &backend, &group_ids);
    });

    // Mute / unmute a specific rail row (from its context menu) — same effect
    // as the header bell, but targets the right-clicked chat by index rather
    // than the open one. Keeps the header in sync when they coincide.
    wire!(ui, on_toggle_mute_chat_at [group_ids, settings_cell, notif], |ui, idx| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let now_muted = !notif.is_muted(&group_hex);
        notif.set_muted(&group_hex, now_muted);
        {
            let mut s = settings_cell.borrow_mut();
            if now_muted {
                s.muted_chats.insert(group_hex.clone());
            } else {
                s.muted_chats.remove(&group_hex);
            }
            s.save();
        }
        if idx == ui.get_active_chat() {
            ui.set_active_chat_muted(now_muted);
        }
        set_chat_row_muted(&ui, idx, now_muted);
    });

    // Mark a specific rail row read or unread (from its context menu).
    // Marking read is the same action opening the chat performs: advance the
    // read marker and drop any manual flag. Marking unread sets the manual
    // flag without touching the marker, so a chat with nothing new can still
    // be flagged to come back to — `record_count`/`chat_meta_from` are what
    // floor the badge at 1 on the next recompute; this handler pokes the row
    // directly so the badge appears immediately.
    wire!(ui, on_toggle_read_chat_at [group_ids, settings_cell], |ui, idx| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let now_unread = !ui
            .get_chats()
            .row_data(idx as usize)
            .map(|r| r.read)
            .unwrap_or(true);
        let mut s = settings_cell.borrow_mut();
        if now_unread {
            unread_state().set_forced_unread(&group_hex, true);
            unread_state().set_count(&group_hex, 1);
            s.manually_unread.insert(group_hex.clone());
            set_chat_row_unread(&ui, idx as usize, 1);
        } else {
            let now = now_unix_secs() as i64;
            unread_state().mark_read(&group_hex, now);
            s.last_read.insert(group_hex.clone(), now);
            s.manually_unread.remove(&group_hex);
            clear_chat_unread_row(&ui, idx as usize);
        }
        s.save();
        drop(s);
        set_rail_badges(&ui, &ui.get_chats());
        refresh_unread_chrome(&ui);
    });

    // Export the right-clicked chat's transcript to an HTML (default) or
    // Markdown file. Reading the history and resolving each message is a pair of
    // UI-thread reads (`Backend::messages` + the name cache), so it runs here;
    // the native save dialog, the image download/decrypt, and the file write go
    // to a blocking task, the same split as the "Save attachment" path. The
    // final extension picks the format: `.md` for Markdown, otherwise HTML.
    wire!(ui, on_export_chat_at [group_ids, backend_cell, vault_cell], |ui, idx| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let Some(backend) = backend_cell.lock().unwrap().clone() else {
            return;
        };
        let chat_name = ui
            .get_chats()
            .row_data(idx as usize)
            .map(|c| c.name.to_string())
            .unwrap_or_default();
        let transcript = build_transcript(&backend, &group_hex, &chat_name);
        if transcript.is_empty() {
            tracing::info!(target: "export", "no messages to export for {group_hex}");
            return;
        }
        let default_name = format!("{}.html", safe_file_stem(&chat_name));
        let vault = vault_cell.lock().unwrap().clone();
        backend.tokio_handle().spawn(async move {
            let chosen = tokio::task::spawn_blocking(move || {
                rfd::FileDialog::new()
                    .set_title("Export chat transcript")
                    .set_file_name(&default_name)
                    .add_filter("HTML", &["html", "htm"])
                    .add_filter("Markdown", &["md"])
                    .save_file()
            })
            .await
            .ok()
            .flatten();
            let Some(path) = chosen else { return };
            let format = ExportFormat::from_path(&path);
            // HTML embeds each image inline, so decrypt them off the UI
            // thread first; Markdown keeps images as notes and needs none.
            let images = if format == ExportFormat::Html {
                collect_image_data(
                    &backend,
                    vault.as_ref(),
                    transcript.group_hex(),
                    &transcript.image_references(),
                )
                .await
            } else {
                ImageData::new()
            };
            let contents = render(&transcript, format, &images);
            match tokio::task::spawn_blocking(move || {
                std::fs::write(&path, contents.as_bytes())
            })
            .await
            {
                Ok(Err(e)) => tracing::warn!(target: "export", "write: {e:#}"),
                Err(e) => tracing::warn!(target: "export", "write join: {e:#}"),
                Ok(Ok(())) => {}
            }
        });
    });

    // Save (or clear) the right-clicked chat's organizing label from the
    // LabelModal. Mirrors the mute-at handler's split: update the live
    // singleton + Settings, patch the one row in place, then refresh the
    // filter-chip row so a brand-new label shows up as a chip immediately.
    wire!(ui, on_set_chat_label [group_ids, settings_cell], |ui, idx, label| {
        let group_hex = group_ids.lock().unwrap().get(idx as usize).cloned();
        let Some(group_hex) = group_hex else { return };
        let label = label.trim().to_string();
        set_chat_label(&group_hex, &label);
        {
            let mut s = settings_cell.borrow_mut();
            if label.is_empty() {
                s.chat_labels.remove(&group_hex);
            } else {
                s.chat_labels.insert(group_hex.clone(), label.clone());
            }
            s.save();
        }
        set_chat_row_label(&ui, idx, &label);
        push_known_chat_labels(&ui);
        ui.set_show_label_modal(false);
        ui.set_label_input(s(""));
        ui.set_label_modal_idx(-1);
    });
    wire!(ui, on_label_modal_dismissed [], |ui| {
        ui.set_show_label_modal(false);
        ui.set_label_input(s(""));
        ui.set_label_modal_idx(-1);
    });

    wire!(ui, on_time_format_selected [settings_cell, backend_cell, pending_state, group_ids, archived_group_ids], |ui, fmt| {
        let fmt = if fmt.as_str() == "12h" { "12h" } else { "24h" };
        {
            let mut st = settings_cell.borrow_mut();
            st.time_format = fmt.to_string();
            st.save();
            apply_stamp_formats(&st);
        }
        ui.set_time_format(s(fmt));
        refresh_stamps_everywhere(
            &ui,
            &backend_cell,
            &pending_state,
            &group_ids,
            &archived_group_ids,
        );
    });

    wire!(ui, on_date_format_selected [settings_cell, backend_cell, pending_state, group_ids, archived_group_ids], |ui, fmt| {
        let fmt = match fmt.as_str() {
            "dmy" => "dmy",
            "iso" => "iso",
            _ => "mdy",
        };
        {
            let mut st = settings_cell.borrow_mut();
            st.date_format = fmt.to_string();
            st.save();
            apply_stamp_formats(&st);
        }
        ui.set_date_format(s(fmt));
        refresh_stamps_everywhere(
            &ui,
            &backend_cell,
            &pending_state,
            &group_ids,
            &archived_group_ids,
        );
    });

    ui.global::<AppState>().on_debug_load({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        // mode: 0 = state snapshot, 1 = raw events, 2 = key packages.
        move |mode| {
            // Liveness check only — the dump lands via the completion below.
            if weak.upgrade().is_none() {
                return;
            }
            // Every collector reads group/message/MLS snapshots that `block_on`
            // the marmot runtime — gather them on a worker, never the UI thread.
            let b = backend_cell.lock().unwrap().clone();
            let weak = weak.clone();
            spawn_ui(
                weak,
                move || {
                    b.map(|b| match mode {
                        1 => b.debug_raw_events(),
                        2 => b.debug_key_packages(),
                        _ => b.debug_snapshot(),
                    })
                    .unwrap_or_else(|| "(backend not booted)".to_string())
                },
                move |ui, snap| {
                    // Rows drive the viewer; the plain string stays for copy.
                    let (rows, gutter_lines) = json_doc_set(JsonSlot::Dump, &snap);
                    ui.set_debug_dump_rows(rows);
                    ui.set_debug_dump_gutter_lines(gutter_lines);
                    ui.set_debug_dump(snap.into());
                },
            );
        }
    });

    // Fold/unfold a container line in the Debug pane's dump viewer.
    wire!(ui, on_debug_dump_toggle [], |ui, logical| {
        let (rows, gutter_lines) = json_doc_toggle(JsonSlot::Dump, logical);
        ui.set_debug_dump_rows(rows);
        ui.set_debug_dump_gutter_lines(gutter_lines);
    });

    ui.global::<AppState>().on_debug_copy_clicked({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let text = ui.get_debug_dump();
            if text.is_empty() {
                set_status_feedback(&ui, error_copy().no_debug_snapshot, false);
                return;
            }
            let weak = weak.clone();
            copy_to_clipboard_async(text.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => set_status_feedback(&ui, error_copy().debug_dump_copied, false),
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy debug dump failed: {e}");
                        set_status_feedback(&ui, error_copy().clipboard_failed, true);
                    }
                }
            });
        }
    });

    // ─── Security & privacy toggles ────────────────────────────────────
    wire!(ui, on_telemetry_toggled [backend_cell], |ui, on| {
        // The marmot settings store is a synchronous disk write — never
        // run it on the UI thread (or while holding the cell lock).
        let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
            ui.set_telemetry_enabled(!on);
            return;
        };
        let weak = ui.as_weak();
        spawn_ui(
            weak,
            move || b.set_telemetry_enabled(on),
            move |ui, result| {
                if let Err(e) = result {
                    tracing::warn!(target: "settings", "set telemetry failed: {e}");
                    ui.set_telemetry_enabled(!on);
                }
            },
        );
    });

    wire!(ui, on_audit_toggled [backend_cell], |ui, on| {
        let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
            ui.set_audit_enabled(!on);
            return;
        };
        // Persist + hot-swap the recorder on running sessions (no restart).
        // Applying the switch awaits each account worker's FIFO queue, which
        // a misbehaving relay can hold for ~35s — never block here.
        let weak = ui.as_weak();
        let fut = b.set_audit_logs_enabled(on);
        let bg = b.clone();
        spawn_ui_tokio(
            &b,
            weak,
            async move {
                let result = fut.await;
                let files = bg.audit_log_files().unwrap_or_default();
                (result, files)
            },
            move |ui, (result, files)| {
                match result {
                    Ok(()) => show_audit_status(
                        &ui,
                        if on {
                            error_copy().audit_enabled
                        } else {
                            error_copy().audit_disabled
                        },
                        StatusKind::Ok,
                    ),
                    Err(e) => {
                        tracing::warn!(target: "settings", "set audit logs failed: {e:#}");
                        ui.set_audit_enabled(!on);
                        show_audit_status(
                            &ui,
                            error_copy().audit_change_failed,
                            StatusKind::Error,
                        );
                    }
                }
                push_audit_files(&ui, files);
            },
        );
    });

    wire!(ui, on_audit_refresh_files [backend_cell], |ui| {
        let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
            return;
        };
        refresh_audit_files(&ui, &b);
    });

    wire!(ui, on_audit_delete_file [backend_cell], |ui, path| {
        let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
            return;
        };
        let weak = ui.as_weak();
        let fut = b.delete_audit_log_file(path.to_string());
        let bg = b.clone();
        spawn_ui_tokio(
            &b,
            weak,
            async move {
                let result = fut.await;
                let files = bg.audit_log_files().unwrap_or_default();
                (result, files)
            },
            move |ui, (result, files)| {
                match result {
                    // `true` = the live recorder owned that file and
                    // rotated in place rather than going dark.
                    Ok(true) => {
                        show_audit_status(&ui, error_copy().audit_deleted_live, StatusKind::Ok)
                    }
                    Ok(false) => {
                        show_audit_status(&ui, error_copy().audit_deleted, StatusKind::Ok)
                    }
                    Err(e) => {
                        tracing::warn!(target: "settings", "delete audit log failed: {e:#}");
                        show_audit_status(
                            &ui,
                            error_copy().audit_delete_failed,
                            StatusKind::Error,
                        );
                    }
                }
                push_audit_files(&ui, files);
            },
        );
    });

    wire_network(ui, cx, boot_backend);
    ui.global::<AppState>().on_copy_to_clipboard({
        let weak = ui.as_weak();
        move |text| {
            tracing::debug!(
                target: "ui", "copy-to-clipboard fired, text empty={}",
                text.is_empty()
            );
            let Some(ui) = weak.upgrade() else { return };
            if text.is_empty() {
                set_status_feedback(&ui, error_copy().nothing_to_copy, false);
                return;
            }
            let weak = weak.clone();
            copy_to_clipboard_async(text.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => set_status_feedback(&ui, error_copy().copied_to_clipboard, false),
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy failed: {e}");
                        set_status_feedback(&ui, error_copy().clipboard_failed, true);
                    }
                }
            });
        }
    });

    // ─── Reveal nsec (Keys → Danger zone) ──────────────────────────────
    // The private key is only ever shown after the user re-confirms their
    // vault password. Verification re-opens the vault file from disk with the
    // supplied password — the same WrongPassword-on-bad-tag path as unlock —
    // which runs the deliberately-slow Argon2id KDF, so it goes on a worker
    // thread. On success we reveal the *active* account's nsec, not blindly the
    // primary key. Nothing decrypted is held anywhere but the UI property,
    // which the dismiss handler clears.
    ui.global::<AppState>().on_reveal_nsec_confirm({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let password = password.to_string();
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                ui.set_reveal_nsec_status(error_copy().backend_not_ready_yet.into());
                ui.set_reveal_nsec_status_error(true);
                return;
            };
            let account_hex = backend.account().account_id_hex;
            ui.set_reveal_nsec_busy(true);
            ui.set_reveal_nsec_status(s(""));
            ui.set_reveal_nsec_status_error(false);
            let weak = weak.clone();
            spawn_ui(
                weak,
                move || -> Result<String, String> {
                    let v = Vault::open(&password).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        other => format!("{other}"),
                    })?;
                    v.nsec_for_pubkey(&account_hex)
                        .ok_or_else(|| error_copy().no_secret_key_account)
                },
                move |ui, result| {
                    ui.set_reveal_nsec_busy(false);
                    match result {
                        Ok(nsec) => {
                            ui.set_reveal_nsec_password(s(""));
                            ui.set_reveal_nsec_status(s(""));
                            ui.set_reveal_nsec_status_error(false);
                            ui.set_reveal_nsec_value(nsec.into());
                        }
                        Err(err) => {
                            ui.set_reveal_nsec_status(err.into());
                            ui.set_reveal_nsec_status_error(true);
                        }
                    }
                },
            );
        }
    });

    wire!(ui, on_reveal_nsec_dismissed [], |ui| {
        // Drop the revealed key and the typed password the moment the
        // dialog closes — don't leave either lingering in UI state.
        ui.set_reveal_nsec_password(s(""));
        ui.set_reveal_nsec_value(s(""));
        ui.set_reveal_nsec_status(s(""));
        ui.set_reveal_nsec_status_error(false);
        ui.set_reveal_nsec_busy(false);
    });

    ui.global::<AppState>().on_reveal_nsec_copy({
        let weak = ui.as_weak();
        move |nsec| {
            let weak = weak.clone();
            copy_secret_to_clipboard_async(nsec.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => {
                        ui.set_reveal_nsec_status(error_copy().nsec_copied.into());
                        ui.set_reveal_nsec_status_error(false);
                    }
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy revealed nsec failed: {e}");
                        ui.set_reveal_nsec_status(error_copy().clipboard_failed_nsec.into());
                        ui.set_reveal_nsec_status_error(true);
                    }
                }
            });
        }
    });

    // ─── Export encrypted key (Keys → Danger zone) ─────────────────────
    // Same gate as reveal-nsec: re-confirm the vault password on a worker
    // thread. On success, encrypt the active account's secret key as an
    // NIP-49 `ncryptsec1…` string, sealed with that same password — matching
    // how BackupCreateModal seals a whole backup with the vault password
    // rather than asking for a second, freshly-typed one.
    ui.global::<AppState>().on_export_key_confirm({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |password| {
            let Some(ui) = weak.upgrade() else { return };
            let password = password.to_string();
            let Some(backend) = backend_cell.lock().unwrap().clone() else {
                ui.set_export_key_status(error_copy().backend_not_ready_yet.into());
                ui.set_export_key_status_error(true);
                return;
            };
            let account_hex = backend.account().account_id_hex;
            ui.set_export_key_busy(true);
            ui.set_export_key_status(s(""));
            ui.set_export_key_status_error(false);
            let weak = weak.clone();
            spawn_ui(
                weak,
                move || -> Result<String, String> {
                    let v = Vault::open(&password).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        other => format!("{other}"),
                    })?;
                    let nsec = v
                        .nsec_for_pubkey(&account_hex)
                        .ok_or_else(|| error_copy().no_secret_key_account)?;
                    let keys =
                        nostr::Keys::parse(&nsec).map_err(|_| error_copy().export_key_failed)?;
                    let encrypted = nostr::nips::nip49::EncryptedSecretKey::new(
                        keys.secret_key(),
                        &password,
                        16,
                        nostr::nips::nip49::KeySecurity::Unknown,
                    )
                    .map_err(|_| error_copy().export_key_failed)?;
                    encrypted
                        .to_bech32()
                        .map_err(|_| error_copy().export_key_failed)
                },
                move |ui, result| {
                    ui.set_export_key_busy(false);
                    match result {
                        Ok(ncryptsec) => {
                            ui.set_export_key_password(s(""));
                            ui.set_export_key_status(s(""));
                            ui.set_export_key_status_error(false);
                            ui.set_export_key_value(ncryptsec.into());
                        }
                        Err(err) => {
                            ui.set_export_key_status(err.into());
                            ui.set_export_key_status_error(true);
                        }
                    }
                },
            );
        }
    });

    wire!(ui, on_export_key_dismissed [], |ui| {
        // Drop the encrypted key and the typed password the moment the
        // dialog closes — don't leave either lingering in UI state.
        ui.set_export_key_password(s(""));
        ui.set_export_key_value(s(""));
        ui.set_export_key_status(s(""));
        ui.set_export_key_status_error(false);
        ui.set_export_key_busy(false);
    });

    // ─── Change vault password (Keys → Danger zone) ────────────────────
    // Re-confirm the current password on a worker thread (Argon2id), then
    // rotate salt+key on the *live* vault so the session's in-memory key
    // matches the file. Media-cache and offline-queue blobs are re-sealed
    // under the new media-cache subkey inside `Vault::change_password`.
    ui.global::<AppState>().on_change_password_submit({
        let weak = ui.as_weak();
        let vault_cell = vault_cell.clone();
        move |current, new, confirm| {
            let Some(ui) = weak.upgrade() else { return };
            let current = current.to_string();
            let new = new.to_string();
            if let Err(err) = validate_new_password(&new, confirm.as_str()) {
                ui.set_change_password_status(err.into());
                ui.set_change_password_status_error(true);
                return;
            }
            let Some(vault) = vault_cell.lock().unwrap().clone() else {
                ui.set_change_password_status(error_copy().backend_not_ready_yet.into());
                ui.set_change_password_status_error(true);
                return;
            };
            ui.set_change_password_busy(true);
            ui.set_change_password_status(s(""));
            ui.set_change_password_status_error(false);
            let weak = weak.clone();
            spawn_ui(
                weak,
                move || -> Result<(), String> {
                    let mut v = vault.lock().map_err(|_| error_copy().change_password_failed)?;
                    v.change_password(&current, &new).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        _ => error_copy().change_password_failed,
                    })
                },
                move |ui, result| {
                    ui.set_change_password_busy(false);
                    match result {
                        Ok(()) => {
                            ui.set_show_change_password(false);
                            ui.set_change_password_current(s(""));
                            ui.set_change_password_new(s(""));
                            ui.set_change_password_repeat(s(""));
                            ui.set_change_password_status(s(""));
                            ui.set_change_password_status_error(false);
                            set_status_feedback(&ui, error_copy().password_changed, false);
                        }
                        Err(err) => {
                            ui.set_change_password_status(err.into());
                            ui.set_change_password_status_error(true);
                        }
                    }
                },
            );
        }
    });

    wire!(ui, on_change_password_dismissed [], |ui| {
        ui.set_change_password_current(s(""));
        ui.set_change_password_new(s(""));
        ui.set_change_password_repeat(s(""));
        ui.set_change_password_status(s(""));
        ui.set_change_password_status_error(false);
        ui.set_change_password_busy(false);
    });

    // After any selection mutation, refresh the breadcrumb so the title bar matches state.
    // Captures only the weak handle, so clones are `Send` and can ride
    // through worker threads into completion closures.
    refresh_breadcrumb();

    // Recompute the Storage pane's media-cache size off the UI thread (disk
    // walk) and push the formatted label back. Cheap, but IO — never inline.
    refresh_storage_size();
    // Static for the session — the data dir doesn't move while we're running.
    ui.set_storage_vault_dir(vault::vault_dir().display().to_string().into());
    // Restore the "Last backup" receipt so it survives a restart, not just the
    // modal that wrote it. Refreshed in place by `on_storage_backup_written`.
    publish_last_backup(ui, &settings_cell.borrow());

    // Reveal the folder holding vault.db in the platform file manager. Reuses the
    // same xdg-open/open handler as external links — a directory path is fine.
    ui.global::<AppState>()
        .on_storage_open_vault_folder(move || {
            open_external(&vault::vault_dir().display().to_string());
        });
}

// ─── Audit-log file rows (Settings → Advanced) ─────────────────────────────

/// Map on-disk audit-log files into UI rows (newest first) and push the model.
pub(crate) fn push_audit_files(ui: &WhiteNoiseLinux, mut files: Vec<AuditLogFile>) {
    files.sort_by(|a, b| {
        b.modified_at_ms
            .unwrap_or(0)
            .cmp(&a.modified_at_ms.unwrap_or(0))
    });
    let rows: Vec<AuditLogEntry> = files
        .iter()
        .map(|f| AuditLogEntry {
            path: f.path.clone().into(),
            name: f.file_name.clone().into(),
            meta: match f.modified_at_ms {
                Some(ms) => format!(
                    "{} · {}",
                    human_bytes(f.size_bytes),
                    format_date_unix(ms / 1000)
                )
                .into(),
                None => human_bytes(f.size_bytes).into(),
            },
        })
        .collect();
    ui.set_audit_files(ModelRc::new(VecModel::from(rows)));
}

/// List audit-log files off the UI thread (disk IO) and push the rows back
/// through the event loop.
pub(crate) fn refresh_audit_files(ui: &WhiteNoiseLinux, backend: &Arc<Backend>) {
    let weak = ui.as_weak();
    let b = backend.clone();
    spawn_ui_tokio(
        backend,
        weak,
        async move {
            b.audit_log_files().unwrap_or_else(|e| {
                tracing::warn!(target: "settings", "list audit logs failed: {e:#}");
                Vec::new()
            })
        },
        move |ui, files| push_audit_files(&ui, files),
    );
}

fn chat_context_can_leave_group(is_group: bool, is_admin: bool) -> bool {
    is_group && !is_admin
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_context_leave_group_only_for_non_admin_groups() {
        assert!(chat_context_can_leave_group(true, false));
        assert!(!chat_context_can_leave_group(false, false));
        assert!(!chat_context_can_leave_group(true, true));
    }
}
