use crate::*;
use nostr::PublicKey;
use nostr::nips::nip19::{FromBech32, Nip19Profile};

/// Resolved display data for one profile mention (npub/nprofile) inside a
/// chat body. `name` is `None` when nothing in the app knows this key — the
/// renderer then falls back to the truncated bech32. `in_group` is true when
/// the key is a member of the group whose rows are being rendered; only those
/// mentions get the "@" prefix, so the reader can tell members from
/// outsiders at a glance.
pub(crate) struct MentionChip {
    pub(crate) name: Option<String>,
    pub(crate) in_group: bool,
    pub(crate) color_a: Color,
    pub(crate) color_b: Color,
}

/// Everything the markdown renderer needs to resolve a mention without
/// touching `Backend` (the render walk is pure and deep — threading a handle
/// through it would touch every walker signature). Populated from the places
/// that already resolve profiles: the member snapshot, the chat-open message
/// fetch, the contacts refresh, and the nickname editor.
struct MentionState {
    /// account hex (lowercase) → published display name. Only real names are
    /// stored — hex-tail fallbacks from a cold profile cache are skipped so a
    /// later warm pass can fill them in.
    names: HashMap<String, String>,
    /// account hex (lowercase) → private nickname (settings.rs). Display
    /// priority over `names`, like the contacts list.
    nicknames: HashMap<String, String>,
    /// group hex (lowercase) → member hex set (lowercase).
    members: HashMap<String, HashSet<String>>,
    /// Keys already sent to a relay profile fetch this session, so a key
    /// with no published kind-0 is attempted once, not on every rebuild.
    fetch_attempted: HashSet<String>,
    /// The group whose rows are currently being built. Row builds all run on
    /// the UI thread, so setting this at the top of each rebuild is race-free.
    render_group: String,
}

fn state() -> &'static Mutex<MentionState> {
    static STATE: OnceLock<Mutex<MentionState>> = OnceLock::new();
    STATE.get_or_init(|| {
        Mutex::new(MentionState {
            names: HashMap::new(),
            nicknames: HashMap::new(),
            members: HashMap::new(),
            fetch_attempted: HashSet::new(),
            render_group: String::new(),
        })
    })
}

/// Repaint hook fired (from the tokio runtime) when a relay profile fetch
/// resolves a mention name after the rows already rendered. Installed once at
/// startup (see main.rs) with the handles a rebuild needs — same stash
/// pattern as `set_album_load_ctx`.
static REFRESH: OnceLock<Box<dyn Fn() + Send + Sync>> = OnceLock::new();

pub(crate) fn mention_set_refresh(f: Box<dyn Fn() + Send + Sync>) {
    let _ = REFRESH.set(f);
}

/// Mark `group_hex` as the group whose message rows are about to be built.
pub(crate) fn mention_render_group(group_hex: &str) {
    if let Ok(mut st) = state().lock() {
        st.render_group = group_hex.to_ascii_lowercase();
    }
}

/// Record a resolved published name for an account. Hex-tail fallbacks (a
/// cold profile cache returns "0x…") are ignored so they never shadow a real
/// name learned later.
pub(crate) fn mention_note_profile(account_hex: &str, name: &str) {
    if name.is_empty() || name.starts_with("0x") {
        return;
    }
    if let Ok(mut st) = state().lock() {
        st.names
            .insert(account_hex.to_ascii_lowercase(), name.to_string());
    }
}

/// Replace the private-nickname map (from `Settings`).
pub(crate) fn mention_set_nicknames(nicknames: &std::collections::BTreeMap<String, String>) {
    if let Ok(mut st) = state().lock() {
        st.nicknames = nicknames
            .iter()
            .map(|(k, v)| (k.to_ascii_lowercase(), v.clone()))
            .collect();
    }
}

fn mentions_filter_flag() -> &'static AtomicBool {
    static ACTIVE: OnceLock<AtomicBool> = OnceLock::new();
    ACTIVE.get_or_init(|| AtomicBool::new(false))
}

/// Whether the active chat is in the mentions-only review mode. Stored outside
/// Slint so every row rebuild path (including live watchers) applies the same
/// filter.
pub(crate) fn mentions_filter_active() -> bool {
    mentions_filter_flag().load(AtomicOrdering::Relaxed)
}

pub(crate) fn set_mentions_filter_active(active: bool) {
    mentions_filter_flag().store(active, AtomicOrdering::Relaxed);
}

/// Replace one group's member set and note each member's published name.
/// Callable from any thread — `account_display_name` is a non-blocking
/// in-process cache read.
pub(crate) fn mention_set_group_members(
    backend: &Backend,
    group_hex: &str,
    members: &[AppGroupMemberRecord],
) {
    let mut set = HashSet::with_capacity(members.len());
    for m in members {
        mention_note_profile(
            &m.member_id_hex,
            &backend.account_display_name(&m.member_id_hex),
        );
        set.insert(m.member_id_hex.to_ascii_lowercase());
    }
    if let Ok(mut st) = state().lock() {
        st.members.insert(group_hex.to_ascii_lowercase(), set);
    }
}

