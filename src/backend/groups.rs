use super::*;

/// One group the local account shares with another account: the group's id,
/// display name, and member count. Returned by [`Backend::shared_groups`] and
/// turned into `SharedGroup` UI rows by the contact/profile glue.
pub struct SharedGroupInfo {
    pub group_id_hex: String,
    pub name: String,
    pub member_count: usize,
    /// Avatar cache key for the group, resolved with the same precedence the
    /// chat list uses: a `marmot.group.avatar-url.v1` URL when present, else
    /// the encrypted Blossom image as `group-image:{hash}`, else `None`.
    pub avatar_key: Option<String>,
}

impl Backend {
    /// Look up one visible chat by its group-id hex (case-insensitive — the
    /// invariant every lookup site must honor). Takes a full `chats()`
    /// snapshot today; centralizing here leaves room for a cheaper query.
    pub(crate) fn find_chat(&self, group_hex: &str) -> Option<AppGroupRecord> {
        self.chats()
            .ok()?
            .into_iter()
            .find(|g| g.group_id_hex.eq_ignore_ascii_case(group_hex))
    }

    /// Create a 1:1 or group chat with the listed members (npub or hex pubkey).
    pub fn create_group(&self, name: &str, members: &[String]) -> Result<GroupId> {
        // The account must have a published NIP-65 list before the runtime will
        // create a group; backfill it if a prior boot left it missing.
        self.ensure_account_relay_lists()?;

        // Diagnostic: log our own relay-list status so a "missing nip65" failure
        // can be unambiguously attributed to us vs. a peer.
        match self
            .app
            .account_relay_list_status_for_account_id(&self.active_id())
        {
            Ok(status) => tracing::info!(
                target: "backend::create_group",
                complete = status.complete,
                missing = ?status.missing,
                nip65 = ?status.nip65.relays,
                "local account relay-list status before create_group"
            ),
            Err(e) => {
                tracing::warn!(target: "backend::create_group", error = %e, "could not read local relay-list status")
            }
        }

        // Warm the directory cache for each peer against the broad discovery set
        // and fail early with a clear, peer-named error if any can't be found.
        let unresolved = self.prewarm_members(members);
        if !unresolved.is_empty() {
            let detail = unresolved
                .iter()
                .map(|(m, e)| format!("{m} ({e})"))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(anyhow!(
                "can't reach these contacts — they haven't published a relay list / key package to any relay we know: {detail}"
            ));
        }

        let label = self.active_label();
        let members = members.to_vec();
        let runtime = self.runtime.clone();
        let name = name.to_string();
        self.tokio.block_on(async move {
            runtime
                .create_group(&label, &name, &members, None)
                .await
                .map_err(|e| anyhow!("create_group: {e}"))
        })
    }

    /// Find the active account's "Saved Messages" self-chat by its sentinel
    /// group-profile name ([`SAVED_MESSAGES_NAME`]). Scans the full group set
    /// (archived included). Detection is by profile name rather than member
    /// list because the member cache is empty until it warms — keying off it
    /// would miss the self-chat right after boot and create a duplicate.
    pub fn find_self_chat(&self) -> Option<String> {
        self.app
            .groups(&self.active_label())
            .ok()?
            .into_iter()
            .find(|g| g.profile.name == SAVED_MESSAGES_NAME)
            .map(|g| g.group_id_hex)
    }

    /// Ensure the active account has a built-in "Saved Messages" notes-to-self
    /// chat, returning its group id hex. Idempotent: returns the existing
    /// self-chat when one is present, otherwise creates a solo MLS group with
    /// no other members. A solo group is valid MLS (the creator is its only
    /// member), so notes/links/media saved here stay private to the account and
    /// gain cross-device sync for free once multi-device lands.
    pub fn ensure_self_chat(&self) -> Result<String> {
        if let Some(hex) = self.find_self_chat() {
            return Ok(hex);
        }
        // marmot rejects group creation when the account has never published a
        // NIP-65 list (same precondition as `create_group`); backfill it. With
        // no members there are no welcomes to publish, so there's no per-peer
        // relay round-trip — just the local MLS group create.
        self.ensure_account_relay_lists()?;
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let id = self.tokio.block_on(async move {
            runtime
                .create_group(&label, SAVED_MESSAGES_NAME, &[], None)
                .await
                .map_err(|e| anyhow!("create self-chat: {e}"))
        })?;
        Ok(hex::encode(id.as_slice()))
    }

    /// Invite additional members into an existing group. Caller must be an
    /// admin of the group (the runtime enforces this; non-admins get an error).
    /// `members` are npub or hex pubkey strings; the runtime fetches each
    /// peer's key package off the relay set before committing.
    pub fn invite_members(&self, group_hex: &str, members: &[String]) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;

        // Same preflight as create_group: the runtime resolves each invitee's
        // relay list + key package against only the configured relays, so a
        // peer who published solely to the discovery indexers fails with the
        // cryptic `missing account relay lists: ["nip65"]` (the *peer's* list,
        // not ours). Warm the cache against the broad set and name the peer.
        self.ensure_account_relay_lists()?;
        let unresolved = self.prewarm_members(members);
        if !unresolved.is_empty() {
            let detail = unresolved
                .iter()
                .map(|(m, e)| format!("{m} ({e})"))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(anyhow!(
                "can't reach these contacts — they haven't published a relay list / key package to any relay we know: {detail}"
            ));
        }

