# GIF keyboard

Open the composer's emoji picker and choose **GIFs**. **Discover** shows
trending GIFs from [GifSnap](https://gifsnap.com/docs), without an API key.
Typing searches after a 300 ms pause. Search stays editable during requests.
Scroll to load more results. Only visible tiles request thumbnails, including
saved GIFs. Loading dots appear while searches and previews are pending.
GIFs that fail to load disappear. An error appears if none can load.

Hover to animate a GIF, or use Tab and the arrow keys to browse. Click a GIF
or press Enter on a focused tile to add it as an attachment. Your draft and
reply stay intact; send the message from the composer as usual. Reduced
motion disables hover playback.

The star saves a GIF to **Saved**, where it remains available offline.
Click its star again to remove it. Saved files and their index are encrypted
with your vault under `<data-dir>/gifs/`. Search text is sent to GifSnap;
saved GIF searches run locally. GifSnap is a best-effort external service.

Downloads are limited to 24 MiB and GIF canvases to 4096 pixels per side.
The picker uses the existing thumbnail worker and attachment send path.

## GIFs shared from iOS

Messages consisting of a GIPHY media URL followed by `via GIPHY` render as
looping GIFs with a clickable attribution. Downloads run in the media workers
and use the same byte and canvas limits as the picker. This contacts GIPHY
directly; no API key is needed. If loading fails, the original message stays
visible as a link. Copying or forwarding keeps the original message text.

Run the parser and storage check with:

```sh
tests/odin.sh app -define:ODIN_TEST_NAMES=gif_data
```

Run the picker, typing, and layout check with:

```sh
SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=gif_keyboard
```

Add `WN_TEST_GIF_LIVE=1` to also verify keyless search and a real GIF download.
The fixture writes screenshots under `/tmp/wn-gifs-*.png` and never sends a
message.
