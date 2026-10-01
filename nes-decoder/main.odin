// wn-nes: runs one NES cartridge for the app's player modal. The ROM is
// untrusted, so the emulator lives here, behind the shared session
// transport (decoder_ipc.c wn_model_*), with the decoder rlimits.
//
//   app                                wn-nes
//    | FBI1 op=0 (OPEN) + iNES bytes  -> | nes_load
//    | <- FBO1 op=0, empty             |
//    | FBI1 op=1 (STEP) + 1 byte pad  -> | nes_frame: one video frame
//    | <- FBO1 op=1, 256*240 palette   |
//    |    indices + i16 LE samples     |
//
// Any malformed request ends the process; the app treats a failed
// exchange as the game stopping.
package main

import "core:c"

WN_TARGET :: #config(WN_TARGET, "")
WN_BUILD_DIR :: "../build" when WN_TARGET == "" else "../build/cross/" + WN_TARGET
foreign import bootstrap {WN_BUILD_DIR + "/libwnmesh.a"}
@(default_calling_convention = "c")
foreign bootstrap {
	wn_mesh_bootstrap :: proc(lifetime: c.int) -> c.int ---
	wn_mesh_input :: proc(bytes: rawptr, length: c.size_t) -> c.int ---
	wn_mesh_output :: proc(bytes: rawptr, length: c.size_t) -> c.int ---
	wn_mesh_flush :: proc() -> c.int ---
	wn_mesh_finish :: proc(success: c.int) ---
}

WN_DECODER_SESSION :: 1
NES_ROM_MAX :: 8 * 1024 * 1024
NES_FRAME_BYTES :: NES_W * NES_H

Op :: enum u32 {
	Open = 0,
	Step = 1,
}

main :: proc() {
	if wn_mesh_bootstrap(WN_DECODER_SESSION) == 0 {wn_mesh_finish(0); return}

	nes := new(Nes)
	loaded := false
	reply := make([]u8, NES_FRAME_BYTES + NES_SAMPLES_MAX * 2)
	samples := make([]i16, NES_SAMPLES_MAX)
	sequence: u32

	for {
		header: [16]u8
		if wn_mesh_input(raw_data(header[:]), 16) == 0 || string(header[:4]) != "FBI1" {break}
		op, size, seq := Op(le_u32(header[4:])), le_u32(header[8:]), le_u32(header[12:])
		if sequence == max(u32) || seq != sequence + 1 {break}
		sequence = seq

		payload: []u8
		switch {
		case op == .Open && !loaded && size >= 16 && size <= NES_ROM_MAX:
			rom := make([]u8, int(size))
			if wn_mesh_input(raw_data(rom), c.size_t(size)) == 0 || !nes_load(nes, rom) {
				wn_mesh_finish(0)
				return
			}
			delete(rom)
			loaded = true
		case op == .Step && loaded && size == 1:
			pad: u8
			if wn_mesh_input(&pad, 1) == 0 {wn_mesh_finish(0); return}
			count := nes_frame(nes, pad, reply[:NES_FRAME_BYTES], samples)
			for sample, i in samples[:count] {
				at := NES_FRAME_BYTES + i * 2
				reply[at], reply[at + 1] = u8(u16(sample)), u8(u16(sample) >> 8)
			}
			payload = reply[:NES_FRAME_BYTES + count * 2]
		case:
			wn_mesh_finish(0)
			return
		}

		out := [4]u32le{0x314f4246, u32le(op), u32le(sequence), u32le(len(payload))} // "FBO1"
		if wn_mesh_output(&out, 16) == 0 ||
		   (len(payload) > 0 && wn_mesh_output(raw_data(payload), c.size_t(len(payload))) == 0) ||
		   wn_mesh_flush() == 0 {break}
	}
	wn_mesh_finish(0)
}

le_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}
