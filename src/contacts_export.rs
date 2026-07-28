//! Contact-list export.
//!
//! Writes the Contacts page's current rows to a plain file the user picks: CSV
//! for spreadsheets, JSON for re-import elsewhere. Unlike the chat-transcript
//! export (`export.rs`), this needs no backend read of its own — the caller
//! already has the rendered `Contact` rows from the UI model, so this module
//! is pure formatting.

use serde::Serialize;

/// Output format, chosen from the save dialog's file extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ContactExportFormat {
    Csv,
    Json,
}

impl ContactExportFormat {
    /// Pick a format from a save path's extension; anything but `.json` falls
    /// back to CSV, matching the default filename.
    pub(crate) fn from_path(path: &std::path::Path) -> Self {
        match path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("json") => ContactExportFormat::Json,
            _ => ContactExportFormat::Csv,
        }
    }
}

/// One exported contact. `nickname` is the private, local-only label from
/// `Settings.nicknames`; `profile_name` is the published kind-0 name/display
/// name, the same fallback the Contacts page itself shows when no nickname
/// is set.
#[derive(Serialize)]
pub(crate) struct ContactExportRow {
    pub(crate) npub: String,
    pub(crate) nickname: String,
    pub(crate) profile_name: String,
}

pub(crate) fn render_contacts(rows: &[ContactExportRow], format: ContactExportFormat) -> String {
    match format {
        ContactExportFormat::Csv => render_csv(rows),
        ContactExportFormat::Json => {
            serde_json::to_string_pretty(rows).unwrap_or_else(|_| "[]".to_string())
        }
    }
}

fn render_csv(rows: &[ContactExportRow]) -> String {
    let mut out = String::from("npub,nickname,profile_name\n");
    for row in rows {
        out.push_str(&csv_field(&row.npub));
        out.push(',');
        out.push_str(&csv_field(&row.nickname));
        out.push(',');
        out.push_str(&csv_field(&row.profile_name));
        out.push('\n');
    }
    out
}

/// Quote a CSV field per RFC 4180: always wrap in quotes, doubling any quote
/// already in the value. Simplest correct option since names/nicknames are
/// free text and can contain commas, quotes, or newlines.
fn csv_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}
