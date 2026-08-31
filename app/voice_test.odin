// Voice WAV round trip: what the recorder encodes, the waveform
// parser must bucket back.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
voice_wav_round_trip :: proc(t: ^testing.T) {
	// One second: silent first half, full-scale square second half.
	clear(&voice.samples)
	defer delete(voice.samples)
	for i in 0 ..< VOICE_RATE {
		append(&voice.samples, i16(i < VOICE_RATE / 2 ? 0 : 30000))
	}
	wav := wav_encode(voice.samples[:])
	defer delete(wav)
	testing.expect_value(t, len(wav), 44 + VOICE_RATE * 2)
	testing.expect_value(t, string(wav[:4]), "RIFF")

	bars := wav_bars(wav)
	defer delete(bars)
	testing.expect_value(t, len(bars), VOICE_BARS)
	testing.expect_value(t, bars[0], 0)
	testing.expect_value(t, bars[VOICE_BARS - 1], 1) // normalized peak

	// Garbage stays nil (the tile falls back to the plain bar).
	testing.expect_value(t, len(wav_bars(wav[:20])), 0)
}
