use crate::*;

/// Upload `bytes` as the account's profile picture and refresh the avatar
/// preview on success (mirrors `upload_group_image_async` in `groups.rs` for
/// groups). Shared by the local-file picker
/// (`wiring/extra.rs::on_upload_profile_picture`) and the remote-image-search
/// picker below — both reach this once they already have raw bytes + a
/// content type in hand. Lives here rather than in `extra.rs` because that
/// file is already at the crate's 2000-line cap.
pub(crate) fn upload_profile_picture_async(
    weak: slint::Weak<WhiteNoiseLinux>,
    backend_cell: BackendCell,
    bytes: Vec<u8>,
    content_type: String,
) {
    {
        let weak = weak.clone();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                show_profile_status(&ui, error_copy().uploading_blossom, StatusKind::Pending);
            }
        });
    }

    let weak_done = weak.clone();
    let backend_cell_done = backend_cell.clone();
    let guard = backend_cell.lock().unwrap();
    let Some(backend) = guard.as_ref() else {
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak_done.upgrade() {
                ui.set_profile_uploading(false);
                show_profile_status(&ui, error_copy().backend_not_ready_lc, StatusKind::Error);
            }
        });
        return;
    };
    backend.upload_public_blob_async(bytes, content_type, move |result| {
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak_done.upgrade() else {
                return;
            };
            ui.set_profile_uploading(false);
            match result {
                Ok(url) => {
                    ui.set_profile_picture(url.clone().into());
                    show_profile_status(&ui, error_copy().picture_uploaded, StatusKind::Ok);
                    if let Some(backend) = backend_cell_done.lock().unwrap().as_ref() {
                        fetch_profile_picture(&ui, backend, &url);
                    }
                }
                Err(e) => {
                    tracing::warn!(target: "profile", "picture upload failed: {e:#}");
                    show_profile_status(
                        &ui,
                        friendly_error(ErrorOp::UploadPicture, &e),
                        StatusKind::Error,
                    );
                }
            }
        });
    });
}

/// Which upload path a picked remote image re-enters — resolved once, at pick
/// time on the UI thread (where `AppState.remote-image-search-target` and the
/// active chat's group hex are both readable), then carried across the
/// download's tokio worker.
enum PickTarget {
    Group(String),
    Profile,
}

/// Download `full_url` and hand the bytes to `target`'s upload path. Runs
/// entirely on a tokio worker (called from the search modal's
/// `remote_image_search_pick` handler, itself already off the UI thread by
/// the time this fires).
fn download_and_apply_picked_image(
    weak: slint::Weak<WhiteNoiseLinux>,
    backend_cell: BackendCell,
    group_ids: Arc<Mutex<Vec<String>>>,
    target: PickTarget,
    full_url: String,
) {
    let tokio_handle = {
        let guard = backend_cell.lock().unwrap();
        match guard.as_ref() {
            Some(b) => b.tokio_handle(),
            None => return,
        }
    };
    tokio_handle.spawn(async move {
        let downloaded = match reqwest::get(&full_url).await {
            Ok(resp) if resp.status().is_success() => {
                let content_type = resp
                    .headers()
                    .get(reqwest::header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| {
                        mime_guess::from_path(&full_url)
                            .first_or_octet_stream()
                            .essence_str()
                            .to_string()
                    });
                match resp.bytes().await {
                    Ok(b) => Some((b.to_vec(), content_type)),
                    Err(e) => {
                        tracing::warn!(target: "image_search", "download body failed: {e:#}");
                        None
                    }
                }
            }
            Ok(resp) => {
                tracing::warn!(target: "image_search", "download failed: HTTP {}", resp.status());
                None
            }
            Err(e) => {
                tracing::warn!(target: "image_search", "download request failed: {e:#}");
                None
            }
        };

        let Some((bytes, content_type)) = downloaded else {
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ui) = weak.upgrade() else { return };
                match target {
                    PickTarget::Group(_) => {
                        ui.set_group_image_busy(false);
                        show_group_settings_status(
                            &ui,
                            error_copy().image_download_failed,
                            StatusKind::Error,
                        );
                    }
                    PickTarget::Profile => {
                        ui.set_profile_uploading(false);
                        show_profile_status(
                            &ui,
                            error_copy().image_download_failed,
                            StatusKind::Error,
                        );
                    }
                }
            });
            return;
        };

        match target {
            PickTarget::Group(group_hex) => {
                upload_group_image_async(
                    weak,
                    backend_cell,
                    group_ids,
                    group_hex,
                    bytes,
                    content_type,
                );
            }
            PickTarget::Profile => {
                upload_profile_picture_async(weak, backend_cell, bytes, content_type);
            }
        }
    });
}

/// Last query + result set per picker target (1 = group photo, 2 = profile
/// picture), so reopening the picker or switching targets prefills instead of
/// starting blank. Local to `wire_image_search`: nothing outside this module
/// reads it.
type ImageSearchMemory = Rc<RefCell<HashMap<i32, (String, Vec<ImageSearchHit>)>>>;

/// Save the modal's current query/results into `memory` under its current
/// target, called right before that target's state would otherwise be
/// discarded (cancel, pick, or reopening under the other target).
fn stash_image_search(ui: &WhiteNoiseLinux, memory: &ImageSearchMemory) {
    let target = ui.get_remote_image_search_target();
    if target == 0 {
        return;
    }
    let query = ui.get_remote_image_search_query().to_string();
    let results_model = ui.get_remote_image_search_results();
    let results: Vec<ImageSearchHit> = (0..results_model.row_count())
        .filter_map(|i| results_model.row_data(i))
        .collect();
    memory.borrow_mut().insert(target, (query, results));
}

