# Dictation

Enable **Speech to text** in Settings > Speech, then choose **Dictate** beside
the composer's microphone button. Wait for **Listening**, speak, then choose
**Finish dictation** (Enter). The recognized text is appended to your draft
for review; it is never sent automatically. **Cancel** (Escape)
stops downloads, recording or recognition. The existing microphone button
still records voice messages.

Choose **Transcription model** in Settings > Speech: Tiny (104 MB, default), Base
(161 MB), Small (375 MB), Medium (946 MB), Large v3 (1.78 GB), or Turbo
(1.04 GB). Non-Whisper options are Parakeet TDT v3 (670 MB) and SenseVoice
Small (240 MB). Selecting a model downloads it immediately, with a progress bar
and **Cancel** button. Downloaded models are marked in the list. The selected
model is used for both dictation and audio messages. Completed transcripts are cached separately for each audio file and model
revision. Switching models restores that model’s cached transcript, if available.

Downloads are checked against pinned SHA-256 hashes before loading.
Interrupted downloads restart on retry; completed files are reused. Each
model is cached separately under `<data-dir>/stt/<model-revision>/`.
The revisions and checksums are listed in `app/stt_models.h`.

Speech recognition runs locally through the same sherpa-onnx CPU runtime as
read aloud. Language is detected automatically. Audio and partial text stay in memory, outside logs and command arguments.
Completed audio transcripts are encrypted before caching. Only model downloads
contact the model host. Switching accounts, chats or threads, changing the
draft, leaving Chats, disabling dictation or closing the app cancels it.

Audio messages have a **Transcribe** button that becomes **Transcribing...**
while busy, with a separate **Cancel** button. Completed transcripts have
**View transcription** and **Collapse transcription** controls.
Progress stays in the audio card so starting transcription does not move the chat. Recognized segments appear below the player as they finish, while the
remaining audio is still being transcribed. Cancel keeps text already shown. WAV and MP3 use the same player controls.
Other formats use the same decoder as playback. Completed transcripts are stored in the encrypted media cache and restored
collapsed. Clearing the media cache removes them. Partial transcripts stay
in memory and are never cached; transcripts are never sent as messages.
Audio files are limited to 100 MB and ten minutes. Recognition uses windows
of at most 29 seconds; words spanning a window boundary may be misrecognized.
The current runtime returns whole segments, so updates are not word by word.
Dictation also appends each completed segment after recording ends.

Each microphone recording ends automatically after 30 seconds, Whisper's context limit.
Recognition starts after recording ends. Accuracy depends on language,
background noise and microphone quality; review the draft before sending.

## Non-Whisper models

[Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
by NVIDIA, supports Bulgarian, Croatian, Czech, Danish, Dutch, English,
Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian,
Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian,
Spanish, Swedish, Russian and Ukrainian. The weights use
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
The app downloads Fangjun Kuang's int8 ONNX conversion.

[SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall),
by FunAudioLLM, supports Chinese, English, Japanese, Korean and Cantonese.
The weights use [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0).
The app downloads Fangjun Kuang's int8 ONNX conversion.

Both use the same local runtime, segment updates, encrypted transcript cache
and download verification as Whisper. Language coverage differs between
models; their sizes alone do not establish transcription quality.

## Whisper model and license

Whisper multilingual int8 exports (Tiny, Base, Small, Medium, Large v3 and Turbo),
exported by Fangjun Kuang from [OpenAI Whisper](https://github.com/openai/whisper).
The Whisper code and model weights are MIT licensed. Runtime notices are
listed in `tts.md`.

MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Checks

```sh
SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=stt_draft_safety
SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=stt_layout
build/stt-test <model-cache> <audio-file> <expected-lowercase-substring> [tiny|base|small|medium|large-v3|turbo|parakeet-v3|sensevoice]
```

The optional C check downloads and verifies the pinned files, performs real
recognition, and checks the transcript. The Odin check exercises completion,
cancellation, draft isolation and audio-attachment routing without accessing a microphone.

## CPU performance check

The helper uses up to eight available logical CPUs. Model checksums use
OpenSSL SHA-256 (also linked by curl); cached files are still verified before
loading. No GPU provider is enabled.

Measured on an AMD Ryzen AI MAX+ 395, using one 6.62-second English clip,
with model files already downloaded and filesystem caches warm. Decode
figures are medians of three runs with a loaded recognizer. Verification
and loading are single startup measurements; they are additional costs.

| Model / configuration | Verify | Load | Median decode |
| --- | ---: | ---: | ---: |
| Whisper Medium, previous two-thread helper | 1.57 s | 2.36 s | 4.11 s |
| Whisper Medium, eight threads + OpenSSL | 0.49 s | 2.09 s | 3.30 s |
| Parakeet TDT v3, eight threads + OpenSSL | 0.34 s | 0.95 s | 0.125 s |
| SenseVoice Small, eight threads + OpenSSL | 0.12 s | 0.49 s | 0.063 s |

The thread sweep for Medium gave decode medians of 4.11, 3.64, 3.38 and
3.41 seconds at 2, 4, 8 and 16 threads, respectively. These are measurements
of this clip and machine, not quality scores or guarantees for other audio.
Each uncached transcript still loads its model in a fresh, cancellable helper.
Completed transcript cache hits skip inference entirely.

To repeat with a mono 16 kHz PCM16 WAV:

```sh
cc -O2 -Ivendor/sherpa-onnx/include scripts/stt-bench.c \
  -Lvendor/sherpa-onnx/lib -lsherpa-onnx-c-api \
  -Wl,-rpath,'$ORIGIN/tts-lib' \
  $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 mpv libcrypto) \
  -lm -o build/stt-bench
build/stt-bench <model-cache> <audio.wav> medium 8
```
