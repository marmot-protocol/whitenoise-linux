# Private group issue tracking

Issue tracking is disabled by default, enabled for the whole group by an
admin, and displayed in an Issues sidebar. Reports stay inside the encrypted
group. Issue transport uses existing custom events. The phase-1 audit found
that durable, authorized configuration needs an MDK API extension exposing
the existing optional group-component mechanism.

## Phase 1: Prove shared configuration

Status: implemented. MDK PR [#1929](https://github.com/marmot-protocol/mdk/pull/1929)
exposes authenticated optional group components. This app pins its head,
`6452402c3728df9de1ab85e11d19a6a1f75cc20f`. The original audit below is
retained as design rationale.

- Define versioned group configuration in an optional MLS app component.
- Validate admin authority using authenticated pre-commit group state,
  rather than trusting sender-supplied timestamps or tags.
- Define deterministic handling of concurrent changes and duplicate delivery.
- Verify promotion, demotion, offline delivery, restart, new-member onboarding,
  and configuration survival when disappearing messages expire.
- Expose the existing authenticated group-state mechanism through the app
  and C APIs. The rejected custom-event approach is documented below.
- Do not build the UI around an unproven authorization or persistence model.

## Phase 2: Define issue events

Status: implemented.

- Kind 1621: subject, Markdown description, optional labels.
- Kind 1111: comments with complete NIP-22 root and parent tags, Markdown,
  encrypted media, mentions, replies, reactions, author edits, and deletions.
- Existing kind-1068 polls can also be posted inside an issue discussion.
- Kinds 1630, 1631, 1632: open, resolved, closed.
- Group members can report and comment. Authors and group admins can change
  issue status. Map group admins to the maintainer role for this adaptation.
- Document the private-group adaptation of NIP-34; do not fabricate repository
  addresses or publish private issues to public Nostr trackers.

## Phase 3: Load issues independently of chat

Status: implemented. Raw kind-filtered history supplies issue identity and
status; the existing timeline projection supplies full comment messages.

- Bind the C API for kind-filtered raw messages. Reuse the existing group-event
  subscription and periodic refresh instead of opening a second firehose.
- Store flat issue records and an ID lookup in app state.
- Reconstruct status and comments deterministically, handling duplicate and
  out-of-order events. Validate references within the same account and group.
- Load issue history independently of the visible chat page.
- Exclude configuration, issues, issue comments, and status events from chat.
- Run blocking reads on reload-safe workers using the existing worker pattern.

## Phase 4: Add settings and sidebar

Status: implemented and visually revised. Issues have crop circles derived
from their event IDs, a searchable list, a compact status filter, a reading
pane, and the same composer and message actions as normal chat. Narrow
windows switch between list and detail. Text and staged files stay scoped to
their discussion; offline retries retain the original issue address.

- Add an admin-only Issue tracking control to group settings. Other members
  can see the current setting.
- Enabled groups show an Issues sidebar with search, status filters, and
  New issue. Selecting an issue opens its description and discussion.
- Expose status actions only to the author and admins; validate incoming
  events independently of which controls the UI displays.
- Disabling hides the tracker and prevents new issue actions without deleting
  records. Re-enabling restores records still available under group retention.
- Reuse existing layout, fields, Markdown rendering, and worker patterns.

## Phase 5: Verify persistence and group behavior

Status: implementation complete; validation recorded below.

- Keep configuration durable independently of expiring discussion messages.
- Issue history follows group retention. New membership must not silently
  grant access to earlier private history.
- Test permissions, ordering, group isolation, reconstruction, and malformed
  input, including changes arriving before their referenced issue.
- Run just test and just test-reload when worker lifecycles change.
- Exercise two clients: enable, report, comment, resolve, disable, reconnect.
- Update translations and PORT.md; visually inspect the sidebar and narrow
  layouts, including keyboard interaction.

## Scope

No assignments, milestones, boards, public ngit synchronization, or custom
notifications in the first version.

## Phase 1 findings (2026-09-19)

Audited MDK pin `4800db0e2901b5be996f32d095f8aabb6d7ae013` with existing
local modifications present. No vendored source was changed for this audit.

### Custom events are suitable for reports, not the setting

- `marmot_send_custom_event` accepts non-reserved kinds and caller tags. It
  does not enforce admin-only application semantics. Hiding a control would
  not prevent a non-admin client from sending the same configuration event.
- Raw message records expose the source epoch, but the C roster API exposes
  the current roster. It does not expose an admin-at-source-epoch query.
  Rechecking old events against today's roster can change an old decision
  after a promotion or demotion and make clients disagree.
- The engine stamps application messages with the source group's retention
  policy without an exception for custom configuration kinds. An expiring
  event cannot be the only durable source of this setting.
- A local cached flag does not solve fresh-device or new-member recovery.
  Reposting events would require an additional state synchronization protocol.

Evidence: `crates/marmot-app/src/messages/intents.rs` (`Custom`),
`crates/marmot-c/include/marmot.h` (`MarmotAppMessageRecord`,
`marmot_group_roster`), and
`crates/cgka-engine/src/message_processor/send.rs` (source retention).
Paths in this findings section are relative to `vendor/mdk`.

### Use an optional app component in MLS GroupContext

MDK already implements `SendIntent::UpdateAppComponents` and component reads.
The send path requires an admin in the pre-commit group state; incoming
commits also undergo admin authorization before merge. Optional opaque
component bytes survive unrelated updates and are carried into new-member
Welcomes. This gives the setting an existing authenticated state and
convergence mechanism, independent of retained application messages.

Proposed setting contract:

- One documented private-use component ID, allocated before implementation.
- Exactly two bytes: version `1`, then enabled `0` or `1`.
- Component absent means disabled. Unsupported versions or malformed payloads
  mean unavailable, not permission to overwrite or enable the setting.
- Disabling writes the explicit version-1 disabled value.
- Keep the component optional so clients without the issue UI can preserve
  it and continue participating. Those clients do not enforce feature-specific
  UI behavior, so receiving clients must still validate issue actions.
- Read the canonical committed component. Do not introduce timestamp-based
  last-writer-wins or a separate application revision counter.
- Let MDK resolve competing commits. Surface a failed or superseded update;
  do not silently resend a losing enable/disable intent.
- A Welcome conveys the current setting, not old issue messages or keys.

Evidence: `crates/cgka-engine/src/update_group_data.rs`,
`crates/cgka-engine/src/message_processor/ingest.rs`, and
`crates/cgka-engine/tests/update_group_data.rs`.

### Required MDK surface

The C header has custom-message APIs but no general app-component read/update
API. The app group projection reads a fixed list of known components. Merely
adding Odin declarations cannot expose the missing functionality.

Next implementation slice: expose the existing optional private-use component
read/update path through marmot-app and marmot-c, retaining the existing
publication, authorization, rollback, and convergence behavior. Include a
reliable way to refresh the value after group-state changes. Keep issue UI and
NIP-34 interpretation in this Linux client; no new MLS engine mechanism is
needed. This is an MDK API extension, correcting the original no-MDK-change
assumption. New exported API signatures need review before implementation.

### Validation

Run from `vendor/mdk`:

```sh
CFLAGS=-O1 cargo test --locked --offline --release -p cgka-engine \
  --test update_group_data \
  --config profile.release.package.cgka-engine.debug-assertions=true
```

The default C optimization failed to link SQLCipher's `xoshiro_s` TLS
relocations with both lld and GNU ld. `CFLAGS=-O1` let the test binary build;
no source workaround was applied.

Result: 33 passed, 0 failed (19.95 seconds).

The existing tests cover non-admin rejection, promotion, opaque component
preservation through updates and invites, concurrent changes, publication
rollback, and restart convergence. These are engine-level checks, not proof
that the missing C API or the issue feature works.

The PR's `app_component_lifecycle` regression exercises the API with admin
checks, promotion/demotion, Welcome onboarding, retention expiry, and restart.
The additional `linux_issue_two_clients` test uses independent runtimes and
stores to cover report/comment/status delivery and an offline enable change.
Concurrency and opaque-component preservation remain covered by the existing
engine tests. Source-state authority is exposed separately as described below.

## Implemented contract and compatibility

- Optional private-use component `0xf301`, exactly `[1, enabled]`, where
  enabled is `0` or `1`. Absence means disabled; malformed or unknown
  versions mean unavailable. Only the MDK-authenticated admin path can update it.
- Status events require the issue author or an affirmative source-state admin
  grant. Current roster membership cannot authorize an old event. Unknown
  authority fails closed for non-author status changes; invalidated events
  cannot affect the projection.
- `patches/mdk-message-authority.patch` exposes source authority and invalidation
  in raw C records, preserves status grants in SQLite, and gives kind-1111
  comments chat media/reply/edit handling and mention tags. It supplements
  PR #1929 locally; it is not part of that upstream PR.
- Reports and comments remain inside MLS. No fake repository address tags or
  public publication are added. Authors/admins replace public repository
  maintainers for status permissions in this private adaptation.
- Disabling hides the UI and rejects new issue sends without deleting retained
  records. Re-enabling reconstructs what retention still permits. A Welcome
  carries the current setting, not earlier message keys or history.
- The C timeline API has no root filter. While browsing issues, a worker reads
  retained timeline pages to hydrate all comments, including old discussions
  outside the normal chat window. A future root-filtered MDK query can replace
  this scan for large histories. No additional dependency was added.

## Implementation validation (2026-09-19)

- `just test`: 176 app tests pass, plus the build's C ABI and helper checks.
  One earlier parallel run hit the existing shared-theme test race; a full
  rerun passed. Existing allocator warnings remain in unrelated tests.
- `just test-reload`: passes code replacement, window/unlock preservation,
  and failed-build recovery. This harness has no active group.
- `linux_issue_two_clients`: passes using two stores/runtimes and a loopback
  relay: non-admin rejection, enable, report, comment, admin resolve, disable
  without deletion, and restart/offline enable recovery.
- `comment_chat_features`: passes media metadata, replies, accepted author
  edits, rejected foreign edits, reactions, history, and deletion in SQLite.
- Six existing accepted-edit regressions pass.
- `comment_mentions` passes parent-tag preservation and mention deduplication.
- `app_component_lifecycle` passes admin rejection, promotion/demotion, new-member
  Welcome, retention expiry, and restart through the PR API.
- App regressions cover malformed settings/tags, expiry, duplicates, ordering,
  source authority/invalidation, group isolation, attachment-only comments,
  mention recipients, draft routing, and offline issue addresses.
- Explicit SDL layout checks pass at 1280px and 420px in dark/English and
  light/German, including list, detail, composer, and creation form. Screenshots
  were inspected. These are layout checks, not a full interactive end-to-end run.
- All three local MDK patches apply cleanly to the pinned PR revision.

## References

- [NIP-34](https://github.com/nostr-protocol/nips/blob/master/34.md#issues)
- [NIP-22](https://github.com/nostr-protocol/nips/blob/master/22.md)
