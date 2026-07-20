use crate::*;

/// Cheap deterministic avatar palette + initials from any string key.
pub(crate) fn avatar_for(key: &str) -> (Color, Color, String) {
    let mut h: u32 = 0x811c_9dc5;
    for b in key.as_bytes() {
        h = h.wrapping_mul(16_777_619) ^ (*b as u32);
    }
    let hue_a = 0x80_8080u32.wrapping_add(h & 0x7f_7f7f);
    let hue_b = 0x20_2020u32.wrapping_add(h.rotate_left(7) & 0x3f_3f3f);
    let init: String = key
        .split_whitespace()
        .filter_map(|w| w.chars().next())
        .take(2)
        .collect::<String>()
        .to_uppercase();
    let init = if init.is_empty() {
        key.chars().take(2).collect::<String>().to_uppercase()
    } else {
        init
    };
    (rgb(hue_a), rgb(hue_b), init)
}

pub(crate) fn short_hex(s: &str) -> String {
    if s.len() <= 6 {
        s.to_string()
    } else {
        s[..6].to_string()
    }
}

/// The synthetic row key that stands in for a group chat's npub. `chat_meta_from`
/// and `archived_from` stamp it into `ChatMeta.npub` / `ArchivedChat.group_id`, and
/// the avatar-fetch completions in `chrome.rs` rebuild it to find the same row again
/// through `update_chat_picture`. Every producer and consumer of the key must call
/// this one helper so the two sides cannot diverge on prefix or truncation.
pub(crate) fn mls_row_key(group_id_hex: &str) -> String {
    format!("mls:0x{}", short_hex(group_id_hex))
}

// ─── Emoji catalog ──────────────────────────────────────────────────────

// `emoji_sprite_map` and `EMOJI_SPRITE_PNG` come from wnl-ui (via the glob
// import at the top) — they're emitted by that crate's build.rs.

// No cap: the picker grid in Slint manually virtualizes (only rows whose
// y-range intersects the viewport are instantiated), so the full ~1900-emoji
// catalog stays cheap regardless of how many match.

/// Decode the build-time sprite sheet into a `slint::Image`. Cached so
/// repeated calls reuse the same texture.
pub(crate) fn emoji_sprite_image() -> slint::Image {
    use std::cell::RefCell;
    thread_local! {
        static CACHE: RefCell<Option<slint::Image>> = const { RefCell::new(None) };
    }
    if let Some(img) = CACHE.with(|c| c.borrow().clone()) {
        return img;
    }
    let decoded = image::load_from_memory_with_format(EMOJI_SPRITE_PNG, image::ImageFormat::Png)
        .expect("decode embedded twemoji sprite")
        .to_rgba8();
    let (w, h) = decoded.dimensions();
    let buffer =
        slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(decoded.as_raw(), w, h);
    let image = slint::Image::from_rgba8(buffer);
    CACHE.with(|c| *c.borrow_mut() = Some(image.clone()));
    image
}

/// Build a fast lookup from emoji string → its (x, y) position in the
/// sprite sheet, using the table emitted by build.rs.
pub(crate) fn emoji_position_index() -> &'static std::collections::HashMap<&'static str, (u32, u32)>
{
    use std::collections::HashMap;
    use std::sync::OnceLock;
    static IDX: OnceLock<HashMap<&'static str, (u32, u32)>> = OnceLock::new();
    IDX.get_or_init(|| {
        emoji_sprite_map::EMOJI_POSITIONS
            .iter()
            .map(|(e, x, y)| (*e, (*x, *y)))
            .collect()
    })
}

// ── Message effects (Telegram-style bursts) ─────────────────────────────────
//
// A small catalog of one-shot particle effects. Each is (catalog-id, wire-key,
// emoji). The id drives the Slint motion switch in message-effect-layer.slint;
// the wire-key is what travels in the kind-9 `["effect", <key>]` tag; the emoji
// is rendered as the flying particle (resolved to a sprite-sheet tile via the
// inline-emoji index).
pub(crate) const EFFECTS: &[(i32, &str, &str)] = &[
    (1, "love", "❤️"),
    (2, "fire", "🔥"),
    (3, "party", "🎉"),
    (4, "star", "⭐"),
    (5, "like", "👍"),
];

/// Name of the out-of-band nostr tag that carries a message effect on the
/// kind-9 chat event: `["effect", <wire-key>]`.
pub(crate) const EFFECT_TAG: &str = "effect";

pub(crate) fn effect_emoji(id: i32) -> Option<&'static str> {
    EFFECTS.iter().find(|e| e.0 == id).map(|e| e.2)
}
pub(crate) fn effect_id_from_key(key: &str) -> i32 {
    EFFECTS
        .iter()
        .find(|e| e.1 == key)
        .map(|e| e.0)
        .unwrap_or(0)
}

/// Resolve an emoji to its (x, y) tile in the Twemoji sheet, tolerating the
/// presence/absence of a trailing U+FE0F variation selector (the sprite index
/// and a caller's string can disagree on it). The shared resolver behind inline
/// emoji, message effects, and the quick-reaction row.
pub(crate) fn emoji_clip(emoji: &str) -> Option<(u32, u32)> {
    let idx = emoji_position_index();
    if let Some(p) = idx.get(emoji) {
        return Some(*p);
    }
    let stripped = emoji.trim_end_matches('\u{FE0F}');
    if let Some(p) = idx.get(stripped) {
        return Some(*p);
    }
    let with_vs = format!("{stripped}\u{FE0F}");
    idx.get(with_vs.as_str()).copied()
}

/// Resolve an effect's emoji to its sprite tile (see [`emoji_clip`]).
pub(crate) fn effect_clip(id: i32) -> Option<(u32, u32)> {
    emoji_clip(effect_emoji(id)?)
}

