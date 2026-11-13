# Building from source

## Nix (x86-64 Linux)

The repository's flake supplies the native build tools and libraries in an FHS
environment; it does not require a global `nix-ld` setup. From this checkout,
enter the interactive shell and use the existing build commands:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
just build
just run
```

For a single command, use the app entrypoint instead of `nix develop -c`, because
the FHS shell hook consumes command arguments:

```sh
nix --extra-experimental-features 'nix-command flakes' run . -- odin version
```

The flake installs the upstream Odin dev-2026-10 release binary, the same
compiler CI uses, and pins OLS to dev-2026-10 through the nixpkgs lock.
Rust is pinned to 1.97.1; install that toolchain with `rustup` if it is not
already available. Cargo output defaults to `target/nix` in the working
directory unless `CARGO_TARGET_DIR` is set.

Running the GUI still needs the host desktop session, display/audio sockets,
and GPU devices. The shell preserves access to host desktop resources,
including Omarchy Compose data when present. It uses the host driver set on
NixOS and Nix Mesa elsewhere. The first build still downloads the project's
pinned source dependencies and resource bundles described below.

## System packages

You need `just`, the [Odin dev-2026-10 release binary](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10), a C and C++ compiler, CMake, and a Rust toolchain (Marmot's C bundle is built from source). MDK compiles its Markdown parser with Odin and requires `odin version` to report commit `84bc3fc`; distribution packages may not. Plus SDL 3.4 or newer and the media libraries the viewers bind. Flatpak bundles SDL because the GNOME 50 SDK ships SDL 3.2.

**Debian / Ubuntu** (SDL3 needs 25.04 or newer, or a source build):

```sh
sudo apt-get install -y just pkg-config cmake clang git curl \
  libsdl3-dev libarchive-dev libmpv-dev libpoppler-glib-dev libcairo2-dev libglib2.0-dev \
  libcurl4-openssl-dev libssl-dev libfreetype-dev libwebp-dev \
  libavformat-dev libavcodec-dev libavutil-dev libswresample-dev zstd
