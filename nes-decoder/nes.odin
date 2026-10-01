package main

// NES console: CPU bus, controller port, OAM DMA and the per-frame driver.
//
// Every CPU bus access is one CPU cycle. cpu_read/cpu_write advance the
// rest of the console around the access, so the PPU and APU always see the
// CPU at the exact cycle it touches them:
//
//   cycle_begin: cycles++, 2 PPU dots, 1 APU cycle
//   access
//   cycle_end:   1 PPU dot, sample NMI/IRQ lines

NES_W :: 256
NES_H :: 240
NES_RATE :: 48000
NES_SAMPLES_MAX :: 1024

// Hard stop for nes_frame: two frames of CPU time, in case vblank never
// arrives (it always should, the PPU runs off CPU cycles).
@(private = "file")
FRAME_CYCLE_CAP :: 2 * 29781

Nes :: struct {
	cpu:         Cpu,
	ppu:         Ppu,
	apu:         Apu,
	cart:        Cart,
	ram:         [0x800]u8,
	bus:         u8, // last value on the CPU data bus (open-bus reads)
	pad:         u8, // buttons for the current frame
	pad_shift:   u8,
	pad_strobe:  bool,
	dma_page:    u8,
	dma_pending: bool,
}

nes_load :: proc(nes: ^Nes, rom: []u8) -> bool {
	delete(nes.cart.prg)
	delete(nes.cart.chr)
	nes^ = {}
	if !cart_load(&nes.cart, rom) {
		return false
	}
	apu_init(&nes.apu)
	cpu_reset(nes)
	return true
}

nes_frame :: proc(nes: ^Nes, buttons: u8, pixels: []u8, samples: []i16) -> int {
	if nes.cart.prg == nil {
		return 0
	}
	// A d-pad can't press opposite directions; some games break if it does.
	pad := buttons
	if pad & 0x30 == 0x30 {
		pad &~= 0x30
	}
	if pad & 0xC0 == 0xC0 {
		pad &~= 0xC0
	}
	nes.pad = pad
	nes.apu.sample_count = 0
	nes.ppu.frame_done = false
	start := nes.cpu.cycles
	for !nes.ppu.frame_done && nes.cpu.cycles - start < FRAME_CYCLE_CAP {
		cpu_step(nes)
	}
	copy(pixels, nes.ppu.screen[:])
	n := min(nes.apu.sample_count, len(samples))
	copy(samples, nes.apu.samples[:n])
	return n
}

cpu_read :: proc(nes: ^Nes, addr: u16) -> u8 {
	// The DMC steals the bus on a read cycle when its buffer runs dry.
	if nes.apu.dmc.remaining > 0 && !nes.apu.dmc.full {
		dmc_dma(nes)
	}
	cycle_begin(nes)
	v := bus_read(nes, addr)
	cycle_end(nes)
	return v
}

cpu_write :: proc(nes: ^Nes, addr: u16, v: u8) {
	cycle_begin(nes)
	bus_write(nes, addr, v)
	cycle_end(nes)
}

// A CPU cycle with no bus access of interest (halted, jammed).
tick :: proc(nes: ^Nes) {
	cycle_begin(nes)
	cycle_end(nes)
}

// $4014: copy a 256-byte page to OAM. One halt cycle, one more to align to
// a read cycle on odd cycles, then 256 read/write pairs.
oam_dma :: proc(nes: ^Nes) {
	nes.dma_pending = false
	tick(nes)
	if nes.cpu.cycles & 1 != 0 {
		tick(nes)
	}
	base := u16(nes.dma_page) << 8
	for i in u16(0) ..< 256 {
		v := cpu_read(nes, base + i)
		cpu_write(nes, 0x2004, v)
	}
}

@(private = "file")
cycle_begin :: #force_inline proc(nes: ^Nes) {
	nes.cpu.cycles += 1
	ppu_step(nes)
	ppu_step(nes)
	apu_step(nes)
}

@(private = "file")
cycle_end :: #force_inline proc(nes: ^Nes) {
	ppu_step(nes)
	cpu_poll(nes)
}

// ponytail: fixed 4-cycle stall; real DMC DMA steals 2-4 cycles depending
// on the cycle it lands on and can re-read I/O registers. Upgrade: model the
// halt/dummy/alignment cycles like the OAM DMA path.
@(private = "file")
dmc_dma :: proc(nes: ^Nes) {
	tick(nes)
	tick(nes)
	tick(nes)
	cycle_begin(nes)
	v := bus_read(nes, nes.apu.dmc.addr)
	cycle_end(nes)
	apu_dmc_fill(&nes.apu, v)
}

@(private = "file")
bus_read :: proc(nes: ^Nes, addr: u16) -> u8 {
	v: u8
	switch {
	case addr < 0x2000:
		v = nes.ram[addr & 0x7FF]
	case addr < 0x4000:
		v = ppu_reg_read(nes, addr & 7)
	case addr == 0x4015:
		// $4015 is internal to the 2A03 and doesn't drive the data bus.
		return apu_status(&nes.apu) | (nes.bus & 0x20)
	case addr == 0x4016:
		v = pad_read(nes) | (nes.bus & 0xE0)
	case addr < 0x6000:
		v = nes.bus // $4017 (no second controller), unmapped: open bus
		if addr == 0x4017 {
			v &= 0xE0
		}
	case addr < 0x8000:
		v = nes.cart.prg_ram[addr & 0x1FFF]
	case:
		v = cart_prg_read(&nes.cart, addr)
	}
	nes.bus = v
	return v
}

@(private = "file")
bus_write :: proc(nes: ^Nes, addr: u16, v: u8) {
	nes.bus = v
	switch {
	case addr < 0x2000:
		nes.ram[addr & 0x7FF] = v
	case addr < 0x4000:
		ppu_reg_write(nes, addr & 7, v)
	case addr == 0x4014:
		nes.dma_page = v
		nes.dma_pending = true
	case addr == 0x4016:
		nes.pad_strobe = v & 1 != 0
		if nes.pad_strobe {
			nes.pad_shift = nes.pad
		}
	case addr < 0x4018:
		apu_write(nes, addr, v)
	case addr < 0x6000:
	case addr < 0x8000:
		nes.cart.prg_ram[addr & 0x1FFF] = v
	case:
		cart_write(nes, addr, v)
	}
}

// Standard controller: A, B, Select, Start, Up, Down, Left, Right, then 1s.
@(private = "file")
pad_read :: proc(nes: ^Nes) -> u8 {
	if nes.pad_strobe {
		return nes.pad & 1
	}
	bit := nes.pad_shift & 1
	nes.pad_shift = (nes.pad_shift >> 1) | 0x80
	return bit
}
