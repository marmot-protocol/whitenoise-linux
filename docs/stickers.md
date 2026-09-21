# Stickers

Open the composer's emoji picker and choose **Stickers**. Import a static PNG,
WebP or JPEG, or preview a Nostr pack using its naddr or
`30031:<author hex>:<identifier>` coordinate. Click a tile to send it. Right-click
it (or press Tab on the selected tile) to manage its image or pack. Arrow keys
select tiles; Enter sends. The text draft stays in the composer.

Click a received sticker to save a personal image or preview and add its pack.
Pack installation stores the supported, successfully downloaded images locally.
Images are limited to 4 MiB and 4096 pixels per dimension. Animated stickers,
pack publishing, and library synchronization are outside this version.

## Message format

Stickers are ordinary encrypted image attachments with extra message tags:

- Pack: `["sticker", coordinate, shortcode, plaintext_sha256, pack_event_id]`.
- Personal: `["wn-sticker", plaintext_sha256, name]` (a Linux extension).
- Optional relay hint: `["sticker-relay", coordinate, relay_url]`.

The pack format follows the [NIP-F6 draft, revision baa8a49](https://github.com/vincenzopalazzo/nips/blob/baa8a4920ab42f65bab24d6edb955aa710f083a0/F6.md).
It uses kind 30031, `pack_format=sonar-sticker-pack-v1`, and keyed sticker
fields. This is a draft, not a finalized NIP. Signature and image hash checks
bind previewed artwork to its publisher. A relay hint is only a discovery hint.
The panel resolves the current pack; it indicates when the sent sticker is no
longer listed. Pack lookups happen when you request a preview. Chat images use
Marmot's encrypted media path, so clients without sticker support retain an
ordinary image attachment.

The library and artwork use the vault's encrypted blob store under the data
directory. Forwarding and offline retries retain the sticker reference and
effect tag. Removing a sticker or pack removes it from your library; cached
artwork can remain on disk.

## Marmot API

`patches/mdk-message-tags.patch` adds `message_tags` to media upload requests
and `send_tagged_text` for kind-9 text. Empty tags preserve existing behavior.
Additional tags are limited to 64 rows and 16 KiB; generated `imeta` references
cannot be overridden. The C ABI changes, so the build rebuilds the bundled
library and binding together. Kind-9 effects use `["effect", effect_name]` and
share the normal send, reply, thread, and offline paths.

Validation includes signed pack parsing, encrypted storage, message tags,
offline replay metadata, narrow picker/panel layouts, and Marmot event building.
Cross-client sticker rendering has not been verified.
