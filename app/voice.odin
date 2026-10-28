// Voice messages: SDL3 records the default mic into an i16 sample
// buffer (the renderer is already SDL3, no extra capture dependency),
// Send hand-rolls a WAV around it and queues it through the normal
// attachment path. Playback stays mpv (the audio tile); the WAV is
// played through the same seek bar as other audio formats.
//
//   MicBtn ──► voice_start ──► worker opens mic ──► voice_poll
//   (per frame: adopt stream, drain, level) ──► Send: WAV + send worker
//          └─► Cancel: discard
package main

import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import sdl "vendor:sdl3"

import marmot "../marmot"

VOICE_RATE :: 48000 // Hz, 16-bit PCM mono

Voice_Rec :: struct {
	starting: ^Voice_Start,
	stream:   ^sdl.AudioStream, // nil = not recording
	samples:  [dynamic]i16,
	level:    f32, // live input peak, 0..1, decays per frame
}

@(private = "file")
Voice_Start :: struct {
	mutex:           sync.Mutex,
	done, cancelled: bool,
	stream:          ^sdl.AudioStream,
}

voice: Voice_Rec

@(private)
voice_active :: proc() -> bool {
	return voice.starting != nil || voice.stream != nil
}

@(private = "file")
voice_close :: proc(stream: ^sdl.AudioStream) {
	if stream == nil {
		return
	}
	sdl.DestroyAudioStream(stream) // also closes its device
	sdl.QuitSubSystem({.AUDIO})
}

@(private = "file")
voice_worker :: proc(job: ^Voice_Start) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	sync.lock(&job.mutex)
	cancelled := job.cancelled
	sync.unlock(&job.mutex)
	if cancelled {
		free(job)
		return
	}
	// Init and device discovery can block indefinitely without a capture service.
	// Only this worker owns the stream until the frame loop adopts its result.
	stream: ^sdl.AudioStream
	if sdl.InitSubSystem({.AUDIO}) {
		spec := sdl.AudioSpec {
			format   = .S16,
			channels = 1,
			freq     = VOICE_RATE,
		}
		stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_RECORDING, &spec, nil, nil)
		if stream == nil {
			sdl.QuitSubSystem({.AUDIO})
		} else if !sdl.ResumeAudioStreamDevice(stream) {
			voice_close(stream)
			stream = nil
		}
	}
	sync.lock(&job.mutex)
	if !job.cancelled {
		job.stream = stream
		job.done = true
		sync.unlock(&job.mutex)
		return
	}
	sync.unlock(&job.mutex)
	// Cancel detached this job. A late success must never start a new recording.
	voice_close(stream)
	free(job)
}

voice_start :: proc(ui: ^Ui_State) {
	if voice_active() {
		return
	}
	clear(&voice.samples)
	voice.level = 0
	voice.starting = new(Voice_Start)
	append(&send_threads, thread.create_and_start_with_poly_data(voice.starting, voice_worker))
}

@(private = "file")
voice_stop :: proc() {
	if job := voice.starting; job != nil {
		voice.starting = nil
		sync.lock(&job.mutex)
		job.cancelled = true
		done, stream := job.done, job.stream
		sync.unlock(&job.mutex)
		if done {
			voice_close(stream)
			free(job)
		}
		// Otherwise the worker will free the detached job and its eventual stream.
	}
	if voice.stream != nil {
		voice_close(voice.stream)
		voice.stream = nil
	}
}

voice_cancel :: proc() {
	voice_stop()
	clear(&voice.samples)
}

// Per frame: adopt completed startup on the UI thread, then move captured
// samples out of the SDL stream and track their peak as the live meter.
voice_poll :: proc() {
	if job := voice.starting; job != nil {
		sync.lock(&job.mutex)
		done, stream := job.done, job.stream
		sync.unlock(&job.mutex)
		if !done {
			return
		}
		voice.starting = nil
		voice.stream = stream
		free(job)
		if stream == nil {
			set_status(
				g_ui,
				strings.clone(tr("Couldn't open the microphone. Please try again.")),
				.Error,
			)
		}
	}
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
	if voice.stream == nil {
		return
	}
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
		issue    = issue_reply(ui),
	}
	append(
		&p.atts,
		Pending_Att{name = name, media_type = "audio/wav", data = wav_encode(voice.samples[:])},
	)
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

// Starting keeps Cancel reachable while SDL opens the microphone.
// Once recording, the meter yields width to the elapsed time and actions.
VOICE_METER_W :: 120

voice_bar :: proc() {
	starting := voice.starting != nil
	phone := single_pane()
	if clay.UI(clay.ID("VoiceBar"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = 44})},
			padding = {left = phone ? 12 : 16, right = phone ? 12 : 16, top = 8, bottom = 8},
			childGap = phone ? 6 : 10,
			layoutDirection = starting ? .TopToBottom : .LeftToRight,
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(22),
		border = {color = DANGER, width = bw()},
	},
	) {
		if starting {
			if clay.UI(clay.ID("VoiceStartingRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("VoiceStartingLabel"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {
					clay.Text(
						tr("Starting microphone…"),
						{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
					)
				}
				action_chip("VoiceCancel", 0, tr("Cancel"))
			}
			busy_bar("VoiceStartBusy")
			return
		}
		if clay.UI(clay.ID("VoiceDot"))(
		{
			layout = {sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)}},
			backgroundColor = DANGER,
			cornerRadius = rr(5),
		},
		) {}
		if !phone {
			clay.Text(tr("Recording"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
		}
		clay.Text(
			fmt_clock(f64(len(voice.samples)) / VOICE_RATE),
			{fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM},
		)
		if clay.UI(clay.ID("VoiceMeter"))(
		{
			layout = {
				sizing = {
					width = clay.SizingGrow({max = VOICE_METER_W}),
					height = clay.SizingFixed(8),
				},
				padding = {left = 1, right = 1},
				childAlignment = {y = .Center},
			},
			backgroundColor = PLATE,
			cornerRadius = rr(4),
		},
		) {
			if clay.UI(clay.ID("VoiceMeterFill"))(
			{
				layout = {
					sizing = {
						width = clay.SizingPercent(max(0.02, voice.level)),
						height = clay.SizingFixed(6),
					},
				},
				backgroundColor = ACCENT,
				cornerRadius = rr(3),
			},
			) {}
		}
		if !phone {
			if clay.UI(clay.ID("VoiceGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		}
		action_chip("VoiceCancel", 0, tr("Cancel"))
		action_chip("VoiceSend", 0, tr("Send"))
	}
}
