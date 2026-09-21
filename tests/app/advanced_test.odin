// Advanced page: observability.toml parsing and the audit-file label.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:testing"
import "core:time"

@(test)
obs_parse_reads_keys :: proc(t: ^testing.T) {
	cfg: Observability
	obs_parse(OBSERVABILITY_TOML, &cfg)

	// The embedded defaults must survive the parse, or boot wires the
	// runtime to nothing and telemetry silently never leaves.
	testing.expect_value(t, cfg.otlp_metrics_endpoint, "https://otlp.ipf.dev/v1/metrics")
	testing.expect_value(t, cfg.tenant, "whitenoise-linux")
	testing.expect_value(t, cfg.deployment_environment, "production")
	testing.expect(t, len(cfg.otlp_token) > 0)
	testing.expect(t, len(cfg.goggles_audit_endpoint) > 0)
	testing.expect(t, len(cfg.goggles_token) > 0)

	// A later file overrides only the keys it names.
	obs_parse("tenant = \"other\"\n# tenant = \"comment\"\n", &cfg)
	testing.expect_value(t, cfg.tenant, "other")
	testing.expect_value(t, cfg.deployment_environment, "production")
}

@(test)
audit_label_formats :: proc(t: ^testing.T) {
	size_only := audit_label(1500, 0)
	defer delete(size_only)
	testing.expect_value(t, size_only, "1.5 KB")

	// The stamp shows local time (2026-02-02 02:40 UTC shifted by the
	// machine's zone), so the expected clock is derived through the same
	// shift; the assertion guards the label's format, not the zone.
	stamp := time.unix(i64(local_seconds(1_770_000_000_000)), 0)
	year, month, day := time.date(stamp)
	hour, minute, _ := time.clock_from_time(stamp)
	expected := fmt.aprintf(
		"2.0 MB · %04d-%02d-%02d · %02d:%02d",
		year,
		int(month),
		day,
		hour,
		minute,
	)
	defer delete(expected)

	dated := audit_label(2_000_000, 1_770_000_000_000)
	defer delete(dated)
	testing.expect_value(t, dated, expected)
}