```

**Arch:**

```sh
sudo pacman -S --needed just rust cmake sdl3 libarchive mpv ffmpeg poppler-glib cairo glib2 curl openssl freetype2 libwebp zstd
```

**Then:**

```sh
git clone https://relay.ngit.dev/npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh/darkmatter-linux.git
cd darkmatter-linux
just build
just run
```

The first build clones the pinned Marmot revision and builds its C bundle,
fetches ufbx and Bragi, and extracts the SHA-256-pinned emoji bundle
with `zstd`. It also builds Odin's STB archives when the installation lacks
them. Later builds reuse the staged dependencies.

The native Linux build extracts speech, font, and emoji archives without
restoring ownership, so it can run as root inside Flatpak's restricted user
namespace.

Native Linux builds, Linux tarballs, and app test binaries hide the symbols
in `libmarmot_c.a` from shared libraries. This keeps Marmot's bundled OpenSSL
separate from libcurl's shared TLS libraries during certificate verification.

The emoji bundle contains each set's PNGs, catalog, licenses and
`emoji/<set>.bin` pixel pack. Cold font and emoji staging measured
0.86-1.62 seconds on a Ryzen AI MAX+ 395 across three fresh-output runs,
including archive verification and extraction, but excluding downloads and
without flushing filesystem caches. The bundle download is about 85 MB;
its independently compressed sets are extracted concurrently.

Maintainers regenerate the bundle with `bash scripts/emoji-bundle.sh`,
using librsvg 2.62.3, cairo 1.18.4 and Odin's STB headers. The script uses
the upstream pins in `DEPS_PIN` and fixed archive metadata. Upload its
output to the `deps` release, then update `emoji-bundle-file` with the
printed SHA-256 and download URL. Normal builds need no SVG renderer or
host emoji-packer compilation.

The app reads the active set's fixed-size RGBA data at startup (and again
when you pick another set in Appearance) and uploads only visible picker
rows, so opening, scrolling, and searching do not launch PNG decoders for
catalog emoji. Each pack is about 119 MiB uncompressed (OpenMoji's 153 MiB,
with its own extra emoji), so the three add about 391 MiB of resources;
only the active one is resident. They ship beside `emoji-catalog.tsv` in
every package.

Trusted Linux CI and release builds run on the two `wn-build-server` slots.
Podman keeps the Ubuntu 24.04 native/cross, GNOME 50 Flatpak, and Arch build
environments separate. OpenBSD builds in a persistent KVM guest. Fork PRs
use ephemeral GitHub-hosted Linux runners; macOS builds stay on Apple
runners. Release publication and the pre-commit gate remain GitHub-hosted.

Each slot retains stamped build outputs, Cargo targets and downloads, and
vcpkg archives under `~/.cache/wn-github/`, separated by build environment.
The build scripts still validate their inputs, run tests, and boot freshly
packaged binaries. Flatpak builds on `master` retain tokenless module state;
tagged module state is isolated and deleted after upload. Only dependency
outputs pass between those Flatpak builds. Only tag pushes publish releases.

The server's shared build slice caps the two slots at 80% of its 16 CPUs
and 50 GiB RAM. A five-second host guard stops CI if available RAM falls
below 8 GiB. Individual job containers also have CPU and memory limits.


## Cross releases

`scripts/cross-build.sh TARGET` accepts `linux-arm64`, `linux-amd64`,
`windows-amd64`, `darwin-amd64`, or `darwin-arm64`. `linux-amd64` is not a
cross build, but the same portable tarball recipe as `linux-arm64`.
`WN_TARGET=TARGET scripts/build.sh` invokes
the same path. The normal `scripts/build.sh` remains a native Linux build.
Each target has separate objects, Rust output, libraries and package files
under `build/cross/TARGET`; finished archives go to `dist/`.

The supplied amd64 Linux container includes the cross compilers and package
tools:

```sh
podman build -f packaging/cross/Containerfile -t whitenoise-cross packaging/cross
podman run --rm -v "$PWD:/work" whitenoise-cross linux-arm64    # or linux-amd64
podman run --rm -v "$PWD:/work" whitenoise-cross windows-amd64
```

The ARM64 build extracts an Ubuntu 24.04 target sysroot without running ARM
compilers. Windows uses LLVM-MinGW 20260922 with UCRT and libc++, paired with
Rust's `x86_64-pc-windows-gnullvm` target. Its separate vcpkg triplet avoids
reusing GCC/MSVCRT libraries. Windows 10 or newer supplies UCRT. Odin emits
target objects; the target C linker links the app with Marmot, STB,
the app shims and media libraries. Odin compiles Bragi's C API into the
`wn-math` object; the C++ linker links it with the Cairo drawing replay shim
(`libwnmath.a`) and Cairo. Source revisions are pinned in
`DEPS_PIN`, and Windows/macOS dependency recipes are pinned by the vcpkg
baseline in `packaging/cross/vcpkg.json`. FFmpeg includes dav1d for CPU AV1
decoding on Windows and macOS. Speech uses the same pinned upstream
sherpa-onnx CPU runtime as the native build. Packages include the speech/font
helpers, curl, their loader dependencies, fonts, emoji data and licenses.
The GUST font license is checked in at `assets/fonts/GUST-FONT-LICENSE.txt`
and staged locally by native and cross builds, without contacting CTAN mirrors.

macOS bundles build on a Mac, where Apple's SDK is licensed: Xcode or its
Command Line Tools supply it, and no Apple account is needed. An Apple silicon
Mac builds both architectures; Odin publishes no compiler for Intel Macs.
`scripts/macos-setup.sh` installs the pinned
tools with Homebrew (GNU userland, bash 5, Odin, Bun, Meson) the way the
container does on Linux, and needs Homebrew, rustup and the Command Line
Tools already present:

```sh
scripts/macos-setup.sh ~/.cache/whitenoise-macos-tools
source ~/.cache/whitenoise-macos-tools/env
scripts/cross-build.sh darwin-arm64    # or darwin-amd64 for Intel
```

The build uses Xcode's clang with a pinned `-arch` and a macOS 13 deployment
target, then signs every Mach-O file and the bundle ad hoc with `codesign`.

OpenBSD builds natively on OpenBSD 7.9; there is no cross toolchain for it.
`scripts/openbsd-build.sh` lists the packages to install in its header, builds
the pinned Odin release from source (OpenBSD has no Odin package), runs
`scripts/build.sh`, and packs the install tree as
`dist/WhiteNoise-<version>-openbsd-amd64.tar.gz`:

```sh
doas pkg_add bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
  sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg zenity libnotify zstd
