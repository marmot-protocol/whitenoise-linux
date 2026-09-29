# AGENTS.md

Guidance for AI coding agents working in this repository.

White Noise Linux is an Odin + [clay](https://github.com/nicbarker/clay)
desktop client for [Marmot](https://github.com/marmot-protocol/mdk): MLS group
messaging over Nostr relays. It talks to the Marmot runtime through
`marmot-c`, the same C API the Android, iOS, and macOS apps use.

## Build & run

```sh
just build         # build build/{app,smoke}
just test          # build, then run the app package's tests
just dev           # rebuild and reload in-process, preserving the window
just run           # run against ~/.local/share/whitenoise
```

The recipes use the shell implementations under `scripts/`, also called
directly by CI and packaging.

`just build` stages everything the build needs and skips each step when its
output is already present, so only the first run is slow:

- `vendor/mdk` cloned at `mdk-commit` from `DEPS_PIN`, and its C bundle built by
  upstream's own `crates/marmot-c/c-bindings.sh` (this is the Rust part of the
  build, and the long pole on a cold checkout).
- `vendor/clay` and `vendor/ufbx` at their pinned commits; `ufbx.c`,
  `app/fbx_shim.c` and `app/fbx_helper.c` build the isolated `build/wn-fbx`
  parser and animation helper. `model-decoder/` builds `build/wn-mesh` for
  STL, OBJ, GLB and G-code. Neither parser library is linked into the UI.
- `vendor/emoji/{noto,twemoji,openmoji}`, the three 128x128 PNG sets the user
  picks between in Appearance: Noto from a sparse clone at
  `noto-emoji-commit`, Twemoji and OpenMoji rasterized from the SVGs in
  sha256-pinned archives with `rsvg-convert`.
  Staging renames every tile to lowercase hex codepoints joined by `-` with
  VS16 dropped. `vendor/emoji/openmoji-extras.tsv` lists the emoji only
  OpenMoji draws. Their licences land in `vendor/emoji-licenses`, and
  `vendor/emoji-catalog.tsv` comes from a pinned crates.io tarball.
- `vendor/common-passwords.txt` and its MIT license from SecLists at
  `seclists-commit` in `DEPS_PIN`. The Odin password-strength check embeds the
  corpus with `#load`; there is no runtime file lookup or network request.
- `vendor/microtex` at its pinned `openmath` commit with
  `patches/microtex-isolation.patch`, `patches/microtex-libcxx-includes.patch`
  and `patches/microtex-locale-fallback.patch` applied, built by CMake into
  `build/microtex/lib/libmicrotex.a`; `app/math_shim.cpp` is archived into
  `build/libwnmath.a` and linked only into `build/wn-math`. The helper embeds
  its font and exchanges bounded source/RGBA messages with `app/math.odin`.
  The UI does not link MicroTeX.
- An `ODIN_ROOT` overlay at `build/odin-root`, but **only** when the installed
  Odin is missing `vendor/stb/lib/stb_truetype.a` or `vendor/cgltf/lib/cgltf.a`
  (the Linux release tarball is; `sdlrl` needs stb truetype and image, the
  mesh helper needs cgltf), and always on OpenBSD. The overlay symlinks the
  real install and swaps in writable `vendor/stb` and `vendor/cgltf` copies it
  can run `build_stb.sh` and `build_cgltf.sh` in. On OpenBSD it also points
  those bindings at the built archives, which they name for Linux only.
  OpenBSD also builds the pinned SDL statically with `NO_SHARED_MEMORY`,
  points the SDL bindings at that archive, and patches Odin's executable
  probe to use `access(X_OK)` rather than a read-opening `O_EXEC` substitute,
  and its futex waits to treat `EAGAIN`, `EINTR` and `ECANCELED` as wakeups
  instead of panicking.

`DEPS_PIN` holds every third-party revision as `<name>-commit = <sha>`, one
per line. Bumping one is a one-line edit; `just build` re-checks out and
rebuilds on the next run.

OpenBSD runs only from a root-owned, non-group/other-writable installation
with protected ancestry. `scripts/openbsd-build.sh` stages one as root, then
runs capability tests and dummy/Xvfb package smokes as the invoking user.
For local runs, install with
`doas bash scripts/install-tree.sh /usr/local/whitenoise whitenoise` and run
`/usr/local/whitenoise/bin/whitenoise` as your normal user.
Direct unprivileged `build/app` runs are rejected.

The OpenBSD main process keeps networking, desktop access and the data,
settings and Downloads roots, but no `exec` promise. Start both brokers
before SDL or workers: `helper_broker.c` freezes helper paths/arguments and
`tool_broker.c` confines curl, notifications and dialogs. Link OpenBSD app
and package-private tests with `--wrap=execve` and
`--exclude-libs=libmarmot_c.a`; the latter keeps bundled OpenSSL symbols out of
system LibreSSL callers. Stop workers and SDL before the brokers, then remove
the private runtime home through `wn_main_sandbox_cleanup()`.
Cache kernel-version metadata before confinement too: Odin's BSD version
query uses `KERN_OSREVISION`, which pledge forbids.
`wn-math` initializes its fixed UTF-8 locale before locking an empty unveil
tree. Keep untrusted TeX parsing after that lock.

Odin has no incremental compilation, so a full app build is the unit of work
(~3s at `-o:minimal`, which is what `just dev` uses; release builds use
`-o:speed` for the STL orbit path). `just dev` builds the Odin app as a shared
library. `scripts/dev-host.c` owns the SDL window and renderer across reloads.
The app joins its workers, closes external handles, and releases its tracked heap before
unloading. UI state is rebuilt from saved settings and drafts. The Rust C
library stays loaded separately because its thread-local destructors retain
code. Only host or Rust-library changes require a new process. Unlock is kept
in an inherited anonymous memory file for the lifetime of `just dev`.

Run `just test-reload` after changing reload or shutdown behavior.
Workers must use `reload_allocator()` and be joined before the module returns.
Native file-dialog callbacks go through the host trampoline; it prevents an
unload until the callback has returned. `just stage` prepares dependencies
and helpers without compiling the release executables.

**Testing:** All tests live under `tests/`. `tests/odin.sh app` assembles a
temporary package with the app and `tests/app/*_test.odin`, preserving private
access. Use `tests/odin.sh app/sdlrl` for the SDL shim. Extra Odin test flags
can follow the package name. `just test` runs the same checks as CI. End-to-end
testing lives in a separate repo, `darkmatter-automated-testing` (the `dmvm`
QEMU harness and multi-VM scenarios). The `WN_TEST_*` env vars in `main.odin`
drive the app into a given state for screenshots and harness runs.

### Runtime env

| Variable | Effect |
| --- | --- |
| `WN_VAULT_PW` | Unlocks (or creates) the vault without the gate. For the harness. |
| `WN_SHOT` / `WN_SHOT_FRAME` | Capture `wn-odin-shot.png` after N frames, then exit. |
| `WN_TEST_*` | Drive a specific pane/action on boot; see `main.odin`. |
| `WN_DEBUG_INPUT` | Log input events. |
| `WN_TEST_LINK` | Raise the external-link guard on a URL at frame 12. |
| `WN_TEST_UPDATE_FEED` | Windows: point the Velopack updater at a local feed directory instead of GitHub releases (`updater.odin`). |
| `WN_WS_DEBUG` | Log the websocket handshake behind nevent cards (`ws_shim.c`). |

The data dir is the app's first argument, defaulting to
`~/.local/share/whitenoise`. It holds `vault.db`, the media cache, and
the offline queue. UI prefs are a separate JSON blob at
`$XDG_CONFIG_HOME/whitenoise/settings.json`.

### System dependencies

Odin (a recent nightly; CI pins one in `.github/workflows/ci.yml`), a C and
C++ compiler, CMake, a Rust toolchain for `marmot-c`, and `rsvg-convert`
(librsvg) to stage the emoji sets. Then SDL3 plus
`libarchive` (`archive.c`), `libmpv` (`mpv.odin`), `poppler-glib` + `glib` +
`gobject` + `fontconfig` (`pdf.c`), `cairo` (`pdf.c`, `math.odin`) and `libcurl`
(`ws_shim.c`, the nevent card fetch). Archive and PDF parsing run in the
packaged `wn-archive` and `wn-pdf` helpers, not in the UI process.

## Architecture

```
 SDL3  ←──  app/sdlrl/  ←──  app/renderer.odin  ←──  clay layout (app/*.odin)
                                                          │
                                                    app/state.odin  (Ui_State)
                                                          │
                                              app/workers.odin  (worker threads)
                                                          │
                                                   marmot/marmot.odin
                                                          │
                                            marmot-c  →  the Marmot runtime
```

- **`marmot/marmot.odin`** is the entire binding layer: a `foreign import` of
  the `marmot-c` staticlib plus Odin-shaped wrappers. Nothing else in the tree
  touches C.
- **`app/state.odin`** owns `Ui_State`, the single struct every pane reads and
  writes, plus the live theme color globals. There is no per-feature state
  container and no observer graph; a frame reads the struct and lays out from
  it.
- **`app/workers.odin`** keeps the UI thread off blocking Marmot calls: a live
  subscription worker feeds updates into a queue that the UI thread drains at
  a frame boundary, and each send runs on its own short-lived thread. Anything
  that can block belongs on a worker.
- **`app/sdlrl/`** is an SDL3 shim with a raylib-shaped API (window, input,
  clipboard, screenshots, IME, and a stb_truetype text engine with a CJK
  fallback stack). It exists because the app was written against raylib
  first, and raylib has no IME text input and no dynamic glyph baking.
  `renderer.odin` is clay's official renderer, retargeted onto it.
- **Panes are flat procs.** `chatpane.odin`, `panes.odin`, `settings_pages.odin`
  and friends each build their part of the clay tree directly from `Ui_State`.
  Follow that: no widget objects, no retained view tree.

### Themes

A theme is a `themes/*.toml` pack, `#load`ed at build time and parsed into a
`Theme_Pack` (`app/theme.odin`). `apply_theme` copies the active pack into the
color globals (`BG`, `TEXT`, `ACCENT`, …) plus the structural metrics and
capability flags (`R_SCALE`, `BORDER_W`, `SCANLINES`, `PAPER_DECOR`, …).

**Never branch on theme identity.** Read the globals, and when a component
needs something no token covers, add a field to `Theme_Pack` and set it in
every pack instead of special-casing a theme by name. Users can drop their own
packs in `<data-dir>/themes/*.toml`.

### Secret vault

Every secret lives in one password-encrypted file, `<data-dir>/vault.db`
(`app/vault.odin`): Argon2id (19 MiB / 2 / 1) over the password, then
XChaCha20-Poly1305 over a JSON key→value map, atomically renamed into place at
mode 0600. There is no OS keychain and no plaintext key on disk.

`vault_gate.odin` runs *before* the runtime boots, because Marmot takes the
secret store at client construction (`marmot_client_new_with_secret_store`):
account signing keys land under `account:<label>` in the same file. The media
cache and the offline queue seal with the vault's blob subkey.

A wrong password fails the Poly1305 tag. There is no recovery: "Use another
key" deletes the vault and everything sealed under it.

## Packaging

Releases are an AppImage and a Flatpak bundle, built by
`.github/workflows/release.yml` on a `v*` tag.
`.ngit/act/workflows/release-appimage.yml` builds the AppImage on every push
to master and hands it to ngit-ci for Blossom. The Flatpak manifest is
`packaging/flatpak/dev.ipf.whitenoise.yml`; it builds
the app inside the GNOME 50 SDK (freedesktop 25.08 base, which is what
ships webkit2gtk-4.1 for wn-webview; libmpv and poppler as modules,
network on during the build for cargo and the pinned clones), so it is a
self-published bundle, not a Flathub submission. `packaging/arch/PKGBUILD` is
a `-git` package against the system libraries, for `makepkg -si`.

All three install the same tree through `scripts/install-tree.sh
<prefix> <id>`. The app reads three things from disk at runtime, and
`res_dir` (`app/paths.odin`) resolves all of them relative to the running
binary, so that layout is a contract with it:

```
<prefix>/bin/whitenoise
<prefix>/share/whitenoise-linux/emoji/<set>/*.png  reaction and picker tiles
<prefix>/share/whitenoise-linux/emoji/<set>.bin    the picker's pixel pack
<prefix>/share/whitenoise-linux/emoji-catalog.tsv  the picker's search index
<prefix>/share/whitenoise-linux/fonts/*.ttf        the four bundled faces
```

Without that tree, `res_dir` falls back to `vendor/`, the path this was built
from, which is what a dev build wants and what a shipped binary must
never rely on. **Anything new the app reads from disk at runtime goes under
`res_dir()`, and gets copied there by `install-tree.sh`.** The data dir
defaults to `$XDG_DATA_HOME/whitenoise`, which is what lands the Flatpak's
data under `~/.var/app/<id>/data`.

Fonts are bundled because the stacks would otherwise depend on the host
distro's font layout, and the icon face in particular has no substitute (the
glyphs are Nerd Font private-use codepoints). Noto Sans CJK is the deliberate
exception: the `.ttc` is tens of megabytes, so Japanese falls back to the
system copy. The system paths behind the bundled ones in each stack cover
Arch, Debian/Ubuntu, and Fedora layouts.

