//! Chat-transcript export.
//!
//! Turns a group's message history into a readable, self-contained document a
//! user can keep for a record, a dispute, or a move to another tool. Two
//! formats: Markdown (plain archival, re-imports elsewhere) and HTML (the
//! threaded look preserved for sharing or printing).
//!
//! The whole pipeline is pure once the records are in hand: [`build_transcript`]
//! reads the backend snapshot on the UI thread (message query + name cache are
//! both UI-thread reads), and the two renderers below take only owned data, so
//! the caller can hand the [`Transcript`] to a blocking file-write task.
//!
//! Message bodies are Markdown already, so the Markdown export embeds them
//! verbatim. For HTML we reparse each body with `whitenoise_markdown` — the
//! same CommonMark + GFM parser the chat bubbles use — and walk the AST into
//! HTML so bold, lists, links, and code survive the export.

use crate::*;
use whitenoise_markdown::{Block, Inline, ListItem, ListKind, NostrEntity, TableCell};

/// Output document format, chosen from the save dialog's file extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExportFormat {
    Markdown,
    Html,
}

impl ExportFormat {
    /// Pick a format from a save path's extension; anything but `.htm`/`.html`
    /// falls back to Markdown, matching the default filename.
    pub(crate) fn from_path(path: &std::path::Path) -> Self {
        match path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("html") | Some("htm") => ExportFormat::Html,
            _ => ExportFormat::Markdown,
        }
    }
}

/// One rendered message in the transcript, resolved to display-ready fields.
struct TranscriptEntry {
    author: String,
    stamp: String,
    /// The message body as Markdown source (edit-resolved). Empty when deleted.
    body: String,
    edited: bool,
    deleted: bool,
    /// One "name (type)" note per attachment; the bytes stay encrypted in the
    /// group, so a note is the honest record — there is no shareable link.
    attachments: Vec<String>,
    /// `(emoji, count)`, most-used first.
    reactions: Vec<(String, i32)>,
}

/// A whole conversation ready to render, plus the metadata the header needs.
pub(crate) struct Transcript {
    chat_name: String,
    exported_at: String,
    entries: Vec<TranscriptEntry>,
}

impl Transcript {
    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Read the group's history from the backend and resolve every chat message
/// into a [`TranscriptEntry`]. Must run on the UI thread (`Backend::messages`
/// and the profile-name cache are UI-thread reads).
pub(crate) fn build_transcript(backend: &Backend, group_hex: &str, chat_name: &str) -> Transcript {
    let records = backend.messages(group_hex, None).unwrap_or_default();
    let my_id = backend.account().account_id_hex;
    let reactions = aggregate_reactions(&records, &my_id);
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
                .map(|m| format!("{} ({})", m.file_name, m.media_type))
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
        });
    }

    Transcript {
        chat_name: chat_name.to_string(),
        exported_at: format_full_stamp(now_unix()),
        entries,
    }
}

/// Render the transcript to the requested format.
pub(crate) fn render(transcript: &Transcript, format: ExportFormat) -> String {
    match format {
        ExportFormat::Markdown => render_markdown(transcript),
        ExportFormat::Html => render_html(transcript),
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
            out.push_str(&format!("\n- 📎 {att}"));
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
    }

    out
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

fn render_html(t: &Transcript) -> String {
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

        if !e.attachments.is_empty() {
            out.push_str("<ul class=\"attachments\">");
            for att in &e.attachments {
                out.push_str(&format!("<li>📎 {}</li>", esc(att)));
            }
            out.push_str("</ul>\n");
        }

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

        out.push_str("</article>\n");
    }

    out.push_str("</main>\n</body>\n</html>\n");
    out
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
.attachments { margin: 8px 0 0; padding-left: 18px; }
.reactions { margin-top: 8px; display: flex; gap: 6px; flex-wrap: wrap; }
.chip { background: #f4f4f5; border: 1px solid #e4e4e7; border-radius: 12px;
  padding: 1px 8px; font-size: 13px; }
@media (prefers-color-scheme: dark) {
  body { background: #18181b; color: #e4e4e7; }
  .msg { background: #27272a; border-color: #3f3f46; }
  .body pre, .body code, .chip { background: #3f3f46; }
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
            ExportFormat::from_path(std::path::Path::new("t.HTM")),
            ExportFormat::Html
        );
        assert_eq!(
            ExportFormat::from_path(std::path::Path::new("t.md")),
            ExportFormat::Markdown
        );
        assert_eq!(
            ExportFormat::from_path(std::path::Path::new("noext")),
            ExportFormat::Markdown
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
}
