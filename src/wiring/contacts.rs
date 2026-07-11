use crate::*;

pub(crate) fn wire_contacts(ui: &DarkMatterLinux, cx: &Cx, h: &Handlers) {
    let Cx {
        settings_cell,
        contacts,
        backend_cell,
        group_ids,
        ..
    } = cx.clone();
    let Handlers {
        refresh_breadcrumb, ..
    } = h.clone();
    // Live contacts-list filter: recompute one case-insensitive match flag per
    // contact row as the user types in the sidebar search field (Slint has no
    // substring match), mirroring the chat-list filter. Matches on the resolved
    // display name, the published real name, and the short npub so a contact is
    // findable by nickname, published name, or key prefix. The flags are only
    // consulted while the query is non-empty, so the empty-query case (which
    // shows everything) needn't clear the array.
    ui.on_contact_search_changed({
        let weak = ui.as_weak();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let q = query.trim().to_lowercase();
            if q.is_empty() {
                ui.set_contact_match_flags(model(Vec::<bool>::new()));
                return;
            }
            let flags: Vec<bool> = ui
                .get_contacts()
                .iter()
                .map(|c| {
                    c.name.to_lowercase().contains(&q)
                        || c.real_name.to_lowercase().contains(&q)
                        || c.npub_short.to_lowercase().contains(&q)
                })
                .collect();
            ui.set_contact_match_flags(model(flags));
        }
    });
    ui.on_add_contact_requested({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_add_contact(true);
            }
        }
    });
    ui.on_add_contact_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_add_contact(false);
                ui.set_add_contact_input(s(""));
                ui.set_add_contact_status(s(""));
                ui.set_add_contact_busy(false);
            }
        }
    });
    ui.on_add_contact({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move |input| {
            let Some(ui) = weak.upgrade() else { return };
            let input = input.trim().to_string();
            if input.is_empty() {
                ui.set_add_contact_status(s("Paste an npub or hex pubkey."));
                return;
            }
            // Accept a pasted `marmot://profile/<npub>` deep link too.
            let input = deeplink::profile_link_ref(&input)
                .map(str::to_owned)
                .unwrap_or(input);
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_add_contact_status(s("Backend not ready."));
                return;
            };
            ui.set_add_contact_busy(true);
            ui.set_add_contact_status(s(""));
            // `add_contact` publishes the follow list and runs a broad
            // directory refresh across relays — worker thread.
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.add_contact(&input);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_add_contact_busy(false);
                    match result {
                        Ok(account_id_hex) => {
                            // Select the freshly-added row (in the continuation,
                            // once the refreshed model is applied) so the detail
                            // pane shows it.
                            refresh_contacts_async(&ui, &b, move |ui| {
                                if let Ok(npub) = npub_for_account_id(&account_id_hex)
                                    && let Some(pos) = ui.get_contacts().iter().position(|c| {
                                        c.npub_full.as_str().eq_ignore_ascii_case(&npub)
                                    })
                                {
                                    ui.set_active_contact(pos as i32);
                                }
                            });
                            ui.set_add_contact_input(s(""));
                            ui.set_add_contact_status(s(""));
                            ui.set_show_add_contact(false);
                            refresh_breadcrumb_now(&ui);
                        }
                        Err(e) => {
                            tracing::warn!(target: "add_contact", "{e:#}");
                            ui.set_add_contact_status(
                                friendly_error(ErrorOp::AddContact, &e).into(),
                            );
                        }
                    }
                });
            });
        }
    });
    // "Add contact" from the peer-profile modal — same flow as the add-contact
    // modal, but feedback stays inside the profile modal (badge flip / status).
    ui.on_peer_profile_add_contact({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let npub = ui.get_peer_profile_npub().to_string();
            if npub.is_empty() {
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            ui.set_peer_profile_adding(true);
            ui.set_peer_profile_status(s(""));
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.add_contact(&npub);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_peer_profile_adding(false);
                    match result {
                        Ok(_) => {
                            refresh_contacts_async(&ui, &b, |_| {});
                            ui.set_peer_profile_is_contact(true);
                            refresh_breadcrumb_now(&ui);
                        }
                        Err(e) => {
                            tracing::warn!(target: "profile_add_contact", "{e:#}");
                            ui.set_peer_profile_status(
                                friendly_error(ErrorOp::AddContact, &e).into(),
                            );
                        }
                    }
                });
            });
        }
    });
    ui.on_contact_nickname_requested({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(row) = contacts.row_data(ui.get_active_contact() as usize) else {
                return;
            };
            ui.set_nickname_input(row.nickname.clone());
            ui.set_nickname_contact_name(row.real_name.clone());
            ui.set_show_nickname_modal(true);
        }
    });
    ui.on_nickname_modal_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_nickname_modal(false);
                ui.set_nickname_input(s(""));
            }
        }
    });
    ui.on_set_contact_nickname({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        let settings_cell = settings_cell.clone();
        let refresh = refresh_breadcrumb.clone();
        move |nick| {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_contact() as usize;
            let Some(mut row) = contacts.row_data(idx) else {
                return;
            };
            let nick = nick.trim().to_string();
            {
                let mut st = settings_cell.borrow_mut();
                if nick.is_empty() {
                    st.nicknames.remove(row.account_id.as_str());
                } else {
                    st.nicknames
                        .insert(row.account_id.to_string(), nick.clone());
                }
                st.save();
                mention_set_nicknames(&st.nicknames);
            }
            // Patch the one row in place — no relay round-trip involved.
            row.name = if nick.is_empty() {
                row.real_name.clone()
            } else {
                nick.clone().into()
            };
            row.nickname = nick.into();
            contacts.set_row_data(idx, row);
            ui.set_show_nickname_modal(false);
            ui.set_nickname_input(s(""));
            refresh();
        }
    });
    // Contact detail → "Show as QR": rasterize the contact's marmot://
    // profile deep link and open the QrModal. Reuses `qr_image` (UI-thread
    // only — Image is !Send).
    ui.on_contact_show_qr({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(row) = contacts.row_data(ui.get_active_contact() as usize) else {
                return;
            };
            let npub = row.npub_full.to_string();
            if npub.is_empty() {
                return;
            }
            ui.set_contact_qr(qr_image(&deeplink::profile_qr_url(&npub)));
            ui.set_contact_qr_npub(s(&npub));
            ui.set_contact_qr_npub_short(row.npub_short.clone());
            ui.set_contact_qr_name(row.name.clone());
            ui.set_contact_qr_open(true);
        }
    });
    ui.on_contact_qr_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_contact_qr_open(false);
            }
        }
    });
    // Contact detail → "Retry" key package: re-fetch the peer's latest key
    // package from their relays. The automatic on-open fetch already covers the
    // common case, so this button only surfaces after a fetch comes up empty.
    ui.on_contact_refresh_key_package({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_contact() as usize;
            spawn_contact_key_package_fetch(&ui, &backend_cell, idx);
        }
    });

    // Developer mode: dump the selected contact's latest key package as raw
    // JSON in the shared viewer. The fetch hits discovery relays — worker
    // thread only.
    ui.on_view_contact_key_packages({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(row) = contacts.row_data(ui.get_active_contact() as usize) else {
                return;
            };
            let account_id = row.account_id.to_string();
            if account_id.is_empty() {
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            ui.set_debug_view_title(s("Key package"));
            ui.set_debug_view_subtitle(row.name.clone());
            ui.set_debug_view_json(s(""));
            ui.set_debug_view_busy(true);
            ui.set_debug_view_open(true);
            let weak = ui.as_weak();
            // `debug_contact_key_packages` does a `block_on` on the backend's
            // tokio runtime — run it on a plain thread, never a runtime worker
            // (that panics: "Cannot start a runtime from within a runtime").
            std::thread::spawn(move || {
                let json = b.debug_contact_key_packages(&account_id);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_debug_view_busy(false);
                    ui.set_debug_view_json(json.into());
                });
            });
        }
    });
    // Contact detail → "Start chat": create a 1:1 conversation with the
    // selected contact and drop the user into it. Mirrors the new-chat
    // modal's single-member path (`create_group` with one npub, empty
    // name) but skips the modal on success — failures surface there
    // instead, since the contact page has no inline status line.
    ui.on_start_chat_with_contact({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(row) = contacts.row_data(ui.get_active_contact() as usize) else {
                return;
            };
            let npub = row.npub_full.to_string();
            if npub.is_empty() {
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            // A contact can't be the user themselves, but guard anyway —
            // marmot rejects self-invites.
            let me_npub = npub_for_account_id(&b.account().account_id_hex).ok();
            if me_npub
                .as_deref()
                .map(|n| n.eq_ignore_ascii_case(&npub))
                .unwrap_or(false)
            {
                return;
            }
            let weak = weak.clone();
            let group_ids = group_ids.clone();
            std::thread::spawn(move || {
                let result = b.create_group("", std::slice::from_ref(&npub));
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(group_id) => {
                            let group_hex = hex::encode(group_id.as_slice());
                            refresh_chats_async(&ui, &b, &group_ids, move |ui, _b, snap| {
                                let pos = snap
                                    .records
                                    .iter()
                                    .position(|r| r.group_id_hex.eq_ignore_ascii_case(&group_hex));
                                if let Some(pos) = pos {
                                    // Arriving from the Contacts page — switch
                                    // to Chats so the new conversation is
                                    // visible, then select it.
                                    ui.set_active_page(Page::Chats as i32);
                                    refresh_breadcrumb_now(ui);
                                    ui.set_active_chat(pos as i32);
                                    ui.invoke_chat_selected(pos as i32);
                                }
                            });
                        }
                        Err(e) => {
                            tracing::warn!(target: "start_chat_with_contact", "{e:#}");
                            // No status line on the contact page, so surface
                            // the error in the new-chat modal (pre-filled
                            // with the member) where the user can adjust or
                            // retry.
                            ui.set_new_chat_name(s(""));
                            ui.set_new_chat_members(s(&npub));
                            ui.set_new_chat_busy(false);
                            ui.set_new_chat_status(friendly_error(ErrorOp::CreateChat, &e).into());
                            ui.set_show_new_chat(true);
                        }
                    }
                });
            });
        }
    });
    ui.on_contact_selected({
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let backend_cell = backend_cell.clone();
        move |idx| {
            if let Some(ui) = weak.upgrade() {
                ui.set_active_contact(idx);
                if let Some(b) = backend_cell.lock().unwrap().clone() {
                    push_contact_shared_groups(&ui, &b);
                }
                refresh();
                // Freshen the key-package status the moment the detail page
                // opens, so the readout is trustworthy without a manual press.
                spawn_contact_key_package_fetch(&ui, &backend_cell, idx as usize);
            }
        }
    });
    // A "groups in common" row was tapped (contact detail or profile modal):
    // switch to Chats and open that group. It's a visible group the local
    // account is in, so its hex is already in `group_ids`; a snapshot refresh
    // is the fallback if the ordering shifted since the list was built.
    ui.on_open_shared_group({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |group_hex| {
            let Some(ui) = weak.upgrade() else { return };
            let group_hex = group_hex.to_string();
            if group_hex.is_empty() {
                return;
            }
            // The row can be tapped from the profile modal, which overlays any
            // page; close it so the chat it opens is visible.
            ui.set_peer_profile_open(false);
            let pos = group_ids
                .lock()
                .unwrap()
                .iter()
                .position(|g| g.eq_ignore_ascii_case(&group_hex));
            if let Some(pos) = pos {
                ui.set_active_page(Page::Chats as i32);
                refresh_breadcrumb_now(&ui);
                ui.set_active_chat(pos as i32);
                ui.invoke_chat_selected(pos as i32);
                return;
            }
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            refresh_chats_async(&ui, &b, &group_ids, move |ui, _b, snap| {
                let Some(pos) = snap
                    .records
                    .iter()
                    .position(|r| r.group_id_hex.eq_ignore_ascii_case(&group_hex))
                else {
                    return;
                };
                ui.set_active_page(Page::Chats as i32);
                refresh_breadcrumb_now(ui);
                ui.set_active_chat(pos as i32);
                ui.invoke_chat_selected(pos as i32);
            });
        }
    });
}

