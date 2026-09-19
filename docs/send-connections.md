# Send connection reuse

On 2026-09-19, 90 real-network sends per build averaged 1,744.136 ms before
and 145.304 ms after (91.7% lower). All 180 messages obtained relay
acknowledgements and were decrypted by an independent receiving runtime.
[Raw samples](send-connections-results.txt) include every measured send.

| Build | Mean (ms) | Median (ms) | p95 (ms) | p99 (ms) |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 1744.136 | 1219.175 | 5842.597 | 10630.380 |
| Reuse connected sockets | 145.304 | 144.840 | 150.721 | 155.624 |

Three alternating baseline/candidate pairs each sent 30 messages. Pair means
were 1137.989/144.708, 2854.999/145.110, and 1239.421/146.094 ms.
Percentiles use nearest rank. Public-network outliers remain in the results.

## Change

The account publisher opened and removed a separate write connection for
each publication, although the shared subscription pool was already connected
to those relays. Signed events now use that connected pool. Unsigned events,
missing or disconnected sockets, and a shut-down pool retain the existing
account publisher. An explicit authentication-required rejection retries with
the account publisher.

Relay targets, signatures, encryption, persistence, acknowledgement requirements,
fanout completion, and telemetry timer boundaries are unchanged. The fanout
still waits for every attempted endpoint's outcome. This does not make a local
message insertion count as a successful network send.

## Method

- Release builds of pinned MDK `4800db0e2901b5be996f32d095f8aabb6d7ae013`.
  Existing workspace changes were held constant between builds; only the
  publishing change differed. Both binaries used the same benchmark harness.
- Each run created two temporary identities, independent storage and runtimes,
  and a fresh two-member MLS group. After setup, both builds waited two seconds
  for subscriptions. Measured messages had distinct plaintext.
- Both default Linux relays were used: `wss://relay.eu.whitenoise.chat` and
  `wss://relay.us.whitenoise.chat`. No proxy or artificial delay was on this path.
- Timing starts before `MarmotAppRuntime::send_message` and ends when it returns
  with a publication. Receiver plaintext is checked before the next send.
  `received_ms` is the time of that check, an upper bound on actual receipt.
- Diagnostics were disabled, and the test binary had no OTLP export feature.
  Temporary local identity files were removed on normal test completion.
- In these logs, `new_connections=0` is an inactive loopback-proxy counter, not
  a measurement of public connections. The final harness prints `None` instead.

The separate loopback proxy counted 30 new connections before and zero after
for 30 sends. With no simulated setup delay, that local test regressed from
8.321 to 26.621 ms mean. Reuse benefits network connection setup; it is not a
universal latency improvement. A separate synthetic setup-delay experiment is
excluded from the real-network results above.

## Reproduce

The Linux build applies `patches/mdk-send-connections.patch`. From `vendor/mdk`:

```sh
CC=clang cargo test --release --locked -p marmot-app --test relay_runtime signed_publish_reuses_pool
SEND_RELAYS=wss://relay.eu.whitenoise.chat,wss://relay.us.whitenoise.chat \
  CC=clang cargo test --release --locked -p marmot-app --test relay_runtime \
  send_connection_reuse -- --ignored --nocapture
```

The second command publishes real test traffic. Omit `SEND_RELAYS` for the
local connection-count diagnostic. To build a baseline, retain the identical
test harness and reverse only the patch's `src/relay_plane/mod.rs` hunk, then
build and copy the executable before restoring the publishing change.

## Limits

The screenshot's 1.3 s iOS mean implies a 1.04 s target for 20% lower latency.
145 ms clears that reference in this workload. This is not a paired iOS test
or a deployed Arena result. The dashboard aggregates different devices,
versions, histories, and workloads; its timer also excludes worker queue wait.
This benchmark includes caller dispatch and queue wait but uses an idle,
fresh two-member group. Production Arena measurement is still needed to claim
the requested platform-wide lead. No dashboard queries or metrics were changed.