/// Open the modal for `target`, prefilling from `memory` if a prior search
/// for that target was stashed, otherwise starting blank.
fn open_image_search(ui: &WhiteNoiseLinux, memory: &ImageSearchMemory, target: i32) {
    stash_image_search(ui, memory);
    let (query, results) = memory.borrow().get(&target).cloned().unwrap_or_default();
    ui.set_remote_image_search_target(target);
    ui.set_remote_image_search_query(s(&query));
    ui.set_remote_image_search_status(s(""));
    ui.set_remote_image_search_busy(false);
    ui.set_remote_image_search_results(ModelRc::new(VecModel::from(results)));
    ui.set_show_remote_image_search(true);
}

pub(crate) fn wire_image_search(ui: &WhiteNoiseLinux, cx: &Cx) {
    let Cx {
        backend_cell,
        group_ids,
        ..
    } = cx.clone();

    let image_search_memory: ImageSearchMemory = Rc::new(RefCell::new(HashMap::new()));

    ui.global::<AppState>().on_open_group_image_search({
        let weak = ui.as_weak();
        let memory = image_search_memory.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            open_image_search(&ui, &memory, 1);
        }
    });

    ui.global::<AppState>().on_open_profile_image_search({
        let weak = ui.as_weak();
        let memory = image_search_memory.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            open_image_search(&ui, &memory, 2);
        }
    });

    ui.global::<AppState>().on_remote_image_search_cancel({
        let weak = ui.as_weak();
        let memory = image_search_memory.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            stash_image_search(&ui, &memory);
            ui.set_show_remote_image_search(false);
            ui.set_remote_image_search_target(0);
        }
    });

    ui.global::<AppState>().on_remote_image_search_run({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.get_remote_image_search_busy() {
                return;
            }
            let query = ui.get_remote_image_search_query().to_string();
            if query.trim().is_empty() {
                return;
            }
            let tokio_handle = {
                let guard = backend_cell.lock().unwrap();
                match guard.as_ref() {
                    Some(b) => b.tokio_handle(),
                    None => {
                        ui.set_remote_image_search_status(s(&error_copy().backend_not_ready_lc));
                        return;
                    }
                }
            };
            ui.set_remote_image_search_busy(true);
            ui.set_remote_image_search_status(s(&error_copy().searching_images));

            let weak = weak.clone();
            tokio_handle.spawn(async move {
                let result = crate::image_search::search_images(&query).await;
                match result {
                    Ok(hits) if hits.is_empty() => {
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = weak.upgrade() {
                                ui.set_remote_image_search_busy(false);
                                ui.set_remote_image_search_status(s(
                                    &error_copy().image_search_no_results
                                ));
                            }
                        });
                    }
                    Ok(hits) => {
                        // Best-effort thumbnail fetch: a failed thumbnail
                        // still yields a pickable (blank) tile, since picking
                        // re-downloads from `full_url` independent of the
                        // thumbnail's fate.
                        let handles: Vec<_> = hits
                            .iter()
                            .map(|h| {
                                let url = h.thumbnail_url.clone();
                                tokio::spawn(async move { fetch_picture_pixels(&url).await })
                            })
                            .collect();
                        let mut thumbs = Vec::with_capacity(handles.len());
                        for handle in handles {
                            thumbs.push(handle.await.unwrap_or(None));
                        }
                        let _ = slint::invoke_from_event_loop(move || {
                            let Some(ui) = weak.upgrade() else { return };
                            ui.set_remote_image_search_busy(false);
                            ui.set_remote_image_search_status(s(""));
                            let rows: Vec<ImageSearchHit> = hits
                                .into_iter()
                                .zip(thumbs)
                                .map(|(hit, pixels)| {
                                    let (thumbnail, has_thumbnail) = match pixels {
                                        Some(p) => (image_from_pixels(&p), true),
                                        None => (slint::Image::default(), false),
                                    };
                                    ImageSearchHit {
                                        thumbnail,
                                        has_thumbnail,
                                        full_url: hit.full_url.into(),
                                        title: hit.title.into(),
                                    }
                                })
                                .collect();
                            ui.set_remote_image_search_results(ModelRc::new(VecModel::from(rows)));
                        });
                    }
                    Err(e) => {
                        tracing::warn!(target: "image_search", "search failed: {e:#}");
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = weak.upgrade() {
                                ui.set_remote_image_search_busy(false);
                                ui.set_remote_image_search_status(s(
                                    &error_copy().image_search_failed
                                ));
                            }
                        });
                    }
                }
            });
        }
    });

    ui.global::<AppState>().on_remote_image_search_pick({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let group_ids = group_ids.clone();
        let memory = image_search_memory.clone();
        move |index| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(hit) = ui
                .get_remote_image_search_results()
                .row_data(index as usize)
            else {
                return;
            };
            let is_group = ui.get_remote_image_search_target() == 1;
            stash_image_search(&ui, &memory);
            ui.set_show_remote_image_search(false);
            ui.set_remote_image_search_target(0);

            let target = if is_group {
                let idx = ui.get_active_chat() as usize;
                let Some(group_hex) = group_ids.lock().unwrap().get(idx).cloned() else {
                    return;
                };
                ui.set_group_image_busy(true);
                show_group_settings_status(&ui, error_copy().choosing_image, StatusKind::Pending);
                PickTarget::Group(group_hex)
            } else {
                ui.set_profile_uploading(true);
                show_profile_status(&ui, error_copy().choosing_image, StatusKind::Pending);
                PickTarget::Profile
            };

            download_and_apply_picked_image(
                weak.clone(),
                backend_cell.clone(),
                group_ids.clone(),
                target,
                hit.full_url.to_string(),
            );
        }
    });
}
