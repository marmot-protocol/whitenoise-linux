use crate::*;

#[derive(Clone)]
pub(crate) struct PendingSend {
    // Local-only id so retry/failure can find the entry. Carried into the
    // bubble's `message_id` so the retry callback can resolve back here.
    pub(crate) temp_id: String,
    pub(crate) text: String,
    pub(crate) failed: bool,
    // When `Some`, this send is a reply — sent via `reply_to_message` so the
    // event carries `e`+`q` tags. The triple is (parent_id_hex, author_label,
    // preview_text) — same values we render in the chip + quoted block.
    pub(crate) reply_to: Option<(String, String, String)>,
    // Media upload + send. Empty for a plain text send; one entry for a single
    // attachment (chip/image preview); 2+ for an album (rendered as a grid).
    // The optimistic bubble renders straight from the local previews while the
    // encrypt+blossom+publish round-trip resolves.
    pub(crate) media: Vec<PendingMedia>,
    // Armed message effect (Telegram-style burst), 0 = none. Plays once on the
    // optimistic outgoing row; the wire body carries the matching marker so the
    // recipient replays it. Attachment sends leave this 0.
    pub(crate) effect: i32,
}

#[derive(Clone)]
pub(crate) struct PendingMedia {
    pub(crate) file_name: String,
    pub(crate) media_type: String,
    pub(crate) size_bytes: u64,
    pub(crate) is_image: bool,
    pub(crate) is_video: bool,
    pub(crate) is_audio: bool,
    // Local pixels for instant image preview while the upload is in flight.
    // None for non-image attachments.
    pub(crate) local_preview: Option<PicturePixels>,
}

/// One attachment queued in the composer (paperclip picker or clipboard
/// paste) but not yet sent. The bytes stay Rust-side; the UI only gets a
/// `StagedAttachment` chip row built by [`refresh_staged_ui`]. Nothing
/// uploads until the user presses Send — the visible chips *are* the
/// confirmation step.
#[derive(Clone)]
pub(crate) struct StagedFile {
    pub(crate) file_name: String,
    pub(crate) media_type: String,
    pub(crate) bytes: Vec<u8>,
    pub(crate) is_image: bool,
    // Full-resolution decode, reused as the optimistic bubble preview and
    // seeded into the attachment image cache once the upload confirms.
    pub(crate) preview: Option<PicturePixels>,
    // Small (≤96px) decode for the chip thumbnail, so rebuilding the chip
    // model never copies full screenshots around.
    pub(crate) thumb: Option<PicturePixels>,
}

#[derive(Clone)]
pub(crate) enum PendingReactionOp {
    /// I just clicked an emoji on a confirmed message — add a chip with
    /// `mine: true` unless the snapshot already shows my reaction.
    Add(String),
    /// I just unreacted — drop the `mine` flag and count from the tapped emoji
    /// chip while the network catches up.
    Remove(String),
}

#[derive(Default)]
pub(crate) struct PendingState {
    /// group_hex → ordered list of pending outgoing messages. Append-only;
    /// entries are removed (or marked failed) when the send resolves.
    pub(crate) sends: HashMap<String, Vec<PendingSend>>,
    /// (group_hex, target_message_id_hex) → my latest pending reaction op
    /// on that target. Only one op per target at a time (the most recent
    /// click wins).
    pub(crate) reactions: HashMap<(String, String), PendingReactionOp>,
    /// (group_hex, target_message_id_hex) → the replacement text of my
    /// not-yet-confirmed edit of that message. Mirrors `reactions`: a single
    /// in-flight op per target; cleared when the kind-1009 send resolves.
    pub(crate) edits: HashMap<(String, String), String>,
    /// (group_hex, target_message_id_hex) of my not-yet-confirmed "delete for
    /// everyone" retractions. The target renders as a tombstone immediately;
    /// the entry is cleared when the kind-5 send resolves (on ack the snapshot
    /// carries the delete; on failure the row reverts).
    pub(crate) deletes: HashSet<(String, String)>,
}

impl PendingState {
    pub(crate) fn add_send(&mut self, group_hex: &str, send: PendingSend) {
        self.sends
            .entry(group_hex.to_string())
            .or_default()
            .push(send);
    }
    pub(crate) fn drop_send(&mut self, group_hex: &str, temp_id: &str) {
        if let Some(v) = self.sends.get_mut(group_hex) {
            v.retain(|p| p.temp_id != temp_id);
        }
    }
    pub(crate) fn mark_send_failed(&mut self, group_hex: &str, temp_id: &str) {
        if let Some(v) = self.sends.get_mut(group_hex) {
            for p in v.iter_mut() {
                if p.temp_id == temp_id {
                    p.failed = true;
                }
            }
        }
    }
    pub(crate) fn find_send(&self, group_hex: &str, temp_id: &str) -> Option<PendingSend> {
        self.sends
            .get(group_hex)
            .and_then(|v| v.iter().find(|p| p.temp_id == temp_id).cloned())
    }
}

// Marks an id minted by `next_temp_id`. Only `next_temp_id` and `is_temp_id`
// may reference the literal; everything else asks `is_temp_id`.
const TEMP_ID_PREFIX: &str = "pending:";

