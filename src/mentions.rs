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

/// One current message body considered for the global mentions inbox. The
/// caller resolves edits/deletes before constructing this value, keeping the
/// filtering and ordering rule independent of storage/backend details.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MentionInboxSource {
    pub(crate) group_id: String,
    pub(crate) message_id: String,
    pub(crate) sender_id: String,
    pub(crate) text: String,
    pub(crate) recorded_at: u64,
}

/// Keep incoming messages that currently mention the local account, newest
/// first across every chat. A stable id tie-break makes refreshes deterministic.
pub(crate) fn filter_and_sort_mention_sources(
    mut sources: Vec<MentionInboxSource>,
    my_account_id_hex: &str,
) -> Vec<MentionInboxSource> {
    sources.retain(|item| {
        !item.sender_id.eq_ignore_ascii_case(my_account_id_hex)
            && text_mentions_account(&item.text, my_account_id_hex)
    });
    sources.sort_by(|a, b| {
        b.recorded_at
            .cmp(&a.recorded_at)
            .then_with(|| b.message_id.cmp(&a.message_id))
    });
    sources
}

fn filter_sort_and_truncate_mention_sources(
    sources: Vec<MentionInboxSource>,
    my_account_id_hex: &str,
    limit: usize,
) -> Vec<MentionInboxSource> {
    let mut sources = filter_and_sort_mention_sources(sources, my_account_id_hex);
    sources.truncate(limit);
    sources
}

fn centered_visible_window(
    visible_count: usize,
    target_index: usize,
    limit: usize,
) -> std::ops::Range<usize> {
    let limit = limit.min(visible_count);
    let start = target_index
        .saturating_sub(limit / 2)
        .min(visible_count.saturating_sub(limit));
    start..start + limit
}

/// Build an eager-Slint-safe message window around `target_id`. Control events
/// (edits, deletes, reactions) from the bounded scan are retained so the rows
/// in the window render their current state, while visible bubbles stay capped.
/// The returned recent-record limit keeps surgical actions able to find the
/// target until the user normally re-enters the chat. Navigation scans the
/// selected chat's full history off the UI thread first, so every mention shown
/// in the bounded global inbox remains reachable regardless of chat activity.
pub(crate) fn mention_navigation_window(
    records: &[AppMessageRecord],
    target_id: &str,
    visible_limit: usize,
) -> Option<(Vec<AppMessageRecord>, usize)> {
    if visible_limit == 0 {
        return None;
    }
    let visible_indices: Vec<usize> = records
        .iter()
        .enumerate()
        .filter_map(|(index, record)| is_visible_chat_message(record).then_some(index))
        .collect();
    let target_visible_index = visible_indices.iter().position(|index| {
        records[*index]
            .message_id_hex
            .eq_ignore_ascii_case(target_id)
    })?;
    let target_record_index = visible_indices[target_visible_index];
    let selected_range =
        centered_visible_window(visible_indices.len(), target_visible_index, visible_limit);
    let selected_ids: HashSet<&str> = visible_indices[selected_range]
        .iter()
        .map(|index| records[*index].message_id_hex.as_str())
        .collect();
    let window = records
        .iter()
        .filter(|record| {
            !is_visible_chat_message(record)
                || selected_ids.contains(record.message_id_hex.as_str())
        })
        .cloned()
        .collect();
    let recent_limit = records
        .len()
        .saturating_sub(target_record_index)
        .saturating_add(visible_limit / 2)
        .max(MESSAGE_WINDOW);
    Some((window, recent_limit))
}

/// Resolve all visible, non-archived chat histories into current mention
/// candidates. Edits replace the original text; deleted messages are omitted.
/// The resulting global list is capped because Slint repeaters are eager rather
/// than virtual. A failed chat query fails the refresh instead of silently
/// presenting a partial inbox as complete.
pub(crate) fn collect_global_mention_sources(
    backend: &Backend,
    group_ids: &[String],
) -> anyhow::Result<Vec<MentionInboxSource>> {
    const INBOX_LIMIT: usize = 100;

    let my_id = backend.account().account_id_hex;
    let mut sources = Vec::new();
    for group_hex in group_ids {
        let records = backend.messages(group_hex, None)?;
        let edits = aggregate_edits(&records);
        let deletes = aggregate_deletes(&records);
        for message in records
            .iter()
            .filter(|message| is_visible_chat_message(message))
        {
            if deletes.contains(&message.message_id_hex) {
                continue;
            }
            let text = edits
                .get(&message.message_id_hex)
                .filter(|edit| edit.count() > 0)
                .map(|edit| edit.text().to_string())
                .unwrap_or_else(|| message.plaintext.clone());
            sources.push(MentionInboxSource {
                group_id: group_hex.clone(),
                message_id: message.message_id_hex.clone(),
                sender_id: message.sender.clone(),
                text,
                recorded_at: message.recorded_at,
            });
        }
    }
    Ok(filter_sort_and_truncate_mention_sources(
        sources,
        &my_id,
        INBOX_LIMIT,
    ))
}