        let label = self.active_label();
        let members = members.to_vec();
        let runtime = self.runtime.clone();
        let summary = self.tokio.block_on(async move {
            runtime
                .invite_members(&label, &group_id, &members)
                .await
                .map_err(|e| anyhow!("invite_members: {e}"))
        })?;
        // The invite commits an MLS Add, so the invitee is in the roster right
        // away (before they accept). But `group_members` is served from
        // `members_cache`, which this invite did not touch, so the immediate UI
        // push would repaint the pre-invite list and the new member (under the
        // "Invited" section) would not show until a later async refresh landed.
        // Refresh the cache synchronously here, mirroring `remove_member`.
        self.refresh_members_blocking(group_hex);
        Ok(summary)
    }

    /// Groups the local account has in common with `account_id_hex`: every
    /// visible group whose cached member list includes that account. 1:1 DMs
    /// (two members) are excluded — they aren't a "group in common" — as is
    /// any group the account isn't a member of. The join is `chats()` against
    /// the members cache, so it stays a cheap in-memory scan; the cache is
    /// warmed at boot and refreshed on group events, and any group still cold
    /// reads as empty and is skipped (a re-open picks it up once warmed).
    pub fn shared_groups(&self, account_id_hex: &str) -> Vec<SharedGroupInfo> {
        let groups = match self.chats() {
            Ok(g) => g,
            Err(e) => {
                tracing::warn!(target: "backend", "shared_groups: chats() failed: {e:#}");
                return Vec::new();
            }
        };
        let mut out: Vec<SharedGroupInfo> = groups
            .iter()
            .filter_map(|g| {
                let members = self.group_members(&g.group_id_hex).unwrap_or_default();
                if members.len() <= 2 {
                    return None;
                }
                let is_member = members
                    .iter()
                    .any(|m| m.member_id_hex.eq_ignore_ascii_case(account_id_hex));
                if !is_member {
                    return None;
                }
                let name = if g.profile.name.trim().is_empty() {
                    g.group_id_hex.clone()
                } else {
                    g.profile.name.clone()
                };
                let avatar_key = if g.avatar_url.present && !g.avatar_url.url.trim().is_empty() {
                    Some(g.avatar_url.url.trim().to_string())
                } else if g.image.present && !g.image.image_hash_hex.is_empty() {
                    Some(format!("group-image:{}", g.image.image_hash_hex))
                } else {
                    None
                };
                Some(SharedGroupInfo {
                    group_id_hex: g.group_id_hex.clone(),
                    name,
                    member_count: members.len(),
                    avatar_key,
                })
            })
            .collect();
        out.sort_by_key(|g| g.name.to_lowercase());
        out
    }

    /// Promote a group member to admin. Caller must already be an admin (the
    /// engine enforces this on the outbound MLS commit; non-admins get an
    /// error). `member_ref` is an npub, hex pubkey, or known account label —
    /// `member_id_hex` from a group-member record works directly.
    pub fn promote_admin(&self, group_hex: &str, member_ref: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let member_ref = member_ref.to_string();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .promote_admin(&label, &group_id, &member_ref)
                .await
                .map_err(|e| anyhow!("promote_admin: {e}"))
        })
    }

    /// Demote a group admin back to a regular member. Caller must be an admin
    /// (the engine enforces this; non-admins get an error). `member_ref` is an
    /// npub, hex pubkey, or known account label.
    pub fn demote_admin(&self, group_hex: &str, member_ref: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let member_ref = member_ref.to_string();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .demote_admin(&label, &group_id, &member_ref)
                .await
                .map_err(|e| anyhow!("demote_admin: {e}"))
        })
    }

    /// Remove a member from a group. Caller must be an admin (the engine
    /// enforces this on the outbound MLS commit; non-admins get an error).
    /// `member_ref` is an npub, hex pubkey, or known account label —
    /// `member_id_hex` from a group-member record works directly. Marmot's
    /// `remove_members` takes a slice; we pass the single target.
    pub fn remove_member(&self, group_hex: &str, member_ref: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let members = vec![member_ref.to_string()];
        let runtime = self.runtime.clone();
        let summary = self.tokio.block_on(async move {
            runtime
                .remove_members(&label, &group_id, &members)
                .await
                .map_err(|e| anyhow!("remove_member: {e}"))
        })?;
        // The eviction mutated the roster, but `group_members` is served from
        // `members_cache`, which the removal did not touch — so the immediate
        // UI push would repaint the pre-removal list and look like nothing
        // happened. Refresh the cache synchronously here so the next read (the
        // panel rebuild) reflects the departed member. Role changes (promote/
        // demote) do not need this: their badges come from `chats()`, a fresh
        // source, not this cache.
        self.refresh_members_blocking(group_hex);
        Ok(summary)
    }

    /// Relinquish the active account's own admin rights on `group_hex`.
    pub fn self_demote_admin(&self, group_hex: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .self_demote_admin(&label, &group_id)
                .await
                .map_err(|e| anyhow!("self_demote_admin: {e}"))
        })
    }

    /// Leave a group, then hide it from the active chat list locally.
    pub fn leave_group(&self, group_hex: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let group_hex = hex::encode(group_id.as_slice());
        let label = self.active_label();
        let runtime = self.runtime.clone();
        let result = self
            .tokio
            .block_on(async move { runtime.leave_group(&label, &group_id).await });
        match result {
            Ok(summary) => {
                self.set_group_archived(&group_hex, true)?;
                Ok(summary)
            }
            Err(e) => {
                let err = anyhow!("leave_group: {e}");
                if leave_group_error_hides_chat(&err) {
                    self.set_group_archived(&group_hex, true)?;
                    Ok(SendSummary {
                        published: 0,
                        message_ids: Vec::new(),
                    })
                } else {
                    Err(err)
                }
            }
        }
    }

    /// Rename a group. Caller must be an admin (the engine enforces this on the
    /// outbound MLS commit; non-admins get an error). Publishes the new name via
    /// the group's `marmot.group.profile.v1` component, leaving the description
    /// untouched.
    pub fn rename_group(&self, group_hex: &str, new_name: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let name = new_name.to_string();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .update_group_profile(&label, &group_id, Some(name), None)
                .await
                .map_err(|e| anyhow!("rename_group: {e}"))
        })
    }

    /// Update a group's description without changing its name.
    pub fn set_group_description(&self, group_hex: &str, description: &str) -> Result<SendSummary> {
        let group_id = group_id_from_hex(group_hex)?;
        let label = self.active_label();
        let description = description.to_string();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .update_group_profile(&label, &group_id, None, Some(description))
                .await
                .map_err(|e| anyhow!("set_group_description: {e}"))
        })
    }

    /// Encrypt + upload a new group avatar to Blossom and publish the group image
    /// component (admin-only, enforced by the engine). Non-blocking: runs on the
    /// tokio runtime and fires `on_done` on a worker thread. Passing empty `bytes`
    /// clears the image.
    pub fn set_group_image_async<F>(
        &self,
        group_hex: &str,
        bytes: Vec<u8>,
        media_type: String,
        on_done: F,
    ) where
        F: FnOnce(Result<SendSummary>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(id) => id,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        // A URL avatar (marmot.group.avatar-url.v1, what Android publishes)
        // takes render precedence over the Blossom image, so setting a new
        // image while one is present would be invisible everywhere. Clear it
        // after a successful image commit; the spec's fallback then lands on
        // the fresh image.
        let clear_url_avatar = !bytes.is_empty()
            && self
                .find_chat(group_hex)
                .map(|g| g.avatar_url.present)
                .unwrap_or(false);
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.spawn(async move {
            let result = runtime
                .update_group_image(&label, &group_id, bytes, media_type)
                .await
                .map_err(|e| anyhow!("set_group_image: {e}"));
            if result.is_ok()
                && clear_url_avatar
                && let Err(e) = runtime
                    .update_group_avatar_url(&label, &group_id, None, None, None)
                    .await
            {
                tracing::warn!(target: "group_avatar", "clear url avatar failed: {e:#}");
            }
            on_done(result);
        });
    }

    /// Fetch + decrypt the group's avatar into raw image bytes (PNG/JPEG/etc.).
    /// Non-blocking; `on_done` fires on a worker thread. Errors when the group
    /// has no image set.
    pub fn fetch_group_image_async<F>(&self, group_hex: &str, on_done: F)
    where
        F: FnOnce(Result<Vec<u8>>) + Send + 'static,
    {
        let group_id = match group_id_from_hex(group_hex) {
            Ok(id) => id,
            Err(e) => {
                on_done(Err(e));
                return;
            }
        };
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.spawn(async move {
            let result = runtime
                .download_group_blossom_image(&label, &group_id)
                .await
                .map_err(|e| anyhow!("fetch_group_image: {e}"));
            on_done(result);
        });
    }

    /// True when the active account is an admin of `group_hex`. Looks at the
    /// group's admin policy component; the admins list contains 32-byte hex
    /// pubkeys, identical encoding to `account_id_hex`.
    pub fn is_group_admin(&self, group_hex: &str) -> bool {
        let me = self.active_id();
        self.find_chat(group_hex)
            .map(|g| {
                g.admin_policy
                    .admins
                    .iter()
                    .any(|a| a.eq_ignore_ascii_case(&me))
            })
            .unwrap_or(false)
    }

    /// Local key-package records for the active account. Sync — reads the
    /// on-disk JSON next to the account home. Use `key_packages_fetch()` for
    /// the network-augmented view (local + what's actually on the relay).
    pub fn key_packages_local(&self) -> Vec<marmot_app::AccountKeyPackageRecord> {
        self.app
            .local_key_package_records(&self.active_label())
            .unwrap_or_default()
    }

    /// Full key-package state: local + a relay snapshot from the account's
    /// configured key-package relays. Bootstrap relay list is whatever the
    /// account was booted with — empty means use the cached relay list.
    pub fn key_packages_fetch(&self) -> Result<Vec<marmot_app::AccountKeyPackageRecord>> {
        let label = self.active_label();
        let app = self.app.clone();
        let bootstrap = self.relay_endpoints();
        self.tokio.block_on(async move {
            app.account_key_package_records(&label, bootstrap)
                .await
                .map_err(|e| anyhow!("account_key_package_records: {e}"))
        })
    }

    /// Relays this account uses for key-package publishing. After the upstream
    /// relay-list rework there is no dedicated kind-10051 list — KeyPackages
    /// publish to the account's NIP-65 (kind 10002) outbox relays, falling back
    /// to the configured bootstrap relays when no NIP-65 list exists yet.
    pub fn key_package_relays(&self) -> Vec<String> {
        let nip65 = self
            .app
            .account_relay_list_status_for_account_id(&self.active_id())
            .map(|status| status.nip65.relays)
            .unwrap_or_default();
        if nip65.is_empty() {
            self.relays.clone()
        } else {
            nip65
        }
    }

    /// Publish a fresh key package for the active account. Returns the number
    /// of relays that acked the publish. Same call as the runtime worker's
    /// `PublishKeyPackage` command.
    pub fn publish_key_package(&self) -> Result<usize> {
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .publish_key_package(&label)
                .await
                .map_err(|e| anyhow!("publish_key_package: {e}"))
        })
    }

    /// Rotate the key package: invalidate the current one (delete-event on
    /// the relay set) and publish a fresh one. Returns the relay-ack count
    /// for the new publish.
    pub fn rotate_key_package(&self) -> Result<usize> {
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.block_on(async move {
            runtime
                .rotate_key_package(&label)
                .await
                .map_err(|e| anyhow!("rotate_key_package: {e}"))
        })
    }

    /// Fetch a *contact's* latest published key package from their relays
    /// (broad discovery set), returning the event's created-at (unix secs) and
    /// the relays it was found on — the real freshness data the contact-detail
    /// IDENTITY panel shows. Sync + blocking: call from a worker thread, never
    /// the UI thread. Accepts npub or hex (normalized internally by marmot).
    pub fn fetch_contact_key_package(&self, account_id: &str) -> Result<(u64, Vec<String>)> {
        let account_id_hex = nostr::PublicKey::parse(account_id)
            .map(|pk| pk.to_hex())
            .map_err(|_| anyhow!("not a valid npub or hex pubkey"))?;
        let broad = self.discovery_relays();
        let app = self.app.clone();
        let fetched = self
            .tokio
            .block_on(async move {
                app.fetch_latest_key_package_for_account_id(&account_id_hex, broad)
                    .await
            })
            .map_err(|e| anyhow!("fetch_latest_key_package_for_account_id: {e}"))?;
        Ok((fetched.created_at, fetched.source_relays))
    }

    /// Relay URLs the running backend was booted with. The on-disk list
    /// (via `load_relays()`) may differ if the user edited it since launch —
    /// in that case the UI shows a "restart to apply" banner.
    pub fn booted_relays(&self) -> &[String] {
        &self.relays
    }

    /// Aggregate connection health of the relay plane. Returns
    /// `(connected, total)`. `total` counts only relays the SDK is currently
    /// tracking, which can lag the configured list briefly after boot.
    pub fn relay_health(&self) -> (usize, usize) {
        let plane = self.runtime.shared_services().relay_plane().clone();
        let health = self
            .tokio
            .block_on(async move { plane.relay_health().await });
        (health.connected, health.total_relays)
    }

    // Diagnostic JSON snapshot — account info, key packages on disk, and
    // projected group rows (visible + archived). Used by the in-app debug
    // pane to surface state that's otherwise locked behind encrypted SQLite.
    // ─── Security & privacy / developer settings ───────────────────────
    // These mirror the darkmatter-android "Security & Privacy" + "Developer"
    // settings cluster. Telemetry + audit-log *enabled* state live in marmot's
    // shared storage (read/written via MarmotApp), not our local settings JSON.

    /// Whether anonymous relay-connection telemetry export is enabled.
    pub fn telemetry_enabled(&self) -> bool {
        self.app
            .relay_telemetry_settings()
            .map(|s| s.export_enabled)
            .unwrap_or(false)
    }

    /// Toggle anonymous relay telemetry export, preserving the export interval.
    pub fn set_telemetry_enabled(&self, on: bool) -> Result<()> {
        let current = self
            .app
            .relay_telemetry_settings()
            .map_err(|e| anyhow!("relay_telemetry_settings: {e}"))?;
        self.app
            .set_relay_telemetry_settings(RelayTelemetrySettings {
                export_enabled: on,
                export_interval_seconds: current.export_interval_seconds,
            })
            .map_err(|e| anyhow!("set_relay_telemetry_settings: {e}"))?;
        Ok(())
    }

    /// Whether the per-account forensic audit log (JSONL) is enabled.
    pub fn audit_logs_enabled(&self) -> bool {
        self.app
            .audit_log_settings()
            .map(|s| s.enabled)
            .unwrap_or(false)
    }

    /// Enable/disable forensic audit logging. Persists the switch and applies
    /// it to running sessions in place via marmot's recorder hot-swap, so no
    /// restart is needed. The returned future must run on the backend tokio
    /// runtime — applying the switch awaits each account worker's FIFO queue,
    /// which a misbehaving relay can hold for its full connection timeout.
    pub fn set_audit_logs_enabled(
        &self,
        on: bool,
    ) -> impl std::future::Future<Output = Result<()>> + Send + 'static {
        let runtime = self.runtime.clone();
        async move {
            runtime
                .set_audit_log_settings(AuditLogSettings {
                    enabled: on,
                    ..AuditLogSettings::default()
                })
                .await
                .map_err(|e| anyhow!("set_audit_log_settings: {e}"))?;
            Ok(())
        }
    }

    /// On-disk forensic audit-log files (JSONL) across all accounts. Reads
    /// the account directories directly; cheap, but still disk IO — call off
    /// the UI thread.
    pub fn audit_log_files(&self) -> Result<Vec<AuditLogFile>> {
        self.runtime
            .audit_log_files()
            .map_err(|e| anyhow!("audit_log_files: {e}"))
    }

    /// Delete one audit-log file by path. Resolves to `still_recording`:
    /// `true` means a live recorder owned the file and rotated to a fresh one
    /// (recording continues), `false` means the file was simply removed.
    pub fn delete_audit_log_file(
        &self,
        path: String,
    ) -> impl std::future::Future<Output = Result<bool>> + Send + 'static {
        let runtime = self.runtime.clone();
        async move {
            let outcome = runtime
                .delete_audit_log_file(&path)
                .await
                .map_err(|e| anyhow!("delete_audit_log_file: {e}"))?;
            Ok(outcome.still_recording)
        }
    }

    pub fn debug_snapshot(&self) -> String {
        use serde_json::{Value, json};
        let chats = self.chats().unwrap_or_default();
        let archived = self.archived_chats().unwrap_or_default();
        let key_packages = read_key_packages_dir(&self.home);
        let active = self.account();
        let account = json!({
            "label": active.label,
            "account_id_hex": active.account_id_hex,
            "npub": marmot_app::npub_for_account_id(&active.account_id_hex).ok(),
        });
        let group_to_json = |g: &AppGroupRecord| -> Value {
            // MLS internals — the developer/diagnostics view (mirrors the
            // darkmatter-android "MLS" card): live epoch, member count, and
            // required app components from the running engine.
            let mls = match self.group_mls_state(&g.group_id_hex) {
                Ok(s) => json!({
                    "epoch": s.epoch,
                    "member_count": s.member_count,
                    "required_app_components": s.required_app_components,
                }),
                Err(e) => json!({ "error": e.to_string() }),
            };
            json!({
                "group_id_hex": g.group_id_hex,
                "name": g.profile.name,
                "description": g.profile.description,
                "archived": g.archived,
                "pending_confirmation": g.pending_confirmation,
                "welcomer_account_id_hex": g.welcomer_account_id_hex,
                "via_welcome_message_id_hex": g.via_welcome_message_id_hex,
                "nostr_group_id_hex": g.nostr_routing.nostr_group_id_hex,
                "relays": g.nostr_routing.relays,
                "admins": g.admin_policy.admins,
                "mls": mls,
            })
        };
        let dump = json!({
            "home": self.home.display().to_string(),
            "relays": self.relays,
            "account": account,
            "key_packages": key_packages,
            "groups_visible": chats.iter().map(group_to_json).collect::<Vec<_>>(),
            "groups_archived": archived.iter().map(group_to_json).collect::<Vec<_>>(),
        });
        serde_json::to_string_pretty(&dump).unwrap_or_else(|e| format!("serialize error: {e}"))
    }

    /// Developer/debug dump of the raw message events for every visible +
    /// archived group. Each entry is the inner Marmot app event as marmot
    /// projects it — kind, tags, sender, plaintext, timestamps — the closest
    /// thing to the on-the-wire event this client keeps. Capped per group so a
    /// large history can't produce an unbounded string. Reads snapshots only
    /// (no relay round-trip), but still blocking: call from a worker thread.
    pub fn debug_raw_events(&self) -> String {
        use serde_json::json;
        const PER_GROUP_LIMIT: usize = 200;
        let mut groups = self.chats().unwrap_or_default();
        groups.extend(self.archived_chats().unwrap_or_default());
        let dumped: Vec<_> = groups
            .iter()
            .map(|g| {
                let events = self
                    .messages(&g.group_id_hex, Some(PER_GROUP_LIMIT))
                    .unwrap_or_default();
                json!({
                    "group_id_hex": g.group_id_hex,
                    "name": g.profile.name,
                    "archived": g.archived,
                    "event_count": events.len(),
                    "events": events,
                })
            })
            .collect();
        let dump = json!({
            "per_group_limit": PER_GROUP_LIMIT,
            "groups": dumped,
        });
        serde_json::to_string_pretty(&dump).unwrap_or_else(|e| format!("serialize error: {e}"))
    }

    /// Developer/debug view of the active account's key packages: the local
    /// on-disk records plus the raw key-package JSON files next to the account
    /// home. Local-only (no relay round-trip), so it's cheap to call and safe
    /// to show whatever the network state is.
    pub fn debug_key_packages(&self) -> String {
        use serde_json::json;
        let records: Vec<_> = self
            .key_packages_local()
            .iter()
            .map(kp_record_to_json)
            .collect();
        let dump = json!({
            "account_id_hex": self.account().account_id_hex,
            "record_count": records.len(),
            "records": records,
            "on_disk": read_key_packages_dir(&self.home),
        });
        serde_json::to_string_pretty(&dump).unwrap_or_else(|e| format!("serialize error: {e}"))
    }

    /// Developer/debug dump of a single message's raw event — the inner Marmot
    /// app event (kind, tags, sender, plaintext, timestamps) as marmot projects
    /// it. Reads the group's window snapshot and picks the matching record;
    /// blocking, so call from a worker thread.
    pub fn debug_message_event(&self, group_hex: &str, message_id_hex: &str) -> String {
        let record = self
            .messages(group_hex, None)
            .unwrap_or_default()
            .into_iter()
            .find(|m| m.message_id_hex.eq_ignore_ascii_case(message_id_hex));
        match record {
            Some(rec) => serde_json::to_string_pretty(&rec)
                .unwrap_or_else(|e| format!("serialize error: {e}")),
            None => format!("(no message with id {message_id_hex} in this chat's window)"),
        }
    }

    /// Developer/debug view of a *contact's* latest published key package,
    /// fetched from the broad discovery relay set. Dumps the fetch metadata as
    /// pretty JSON — the MLS key-package blob itself is summarized by its ref,
    /// not spelled out. Blocking network call: worker thread only. Accepts npub
    /// or hex.
    pub fn debug_contact_key_packages(&self, account_id: &str) -> String {
        use serde_json::json;
        let account_id_hex = match nostr::PublicKey::parse(account_id) {
            Ok(pk) => pk.to_hex(),
            Err(_) => return format!("not a valid npub or hex pubkey: {account_id}"),
        };
        let broad = self.discovery_relays();
        let app = self.app.clone();
        let query_id = account_id_hex.clone();
        let fetched = self.tokio.block_on(async move {
            app.fetch_latest_key_package_for_account_id(&query_id, broad)
                .await
        });
        match fetched {
            Ok(kp) => {
                let dump = json!({
                    "account_id_hex": kp.account_id_hex,
                    "key_package_id": kp.key_package_id,
                    "key_package_ref_hex": kp.key_package_ref_hex,
                    "key_package_event_id": kp.key_package_event_id,
                    "created_at": kp.created_at,
                    "source_relays": kp.source_relays,
                    "relay_lists": kp.relay_lists,
                    // The decomposed MLS KeyPackage: a readable summary of the
                    // ciphersuite/leaf/capabilities up front, plus the complete
                    // serde structure for anything the summary doesn't name.
                    "key_package": decompose_key_package(&kp.key_package),
                });
                serde_json::to_string_pretty(&dump)
                    .unwrap_or_else(|e| format!("serialize error: {e}"))
            }
            Err(e) => format!("No key package found for {account_id_hex}:\n{e}"),
        }
    }

    /// Pump live chat-list updates for the active account onto the Slint
    /// event loop.
    ///
    /// `on_update` is invoked on a tokio worker; it should re-marshal onto the
    /// Slint main thread via `slint::invoke_from_event_loop`.
    ///
    /// Returns a `JoinHandle` so the caller can `.abort()` the watcher on
    /// account switch — the subscription is bound to the label it was created
    /// with, so a stale watcher would keep pushing the previous account's
    /// chats into the UI.
    pub fn watch_chats<F>(&self, mut on_update: F) -> JoinHandle<()>
    where
        F: FnMut(AppGroupRecord) + Send + 'static,
    {
        let label = self.active_label();
        let runtime = self.runtime.clone();
        self.tokio.spawn(async move {
            let mut sub = match runtime.subscribe_chats(&label, false) {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!(target: "backend", "subscribe_chats failed: {e}");
                    return;
                }
            };
            while let Some(update) = sub.recv().await {
                on_update(update);
            }
        })
    }

    /// Pump live message updates for a single group. `on_update` receives each
    /// live `RuntimeMessageUpdate`; `on_ready` runs once with the subscription
    /// snapshot after subscribe but before the first live update, so the caller
    /// can reconcile that snapshot against its own rows.
    ///
    /// Returns a `JoinHandle` so the caller can `.abort()` the watcher when
    /// the user switches chats (otherwise watchers accumulate forever).
    pub fn watch_messages<F, R>(
        &self,
        group_hex: &str,
        mut on_update: F,
        on_ready: R,
    ) -> JoinHandle<()>
    where
        F: FnMut(RuntimeMessageUpdate) + Send + 'static,
        R: FnOnce(Vec<AppMessageRecord>) + Send + 'static,
    {
        let label = self.active_label();
        let runtime = self.runtime.clone();
        // The subscription snapshot seeds marmot's internal "already seen"
        // dedup set, and we ALSO hand it to `on_ready`: a message arriving
        // between the caller's own snapshot read and this subscribe is seeded
        // here as "seen" (it is the group's latest) yet is absent from the
        // caller's rows, so the live stream below never re-emits it. The
        // reconcile in `on_ready` re-surfaces that one row. `limit: None` would
        // decrypt the group's ENTIRE history on every chat switch; keep it at 1
        // — the reconcile only needs the newest row, and re-emitted old events
        // slip through marmot's dedup but the UI handler is idempotent
        // (find_message_row / refresh_one_message_row), so duplicates are
        // no-ops there.
        let query = AppMessageQuery {
            group_id_hex: Some(group_hex.to_string()),
            limit: Some(1),
        };
        self.tokio.spawn(async move {
            let mut sub: RuntimeMessagesSubscription =
                match runtime.subscribe_messages(&label, query).await {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!(target: "backend", "subscribe_messages failed: {e}");
                        return;
                    }
                };
            // Reconcile against the subscription snapshot before draining live
            // updates, closing the switch-read-vs-subscribe gap.
            on_ready(std::mem::take(&mut sub.snapshot));
            while let Some(update) = sub.recv().await {
                on_update(update);
            }
        })
    }
}

