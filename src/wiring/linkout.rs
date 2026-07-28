use crate::*;

fn external_link_host(url: &str) -> Option<String> {
    let url = reqwest::Url::parse(url).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    url.host_str().map(str::to_ascii_lowercase)
}

fn is_external_link_host_trusted(settings: &Settings, host: Option<&str>) -> bool {
    host.is_some_and(|host| settings.is_link_host_trusted(host))
}

fn push_trusted_link_hosts(ui: &WhiteNoiseLinux, settings: &Settings) {
    let hosts: Vec<SharedString> = settings
        .trusted_link_hosts
        .iter()
        .cloned()
        .map(SharedString::from)
        .collect();
    ui.set_trusted_link_hosts(ModelRc::new(VecModel::from(hosts)));
}

/// Wire chat-link handling, confirmation, and the persisted trusted-host list.
pub(crate) fn wire_linkout(ui: &WhiteNoiseLinux, cx: &Cx) {
    let Cx {
        settings_cell,
        backend_cell,
        ..
    } = cx.clone();

    push_trusted_link_hosts(ui, &settings_cell.borrow());

    // Markdown links/anchors in chat bubbles activate through this global so
    // they don't have to be plumbed through every row component. nostr: profile
    // references (@mentions render as `nostr:npub…` anchors) and marmot://
    // profile deep links open the in-app profile modal; everything else goes
    // to the platform handler (xdg-open).
    ui.global::<Linkout>().on_open({
        let weak = ui.as_weak();
        let backend_cell = backend_cell.clone();
        let settings_cell = settings_cell.clone();
        move |url| {
            let url = url.as_str();
            if let Some(reference) = url
                .strip_prefix("nostr:")
                .or_else(|| deeplink::profile_link_ref(url))
                && let Some(hex) = nostr_ref_to_hex(reference)
                && let Some(ui) = weak.upgrade()
            {
                open_profile_modal(&ui, &backend_cell, &hex);
                return;
            }
            // We are the OS handler for marmot:// — handing an unresolvable
            // link to xdg-open would just relaunch this app.
            if deeplink::is_marmot_url(url) {
                tracing::warn!(target: "deeplink", "unhandled marmot:// link: {url}");
                return;
            }
            // Anything else is an outside link. Previously approved exact
            // hosts open directly; all others arm the confirmation modal.
            let host = external_link_host(url);
            if is_external_link_host_trusted(&settings_cell.borrow(), host.as_deref()) {
                open_external(url);
                return;
            }
            if let Some(ui) = weak.upgrade() {
                ui.set_pending_external_link(url.into());
                ui.set_pending_external_host(host.unwrap_or_else(|| url_host(url)).into());
            }
        }
    });

    ui.global::<AppState>().on_confirm_external_link({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |url, remember_host| {
            if remember_host && let Some(host) = external_link_host(url.as_str()) {
                let mut settings = settings_cell.borrow_mut();
                if settings.trust_link_host(&host) {
                    settings.save();
                    if let Some(ui) = weak.upgrade() {
                        push_trusted_link_hosts(&ui, &settings);
                    }
                }
            }
            open_external(url.as_str());
        }
    });

    ui.global::<AppState>().on_forget_trusted_link_host({
        let weak = ui.as_weak();
        let settings_cell = settings_cell.clone();
        move |host| {
            let mut settings = settings_cell.borrow_mut();
            if settings.forget_link_host(host.as_str()) {
                settings.save();
                if let Some(ui) = weak.upgrade() {
                    push_trusted_link_hosts(&ui, &settings);
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trusted_external_link_matches_the_exact_host() {
        let mut settings = Settings::default();
        assert!(settings.trust_link_host("example.com"));

        assert!(is_external_link_host_trusted(
            &settings,
            external_link_host("https://EXAMPLE.com/path?q=1").as_deref()
        ));
        assert!(!is_external_link_host_trusted(
            &settings,
            external_link_host("https://sub.example.com/path").as_deref()
        ));
    }

    #[test]
    fn path_at_sign_cannot_impersonate_a_trusted_host() {
        let mut settings = Settings::default();
        assert!(settings.trust_link_host("trusted.example"));

        assert!(!is_external_link_host_trusted(
            &settings,
            external_link_host("https://evil.example/path@trusted.example").as_deref()
        ));
    }

    #[test]
    fn only_http_links_have_trustable_hosts() {
        assert_eq!(
            external_link_host("https://example.com/path"),
            Some("example.com".into())
        );
        assert_eq!(
            external_link_host("http://example.com/path"),
            Some("example.com".into())
        );
        assert_eq!(external_link_host("ftp://example.com/file"), None);
        assert_eq!(external_link_host("mailto:user@example.com"), None);
        assert_eq!(external_link_host("not a url"), None);
    }
}
