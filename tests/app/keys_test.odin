// Keys page: status summary and the two-step danger confirm.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(test)
keys_status :: proc(t: ^testing.T) {
	ui: Ui_State
	defer delete(ui.kp_list)

	testing.expect_value(t, kp_status_line(&ui), "Not loaded yet. Click Refresh.")

	ui.kp_fetched = true
	testing.expect_value(t, kp_status_line(&ui), "No key package yet. Publish one so people can invite you.")

	append(&ui.kp_list, Kp_Row{local = true})
	testing.expect_value(t, kp_status_line(&ui), "Stored on this device, not published to any relay yet.")

	append(&ui.kp_list, Kp_Row{relay = true, relay_urls = {"wss://a", "wss://b"}})
	testing.expect_value(t, kp_status_line(&ui), "1 published, 1 on this device, seen on 2 relays.")
}

@(test)
keys_confirm_arms :: proc(t: ^testing.T) {
	ui: Ui_State

	// First click arms, second acts; a different button steals the arm.
	testing.expect(t, !armed(&ui, "RotateBtn"))
	testing.expect_value(t, ui.keys_confirm, "RotateBtn")
	testing.expect(t, armed(&ui, "RotateBtn"))
	testing.expect_value(t, ui.keys_confirm, "")

	testing.expect(t, !armed(&ui, "RotateBtn"))
	testing.expect(t, !armed(&ui, "ExportBtn"))
	testing.expect_value(t, ui.keys_confirm, "ExportBtn")
}
