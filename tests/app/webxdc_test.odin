// The one branch worth a check: the manifest name wins over the file
// name, and a manifest without one falls back.
package main

import "core:testing"

@(test)
xdc_manifest :: proc(t: ^testing.T) {
	manifest := "name = \"Chess\"\nsource_code_url = \"https://example.com\"\n"
	testing.expect_value(t, xdc_manifest_name(manifest), "Chess")
	testing.expect_value(t, xdc_manifest_name("  name='Tac Toe'  "), "Tac Toe")
	testing.expect_value(t, xdc_manifest_name("request_integration = true\n"), "")
	testing.expect_value(t, xdc_manifest_name(""), "")
}
