//! Chat-transcript export.
//!
//! Turns a group's message history into a document a user can keep for a
//! record, a dispute, or a move to another tool. HTML is the primary format:
//! it rebuilds the threaded look, embeds each image attachment inline as a
//! `data:` URI, and carries a per-message "Raw event" panel with the event
//! JSON for debugging. Markdown is the plain-text alternative for archival and
//! re-import elsewhere.
//!
//! Two phases. [`build_transcript`] reads the backend snapshot on the UI thread
//! (the message query and name cache are both UI-thread reads) and resolves
//! every message into owned data. The caller then hands the [`Transcript`] to a
//! blocking task, which downloads and decrypts the image attachments off the UI
//! thread ([`collect_image_data`]) before rendering.
//!
//! Message bodies are Markdown already, so the Markdown export embeds them
//! verbatim. For HTML we reparse each body with `whitenoise_markdown`, the same
//! CommonMark + GFM parser the chat bubbles use, and walk the AST into HTML so
//! bold, lists, links, and code survive.

use crate::*;
use nostr::base64::Engine as _;
use nostr::base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use whitenoise_markdown::{Block, Inline, ListItem, ListKind, NostrEntity, TableCell};

/// Output document format, chosen from the save dialog's file extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExportFormat {
    Markdown,
    Html,
}

impl ExportFormat {
    /// Pick a format from a save path's extension; anything but `.md` falls
    /// back to HTML, matching the default filename.
    pub(crate) fn from_path(path: &std::path::Path) -> Self {
        match path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("md") | Some("markdown") => ExportFormat::Markdown,
            _ => ExportFormat::Html,
        }
    }
}

/// Decrypted image bytes ready to inline, keyed by the attachment's
/// `ciphertext_sha256`. The value is a full `data:` URI.
pub(crate) type ImageData = HashMap<String, String>;

/// One attachment on a message. Images carry their reference so the export task
/// can download and embed them; other files render as a name/type note.
struct AttachmentInfo {
    note: String,
    file_name: String,
    image: Option<MediaAttachmentReference>,
}

/// One rendered message in the transcript, resolved to display-ready fields.
struct TranscriptEntry {
    author: String,
    stamp: String,
    /// The message body as Markdown source (edit-resolved). Empty when deleted.
    body: String,
    edited: bool,
    deleted: bool,
    attachments: Vec<AttachmentInfo>,
    /// `(emoji, count)`, most-used first.
    reactions: Vec<(String, i32)>,
    /// Pretty-printed nostr event JSON for the debug panel.
    event_json: String,
}

/// A whole conversation ready to render, plus the metadata the header needs.
pub(crate) struct Transcript {
    chat_name: String,
    exported_at: String,
    group_hex: String,
    entries: Vec<TranscriptEntry>,
}

impl Transcript {
    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(crate) fn group_hex(&self) -> &str {
        &self.group_hex
    }

    /// Every image attachment across the transcript, deduplicated by ciphertext
    /// hash so a blob repeated across messages downloads once.
    pub(crate) fn image_references(&self) -> Vec<MediaAttachmentReference> {
        let mut seen = std::collections::HashSet::new();
        let mut refs = Vec::new();
        for entry in &self.entries {
            for att in &entry.attachments {
                if let Some(r) = &att.image
                    && seen.insert(r.ciphertext_sha256.clone())
                {
                    refs.push(r.clone());
                }
            }
        }
        refs
    }
}

