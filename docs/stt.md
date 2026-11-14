<sub>GUIDE&ensp;·&ensp;SPEECH</sub>

# Dictation

### Speak into the composer, and the words wait in your draft until you choose to send them.

Dictation and audio transcription run on your CPU with a model you pick. Only the model download contacts the model host.

## Dictate into a draft

Enable **Speech to text** in Settings > Speech, then:

1. Choose **Dictate** beside the composer's microphone button.
2. Wait for **Listening**, then speak.
3. Choose **Finish dictation** (Enter).

The recognized text is appended to your draft for review; it is never sent automatically. The existing microphone button still records voice messages.

- **Cancel (Escape) stops whatever is running.** That covers downloads, recording and recognition.
- **Each recording ends automatically after 30 seconds.** That is Whisper's context limit. Recognition starts after recording ends.
- **Text arrives a segment at a time.** Dictation appends each completed segment after recording ends.
- **Moving away cancels it.** Switching accounts, chats or threads, changing the draft, leaving Chats, disabling dictation or closing the app all cancel dictation.

Accuracy depends on language, background noise and microphone quality, so review the draft before sending.

## Transcribe an audio message

Audio messages have a **Transcribe** button that becomes **Transcribing...** while busy, with a separate **Cancel** button. Progress stays in the audio card, so starting transcription does not move the chat.

- **Segments appear as they finish.** Recognized text shows up below the player while the remaining audio is still being transcribed. The current runtime returns whole segments, so updates are not word by word.
- **Cancel keeps text already shown.** Partial transcripts stay in memory and are never cached.
- **Finished transcripts fold away.** They get **View transcription** and **Collapse transcription** controls, are stored in the encrypted media cache, and come back collapsed. Clearing the media cache removes them.
- **Transcripts stay yours.** They are never sent as messages.
- **Every format gets the same treatment.** WAV and MP3 use the same player controls. Other formats use the same decoder as playback.

| Limit | Value |
| --- | --- |
| Audio file size | 100 MB |
| Audio file length | Ten minutes |
| Recognition window | At most 29 seconds; words spanning a window boundary may be misrecognized |

## Which transcription model to pick

Choose **Transcription model** in Settings > Speech. The selected model is used for both dictation and audio messages.

| Model | Family | Download | Languages |
| --- | --- | ---: | --- |
| Tiny (default) | Whisper | 104 MB | Multilingual |
| Base | Whisper | 161 MB | Multilingual |
| Small | Whisper | 375 MB | Multilingual |
| Medium | Whisper | 946 MB | Multilingual |
| Large v3 | Whisper | 1.78 GB | Multilingual |
| Turbo | Whisper | 1.04 GB | Multilingual |
| Parakeet TDT v3 | NVIDIA | 670 MB | 25, listed below |
| SenseVoice Small | FunAudioLLM | 240 MB | 5, listed below |

- **Selecting a model downloads it immediately.** A progress bar and **Cancel** button show while it runs, and downloaded models are marked in the list.
- **Each model keeps its own transcripts.** Completed transcripts are cached separately for each audio file and model revision. Switching models restores that model's cached transcript, if available.
- **Language is detected automatically.** Coverage differs between models, and their sizes alone do not establish transcription quality.

## What leaves your machine, and what never does

Speech recognition runs locally through the same sherpa-onnx CPU runtime as read aloud. Only model downloads contact the model host.

- **Audio and partial text stay in memory.** They are kept out of logs and command arguments.
- **Completed audio transcripts are encrypted before caching.**
- **Downloads are checked before loading.** Each file must match a pinned SHA-256 hash. Interrupted downloads restart on retry; completed files are reused.
- **Each model has its own folder.** Models are cached under `<data-dir>/stt/<model-revision>/`. The revisions and checksums are listed in `app/stt_models.h`.

## Non-Whisper models

[Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), by NVIDIA, supports Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian and Ukrainian. The weights use [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The app downloads Fangjun Kuang's int8 ONNX conversion.

[SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall), by FunAudioLLM, supports Chinese, English, Japanese, Korean and Cantonese. The weights use [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0). The app downloads Fangjun Kuang's int8 ONNX conversion.

Both use the same local runtime, segment updates, encrypted transcript cache and download verification as Whisper.

## Whisper model and license

Whisper multilingual int8 exports (Tiny, Base, Small, Medium, Large v3 and Turbo), exported by Fangjun Kuang from [OpenAI Whisper](https://github.com/openai/whisper). The Whisper code and model weights are MIT licensed. Runtime notices are listed in `tts.md`.

```text
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
```

## How long each model takes on one 6.62-second clip

Measured on an AMD Ryzen AI MAX+ 395, with model files already downloaded and filesystem caches warm. Verification and loading are additional startup costs.

| Model / configuration | Verify | Load | Median decode |
| --- | ---: | ---: | ---: |
| Whisper Medium, previous two-thread helper | 1.57 s | 2.36 s | 4.11 s |
| Whisper Medium, eight threads + OpenSSL | 0.49 s | 2.09 s | 3.30 s |
| Parakeet TDT v3, eight threads + OpenSSL | 0.34 s | 0.95 s | 0.125 s |
| SenseVoice Small, eight threads + OpenSSL | 0.12 s | 0.49 s | 0.063 s |

These are measurements of this clip and machine, not quality scores or guarantees for other audio. Completed transcript cache hits skip inference entirely.

<details>
<summary><b>Where the numbers come from, and how to repeat them</b></summary>

The helper uses up to eight available logical CPUs. Model checksums use OpenSSL SHA-256 (also linked by curl); cached files are still verified before loading. No GPU provider is enabled.

The clip is one English recording. Decode figures are medians of three runs with a loaded recognizer. Verification and loading are single startup measurements.

The thread sweep for Medium gave these decode medians:

| Threads | 2 | 4 | 8 | 16 |
| --- | ---: | ---: | ---: | ---: |
| Median decode | 4.11 s | 3.64 s | 3.38 s | 3.41 s |

Each uncached transcript still loads its model in a fresh, cancellable helper.

To repeat with a mono 16 kHz PCM16 WAV:

```sh
cc -O2 -Ivendor/sherpa-onnx/include scripts/stt-bench.c \
  -Lvendor/sherpa-onnx/lib -lsherpa-onnx-c-api \
  -Wl,-rpath,'$ORIGIN/tts-lib' \
  $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 mpv libcrypto) \
  -lm -o build/stt-bench
build/stt-bench <model-cache> <audio.wav> medium 8
```

</details>

<details>
<summary><b>Checks that never touch a microphone</b></summary>

```sh
SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=stt_draft_safety
SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=stt_layout
build/stt-test <model-cache> <audio-file> <expected-lowercase-substring> [tiny|base|small|medium|large-v3|turbo|parakeet-v3|sensevoice]
```

The Odin check exercises completion, cancellation, draft isolation and audio-attachment routing without accessing a microphone. The optional C check downloads and verifies the pinned files, performs real recognition, and checks the transcript.

</details>