bash scripts/openbsd-build.sh
```

Run the build as your normal user, with `sudo` or `doas` configured for
package staging. The script tests a root-owned installation, including an
Xvfb window that resizes and closes under confinement.

OpenBSD's Rust package (1.94) is older than the toolchain Marmot pins, so
`scripts/build.sh` enables the one unstable feature the build needs
(`cfg_select`) on OpenBSD. It also raises the per-process data size limit,
which rustc and Odin's optimizing build otherwise run out of.
Reading aloud and dictation are left out: sherpa-onnx publishes no OpenBSD
runtime, so those features report that they could not start.
Webxdc is disabled on OpenBSD. `.xdc` attachments remain ordinary downloadable
files; the build omits `wn-webview`, and installation removes an older copy.

`.github/workflows/cross.yml` is called by CI and tagged releases. Its Linux
ARM64 and Windows jobs extract the shipped archive and require a headless
launch to produce a screenshot under QEMU or Wine. No compiler runs under
those emulators. The cross-architecture Linux smoke uses a temporary package
view with helper launchers that re-enter QEMU, including helpers launched with
an empty environment. It runs the shipped executables and libraries, with only
glibc supplied by the target sysroot. The macOS jobs build and launch both
bundles on Apple silicon, using Rosetta for the Intel bundle. Its
OpenBSD job boots the OpenBSD 7.9 image from
[cross-platform-actions](https://github.com/cross-platform-actions/action)
under QEMU, builds and packages inside it, and launches the packaged binary
headless there.

Platform-specific Odin code can be checked from Linux before building a package:

```sh
odin check app -target:windows_amd64 -define:WN_TARGET=windows-amd64
odin check app -target:openbsd_amd64 -vet-unused-imports
```

These commands type-check the app; they do not link it or verify runtime behavior.

## Releasing

`APP_VERSION` in `app/advanced.odin` is `YYYY.M.D+REVISION`, starting at
`2026.9.15+1`. Like Android and iOS, the date is the release date and the
numeric revision increases for every shipment, including on a new date.
Set it before releasing and tag that commit `vYYYY.M.D-build.REVISION`
(for example, `v2026.9.15-build.1`). Never reuse a published tag.
About, diagnostics, AppImage, Flatpak, and Arch packaging use this version.

The app shows the version written in `APP_VERSION` (`app/advanced.odin`); a
tag does not change it, and `release.yml` rejects a tag that does not match
it. `just release` (`scripts/release.sh`) keeps the two together: it takes
`origin/master` (a dirty checkout or another branch is left untouched), sets
`APP_VERSION` to today's date with the next revision (`2026.9.27+1`, then
`+2` the same day), commits that on top, tags `v2026.9.27-build.1`, and
pushes the result and the tag to both remotes. The tag reaching GitHub
starts the release build. `just release --dry-run` prints the version and
tag without changing anything.

`just publish` (`scripts/publish.sh`) does all of that, waits for the
release workflow to publish the GitHub release, then signs its AppImage,
Flatpak bundle, and Orchard OCI components with your bunker or nsec.
One NIP-82 release lists all five assets and is sent to
`wss://relay.cyberguy.fyi`, `wss://relay.orchard.rocks`,
`wss://relay.ditto.pub`, and `wss://relay.zapstore.dev`.
`just publish <tag>` waits for and announces an existing release without
creating another one. Use it to resume publication after the tag was pushed.
Both stores use the publisher in `zapstore.yaml`; `orchard.txt`
records that public key for Orchard's repository check.

Run `bash tests/release-test.sh` to check the release-to-publish tag handoff
with signed commits and local remotes, without publishing publicly.