// Monotonic temp-id source. Survives the lifetime of the process; we only
// need uniqueness within a session.
pub(crate) fn next_temp_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let v = N.fetch_add(1, Ordering::Relaxed);
    format!("{TEMP_ID_PREFIX}{v}")
}

/// True when `id` was minted by [`next_temp_id`] — an optimistic row with no
/// confirmed backend record yet. Also matches callback keys that embed a temp
/// id at the front (the album grid's `message_id#index` keys), so those guards
/// need no extra parsing.
pub(crate) fn is_temp_id(id: &str) -> bool {
    id.starts_with(TEMP_ID_PREFIX)
}

#[cfg(test)]
mod temp_id_tests {
    use super::*;

    #[test]
    fn minted_ids_round_trip_through_is_temp_id() {
        assert!(is_temp_id(&next_temp_id()));
        assert!(is_temp_id(&format!("{}#2", next_temp_id())));
        assert!(!is_temp_id(""));
        assert!(!is_temp_id(
            "5b8e2f0a1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b"
        ));
    }
}

// ─── Delete-for-me (local-only hidden messages) ──────────────────────────────
//
// "Delete for me" never touches the wire — it just hides a message id from this
// client, for the account that hid it. The durable store is
// `Settings.hidden_messages_by_account`; this process-wide map (account hex →
// hidden ids) is the fast in-memory view consulted by `is_visible_chat_message`
// (a free fn with no settings handle). `hidden_account()` names the account
// whose set the renderer currently consults — it follows the active account,
// so a hide on one account never leaks to another on the same machine.
pub(crate) fn hidden_messages() -> &'static Mutex<HashMap<String, HashSet<String>>> {
    static S: OnceLock<Mutex<HashMap<String, HashSet<String>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The account hex whose hidden set the renderer currently consults. Set at
/// boot and on every account switch, before the chat models are rebuilt.
pub(crate) fn hidden_account() -> &'static Mutex<String> {
    static S: OnceLock<Mutex<String>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(String::new()))
}

/// Point the renderer at `account_hex`'s hidden set (called on boot + switch).
pub(crate) fn hidden_set_account(account_hex: &str) {
    if let Ok(mut a) = hidden_account().lock() {
        *a = account_hex.to_ascii_lowercase();
    }
}

/// Seed `account_hex`'s in-memory hidden set from persisted settings (idempotent).
pub(crate) fn hidden_init(account_hex: &str, ids: impl IntoIterator<Item = String>) {
    if let Ok(mut m) = hidden_messages().lock() {
        m.entry(account_hex.to_ascii_lowercase())
            .or_default()
            .extend(ids);
    }
}

/// Mark a message hidden for `account_hex` in the in-memory map. Returns true if
/// it wasn't already hidden (so the caller knows to persist + rebuild).
pub(crate) fn hidden_insert(account_hex: &str, message_id: &str) -> bool {
    hidden_messages()
        .lock()
        .map(|mut m| {
            m.entry(account_hex.to_ascii_lowercase())
                .or_default()
                .insert(message_id.to_string())
        })
        .unwrap_or(false)
}

pub(crate) fn is_hidden_message(message_id: &str) -> bool {
    let account = hidden_account()
        .lock()
        .map(|a| a.clone())
        .unwrap_or_default();
    hidden_messages()
        .lock()
        .map(|m| m.get(&account).is_some_and(|s| s.contains(message_id)))
        .unwrap_or(false)
}

/// Pre-upgrade global hides, stashed at startup (when the boot account isn't
/// known yet) and folded into the boot account's set once it is. `take` drains
/// it so the fold runs once per boot.
pub(crate) fn hidden_legacy_stash() -> &'static Mutex<Vec<String>> {
    static S: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(Vec::new()))
}

pub(crate) fn hidden_stash_legacy(ids: Vec<String>) {
    if let Ok(mut s) = hidden_legacy_stash().lock() {
        *s = ids;
    }
}

pub(crate) fn hidden_take_legacy() -> Vec<String> {
    hidden_legacy_stash()
        .lock()
        .map(|mut s| std::mem::take(&mut *s))
        .unwrap_or_default()
}

// ─── Durable offline send queue ────────────────────────────────────────────
//
// The optimistic overlay above lives only in RAM. These process-wide handles
// add the missing durability + auto-flush-on-reconnect: see `offline_queue.rs`
// for the encrypted on-disk store. The *disk* queue is the source of truth for
// any (re)dispatch — the overlay is just what's rendered.

// (HashSet / OnceLock / atomics are re-exported at the crate root above.)

/// temp_ids whose send is currently in flight (dispatched, not yet resolved).
/// The reconnect flush skips these so a send can't be dispatched twice
/// concurrently. Entries are inserted at dispatch and removed when the op
/// resolves (ack or error), on whichever thread resolves it.
pub(crate) fn offline_inflight() -> &'static Mutex<HashSet<String>> {
    static S: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashSet::new()))
}

pub(crate) fn offline_inflight_insert(temp_id: &str) {
    if let Ok(mut s) = offline_inflight().lock() {
        s.insert(temp_id.to_string());
    }
}

pub(crate) fn offline_inflight_remove(temp_id: &str) {
    if let Ok(mut s) = offline_inflight().lock() {
        s.remove(temp_id);
    }
}