/// Read a message effect off a kind-9's tags (`["effect", <key>]`). Returns the
/// catalog id, or 0 when there's no effect tag (or its key is unknown).
pub(crate) fn effect_from_tags(tags: &[Vec<String>]) -> i32 {
    tags.iter()
        .find(|t| t.first().map(|n| n == EFFECT_TAG).unwrap_or(false))
        .and_then(|t| t.get(1))
        .map(|key| effect_id_from_key(key))
        .unwrap_or(0)
}

/// Set of message-ids whose effect has already been claimed for autoplay (or
/// marked seen-during-backfill). Rows rebuild from scratch (reactions, picture
/// loads, full rebuilds recreate components and re-run `init`), so the
/// fire-exactly-once decision can't live in Slint state — it lives here.
pub(crate) fn effect_seen_ids() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    use std::sync::OnceLock;
    static S: OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    S.get_or_init(|| std::sync::Mutex::new(std::collections::HashSet::new()))
}

/// Whether this build should AUTOPLAY the effect for `message_id`. True only on
/// the very first time the id is ever built, and only if that first build is
/// `live` (a watcher arrival or optimistic send). Every later build — including
/// a full rebuild that recreates the row component and re-runs its `init`, or a
/// chat reopen — returns false, so a playing burst is never re-fired or
/// interrupted. Backfill (`live == false`) just claims the id as seen-but-quiet.
/// (Tap-to-replay is independent of this — it fires straight from the bubble.)
pub(crate) fn effect_should_autoplay(message_id: &str, raw_effect: i32, live: bool) -> bool {
    if raw_effect == 0 {
        return false;
    }
    let mut seen = effect_seen_ids().lock().unwrap();
    if !seen.insert(message_id.to_string()) {
        // Already present → already handled once; never autoplay again.
        return false;
    }
    live
}

// ── Markdown rendering ──────────────────────────────────────────────────────
//
// Chat bodies are parsed with `whitenoise_markdown` (the same CommonMark + GFM +
// nostr parser whitenoise-rs uses) into a `Document`, then flattened into the
// bubble's existing line/run model: each `MessageLine` is one visual line, each
// `MessageRun` an inline text/emoji cell carrying resolved styling. Block
// context (heading scale, list/blockquote indent, code plates, rules) rides on
// the line. Wrapping stays Rust-side and greedy — widths are estimated against
// the monospace advance only to decide *where* to break; Slint draws with real
// metrics, exactly as the plain-text path did before.
use whitenoise_markdown::{Block, Inline, ListItem, ListKind, NostrEntity};

/// Approximate monospace glyph advance as a fraction of font-size. Only used to
/// decide wrap points; never to position glyphs.
pub(crate) const MD_CHAR_W: f32 = 0.62;
/// Approximate inline-emoji advance as a fraction of font-size.
pub(crate) const MD_EMOJI_W: f32 = 1.25;
/// Extra horizontal pixels a mention chip's plate adds around its text (must
/// match the RunCell's mention padding so the wrapper doesn't overshoot).
pub(crate) const MD_MENTION_PAD: f32 = 10.0;

/// Inline styling resolved for a single run while walking the AST.
#[derive(Clone, Copy, Default)]
pub(crate) struct MdStyle {
    bold: bool,
    italic: bool,
    strike: bool,
    code: bool,
    /// iMessage text effects as a bitmask, so any number of effects stack on
    /// the same glyph (each acts on an independent visual axis). Bits:
    /// 1 big, 2 small, 4 explode, 8 bloom, 16 shake, 32 nod, 64 ripple,
    /// 128 jitter. The RunCell decodes the bits and composes the transforms.
    fx: u8,
    /// Profile-mention chip: the run renders its text on a rounded plate
    /// tinted with the account's avatar gradient (`mention_a`/`mention_b`).
    mention: bool,
    mention_a: Color,
    mention_b: Color,
}

/// OR the `{name}…{/name}` effect into the style's bitmask. Effects compose, so
/// nesting (`{big}{explode}…`) keeps both. Unknown names set no bit, so the
/// span passes through as literal styled text.
pub(crate) fn apply_effect(style: &mut MdStyle, name: &str) {
    let bit: u8 = match name.to_ascii_lowercase().as_str() {
        "big" => 1,
        "small" => 2,
        "explode" => 4,
        "bloom" => 8,
        "shake" => 16,
        "nod" => 32,
        "ripple" => 64,
        "jitter" => 128,
        _ => 0,
    };
    style.fx |= bit;
}

impl MdStyle {
    /// True when any effect bit is set — drives per-letter splitting.
    fn has_fx(&self) -> bool {
        self.fx != 0
    }
}

/// One atomic token in the inline stream feeding the greedy wrapper.
pub(crate) enum MdTok {
    Word {
        text: String,
        style: MdStyle,
        link: Option<String>,
    },
    Space {
        text: String,
        style: MdStyle,
        link: Option<String>,
    },
    Emoji {
        /// The source emoji string (possibly a multi-scalar ZWJ sequence).
        /// Rendered from the sprite sheet, but kept on the run so
        /// selection-copy can reproduce the character.
        text: String,
        x: u32,
        y: u32,
        fx: u8,
    },
    Break,
}

/// A wrapped line plus its block-level context, before conversion to the Slint
/// `MessageLine` struct.
pub(crate) struct MdLine {
    runs: Vec<MessageRun>,
    indent: f32,
    scale: f32,
    quote: i32,
    code_block: bool,
    rule: bool,
    /// False only for wrap-continuation lines produced inside `md_wrap`; every
    /// block boundary, explicit break, code line, spacer, and rule starts a
    /// new logical line. See `MessageLine.hard-break` in tokens.slint.
    hard_break: bool,
}

/// Block-walk context: accumulated left inset and current blockquote depth.
#[derive(Clone, Copy)]
pub(crate) struct MdCtx {
    indent: f32,
    quote: i32,
}

