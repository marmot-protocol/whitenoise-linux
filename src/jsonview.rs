//! Tokenizer + fold state for the shared debug JSON viewer
//! (`primitives/json-view.slint`).
//!
//! Slint has no rich text, so — like the chat body's markdown pipeline — the
//! coloring happens here: pretty-printed JSON becomes `JsonLine` rows of
//! `JsonRun` cells, each run tagged with a kind the component maps to a
//! palette color. Containers (`{…}` / `[…]`) are collapsible: the viewer
//! reports a chevron click via its `toggle` callback, the per-surface doc
//! state here flips the fold and hands back the rebuilt visible rows. Input
//! that isn't JSON (error strings, mixed dumps) falls out of the lexer as
//! plain punctuation-colored runs, so every caller can feed whatever it has.
//!
//! UI-thread only (rows are `ModelRc`, and the fold state is thread-local) —
//! every caller already runs inside the event loop.

use crate::*;
use std::cell::RefCell;

// Run kinds — must match the color map in ui/primitives/json-view.slint.
const K_PUNCT: i32 = 0;
const K_KEY: i32 = 1;
const K_STR: i32 = 2;
const K_NUM: i32 = 3;
const K_WORD: i32 = 4;

/// Columns before a line is wrapped onto a continuation line. The viewer has
/// no horizontal scroll (it would break ListView virtualization), and real
/// dumps carry base64/hex blobs hundreds of characters long; wrapping them
/// Rust-side keeps every line renderable. Sized to the 560px modal.
const WRAP_COLS: usize = 60;

/// Which surface's fold state a call addresses. Each keeps its own document
/// so collapsing in the Debug pane can't fold the raw-event modal.
#[derive(Copy, Clone, PartialEq, Eq, Hash)]
pub(crate) enum JsonSlot {
    /// The DebugJsonModal (raw event / key packages / KP inspector).
    View,
    /// The Settings → Debug pane dump area.
    Dump,
}

type Runs = Vec<(String, i32)>;

struct JsonDoc {
    /// Token runs per logical (pre-wrap) line.
    lines: Vec<Runs>,
    /// open-line index → matching close-line index, for lines that open a
    /// container which closes on a *different* line (the collapsible ones).
    close_of: HashMap<usize, usize>,
    /// Logical line indices currently folded.
    collapsed: HashSet<usize>,
}

thread_local! {
    static DOCS: RefCell<HashMap<JsonSlot, JsonDoc>> = RefCell::new(HashMap::new());
}

/// Parse `text` into `slot`'s document (resetting any fold state) and return
/// the visible rows.
pub(crate) fn json_doc_set(slot: JsonSlot, text: &str) -> ModelRc<JsonLine> {
    let lines: Vec<Runs> = text.lines().map(tokenize_line).collect();
    let close_of = match_brackets(&lines);
    let doc = JsonDoc {
        lines,
        close_of,
        collapsed: HashSet::new(),
    };
    let rows = visible_rows(&doc);
    DOCS.with(|d| d.borrow_mut().insert(slot, doc));
    rows
}

/// Flip one container's fold and return the rebuilt visible rows. Unknown
/// indices (or a slot never filled) return the current state unchanged.
pub(crate) fn json_doc_toggle(slot: JsonSlot, logical: i32) -> ModelRc<JsonLine> {
    DOCS.with(|d| {
        let mut docs = d.borrow_mut();
        let Some(doc) = docs.get_mut(&slot) else {
            return ModelRc::new(VecModel::from(Vec::<JsonLine>::new()));
        };
        let idx = logical as usize;
        if doc.close_of.contains_key(&idx) && !doc.collapsed.remove(&idx) {
            doc.collapsed.insert(idx);
        }
        visible_rows(doc)
    })
}

/// Walk the document, emitting expanded lines (wrapped) and one summary line
/// per folded container, skipping everything a fold hides.
fn visible_rows(doc: &JsonDoc) -> ModelRc<JsonLine> {
    let mut rows: Vec<JsonLine> = Vec::new();
    let mut i = 0usize;
    while i < doc.lines.len() {
        let collapsible = doc.close_of.contains_key(&i);
        if collapsible && doc.collapsed.contains(&i) {
            let close = doc.close_of[&i];
            rows.extend(build_rows(
                summary_runs(doc, i, close),
                i,
                true,
                true,
            ));
            i = close + 1;
            continue;
        }
        rows.extend(build_rows(doc.lines[i].clone(), i, collapsible, false));
        i += 1;
    }
    ModelRc::new(VecModel::from(rows))
}

/// `{ … n lines … }` — the folded form: the open line's runs, an elision
/// marker with the hidden count, then the close line's (trimmed) brackets.
fn summary_runs(doc: &JsonDoc, open: usize, close: usize) -> Runs {
    let mut runs = doc.lines[open].clone();
    let hidden = close.saturating_sub(open + 1);
    runs.push((format!(" … {hidden} lines … "), K_PUNCT));
    for (text, kind) in &doc.lines[close] {
        let trimmed = text.trim_start();
        if !trimmed.is_empty() {
            runs.push((trimmed.to_string(), *kind));
        }
    }
    runs
}

