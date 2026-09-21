package main

import "core:encoding/json"
import "core:fmt"
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

@(test)
local_timing_boundaries :: proc(t: ^testing.T) {
	op: Local_Distribution
	testing.expect_value(t, local_timing_percentile(op, 95), "null")
	for ns in ([4]u64{0, 1000, 1001, 2000}) { local_timing_add(&op, ns) }
	testing.expect_value(t, op.samples, 4)
	testing.expect_value(t, op.sum_ns, 4001)
	testing.expect_value(t, op.min_ns, 0)
	testing.expect_value(t, op.max_ns, 2000)
	testing.expect_value(t, op.buckets[0], 2)
	testing.expect_value(t, op.buckets[1], 2)
	testing.expect_value(t, local_timing_percentile(op, 50), "0.001000")
	testing.expect_value(t, local_timing_percentile(op, 95), "0.002000")
	local_timing_add(&op, 1000 << 27)
	testing.expect_value(t, local_timing_percentile(op, 99), "null")
	testing.expect_value(t, op.buckets[27], 1)
	for stage in Local_Timing {
		foreign_stage := marmot.Host_Performance(u32(marmot.Host_Performance.Linux_startup_before_vault) + u32(stage))
		testing.expect_value(t, fmt.tprintf("%v", foreign_stage), fmt.tprintf("Linux_%v", stage))
	}
	report := timings_json(nil)
	defer delete(report)
	decoded: struct { linux_performance: struct {
		scope, unit: string,
		timings: map[string]struct { samples: u64 },
	}}
	err := json.unmarshal(transmute([]u8)report, &decoded, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(decoded.linux_performance.timings), 38)
	testing.expect_value(t, decoded.linux_performance.scope, "module_lifetime")
	testing.expect_value(t, decoded.linux_performance.unit, "milliseconds")
}