/// Render-wide constants threaded through the whole block walk: the wrap width,
/// the base font size, and the emoji sprite-position index. Bundled (and `Copy`,
/// since `positions` is `&'static`) so the recursive walkers pass a single `env`
/// instead of repeating the same three positional arguments at every call.
#[derive(Clone, Copy)]
pub(crate) struct MdEnv {
    max_width: f32,
    base_fs: f32,
    positions: &'static std::collections::HashMap<&'static str, (u32, u32)>,
}

pub(crate) fn md_run_text(text: &str, style: MdStyle, link: &Option<String>) -> MessageRun {
    MessageRun {
        is_emoji: false,
        text: SharedString::from(text),
        clip_x: 0,
        clip_y: 0,
        bold: style.bold,
        italic: style.italic,
        strike: style.strike,
        code: style.code,
        link: link.as_deref().map(SharedString::from).unwrap_or_default(),
        fx: style.fx as i32,
        // Assigned in a second pass over the finished runs (md_assign_phases).
        phase: 0.0,
        mention: style.mention,
        mention_a: style.mention_a,
        mention_b: style.mention_b,
    }
}

pub(crate) fn md_run_emoji(text: &str, x: u32, y: u32, fx: u8) -> MessageRun {
    MessageRun {
        is_emoji: true,
        text: SharedString::from(text),
        clip_x: x as i32,
        clip_y: y as i32,
        bold: false,
        italic: false,
        strike: false,
        code: false,
        link: SharedString::new(),
        fx: fx as i32,
        phase: 0.0,
        mention: false,
        mention_a: Color::default(),
        mention_b: Color::default(),
    }
}

/// Shorten a long bech32 (or any) string to `head…tail` for ergonomic display.
pub(crate) fn md_shorten(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= 18 {
        return s.to_string();
    }
    let head: String = chars[..12].iter().collect();
    let tail: String = chars[chars.len() - 4..].iter().collect();
    format!("{head}…{tail}")
}

/// Tokenize a raw text run into words / whitespace / (optionally) emoji,
/// tagging each with the active style + link. Emoji probing is skipped for
/// code spans, where glyph sequences must stay literal.
pub(crate) fn md_push_text(
    out: &mut Vec<MdTok>,
    text: &str,
    style: MdStyle,
    link: &Option<String>,
    positions: &std::collections::HashMap<&'static str, (u32, u32)>,
    probe_emoji: bool,
) {
    let mut buf = String::new();
    let mut buf_space = false;
    let flush = |buf: &mut String, is_space: &mut bool, out: &mut Vec<MdTok>| {
        if buf.is_empty() {
            return;
        }
        let taken = std::mem::take(buf);
        if *is_space {
            out.push(MdTok::Space {
                text: taken,
                style,
                link: link.clone(),
            });
        } else {
            out.push(MdTok::Word {
                text: taken,
                style,
                link: link.clone(),
            });
        }
        *is_space = false;
    };

    let mut i = 0;
    while i < text.len() {
        if probe_emoji {
            // Probe for the longest emoji match at `i`. ZWJ sequences can be
            // ~30+ bytes; 48 is a comfortable cap.
            let end_max = (i + 48).min(text.len());
            let mut matched: Option<(usize, u32, u32)> = None;
            for end in (i + 1..=end_max).rev() {
                if !text.is_char_boundary(end) {
                    continue;
                }
                if let Some(&(x, y)) = positions.get(&text[i..end]) {
                    matched = Some((end, x, y));
                    break;
                }
            }
            if let Some((end, x, y)) = matched {
                flush(&mut buf, &mut buf_space, out);
                out.push(MdTok::Emoji {
                    text: text[i..end].to_string(),
                    x,
                    y,
                    fx: style.fx,
                });
                i = end;
                continue;
            }
        }
        let c = text[i..].chars().next().unwrap();
        let clen = c.len_utf8();
        if c.is_whitespace() {
            if !buf_space {
                flush(&mut buf, &mut buf_space, out);
                buf_space = true;
            }
            buf.push(c);
        } else {
            if buf_space {
                flush(&mut buf, &mut buf_space, out);
            }
            buf.push(c);
            // Effect runs render per-letter so motion effects (ripple, jitter,
            // shake…) animate each glyph independently, like iMessage. Flush
            // after every visible character so each becomes its own run/cell.
            if style.has_fx() {
                flush(&mut buf, &mut buf_space, out);
            }
        }
        i += clen;
    }
    flush(&mut buf, &mut buf_space, out);
}

/// Emit a nostr entity as a single linkified word. Profile entities
/// (npub/nprofile) resolve to a name chip: the nickname or published name on
/// an avatar-gradient plate, "@"-prefixed only when the account is a member
/// of the group being rendered (so readers can tell members from outsiders).
/// Unresolvable names — and every non-profile entity — fall back to the
/// shortened bech32. The `nostr:` link is emitted unchanged either way, so a
/// tap still opens the in-app profile modal.
pub(crate) fn md_push_nostr(out: &mut Vec<MdTok>, e: &NostrEntity, style: MdStyle, mention: bool) {
    if let Some(chip) = mention_chip_for(&e.bech32) {
        let name = chip.name.unwrap_or_else(|| md_shorten(&e.bech32));
        let display = if chip.in_group {
            format!("@{name}")
        } else {
            name
        };
        out.push(MdTok::Word {
            text: display,
            style: MdStyle {
                mention: true,
                // Bold like the sender-name label: the name is the payload
                // and it thickens the white glyphs over the tinted plate.
                bold: true,
                mention_a: chip.color_a,
                mention_b: chip.color_b,
                ..style
            },
            link: Some(format!("nostr:{}", e.bech32)),
        });
        return;
    }
    let mut display = md_shorten(&e.bech32);
    if mention {
        display = format!("@{display}");
    }
    out.push(MdTok::Word {
        text: display,
        style,
        link: Some(format!("nostr:{}", e.bech32)),
    });
}

