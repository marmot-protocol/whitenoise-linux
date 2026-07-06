use crate::*;

pub(crate) fn wire_nav(ui: &DarkMatterLinux, cx: &Cx, h: &Handlers) {
    let Cx { settings_cell, .. } = cx.clone();
    let Handlers {
        refresh_breadcrumb,
        refresh_storage_size,
        ..
    } = h.clone();
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
