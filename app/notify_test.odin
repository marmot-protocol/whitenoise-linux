// The desktop-notification gate: only a fresh, unmuted, incoming chat
// message the user isn't looking at gets announced, and only once.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
notify_gate :: proc(t: ^testing.T) {
	base := Notify_Gate{enabled = true, fresh = true, kind = KIND_CHAT_MESSAGE, msg_id = "m1"}
	testing.expect(t, should_notify(base), "plain incoming message notifies")

	off := base; off.enabled = false
	testing.expect(t, !should_notify(off), "master toggle off")

	muted := base; muted.muted = true
	testing.expect(t, !should_notify(muted), "muted chat")

	mine := base; mine.from_me = true
	testing.expect(t, !should_notify(mine), "own send")

	stale := base; stale.fresh = false
	testing.expect(t, !should_notify(stale), "unread count unchanged")

	edit := base; edit.kind = 1009
	testing.expect(t, !should_notify(edit), "edit is not a message")

	react := base; react.kind = 7
	testing.expect(t, !should_notify(react), "reaction is not a message")

	seen := base; seen.seen_id = "m1"
	testing.expect(t, !should_notify(seen), "already notified for this id")

	open := base; open.focused = true; open.viewing = true
	testing.expect(t, !should_notify(open), "chat open and focused")

	bg := base; bg.viewing = true
	testing.expect(t, should_notify(bg), "chat open but app unfocused")

	other := base; other.focused = true
	testing.expect(t, should_notify(other), "focused on a different chat")
}

@(test)
notify_mark_dedupes :: proc(t: ^testing.T) {
	notify_mark("g1", "m1")
	testing.expect_value(t, notify_seen_id("g1"), "m1")
	notify_mark("g1", "m2")
	testing.expect_value(t, notify_seen_id("g1"), "m2")
	notify_mark("g1", "")
	testing.expect_value(t, notify_seen_id("g1"), "m2")
	testing.expect_value(t, notify_seen_id("g2"), "")
}