/// Recursively flatten inline AST nodes into styled tokens.
pub(crate) fn md_walk_inlines(
    out: &mut Vec<MdTok>,
    inlines: &[Inline],
    style: MdStyle,
    link: Option<String>,
    positions: &std::collections::HashMap<&'static str, (u32, u32)>,
) {
    for inl in inlines {
        match inl {
            Inline::Text(s) => md_push_text(out, s, style, &link, positions, true),
            Inline::SoftBreak | Inline::HardBreak => out.push(MdTok::Break),
            Inline::Code(s) => {
                let st = MdStyle {
                    code: true,
                    ..style
                };
                md_push_text(out, s, st, &link, positions, false);
            }
            Inline::Emph(c) => md_walk_inlines(
                out,
                c,
                MdStyle {
                    italic: true,
                    ..style
                },
                link.clone(),
                positions,
            ),
            Inline::Strong(c) => md_walk_inlines(
                out,
                c,
                MdStyle {
                    bold: true,
                    ..style
                },
                link.clone(),
                positions,
            ),
            Inline::Strikethrough(c) => md_walk_inlines(
                out,
                c,
                MdStyle {
                    strike: true,
                    ..style
                },
                link.clone(),
                positions,
            ),
            Inline::Link { dest, children, .. } => {
                md_walk_inlines(out, children, style, Some(dest.clone()), positions)
            }
            Inline::Image { dest, alt, .. } => {
                let l = Some(dest.clone());
                md_push_text(out, "🖼", style, &l, positions, true);
                md_push_text(out, " ", style, &l, positions, false);
                if alt.is_empty() {
                    md_push_text(out, dest, style, &l, positions, false);
                } else {
                    md_walk_inlines(out, alt, style, l, positions);
                }
            }
            Inline::Autolink { url, .. } => {
                md_push_text(out, url, style, &Some(url.clone()), positions, false)
            }
            Inline::Math(s) => {
                let st = MdStyle {
                    code: true,
                    ..style
                };
                md_push_text(out, s, st, &link, positions, false);
            }
            Inline::NostrMention(e) => md_push_nostr(out, e, style, true),
            Inline::NostrUri(e) => md_push_nostr(out, e, style, false),
            Inline::Effect { name, children } => {
                // Set the matching channel (size or motion) on top of the
                // inherited style, so nesting stacks instead of overwriting.
                // Unknown names leave both channels untouched → pass-through.
                let mut st = style;
                apply_effect(&mut st, name);
                md_walk_inlines(out, children, st, link.clone(), positions);
            }
        }
    }
}

/// Font scale for an ATX heading level.
pub(crate) fn md_heading_scale(level: u8) -> f32 {
    match level {
        1 => 1.5,
        2 => 1.34,
        3 => 1.2,
        4 => 1.1,
        _ => 1.04,
    }
}

/// A thin blank line used to separate sibling blocks.
pub(crate) fn md_spacer(ctx: MdCtx) -> MdLine {
    MdLine {
        runs: vec![md_run_text(" ", MdStyle::default(), &None)],
        indent: ctx.indent,
        scale: 0.4,
        quote: ctx.quote,
        code_block: false,
        rule: false,
        hard_break: true,
    }
}

/// Greedy-pack a token stream into wrapped lines under `max_width` (minus the
/// block indent). Over-long single tokens (URLs, code) are hard-split so they
/// never overflow the bubble.
pub(crate) fn md_wrap(
    out: &mut Vec<MdLine>,
    toks: Vec<MdTok>,
    env: MdEnv,
    indent: f32,
    scale: f32,
    quote: i32,
    code_block: bool,
) {
    let char_w = env.base_fs * MD_CHAR_W * scale;
    let emoji_w = env.base_fs * MD_EMOJI_W * scale;
    let avail = (env.max_width - indent).max(40.0);
    let max_chars = ((avail / char_w).floor() as usize).max(1);

    let mut cur: Vec<MessageRun> = Vec::new();
    let mut x = 0.0f32;
    // Whether the line currently accumulating in `cur` starts a new logical
    // line. The first line of the block does; a line opened by a width-driven
    // wrap (or a hard-split chunk) is a continuation of the previous one.
    let mut hard = true;
    let flush = |out: &mut Vec<MdLine>, cur: &mut Vec<MessageRun>, hard: &mut bool, next: bool| {
        out.push(MdLine {
            runs: std::mem::take(cur),
            indent,
            scale,
            quote,
            code_block,
            rule: false,
            hard_break: *hard,
        });
        *hard = next;
    };

    for tok in toks {
        match tok {
            MdTok::Break => {
                flush(out, &mut cur, &mut hard, true);
                x = 0.0;
            }
            MdTok::Space { text, style, link } => {
                // Drop whitespace at the start of a wrapped line — except in
                // code blocks, where leading indentation is significant.
                if x == 0.0 && !code_block {
                    continue;
                }
                x += text.chars().count() as f32 * char_w;
                cur.push(md_run_text(&text, style, &link));
            }
            MdTok::Emoji {
                text,
                x: ex,
                y: ey,
                fx,
            } => {
                if x > 0.0 && x + emoji_w > avail {
                    flush(out, &mut cur, &mut hard, false);
                    x = 0.0;
                }
                cur.push(md_run_emoji(&text, ex, ey, fx));
                x += emoji_w;
            }
            MdTok::Word { text, style, link } => {
                let n = text.chars().count();
                let pad = if style.mention { MD_MENTION_PAD } else { 0.0 };
                let w = n as f32 * char_w + pad;
                if w <= avail {
                    if x > 0.0 && x + w > avail {
                        flush(out, &mut cur, &mut hard, false);
                        x = 0.0;
                    }
                    cur.push(md_run_text(&text, style, &link));
                    x += w;
                } else {
                    // Hard-split an over-long token into width-fitting chunks.
                    let chars: Vec<char> = text.chars().collect();
                    let mut start = 0;
                    while start < chars.len() {
                        if x > 0.0 {
                            flush(out, &mut cur, &mut hard, false);
                            x = 0.0;
                        }
                        let end = (start + max_chars).min(chars.len());
                        let chunk: String = chars[start..end].iter().collect();
                        cur.push(md_run_text(&chunk, style, &link));
                        x += (end - start) as f32 * char_w;
                        start = end;
                    }
                }
            }
        }
    }
    if !cur.is_empty() {
        flush(out, &mut cur, &mut hard, true);
    }
}

