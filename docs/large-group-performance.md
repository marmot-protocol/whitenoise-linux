# Large-group UI performance

Measured on 2026-09-22, AMD Ryzen AI MAX+ 395, Odin
`dev-2026-09:a2fb372b7`, `-o:speed`, SDL dummy video driver, 1200×800.
Baseline: `ba5b14e`. Each process takes 31 samples after five warmup layouts.
The table reports the median of five process medians, alternating baseline
and changed builds with no compilation running during measurement.

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Member-panel layout, 1,000 members | 2.118 ms | 0.262 ms | 8.08× |
| Mention search, 1,000 members, no match | 0.691 ms | 0.205 ms | 3.37× |
| Timeline layout, 1,000 member-join messages | 5.141 ms | 0.449 ms | 11.45× |

The slowest measured improvement is 237% greater throughput. These measure
local UI work, not relay latency, message decryption, first-open database
latency, GPU presentation, or overall application speed on a real account.

The member panel previously built every avatar and name on every frame.
It now builds 13–16 detailed rows in the tested viewports, keeping fixed-height
placeholders for scroll geometry. System messages previously bypassed
timeline virtualization; they now use the same measured heights as chat rows.
Mention search reuses the member's stored npub instead of encoding it on
every unsuccessful name comparison.

Chat selection also fetched all members solely to populate a field that had
no readers. That runtime query is removed (one call per switch becomes zero).
Member-panel and mention loading now fetch group details on a worker, discard
results for obsolete account/group selections, and join workers at shutdown.
Member snapshots release their strings when replaced or leaving a chat.

Run the benchmark and scroll, narrow-layout, nickname, and search checks:

```sh
SDL_VIDEODRIVER=dummy tests/odin.sh app -o:speed \
  -define:WN_PERF=true -define:ODIN_TEST_NAMES=large_group_layout
```

`just test` also checks snapshot ownership and stale worker completions.
`just test-reload` checks shutdown and module replacement.

The follow-up removes periodic chat-list and mentions-inbox database scans
from the UI thread. Live events coalesce behind one chat-list reader; account
changes and explicit refreshes invalidate older results. System-message
previews use the supplied event instead of rereading its timeline, and marking
messages read no longer reloads the entire chat list or saves unchanged prefs.

Incoming messages now preserve the viewport when reading older messages.
Scroll-anchor and jump corrections are rendered in the same frame, avoiding
one frame at the old offset. The regressions cover a blocked reader, stale
results, mention filtering, and arrivals while scrolled away from the bottom.
Row measurements use the offset captured for layout, so anchor corrections
cannot undo a scrollbar drag made during that layout. The large-group test
holds the mouse down across four thumb positions and checks three frames at
each position before release.
