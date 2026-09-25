# Timing diagnostics

MDK is pinned to the merge of marmot-protocol/mdk#1760. Enable Developer
mode in Settings > Advanced, then open Debug > Timings and click Refresh.
Copy JSON exports all **79 distinct operation distributions**. The names
are listed explicitly in `app/timings.odin`, matching the C snapshot in
`marmot/marmot.odin`. Empty metrics remain visible with zero samples and
null mean/p95, so unexercised paths are distinguishable from measured zeroes.

Each operation reports samples, successes, failures, total milliseconds,
mean milliseconds, the p95 bucket upper bound, and overflow count. The p95
is a histogram bound, not an exact percentile. A null p95 with samples
means its rank falls in the unbounded overflow bucket. Local counters cover
the current process, across accounts; restart the app for a fresh baseline.
Nested stages overlap, so do not sum their means into an end-to-end total.

## Uploads

Settings > Advanced > Share usage and diagnostics explicitly grants MDK's
combined consent. Existing relay-only consent requires a new decision.
Turning sharing off revokes export. Audit logging has a separate switch.
The app configures its route before starting MDK and builds marmot-c with
`otlp-export`; cached bundles without that feature are rebuilt.

MDK exports its fixed set of aggregate timing histograms and counters to
the `otlp_metrics_endpoint` in `observability.toml`, by default
`https://otlp.ipf.dev/v1/metrics`. The runtime does not offer a per-operation
export filter. The local report's `otlp_export` field describes readiness,
not delivery acknowledgement. Raw message contents and account/group IDs
are not timing dimensions. Resource metadata includes a consent-scoped
installation ID; relay diagnostics also include relay labels.

Goggles' `/api/v1/audit-logs/` endpoint accepts forensic audit events, not
OTLP metrics. Do not send timing JSON there. Displaying these aggregates in
Goggles requires a collector-backed metrics view in that separate project.
Production retention and server ingestion were not verified by local tests.

Prioritize these OTLP histograms when building that view:

| Measurement | OTLP histogram |
| --- | --- |
| Send queue contention | `app_outbound_message_queue_wait_duration_ms` |
| Optimistic local projection | `app_outbound_message_local_projection_duration_ms` |
| Durable local acceptance | `app_outbound_message_local_accept_duration_ms` |
| Relay publication | `app_outbound_message_publish_duration_ms` |
| Caller response | `app_outbound_message_response_duration_ms` |
| Inbound processing | `app_inbound_delivery_projection_duration_ms` |
| Outbound presentation | `app_host_outbound_message_visible_duration_ms` |
| Inbound presentation | `app_host_inbound_message_visible_duration_ms` |
| Account readiness | `app_account_worker_readiness_duration_ms` |
| Group creation | `app_group_create_total_caller_latency_duration_ms` |
| Media queue wait | `app_media_download_queue_wait_duration_ms` |
| Media first byte | `app_media_download_first_byte_duration_ms` |
| Media transfer | `app_media_download_body_transfer_duration_ms` |

## Host measurement boundaries

- `host_splash_ready`: after vault unlock, before booting the runtime, until
  the first foreground application frame is presented. Includes synchronous
  boot work and excludes password-entry time.
- `host_foreground_local_ready`: observing a foreground transition in the
  frame loop until that frame is presented. This is host update/layout/draw
  time, not relay catch-up or full startup.
- `host_outbound_message_visible`: queueing a new text or attachment send
  until its optimistic row intersects the timeline viewport in a presented
  foreground frame. Retrying does not restart this measurement. Sends that
  settle before their optimistic row is drawn do not produce this sample.
- `host_inbound_message_visible`: receiving a chat-list change naming a new
  incoming message until its row intersects the timeline viewport in a
  presented foreground frame. Only changes for the selected conversation
  are eligible. Initial history, polling-only discoveries, edits, and rows
  not presented do not produce samples. Coalesced stream updates can omit
  intermediate messages; this is a sampled host-render metric.

Message visibility includes any wait for foregrounding or scrolling to the
row. Compare it with projection timings to separate that wait from processing.

Visibility means SDL presentation of a row intersecting the viewport. It
cannot establish compositor scanout, actual reading, recipient delivery,
or whether another window obscures part of the app. Host milestones record
success only on presentation; missing observations are not counted as failures.

Run `just test` for report/percentile/viewport checks, and
`build/smoke <fresh-empty-directory>` for real C snapshot and consent checks.
The smoke test never starts the runtime or uploads telemetry.

