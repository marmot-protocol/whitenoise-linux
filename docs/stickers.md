<sub>GUIDE&ensp;·&ensp;MEDIA</sub>

# Stickers

### Packs follow you to every device; the stickers you import stay on this one.

Stickers live in the composer's emoji picker. Packs come from MDK and sync through your relays, while your own stickers are a Linux extension.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/stickers-paths-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/stickers-paths-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/stickers-paths-dark.svg">
  <img alt="Two kinds of sticker in the composer's emoji picker. Packs are added from a link pasted into Manage, previewed first: an naddr, a 30031:author hex:identifier coordinate, or a sonarprivacy.xyz/stickers?a= link. MDK installs the pack and publishes your kind-10031 list, so your other devices pick it up; packs are not offered in threads, which are kind 1111. Your own stickers are imported from a static PNG, WebP or JPEG of up to 4 MiB and 4096 pixels per side and listed in stickers/library.bin. They are sent as an image tagged wn-sticker, other clients see an ordinary image, and they stay on this device without syncing. In the picker, click a tile to send it and right-click it to manage it." src="../assets/docs/stickers-paths-light.svg" width="880">
</picture>

## Send a sticker

Open the composer's emoji picker and choose **Stickers**. Click a tile to send it.

- **The keyboard works too.** Arrow keys select tiles; Enter sends.
- **Right-click a tile to manage it.** Right-click (or press Tab on the selected tile) to manage its image or pack.
- **Your draft stays put.** The text draft stays in the composer, and the reply you are composing and the armed effect go with the sticker.
- **Threads show only your own stickers.** Inside a thread the picker lists only your own stickers.

## Add a pack or import your own

Choose **Manage** to import a static PNG, WebP or JPEG as one of your own stickers, or to add a pack. Images are limited to 4 MiB and 4096 pixels per side. Animated stickers show as unavailable.

To preview a pack first, paste any of these:

| Form | Example |
| --- | --- |
| `naddr` | `naddr1…` |
| Coordinate | `30031:<author hex>:<identifier>` |
| Sonar link | `https://sonarprivacy.xyz/stickers?a=…` |

Stickers you receive work too. Click a received personal sticker to save it to your own stickers, or a pack sticker to open its pack.

## Sticker packs

MDK owns packs end to end, through the `marmot_*sticker*` C API:

| Call | What it does |
| --- | --- |
| `marmot_sticker_packs` | Lists the installed packs |
| `marmot_sync_sticker_packs` | Refreshes them and recent public packs from your relays when the sticker library first opens for an account |
| `marmot_install_sticker_pack`, `marmot_uninstall_sticker_pack` | Record the change and publish your kind-10031 installed list, so your other devices pick it up |
| `marmot_sticker_pack` | Reads a cached pack |
| `marmot_fetch_sticker_pack` | Looks one up on its relay hints and your relays |
| `marmot_fetch_sticker_asset` | Downloads one exact `(pack, shortcode, hash)` image and checks its hash, type and dimensions |
| `marmot_send_sticker` | Sends a kind-9 message whose content is the sticker tag |

- **An offline change waits.** It is kept and published on the next sync.
- **Pack images download once.** The app keeps a copy sealed with the vault's blob key under `stickers/` so it is not downloaded again.
- **Replies and effects ride along.** `patches/mdk-sticker-context.patch` adds a `tags` argument for the reply (`e`, `q`) and `effect` tags; MDK rejects a second `sticker` tag and `imeta`.

Timeline records and reply previews carry the pack sticker MDK parsed, so the app does not read pack sticker tags itself. MDK only recognizes pack stickers in kind-9 messages. Thread messages are kind 1111, so packs are not offered there.

## Your own stickers

MDK has no personal stickers, so these stay on this device. The images are sealed with the vault's blob key under `stickers/`, and `stickers/library.bin` lists them with your recent stickers.

- **They travel as ordinary images.** Sending one uploads it as an encrypted image attachment tagged `["wn-sticker", plaintext_sha256, name]`, a Linux extension.
- **Other clients see a picture.** Clients without the extension show an ordinary image.
- **They do not sync.** These stickers do not reach your other devices.

<details>
<summary><b>Where packs from before MDK kept the list went</b></summary>

Packs added before MDK owned the installed list were also kept in `library.bin`. The first account to open stickers installs them through MDK and removes them from the file. A pack that cannot be reached stays for a later open.

</details>

<sub>[Back to the README](../README.md#further-reading)</sub>
