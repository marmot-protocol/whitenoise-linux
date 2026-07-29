// App-level settings persisted as a tiny JSON file in XDG_CONFIG_HOME.
// Stores UI prefs such as locale, theme, accent color, and debug toggle.
// Failures (read, parse, write) are swallowed — defaults keep the app
// booting even if the config file is corrupt or missing.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub debug_enabled: bool,
    /// BCP-47 language tag without region, e.g. `en`, `it`, `de`, `ja`.
    #[serde(default = "default_locale")]
    pub locale: String,
    /// Stable theme mode name — one of `THEME_MODES` in `state.rs` (`dark`,
    /// `light`, `retro`, `terminal`, `crayon`, `synthwave`, `chalkboard`,
    /// `amoled`). Its index in that table is the `Theme.id` the UI selects.
    #[serde(default = "default_theme")]
    pub theme: String,
    /// Accent color name. One of `mint`, `ocean`, `berry`, `coral`, `lavender`.
    #[serde(default = "default_accent")]
    pub accent_color: String,
    #[serde(default = "default_outgoing_on_right")]
    pub outgoing_on_right: bool,
    /// UI zoom level (Ctrl +/-/0): multiplies the window scale factor so the
    /// whole UI scales like browser zoom. Clamped to [0.5, 3.0]; 1.0 is 100%.
    #[serde(default = "default_zoom")]
    pub zoom: f32,
    /// Clock style for all visible timestamps. One of `24h`, `12h`.
    #[serde(default = "default_time_format")]
    pub time_format: String,
    /// Date style for all visible stamps. One of `mdy` ("Jun 12"),
    /// `dmy` ("12 Jun"), `iso` ("2026-06-12").
    #[serde(default = "default_date_format")]
    pub date_format: String,
    /// Private per-contact nicknames, keyed by the contact's account id (hex).
    /// Local-only — never published to relays.
    #[serde(default)]
    pub nicknames: BTreeMap<String, String>,
    /// The emoji shown in the one-tap quick-reaction row on the message hover
    /// toolbar and the right-click menu; a trailing "+" always opens the full
    /// picker. Ordered as the user arranged them, editable in Settings. Local-
    /// only, like nicknames — never published to relays.
    #[serde(default = "default_quick_reactions")]
    pub quick_reactions: Vec<String>,
    /// The emoji the user has picked from the full emoji picker most recently,
    /// newest first, capped at `RECENT_EMOJI_MAX`. Feeds the picker's own
    /// recent-emoji row (see `record_recent_emoji`). Local-only, like
    /// `quick_reactions` — never published to relays.
    #[serde(default)]
    pub recent_emoji: Vec<String>,
    /// Group ids (`group_id_hex`) the user has recently forwarded a message
    /// to, newest first, capped at `RECENT_FORWARD_MAX`. Feeds the forward
    /// picker's row order (see `record_recent_forward`). Local-only, like
    /// `recent_emoji` — never published to relays.
    #[serde(default)]
    pub recent_forwards: Vec<String>,
    /// Fire a desktop notification for incoming messages in chats you aren't
    /// currently viewing. Master switch for the two below.
    #[serde(default = "default_true")]
    pub notifications_enabled: bool,
    /// Ask the notification server to play its message sound.
    #[serde(default = "default_true")]
    pub notification_sound: bool,
    /// Include the message text in the notification body (off = "New message").
    #[serde(default = "default_true")]
    pub notification_preview: bool,
    /// Register a freedesktop autostart entry so the app launches at login.
    #[serde(default)]
    pub launch_at_login: bool,
    /// Start with the window hidden and a tray icon visible; the tray can reopen
    /// the main window. Applied on next launch.
    #[serde(default)]
    pub start_minimized_to_tray: bool,
    /// Reopen the last selected chat instead of the first real chat at boot.
    #[serde(default)]
    pub restore_last_selected_chat: bool,
    /// Last selected visible chat group id (hex). Local-only.
    #[serde(default)]
    pub last_selected_chat: Option<String>,
    /// Chats (group_id_hex) the user has muted — suppresses their desktop
    /// notifications. Local-only, like nicknames.
    #[serde(default)]
    pub muted_chats: BTreeSet<String>,
    /// Chats (group_id_hex) the user has pinned to the top of the rail. Kept
    /// above the time-sorted list, in the order they were pinned. Local-only,
    /// like nicknames — never published to relays.
    #[serde(default)]
    pub pinned_chats: BTreeSet<String>,
    /// Accounts (account_id_hex) the user has blocked. Their 1:1 chat — and any
    /// chat request they send — is filtered out of the visible chat list, which
    /// also takes their notifications and unread counts with it. Local-only,
    /// like `muted_chats`: nothing is published to relays and nothing is
    /// deleted, so unblocking restores the conversation intact.
    #[serde(default)]
    pub blocked_accounts: BTreeSet<String>,
    /// External-link hosts the user explicitly chose to open without another
    /// confirmation. Exact, lower-case host matches only; local-only.
    #[serde(default)]
    pub trusted_link_hosts: BTreeSet<String>,
    /// Per-chat read marker: `group_id_hex` → the Unix-seconds timestamp the
    /// user last viewed that chat. Messages recorded after the marker count as
    /// unread. Written when a chat is opened; the authoritative read state the
    /// rail/tray unread counts derive from. Local-only, like nicknames.
    #[serde(default)]
    pub last_read: BTreeMap<String, i64>,
    /// Unsent composer text ("drafts"), keyed by `group_id_hex`. Written when
    /// the user switches away from (or quits with) a half-written message, and
    /// restored when the chat is reopened. Local-only, like nicknames — never
    /// published to relays.
    #[serde(default)]
    pub composer_drafts: BTreeMap<String, String>,
    /// Per-chat scroll offset (viewport-y in px), keyed by `group_id_hex`.
    /// Mirrors the in-memory `msg_scroll_positions` cache in `state.rs`:
    /// written when the user switches away from (or quits with) a chat
    /// scrolled away from the bottom, and used to seed that cache at boot so
    /// a chat left mid-history reopens there after a restart instead of at
    /// the bottom. Local-only, like nicknames — never published to relays.
    #[serde(default)]
    pub scroll_positions: BTreeMap<String, f32>,
    /// Messages the user deleted *for themselves* ("delete for me"), keyed by
    /// the local account hex that hid them → the set of inner event ids (hex).
    /// Local-only — never published; the message stays on the wire for everyone
    /// else, it's just filtered out of this client's view. Per-account so a hide
    /// on one account doesn't leak to another account on the same machine.
    #[serde(default)]
    pub hidden_messages_by_account: BTreeMap<String, BTreeSet<String>>,
    /// Legacy global hidden set (pre per-account scoping). The old `hidden_messages`
    /// key deserializes here; at boot it's folded into the boot account's
    /// in-memory hidden set so pre-upgrade "delete for me" hides survive. Kept in
    /// the file (not account-attributed on disk) since it predates account scoping.
    #[serde(default, rename = "hidden_messages")]
    pub hidden_messages_legacy: BTreeSet<String>,
    /// Chat-shell layout: the user-chosen widths (logical px) of the left
    /// chat-bar column and the right info column, remembered across restarts as
    /// the bento columns are dragged. Local-only UI prefs.
    #[serde(default = "default_shell_chats_width")]
    pub shell_chats_width: f32,
    #[serde(default = "default_shell_info_width")]
    pub shell_info_width: f32,
    /// Chat-shell: constrain the open conversation to a centred reading measure
    /// instead of filling the column. Opt-in, off by default (Appearance).
    #[serde(default)]
    pub centered_conversation: bool,
    /// Where the last "Back up everything" write landed, and when (Unix
    /// seconds). The success toast scrolls away within seconds, so this is what
    /// lets the Storage pane keep showing that a backup exists and where it
    /// went. Both stay `None` until a backup succeeds, which is what keeps the
    /// pane's "Last backup" row unmounted on a fresh install. Local-only, like
    /// nicknames — the path never leaves this machine.
    #[serde(default)]
    pub last_backup_path: Option<String>,
    #[serde(default)]
    pub last_backup_at: Option<i64>,
    /// Chats (group_id_hex) the user manually marked unread from the rail
    /// context menu, independent of `last_read` — the badge floors at 1 while
    /// a chat is in this set, even though `count_unread` sees nothing new.
    /// Cleared the moment the chat is genuinely read (opened, or read while
    /// already on screen). Local-only, like `muted_chats`.
    #[serde(default)]
    pub manually_unread: BTreeSet<String>,
    /// Window geometry (physical pixels), remembered across launches so the
    /// window reopens at the size and position the user left it at. `None`
    /// until the window is closed once; a fresh install falls back to the
    /// `.slint` root's `preferred-width`/`preferred-height` and whatever
    /// position the windowing system picks. `window_x`/`window_y` are best
    /// effort — Wayland compositors generally ignore a requested position.
    #[serde(default)]
    pub window_width: Option<u32>,
    #[serde(default)]
    pub window_height: Option<u32>,
    #[serde(default)]
    pub window_x: Option<i32>,
    #[serde(default)]
    pub window_y: Option<i32>,
    /// User-defined organizing label per chat, keyed by `group_id_hex`. A chat
    /// with no entry is unlabeled. Local-only, like nicknames — never
    /// published to relays. Drives both the rail's filter row (distinct
    /// values) and each row's own label.
    #[serde(default)]
    pub chat_labels: BTreeMap<String, String>,
    /// User-uploaded custom emoji, shown in the emoji picker alongside the
    /// built-in Twemoji set (see AGENTS.md's "Build-time sprite sheet"
    /// section for why custom entries can't join that build-time sheet).
    /// Local-only, like `quick_reactions` — never published to relays, so
    /// only this account sees its own custom emoji in the picker.
    #[serde(default)]
    pub custom_emoji: Vec<CustomEmoji>,
}

