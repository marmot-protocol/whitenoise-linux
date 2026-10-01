package main

// 2A03 CPU: a 6502 without decimal mode, including the stable unofficial
// opcodes. Each bus access is one cycle (cpu_read/cpu_write), and the
// addressing helpers make the same dummy reads and writes as the chip, so
// cycle counts, page-cross and branch penalties follow from the accesses.
//
// Interrupts: cpu_poll runs at the end of every cycle. An instruction takes
// an interrupt if it was pending at the end of its second-to-last cycle,
// which gives the CLI/SEI/PLP one-instruction delay for free.

Cpu :: struct {
	pc:        u16,
	a, x, y:   u8,
	s, p:      u8,
	cycles:    u64,
	nmi_line:  bool, // NMI input level at the end of the last cycle
	nmi_edge:  bool, // falling edge seen, cleared when the NMI is taken
	nmi_ready: bool, // nmi_edge one cycle ago
	irq_now:   bool, // IRQ asserted and unmasked at the end of the last cycle
	irq_ready: bool, // irq_now one cycle ago
	jammed:    bool, // KIL opcode: halted until reload
}

@(private = "file")
FLAG_C :: u8(0x01)
@(private = "file")
FLAG_Z :: u8(0x02)
@(private = "file")
FLAG_I :: u8(0x04)
@(private = "file")
FLAG_B :: u8(0x10)
@(private = "file")
FLAG_U :: u8(0x20)
@(private = "file")
FLAG_V :: u8(0x40)
@(private = "file")
FLAG_N :: u8(0x80)

@(private = "file")
Mode :: enum u8 {
	Imp,
	Imm,
	Zp,
	Zpx,
	Zpy,
	Abs,
	Abx,
	Aby,
	Izx,
	Izy,
}

// Operand addressing per opcode. Control flow (branches, JMP, JSR, RTS,
// RTI, BRK) and implied ops do their own bus cycles and are listed as Imp.
@(private = "file", rodata)
MODES := [256]Mode {
	.Imp,
	.Izx,
	.Imp,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // 0x
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // 1x
	.Imp,
	.Izx,
	.Imp,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // 2x
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // 3x
	.Imp,
	.Izx,
	.Imp,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Imp,
	.Abs,
	.Abs,
	.Abs, // 4x
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // 5x
	.Imp,
	.Izx,
	.Imp,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Imp,
	.Abs,
	.Abs,
	.Abs, // 6x
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // 7x
	.Imm,
	.Izx,
	.Imm,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // 8x
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpy,
	.Zpy,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Aby,
	.Aby, // 9x
	.Imm,
	.Izx,
	.Imm,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // Ax
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpy,
	.Zpy,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Aby,
	.Aby, // Bx
	.Imm,
	.Izx,
	.Imm,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // Cx
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // Dx
	.Imm,
	.Izx,
	.Imm,
	.Izx,
	.Zp,
	.Zp,
	.Zp,
	.Zp,
	.Imp,
	.Imm,
	.Imp,
	.Imm,
	.Abs,
	.Abs,
	.Abs,
	.Abs, // Ex
	.Imp,
	.Izy,
	.Imp,
	.Izy,
	.Zpx,
	.Zpx,
	.Zpx,
	.Zpx,
	.Imp,
	.Aby,
	.Imp,
	.Aby,
	.Abx,
	.Abx,
	.Abx,
	.Abx, // Fx
}

// Power-on/reset: an interrupt sequence whose three stack writes are reads.
cpu_reset :: proc(nes: ^Nes) {
	c := &nes.cpu
	c.jammed = false
	_ = cpu_read(nes, c.pc)
	_ = cpu_read(nes, c.pc)
	for _ in 0 ..< 3 {
		_ = cpu_read(nes, 0x100 | u16(c.s))
		c.s -= 1
	}
	c.p |= FLAG_I | FLAG_U
	lo := cpu_read(nes, 0xFFFC)
	hi := cpu_read(nes, 0xFFFD)
	c.pc = u16(lo) | u16(hi) << 8
}

