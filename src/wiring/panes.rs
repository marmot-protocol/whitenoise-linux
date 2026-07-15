use crate::*;

pub(crate) fn wire_panes(
    ui: &DarkMatterLinux,
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
                    ui.set_backend_error(friendly_error(ErrorOp::SwitchAccount, &e).into());
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

    ui.global::<AppState>().on_account_switcher_requested({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            refresh_accounts_model(&ui, &b);
            ui.set_show_account_switcher(true);
        }
    });

    ui.global::<AppState>().on_switch_account({
        let do_switch = do_switch_account.clone();
        move |id| do_switch(id.to_string())
    });

    ui.global::<AppState>().on_add_account_requested({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_show_account_switcher(false);
            ui.set_add_account_nsec(s(""));
            ui.set_add_account_status(s(""));
            ui.set_add_account_generated(false);
            ui.set_add_account_busy(false);
            ui.set_show_add_account(true);
        }
    });

    ui.global::<AppState>().on_add_account_dismissed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_show_add_account(false);
            ui.set_add_account_nsec(s(""));
            ui.set_add_account_generated(false);
            ui.set_add_account_status(s(""));
        }
    });

    ui.global::<AppState>().on_generate_add_account_key({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let keys = Keys::generate();
            match keys.secret_key().to_bech32() {
                Ok(nsec) => {
                    ui.set_add_account_nsec(nsec.into());
                    ui.set_add_account_generated(true);
                    ui.set_add_account_status(s(""));
                }
                Err(e) => ui.set_add_account_status(tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into()),
            }
        }
    });

    ui.global::<AppState>().on_add_account({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let vault_cell = vault_cell.clone();
        let do_switch = do_switch_account.clone();
        move |nsec_input| {
            let Some(ui) = weak.upgrade() else { return };
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
                    ui.set_add_account_status(tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into());
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
            let do_switch = do_switch.clone();
            let backend_for_seed = backend.clone();
            backend.add_account_async(nsec.clone(), move |result| {
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
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
        }
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
            std::thread::spawn(move || {
                let result = (|| -> Result<(String, String, Arc<Mutex<Vault>>), String> {
                    let npub = keys.public_key().to_bech32().map_err(|e| e.to_string())?;
                    let nsec = keys.secret_key().to_bech32().map_err(|e| e.to_string())?;
                    let mut v = Vault::create(&password).map_err(|e| format!("save key: {e}"))?;
                    v.set(vault::NSEC_KEY, &nsec)
                        .map_err(|e| format!("seal nsec: {e}"))?;
                    Ok((npub, nsec, Arc::new(Mutex::new(v))))
                })();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
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
                });
            });
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
            std::thread::spawn(move || {
                type UnlockOutcome =
                    Result<(String, String, Arc<Mutex<Vault>>, Option<String>), String>;
                let result = (|| -> UnlockOutcome {
                    let v = Vault::open(&password).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        other => format!("{other}"),
                    })?;
                    let nsec = v.nsec().ok_or_else(|| error_copy().no_key_stored)?;
                    let keys =
                        Keys::parse(&nsec).map_err(|_| error_copy().stored_key_invalid)?;
                    let npub = keys.public_key().to_bech32().map_err(|e| e.to_string())?;
                    // The account the user last had active — boot displays it
                    // instead of the primary when it still exists.
                    let active = v.get(vault::ACTIVE_ACCOUNT_KEY).map(|s| s.to_string());
                    Ok((npub, nsec, Arc::new(Mutex::new(v)), active))
                })();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
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
                });
            });
        }
    });

    // "Reset & use another key" on the unlock screen. No password recovery exists,
    // so this deletes the vault and returns to first-run choose.
    ui.global::<AppState>().on_reset_vault({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if let Err(e) = vault::delete() {
                tracing::warn!(target: "login", "vault reset failed: {e}");
            }
            // Queued sends were sealed under the old vault key — unreadable now.
            offline_queue::clear();
            ui.set_password_input(s(""));
            ui.set_password_confirm(s(""));
            ui.set_login_error(s(""));
            ui.set_login_mode(0);
        }
    });

    ui.global::<AppState>().on_generate_key_requested({
        let weak = ui.as_weak();
        let pending = pending_generated.clone();
        let pending_name = pending_profile_name.clone();
        move || {
            tracing::debug!(target: "login", "generate_key_requested fired");
            let Some(ui) = weak.upgrade() else { return };
            let keys = Keys::generate();
            let nsec = match keys.secret_key().to_bech32() {
                Ok(v) => v,
                Err(e) => {
                    ui.set_login_error(tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into());
                    return;
                }
            };
            let npub = match keys.public_key().to_bech32() {
                Ok(v) => v,
                Err(e) => {
                    ui.set_login_error(tmpl(&error_copy().encode_key_failed, &[&e.to_string()]).into());
                    return;
                }
            };
            *pending.lock().unwrap() = Some(nsec.clone());
            let name = random_profile_name();
            *pending_name.lock().unwrap() = Some(name.clone());
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
        }
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
            std::thread::spawn(move || {
                let result = (|| -> Result<(String, String, Arc<Mutex<Vault>>), String> {
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
                })();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
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
                });
            });
        }
    });

    ui.global::<AppState>().on_copy_nsec({
        let weak = ui.as_weak();
        move |nsec| {
            let weak = weak.clone();
            copy_to_clipboard_async(nsec.to_string(), move |result| {
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

    // ─── Debug pane ────────────────────────────────────────────────────
    // Settings persist the toggle across launches. The pane itself is gated
    // behind that toggle; when off, the sidebar entry doesn't even render.
    ui.set_debug_enabled(settings_cell.borrow().debug_enabled);

    ui.global::<AppState>().on_change_language_clicked({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_language_picker(true);
            }
        }
    });

    ui.global::<AppState>().on_locale_selected({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |code| {
            let locale = normalize_locale(code.as_str()).to_string();
            apply_locale(&locale);
            {
                let mut s = settings_cell.borrow_mut();
                s.locale = locale.clone();
                s.save();
            }
            if let Some(ui) = weak.upgrade() {
                ui.set_locale(s(&locale));
                ui.set_locale_display(s(locale_display(&locale)));
                ui.set_show_language_picker(false);
                // Re-snapshot the now-localized error/status copy for worker threads.
                refresh_error_copy(&ui);
                refresh_time_copy(&ui);
                refresh_system_copy(&ui);
            }
        }
    });

    ui.global::<AppState>().on_theme_mode_selected({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |mode| {
            let mode = normalize_theme_mode(mode.as_str()).to_string();
            {
                let mut s = settings_cell.borrow_mut();
                s.theme = mode.clone();
                s.save();
            }
            if let Some(ui) = weak.upgrade() {
                apply_theme_mode(&ui, &mode);
            }
        }
    });

    ui.global::<AppState>().on_accent_selected({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |idx| {
            let color = accent_color_name(idx);
            {
                let mut s = settings_cell.borrow_mut();
                s.accent_color = color.to_string();
                s.save();
            }
            if let Some(ui) = weak.upgrade() {
                set_accent_index(&ui, accent_color_idx(color));
            }
        }
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

    ui.global::<AppState>().on_launch_at_login_toggled({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |on| {
            if let Err(e) = startup::set_launch_at_login(on) {
                tracing::warn!(target: "startup", on, "set launch-at-login failed: {e}");
                if let Some(ui) = weak.upgrade() {
                    ui.set_launch_at_login(!on);
                }
                return;
            }
            let mut s = settings_cell.borrow_mut();
            s.launch_at_login = on;
            s.save();
        }
    });

    ui.global::<AppState>().on_start_minimized_to_tray_toggled({
        let settings_cell = settings_cell.clone();
        move |on| {
            let mut s = settings_cell.borrow_mut();
            s.start_minimized_to_tray = on;
            s.save();
        }
    });

    ui.global::<AppState>()
        .on_restore_last_selected_chat_toggled({
            let weak = ui.as_weak();
            let settings_cell = settings_cell.clone();
            let group_ids = group_ids.clone();
            move |on| {
                let current = weak.upgrade().and_then(|ui| {
                    group_ids
                        .lock()
                        .unwrap()
                        .get(ui.get_active_chat() as usize)
                        .cloned()
                });
                let mut s = settings_cell.borrow_mut();
                s.restore_last_selected_chat = on;
                if on && current.is_some() {
                    s.last_selected_chat = current;
                }
                s.save();
            }
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

    // Mute / unmute the currently-open chat (header bell). Flips the live
    // NotifState set + the persisted settings, and updates the header.
    ui.global::<AppState>().on_toggle_mute_chat({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let settings_cell = settings_cell.clone();
        let notif = notif.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
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
        }
    });

    // Right-click a rail chat row: resolve the row's group id, read its live
    // pin + mute state (Rust owns both sets), and open the context menu at the
    // cursor. The menu itself is Slint; only the state lookup needs Rust.
    ui.global::<AppState>().on_request_chat_context({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let notif = notif.clone();
        let backend_cell = backend_cell.clone();
        move |idx, ax, ay| {
            let Some(ui) = weak.upgrade() else { return };
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
            ui.set_chat_ctx_can_leave(can_leave);
            // The self-chat is permanently pinned to the top; drop the Pin/Unpin
            // item so it doesn't present a control that reorders nothing.
            ui.set_chat_ctx_can_pin(!is_self_chat);
            ui.set_chat_ctx_open(true);
        }
    });

    // Pin / unpin a chat to the top of the rail. Flips the live pinned set +
    // the persisted settings, then re-sorts the chat list — keeping whatever
    // chat is currently open selected across the reorder.
    ui.global::<AppState>().on_toggle_pin_chat({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let settings_cell = settings_cell.clone();
        let backend_cell = backend_cell.clone();
        move |idx| {
            let Some(ui) = weak.upgrade() else { return };
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
        }
    });

    // Mute / unmute a specific rail row (from its context menu) — same effect
    // as the header bell, but targets the right-clicked chat by index rather
    // than the open one. Keeps the header in sync when they coincide.
    ui.global::<AppState>().on_toggle_mute_chat_at({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let settings_cell = settings_cell.clone();
        let notif = notif.clone();
        move |idx| {
            let Some(ui) = weak.upgrade() else { return };
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
        }
    });

    // Export the right-clicked chat's transcript to an HTML (default) or
    // Markdown file. Reading the history and resolving each message is a pair of
    // UI-thread reads (`Backend::messages` + the name cache), so it runs here;
    // the native save dialog, the image download/decrypt, and the file write go
    // to a blocking task, the same split as the "Save attachment" path. The
    // final extension picks the format: `.md` for Markdown, otherwise HTML.
    ui.global::<AppState>().on_export_chat_at({
        let weak = ui.as_weak();
        let group_ids = group_ids.clone();
        let backend_cell = backend_cell.clone();
        let vault_cell = vault_cell.clone();
        move |idx| {
            let Some(ui) = weak.upgrade() else { return };
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
        }
    });

    ui.global::<AppState>().on_time_format_selected({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        let backend_cell = backend_cell.clone();
        let pending_state = pending_state.clone();
        let group_ids = group_ids.clone();
        let archived_group_ids = archived_group_ids.clone();
        move |fmt| {
            let fmt = if fmt.as_str() == "12h" { "12h" } else { "24h" };
            {
                let mut st = settings_cell.borrow_mut();
                st.time_format = fmt.to_string();
                st.save();
                apply_stamp_formats(&st);
            }
            if let Some(ui) = weak.upgrade() {
                ui.set_time_format(s(fmt));
                refresh_stamps_everywhere(
                    &ui,
                    &backend_cell,
                    &pending_state,
                    &group_ids,
                    &archived_group_ids,
                );
            }
        }
    });

    ui.global::<AppState>().on_date_format_selected({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        let backend_cell = backend_cell.clone();
        let pending_state = pending_state.clone();
        let group_ids = group_ids.clone();
        let archived_group_ids = archived_group_ids.clone();
        move |fmt| {
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
            if let Some(ui) = weak.upgrade() {
                ui.set_date_format(s(fmt));
                refresh_stamps_everywhere(
                    &ui,
                    &backend_cell,
                    &pending_state,
                    &group_ids,
                    &archived_group_ids,
                );
            }
        }
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
            std::thread::spawn(move || {
                let snap = b
                    .map(|b| match mode {
                        1 => b.debug_raw_events(),
                        2 => b.debug_key_packages(),
                        _ => b.debug_snapshot(),
                    })
                    .unwrap_or_else(|| "(backend not booted)".to_string());
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_debug_dump(snap.into());
                });
            });
        }
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
    ui.global::<AppState>().on_telemetry_toggled({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |on| {
            let Some(ui) = weak.upgrade() else { return };
            // The marmot settings store is a synchronous disk write — never
            // run it on the UI thread (or while holding the cell lock).
            let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
                ui.set_telemetry_enabled(!on);
                return;
            };
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = b.set_telemetry_enabled(on);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    if let Err(e) = result {
                        tracing::warn!(target: "settings", "set telemetry failed: {e}");
                        ui.set_telemetry_enabled(!on);
                    }
                });
            });
        }
    });

    ui.global::<AppState>().on_audit_toggled({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |on| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
                ui.set_audit_enabled(!on);
                return;
            };
            // Persist + hot-swap the recorder on running sessions (no restart).
            // Applying the switch awaits each account worker's FIFO queue, which
            // a misbehaving relay can hold for ~35s — never block here.
            let weak = ui.as_weak();
            let fut = b.set_audit_logs_enabled(on);
            b.tokio_handle().spawn(async move {
                let result = fut.await;
                let files = b.audit_log_files().unwrap_or_default();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(()) => ui.set_audit_status(
                            if on {
                                error_copy().audit_enabled
                            } else {
                                error_copy().audit_disabled
                            }
                            .into(),
                        ),
                        Err(e) => {
                            tracing::warn!(target: "settings", "set audit logs failed: {e:#}");
                            ui.set_audit_enabled(!on);
                            ui.set_audit_status(error_copy().audit_change_failed.into());
                        }
                    }
                    push_audit_files(&ui, files);
                });
            });
        }
    });

    ui.global::<AppState>().on_audit_refresh_files({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
                return;
            };
            refresh_audit_files(&ui, &b);
        }
    });

    ui.global::<AppState>().on_audit_delete_file({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |path| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().ok().and_then(|g| g.as_ref().cloned()) else {
                return;
            };
            let weak = ui.as_weak();
            let fut = b.delete_audit_log_file(path.to_string());
            b.tokio_handle().spawn(async move {
                let result = fut.await;
                let files = b.audit_log_files().unwrap_or_default();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        // `true` = the live recorder owned that file and
                        // rotated in place rather than going dark.
                        Ok(true) => ui.set_audit_status(
                            error_copy().audit_deleted_live.into(),
                        ),
                        Ok(false) => ui.set_audit_status(error_copy().audit_deleted.into()),
                        Err(e) => {
                            tracing::warn!(target: "settings", "delete audit log failed: {e:#}");
                            ui.set_audit_status(error_copy().audit_delete_failed.into());
                        }
                    }
                    push_audit_files(&ui, files);
                });
            });
        }
    });

    // ─── Network & relays pane ─────────────────────────────────────────
    // The on-disk list (`backend::load_relays`) is the source of truth and
    // what we mutate from the UI. `backend.booted_relays()` is what the
    // running runtime was started with — when they diverge the pane shows a
    // "restart to apply" banner. MarmotApp has no `set_relays` API; pushing
    // the new list into the live runtime would require a much larger refactor,
    // so for now the user restarts to pick up changes.
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
        ui.set_network_booted_relays(ModelRc::new(VecModel::from(Vec::<SharedString>::new())));
        ui.set_network_connected(0);
        ui.set_network_total(0);
        ui.set_network_status(s(""));
        ui.set_network_republish_busy(false);
    }

    // On the first-run get-started screen the backend is booted *before* the
    // user has configured any relay (`load_relays()` is empty at boot), and
    // MarmotApp exposes no live `set_relays`. So a relay added there would only
    // ever land on disk — never on the running transport — which is why it
    // "does nothing" until the next restart. To make the welcome flow actually
    // work, re-boot the runtime against the new on-disk list whenever it
    // changes while we're still in the no-chats first-run state. Once a chat
    // exists the Settings → Network pane is the only entry point, and it keeps
    // its intentional "restart to apply" banner rather than yanking a live
    // session out from under the user.
    let reboot_relays_first_run: Rc<dyn Fn()> = {
        let weak = ui.as_weak();
        let boot = boot_backend.clone();
        let vault_cell = vault_cell.clone();
        Rc::new(move || {
            let Some(ui) = weak.upgrade() else { return };
            // Only when a previous boot has settled (avoid racing a boot in
            // flight) and we're still on the first-run get-started screen.
            if !ui.get_backend_ready() {
                return;
            }
            if ui.get_chats().row_count() > 0 {
                return;
            }
            let Some(vault) = vault_cell.lock().unwrap().clone() else {
                return;
            };
            let Some(nsec) = vault.lock().unwrap().nsec() else {
                return;
            };
            // `boot` re-reads `load_relays()` (already saved below), spawns a
            // fresh runtime, and on success replaces backend_cell + re-pushes
            // the live connection counts via refresh_network_post_boot.
            boot(nsec, vault, None);
        })
    };

    ui.global::<AppState>().on_network_add_relay({
        let weak = ui.as_weak();
        let reboot = reboot_relays_first_run.clone();
        // Returns whether the relay was accepted — the add-relay fields keep
        // their draft on a rejection so the user can correct it in place.
        move |raw| {
            let Some(ui) = weak.upgrade() else {
                return false;
            };
            let trimmed = raw.trim().to_string();
            if let Err(msg) = validate_relay_url(&trimmed) {
                ui.set_network_add_error(msg.into());
                ui.set_network_status(SharedString::default());
                return false;
            }
            let mut list: Vec<String> = vec_string_from_model(&ui.get_network_relays());
            if list.iter().any(|u| u.eq_ignore_ascii_case(&trimmed)) {
                ui.set_network_add_error(error_copy().relay_already_listed.into());
                ui.set_network_status(SharedString::default());
                return false;
            }
            list.push(trimmed);
            if let Err(e) = backend::save_relays(&list) {
                tracing::warn!(target: "network", "save relays failed: {e}");
                ui.set_network_add_error(error_copy().save_relays_failed.into());
                ui.set_network_status(SharedString::default());
                return false;
            }
            ui.set_network_add_error(SharedString::default());
            push_network_relays(&ui, &list);
            ui.set_network_status(error_copy().relay_added.into());
            // First-run: connect the freshly-added relay live (no-op otherwise).
            reboot();
            true
        }
    });

    ui.global::<AppState>().on_network_remove_relay({
        let weak = ui.as_weak();
        let reboot = reboot_relays_first_run.clone();
        move |url| {
            let Some(ui) = weak.upgrade() else { return };
            let mut list: Vec<String> = vec_string_from_model(&ui.get_network_relays());
            let before = list.len();
            list.retain(|u| u != url.as_str());
            if list.len() == before {
                return;
            }
            if let Err(e) = backend::save_relays(&list) {
                tracing::warn!(target: "network", "save relays failed: {e}");
                ui.set_network_status(error_copy().save_relays_failed.into());
                return;
            }
            push_network_relays(&ui, &list);
            ui.set_network_status(error_copy().relay_removed.into());
            // First-run: re-boot so the live transport drops the removed relay.
            reboot();
        }
    });

    ui.global::<AppState>().on_network_refresh_health({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let allow_status_update = !ui.get_network_republish_busy();
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            std::thread::spawn(move || {
                // Clone the handle, drop the lock, then poll — the UI thread
                // must never find this mutex held across a relay query.
                let b = backend_cell.lock().unwrap().clone();
                let snapshot = b.map(|b| b.relay_health());
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match snapshot {
                        Some((connected, total)) => {
                            ui.set_network_connected(connected as i32);
                            ui.set_network_total(total as i32);
                            // We just polled the relay pool — that's a real sync.
                            ui.set_sync_secs(0);
                        }
                        None if allow_status_update && !ui.get_network_republish_busy() => {
                            ui.set_network_status(error_copy().not_connected.into())
                        }
                        None => {}
                    }
                });
            });
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
            ui.set_network_status(error_copy().republishing.into());
            ui.set_network_republish_busy(true);
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            std::thread::spawn(move || {
                // Same handle-clone dance: never hold the cell lock across
                // the relay publish.
                let b = backend_cell.lock().unwrap().clone();
                let result = match b {
                    None => Err(error_copy().not_connected),
                    Some(b) => b
                        .republish_relay_lists()
                        .map_err(|e| friendly_error(ErrorOp::Republish, &e)),
                };
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_network_republish_busy(false);
                    match result {
                        Ok(n) => ui.set_network_status(
                            format!("Republished to {n} relay{}.", if n == 1 { "" } else { "s" })
                                .into(),
                        ),
                        Err(e) => ui.set_network_status(e.into()),
                    }
                });
            });
        }
    });

    // ─── Keys page: KP publish / rotate / refresh ──────────────────────
    // All three call into the marmot runtime, which blocks on its tokio
    // executor — so we hop onto a worker thread first, then back to the
    // Slint event loop with the results. UI sets `kp-busy` for the
    // round-trip so buttons can disable themselves visually.

    let kp_run = {
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        // op_kind: "publish" | "rotate" | "refresh"
        Rc::new(move |op_kind: &'static str| {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_kp_busy(true);
            let copy = error_copy();
            ui.set_kp_status(
                match op_kind {
                    "rotate" => copy.kp_rotating,
                    "refresh" => copy.kp_refreshing,
                    _ => copy.kp_publishing,
                }
                .into(),
            );
            let weak = weak.clone();
            // Clone the backend handle and drop the lock before the relay
            // round-trip — other callbacks keep locking this cell freely.
            let b = backend_cell.lock().unwrap().clone();
            std::thread::spawn(move || {
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
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_kp_busy(false);
                    match result {
                        Ok(status) => ui.set_kp_status(status.into()),
                        Err(e) => ui.set_kp_status(e.into()),
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
                });
            });
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

    ui.global::<AppState>().on_copy_to_clipboard({
        let weak = ui.as_weak();
        move |text| {
            tracing::debug!(
                target: "ui", "copy-to-clipboard fired, text empty={}",
                text.is_empty()
            );
            let Some(ui) = weak.upgrade() else { return };
            if text.is_empty() {
                show_profile_status(&ui, error_copy().npub_empty_nothing, StatusKind::Pending);
                set_status_feedback(&ui, error_copy().npub_empty_nothing, false);
                return;
            }
            let weak = weak.clone();
            copy_to_clipboard_async(text.to_string(), move |result| {
                let Some(ui) = weak.upgrade() else { return };
                match result {
                    Ok(()) => {
                        show_profile_status(&ui, error_copy().npub_copied, StatusKind::Ok);
                        set_status_feedback(&ui, error_copy().npub_copied, false);
                    }
                    Err(e) => {
                        tracing::warn!(target: "clipboard", "copy failed: {e}");
                        show_profile_status(
                            &ui,
                            error_copy().clipboard_failed,
                            StatusKind::Error,
                        );
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
            std::thread::spawn(move || {
                let result: Result<String, String> = (|| {
                    let v = Vault::open(&password).map_err(|e| match e {
                        vault::VaultError::WrongPassword => error_copy().wrong_password,
                        other => format!("{other}"),
                    })?;
                    v.nsec_for_pubkey(&account_hex)
                        .ok_or_else(|| error_copy().no_secret_key_account)
                })();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
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
                });
            });
        }
    });

    ui.global::<AppState>().on_reveal_nsec_dismissed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            // Drop the revealed key and the typed password the moment the
            // dialog closes — don't leave either lingering in UI state.
            ui.set_reveal_nsec_password(s(""));
            ui.set_reveal_nsec_value(s(""));
            ui.set_reveal_nsec_status(s(""));
            ui.set_reveal_nsec_status_error(false);
            ui.set_reveal_nsec_busy(false);
        }
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

    // Reveal the folder holding vault.db in the platform file manager. Reuses the
    // same xdg-open/open handler as external links — a directory path is fine.
    ui.global::<AppState>()
        .on_storage_open_vault_folder(move || {
            open_external(&vault::vault_dir().display().to_string());
        });
}

// ─── Audit-log file rows (Settings → Advanced) ─────────────────────────────

/// Map on-disk audit-log files into UI rows (newest first) and push the model.
pub(crate) fn push_audit_files(ui: &DarkMatterLinux, mut files: Vec<AuditLogFile>) {
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
pub(crate) fn refresh_audit_files(ui: &DarkMatterLinux, backend: &Arc<Backend>) {
    let weak = ui.as_weak();
    let b = backend.clone();
    backend.tokio_handle().spawn(async move {
        let files = b.audit_log_files().unwrap_or_else(|e| {
            tracing::warn!(target: "settings", "list audit logs failed: {e:#}");
            Vec::new()
        });
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                push_audit_files(&ui, files);
            }
        });
    });
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
