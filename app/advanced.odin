// Settings → Advanced: relay telemetry, audit-log recording plus the
// files it leaves on disk, the trusted-link-sites allowlist, and the
// developer-mode flag.
//
// Both observability switches read and write marmot's own settings, so
// the runtime stays the single source of truth. Where the data would go
// is separate from whether it goes: apply_observability sets the OTLP
// and Goggles routes at boot, and nothing is exported or uploaded until
// the matching toggle is on.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"

import marmot "../marmot"

APP_VERSION :: "2026.9.15+1" // YYYY.M.D + increasing build revision

// Endpoints and tokens, embedded like the slint app does. Not secret.
OBSERVABILITY_TOML :: #load("../observability.toml", string)

Audit_File :: struct {
	path:  string,
	name:  string,
	label: string, // "48.5 KB · 2026-08-24 · 17:04"
}

// ── Page ────────────────────────────────────────────────────────────

settings_advanced :: proc(ui: ^Ui_State) {
	eyebrow("SECURITY & PRIVACY")
	if clay.UI(clay.ID("RowTelemetry"))(srow()) {
		row_labels("Share usage and diagnostics", "Share aggregate performance timings and relay diagnostics. Nothing is sent while this is off.")
		toggle("TgTelemetry", ui.telemetry_enabled)
	}
	clay.Text(tr("Diagnostics includes a random installation identifier until you turn sharing off, app and device details, and relay labels. The collector receives your IP address. Message contents and account or group identifiers are excluded. Turning sharing off stops future uploads; already sent data cannot be recalled. Audit logs are separate."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	clay.Text(tr("Diagnostics is sent to the operator of otlp.ipf.dev unless you configured another collector. Its retention policy has not been verified here. Usage event export is not configured."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	if clay.UI(clay.ID("RowAudit"))(srow()) {
		row_labels("Audit logs", "Record group audit log files on this device. Identifiers are hashed.")
		toggle("TgAudit", ui.audit_enabled)
	}

	eyebrow("TRUSTED LINK SITES")
	if len(ui.prefs.trusted_sites) == 0 {
		if clay.UI(clay.ID("RowNoTrusted"))(srow()) {
			clay.Text(tr("No trusted sites."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		}
	}
	for site, i in ui.prefs.trusted_sites {
		relay_row("TrustRow", "TrustRemove", u32(i), site)
	}
	if len(ui.prefs.trusted_sites) > 0 {
		if clay.UI(clay.ID("TrustActions"))({layout = {childGap = 8}}) {
			micro_button("TrustForgetAll", ui.keys_confirm == "TrustForgetAll" ? "Confirm forget all" : "Forget all", DANGER)
		}
	}
	clay.Text(tr("Links to these exact sites open without confirmation."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})

	eyebrow("AUDIT LOG FILES")
	if len(ui.audit_files) == 0 {
		if clay.UI(clay.ID("RowNoAudit"))(srow()) {
			clay.Text(tr("No audit log files."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		}
	}
	for file, i in ui.audit_files {
		if clay.UI(clay.ID("AuditRow", u32(i)))(
		{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12), childGap = 8, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : ROW_BG, cornerRadius = rr(8)},
		) {
			if clay.UI(clay.ID("AuditRowCol", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}}) {
				clay.Text(file.name, {fontId = FONT_MONO, fontSize = 12, textColor = TEXT})
				clay.Text(file.label, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
			id := audit_delete_id(i)
			micro_button(id, ui.keys_confirm == id ? "Confirm delete" : "Delete", DANGER)
		}
	}
	if clay.UI(clay.ID("AuditRefreshRow"))({layout = {childGap = 8}}) {
		micro_button("AuditRefresh", "Refresh")
	}
	clay.Text(tr("Deleting the file being recorded rotates it. Recording continues in a fresh file."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})

	eyebrow("DEVELOPER")
	if clay.UI(clay.ID("RowDevMode"))(srow()) {
		row_labels("Developer mode", "Shows diagnostics and MLS internals. Adds a Debug entry with account, key-packages, and group state.")
		toggle("TgDevMode", ui.prefs.dev_mode)
	}
}

// Per-row id for the two-step delete; hashed as a plain string to dodge
// the indexed-id binding bug (PORT.md Quirks).
audit_delete_id :: proc(index: int) -> string {
	return fmt.tprintf("AuditDelete%d", index)
}

// ── Interactions ────────────────────────────────────────────────────

handle_advanced :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clay.PointerOver(clay.ID("TgTelemetry")) {
		set_telemetry(ui, client, !ui.telemetry_enabled)
		return
	}
	if clay.PointerOver(clay.ID("TgAudit")) {
		set_audit(ui, client, !ui.audit_enabled)
		return
	}
	if clay.PointerOver(clay.ID("TgDevMode")) {
		flip(ui, &ui.prefs.dev_mode)
		return
	}
	if clicked("AuditRefresh") {
		audit_scan(ui, client)
		return
	}
	for file, i in ui.audit_files {
		id := audit_delete_id(i)
		if clicked(id) {
			if armed(ui, id) {
				audit_delete(ui, client, file.path)
			}
			return
		}
	}
	for site, i in ui.prefs.trusted_sites {
		if clay.PointerOver(clay.ID("TrustRemove", u32(i))) {
			delete(site)
			ordered_remove(&ui.prefs.trusted_sites, i)
			save_settings(ui)
			return
		}
	}
	if clicked("TrustForgetAll") {
		if armed(ui, "TrustForgetAll") {
			for site in ui.prefs.trusted_sites {
				delete(site)
			}
			clear(&ui.prefs.trusted_sites)
			save_settings(ui)
		}
		return
	}
	ui.keys_confirm = "" // a click anywhere else disarms
}

// ── Telemetry and audit settings ────────────────────────────────────

load_advanced :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil {
		return
	}

	telemetry: ^marmot.Diagnostics_Settings
	if marmot.diagnostics_settings(client, &telemetry) == .OK {
		ui.telemetry_enabled = telemetry.decision == .Granted
		marmot.diagnostics_settings_free(telemetry)
	}

	audit: ^marmot.Audit_Log_Settings
	if marmot.audit_log_settings(client, &audit) == .OK {
		ui.audit_enabled = audit.enabled
		marmot.audit_log_settings_free(audit)
	}

	audit_scan(ui, client)
}

// An explicit toggle grants the expanded scope; startup never grants consent.
set_telemetry :: proc(ui: ^Ui_State, client: ^marmot.Client, on: bool) {
	out: ^marmot.Diagnostics_Settings
	if client == nil || marmot.set_diagnostics_consent(client, on ? .Grant : .Decline, &out) != .OK {
		ui.telemetry_enabled = false // MDK fails closed if the receipt cannot be saved.
		ui.client_status = tr("Couldn't change diagnostics sharing. Please try again.")
		return
	}
	ui.telemetry_enabled = out.decision == .Granted
	marmot.diagnostics_settings_free(out)
}

// Flip the recorder, keeping the runtime's content posture.
set_audit :: proc(ui: ^Ui_State, client: ^marmot.Client, on: bool) {
	cur: ^marmot.Audit_Log_Settings
	if client == nil || marmot.audit_log_settings(client, &cur) != .OK {
		ui.client_status = fmt.aprintf(tr("Couldn't change audit logs. %s"), marmot.last_error())
		return
	}
	next := marmot.Audit_Log_Settings{enabled = on, data_mode = cur.data_mode}
	marmot.audit_log_settings_free(cur)

	out: ^marmot.Audit_Log_Settings
	if marmot.set_audit_log_settings(client, &next, &out) != .OK {
		ui.client_status = fmt.aprintf(tr("Couldn't change audit logs. %s"), marmot.last_error())
		return
	}
	ui.audit_enabled = out.enabled
	marmot.audit_log_settings_free(out)

	audit_scan(ui, client)
}

// ── Audit-log files ─────────────────────────────────────────────────

audit_scan :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for &f in ui.audit_files {
		delete(f.path)
		delete(f.name)
		delete(f.label)
	}
	clear(&ui.audit_files)
	ui.audit_scanned = true

	list: ^marmot.Audit_Log_File_List
	if client == nil || marmot.audit_log_files(client, &list) != .OK {
		return
	}
	defer marmot.audit_log_file_list_free(list)

	for i in 0 ..< int(list.len) {
		file := list.items[i]
		append(&ui.audit_files, Audit_File {
			path  = strings.clone(string(file.path)),
			name  = strings.clone(string(file.file_name)),
			label = audit_label(i64(file.size_bytes), file.has_modified_at_ms ? i64(file.modified_at_ms) : 0),
		})
	}
}

// "48.5 KB · 2026-08-24 · 17:04", or just the size when marmot reports
// no modification time.
audit_label :: proc(size_bytes: i64, modified_at_ms: i64) -> string {
	if modified_at_ms == 0 {
		return strings.clone(human_size(size_bytes))
	}
	stamp := time.unix(i64(local_seconds(u64(modified_at_ms))), 0)
	year, month, day := time.date(stamp)
	hour, minute, _ := time.clock_from_time(stamp)
	return fmt.aprintf("%s · %04d-%02d-%02d · %02d:%02d", human_size(size_bytes), year, int(month), day, hour, minute)
}

// marmot owns these files (it may be recording into one right now), so
// deletion goes through the runtime, which rotates instead of yanking.
audit_delete :: proc(ui: ^Ui_State, client: ^marmot.Client, path: string) {
	result: ^marmot.Audit_Log_Delete_Result
	if client == nil || marmot.delete_audit_log_file(client, strings.clone_to_cstring(path, context.temp_allocator), &result) != .OK {
		ui.client_status = fmt.aprintf(tr("Couldn't delete the audit log file. %s"), marmot.last_error())
		return
	}
	ui.client_status = result.still_recording ? tr("Deleted. Recording continues in a fresh file.") : tr("Audit log file deleted.")
	marmot.audit_log_delete_result_free(result)

	audit_scan(ui, client)
}

// ── Observability routes ────────────────────────────────────────────

Observability :: struct {
	otlp_metrics_endpoint:  string,
	otlp_token:             string,
	goggles_audit_endpoint: string,
	goggles_token:          string,
	tenant:                 string,
	deployment_environment: string,
}

// `key = "value"` lines only; comments and anything else are skipped.
obs_parse :: proc(text: string, out: ^Observability) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 || strings.has_prefix(trimmed, "#") {
			continue
		}
		value := strings.trim(strings.trim_space(trimmed[eq + 1:]), `"`)
		switch strings.trim_space(trimmed[:eq]) {
		case "otlp_metrics_endpoint":
			out.otlp_metrics_endpoint = value
		case "otlp_token":
			out.otlp_token = value
		case "goggles_audit_endpoint":
			out.goggles_audit_endpoint = value
		case "goggles_token":
			out.goggles_token = value
		case "tenant":
			out.tenant = value
		case "deployment_environment":
			out.deployment_environment = value
		}
	}
}

// Tell the runtime where telemetry and audit uploads would go. Borrowed
// inputs only, so everything here can live in the temp allocator.
apply_observability :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil {
		return
	}
	cfg: Observability
	obs_parse(OBSERVABILITY_TOML, &cfg)

	// A copy in the data dir wins, so endpoints change without a rebuild.
	if data, err := os.read_entire_file(fmt.tprintf("%s/observability.toml", data_home), context.temp_allocator); err == nil {
		obs_parse(string(data), &cfg)
	}

	install_id: cstring
	marmot.telemetry_install_id(client, &install_id)
	defer if install_id != nil {
		marmot.string_free(install_id)
	}

	// Every resource attribute is required: one NULL and the runtime
	// rejects the whole route.
	resource := marmot.Relay_Telemetry_Resource {
		service_version         = APP_VERSION,
		service_instance_id     = install_id != nil ? install_id : "unknown",
		deployment_environment  = obs_cstr(cfg.deployment_environment, "development"),
		tenant                  = obs_cstr(cfg.tenant, "whitenoise-linux"),
		os_type                 = "linux",
		os_version              = obs_file_cstr("/proc/sys/kernel/osrelease"),
		device_model_identifier = obs_file_cstr("/sys/devices/virtual/dmi/id/product_name"),
	}
	route := marmot.Relay_Telemetry_Runtime_Config {
		otlp_endpoint              = obs_cstr(cfg.otlp_metrics_endpoint),
		authorization_bearer_token = obs_cstr(cfg.otlp_token),
		resource                   = &resource,
	}
	if marmot.set_relay_telemetry_runtime_config(client, &route) != .OK {
		fmt.eprintfln("telemetry route rejected: %s", marmot.last_error())
	}

	tracker := marmot.Audit_Log_Tracker_Config {
		endpoint = obs_cstr(cfg.goggles_audit_endpoint),
		authorization_bearer_token = obs_cstr(cfg.goggles_token),
		source = {
			device_label = obs_cstr(ui.account_ref, "whitenoise-linux"),
			platform = "linux",
			app_version = APP_VERSION,
		},
	}
	out: ^marmot.Audit_Log_Tracker_Config
	if marmot.set_audit_log_tracker_config(client, &tracker, &out) != .OK {
		fmt.eprintfln("audit-log tracker config rejected: %s", marmot.last_error())
		return
	}
	marmot.audit_log_tracker_config_free(out)
}

obs_cstr :: proc(s: string, fallback: string = "") -> cstring {
	text := len(s) > 0 ? s : fallback
	if len(text) == 0 {
		return nil
	}
	return strings.clone_to_cstring(text, context.temp_allocator)
}

// Host facts (kernel release, DMI product name); "unknown" when the
// file is missing, since the runtime rejects a NULL attribute.
obs_file_cstr :: proc(path: string) -> cstring {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "unknown"
	}
	return obs_cstr(strings.trim_space(string(data)), "unknown")
}