/// Read the group's history from the backend and resolve every chat message
/// into a [`TranscriptEntry`]. Must run on the UI thread (`Backend::messages`
/// and the profile-name cache are UI-thread reads).
pub(crate) fn build_transcript(backend: &Backend, group_hex: &str, chat_name: &str) -> Transcript {
    let records = backend.messages(group_hex, None).unwrap_or_default();
    let my_id = backend.account().account_id_hex;
    let reactions = aggregate_reactions(&records, &my_id, backend);
    let edits = aggregate_edits(&records);
    let deletes = aggregate_deletes(&records);

    let mut entries = Vec::new();
    for r in &records {
        if r.kind != CHAT_MESSAGE_KIND {
            continue;
        }
        let deleted = deletes.contains(&r.message_id_hex);
        let edit = edits.get(&r.message_id_hex);
        let body = if deleted {
            String::new()
        } else {
            edit.map(|e| e.text().to_string())
                .unwrap_or_else(|| r.plaintext.clone())
        };
        let attachments = if deleted {
            Vec::new()
        } else {
            parse_all_media_references(&r.tags, r.source_epoch)
                .into_iter()
                .map(|m| {
                    let note = format!("{} ({})", m.file_name, m.media_type);
                    let file_name = m.file_name.clone();
                    let image = mime_is_image(&m.media_type).then_some(m);
                    AttachmentInfo {
                        note,
                        file_name,
                        image,
                    }
                })
                .collect()
        };
        let msg_reactions = if deleted {
            Vec::new()
        } else {
            reactions
                .get(&r.message_id_hex)
                .map(|list| {
                    list.iter()
                        .map(|rx| (rx.emoji.to_string(), rx.count))
                        .collect()
                })
                .unwrap_or_default()
        };
        entries.push(TranscriptEntry {
            author: backend.account_display_name(&r.sender),
            stamp: format_full_stamp(r.recorded_at),
            body,
            edited: edit.map(|e| e.count() > 0).unwrap_or(false),
            deleted,
            attachments,
            reactions: msg_reactions,
            event_json: event_json(r),
        });
    }

    Transcript {
        chat_name: chat_name.to_string(),
        exported_at: format_full_stamp(now_unix()),
        group_hex: group_hex.to_string(),
        entries,
    }
}

/// The decrypted inner nostr event of a record, shaped like the wire event and
/// pretty-printed for the debug panel.
fn event_json(r: &AppMessageRecord) -> String {
    let value = serde_json::json!({
        "id": r.message_id_hex,
        "pubkey": r.sender,
        "created_at": r.recorded_at,
        "kind": r.kind,
        "tags": r.tags,
        "content": r.plaintext,
    });
    serde_json::to_string_pretty(&value).unwrap_or_default()
}

/// Download and decrypt each image attachment (off the UI thread), returning a
/// `ciphertext_sha256` to `data:` URI map for [`render`] to inline. Reads the
/// encrypted media cache first so an already-viewed image skips the network. A
/// download that fails is left out of the map, and the renderer falls back to a
/// note for it.
pub(crate) async fn collect_image_data(
    backend: &Backend,
    vault: Option<&Arc<Mutex<Vault>>>,
    group_hex: &str,
    refs: &[MediaAttachmentReference],
) -> ImageData {
    let mut map = ImageData::new();
    for r in refs {
        if map.contains_key(&r.ciphertext_sha256) {
            continue;
        }
        let cached = vault.and_then(|v| crate::media_cache::get(v, &r.ciphertext_sha256));
        let bytes = match cached {
            Some(b) => Some(b),
            None => download_attachment(backend, group_hex, r.clone()).await,
        };
        if let Some(bytes) = bytes {
            let uri = format!(
                "data:{};base64,{}",
                r.media_type,
                BASE64_STANDARD.encode(&bytes)
            );
            map.insert(r.ciphertext_sha256.clone(), uri);
        }
    }
    map
}

async fn download_attachment(
    backend: &Backend,
    group_hex: &str,
    reference: MediaAttachmentReference,
) -> Option<Vec<u8>> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    backend.download_media_async(group_hex, reference, move |res| {
        let _ = tx.send(res);
    });
    rx.await.ok().and_then(Result::ok).map(|d| d.plaintext)
}

/// Render the transcript to the requested format. `images` is only consulted
/// for HTML; pass an empty map for Markdown.
pub(crate) fn render(transcript: &Transcript, format: ExportFormat, images: &ImageData) -> String {
    match format {
        ExportFormat::Markdown => render_markdown(transcript),
        ExportFormat::Html => render_html(transcript, images),
    }
}