fn mention_inbox_refresh_account() -> &'static Mutex<Option<String>> {
    static ACCOUNT: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    ACCOUNT.get_or_init(|| Mutex::new(None))
}

fn begin_mention_inbox_refresh(account_id: &str) -> bool {
    let Ok(mut active) = mention_inbox_refresh_account().lock() else {
        return false;
    };
    if active
        .as_deref()
        .is_some_and(|current| current.eq_ignore_ascii_case(account_id))
    {
        return false;
    }
    *active = Some(account_id.to_string());
    true
}

fn finish_mention_inbox_refresh(account_id: &str) {
    let Ok(mut active) = mention_inbox_refresh_account().lock() else {
        return;
    };
    if active
        .as_deref()
        .is_some_and(|current| current.eq_ignore_ascii_case(account_id))
    {
        active.take();
    }
}

static MENTION_INBOX_GENERATION: AtomicUsize = AtomicUsize::new(0);

/// Refresh the global inbox without blocking Slint on full-history sqlite reads.
/// Chat display metadata is joined by stable group id on the UI thread. The
/// generation and account checks prevent stale scans from crossing popup opens
/// or account switches.
pub(crate) fn refresh_mention_inbox_async(
    ui: &WhiteNoiseLinux,
    backend: &Arc<Backend>,
    group_ids: &Arc<Mutex<Vec<String>>>,
) {
    let account_id = backend.account().account_id_hex;
    if !begin_mention_inbox_refresh(&account_id) {
        return;
    }
    let generation = MENTION_INBOX_GENERATION.fetch_add(1, AtomicOrdering::Relaxed) + 1;
    let identity_epoch = account_epoch();
    ui.set_mention_inbox_items(model(Vec::<MentionInboxItem>::new()));
    ui.set_mention_inbox_loading(true);
    let weak = ui.as_weak();
    let b = backend.clone();
    let ids = group_ids.lock().unwrap().clone();
    let current_group_ids = group_ids.clone();
    let refresh_account_id = account_id.clone();
    backend.tokio_handle().spawn(async move {
        let sources = match collect_global_mention_sources(&b, &ids) {
            Ok(sources) => Some(sources),
            Err(error) => {
                tracing::warn!(target: "mentions", "mention inbox refresh failed: {error:#}");
                None
            }
        };
        finish_mention_inbox_refresh(&refresh_account_id);
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            if MENTION_INBOX_GENERATION.load(AtomicOrdering::Relaxed) != generation
                || account_epoch() != identity_epoch
                || !b.account().account_id_hex.eq_ignore_ascii_case(&account_id)
            {
                return;
            }
            let Some(sources) = sources else {
                ui.set_mention_inbox_loading(false);
                return;
            };
            let current_ids = current_group_ids.lock().unwrap().clone();
            let chats = ui.get_chats();
            // Senders whose profile picture isn't cached yet: fetched below
            // after the rows land, then bound in place by sender id (same
            // shape as the global-search rows).
            let mut pending_fetches: HashMap<String, String> = HashMap::new();
            let items: Vec<MentionInboxItem> = sources
                .into_iter()
                .filter_map(|source| {
                    let chat_index = current_ids
                        .iter()
                        .position(|group| group.eq_ignore_ascii_case(&source.group_id))?;
                    let chat = chats.row_data(chat_index)?;
                    let (sender_name, picture_url) = b.account_name_and_picture(&source.sender_id);
                    let (sender_a, sender_b, sender_initials) = avatar_for(&sender_name);
                    let (picture, has_picture) = bind_cached_picture(picture_url.as_deref());
                    if !has_picture
                        && let Some(url) = picture_url
                            .as_deref()
                            .map(str::trim)
                            .filter(|u| !u.is_empty())
                    {
                        pending_fetches
                            .entry(source.sender_id.clone())
                            .or_insert_with(|| url.to_string());
                    }
                    Some(MentionInboxItem {
                        group_id: s(&source.group_id),
                        message_id: s(&source.message_id),
                        sender_id: s(&source.sender_id),
                        chat_name: chat.name,
                        sender_name: s(&sender_name),
                        sender_initials: s(&sender_initials),
                        sender_a,
                        sender_b,
                        picture,
                        has_picture,
                        text: s(&source.text),
                        stamp: s(&format_date_unix(source.recorded_at)),
                    })
                })
                .collect();
            ui.set_mention_inbox_items(model(items));
            ui.set_mention_inbox_loading(false);
            // Fetch the missing pictures and bind each onto every inbox row
            // from that sender once decoded.
            for (sender_id, url) in pending_fetches {
                spawn_picture_fetch(ui.as_weak(), b.tokio_handle(), url, move |ui, pixels| {
                    bind_picture_to_rows(
                        &ui.get_mention_inbox_items(),
                        pixels,
                        false,
                        |row: &MentionInboxItem| row.sender_id.as_str() == sender_id,
                        |row, img| {
                            row.picture = img;
                            row.has_picture = true;
                        },
                    );
                });
            }
        });
    });
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

    fn message_record(id: impl Into<String>, kind: u64) -> AppMessageRecord {
        AppMessageRecord {
            message_id_hex: id.into(),
            direction: "incoming".into(),
            group_id_hex: "chat-0".into(),
            sender: OTHER.into(),
            plaintext: "message".into(),
            kind,
            tags: Vec::new(),
            source_epoch: None,
            recorded_at: 0,
            received_at: 0,
            insert_order: 0,
        }
    }

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

    #[test]
    fn mention_inbox_collects_across_chats_and_sorts_newest_first() {
        let me = npub_for_account_id(ME).unwrap();
        let sources = vec![
            MentionInboxSource {
                group_id: "chat-0".into(),
                message_id: "older".into(),
                sender_id: OTHER.into(),
                text: format!("older ping {me}"),
                recorded_at: 10,
            },
            MentionInboxSource {
                group_id: "chat-1".into(),
                message_id: "newer".into(),
                sender_id: OTHER.into(),
                text: format!("newer ping {me}"),
                recorded_at: 20,
            },
            MentionInboxSource {
                group_id: "chat-2".into(),
                message_id: "outgoing".into(),
                sender_id: ME.into(),
                text: format!("I mentioned myself {me}"),
                recorded_at: 30,
            },
            MentionInboxSource {
                group_id: "chat-0".into(),
                message_id: "not-a-mention".into(),
                sender_id: OTHER.into(),
                text: "ordinary message".into(),
                recorded_at: 40,
            },
        ];

        let items = filter_and_sort_mention_sources(sources, ME);
        assert_eq!(
            items
                .iter()
                .map(|item| (item.group_id.as_str(), item.message_id.as_str()))
                .collect::<Vec<_>>(),
            vec![("chat-1", "newer"), ("chat-0", "older")]
        );
    }

    #[test]
    fn mention_inbox_uses_current_edited_text() {
        let me = npub_for_account_id(ME).unwrap();
        let items = filter_and_sort_mention_sources(
            vec![MentionInboxSource {
                group_id: "chat-0".into(),
                message_id: "edited".into(),
                sender_id: OTHER.into(),
                text: format!("edited to mention {me}"),
                recorded_at: 10,
            }],
            ME,
        );

        assert_eq!(items.len(), 1);
        assert!(items[0].text.contains("edited to mention"));
    }

    #[test]
    fn mention_inbox_keeps_only_the_newest_bounded_items() {
        let me = npub_for_account_id(ME).unwrap();
        let sources = (0..3)
            .map(|recorded_at| MentionInboxSource {
                group_id: "chat-0".into(),
                message_id: format!("message-{recorded_at}"),
                sender_id: OTHER.into(),
                text: format!("ping {me}"),
                recorded_at,
            })
            .collect();

        let items = filter_sort_and_truncate_mention_sources(sources, ME, 2);

        assert_eq!(items.len(), 2);
        assert_eq!(items[0].recorded_at, 2);
        assert_eq!(items[1].recorded_at, 1);
    }

    #[test]
    fn centered_visible_window_stays_bounded_around_target() {
        assert_eq!(centered_visible_window(200, 100, 80), 60..140);
        assert_eq!(centered_visible_window(200, 3, 80), 0..80);
        assert_eq!(centered_visible_window(20, 3, 80), 0..20);
    }

    #[test]
    fn duplicate_inbox_refreshes_coalesce_per_account() {
        let account_id = "coalesce-test-account";
        assert!(begin_mention_inbox_refresh(account_id));
        assert!(!begin_mention_inbox_refresh(account_id));
        finish_mention_inbox_refresh(account_id);
        assert!(begin_mention_inbox_refresh(account_id));
        finish_mention_inbox_refresh(account_id);
    }

    #[test]
    fn navigation_window_caps_bubbles_and_keeps_control_events() {
        let mut records: Vec<AppMessageRecord> = (0..200)
            .map(|index| message_record(format!("message-{index:03}"), CHAT_MESSAGE_KIND))
            .collect();
        records.push(message_record("reaction", 7));

        let (window, recent_limit) =
            mention_navigation_window(&records, "message-100", MESSAGE_WINDOW).unwrap();

        assert_eq!(
            window
                .iter()
                .filter(|record| is_visible_chat_message(record))
                .count(),
            MESSAGE_WINDOW
        );
        assert!(
            window
                .iter()
                .any(|record| record.message_id_hex == "message-100")
        );
        assert!(
            window
                .iter()
                .any(|record| record.message_id_hex == "reaction")
        );
        assert_eq!(recent_limit, 141);
    }

    #[test]
    fn navigation_window_keeps_old_targets_reachable_after_refresh() {
        let records: Vec<AppMessageRecord> = (0..1_000)
            .map(|index| message_record(format!("message-{index:04}"), CHAT_MESSAGE_KIND))
            .collect();

        let (window, recent_limit) =
            mention_navigation_window(&records, "message-0100", MESSAGE_WINDOW).unwrap();

        assert!(
            window
                .iter()
                .any(|record| record.message_id_hex == "message-0100")
        );
        assert_eq!(recent_limit, 940);
    }
}
