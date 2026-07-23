use crate::*;

/// Read the profile from the directory cache on the backend runtime (a
/// sqlite read), then apply it on the UI thread.
pub(crate) fn populate_profile_async(ui: &WhiteNoiseLinux, backend: &Arc<Backend>) {
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
    ui: &WhiteNoiseLinux,
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
        // No picture to load, so there is nothing to have failed or to retry.
        ui.set_my_av_load_failed(false);
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
pub(crate) fn fetch_profile_picture(ui: &WhiteNoiseLinux, backend: &Backend, url: &str) {
    let url = url.trim().to_string();
    // Starting a fresh attempt: drop any previous failure so the retry
    // affordance disappears while the download is in flight.
    ui.set_my_av_load_failed(false);
    if picture_cache_has(&url) {
        apply_picture(ui, &url);
        return;
    }
    let weak = ui.as_weak();
    let url_for_task = url.clone();
    // Flag the failure so the profile page can offer a retry, but only while
    // this URL is still the account's current picture: a profile edit that
    // swapped the URL out mid-download must not paint a stale failure.
    let mark_failed = {
        let weak = ui.as_weak();
        let url = url.clone();
        move || {
            let weak = weak.clone();
            let url = url.clone();
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ui) = weak.upgrade() else { return };
                if ui.get_profile_picture().as_str() == url && !ui.get_my_av_has_picture() {
                    ui.set_my_av_load_failed(true);
                }
            });
        }
    };
    backend.tokio_handle().spawn(async move {
        let bytes = match reqwest::get(&url_for_task).await {
            Ok(resp) => match resp.bytes().await {
                Ok(b) => b,
                Err(e) => {
                    tracing::warn!(target: "avatar", "download failed for {url_for_task}: {e}");
                    mark_failed();
                    return;
                }
            },
            Err(e) => {
                tracing::warn!(target: "avatar", "request failed for {url_for_task}: {e}");
                mark_failed();
                return;
            }
        };
        let pixels = match decode_avatar_pixels(&bytes) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(target: "avatar", "decode failed for {url_for_task}: {e}");
                mark_failed();
                return;
            }
        };
        picture_cache_put(url_for_task.clone(), pixels);
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                apply_picture(&ui, &url_for_task);
                ui.set_my_av_load_failed(false);
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
    ui: &WhiteNoiseLinux,
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
    ui.set_peer_profile_nip05_verified(false);
    ui.set_peer_profile_picture(slint::Image::default());
    ui.set_peer_profile_has_picture(false);
    ui.set_peer_profile_picture_failed(false);
    ui.set_peer_profile_picture_url(s(""));
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
    ui: &WhiteNoiseLinux,
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
    // The handle text always shows when present; the verified badge only
    // appears once it is confirmed against the domain's `.well-known/nostr.json`
    // (an unverified, self-declared handle renders without the check). Seed from
    // the cache, then confirm asynchronously and bind if the modal is still on
    // this account.
    let nip05 = profile
        .and_then(|p| p.nip05.as_deref())
        .unwrap_or("")
        .trim()
        .to_string();
    ui.set_peer_profile_nip05(s(&nip05));
    ui.set_peer_profile_nip05_verified(
        !nip05.is_empty() && nip05_verify_cached(account_id_hex, &nip05).unwrap_or(false),
    );
    if !nip05.is_empty() {
        let id = account_id_hex.to_string();
        spawn_nip05_verify(
            ui.as_weak(),
            backend.tokio_handle(),
            id.clone(),
            nip05.clone(),
            move |ui, verified| {
                if ui
                    .get_peer_profile_account_id()
                    .as_str()
                    .eq_ignore_ascii_case(&id)
                {
                    ui.set_peer_profile_nip05_verified(verified);
                }
            },
        );
    }
    ui.set_peer_profile_about(s(profile
        .and_then(|p| p.about.as_deref())
        .unwrap_or("")
        .trim()));
    ui.set_peer_profile_lud16(s(profile.and_then(|p| p.lud16.as_deref()).unwrap_or("")));

    let url = profile
        .and_then(|p| p.picture.clone())
        .filter(|u| !u.trim().is_empty());
    match url {
        Some(url) => {
            // Keep the source URL so the retry callback can re-enter the fetch,
            // and clear any prior failure before this attempt.
            ui.set_peer_profile_picture_url(s(url.trim()));
            ui.set_peer_profile_picture_failed(false);
            let (img, has) = bind_cached_picture(Some(&url));
            ui.set_peer_profile_picture(img);
            ui.set_peer_profile_has_picture(has);
            if !has {
                fetch_peer_profile_picture(ui, backend, account_id_hex, &url);
            }
        }
        None => {
            ui.set_peer_profile_picture_url(s(""));
            ui.set_peer_profile_picture_failed(false);
        }
    }
}

