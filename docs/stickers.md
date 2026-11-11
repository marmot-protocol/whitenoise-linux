# Stickers

Open the composer's emoji picker and choose **Stickers**. Click a tile to send
it. Right-click it (or press Tab on the selected tile) to manage its image or
pack. Arrow keys select tiles; Enter sends. The text draft stays in the
composer, and the reply you are composing and the armed effect go with the
sticker. Inside a thread the picker lists only your own stickers.

Choose **Manage** to import a static PNG, WebP or JPEG as one of your own
stickers, or to add a pack: paste its `naddr`, its
`30031:<author hex>:<identifier>` coordinate, or a Sonar
`https://sonarprivacy.xyz/stickers?a=…` link to preview it first. Click a
received personal sticker to save it to your own stickers, or a pack sticker
to open its pack.

Images are limited to 4 MiB and 4096 pixels per side. Animated stickers show
as unavailable.

## Sticker packs

MDK owns packs end to end, through the `marmot_*sticker*` C API:

- `marmot_sticker_packs` lists the installed packs, and
  `marmot_sync_sticker_packs` refreshes them and recent public packs from your
  relays when the sticker library first opens for an account.
- `marmot_install_sticker_pack` and `marmot_uninstall_sticker_pack` record the
  change and publish your kind-10031 installed list, so your other devices
  pick it up. An offline change is kept and published on the next sync.
- `marmot_sticker_pack` reads a cached pack; `marmot_fetch_sticker_pack` looks
  one up on its relay hints and your relays.
- `marmot_fetch_sticker_asset` downloads one exact `(pack, shortcode, hash)`
  image and checks its hash, type and dimensions. The app keeps a copy sealed
  with the vault's blob key under `stickers/` so it is not downloaded again.
- `marmot_send_sticker` sends a kind-9 message whose content is the sticker
  tag. `patches/mdk-sticker-context.patch` adds a `tags` argument for the
  reply (`e`, `q`) and `effect` tags; MDK rejects a second `sticker` tag and
  `imeta`.

Timeline records and reply previews carry the pack sticker MDK parsed, so the
app does not read pack sticker tags itself. MDK only recognizes pack stickers
in kind-9 messages. Thread messages are kind 1111, so packs are not offered
there.

## Your own stickers

MDK has no personal stickers, so these stay on this device: the images are
sealed with the vault's blob key under `stickers/`, and `stickers/library.bin`
lists them with your recent stickers. Sending one uploads it as an ordinary
encrypted image attachment tagged `["wn-sticker", plaintext_sha256, name]`, a
Linux extension. Clients without it show an ordinary image. These stickers do
not sync to your other devices.

Packs added before MDK owned the installed list were also kept in
`library.bin`. The first account to open stickers installs them through MDK
and removes them from the file. A pack that cannot be reached stays for a
later open.