/// Serialize a key-package record for the debug view. `AccountKeyPackageRecord`
/// isn't `Serialize`, so spell the fields out; `key_package_bytes` is a length,
/// never the private key material itself.
pub(crate) fn kp_record_to_json(rec: &marmot_app::AccountKeyPackageRecord) -> serde_json::Value {
    serde_json::json!({
        "account_label": rec.account_label,
        "account_id_hex": rec.account_id_hex,
        "key_package_id": rec.key_package_id,
        "key_package_ref_hex": rec.key_package_ref_hex,
        "key_package_event_id": rec.key_package_event_id,
        "published_at": rec.published_at,
        "key_package_bytes": rec.key_package_bytes,
        "source_relays": rec.source_relays,
        "local": rec.local,
        "relay": rec.relay,
    })
}

/// Decode an opaque transported `KeyPackage` (TLS wire bytes) and decompose it
/// into a debug-friendly JSON value: a curated `summary` (ciphersuite,
/// lifetime, HPKE init key, leaf node + the leaf's advertised capabilities —
/// the "supported stuff") plus `raw`, the complete serde structure of the
/// decoded package. Enum values are rendered via their `Debug` name (e.g.
/// `MLS_128_…`, `Ed25519`), key material as hex.
///
/// Mirrors cgka-engine's `key_package_metadata` decode path
/// (`MlsMessageIn` → `KeyPackageIn` → `validate`), then reads the OpenMLS
/// accessors. On a decode/validate failure we surface the error and the raw
/// bytes rather than dropping everything.
fn decompose_key_package(kp: &cgka_traits::engine::KeyPackage) -> serde_json::Value {
    use openmls::prelude::{
        KeyPackage as MlsKeyPackage, MlsMessageBodyIn, MlsMessageIn, ProtocolVersion,
    };
    use openmls_rust_crypto::RustCrypto;
    use serde_json::json;
    use tls_codec::Deserialize as _;

    let bytes = kp.bytes();
    let decoded: Result<MlsKeyPackage, String> = (|| {
        let msg = MlsMessageIn::tls_deserialize_exact(bytes)
            .map_err(|e| format!("tls_deserialize: {e:?}"))?;
        let kp_in = match msg.extract() {
            MlsMessageBodyIn::KeyPackage(k) => k,
            _ => return Err("MLS message did not carry a KeyPackage".to_string()),
        };
        kp_in
            .validate(&RustCrypto::default(), ProtocolVersion::Mls10)
            .map_err(|e| format!("validate: {e:?}"))
    })();

    let mls = match decoded {
        Ok(m) => m,
        Err(e) => {
            return json!({
                "decode_error": e,
                "wire_bytes": bytes.len(),
                "wire_hex": hex::encode(bytes),
            });
        }
    };

    let names = |v: &mut dyn Iterator<Item = String>| -> Vec<String> { v.collect() };
    let leaf = mls.leaf_node();
    let caps = leaf.capabilities();
    let credential = leaf.credential();
    let summary = json!({
        "ciphersuite": format!("{:?}", mls.ciphersuite()),
        "last_resort": mls.last_resort(),
        "lifetime": {
            "not_before": mls.life_time().not_before(),
            "not_after": mls.life_time().not_after(),
        },
        "hpke_init_key": hex::encode(mls.hpke_init_key().as_slice()),
        "leaf_node": {
            "source": format!("{:?}", leaf.leaf_node_source()),
            "signature_key": hex::encode(leaf.signature_key().as_slice()),
            "credential": {
                "type": format!("{:?}", credential.credential_type()),
                "serialized_content_hex": hex::encode(credential.serialized_content()),
            },
            // The leaf's advertised MLS capabilities — what this client says it
            // supports. Names via Debug so they read as MLS identifiers.
            "capabilities": {
                "versions": names(&mut caps.versions().iter().map(|v| format!("{v:?}"))),
                "ciphersuites": names(&mut caps.ciphersuites().iter().map(|c| format!("{c:?}"))),
                "extensions": names(&mut caps.extensions().iter().map(|e| format!("{e:?}"))),
                "proposals": names(&mut caps.proposals().iter().map(|p| format!("{p:?}"))),
                "credentials": names(&mut caps.credentials().iter().map(|c| format!("{c:?}"))),
            },
        },
    });
    json!({
        "summary": summary,
        "raw": serde_json::to_value(&mls).unwrap_or(serde_json::Value::Null),
    })
}

