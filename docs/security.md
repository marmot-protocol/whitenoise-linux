# Security model

There is no OS keyring and no plaintext key on disk. Every secret (your nsec, Marmot's per-account MLS keys, the decrypted media cache, the offline queue) lives in a single vault file (`vault.db`) sealed with XChaCha20-Poly1305 under a key derived from your password with Argon2id.

For NIP-46 accounts, your Nostr private key stays in the remote signer and cannot
be revealed or exported here. Client communication keys and device-local database
keys stay in your encrypted vault. Locking or restarting disconnects the transport
without logging out. Signing out removes the saved session and attempts remote
logout even if the signer is unavailable. Each account reconnects independently;
an unavailable signer does not block local accounts.

The flip side is that **there is no recovery**: lose the password and the data is gone. Export your account key separately; local-data backups do not include account keys or message history.

Creating or changing a vault password requires at least 40 bits of estimated
strength. The Odin check counts character diversity and discounts repeated
blocks and alphabet or keyboard sequences. It rejects whole passwords found
in the [SecLists common-password file](https://github.com/danielmiessler/SecLists/blob/master/Passwords/Common-Credentials/10k-most-common.txt),
including case changes and simple letter substitutions. It does not penalize
individual words inside a passphrase or require particular character classes.
Use unrelated words or a password-manager password.

The password form shows "Too easy to guess" or "Strong enough" rather than a
numeric bit count. Correcting a weak password clears its strength error without
requiring another submission; unrelated errors remain until addressed.

The corpus is staged at `vendor/common-passwords.txt`, pinned by
`seclists-passwords-file` in `DEPS_PIN`, and embedded in the app. The check
runs offline.

This heuristic does not measure entropy, model a full dictionary attack, or
predict cracking time. It scores the first 100 Unicode characters to bound
its work; the full password encrypts the vault. Existing passwords still unlock
regardless of strength. The `WN_VAULT_PW` harness bypasses this UI policy.

Image previews stay in memory for the session. They check decoded format
and dimensions, with a 16 MiB download limit and a 16-megapixel decode limit.
These checks do not sandbox image decoders or prevent requests to
private-network hosts. Disable link previews if you do not want message
links fetched automatically.

## Helper processes and OpenBSD confinement

The main process locks `unveil()` and enters `pledge()` after opening the
display, before starting attachment workers, the vault or Marmot. It keeps
networking, display/audio access and read-write access to the canonical
Marmot data, app settings and Downloads directories. Runtime resources are
read-only. Temporary files and caches stay under the data directory.
MDK anchors directory creation inside the unveiled data
tree; it does not require opening `/`.

SQLCipher's C build uses OpenBSD's concealed allocators instead of unsupported
`mlock` calls. Those allocations are excluded from core dumps and wiped on
free. They can enter swap; swap confidentiality depends on the host's
encryption policy. Marmot's bundled OpenSSL symbols are hidden from dynamic
libraries so they cannot replace system libcurl's incompatible LibreSSL symbols.

The main process has no `exec` promise. A prestarted broker launches only
the frozen `wn-*` helper paths, with fixed decoder arguments and an empty
decoder environment. A separate broker runs curl, notifications and file
dialogs with an inherited, locked policy. Display credentials are copied
into a private runtime home, removed with its GTK state on normal shutdown.
Forced termination can leave that private directory behind.

SDL is built from its pin without SysV shared memory and linked statically.
GTK dialogs use Cairo rather than GL for the same restriction. Links offer
Copy link, storage offers Copy path instead of Open folder, and Launch at
login is not offered. Network and desktop IPC remain available; this policy
does not isolate X11 or D-Bus from the rest of your desktop.

Websocket fetching remains in-process. Frame lengths are checked against the
remaining response capacity without adding untrusted lengths, including across
fragmented messages.

The `wn-font` helper receives an already-open input file on stdin, locks
`unveil()` with no paths and pledges `stdio` before initializing FreeType.

Still images are decoded by `wn-image`, including header probes for card,
sticker and model-texture budgets. The app sends compressed bytes over private
pipes and accepts only bounded RGBA pixels. Each request allows at most
128 MiB of input, 256 MiB of pixels and 32,768 pixels per dimension; individual
callers can impose smaller limits. The parent checks the response dimensions,
byte count, end of stream and exit status, and kills the helper after ten
seconds. A missing helper or failed decode has no in-process fallback.

Archives are listed and extracted by `wn-archive`. Requests accept up to
128 MiB of input, scan at most 65,536 headers and return at most 2,000 regular
files. Listings are limited to 8 MiB, with UTF-8 names up to 4,096 bytes;
one extracted entry is limited to 64 MiB. The parent validates every metadata
record before publishing it. Neither side writes extracted files to disk.
Links and libarchive filters requiring external programs are rejected.

PDF pages are rendered by `wn-pdf`. The app retains source bytes and requests
one page at a time, including on navigation and fullscreen resize. Input is
limited to 128 MiB and documents to 10,000 pages; each reply contains at most
64 MiB of RGBA pixels, with dimensions no larger than 32,768 or the requested
bounding box. Poppler and embedded-font parsing stay in the helper.

STL, OBJ, GLB and G-code parsing runs in `wn-mesh`; FBX parsing and animation
evaluation run in `wn-fbx`. Input is limited to 128 MiB, geometry to two
million triangles or toolpath segments, and flat replies to 512 MiB. The app
validates channel sizes, indices, finite values, strings and texture references
before publishing a model. Embedded GLB images go through `wn-image`.
Neither cgltf nor ufbx is linked into the main application.
FBX triangles are not subdivided after import; animation poses the imported
geometry without changing its topology.

G-code previews draw shaded, rounded toolpaths with depth testing and 2x
supersampling. The slider selects the printed portion; orbit and zoom change
the camera. Large previews show raster progress as toolpaths appear. Stroke
width is a visual approximation, not a measured nozzle or extrusion width.

Math blocks are rendered by `wn-math`, which compiles Bragi's Odin C API
alongside the helper and replays its drawing commands through a C++ Cairo
shim. The main application does not link Bragi. Each request accepts at most
4,096 source bytes and returns
at most 8 MiB of straight RGBA pixels, with dimensions no larger than 4,096.
The helper embeds Bragi's TeX Gyre DejaVu Math font. Invalid input, a failed helper or an exceeded
budget leaves the source text visible instead of rendering it in-process.

NES cartridges run in `wn-nes`, one helper per open game, over the same
sequenced exchange as `wn-fbx`. The app sends the ROM once (an iNES header and
at most 8 MiB), then one controller byte per emulated frame. Each reply holds
61,440 palette indices and at most 1,024 16-bit audio samples. A malformed
reply, a dead helper or a missed ten-second deadline closes the player.

On OpenBSD, `wn-image`, `wn-archive`, `wn-mesh`, `wn-fbx`, `wn-math` and `wn-nes` lock
`unveil()` with no filesystem paths and pledge `stdio` before reading input.
`wn-math` parses UTF-8 directly, without locale initialization or runtime font files.
`wn-pdf` initializes Fontconfig and the trusted bundled fonts first, then
unveils the bundle, standard system font trees and Poppler resource directories
read-only. Directory grants avoid OpenBSD's limit on individual unveiled names.
It locks that policy and pledges `stdio rpath` before reading PDF bytes.

The image, archive, PDF, mesh, FBX, math and NES helpers share a 1 GiB memory limit,
no inherited environment and only input, output and a null error stream.
On macOS, the address-space limit adds that budget to all startup mappings,
including Rosetta's reserved regions. Mach's basic task counter omits those
regions even though the kernel includes them when checking the limit.
Image, archive, PDF, mesh and math helpers
have five CPU seconds and ten seconds wall time; the parent requires exact
reply framing, end of stream and successful exit. FBX helpers have a ten-second
deadline and an echoed sequence number per exchange, but no cumulative CPU
quota, so valid looping animations do not expire.
Static FBX helpers close after loading; animated helpers close with the model.
An invalid pose leaves the last validated geometry intact and closes the helper.
`wn-nes` follows the same session rules and closes with the player.

Failure has no in-process fallback. Linux requires `close_range` (kernel 5.9
or newer); descriptor or sandbox setup failure stops decoding. Platforms other
than OpenBSD use separate resource-limited processes, not an equivalent
filesystem or syscall sandbox. Video parsing remains in the main process.