/// One user-uploaded custom emoji: a short name plus the public Blossom URL
/// the image was uploaded to (same upload path as profile pictures, see
/// `src/blossom.rs`). Picking it inserts `:shortcode:` into the composer or
/// reaction, matching how NIP-30 custom emoji are named.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CustomEmoji {
    pub shortcode: String,
    pub url: String,
}

impl Settings {
    /// Remember an external-link host, normalized for DNS case-insensitivity.
    /// Returns true when the trusted-host set changed.
    pub fn trust_link_host(&mut self, host: &str) -> bool {
        let host = host.trim().to_ascii_lowercase();
        !host.is_empty() && self.trusted_link_hosts.insert(host)
    }

    pub fn is_link_host_trusted(&self, host: &str) -> bool {
        self.trusted_link_hosts
            .contains(&host.trim().to_ascii_lowercase())
    }

    /// Forget an external-link host. Returns true when the set changed.
    pub fn forget_link_host(&mut self, host: &str) -> bool {
        self.trusted_link_hosts
            .remove(&host.trim().to_ascii_lowercase())
    }

    /// Hide `message_id` for `account_hex`. Returns true if it wasn't already
    /// hidden (so the caller knows to persist).
    pub fn hide_message(&mut self, account_hex: &str, message_id: &str) -> bool {
        self.hidden_messages_by_account
            .entry(account_hex.to_ascii_lowercase())
            .or_default()
            .insert(message_id.to_string())
    }