/// Best-effort dump of the `key-packages/` directory next to the account home.
/// We surface filename + a few well-known fields; private material stays in the
/// blob and is never read out here.
pub(crate) fn read_key_packages_dir(home: &Path) -> Vec<serde_json::Value> {
    use serde_json::{Value, json};
    let dir = home.join("key-packages");
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let val: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(_) => continue,
        };
        out.push(json!({
            "file": path.file_name().and_then(|s| s.to_str()).unwrap_or(""),
            "account_label": val.get("account_label"),
            "account_id_hex": val.get("account_id_hex"),
            "key_package_id": val.get("key_package_id"),
            "key_package_ref_hex": val.get("key_package_ref_hex"),
            "key_package_event_id": val.get("key_package_event_id"),
            "published_at": val.get("published_at"),
        }));
    }
    out
}

pub fn default_home() -> PathBuf {
    if let Some(p) = std::env::var_os("WN_HOME") {
        return PathBuf::from(p);
    }
    directories::ProjectDirs::from("", "", "whitenoise-linux")
        .map(|d| d.data_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("./wn-home"))
}

pub(crate) fn group_id_from_hex(group_hex: &str) -> Result<GroupId> {
    let bytes = hex::decode(group_hex).context("decode group id")?;
    Ok(GroupId::new(bytes))
}