/// Fetch `group_hex`'s member list and register it. A sqlite read — call it
/// off the UI thread (it rides the same runtime tasks that read the message
/// window, so membership is registered before the rows that need it build).
pub(crate) fn warm_group_mentions(backend: &Backend, group_hex: &str) {
    match backend.group_members(group_hex) {
        Ok(members) => mention_set_group_members(backend, group_hex, &members),
        Err(e) => tracing::warn!(target: "mentions", "group_members({group_hex}): {e:#}"),
    }
}

/// Extract the pubkey hex (lowercase) from a profile-bearing bech32. `None`
/// for every other entity kind (note/nevent/naddr/nrelay).
fn mention_pubkey_hex(bech32: &str) -> Option<String> {
    if bech32.starts_with("npub1") {
        Some(PublicKey::from_bech32(bech32).ok()?.to_hex())
    } else if bech32.starts_with("nprofile1") {
        Some(Nip19Profile::from_bech32(bech32).ok()?.public_key.to_hex())
    } else {
        None
    }
}

/// WCAG relative luminance of a color (sRGB linearized).
fn rel_luminance(c: Color) -> f32 {
    fn chan(u: u8) -> f32 {
        let x = u as f32 / 255.0;
        if x <= 0.04045 {
            x / 12.92
        } else {
            ((x + 0.055) / 1.055).powf(2.4)
        }
    }
    0.2126 * chan(c.red()) + 0.7152 * chan(c.green()) + 0.0722 * chan(c.blue())
}

/// Darken a chip color until white text on it clears WCAG AA for small text
/// (4.5:1 needs a background luminance ≤ ~0.175). Scales all channels evenly,
/// so the account's hue survives — only the lightness drops. The avatar
/// gradient's light end (`avatar_for` hue_a starts at 0x808080) is unreadable
/// under white glyphs without this.
pub(crate) fn chip_shade(c: Color) -> Color {
    let (mut r, mut g, mut b) = (c.red() as f32, c.green() as f32, c.blue() as f32);
    let mut guard = 0;
    while rel_luminance(Color::from_rgb_u8(r as u8, g as u8, b as u8)) > 0.175 && guard < 32 {
        r *= 0.9;
        g *= 0.9;
        b *= 0.9;
        guard += 1;
    }
    Color::from_rgb_u8(r as u8, g as u8, b as u8)
}

/// Resolve a mention's bech32 into its chip: display name (nickname first,
/// then the published name), membership in the group being rendered, and the
/// stable avatar gradient. `None` when the bech32 doesn't carry a pubkey
/// (note/nevent/naddr keep the plain shortened-link rendering).
pub(crate) fn mention_chip_for(bech32: &str) -> Option<MentionChip> {
    let hex = mention_pubkey_hex(bech32)?;
    let st = state().lock().ok()?;
    let published = st.names.get(&hex).cloned();
    let name = st
        .nicknames
        .get(&hex)
        .cloned()
        .or_else(|| published.clone());
    let in_group = st
        .members
        .get(&st.render_group)
        .is_some_and(|m| m.contains(&hex));
    // The gradient keys off the published name — the same key the avatar
    // pipeline hashes — so the chip carries the hue the reader already knows
    // from this account's avatar; a nickname changes the label, not the hue.
    let color_key = published.as_deref().unwrap_or(bech32);
    let (color_a, color_b, _) = avatar_for(color_key);
    Some(MentionChip {
        name,
        in_group,
        color_a: chip_shade(color_a),
        color_b: chip_shade(color_b),
    })
}

/// The bech32 data charset — token bytes after the "1" separator. Note it
/// has no 'b', so "npub1" can never occur inside another entity's data part.
const BECH32_DATA: &[u8] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// Collect every npub/nprofile token appearing in `text`.
fn collect_profile_refs(text: &str, out: &mut HashSet<String>) {
    for prefix in ["npub1", "nprofile1"] {
        let mut at = 0;
        while let Some(pos) = text[at..].find(prefix) {
            let start = at + pos;
            let data = start + prefix.len();
            let len = text.as_bytes()[data..]
                .iter()
                .take_while(|b| BECH32_DATA.contains(b))
                .count();
            if len > 0 {
                out.insert(text[start..data + len].to_string());
            }
            at = data + len;
        }
    }
}

