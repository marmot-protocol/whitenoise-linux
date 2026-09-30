package main

import "core:testing"

import marmot "../marmot"

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

// A NIP-30 emoji tag claims the attachment whose locator is its url;
// other attachments and malformed tags stay ordinary.
@(test)
test_emoji_tag_code :: proc(t: ^testing.T) {
	party := [3]cstring{"emoji", "party", "https://b.example/aa"}
	short := [2]cstring{"emoji", "cat"}
	other := [3]cstring{"t", "cat", "https://b.example/bb"}
	tags := [3]marmot.Message_Tag {
		{raw_data(party[:]), 3},
		{raw_data(short[:]), 2},
		{raw_data(other[:]), 3},
	}

	loc_a := [2]marmot.Media_Locator {
		{"blossom", "https://mirror.example/aa"},
		{"blossom", "https://b.example/aa"},
	}
	loc_b := [1]marmot.Media_Locator{{"blossom", "https://b.example/bb"}}
	ref_a := marmot.Media_Attachment_Reference {
		locators     = raw_data(loc_a[:]),
		locators_len = 2,
	}
	ref_b := marmot.Media_Attachment_Reference {
		locators     = raw_data(loc_b[:]),
		locators_len = 1,
	}

	testing.expect_value(t, emoji_tag_code(tags[:], &ref_a), "party")
	testing.expect_value(t, emoji_tag_code(tags[:], &ref_b), "")
}