// End of every CPU cycle: NMI is edge-detected, IRQ is a level gated by I.
cpu_poll :: #force_inline proc(nes: ^Nes) {
	c := &nes.cpu
	c.nmi_ready = c.nmi_edge
	line := nes.ppu.status & 0x80 != 0 && nes.ppu.ctrl & 0x80 != 0
	if line && !c.nmi_line {
		c.nmi_edge = true
	}
	c.nmi_line = line
	c.irq_ready = c.irq_now
	c.irq_now = c.p & FLAG_I == 0 && (nes.apu.frame_irq || nes.apu.dmc.irq || nes.cart.irq)
}

// Runs one instruction (or one idle cycle when jammed), then any OAM DMA it
// started and any interrupt it let through.
cpu_step :: proc(nes: ^Nes) {
	c := &nes.cpu
	if c.jammed {
		tick(nes)
		return
	}
	execute(nes, fetch(nes))
	poll := c.nmi_ready || c.irq_ready
	if nes.dma_pending {
		oam_dma(nes)
	}
	if poll && !c.jammed {
		interrupt(nes)
	}
}

@(private = "file")
interrupt :: proc(nes: ^Nes) {
	c := &nes.cpu
	_ = cpu_read(nes, c.pc)
	_ = cpu_read(nes, c.pc)
	push(nes, u8(c.pc >> 8))
	push(nes, u8(c.pc))
	// An NMI arriving while PC is pushed hijacks the IRQ vector.
	vector := u16(0xFFFE)
	if c.nmi_edge {
		c.nmi_edge = false
		vector = 0xFFFA
	}
	push(nes, (c.p | FLAG_U) & ~FLAG_B)
	c.p |= FLAG_I
	lo := cpu_read(nes, vector)
	hi := cpu_read(nes, vector + 1)
	c.pc = u16(lo) | u16(hi) << 8
}

