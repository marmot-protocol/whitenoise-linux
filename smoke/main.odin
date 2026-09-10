// Minimal liveness check for the Odin marmot bindings: construct the
// runtime against a fresh home dir, do an offline read, shut down.
// Usage: smoke <fresh-empty-home-dir>
package smoke

import "core:fmt"
import "core:os"
import "core:strings"

import marmot "../marmot"

fail :: proc(what: string) -> ! {
	fmt.eprintfln("smoke: FAILED: %s: %s", what, marmot.last_error())
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintfln("usage: %s <fresh-home-dir>", os.args[0])
		os.exit(2)
	}
	home := strings.clone_to_cstring(os.args[1])

	// NULL root path must be rejected at the binding layer.
	client: ^marmot.Client
	if marmot.client_new(nil, nil, 0, &client) != .NULL_POINTER {
		fail("NULL root_path not rejected")
	}

	relays := []cstring{"wss://relay.example.org"}
	if marmot.client_new(home, raw_data(relays), 1, &client) != .OK {
		fail("client_new")
	}
	fmt.println("smoke: client constructed")

	// Offline read: a fresh home has no accounts.
	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) != .OK {
		fail("list_accounts")
	}
	fmt.printfln("smoke: accounts: %d", accounts.len)
	assert(accounts.len == 0, "fresh home has accounts")
	marmot.account_summary_list_free(accounts)

	// Error taxonomy: unknown account maps to its typed status.
	nsec: ^marmot.Account_Summary
	if marmot.login(client, "not-an-identity", nil, 0, nil, 0, &nsec) == .OK {
		fail("bogus login unexpectedly succeeded")
	}
	fmt.printfln("smoke: bogus login rejected: %s", marmot.last_error())

	// Exercise the real C ABI across both sides of the migration counters.
	for operation in marmot.Host_Performance {
		if marmot.record_host_performance(client, operation, 251, .Success) != .OK {
			fail("record_host_performance")
		}
	}
	snapshot: ^marmot.Performance_Snapshot
	if marmot.performance_snapshot(client, &snapshot) != .OK {
		fail("performance_snapshot")
	}
	assert(snapshot.host_outbound_message_visible.attempts == 1)
	assert(snapshot.host_inbound_message_visible.duration_ms.sum_ms == 251)
	assert(snapshot.host_splash_ready.successes == 1)
	assert(snapshot.host_foreground_local_ready.duration_ms.sum_ms == 251)
	assert(snapshot.host_foreground_local_ready.duration_ms.buckets_len > 0)
	marmot.performance_snapshot_free(snapshot)

	// No runtime start or exporter route: consent round-trip stays offline.
	consent: ^marmot.Diagnostics_Settings
	if marmot.diagnostics_settings(client, &consent) != .OK {
		fail("diagnostics_settings")
	}
	assert(consent.decision == .Acceptance_Required)
	marmot.diagnostics_settings_free(consent)
	if marmot.set_diagnostics_consent(client, .Grant, &consent) != .OK {
		fail("grant diagnostics")
	}
	assert(consent.decision == .Granted)
	marmot.diagnostics_settings_free(consent)
	if marmot.set_diagnostics_consent(client, .Decline, &consent) != .OK {
		fail("revoke diagnostics")
	}
	assert(consent.decision == .Declined)
	marmot.diagnostics_settings_free(consent)
	diagnostics: ^marmot.Diagnostics_Status
	if marmot.diagnostics_status(client, &diagnostics) != .OK {
		fail("diagnostics_status")
	}
	assert(diagnostics.telemetry == .Disabled)
	marmot.diagnostics_status_free(diagnostics)

	if marmot.client_shutdown(client) != .OK {
		fail("client_shutdown")
	}
	marmot.client_free(client)
	fmt.println("smoke: all checks passed")
}
