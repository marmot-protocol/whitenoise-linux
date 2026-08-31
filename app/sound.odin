// Interface sounds: three short tones, synthesized rather than shipped.
// A send, an arrival and a failure are the only moments worth a sound,
// and each is a sine sweep under an envelope, so the whole feature is a
// few hundred samples of arithmetic and no asset files.
//
// This is the one place in `app` that talks to SDL directly instead of
// going through the sdlrl shim: the device, the synthesis and the
// policy are one small thing, and splitting them across two layers
// would be more code than the feature.
//
// On by default (`prefs.ui_sounds`), and one toggle turns the set
// off. The notification sound is a
// separate, system-level thing (notify.odin).
package main

import rl "sdlrl"
import sdl "vendor:sdl3"

SND_RATE :: 48000
SND_MAX :: 12000 // 250ms, the longest tone here
SND_VOL :: f32(0.10)

Sound :: enum {
	Send,
	Receive,
	Error,
	Pop, // something opened under the pointer
}

// (start hz, end hz, seconds, square) per sound. A sweep up leaves, a
// sweep down arrives, and the failure buzzes low.
SOUNDS := [Sound]struct {
	from, to: f32,
	secs:     f32,
	square:   bool,
} {
	.Send    = {620, 990, 0.09, false},
	.Receive = {990, 740, 0.13, false},
	.Error   = {200, 150, 0.18, true},
	.Pop     = {1180, 1480, 0.05, false},
}

snd_stream: ^sdl.AudioStream
snd_failed: bool // one failed open is enough; don't retry every click

SND_GAP :: 0.25 // shortest time between two of the same tone

// When each sound last played: a page of arrivals landing at once must
// not fire one tone per row.
snd_last: [Sound]f64

// Opened on the first sound played, not at boot: a user who never turns
// the toggle on never touches an audio device.
@(private = "file")
snd_open :: proc() -> bool {
	if snd_stream != nil {
		return true
	}
	if snd_failed || !sdl.InitSubSystem({.AUDIO}) {
		snd_failed = true
		return false
	}
	spec := sdl.AudioSpec {
		format   = .F32,
		channels = 1,
		freq     = SND_RATE,
	}
	snd_stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if snd_stream == nil {
		snd_failed = true
		return false
	}
	sdl.ResumeAudioStreamDevice(snd_stream)
	return true
}

play_sound :: proc(kind: Sound) {
	if g_prefs == nil || !g_prefs.ui_sounds || !snd_open() {
		return
	}
	now := rl.GetTime()
	if now - snd_last[kind] < SND_GAP {
		return
	}
	snd_last[kind] = now

	tone := SOUNDS[kind]
	count := min(int(tone.secs * SND_RATE), SND_MAX)

	buffer: [SND_MAX]f32
	phase := f64(0)
	for i in 0 ..< count {
		t := f32(i) / f32(count)
		// Attack over the first 4% kills the click; the rest decays
		// away so the tone never ends on a step either.
		env := min(t * 25, 1) * (1 - t) * (1 - t)
		hz := tone.from + (tone.to - tone.from) * t
		phase += f64(hz) * 2 * 3.14159265 / SND_RATE
		sample := sin_approx(phase)
		if tone.square {
			sample = sample > 0 ? 0.6 : -0.6
		}
		buffer[i] = sample * env * SND_VOL
	}
	sdl.PutAudioStreamData(snd_stream, &buffer, i32(count * size_of(f32)))
}
