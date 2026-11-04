// .nes attachments: a cartridge tile in the timeline and a player modal.
// The cartridge runs in the wn-nes helper (nes-decoder/), one session per
// game; the UI sends the pad each emulated frame and gets back palette
// indices plus 48 kHz audio, which it colors and queues here.
//
//   nes_tick (frame loop) --pad--> wn-nes --frame + samples--> tex, audio
package main

import "core:c"
import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

ICON_GAMEPAD :: "\uf11b"

NES_W :: 256
NES_H :: 240
NES_ROM_MAX :: 8 * 1024 * 1024 // matches nes-decoder/main.odin
NES_RATE :: 48000
NES_FRAME_BYTES :: NES_W * NES_H
NES_REPLY_MAX :: NES_FRAME_BYTES + 1024 * 2 // pixels + at most 1024 i16 samples
NES_FRAME_SECS :: 1 / 60.0988 // NTSC
NES_STEPS_MAX :: 4 // frames emulated per UI frame before giving up on catching up

// Audio queue watermarks, in bytes of i16 mono (one frame is ~1600). A
// hungry device pulls the next frame early, so the game locks to the
// audio clock; a device that stopped consuming is cleared instead of
// letting latency grow.
NES_AUDIO_LOW :: 1600
NES_AUDIO_HIGH :: 8 * 1600

// Room the modal keeps around the screen, in layout units: padding
// either side, plus the title bar above and the key hint below.
NES_MARGIN :: 48
NES_CHROME :: 80

@(private = "file")
NES_OPEN :: 0
@(private = "file")
NES_STEP :: 1

// 2C02 master palette, 0xRRGGBB.
@(private = "file")
NES_PALETTE := [64]u32 {
	0x666666,
	0x002a88,
	0x1412a7,
	0x3b00a4,
	0x5c007e,
	0x6e0040,
	0x6c0600,
	0x561d00,
	0x333500,
	0x0b4800,
	0x005200,
	0x004f08,
	0x00404d,
	0x000000,
	0x000000,
	0x000000,
	0xadadad,
	0x155fd9,
	0x4240ff,
	0x7527fe,
	0xa01acc,
	0xb71e7b,
	0xb53120,
	0x994e00,
	0x6b6d00,
	0x388700,
	0x0c9300,
	0x008f32,
	0x007c8d,
	0x000000,
	0x000000,
	0x000000,
	0xfffeff,
	0x64b0ff,
	0x9290ff,
	0xc676ff,
	0xf36aff,
	0xfe6ecc,
	0xfe8170,
	0xea9e22,
	0xbcbe00,
	0x88d800,
	0x5ce430,
	0x45e082,
	0x48cdde,
	0x4f4f4f,
	0x000000,
	0x000000,
	0xfffeff,
	0xc0dfff,
	0xd3d2ff,
	0xe8c8ff,
	0xfbc2ff,
	0xfec4ea,
	0xfeccc5,
	0xf7d8a5,
	0xe4e594,
	0xcfef96,
	0xbdf4ab,
	0xb3f3cc,
	0xb5ebf2,
	0xb8b8b8,
	0x000000,
	0x000000,
}

// Controller bits in the order the console shifts them out:
// A, B, Select, Start, Up, Down, Left, Right.
@(private = "file")
NES_KEYS := [8][2]rl.KeyboardKey {
	{.X, .X},
	{.Z, .Z},
	{.LEFT_SHIFT, .RIGHT_SHIFT},
	{.ENTER, .ENTER},
	{.UP, .UP},
	{.DOWN, .DOWN},
	{.LEFT, .LEFT},
	{.RIGHT, .RIGHT},
}

// The worker's cartridge bytes, kept so Play starts without a fetch.
Nes_View :: struct {
	rom: []u8,
}

Nes_Player :: struct {
	session: rawptr, // wn_model_* session running the cartridge
	audio:   ^sdl.AudioStream, // nil = no audio device; the game runs silent
	tex:     rl.Texture2D,
	reply:   []u8, // NES_REPLY_MAX scratch each frame lands in
	rgba:    []u8,
	title:   string,
	lag:     f64, // seconds of emulation owed to the wall clock
	open:    bool,
}

nes_player: Nes_Player

// The Play button under the pointer, rebound every build like xdc_hover.
Nes_Hover :: struct {
	view: ^Nes_View,
	name: string,
}
nes_hover: Nes_Hover