/// Whether an `upload_media` error means the group's encrypted-media policy
/// component is unusable (stale pre-#319 encoding that no longer decodes, or
/// absent/disabled) rather than a transient failure. These are the cases a
/// re-publish of the policy via `replace_encrypted_media_blob_endpoints` can
/// fix; anything else (network, encryption, send) must not trigger a heal.
pub(crate) fn is_stale_encrypted_media_policy(msg: &str) -> bool {
    msg.contains("encrypted media format must be")
        || msg.contains("encrypted media policy has no default endpoint")
        || msg.contains("group does not require encrypted media")
}

const MEDIA_REDIRECT_LIMIT: usize = 5;
const MEDIA_REDIRECT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MEDIA_REDIRECT_READ_TIMEOUT: Duration = Duration::from_secs(15);
const MEDIA_REDIRECT_TOTAL_TIMEOUT: Duration = Duration::from_secs(60);

pub(crate) async fn download_media_with_redirect_retry(
    runtime: MarmotAppRuntime,
    label: String,
    group_id: GroupId,
    reference: MediaAttachmentReference,
) -> Result<MediaDownloadResult> {
    match runtime
        .download_media(&label, &group_id, reference.clone())
        .await
    {
        Ok(download) => Ok(download),
        Err(err) => {
            let msg = err.to_string();
            if !is_media_redirect_error(&msg) {
                return Err(anyhow!("download_media: {err}"));
            }

            tracing::warn!(
                target: "backend::download_media",
                error = %msg,
                "encrypted-media download hit a Blossom redirect; resolving locator and retrying"
            );
            match resolve_media_reference_redirects(reference).await {
                Ok(Some(resolved_reference)) => runtime
                    .download_media(&label, &group_id, resolved_reference)
                    .await
                    .map_err(|retry| {
                        anyhow!("download_media (after redirect resolution): {retry}")
                    }),
                Ok(None) => Err(anyhow!("download_media: {err}")),
                Err(resolve_err) => Err(anyhow!(
                    "download_media: {err}; redirect resolution failed: {resolve_err:#}"
                )),
            }
        }
    }
}

