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