is_nes_name :: proc(lower: string) -> bool {
	return strings.has_suffix(lower, ".nes")
}

// data ownership transfers to the view. nil = no iNES header, and the
// caller falls back to the plain file chip.
nes_view_make :: proc(data: []u8) -> ^Nes_View {
	if len(data) < 16 || len(data) > NES_ROM_MAX || string(data[:4]) != "NES\x1a" {
		return nil
	}
	view := new(Nes_View)
	view.rom = data
	return view
}

// Starts the cartridge and opens the modal in the same frame as the
// click; a ROM the helper rejects never opens it.
nes_play :: proc(ui: ^Ui_State, view: ^Nes_View, title: string) {
	nes_close()
	helper := strings.clone_to_cstring(helper_path("wn-nes"), context.temp_allocator)
	session := wn_model_start(helper)
	reply := make([]u8, NES_REPLY_MAX)
	length: u32
	if session == nil ||
	   wn_model_exchange(
		   session,
		   NES_OPEN,
		   raw_data(view.rom),
		   u32(len(view.rom)),
		   raw_data(reply),
		   u32(len(reply)),
		   &length,
	   ) ==
		   nil {
		if session != nil {
			wn_model_close(session)
		}
		delete(reply)
		set_status(
			ui,
			fmt.aprintf(tr("Couldn't start %s. Its cartridge type isn't supported."), title),
			.Error,
		)
		return
	}

	tex := rl.CreateStreamTexture(NES_W, NES_H)
	rl.SetTextureFilter(tex, .POINT)
	nes_player = {
		session = session,
		audio   = nes_audio_open(),
		tex     = tex,
		reply   = reply,
		rgba    = make([]u8, NES_FRAME_BYTES * 4),
		title   = strings.clone(title),
		lag     = NES_FRAME_SECS,
		open    = true,
	}
}

// A separate stream from the UI sounds: SDL mixes the two logical
// devices, while a shared stream would queue them back to back.
@(private = "file")
nes_audio_open :: proc() -> ^sdl.AudioStream {
	if !sdl.InitSubSystem({.AUDIO}) {
		return nil
	}
	spec := sdl.AudioSpec {
		format   = .S16LE,
		channels = 1,
		freq     = NES_RATE,
	}
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if stream != nil {
		sdl.ResumeAudioStreamDevice(stream)
	}
	return stream
}

nes_close :: proc() {
	if !nes_player.open {
		return
	}
	if nes_player.session != nil {
		wn_model_close(nes_player.session)
	}
	if nes_player.audio != nil {
		sdl.DestroyAudioStream(nes_player.audio)
	}
	rl.UnloadTexture(nes_player.tex)
	delete(nes_player.reply)
	delete(nes_player.rgba)
	delete(nes_player.title)
	nes_player = {}
}

// Frame-loop step: emulate the frames the clock owes, then show the
// newest one. A failed exchange means the helper died or misbehaved.
nes_tick :: proc(ui: ^Ui_State) {
	p := &nes_player
	if !p.open {
		return
	}
	p.lag += f64(rl.GetFrameTime())
	if p.audio != nil {
		queued := sdl.GetAudioStreamQueued(p.audio)
		if queued < NES_AUDIO_LOW {
			p.lag = max(p.lag, NES_FRAME_SECS)
		} else if queued > NES_AUDIO_HIGH {
			sdl.ClearAudioStream(p.audio)
		}
	}

	pad := nes_pad()
	steps := 0
	for ; steps < NES_STEPS_MAX && p.lag >= NES_FRAME_SECS; steps += 1 {
		p.lag -= NES_FRAME_SECS
		length: u32
		out := wn_model_exchange(
			p.session,
			NES_STEP,
			([^]u8)(&pad),
			1,
			raw_data(p.reply),
			u32(len(p.reply)),
			&length,
		)
		audio := int(length) - NES_FRAME_BYTES
		if out == nil || audio < 0 || audio % 2 != 0 {
			set_status(
				ui,
				fmt.aprintf(tr("Couldn't keep %s running. Please try again."), p.title),
				.Error,
			)
			nes_close()
			return
		}
		if p.audio != nil && audio > 0 {
			sdl.PutAudioStreamData(p.audio, &p.reply[NES_FRAME_BYTES], i32(audio))
		}
	}
	// After a stall (a dragged window, a slow frame) resume in real
	// time instead of fast-forwarding through the backlog.
	if p.lag > NES_FRAME_SECS {
		p.lag = 0
	}
	if steps == 0 {
		return
	}

	for index, i in p.reply[:NES_FRAME_BYTES] {
		rgb := NES_PALETTE[index & 63]
		p.rgba[i * 4 + 0] = u8(rgb >> 16)
		p.rgba[i * 4 + 1] = u8(rgb >> 8)
		p.rgba[i * 4 + 2] = u8(rgb)
		p.rgba[i * 4 + 3] = 255
	}
	rl.UpdateTexturePixels(&p.tex, raw_data(p.rgba))
}