@(private = "file")
execute :: proc(nes: ^Nes, op: u8) {
	c := &nes.cpu
	switch op {
	// Loads and stores
	case 0xA1, 0xA5, 0xA9, 0xAD, 0xB1, 0xB5, 0xB9, 0xBD:
		c.a = load(nes, op)
		set_zn(c, c.a)
	case 0xA2, 0xA6, 0xAE, 0xB6, 0xBE:
		c.x = load(nes, op)
		set_zn(c, c.x)
	case 0xA0, 0xA4, 0xAC, 0xB4, 0xBC:
		c.y = load(nes, op)
		set_zn(c, c.y)
	case 0x81, 0x85, 0x8D, 0x91, 0x95, 0x99, 0x9D:
		cpu_write(nes, operand(nes, op, true), c.a)
	case 0x86, 0x8E, 0x96:
		cpu_write(nes, operand(nes, op, true), c.x)
	case 0x84, 0x8C, 0x94:
		cpu_write(nes, operand(nes, op, true), c.y)

	// ALU
	case 0x01, 0x05, 0x09, 0x0D, 0x11, 0x15, 0x19, 0x1D:
		c.a |= load(nes, op)
		set_zn(c, c.a)
	case 0x21, 0x25, 0x29, 0x2D, 0x31, 0x35, 0x39, 0x3D:
		c.a &= load(nes, op)
		set_zn(c, c.a)
	case 0x41, 0x45, 0x49, 0x4D, 0x51, 0x55, 0x59, 0x5D:
		c.a ~= load(nes, op)
		set_zn(c, c.a)
	case 0x61, 0x65, 0x69, 0x6D, 0x71, 0x75, 0x79, 0x7D:
		adc(c, load(nes, op))
	case 0xE1, 0xE5, 0xE9, 0xEB, 0xED, 0xF1, 0xF5, 0xF9, 0xFD:
		adc(c, ~load(nes, op))
	case 0xC1, 0xC5, 0xC9, 0xCD, 0xD1, 0xD5, 0xD9, 0xDD:
		compare(c, c.a, load(nes, op))
	case 0xE0, 0xE4, 0xEC:
		compare(c, c.x, load(nes, op))
	case 0xC0, 0xC4, 0xCC:
		compare(c, c.y, load(nes, op))
	case 0x24, 0x2C:
		v := load(nes, op)
		c.p = (c.p & ~(FLAG_Z | FLAG_V | FLAG_N)) | (v & (FLAG_V | FLAG_N))
		if c.a & v == 0 {
			c.p |= FLAG_Z
		}

	// Shifts, increments (accumulator and read-modify-write)
	case 0x0A:
		idle(nes)
		c.a = asl(c, c.a)
	case 0x4A:
		idle(nes)
		c.a = lsr(c, c.a)
	case 0x2A:
		idle(nes)
		c.a = rol(c, c.a)
	case 0x6A:
		idle(nes)
		c.a = ror(c, c.a)
	case 0x06, 0x0E, 0x16, 0x1E:
		rmw(nes, op, asl)
	case 0x46, 0x4E, 0x56, 0x5E:
		rmw(nes, op, lsr)
	case 0x26, 0x2E, 0x36, 0x3E:
		rmw(nes, op, rol)
	case 0x66, 0x6E, 0x76, 0x7E:
		rmw(nes, op, ror)
	case 0xC6, 0xCE, 0xD6, 0xDE:
		rmw(nes, op, dec)
	case 0xE6, 0xEE, 0xF6, 0xFE:
		rmw(nes, op, inc)

	// Register transfers and flags
	case 0xAA:
		idle(nes)
		c.x = c.a
		set_zn(c, c.x)
	case 0x8A:
		idle(nes)
		c.a = c.x
		set_zn(c, c.a)
	case 0xA8:
		idle(nes)
		c.y = c.a
		set_zn(c, c.y)
	case 0x98:
		idle(nes)
		c.a = c.y
		set_zn(c, c.a)
	case 0xBA:
		idle(nes)
		c.x = c.s
		set_zn(c, c.x)
	case 0x9A:
		idle(nes)
		c.s = c.x
	case 0xE8:
		idle(nes)
		c.x += 1
		set_zn(c, c.x)
	case 0xCA:
		idle(nes)
		c.x -= 1
		set_zn(c, c.x)
	case 0xC8:
		idle(nes)
		c.y += 1
		set_zn(c, c.y)
	case 0x88:
		idle(nes)
		c.y -= 1
		set_zn(c, c.y)
	case 0x18:
		idle(nes)
		c.p &= ~FLAG_C
	case 0x38:
		idle(nes)
		c.p |= FLAG_C
	case 0x58:
		idle(nes)
		c.p &= ~FLAG_I
	case 0x78:
		idle(nes)
		c.p |= FLAG_I
	case 0xB8:
		idle(nes)
		c.p &= ~FLAG_V
	case 0xD8:
		idle(nes)
		c.p &= ~u8(0x08)
	case 0xF8:
		idle(nes)
		c.p |= 0x08
	case 0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA:
		idle(nes)
	case 0x80,
	     0x82,
	     0x89,
	     0xC2,
	     0xE2,
	     0x04,
	     0x44,
	     0x64,
	     0x0C,
	     0x14,
	     0x34,
	     0x54,
	     0x74,
	     0xD4,
	     0xF4,
	     0x1C,
	     0x3C,
	     0x5C,
	     0x7C,
	     0xDC,
	     0xFC:
		_ = load(nes, op)

	// Branches
	case 0x10:
		branch(nes, c.p & FLAG_N == 0)
	case 0x30:
		branch(nes, c.p & FLAG_N != 0)
	case 0x50:
		branch(nes, c.p & FLAG_V == 0)
	case 0x70:
		branch(nes, c.p & FLAG_V != 0)
	case 0x90:
		branch(nes, c.p & FLAG_C == 0)
	case 0xB0:
		branch(nes, c.p & FLAG_C != 0)
	case 0xD0:
		branch(nes, c.p & FLAG_Z == 0)
	case 0xF0:
		branch(nes, c.p & FLAG_Z != 0)

	// Jumps, subroutines, stack
	case 0x4C:
		c.pc = fetch16(nes)
	case 0x6C:
		// The pointer's high byte doesn't carry into the next page.
		ptr := fetch16(nes)
		lo := cpu_read(nes, ptr)
		hi := cpu_read(nes, (ptr & 0xFF00) | ((ptr + 1) & 0x00FF))
		c.pc = u16(lo) | u16(hi) << 8
	case 0x20:
		lo := fetch(nes)
		_ = cpu_read(nes, 0x100 | u16(c.s))
		push(nes, u8(c.pc >> 8))
		push(nes, u8(c.pc))
		hi := cpu_read(nes, c.pc)
		c.pc = u16(lo) | u16(hi) << 8
	case 0x60:
		idle(nes)
		_ = cpu_read(nes, 0x100 | u16(c.s))
		lo := pull(nes)
		hi := pull(nes)
		c.pc = u16(lo) | u16(hi) << 8
		_ = fetch(nes)
	case 0x40:
		idle(nes)
		_ = cpu_read(nes, 0x100 | u16(c.s))
		c.p = (pull(nes) & ~FLAG_B) | FLAG_U
		lo := pull(nes)
		hi := pull(nes)
		c.pc = u16(lo) | u16(hi) << 8
	case 0x00:
		_ = fetch(nes)
		push(nes, u8(c.pc >> 8))
		push(nes, u8(c.pc))
		vector := u16(0xFFFE)
		if c.nmi_edge {
			c.nmi_edge = false
			vector = 0xFFFA
		}
		push(nes, c.p | FLAG_B | FLAG_U)
		c.p |= FLAG_I
		lo := cpu_read(nes, vector)
		hi := cpu_read(nes, vector + 1)
		c.pc = u16(lo) | u16(hi) << 8
		// Like the interrupt sequence, BRK doesn't poll at its end: an NMI
		// too late to hijack waits for the handler's first instruction.
		c.nmi_ready = false
	case 0x48:
		idle(nes)
		push(nes, c.a)
	case 0x08:
		idle(nes)
		push(nes, c.p | FLAG_B | FLAG_U)
	case 0x68:
		idle(nes)
		_ = cpu_read(nes, 0x100 | u16(c.s))
		c.a = pull(nes)
		set_zn(c, c.a)
	case 0x28:
		idle(nes)
		_ = cpu_read(nes, 0x100 | u16(c.s))
		c.p = (pull(nes) & ~FLAG_B) | FLAG_U

	// Unofficial
	case 0xA3, 0xA7, 0xAB, 0xAF, 0xB3, 0xB7, 0xBF:
		// LAX (0xAB: LAX #imm, the common "magic $FF" behaviour)
		c.a = load(nes, op)
		c.x = c.a
		set_zn(c, c.a)
	case 0x83, 0x87, 0x8F, 0x97:
		cpu_write(nes, operand(nes, op, true), c.a & c.x)
	case 0x03, 0x07, 0x0F, 0x13, 0x17, 0x1B, 0x1F:
		c.a |= rmw(nes, op, asl)
		set_zn(c, c.a)
	case 0x23, 0x27, 0x2F, 0x33, 0x37, 0x3B, 0x3F:
		c.a &= rmw(nes, op, rol)
		set_zn(c, c.a)
	case 0x43, 0x47, 0x4F, 0x53, 0x57, 0x5B, 0x5F:
		c.a ~= rmw(nes, op, lsr)
		set_zn(c, c.a)
	case 0x63, 0x67, 0x6F, 0x73, 0x77, 0x7B, 0x7F:
		adc(c, rmw(nes, op, ror))
	case 0xC3, 0xC7, 0xCF, 0xD3, 0xD7, 0xDB, 0xDF:
		compare(c, c.a, rmw(nes, op, dec))
	case 0xE3, 0xE7, 0xEF, 0xF3, 0xF7, 0xFB, 0xFF:
		adc(c, ~rmw(nes, op, inc))
	case 0x0B, 0x2B:
		// ANC
		c.a &= load(nes, op)
		set_zn(c, c.a)
		set_flag(c, FLAG_C, c.a & 0x80 != 0)
	case 0x4B:
		// ALR
		c.a = lsr(c, c.a & load(nes, op))
	case 0x6B:
		// ARR: AND, then ROR with C and V taken from bits 6 and 5.
		v := c.a & load(nes, op)
		c.a = (v >> 1) | ((c.p & FLAG_C) << 7)
		set_zn(c, c.a)
		set_flag(c, FLAG_C, c.a & 0x40 != 0)
		set_flag(c, FLAG_V, (c.a ~ (c.a << 1)) & 0x40 != 0)
	case 0xCB:
		// AXS: X = (A & X) - imm, carry as in CMP.
		v := load(nes, op)
		t := c.a & c.x
		set_flag(c, FLAG_C, t >= v)
		c.x = t - v
		set_zn(c, c.x)
	case 0x8B:
		// XAA, unstable on hardware; uses the common magic constant $FF.
		c.a = c.x & load(nes, op)
		set_zn(c, c.a)
	case 0xBB:
		// LAS
		v := load(nes, op) & c.s
		c.a, c.x, c.s = v, v, v
		set_zn(c, v)
	case 0x9C:
		high_store(nes, fetch16(nes), c.x, c.y)
	case 0x9E:
		high_store(nes, fetch16(nes), c.y, c.x)
	case 0x9F:
		high_store(nes, fetch16(nes), c.y, c.a & c.x)
	case 0x93:
		ptr := fetch(nes)
		lo := cpu_read(nes, u16(ptr))
		hi := cpu_read(nes, u16(ptr + 1))
		high_store(nes, u16(lo) | u16(hi) << 8, c.y, c.a & c.x)
	case 0x9B:
		c.s = c.a & c.x
		high_store(nes, fetch16(nes), c.y, c.s)
	case 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2:
		c.jammed = true
	}
}