/// Download + decode the modal avatar, then bind it if the modal still shows
/// the same account. Cache-backed; the `slint::Image` is reconstructed on the
/// UI thread because it is `!Send`.
pub(crate) fn fetch_peer_profile_picture(
    ui: &WhiteNoiseLinux,
    backend: &Backend,
    account_id_hex: &str,
    url: &str,
) {
    let url = url.trim().to_string();
    let id = account_id_hex.to_string();
    let weak = ui.as_weak();
    let weak_fail = ui.as_weak();
    let id_fail = id.clone();
    backend.tokio_handle().spawn(async move {
        let Some(pixels) = fetch_picture_pixels(&url).await else {
            // Flag the failure so the modal can offer a retry, but only while it
            // still shows this account (the modal may have moved on).
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ui) = weak_fail.upgrade() else {
                    return;
                };
                if ui
                    .get_peer_profile_account_id()
                    .as_str()
                    .eq_ignore_ascii_case(&id_fail)
                    && !ui.get_peer_profile_has_picture()
                {
                    ui.set_peer_profile_picture_failed(true);
                }
            });
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
pub(crate) fn apply_picture(ui: &WhiteNoiseLinux, url: &str) {
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

// ─── NIP-05 verification ────────────────────────────────────────────────
//
// A "verified" badge must reflect a real check against the domain's
// `.well-known/nostr.json`, not the mere presence of a self-declared handle
// (anyone can put `jack@cash.app` in their kind-0 profile). Verification is a
// network fetch, so verdicts are cached process-wide (like avatar pixels) and
// keyed by the exact `(pubkey, handle)` pair: a profile that later changes its
// handle re-verifies rather than inheriting a stale verdict. Any parse,
// network, or HTTP failure is an unverified result — the badge only ever
// appears on a positive match.

/// Fetch `handle`'s domain `.well-known/nostr.json?name=<local>` and confirm
/// `names[local]` maps to `pubkey_hex` (NIP-05). Async, so it is safe to
/// `.await` inside a runtime task, unlike the blocking `Backend::add_contact`
/// resolve path. Returns `false` on any failure.
pub(crate) async fn verify_nip05(pubkey_hex: &str, handle: &str) -> bool {
    use nostr::nips::nip05::{Nip05Address, verify_from_raw_json};
    let Ok(pubkey) = nostr::PublicKey::from_hex(pubkey_hex) else {
        return false;
    };
    let handle = handle.trim().to_lowercase();
    let Ok(address) = Nip05Address::parse(&handle) else {
        return false;
    };
    let url = address.url().as_str().to_string();
    let Ok(client) = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
    else {
        return false;
    };
    let Ok(resp) = client.get(&url).send().await else {
        return false;
    };
    if !resp.status().is_success() {
        return false;
    }
    let Ok(body) = resp.text().await else {
        return false;
    };
    verify_from_raw_json(&pubkey, &address, &body).unwrap_or(false)
}

fn nip05_verify_cache() -> &'static Mutex<HashMap<String, bool>> {
    use std::sync::OnceLock;
    static CACHE: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn nip05_verify_key(pubkey_hex: &str, handle: &str) -> String {
    format!(
        "{}|{}",
        pubkey_hex.trim().to_lowercase(),
        handle.trim().to_lowercase()
    )
}

/// Cached verdict for an exact `(pubkey, handle)` pair: `Some(true)` verified,
/// `Some(false)` checked-and-failed, `None` not yet checked. Callers seed a
/// badge from this synchronously and default `None` to unverified.
pub(crate) fn nip05_verify_cached(pubkey_hex: &str, handle: &str) -> Option<bool> {
    nip05_verify_cache()
        .lock()
        .ok()?
        .get(&nip05_verify_key(pubkey_hex, handle))
        .copied()
}

fn nip05_verify_put(pubkey_hex: &str, handle: &str, verified: bool) {
    if let Ok(mut c) = nip05_verify_cache().lock() {
        c.insert(nip05_verify_key(pubkey_hex, handle), verified);
    }
}

/// Verify `handle` against `pubkey_hex` off the UI thread, then hop back to it
/// and hand the verdict to `apply` so the caller can bind its badge. A cached
/// verdict skips the fetch (still delivered through the same event-loop hop for
/// a uniform call site); a blank handle is a no-op. Mirrors the avatar
/// `spawn_picture_fetch` pipeline.
pub(crate) fn spawn_nip05_verify(
    weak: Weak<WhiteNoiseLinux>,
    handle: tokio::runtime::Handle,
    pubkey_hex: String,
    nip05: String,
    apply: impl FnOnce(&WhiteNoiseLinux, bool) + Send + 'static,
) {
    if nip05.trim().is_empty() {
        return;
    }
    if let Some(verified) = nip05_verify_cached(&pubkey_hex, &nip05) {
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                apply(&ui, verified);
            }
        });
        return;
    }
    handle.spawn(async move {
        let verified = verify_nip05(&pubkey_hex, &nip05).await;
        nip05_verify_put(&pubkey_hex, &nip05, verified);
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = weak.upgrade() {
                apply(&ui, verified);
            }
        });
    });
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
