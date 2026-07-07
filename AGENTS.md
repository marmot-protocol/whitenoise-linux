# AGENTS.md

Guidance for AI coding agents working in this repository.

## Build & run

The workspace has two crates: the root binary (`darkmatter-linux`, the `default-run` target) and `wnl-ui`, a build-time-isolation lib crate.

- **The two-crate split exists to keep rebuilds fast.** `wnl-ui/build.rs` compiles the Slint UI tree (`ui/dark-matter-linux.slint`) into a ~580k-line generated module (`slint::include_modules!()` in `wnl-ui/src/lib.rs`), bundles the gettext catalogs from `lang/`, and composes the Twemoji sprite sheet. Because all of that lives in `wnl-ui`, editing Rust in `src/` rebuilds only the root crate (~2s); editing `.slint` or `lang/` files rebuilds `wnl-ui` too (tens of seconds to minutes as the tree grows). The first build is slow (marmot deps plus sprite composition).
- **Live-reload for UI iteration (automatic in dev).** Any non-release build (`cargo build`/`cargo run`, no flags) skips the `.slint`-recompile loop: `wnl-ui/build.rs` sets `SLINT_LIVE_PREVIEW=1` for non-release profiles, so Slint's `live-preview` codegen emits an interpreter-backed shim instead of the ~580k-line module. The shim exposes the **same** strongly-typed generated API (`DarkMatterLinux`, `ChatMessage`, callbacks, globals — so `src/` glue is unchanged), but loads `ui/*.slint` from disk at runtime and hot-reloads on save. `cargo build --release` keeps the (default-on) `live-reload` feature but compiles the self-contained, statically checked UI into the binary; add `--no-default-features` for a release that also omits the interpreter crate. Because a dev binary reads `ui/*.slint` from its build-time absolute path, set **`DM_COMPILED_UI=1`** to force the compiled path in a debug build — required for anything that runs the binary away from this checkout (e.g. the `darkmatter-automated-testing` VM harness). Other caveats in shim mode: bundled `lang/` translations aren't applied (the interpreter loads the raw `.slint`), and a `.slint` edit still triggers a quick `wnl-ui` rebuild of the tiny shim on the next `cargo run` (hot-reload avoids even that while the app is running).
- **Testing:** no unit-test suite exists (`cargo test` is a no-op), so verify changes by running the app. End-to-end/automated testing lives in a separate repo, `darkmatter-automated-testing`: the `dmvm` QEMU harness, the `dm-ctl` headless control daemon, and the multi-VM scenarios. That repo builds this checkout (located via `$DARKMATTER_LINUX_DIR`, default sibling `../darkmatter-linux`) and stages its `dm-ctl`/`bootbench` sources into `src/bin/`, which is why `src/bin/` is gitignored here and `cargo run --bin bootbench` only works after staging.
- **Logging:** `tracing-subscriber` is installed in `main` (writes to stderr). Filter via `RUST_LOG`; default is `info`.
- **Translations:** after adding/changing `@tr("…")` strings in `.slint` files, run `scripts/update-translations.sh` (needs `cargo install slint-tr-extractor` and gettext's `msgmerge`) to regenerate `lang/wnl-ui.pot` and merge into the `it`/`de`/`ja` catalogs. The gettext domain is `wnl-ui` because slint-build hardwires it to the name of the crate that compiles the UI. Edit the `.po` files directly. See [i18n](#i18n).

### Dependencies (marmot + whitenoise)

`Cargo.toml` pulls `marmot-app`, `marmot-account`, and `cgka-traits` from the public `darkmatter` repo over https (`git = "https://github.com/marmot-protocol/darkmatter.git", branch = "master"`), so cargo fetches them anonymously, with no ssh key or deploy secret. `.cargo/config.toml` sets `net.git-fetch-with-cli` to fetch through the git CLI (honouring local proxy/credential config). `Cargo.lock` pins the exact rev; bump with `cargo update -p marmot-app -p marmot-account -p cgka-traits`.

`whitenoise-markdown` (the chat-body markdown parser) is a separate git dependency on the public `whitenoise-rs` repo.

To develop against a local darkmatter checkout, **don't edit `Cargo.toml`**; add a patch to `.cargo/config.toml` (or `[patch]` locally):

```toml
[patch."https://github.com/marmot-protocol/darkmatter.git"]
marmot-app     = { path = "../darkmatter/crates/marmot-app" }
marmot-account = { path = "../darkmatter/crates/marmot-account" }
cgka-traits    = { path = "../darkmatter/crates/traits" }
```

Note: changes in darkmatter must be **pushed to master** before a plain build here picks them up.

### Runtime env vars

- `DM_HOME`: override data dir (default: `directories::ProjectDirs` for `"darkmatter"`). Holds the encrypted vault (`vault.db`), the encrypted media cache (`media-cache/`), and an optional `observability.toml` override.
- `WAYLAND_DISPLAY` / `DISPLAY`: clipboard chooses `wl-copy` on Wayland and falls back to `xclip` / `xsel` / `arboard` on X11 (Linux and FreeBSD). With neither set, only the `arboard` fallback runs. On macOS these are ignored: the clipboard goes through `pbcopy`, with `arboard` as fallback.

(`DM_SECRET_STORE` is gone; there is no more libsecret/pass/plaintext path. See [Secret vault](#secret-vault).)

## Architecture

### Layering

```
slint UI (ui/*.slint)  ←──  wnl-ui (generated Slint module)  ←──  src/main.rs + UI-glue modules  ──→  Backend (src/backend.rs)  ──→  MarmotApp (sibling crate) + tokio runtime
```

- **`wnl-ui`** owns `slint::include_modules!()` and re-exports all generated Slint types; `main.rs` pulls them in with `use wnl_ui::*;`. UI structs (`ChatMessage`, `ChatMeta`, `GroupMember`, `Contact`, `ArchivedChat`, `Reaction`) live in `ui/tokens.slint` and Rust constructs them directly. The split is purely for rebuild speed, so **don't put app logic in `wnl-ui`.**
- **Hard rule: no Rust source file may exceed 2000 lines.** Keeps files readable and rebuilds fast. The pre-commit hook (`.githooks/pre-commit`) enforces it on staged `*.rs`; split before you cross it.
- **The UI glue is one logical layer split across files purely to stay under that limit.** `src/main.rs` builds the window, the shared handles (bundled in `Cx`), and the cross-section closures (bundled in `Handlers`), then calls the `wire_*` functions. The callback sections live under `src/wiring/` — `wiring/mod.rs` (the `Cx`/`Handlers`/type-alias definitions), `wiring/panes.rs` (account/settings/keys), `wiring/backup.rs` (backup create/import + storage), `wiring/chats.rs` (new-chat/chat-select/chat-request/archive), `wiring/nav.rs` (page nav + command palette), `wiring/contacts.rs` (contact select/add/nicknames/QR/key-package), `wiring/groups.rs` (group admin: members/admins/rename/image), `wiring/messaging.rs` (send/edit/attach/media), `wiring/forward.rs` (forward picker), and `wiring/extra.rs` (reactions/delete/pickers/profile/offline); each `wire_*` takes `(&ui, &cx, &h)` and reproduces its local bindings with `let Cx { .. } = cx.clone();`. The pure row/model/render helpers live in `chatmodel.rs`, `chatlist.rs`, `chrome.rs`, `media.rs`, `render.rs`, the system-clipboard stack in `clipboard.rs`, the network-relay UI plumbing in `relays.rs`, and the optimistic-overlay state in `state.rs`. All of these share the crate-root prelude (`pub(crate) use` re-exports in `main.rs`) via `use crate::*;`, so the data flow still reads flat — treat them as one file that happens to be chaptered.
- **`Backend` (`src/backend.rs` + `src/backend/groups.rs`)** wraps `MarmotApp` plus its own multi-thread tokio runtime. `groups.rs` is a child module holding the second half of `impl Backend` (groups/keys/admin/telemetry/watchers) plus the media-validation free fns, so it can reach `Backend`'s private fields. It exposes `tokio_handle()` so callers can `spawn` ad-hoc background work (HTTP fetches, etc.) on that same runtime; one runtime serves all background work. Platform-specific path handling lives here; the platform-specific clipboard ladder lives in `src/clipboard.rs`.
- **Support modules are thin and single-purpose** and do not own state (the UI does): `vault.rs` (password-encrypted secret vault), `settings.rs` (JSON UI prefs), `blossom.rs` (public Blossom uploads), `media_cache.rs` (encrypted attachment cache), `observability.rs` (telemetry/audit endpoint config).

### Secret vault

There is no OS keyring, no `pass`, no plaintext key on disk. All secrets (the user's nsec plus marmot's per-account keys) live in one password-encrypted file, `$DM_HOME/vault.db` (`vault.rs`).

- **Format:** a serde envelope `{ version, kdf{argon2id salt + cost params}, nonce, ciphertext }`. The ciphertext is `XChaCha20-Poly1305(serde_json(BTreeMap<String,String>))` keyed by `Argon2id(password, salt)`. Every mutation re-seals the whole map under a fresh nonce and atomically renames into place (mode `0600`). The derived key is held in `Zeroizing` and wiped on drop.
- **Unlock vs create:** on startup, if `vault.db` exists the login screen opens in mode 3 (Unlock, where the user enters the password). Otherwise it's first-run: the user pastes/generates an nsec **and** sets a password (with confirm), creating the vault. A wrong password fails the Poly1305 tag, returning `VaultError::WrongPassword`. There is no recovery; the unlock screen offers "Use another key", which deletes the vault and restarts from the nsec.
- **marmot integration:** `VaultSecretStore` implements marmot's `AccountSecretStore` and is passed to `AccountHome::open_with_secret_store` in `Backend::boot`, so marmot's account secrets land in the *same* vault file (under `account:<label>` keys). The same `Arc<Mutex<Vault>>` unlocked on the login screen is threaded into boot.
- **Blob sealing:** `Vault::seal_blob` / `open_blob` encrypt arbitrary byte blobs under a vault subkey, used by the media cache so nothing decrypted ever hits disk in plaintext.

### Media: two upload paths + encrypted cache

- **Chat attachments** go through marmot's encrypted MIP-04 path (sealed blobs only group members can read; content type is always `application/octet-stream`). The UI resolves a record's NIP-92 `imeta` tag to download/decrypt on tap. Encrypted downloads retry marmot redirect failures by resolving Blossom redirects in `src/backend.rs`, validating each hop before retrying.
- **Profile pictures** are the opposite (publicly fetchable), so `blossom.rs` is a deliberately simple unencrypted path: BUD-01/BUD-02 `PUT /upload` with a signed kind-24242 auth event, returning the public URL that goes into the kind-0 `picture` field. Default server: `https://blossom.primal.net`.
- **`media_cache.rs`** is an encrypted-at-rest disk cache for *decrypted* attachment bytes at `$DM_HOME/media-cache/<blob_hash>.bin`, sealed with the vault's media-cache subkey and content-addressed by the Blossom blob hash. Best-effort: any IO/crypto failure degrades to a miss, triggering a fresh download+decrypt. Cleared entirely on vault reset (old-key entries are unreadable anyway). It stores original compressed bytes (PNG/JPEG), not decoded RGBA.

### Observability (telemetry + audit logs)

`observability.toml` at the repo root holds OTLP-metrics and Goggles-audit endpoints/tokens (deliberately not secret). It's embedded into the binary at build time (`include_str!`); a copy at `$DM_HOME/observability.toml` overrides it at runtime without a rebuild. `Backend::configure_observability` feeds these to marmot's relay-telemetry exporter and audit-log tracker at boot, but **sending only happens when the user enables the Telemetry / Audit-logs toggles in Settings (Advanced section)**. Those enabled-flags live in marmot's settings store (not `settings.rs`), via `telemetry_enabled()` / `audit_logs_enabled()` and their setters; the audit toggle takes effect on next restart.

### Settings (`settings.rs`)

UI prefs as a tiny JSON blob in XDG config: `debug_enabled`, `locale` (`en`/`it`/`de`/`ja`), `theme` (`dark`/`light`/`retro`/`terminal`/`crayon`/`synthwave`/`chalkboard`), `accent_color` (`mint`/`ocean`/`berry`/`coral`/`lavender`), `outgoing_on_right`, and `nicknames` (private per-contact nicknames keyed by account hex, local-only and never published to relays). All load/save failures are swallowed; defaults keep the app booting.

### Optimistic overlay model

All UI mutations (send, react, unreact) go through a `PendingState` overlay (`state.rs`; the row builders below live in `chatmodel.rs`):

1. The mutation is applied locally to the overlay, and the UI rebuilds the affected message rows from `backend snapshot ∪ overlay`.
2. The real op dispatches on the tokio runtime.
3. On ack, the overlay entry is dropped, and the next rebuild pulls the confirmed record from the snapshot.
4. On failure, the overlay entry is marked failed (red bubble, tap to retry).

Three entry points share the same model-to-row pipeline; **changing the avatar/text/etc. for a row means touching all three:**

- `chat_message_from_with_reactions(record, records_by_id, my_id, my_label, reactions)`: confirmed rows (`records_by_id` is a prebuilt message-id-to-record map for reply-preview lookups).
- `pending_chat_message(pending, my_id, my_label)`: pending/failed rows.
- `build_one_message_row(...)` / `rebuild_chat_messages(...)` / `refresh_one_message_row(...)`: orchestrators that call the two above.

`my_label` is the user's display name (`backend.account_display_name(&my_id)`, falling back to the account hex). It drives the outgoing-bubble avatar palette/initials so the user's own messages match the left-rail avatar.

Group chats add a member-list panel backed by `Backend::group_members`, `GroupMember` Slint rows, and `push_group_members_to_ui`.

### Markdown rendering

Chat bodies are parsed with `whitenoise-markdown` (the same CommonMark + GFM + nostr-entity parser whitenoise-rs uses) into a `Document`, then flattened in `render.rs` into the bubble's line/run model: each `MessageLine` is one visual line, each `MessageRun` an inline text/emoji cell with resolved styling; block context (heading scale, list/blockquote indent, code plates, rules) rides on the line. Line wrapping is Rust-side and greedy: character widths are *estimated* (`MD_CHAR_W`, `MD_EMOJI_W`, fractions of font-size) only to pick break points, and Slint draws with real metrics.

### Avatar pipeline

Two layers:

1. **Deterministic fallback:** `avatar_for(key: &str) -> (Color, Color, String)` hashes any string into a gradient + initials. Used for everyone (self, peers, group rows); always renders something.
2. **Profile pictures:** `fetch_profile_picture` / `fetch_picture_pixels` GET the URL via `reqwest`, decode with `image`, and cache as raw RGBA (`PicturePixels { w, h, rgba }`) in a process-wide `OnceLock<Mutex<HashMap<...>>>`.

**Critical constraint:** `slint::Image` holds a `VRc<...>` that is `!Send`, so you cannot move an `Image` from a `tokio::spawn` into `slint::invoke_from_event_loop`. The cache stores `PicturePixels` (which is `Send`); the `slint::Image` is reconstructed on the UI thread via `slint::SharedPixelBuffer::clone_from_slice` + `Image::from_rgba8` inside the event-loop closure.

`Avatar` (`ui/primitives/avatar.slint`) takes `picture: image` + `has-picture: bool`. When `has-picture` is false it renders initials over the gradient; when true it renders the `Image` with `image-fit: cover` and `clip: true` (the circular border-radius does the clip).

### Build-time sprite sheet

`wnl-ui/build.rs` walks all `emojis::iter()`, looks up each in `twemoji-assets`, and composes a single 44-column, 72px-tile sheet. Runtime renders the picker with one shared texture and per-cell `source-clip`, never decoding individual PNGs at runtime. The emitted `EMOJI_POSITIONS` table and the sprite PNG bytes are included in `wnl-ui/src/lib.rs` (`emoji_sprite_map` module, `EMOJI_SPRITE_PNG`) and re-exported to `main.rs`. The build reuses `twemoji_sprite.png` and `emoji_sprite_map.rs` from `OUT_DIR` when both exist, so sprite generation only runs when an output is missing.

### i18n

All user-visible Slint strings use `@tr("…")`. `wnl-ui/build.rs` bundles the gettext catalogs from `lang/` (`slint_build::CompilerConfiguration::new().with_bundled_translations("../lang")`); locales are `en` (source), `it`, `de`, `ja`. Runtime switching happens via `slint::select_bundled_translation` (`apply_locale` in `main.rs`), driven by `Settings.locale` and the language-picker modal. Catalog maintenance is `scripts/update-translations.sh` (see [Build & run](#build--run)).

### Slint conventions specific to this repo

- **Data-driven themes** (`Theme` global in `ui/tokens.slint`; see `ui/CONTRACT.md` for the engine's layering and rules): a theme is a pair of registry entries indexed by `Theme.id` (0=dark, 1=light, 2=retro, 3=terminal, 4=sketch/`crayon`, 5=synthwave, 6=chalkboard) — a `ThemeColors` pack (every color the UI reads, exposed as `Palette.*`) and a `ThemeStyle` pack (capability flags such as `hard-shadow`, `bevel`, `soft-decor`, `outline-surfaces`, `pixel-metrics`, plus per-family skin selectors). **Never branch on theme identity for styling** — `Theme.retro` / `Theme.light` are back-compat shims and `Theme.id == N` is equally banned. Branch on the capability flags, read colors from `Palette`, and when a component needs a themed value no token covers, add a `ThemeColors` field or `ThemeStyle` flag and set it in every pack instead of writing an inline identity ternary.
- **Accent system:** `Theme.accent` is an index (0..4 = mint/ocean/berry/coral/lavender) into the active pack's `accent-*` tables. Read the resolved colors from `Palette.mint` / `mint-hi` / `mint-dim` / `mint-glow` / `mint-surface`, never hardcode an accent.
- **Font sizes** go through the theme helpers: `font-size: Theme.fs(12px, 14px)` declares the modern and pixel-grid sizes and lets the active theme's `pixel-metrics` flag pick one (`Theme.fsr(…)` is the unscaled variant). Never write a bare `font-size: 12px`; older `12px * Theme.fs-scale` sites remain, but new code uses the helpers.
- **Border radius** is scaled by `Theme.r-scale` so retro mode can zero it.
- **Avatars** on the left-rail / outgoing-bubble / profile-page / members-list all read from a common `my-av-*` set of root properties on `DarkMatterLinux`, pushed from Rust on profile load. Don't reintroduce hardcoded initials/colors at the leaf; wire the property through.

## Learned user preferences

- Avoid adding Python project tooling or helper scripts; prefer Rust or the existing shell/toolchain workflows.
- For i18n work, keep scope to Slint `@tr()` bundled catalogs unless explicitly asked; do not propose Rust-side string translation.
- When implementing from an attached plan, do not edit the plan file itself; update the already-created todos instead of recreating them.
