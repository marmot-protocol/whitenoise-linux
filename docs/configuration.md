<sub>REFERENCE&ensp;·&ensp;CONFIGURATION</sub>

# Configuration

### Your secrets live in one directory, your preferences in another, and the proxy password in neither JSON file.

This page covers where White Noise keeps its files, which settings survive a restart, the SOCKS5 proxy, and the few environment variables worth knowing. Nothing here needs a config file to get started.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/configuration-files-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/configuration-files-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/configuration-files-dark.svg">
  <img alt="What lives where. The data directory, ~/.local/share/whitenoise/ unless the first argument names another, holds the vault with your keys and proxy login, the media cache, the offline queue and themes/*.toml packs. Settings, $XDG_CONFIG_HOME/whitenoise/settings.json, holds theme, accent, locale, notification toggles, nicknames, and prefs.socks5_proxy and prefs.socks5_auth: plain JSON with no secrets. Observability, $XDG_CONFIG_HOME/whitenoise/observability.toml, optionally overrides the telemetry and audit log endpoints, and the built-in endpoints apply without it; nothing is sent until you enable it." src="../assets/docs/configuration-files-light.svg" width="880">
</picture>

## The data directory and settings.json hold different things

| Location | Default | Holds |
| --- | --- | --- |
| Data directory | `~/.local/share/whitenoise`, or the app's first argument | The vault, the media cache, the offline queue, and any custom theme packs you drop in its `themes/` subdirectory |
| UI preferences | `$XDG_CONFIG_HOME/whitenoise/settings.json` | Theme, accent, locale, notification toggles, nicknames |

## What comes back after a restart

The app restores your last page, settings section and tab, the rail's Unread filter, and window size after a restart. Reopening Settings returns to the section you left. These preferences are independent of General's "Restore last chat" toggle, which controls only the selected conversation.

## Relay fields refuse bad input without losing it

- **Add fields start empty.** Relay add fields under Network & relays ask you to enter a relay URL. Choosing Add with an empty or whitespace-only field focuses it and shows a correction without changing your relay lists.
- **Event fetch relays need a `ws://` or `wss://` URL with a host.** Local addresses, IPv6, ports, paths, and query strings are supported.
- **Malformed input stays put.** It remains in the field with a correction message and is not saved.

## Routing through a SOCKS5 proxy

1. Open Settings > Network & relays > Relays and enable the proxy.
2. Enter a numeric address such as `127.0.0.1:9050` or `[::1]:9050`. The field starts empty unless you have saved a proxy.
3. For authentication, enable Use username and password and fill both fields. Each accepts 1 to 255 UTF-8 bytes. Leave that switch off for an unauthenticated proxy.
4. Choose Save, then restart White Noise. Restart guidance appears after saving succeeds.

To return to direct connections, disable the switch, save, and restart. Hostnames and proxy URLs are not supported.

- **The address lives in settings.json.** It is stored as `prefs.socks5_proxy`; an empty value disables it.
- **Credentials live in the vault.** They are stored in the encrypted vault, not `settings.json`; `prefs.socks5_auth` stores only the authentication choice.
- **You can set it before you have an account.** Choose "Connection settings (SOCKS5 proxy)" on the sign-in screen to configure the same setting without creating an account. Back and Escape return to the account options. A saved change applies after a restart.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/configuration-proxy-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/configuration-proxy-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/configuration-proxy-dark.svg">
  <img alt="What the SOCKS5 proxy carries. Through it: relay connections, with relay names resolved through the proxy, remote signers, media transfers, link previews and embedded pages, speech and translation model downloads, and telemetry exports when enabled; a failed request never falls back to a direct connection. Not through it: QUIC agent previews need UDP and are off; Marmot's HTTP host checks use local DNS; external browsers and other apps ignore it; AppImage and macOS update checks are off. So the proxy does not hide every DNS query." src="../assets/docs/configuration-proxy-light.svg" width="880">
</picture>

The proxy carries relay and remote-signer connections, media transfers, link previews, embedded web pages, speech and translation model downloads, and enabled telemetry exports. Failed proxied requests do not fall back to direct connections. Relay names are resolved through the proxy.

> [!WARNING]
> This setting does not hide all DNS queries. Marmot's HTTP host checks still use local DNS so downloads and telemetry retain their validated address pins.

QUIC agent previews are unavailable while the proxy is enabled because they require UDP. External browsers and other apps do not use this setting. AppImage and macOS update checks are also disabled while a proxy is configured; see [Install](install.md#how-each-build-updates-itself).

## Telemetry endpoints, if you want your own

Telemetry and audit logs use built-in endpoints. To override them, create `$XDG_CONFIG_HOME/whitenoise/observability.toml` (or `~/.config/whitenoise/observability.toml` when `XDG_CONFIG_HOME` is unset). Nothing is sent until you enable the corresponding toggles under **Settings**, in the **Advanced** section.

## Environment variables for automation

| Variable | Effect |
| --- | --- |
| `WN_VAULT_PW` | Unlocks (or creates) the vault without showing the gate. |
| `WN_SHOT` / `WN_SHOT_FRAME` | Capture a screenshot after N frames, then exit. |
| `WN_TEST_*` | Drive the app into a given pane or action on boot; see `app/main.odin`. |

## Deep links (`marmot://`)

Profile QR codes encode `marmot://profile/<npub>?from=qr`, the scheme shared by all Marmot clients. The app handles these when they arrive as a command-line argument or are pasted into **Add contact**. To have your desktop hand `marmot://` links to White Noise:

```sh
scripts/install-scheme.sh
```

<sub>[Back to the README](../README.md#further-reading)</sub>
