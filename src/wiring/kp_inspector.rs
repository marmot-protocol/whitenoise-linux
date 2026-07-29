use crate::*;

// ─── KP inspector (dev-mode settings tab) ──────────────────────────────
//
// Decoded MLS key packages: the active account's durably owned KPs, plus a
// fetch-and-decode of any pubkey's latest published KP. Both backend calls
// `block_on` the backend runtime, so each handler runs on a plain thread —
// never a runtime worker ("Cannot start a runtime from within a runtime").

pub(crate) fn wire_kp_inspector(ui: &WhiteNoiseLinux, cx: &Cx) {
    let Cx { backend_cell, .. } = cx.clone();

    ui.global::<AppState>().on_kp_inspector_refresh({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            ui.set_kp_inspector_busy(true);
            ui.set_kp_inspector_status(s(""));
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let reports = b.inspect_own_key_packages();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_kp_inspector_busy(false);
                    // Dev-only surface: statuses stay untranslated, like the
                    // debug pane's JSON dumps.
                    ui.set_kp_inspector_status(s(&format!(
                        "{} owned key package{}",
                        reports.len(),
                        if reports.len() == 1 { "" } else { "s" }
                    )));
                    let rows: Vec<KpInspection> =
                        reports.iter().map(kp_report_to_ui).collect();
                    ui.set_kp_inspector_own(ModelRc::new(VecModel::from(rows)));
                });
            });
        }
    });

    ui.global::<AppState>().on_kp_inspect_peer({
        let weak = ui.as_weak();
        move |query| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(b) = backend_cell.lock().unwrap().clone() else {
                return;
            };
            let query = query.to_string();
            ui.set_kp_peer_busy(true);
            ui.set_kp_peer_loaded(false);
            ui.set_kp_peer_status(s(""));
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = b.inspect_contact_key_package(&query);
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(ui) = weak.upgrade() else { return };
                    ui.set_kp_peer_busy(false);
                    match result {
                        Ok(report) => {
                            ui.set_kp_peer_result(kp_report_to_ui(&report));
                            ui.set_kp_peer_loaded(true);
                        }
                        Err(e) => ui.set_kp_peer_status(s(&e.to_string())),
                    }
                });
            });
        }
    });
}

/// Backend inspection report → Slint row. Timestamps come out pretty-formatted
/// here so the UI renders every field verbatim.
fn kp_report_to_ui(r: &KpInspectionReport) -> KpInspection {
    KpInspection {
        owner: s(&r.owner_hex),
        kp_ref: s(&r.kp_ref_hex),
        event_id: s(&r.event_id),
        published_at: s(&format_date_unix(r.published_at)),
        relays: s(&r.source_relays.join(", ")),
        local: r.local,
        on_relay: r.relay,
        decode_error: s(&r.decode_error),
        ciphersuite: s(&r.ciphersuite),
        last_resort: r.last_resort,
        lifetime: s(&format!(
            "{} → {}",
            format_date_unix(r.not_before),
            format_date_unix(r.not_after)
        )),
        credential_type: s(&r.credential_type),
        signature_key: s(&r.signature_key_hex),
        cap_versions: s(&r.cap_versions),
        cap_ciphersuites: s(&r.cap_ciphersuites),
        cap_extensions: s(&r.cap_extensions),
        cap_proposals: s(&r.cap_proposals),
        cap_credentials: s(&r.cap_credentials),
        kp_extensions: s(&r.kp_extensions),
        leaf_extensions: s(&r.leaf_extensions),
        raw_json: s(&r.raw_json),
    }
}
