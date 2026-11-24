package main

import "core:strings"
import "core:testing"
import "core:text/edit"

@(test)
test_react_shortcode :: proc(t: ^testing.T) {
	if !test_isolated("test_react_shortcode") {
		return
	}
	// A custom shortcode can shadow a Unicode alias. Selecting the
	// Unicode suggestion must still send that emoji.
	old_catalog := emoji_catalog
	emoji_catalog = {}
	pixels := [1]u8{1}
	append(
		&emoji_catalog,
		Emoji_Entry{emoji = "👍", name = "thumbs up :marmot:", pixels = pixels[:]},
	)
	defer {
		delete(emoji_catalog)
		emoji_catalog = old_catalog
	}

	ui := Ui_State {
		focus               = .Compose,
		shortcode_dismissed = -1,
	}
	ui.ed_target = &ui.compose
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer delete(ui.compose)
	defer delete(ui.shortcode_cands)

	for row in ([]struct {
			draft, emoji, completed, reaction: string,
		}{{"+:marm", "", "+:marmot:", ":marmot:"}, {"+:marmot", "👍", "+:👍:", "👍"}, {":marm", "", ":marmot: ", ""}}) {
		ed_set(&ui, &ui.compose, row.draft)
		shortcode_update(&ui)
		if !testing.expect(t, ui.shortcode_active) {
			return
		}
		index := -1
		for cand, i in ui.shortcode_cands {
			if cand.code == "marmot" && cand.emoji == row.emoji {
				index = i
				break
			}
		}
		if !testing.expect(t, index >= 0) {
			return
		}
		shortcode_commit(&ui, index)
		text := string(ui.compose[:])
		testing.expect_value(t, text, row.completed)
		testing.expect_value(t, reaction_emoji(strings.trim_space(text)), row.reaction)
		shortcode_update(&ui)
		testing.expect(t, !ui.shortcode_active)
	}
	testing.expect_value(t, reaction_emoji("+👍"), "")
}