/// True when `text` contains an npub/nprofile mention that resolves to
/// `account_hex`. Plain hex is deliberately ignored: composer mentions are
/// profile-bearing Nostr bech32 tokens, and matching raw hex would create false
/// positives in logs or pasted ids.
pub(crate) fn text_mentions_account(text: &str, account_hex: &str) -> bool {
    if account_hex.is_empty() {
        return false;
    }
    let want = account_hex.to_ascii_lowercase();
    let mut refs = HashSet::new();
    collect_profile_refs(text, &mut refs);
    refs.iter()
        .filter_map(|b| mention_pubkey_hex(b))
        .any(|hex| hex == want)
}

/// Cheap scan for `Backend::messages`' catch-all warm: the pubkey hexes
/// mentioned anywhere in `msgs` that the registry can't name yet. Pure
/// in-memory work (string scan + map lookups) — safe on any thread,
/// including the UI thread. All kinds are scanned: edits (1009) carry
/// replacement bodies that can mention someone the original didn't;
/// reactions scan to nothing.
pub(crate) fn mention_unresolved_keys(msgs: &[AppMessageRecord]) -> Vec<String> {
    let mut refs = HashSet::new();
    for m in msgs {
        collect_profile_refs(&m.plaintext, &mut refs);
    }
    unresolved_from_refs(refs)
}

/// Single-text variant of [`mention_unresolved_keys`], for warming straight
/// off the composer at dispatch time — resolution starts on the relay
/// round-trip immediately instead of waiting for the send/edit ack to echo
/// the text back through a snapshot read.
pub(crate) fn mention_unresolved_keys_in_text(text: &str) -> Vec<String> {
    let mut refs = HashSet::new();
    collect_profile_refs(text, &mut refs);
    unresolved_from_refs(refs)
}

fn unresolved_from_refs(refs: HashSet<String>) -> Vec<String> {
    if refs.is_empty() {
        return Vec::new();
    }
    let Ok(st) = state().lock() else {
        return Vec::new();
    };
    let mut out: Vec<String> = refs
        .iter()
        .filter_map(|b| mention_pubkey_hex(b))
        .filter(|hex| !st.names.contains_key(hex) && !st.nicknames.contains_key(hex))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// Claim a relay-fetch slot for `hex`. `false` = a fetch is already in
/// flight (or previously failed and hasn't been released).
pub(crate) fn mention_fetch_attempt(hex: &str) -> bool {
    state()
        .lock()
        .map(|mut st| st.fetch_attempted.insert(hex.to_string()))
        .unwrap_or(false)
}

/// Release a fetch slot after a fetch that yielded no name, so a transient
/// relay failure retries on a later rebuild instead of staying unresolved
/// for the rest of the session.
pub(crate) fn mention_fetch_clear(hex: &str) {
    if let Ok(mut st) = state().lock() {
        st.fetch_attempted.remove(hex);
    }
}

/// Repaint the active chat after names resolved asynchronously.
pub(crate) fn mention_fire_refresh() {
    match REFRESH.get() {
        Some(refresh) => refresh(),
        None => tracing::warn!(target: "mentions", "no repaint hook installed"),
    }
}

/// Resolve mentioned account ids nothing has named yet, via
/// [`Backend::resolve_display_name_async`] (local directory, then a kind-0
/// relay fetch). Each name that lands registers itself and repaints the
/// active chat; a resolve that comes up empty releases its fetch slot so a
/// later rebuild retries. Fed by the `Backend::messages` snapshot observer
/// (see main.rs), so it fires for every flow that renders text. The gate
/// covers the whole resolve, so concurrent rebuilds don't duplicate fetches.
pub(crate) fn warm_unresolved_mentions(backend: &Backend, hexes: Vec<String>) {
    for hex in hexes {
        if !mention_fetch_attempt(&hex) {
            continue;
        }
        let hex_done = hex.clone();
        backend.resolve_display_name_async(&hex, move |name| match name {
            Some(name) => {
                tracing::info!(target: "mentions", hex = %hex_done, %name, "mention resolved — repainting");
                mention_note_profile(&hex_done, &name);
                mention_fire_refresh();
            }
            None => {
                tracing::warn!(target: "mentions", hex = %hex_done, "mention unresolved (no directory entry, no relay profile)");
                mention_fetch_clear(&hex_done);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "0000000000000000000000000000000000000000000000000000000000000001";
    const OTHER: &str = "0000000000000000000000000000000000000000000000000000000000000002";

    #[test]
    fn text_mentions_account_detects_local_npub_only() {
        let me = npub_for_account_id(ME).unwrap();
        let other = npub_for_account_id(OTHER).unwrap();

        assert!(text_mentions_account(&format!("ping {me}"), ME));
        assert!(text_mentions_account(
            &format!("ping {me}"),
            &ME.to_ascii_uppercase()
        ));
        assert!(!text_mentions_account(&format!("ping {other}"), ME));
        assert!(!text_mentions_account(ME, ME));
    }
}