pub(crate) fn offline_inflight_contains(temp_id: &str) -> bool {
    offline_inflight()
        .lock()
        .map(|s| s.contains(temp_id))
        .unwrap_or(false)
}

/// Set by the background connectivity watcher when there's queued work to (re)try
/// — on first boot-ready and on every offline→online relay transition. The UI
/// timer consumes it and calls `flush_now`.
pub(crate) fn offline_flush_requested() -> &'static AtomicBool {
    static B: AtomicBool = AtomicBool::new(false);
    &B
}

/// Last-known connected relay count, published by the watcher thread so the
/// UI-thread flush can decide whether to dispatch (online) or only render the
/// queued bubbles (offline) without itself blocking on `relay_health`.
pub(crate) fn offline_last_connected() -> &'static AtomicUsize {
    static N: AtomicUsize = AtomicUsize::new(0);
    &N
}

/// Seal `send` into the durable queue using the session vault, if it's unlocked.
/// A no-op (best-effort) when the vault handle isn't present.
pub(crate) fn offline_persist(
    vault_cell: &Arc<Mutex<Option<Arc<Mutex<Vault>>>>>,
    send: &offline_queue::QueuedSend,
) {
    if let Some(vault) = vault_cell.lock().ok().and_then(|g| g.clone()) {
        offline_queue::put(&vault, send);
    }
}

/// Boot-only duplicate guard for the narrow kill-after-publish-before-ack
/// window: a queued send whose relay publish actually succeeded but whose
/// durable entry we never got to delete before the process exited. On the next
/// boot we'd otherwise re-send it. Returns true when an outgoing kind-9 from
/// `my_id` whose body matches one of `bodies` already exists near the enqueue
/// time (±10 min). Text-only — attachment bodies have no stable comparison key.
pub(crate) fn looks_already_sent(
    backend: &Backend,
    group_hex: &str,
    my_id: &str,
    bodies: &[String],
    enqueued_at: u64,
) -> bool {
    let Ok(msgs) = backend.messages(group_hex, Some(msg_window_for(group_hex))) else {
        return false;
    };
    msgs.iter().any(|m| {
        m.kind == CHAT_MESSAGE_KIND
            && m.sender.eq_ignore_ascii_case(my_id)
            && bodies.iter().any(|b| &m.plaintext == b)
            && m.recorded_at.abs_diff(enqueued_at) <= 600
    })
}

// ─── Message-window paging ─────────────────────────────────────────────────

/// How many recent records (all kinds — chat, reactions, edits) are loaded
/// per chat by default. The messages view instantiates a full bubble
/// component tree per visible row (the Slint `for` is eager, not
/// virtualized), so this window is the main lever on chat-switch latency.
/// "Load earlier messages" grows it per chat via [`msg_window_expand`].
pub(crate) const MESSAGE_WINDOW: usize = 80;

/// Per-chat message-window overrides (group_id_hex → record limit). Only
/// chats expanded via "Load earlier messages" have an entry; everything else
/// uses [`MESSAGE_WINDOW`]. Process-wide like the picture caches so the many
/// callback closures don't all need another captured handle.
pub(crate) fn msg_windows() -> &'static Mutex<HashMap<String, usize>> {
    use std::sync::OnceLock;
    static MAP: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Current record limit for a chat (default [`MESSAGE_WINDOW`]).
pub(crate) fn msg_window_for(group_hex: &str) -> usize {
    msg_windows()
        .lock()
        .ok()
        .and_then(|m| m.get(group_hex).copied())
        .unwrap_or(MESSAGE_WINDOW)
}

/// Grow a chat's window by one [`MESSAGE_WINDOW`] step; returns the new limit.
pub(crate) fn msg_window_expand(group_hex: &str) -> usize {
    let mut map = match msg_windows().lock() {
        Ok(m) => m,
        Err(_) => return MESSAGE_WINDOW,
    };
    let w = map.entry(group_hex.to_string()).or_insert(MESSAGE_WINDOW);
    *w += MESSAGE_WINDOW;
    *w
}

/// Drop a chat's expanded window (back to the default). Called on chat
/// select so re-entering a chat is always the fast path.
pub(crate) fn msg_window_reset(group_hex: &str) {
    if let Ok(mut m) = msg_windows().lock() {
        m.remove(group_hex);
    }
}

// ─── Voice-message state ───────────────────────────────────────────────────

// The active cpal recorder and the currently-playing rodio audio player are
// !Send, so they live in thread-locals on the Slint UI thread. The timer
// thread only reads the monotonic start instant; it never touches the
// recorder. The monitor thread only touches the rodio Sink (Send + Sync).
thread_local! {
    static ACTIVE_AUDIO_RECORDER: RefCell<Option<audio::AudioRecorder>> = const { RefCell::new(None) };
    static ACTIVE_AUDIO_PLAYER: RefCell<Option<audio::AudioPlayer>> = const { RefCell::new(None) };
}

pub(crate) fn with_active_recorder<R>(f: impl FnOnce(&mut Option<audio::AudioRecorder>) -> R) -> R {
    ACTIVE_AUDIO_RECORDER.with(|r| f(&mut r.borrow_mut()))
}

pub(crate) fn with_active_player<R>(f: impl FnOnce(&mut Option<audio::AudioPlayer>) -> R) -> R {
    ACTIVE_AUDIO_PLAYER.with(|p| f(&mut p.borrow_mut()))
}

