package main

import "base:runtime"
import "core:sync"
import "core:testing"

@(test)
test_page_chat_identity :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "account-a",
		selected    = 1,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "chat-a"}, Chat_Row_Ui{group_id = "chat-b"})
	defer delete(ui.chats)
	key := page_view_key(&ui)

	ui.chats[0], ui.chats[1] = ui.chats[1], ui.chats[0]
	ui.selected = 0
	testing.expect(t, page_view_key(&ui) == key, "reordering must not restart the transition")

	ui.selected = 1
	testing.expect(t, page_view_key(&ui) != key, "switching chats must change the view")
	ui.selected = 0
	ui.account_ref = "account-b"
	testing.expect(t, page_view_key(&ui) != key, "switching accounts must change the view")
	ui.account_ref = "account-a"
	ui.selected = -1
	testing.expect(t, page_view_key(&ui) != key, "leaving the chat must change the view")
}

// The runner frees each test's allocator when the test ends, so a global
// map first grown inside one test points at dead memory in the next and
// its next insert panics. Allocate the anim maps from the heap up front,
// as the app's own context does.
@(init)
anim_maps_on_heap :: proc "contextless" () {
	context = runtime.default_context()
	anim_vals = make(map[u32]Anim)
	anim_cols = make(map[u32]Anim_Color)
}

// The scroll-lag split must never change a row's height: if it does,
// the timeline's content resizes mid-scroll and the bottom-pinned view
// slides off the newest message.
// A pinned entry must not replay: after anim_set, the next anim_to at
// the same target returns it immediately instead of easing in from the
// value the drag started at.
@(test)
test_anim_set_no_replay :: proc(t: ^testing.T) {
	// Layout tests step the same global anim state under this lock.
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	anim_tick(1.0 / 60)
	_ = anim_to(0x77770001, 100) // first sighting seeds at the target
	anim_tick(1.0 / 60)
	anim_set(0x77770001, 340)
	anim_tick(1.0 / 60)
	testing.expect(t, anim_to(0x77770001, 340) == 340, "entry replayed the drag")
}