// Held keys as a controller byte. Opposite directions cancel: no real
// pad presses both, and some games glitch when they see it.
@(private = "file")
nes_pad :: proc() -> u8 {
	pad: u8
	for keys, bit in NES_KEYS {
		if rl.IsKeyDown(keys[0]) || rl.IsKeyDown(keys[1]) {
			pad |= 1 << u8(bit)
		}
	}
	if tap_size() {
		for bit in 0 ..< 8 {
			if rl.IsMouseButtonDown(.LEFT) &&
			   nendo.pointer_over(nendo.id("NesTouch", u32(bit))) {pad |= 1 << u8(bit)}
		}
		devices_count: c.int
		devices := sdl.GetTouchDevices(&devices_count)
		defer sdl.free(devices)
		for device in devices[:int(devices_count)] {
			if sdl.GetTouchDeviceType(device) != .DIRECT {continue}
			count: c.int
			fingers := sdl.GetTouchFingers(device, &count)
			defer sdl.free(fingers)
			for finger in fingers[:int(count)] {
				x, y :=
					finger.x *
					f32(rl.GetScreenWidth()) /
					UI_ZOOM,
					finger.y *
					f32(rl.GetScreenHeight()) /
					UI_ZOOM
				for bit in 0 ..< 8 {
					box := nendo.element(nendo.id("NesTouch", u32(bit)))
					if !box.found {continue}
					b := box.rect
					if x >= b.x &&
					   y >= b.y &&
					   x < b.x + b.width &&
					   y < b.y + b.height {pad |= 1 << u8(bit)}
				}
			}
		}
	}
	if pad & 0x30 == 0x30 {
		pad &~= 0x30
	}
	if pad & 0xc0 == 0xc0 {
		pad &~= 0xc0
	}
	return pad
}

// The modal owns the keyboard while open (main.odin routes here instead
// of the chat handlers), so arrows and Enter never reach the composer.
handle_nes_input :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) || clicked("NesClose") {
		nes_close()
	}
}

// Whole device pixels when they fit; small viewports downscale the image.
@(private = "file")
nes_fit :: proc() -> (w, h: f32) {
	return nes_fit_bounds(
		f32(rl.GetScreenWidth()) / UI_ZOOM,
		f32(rl.GetScreenHeight()) / UI_ZOOM,
		UI_ZOOM,
		tap_size() ? .Touch : .Keyboard,
	)
}

@(private)
Nes_Fit_Mode :: enum {
	Keyboard,
	Touch,
}

@(private)
nes_fit_bounds :: proc(width, height, zoom: f32, mode: Nes_Fit_Mode) -> (w, h: f32) {
	max_w := max(1, width - NES_MARGIN)
	max_h := max(1, height - NES_MARGIN - (mode == .Touch ? 190 : NES_CHROME))
	fit := min(max_w * zoom / NES_W, max_h * zoom / NES_H)
	scale := fit >= 1 ? f32(int(fit)) : fit
	return NES_W * scale / zoom, NES_H * scale / zoom
}

