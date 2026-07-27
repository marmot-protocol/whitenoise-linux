use crate::*;

pub(crate) fn wire_nav(ui: &WhiteNoiseLinux, cx: &Cx, h: &Handlers) {
    let Cx {
        settings_cell,
        backend_cell,
        archived_group_ids,
        ..
    } = cx.clone();
    let Handlers {
        refresh_breadcrumb,
        refresh_storage_size,
        ..
    } = h.clone();
    let go_to_page = {
        let weak = ui.as_weak();
        let refresh = refresh_breadcrumb.clone();
        let refresh_storage = refresh_storage_size.clone();
        let backend_cell = backend_cell.clone();
        let archived_group_ids = archived_group_ids.clone();
        move |page: Page| {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_active_page(page as i32);
            refresh();
            // Settings can land on the Storage tab — make sure the size is fresh.
            if matches!(page, Page::Settings) {
                refresh_storage();
            }
            // Archived binds to the same chat-members/chat-is-group globals the
            // live Chats tab uses. Reaching it via the left rail or command
            // palette skips the row click that normally refreshes them, so
            // it can render whatever chat was loaded last — refresh here too.
            if matches!(page, Page::Archived) {
                let idx = ui.get_active_archived();
                if idx >= 0 {
                    if let Some(backend) = backend_cell.lock().unwrap().clone() {
                        let hex = archived_group_ids.lock().unwrap().get(idx as usize).cloned();
                        if let Some(group_hex) = hex {
                            push_group_members_to_ui_async(&ui, &backend, &group_hex);
                        }
                    }
                }
            }
        }
    };
    ui.global::<AppState>().on_nav_requested({
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
    ui.global::<AppState>().on_profile_requested({
        let go = go_to_page.clone();
        move || go(Page::Profile)
    });

    // ─── Command palette wiring ────────────────────────────────────────
    let palette_master = all_palette_actions();

    // Ctrl+K: populate actions for the empty query and open the palette.
    ui.global::<AppState>().on_palette_requested({
        let weak = ui.as_weak();
        let master = palette_master.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_palette_query(s(""));
            ui.set_palette_actions(model(filter_palette(&master, "")));
            ui.set_show_palette(true);
        }
    });

    ui.global::<AppState>().on_palette_dismissed({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.set_show_palette(false);
            }
        }
    });

    ui.global::<AppState>().on_palette_query_changed({
        let weak = ui.as_weak();
        let master = palette_master.clone();
        move |q| {
            if let Some(ui) = weak.upgrade() {
                ui.set_palette_actions(model(filter_palette(&master, q.as_str())));
            }
        }
    });

    ui.global::<AppState>().on_palette_execute({
        let weak = ui.as_weak();
        let go = go_to_page.clone();
        let settings_cell = settings_cell.clone();
        move |id| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(command) = PaletteCommand::from_id(id.as_str()) else {
                tracing::warn!(target: "command_palette", "unknown palette action id: {}", id);
                return;
            };
            match command {
                PaletteCommand::NavChats => go(Page::Chats),
                PaletteCommand::NavContacts => go(Page::Contacts),
                PaletteCommand::NavArchived => go(Page::Archived),
                PaletteCommand::NavKeys => go(Page::Keys),
                PaletteCommand::NavSettings => go(Page::Settings),
                PaletteCommand::NavProfile => go(Page::Profile),
                PaletteCommand::NewChat => ui.set_show_new_chat(true),
                PaletteCommand::OpenSearch => ui.set_msg_global_open(true),
                PaletteCommand::CopyNpub => {
                    let npub = ui.get_my_npub();
                    let weak = weak.clone();
                    copy_to_clipboard_async(npub.to_string(), move |result| {
                        let Some(ui) = weak.upgrade() else { return };
                        match result {
                            Ok(()) => set_status_feedback(&ui, error_copy().npub_copied, false),
                            Err(e) => {
                                tracing::warn!(target: "clipboard", "copy npub failed: {e}");
                                set_status_feedback(&ui, error_copy().clipboard_failed, true);
                            }
                        }
                    });
                }
                PaletteCommand::ToggleRetro => {
                    let mode = if ui.get_theme_id() == theme_mode_idx("retro") {
                        "dark"
                    } else {
                        "retro"
                    };
                    {
                        let mut s = settings_cell.borrow_mut();
                        s.theme = mode.into();
                        s.save();
                    }
                    apply_theme_mode(&ui, mode);
                }
            }
        }
    });
}
