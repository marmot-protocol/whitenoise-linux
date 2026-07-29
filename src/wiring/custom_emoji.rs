use crate::*;

/// Resolve `list` into picker rows, using whatever the process-wide picture
/// cache (`profiles.rs`) already has — the same cache avatars and profile
/// pictures share, since a custom emoji is just another public Blossom
/// image. Filtered by `query` against the shortcode, same as the Twemoji
/// catalog filters by name. Returns the rows plus the URLs still missing
/// from cache, so a caller with a `Backend` handy can fetch and re-refresh.
pub(crate) fn custom_emoji_entries(
    list: &[CustomEmoji],
    query: &str,
) -> (Vec<EmojiEntry>, Vec<String>) {
    let q = query.trim().to_lowercase();
    let mut rows = Vec::new();
    let mut missing = Vec::new();
    for c in list {
        if !q.is_empty() && !c.shortcode.to_lowercase().contains(&q) {
            continue;
        }
        let (picture, has_picture) = bind_cached_picture(Some(&c.url));
        if !has_picture {
            missing.push(c.url.clone());
        }
        rows.push(EmojiEntry {
            emoji: s(&format!(":{}:", c.shortcode)),
            name: s(&c.shortcode),
            clip_x: -1,
            clip_y: -1,
            picture,
            has_picture,
        });
    }
    (rows, missing)
}

/// Rebuild the picker's `emoji-list` from `custom` (first) plus the built-in
/// Twemoji catalog, and return whichever custom-emoji URLs missed the
/// picture cache so the caller can backfill them. Takes an owned snapshot
/// rather than reading `Settings` itself so it can run equally from the UI
/// thread or from inside a `tokio::spawn`ed backfill (an `Rc<RefCell<..>>`
/// settings handle isn't `Send`, a `Vec<CustomEmoji>` is).
pub(crate) fn build_and_set_emoji_rows(
    ui: &WhiteNoiseLinux,
    custom: &[CustomEmoji],
    query: &str,
) -> Vec<String> {
    let (mut list, missing) = custom_emoji_entries(custom, query);
    list.extend(build_emoji_list(query));
    let total = list.len();
    ui.set_emoji_list(ModelRc::new(VecModel::from(list)));
    ui.set_emoji_shown(total as i32);
    missing
}

/// Push the user's custom-emoji list into the Settings editor row
/// (`AppState.custom-emoji-list`), resolving pictures from cache. Called at
/// boot with whatever's already cached (usually nothing, on a cold start) and
/// again after every add/remove — an add seeds the cache directly from the
/// bytes just uploaded, so the fresh entry already has its picture by the
/// time this runs.
pub(crate) fn push_custom_emoji_settings_list(ui: &WhiteNoiseLinux, list: &[CustomEmoji]) {
    let (rows, _missing) = custom_emoji_entries(list, "");
    let entries: Vec<CustomEmojiEntry> = list
        .iter()
        .zip(rows)
        .map(|(c, r)| CustomEmojiEntry {
            shortcode: r.name,
            url: s(&c.url),
            picture: r.picture,
            has_picture: r.has_picture,
        })
        .collect();
    ui.set_custom_emoji_list(ModelRc::new(VecModel::from(entries)));
}

