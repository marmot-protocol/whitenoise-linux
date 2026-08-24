use crate::*;

/// Horizontal budget for diff lines inside the edit-history modal (card width
/// minus padding and the timeline rail).
const EDIT_DIFF_WRAP_PX: f32 = 380.0;

#[derive(Clone, Copy, PartialEq, Eq)]
enum DiffKind {
    Unchanged = 0,
    Removed = 1,
    Added = 2,
}

impl DiffKind {
    fn as_i32(self) -> i32 {
        self as i32
    }
}

/// Split `text` into alternating word and whitespace tokens so diffs preserve
/// spacing.
fn tokenize(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut ws: Option<bool> = None;
    for ch in text.chars() {
        let is_ws = ch.is_whitespace();
        match ws {
            None => {
                buf.push(ch);
                ws = Some(is_ws);
            }
            Some(was_ws) if was_ws == is_ws => buf.push(ch),
            Some(_) => {
                out.push(buf);
                buf = ch.to_string();
                ws = Some(is_ws);
            }
        }
    }
    if !buf.is_empty() {
        out.push(buf);
    }
    out
}

fn lcs_pairs(a: &[String], b: &[String]) -> Vec<(usize, usize)> {
    let n = a.len();
    let m = b.len();
    let mut dp = vec![vec![0usize; m + 1]; n + 1];
    for (i, ai) in a.iter().enumerate() {
        for (j, bj) in b.iter().enumerate() {
            dp[i + 1][j + 1] = if ai == bj {
                dp[i][j] + 1
            } else {
                dp[i][j + 1].max(dp[i + 1][j])
            };
        }
    }
    let mut pairs = Vec::new();
    let (mut i, mut j) = (n, m);
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            pairs.push((i - 1, j - 1));
            i -= 1;
            j -= 1;
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    pairs.reverse();
    pairs
}

fn push_run(runs: &mut Vec<(DiffKind, String)>, kind: DiffKind, text: String) {
    if text.is_empty() {
        return;
    }
    if let Some((last_kind, last_text)) = runs.last_mut()
        && *last_kind == kind
    {
        last_text.push_str(&text);
        return;
    }
    runs.push((kind, text));
}

/// Word-level diff between `prev` and `next`, merged into contiguous runs.
fn diff_words(prev: &str, next: &str) -> Vec<(DiffKind, String)> {
    let a = tokenize(prev);
    let b = tokenize(next);
    if a.is_empty() && b.is_empty() {
        return Vec::new();
    }
    let pairs = lcs_pairs(&a, &b);
    let mut runs = Vec::new();
    let (mut ai, mut bi, mut pi) = (0usize, 0usize, 0usize);
    loop {
        if pi < pairs.len() {
            let (lai, lbi) = pairs[pi];
            while ai < lai {
                push_run(&mut runs, DiffKind::Removed, a[ai].clone());
                ai += 1;
            }
            while bi < lbi {
                push_run(&mut runs, DiffKind::Added, b[bi].clone());
                bi += 1;
            }
            push_run(&mut runs, DiffKind::Unchanged, a[ai].clone());
            ai += 1;
            bi += 1;
            pi += 1;
        } else {
            while ai < a.len() {
                push_run(&mut runs, DiffKind::Removed, a[ai].clone());
                ai += 1;
            }
            while bi < b.len() {
                push_run(&mut runs, DiffKind::Added, b[bi].clone());
                bi += 1;
            }
            break;
        }
    }
    runs
}

fn run_width(text: &str, fs: f32) -> f32 {
    if text.is_empty() {
        0.0
    } else {
        text.chars().count() as f32 * fs * MD_CHAR_W
    }
}

fn push_slint_run(out: &mut Vec<EditDiffRun>, kind: DiffKind, text: &str) {
    if text.is_empty() {
        return;
    }
    if let Some(last) = out.last_mut()
        && last.kind == kind.as_i32()
    {
        last.text = s(&format!("{}{}", last.text, text));
        return;
    }
    out.push(EditDiffRun {
        text: s(text),
        kind: kind.as_i32(),
    });
}

