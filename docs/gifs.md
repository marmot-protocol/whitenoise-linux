<sub>GUIDE&ensp;·&ensp;MEDIA</sub>

# GIF keyboard

### One click sends a GIF, and your half-written draft stays exactly where it was.

The GIFs tab searches GifSnap without an API key. GIFs you star are kept encrypted for offline use.

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="../assets/docs/gifs-picker-narrow-dark.svg">
  <source media="(max-width: 600px)" srcset="../assets/docs/gifs-picker-narrow-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs/gifs-picker-dark.svg">
  <img alt="The GIFs tab sits beside Emoji and Stickers in the composer's emoji picker. It has a search field that searches GifSnap after a 300 ms pause, Discover and Saved views, and a grid of tiles; Tab and the arrow keys move focus and hover animates. Click a tile or press Enter: the GIF is sent right away, the picker closes without adding an attachment, your draft, reply and staged files stay, and a failed send can be clicked to retry. Star a tile: it is kept in Saved, available offline and sealed with your vault under data-dir/gifs/." src="../assets/docs/gifs-picker-light.svg" width="880">
</picture>

## Find a GIF

Open the composer's emoji picker and choose **GIFs**. **Discover** shows trending GIFs from [GifSnap](https://gifsnap.com/docs), without an API key.

- **Typing searches after a 300 ms pause.** Search stays editable during requests.
- **Scroll to load more results.** Only visible tiles request thumbnails, including saved GIFs. Loading dots appear while searches and previews are pending.
- **Hover to animate a GIF.** The still stays until the animation's first frame is ready. Reduced motion disables hover playback.
- **Tab and the arrow keys browse.** Focus moves from tile to tile.

## Send it with one click

Click a GIF or press Enter on a focused tile to send it immediately. The picker closes without adding a composer attachment, and your draft, reply, and other staged files stay intact.

A pending message shows preparation and sending status. Click a failed message to retry.

## Why a tile changes its picture or disappears

Some GIFs open on a black or empty frame, which makes a blank thumbnail. Such a tile loads the GIF itself and shows its brightest early frame instead.

GIFs that fail to load, or have no visible frame, disappear. An error appears if none can load.

## Keep a GIF for offline use

The star saves a GIF to **Saved**, where it remains available offline. Click its star again to remove it. Saved files and their index are encrypted with your vault under `<data-dir>/gifs/`.

## What reaches GifSnap, and the limits on what comes back

Search text is sent to GifSnap; saved GIF searches run locally. GifSnap is a best-effort external service, and results load from its media CDN.

| Limit | Value |
| --- | --- |
| Search request timeout | 30 seconds |
| Media download timeout | 10 seconds |
| Download size | 24 MiB |
| Animation canvas | 4096 pixels per side |

GIF and animated WebP messages retain their original format and loop in the timeline, including when saved offline. The picker uses the existing thumbnail worker and encrypted media send path.

## GIFs shared from iOS

Messages consisting of a GIPHY media URL followed by `via GIPHY` render as looping GIFs with a clickable attribution. This contacts GIPHY directly; no API key is needed.

- **The same limits apply.** Downloads run in the media workers and use the same byte and canvas limits as the picker.
- **A failed load leaves the link.** If loading fails, the original message stays visible as a link.
- **The text survives copying.** Copying or forwarding keeps the original message text.

<details>
<summary><b>Checks, one of which really downloads a GIF</b></summary>

Run the parser and storage check with:

```sh
tests/odin.sh app -define:ODIN_TEST_NAMES=gif_data
```

Run the picker, typing, and layout check with:

```sh
SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=gif_keyboard
```

Add `WN_TEST_GIF_LIVE=1` to also verify keyless search and a real GIF download. The fixture writes screenshots under `/tmp/wn-gifs-*.png` and never sends a message.

</details>

<sub>[Back to the README](../README.md#further-reading)</sub>
