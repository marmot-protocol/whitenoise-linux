---
name: two-frame-ui-feedback
description: Find and fix delayed UI feedback, blocked rendering, bare spinners, and missing progress in White Noise Linux. Use for responsiveness audits and user reports of lag or actions that appear to do nothing.
---

# Two-frame UI feedback

## Contract

Every user action MUST produce visible feedback within 0 to 2 frames at
60 fps (at most 33.33 ms). This is an input-to-visible-feedback budget, not
a deadline for completing the underlying work. Longer operations MUST show
that work is happening within the same budget and remain visibly pending
until completion, failure, or cancellation.

Match feedback to the element. Opening a menu, inserting a pending message,
or starting an animation can provide immediate feedback. A spinner MUST
include details of what is happening and a progress bar. A bare spinner is
insufficient. Show measured progress when available; otherwise use an
explicitly indeterminate bar. Never invent percentages or imply success
before the operation succeeds.

## Find the broken interactions

1. Read repository rules and the relevant runtime/debug skills. Use descriptive
   search to locate action handlers, frame rendering, workers, and existing
   pending/progress states. Reuse existing conventions.
2. Trace each in-scope action from input through state mutation, scheduling,
   rendering, and completion. Record its handler, first visible feedback,
   blocking work, and terminal states.
3. Look for synchronous I/O, network calls, decoding, parsing, database work,
   waits, lock contention, expensive loops, and lazy initialization on the UI
   thread. Also find background work with no visible pending state. Moving
   work off-thread alone does not satisfy the contract.
4. Exercise cold and warm paths, realistic large inputs, slow dependencies,
   and repeated actions. Do not generalize from a cache hit or tiny fixture.
5. Reproduce findings in the actual UI before editing. Capture input and the
   first changed frame with timestamped instrumentation or a recording with
   enough time resolution. Measure from actual input, not entry into a handler
   that may already be delayed. Record whether timing measures rendering or
   presentation. A screenshot proves appearance, not latency.

## Fix the interaction

1. Define the smallest required state first: pending work, activity details,
   measured progress if available, and terminal results. Reuse existing state
   and workers rather than adding a second framework.
2. Set visible pending state when accepting the action, before expensive work.
   Let the renderer present it within the budget. Setting a flag and then
   blocking the UI thread still fails.
3. Move blocking work to the existing worker mechanism, or split bounded CPU
   work across frames when appropriate. Keep UI mutation on the UI thread.
   Avoid unbounded work and new hot-loop allocations in frame callbacks.
4. Choose feedback appropriate to the element. Start its animation promptly
   or show an in-place pending result. Spinner-based feedback needs activity
   details and a progress bar together. Keep feedback responsive throughout
   the operation, not merely painted once before a stall.
5. Apply results at the normal frame boundary. Resolve pending feedback on
   every terminal path and show the actual outcome. Preserve error recovery.
   Prevent stale results from overwriting a newer action or updating a closed
   view. Preserve repeated-action semantics; do not add unrelated retries or
   cancellation features.

## Repository integration

- `app/state.odin` owns `Ui_State`; panes read it directly each frame.
- Inspect `app/workers.odin` for blocking Marmot calls and frame-boundary
  result delivery before introducing another work queue.
- Workers use `reload_allocator()` and must be joined before module unload.
  Run `just test-reload` when changing reload or shutdown behavior.
- User-visible text goes through `tr()`. Mark table literals with `N_()` and
  register new translating helpers in `scripts/update-translations.sh` when
  required. Follow existing copy and translation rules.
- Read theme tokens rather than branching on theme identity. Keep feedback
  local to the relevant control or pane where possible.
- Use the actual SDL app for visual verification. Use isolated data/config
  directories for scenarios that mutate data, not the user's vault or chats.

## Verify and report

Exercise the repaired action under normal and deliberately slow conditions.
Verify feedback starts within the budget, stays visible and responsive while
work continues, and resolves correctly on success and failure. Exercise
cancellation and view changes where supported. Use existing test facilities
or temporary instrumentation for slow conditions; remove scaffolding after
verification.

Keep deterministic regression tests for consumer-visible state transitions,
races, and error paths where useful. Do not add wall-clock threshold tests
that depend on CI scheduling. Tests do not replace runtime observation.

Report the action, cause, affected files, feedback chosen, and measured
before/after input-to-feedback latency with measurement limits. If presentation
timing cannot be measured, say so. Do not claim the budget was verified from
screenshots, handler duration, or code inspection alone. Update existing docs
for permanent behavior changes and follow repository formatting and commit
rules.
