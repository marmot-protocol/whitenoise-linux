//! Network-relay UI plumbing: push the relay list / suggested-relay chips
//! into the Slint models, validate user-entered relay URLs, and track
//! whether the booted relay set diverged from the configured one (the
//! "restart required" banner).

use crate::*;

/// Push the on-disk relay list into the UI model. Used after add/remove.
pub(crate) fn push_network_relays(ui: &WhiteNoiseLinux, list: &[String]) {
    let rows: Vec<SharedString> = list.iter().cloned().map(SharedString::from).collect();
    ui.set_network_relays(ModelRc::new(VecModel::from(rows)));
    // Keep the one-click suggestions in sync: only offer ones not already added.
    push_suggested_relays(ui, list);
    refresh_network_restart_required(ui);
}

/// Well-known public relays offered as one-click adds on the get-started screen.
/// DEV POLICY: whitenoise official relays only while in development — these are
/// where the mobile apps publish, so dev peers are always mutually discoverable.
/// Before release, broaden again (e.g. relay.primal.net, relay.ditto.pub).
pub(crate) const SUGGESTED_RELAYS: &[&str] = &[
    "wss://relay.eu.whitenoise.chat",
    "wss://relay.us.whitenoise.chat",
];

/// Publish the suggested-relay chips = `SUGGESTED_RELAYS` minus whatever the user
/// already has, so a suggestion vanishes once it's added.
pub(crate) fn push_suggested_relays(ui: &WhiteNoiseLinux, current: &[String]) {
    let suggestions: Vec<SharedString> = SUGGESTED_RELAYS
        .iter()
        .filter(|s| !current.iter().any(|u| u.eq_ignore_ascii_case(s)))
        .map(|s| SharedString::from(*s))
        .collect();
    ui.set_suggested_relays(ModelRc::new(VecModel::from(suggestions)));
}

/// Collect a `[string]` Slint model into an owned `Vec<String>`.
pub(crate) fn vec_string_from_model(model: &ModelRc<SharedString>) -> Vec<String> {
    model.iter().map(|s| s.to_string()).collect()
}

/// Validate a user-entered relay URL. Trim is the caller's job. Returns the
/// localized message for the first problem found, surfaced inline under the
/// add-relay field.
pub(crate) fn validate_relay_url(url: &str) -> Result<(), String> {
    let copy = error_copy();
    if url.is_empty() {
        return Err(copy.relay_url_empty);
    }
    let rest = ["wss://", "ws://"]
        .iter()
        .find(|scheme| {
            url.get(..scheme.len())
                .is_some_and(|p| p.eq_ignore_ascii_case(scheme))
        })
        .map(|scheme| &url[scheme.len()..]);
    let Some(rest) = rest else {
        return Err(copy.relay_url_scheme);
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty() {
        return Err(copy.relay_url_no_host);
    }
    if url.contains(char::is_whitespace) {
        return Err(copy.relay_url_invalid);
    }
    Ok(())
}

pub(crate) fn relay_sets_differ(current: &[String], booted: &[String]) -> bool {
    use std::collections::BTreeSet;

    let current: BTreeSet<&str> = current.iter().map(String::as_str).collect();
    let booted: BTreeSet<&str> = booted.iter().map(String::as_str).collect();
    current != booted
}

pub(crate) fn refresh_network_restart_required(ui: &WhiteNoiseLinux) {
    let current = vec_string_from_model(&ui.get_network_relays());
    let booted = vec_string_from_model(&ui.get_network_booted_relays());
    ui.set_network_restart_required(relay_sets_differ(&current, &booted));
}

/// Push the booted-relays list + current health into the UI. Called after
/// the backend finishes booting.
pub(crate) fn refresh_network_post_boot(backend: &Arc<Backend>, ui: &WhiteNoiseLinux) {
    let booted: Vec<SharedString> = backend
        .booted_relays()
        .iter()
        .cloned()
        .map(SharedString::from)
        .collect();
    ui.set_network_booted_relays(ModelRc::new(VecModel::from(booted)));
    refresh_network_restart_required(ui);
    // `relay_health` does a `block_on` into the relay plane — poll it from a
    // worker so this post-boot UI pass never stalls the event loop.
    let weak = ui.as_weak();
    let backend = backend.clone();
    std::thread::spawn(move || {
        let (connected, total) = backend.relay_health();
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_network_connected(connected as i32);
            ui.set_network_total(total as i32);
            // Mark the first sync so the chat-list footer leaves "SYNCING…"
            // and the 1s timer starts counting up from a real baseline.
            ui.set_sync_secs(0);
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn relay_sets_differ_when_same_count_but_membership_changed() {
        let current = strings(&["wss://relay-a.example", "wss://relay-c.example"]);
        let booted = strings(&["wss://relay-a.example", "wss://relay-b.example"]);

        assert!(relay_sets_differ(&current, &booted));
    }

    #[test]
    fn relay_sets_do_not_differ_when_members_match_in_different_order() {
        let current = strings(&["wss://relay-b.example", "wss://relay-a.example"]);
        let booted = strings(&["wss://relay-a.example", "wss://relay-b.example"]);

        assert!(!relay_sets_differ(&current, &booted));
    }
}
