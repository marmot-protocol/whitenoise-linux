package main

// iNES cartridge: PRG/CHR banks and mappers 0, 1, 2, 3, 4 and 7.
//
// Every mapper reduces to two small tables of byte offsets, rebuilt on each
// register write (cart_update):
//
//   prg_map[4]  8 KiB windows at $8000 $A000 $C000 $E000
//   chr_map[8]  1 KiB windows at PPU $0000..$1C00
//
// Bank numbers from the ROM are always taken modulo the bank count, so a
// hostile cartridge can't steer a read outside prg/chr.

@(private = "file")
Mirror :: enum u8 {
	Horizontal,
	Vertical,
	Single_A,
	Single_B,
	Four,
}

Cart :: struct {
	prg:          []u8,
	chr:          []u8,
	prg_ram:      [0x2000]u8,
	prg_map:      [4]int,
	chr_map:      [8]int,
	nt_map:       [4]u16, // CIRAM offset of each logical nametable
	mapper:       u8,
	mirror:       Mirror,
	chr_writable: bool,
	irq:          bool, // mapper IRQ line (MMC3)
	// Mapper registers. bank: UxROM/CNROM/AxROM latch, MMC3 bank select.
	bank:         u8,
	regs:         [8]u8, // MMC3 R0..R7
	mmc1_shift:   u8,
	mmc1_count:   u8,
	mmc1_ctrl:    u8,
	mmc1_chr0:    u8,
	mmc1_chr1:    u8,
	mmc1_prg:     u8,
	mmc1_last:    u64, // CPU cycle of the last MMC1 write
	irq_latch:    u8,
	irq_counter:  u8,
	irq_reload:   bool,
	irq_enabled:  bool,
}

// Parses an iNES (or NES 2.0, read as iNES) image and copies its banks.
// Validates every size against len(rom) before slicing.
cart_load :: proc(cart: ^Cart, rom: []u8) -> bool {
	if len(rom) < 16 || rom[0] != 'N' || rom[1] != 'E' || rom[2] != 'S' || rom[3] != 0x1A {
		return false
	}
	flags6, flags7 := rom[6], rom[7]
	mapper := flags6 >> 4
	// Old dumps put junk ("DiskDude!") in bytes 7..15; only trust the high
	// mapper nibble for NES 2.0 or a clean iNES tail.
	nes2 := flags7 & 0x0C == 0x08
	clean := flags7 & 0x0C == 0 && rom[12] | rom[13] | rom[14] | rom[15] == 0
	if nes2 || clean {
		mapper |= flags7 & 0xF0
	}
	switch mapper {
	case 0, 1, 2, 3, 4, 7:
	case:
		return false
	}

	prg_size := int(rom[4]) * 0x4000
	chr_size := int(rom[5]) * 0x2000
	if prg_size == 0 {
		return false
	}
	at := 16
	if flags6 & 0x04 != 0 {
		// 512-byte trainer, loaded at $7000.
		if len(rom) < at + 512 {
			return false
		}
		copy(cart.prg_ram[0x1000:], rom[at:at + 512])
		at += 512
	}
	if len(rom) - at < prg_size + chr_size {
		return false
	}

	prg, prg_err := make([]u8, prg_size)
	if prg_err != nil {
		return false
	}
	chr, chr_err := make([]u8, chr_size if chr_size > 0 else 0x2000)
	if chr_err != nil {
		delete(prg)
		return false
	}
	copy(prg, rom[at:at + prg_size])
	copy(chr, rom[at + prg_size:at + prg_size + chr_size])
	cart.prg, cart.chr = prg, chr
	cart.chr_writable = chr_size == 0
	cart.mapper = mapper

	cart.mirror = .Vertical if flags6 & 0x01 != 0 else .Horizontal
	if flags6 & 0x08 != 0 {
		cart.mirror = .Four
	}
	switch mapper {
	case 1:
		cart.mmc1_ctrl = 0x0C
	case 4:
		cart.regs = {0, 2, 4, 5, 6, 7, 0, 1}
	}
	cart_update(cart)
	return true
}

cart_prg_read :: #force_inline proc(cart: ^Cart, addr: u16) -> u8 {
	return cart.prg[cart.prg_map[(addr >> 13) & 3] + int(addr & 0x1FFF)]
}