/// Start instant of the current recording, shared with the timer thread.
pub(crate) fn recording_start() -> &'static Mutex<Option<std::time::Instant>> {
    use std::sync::OnceLock;
    static S: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// The message id of the currently-playing voice message.
pub(crate) fn current_audio_message_id() -> &'static Mutex<Option<String>> {
    use std::sync::OnceLock;
    static M: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(None))
}

/// Last-known playback progress per message id (0..1). Kept so rows that
/// scroll out and back in show the correct progress without re-querying the
/// player.
pub(crate) fn audio_progress() -> &'static Mutex<HashMap<String, f32>> {
    use std::sync::OnceLock;
    static M: OnceLock<Mutex<HashMap<String, f32>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Duration label per audio message id (e.g. "0:42"), captured the first
/// time the clip is decoded.
pub(crate) fn audio_meta() -> &'static Mutex<HashMap<String, String>> {
    use std::sync::OnceLock;
    static M: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Message ids whose audio attachment downloaded and decrypted fine but failed
/// to decode (unsupported codec or corrupt data). The bubble swaps its size
/// label for a "Can't play this audio format" notice. An entry is cleared when
/// a later play attempt on the same message succeeds.
pub(crate) fn audio_decode_failed() -> &'static Mutex<std::collections::HashSet<String>> {
    use std::sync::OnceLock;
    static SET: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    SET.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

pub(crate) fn rgb(hex: u32) -> Color {
    Color::from_rgb_u8((hex >> 16) as u8, (hex >> 8) as u8, hex as u8)
}

pub(crate) fn s(v: &str) -> SharedString {
    v.into()
}

pub(crate) fn set_clipboard_feedback(
    ui: &DarkMatterLinux,
    message: impl Into<SharedString>,
    is_error: bool,
) {
    ui.set_clipboard_status(message.into());
    ui.set_clipboard_status_error(is_error);
}

/// Persist the composer draft for the currently active chat index.
///
/// Entering edit mode temporarily reuses the composer for the edited message,
/// so the pre-edit draft must be saved before the edit text is loaded. The UI's
/// active-chat index is signed; invalid/stale indexes are ignored.
pub(crate) fn stash_draft_for_chat_index(
    settings: &mut Settings,
    group_ids: &[String],
    active_chat: i32,
    draft: &str,
) -> bool {
    let Ok(idx) = usize::try_from(active_chat) else {
        return false;
    };
    let Some(group_hex) = group_ids.get(idx) else {
        return false;
    };
    settings.set_draft(group_hex, draft)
}

/// Persist the pre-edit composer draft only when entering edit mode.
pub(crate) fn stash_pre_edit_draft_for_chat_index(
    settings: &mut Settings,
    group_ids: &[String],
    active_chat: i32,
    current_editing_message_id: &str,
    draft: &str,
) -> bool {
    if !current_editing_message_id.is_empty() {
        return false;
    }
    stash_draft_for_chat_index(settings, group_ids, active_chat, draft)
}

/// Return the saved composer draft for the currently active chat index.
pub(crate) fn draft_for_chat_index(
    settings: &Settings,
    group_ids: &[String],
    active_chat: i32,
) -> String {
    let Ok(idx) = usize::try_from(active_chat) else {
        return String::new();
    };
    group_ids
        .get(idx)
        .map(|group_hex| settings.draft(group_hex).to_string())
        .unwrap_or_default()
}

/// Gate for setting a brand-new vault password. This password is the only thing
/// protecting every stored secret, and there is no recovery — so we require a
/// minimum length and a matching confirmation.
pub(crate) fn validate_new_password(pw: &str, confirm: &str) -> Result<(), String> {
    if pw.chars().count() < 8 {
        return Err("Password must be at least 8 characters.".to_string());
    }
    if pw != confirm {
        return Err("Passwords don't match.".to_string());
    }
    Ok(())
}

// ─── Localized copy snapshots ────────────────────────────────────────────
//
// `ErrorCopySnapshot` (below) and `TimeCopySnapshot` (`chrome.rs`) mirror
// Slint `@tr()` globals into process-wide cells so worker threads can read
// localized copy without touching Slint property getters (unsound off the UI
// thread). Each snapshot keeps three things in lockstep per string: the
// struct field, the English `Default`, and the getter call in the refresh
// function. `copy_snapshot!` derives all three from one field list, so adding
// a string is one line in the invocation plus the `@tr()` property on the
// Slint global.

/// Per-field helper for [`copy_snapshot!`]: build the English fallback value
/// (a single string literal, or a bracketed list for array fields).
macro_rules! copy_field_default {
    ([$($d:expr),+ $(,)?]) => { [$($d),+].map(String::from) };
    ($d:expr) => { ($d).into() };
}
pub(crate) use copy_field_default;

/// Per-field helper for [`copy_snapshot!`]: read the localized value off the
/// Slint global (a single getter, or a bracketed list for array fields).
macro_rules! copy_field_read {
    ($g:ident, [$($getter:ident),+ $(,)?]) => { [$($g.$getter()),+].map(|s| s.to_string()) };
    ($g:ident, $getter:ident) => { $g.$getter().to_string() };
}
pub(crate) use copy_field_read;