/// A filesystem-safe default filename stem derived from the chat name. Keeps
/// letters, digits, spaces, dashes, and underscores; collapses everything else
/// (path separators, punctuation, control bytes) to a dash.
pub(crate) fn safe_file_stem(chat_name: &str) -> String {
    let cleaned: String = chat_name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == ' ' || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = cleaned.trim().trim_matches('-').trim();
    if trimmed.is_empty() {
        "chat".to_string()
    } else {
        trimmed.to_string()
    }
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

fn render_markdown(t: &Transcript) -> String {
    let mut out = String::new();
    out.push_str(&format!("# {}\n\n", t.chat_name));
    out.push_str(&format!(
        "*{} messages · exported {}*\n",
        t.entries.len(),
        t.exported_at
    ));

    for e in &t.entries {
        out.push_str("\n---\n\n");
        out.push_str(&format!("**{}** · {}", e.author, e.stamp));
        if e.edited {
            out.push_str(" *(edited)*");
        }
        out.push('\n');

        if e.deleted {
            out.push_str("\n*[Message deleted]*\n");
        } else if !e.body.trim().is_empty() {
            out.push('\n');
            out.push_str(e.body.trim_end());
            out.push('\n');
        }

        for att in &e.attachments {
            out.push_str(&format!("\n- 📎 {}", att.note));
        }
        if !e.attachments.is_empty() {
            out.push('\n');
        }

        if !e.reactions.is_empty() {
            let chips: Vec<String> = e
                .reactions
                .iter()
                .map(|(emoji, count)| format!("{emoji} {count}"))
                .collect();
            out.push_str(&format!("\nReactions: {}\n", chips.join(" · ")));
        }

        if !e.event_json.is_empty() {
            out.push_str("\n<details><summary>Raw event</summary>\n\n```json\n");
            out.push_str(&e.event_json);
            out.push_str("\n```\n\n</details>\n");
        }
    }

    out
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

fn render_html(t: &Transcript, images: &ImageData) -> String {
    let mut out = String::new();
    out.push_str("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    out.push_str(&format!("<title>{}</title>\n", esc(&t.chat_name)));
    out.push_str("<style>\n");
    out.push_str(HTML_STYLE);
    out.push_str("</style>\n</head>\n<body>\n<main>\n");

    out.push_str(&format!("<h1>{}</h1>\n", esc(&t.chat_name)));
    out.push_str(&format!(
        "<p class=\"meta\">{} messages · exported {}</p>\n",
        t.entries.len(),
        esc(&t.exported_at)
    ));

    for e in &t.entries {
        out.push_str("<article class=\"msg\">\n<header>");
        out.push_str(&format!("<span class=\"author\">{}</span>", esc(&e.author)));
        out.push_str(&format!("<span class=\"stamp\">{}</span>", esc(&e.stamp)));
        if e.edited {
            out.push_str("<span class=\"edited\">(edited)</span>");
        }
        out.push_str("</header>\n");

        if e.deleted {
            out.push_str("<p class=\"deleted\">[Message deleted]</p>\n");
        } else if !e.body.trim().is_empty() {
            let doc = whitenoise_markdown::parse(&e.body);
            out.push_str("<div class=\"body\">");
            for block in &doc.blocks {
                html_block(&mut out, block);
            }
            out.push_str("</div>\n");
        }

        html_attachments(&mut out, &e.attachments, images);

        if !e.reactions.is_empty() {
            out.push_str("<div class=\"reactions\">");
            for (emoji, count) in &e.reactions {
                out.push_str(&format!(
                    "<span class=\"chip\">{} {}</span>",
                    esc(emoji),
                    count
                ));
            }
            out.push_str("</div>\n");
        }

        if !e.event_json.is_empty() {
            out.push_str("<details class=\"debug\"><summary>Raw event</summary><pre><code>");
            out.push_str(&esc(&e.event_json));
            out.push_str("</code></pre></details>\n");
        }

        out.push_str("</article>\n");
    }

    out.push_str("</main>\n</body>\n</html>\n");
    out
}

/// Embed image attachments inline (from the decrypted `images` map) and list
/// everything else, plus any image whose download failed, as a note.
fn html_attachments(out: &mut String, attachments: &[AttachmentInfo], images: &ImageData) {
    for att in attachments {
        if let Some(img) = &att.image
            && let Some(uri) = images.get(&img.ciphertext_sha256)
        {
            out.push_str(&format!(
                "<img class=\"attachment-img\" src=\"{}\" alt=\"{}\">\n",
                esc_attr(uri),
                esc(&att.file_name)
            ));
        }
    }

    let notes: Vec<&AttachmentInfo> = attachments
        .iter()
        .filter(|att| {
            att.image
                .as_ref()
                .is_none_or(|img| !images.contains_key(&img.ciphertext_sha256))
        })
        .collect();
    if !notes.is_empty() {
        out.push_str("<ul class=\"attachments\">");
        for att in notes {
            out.push_str(&format!("<li>📎 {}</li>", esc(&att.note)));
        }
        out.push_str("</ul>\n");
    }
}

const HTML_STYLE: &str = r#"
:root { color-scheme: light dark; }
body { margin: 0; background: #f4f4f5; color: #18181b;
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 32px 20px 64px; }
h1 { font-size: 22px; margin: 0 0 4px; }
.meta { color: #71717a; margin: 0 0 24px; font-size: 13px; }
.msg { background: #fff; border: 1px solid #e4e4e7; border-radius: 12px;
  padding: 12px 16px; margin: 0 0 12px; }
.msg header { display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
.author { font-weight: 600; }
.stamp { color: #a1a1aa; font-size: 12px; }
.edited { color: #a1a1aa; font-size: 12px; font-style: italic; }
.body { margin-top: 6px; }
.body p { margin: 6px 0; }
.body pre { background: #f4f4f5; border-radius: 8px; padding: 10px 12px;
  overflow-x: auto; }
.body code { background: #f4f4f5; border-radius: 4px; padding: 1px 5px;
  font-size: 90%; }
.body pre code { background: none; padding: 0; }
.body blockquote { margin: 6px 0; padding-left: 12px;
  border-left: 3px solid #d4d4d8; color: #52525b; }
.body table { border-collapse: collapse; }
.body th, .body td { border: 1px solid #e4e4e7; padding: 4px 8px; }
.deleted { color: #a1a1aa; font-style: italic; margin: 6px 0; }
.attachment-img { max-width: 100%; height: auto; border-radius: 8px;
  margin: 6px 0; display: block; }
.attachments { margin: 8px 0 0; padding-left: 18px; }
.reactions { margin-top: 8px; display: flex; gap: 6px; flex-wrap: wrap; }
.chip { background: #f4f4f5; border: 1px solid #e4e4e7; border-radius: 12px;
  padding: 1px 8px; font-size: 13px; }
.debug { margin-top: 8px; }
.debug summary { cursor: pointer; color: #71717a; font-size: 12px; }
.debug pre { margin-top: 6px; background: #f4f4f5; border-radius: 8px;
  padding: 10px 12px; overflow-x: auto; font-size: 12px; }
@media (prefers-color-scheme: dark) {
  body { background: #18181b; color: #e4e4e7; }
  .msg { background: #27272a; border-color: #3f3f46; }
  .body pre, .body code, .chip, .debug pre { background: #3f3f46; }
  .chip { border-color: #52525b; }
  .body blockquote { border-left-color: #52525b; color: #a1a1aa; }
  .body th, .body td { border-color: #3f3f46; }
}
"#;

fn html_block(out: &mut String, block: &Block) {
    match block {
        Block::Paragraph { inlines } => {
            out.push_str("<p>");
            html_inlines(out, inlines);
            out.push_str("</p>");
        }
        Block::Heading { level, inlines } => {
            // Demote body headings so they never outrank the transcript's own
            // <h1>; clamp to the <h6> floor.
            let tag = (level + 1).min(6);
            out.push_str(&format!("<h{tag}>"));
            html_inlines(out, inlines);
            out.push_str(&format!("</h{tag}>"));
        }
        Block::ThematicBreak => out.push_str("<hr>"),
        Block::CodeBlock { content, .. } => {
            out.push_str("<pre><code>");
            out.push_str(&esc(content));
            out.push_str("</code></pre>");
        }
        Block::BlockQuote { blocks } => {
            out.push_str("<blockquote>");
            for b in blocks {
                html_block(out, b);
            }
            out.push_str("</blockquote>");
        }
        Block::List { kind, items, .. } => {
            let (tag, start) = match kind {
                ListKind::Ordered { start, .. } => ("ol", Some(*start)),
                ListKind::Bullet { .. } => ("ul", None),
            };
            match start {
                Some(n) if n != 1 => out.push_str(&format!("<{tag} start=\"{n}\">")),
                _ => out.push_str(&format!("<{tag}>")),
            }
            for item in items {
                html_list_item(out, item);
            }
            out.push_str(&format!("</{tag}>"));
        }
        Block::Table { header, rows, .. } => {
            out.push_str("<table>");
            if !header.is_empty() {
                out.push_str("<thead><tr>");
                for cell in header {
                    html_table_cell(out, cell, "th");
                }
                out.push_str("</tr></thead>");
            }
            out.push_str("<tbody>");
            for row in rows {
                out.push_str("<tr>");
                for cell in row {
                    html_table_cell(out, cell, "td");
                }
                out.push_str("</tr>");
            }
            out.push_str("</tbody></table>");
        }
        Block::MathBlock { content } => {
            out.push_str("<pre><code>");
            out.push_str(&esc(content));
            out.push_str("</code></pre>");
        }
    }
}

fn html_list_item(out: &mut String, item: &ListItem) {
    out.push_str("<li>");
    if let Some(checked) = item.checked {
        out.push_str(if checked {
            "<input type=\"checkbox\" checked disabled> "
        } else {
            "<input type=\"checkbox\" disabled> "
        });
    }
    for b in &item.blocks {
        // Tight single-paragraph items read better unwrapped, matching how the
        // bubbles flatten them.
        if let Block::Paragraph { inlines } = b {
            html_inlines(out, inlines);
        } else {
            html_block(out, b);
        }
    }
    out.push_str("</li>");
}

fn html_table_cell(out: &mut String, cell: &TableCell, tag: &str) {
    out.push_str(&format!("<{tag}>"));
    html_inlines(out, &cell.inlines);
    out.push_str(&format!("</{tag}>"));
}

fn html_inlines(out: &mut String, inlines: &[Inline]) {
    for inline in inlines {
        html_inline(out, inline);
    }
}

fn html_inline(out: &mut String, inline: &Inline) {
    match inline {
        Inline::Text(s) => out.push_str(&esc(s)),
        Inline::SoftBreak => out.push(' '),
        Inline::HardBreak => out.push_str("<br>"),
        Inline::Code(s) => {
            out.push_str("<code>");
            out.push_str(&esc(s));
            out.push_str("</code>");
        }
        Inline::Emph(c) => wrap_inlines(out, "em", c),
        Inline::Strong(c) => wrap_inlines(out, "strong", c),
        Inline::Strikethrough(c) => wrap_inlines(out, "del", c),
        // The effect wrapper has no meaning in a static document; render its
        // contents plainly.
        Inline::Effect { children, .. } => html_inlines(out, children),
        Inline::Link { dest, children, .. } => {
            html_anchor_open(out, dest);
            html_inlines(out, children);
            out.push_str("</a>");
        }
        Inline::Image { dest, alt, .. } => {
            let mut alt_text = String::new();
            html_inlines(&mut alt_text, alt);
            html_anchor_open(out, dest);
            if alt_text.is_empty() {
                out.push_str(&esc(dest));
            } else {
                out.push_str(&alt_text);
            }
            out.push_str("</a>");
        }
        Inline::Autolink { url, .. } => {
            html_anchor_open(out, url);
            out.push_str(&esc(url));
            out.push_str("</a>");
        }
        Inline::Math(s) => {
            out.push_str("<code>");
            out.push_str(&esc(s));
            out.push_str("</code>");
        }
        Inline::NostrMention(e) | Inline::NostrUri(e) => html_nostr(out, e),
    }
}

/// Open an `<a>` tag whose `href` is safe to open from a downloaded file. Only
/// scheme-less (relative/fragment) links and the `http`/`https`/`mailto`/`nostr`
/// schemes keep their destination; anything else (`javascript:`, `data:`, …) is
/// stripped so the exported document can be opened in a browser without a script
/// smuggled through a message body running.
fn html_anchor_open(out: &mut String, dest: &str) {
    if href_is_safe(dest) {
        out.push_str(&format!("<a href=\"{}\">", esc_attr(dest)));
    } else {
        out.push_str("<a>");
    }
}

fn href_is_safe(dest: &str) -> bool {
    // A scheme is the run of `[A-Za-z][A-Za-z0-9+.-]*` before the first ':',
    // but only when that colon precedes any '/', '?', or '#' (otherwise the
    // ':' belongs to a path, so there is no scheme and the link is relative).
    let scheme_end = dest.find([':', '/', '?', '#']);
    let Some(idx) = scheme_end else {
        return true; // no scheme, no path separators — relative
    };
    if dest.as_bytes().get(idx) != Some(&b':') {
        return true; // hit a path separator first — relative
    }
    let scheme = dest[..idx].to_ascii_lowercase();
    matches!(scheme.as_str(), "http" | "https" | "mailto" | "nostr")
}

fn wrap_inlines(out: &mut String, tag: &str, children: &[Inline]) {
    out.push_str(&format!("<{tag}>"));
    html_inlines(out, children);
    out.push_str(&format!("</{tag}>"));
}

fn html_nostr(out: &mut String, entity: &NostrEntity) {
    out.push_str("<code>nostr:");
    out.push_str(&esc(&entity.bech32));
    out.push_str("</code>");
}

/// Escape text for HTML element content.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

/// Escape text for a double-quoted HTML attribute (e.g. `href`).
fn esc_attr(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_stem_sanitizes_and_falls_back() {
        assert_eq!(safe_file_stem("Alice & Bob"), "Alice - Bob");
        assert_eq!(safe_file_stem("a/b\\c"), "a-b-c");
        assert_eq!(safe_file_stem("///"), "chat");
        assert_eq!(safe_file_stem("  "), "chat");
    }

    #[test]
    fn format_from_extension() {
        assert_eq!(
            ExportFormat::from_path(std::path::Path::new("t.html")),
            ExportFormat::Html
        );
        assert_eq!(
            ExportFormat::from_path(std::path::Path::new("t.md")),
            ExportFormat::Markdown
        );
        // Anything unrecognized (including no extension) defaults to HTML.
        assert_eq!(
            ExportFormat::from_path(std::path::Path::new("noext")),
            ExportFormat::Html
        );
    }

    #[test]
    fn html_escapes_body_and_renders_formatting() {
        let mut out = String::new();
        let doc = whitenoise_markdown::parse("**bold** and <script> & `code`");
        for b in &doc.blocks {
            html_block(&mut out, b);
        }
        assert!(out.contains("<strong>bold</strong>"));
        assert!(out.contains("&lt;script&gt;"));
        assert!(out.contains("&amp;"));
        assert!(out.contains("<code>code</code>"));
    }

    #[test]
    fn href_scheme_allowlist() {
        assert!(href_is_safe("https://example.com"));
        assert!(href_is_safe("http://example.com"));
        assert!(href_is_safe("mailto:a@b.com"));
        assert!(href_is_safe("nostr:npub1abc"));
        assert!(href_is_safe("/relative/path"));
        assert!(href_is_safe("#anchor"));
        assert!(href_is_safe("page.html"));
        assert!(!href_is_safe("javascript:alert(1)"));
        assert!(!href_is_safe("JavaScript:alert(1)"));
        assert!(!href_is_safe("data:text/html,<script>"));
        assert!(!href_is_safe("vbscript:msgbox"));
    }

    #[test]
    fn dangerous_link_href_is_dropped() {
        let mut out = String::new();
        let doc = whitenoise_markdown::parse("[x](javascript:alert(1))");
        for b in &doc.blocks {
            html_block(&mut out, b);
        }
        assert!(!out.contains("javascript:"));
        assert!(out.contains("<a>x</a>"));
    }

    #[test]
    fn image_embedded_when_present_note_when_missing() {
        let img = |hash: &str| AttachmentInfo {
            note: "photo.jpg (image/jpeg)".to_string(),
            file_name: "photo.jpg".to_string(),
            image: Some(MediaAttachmentReference {
                locators: vec![],
                ciphertext_sha256: hash.to_string(),
                plaintext_sha256: String::new(),
                nonce_hex: String::new(),
                file_name: "photo.jpg".to_string(),
                media_type: "image/jpeg".to_string(),
                version: String::new(),
                source_epoch: 0,
                dim: None,
                thumbhash: None,
            }),
        };
        let mut images = ImageData::new();
        images.insert("have".to_string(), "data:image/jpeg;base64,AAA".to_string());

        let mut out = String::new();
        html_attachments(&mut out, &[img("have")], &images);
        assert!(out.contains("<img class=\"attachment-img\" src=\"data:image/jpeg;base64,AAA\""));
        assert!(!out.contains("<ul"));

        let mut miss = String::new();
        html_attachments(&mut miss, &[img("missing")], &images);
        assert!(!miss.contains("<img"));
        assert!(miss.contains("📎 photo.jpg (image/jpeg)"));
    }
}
