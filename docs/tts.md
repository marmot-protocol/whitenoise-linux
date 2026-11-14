<sub>GUIDE&ensp;·&ensp;SPEECH</sub>

# Read aloud

### One 145 MB download gives you ten voices that read 31 languages, Chinese not among them.

Read aloud speaks messages with a local Supertonic 3 model. No message text is sent to the model host or written to logs.

## Turn it on and pick a voice

Enable **Read aloud** in Settings > Speech. Each voice has a row with its selection state, description, download status and **Preview** button.

- **Preview does three things at once.** It selects that voice, downloads any missing files, and reads a sample in your app's language (English if unsupported).
- **Stop reading cancels whatever is running.** That covers downloads, preparation or playback.
- **The voice IDs follow the upstream sorted order.** F1–F5, then M1–M5.

## One download serves every voice

The first request downloads about 145 MB. One Supertonic 3 model and voice pack serve all ten voices and 31 languages.

- **Progress shows in two places.** The model row shows aggregate download progress; voice rows show the shared voice pack's status.
- **Files are verified at 100%.** Downloaded files are checked against pinned SHA-256 hashes before being made available.
- **Retry with Preview.** Failed downloads can be retried with Preview, and interrupted partial files are replaced on retry.
- **Models live under `<data-dir>/tts/<model-revision>/`.**

## Which language a message is read in

The model supports English, Japanese, Korean, Arabic, Bulgarian, Czech, Danish, German, Greek, Spanish, Estonian, Finnish, French, Hindi, Croatian, Hungarian, Indonesian, Italian, Lithuanian, Latvian, Dutch, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Swedish, Turkish, Ukrainian and Vietnamese. Chinese is not supported by this model.

| Text | Reading language |
| --- | --- |
| Japanese kana, even mixed with Latin text | Japanese |
| Only kanji, app language Japanese | Japanese |
| Anything else | Your app's language, else English |

This does not detect different languages that share the Latin alphabet. Mixed-language sentences use one reading language, not independent detection for each word.

## What stays on your machine

Messages and audio stay in memory. A separate helper runs CPU inference through sherpa-onnx and ONNX Runtime.

- **Long messages are read in pieces.** They are split at sentence boundaries, with a 240-byte ceiling that preserves UTF-8, and generation overlaps playback.
- **Messages over 1 MiB are rejected.** They are not truncated.
- **The helper stops with speech.** Turning speech off, switching accounts or closing the app stops the helper.

## Dependencies and licenses

- [Supertonic 3](https://huggingface.co/Supertone/supertonic-3), Supertone Inc., MIT. This build uses the [sherpa-onnx int8 export](https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11) at `cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4`.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache-2.0, v1.13.7, source revision `917bed95c8e5c7c18aa4d69fea42e9ef8ef0a60e`.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime), MIT, distributed with the pinned speech runtime. It executes the multilingual model locally without adding Python or a service.

The downloaded model includes its MIT license.

- **Runtime binaries, headers and notices are checksum-pinned in `DEPS_PIN`.** They are staged by `scripts/build-tts.sh`; Linux x86-64 and aarch64 packages are selected by host architecture.
- **`install-tree.sh` puts them in place.** It installs the shared libraries under `lib/whitenoise-linux/tts-lib/` and the notices under `share/whitenoise-linux/licenses/`.

<details>
<summary><b>Checks for read aloud</b></summary>

```sh
SDL_VIDEODRIVER=dummy just test
SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=tts_layout
```

</details>