/// Generate a localized-copy snapshot from one field list: the struct, its
/// English `Default`, the process-wide cell, the UI-thread refresh function,
/// and the any-thread reader. Field syntax is
/// `name: String = getter => "English default";` or, for array fields,
/// `name: [String; N] = [getter, …] => ["default", …];`.
macro_rules! copy_snapshot {
    (
        $(#[$smeta:meta])*
        $vis:vis struct $name:ident from $global:ident;
        $(#[$rmeta:meta])*
        refresh fn $refresh:ident, cell fn $cell:ident;
        $(#[$dmeta:meta])*
        read fn $read:ident;
        $(
            $(#[$fmeta:meta])*
            $field:ident : $fty:ty = $getter:tt => $default:tt
        );+ $(;)?
    ) => {
        $(#[$smeta])*
        #[derive(Clone)]
        $vis struct $name {
            $( $(#[$fmeta])* pub(crate) $field: $fty, )+
        }

        impl Default for $name {
            /// English fallback, identical to the `@tr()` source strings. Used
            /// before the first UI-thread snapshot lands (and as a
            /// belt-and-braces default).
            fn default() -> Self {
                Self { $( $field: $crate::copy_field_default!($default), )+ }
            }
        }

        $vis fn $cell() -> &'static ::std::sync::Mutex<$name> {
            static C: ::std::sync::OnceLock<::std::sync::Mutex<$name>> =
                ::std::sync::OnceLock::new();
            C.get_or_init(|| ::std::sync::Mutex::new(<$name>::default()))
        }

        $(#[$rmeta])*
        $vis fn $refresh(ui: &DarkMatterLinux) {
            let g = ui.global::<$global>();
            *$cell().lock().unwrap() = $name {
                $( $field: $crate::copy_field_read!(g, $getter), )+
            };
        }

        $(#[$dmeta])*
        $vis fn $read() -> $name {
            $cell().lock().unwrap().clone()
        }
    };
}
pub(crate) use copy_snapshot;

copy_snapshot! {
    /// Localized snapshot of the user-facing error/status copy.
    ///
    /// The strings themselves are authored as `@tr()` properties on the Slint
    /// `ErrorCopy` global so they flow through the same gettext catalogs as the
    /// rest of the UI (the project keeps *all* i18n in the Slint `@tr` catalogs —
    /// see the `notification_body` note). But `friendly_error` and the relay-pane
    /// status setters run on worker threads, where touching a Slint getter is
    /// unsound. So we snapshot the translated strings on the UI thread (at startup
    /// and on every locale change) into this process-global, and worker threads
    /// read the snapshot instead.
    pub(crate) struct ErrorCopySnapshot from ErrorCopy;
    /// Snapshot the localized `ErrorCopy` strings off the Slint global into the
    /// process-global cache. MUST be called on the UI/event-loop thread (it reads
    /// Slint property getters). Call at startup and after every locale change so
    /// worker-thread error copy follows the active language.
    refresh fn refresh_error_copy, cell fn error_copy_cell;
    /// Read the current localized `ErrorCopy` snapshot. Safe from any thread.
    read fn error_copy;
    invalid_key: String = get_invalid_key => "That doesn't look like a valid npub or public key. Double-check it and try again.";
    network: String = get_network => "Can't reach your relays right now. Check your network and relay settings, then try again.";
    sync: String = get_sync => "Couldn't finish syncing. We'll keep retrying — check your relay settings if this keeps happening.";
    backend: String = get_backend => "Couldn't start up. Check your network and relay settings, then try again.";
    switch_account: String = get_switch_account => "Couldn't switch accounts. Please try again in a moment.";
    accept: String = get_accept => "Couldn't accept the invitation. Please try again in a moment.";
    block: String = get_block => "Couldn't decline the invitation. Please try again in a moment.";
    archive: String = get_archive => "Couldn't archive this chat. Please try again.";
    unarchive: String = get_unarchive => "Couldn't restore this chat. Please try again.";
    send: String = get_send => "Couldn't send your message. Check your connection and try again.";
    edit: String = get_edit => "Couldn't save your edit. Check your connection and try again.";
    react: String = get_react => "Couldn't add your reaction. Please try again.";
    unreact: String = get_unreact => "Couldn't remove your reaction. Please try again.";
    kp_publish: String = get_kp_publish => "Couldn't publish your key package. Check your relay settings and try again.";
    kp_rotate: String = get_kp_rotate => "Couldn't rotate your key package. Check your relay settings and try again.";
    kp_refresh: String = get_kp_refresh => "Couldn't refresh your key packages. Check your relay settings and try again.";
    republish: String = get_republish => "Couldn't republish to your relays. Check your relay settings and try again.";
    add_account: String = get_add_account => "Couldn't add that account. Please check the key and try again.";
    create_chat: String = get_create_chat => "Couldn't create the chat. Please try again.";
    add_contact: String = get_add_contact => "Couldn't add that contact. Please try again.";
    add_member: String = get_add_member => "Couldn't add that member. Please try again.";
    group_settings: String = get_group_settings => "Couldn't update the group settings. Please try again.";
    group_image: String = get_group_image => "Couldn't update the group image. Please try again.";
    save_profile: String = get_save_profile => "Couldn't save your profile. Check your connection and try again.";
    upload_picture: String = get_upload_picture => "Couldn't upload your picture. Please try again.";
    generic: String = get_generic => "Something went wrong. Please try again.";
    not_connected: String = get_not_connected => "Not connected yet. Please wait a moment and try again.";
    relay_already_listed: String = get_relay_already_listed => "That relay is already in your list.";
    relay_url_empty: String = get_relay_url_empty => "Enter a relay address.";
    relay_url_scheme: String = get_relay_url_scheme => "A relay address starts with wss:// — for example wss://relay.example.com.";
    relay_url_no_host: String = get_relay_url_no_host => "Add the relay's address after wss://.";
    relay_url_invalid: String = get_relay_url_invalid => "That doesn't look like a valid relay address.";
    save_relays_failed: String = get_save_relays_failed => "Couldn't save your relay list. Please try again.";
    relay_added: String = get_relay_added => "Relay added.";
    relay_removed: String = get_relay_removed => "Relay removed.";
    republishing: String = get_republishing => "Republishing…";
}

/// The operation behind a [`friendly_error`] call. Each variant selects the
/// operation-specific fallback message from [`ErrorCopySnapshot`]; because the
/// match in `friendly_error` is exhaustive, adding a variant forces a copy
/// decision at compile time, and a call site can no longer misspell a string
/// key and silently fall through to the generic message.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum ErrorOp {
    Sync,
    Backend,
    SwitchAccount,
    Accept,
    Block,
    Archive,
    Unarchive,
    Send,
    Edit,
    React,
    Unreact,
    KpPublish,
    KpRotate,
    KpRefresh,
    Republish,
    AddAccount,
    CreateChat,
    AddContact,
    AddMember,
    GroupSettings,
    GroupImage,
    SaveProfile,
    UploadPicture,
    /// No dedicated copy yet — maps to the generic message.
    Delete,
    /// No dedicated copy yet — maps to the generic message.
    Forward,
}

/// Map a low-level backend error into approachable, action-oriented UI copy.
///
/// User-facing error surfaces must never show raw `anyhow` context strings,
/// Rust debug formatting, or internal module/concept names. The full technical
/// error is still logged at every call site (`tracing::warn!(target: "op", "{e:#}")`) and
/// stays available for diagnosis — this governs only what the *user* reads.
///
/// Classification is two-tier: first we inspect the flattened error chain for
/// signals that point at a specific, fixable user action (a malformed key, an
/// unreachable relay); failing that we fall back to a reassuring, operation-
/// specific message selected by `op`.
///
/// The returned text is localized: it comes from the `ErrorCopy` snapshot which
/// mirrors the Slint `@tr()` catalogs for the active locale.
pub(crate) fn friendly_error(op: ErrorOp, e: &anyhow::Error) -> String {
    let copy = error_copy();
    // Flatten the whole error chain once for case-insensitive keyword matching.
    let detail = format!("{e:#}").to_lowercase();

    // Tier 1 — content-based classification. These conditions name a concrete
    // thing the user can fix, so they take priority over the op default.
    if detail.contains("npub") || detail.contains("pubkey") || detail.contains("public key") {
        return copy.invalid_key;
    }
    if detail.contains("timed out")
        || detail.contains("timeout")
        || detail.contains("connection")
        || detail.contains("connect")
        || detail.contains("network")
        || detail.contains("relay")
        || detail.contains("offline")
        || detail.contains("unreachable")
        || detail.contains("dns")
    {
        return copy.network;
    }

    // Tier 2 — operation-specific fallback. Reassuring, names no internals.
    // Exhaustive on purpose: a new `ErrorOp` variant must pick its copy here.
    match op {
        ErrorOp::Sync => copy.sync,
        ErrorOp::Backend => copy.backend,
        ErrorOp::SwitchAccount => copy.switch_account,
        ErrorOp::Accept => copy.accept,
        ErrorOp::Block => copy.block,
        ErrorOp::Archive => copy.archive,
        ErrorOp::Unarchive => copy.unarchive,
        ErrorOp::Send => copy.send,
        ErrorOp::Edit => copy.edit,
        ErrorOp::React => copy.react,
        ErrorOp::Unreact => copy.unreact,
        ErrorOp::KpPublish => copy.kp_publish,
        ErrorOp::KpRotate => copy.kp_rotate,
        ErrorOp::KpRefresh => copy.kp_refresh,
        ErrorOp::Republish => copy.republish,
        ErrorOp::AddAccount => copy.add_account,
        ErrorOp::CreateChat => copy.create_chat,
        ErrorOp::AddContact => copy.add_contact,
        ErrorOp::AddMember => copy.add_member,
        ErrorOp::GroupSettings => copy.group_settings,
        ErrorOp::GroupImage => copy.group_image,
        ErrorOp::SaveProfile => copy.save_profile,
        ErrorOp::UploadPicture => copy.upload_picture,
        ErrorOp::Delete | ErrorOp::Forward => copy.generic,
    }
}

pub(crate) fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    ModelRc::new(VecModel::from(v))
}

/// Recompute the breadcrumb from the UI's own models. Same effect as the
/// `refresh_breadcrumb` closure in `main`, but callable from `Send` completion
/// closures that can't capture the model handles.
pub(crate) fn refresh_breadcrumb_now(ui: &DarkMatterLinux) {
    ui.set_breadcrumb(breadcrumb(
        ui.get_active_page(),
        &ui.get_chats(),
        &ui.get_contacts(),
        &ui.get_archived_chats(),
        ui.get_active_chat(),
        ui.get_active_contact(),
        ui.get_active_archived(),
    ));
}

pub(crate) fn breadcrumb(
    page: i32,
    chats: &ModelRc<ChatMeta>,
    contacts: &ModelRc<Contact>,
    archived: &ModelRc<ArchivedChat>,
    active_chat: i32,
    active_contact: i32,
    active_archived: i32,
) -> SharedString {
    let label = match page {
        0 => chats
            .row_data(active_chat as usize)
            .map(|c| c.name.to_string())
            .unwrap_or_default(),
        1 => contacts
            .row_data(active_contact as usize)
            .map(|c| c.name.to_string())
            .unwrap_or_default(),
        2 => archived
            .row_data(active_archived as usize)
            .map(|c| c.name.to_string())
            .unwrap_or_default(),
        3 => "Keys".into(),
        4 => "Settings".into(),
        _ => "Profile".into(),
    };
    label.to_uppercase().into()
}

// Pages the UI can show. Cast to i32 for Slint's `active-page` property.
#[repr(i32)]
#[derive(Copy, Clone)]
pub(crate) enum Page {
    Chats = 0,
    Contacts = 1,
    Archived = 2,
    Keys = 3,
    Settings = 4,
    Profile = 5,
}

macro_rules! palette_commands {
    ($($variant:ident => ($id:literal, $label:literal, $group:literal, $kbd:literal)),+ $(,)?) => {
        #[derive(Copy, Clone, Debug, Eq, PartialEq)]
        pub(crate) enum PaletteCommand {
            $($variant,)+
        }

        impl PaletteCommand {
            pub(crate) const ALL: [Self; palette_commands!(@count $($variant),+)] = [
                $(Self::$variant,)+
            ];

            pub(crate) fn from_id(id: &str) -> Option<Self> {
                Self::ALL.iter().copied().find(|command| command.id() == id)
            }

            fn id(self) -> &'static str {
                match self {
                    $(Self::$variant => $id,)+
                }
            }

            fn label(self) -> &'static str {
                match self {
                    $(Self::$variant => $label,)+
                }
            }

            fn group(self) -> &'static str {
                match self {
                    $(Self::$variant => $group,)+
                }
            }

            fn kbd(self) -> &'static str {
                match self {
                    $(Self::$variant => $kbd,)+
                }
            }

            fn action(self) -> PaletteAction {
                PaletteAction {
                    id: s(self.id()),
                    label: s(self.label()),
                    group: s(self.group()),
                    kbd: s(self.kbd()),
                }
            }
        }
    };
    (@count $($variant:ident),+ $(,)?) => {
        <[()]>::len(&[$(palette_commands!(@unit $variant)),+])
    };
    (@unit $variant:ident) => { () };
}

palette_commands! {
    NavChats => ("nav.chats", "Go to Chats", "NAVIGATE", "1"),
    NavContacts => ("nav.contacts", "Go to Contacts", "NAVIGATE", "2"),
    NavArchived => ("nav.archived", "Go to Archived", "NAVIGATE", "3"),
    NavKeys => ("nav.keys", "Go to Keys", "NAVIGATE", "4"),
    NavSettings => ("nav.settings", "Go to Settings", "NAVIGATE", "5"),
    NavProfile => ("nav.profile", "Go to Profile", "NAVIGATE", ""),
    NewChat => ("act.new-chat", "New chat", "ACTIONS", "Ctrl N"),
    CopyNpub => ("act.copy-npub", "Copy your npub", "ACTIONS", ""),
    ToggleRetro => ("act.toggle-retro", "Toggle retro mode", "ACTIONS", ""),
}

// Master list of palette actions. The single `palette_commands!` table declares
// the variants and row metadata together; the executor matches the generated
// enum exhaustively, so adding a row without a handler becomes a compiler error
// instead of a silent no-op.
pub(crate) fn all_palette_actions() -> Vec<PaletteAction> {
    PaletteCommand::ALL
        .into_iter()
        .map(PaletteCommand::action)
        .collect()
}

pub(crate) fn filter_palette(all: &[PaletteAction], query: &str) -> Vec<PaletteAction> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return all.to_vec();
    }
    all.iter()
        .filter(|a| a.label.to_lowercase().contains(&q) || a.id.to_lowercase().contains(&q))
        .cloned()
        .collect()
}

