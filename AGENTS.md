# AGENTS.md

Guidance for AI coding agents working in this repository.

White Noise Linux is an Odin + [clay](https://github.com/nicbarker/clay)
desktop client for [Marmot](https://github.com/marmot-protocol/mdk): MLS group
messaging over Nostr relays. It talks to the Marmot runtime through
`marmot-c`, the same C API the Android, iOS, and macOS apps use.

`PORT.md` records what is built, what is still outstanding, and the clay/SDL
quirks worth knowing before you debug a layout.

## Build & run

```sh
./build.sh          # build build/{app,smoke}
./build.sh test     # build, then run the app package's tests
./dev.sh            # watch app/ and marmot/, rebuild + restart on save
build/app           # run against ~/.local/share/whitenoise
```

`build.sh` stages everything the build needs and skips each step when its
output is already present, so only the first run is slow:

- `vendor/mdk` cloned at `mdk-commit` from `DEPS_PIN`, and its C bundle built by
  upstream's own `crates/marmot-c/c-bindings.sh` (this is the Rust part of the
  build, and the long pole on a cold checkout).
- `vendor/clay` and `vendor/ufbx` at their pinned commits; `ufbx.c` plus
  `app/fbx_shim.c` are archived into `build/libwnfbx.a`.
- `vendor/twemoji` (the 72x72 PNG set) and `vendor/emoji-catalog.tsv`, both
  pulled from pinned crates.io tarballs.
- An `ODIN_ROOT` overlay at `build/odin-root`, but **only** when the installed
  Odin is missing `vendor/stb/lib/stb_truetype.a` (the Linux release tarball
  and the Arch package both are; `sdlrl` needs truetype and image). The
  overlay symlinks the real install and swaps in a writable `vendor/stb` copy
  it can run `build_stb.sh` in.

`DEPS_PIN` holds every third-party revision as `<name>-commit = <sha>`, one
per line. Bumping one is a one-line edit; `build.sh` re-checks out and
rebuilds on the next run.

Odin has no incremental compilation, so a full app build is the unit of work
(~3s at `-o:minimal`, which is what `dev.sh` uses; release builds use
`-o:speed` for the STL orbit path). There is no UI markup to hot-reload: the
layout is Odin code, so `dev.sh` watches, rebuilds, and restarts.

**Testing:** `odin test app` runs the `@(test)` procs that live beside the
code they cover (`*_test.odin`). CI runs exactly `build.sh test`. End-to-end
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
| `WN_WS_DEBUG` | Log the websocket handshake behind nevent cards (`ws_shim.c`). |

The data dir is the app's first argument, defaulting to
`~/.local/share/whitenoise`. It holds `vault.db`, the media cache, and
the offline queue. UI prefs are a separate JSON blob at
`$XDG_CONFIG_HOME/whitenoise/settings.json`.

### System dependencies

Odin (a recent nightly; CI pins one in `.github/workflows/ci.yml`), a C
compiler, and a Rust toolchain for `marmot-c`. Then SDL3 plus the libraries
behind the `foreign import "system:…"` lines in `app/`: `libarchive`
(`archive.odin`), `libmpv` (`mpv.odin`), `poppler-glib` + `glib` + `gobject` +
`cairo` (`pdf.odin`), `libcurl` (`ws_shim.c`, the nevent card fetch).

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

Releases are AppImages, built by `.github/workflows/release.yml` on a `v*`
tag. `.ngit/act/workflows/release-appimage.yml` builds the same thing on every
push to master and hands it to ngit-ci for Blossom.

The app reads three things from disk at runtime, and `res_dir`
(`app/paths.odin`) resolves all of them relative to the running binary, so the
AppDir layout is a contract with it:

```
usr/bin/whitenoise-linux
usr/share/whitenoise-linux/twemoji/*.png      reaction and picker tiles
usr/share/whitenoise-linux/emoji-catalog.tsv  the picker's search index
usr/share/whitenoise-linux/fonts/*.ttf        the four bundled faces
```

Without that tree, `res_dir` falls back to `vendor/`, the path this was built
from, which is what a dev build wants and what a shipped binary must
never rely on. **Anything new the app reads from disk at runtime goes under
`res_dir()`, and gets copied into the AppDir by both workflows.**

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
and it recognizes three shapes:

- `tr("…")`: translated where it is written.
- `N_("…")`: gettext's noop marker, for a string held in a package-level
  table or returned from a copy proc, where some `tr(var)` downstream does the
  lookup. Mark at the literal, translate at the point of use.
- `helper("…", …)`: a proc that calls `tr()` on one of its parameters, so the
  literal at the call site is the msgid. These are listed by name and argument
  position in the script's `HELPERS` array.

**Adding a proc that `tr()`s a parameter means adding it to `HELPERS`,** or
its call sites go unextracted and stay English. Same for a new table of
copy: mark each literal `N_(…)`.

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

- **Data first.** Design the layout of `Ui_State` and how a frame reads it
  before writing procs. Flat arrays and structs, not object graphs.
- **No speculative generality.** No interface with one implementation, no
  config for a constant, no helper that only forwards arguments. A layer earns
  its place at the second call site, not the first.
- **Deliberate corner cuts get a `ponytail:` comment** naming the ceiling and
  the upgrade path (see `sdlrl.odin`'s per-glyph textures for the shape).
- Keep visibility tight: `@(private)` / `@(private = "file")` unless another
  file genuinely needs the symbol.
- Comments explain *what* a block does and *why*, with an example or an ASCII
  diagram where a system needs one. Don't annotate code you didn't touch.
- When committing work that closes ngit issues, add a `fixes nevent1…` trailer per issue (full bech32, one per line). Do not use GitHub `Fixes #N`.

## Commits

Install the hooks once per clone: `scripts/install-hooks.sh`. The pre-commit
hook normalizes and validates staged gettext catalogs, and keeps
`.github/workflows/pr-precommit.yml` byte-identical to its canonical copy at
`.ngit/act/workflows/pr-precommit.yml` (ngit is the primary forge; GitHub
cannot run workflows through symlinks).

Commit messages: imperative subject under 50 characters, capitalized, no
trailing period, a blank line, then a body wrapped at 72 explaining what and
why rather than how.