/// Wrap one logical line into `JsonLine` rows. Only the first visual line
/// carries the line number and the fold affordance; continuations render
/// with a blank gutter and ignore clicks (`logical` still points home).
fn build_rows(runs: Runs, logical: usize, collapsible: bool, collapsed: bool) -> Vec<JsonLine> {
    wrap_runs(runs)
        .into_iter()
        .enumerate()
        .map(|(v, visual)| {
            let first = v == 0;
            let cells: Vec<JsonRun> = visual
                .into_iter()
                .map(|(t, k)| JsonRun { text: s(&t), kind: k })
                .collect();
            JsonLine {
                runs: ModelRc::new(VecModel::from(cells)),
                num: if first { logical as i32 + 1 } else { 0 },
                logical: logical as i32,
                collapsible: collapsible && first,
                collapsed,
            }
        })
        .collect()
}

/// Match container brackets across logical lines, scanning only punctuation
/// runs (string/key runs are separate tokens, so brackets inside string
/// values can't miscount). When a line opens several containers that close
/// elsewhere, the outermost wins — folding collapses the whole construct.
fn match_brackets(lines: &[Runs]) -> HashMap<usize, usize> {
    let mut close_of: HashMap<usize, usize> = HashMap::new();
    let mut stack: Vec<usize> = Vec::new();
    for (i, runs) in lines.iter().enumerate() {
        for (text, kind) in runs {
            if *kind != K_PUNCT {
                continue;
            }
            for c in text.chars() {
                match c {
                    '{' | '[' => stack.push(i),
                    '}' | ']' => {
                        if let Some(open) = stack.pop()
                            && open != i
                        {
                            // Overwrite on purpose: outer brackets pop later.
                            close_of.insert(open, i);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    close_of
}

/// Lex one physical line into (text, kind) runs. Strings never span lines in
/// serde's pretty output (newlines are escaped), so a per-line lexer is safe.
fn tokenize_line(line: &str) -> Runs {
    let chars: Vec<char> = line.chars().collect();
    let mut runs: Runs = Vec::new();
    let mut i = 0;
    let mut punct = String::new();
    let flush_punct = |punct: &mut String, runs: &mut Runs| {
        if !punct.is_empty() {
            runs.push((std::mem::take(punct), K_PUNCT));
        }
    };
    while i < chars.len() {
        let c = chars[i];
        if c == '"' {
            // Quoted string, escapes included. A string followed by `:` is an
            // object key; anything else is a value.
            let start = i;
            i += 1;
            while i < chars.len() {
                if chars[i] == '\\' {
                    i += 2;
                    continue;
                }
                if chars[i] == '"' {
                    i += 1;
                    break;
                }
                i += 1;
            }
            let tok: String = chars[start..i.min(chars.len())].iter().collect();
            let mut j = i;
            while j < chars.len() && chars[j] == ' ' {
                j += 1;
            }
            let kind = if j < chars.len() && chars[j] == ':' {
                K_KEY
            } else {
                K_STR
            };
            flush_punct(&mut punct, &mut runs);
            runs.push((tok, kind));
        } else if c.is_ascii_digit() || (c == '-' && chars.get(i + 1).is_some_and(|n| n.is_ascii_digit())) {
            let start = i;
            i += 1;
            while i < chars.len()
                && (chars[i].is_ascii_digit() || matches!(chars[i], '.' | 'e' | 'E' | '+' | '-'))
            {
                i += 1;
            }
            flush_punct(&mut punct, &mut runs);
            runs.push((chars[start..i].iter().collect(), K_NUM));
        } else if c.is_alphabetic() {
            let start = i;
            while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            if matches!(word.as_str(), "true" | "false" | "null") {
                flush_punct(&mut punct, &mut runs);
                runs.push((word, K_WORD));
            } else {
                // Not JSON vocabulary — plain text riding along in the dump.
                punct.push_str(&word);
            }
        } else {
            punct.push(c);
            i += 1;
        }
    }
    flush_punct(&mut punct, &mut runs);
    runs
}

/// Split one logical line's runs into visual lines of at most [`WRAP_COLS`]
/// characters. Continuation lines re-indent to the logical line's indent + 2
/// so wrapped blobs still read as part of their value.
fn wrap_runs(runs: Runs) -> Vec<Runs> {
    let total: usize = runs.iter().map(|(t, _)| t.chars().count()).sum();
    if total <= WRAP_COLS {
        return vec![runs];
    }
    let indent = runs
        .first()
        .filter(|(_, k)| *k == K_PUNCT)
        .map(|(t, _)| t.chars().take_while(|c| *c == ' ').count())
        .unwrap_or(0);
    let cont_prefix = " ".repeat(indent + 2);
    let mut out: Vec<Runs> = Vec::new();
    let mut cur: Runs = Vec::new();
    let mut col = 0usize;
    for (text, kind) in runs {
        let chars: Vec<char> = text.chars().collect();
        let mut offset = 0usize;
        while offset < chars.len() {
            let room = WRAP_COLS.saturating_sub(col);
            if room == 0 {
                out.push(std::mem::take(&mut cur));
                cur.push((cont_prefix.clone(), K_PUNCT));
                col = cont_prefix.len();
                continue;
            }
            let take = room.min(chars.len() - offset);
            let piece: String = chars[offset..offset + take].iter().collect();
            offset += take;
            col += take;
            cur.push((piece, kind));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}
