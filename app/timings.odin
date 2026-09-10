// Snapshot formatting and host milestones. MDK owns consent and export.
package main

import "core:fmt"
import "core:strings"
import "core:time"
import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
timing_record :: proc(client: ^marmot.Client, operation: marmot.Host_Performance, start: time.Tick) {
	if client == nil || start == {} {
		return
	}
	elapsed := u64(max(time.tick_since(start) / time.Millisecond, 0))
	// Valid enum values and a live client make rejection a programming error.
	status := marmot.record_host_performance(client, operation, elapsed, .Success)
	assert(status == .OK)
}

// null means no observations or an unbounded overflow bucket, never zero latency.
@(private)
timing_p95 :: proc(op: marmot.Performance_Operation) -> string {
	if op.attempts == 0 {
		return "null"
	}
	target := op.attempts - op.attempts / 20
	count: u64
	for bucket in op.duration_ms.buckets[:op.duration_ms.buckets_len] {
		count += bucket.count
		if count >= target {
			return fmt.tprintf("%d", bucket.upper_bound_ms)
		}
	}
	return "null"
}

@(private)
timings_json :: proc(client: ^marmot.Client) -> string {
	snapshot: ^marmot.Performance_Snapshot
	if client == nil || marmot.performance_snapshot(client, &snapshot) != .OK {
		return strings.clone(tr("Couldn't load timings. Please try again."))
	}
	defer marmot.performance_snapshot_free(snapshot)
	report := timing_snapshot_json(snapshot)
	defer delete(report)
	status: ^marmot.Diagnostics_Status
	if marmot.diagnostics_status(client, &status) != .OK {
		return strings.clone(tr("Couldn't load timings. Please try again."))
	}
	defer marmot.diagnostics_status_free(status)
	// Readiness is configuration/consent status, not proof of server receipt.
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"diagnostics_consent\": \"%v\",\n  \"otlp_export\": \"%v\",\n  \"performance\": %s\n", status.consent, status.telemetry, report)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

