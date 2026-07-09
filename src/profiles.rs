use crate::*;

/// Read the profile from the directory cache on the backend runtime (a
/// sqlite read), then apply it on the UI thread.
pub(crate) fn populate_profile_async(ui: &DarkMatterLinux, backend: &Arc<Backend>) {
    let weak = ui.as_weak();
    let b = backend.clone();
    backend.tokio_handle().spawn(async move {
        let profile = b.load_profile();
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            populate_profile_from(&b, &ui, profile);
        });
    });
}

pub(crate) fn populate_profile_from(
    backend: &Backend,
    ui: &DarkMatterLinux,
    profile: anyhow::Result<Option<UserProfileMetadata>>,
) {
    let picture_url = match profile {
        Ok(profile) => {
            let url = profile
                .as_ref()
                .and_then(|p| p.picture.clone())
                .unwrap_or_default();
            apply_profile(ui, profile.as_ref());
            url
        }
        Err(e) => {
            tracing::warn!(target: "backend", "load_profile failed: {e:#}");
            apply_profile(ui, None);
            String::new()
        }
    };
    set_my_avatar(ui, backend);
    // If the URL is empty (or fetch fails), the Avatar falls back to the
    // initials/gradient — no further work needed here. Only clear when a
    // picture is currently bound: redundant writes to `my-av-picture`
    // re-render every outgoing bubble.
    if picture_url.trim().is_empty() {
        if ui.get_my_av_has_picture() {
            ui.set_my_av_has_picture(false);
            ui.set_my_av_picture(slint::Image::default());
        }
    } else {
        fetch_profile_picture(ui, backend, &picture_url);
    }
}

/// Background fetch + decode of the current account's profile picture.
/// `slint::Image` itself is `!Send`, so the worker thread ships raw RGBA
/// pixels + dimensions across the event loop and the actual `Image` is
/// constructed on the UI thread. Cache mirrors that shape.
pub(crate) fn fetch_profile_picture(ui: &DarkMatterLinux, backend: &Backend, url: &str) {
    let url = url.trim().to_string();
    if picture_cache_has(&url) {
        apply_picture(ui, &url);
        return;
    }
    let weak = ui.as_weak();
    let url_for_task = url.clone();
    backend.tokio_handle().spawn(async move {
        let bytes = match reqwest::get(&url_for_task).await {
            Ok(resp) => match resp.bytes().await {
                Ok(b) => b,
                Err(e) => {
                    tracing::warn!(target: "avatar", "download failed for {url_for_task}: {e}");
                    return;
                }
            },
            Err(e) => {
                tracing::warn!(target: "avatar", "request failed for {url_for_task}: {e}");
                return;
            }
        };
        let pixels = match decode_avatar_pixels(&bytes) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(target: "avatar", "decode failed for {url_for_task}: {e}");
                return;
            }
        };
        picture_cache_put(url_for_task.clone(), pixels);
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                apply_picture(&ui, &url_for_task);
            }
        });
    });
}

// ─── Peer profile modal ─────────────────────────────────────────────────

/// Resolve a nostr profile reference ("npub1…", "nprofile1…", or 64-char hex)
/// to an account-id hex. Non-profile entities (nevent/naddr/note) return None
/// so the caller can fall back to the platform URL handler.
pub(crate) fn nostr_ref_to_hex(reference: &str) -> Option<String> {
    if let Ok(pk) = nostr::PublicKey::parse(reference) {
        return Some(pk.to_hex());
    }
    use nostr::nips::nip19::FromBech32;
    nostr::nips::nip19::Nip19Profile::from_bech32(reference)
        .ok()
        .map(|p| p.public_key.to_hex())
}

