// The profile/directory half of `impl Backend`: the name/picture cache, its
// warmers and async refreshers, and display-name resolution. Split out of
// `backend.rs` (same child-module pattern as `groups.rs`) to keep that file
// under the 2000-line pre-commit cap; see the module declarations at the
// bottom of `backend.rs`.

use super::*;

impl Backend {
    /// Resolve an account's published display name asynchronously: the local
    /// directory first, then kind-0 relay fetches (configured + discovery
    /// relays) with a directory re-read after each. Fetches retry with
    /// backoff — a transient relay failure must not strand the caller until
    /// some unrelated event re-asks (that stranding was visible as mention
    /// chips resolving only "on the next edit"). `on_done` runs on the
    /// backend runtime with the name, or `None` once every attempt is spent.
    /// Neutral plumbing — the mention resolver drives it via the
    /// messages-snapshot observer, but nothing here is mention-specific.
    pub fn resolve_display_name_async(
        &self,
        account_id_hex: &str,
        on_done: impl FnOnce(Option<String>) + Send + 'static,
    ) {
        let app = self.app.clone();
        let relays = self.discovery_relays();
        let id = account_id_hex.to_string();
        self.tokio.spawn(async move {
            let directory_name = |app: &MarmotApp| -> Option<String> {
                let p = app
                    .directory_entry_for_account_id(&id)
                    .ok()
                    .flatten()
                    .and_then(|e| e.profile)?;
                p.display_name
                    .filter(|n| !n.trim().is_empty())
                    .or(p.name)
                    .filter(|n| !n.trim().is_empty())
            };
            let mut attempt = 0u32;
            let name = loop {
                // Re-read the directory each pass — it also catches a fetch
                // whose write landed but wasn't readable on the previous pass.
                if let Some(name) = directory_name(&app) {
                    tracing::info!(target: "mentions", account = %id, %name, attempt, "resolved from directory");
                    break Some(name);
                }
                attempt += 1;
                if attempt > 3 {
                    break None;
                }
                if attempt > 1 {
                    tokio::time::sleep(Duration::from_secs(2u64 << (attempt - 2))).await;
                }
                tracing::info!(target: "mentions", account = %id, attempt, "not in directory — fetching kind-0 from relays");
                if let Err(e) = app
                    .refresh_profile_for_account_id(&id, relays.clone())
                    .await
                {
                    tracing::warn!(target: "mentions", account = %id, attempt, error = %e, "relay profile fetch failed");
                }
            };
            on_done(name);
        });
    }

    /// Best-effort profile picture URL for an account id. Cache-backed —
    /// see [`Backend::account_name_and_picture`].
    pub fn account_picture_url(&self, account_id_hex: &str) -> Option<String> {
        self.account_name_and_picture(account_id_hex).1
    }

    /// Best-effort display name for an account id (cache, then hex tail).
    pub fn account_display_name(&self, account_id_hex: &str) -> String {
        self.account_name_and_picture(account_id_hex).0
    }

    /// Published display name for ANY account, read synchronously from the
    /// directory storage (a disk read — never call on the UI thread). Unlike
    /// [`Self::account_name_and_picture`] this doesn't depend on the boot-time
    /// cache warm, so it resolves keys outside the user's groups/contacts —
    /// the mention warm paths (src/mentions.rs) use it for arbitrary npubs.
    /// `None` when the directory has no profile (or no name) for the key.
    pub fn directory_display_name(&self, account_id_hex: &str) -> Option<String> {
        let entry = self
            .app
            .directory_entry_for_account_id(account_id_hex)
            .ok()??;
        let profile = entry.profile?;
        profile
            .display_name
            .filter(|n| !n.trim().is_empty())
            .or(profile.name)
            .filter(|n| !n.trim().is_empty())
    }

    /// Display name + picture URL for an account id, served from the
    /// in-process profile cache — NEVER synchronously from the directory
    /// storage (see `profile_cache`). A cold entry returns the hex-tail
    /// fallback and queues a background refresh; the cache is warmed at boot
    /// for every group member + contact, so misses are rare.
    pub fn account_name_and_picture(&self, account_id_hex: &str) -> (String, Option<String>) {
        let key = account_id_hex.to_ascii_lowercase();
        if let Some(v) = self.profile_cache.lock().unwrap().get(&key) {
            return v.clone();
        }
        self.refresh_profile_cache_async(account_id_hex);
        let fallback = if account_id_hex.eq_ignore_ascii_case(&self.active_id()) {
            "You".to_string()
        } else {
            short_account_id(account_id_hex)
        };
        (fallback, None)
    }