/// Greedy wrap of diff runs into visual lines that fit the modal width.
fn wrap_diff_runs(runs: &[(DiffKind, String)]) -> Vec<EditDiffLine> {
    let fs = body_fs();
    let max_w = EDIT_DIFF_WRAP_PX;
    let mut lines: Vec<EditDiffLine> = Vec::new();
    let mut line_runs: Vec<EditDiffRun> = Vec::new();
    let mut line_w = 0.0f32;

    let flush = |lines: &mut Vec<EditDiffLine>, line_runs: &mut Vec<EditDiffRun>| {
        if !line_runs.is_empty() {
            lines.push(EditDiffLine {
                runs: ModelRc::new(VecModel::from(std::mem::take(line_runs))),
            });
        }
    };

    for (kind, text) in runs {
        let mut rest = text.as_str();
        while !rest.is_empty() {
            let w = run_width(rest, fs);
            if line_w + w <= max_w || line_runs.is_empty() {
                push_slint_run(&mut line_runs, *kind, rest);
                line_w += w;
                break;
            }
            // Split at the last char that still fits on this line.
            let budget = (max_w - line_w).max(fs * MD_CHAR_W);
            let max_chars = (budget / (fs * MD_CHAR_W)).floor() as usize;
            let max_chars = max_chars.max(1);
            let split_at = rest
                .char_indices()
                .nth(max_chars)
                .map(|(i, _)| i)
                .unwrap_or(rest.len());
            let (head, tail) = rest.split_at(split_at);
            push_slint_run(&mut line_runs, *kind, head);
            flush(&mut lines, &mut line_runs);
            line_w = 0.0;
            rest = tail;
        }
    }
    flush(&mut lines, &mut line_runs);
    lines
}

fn diff_runs_to_lines(prev: &str, next: &str) -> Vec<EditDiffLine> {
    let runs = diff_words(prev, next);
    if runs.is_empty() {
        return Vec::new();
    }
    wrap_diff_runs(&runs)
}

/// Build the full version history for the edit-history modal. Returns the
/// version rows and the edit count (excluding the original).
pub(crate) fn build_edit_history_bundle(
    records: &[AppMessageRecord],
    message_id: &str,
) -> Option<(Vec<EditVersion>, i32)> {
    let Some(original) = records
        .iter()
        .find(|r| r.kind == CHAT_MESSAGE_KIND && r.message_id_hex == message_id)
    else {
        return None;
    };
    let mut edits: Vec<&AppMessageRecord> = records
        .iter()
        .filter(|r| r.kind == 1009)
        .filter(|r| r.sender.eq_ignore_ascii_case(&original.sender))
        .filter(|r| {
            r.tags
                .iter()
                .any(|t| t.len() >= 2 && t[0] == "e" && t[1] == message_id)
        })
        .filter(|r| !r.plaintext.trim().is_empty())
        .collect();
    if edits.is_empty() {
        return None;
    }
    edits.sort_by(|a, b| {
        a.recorded_at
            .cmp(&b.recorded_at)
            .then(a.message_id_hex.cmp(&b.message_id_hex))
    });

    let mut out = Vec::with_capacity(edits.len() + 1);
    let mut prev_text = original.plaintext.as_str();

    out.push(EditVersion {
        stamp: s(&format_unix(original.recorded_at)),
        is_original: true,
        is_current: false,
        edit_number: 0,
        show_full: true,
        full_text: s(prev_text),
        diff_lines: ModelRc::new(VecModel::from(Vec::<EditDiffLine>::new())),
    });

    for (i, edit) in edits.iter().enumerate() {
        let is_last = i + 1 == edits.len();
        let next_text = edit.plaintext.as_str();
        let diff_lines = diff_runs_to_lines(prev_text, next_text);
        let show_full = diff_lines.is_empty();
        out.push(EditVersion {
            stamp: s(&format_unix(edit.recorded_at)),
            is_original: false,
            is_current: is_last,
            edit_number: (i + 1) as i32,
            show_full,
            full_text: if show_full {
                s(next_text)
            } else {
                SharedString::default()
            },
            diff_lines: ModelRc::new(VecModel::from(diff_lines)),
        });
        prev_text = next_text;
    }

    Some((out, edits.len() as i32))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diff_inserts_one_word() {
        let prev = "remove the bubbles and make it";
        let next = "remove the message bubbles and make it";
        let runs = diff_words(prev, next);
        assert!(runs.iter().any(|(k, t)| *k == DiffKind::Added && t == "message "));
        assert!(runs
            .iter()
            .any(|(k, t)| *k == DiffKind::Unchanged && t.contains("bubbles")));
    }

    #[test]
    fn diff_removes_word() {
        let runs = diff_words("hello world", "hello");
        assert!(runs
            .iter()
            .any(|(k, t)| *k == DiffKind::Removed && t.contains("world")));
    }

    #[test]
    fn diff_full_rewrite() {
        let runs = diff_words("old text", "completely new");
        assert!(runs.iter().any(|(k, _)| *k == DiffKind::Removed));
        assert!(runs.iter().any(|(k, _)| *k == DiffKind::Added));
    }
}