/// Open the profile modal for `account_id_hex`. Cached directory data (group
/// members, contacts, self) renders instantly; unknown accounts — e.g. an
/// @mention of someone outside the group — get the loading skeleton plus an
/// async relay fetch through the discovery set.
pub(crate) fn open_profile_modal(
    ui: &DarkMatterLinux,
    backend_cell: &Arc<Mutex<Option<Arc<Backend>>>>,
    account_id_hex: &str,
) {
    let guard = backend_cell.lock().unwrap();
    let Some(backend) = guard.as_ref() else {
        return;
    };
    let id = account_id_hex.to_lowercase();
    let is_self = id.eq_ignore_ascii_case(&backend.account().account_id_hex);
    let npub = npub_for_account_id(&id).unwrap_or_else(|_| id.clone());
    let npub_short = shorten_npub(&npub);

    ui.set_peer_profile_account_id(s(&id));
    ui.set_peer_profile_npub(s(&npub));
    ui.set_peer_profile_npub_short(s(&npub_short));
    ui.set_peer_profile_is_self(is_self);
    ui.set_peer_profile_adding(false);
    ui.set_peer_profile_status(s(""));
    ui.set_peer_profile_not_found(false);
    ui.set_peer_profile_picture(slint::Image::default());
    ui.set_peer_profile_has_picture(false);
    // Groups in common — meaningless for one's own profile, so leave it empty
    // there (the modal hides the section for self anyway).
    let shared = if is_self {
        Vec::new()
    } else {
        shared_groups_rows(ui, backend, &id)
    };
    ui.set_peer_profile_shared_groups(model(shared));

    // Paint the loading skeleton immediately; follow-list membership and the
    // cached profile are sqlite reads, so they resolve on the runtime and
    // land a beat later (guarded against the modal moving on).
    ui.set_peer_profile_is_contact(false);
    ui.set_peer_profile_loading(true);
    apply_peer_profile(ui, backend, &id, &npub_short, None);
    ui.set_peer_profile_open(true);

    let weak = ui.as_weak();
    let backend_cell = backend_cell.clone();
    let b = backend.clone();
    let npub_short = npub_short.clone();
    backend.tokio_handle().spawn(async move {
        let is_contact = !is_self
            && b.follow_list()
                .map(|l| l.iter().any(|r| r.account_id_hex.eq_ignore_ascii_case(&id)))
                .unwrap_or(false);
        let cached = b.cached_profile(&id);
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            // Stale guard: the modal may have closed or moved on to a
            // different user while the lookup was in flight.
            if !ui
                .get_peer_profile_account_id()
                .as_str()
                .eq_ignore_ascii_case(&id)
            {
                return;
            }
            ui.set_peer_profile_is_contact(is_contact);
            if let Some(profile) = cached {
                ui.set_peer_profile_loading(false);
                apply_peer_profile(&ui, &b, &id, &npub_short, Some(&profile));
                return;
            }
            let weak = ui.as_weak();
            let id_done = id.clone();
            let npub_short_done = npub_short.clone();
            b.fetch_profile_async(&id, move |profile| {
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    // Same stale guard for the relay round-trip.
                    if !ui
                        .get_peer_profile_account_id()
                        .as_str()
                        .eq_ignore_ascii_case(&id_done)
                    {
                        return;
                    }
                    ui.set_peer_profile_loading(false);
                    let guard = backend_cell.lock().unwrap();
                    let Some(backend) = guard.as_ref() else {
                        return;
                    };
                    match profile {
                        Some(p) => {
                            apply_peer_profile(&ui, backend, &id_done, &npub_short_done, Some(&p))
                        }
                        None => ui.set_peer_profile_not_found(true),
                    }
                });
            });
        });
    });
}

/// Push a resolved (or placeholder) profile into the modal's properties and
/// kick off the avatar download when a picture URL is present.
pub(crate) fn apply_peer_profile(
    ui: &DarkMatterLinux,
    backend: &Backend,
    account_id_hex: &str,
    npub_short: &str,
    profile: Option<&UserProfileMetadata>,
) {
    let name = profile
        .and_then(|p| {
            p.display_name
                .clone()
                .filter(|s| !s.is_empty())
                .or_else(|| p.name.clone().filter(|s| !s.is_empty()))
        })
        .unwrap_or_else(|| npub_short.to_string());
    let (a, b, init) = avatar_for(&name);
    ui.set_peer_profile_name(s(&name));
    ui.set_peer_profile_av_a(a);
    ui.set_peer_profile_av_b(b);
    ui.set_peer_profile_av_initials(s(&init));
    ui.set_peer_profile_nip05(s(profile.and_then(|p| p.nip05.as_deref()).unwrap_or("")));
    ui.set_peer_profile_about(s(profile
        .and_then(|p| p.about.as_deref())
        .unwrap_or("")
        .trim()));
    ui.set_peer_profile_lud16(s(profile.and_then(|p| p.lud16.as_deref()).unwrap_or("")));

    let url = profile
        .and_then(|p| p.picture.clone())
        .filter(|u| !u.trim().is_empty());
    if let Some(url) = url {
        let (img, has) = bind_cached_picture(Some(&url));
        ui.set_peer_profile_picture(img);
        ui.set_peer_profile_has_picture(has);
        if !has {
            fetch_peer_profile_picture(ui, backend, account_id_hex, &url);
        }
    }
}

/// Download + decode the modal avatar, then bind it if the modal still shows
/// the same account. Cache-backed; the `slint::Image` is reconstructed on the
/// UI thread because it is `!Send`.
pub(crate) fn fetch_peer_profile_picture(
    ui: &DarkMatterLinux,
    backend: &Backend,
    account_id_hex: &str,
    url: &str,
) {
    let url = url.trim().to_string();
    let id = account_id_hex.to_string();
    let weak = ui.as_weak();
    backend.tokio_handle().spawn(async move {
        let Some(pixels) = fetch_picture_pixels(&url).await else {
            return;
        };
        picture_cache_put(url.clone(), pixels.clone());
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            if !ui
                .get_peer_profile_account_id()
                .as_str()
                .eq_ignore_ascii_case(&id)
            {
                return;
            }
            ui.set_peer_profile_picture(image_from_pixels(&pixels));
            ui.set_peer_profile_has_picture(true);
        });
    });
}

