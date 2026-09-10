package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
import marmot "../marmot"

@(test)
timing_report_boundaries :: proc(t: ^testing.T) {
	buckets := [?]marmot.Duration_Bucket{{10, 18}, {500, 1}}
	op := marmot.Performance_Operation{
		attempts = 20, successes = 19, failures = 1,
		duration_ms = {buckets = raw_data(buckets[:]), buckets_len = len(buckets), overflow_count = 1, sum_ms = 1000},
	}
	testing.expect_value(t, timing_p95(op), "500")
	op.attempts = 21
	op.duration_ms.overflow_count = 2
	testing.expect_value(t, timing_p95(op), "null")
	testing.expect_value(t, timing_p95({}), "null")

	snapshot := marmot.Performance_Snapshot{outbound_message_queue_wait = op}
	report := timing_snapshot_json(&snapshot)
	defer delete(report)
	decoded: struct {
		scope, unit: string,
		timings: map[string]struct { samples, successes, failures, sum_ms: u64 },
	}
	err := json.unmarshal(transmute([]u8)report, &decoded, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(decoded.timings), 79)
	testing.expect_value(t, decoded.timings["outbound_message_queue_wait"].samples, 21)
	testing.expect_value(t, decoded.timings["outbound_message_queue_wait"].sum_ms, 1000)
	testing.expect(t, "host_foreground_local_ready" in decoded.timings)
	testing.expect(t, strings.contains(report, `"mean_ms": null`))

	testing.expect(t, timing_intersects({0, 0, 10, 10}, {5, 5, 10, 10}))
	testing.expect(t, !timing_intersects({0, 0, 10, 10}, {0, 10, 10, 10}))
	testing.expect(t, !timing_intersects({0, 0, 0, 10}, {0, 0, 10, 10}))
}