pub(crate) fn normalize_locale(code: &str) -> &'static str {
    let base = code
        .split('.')
        .next()
        .unwrap_or(code)
        .split('_')
        .next()
        .unwrap_or(code);
    match base {
        "it" => "it",
        "de" => "de",
        "ja" => "ja",
        _ => "en",
    }
}

/// The one theme-mode registry: each non-default mode's name paired with the
/// root flag setter that turns it on. `normalize_theme_mode` and
/// `apply_theme_mode` both derive from this list, so adding a theme mode is
/// one new row here (plus the Slint side).
type ThemeFlagSetter = fn(&DarkMatterLinux, bool);
const THEME_MODE_FLAGS: [(&str, ThemeFlagSetter); 6] = [
    ("light", DarkMatterLinux::set_light_theme),
    ("retro", DarkMatterLinux::set_retro_mode),
    ("terminal", DarkMatterLinux::set_terminal_mode),
    ("crayon", DarkMatterLinux::set_crayon_mode),
    ("synthwave", DarkMatterLinux::set_synthwave_mode),
    ("chalkboard", DarkMatterLinux::set_chalkboard_mode),
];

pub(crate) fn normalize_theme_mode(mode: &str) -> &'static str {
    THEME_MODE_FLAGS
        .iter()
        .map(|(name, _)| *name)
        .find(|name| *name == mode)
        .unwrap_or("dark")
}

