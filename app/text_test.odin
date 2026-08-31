// Line-level markdown parser checks.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
md_text_parse :: proc(t: ^testing.T) {
	src := "# Title\n\nHello\nworld\n\n- one\n- two\n\n```\ncode here\n```\n> quoted\n---\n"
	blocks := parse_md_text(src)
	defer delete(blocks)

	testing.expect_value(t, len(blocks), 7)
	testing.expect_value(t, blocks[0].kind, Md_Kind.Heading)
	testing.expect_value(t, blocks[0].level, 1)
	testing.expect_value(t, blocks[1].kind, Md_Kind.Para)
	testing.expect_value(t, blocks[1].text, "Hello world") // joined lines
	testing.expect_value(t, blocks[2].kind, Md_Kind.List_Item)
	testing.expect_value(t, blocks[4].kind, Md_Kind.Code)
	testing.expect_value(t, blocks[4].text, "code here")
	testing.expect_value(t, blocks[5].kind, Md_Kind.Quote)
	testing.expect_value(t, blocks[6].kind, Md_Kind.Rule)

	// Unclosed fence still yields its code block.
	open_fence := parse_md_text("```\ndangling")
	defer delete(open_fence)
	testing.expect_value(t, len(open_fence), 1)
	testing.expect_value(t, open_fence[0].kind, Md_Kind.Code)
}