Both workflows boot the finished AppImage headlessly (`SDL_VIDEODRIVER=dummy`
plus `WN_SHOT`) before publishing, which catches a library linuxdeploy failed
to bundle and a `res_dir` that stopped finding its data.

## i18n

User-visible strings go through `tr()` (`app/i18n.odin`), which looks the
English source string up in the gettext catalog for the active locale. The
catalogs in `lang/` (`it`, `de`, `ja`; `en` is the msgid source) are `#load`ed
at build time and parsed on boot and on locale switch. A missing entry falls
back to English, so an unextracted string is invisible until someone switches
locale.

`scripts/update-translations.sh` regenerates `lang/wnl-ui.pot` and merges it
into the catalogs. It is `xgettext -L C` over a copy of `app/*.odin` (Odin is
close enough to C for the lexer, once backtick raw strings are blanked out),
and it recognizes two markers:

- `tr("…")`: translated where it is written.
- `N_("…")`: gettext's noop marker, for a string held in a package-level
  table or returned from a copy proc, where some `tr(var)` downstream does the
  lookup. Mark at the literal, translate at the point of use.

UI helpers (`micro_button`, `row_labels`, `tooltip`, …) render the display
string they are given and never call `tr()` on a parameter, so every call
site marks its own copy: `micro_button("Id", tr("Save"))`. A ternary marks
each branch. A counted label picks its msgid at the call site:
`tr(n == 1 ? N_("%d reply") : N_("%d replies"))`. Never pass user text,
paths or symbols (`+`, `100%`, `HTML`) through `tr()`.

