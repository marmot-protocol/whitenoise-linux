// Telemetry + audit-log endpoint/token config, kept in one editable place
// (`observability.toml`) instead of inline Rust consts. Not secret — just
// centralized so the values are easy to change.
//
// The repo's `observability.toml` is embedded at build time as the default, so
// the binary always has working values. A copy at `$DM_HOME/observability.toml`
// overrides it at runtime (edit + restart, no rebuild). Endpoints/tokens are
// fed to marmot's telemetry exporter + audit-log tracker in `backend.rs`.

use std::path::Path;

use serde::Deserialize;

/// The build-time default, baked from the repo file.
const EMBEDDED: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/observability.toml"));

#[derive(Clone, Debug, Deserialize)]
pub struct ObservabilityConfig {
    /// OTLP/HTTP metrics endpoint (`https://…/v1/metrics`).
    pub otlp_metrics_endpoint: String,
    /// Bearer token for the OTLP collector.
    pub otlp_token: String,
    /// Goggles audit-log upload endpoint.
    pub goggles_audit_endpoint: String,
    /// Bearer token for the Goggles audit sink.
    pub goggles_token: String,
    /// OTLP resource attr `tenant` (a label, never the X-OTLP-Tenant header).
    pub tenant: String,
    /// OTLP resource attr `deployment.environment`.
    pub deployment_environment: String,
}

impl ObservabilityConfig {
    /// Load the config, preferring `$DM_HOME/observability.toml` when present
    /// and parseable, otherwise the embedded default. Never fails: a malformed
    /// override falls back to the embedded copy (which is validated at startup
    /// by construction, since it ships with the binary).
    pub fn load(home: &Path) -> Self {
        let override_path = home.join("observability.toml");
        match std::fs::read_to_string(&override_path) {
            Ok(text) => match toml::from_str(&text) {
                Ok(cfg) => return cfg,
                Err(e) => tracing::warn!(
                    target: "observability", "{} is invalid ({e}); using embedded default",
                    override_path.display()
                ),
            },
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => tracing::warn!(
                target: "observability", "could not read {} ({e}); using embedded default",
                override_path.display()
            ),
            Err(_) => {}
        }
        Self::embedded()
    }

    /// The embedded default. Panics only if the repo's `observability.toml` is
    /// malformed — a build-time authoring error, caught on first run.
    pub fn embedded() -> Self {
        toml::from_str(EMBEDDED).expect("embedded observability.toml must be valid TOML")
    }
}
