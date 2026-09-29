// Advanced page: optional observability configuration and the audit-file label.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
obs_parse_reads_keys :: proc(t: ^testing.T) {
	cfg: Observability
	obs_parse(
		"otlp_metrics_endpoint = \"https://metrics.example/v1/metrics\"\n" +
		"otlp_token = \"metrics-test\"\n" +
		"goggles_audit_endpoint = \"https://audit.example/\"\n" +
		"goggles_token = \"audit-test\"\n" +
		"tenant = \"test\"\n" +
		"deployment_environment = \"development\"\n",
		&cfg,
	)
	testing.expect_value(t, cfg.otlp_metrics_endpoint, "https://metrics.example/v1/metrics")
	testing.expect_value(t, cfg.otlp_token, "metrics-test")
	testing.expect_value(t, cfg.goggles_audit_endpoint, "https://audit.example/")
	testing.expect_value(t, cfg.goggles_token, "audit-test")
	testing.expect_value(t, cfg.tenant, "test")
	testing.expect_value(t, cfg.deployment_environment, "development")

	// A later file overrides only the keys it names.
	obs_parse("tenant = \"other\"\n# tenant = \"comment\"\n", &cfg)
	testing.expect_value(t, cfg.tenant, "other")
	testing.expect_value(t, cfg.deployment_environment, "development")
	testing.expect_value(t, cfg.otlp_token, "metrics-test")
	testing.expect_value(t, cfg.goggles_token, "audit-test")
}

@(test)
obs_config_path :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	previous_home := os.get_env("HOME", context.temp_allocator)
	defer {
		if previous_config == "" {
			os.unset_env("XDG_CONFIG_HOME")
		} else {
			os.set_env("XDG_CONFIG_HOME", previous_config)
		}
		if previous_home == "" {
			os.unset_env("HOME")
		} else {
			os.set_env("HOME", previous_home)
		}
	}

	// Resolve paths only: none of these locations is read or written.
	os.set_env("XDG_CONFIG_HOME", "/isolated-config")
	os.set_env("HOME", "/isolated-home")
	when ODIN_OS == .Windows {
		base, err := os.user_config_dir(context.temp_allocator)
		if !testing.expect(t, err == nil) {return}
		testing.expect_value(
			t,
			settings_path(filename = "observability.toml"),
			fmt.tprintf("%s/whitenoise/observability.toml", base),
		)
	} else when ODIN_OS == .Darwin {
		testing.expect_value(
			t,
			settings_path(filename = "observability.toml"),
			"/isolated-home/Library/Application Support/whitenoise/observability.toml",
		)
	} else {
		testing.expect_value(
			t,
			settings_path(filename = "observability.toml"),
			"/isolated-config/whitenoise/observability.toml",
		)
		os.unset_env("XDG_CONFIG_HOME")
		testing.expect_value(
			t,
			settings_path(filename = "observability.toml"),
			"/isolated-home/.config/whitenoise/observability.toml",
		)
		os.set_env("XDG_CONFIG_HOME", "")
		testing.expect_value(
			t,
			settings_path(filename = "observability.toml"),
			"/isolated-home/.config/whitenoise/observability.toml",
		)
		os.unset_env("HOME")
		testing.expect_value(t, settings_path(filename = "observability.toml"), "")
	}
}

@(test)
obs_override_precedence :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("", "wn-observability", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	path := fmt.tprintf("%s/observability.toml", home)
	tokens :: "otlp_token = \"metrics-test\"\ngoggles_token = \"audit-test\"\n"

	// A missing override keeps both the public routes and embedded tokens.
	cfg := obs_load(path, tokens)
	testing.expect_value(t, cfg.otlp_metrics_endpoint, "https://otlp.ipf.dev/v1/metrics")
	testing.expect_value(
		t,
		cfg.goggles_audit_endpoint,
		"https://goggles.ipf.dev/api/v1/audit-logs/",
	)
	testing.expect_value(t, cfg.tenant, "whitenoise-linux")
	testing.expect_value(t, cfg.deployment_environment, "production")
	testing.expect_value(t, cfg.otlp_token, "metrics-test")
	testing.expect_value(t, cfg.goggles_token, "audit-test")

	override ::
		"otlp_metrics_endpoint = \"https://metrics.example/v1/metrics\"\n" +
		"otlp_token = \"\"\n" +
		"tenant = \"test-tenant\"\n" +
		"deployment_environment = \"development\"\n"
	if !testing.expect(t, os.write_entire_file(path, override) == nil) {return}
	cfg = obs_load(path, tokens)
	testing.expect_value(t, cfg.otlp_metrics_endpoint, "https://metrics.example/v1/metrics")
	testing.expect_value(t, cfg.otlp_token, "")
	testing.expect_value(
		t,
		cfg.goggles_audit_endpoint,
		"https://goggles.ipf.dev/api/v1/audit-logs/",
	)
	testing.expect_value(t, cfg.goggles_token, "audit-test")
	testing.expect_value(t, cfg.tenant, "test-tenant")
	testing.expect_value(t, cfg.deployment_environment, "development")
}

@(test)
obs_ignores_data_directory :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-observability-data", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous_data := data_home
	data_home = home
	defer data_home = previous_data
	override :: "tenant = \"data-directory-must-not-win\"\notlp_token = \"data-test\"\n"
	data_path := fmt.tprintf("%s/observability.toml", home)
	if !testing.expect(t, os.write_entire_file(data_path, override) == nil) {return}

	cfg := obs_load(fmt.tprintf("%s/missing-config/observability.toml", home), "")
	testing.expect_value(t, cfg.tenant, "whitenoise-linux")
	testing.expect_value(t, cfg.otlp_token, "")
	// A failed config-directory lookup must not fall back to data or cwd.
	cfg = obs_load("", "")
	testing.expect_value(t, cfg.tenant, "whitenoise-linux")
	testing.expect_value(t, cfg.otlp_token, "")
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
