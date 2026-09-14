# Dictation

Enable **Dictation** in Settings > Speech, then choose **Dictate** beside
the composer's microphone button. Wait for **Listening**, speak, then choose
**Finish dictation** (Enter). The recognized text is appended to your draft
for review; it is never sent automatically. **Cancel dictation** (Escape)
stops downloads, recording or recognition. The existing microphone button
still records voice messages.

The first use downloads about 104 MB of multilingual Whisper tiny int8 models
and vocabulary. Download progress is shown, and SHA-256 is checked before
loading. Interrupted downloads restart on retry. Files are cached under
`<data-dir>/stt/65176e2deb88badc814a94058666cadccc29b61c/`.

Speech recognition runs locally through the same sherpa-onnx CPU runtime as
read aloud. Language is detected automatically. Audio and recognized text
stay in memory, outside logs and command arguments. Only model downloads
contact the model host. Switching accounts, chats or threads, changing the
draft, leaving Chats, disabling dictation or closing the app cancels it.

Each recording ends automatically after 30 seconds, Whisper's context limit.
Recognition starts after recording ends. Accuracy depends on language,
background noise and microphone quality; review the draft before sending.

## Model and license

[Whisper tiny int8 export](https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/tree/65176e2deb88badc814a94058666cadccc29b61c),
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
build/stt-test <model-cache> <16kHz-mono-wav> <expected-lowercase-substring>
```

The optional C check downloads and verifies the pinned files, performs real
recognition, and checks the transcript. The Odin check exercises completion,
cancellation and draft isolation without accessing a microphone.
