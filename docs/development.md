<sub>MAINTAINERS&ensp;·&ensp;DEVELOPMENT</sub>

# Development

### Reload the code, keep the window, and let the caches remember the rest.

This page covers the `just` commands, the rules tests must follow, and how builds stay fast. Install the git hooks before your first commit.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/development-reload-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/development-reload-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/development-reload-dark.svg">
  <img alt="What just dev does across a code reload. Kept: the SDL window, the vault unlock, saved settings and drafts. Rebuilt: the UI and the runtime, so transient dialogs and playback reset. The reload waits for active writes, open file pickers, staged attachments and message edits. A failed build leaves the current app running; a change to the C window host or the Rust library restarts the host while the vault stays unlocked." src="../assets/docs/development-reload-light.svg" width="880">
</picture>

## Six commands cover the daily loop

```sh
just                   # list commands
just build             # build
just test              # build, then run the tests
just dev               # rebuild code in-process, keeping the window
just test-reload       # check reload, unlock, and failed-build recovery
just translations      # regenerate the gettext catalogs
```

`just dev [data-dir]` and `just run [data-dir]` accept an optional data directory. The shell implementations live under `scripts/`; CI and packaging call them directly.

## What `just dev` keeps across a reload

`just dev` keeps the SDL window and vault unlock across code reloads. It rebuilds the UI and runtime from saved settings and drafts, so transient dialogs and playback reset.

- **Reload waits for you.** It holds for active writes and file pickers, and until you send or clear staged attachments and finish message edits.
- **Failed builds change nothing.** The current app keeps running.
- **Native changes restart the host.** Editing the small C window host or the Rust library restarts the host; the vault stays unlocked for the `just dev` session.
- **Release builds ignore the dev unlock cache.** Normal release builds do not accept it.

## Tests run the same checks as CI

All tests live under `tests/`; `just test` runs the same checks as CI. For a focused Odin run, use `tests/odin.sh app [odin test flags]` or `tests/odin.sh app/sdlrl`. The runner assembles a temporary package so tests retain access to private symbols.