/// Render one table row as a wrapped line, cells separated by a thin divider.
pub(crate) fn md_emit_table_row(
    out: &mut Vec<MdLine>,
    cells: &[whitenoise_markdown::TableCell],
    header: bool,
    ctx: MdCtx,
    env: MdEnv,
) {
    let mut toks = Vec::new();
    for (ci, cell) in cells.iter().enumerate() {
        if ci > 0 {
            toks.push(MdTok::Word {
                text: "│".to_string(),
                style: MdStyle::default(),
                link: None,
            });
            toks.push(MdTok::Space {
                text: " ".to_string(),
                style: MdStyle::default(),
                link: None,
            });
        }
        md_walk_inlines(
            &mut toks,
            &cell.inlines,
            MdStyle {
                bold: header,
                ..Default::default()
            },
            None,
            env.positions,
        );
        toks.push(MdTok::Space {
            text: " ".to_string(),
            style: MdStyle::default(),
            link: None,
        });
    }
    md_wrap(out, toks, env, ctx.indent, 1.0, ctx.quote, false);
}

/// Render the items of a list, placing each item's marker on its first line and
/// indenting wrapped / nested content under it.
pub(crate) fn md_walk_list(
    out: &mut Vec<MdLine>,
    kind: ListKind,
    tight: bool,
    items: &[ListItem],
    ctx: MdCtx,
    env: MdEnv,
) {
    let mut number = match kind {
        ListKind::Ordered { start, .. } => start,
        ListKind::Bullet { .. } => 0,
    };
    for (ii, item) in items.iter().enumerate() {
        if ii > 0 && !tight {
            out.push(md_spacer(ctx));
        }
        let mut marker = match kind {
            ListKind::Ordered { .. } => {
                let m = format!("{number}. ");
                number += 1;
                m
            }
            ListKind::Bullet { .. } => "•  ".to_string(),
        };
        if let Some(checked) = item.checked {
            marker.push_str(if checked { "☑ " } else { "☐ " });
        }
        let marker_w = marker.chars().count() as f32 * env.base_fs * MD_CHAR_W;
        let child = MdCtx {
            indent: ctx.indent + marker_w,
            quote: ctx.quote,
        };
        let mut tmp: Vec<MdLine> = Vec::new();
        md_walk_blocks(&mut tmp, &item.blocks, child, env);
        if tmp.is_empty() {
            tmp.push(MdLine {
                runs: Vec::new(),
                indent: child.indent,
                scale: 1.0,
                quote: ctx.quote,
                code_block: false,
                rule: false,
                hard_break: true,
            });
        }
        // The marker sits at the item's own indent; content trails after it.
        tmp[0].indent = ctx.indent;
        tmp[0]
            .runs
            .insert(0, md_run_text(&marker, MdStyle::default(), &None));
        out.extend(tmp);
    }
}

/// Recursively flatten block AST nodes into wrapped, context-tagged lines.
pub(crate) fn md_walk_blocks(out: &mut Vec<MdLine>, blocks: &[Block], ctx: MdCtx, env: MdEnv) {
    for (bi, b) in blocks.iter().enumerate() {
        if bi > 0 {
            out.push(md_spacer(ctx));
        }
        match b {
            Block::Paragraph { inlines } => {
                let mut toks = Vec::new();
                md_walk_inlines(&mut toks, inlines, MdStyle::default(), None, env.positions);
                md_wrap(out, toks, env, ctx.indent, 1.0, ctx.quote, false);
            }
            Block::Heading { level, inlines } => {
                let mut toks = Vec::new();
                md_walk_inlines(
                    &mut toks,
                    inlines,
                    MdStyle {
                        bold: true,
                        ..Default::default()
                    },
                    None,
                    env.positions,
                );
                md_wrap(
                    out,
                    toks,
                    env,
                    ctx.indent,
                    md_heading_scale(*level),
                    ctx.quote,
                    false,
                );
            }
            Block::ThematicBreak => out.push(MdLine {
                runs: Vec::new(),
                indent: ctx.indent,
                scale: 1.0,
                quote: ctx.quote,
                code_block: false,
                rule: true,
                hard_break: true,
            }),
            Block::CodeBlock { content, .. } => {
                let body = content.strip_suffix('\n').unwrap_or(content);
                let st = MdStyle {
                    code: true,
                    ..Default::default()
                };
                for line in body.split('\n') {
                    if line.is_empty() {
                        out.push(MdLine {
                            runs: vec![md_run_text(" ", st, &None)],
                            indent: ctx.indent,
                            scale: 1.0,
                            quote: ctx.quote,
                            code_block: true,
                            rule: false,
                            hard_break: true,
                        });
                        continue;
                    }
                    let mut toks = Vec::new();
                    md_push_text(&mut toks, line, st, &None, env.positions, false);
                    md_wrap(out, toks, env, ctx.indent, 1.0, ctx.quote, true);
                }
            }
            Block::BlockQuote { blocks } => {
                let inner = MdCtx {
                    indent: ctx.indent + 12.0,
                    quote: ctx.quote + 1,
                };
                md_walk_blocks(out, blocks, inner, env);
            }
            Block::List { kind, tight, items } => {
                md_walk_list(out, *kind, *tight, items, ctx, env);
            }
            Block::Table { header, rows, .. } => {
                md_emit_table_row(out, header, true, ctx, env);
                for row in rows {
                    md_emit_table_row(out, row, false, ctx, env);
                }
            }
            Block::MathBlock { content } => {
                let body = content.strip_suffix('\n').unwrap_or(content);
                let st = MdStyle {
                    code: true,
                    ..Default::default()
                };
                for line in body.split('\n') {
                    let mut toks = Vec::new();
                    md_push_text(&mut toks, line, st, &None, env.positions, false);
                    md_wrap(out, toks, env, ctx.indent, 1.0, ctx.quote, true);
                }
            }
        }
    }
}

