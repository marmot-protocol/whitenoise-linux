// URL detection in message bodies and the host the guard names.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "base:runtime"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
url_at_scan :: proc(t: ^testing.T) {
	// A link mid-sentence stops at whitespace, without the period.
	text := "see https://example.com/docs. ok"
	end, url, ok := url_at(text, 4)
	testing.expect(t, ok)
	testing.expect_value(t, url, "https://example.com/docs")
	testing.expect_value(t, text[end:], ". ok")

	// http too, and the end of the string is a valid end.
	_, plain, ok2 := url_at("http://a.example", 0)
	testing.expect(t, ok2)
	testing.expect_value(t, plain, "http://a.example")

	// Not a URL: another scheme, and a scheme with no host.
	_, _, ok3 := url_at("ftp://example.com", 0)
	testing.expect(t, !ok3)
	_, _, ok4 := url_at("https://", 0)
	testing.expect(t, !ok4)
}

@(test)
url_host_parse :: proc(t: ^testing.T) {
	testing.expect_value(t, url_host("https://example.com/a?b#c"), "example.com")
	testing.expect_value(t, url_host("http://example.com:8080/x"), "example.com:8080")
	testing.expect_value(t, url_host("https://example.com"), "example.com")
	// A lookalike host must not fold into the trusted one.
	testing.expect(t, url_host("https://evil.example.com/x") != url_host("https://example.com/x"))
}

@(test)
link_address_scroll :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "link_address_scroll" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Link address")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	init_fonts()
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui: Ui_State
	defer delete(ui.link_url)
	url := "https://example.com/a/long/address/whose/path/should/remain/readable?value=%E6%97%A5#fragment"
	open_link(&ui, url)
	for width in ([]f32{1024, 480}) {
		clay.SetLayoutDimensions({width, 700})
		for _ in 0 ..< 3 {
			clay.BeginLayout()
			link_modal(&ui)
			commands := clay.EndLayout(1.0 / 60)
			found := false
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				text := cmd.renderData.text.stringContents
				found ||= string(text.chars[:text.length]) == url
			}
			testing.expect(t, found, "the address remains one complete rendered line")
		}
		data := clay.GetScrollContainerData(clay.ID("LinkAddress"))
		if !testing.expect(t, data.found) {continue}
		testing.expect(t, data.contentDimensions.width > data.scrollContainerDimensions.width)
		box := clay.GetElementData(clay.ID("LinkAddress")).boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		clay.UpdateScrollContainers(false, {-20, 0}, 1.0 / 60)
		testing.expect(
			t,
			data.scrollPosition.x < 0,
			"the hidden address tail can be scrolled into view",
		)
		testing.expect_value(t, ui.link_url, url)
		testing.expect_value(t, url_host(ui.link_url), "example.com")
		open_link(&ui, url)
		testing.expect_value(t, data.scrollPosition.x, 0)
	}
}
