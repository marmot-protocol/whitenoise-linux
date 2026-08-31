// marmot:// deep links, the slint deeplink.rs port. The QR payload
// builder lives in panes.odin (qr_texture, marmot://profile/<npub>
// ?from=qr); this file parses inbound links: in-chat anchors
// (inline_segs), a pasted new-chat member, and the argv link from the
// OS scheme handler (x-scheme-handler/marmot, see
// assets/whitenoise.desktop + install-scheme.sh).
package main

import "core:encoding/hex"
import "core:strings"

MARMOT_SCHEME :: "marmot://"

// True if url uses the marmot:// scheme (scheme case-folded).
is_marmot_url :: proc(url: string) -> bool {
	return(
		len(url) >= len(MARMOT_SCHEME) &&
		strings.equal_fold(url[:len(MARMOT_SCHEME)], MARMOT_SCHEME) \
	)
}

// Extract the profile reference from a marmot://profile/<ref> link,
// dropping query/fragment and a trailing slash. "" for non-profile or
// malformed links; validation is the caller's job.
marmot_link_ref :: proc(url: string) -> string {
	if !is_marmot_url(url) {
		return ""
	}
	rest := url[len(MARMOT_SCHEME):]
	if !strings.has_prefix(rest, "profile/") {
		return ""
	}
	rest = rest[len("profile/"):]
	if cut := strings.index_any(rest, "?#"); cut >= 0 {
		rest = rest[:cut]
	}
	return strings.trim_suffix(rest, "/")
}

// Profile reference (npub/nprofile/hex) → pubkey hex, "" undecodable.
deeplink_hex :: proc(ref: string) -> string {
	if hx := mention_hex(ref); len(hx) > 0 {
		return hx
	}
	if len(ref) == 64 {
		if _, ok := hex.decode(transmute([]u8)ref, context.temp_allocator); ok {
			return ref
		}
	}
	return ""
}

// Parse a marmot://profile deep link at text[i:] for the body chip
// pass: end is the byte past the link (a ?query/#fragment rides along
// to the next whitespace), hx the pubkey hex.
marmot_link_at :: proc(text: string, i: int) -> (end: int, hx: string, ok: bool) {
	if !is_marmot_url(text[i:]) {
		return
	}
	j := i + len(MARMOT_SCHEME)
	if !strings.has_prefix(text[j:], "profile/") {
		return
	}
	end, hx, ok = mention_at(text, j + len("profile/"))
	if !ok {
		return
	}
	if end < len(text) && (text[end] == '?' || text[end] == '#') {
		for end < len(text) && text[end] > ' ' {
			end += 1
		}
	}
	return
}
