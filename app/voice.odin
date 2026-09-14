// Voice messages: SDL3 records the default mic into an i16 sample
// buffer (the renderer is already SDL3, no extra capture dependency),
// Send hand-rolls a WAV around it and queues it through the normal
// attachment path. Playback stays mpv (the audio tile); the WAV is
// played through the same seek bar as other audio formats.
//
//   MicBtn ──► voice_start ──► voice_poll (per frame: drain stream,
//   level)  ──► Send: wav_encode + Pending_Send ──► send worker
//          └─► Cancel: discard
package main

import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import sdl "vendor:sdl3"

import marmot "../marmot"

VOICE_RATE :: 48000 // Hz, 16-bit PCM mono

Voice_Rec :: struct {
	stream:  ^sdl.AudioStream, // nil = not recording
	samples: [dynamic]i16,
	level:   f32, // live input peak, 0..1, decays per frame
}

voice: Voice_Rec

voice_start :: proc(ui: ^Ui_State) {
	// Subsystem init is ref-counted; safe on every start.
	if !sdl.InitSubSystem({.AUDIO}) {
		ui.client_status = strings.clone("Couldn't open the microphone. Please try again.")
		return
	}
	spec := sdl.AudioSpec{format = .S16, channels = 1, freq = VOICE_RATE}
	voice.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_RECORDING, &spec, nil, nil)
	if voice.stream == nil {
		ui.client_status = strings.clone("Couldn't open the microphone. Please try again.")
		return
	}
	sdl.ResumeAudioStreamDevice(voice.stream)
	clear(&voice.samples)
	voice.level = 0
}

@(private = "file")
voice_stop :: proc() {
	if voice.stream != nil {
		sdl.DestroyAudioStream(voice.stream) // also closes its device
		voice.stream = nil
	}
}

voice_cancel :: proc() {
	voice_stop()
	clear(&voice.samples)
}

// Per frame while recording: move captured samples out of the SDL
// stream and track the peak of the new chunk as the live meter.
voice_poll :: proc() {
	if voice.stream == nil {
		return
	}
	peak: f32
	buf: [4096]i16
	for {
		got := sdl.GetAudioStreamData(voice.stream, &buf, size_of(buf))
		if got <= 0 {
			break
		}
		chunk := buf[:int(got) / 2]
		append(&voice.samples, ..chunk)
		for s in chunk {
			peak = max(peak, abs(f32(s)) / 32768)
		}
	}
	voice.level = max(peak, voice.level * 0.85)
}

// Stop, wrap the samples in a WAV, and queue it like a staged
// non-image attachment (own pending row + upload worker).
voice_send :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	voice_stop()
	if len(voice.samples) == 0 {
		return
	}
	name := fmt.aprintf("voice-%d.wav", time.time_to_unix(time.now()))
	info := profile_info(client, ui.account_ref)

	send_ticket += 1
	p := Pending_Send {
		ticket   = send_ticket,
		group_id = strings.clone(ui.chats[ui.selected].group_id),
		sender   = strings.clone(len(info.name) > 0 ? info.name : "you"),
		body     = strings.clone(name),
		thread   = strings.clone(thread_cur(ui)),
	}
	append(&p.atts, Pending_Att{name = name, media_type = "audio/wav", data = wav_encode(voice.samples[:])})
	append(&ui.pending, p)
	spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])

	clear(&voice.samples)
	ui.scroll_pending = true
}

// 44-byte canonical PCM WAV header + the samples, little-endian.
wav_encode :: proc(samples: []i16) -> []u8 {
	data_len := len(samples) * size_of(i16)
	out := make([]u8, 44 + data_len)
	copy(out, "RIFF")
	endian.put_u32(out[4:], .Little, u32(36 + data_len))
	copy(out[8:], "WAVEfmt ")
	endian.put_u32(out[16:], .Little, 16) // fmt chunk size
	endian.put_u16(out[20:], .Little, 1) // PCM
	endian.put_u16(out[22:], .Little, 1) // mono
	endian.put_u32(out[24:], .Little, VOICE_RATE)
	endian.put_u32(out[28:], .Little, VOICE_RATE * 2) // byte rate
	endian.put_u16(out[32:], .Little, 2) // block align
	endian.put_u16(out[34:], .Little, 16) // bits per sample
	copy(out[36:], "data")
	endian.put_u32(out[40:], .Little, u32(data_len))
	copy(out[44:], slice.to_bytes(samples))
	return out
}

// The recording pill, shown in place of the composer: red dot,
// elapsed time, live level meter, Cancel / Send.
VOICE_METER_W :: 120

voice_bar :: proc() {
	if clay.UI(clay.ID("VoiceBar"))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = 44})}, padding = {left = 16, right = 16, top = 8, bottom = 8}, childGap = 10, childAlignment = {y = .Center}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(22),
		border = {color = DANGER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("VoiceDot"))(
		{layout = {sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)}}, backgroundColor = DANGER, cornerRadius = rr(5)},
		) {}
		clay.Text("Recording", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
		clay.Text(fmt_clock(f64(len(voice.samples)) / VOICE_RATE), {fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM})
		if clay.UI(clay.ID("VoiceMeter"))(
		{layout = {sizing = {width = clay.SizingFixed(VOICE_METER_W), height = clay.SizingFixed(8)}, padding = {left = 1, right = 1}, childAlignment = {y = .Center}}, backgroundColor = PLATE, cornerRadius = rr(4)},
		) {
			if clay.UI(clay.ID("VoiceMeterFill"))(
			{layout = {sizing = {width = clay.SizingFixed(max(2, voice.level * (VOICE_METER_W - 2))), height = clay.SizingFixed(6)}}, backgroundColor = ACCENT, cornerRadius = rr(3)},
			) {}
		}
		if clay.UI(clay.ID("VoiceGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		action_chip("VoiceCancel", 0, "Cancel")
		action_chip("VoiceSend", 0, "Send")
	}
}
