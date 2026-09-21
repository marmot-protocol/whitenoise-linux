# Outbound latency investigation, 2026-09-21

Push-enabled sends now reuse connected subscription sockets for their signed
notification gift wraps. Previously notification publishing opened a separate
connection after message publication, occupying the account worker until it
finished. The existing signer-bound fallback still handles disconnected
endpoints and explicit authentication rejection.

Three alternating baseline/candidate pairs used isolated two-member groups,
30 sequential messages per run, and the EU and US White Noise relays. Both
builds included the unchanged-subscription guard below; the only measured
network-path difference was notification connection reuse. Each send required
a relay acknowledgement and independent receiver decryption. Release builds,
no injected delay, push enabled with a synthetic token and generated server key:

| Caller response, 90 sends per build | Before | After |
| --- | ---: | ---: |
| Mean | 525.8 ms | 210.7 ms |
| p95 | 537.6 ms | 217.9 ms |
| Maximum | 543.9 ms | 222.0 ms |

Mean response decreased 59.9%. This measures the complete SDK send response,
including push publication. It does not establish cross-platform rankings or
explain every historical queue stall. Reproduce with:

```sh
cd vendor/mdk
SEND_PUSH=1 SEND_RELAYS=wss://relay.eu.whitenoise.chat,wss://relay.us.whitenoise.chat \
  CC=clang cargo test --release --locked -p marmot-app --test relay_runtime \
  send_connection_reuse -- --ignored --nocapture
```

Without `SEND_RELAYS`, the diagnostic uses a local relay and counts connections.
With `SEND_PUSH=1`, it also fetches and decrypts all 30 notification gift wraps.
Both public-relay and loopback delivery checks passed. Loopback opened zero
connections during the candidate's 30 sends, versus 30 before. Its mean was
56.6 ms versus 36.3 ms before, so the latency improvement is specific to the
measured remote-relay workload. The final local fixture allows 1,000 events
per minute: setup plus 30 messages and 30 pushes exceeded the mock's default
60-event allowance on one connection.

Unchanged subscription syncs now return before rebuilding the routing index.
The lifecycle lock and pending-unsubscribe retry remain in place. A separate
release benchmark measured sync alone, excluding request cloning, after ten
warmups with 100 samples per group count:

| Groups | Before median | After median |
| --- | ---: | ---: |
| 1 | 0.001803 ms | 0.000180 ms |
| 100 | 0.163177 ms | 0.005139 ms |
| 1,000 | 1.708731 ms | 0.051287 ms |

Reproduce with `cargo test --release --locked -p transport-nostr-adapter
--test inbound_routing unchanged_sync_latency -- --ignored --nocapture`.

The [Arena outbound panels](https://grafana.ipf.dev/d/mdk-app-arena/mdk-app-arena?from=now-7d&to=now&var-env=production)
combine Linux commits under `2026.9.15+1`. That label cannot isolate a build.
Read-only production queries on September 21 returned these means:

| Stage | Seven days | Last 24 hours | Last three hours |
| --- | ---: | ---: | ---: |
| Queue wait | 6,622.6 ms | 207.5 ms | 449.2 ms |
| Send execution | 1,081.3 ms | 972.0 ms | 888.9 ms |
| Local accept | 12.4 ms | 24.9 ms | 19.9 ms |
| Publish | 775.4 ms | 578.1 ms | 379.5 ms |
| Caller response | 7,704.3 ms | 1,179.9 ms | 1,338.6 ms |

There were approximately 203, 39, and 18 send samples respectively.
Counts use Prometheus `increase`, including its boundary extrapolation.
These are different workloads, not a before/after comparison. The recent
queue delay still needs a controlled reproduction; storage transaction mean
was 0.17 ms over 24 hours, while worker convergence averaged 1,276.5 ms.
Aggregate timings alone cannot identify which operation blocked a send.

The existing `active_group_send_timings` release diagnostic passed on the
local working tree with a loopback relay. Caller means were 36.5, 59.4, and
138.1 ms for 2-, 5-, and 9-member groups (14, 35, and 63 samples). Twenty-six
sends returned accepted-pending during group changes; every measured row
eventually obtained a published source. This checks SDK state, not rendering
or independent receiver decryption, and does not establish a platform lead.

The host fix requests bottom scrolling when text, files, or image albums
enter the pending list. Previously the row could remain below the viewport
until another update or manual scroll. The composer also stops rebuilding
the retained timeline on send: one full projection becomes zero on that path.
Subscriptions and the existing completion fallback still reconcile messages.

`tests/odin.sh app -define:ODIN_TEST_NAMES=send_reveals_preview` checks the
scroll request without a usable client. It fails against the previous send
code. `just test` covers the existing acknowledgement handoff as well.
No deployed latency improvement is claimed until fresh production samples
exercise this change.
