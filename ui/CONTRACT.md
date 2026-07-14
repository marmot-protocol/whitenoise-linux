# The View-Model Contract

This is the **interface between `src/main.rs` (the glue) and the Slint UI tree**. It
is the keystone of the theming engine: a *skin* (a drastically different rendering of
the app) is an interchangeable consumer of this contract. The whole engine works only
because of one rule.

## The Rule

> **A skin may only *consume* contract data (the structs + the root component's
> in-properties) and *invoke* the contract sinks (sink globals + the root component's
> callbacks). A skin may NEVER require new glue in `main.rs` or `backend.rs`.**

If a new theme/skin needs a value or an action that the contract doesn't already
expose, that is a contract change — it must be added here and wired in `main.rs`
*once*, for *all* skins — never as a one-off binding that only one skin uses.

This is what guarantees that adding a radically different-looking theme touches no
Rust glue and no other theme's code (ISC #1), and that the MarmotApp data flow keeps
working under every theme (ISC #3).

## The contract surface

### 1. Data structs (`ui/tokens.slint`)

The view-model. Rust constructs these directly and pushes them to the root. Skins read
them; skins never invent their own message/contact/chat model.

`ChatMessage`, `MessageLine`, `MessageRun`, `AlbumCell`, `Reaction` · `ChatMeta` ·
`Contact` · `GroupMember` · `AccountEntry` · `ArchivedChat` · `StagedAttachment` ·
`EditVersion` · `EmojiEntry` · `EffectChoice` · `AuditLogEntry`.
(Also `keys/types.slint`: `Signer`, `LinkedDevice`, `KeyPackageInfo`;
`modals/command-palette.slint`: `PaletteAction`.)

These structs are **frozen** with respect to skins: a skin must render whatever subset
of fields it wants and ignore the rest. It must not depend on a field being absent.

### 2. Sink globals (`ui/tokens.slint`)

Leaf-to-Rust channels that bypass callback threading. A skin invokes these directly:

- `Linkout.open(url)` — a tapped Markdown anchor.
- `ProfileSink.open(account_id_hex)` — a tapped avatar / sender name.
- `EmojiSheet.sprite` / `.tile` — the shared Twemoji texture (read-only).
- `EffectCatalog.choices` / `.selected` — message-effect catalog + pending selection.

### 3. View-model surface (`ui/shell/app-state.slint`)

The `AppState` global holds ~250 properties and ~155 callbacks that `main.rs`
binds once. This is the authoritative action/state surface. Skins route
user intent through these callbacks (e.g. `send-message`, `react-message`,
`request-reply`, `attachment-clicked`, `switch-account`) and read state from these
properties (e.g. `composer-draft`, `chats`, `messages`, `reply-target-*`).
Rust binds callbacks on the global (`ui.global::<AppState>().on_*`); properties
are also re-exposed on the `DarkMatterLinux` root via two-way aliases, so
property setters/getters stay on the window handle (`ui.set_*` / `ui.get_*`).
The root component itself is thin: the alias contract plus mounts of the shell
pieces (`shell/app-shell.slint`, `shell/modal-host.slint`,
`shell/login-gate.slint`, `shell/shell-timers.slint`), which read `AppState`
directly instead of having state forwarded per-mount.

### 4. Theme-selection properties (managed by the engine, set from `settings.rs`)

The only theme state Rust sets: `theme-id: int` and `accent-color: int`. The root
folds `theme-id` straight onto `Theme.id`, which selects a `ThemeColors`/`ThemeStyle`
pack and, transitively, the per-family skin ids. Rust's job is just "set
the active theme id + accent"; all resolution happens in Slint. The persisted string
mode name maps to the id through the `THEME_MODES` table in `state.rs` (index = id),
exactly as `ACCENTS` maps accent names to `accent-color`. There are no per-theme
boolean flags — the old `light-theme`/`retro-mode`/… props and the ternary that folded
them back into an id are gone.

## What a skin is allowed to do

- Read any contract struct field and render it however it likes (or not at all).
- Read any `Tokens.*` value (Phase B) — colors, type sizes, geometry, motion, flags.
- Invoke any sink global or root callback.
- Mount its own internal sub-components, animations, and layout freely.

## What a skin must NOT do

- Add a new property/callback that only it consumes (→ contract change instead).
- Reach into `MarmotApp`/`Backend` or assume anything about data production.
- Branch on theme *identity* (`theme-id == 3`, `Theme.id == N`) for styling. Style comes
  from `Tokens.*`; structure comes from being *selected* as the active skin. (A skin
  body is chosen by the dispatch slot — it never asks "am I the active theme?".)

## Layers built on this contract

```
Theme (id + accent)          ← Rust sets only this
  └─ Tokens (ThemeTokens)    ← L0: colors/type/geometry/motion/flags  (Phase B)
  └─ component skin slots    ← L1: dispatch to a skin body per family  (Phase C)
  └─ theme files (built + user)  ← ThemeColors/ThemeStyle packs loaded at startup
```

Every theme, built-in or user, is a `.toml` file loaded through one path
(`src/themes.rs`). The built-ins are embedded (`themes/<mode>.toml`, `include_str!`);
user themes are read from `$DM_HOME/themes/*.toml`. Rust builds the whole pack list and
fills `Theme.color-packs` / `style-packs`; the Slint side holds no theme data and just
renders whatever id it is handed. Runtime *skin bodies* (new Slint via
slint-interpreter) remain the not-built extension the contract still permits.

## How to add a theme

A theme is a `.toml` file, `[colors]` + `[style]`, optionally starting from a `base`.
A pure recolor overrides a handful of fields; a drastic theme additionally writes skin
bodies and bumps the selectors.

1. **Write the file** — a built-in goes in `themes/<mode>.toml`, a user theme in
   `$DM_HOME/themes/<mode>.toml` (same format). Name a `base` (another theme by mode)
   and override any `ThemeColors` field or `ThemeStyle` flag by its kebab-case name;
   everything unspecified inherits the base. A file with no `base` is a complete
   definition (the eight built-ins are authored this way).
2. **Skins (only if a `[style]` selector is non-zero)** — add the alternate body to
   that family's slot, guarded by its selector value, reading the contract structs:
    - messages → `ui/primitives/message-view.slint` (`if Theme.skin-message == N`)
    - chat list → `ui/primitives/chat-list-entry.slint` (`if Theme.skin-list == N`)
3. **Make a built-in selectable** — add the file to `BUILTIN_THEME_FILES` in
   `src/themes.rs`, append its mode name to `THEME_MODES` in `src/state.rs` (its
   position is the theme id), and add a matching `names`/`modes` entry in
   `ui/settings/theme-picker.slint`. A **user** theme needs none of this: it appears in
   the picker automatically. No Rust setter, no per-theme bool, no `changed` handler.

A file that fails to read or parse, or whose mode name collides, is logged and skipped,
matching how `settings.rs` swallows bad input.

The worked example is theme id 3, **Terminal** (terminal message lines + IRC chat
list + bracketed buttons): it required **zero** changes to message/list/button
*rendering logic in Rust* — only the theme-selection plumbing in step 4.