/// Re-resolve pictures for whichever rows in the already-set
/// `AppState.custom-emoji-list` missed the cache when it was last pushed —
/// typically the boot-time push, made before the backend (and so the
/// network) existed. Reads the URLs straight off the UI model instead of
/// `Settings` so it needs no `Rc<RefCell<Settings>>` (not `Send`, so it
/// couldn't ride into the `tokio::spawn`ed fetch below anyway). A no-op when
/// every row already has its picture.
pub(crate) fn backfill_custom_emoji_settings_list(ui: &WhiteNoiseLinux, backend: &Arc<Backend>) {
    let rows = ui.get_custom_emoji_list();
    let missing: Vec<String> = (0..rows.row_count())
        .filter_map(|i| rows.row_data(i))
        .filter(|e| !e.has_picture && !e.url.is_empty())
        .map(|e| e.url.to_string())
        .collect();
    if missing.is_empty() {
        return;
    }
    let weak = ui.as_weak();
    let backend = backend.clone();
    backend.tokio_handle().spawn(async move {
        let mut any = false;
        for url in missing {
            if fetch_picture_pixels(&url).await.is_some() {
                any = true;
            }
        }
        if !any {
            return;
        }
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            let rows = ui.get_custom_emoji_list();
            let refreshed: Vec<CustomEmojiEntry> = (0..rows.row_count())
                .filter_map(|i| rows.row_data(i))
                .map(|e| {
                    if e.has_picture {
                        return e;
                    }
                    let (picture, has_picture) = bind_cached_picture(Some(e.url.as_str()));
                    CustomEmojiEntry {
                        picture,
                        has_picture,
                        ..e
                    }
                })
                .collect();
            ui.set_custom_emoji_list(ModelRc::new(VecModel::from(refreshed)));
        });
    });
}

/// Normalize a user-entered shortcode: trim surrounding whitespace/colons,
/// lowercase, and fold anything that isn't `[a-z0-9_-]` to `_` so it stays a
/// safe `:shortcode:` token. Empty after cleanup (e.g. the user typed only
/// punctuation) yields `None`.
fn sanitize_shortcode(raw: &str) -> Option<String> {
    let trimmed = raw.trim().trim_matches(':').trim();
    if trimmed.is_empty() {
        return None;
    }
    let cleaned: String = trimmed
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    Some(cleaned)
}

fn show_custom_emoji_modal_status(
    ui: &WhiteNoiseLinux,
    message: impl Into<SharedString>,
    is_error: bool,
) {
    ui.set_custom_emoji_modal_status(message.into());
    ui.set_custom_emoji_modal_status_error(is_error);
}

