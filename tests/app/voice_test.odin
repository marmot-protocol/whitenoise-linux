// Voice WAV encoding preserves the header and recorded PCM.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"
import "core:encoding/endian"

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

	count, _ := endian.get_u32(wav[40:], .Little)
	testing.expect_value(t, count, u32(VOICE_RATE * 2))
	first, _ := endian.get_u16(wav[44:], .Little)
	last, _ := endian.get_u16(wav[len(wav)-2:], .Little)
	testing.expect_value(t, first, u16(0))
	testing.expect_value(t, last, u16(30000))
}