pub(crate) fn is_media_redirect_error(msg: &str) -> bool {
    msg.contains("download returned HTTP")
        && ["HTTP 301", "HTTP 302", "HTTP 303", "HTTP 307", "HTTP 308"]
            .iter()
            .any(|status| msg.contains(status))
}

pub(crate) async fn resolve_media_reference_redirects(
    mut reference: MediaAttachmentReference,
) -> Result<Option<MediaAttachmentReference>> {
    let expected_hash = reference.ciphertext_sha256.to_ascii_lowercase();
    let mut changed = false;
    let mut last_error = None;
    for locator in &mut reference.locators {
        if locator.kind != BLOSSOM_LOCATOR_KIND_V1 {
            continue;
        }
        match resolve_media_locator_redirects(&locator.value, &expected_hash).await {
            Ok(resolved) => {
                if resolved != locator.value {
                    locator.value = resolved;
                    changed = true;
                }
            }
            Err(err) => {
                tracing::warn!(
                    target: "backend::download_media",
                    locator = %locator.value,
                    error = %err,
                    "could not resolve media locator redirect"
                );
                last_error = Some(err);
            }
        }
    }
    if changed {
        Ok(Some(reference))
    } else if let Some(err) = last_error {
        Err(err)
    } else {
        Ok(None)
    }
}

