package main

import "core:strings"
import "core:sync"
import "core:testing"
import rl "sdlrl"

// Consecutive rows from one sender collapse into a run until the window,
// the line budget, another sender, or a system line breaks it.
@(test)
msg_run_grouping :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	a :: "aa"
	b :: "bb"
	rows := []struct {
		msg:  Msg_Ui,
		want: Msg_Head,
	} {
		{{sender_id = a, sort_at = 1000, body = "one"}, .Full},
		{{sender_id = a, sort_at = 1100, body = "two"}, .Continued},
		// 5 minutes after the run's first row, not after the previous row.
		{{sender_id = a, sort_at = 1000 + GROUP_WINDOW_SECS, body = "late"}, .Full},
		{{sender_id = b, sort_at = 1310, body = "other"}, .Full},
		{{sender_id = a, sort_at = 1320, body = "back"}, .Full},
		{{sender_id = a, sort_at = 1330, body = "again"}, .Continued},
		{{sender_id = a, sort_at = 1335, body = "re", reply_text = "q"}, .Continued},
		// 3 lines so far; 12 more reaches 15, which is not under the cap.
		{{sender_id = a, sort_at = 1340, body = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12"}, .Full},
		// 12 + 2 = 14 stays under it.
		{{sender_id = a, sort_at = 1350, body = "x\ny"}, .Continued},
		{{sender_id = a, sort_at = 1370, system = true}, .Full},
		{{sender_id = a, sort_at = 1380, body = "after system"}, .Full},
		{{sender_id = a, sort_at = 1390, deleted = true}, .Full},
		{{sender_id = a, sort_at = 1400, body = "after tombstone"}, .Full},
	}
	run: Msg_Run
	for row, i in rows {
		got := msg_run_step(&run, row.msg, 480)
		testing.expectf(t, got == row.want, "row %d: got %v, want %v", i, got, row.want)
	}

	// Millisecond stamps normalize to seconds.
	run = {}
	msg_run_step(&run, {sender_id = a, sort_at = 1_750_000_000_000, body = "s"}, 480)
	late := msg_run_step(&run, {sender_id = a, sort_at = 1_750_000_299_000, body = "ms"}, 480)
	testing.expect_value(t, late, Msg_Head.Continued)
}

// The budget counts drawn lines: one paragraph fits a wide column but
// wraps past 15 lines in a narrow one. Needs real font metrics:
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=msg_run_wrap
@(test)
msg_run_wrap :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "msg_run_wrap" {return}
	rl.InitWindow(600, 400, "Message run wrap")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	defer wrap_clear()
	long := strings.repeat("word ", 60, context.temp_allocator)
	for width in ([]f32{4000, 120}) {
		run: Msg_Run
		msg_run_step(&run, {sender_id = "aa", sort_at = 2000, body = "head"}, width)
		got := msg_run_step(&run, {sender_id = "aa", sort_at = 2010, body = long}, width)
		want := width > 1000 ? Msg_Head.Continued : Msg_Head.Full
		testing.expectf(t, got == want, "width %v: got %v, want %v", width, got, want)
	}
}