@(private = "file")
fetch :: #force_inline proc(nes: ^Nes) -> u8 {
	v := cpu_read(nes, nes.cpu.pc)
	nes.cpu.pc += 1
	return v
}

@(private = "file")
fetch16 :: proc(nes: ^Nes) -> u16 {
	lo := fetch(nes)
	hi := fetch(nes)
	return u16(lo) | u16(hi) << 8
}

// Second cycle of a one-byte instruction: reads the next byte, PC stays.
@(private = "file")
idle :: #force_inline proc(nes: ^Nes) {
	_ = cpu_read(nes, nes.cpu.pc)
}

@(private = "file")
push :: proc(nes: ^Nes, v: u8) {
	cpu_write(nes, 0x100 | u16(nes.cpu.s), v)
	nes.cpu.s -= 1
}

@(private = "file")
pull :: proc(nes: ^Nes) -> u8 {
	nes.cpu.s += 1
	return cpu_read(nes, 0x100 | u16(nes.cpu.s))
}

@(private = "file")
load :: #force_inline proc(nes: ^Nes, op: u8) -> u8 {
	return cpu_read(nes, operand(nes, op, false))
}

// Effective address for op's mode, after the mode's own bus cycles.
// Indexed modes first touch the address before the carry into the high
// byte: reads skip that dummy read when no page is crossed, writes and
// read-modify-writes always pay it.
@(private = "file")
operand :: proc(nes: ^Nes, op: u8, write: bool) -> u16 {
	c := &nes.cpu
	switch MODES[op] {
	case .Imm:
		c.pc += 1
		return c.pc - 1
	case .Zp:
		return u16(fetch(nes))
	case .Zpx, .Zpy:
		base := fetch(nes)
		_ = cpu_read(nes, u16(base))
		return u16(base + (c.x if MODES[op] == .Zpx else c.y))
	case .Abs:
		return fetch16(nes)
	case .Abx:
		return indexed(nes, fetch16(nes), c.x, write)
	case .Aby:
		return indexed(nes, fetch16(nes), c.y, write)
	case .Izx:
		ptr := fetch(nes)
		_ = cpu_read(nes, u16(ptr))
		ptr += c.x
		lo := cpu_read(nes, u16(ptr))
		hi := cpu_read(nes, u16(ptr + 1))
		return u16(lo) | u16(hi) << 8
	case .Izy:
		ptr := fetch(nes)
		lo := cpu_read(nes, u16(ptr))
		hi := cpu_read(nes, u16(ptr + 1))
		return indexed(nes, u16(lo) | u16(hi) << 8, c.y, write)
	case .Imp:
	}
	return 0
}