pub(crate) async fn resolve_media_locator_redirects(
    value: &str,
    expected_hash: &str,
) -> Result<String> {
    let mut current = reqwest::Url::parse(value).context("parse media locator URL")?;
    validate_media_fetch_url(&current).map_err(|err| anyhow!("unsafe Blossom URL: {err}"))?;

    for _ in 0..MEDIA_REDIRECT_LIMIT {
        let client = media_redirect_client_for_url(&current).await?;
        let response = client
            .get(current.clone())
            .send()
            .await
            .context("request media locator")?;
        if !response.status().is_redirection() {
            return Ok(current.to_string());
        }

        let location = response
            .headers()
            .get(reqwest::header::LOCATION)
            .ok_or_else(|| anyhow!("redirect response did not include Location"))?
            .to_str()
            .context("redirect Location header is not UTF-8")?;
        let next = current
            .join(location)
            .context("redirect Location header is not a valid URL")?;
        validate_media_fetch_url(&next)
            .map_err(|err| anyhow!("unsafe Blossom redirect URL: {err}"))?;
        if !media_url_contains_hash(&next, expected_hash) {
            return Err(anyhow!(
                "redirect URL does not include the expected encrypted blob hash"
            ));
        }
        current = next;
    }

    Err(anyhow!(
        "media redirect chain exceeded {MEDIA_REDIRECT_LIMIT} hops"
    ))
}

pub(crate) async fn media_redirect_client_for_url(url: &reqwest::Url) -> Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(MEDIA_REDIRECT_CONNECT_TIMEOUT)
        .read_timeout(MEDIA_REDIRECT_READ_TIMEOUT)
        .timeout(MEDIA_REDIRECT_TOTAL_TIMEOUT)
        .no_proxy();
    if let Some((domain, addrs)) = resolve_media_host(url).await? {
        builder = builder.resolve_to_addrs(&domain, &addrs);
    }
    builder.build().context("build media redirect HTTP client")
}

pub(crate) async fn resolve_media_host(
    url: &reqwest::Url,
) -> Result<Option<(String, Vec<SocketAddr>)>> {
    let host = url
        .host_str()
        .ok_or_else(|| anyhow!("Blossom URL is missing a host"))?;
    let allow_loopback = url.scheme() == "http" && cfg!(debug_assertions) && is_loopback_host(host);
    if let Ok(ip) = host.parse::<IpAddr>() {
        reject_non_public_ip(ip, allow_loopback)
            .map_err(|err| anyhow!("unsafe media host address: {err}"))?;
        return Ok(None);
    }

    let port = url
        .port_or_known_default()
        .ok_or_else(|| anyhow!("Blossom URL is missing a fetch port"))?;
    let addrs = tokio::net::lookup_host((host, port))
        .await
        .context("media host DNS lookup failed")?
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(anyhow!("media host DNS lookup returned no addresses"));
    }
    for addr in &addrs {
        reject_non_public_ip(addr.ip(), allow_loopback)
            .map_err(|err| anyhow!("unsafe media host address: {err}"))?;
    }
    Ok(Some((host.to_ascii_lowercase(), addrs)))
}

pub(crate) fn validate_media_fetch_url(url: &reqwest::Url) -> std::result::Result<(), String> {
    if !url.username().is_empty() || url.password().is_some() {
        return Err("URL must not include credentials".into());
    }
    if url.fragment().is_some() {
        return Err("URL must not include a fragment".into());
    }
    let host = url.host_str().ok_or("URL must include a host")?;
    match url.scheme() {
        "https" => validate_public_or_allowed_loopback_host(host, false),
        "http" if cfg!(debug_assertions) && is_loopback_host(host) => Ok(()),
        "http" => Err("URL scheme must be https".into()),
        _ => Err("URL scheme must be https".into()),
    }
}

pub(crate) fn validate_public_or_allowed_loopback_host(
    host: &str,
    allow_loopback: bool,
) -> std::result::Result<(), String> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return reject_non_public_ip(ip, allow_loopback);
    }
    if is_loopback_host(host) {
        if allow_loopback {
            Ok(())
        } else {
            Err("URL must not point at localhost".into())
        }
    } else {
        Ok(())
    }
}

pub(crate) fn is_loopback_host(host: &str) -> bool {
    let lowered = host.to_ascii_lowercase();
    lowered == "localhost"
        || lowered.ends_with(".localhost")
        || host.parse::<IpAddr>().is_ok_and(|addr| match addr {
            IpAddr::V4(addr) => addr.is_loopback(),
            IpAddr::V6(addr) => addr.is_loopback(),
        })
}

pub(crate) fn reject_non_public_ip(
    addr: IpAddr,
    allow_loopback: bool,
) -> std::result::Result<(), String> {
    match addr {
        IpAddr::V4(addr) if allow_loopback && addr.is_loopback() => Ok(()),
        IpAddr::V6(addr) if allow_loopback && addr.is_loopback() => Ok(()),
        IpAddr::V4(addr) if is_public_ipv4(addr) => Ok(()),
        IpAddr::V6(addr) if is_public_ipv6(addr) => Ok(()),
        _ => Err("URL must not point at a non-public address".into()),
    }
}

