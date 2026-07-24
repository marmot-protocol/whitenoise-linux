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

use std::collections::{HashMap, HashSet};
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
    /// Chats the user manually flagged unread from the rail context menu,
    /// layered under the marker-derived count (see `record_count`).
    forced_unread: Mutex<HashSet<String>>,
}

impl UnreadState {
    pub fn new(last_read: HashMap<String, i64>) -> Self {
        Self::with_forced_unread(last_read, HashSet::new())
    }

    pub fn with_forced_unread(last_read: HashMap<String, i64>, forced_unread: HashSet<String>) -> Self {
        Self {
            last_read: Mutex::new(last_read),
            counts: Mutex::new(HashMap::new()),
            divider_anchor: Mutex::new(None),
            forced_unread: Mutex::new(forced_unread),
        }
    }

    fn lock_markers(&self) -> std::sync::MutexGuard<'_, HashMap<String, i64>> {
        self.last_read.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn lock_counts(&self) -> std::sync::MutexGuard<'_, HashMap<String, u32>> {
        self.counts.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn lock_forced(&self) -> std::sync::MutexGuard<'_, HashSet<String>> {
        self.forced_unread.lock().unwrap_or_else(|p| p.into_inner())
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

    /// Whether the chat carries the user's manual "mark unread" flag.
    pub fn is_forced_unread(&self, group_hex: &str) -> bool {
        self.lock_forced().contains(group_hex)
    }

    /// Flip the manual "mark unread" flag on or off. Setting it true does not
    /// by itself change the stored count — the next `record_count` (a
    /// recompute) is what floors the badge at 1; setting it false likewise
    /// leaves the count for the next recompute to decide.
    pub fn set_forced_unread(&self, group_hex: &str, flagged: bool) {
        let mut set = self.lock_forced();
        if flagged {
            set.insert(group_hex.to_string());
        } else {
            set.remove(group_hex);
        }
    }

    /// Record a chat's *naturally recomputed* unread count (from
    /// `count_unread`), flooring at 1 when the manual "mark unread" flag is
    /// set and the real count is zero — so a chat with nothing new can still
    /// render as unread. Returns the count actually stored, for callers to
    /// pass straight into `chat_meta_from`.
    pub fn record_count(&self, group_hex: &str, n: u32) -> u32 {
        let effective = if n == 0 && self.is_forced_unread(group_hex) {
            1
        } else {
            n
        };
        self.set_count(group_hex, effective);
        effective
    }

    /// Mark a chat fully read: advances the marker to `ts`, drops the manual
    /// "mark unread" flag, and clears the stored count. Used both by opening
    /// a chat and by the rail context menu's "Mark as read".
    pub fn mark_read(&self, group_hex: &str, ts: i64) {
        self.set_marker(group_hex, ts);
        self.lock_forced().remove(group_hex);
        self.set_count(group_hex, 0);
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