@(private = "file")
indexed :: proc(nes: ^Nes, base: u16, index: u8, write: bool) -> u16 {
	addr := base + u16(index)
	if write || (base ~ addr) & 0xFF00 != 0 {
		_ = cpu_read(nes, (base & 0xFF00) | (addr & 0x00FF))
	}
	return addr
}

// Read, write back unchanged (the 6502's dummy write), write the result.
@(private = "file")
rmw :: proc(nes: ^Nes, op: u8, f: proc(c: ^Cpu, v: u8) -> u8) -> u8 {
	addr := operand(nes, op, true)
	v := cpu_read(nes, addr)
	cpu_write(nes, addr, v)
	r := f(&nes.cpu, v)
	cpu_write(nes, addr, r)
	return r
}

// SHY/SHX/AHX/TAS store v & (H + 1), H being the base address high byte;
// on a page cross that value also replaces the target's high byte.
@(private = "file")
high_store :: proc(nes: ^Nes, base: u16, index: u8, v: u8) {
	addr := indexed(nes, base, index, true)
	r := v & u8((base >> 8) + 1)
	if (base ~ addr) & 0xFF00 != 0 {
		addr = u16(r) << 8 | (addr & 0x00FF)
	}
	cpu_write(nes, addr, r)
}

// A taken branch costs a cycle, plus one more to fix up a page cross.
@(private = "file")
branch :: proc(nes: ^Nes, taken: bool) {
	c := &nes.cpu
	offset := fetch(nes)
	if !taken {
		return
	}
	// A taken branch that stays on its page doesn't poll IRQ on its last
	// cycle, so an IRQ raised during it waits one more instruction.
	if c.irq_now && !c.irq_ready {
		c.irq_now = false
	}
	_ = cpu_read(nes, c.pc)
	target := c.pc + u16(i16(i8(offset)))
	if (target ~ c.pc) & 0xFF00 != 0 {
		_ = cpu_read(nes, (c.pc & 0xFF00) | (target & 0x00FF))
	}
	c.pc = target
}

