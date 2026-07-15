use unicode_normalization::UnicodeNormalization;

// Fuzzy matching for the in-conversation search bar — a port of the
// content-search semantics from whitenoise-rs (`content_search.rs`, PR #726):
// NFC + Unicode-aware lowercasing on both the query and the message body, the
// query split into word tokens, and a message matching when every token
// occurs in the body in forward order (the SQL `%tok1%tok2%` LIKE pattern,
// evaluated in Rust because our records live behind marmot, not sqlite).

/// Returns `true` if `c` should be considered part of a search token.
///
/// A word character is either alphanumeric (Unicode `Alphabetic`/`Numeric`,
/// so CJK ideographs, Arabic letters, etc. are included) or a combining mark
/// — splitting a token at a combining mark would corrupt the grapheme
/// cluster (Devanagari virama, Arabic diacritics, Thai tone marks, …).
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || is_combining_mark(c)
}

/// Check if a character is a Unicode combining mark (categories Mn, Mc, Me).
///
/// Rust's std doesn't expose Unicode General_Category, so this checks the
/// known combining-mark codepoint ranges of the BMP blocks used by major
/// world scripts.
fn is_combining_mark(c: char) -> bool {
    let cp = c as u32;
    matches!(cp,
        0x0300..=0x036F   // Combining Diacritical Marks
        | 0x0483..=0x0489 // Cyrillic combining marks
        | 0x0591..=0x05BD // Hebrew marks
        | 0x05BF
        | 0x05C1..=0x05C2
        | 0x05C4..=0x05C5
        | 0x05C7
        | 0x0610..=0x061A // Arabic marks
        | 0x064B..=0x065F // Arabic diacritics
        | 0x0670
        | 0x06D6..=0x06DC
        | 0x06DF..=0x06E4
        | 0x06E7..=0x06E8
        | 0x06EA..=0x06ED
        | 0x0711          // Syriac
        | 0x0730..=0x074A
        | 0x07A6..=0x07B0 // Thaana
        | 0x0901..=0x0903 // Devanagari
        | 0x093A..=0x094F
        | 0x0951..=0x0957
        | 0x0962..=0x0963
        | 0x0981..=0x0983 // Bengali
        | 0x09BC..=0x09CD
        | 0x09D7
        | 0x09E2..=0x09E3
        | 0x0A01..=0x0A03 // Gurmukhi
        | 0x0A3C..=0x0A4D
        | 0x0A70..=0x0A71
        | 0x0A81..=0x0A83 // Gujarati
        | 0x0ABC..=0x0ACD
        | 0x0AE2..=0x0AE3
        | 0x0B01..=0x0B03 // Oriya
        | 0x0B3C..=0x0B4D
        | 0x0B56..=0x0B57
        | 0x0B82          // Tamil
        | 0x0BBE..=0x0BCD
        | 0x0BD7
        | 0x0C00..=0x0C04 // Telugu
        | 0x0C3C..=0x0C4D
        | 0x0C55..=0x0C56
        | 0x0C81..=0x0C83 // Kannada
        | 0x0CBC..=0x0CCD
        | 0x0CD5..=0x0CD6
        | 0x0D00..=0x0D03 // Malayalam
        | 0x0D3B..=0x0D4D
        | 0x0D57
        | 0x0DCA          // Sinhala
        | 0x0DCF..=0x0DDF
        | 0x0DF2..=0x0DF3
        | 0x0E31          // Thai
        | 0x0E34..=0x0E3A
        | 0x0E47..=0x0E4E
        | 0x0EB1          // Lao
        | 0x0EB4..=0x0EBC
        | 0x0EC8..=0x0ECE
        | 0x0F18..=0x0F19 // Tibetan
        | 0x0F35
        | 0x0F37
        | 0x0F39
        | 0x0F3E..=0x0F3F
        | 0x0F71..=0x0F84
        | 0x0F86..=0x0F87
        | 0x0F8D..=0x0FBC
        | 0x0FC6
        | 0x102B..=0x103E // Myanmar
        | 0x1056..=0x1059
        | 0x105E..=0x1060
        | 0x1062..=0x1064
        | 0x1067..=0x106D
        | 0x1071..=0x1074
        | 0x1082..=0x108D
        | 0x108F
        | 0x109A..=0x109D
        | 0x1DC0..=0x1DFF // Combining Diacritical Marks Supplement
        | 0x20D0..=0x20FF // Combining Diacritical Marks for Symbols
        | 0xFE20..=0xFE2F // Combining Half Marks
    )
}

/// Normalize a string for search comparison: NFC followed by Unicode-aware
/// lowercasing, so composed/decomposed forms (`é` vs `e`+U+0301) compare
/// equal and case folding works for scripts where ASCII lowering is a no-op.
/// Applied to both the message body and the query so both sides use the
/// same form.
pub(crate) fn normalize_for_search(s: &str) -> String {
    s.nfc().collect::<String>().to_lowercase()
}

