# Configuration

The data directory is the app's first argument and defaults to `~/.local/share/whitenoise`. It holds the vault, the media cache, the offline queue, and any custom theme packs you drop in its `themes/` subdirectory. UI preferences (theme, accent, locale, notification toggles, nicknames) live separately in `$XDG_CONFIG_HOME/whitenoise/settings.json`.

The app restores your last page, settings section and tab, the rail's Unread
filter, and window size after a restart. Reopening Settings returns to the
section you left. These preferences are independent of General's
"Restore last chat" toggle, which controls only the selected conversation.

Relay add fields under Network & relays start empty and ask you to enter a
relay URL. Choosing Add with an empty or whitespace-only field focuses it
and shows a correction without changing your relay lists.

Event fetch relays require a `ws://` or `wss://` URL with a host. Local
addresses, IPv6, ports, paths, and query strings are supported. Malformed
input stays in the field with a correction message and is not saved.

Set a SOCKS5 proxy under Settings > Network & relays > Relays. Enable the
proxy, enter a numeric address such as `127.0.0.1:9050` or `[::1]:9050`,
then choose Save and restart White Noise. Disable the switch, save, and
restart to return to direct connections. The setting is stored as
`prefs.socks5_proxy` in `settings.json`; an empty value disables it.
The address field starts empty unless you have saved a proxy. Restart
guidance appears after saving succeeds.
For authentication, enable Use username and password and fill both fields.
Each accepts 1 to 255 UTF-8 bytes. Credentials are stored in the encrypted
vault, not `settings.json`; `prefs.socks5_auth` stores only the authentication
choice. Leave that switch off for an unauthenticated proxy. Hostnames and
proxy URLs are not supported.
Before signing in, choose "Connection settings (SOCKS5 proxy)" on the sign-in
screen to configure the same setting without creating an account. Back and
Escape return to the account options. A saved change applies after a restart.

The proxy carries relay and remote-signer connections, media transfers,
link previews, embedded web pages, speech and translation model downloads, and enabled
telemetry exports. Failed proxied requests do not fall back to direct
connections. Relay names are resolved through the proxy. Marmot's HTTP host
checks still use local DNS so downloads and telemetry retain their validated
address pins; this setting does not hide all DNS queries. QUIC agent previews
are unavailable while the proxy is enabled because they require UDP.
External browsers and other apps do not use this setting.

Telemetry and audit logs use built-in endpoints. To override them, create
`$XDG_CONFIG_HOME/whitenoise/observability.toml` (or
`~/.config/whitenoise/observability.toml` when `XDG_CONFIG_HOME` is unset).
Nothing is sent until you enable the corresponding toggles under
**Settings**, in the **Advanced** section.

A few environment variables matter, mostly for automation:

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
