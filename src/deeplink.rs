//! `marmot://` deep-link scheme (profile links).
//!
//! MDK's canonical profile deep link is `marmot://profile/<npub>?from=qr`
//! (the experimental `darkmatter://` scheme was retired with no fallback).
//! This module owns the three touch points:
//!
//! - building the URL that goes into profile QR codes,
//! - parsing inbound links (chat anchors, pasted add-contact input),
//! - stashing a link passed on the command line by the OS scheme handler
//!   (`x-scheme-handler/marmot`, see `assets/whitenoise-linux.desktop`)
//!   until the backend has booted and the profile modal can resolve it.

use std::sync::Mutex;

const SCHEME: &str = "marmot://";

/// The URL rasterized into profile QR codes.
pub(crate) fn profile_qr_url(npub: &str) -> String {
    format!("marmot://profile/{npub}?from=qr")
}

/// True if `url` uses the `marmot://` scheme (any path, scheme case-folded).
pub(crate) fn is_marmot_url(url: &str) -> bool {
    strip_prefix_ci(url, SCHEME).is_some()
}

/// Extract the profile reference from a `marmot://profile/<ref>` link,
/// dropping any query/fragment and a trailing slash. Returns the bare
/// reference (npub/nprofile/hex — validation is the caller's job) or None
/// for non-profile or malformed links.
pub(crate) fn profile_link_ref(url: &str) -> Option<&str> {
    let rest = strip_prefix_ci(url, SCHEME)?;
    let rest = rest.strip_prefix("profile/")?;
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let rest = rest.trim_end_matches('/');
    (!rest.is_empty()).then_some(rest)
}

/// A deep link handed to us on the command line, parked until boot finishes.
static PENDING: Mutex<Option<String>> = Mutex::new(None);

/// Scan argv for a `marmot://` URL (the OS scheme handler passes it as the
/// sole argument via `Exec=… %u`) and park it for [`take_pending`].
pub(crate) fn stash_from_args() {
    if let Some(url) = std::env::args().skip(1).find(|a| is_marmot_url(a)) {
        tracing::info!(target: "deeplink", "queued deep link from argv: {url}");
        *PENDING.lock().unwrap() = Some(url);
    }
}

/// Take the parked command-line deep link, if any.
pub(crate) fn take_pending() -> Option<String> {
    PENDING.lock().unwrap().take()
}

/// Case-insensitive `strip_prefix` (URI schemes are case-insensitive).
fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    s.get(..prefix.len())?
        .eq_ignore_ascii_case(prefix)
        .then(|| &s[prefix.len()..])
}

#[cfg(test)]
mod tests {
    use super::*;

    const NPUB: &str = "npub1xlrek38rqmoldexamplexamplexample";

    #[test]
    fn qr_url_round_trips_through_parser() {
        let url = profile_qr_url(NPUB);
        assert_eq!(profile_link_ref(&url), Some(NPUB));
    }

    #[test]
    fn parses_plain_and_decorated_links() {
        assert_eq!(profile_link_ref("marmot://profile/abc"), Some("abc"));
        assert_eq!(profile_link_ref("marmot://profile/abc/"), Some("abc"));
        assert_eq!(
            profile_link_ref("marmot://profile/abc?from=qr"),
            Some("abc")
        );
        assert_eq!(profile_link_ref("marmot://profile/abc#x"), Some("abc"));
        assert_eq!(profile_link_ref("MARMOT://profile/abc"), Some("abc"));
    }

    #[test]
    fn rejects_non_profile_links() {
        assert_eq!(profile_link_ref("marmot://profile/"), None);
        assert_eq!(profile_link_ref("marmot://profile/?from=qr"), None);
        assert_eq!(profile_link_ref("marmot://group/abc"), None);
        assert_eq!(profile_link_ref("darkmatter://profile/abc"), None);
        assert_eq!(profile_link_ref("nostr:npub1abc"), None);
        assert_eq!(
            profile_link_ref("https://example.com/marmot://profile/a"),
            None
        );
    }

    #[test]
    fn scheme_detection() {
        assert!(is_marmot_url("marmot://anything"));
        assert!(is_marmot_url("Marmot://profile/x"));
        assert!(!is_marmot_url("marmot:profile/x"));
        assert!(!is_marmot_url("darkmatter://profile/x"));
    }
}