Banner messages go through `set_status(ui, text, .Error | .Info)`
(`shell.odin`). The kind is explicit because translated text can't be
inspected for words like "Couldn't".

Edit the `.po` files directly. The catalogs have no `msgctxt` (`po_parse`
ignores it and keys on msgid alone, first entry winning), and no plural forms.

### Copy voice

One voice for every user-visible string. English source rules:

- **Address the user as "you."** The user's things are "your" ("your relays",
  "your key package"). Descriptive copy never casts the user as "me"/"I". The
  only first-person strings are the established control labels where the user
  names themself as the object of their own click ("Delete for me", "I have an
  nsec"); don't coin new ones.
- **The app never speaks as "we."** No "we can't read them", no "we'll keep
  retrying". Say what is true of the system instead ("no one else can read
  it", "it will retry automatically").
- **Register: plain and calm.** State facts; no marketing flourish, no
  superlatives, no exclamation points.
- **Never use em dashes** in copy or docs. Use a period, comma, or parentheses.
- **Error copy** is "Couldn't ⟨what failed⟩. ⟨recovery⟩." with exactly this
  recovery ladder:
  - `Please try again.` is the default, for transient failures.
  - `Check your relay settings and try again.` only when relay configuration
    genuinely bears on the failure.
  - Input errors name the specific correction as a bare imperative
    ("Double-check it and try again.", "Wait a moment and try again.").
  - "Please" appears only in the bare default clause; an imperative that
    carries content drops it.
- **Casing ladder:** section eyebrows/captions are ALL CAPS ("DESKTOP
  ALERTS"); row titles, buttons, toggles, and menu items are sentence case
  ("Desktop notifications", "Send test"); sublabels and descriptions are full
  sentences ending with a period.

Translations keep one register per language across the whole catalog: `it`
informal *tu*, `de` informal *du*, `ja` polite です／ます form. Don't switch
register per string.

## Conventions

- **Visible feedback within two frames.** Every user action MUST produce a
  visible result within 0 to 2 frames at 60 fps (about 33 ms maximum). The work
  itself does not have to finish in that time. If it takes longer for any
  reason, the UI MUST show a visual indication within that same budget that
  work is happening, and keep its ongoing status visible until completion.
  Match the feedback to the UI element: the start of an animation can be
  enough; a spinner MUST include details of what is happening and a progress
  bar, not just spin without explanation. Show measured progress when known;
  use an explicitly indeterminate bar otherwise. Never invent percentages.
  More than two frames without visible feedback is S L O W. The user WILL
  notice, WILL call it lag, and WILL think White Noise sucks. This is a
  requirement, not optional polish.
- **Data first.** Design the layout of `Ui_State` and how a frame reads it
  before writing procs. Flat arrays and structs, not object graphs.
- **No speculative generality.** No interface with one implementation, no
  config for a constant, no helper that only forwards arguments. A layer earns
  its place at the second call site, not the first.
- **Deliberate corner cuts get a `ponytail:` comment** naming the ceiling and
  the upgrade path (see `sdlrl.odin`'s per-glyph textures for the shape).
- **MDK changes ship as patch files.** When a task needs a change in MDK,
  write it as `patches/mdk-<topic>.patch` against the `mdk-commit` pin and
  add it to `MDK_PATCHES` in `scripts/build.sh`. Never leave the change as
  uncommitted edits in `vendor/mdk`.
- Keep visibility tight: `@(private)` / `@(private = "file")` unless another
  file genuinely needs the symbol.
- Comments explain *what* a block does and *why*, with an example or an ASCII
  diagram where a system needs one. Don't annotate code you didn't touch.
- When committing work that closes ngit issues, add a `fixes nevent1…` trailer per issue (full bech32, one per line). Do not use GitHub `Fixes #N`.

## Commits

Install the hooks once per clone: `scripts/install-hooks.sh`. The pre-commit
hook formats staged Odin files when `odinfmt` is installed and C sources and
headers when `clang-format` is installed, normalizes and validates staged
gettext catalogs, and keeps
`.github/workflows/pr-precommit.yml` byte-identical to its canonical copy at
`.ngit/act/workflows/pr-precommit.yml` (ngit is the primary forge; GitHub
cannot run workflows through symlinks).

Commit messages: imperative subject under 50 characters, capitalized, no
trailing period, a blank line, then a body wrapped at 72 explaining what and
why rather than how.
