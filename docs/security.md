<sub>REFERENCE&ensp;·&ensp;SECURITY</sub>

# Security model

### One password seals every secret, and nobody can reset it.

This page covers the vault, remote-signer accounts, the password check, and the helper processes that parse untrusted files. Every limit below is enforced in code.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/security-boundaries-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/security-boundaries-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/security-boundaries-dark.svg">
  <img alt="Three trust zones. The main process holds vault.db with every secret sealed, no OS keyring and no plaintext key; on OpenBSD it unveils only the data, settings and Downloads directories, pledges network, display and audio, and has no exec promise. Prestarted brokers launch only the frozen wn-* helper paths, or run curl, notifications and file dialogs under an inherited locked policy. Helpers wn-image, wn-pdf, wn-archive, wn-mesh, wn-fbx, wn-math, wn-nes and wn-font parse untrusted bytes with a 1 GiB memory limit, stdio pipes and no inherited environment." src="../assets/docs/security-boundaries-light.svg" width="880">
</picture>

## Where your keys live

There is no OS keyring and no plaintext key on disk. Every secret lives in a single vault file, `vault.db`, sealed with XChaCha20-Poly1305 under a key derived from your password with Argon2id.

- **The vault holds everything secret.** Your nsec, Marmot's per-account MLS keys, the decrypted media cache and the offline queue.
- **NIP-46 accounts keep the Nostr key remote.** Your Nostr private key stays in the remote signer and cannot be revealed or exported here. Client communication keys and device-local database keys stay in your encrypted vault.
- **Locking or restarting disconnects without logging out.** The transport closes; the session remains.
- **Signing out removes the saved session.** It also attempts remote logout, even if the signer is unavailable.
- **Each account reconnects independently.** An unavailable signer does not block local accounts.

> [!CAUTION]
> There is no recovery: lose the password and the data is gone. Export your account key separately; local-data backups do not include account keys or message history.

## How strong the password has to be

Creating or changing a vault password requires at least 40 bits of estimated strength. Use unrelated words or a password-manager password.