    /// The uncached directory read backing the profile cache. Reads marmot's
    /// shared directory storage — can block behind the background sync's
    /// writes, so only the boot warm-up and async refreshes call it.
    pub(super) fn name_and_picture_direct(
        app: &MarmotApp,
        my_account_id_hex: &str,
        account_id_hex: &str,
    ) -> (String, Option<String>) {
        let is_self = account_id_hex.eq_ignore_ascii_case(my_account_id_hex);
        let entry = app
            .directory_entry_for_account_id(account_id_hex)
            .ok()
            .flatten();
        let profile = entry.and_then(|e| e.profile);
        let name = profile.as_ref().and_then(|p| {
            p.display_name
                .clone()
                .filter(|s| !s.is_empty())
                .or_else(|| p.name.clone().filter(|s| !s.is_empty()))
        });
        let pic = profile
            .as_ref()
            .and_then(|p| p.picture.clone().filter(|s| !s.is_empty()));
        let name = name.unwrap_or_else(|| {
            if is_self {
                "You".to_string()
            } else {
                short_account_id(account_id_hex)
            }
        });
        (name, pic)
    }

    /// Queue a background refresh of one account's cached name/picture.
    /// Deduped per account id.
    pub fn refresh_profile_cache_async(&self, account_id_hex: &str) {
        let key = account_id_hex.to_ascii_lowercase();
        {
            let mut inflight = self.profile_inflight.lock().unwrap();
            if !inflight.insert(key.clone()) {
                return;
            }
        }
        let app = self.app.clone();
        let me = self.active_id();
        let cache = self.profile_cache.clone();
        let inflight = self.profile_inflight.clone();
        self.tokio.spawn(async move {
            let v = Self::name_and_picture_direct(&app, &me, &key);
            inflight.lock().unwrap().remove(&key);
            cache.lock().unwrap().insert(key, v);
        });
    }

    /// Queue background refreshes for every cached profile. Called when the
    /// background directory sync completes, so names/pictures that changed
    /// while we were offline converge shortly after.
    pub fn refresh_all_profiles_async(&self) {
        let keys: Vec<String> = self.profile_cache.lock().unwrap().keys().cloned().collect();
        for k in keys {
            self.refresh_profile_cache_async(&k);
        }
    }

    /// Synchronously fill the profile cache for self, every known group
    /// member, and every contact. Called from boot (worker thread) before
    /// the background sync starts writing to the directory storage.
    pub(super) fn warm_profile_cache(&self) {
        let t = std::time::Instant::now();
        let mut ids: HashSet<String> = HashSet::new();
        ids.insert(self.active_id().to_ascii_lowercase());
        for members in self.members_cache.lock().unwrap().values() {
            for m in members {
                ids.insert(m.member_id_hex.to_ascii_lowercase());
            }
        }
        if let Ok(follows) = self.follow_list() {
            for f in &follows {
                ids.insert(f.account_id_hex.to_ascii_lowercase());
            }
        }
        let count = ids.len();
        for id in ids {
            let v = Self::name_and_picture_direct(&self.app, &self.active_id(), &id);
            self.profile_cache.lock().unwrap().insert(id, v);
        }
        tracing::debug!(
            target: "boot_timing", "profile cache warmed for {count} accounts in {:?}",
            t.elapsed()
        );
    }

    /// Full profile metadata for an account id from the local directory cache
    /// (own profile reads from disk). No network — `None` simply means the
    /// account isn't cached yet; callers fall back to
    /// [`Backend::fetch_profile_async`].
    pub fn cached_profile(&self, account_id_hex: &str) -> Option<UserProfileMetadata> {
        if account_id_hex.eq_ignore_ascii_case(&self.active_id()) {
            return self.load_profile().ok().flatten();
        }
        self.app
            .directory_entry_for_account_id(account_id_hex)
            .ok()
            .flatten()
            .and_then(|entry| entry.profile)
    }

    /// Fetch an arbitrary account's kind-0 profile from the relays (configured
    /// set + the whitenoise discovery relays), warming the directory cache,
    /// then hand the result to `on_done` on the tokio runtime. Used by the
    /// profile modal for @-mentioned users who aren't in any shared group and
    /// therefore have no cached directory entry.
    pub fn fetch_profile_async<F>(&self, account_id_hex: &str, on_done: F)
    where
        F: FnOnce(Option<UserProfileMetadata>) + Send + 'static,
    {
        let app = self.app.clone();
        let relays = self.discovery_relays();
        let id = account_id_hex.to_string();
        self.tokio.spawn(async move {
            if let Err(e) = app.refresh_profile_for_account_id(&id, relays).await {
                tracing::warn!(target: "backend::profile", account = %id, error = %e, "relay profile fetch failed");
            }
            let profile = app
                .directory_entry_for_account_id(&id)
                .ok()
                .flatten()
                .and_then(|entry| entry.profile);
            on_done(profile);
        });
    }
}