/// The one accent registry: position i names column i of every `accent-*`
/// lookup array in the `ui/tokens.slint` theme packs (`Theme.accent` indexes
/// them). `normalize_accent_color`, `accent_color_idx`, and
/// `accent_color_name` all derive from this table; keep its order in sync
/// with the Slint arrays.
pub(crate) const ACCENTS: [&str; 5] = ["mint", "ocean", "berry", "coral", "lavender"];

pub(crate) fn normalize_accent_color(color: &str) -> &'static str {
    ACCENTS
        .iter()
        .copied()
        .find(|name| *name == color)
        .unwrap_or(ACCENTS[0])
}

pub(crate) fn accent_color_idx(color: &str) -> i32 {
    ACCENTS.iter().position(|name| *name == color).unwrap_or(0) as i32
}

pub(crate) fn accent_color_name(idx: i32) -> &'static str {
    usize::try_from(idx)
        .ok()
        .and_then(|i| ACCENTS.get(i))
        .copied()
        .unwrap_or(ACCENTS[0])
}

/// Every Rust-side accent push goes through here so an index the Slint
/// accent arrays cannot resolve fails loudly in dev builds instead of
/// silently painting the wrong swatch.
pub(crate) fn set_accent_index(ui: &DarkMatterLinux, idx: i32) {
    debug_assert!(
        (0..ACCENTS.len() as i32).contains(&idx),
        "accent index {idx} outside the ACCENTS table (len {})",
        ACCENTS.len()
    );
    ui.set_accent_color(idx);
}