/// Parse a chat-message body as Markdown and flatten it into pre-wrapped lines.
/// Second pass over finished runs: stagger each effect run's `phase` so motion
/// effects animate per-letter rather than in lockstep. The counter advances
/// once per effect cell (giving Ripple its travelling crest and Jitter its
/// decorrelated wobble) and resets on any non-effect run so each contiguous
/// span starts its wave fresh.
pub(crate) fn md_assign_phases(lines: &mut [MdLine]) {
    let mut step: u32 = 0;
    for line in lines.iter_mut() {
        for run in line.runs.iter_mut() {
            if run.fx != 0 {
                run.phase = step as f32 * 0.12;
                step += 1;
            } else {
                step = 0;
            }
        }
    }
}

pub(crate) fn tokenize_message_lines(text: &str, max_width: f32, base_fs: f32) -> Vec<MessageLine> {
    let positions = emoji_position_index();
    let doc = whitenoise_markdown::parse(text);
    let mut lines: Vec<MdLine> = Vec::new();
    let env = MdEnv {
        max_width,
        base_fs,
        positions,
    };
    md_walk_blocks(
        &mut lines,
        &doc.blocks,
        MdCtx {
            indent: 0.0,
            quote: 0,
        },
        env,
    );
    md_assign_phases(&mut lines);
    // The selection edge claims live on the outermost lines that render run
    // cells; rules and empty lines render none (see MessageLine in
    // tokens.slint).
    let first_content = lines.iter().position(|l| !l.runs.is_empty());
    let last_content = lines.iter().rposition(|l| !l.runs.is_empty());
    lines
        .into_iter()
        .enumerate()
        .map(|(i, l)| MessageLine {
            runs: ModelRc::new(VecModel::from(l.runs)),
            indent: l.indent,
            scale: l.scale,
            quote: l.quote,
            code_block: l.code_block,
            rule: l.rule,
            hard_break: l.hard_break,
            first_content: Some(i) == first_content,
            last_content: Some(i) == last_content,
        })
        .collect()
}

/// Expand a document position (line, run, fraction of the run's width) to the
/// word around it, returned as a (start, end) fraction pair within the same
/// run. Word boundaries come from ICU segmentation, whose dictionary/LSTM
/// models segment unspaced scripts (Japanese, Chinese, Thai) that character
/// classes cannot; an emoji run is one atomic word. `None` when the position
/// does not resolve to a non-empty run.
pub(crate) fn word_span_at(
    lines: &ModelRc<MessageLine>,
    line: i32,
    run: i32,
    frac: f32,
) -> Option<(f32, f32)> {
    if line < 0 || run < 0 {
        return None;
    }
    let l = lines.row_data(line as usize)?;
    let r = l.runs.row_data(run as usize)?;
    if r.is_emoji {
        return Some((0.0, 1.0));
    }
    let text = r.text.as_str();
    let n = text.chars().count();
    if n == 0 {
        return None;
    }
    // The fraction maps to a character with the wrapper's uniform-advance
    // assumption; the segmenter works in byte offsets.
    let idx = ((frac * n as f32).floor() as usize).min(n - 1);
    let byte_idx = text
        .char_indices()
        .nth(idx)
        .map(|(b, _)| b)
        .unwrap_or_default();
    // Borrowed segmenter over compiled data: construction is free, so no
    // caching is needed for a per-double-click call.
    let seg = icu_segmenter::WordSegmenter::new_auto(Default::default());
    let mut start_b = 0usize;
    let mut end_b = text.len();
    for boundary in seg.segment_str(text) {
        if boundary <= byte_idx {
            start_b = boundary;
        } else {
            end_b = boundary;
            break;
        }
    }
    let start = text[..start_b].chars().count();
    let end = text[..end_b].chars().count();
    Some((start as f32 / n as f32, end as f32 / n as f32))
}

/// Character count of a run in selection units. Emoji runs are atomic: one
/// unit covering the whole (possibly multi-scalar ZWJ) sequence.
fn run_char_count(run: &MessageRun) -> usize {
    if run.is_emoji {
        1
    } else {
        run.text.chars().count()
    }
}

/// Slice `[from, to)` selection units out of a run's text.
fn run_slice(run: &MessageRun, from: usize, to: usize) -> String {
    if from >= to {
        return String::new();
    }
    if run.is_emoji {
        return run.text.to_string();
    }
    run.text.chars().skip(from).take(to - from).collect()
}

