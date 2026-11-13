# Install

Every tagged release publishes a self-contained x86-64 AppImage on the [Releases](https://github.com/marmot-protocol/whitenoise-linux/releases) page. It carries its own libraries, fonts, and emoji set, so there is nothing to install alongside it:

```sh
chmod +x WhiteNoise-*-x86_64.AppImage
./WhiteNoise-*-x86_64.AppImage
```

Japanese and Korean text are the one exception: Noto Sans CJK is tens of megabytes, so it is not bundled and comes from your system instead (`noto-fonts-cjk` on Arch, `fonts-noto-cjk` on Debian and Ubuntu).

For Flatpak updates, install [Orchard](https://github.com/Letdown2491/orchard)
0.3 or newer and find White Noise in its Orchard catalog. Check the publisher
against `orchard.txt` in this repository, then choose Verify and install.
Orchard verifies the signed release and each OCI component before installation;
subsequent updates are managed by Orchard, outside White Noise's sandbox.
The package uses the GNOME 50 runtime and currently supports x86-64.

Each release also ships a standalone Flatpak bundle for manual installation.
This download does not set up an update remote:

```sh
flatpak install --user WhiteNoise-*-x86_64.flatpak
flatpak run dev.ipf.whitenoise
```

The Flatpak keeps its data under `~/.var/app/dev.ipf.whitenoise/`. One thing stays outside its sandbox: "Launch at login".

Linux ARM64 and x86-64 tarballs and Windows x86-64 packages are built on
Linux alongside the AppImage and Flatpak; macOS Intel and ARM64 bundles are
built on a Mac, and the OpenBSD package on OpenBSD 7.9.

| Target | Archive | Launch |
| --- | --- | --- |
| Linux ARM64 / x86-64 | `WhiteNoise-<version>-linux-{arm64,amd64}.tar.gz` | Extract and run the top-level `whitenoise` script; requires glibc 2.39 or newer |
| Windows x86-64 | `WhiteNoise-win-Setup.exe` or `WhiteNoise-win-Portable.zip` | Run the installer, or extract the portable zip anywhere and run `White Noise.exe`; requires Windows 10 or newer |
| macOS Intel / ARM64 | `WhiteNoise-<version>-darwin-{amd64,arm64}.tar.gz` | Extract `White Noise.app`; requires macOS 13 or newer |
| OpenBSD amd64 | `WhiteNoise-<version>-openbsd-amd64.tar.gz` | Install as root under a protected prefix, then run as your normal user (see below). Requires OpenBSD 7.9 and `pkg_add libarchive libwebp mpv poppler cairo curl glib2 zenity libnotify`. Reading aloud and dictation are not included |

Windows installs update themselves through [Velopack](https://velopack.io).
The app checks this repository's GitHub releases at launch and every six
hours, downloads a newer build in the background, and shows a
"Restart now" strip in the status bar. An update left waiting applies on the
next launch. The About page in Settings shows the update state and has a "Check now"
button. The portable zip updates the same way, in place. A build run from
anywhere else (a development build, a staging zip) has no updater and shows
no update UI.

AppImage builds use [AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate)
for signed delta updates. In Settings, About, choose "Check now" to check and
download, or enable "Automatically download updates" to check at launch and
every six hours. Automatic downloads are off until you enable them. Downloads
show progress without blocking chat. "Restart now" saves your drafts and
relaunches the updated AppImage with the same data directory. "Later" leaves
the current version running; a normal quit installs the download for your next
launch. The updater preserves the original filename and
keeps the previous image for rollback. Updates must carry a valid signature
from the installed image's signing key and a newer version, including the
same-day revision. The AppImage must be in a writable, privately controlled directory.

macOS builds use [Sparkle](https://sparkle-project.org) for update checks,
download progress, and installation. Settings, About has "Check now" and an
automatic-checking preference. Sparkle asks for permission to check
automatically and verifies the update archive's Ed25519 signature before
extraction. Installing an update saves your drafts before quitting and
preserves your data directory on relaunch.

AppImage and macOS update checks are disabled while a SOCKS5 proxy is
configured, because their update frameworks cannot use the app's proxy
settings safely. Download a release manually instead. Flatpak, AUR, other
tarballs, and development builds do not use these self-updaters. Existing
AppImage and macOS versions without an updater need one manual upgrade to
an updater-capable release.

Windows and macOS builds do not run webxdc (`.xdc`) apps. Linux retains its
WebKitGTK webxdc viewer. Ordinary attachments, video, PDFs, 3D previews,
speech and dictation are not disabled on the other targets.

The macOS bundle is ad-hoc signed, not Developer ID signed or notarized, so
macOS says it cannot verify the developer the first time you open it. Open it
once with Control-click, Open (or System Settings, Privacy & Security, Open
Anyway); after that it launches normally. A Developer ID signature and
notarization need an Apple Developer account.

On Arch, install `whitenoise-linux-bin` from the AUR. It installs the
`WhiteNoise-<version>-archlinux-x86_64.tar.zst` each release ships, which CI
builds on Arch against the system SDL3, mpv and poppler, so installing
compiles nothing:

```sh
yay -S whitenoise-linux-bin
```

`whitenoise-linux` builds the latest release from source. Every input it
needs is a checksummed source in its PKGBUILD, generated from `DEPS_PIN` by
`scripts/aur-source.sh`, and `build()` runs with the network off. Expect a
long first build: it compiles the Rust Marmot library.

```sh
yay -S whitenoise-linux
```

`whitenoise-linux-git` builds the current master from source. Its
`prepare()` downloads every pinned input and `build()` runs with the network
off. To build it from a checkout:

```sh
cd packaging/arch/whitenoise-linux-git && makepkg -si
```

The three packages conflict with each other and with `whitenoise-git`, the
Flutter client, because all of them install `/usr/bin/whitenoise`.

## OpenBSD

OpenBSD requires a root-owned installation whose resources, helpers,
libraries and ancestor directories are not group- or other-writable.
Mutable symlink routes are rejected too. Extract the release as root into
a protected directory, not your home directory:

```sh
doas tar -xzf WhiteNoise-<version>-openbsd-amd64.tar.gz -C /usr/local
/usr/local/WhiteNoise-<version>-openbsd-amd64/bin/whitenoise
```

Run the app as your normal user. Running as root or directly from an
unprivileged build tree is rejected. For a source build, use
`doas bash scripts/install-tree.sh /usr/local/whitenoise whitenoise`, then
run `/usr/local/whitenoise/bin/whitenoise`.

## First run

On first launch, set a vault password, then choose Generate a new key to create
your identity. If you already have a secret key, choose Import a secret key
(nsec). You can also paste a bunker link or pair with a remote signer.
Later launches unlock the same vault.
A wrong password cannot decrypt it. **Use another key** deletes the vault and
its sealed data and returns to account setup.

The get-started card checks for an existing key package before offering to
publish one. A key package lets other people invite you to encrypted chats.
Settings > Keys & identity > Key packages counts each package once and lists
where it is stored. A package can be on this device and on several relays;
the relay count describes copies of that package, not additional packages.
Export encrypted key opens its password dialog on the first click.

If relay discovery fails during key import or remote-signer login, missing lists
use `wss://relay.eu.whitenoise.chat`, `wss://relay.us.whitenoise.chat`,
`wss://relay.ditto.pub`, and `wss://relay.cyberguy.fyi`. Signed relay lists already
found remain unchanged.