    /// Store (or clear) the unsent draft for `group_hex`. Whitespace-only text
    /// drops the entry so an emptied composer leaves nothing behind. Returns
    /// true when the stored value actually changed, so callers only `save()`
    /// (a disk write) when there's something new to persist.
    pub fn set_draft(&mut self, group_hex: &str, text: &str) -> bool {
        if text.trim().is_empty() {
            self.composer_drafts.remove(group_hex).is_some()
        } else {
            self.composer_drafts
                .insert(group_hex.to_string(), text.to_string())
                .as_deref()
                != Some(text)
        }
    }

    /// The saved draft for `group_hex`, or `""` if none.
    pub fn draft(&self, group_hex: &str) -> &str {
        self.composer_drafts
            .get(group_hex)
            .map(String::as_str)
            .unwrap_or_default()
    }

    /// Store (or clear) the saved scroll offset for `group_hex`. `None`
    /// clears the entry (chat left at the bottom). Returns true when the
    /// stored value actually changed, so callers only `save()` when there's
    /// something new to persist.
    pub fn set_scroll_position(&mut self, group_hex: &str, y: Option<f32>) -> bool {
        match y {
            Some(y) => self.scroll_positions.insert(group_hex.to_string(), y) != Some(y),
            None => self.scroll_positions.remove(group_hex).is_some(),
        }
    }

    /// Move `emoji` to the front of the recent-emoji row, dropping any
    /// earlier occurrence and truncating to `RECENT_EMOJI_MAX`.
    pub fn record_recent_emoji(&mut self, emoji: &str) {
        self.recent_emoji.retain(|e| e != emoji);
        self.recent_emoji.insert(0, emoji.to_string());
        self.recent_emoji.truncate(RECENT_EMOJI_MAX);
    }

    /// Move `group_hex` to the front of the recent-forwards list, dropping any
    /// earlier occurrence and truncating to `RECENT_FORWARD_MAX`.
    pub fn record_recent_forward(&mut self, group_hex: &str) {
        self.recent_forwards.retain(|g| g != group_hex);
        self.recent_forwards.insert(0, group_hex.to_string());
        self.recent_forwards.truncate(RECENT_FORWARD_MAX);
    }
}

/// The recent-emoji row is a single unscrolled strip, so the cap matches the
/// picker grid's fixed column count (`EmojiPicker.cols` in
/// `ui/emoji/emoji-picker.slint`).
pub const RECENT_EMOJI_MAX: usize = 10;

