package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
retry_convergence_failure :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous := ops_done
	ops_done = {}
	defer {
		for done in ops_done {delete(done.err)}
		delete(ops_done)
		ops_done = previous
	}
	job := new(Op_Job)
	job.op = .Retry_Convergence
	job.account = strings.clone_to_cstring("account")
	job.group = strings.clone_to_cstring("group")
	job.target = strings.clone_to_cstring("")
	worker := thread.Thread {
		data = job,
	}
	op_worker(&worker)
	testing.expect_value(t, len(ops_done), 1)
	testing.expect_value(t, ops_done[0].op, Msg_Op.Retry_Convergence)
	testing.expect(t, ops_done[0].err != "", "a failed retry must reach the UI")
}