nes_modal_draw :: proc(ui: ^Ui_State) {
	w, h := nes_fit()
	if nendo.box(nendo.id("NesModal"))(
	{
		width = nendo.fixed(tap_size() ? fit_w(max(320, w + 24)) : w + 24),
		height = nendo.fit(max = modal_h(f32(rl.GetScreenHeight()) / UI_ZOOM)),
		direction = .Column,
		gap = 8,
		padding = nendo.pad(12),
		align = {x = .Center},
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			z = 10,
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
	},
	) {
		if nendo.box(nendo.id("NesBar"))({width = nendo.grow(), gap = 10, align = {y = .Center}}) {
			if nendo.box(nendo.id("NesTitle"))({width = nendo.grow(), clip = {x = true}}) {
				nendo.text(
					nes_player.title,
					{font = FONT_TITLE, size = 14, color = TEXT, wrap = .None},
				)
			}
			if nendo.box(nendo.id("NesPad"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("NesClose"))(
			{
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				padding = {left = 10, right = 10},
				align = {y = .Center},
				color = hovered() ? HOVER : ROW_BG,
				radius = rr(6),
			},
			) {
				nendo.text(tr("Close"), {font = FONT_BODY, size = 12, color = TEXT})
			}
		}
		if nendo.box(nendo.id("NesScreen"))(
		{width = nendo.fixed(w), height = nendo.fixed(h), image = &nes_player.tex},
		) {}
		if tap_size() {
			labels := [8]string{"A", "B", tr("Select"), tr("Start"), "↑", "↓", "←", "→"}
			for row in 0 ..< 2 {
				if nendo.box(nendo.id("NesTouchRow", u32(row)))({width = nendo.grow(), gap = 6}) {
					for bit in row * 4 ..< row * 4 + 4 {
						if nendo.box(nendo.id("NesTouch", u32(bit)))(
						{
							width = nendo.grow(),
							height = nendo.fixed(44),
							align = {x = .Center, y = .Center},
							color = hovered() ? HOVER : ROW_BG,
							radius = rr(6),
						},
						) {
							nendo.text(labels[bit], {font = FONT_BODY, size = 13, color = TEXT})
						}
					}
				}
			}
		} else {
			nendo.text(
				tr("Arrow keys move. X is A, Z is B, Enter is Start, Shift is Select."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
		}
	}
	scrollbar(nendo.id("NesModal"), 11)
}

// A zip holding nothing but one .nes ROM plays like the ROM itself:
// people zip cartridges by habit. Runs on the media worker, after the
// listing, and the extraction goes through wn-archive like any entry.
nes_from_arc :: proc(arc: ^Arc_View) -> ^Nes_View {
	if len(arc.entries) != 1 {
		return nil
	}
	entry := arc.entries[0]
	lower := strings.to_lower(entry.name, context.temp_allocator)
	if !is_nes_name(lower) || entry.size > NES_ROM_MAX {
		return nil
	}
	bytes, ok := arc_entry_bytes(arc, entry.index)
	if !ok {
		return nil
	}
	view := nes_view_make(bytes)
	if view == nil {
		delete(bytes)
	}
	return view
}

// Icon, game title and Play, plated like the webxdc tile. file_name is
// the attachment the download corner saves; title is the ROM's name,
// which differs when the ROM came zipped.
nes_tile :: proc(view: ^Nes_View, id: u32, msg_id: string, att: int, file_name, title: string) {
	if nendo.box(nendo.id("MsgNes", id))(
	{
		width = nendo.fixed(min(320, att_w())),
		padding = nendo.pad(10),
		gap = 10,
		align = {y = .Center},
		color = PLATE,
		radius = rr(8),
	},
	) {
		att_dl_button("DlNes", id, msg_id, att, file_name)
		nendo.text(ICON_GAMEPAD, {font = FONT_ICON, size = 28, color = TEXT_DIM})
		if nendo.box(nendo.id("MsgNesText", id))(
		{direction = .Column, width = nendo.grow(), gap = 2},
		) {
			nendo.text(title, {font = FONT_TITLE, size = 13, color = TEXT})
			nendo.text(tr("NES game"), {font = FONT_BODY, size = 11, color = TEXT_DIM})
		}
		if nendo.box(nendo.id("MsgNesPlay", id))(
		{
			padding = {left = 12, right = 12, top = 6, bottom = 6},
			color = hovered() ? ACCENT : ROW_BG,
			radius = rr(6),
		},
		) {
			if hovered() {
				nes_hover = {view, title}
			}
			// Not "Play": its catalogs mean media playback.
			nendo.text(tr("Play game"), {font = FONT_TITLE, size = 12, color = TEXT})
		}
	}
}

handle_nes_click :: proc(ui: ^Ui_State) {
	if nes_hover.view == nil || att_hover.msg_id != "" || !mouse_released() {
		return
	}
	nes_play(ui, nes_hover.view, nes_hover.name)
}