The release publisher is the White Noise identity,
`npub1whtn0s68y3cs98zysa4nxrfzss5g5snhndv35tk5m2sudsr7ltms48r3ec`.
Run `just publish` (or `just publish <tag>` for a built release), paste its
`bunker://` URL at the hidden signer prompt, and approve the seven NIP-46
signing requests: one kind 32267 listing, five kind 3063 assets, and one
kind 30063 release. The publisher checks the returned signing key before
sending each event. The bunker URL stays out of command arguments and
shell history; exporting the White Noise private key is not required.

The Flatpak build prepares Orchard's manifest, config, layer, and bootstrap
OCI archive from the finished sandbox tree. These files and their checksums
are hosted on the GitHub release; a registry account and another signing key
are not needed. Preparation uses the Orchard revision in `DEPS_PIN` and
does not publish events. The signed announcement happens during
`just publish`, so a tag push alone does not add a version to Orchard.

Tagged releases publish the Windows installer, the portable zip, and
Velopack's feed (`releases.win.json`, `assets.win.json`, `RELEASES`, and the
`.nupkg` packages) to the GitHub release. The job first downloads the previous
release so Velopack can also publish a delta package. Windows packages are
unsigned unless `JSIGN_STORETYPE` is configured. Unsigned builds may trigger
Windows publisher and SmartScreen warnings. To enable Authenticode signing
with [jsign](https://ebourg.github.io/jsign/), set repository variables `JSIGN_STORETYPE` (jsign's
`--storetype`, for example `PKCS12` or `TRUSTEDSIGNING`) and `JSIGN_ALIAS`,
secret `JSIGN_STOREPASS`, and either secret `JSIGN_KEYSTORE_BASE64` (a
base64 keystore file, such as a `.p12`) or secret `JSIGN_KEYSTORE` (a cloud
keystore name or endpoint). Local builds sign when the same `JSIGN_*`
variables are passed to the container. Staging builds (a non-release version)
keep a plain zip and never join the update feed.

AppImage releases require the `WN_APPIMAGE_SIGNING_KEY` Actions secret, an
armored GPG private key matching `packaging/appimage-update-key.asc`.
`scripts/sign-appimage.sh` embeds that identity and the signature in the
image. Build its isolated updater with `scripts/build-appimage-updater.sh`
and stage with `WN_PACKAGE_APPIMAGE=1 scripts/install-tree.sh AppDir/usr whitenoise`.
Ordinary Linux builds compile only the small process bridge and do not build
or ship the delta updater.
The updater closes its GPG context before removing the temporary keyring,
including when an unsigned or invalid image is rejected.

macOS releases require `WN_SPARKLE_PRIVATE_KEY`, a base64 Ed25519 seed
matching `packaging/sparkle-public-key.txt`. Each architecture publishes its
own signed update archive and `appcast-<arch>.xml` on the GitHub release.
The public keys are committed; private keys stay in Actions secrets and
maintainer backups. Missing or mismatched release keys fail packaging.
Sparkle archive signatures authenticate updates independently of the
bundle's ad-hoc code signature; they do not add Developer ID signing or
notarization.

To store a generated key backup in KeePass, close that database in the GUI
and run:

```sh
scripts/store-release-keys.sh /path/to/passwords.kdbx /path/to/key-backup
```

The script uses the native or Flatpak KeePassXC CLI and prompts for the
database password. It creates `White Noise release signing keys` with the
AppImage private key, Sparkle seed and Sparkle PEM as attachments, then
reads each one back for comparison. Reruns verify existing attachments and
add missing ones, but stop if a stored key differs. Nothing is overwritten;
source keys are not deleted. Pass KeePassXC unlock options after the two
paths if needed, for example `-k /path/to/keyfile` or `--no-password`.

ngit staging uses `.ngit/act/workflows/release-cross.yml` alongside the
existing x86-64 AppImage workflow. The act worker needs Podman with working
user namespaces and permission to build and run nested containers. It has no
macOS job yet: those need a Mac act runner, and until one exists macOS
bundles come from the GitHub workflow. Each target is passed
to `actions/upload-artifact`; Blossom publication requires the coordinator's
`--blossom-servers` setting and an artifact-size limit large enough for the
archives (`--blossom-max-artifact-bytes`, commonly above the default 64 MiB).

