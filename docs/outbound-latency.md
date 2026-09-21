# Outbound latency investigation, 2026-09-21

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
