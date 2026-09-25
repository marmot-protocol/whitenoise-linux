// Fixed local counters, independent of MDK consent and its millisecond buckets.
package main

import marmot "../marmot"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// Same order and names as the host stages after Conversation_Composer_Ready in
// marmot.Host_Performance, so a stage maps to its C value by offset.
@(private)
Local_Timing :: enum {
	linux_startup_before_vault,
	linux_startup_after_vault,
	window_init,
	fonts_init,
	runtime_init,
	account_load,
	account_switch,
	frame_update,
	frame_layout,
	frame_draw,
	frame_present,
	linux_frame_post_present,
	linux_frame_until_present,
	linux_frame_idle_wait,
	chat_list_load,
	contacts_load,
	archived_chat_list_load,
	profile_load,
	profile_read,
	timeline_open,
	timeline_page,
	timeline_handoff,
	timeline_apply,
	message_send,
	message_search,
	conversation_search,
	media_queue_wait,
	media_prepare,
	media_load,
	media_cache_read,
	media_decode,
	media_apply,
	linux_vault_derive_key,
	linux_vault_open,
	linux_vault_create,
	linux_vault_persist,
	settings_save,
}

@(private)
Local_Distribution :: struct {
	samples, sum_ns, min_ns, max_ns: u64,
	// Inclusive powers of two microseconds, then unbounded overflow.
	buckets:                         [28]u64,
}

@(private)
local_timings: [Local_Timing]Local_Distribution
@(private)
local_timing_mutex: sync.Mutex
@(private)
local_timing_client: ^marmot.Client
@(private)
local_timing_stopped: bool = true
@(private)
Local_Timing_Sample :: struct {
	operation: Local_Timing,
	ns:        u64,
}
@(private)
local_timing_pending: [dynamic]Local_Timing_Sample

@(private)
local_timing_add :: proc(op: ^Local_Distribution, ns: u64) {
	if op.samples == 0 || ns < op.min_ns {op.min_ns = ns}
	op.samples += 1
	op.sum_ns += ns
	op.max_ns = max(op.max_ns, ns)
	bucket := 0
	for bucket < len(op.buckets) - 1 && ns > (u64(1000) << u64(bucket)) {
		bucket += 1
	}
	op.buckets[bucket] += 1
}

@(private)
local_timing_end :: proc(operation: Local_Timing, start: time.Tick) {
	if start == {} {return}
	ns := u64(max(time.tick_since(start), 0))
	// ponytail: one lock serializes counter updates; split per operation if contended.
	sync.lock(&local_timing_mutex)
	local_timing_add(&local_timings[operation], ns)
	if local_timing_client != nil {
		status := marmot.record_host_performance(
			local_timing_client,
			marmot.Host_Performance(
				u32(marmot.Host_Performance.Linux_Startup_Before_Vault) + u32(operation),
			),
			ns / 1_000_000,
			.Success,
		)
		assert(status == .OK)
	} else if !local_timing_stopped {
		append(&local_timing_pending, Local_Timing_Sample{operation, ns})
	}
	sync.unlock(&local_timing_mutex)
}

// Called before runtime start and before shutdown. Never retain a freed client.
@(private)
local_timing_bind :: proc(client: ^marmot.Client) {
	sync.lock(&local_timing_mutex)
	defer sync.unlock(&local_timing_mutex)
	local_timing_client = client
	local_timing_stopped = client == nil
	if client != nil {
		for sample in local_timing_pending {
			status := marmot.record_host_performance(
				client,
				marmot.Host_Performance(
					u32(marmot.Host_Performance.Linux_Startup_Before_Vault) +
					u32(sample.operation),
				),
				sample.ns / 1_000_000,
				.Success,
			)
			assert(status == .OK)
		}
	}
	delete(local_timing_pending)
	local_timing_pending = {}
}

@(private)
local_timing_percentile :: proc(op: Local_Distribution, percentile: u64) -> string {
	if op.samples == 0 {return "null"}
	target := op.samples / 100 * percentile + (op.samples % 100 * percentile + 99) / 100
	count: u64
	for i in 0 ..< len(op.buckets) - 1 {
		count += op.buckets[i]
		if count >= target {return fmt.tprintf("%.6f", f64(u64(1000) << u64(i)) / 1e6)}
	}
	return "null"
}

@(private)
local_timings_json :: proc() -> string {
	sync.lock(&local_timing_mutex)
	snapshot := local_timings
	sync.unlock(&local_timing_mutex)
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"app_version\": \"%s\",\n", APP_VERSION)
	strings.write_string(
		&b,
		"  \"scope\": \"module_lifetime\",\n  \"unit\": \"milliseconds\",\n  \"timings\": {\n",
	)
	for op, name in snapshot {
		fmt.sbprintf(&b, "    \"%v\": ", name)
		strings.write_string(&b, "{")
		fmt.sbprintf(&b, "\"samples\": %d, \"sum_ms\": %.6f, ", op.samples, f64(op.sum_ns) / 1e6)
		if op.samples == 0 {
			strings.write_string(&b, "\"min_ms\": null, \"max_ms\": null, \"mean_ms\": null, ")
		} else {
			fmt.sbprintf(
				&b,
				"\"min_ms\": %.6f, \"max_ms\": %.6f, \"mean_ms\": %.6f, ",
				f64(op.min_ns) / 1e6,
				f64(op.max_ns) / 1e6,
				f64(op.sum_ns) / f64(op.samples) / 1e6,
			)
		}
		fmt.sbprintf(
			&b,
			"\"p50_upper_ms\": %s, \"p95_upper_ms\": %s, \"p99_upper_ms\": %s, \"overflow\": %d",
			local_timing_percentile(op, 50),
			local_timing_percentile(op, 95),
			local_timing_percentile(op, 99),
			op.buckets[len(op.buckets) - 1],
		)
		strings.write_string(&b, int(name) + 1 < len(snapshot) ? "},\n" : "}\n")
	}
	strings.write_string(&b, "  }\n}")
	return strings.to_string(b)
}

@(private)
local_timings_export :: proc() {
	defer local_timing_bind(nil)
	path := os.get_env("WN_TIMINGS", context.temp_allocator)
	if path == "" {return}
	report := local_timings_json()
	defer delete(report)
	if err := os.write_entire_file(path, transmute([]u8)report); err != nil {
		fmt.eprintfln("timings: couldn't write %s: %v", path, err)
	}
}
