package main

import "core:testing"

// A body's shortcodes are found once each; unknown codes are skipped.
@(test)
test_emoji_codes_in :: proc(t: ^testing.T) {
	append(&custom_emoji_names, "party.png", "cat.gif")
	defer clear(&custom_emoji_names)

	// custom_tex_by_code loads real files, so drive the pure half:
	// emoji_file_for is what gates a code onto the wire.
	testing.expect_value(t, emoji_file_for("party"), "party.png")
	testing.expect_value(t, emoji_file_for("cat"), "cat.gif")
	testing.expect_value(t, emoji_file_for("nope"), "")
}

@(test)
test_emoji_att_name :: proc(t: ^testing.T) {
	name := EMOJI_ATT_PREFIX + "party.png"
	testing.expect_value(t, emoji_code(name[len(EMOJI_ATT_PREFIX):]), "party")
}
