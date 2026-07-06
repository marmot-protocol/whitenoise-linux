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
                            ui.set_add_contact_status(friendly_error("add contact", &e).into());
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
                            ui.set_peer_profile_status(friendly_error("add contact", &e).into());
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
    // Contact detail → "Refresh" key package: re-fetch the peer's latest key
    // package from their relays off-thread, then patch the row with the real
    // freshness state (matched by account-id, since the index may have moved).
    ui.on_contact_refresh_key_package({
        let weak = ui.as_weak();
        let contacts = contacts.clone();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_contact() as usize;
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
            // Honest in-flight state instead of a frozen placeholder.
            row.kp_status = s("Checking…");
            row.kp_detail = s("Contacting relays…");
            contacts.set_row_data(idx, row);

            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = b.fetch_contact_key_package(&account_id);
                let (status, detail) = match result {
                    Ok((created_at, relays)) => kp_labels(created_at, &relays),
                    Err(e) => {
                        tracing::warn!(target: "backend", "fetch_contact_key_package failed: {e:#}");
                        (
                            "Not found".to_string(),
                            "No key package on relays yet".to_string(),
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
                        vm.set_row_data(i, r);
                        break;
                    }
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
                            ui.set_new_chat_status(friendly_error("create chat", &e).into());
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
        move |idx| {
            if let Some(ui) = weak.upgrade() {
                ui.set_active_contact(idx);
                refresh();
            }
        }
    });
}