pub(crate) fn apply_theme_mode(ui: &DarkMatterLinux, mode: &str) {
    let mode = normalize_theme_mode(mode);
    for (name, set_flag) in THEME_MODE_FLAGS {
        set_flag(ui, mode == name);
    }
}

pub(crate) fn locale_display(code: &str) -> &'static str {
    match normalize_locale(code) {
        "it" => "Italiano",
        "de" => "Deutsch",
        "ja" => "日本語",
        _ => "English",
    }
}

pub(crate) fn apply_locale(locale: &str) {
    let code = normalize_locale(locale);
    if let Err(e) = slint::select_bundled_translation(code) {
        tracing::warn!(target: "i18n", "select_bundled_translation({code}): {e}");
        let _ = slint::select_bundled_translation("en");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_actions_round_trip_through_command_registry() {
        let expected = [
            ("nav.chats", "Go to Chats", "NAVIGATE", "1"),
            ("nav.contacts", "Go to Contacts", "NAVIGATE", "2"),
            ("nav.archived", "Go to Archived", "NAVIGATE", "3"),
            ("nav.keys", "Go to Keys", "NAVIGATE", "4"),
            ("nav.settings", "Go to Settings", "NAVIGATE", "5"),
            ("nav.profile", "Go to Profile", "NAVIGATE", ""),
            ("act.new-chat", "New chat", "ACTIONS", "Ctrl N"),
            ("act.copy-npub", "Copy your npub", "ACTIONS", ""),
            ("act.toggle-retro", "Toggle retro mode", "ACTIONS", ""),
        ];
        let actions = all_palette_actions();
        assert_eq!(actions.len(), expected.len());
        assert_eq!(PaletteCommand::ALL.len(), expected.len());

        let mut ids = HashSet::new();
        for ((action, command), (id, label, group, kbd)) in
            actions.iter().zip(PaletteCommand::ALL).zip(expected)
        {
            assert_eq!(action.id.as_str(), id);
            assert_eq!(action.label.as_str(), label);
            assert_eq!(action.group.as_str(), group);
            assert_eq!(action.kbd.as_str(), kbd);
            assert_eq!(command.id(), id);
            assert!(
                ids.insert(action.id.to_string()),
                "duplicate palette action id {id}"
            );
            assert_eq!(PaletteCommand::from_id(id), Some(command));
        }
        assert_eq!(PaletteCommand::from_id("missing.action"), None);
    }

    #[test]
    fn edit_draft_stash_does_not_overwrite_when_already_editing() {
        let mut settings = Settings::default();
        let group_ids = vec!["chat-a".to_string()];

        assert!(stash_pre_edit_draft_for_chat_index(
            &mut settings,
            &group_ids,
            0,
            "",
            "draft before edit"
        ));

        assert!(!stash_pre_edit_draft_for_chat_index(
            &mut settings,
            &group_ids,
            0,
            "message-being-edited",
            "first edit body"
        ));

        assert_eq!(
            draft_for_chat_index(&settings, &group_ids, 0),
            "draft before edit"
        );
    }
}