#[derive(Clone)]
pub(crate) struct PicturePixels {
    pub(crate) w: u32,
    pub(crate) h: u32,
    pub(crate) rgba: Vec<u8>,
}

/// Bind the user's own avatar picture by cache key (URL). Uses the shared
/// thread-local `Image` handle and SKIPS the property writes when the handle
/// is already bound: `my-av-picture` feeds the left-rail avatar AND every
/// outgoing bubble, so a fresh handle (or even a redundant set) re-renders
/// the whole conversation — the visible blink reported after background
/// syncs.
pub(crate) fn apply_picture(ui: &DarkMatterLinux, url: &str) {
    let Some(img) = cached_picture_image(url) else {
        return;
    };
    if ui.get_my_av_has_picture() && ui.get_my_av_picture() == img {
        return;
    }
    ui.set_my_av_picture(img);
    ui.set_my_av_has_picture(true);
}

pub(crate) fn picture_cache() -> &'static Mutex<HashMap<String, PicturePixels>> {
    use std::sync::OnceLock;
    static CACHE: OnceLock<Mutex<HashMap<String, PicturePixels>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn picture_cache_get(url: &str) -> Option<PicturePixels> {
    picture_cache().lock().ok()?.get(url).cloned()
}

pub(crate) fn picture_cache_put(url: String, pixels: PicturePixels) {
    if let Ok(mut c) = picture_cache().lock() {
        c.insert(url, pixels);
    }
}

/// Presence check that doesn't clone the pixel buffer out of the cache —
/// `picture_cache_get(url).is_some()` copies the whole RGBA blob just to
/// throw it away.
pub(crate) fn picture_cache_has(url: &str) -> bool {
    picture_cache()
        .lock()
        .map(|c| c.contains_key(url))
        .unwrap_or(false)
}

// UI-thread cache of ready `slint::Image` handles. `slint::Image` is `!Send`
// (it wraps a `VRc`), so this mirrors the `Send` pixel cache above as a
// thread-local: the first bind converts pixels → image once, and every later
// row build clones the cheap shared handle instead of re-copying the whole
// RGBA buffer. Sharing one handle across rows also means the renderer sees
// one texture per picture instead of one per bubble. Entries never go stale:
// the underlying pixel cache is write-once per key (URLs are
// content-addressed). Attachment images get the same treatment in
// `src/media.rs` (`cached_attachment_image`).
thread_local! {
    static PICTURE_IMAGES: RefCell<HashMap<String, slint::Image>> = RefCell::new(HashMap::new());
}

/// Resolve a picture-cache key (URL or `group-image:` key) to a shared
/// `slint::Image`, converting from cached pixels on first use. UI thread only.
pub(crate) fn cached_picture_image(url: &str) -> Option<slint::Image> {
    PICTURE_IMAGES.with(|cache| {
        if let Some(img) = cache.borrow().get(url) {
            return Some(img.clone());
        }
        let pixels = picture_cache_get(url)?;
        let img = image_from_pixels(&pixels);
        cache.borrow_mut().insert(url.to_string(), img.clone());
        Some(img)
    })
}

/// Resolve an optional picture URL against the process-wide picture cache,
/// returning a ready-to-render `(Image, has-picture)` pair. A miss yields the
/// default image; callers spawn an async fetch that repopulates the cache and
/// triggers a rebuild so the picture lands on a later frame.
pub(crate) fn bind_cached_picture(url: Option<&str>) -> (slint::Image, bool) {
    url.map(str::trim)
        .filter(|u| !u.is_empty())
        .and_then(cached_picture_image)
        .map(|img| (img, true))
        .unwrap_or((slint::Image::default(), false))
}

/// Map of sender account-id hex → (display name, optional picture URL).
/// Built once per rebuild so rendering N message rows costs one directory read
/// per *unique* sender instead of one per message (keeps the hot path cheap
/// while still resolving real profiles).
pub(crate) type SenderProfiles = std::collections::HashMap<String, (String, Option<String>)>;

pub(crate) fn build_sender_profiles(
    backend: &Backend,
    records: &[AppMessageRecord],
    my_id: &str,
) -> SenderProfiles {
    let mut map = SenderProfiles::new();
    for r in records {
        if r.sender.eq_ignore_ascii_case(my_id) {
            continue;
        }
        map.entry(r.sender.clone())
            .or_insert_with(|| backend.account_name_and_picture(&r.sender));
    }
    map
}
