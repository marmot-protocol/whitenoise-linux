// The desktop-notification gate: only a fresh, unmuted, incoming chat
// message the user isn't looking at gets announced, and only once.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
notify_gate :: proc(t: ^testing.T) {
	base := Notify_Gate {
		enabled = true,
		fresh   = true,
		kind    = KIND_CHAT_MESSAGE,
		msg_id  = "m1",
	}
	testing.expect(t, should_notify(base), "plain incoming message notifies")

	off := base; off.enabled = false
	testing.expect(t, !should_notify(off), "master toggle off")

	muted := base; muted.muted = true
	testing.expect(t, !should_notify(muted), "muted chat")

	mine := base; mine.from_me = true
	testing.expect(t, !should_notify(mine), "own send")

	blocked := base; blocked.blocked = true; blocked.focused = true
	testing.expect(t, !should_notify(blocked), "sender is blocked")

	stale := base; stale.fresh = false
	testing.expect(t, !should_notify(stale), "unread count unchanged")

	edit := base; edit.kind = 1009
	testing.expect(t, !should_notify(edit), "edit is not a message")

	react := base; react.kind = 7
	testing.expect(t, !should_notify(react), "reaction is not a message")

	for kind in ([]u64{1200, KIND_AGENT_ITEM, 1202}) {
		agent := base; agent.kind = kind
		testing.expect(t, !should_notify(agent), "agent records do not trigger chat notifications")
	}

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

when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
	@(test)
	notify_test_send :: proc(t: ^testing.T) {
		if !test_isolated("notify_test_send") {return}
		dir, err := os.make_directory_temp("", "wn-notify-test", context.temp_allocator)
		if !testing.expect_value(t, err, nil) {return}
		defer os.remove_all(dir)

		bin := fmt.tprintf("%s/bin", dir)
		log_path := fmt.tprintf("%s/notify.log", dir)
		if !testing.expect_value(t, os.make_directory(bin), nil) {return}

		mode := os.Permissions{.Read_User, .Write_User, .Execute_User}
		notify_script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$WN_NOTIFY_LOG\"\nexit \"${WN_NOTIFY_EXIT:-0}\"\n"
		fail_audio := "#!/bin/sh\necho 'audio unavailable' >&2\nexit 1\n"
		noisy_sh := "#!/bin/sh\necho 'shell stderr' >&2\nexec /bin/sh \"$@\"\n"
		if !testing.expect_value(
			   t,
			   os.write_entire_file(
				   fmt.tprintf("%s/notify-send", bin),
				   transmute([]u8)notify_script,
				   mode,
			   ),
			   nil,
		   ) ||
		   !testing.expect_value(
				   t,
				   os.write_entire_file(
					   fmt.tprintf("%s/paplay", bin),
					   transmute([]u8)fail_audio,
					   mode,
				   ),
				   nil,
			   ) ||
		   !testing.expect_value(
				   t,
				   os.write_entire_file(
					   fmt.tprintf("%s/canberra-gtk-play", bin),
					   transmute([]u8)fail_audio,
					   mode,
				   ),
				   nil,
			   ) {
			return
		}

		old_path := os.get_env("PATH", context.temp_allocator)
		os.set_env("PATH", fmt.tprintf("%s:%s", bin, old_path))
		os.set_env("WN_NOTIFY_LOG", log_path)
		defer {
			if old_path == "" {os.unset_env("PATH")} else {os.set_env("PATH", old_path)}
			os.unset_env("WN_NOTIFY_LOG")
			os.unset_env("WN_NOTIFY_EXIT")
		}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)

		ui := Ui_State {
			prefs = {notify_desktop = true, notify_sound = true, notify_preview = true},
		}

		// Exercise spawn_cmd under a tracking allocator, both when a compound
		// background command fails and when sh itself writes to stderr.
		testing.expect(t, do_notify(&ui, "Alice", "Hello"))
		if !testing.expect_value(
			t,
			os.write_entire_file(fmt.tprintf("%s/sh", bin), transmute([]u8)noisy_sh, mode),
			nil,
		) {
			return
		}
		testing.expect(t, do_notify(&ui, "Alice", "Hello"))

		notify_test_start(&ui)
		testing.expect(t, notify_test_pending)
		testing.expect(t, !notify_test_enabled(&ui))
		for _ in 0 ..< 500 {
			notify_test_tick(&ui)
			if !notify_test_pending {break}
			time.sleep(2 * time.Millisecond)
		}
		testing.expect(t, !notify_test_pending)
		testing.expect_value(t, notify_test_result, Notify_Test_Result.Accepted)
		logged, read_err := os.read_entire_file(log_path, context.temp_allocator)
		testing.expect_value(t, read_err, nil)
		testing.expect(
			t,
			strings.contains(
				string(logged),
				"Test notification\nThis is what a message alert looks like.\n",
			),
		)

		os.set_env("WN_NOTIFY_EXIT", "1")
		notify_test_start(&ui)
		for _ in 0 ..< 500 {
			notify_test_tick(&ui)
			if !notify_test_pending {break}
			time.sleep(2 * time.Millisecond)
		}
		testing.expect(t, !notify_test_pending)
		testing.expect_value(t, notify_test_result, Notify_Test_Result.Failed)

		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		delete(send_threads)
		send_threads = {}
		notify_test_pending = false
		notify_test_result = .Idle

		testing.expect_value(t, len(track.bad_free_array), 0)
		testing.expect_value(t, len(track.allocation_map), 0)
	}
}
