package main

import "core:testing"

// NIP-88 counting: single choice takes the first response tag, multiple
// choice dedups repeats, votes after endsAt are ignored.
@(test)
poll_tally_rules :: proc(t: ^testing.T) {
	single: Msg_Ui
	append(&single.poll_opts, Poll_Opt_Ui{id = "0", label = "a"})
	append(&single.poll_opts, Poll_Opt_Ui{id = "1", label = "b"})
	per := make(map[string]Poll_Vote, context.temp_allocator)
	per["alice"] = {at = 10, opts = {"0", "1"}} // "1" ignored: singlechoice
	per["bob"] = {at = 20, opts = {"1"}}
	poll_tally(&single, per, "alice")
	testing.expect_value(t, single.poll_opts[0].count, 1)
	testing.expect_value(t, single.poll_opts[1].count, 1)
	testing.expect_value(t, single.poll_total, 2)
	testing.expect(t, single.poll_opts[0].mine)
	testing.expect(t, !single.poll_opts[1].mine)

	multi: Msg_Ui
	multi.poll_multi = true
	multi.poll_ends = 100
	append(&multi.poll_opts, Poll_Opt_Ui{id = "0", label = "a"})
	append(&multi.poll_opts, Poll_Opt_Ui{id = "1", label = "b"})
	per2 := make(map[string]Poll_Vote, context.temp_allocator)
	per2["alice"] = {at = 50, opts = {"1", "0", "1"}} // repeat dedups
	per2["bob"] = {at = 150, opts = {"0"}} // after endsAt
	poll_tally(&multi, per2, "carol")
	testing.expect_value(t, multi.poll_opts[0].count, 1)
	testing.expect_value(t, multi.poll_opts[1].count, 1)
	testing.expect_value(t, multi.poll_total, 1)
}