@(private)
timing_snapshot_json :: proc(s: ^marmot.Performance_Snapshot) -> string {
	rows := [?]struct {name: string, op: marmot.Performance_Operation} {
		{"app_start", s.app_start},
		{"directory_subscription_sync", s.directory_subscription_sync},
		{"account_reconcile", s.account_reconcile},
		{"account_open", s.account_open},
		{"account_worker_readiness", s.account_worker_readiness},
		{"account_session_open", s.account_session_open},
		{"account_group_hydration", s.account_group_hydration},
		{"account_profile_load", s.account_profile_load},
		{"account_group_read_snapshot", s.account_group_read_snapshot},
		{"account_transport_activation", s.account_transport_activation},
		{"account_subscription_registration", s.account_subscription_registration},
		{"account_catch_up", s.account_catch_up},
		{"account_sync", s.account_sync},
		{"account_setup_advisory_step", s.account_setup_advisory_step},
		{"account_bootstrap_relay_and_follow_publish", s.account_bootstrap_relay_and_follow_publish},
		{"account_default_profile_publish", s.account_default_profile_publish},
		{"account_initial_key_package_publish", s.account_initial_key_package_publish},
		{"account_initial_sync_overlap", s.account_initial_sync_overlap},
		{"account_setup_identity_local", s.account_setup_identity_local},
		{"account_setup_storage_local", s.account_setup_storage_local},
		{"account_setup_profile_local", s.account_setup_profile_local},
		{"account_setup_key_package_local", s.account_setup_key_package_local},
		{"account_setup_local_ready_handoff", s.account_setup_local_ready_handoff},
		{"account_setup_network_ready", s.account_setup_network_ready},
		{"inbound_delivery_projection", s.inbound_delivery_projection},
		{"outbound_message_send", s.outbound_message_send},
		{"outbound_message_queue_wait", s.outbound_message_queue_wait},
		{"outbound_message_local_projection", s.outbound_message_local_projection},
		{"outbound_message_local_accept", s.outbound_message_local_accept},
		{"outbound_message_publish", s.outbound_message_publish},
		{"outbound_message_response", s.outbound_message_response},
		{"host_outbound_message_visible", s.host_outbound_message_visible},
		{"host_inbound_message_visible", s.host_inbound_message_visible},
		{"group_create_queue_wait", s.group_create_queue_wait},
		{"group_create_key_package_lookup", s.group_create_key_package_lookup},
		{"group_member_key_package_prewarm", s.group_member_key_package_prewarm},
		{"group_create_key_package_cache_reuse", s.group_create_key_package_cache_reuse},
		{"group_create_key_package_network_resolution", s.group_create_key_package_network_resolution},
		{"group_create_image_preprocess", s.group_create_image_preprocess},
		{"group_create_image_upload", s.group_create_image_upload},
		{"group_create_mls_prepare_persist", s.group_create_mls_prepare_persist},
		{"group_create_pending_welcome_index", s.group_create_pending_welcome_index},
		{"group_create_welcome_publish", s.group_create_welcome_publish},
		{"group_create_local_projection_save", s.group_create_local_projection_save},
		{"group_create_response_handoff", s.group_create_response_handoff},
		{"group_create_subscription_refresh", s.group_create_subscription_refresh},
		{"group_create_post_mutation_catch_up", s.group_create_post_mutation_catch_up},
		{"group_create_total_caller_latency", s.group_create_total_caller_latency},
		{"group_invite_members", s.group_invite_members},
		{"group_invite_key_package_lookup", s.group_invite_key_package_lookup},
		{"group_invite_routing_refresh", s.group_invite_routing_refresh},
		{"group_invite_pre_send_sync", s.group_invite_pre_send_sync},
		{"group_invite_engine_publish", s.group_invite_engine_publish},
		{"group_invite_local_refresh", s.group_invite_local_refresh},
		{"group_invite_notification_trigger", s.group_invite_notification_trigger},
		{"group_invite_welcome_publish", s.group_invite_welcome_publish},
		{"group_invite_post_mutation_catch_up", s.group_invite_post_mutation_catch_up},
		{"group_promote_admin", s.group_promote_admin},
		{"group_details_read", s.group_details_read},
		{"group_conversation_snapshot_read", s.group_conversation_snapshot_read},
		{"chat_list_row_read", s.chat_list_row_read},
		{"existing_direct_conversation_read", s.existing_direct_conversation_read},
		{"group_mls_state_read", s.group_mls_state_read},
		{"group_roster_read", s.group_roster_read},
		{"group_accept_invite", s.group_accept_invite},
		{"media_upload", s.media_upload},
		{"media_download", s.media_download},
		{"media_download_queue_wait", s.media_download_queue_wait},
		{"media_download_preparation", s.media_download_preparation},
		{"media_download_host_setup", s.media_download_host_setup},
		{"media_download_response_headers", s.media_download_response_headers},
		{"media_download_first_byte", s.media_download_first_byte},
		{"media_download_body_transfer", s.media_download_body_transfer},
		{"media_download_locator_failover", s.media_download_locator_failover},
		{"media_download_ciphertext_verify", s.media_download_ciphertext_verify},
		{"media_download_decrypt", s.media_download_decrypt},
		{"media_download_plaintext_verify", s.media_download_plaintext_verify},
		{"host_splash_ready", s.host_splash_ready},
		{"host_foreground_local_ready", s.host_foreground_local_ready},
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\n  \"scope\": \"process_lifetime\",\n  \"unit\": \"milliseconds\",\n  \"timings\": {\n")
	for row, i in rows {
		op := row.op
		mean := op.attempts > 0 ? fmt.tprintf("%.3f", f64(op.duration_ms.sum_ms) / f64(op.attempts)) : "null"
		fmt.sbprintf(&b, "    \"%s\": ", row.name)
		strings.write_string(&b, "{\n")
		fmt.sbprintf(&b, "      \"samples\": %d,\n      \"successes\": %d,\n      \"failures\": %d,\n      \"sum_ms\": %d,\n      \"mean_ms\": %s,\n      \"p95_upper_ms\": %s,\n      \"overflow\": %d\n",
			op.attempts, op.successes, op.failures, op.duration_ms.sum_ms, mean, timing_p95(op), op.duration_ms.overflow_count)
		strings.write_string(&b, i + 1 < len(rows) ? "    },\n" : "    }\n")
	}
	strings.write_string(&b, "  }\n}")
	return strings.to_string(b)
}

// Count only rows in the current viewport after SDL presents the frame.
// This measures host observation/compose to presentation, not network delivery.
@(private)
timings_presented :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || ui.page != .Chats || ui.selected < 0 || !rl.IsWindowFocused() {
		return
	}
	view := clay.GetElementData(clay.ID("Timeline"))
	if !view.found {
		return
	}
	cur := thread_cur(ui)
	for &msg, i in ui.messages {
		if msg.visible_since == {} || msg.thread_of != cur {
			continue
		}
		row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
		if row.found && timing_intersects(row.boundingBox, view.boundingBox) {
			timing_record(client, .Inbound_Message_Visible, msg.visible_since)
			msg.visible_since = {}
		}
	}
	for &p, i in ui.pending {
		if p.visible_since == {} || p.group_id != ui.chats[ui.selected].group_id || p.thread != cur {
			continue
		}
		row := clay.GetElementData(clay.ID("PendingRow", u32(i)))
		if row.found && timing_intersects(row.boundingBox, view.boundingBox) {
			timing_record(client, .Outbound_Message_Visible, p.visible_since)
			p.visible_since = {}
		}
	}
}

@(private)
timing_intersects :: proc(row, view: clay.BoundingBox) -> bool {
	return row.width > 0 && row.height > 0 && view.width > 0 && view.height > 0 &&
		row.x < view.x + view.width && row.x + row.width > view.x &&
		row.y < view.y + view.height && row.y + row.height > view.y
}
