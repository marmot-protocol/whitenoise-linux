# Read aloud

Enable **Read aloud** in Settings > Speech. Each voice has a row with its
selection state, description, download status and **Preview** button. Preview
selects that voice, downloads any missing files, and reads a sample in your
app's language (English if unsupported). **Stop reading** cancels downloads, preparation or playback.

The first request downloads about 145 MB. One Supertonic 3 model and voice pack
serve all ten voices and 31 languages. The model row shows aggregate download
progress; voice rows show the shared voice pack's status. At 100%, downloaded
files are verified against pinned SHA-256 hashes before being made available.
Failed downloads can be retried with Preview. Interrupted partial files are
replaced on retry. Models live under `<data-dir>/tts/<model-revision>/`.

Japanese kana are always recognized, including Japanese mixed with Latin text.
Other text uses your app's language, falling back to English. This does not
detect different languages that share the Latin alphabet. Text consisting only
of kanji uses Japanese when your app language is Japanese. Mixed-language
sentences use one reading language, not independent detection for each word.

The model supports English, Japanese, Korean, Arabic, Bulgarian, Czech, Danish,
German, Greek, Spanish, Estonian, Finnish, French, Hindi, Croatian, Hungarian,
Indonesian, Italian, Lithuanian, Latvian, Dutch, Polish, Portuguese, Romanian,
Russian, Slovak, Slovenian, Swedish, Turkish, Ukrainian and Vietnamese.
Chinese is not supported by this model.

Messages and audio stay in memory. No message text is sent to the model host
or written to logs. A separate helper runs CPU inference through sherpa-onnx
and ONNX Runtime. Long messages are split at sentence boundaries, with a
240-byte ceiling that preserves UTF-8, and generation overlaps playback.
Messages over 1 MiB are rejected rather than truncated. Turning speech off,
switching accounts or closing the app stops the helper.

## Dependencies and licenses

- [Supertonic 3](https://huggingface.co/Supertone/supertonic-3), Supertone Inc.,
  MIT. This build uses the [sherpa-onnx int8 export](https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11)
  at `cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4`.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache-2.0, v1.13.7,
  source revision `917bed95c8e5c7c18aa4d69fea42e9ef8ef0a60e`.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime), MIT, distributed
  with the pinned speech runtime. It executes the multilingual model locally
  without adding Python or a service.

Runtime binaries, headers and notices are checksum-pinned by
`scripts/build-tts.sh`. Linux x86-64 and aarch64 packages are selected by host
architecture. `install-tree.sh` installs the shared libraries and notices under
`share/whitenoise-linux/`. The downloaded model includes its MIT license.
The voice IDs follow the upstream sorted order: F1–F5, then M1–M5.

## Checks

```sh
SDL_VIDEODRIVER=dummy ./build.sh test
SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=tts_layout
```