/// How many recently-forwarded-to chats the forward picker pins to the top —
/// "the same handful of people or groups" from the issue this implements, not
/// the whole chat list.
pub const RECENT_FORWARD_MAX: usize = 8;

fn default_locale() -> String {
    "en".into()
}

fn default_theme() -> String {
    "dark".into()
}

fn default_accent() -> String {
    "mint".into()
}

fn default_outgoing_on_right() -> bool {
    true
}

fn default_zoom() -> f32 {
    1.0
}

fn default_shell_chats_width() -> f32 {
    340.0
}

fn default_shell_info_width() -> f32 {
    292.0
}

fn default_time_format() -> String {
    "24h".into()
}

fn default_date_format() -> String {
    "mdy".into()
}

fn default_true() -> bool {
    true
}

/// The default quick-reaction set: the six reactions Telegram, WhatsApp,
/// Signal, and iMessage all seed their one-tap row with. The Settings "Reset"
/// button restores exactly this list (see `wire_quick_reactions`).
pub fn default_quick_reactions() -> Vec<String> {
    ["👍", "❤️", "😂", "😮", "😢", "🙏"]
        .into_iter()
        .map(str::to_string)
        .collect()
}

impl Default for Settings {
    // Deserialize an empty JSON object so every field takes its
    // `#[serde(default …)]` value. That attribute is the single source of truth
    // for defaults; a hand-written struct literal here would duplicate the
    // fields and silently drift when a field is added or a default changes.
    fn default() -> Self {
        serde_json::from_str("{}").expect("every Settings field has a serde default")
    }
}

impl Settings {
    pub fn load() -> Self {
        let path = match Self::path() {
            Some(p) => p,
            None => return Self::default(),
        };
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(_) => return Self::default(),
        };
        serde_json::from_slice(&bytes).unwrap_or_default()
    }

    pub fn save(&self) {
        let path = match Self::path() {
            Some(p) => p,
            None => return,
        };
        if let Some(parent) = path.parent()
            && let Err(e) = fs::create_dir_all(parent)
        {
            tracing::warn!(target: "settings", "create_dir_all({}): {e}", parent.display());
            return;
        }
        let bytes = match serde_json::to_vec_pretty(self) {
            Ok(b) => b,
            Err(e) => {
                tracing::warn!(target: "settings", "serialize: {e}");
                return;
            }
        };
        if let Err(e) = fs::write(&path, bytes) {
            tracing::warn!(target: "settings", "write({}): {e}", path.display());
        }
    }

    fn path() -> Option<PathBuf> {
        directories::ProjectDirs::from("", "", "whitenoise-linux")
            .map(|d| d.config_dir().join("settings.json"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_preferences_default_to_safe_values() {
        let settings: Settings = serde_json::from_str("{}").unwrap();

        assert!(!settings.launch_at_login);
        assert!(!settings.start_minimized_to_tray);
        assert!(!settings.restore_last_selected_chat);
        assert_eq!(settings.last_selected_chat, None);
    }

    #[test]
    fn startup_preferences_deserialize_from_existing_file() {
        let settings: Settings = serde_json::from_str(
            r#"{
                "launch_at_login": true,
                "start_minimized_to_tray": true,
                "restore_last_selected_chat": true,
                "last_selected_chat": "group-123"
            }"#,
        )
        .unwrap();

        assert!(settings.launch_at_login);
        assert!(settings.start_minimized_to_tray);
        assert!(settings.restore_last_selected_chat);
        assert_eq!(settings.last_selected_chat.as_deref(), Some("group-123"));
    }

    #[test]
    fn trusted_link_hosts_match_case_insensitively_and_round_trip() {
        let mut settings = Settings::default();

        assert!(settings.trust_link_host("Example.COM"));
        assert!(!settings.trust_link_host("example.com"));
        assert!(settings.is_link_host_trusted("EXAMPLE.com"));
        assert!(!settings.is_link_host_trusted("sub.example.com"));

        let json = serde_json::to_string(&settings).unwrap();
        let restored: Settings = serde_json::from_str(&json).unwrap();
        assert!(restored.is_link_host_trusted("example.com"));
    }

    #[test]
    fn trusted_link_host_can_be_forgotten() {
        let mut settings = Settings::default();
        assert!(settings.trust_link_host("example.com"));

        assert!(settings.forget_link_host("EXAMPLE.COM"));
        assert!(!settings.forget_link_host("example.com"));
        assert!(!settings.is_link_host_trusted("example.com"));
    }
}
