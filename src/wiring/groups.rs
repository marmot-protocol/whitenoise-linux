use crate::*;

pub(crate) fn wire_groups(ui: &DarkMatterLinux, cx: &Cx) {
    let Cx {
        backend_cell,
        group_ids,
        archived_group_ids,
        ..
    } = cx.clone();
    ui.global::<AppState>().on_add_member({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |npub| {
            let Some(ui) = weak.upgrade() else { return };
            let npub = npub.trim().to_string();
            if npub.is_empty() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_add_member_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            ui.set_add_member_busy(true);
            ui.set_add_member_status(s(""));
            // Inviting publishes an MLS commit + welcome to relays — worker.
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.invite_members(&group_hex, std::slice::from_ref(&npub));
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_add_member_busy(false);
                    match result {
                        Ok(_) => {
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            ui.set_add_member_draft(s(""));
                            show_add_member_status(&ui, s("Invited."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "invite", "{e:#}");
                            show_add_member_status(
                                &ui,
                                friendly_error(ErrorOp::AddMember, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_promote_admin({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |member_id| {
            let Some(ui) = weak.upgrade() else { return };
            let member_id = member_id.trim().to_string();
            if member_id.is_empty() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            ui.set_group_settings_status(s(""));
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            // Admin changes publish an MLS commit to relays — worker.
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.promote_admin(&group_hex, &member_id);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(_) => {
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(&ui, s("Admin added."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "promote", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_demote_admin({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |member_id| {
            let Some(ui) = weak.upgrade() else { return };
            let member_id = member_id.trim().to_string();
            if member_id.is_empty() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            ui.set_group_settings_status(s(""));
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.demote_admin(&group_hex, &member_id);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(_) => {
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(&ui, s("Admin removed."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "demote", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_self_demote_admin({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            ui.set_group_settings_status(s(""));
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.self_demote_admin(&group_hex);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(_) => {
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(&ui, s("You stepped down."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "self_demote", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_remove_member({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |member_id| {
            let Some(ui) = weak.upgrade() else { return };
            let member_id = member_id.trim().to_string();
            if member_id.is_empty() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            ui.set_group_settings_status(s(""));
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            // Removal publishes an MLS commit to relays — worker.
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.remove_member(&group_hex, &member_id);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    match result {
                        Ok(_) => {
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(&ui, s("Member removed."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "remove_member", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_leave_group_at({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let archived_group_ids = archived_group_ids.clone();
        move |remove_idx| {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_group_leave_busy() || remove_idx < 0 {
                return;
            }
            let Some(group_hex) = group_ids.lock().unwrap().get(remove_idx as usize).cloned()
            else {
                return;
            };
            ui.set_group_leave_busy(true);
            show_group_settings_status(&ui, s("Leaving group…"), StatusKind::Pending);
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                ui.set_group_leave_busy(false);
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            let weak = weak.clone();
            let group_ids = group_ids.clone();
            let archived_group_ids = archived_group_ids.clone();
            std::thread::spawn(move || {
                let result = b.leave_group(&group_hex);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_group_leave_busy(false);
                    match result {
                        Ok(_) => {
                            ui.set_group_settings_status(s(""));
                            ui.set_show_chat_members(false);
                            let current_idx = ui.get_active_chat();
                            refresh_archived_async(&ui, &b, &archived_group_ids);
                            refresh_chats_async(&ui, &b, &group_ids, move |ui, _b, snap| {
                                let next = active_chat_after_row_removed(
                                    current_idx,
                                    remove_idx,
                                    snap.records.len(),
                                );
                                ui.set_active_chat(next);
                                if !snap.records.is_empty() {
                                    ui.global::<AppState>().invoke_chat_selected(next);
                                }
                            });
                        }
                        Err(e) => {
                            tracing::warn!(target: "leave_group", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_rename_group({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |name| {
            let Some(ui) = weak.upgrade() else { return };
            let name = name.trim().to_string();
            if name.is_empty() {
                show_group_settings_status(&ui, s("Name can't be empty."), StatusKind::Error);
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            ui.set_group_rename_busy(true);
            ui.set_group_settings_status(s(""));
            // Renaming publishes an MLS commit to relays — worker.
            let weak = weak.clone();
            let group_ids = group_ids.clone();
            std::thread::spawn(move || {
                let result = b.rename_group(&group_hex, &name);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_group_rename_busy(false);
                    match result {
                        Ok(_) => {
                            refresh_chats_async(&ui, &b, &group_ids, |_, _, _| {});
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(&ui, s("Renamed."), StatusKind::Ok);
                        }
                        Err(e) => {
                            tracing::warn!(target: "rename", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_set_group_description({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move |description| {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_group_description_busy() {
                return;
            }
            let description = description.trim().to_string();
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            ui.set_group_description_busy(true);
            ui.set_group_settings_status(s(""));
            // Description edits publish an MLS commit to relays — worker.
            let weak = weak.clone();
            std::thread::spawn(move || {
                let result = b.set_group_description(&group_hex, &description);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_group_description_busy(false);
                    match result {
                        Ok(_) => {
                            ui.set_chat_group_description(s(&description));
                            ui.set_group_description_draft(s(&description));
                            push_group_members_to_ui_async(&ui, &b, &group_hex);
                            show_group_settings_status(
                                &ui,
                                s("Description saved."),
                                StatusKind::Ok,
                            );
                        }
                        Err(e) => {
                            tracing::warn!(target: "group_description", "{e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupSettings, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_clear_group_image({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_group_image_busy() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            ui.set_group_image_busy(true);
            show_group_settings_status(&ui, s("removing image…"), StatusKind::Pending);
            let weak_done = ui.as_weak();
            let backend_cell_done = backend_cell.clone();
            let group_ids = group_ids.clone();
            let group_hex_done = group_hex.clone();
            let guard = backend_cell.lock().unwrap();
            let Some(b) = guard.as_ref() else {
                ui.set_group_image_busy(false);
                show_group_settings_status(&ui, s("Backend not ready."), StatusKind::Error);
                return;
            };
            b.set_group_image_async(&group_hex, Vec::new(), String::new(), move |result| {
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak_done.upgrade() else {
                        return;
                    };
                    ui.set_group_image_busy(false);
                    match result {
                        Ok(_) => {
                            show_group_settings_status(&ui, s("image removed"), StatusKind::Ok);
                            if let Some(b) = backend_cell_done.lock().unwrap().as_ref() {
                                refresh_chats_async(&ui, b, &group_ids, |_, _, _| {});
                                push_group_members_to_ui_async(&ui, b, &group_hex_done);
                            }
                        }
                        Err(e) => {
                            tracing::warn!(target: "group_image", "clear failed: {e:#}");
                            show_group_settings_status(
                                &ui,
                                friendly_error(ErrorOp::GroupImage, &e),
                                StatusKind::Error,
                            );
                        }
                    }
                });
            });
        }
    });
    ui.global::<AppState>().on_change_group_image({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_group_image_busy() {
                return;
            }
            let idx = ui.get_active_chat() as usize;
            let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                return;
            };
            let tokio_handle = {
                let guard = backend_cell.lock().unwrap();
                match guard.as_ref() {
                    Some(b) => b.tokio_handle(),
                    None => {
                        show_group_settings_status(&ui, s("backend not ready"), StatusKind::Error);
                        return;
                    }
                }
            };
            ui.set_group_image_busy(true);
            show_group_settings_status(&ui, s("choosing image…"), StatusKind::Pending);
            let weak = ui.as_weak();
            let backend_cell = backend_cell.clone();
            let group_ids = group_ids.clone();
            tokio_handle.spawn(async move {
                let chosen = tokio::task::spawn_blocking(|| {
                    rfd::FileDialog::new()
                        .set_title("Choose a group image")
                        .add_filter("Images", &["png", "jpg", "jpeg", "gif", "webp"])
                        .pick_file()
                })
                .await
                .ok()
                .flatten();

                let Some(path) = chosen else {
                    let weak = weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak.upgrade() {
                            ui.set_group_image_busy(false);
                            ui.set_group_settings_status(s(""));
                        }
                    });
                    return;
                };

                let bytes = match std::fs::read(&path) {
                    Ok(b) => b,
                    Err(e) => {
                        let msg = format!("could not read file: {e}");
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = weak.upgrade() {
                                ui.set_group_image_busy(false);
                                show_group_settings_status(&ui, msg, StatusKind::Error);
                            }
                        });
                        return;
                    }
                };
                let content_type = mime_guess::from_path(&path)
                    .first_or_octet_stream()
                    .essence_str()
                    .to_string();

                {
                    let weak = weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak.upgrade() {
                            show_group_settings_status(
                                &ui,
                                s("uploading to Blossom…"),
                                StatusKind::Pending,
                            );
                        }
                    });
                }

                let weak_done = weak.clone();
                let backend_cell_done = backend_cell.clone();
                let group_ids_done = group_ids.clone();
                let group_hex_done = group_hex.clone();
                let guard = backend_cell.lock().unwrap();
                let Some(backend) = guard.as_ref() else {
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak_done.upgrade() {
                            ui.set_group_image_busy(false);
                            show_group_settings_status(
                                &ui,
                                s("backend not ready"),
                                StatusKind::Error,
                            );
                        }
                    });
                    return;
                };
                backend.set_group_image_async(&group_hex, bytes, content_type, move |result| {
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak_done.upgrade() else {
                            return;
                        };
                        ui.set_group_image_busy(false);
                        match result {
                            Ok(_) => {
                                show_group_settings_status(
                                    &ui,
                                    s("group image updated"),
                                    StatusKind::Ok,
                                );
                                if let Some(backend) = backend_cell_done.lock().unwrap().as_ref() {
                                    refresh_chats_async(
                                        &ui,
                                        backend,
                                        &group_ids_done,
                                        |_, _, _| {},
                                    );
                                    push_group_members_to_ui_async(&ui, backend, &group_hex_done);
                                }
                            }
                            Err(e) => {
                                tracing::warn!(target: "group_image", "upload failed: {e:#}");
                                show_group_settings_status(
                                    &ui,
                                    friendly_error(ErrorOp::GroupImage, &e),
                                    StatusKind::Error,
                                );
                            }
                        }
                    });
                });
            });
        }
    });
}

fn active_chat_after_row_removed(current: i32, removed: i32, remaining_rows: usize) -> i32 {
    if remaining_rows == 0 {
        return 0;
    }
    let last = remaining_rows.saturating_sub(1) as i32;
    let next = if current == removed {
        removed
    } else if current > removed {
        current - 1
    } else {
        current
    };
    next.min(last).max(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn active_chat_after_removed_tail_moves_to_previous_row() {
        assert_eq!(active_chat_after_row_removed(3, 3, 3), 2);
    }

    #[test]
    fn active_chat_after_removed_middle_keeps_same_index() {
        assert_eq!(active_chat_after_row_removed(1, 1, 3), 1);
    }

    #[test]
    fn active_chat_after_last_row_removed_stays_at_zero() {
        assert_eq!(active_chat_after_row_removed(0, 0, 0), 0);
    }

    #[test]
    fn active_chat_after_removed_row_before_current_shifts_left() {
        assert_eq!(active_chat_after_row_removed(3, 1, 4), 2);
    }

    #[test]
    fn active_chat_after_removed_row_after_current_keeps_current() {
        assert_eq!(active_chat_after_row_removed(1, 3, 4), 1);
    }
}
