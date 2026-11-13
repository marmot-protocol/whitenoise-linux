# Development

```sh
just                   # list commands
just build             # build
just test              # build, then run the tests
just dev               # rebuild code in-process, keeping the window
just test-reload       # check reload, unlock, and failed-build recovery
just translations      # regenerate the gettext catalogs
```

`just dev [data-dir]` and `just run [data-dir]` accept an optional data directory.
The shell implementations live under `scripts/`; CI and packaging call them directly.

All tests live under `tests/`; `just test` runs the same checks as CI. For a focused Odin run, use `tests/odin.sh app [odin test flags]` or `tests/odin.sh app/sdlrl`. The runner assembles a temporary package so tests retain access to private symbols. End-to-end testing (a QEMU VM harness, a headless control daemon, and multi-VM messaging scenarios) lives in the separate [`darkmatter-automated-testing`](https://github.com/marmot-protocol/darkmatter-automated-testing) repo, which builds this checkout.

Vault fixtures must release `g_vault` with `vault_lock()` or `vault_delete()`
before releasing `test_home_lock`. The test allocator resets after each test;
leaving its strings in the vault lets a later worker free them with the wrong
allocator.

Theme and font registries outlive individual tests. Fixtures that populate
them use `runtime.default_context().allocator`. Tests that replace `g_ui` take
`nendo_test_mutex` before `test_home_lock` when both are needed. Use nonfatal
expectations while holding these locks: Odin's `fail_now` skips deferred
unlocks and can stall the suite.

Mention-chip fixtures also populate the global profile caches. Use the runtime
allocator and defer `profile_session_clear()` while holding `nendo_test_mutex`.

Composer wrapping allocates its cache on the process heap without changing
the caller's allocator. Mention measurement can queue profile reads; those
IDs must stay on the UI heap that frees completed batches.

Closed avatar covers stay in normal layout flow so sidebar mentions retain
both the preview's horizontal clip and the chat list's vertical clip. Only a
partly open cover floats over its revealed fingerprint.

Use `tr("text")` for UI strings and `tr("%d item", "%d items", count)` for
counted labels, then format the returned string with the count. The latter
selects the first catalog entry for one and the second for every other count.
Run `just translations` to extract both entries. Japanese and Korean use the
same translation for both; English, Italian, and German distinguish singular
and plural. This does not interpret gettext `Plural-Forms` expressions;
adding a language with other count rules requires extending `tr()`.

`just dev` keeps the SDL window and vault unlock across code reloads. It rebuilds
the UI and runtime from saved settings and drafts, so transient dialogs and
playback reset. Reload waits for active writes and file pickers, and for you
to send or clear staged attachments and finish message edits.
Failed builds leave the current app running. Changes to the small C window
host or the Rust library restart the host; the vault stays unlocked for the
`just dev` session. Normal release builds do not accept the dev unlock cache.

To build against a different Marmot revision, edit `mdk-commit` in `DEPS_PIN`; the next `just build` re-checks it out and rebuilds the C bundle. Every pinned third-party revision lives in that one file.

Keep `build/cargo/native` and `build/cross/<target>/cargo` between builds. Cargo
checks MDK's inputs on each build and reuses unchanged crates across MDK pin and
patch changes. Rust and C/C++ compiler versions, target, and build flags select
separate cache directories. `CARGO_TARGET_DIR` selects the native cache root;
the build appends its compiler-environment fingerprint.

Cross builds also retain the target sysroot, SDL, speech runtime, and vcpkg
outputs. Their stamps include the inputs that produced them; changing those
inputs rebuilds the affected dependency. CI restores Cargo state from older
source revisions within the same compiler/target boundary, rather than treating
a previously staged Marmot library as proof that its inputs are unchanged.

Native and cross builds also cache C/C++ helpers and Odin outputs by input
contents, compiler, target, and flags. Output manifests detect missing or
corrupted files. Dangling SDK symlinks contribute their link metadata to input
keys; resolving or retargeting them invalidates the cache. Output manifests
reject dangling links. Native Linux/OpenBSD and cross builds cache Odin objects
separately from linking, so an MDK-only change relinks the app without
recompiling its Odin sources.
Linux and Windows package caches cover bundled runtime libraries and archives;
release downloads, signing, and update feeds still run when requested.

The build-server workflow builds native Linux, Linux amd64/arm64, Windows amd64,
and OpenBSD amd64 once each. It runs the native C/Odin suite, packaged Linux and
Windows startup tests, and OpenBSD's filesystem, helper, and startup tests.
The native runner signs temporary Git fixtures with a dedicated CI test key.
The MDK patch-staging test generates its own temporary SSH signing key.
The workflow queues these five jobs together on two isolated
runner slots, with six build threads per job and shared CPU/memory limits.
Native and Linux jobs use `wn-cache-2`; Windows and OpenBSD use `wn-cache-1`.
This keeps targets on warmed caches while both slots can build concurrently.
Bragi's math-helper object is cached per target and slot, including its sources,
font, toolchain, and build flags. Unrelated application edits do not rebuild it.
Native SDL, Odin overlay, and Odin object keys track SDK headers and
versions separately from shared-library contents. OpenBSD's boot-time library
reordering invalidates linked executables, not these compiled outputs.
It does not change the default-branch runner routing or include macOS.

The current pin is MDK master at `c8210585cab6` (0.14.0-dev). The build applies
the patches listed in `scripts/build.sh`. NIP-46 C sessions, Windows
portability, OpenBSD sandbox support, SOCKS5 routing, and Markdown timestamps
come from upstream MDK.
The app supplies White Noise's deployment services explicitly when creating
the Marmot client; every C constructor requires a deployment.
History catch-up uses MDK's ordered replay and account-owned recovery.
The `retry-convergence` dev command retries convergence for the selected group.
Staging recognizes an already-applied prefix of the patch series and applies
only the remaining patches. Appending a patch does not require resetting
`vendor/mdk`, even when earlier patches overlap. Local edits outside the files
touched by the patches are preserved. Conflicting local edits still stop staging.
Poll creation, voting, and tallies use MDK's native poll APIs and timeline
projection. `patches/mdk-poll-context.patch` preserves thread and issue context
through native creation. MDK supports poll creation in direct and group
conversations. A multiple-choice vote must retain at least one selection.
Poll cards stay compact in wide chats and wrap option labels in narrow panes.
Checkmarks identify your selections.

Validate MDK patch changes by applying the full `MDK_PATCHES` list, in order,
to a clean checkout of `mdk-commit`, then checking the already-patched tree.
A successful reverse check alone can hide an invalid old-file path.
Run `bash tests/mdk-patches-test.sh` to check fresh staging, reruns, appended
overlapping patches, preserved unrelated source edits, and conflicting local edits.

Publishing workflows read `WN_METRICS_WRITE_TOKEN` and `WN_AUDIT_WRITE_TOKEN`
from CI secrets. Configure both on GitHub and on trusted ngit/act publishing
runners, not PR runners. Local builds without them contain no write tokens.
The build embeds a generated, mode-0600 `build/observability-tokens.toml`;
CI removes that file before cache and artifact uploads. Tokens must be
printable ASCII without double quotes or backslashes.

This keeps credentials out of source and build logs, but they remain
extractable from published binaries. Keep them write-only and narrowly
scoped. The optional per-user `observability.toml` overrides embedded settings;
protect credentials in that file with mode 0600. On macOS it lives under
`~/Library/Application Support/whitenoise/`; on Windows, under
`%LOCALAPPDATA%/whitenoise/`. Uploads still require the corresponding consent
setting. See [timing and observability configuration](timings.md).

## Git hooks

Before your first commit, install the project git hooks (**required**):

```sh
scripts/install-hooks.sh
```

This points `core.hooksPath` at the tracked `.githooks/` directory and registers the `po-clean` catalog filter, so the same checks CI enforces run locally before you commit. The `pre-commit` hook normalizes and validates staged gettext catalogs (stripping source-line references and the volatile `POT-Creation-Date` header so unrelated line shifts never surface as diffs), and keeps the GitHub mirror of the ngit-ci gate in sync. Needs `gettext`.

In a real emergency you can bypass a single commit with `git commit --no-verify`, but CI runs the same checks, so the bypass only defers them.

## Architecture

```
 SDL3  ←──  app/sdlrl/  ←──  app/renderer.odin  ←──  nendo layout (app/*.odin)
                                                          │
                                                    app/state.odin  (Ui_State)
                                                          │
                                              app/workers.odin  (worker threads)
                                                          │
                                                   marmot/marmot.odin
                                                          │
                                            marmot-c  →  the Marmot runtime
```

It reads flat by intent. The layout is immediate-mode: every frame rebuilds the nendo tree by reading one `Ui_State` struct, so there is no retained view tree, no widget objects, and no observer graph to trace. Panes are plain procs.

| Path | What's there |
| --- | --- |
| `app/` | The whole app: panes, layout, state, workers, vault, media viewers |
| `app/state.odin` | `Ui_State`, the single struct every pane reads, plus the live theme globals |
| `app/chatpane.odin` | Chat-pane rendering, group info, and the composer |
| `app/loginpane.odin` | Sign-in and key-generation UI, with button and progress helpers |
| `app/workers.odin` | Live subscriptions, sends, member loading, and other blocking Marmot calls kept off the UI thread |
| `app/sdlrl/` | SDL3 shim with a raylib-shaped API: window, input, IME, clipboard, and a stb_truetype text engine |
| `app/nendo/` | nendo, White Noise's layout engine |
| `app/vault.odin` | The password-encrypted secret vault |
| `marmot/` | The `marmot-c` bindings, the only place that touches C |
| `app/password.odin` | The allocation-free password-strength heuristic and input cache |
| `tests/smoke/` | Standalone liveness check for the bindings against a fresh home dir |
| `themes/` | The theme packs, `#load`ed at build time |
| `lang/` | gettext catalogs (`en` source, plus `it`, `de`, `ja`, `ko`), `#load`ed at build time |
| `assets/` | Logo, fonts, and the SVG starter-avatar set |

A few design choices are worth knowing before you dig in:

- **Optimistic rendering.** Sending, reacting, and unreacting apply locally and repaint immediately, then reconcile against Marmot's response. The UI never blocks on the network round-trip.
- **Two upload paths.** Chat attachments go through Marmot's encrypted MIP-04 path, readable only by group members. Profile pictures take the deliberately public Blossom path.
- **Data-driven themes.** Every color, metric, and capability flag comes from a `themes/*.toml` pack. The parser and editor share one token-to-field table in `app/theme.odin`; `app/state.odin` owns the live colors. A new component reads the globals; it never branches on which theme is active. Fullscreen media uses `media-backdrop` and `media-chip-bg` for its backdrop and floating header.
- **Standard math.** Motion, decoration and sound synthesis call `core:math` directly, evaluating `f64` phases before narrowing to `f32`. Checkmark strokes use `math.sqrt` with a minimum normalization length of 0.001.

Sidecar palettes, title faces, and background artwork are pinned to
`3aaebf9dc7beb9924c6e1f9bc060cecbc1be6f8f`. Run
`bun scripts/render-sidecar-themes.ts` with Chromium installed to regenerate
the embedded 1280×800 background images from the source CSS and SVGs.
Backgrounds keep their aspect ratio and fill the window, centered with excess
cropped at the edges. Browser animations and component-surface gradients are
not reproduced. `font-title` selects a bundled display face
separately from the body `font`. Font licences, source hashes, and conversion
details are in `assets/fonts/sidecar/` and installed with the fonts. The native
text engine does not provide browser OpenType shaping.

For the deeper details, see [`AGENTS.md`](../AGENTS.md).