cart_chr_read :: #force_inline proc(cart: ^Cart, addr: u16) -> u8 {
	return cart.chr[cart.chr_map[(addr >> 10) & 7] + int(addr & 0x3FF)]
}

cart_chr_write :: proc(cart: ^Cart, addr: u16, v: u8) {
	if !cart.chr_writable {
		return
	}
	cart.chr[cart.chr_map[(addr >> 10) & 7] + int(addr & 0x3FF)] = v
}

// CPU write to $8000-$FFFF: mapper registers.
cart_write :: proc(nes: ^Nes, addr: u16, v: u8) {
	cart := &nes.cart
	switch cart.mapper {
	case 0:
		return
	case 1:
		mmc1_write(cart, addr, v, nes.cpu.cycles)
		return
	case 2, 3, 7:
		cart.bank = v
	case 4:
		mmc3_write(cart, addr, v)
	}
	cart_update(cart)
}

// MMC3 scanline counter, clocked once per rendered line just after dot 260.
// ponytail: approximates A12 edge counting; games that fetch background
// from $1000 and sprites from $0000 really clock near dot 324, and
// $2006/$2007-driven A12 toggles are ignored. Upgrade: track A12 rises in
// ppu_read (with sprite fetches at their real dots) plus an M2 low-time
// filter.
cart_scanline :: proc(cart: ^Cart) {
	if cart.mapper != 4 {
		return
	}
	if cart.irq_counter == 0 || cart.irq_reload {
		cart.irq_counter = cart.irq_latch
		cart.irq_reload = false
	} else {
		cart.irq_counter -= 1
	}
	if cart.irq_counter == 0 && cart.irq_enabled {
		cart.irq = true
	}
}

// Serial port: five writes of bit 0 fill a register chosen by the address
// of the fifth. Bit 7 resets. The second write of a read-modify-write
// (two writes on consecutive cycles) is ignored by the real chip.
@(private = "file")
mmc1_write :: proc(cart: ^Cart, addr: u16, v: u8, cycle: u64) {
	consecutive := cycle == cart.mmc1_last + 1
	cart.mmc1_last = cycle
	if consecutive {
		return
	}
	if v & 0x80 != 0 {
		cart.mmc1_shift, cart.mmc1_count = 0, 0
		cart.mmc1_ctrl |= 0x0C
		cart_update(cart)
		return
	}
	cart.mmc1_shift |= (v & 1) << cart.mmc1_count
	cart.mmc1_count += 1
	if cart.mmc1_count < 5 {
		return
	}
	switch (addr >> 13) & 3 {
	case 0:
		cart.mmc1_ctrl = cart.mmc1_shift
	case 1:
		cart.mmc1_chr0 = cart.mmc1_shift
	case 2:
		cart.mmc1_chr1 = cart.mmc1_shift
	case 3:
		cart.mmc1_prg = cart.mmc1_shift
	}
	cart.mmc1_shift, cart.mmc1_count = 0, 0
	cart_update(cart)
}

@(private = "file")
mmc3_write :: proc(cart: ^Cart, addr: u16, v: u8) {
	even := addr & 1 == 0
	switch addr & 0xE000 {
	case 0x8000:
		if even {
			cart.bank = v
		} else {
			cart.regs[cart.bank & 7] = v
		}
	case 0xA000:
		// Odd: PRG RAM protect, ignored so MMC6-style boards keep their RAM.
		if even && cart.mirror != .Four {
			cart.mirror = .Horizontal if v & 1 != 0 else .Vertical
		}
	case 0xC000:
		if even {
			cart.irq_latch = v
		} else {
			cart.irq_counter = 0
			cart.irq_reload = true
		}
	case 0xE000:
		cart.irq_enabled = !even
		if even {
			cart.irq = false
		}
	}
}