/// Extract non-empty, normalized search tokens from a query string (split on
/// non-word characters). Empty when the query holds no tokens — the caller
/// treats that as "no search".
pub(crate) fn query_tokens(query: &str) -> Vec<String> {
    normalize_for_search(query)
        .split(|c: char| !is_word_char(c))
        .filter(|t| !t.is_empty())
        .map(|t| t.to_string())
        .collect()
}

/// Forward-order token match: every token must occur in the normalized body,
/// each one at or after the end of the previous token's match.
pub(crate) fn matches_tokens(content: &str, tokens: &[String]) -> bool {
    if tokens.is_empty() {
        return false;
    }
    let normalized = normalize_for_search(content);
    let mut from = 0usize;
    for token in tokens {
        match normalized[from..].find(token.as_str()) {
            Some(pos) => from += pos + token.len(),
            None => return false,
        }
    }
    true
}

/// Split `text` into `(pre, matched, post)` around the first fuzzy-matched
/// token, for result rows that highlight the match as its own text run. The
/// lead is trimmed so the match stays visible in a one-line elided row, and
/// newlines are flattened to spaces. Works in char space and only trusts the
/// lowercase mapping when it preserves the char count (it almost always
/// does; the rare expanding codepoint — and a token the un-normalized
/// lowering can't find — falls back to `(head, "", "")`).
pub(crate) fn snippet_parts(text: &str, tokens: &[String]) -> (String, String, String) {
    const LEAD: usize = 20; // chars kept before the match
    const TAIL: usize = 160; // chars kept after it

    let flat: String = text
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    let orig: Vec<char> = flat.chars().collect();
    if let Some(first) = tokens.first() {
        let lower: Vec<char> = flat.to_lowercase().chars().collect();
        let tok: Vec<char> = first.chars().collect();
        if lower.len() == orig.len()
            && !tok.is_empty()
            && tok.len() <= lower.len()
            && let Some(pos) = lower.windows(tok.len()).position(|w| w == &tok[..])
        {
            let start = pos.saturating_sub(LEAD);
            let mut pre = String::new();
            if start > 0 {
                pre.push('…');
            }
            pre.extend(orig[start..pos].iter());
            let matched: String = orig[pos..pos + tok.len()].iter().collect();
            let after = pos + tok.len();
            let mut post: String = orig[after..].iter().take(TAIL).collect();
            if orig.len() - after > TAIL {
                post.push('…');
            }
            return (pre, matched, post);
        }
    }
    let mut head: String = orig.iter().take(TAIL).collect();
    if orig.len() > TAIL {
        head.push('…');
    }
    (head, String::new(), String::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(content: &str, query: &str) -> bool {
        matches_tokens(content, &query_tokens(query))
    }

    #[test]
    fn forward_order_tokens() {
        assert!(matches("hello brave new world", "hello world"));
        assert!(matches("hello brave new world", "brave world"));
        assert!(!matches("hello brave new world", "world hello"));
    }

    #[test]
    fn case_and_diacritics_fold() {
        assert!(matches("Grüße aus MÜNCHEN", "grüße münchen"));
        // Decomposed query vs composed content.
        assert!(matches("café", "cafe\u{0301}"));
        assert!(matches("ПРИВЕТ мир", "привет"));
    }

    #[test]
    fn punctuation_splits_tokens() {
        assert!(matches("deploy: v2.1 shipped!", "deploy shipped"));
        assert!(matches("one,two", "one two"));
    }

    #[test]
    fn empty_query_never_matches() {
        assert!(query_tokens("  …!?  ").is_empty());
        assert!(!matches("anything", ""));
    }

    #[test]
    fn cjk_matches() {
        assert!(matches("明日は晴れです", "晴れ"));
    }

    #[test]
    fn snippet_splits_around_match() {
        let tokens = query_tokens("hello");
        let (pre, hit, post) = snippet_parts("say Hello world", &tokens);
        assert_eq!(pre, "say ");
        assert_eq!(hit, "Hello"); // original casing preserved
        assert_eq!(post, " world");
    }

    #[test]
    fn snippet_trims_to_late_match() {
        let long = format!("{}needle in here", "x".repeat(300));
        let tokens = query_tokens("needle");
        let (pre, hit, post) = snippet_parts(&long, &tokens);
        assert!(pre.starts_with('…'));
        assert!(pre.chars().count() <= 21);
        assert_eq!(hit, "needle");
        assert_eq!(post, " in here");
    }

    #[test]
    fn snippet_flattens_newlines() {
        let tokens = query_tokens("café");
        let (pre, hit, post) = snippet_parts("line1\nline2 café", &tokens);
        assert_eq!(pre, "line1 line2 ");
        assert_eq!(hit, "café");
        assert_eq!(post, "");
    }

    #[test]
    fn snippet_survives_unfindable_token() {
        // Decomposed content: the NFC-composed token isn't in the raw
        // lowercase, so the split falls back to the untrimmed head.
        let tokens = query_tokens("café");
        let (pre, hit, post) = snippet_parts("cafe\u{0301} again", &tokens);
        assert_eq!(pre, "cafe\u{0301} again");
        assert_eq!(hit, "");
        assert_eq!(post, "");
    }
}