/// Re-fetch the peer at `idx`'s latest key package from their relays off-thread,
/// showing the "Checking…" in-flight state while it runs, then patch every row
/// that matches the account id (the index may have moved) with the real
/// freshness state. Shared by the automatic fetch on contact-detail open and
/// the failure-only Retry button. On a miss or error the row keeps `kp-can-retry`
/// set, so the detail page keeps offering a Retry.
pub(crate) fn spawn_contact_key_package_fetch(
    ui: &DarkMatterLinux,
    backend_cell: &BackendCell,
    idx: usize,
) {
    let contacts = ui.get_contacts();
    let Some(mut row) = contacts.row_data(idx) else {
        return;
    };
    let account_id = row.account_id.to_string();
    if account_id.is_empty() {
        return;
    }
    let Some(b) = backend_cell.lock().unwrap().clone() else {
        return;
    };
    // Honest in-flight state instead of a frozen placeholder; hide the Retry
    // button while the fetch is outstanding.
    row.kp_status = s("Checking…");
    row.kp_detail = s("Contacting relays…");
    row.kp_can_retry = false;
    contacts.set_row_data(idx, row);

    let weak = ui.as_weak();
    std::thread::spawn(move || {
        let result = b.fetch_contact_key_package(&account_id);
        let (status, detail, can_retry) = match result {
            Ok((created_at, relays)) => {
                let (status, detail) = kp_labels(created_at, &relays);
                (status, detail, false)
            }
            Err(e) => {
                tracing::warn!(target: "backend", "fetch_contact_key_package failed: {e:#}");
                (
                    "Not found".to_string(),
                    "No key package on relays yet".to_string(),
                    true,
                )
            }
        };
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            let contacts = ui.get_contacts();
            let Some(vm) = contacts.as_any().downcast_ref::<VecModel<Contact>>() else {
                return;
            };
            for i in 0..vm.row_count() {
                let Some(mut r) = vm.row_data(i) else {
                    continue;
                };
                if r.account_id != account_id {
                    continue;
                }
                r.kp_status = s(&status);
                r.kp_detail = s(&detail);
                r.kp_can_retry = can_retry;
                vm.set_row_data(i, r);
                break;
            }
        });
    });
}