pub(crate) fn is_public_ipv4(addr: Ipv4Addr) -> bool {
    let [a, b, c, d] = addr.octets();
    !matches!(
        (a, b, c, d),
        (0, _, _, _)
            | (10, _, _, _)
            | (100, 64..=127, _, _)
            | (127, _, _, _)
            | (169, 254, _, _)
            | (172, 16..=31, _, _)
            | (192, 0, 0, _)
            | (192, 0, 2, _)
            | (192, 88, 99, _)
            | (192, 168, _, _)
            | (198, 18..=19, _, _)
            | (198, 51, 100, _)
            | (203, 0, 113, _)
            | (224..=255, _, _, _)
    )
}

pub(crate) fn is_public_ipv6(addr: Ipv6Addr) -> bool {
    if let Some(mapped) = addr.to_ipv4_mapped() {
        return is_public_ipv4(mapped);
    }
    if addr.is_loopback() || addr.is_unspecified() || addr.is_multicast() {
        return false;
    }
    let segments = addr.segments();
    let first = segments[0];
    let second = segments[1];
    if (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80 {
        return false;
    }
    if first == 0x2001 && second == 0x0db8 {
        return false;
    }
    (first & 0xe000) == 0x2000
}

pub(crate) fn media_url_contains_hash(url: &reqwest::Url, expected_hash: &str) -> bool {
    url.path().as_bytes().windows(64).any(|window| {
        std::str::from_utf8(window)
            .ok()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(expected_hash))
    })
}

/// Run an `upload_media` request, transparently self-healing a group whose
/// encrypted-media policy component predates darkmatter #319 (the endpoint
/// byte-layout change). Such components no longer decode under the strict
/// decoder — the policy reads back with an empty `media_format` and the upload
/// fails with "encrypted media format must be encrypted-media-v1". On that
/// class of failure we re-publish the policy with the current encoding (an MLS
/// commit — needs admin rights) and retry the upload once. Best-effort: if the
/// heal or retry fails we surface the original error. Shared by the single-file
/// and album upload paths.
pub(crate) async fn upload_media_with_heal(
    runtime: MarmotAppRuntime,
    label: String,
    group_id: GroupId,
    request: MediaUploadRequest,
) -> Result<MediaUploadResult> {
    match runtime
        .upload_media(&label, &group_id, request.clone())
        .await
    {
        Ok(r) => Ok(r),
        Err(e) => {
            let msg = e.to_string();
            if is_stale_encrypted_media_policy(&msg) {
                tracing::warn!(
                    target: "backend::upload_media",
                    error = %msg,
                    "encrypted-media policy is stale (pre-#319 layout); re-publishing endpoints and retrying"
                );
                let endpoints = vec![AppBlobEndpoint {
                    locator_kind: BLOSSOM_LOCATOR_KIND_V1.to_owned(),
                    base_url: DEFAULT_BLOSSOM_SERVER_URL.to_owned(),
                }];
                match runtime
                    .replace_encrypted_media_blob_endpoints(&label, &group_id, endpoints)
                    .await
                {
                    Ok(_) => runtime
                        .upload_media(&label, &group_id, request)
                        .await
                        .map_err(|e| anyhow!("upload_media (after policy heal): {e}")),
                    Err(heal) => {
                        tracing::warn!(
                            target: "backend::upload_media",
                            error = %heal,
                            "could not re-publish encrypted-media policy (not admin?)"
                        );
                        Err(anyhow!("upload_media: {e}"))
                    }
                }
            } else {
                Err(anyhow!("upload_media: {e}"))
            }
        }
    }
}

fn leave_group_error_hides_chat(err: &anyhow::Error) -> bool {
    format!("{err:#}").contains("UseAfterEviction")
}

pub(crate) fn short_account_id(account_id_hex: &str) -> String {
    if account_id_hex.len() <= 12 {
        return account_id_hex.to_string();
    }
    format!("0x{}…", &account_id_hex[..8])
}

/// Build a placeholder directory record for a followed account whose profile
/// hasn't been resolved yet (no relay sync has populated the cache).
pub(crate) fn stub_directory_entry(account_id_hex: &str) -> UserDirectoryRecord {
    use marmot_app::{AccountRelayListState, AccountRelayListStatus};
    let empty_state = |kind: u64| AccountRelayListState {
        kind,
        relays: Vec::new(),
    };
    UserDirectoryRecord {
        account_id_hex: account_id_hex.to_string(),
        npub: marmot_app::npub_for_account_id(account_id_hex)
            .unwrap_or_else(|_| account_id_hex.to_string()),
        local_account: None,
        profile: None,
        follows: Vec::new(),
        follow_source_relays: Vec::new(),
        relay_lists: AccountRelayListStatus {
            complete: false,
            missing: Vec::new(),
            default_relays: Vec::new(),
            bootstrap_relays: Vec::new(),
            nip65: empty_state(10_002),
            inbox: empty_state(10_050),
        },
        key_package: None,
    }
}

/// Read relay URLs from the user's config dir. No defaults — empty list when
/// the file is missing or malformed, which is the documented behavior.
pub fn load_relays() -> Vec<String> {
    let Some(proj) = directories::ProjectDirs::from("", "", "whitenoise-linux") else {
        return Vec::new();
    };
    let path = proj.config_dir().join("relays.json");
    let Ok(bytes) = std::fs::read(&path) else {
        return Vec::new();
    };
    serde_json::from_slice::<Vec<String>>(&bytes).unwrap_or_default()
}

/// Persist the relay list. Best-effort — surfaces an error string on failure.
pub fn save_relays(relays: &[String]) -> Result<(), String> {
    let proj = directories::ProjectDirs::from("", "", "whitenoise-linux")
        .ok_or_else(|| "no config dir".to_string())?;
    let dir = proj.config_dir();
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let path = dir.join("relays.json");
    let bytes = serde_json::to_vec_pretty(relays).map_err(|e| e.to_string())?;
    std::fs::write(&path, bytes).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn use_after_eviction_leave_error_hides_group() {
        let err =
            anyhow!("leave_group: backend failure: self_remove: GroupStateError(UseAfterEviction)");

        assert!(leave_group_error_hides_chat(&err));
    }

    #[test]
    fn unrelated_leave_error_does_not_hide_group() {
        let err = anyhow!("leave_group: backend failure: relay publish failed");

        assert!(!leave_group_error_hides_chat(&err));
    }
}