@(private = "file")
set_zn :: #force_inline proc(c: ^Cpu, v: u8) {
	c.p = (c.p & ~(FLAG_Z | FLAG_N)) | (v & FLAG_N)
	if v == 0 {
		c.p |= FLAG_Z
	}
}

@(private = "file")
set_flag :: #force_inline proc(c: ^Cpu, flag: u8, on: bool) {
	if on {
		c.p |= flag
	} else {
		c.p &= ~flag
	}
}

@(private = "file")
adc :: proc(c: ^Cpu, v: u8) {
	sum := u16(c.a) + u16(v) + u16(c.p & FLAG_C)
	r := u8(sum)
	set_flag(c, FLAG_C, sum > 0xFF)
	set_flag(c, FLAG_V, (c.a ~ r) & (v ~ r) & 0x80 != 0)
	c.a = r
	set_zn(c, r)
}

@(private = "file")
compare :: proc(c: ^Cpu, reg: u8, v: u8) {
	set_flag(c, FLAG_C, reg >= v)
	set_zn(c, reg - v)
}

@(private = "file")
asl :: proc(c: ^Cpu, v: u8) -> u8 {
	set_flag(c, FLAG_C, v & 0x80 != 0)
	set_zn(c, v << 1)
	return v << 1
}

@(private = "file")
lsr :: proc(c: ^Cpu, v: u8) -> u8 {
	set_flag(c, FLAG_C, v & 1 != 0)
	set_zn(c, v >> 1)
	return v >> 1
}

@(private = "file")
rol :: proc(c: ^Cpu, v: u8) -> u8 {
	r := v << 1 | (c.p & FLAG_C)
	set_flag(c, FLAG_C, v & 0x80 != 0)
	set_zn(c, r)
	return r
}

@(private = "file")
ror :: proc(c: ^Cpu, v: u8) -> u8 {
	r := v >> 1 | (c.p & FLAG_C) << 7
	set_flag(c, FLAG_C, v & 1 != 0)
	set_zn(c, r)
	return r
}

@(private = "file")
inc :: proc(c: ^Cpu, v: u8) -> u8 {
	set_zn(c, v + 1)
	return v + 1
}

@(private = "file")
dec :: proc(c: ^Cpu, v: u8) -> u8 {
	set_zn(c, v - 1)
	return v - 1
}