- **Diversity counts, patterns do not.** The Odin check counts character diversity and discounts repeated blocks and alphabet or keyboard sequences.
- **Common passwords are rejected whole.** Any password found in the [SecLists common-password file](https://github.com/danielmiessler/SecLists/blob/master/Passwords/Common-Credentials/10k-most-common.txt) fails, including case changes and simple letter substitutions.
- **Passphrases are not punished.** The check does not penalize individual words inside a passphrase or require particular character classes.
- **The form speaks in words.** It shows "Too easy to guess" or "Strong enough" rather than a numeric bit count. Correcting a weak password clears its strength error without another submission; unrelated errors remain until addressed.
- **Old passwords still work.** Existing passwords unlock regardless of strength.

<details>
<summary><b>What a 40-bit estimate does and does not promise</b></summary>

The corpus is staged at `vendor/common-passwords.txt`, pinned by `seclists-passwords-file` in `DEPS_PIN`, and embedded in the app. The check runs offline.

This heuristic does not measure entropy, model a full dictionary attack, or predict cracking time. It scores the first 100 Unicode characters to bound its work; the full password encrypts the vault. The `WN_VAULT_PW` harness bypasses this UI policy.

</details>

## What link previews fetch

Image previews stay in memory for the session. They check decoded format and dimensions, with a 16 MiB download limit and a 16-megapixel decode limit.

These checks do not sandbox image decoders or prevent requests to private-network hosts. Disable link previews if you do not want message links fetched automatically.

## The main process on OpenBSD

The main process locks `unveil()` and enters `pledge()` after opening the display, before starting attachment workers, the vault or Marmot.

| Access | What it covers |
| --- | --- |
| Kept | Networking, display/audio access |
| Read-write | Canonical Marmot data, app settings and Downloads directories |
| Read-only | Runtime resources |
| Temporary files, caches | Under the data directory |
| `exec` | No promise |

- **MDK stays inside the data tree.** It anchors directory creation inside the unveiled data tree and does not require opening `/`.
- **Brokers start processes instead.** A prestarted broker launches only the frozen `wn-*` helper paths, with fixed decoder arguments and an empty decoder environment. A separate broker runs curl, notifications and file dialogs with an inherited, locked policy.
- **Display credentials get a private home.** They are copied into a private runtime home, removed with its GTK state on normal shutdown. Forced termination can leave that private directory behind.
- **Some desktop actions change.** Links offer Copy link, storage offers Copy path instead of Open folder, and Launch at login is not offered.
- **Websocket fetching remains in-process.** Frame lengths are checked against the remaining response capacity without adding untrusted lengths, including across fragmented messages.

> [!WARNING]
> Network and desktop IPC remain available; this policy does not isolate X11 or D-Bus from the rest of your desktop.

<details>
<summary><b>Build changes made so OpenBSD would agree to all this</b></summary>

SQLCipher's C build uses OpenBSD's concealed allocators instead of unsupported `mlock` calls. Those allocations are excluded from core dumps and wiped on free. They can enter swap; swap confidentiality depends on the host's encryption policy.

Marmot's bundled OpenSSL symbols are hidden from dynamic libraries so they cannot replace system libcurl's incompatible LibreSSL symbols.

SDL is built from its pin without SysV shared memory and linked statically. GTK dialogs use Cairo rather than GL for the same restriction.

</details>

## Which helper parses what

Untrusted file formats are parsed in separate `wn-*` processes. The app sends input over private pipes and validates every reply. A missing helper or failed decode has no in-process fallback.

- **`wn-image`** decodes still images, including header probes for card, sticker and model-texture budgets.
- **`wn-archive`** lists and extracts archives.
- **`wn-pdf`** renders PDF pages, one at a time.
- **`wn-mesh`** parses STL, OBJ, GLB and G-code; **`wn-fbx`** parses FBX and evaluates animation.
- **`wn-math`** renders math blocks; **`wn-nes`** runs NES cartridges; **`wn-font`** reads fonts.

| Helper | Input | Output | Other |
| --- | --- | --- | --- |
| <code>wn&#8209;image</code> | 128 MiB | 256 MiB RGBA | 32,768 px per dimension |
| <code>wn&#8209;archive</code> | 128 MiB | 8 MiB listing; 64 MiB per entry | 65,536 headers; 2,000 regular files; 4,096-byte UTF-8 names |
| <code>wn&#8209;pdf</code> | 128 MiB | 64 MiB RGBA per reply | 10,000 pages; up to 32,768 px or the requested box |
| <code>wn&#8209;mesh</code> | 128 MiB | 512 MiB flat reply | Two million triangles or toolpath segments |
| <code>wn&#8209;fbx</code> | 128 MiB | 512 MiB flat reply | Two million triangles |
| <code>wn&#8209;math</code> | 4,096 bytes | 8 MiB straight RGBA | Up to 4,096 px |
| <code>wn&#8209;nes</code> | iNES header, ROM up to 8 MiB | 61,440 palette indices, up to 1,024 16-bit samples per frame | One helper per open game |
| <code>wn&#8209;font</code> | Open file on stdin | | FreeType starts after pledging |

Individual callers can impose smaller limits than the table.

<details>
<summary><b>Per-helper details, from pixels to cartridges</b></summary>

**`wn-image`.** The app sends compressed bytes and accepts only bounded RGBA pixels. The parent checks the response dimensions, byte count, end of stream and exit status, and kills the helper after ten seconds.

**`wn-archive`.** The parent validates every metadata record before publishing it. Neither side writes extracted files to disk. Links and libarchive filters requiring external programs are rejected.

**`wn-pdf`.** The app retains source bytes and requests one page at a time, including on navigation and fullscreen resize. Poppler and embedded-font parsing stay in the helper.

**`wn-mesh` and `wn-fbx`.** The app validates channel sizes, indices, finite values, strings and texture references before publishing a model. Embedded GLB images go through `wn-image`. Neither cgltf nor ufbx is linked into the main application. FBX triangles are not subdivided after import; animation poses the imported geometry without changing its topology.

G-code previews draw shaded, rounded toolpaths with depth testing and 2x supersampling. The slider selects the printed portion; orbit and zoom change the camera. Large previews show raster progress as toolpaths appear. Stroke width is a visual approximation, not a measured nozzle or extrusion width.

**`wn-math`.** It compiles Bragi's Odin C API alongside the helper and replays its drawing commands through a C++ Cairo shim. The main application does not link Bragi. The helper embeds Bragi's TeX Gyre DejaVu Math font. Invalid input, a failed helper or an exceeded budget leaves the source text visible instead of rendering it in-process.

**`wn-nes`.** It uses the same sequenced exchange as `wn-fbx`. The app sends the ROM once, then one controller byte per emulated frame. A malformed reply, a dead helper or a missed ten-second deadline closes the player.

</details>

## What every helper is held to

The image, archive, PDF, mesh, FBX, math and NES helpers share a 1 GiB memory limit, no inherited environment and only input, output and a null error stream.

| Helpers | CPU | Wall time | Session |
| --- | --- | --- | --- |
| Image, archive, PDF, mesh, math | Five CPU seconds | Ten seconds | Parent requires exact reply framing, end of stream and successful exit |
| FBX | No cumulative quota, so valid looping animations do not expire | Ten-second deadline per exchange, with an echoed sequence number | Static helpers close after loading; animated helpers close with the model |
| NES | Same session rules as FBX | Ten-second deadline | Closes with the player |

An invalid FBX pose leaves the last validated geometry intact and closes the helper.

## How OpenBSD confines each helper

| Helper | Policy |
| --- | --- |
| `wn-image`, `wn-archive`, `wn-mesh`, `wn-fbx`, `wn-math`, `wn-nes` | Lock `unveil()` with no filesystem paths and pledge `stdio` before reading input |
| `wn-font` | Locks `unveil()` with no paths and pledges `stdio` before initializing FreeType |
| `wn-pdf` | Initializes Fontconfig and the trusted bundled fonts, unveils the bundle, standard system font trees and Poppler resource directories read-only, then pledges `stdio rpath` before reading PDF bytes |

`wn-math` parses UTF-8 directly, without locale initialization or runtime font files. `wn-pdf` uses directory grants to avoid OpenBSD's limit on individual unveiled names.

## What the other platforms get

Failure has no in-process fallback. Linux requires `close_range` (kernel 5.9 or newer); descriptor or sandbox setup failure stops decoding.

Platforms other than OpenBSD use separate resource-limited processes, not an equivalent filesystem or syscall sandbox. Video parsing remains in the main process.

<details>
<summary><b>Why macOS counts memory Mach does not report</b></summary>

On macOS, the address-space limit adds the 1 GiB budget to all startup mappings, including Rosetta's reserved regions. Mach's basic task counter omits those regions even though the kernel includes them when checking the limit.

</details>

<sub>[Back to the README](../README.md#further-reading)</sub>
