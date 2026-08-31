// Checks for the export text builders.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:strings"
import "core:testing"

@(test)
export_escaping :: proc(t: ^testing.T) {
	testing.expect_value(t, html_esc(`<b>"a" & b</b>`), "&lt;b&gt;&quot;a&quot; &amp; b&lt;/b&gt;")

	b := strings.builder_make(context.temp_allocator)
	csv_field(&b, `say "hi", ok`)
	testing.expect_value(t, strings.to_string(b), `"say ""hi"", ok"`)
}