/// Wire the Settings "Custom Emoji" editor: the "+" cell picks a local image,
/// uploads it via the same public Blossom path profile pictures use
/// (`src/blossom.rs`), then opens the naming modal; the modal's Save stores
/// `{ shortcode, url }` in settings.json and refreshes both the editor row
/// and (on next open) the emoji picker.
pub(crate) fn wire_custom_emoji(ui: &WhiteNoiseLinux, cx: &Cx) {
    let Cx {
        settings_cell,
        backend_cell,
        ..
    } = cx.clone();

    ui.global::<AppState>().on_custom_emoji_add_requested({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_custom_emoji_modal_busy() {
                return;
            }
            let tokio_handle = {
                let guard = backend_cell.lock().unwrap();
                match guard.as_ref() {
                    Some(b) => b.tokio_handle(),
                    None => return,
                }
            };
            ui.set_custom_emoji_modal_pending_url(s(""));
            ui.set_custom_emoji_modal_shortcode(s(""));
            ui.set_custom_emoji_modal_preview(slint::Image::default());
            ui.set_custom_emoji_modal_has_preview(false);
            ui.set_custom_emoji_modal_busy(true);
            show_custom_emoji_modal_status(&ui, error_copy().choosing_image, false);
            ui.set_show_custom_emoji_modal(true);
            let dialog_title = ui
                .global::<NativeDialogStrings>()
                .get_choose_custom_emoji()
                .to_string();
            let weak = weak.clone();
            let backend_cell = backend_cell.clone();
            tokio_handle.spawn(async move {
                let chosen = tokio::task::spawn_blocking(move || {
                    rfd::FileDialog::new()
                        .set_title(dialog_title)
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
                            ui.set_custom_emoji_modal_busy(false);
                            ui.set_show_custom_emoji_modal(false);
                        }
                    });
                    return;
                };

                let default_shortcode = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .and_then(sanitize_shortcode)
                    .unwrap_or_default();
                let bytes = match std::fs::read(&path) {
                    Ok(b) => b,
                    Err(e) => {
                        let msg = format!("could not read file: {e}");
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = weak.upgrade() {
                                ui.set_custom_emoji_modal_busy(false);
                                show_custom_emoji_modal_status(&ui, msg, true);
                            }
                        });
                        return;
                    }
                };
                let content_type = mime_guess::from_path(&path)
                    .first_or_octet_stream()
                    .essence_str()
                    .to_string();
                let preview_pixels = decode_avatar_pixels(&bytes).ok();

                let Some(backend) = backend_cell.lock().unwrap().clone() else {
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak.upgrade() {
                            ui.set_custom_emoji_modal_busy(false);
                            show_custom_emoji_modal_status(
                                &ui,
                                error_copy().backend_not_ready_lc,
                                true,
                            );
                        }
                    });
                    return;
                };

                {
                    let weak = weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = weak.upgrade() {
                            show_custom_emoji_modal_status(
                                &ui,
                                error_copy().uploading_blossom,
                                false,
                            );
                        }
                    });
                }

                let weak_done = weak.clone();
                backend.upload_public_blob_async(bytes, content_type, move |result| {
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak_done.upgrade() else {
                            return;
                        };
                        ui.set_custom_emoji_modal_busy(false);
                        match result {
                            Ok(url) => {
                                if let Some(pixels) = preview_pixels {
                                    picture_cache_put(url.clone(), pixels.clone());
                                    ui.set_custom_emoji_modal_preview(image_from_pixels(&pixels));
                                    ui.set_custom_emoji_modal_has_preview(true);
                                }
                                ui.set_custom_emoji_modal_shortcode(s(&default_shortcode));
                                ui.set_custom_emoji_modal_pending_url(s(&url));
                                show_custom_emoji_modal_status(
                                    &ui,
                                    error_copy().emoji_uploaded,
                                    false,
                                );
                            }
                            Err(e) => {
                                tracing::warn!(target: "custom_emoji", "upload failed: {e:#}");
                                show_custom_emoji_modal_status(
                                    &ui,
                                    friendly_error(ErrorOp::UploadPicture, &e),
                                    true,
                                );
                            }
                        }
                    });
                });
            });
        }
    });

    ui.global::<AppState>().on_custom_emoji_modal_save({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |shortcode| {
            let Some(ui) = weak.upgrade() else { return };
            let url = ui.get_custom_emoji_modal_pending_url().to_string();
            if url.is_empty() {
                return;
            }
            let Some(shortcode) = sanitize_shortcode(shortcode.as_str()) else {
                show_custom_emoji_modal_status(&ui, error_copy().emoji_shortcode_empty, true);
                return;
            };
            let mut st = settings_cell.borrow_mut();
            if st
                .custom_emoji
                .iter()
                .any(|c| c.shortcode.eq_ignore_ascii_case(&shortcode))
            {
                drop(st);
                show_custom_emoji_modal_status(&ui, error_copy().emoji_shortcode_taken, true);
                return;
            }
            st.custom_emoji.push(CustomEmoji { shortcode, url });
            st.save();
            push_custom_emoji_settings_list(&ui, &st.custom_emoji);
            drop(st);
            ui.set_custom_emoji_modal_pending_url(s(""));
            ui.set_show_custom_emoji_modal(false);
        }
    });

    ui.global::<AppState>().on_custom_emoji_modal_dismissed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_custom_emoji_modal_pending_url(s(""));
            ui.set_custom_emoji_modal_busy(false);
            ui.set_show_custom_emoji_modal(false);
        }
    });

    ui.global::<AppState>().on_custom_emoji_removed({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |index| {
            let Some(ui) = weak.upgrade() else { return };
            let mut st = settings_cell.borrow_mut();
            let idx = index as usize;
            if idx < st.custom_emoji.len() {
                st.custom_emoji.remove(idx);
                st.save();
                push_custom_emoji_settings_list(&ui, &st.custom_emoji);
            }
        }
    });
}