/// Extract the text between two document endpoints of a message's pre-wrapped
/// line model. An endpoint is (visual line index, run index, fraction of the
/// run's width); the fraction maps to a character boundary with the same
/// uniform-advance assumption the wrapper uses, so the copied range tracks the
/// painted highlight. Endpoints arrive unordered (anchor vs cursor); a
/// negative index means the endpoint was never resolved — nothing to copy.
pub(crate) fn extract_selection(
    lines: &ModelRc<MessageLine>,
    a: (i32, i32, f32),
    b: (i32, i32, f32),
) -> String {
    if a.0 < 0 || a.1 < 0 || b.0 < 0 || b.1 < 0 {
        return String::new();
    }
    let key = |p: (i32, i32, f32)| (p.0, p.1, (p.2 * 1e6) as i64);
    let (start, end) = if key(a) <= key(b) { (a, b) } else { (b, a) };
    let last_line = match lines.row_count() {
        0 => return String::new(),
        n => n - 1,
    };
    let mut out = String::new();
    for li in (start.0.max(0) as usize)..=(end.0.max(0) as usize).min(last_line) {
        let Some(line) = lines.row_data(li) else {
            continue;
        };
        // Separator before this visual line: a newline when it starts a new
        // logical line, nothing for a soft wrap (the inter-word space already
        // sits at the end of the previous visual line).
        if li as i32 > start.0 && line.hard_break {
            out.push('\n');
        }
        if line.rule {
            continue;
        }
        let mut line_text = String::new();
        let n_runs = line.runs.row_count();
        for ri in 0..n_runs {
            let Some(run) = line.runs.row_data(ri) else {
                continue;
            };
            let n = run_char_count(&run);
            let mut from = 0usize;
            let mut to = n;
            if li as i32 == start.0 {
                if (ri as i32) < start.1 {
                    continue;
                }
                if ri as i32 == start.1 {
                    from = ((start.2 * n as f32).round() as usize).min(n);
                }
            }
            if li as i32 == end.0 {
                if (ri as i32) > end.1 {
                    break;
                }
                if ri as i32 == end.1 {
                    to = ((end.2 * n as f32).round() as usize).min(n);
                }
            }
            line_text.push_str(&run_slice(&run, from, to));
        }
        // Whitespace-only lines are the spacer rows between blocks (and blank
        // code lines); they contribute their newline but no padding chars.
        // Content lines keep trailing spaces — significant inside code blocks.
        if !line_text.trim().is_empty() {
            out.push_str(&line_text);
        }
    }
    out.trim_matches('\n').to_string()
}

/// Open a URL (or `mailto:` / `nostr:` URI) with the platform's default
/// handler. Fire-and-forget; failures are logged, not surfaced.
pub(crate) fn open_external(url: &str) {
    if url.is_empty() {
        return;
    }
    #[cfg(target_os = "macos")]
    let program = "open";
    #[cfg(not(target_os = "macos"))]
    let program = "xdg-open";
    match std::process::Command::new(program).arg(url).spawn() {
        Ok(_) => tracing::debug!(url, "opened external link"),
        Err(e) => tracing::warn!(url, error = %e, "failed to open external link"),
    }
}

/// Find an active `@mention` token ending at the caret. Returns the byte offset
/// of the `@` and the query text between it and the caret. The token is active
/// only when the `@` sits at the start or directly after whitespace, and there
/// is no whitespace between it and the caret.
pub(crate) fn detect_mention(text: &str, cursor: usize) -> Option<(usize, String)> {
    if cursor > text.len() || !text.is_char_boundary(cursor) {
        return None;
    }
    let prefix = &text[..cursor];
    let mut at_byte = None;
    for (i, c) in prefix.char_indices().rev() {
        if c == '@' {
            let preceded_ok = i == 0
                || prefix[..i]
                    .chars()
                    .next_back()
                    .map(|p| p.is_whitespace())
                    .unwrap_or(true);
            if preceded_ok {
                at_byte = Some(i);
            }
            break;
        }
        if c.is_whitespace() {
            break;
        }
    }
    let at = at_byte?;
    Some((at, prefix[at + 1..].to_string()))
}

/// Filter the open chat's members by a mention query (matches display name,
/// short npub, or full npub; an empty query lists everyone). Capped at 50.
pub(crate) fn filter_mention_candidates(ui: &DarkMatterLinux, query: &str) -> Vec<GroupMember> {
    let q = query.to_lowercase();
    ui.get_chat_members()
        .iter()
        .filter(|m| {
            if q.is_empty() {
                return true;
            }
            if m.name.as_str().to_lowercase().contains(&q)
                || m.npub_short.as_str().to_lowercase().contains(&q)
            {
                return true;
            }
            npub_for_account_id(m.member_id.as_str())
                .map(|n| n.to_lowercase().contains(&q))
                .unwrap_or(false)
        })
        .take(50)
        .collect()
}

/// Splice the chosen member's npub over the active `@token` and place the caret
/// just after the inserted mention.
pub(crate) fn commit_mention(
    ui: &DarkMatterLinux,
    mention_span: &Rc<RefCell<Option<(usize, usize)>>>,
    index: i32,
) {
    ui.set_mention_active(false);
    let Some((at, end)) = mention_span.borrow_mut().take() else {
        return;
    };
    if index < 0 {
        return;
    }
    let cands = ui.get_mention_candidates();
    let Some(member) = cands.row_data(index as usize) else {
        return;
    };
    let npub = npub_for_account_id(member.member_id.as_str())
        .unwrap_or_else(|_| member.member_id.to_string());
    let mut draft = ui.get_composer_draft().to_string();
    if at > end || end > draft.len() || !draft.is_char_boundary(at) || !draft.is_char_boundary(end)
    {
        return;
    }
    let insert = format!("@{npub} ");
    let new_cursor = at + insert.len();
    draft.replace_range(at..end, &insert);
    ui.set_composer_draft(draft.into());
    // Move the caret past the inserted mention (tick forces re-apply).
    ui.set_composer_caret_pos(new_cursor as i32);
    ui.set_composer_caret_tick(ui.get_composer_caret_tick().wrapping_add(1));
}

