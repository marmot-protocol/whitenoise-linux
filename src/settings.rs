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
}

impl Settings {
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
}

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
}