// Rebuilds the bank and nametable tables from the mapper registers.
@(private = "file")
cart_update :: proc(cart: ^Cart) {
	prg16 := len(cart.prg) / 0x4000
	switch cart.mapper {
	case 0:
		prg_32k(cart, 0)
		chr_8k(cart, 0)
	case 1:
		// 512 KiB SUROM: CHR register bit 4 picks the 256 KiB PRG half.
		outer := int(cart.mmc1_chr0 & 0x10) if prg16 > 16 else 0
		bank := int(cart.mmc1_prg & 0x0F)
		switch (cart.mmc1_ctrl >> 2) & 3 {
		case 0, 1:
			prg_32k(cart, (outer + bank) >> 1)
		case 2:
			prg_16k(cart, 0, outer)
			prg_16k(cart, 1, outer + bank)
		case 3:
			prg_16k(cart, 0, outer + bank)
			prg_16k(cart, 1, outer + ((prg16 - 1) & 0x0F))
		}
		if cart.mmc1_ctrl & 0x10 != 0 {
			chr_4k(cart, 0, int(cart.mmc1_chr0))
			chr_4k(cart, 1, int(cart.mmc1_chr1))
		} else {
			chr_8k(cart, int(cart.mmc1_chr0 >> 1))
		}
		modes := [4]Mirror{.Single_A, .Single_B, .Vertical, .Horizontal}
		cart.mirror = modes[cart.mmc1_ctrl & 3]
	case 2:
		prg_16k(cart, 0, int(cart.bank))
		prg_16k(cart, 1, prg16 - 1)
		chr_8k(cart, 0)
	case 3:
		prg_32k(cart, 0)
		chr_8k(cart, int(cart.bank))
	case 4:
		prg8 := prg16 * 2
		r6, r7 := int(cart.regs[6] & 0x3F), int(cart.regs[7] & 0x3F)
		banks := [4]int{r6, r7, prg8 - 2, prg8 - 1}
		if cart.bank & 0x40 != 0 {
			banks[0], banks[2] = prg8 - 2, r6
		}
		for b, i in banks {
			cart.prg_map[i] = (b % prg8) * 0x2000
		}
		r := &cart.regs
		chr := [8]int {
			int(r[0] & 0xFE),
			int(r[0] | 1),
			int(r[1] & 0xFE),
			int(r[1] | 1),
			int(r[2]),
			int(r[3]),
			int(r[4]),
			int(r[5]),
		}
		// Bank select bit 7 swaps the 2 KiB and 1 KiB halves.
		swap := 4 if cart.bank & 0x80 != 0 else 0
		chr1k := len(cart.chr) / 0x400
		for b, i in chr {
			cart.chr_map[i ~ swap] = (b % chr1k) * 0x400
		}
	case 7:
		prg_32k(cart, int(cart.bank & 0x07))
		chr_8k(cart, 0)
		cart.mirror = .Single_B if cart.bank & 0x10 != 0 else .Single_A
	}

	// Nametable $2000/$2400/$2800/$2C00 -> CIRAM offset.
	switch cart.mirror {
	case .Horizontal:
		cart.nt_map = {0, 0, 0x400, 0x400}
	case .Vertical:
		cart.nt_map = {0, 0x400, 0, 0x400}
	case .Single_A:
		cart.nt_map = {0, 0, 0, 0}
	case .Single_B:
		cart.nt_map = {0x400, 0x400, 0x400, 0x400}
	case .Four:
		cart.nt_map = {0, 0x400, 0x800, 0xC00}
	}
}

@(private = "file")
prg_16k :: proc(cart: ^Cart, slot: int, bank: int) {
	b := bank % (len(cart.prg) / 0x4000)
	cart.prg_map[slot * 2] = b * 0x4000
	cart.prg_map[slot * 2 + 1] = b * 0x4000 + 0x2000
}

// 16 KiB carts mirror into both halves.
@(private = "file")
prg_32k :: proc(cart: ^Cart, bank: int) {
	prg16 := len(cart.prg) / 0x4000
	prg_16k(cart, 0, bank * 2 % prg16)
	prg_16k(cart, 1, (bank * 2 + 1) % prg16)
}

@(private = "file")
chr_4k :: proc(cart: ^Cart, slot: int, bank: int) {
	chr1k := len(cart.chr) / 0x400
	for i in 0 ..< 4 {
		cart.chr_map[slot * 4 + i] = ((bank * 4 + i) % chr1k) * 0x400
	}
}

@(private = "file")
chr_8k :: proc(cart: ^Cart, bank: int) {
	chr_4k(cart, 0, bank * 2)
	chr_4k(cart, 1, bank * 2 + 1)
}