// The size the chat bubble actually draws its body text at, in logical pixels
// — the live value of `Theme.body-fs`, pushed from the window root through
// `AppState.body-fs-changed` every time the theme id changes.
//
// The greedy wrapper derives its per-character width estimate from this
// (`env.base_fs * MD_CHAR_W`), so it has to track the theme: a `pixel-metrics`
// theme resolves `Theme.fs(13px, 16px)` to 16px, and wrapping those lines
// against 13px packs them about a quarter too wide for the bubble. UI-thread
// only, like the line cache it keys.
thread_local! {
    static BODY_FS: std::cell::Cell<f32> = const { std::cell::Cell::new(DEFAULT_BODY_FS) };
}

/// The non-pixel-metrics body size — the `modern` half of the bubble's
/// `Theme.fs(13px, 16px)`. Only the value before the first push; every theme
/// (including the default one) re-states it through `body-fs-changed`.
pub(crate) const DEFAULT_BODY_FS: f32 = 13.0;

pub(crate) fn body_fs() -> f32 {
    BODY_FS.with(|c| c.get())
}

/// Record the theme's body size. Returns whether it moved, so the caller can
/// skip re-wrapping the rendered rows when a theme switch leaves the metric
/// alone (every non-pixel-metrics theme resolves to the same size).
pub(crate) fn set_body_fs(px: f32) -> bool {
    BODY_FS.with(|c| {
        if (c.get() - px).abs() < 0.01 {
            return false;
        }
        c.set(px);
        true
    })
}

// Memoized markdown line models, keyed by (body, wrap-width, body-size).
// Rebuilding a
// chat re-parses every visible body through the full markdown → wrap pipeline;
// bodies are immutable (edits arrive as new text → new key), so the flattened
// model can be shared across rows and rebuilds. UI-thread only (the line
// models hold `ModelRc`s, which are not `Send`). Bounded: wholesale-cleared
// at the cap rather than LRU-tracked — a full re-parse of one chat is cheap
// compared to bookkeeping on every hit.
thread_local! {
    static MESSAGE_LINES_CACHE: RefCell<HashMap<(String, u32, u32), ModelRc<MessageLine>>> =
        RefCell::new(HashMap::new());
}
pub(crate) const MESSAGE_LINES_CACHE_CAP: usize = 4096;

/// Build the `lines` model for `ChatMessage` from the message body.
pub(crate) fn build_message_lines(text: &str, bubble_max: f32) -> ModelRc<MessageLine> {
    // Chat-body chrome: 2*pad-h (14) + gap (12) + meta col (~70). Conservative
    // so wrapping kicks in before the dynamic `available-w` clips the bubble.
    let budget = (bubble_max - 110.0).max(60.0);
    // Part of the key: the same body at the same width wraps differently once
    // the theme moves the body size, so a cached model from the previous theme
    // must not answer for the new one.
    let base_fs = body_fs();
    MESSAGE_LINES_CACHE.with(|cache| {
        let key = (text.to_string(), budget.to_bits(), base_fs.to_bits());
        if let Some(model) = cache.borrow().get(&key) {
            return model.clone();
        }
        let model: ModelRc<MessageLine> = ModelRc::new(VecModel::from(tokenize_message_lines(
            text, budget, base_fs,
        )));
        let mut cache = cache.borrow_mut();
        if cache.len() >= MESSAGE_LINES_CACHE_CAP {
            cache.clear();
        }
        cache.insert(key, model.clone());
        model
    })
}

/// Telegram-style jumbo-emoji test. If `text` is nothing but emoji (plus
/// whitespace) and short enough — at most [`JUMBO_EMOJI_MAX`] glyphs — return
/// the emoji count; otherwise 0. The probe mirrors the tokenizer's longest-
/// match-against-the-sprite-table logic ([`md_push_text`]) so what we classify
/// as jumbo is exactly what would render as sprite cells.
pub(crate) const JUMBO_EMOJI_MAX: u32 = 3;
pub(crate) fn jumbo_emoji_count(text: &str) -> u32 {
    let positions = emoji_position_index();
    let t = text.trim();
    if t.is_empty() {
        return 0;
    }
    let mut count = 0u32;
    let mut i = 0usize;
    while i < t.len() {
        let c = t[i..].chars().next().unwrap();
        if c.is_whitespace() {
            i += c.len_utf8();
            continue;
        }
        // Longest emoji match at `i` (ZWJ sequences run ~30+ bytes; 48 caps it).
        let end_max = (i + 48).min(t.len());
        let mut matched = None;
        for end in (i + 1..=end_max).rev() {
            if t.is_char_boundary(end) && positions.contains_key(&t[i..end]) {
                matched = Some(end);
                break;
            }
        }
        match matched {
            Some(end) => {
                count += 1;
                if count > JUMBO_EMOJI_MAX {
                    return 0;
                }
                i = end;
            }
            // Any non-emoji glyph disqualifies the whole message.
            None => return 0,
        }
    }
    count
}

/// Filter the full emoji catalog by `query` (matches name + shortcodes,
/// lowercased substring) and return the flat list. The Slint side handles
/// column packing and virtualization.
pub(crate) fn build_emoji_list(query: &str) -> Vec<EmojiEntry> {
    let q = query.trim().to_lowercase();
    let positions = emoji_position_index();
    let mut hits: Vec<EmojiEntry> = Vec::new();
    for e in emojis::iter() {
        if !q.is_empty() {
            let name_match = e.name().to_lowercase().contains(&q);
            let code_match = e.shortcodes().any(|c| c.to_lowercase().contains(&q));
            if !name_match && !code_match {
                continue;
            }
        }
        // Skip emojis the build-time sprite sheet doesn't cover.
        let Some(&(x, y)) = positions.get(e.as_str()) else {
            continue;
        };
        hits.push(EmojiEntry {
            emoji: s(e.as_str()),
            name: s(e.name()),
            clip_x: x as i32,
            clip_y: y as i32,
        });
    }
    hits
}