## Linux stages

Debug > Timings also includes `linux_performance`, with 37 fixed stages.
Each reports a sample count, sum, min, max, mean, p50/p95/p99 upper bounds,
and overflow. Totals retain nanoseconds and display fractional milliseconds.
The local histogram uses powers of two microseconds through 67,108.864 ms;
larger samples enter overflow. Empty values and overflow percentiles are null.
These counters reset on process start or development module reload.

All 37 stages also feed MDK's consent-controlled OTLP exporter to the
configured IPF endpoint. They are MDK's host-performance operations after
`CONVERSATION_COMPOSER_READY`: 28 shared across platforms and nine
Linux-specific (`linux_*`). MDK exports each through its runtime registry
as `app_runtime_host_<stage>_*` series (started, completed, outcome
counters, and `_duration_ms`), and lists it by `host_<stage>` in the C
snapshot's `runtime_operations`. Local stage names match MDK's, and
`Local_Timing` keeps MDK's order so each stage maps to its C value by
offset. The upstream catalog defines each boundary:
`docs/marmot-architecture/runtime-latency-telemetry.md` in `vendor/mdk`.
They use the same installation metadata, route, retry policy, and sharing
switch as the original timings. No separate uploader or consent is added.
Startup samples are buffered until client construction. Collection becomes
local-only at runtime shutdown. Turning off sharing stops remote export,
while local diagnostics remain available, as with the original timings.

The C API accepts whole milliseconds, so exported samples truncate below
one millisecond and use MDK's histogram bounds. Use the local report for
sub-millisecond comparisons. These stage spans include error and early
returns but always report `Success`, so the exported success counters count
samples, not successful actions.

| Stages | Boundaries |
| --- | --- |
| `linux_startup_before_vault`, `linux_startup_after_vault` | App entry to the vault gate, then post-unlock runtime boot to first normal frame presentation. Password-entry time is excluded. |
| `window_init`, `fonts_init`, `runtime_init` | Window/renderer initialization, font initialization, and runtime boot including account loading. |
| `account_load`, `account_switch` | Account snapshot/setup and synchronous account switch work. |
| `frame_update` | After SDL event polling through worker drains, input preparation and media advancement, before layout. |
| `frame_layout` | Layout builds and scroll correction, including rebuilds. |
| `frame_draw`, `frame_present` | Render-command submission and SDL present respectively. Present can include compositor/vsync wait; neither measures GPU completion. |
| `linux_frame_until_present` | After event polling through normal frame presentation. Excludes post-present handlers and idle sleep. |
| `linux_frame_post_present`, `linux_frame_idle_wait` | Post-present drains and input handlers, then intentional idle sleep measured separately. |
| `chat_list_load`, `contacts_load`, `archived_chat_list_load`, `profile_load`, `profile_read` | Synchronous reads/projection; cached profile no-ops are excluded. |
| `timeline_open`, `timeline_page`, `timeline_handoff`, `timeline_apply` | Subscription/initial snapshot, cursor reads, latest snapshot publication-to-UI handoff, and UI projection. Subscription idle waits are excluded. |
| `message_send` | Send worker execution including uploads/runtime calls and cleanup, excluding thread scheduling. |
| `message_search`, `conversation_search` | Global message search and sidebar conversation filter worker execution, including failed or cancelled partial searches; excludes debounce/queue wait. |
| `media_queue_wait`, `media_prepare` | Enqueue-to-worker-start, then the worker's load/decode/cleanup. |
| `media_load`, `media_cache_read`, `media_decode`, `media_apply` | Cache/download work, successful cache reads, decode/preparation, and UI texture/view installation. Cache reads are a subset of loads. |
| `linux_vault_derive_key`, `linux_vault_open`, `linux_vault_create`, `linux_vault_persist`, `settings_save` | Key derivation, vault operations and settings persistence, including failures. No paths or secret values are recorded. |

Screenshot-exit frames contribute update/layout/draw samples but skip the
normal presentation and post-present measurements. Nested spans overlap;
their sums are not elapsed wall time. Collection itself adds clock reads
and mutex updates and is included in outer spans.

For automated runs, `WN_TIMINGS=/absolute/path/timings.json build/app`
writes the local Linux report on normal exit, including screenshot runs.
The report can also be copied alongside MDK counters from Debug > Timings.
Record the build, hardware, renderer/display, window size, dataset, workload,
network, cache state, sample counts, and warm-up policy with each comparison.
Run the same workload on the other apps before making comparative claims.
