// Per-chat unread tracking — the authoritative read state the rail badges and
// the window/tray total derive from.
//
// `UnreadState` is the runtime mirror of `Settings::last_read`: a map of
// `group_id_hex` → last-read Unix-seconds marker, plus a cache of the current
// unread count per chat. It is `Send`/`Sync` (interior `Mutex`es) because it's
// read from the tokio chat watcher and the chat-list snapshot fetch (off the UI
// thread) and written from chat-open on the UI thread — an `Rc<RefCell<…>>`
// can't cross that boundary, so this owns its own locks, the same shape as
// `notify::NotifState`.
//
// Marker semantics: a message counts as unread when its `recorded_at` is
// strictly greater than the chat's marker AND it's incoming (not ours). Opening
// a chat advances the marker to "now", which clears its unread. A chat with no
// marker yet is seeded to "now" the first time it's observed, so existing
// history never floods the badges on first run; only the persisted markers (set
// when you actually open a chat) survive a restart and surface backlog that
// arrived while the app was closed.

use std::collections::HashMap;
use std::sync::Mutex;

pub struct UnreadState {
    /// group_id_hex → last-read Unix-seconds marker.
    last_read: Mutex<HashMap<String, i64>>,
    /// group_id_hex → current unread count. Only non-zero entries are kept.
    counts: Mutex<HashMap<String, u32>>,
    /// The "New messages" divider anchor: `(group_id_hex, message_id_hex)` of
    /// the first message that was unread when the open chat was opened. Captured
    /// once per open (from the marker before it advances) and held until another
    /// chat is opened, so the divider stays put while you read past it. `None`
    /// when the open chat had no unread history.
    divider_anchor: Mutex<Option<(String, String)>>,
}

impl UnreadState {
    pub fn new(last_read: HashMap<String, i64>) -> Self {
        Self {
            last_read: Mutex::new(last_read),
            counts: Mutex::new(HashMap::new()),
            divider_anchor: Mutex::new(None),
        }
    }

    fn lock_markers(&self) -> std::sync::MutexGuard<'_, HashMap<String, i64>> {
        self.last_read.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn lock_counts(&self) -> std::sync::MutexGuard<'_, HashMap<String, u32>> {
        self.counts.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// The marker for a chat, seeding it (in memory) to `now` if it has none.
    /// Seeding keeps a never-before-seen chat's existing history from counting
    /// as unread.
    pub fn marker_or_seed(&self, group_hex: &str, now: i64) -> i64 {
        *self
            .lock_markers()
            .entry(group_hex.to_string())
            .or_insert(now)
    }

    /// Advance a chat's read marker (e.g. on open or while it's on screen).
    pub fn set_marker(&self, group_hex: &str, ts: i64) {
        self.lock_markers().insert(group_hex.to_string(), ts);
    }

    /// Record a chat's current unread count. Zero clears the entry.
    pub fn set_count(&self, group_hex: &str, n: u32) {
        let mut counts = self.lock_counts();
        if n == 0 {
            counts.remove(group_hex);
        } else {
            counts.insert(group_hex.to_string(), n);
        }
    }

    /// Drop every cached count. Used before a full chat-list recompute so
    /// counts for chats that are no longer visible (archived/blocked) don't
    /// linger in the total.
    pub fn clear_counts(&self) {
        self.lock_counts().clear();
    }

    /// Total unread across all chats — the number shown in the window title and
    /// folded into the rail's chats badge.
    pub fn total(&self) -> u32 {
        self.lock_counts().values().copied().sum()
    }

    fn lock_anchor(&self) -> std::sync::MutexGuard<'_, Option<(String, String)>> {
        self.divider_anchor
            .lock()
            .unwrap_or_else(|p| p.into_inner())
    }

    /// Set (or clear, with `None`) the unread-divider anchor for the chat that
    /// was just opened. Replaces any previous anchor.
    pub fn set_divider_anchor(&self, group_hex: &str, message_id: Option<String>) {
        *self.lock_anchor() = message_id.map(|id| (group_hex.to_string(), id));
    }

    /// The anchored first-unread message id, but only when the anchor belongs to
    /// `group_hex` — so a rebuild of any other chat never draws the divider.
    pub fn divider_anchor_for(&self, group_hex: &str) -> Option<String> {
        self.lock_anchor()
            .as_ref()
            .filter(|(group, _)| group.eq_ignore_ascii_case(group_hex))
            .map(|(_, id)| id.clone())
    }
}

/// Render an unread count for the rail badge: empty when zero, the number up to
/// 99, then `99+`.
pub fn format_unread(n: u32) -> String {
    if n == 0 {
        String::new()
    } else if n > 99 {
        "99+".to_string()
    } else {
        n.to_string()
    }
}
