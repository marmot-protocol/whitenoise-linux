<sub>GUIDE&ensp;·&ensp;INSTALL AND UPDATES</sub>

# Install

### Four systems, three self-updaters, and a pile of tarballs you update by hand.

Every tagged release publishes builds for Linux, Windows, macOS and OpenBSD on the [Releases](https://github.com/marmot-protocol/whitenoise-linux/releases) page. Which one you pick decides how it updates.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/install-updates-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/install-updates-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/install-updates-dark.svg">
  <img alt="Who updates each package. Windows: Velopack checks at launch and every six hours, for the installer and the portable zip. AppImage: AppImageUpdate fetches signed deltas, with automatic downloads off until you opt in. macOS: Sparkle checks the Ed25519 signature before extracting. Flatpak: Orchard 0.3 or newer updates from outside the sandbox; the standalone bundle has no update remote. Arch: the AUR, with whitenoise-linux-bin or a source build. Tarballs for Linux and OpenBSD, and development builds: you download each release. AppImage and macOS update checks are off while a SOCKS5 proxy is configured." src="../assets/docs/install-updates-light.svg" width="880">
</picture>

## The AppImage needs nothing beside it

The self-contained x86-64 AppImage carries its own libraries, fonts, and emoji set:

```sh
chmod +x WhiteNoise-*-x86_64.AppImage
./WhiteNoise-*-x86_64.AppImage
```

Japanese and Korean text are the one exception. Noto Sans CJK is tens of megabytes, so it is not bundled and comes from your system instead: `noto-fonts-cjk` on Arch, `fonts-noto-cjk` on Debian and Ubuntu.

## Flatpak through Orchard, or as a bare bundle

- **Orchard gives you updates.** Install [Orchard](https://github.com/Letdown2491/orchard) 0.3 or newer and find White Noise in its Orchard catalog. Check the publisher against `orchard.txt` in this repository, then choose Verify and install.
- **Orchard checks before it installs.** It verifies the signed release and each OCI component before installation; subsequent updates are managed by Orchard, outside White Noise's sandbox.
- **The package targets GNOME 50.** It uses the GNOME 50 runtime and currently supports x86-64.

Each release also ships a standalone Flatpak bundle for manual installation. This download does not set up an update remote:

```sh
flatpak install --user WhiteNoise-*-x86_64.flatpak
flatpak run dev.ipf.whitenoise
```

The Flatpak keeps its data under `~/.var/app/dev.ipf.whitenoise/`. One thing stays outside its sandbox: "Launch at login".

## Every other archive, by platform

Linux ARM64 and x86-64 tarballs and Windows x86-64 packages are built on Linux alongside the AppImage and Flatpak. macOS Intel and ARM64 bundles are built on a Mac, and the OpenBSD package on OpenBSD 7.9.

| Target | Archive | Launch | Requires |
| --- | --- | --- | --- |
| Linux ARM64 / x86-64 | `WhiteNoise-<version>-linux-{arm64,amd64}.tar.gz` | Extract and run the top-level `whitenoise` script | glibc 2.39 or newer |
| Windows x86-64 | `WhiteNoise-win-Setup.exe` or `WhiteNoise-win-Portable.zip` | Run the installer, or extract the portable zip anywhere and run `White Noise.exe` | Windows 10 or newer |
| macOS Intel / ARM64 | `WhiteNoise-<version>-darwin-{amd64,arm64}.tar.gz` | Extract `White Noise.app` | macOS 13 or newer |
| OpenBSD amd64 | `WhiteNoise-<version>-openbsd-amd64.tar.gz` | Install as root under a protected prefix, then run as your normal user ([see below](#openbsd)) | OpenBSD 7.9 and `pkg_add libarchive libwebp mpv poppler cairo curl glib2 zenity libnotify` |

Reading aloud and dictation are not included in the OpenBSD package.

Windows and macOS builds do not run webxdc (`.xdc`) apps. Linux retains its WebKitGTK webxdc viewer. Ordinary attachments, video, PDFs, 3D previews, speech and dictation are not disabled on the other targets.

## How each build updates itself

- **Windows uses [Velopack](https://velopack.io).** The app checks this repository's GitHub releases at launch and every six hours, downloads a newer build in the background, and shows a "Restart now" strip in the status bar. An update left waiting applies on the next launch. The portable zip updates the same way, in place.
- **AppImage builds use [AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate).** It fetches signed delta updates. In Settings, About, choose "Check now" to check and download, or enable "Automatically download updates" to check at launch and every six hours. Automatic downloads are off until you enable them.
- **macOS builds use [Sparkle](https://sparkle-project.org).** It handles update checks, download progress, and installation. Sparkle asks for permission to check automatically and verifies the update archive's Ed25519 signature before extraction.
- **Settings, About is the control panel.** On Windows it shows the update state and has a "Check now" button; on macOS it has "Check now" and an automatic-checking preference.
- **Flatpak, AUR, other tarballs, and development builds do not self-update.** A build run from anywhere else (a development build, a staging zip) has no updater and shows no update UI.

> [!WARNING]
> AppImage and macOS update checks are disabled while a SOCKS5 proxy is configured, because their update frameworks cannot use the app's proxy settings safely. Download a release manually instead.

Existing AppImage and macOS versions without an updater need one manual upgrade to an updater-capable release.

<details>
<summary><b>What happens between "Restart now" and the new version</b></summary>

**AppImage.** Downloads show progress without blocking chat. "Restart now" saves your drafts and relaunches the updated AppImage with the same data directory. "Later" leaves the current version running; a normal quit installs the download for your next launch. The updater preserves the original filename and keeps the previous image for rollback. Updates must carry a valid signature from the installed image's signing key and a newer version, including the same-day revision. The AppImage must be in a writable, privately controlled directory.

**macOS.** Installing an update saves your drafts before quitting and preserves your data directory on relaunch.

</details>

## macOS asks about the developer once

The macOS bundle is ad-hoc signed, not Developer ID signed or notarized, so macOS says it cannot verify the developer the first time you open it. Open it once with Control-click, Open (or System Settings, Privacy & Security, Open Anyway); after that it launches normally. A Developer ID signature and notarization need an Apple Developer account.

## Three AUR packages, one `/usr/bin/whitenoise`

| Package | What it installs | Build |
| --- | --- | --- |
| `whitenoise-linux-bin` | The `WhiteNoise-<version>-archlinux-x86_64.tar.zst` each release ships | CI builds it on Arch against the system SDL3, mpv and poppler, so installing compiles nothing |
| `whitenoise-linux` | The latest release, from source | Every input is a checksummed source in its PKGBUILD, generated from `DEPS_PIN` by `scripts/aur-source.sh`; `build()` runs with the network off |
| `whitenoise-linux-git` | The current master, from source | `prepare()` downloads every pinned input and `build()` runs with the network off |

```sh
yay -S whitenoise-linux-bin
```

Expect a long first build from `whitenoise-linux`: it compiles the Rust Marmot library.

```sh
yay -S whitenoise-linux
```

To build `whitenoise-linux-git` from a checkout:

```sh
cd packaging/arch/whitenoise-linux-git && makepkg -si
```

The three packages conflict with each other and with `whitenoise-git`, the Flutter client, because all of them install `/usr/bin/whitenoise`.

## OpenBSD

OpenBSD requires a root-owned installation whose resources, helpers, libraries and ancestor directories are not group- or other-writable. Mutable symlink routes are rejected too. Extract the release as root into a protected directory, not your home directory:

```sh
doas tar -xzf WhiteNoise-<version>-openbsd-amd64.tar.gz -C /usr/local
/usr/local/WhiteNoise-<version>-openbsd-amd64/bin/whitenoise
```

Run the app as your normal user. Running as root or directly from an unprivileged build tree is rejected. For a source build, use `doas bash scripts/install-tree.sh /usr/local/whitenoise whitenoise`, then run `/usr/local/whitenoise/bin/whitenoise`.

## First run

1. Set a vault password.
2. Choose Generate a new key to create your identity. If you already have a secret key, choose Import a secret key (nsec). You can also paste a bunker link or pair with a remote signer.

Later launches unlock the same vault. A wrong password cannot decrypt it. **Use another key** deletes the vault and its sealed data and returns to account setup.

- **The get-started card looks before it publishes.** It checks for an existing key package before offering to publish one. A key package lets other people invite you to encrypted chats.
- **Key packages are counted once.** Settings > Keys & identity > Key packages counts each package once and lists where it is stored. A package can be on this device and on several relays; the relay count describes copies of that package, not additional packages.
- **Export encrypted key opens on the first click.** Its password dialog appears immediately.

<details>
<summary><b>Relays used when discovery finds none</b></summary>

If relay discovery fails during key import or remote-signer login, missing lists use `wss://relay.eu.whitenoise.chat`, `wss://relay.us.whitenoise.chat`, `wss://relay.ditto.pub`, and `wss://relay.cyberguy.fyi`. Signed relay lists already found remain unchanged.

</details>

<sub>[Back to the README](../README.md#further-reading)</sub>