End-to-end testing (a QEMU VM harness, a headless control daemon, and multi-VM messaging scenarios) lives in the separate [`darkmatter-automated-testing`](https://github.com/marmot-protocol/darkmatter-automated-testing) repo, which builds this checkout.

On Linux, the tray needs a StatusNotifier host. Without one, the app starts with its window visible and closing it quits. To check the tray, enable **Close to tray**, close the window, then use the icon to reopen it. Close the window again and choose **Quit** from the tray menu.

## Fixture rules that keep the suite from stalling

- **Release the vault before the home lock.** Vault fixtures must release `g_vault` with `vault_lock()` or `vault_delete()` before releasing `test_home_lock`. The test allocator resets after each test; strings left in the vault let a later worker free them with the wrong allocator.
- **Registries use the runtime allocator.** Theme and font registries outlive individual tests, so fixtures that populate them use `runtime.default_context().allocator`.
- **Take `nendo_test_mutex` first.** Tests that replace `g_ui` take `nendo_test_mutex` before `test_home_lock` when both are needed.
- **Expect, do not fail, under a lock.** Use nonfatal expectations while holding these locks: Odin's `fail_now` skips deferred unlocks and can stall the suite.
- **Mention chips touch the profile caches.** Mention-chip fixtures also populate the global profile caches. Use the runtime allocator and defer `profile_session_clear()` while holding `nendo_test_mutex`.
- **Composer wrapping uses the process heap.** It allocates its cache there without changing the caller's allocator. Mention measurement can queue profile reads; those IDs must stay on the UI heap that frees completed batches.
- **Closed avatar covers stay in layout flow.** That way sidebar mentions retain both the preview's horizontal clip and the chat list's vertical clip. Only a partly open cover floats over its revealed fingerprint.

## Translations go through `tr()`

Use `tr("text")` for UI strings and `tr("%d item", "%d items", count)` for counted labels, then format the returned string with the count. The counted form selects the first catalog entry for one and the second for every other count. Run `just translations` to extract both entries.

| Language | Singular and plural |
| --- | --- |
| English, Italian, German | Distinct entries |
| Japanese, Korean | Same translation for both |

`tr()` does not interpret gettext `Plural-Forms` expressions. Adding a language with other count rules requires extending `tr()`.

## Install the git hooks before your first commit

The hooks are **required**:

```sh
scripts/install-hooks.sh
```

This points `core.hooksPath` at the tracked `.githooks/` directory and registers the `po-clean` catalog filter, so the same checks CI enforces run locally before you commit. The `pre-commit` hook normalizes and validates staged gettext catalogs (stripping source-line references and the volatile `POT-Creation-Date` header so unrelated line shifts never surface as diffs), and keeps the GitHub mirror of the ngit-ci gate in sync. Needs `gettext`.

In a real emergency you can bypass a single commit with `git commit --no-verify`, but CI runs the same checks, so the bypass only defers them.

## One file pins MDK and every other dependency

To build against a different Marmot revision, edit `mdk-commit` in `DEPS_PIN`; the next `just build` re-checks it out and rebuilds the C bundle. Every pinned third-party revision lives in that one file.

The build applies the patches listed in `scripts/build.sh`.

- **Upstream now carries the old patches.** NIP-46 C sessions, Windows portability, OpenBSD sandbox support, SOCKS5 routing, and Markdown timestamps come from upstream MDK.
- **Deployments are explicit.** The app supplies White Noise's deployment services when creating the Marmot client; every C constructor requires a deployment.
- **History uses MDK's replay.** History catch-up uses MDK's ordered replay and account-owned recovery. Partial epoch advances reassess retained unreadable messages after local replay settles, carrying recovery forward without reopening the account. The `retry-convergence` dev command retries convergence for the selected group.
- **MDK places thread messages.** `marmot_send_thread_message` builds the NIP-22 tags from the selected parent. The thread pane groups rows by the projected parent, so nested replies stay under the message they answer.
- **Polls are native.** Poll creation, voting, and tallies use MDK's native poll APIs and timeline projection. `marmot_create_tagged_poll` preserves thread and issue context through native creation. MDK supports poll creation in direct and group conversations, and a multiple-choice vote must retain at least one selection. Poll cards stay compact in wide chats and wrap option labels in narrow panes; checkmarks identify your selections.

MDK migrates account databases to schema 219. Older builds cannot open a migrated database.

<details>
<summary><b>Staging and validating the patch series</b></summary>

Staging recognizes an already-applied prefix of the patch series and applies only the remaining patches. Appending a patch does not require resetting `vendor/mdk`, even when earlier patches overlap. Local edits outside the files touched by the patches are preserved. Conflicting local edits still stop staging.

Validate MDK patch changes by applying the full `MDK_PATCHES` list, in order, to a clean checkout of `mdk-commit`, then checking the already-patched tree. A successful reverse check alone can hide an invalid old-file path.

Run `bash tests/mdk-patches-test.sh` to check fresh staging, reruns, appended overlapping patches, preserved unrelated source edits, and conflicting local edits.

</details>

## Keep the build caches between builds

Keep `build/cargo/native` and `build/cross/<target>/cargo` between builds. Cargo checks MDK's inputs on each build and reuses unchanged crates across MDK pin and patch changes. An MDK-only change relinks the app without recompiling its Odin sources.

<details>
<summary><b>What each cache key covers, and what invalidates it</b></summary>

- **Cargo.** Rust and C/C++ compiler versions, target, and build flags select separate cache directories. `CARGO_TARGET_DIR` selects the native cache root; the build appends its compiler-environment fingerprint.
- **Cross dependencies.** Cross builds also retain the target sysroot, SDL, speech runtime, and vcpkg outputs. Their stamps include the inputs that produced them; changing those inputs rebuilds the affected dependency.
- **CI restores.** CI restores Cargo state within the same compiler and target boundary and lets Cargo check the inputs. GitHub's macOS jobs save one snapshot per dependency and toolchain key, not per app commit.
- **C/C++ helpers and Odin outputs.** Native and cross builds cache these by input contents, compiler, target, and flags. Output manifests detect missing or corrupted files and reject dangling links.
- **SDK symlinks.** Dangling SDK symlinks contribute their link metadata to input keys; resolving or retargeting them invalidates the cache.
- **Odin objects.** Native Linux/OpenBSD and cross builds cache Odin objects separately from linking.
- **Packages.** Linux and Windows package caches cover bundled runtime libraries and archives; release downloads, signing, and update feeds still run when requested.

</details>

## Where the build checks run

The [GitHub build matrix](building.md#where-ci-builds-run) runs the native
C and Odin suite, the Linux and Windows package boots, and the OpenBSD
filesystem, helper, and startup tests.

<details>
<summary><b>Test signing keys and build cache keys</b></summary>

- **Signing keys.** The native runner signs temporary Git fixtures with a dedicated CI test key. The MDK patch-staging test generates its own temporary SSH signing key.
- **Bragi.** Bragi's math-helper object is cached per target, including its sources, font, toolchain, and build flags. Unrelated application edits do not rebuild it in a warm build tree.
- **SDK tracking.** Native SDL, Odin overlay, and Odin object keys track SDK headers and versions separately from shared-library contents. OpenBSD's boot-time library reordering invalidates linked executables, not these compiled outputs.

</details>

The GitHub `Release` workflow keeps one Flatpak cache warm-up running and one
waiting for the latest `master` push. Tagged builds, PR checks, and manual runs
are independent.

The ngit staging log reports `Cross phase` durations. On ARM64, subtract
`package` from `build_and_package` for the build time. `bundle` and `compress`
are part of `package`, and `app_boot` is part of `boot_smoke`. The workflow
reports artifact upload separately.

## Observability tokens come from CI secrets

Publishing workflows read `WN_METRICS_WRITE_TOKEN` and `WN_AUDIT_WRITE_TOKEN` from CI secrets. Configure both on GitHub and on trusted ngit/act publishing runners, not PR runners. Local builds without them contain no write tokens.

> [!CAUTION]
> Embedded tokens stay out of source and build logs, but they remain extractable from published binaries. Keep them write-only and narrowly scoped.

- **Embedding.** The build embeds a generated, mode-0600 `build/observability-tokens.toml`; CI removes that file before cache and artifact uploads.
- **Format.** Tokens must be printable ASCII without double quotes or backslashes.
- **Per-user overrides.** The optional per-user `observability.toml` overrides embedded settings; protect credentials in that file with mode 0600. On macOS it lives under `~/Library/Application Support/whitenoise/`; on Windows, under `%LOCALAPPDATA%/whitenoise/`.
- **Consent still applies.** Uploads still require the corresponding consent setting.

See [timing and observability configuration](timings.md).

## A flat architecture, rebuilt every frame

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

For an auto-fit grid, set `width = nendo.grow()`, `gap`, and `grid = {min_cell_width = 120, row_height = 80}` on a box. Declare the tiles as direct children without setting their width or height. Nendo uses the allocated inner width to choose the column count and size the tiles. The gap applies on both axes, and a partial row keeps the same column widths as the full rows.

For buttons or chips of different widths, set `direction = .Wrap_Row`. Nendo keeps children in declaration order and starts a new line when the next child would exceed the allocated inner width. `gap` applies between items and between lines. `align.x` aligns each line, and `align.y` aligns items within their line. Items do not grow to absorb gaps in a line. For items with percentage heights, give the container a fixed height, percentage height, or aspect ratio.

Use `nendo.percent(1, max = 480)` to fill the parent up to a cap. A row or column subtracts padding and any gaps on the sizing axis before applying the percentage. A wrapping row applies the percentage to its padded width before packing items with gaps. A floating box uses the full size of its anchor, so `nendo.percent(1)` makes a menu as wide as its trigger. Use `nendo.grow(max = 480)` to share leftover space with siblings.

Set `scroll = true` on a clip to retain a scroll position and accept wheel and drag input on its clipped axes. An ordinary clip still masks its children and applies a declared `offset`, but uses no scroll state.

Use `nendo.virtual_rows` for a run at the end of a top-aligned column. Nendo reserves the full scroll extent and returns the range to build, even if an outer column handles the scroll. A picker with a height cap that fits on the canvas keeps its own row window so keyboard navigation can reveal hidden rows. Give each row a stable ID and the declared row height. Put headers before the run. Nendo starts with the current declared heights and uses the previous layout to estimate adjustments from wrapping or alignment. The run closes at the end of its enclosing block.

```odin
if nendo.box(nendo.id("Results"))({
    width = nendo.grow(), height = nendo.fixed(240), direction = .Column,
    clip = {y = true, scroll = true},
}) {
    rows := nendo.virtual_rows(nendo.id("ResultRows"), len(labels), 32, gap = 4)
    for i in rows.first ..< rows.end {
        if nendo.box(nendo.id("Result", u32(i)))({width = nendo.grow(), height = nendo.fixed(32)}) {
            nendo.text(labels[i], {wrap = .None})
        }
    }
}
```

For unequal heights, pass cumulative heights instead of a count and a row height. For rows of height 32, 56, and 24, set `offsets := []f32{0, 32, 88, 112}` and call `nendo.virtual_rows(id, offsets, gap = 4)`. Build row `i` at height `offsets[i + 1] - offsets[i]`. Leave gaps out of `offsets`: nendo adds them between rows. Supply positive heights known before layout. Nendo searches the slice without copying it or measuring offscreen rows.

The timeline measures messages with their preceding markers and passes measured stretches to `nendo.virtual_rows`. Unmeasured rows, jump targets, and deletion animations stay outside those stretches so they can lay out even offscreen. The timeline still owns the reading anchor and pending sends. It passes one viewport of `overscan` in each direction. When a growing clip has not resolved its height, nendo uses the current canvas or the declared height cap rather than the previous viewport height.

The sidebar uses fixed rows for recent chats and one measured row per folder in the grouped view. An expanded folder contains its own fixed run and inherits the sidebar's scroll position. Keyboard cycling keeps the full order of expanded chats, including rows nendo did not build. The contacts list counts a letter heading as part of its first contact's row.

In short windows, `RailContent` scrolls both the chat list and its controls. If filtering puts that offset past the new end, `build_layout` clamps it and lays out the frame again before drawing. An offset still in range stays put.

Group Members uses fixed rows. The edited member and nickname field stay mounted between two virtual runs. The prompt wraps at the current card width before nendo chooses the lower run's rows.

Global search keeps the line breaks and cumulative heights for its result cards. Appending a page adds to the plan without measuring earlier pages again. Width, font, or timestamp changes rebuild the plan. Nendo uses the heights to mount only the cards near the viewport.
The loading message and progress bar stay above the scrollable filters and results.

The destination picker passes fixed-height rows to nendo for forwarding, theme sharing, and adding a peer to a group. It reads group IDs from the painted rows before rebuilding the list. A release acts only on the chat that was pressed, even if a live refresh changed its index.

The composer sticker grid mounts fixed-height rows near the viewport. Arrow keys scroll to the focused row by its position in the filtered grid, even when the row has not been built.
The sticker library and pack previews also mount fixed-height rows. The modal scrolls the rows together with the headings and pack controls.

The GIF picker passes cumulative tile heights to nendo for each column. The tallest column sets the scroll extent. Thumbnail requests still follow reading order and require a visible tile.

The emoji picker uses a category rail in wide windows and a bottom sheet in the single-pane layout. It opens on Custom emoji. Each installed pack has a category marked by one of its emoji, before the Unicode categories. Tab and Shift+Tab cycle categories. Search spans all categories, and clearing it restores the browse position. Nendo mounts only the grid rows near the viewport.
Cold artwork starts as placeholders. The emoji preview worker decodes visible pack icons and grid artwork, and the UI uploads a bounded batch of textures after presenting each frame.

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

## Design choices to know before you dig in

- **Optimistic rendering.** Sending, reacting, and unreacting apply locally and repaint immediately, then reconcile against Marmot's response. The UI never blocks on the network round-trip.
- **Two upload paths.** Chat attachments go through Marmot's encrypted MIP-04 path, readable only by group members. Profile pictures take the deliberately public Blossom path.
- **Data-driven themes.** Every color, metric, and capability flag comes from a `themes/*.toml` pack. The parser and editor share one token-to-field table in `app/theme.odin`; `app/state.odin` owns the live colors. A new component reads the globals; it never branches on which theme is active. Fullscreen media uses `media-backdrop` and `media-chip-bg` for its backdrop and floating header.
- **Antialiasing stays at the edge.** `app/sdlrl/` blends rounded fills and border arcs over a narrow band measured in output pixels. Straight edges and text keep their own drawing paths.
- **Standard math.** Motion, decoration and sound synthesis call `core:math` directly, evaluating `f64` phases before narrowing to `f32`. Checkmark strokes use `math.sqrt` with a minimum normalization length of 0.001.

## Sidecar themes are pinned to one commit

Sidecar palettes, title faces, and background artwork are pinned to `3aaebf9dc7beb9924c6e1f9bc060cecbc1be6f8f`. Run `bun scripts/render-sidecar-themes.ts` with Chromium installed to regenerate the embedded 1280×800 background images from the source CSS and SVGs.

- **Backgrounds crop, never stretch.** They keep their aspect ratio and fill the window, centered with excess cropped at the edges.
- **Some browser effects are dropped.** Browser animations and component-surface gradients are not reproduced, and the native text engine does not provide browser OpenType shaping.
- **Two font slots.** `font-title` selects a bundled display face separately from the body `font`.
- **Licences ship with the fonts.** Font licences, source hashes, and conversion details are in `assets/fonts/sidecar/` and installed with the fonts.

For the deeper details, see [`AGENTS.md`](../AGENTS.md).

<sub>[Back to the README](../README.md#further-reading)</sub>
