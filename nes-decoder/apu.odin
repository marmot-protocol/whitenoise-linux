package main

// 2A03 APU: two pulses, triangle, noise, DMC and the frame counter, run
// every CPU cycle. Output goes through the standard nonlinear mixer,
// averaged down to NES_RATE with an exact integer rate accumulator, then a
// ~90 Hz high-pass (removes DC from the unipolar mix) and a ~14 kHz
// low-pass (softens aliasing) before scaling to i16.

@(private = "file")
CPU_HZ :: 1789773

@(private = "file")
HIGH_PASS :: 0.988356 // 1 / (1 + 2*pi*90/48000)
@(private = "file")
LOW_PASS :: 0.646967 // a / (1 + a), a = 2*pi*14000/48000

@(private = "file")
Envelope :: struct {
	start:    bool,
	loop:     bool, // also halts the length counter
	constant: bool,
	period:   u8, // divider period, or the volume when constant
	divider:  u8,
	decay:    u8,
}

@(private = "file")
Pulse :: struct {
	env:          Envelope,
	length:       u8,
	duty:         u8,
	step:         u8,
	period:       u16,
	timer:        u16,
	sweep_on:     bool,
	sweep_neg:    bool,
	sweep_reload: bool,
	sweep_period: u8,
	sweep_shift:  u8,
	sweep_div:    u8,
}

@(private = "file")
Triangle :: struct {
	length:        u8,
	control:       bool, // halts length, keeps reloading the linear counter
	linear:        u8,
	linear_period: u8,
	linear_reload: bool,
	period:        u16,
	timer:         u16,
	step:          u8,
}

@(private = "file")
Noise :: struct {
	env:    Envelope,
	length: u8,
	mode:   bool,
	period: u16,
	timer:  u16,
	lfsr:   u16,
}

Dmc :: struct {
	irq_on:    bool,
	loop:      bool,
	irq:       bool,
	full:      bool, // sample buffer holds a byte
	silent:    bool,
	period:    u16,
	timer:     u16,
	level:     u8,
	buffer:    u8,
	shift:     u8,
	bits:      u8,
	start:     u16,
	length:    u16,
	addr:      u16,
	remaining: u16, // bytes left to fetch
}

Apu :: struct {
	pulse:        [2]Pulse,
	tri:          Triangle,
	noise:        Noise,
	dmc:          Dmc,
	enabled:      u8, // $4015 bits 0-3: length counters may load
	frame_irq:    bool,
	irq_inhibit:  bool,
	five_step:    bool,
	fc_cycle:     int, // CPU cycles into the frame sequence
	fc_delay:     int, // cycles until a $4017 write takes effect
	fc_value:     u8,
	fc_block:     int, // cycles a just-made clock blocks another
	rate_acc:     int,
	mix_sum:      f32,
	mix_n:        int,
	hp_in:        f32,
	hp_out:       f32,
	lp_out:       f32,
	pulse_mix:    [31]f32,
	tnd_mix:      [203]f32,
	samples:      [NES_SAMPLES_MAX]i16,
	sample_count: int,
}

@(private = "file", rodata)
LENGTHS := [32]u8 {
	10,
	254,
	20,
	2,
	40,
	4,
	80,
	6,
	160,
	8,
	60,
	10,
	14,
	12,
	26,
	14,
	12,
	16,
	24,
	18,
	48,
	20,
	96,
	22,
	192,
	24,
	72,
	26,
	16,
	28,
	32,
	30,
}

@(private = "file", rodata)
DUTY := [4]u8{0b01000000, 0b01100000, 0b01111000, 0b10011111}

@(private = "file", rodata)
TRIANGLE := [32]u8 {
	15,
	14,
	13,
	12,
	11,
	10,
	9,
	8,
	7,
	6,
	5,
	4,
	3,
	2,
	1,
	0,
	0,
	1,
	2,
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
}

@(private = "file", rodata)
NOISE_PERIODS := [16]u16{4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068}

@(private = "file", rodata)
DMC_RATES := [16]u16{428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54}

apu_init :: proc(a: ^Apu) {
	a.noise.lfsr = 1
	a.noise.period = NOISE_PERIODS[0]
	a.dmc.period = DMC_RATES[0]
	a.dmc.bits = 8
	a.dmc.silent = true
	// Power-on behaves as if $4017 = 0 was written just before reset.
	a.fc_delay = 3
	for i in 1 ..< len(a.pulse_mix) {
		a.pulse_mix[i] = 95.52 / (8128.0 / f32(i) + 100)
	}
	for i in 1 ..< len(a.tnd_mix) {
		a.tnd_mix[i] = 163.67 / (24329.0 / f32(i) + 100)
	}
	// The idle triangle sits at step 0 (level 15); start the high-pass
	// there so power-on doesn't click.
	a.hp_in = a.tnd_mix[int(TRIANGLE[0]) * 3]
}

apu_write :: proc(nes: ^Nes, addr: u16, v: u8) {
	a := &nes.apu
	switch addr {
	case 0x4000, 0x4004:
		p := &a.pulse[(addr >> 2) & 1]
		p.duty = v >> 6
		env_write(&p.env, v)
	case 0x4001, 0x4005:
		p := &a.pulse[(addr >> 2) & 1]
		p.sweep_on = v & 0x80 != 0
		p.sweep_period = (v >> 4) & 7
		p.sweep_neg = v & 0x08 != 0
		p.sweep_shift = v & 7
		p.sweep_reload = true
	case 0x4002, 0x4006:
		p := &a.pulse[(addr >> 2) & 1]
		p.period = (p.period & 0x700) | u16(v)
	case 0x4003, 0x4007:
		ch := (addr >> 2) & 1
		p := &a.pulse[ch]
		p.period = (p.period & 0xFF) | u16(v & 7) << 8
		if a.enabled & (u8(1) << ch) != 0 {
			p.length = LENGTHS[v >> 3]
		}
		p.step = 0
		p.env.start = true
	case 0x4008:
		a.tri.control = v & 0x80 != 0
		a.tri.linear_period = v & 0x7F
	case 0x400A:
		a.tri.period = (a.tri.period & 0x700) | u16(v)
	case 0x400B:
		a.tri.period = (a.tri.period & 0xFF) | u16(v & 7) << 8
		if a.enabled & 0x04 != 0 {
			a.tri.length = LENGTHS[v >> 3]
		}
		a.tri.linear_reload = true
	case 0x400C:
		env_write(&a.noise.env, v)
	case 0x400E:
		a.noise.mode = v & 0x80 != 0
		a.noise.period = NOISE_PERIODS[v & 0x0F]
	case 0x400F:
		if a.enabled & 0x08 != 0 {
			a.noise.length = LENGTHS[v >> 3]
		}
		a.noise.env.start = true
	case 0x4010:
		a.dmc.irq_on = v & 0x80 != 0
		a.dmc.loop = v & 0x40 != 0
		a.dmc.period = DMC_RATES[v & 0x0F]
		if !a.dmc.irq_on {
			a.dmc.irq = false
		}
	case 0x4011:
		a.dmc.level = v & 0x7F
	case 0x4012:
		a.dmc.start = 0xC000 | u16(v) << 6
	case 0x4013:
		a.dmc.length = u16(v) << 4 | 1
	case 0x4015:
		a.enabled = v & 0x0F
		if v & 0x01 == 0 {
			a.pulse[0].length = 0
		}
		if v & 0x02 == 0 {
			a.pulse[1].length = 0
		}
		if v & 0x04 == 0 {
			a.tri.length = 0
		}
		if v & 0x08 == 0 {
			a.noise.length = 0
		}
		if v & 0x10 == 0 {
			a.dmc.remaining = 0
		} else if a.dmc.remaining == 0 {
			a.dmc.addr = a.dmc.start
			a.dmc.remaining = a.dmc.length
		}
		a.dmc.irq = false
	case 0x4017:
		// The sequencer restarts 3 or 4 cycles later depending on CPU
		// cycle parity (the APU runs at half the CPU clock).
		a.fc_value = v
		a.fc_delay = 4 if nes.cpu.cycles & 1 != 0 else 3
		a.irq_inhibit = v & 0x40 != 0
		if a.irq_inhibit {
			a.frame_irq = false
		}
	}
}

// $4015 read: length counters, DMC active, IRQ flags. Acknowledges the
// frame IRQ.
apu_status :: proc(a: ^Apu) -> u8 {
	v: u8
	if a.pulse[0].length > 0 {
		v |= 0x01
	}
	if a.pulse[1].length > 0 {
		v |= 0x02
	}
	if a.tri.length > 0 {
		v |= 0x04
	}
	if a.noise.length > 0 {
		v |= 0x08
	}
	if a.dmc.remaining > 0 {
		v |= 0x10
	}
	if a.frame_irq {
		v |= 0x40
	}
	if a.dmc.irq {
		v |= 0x80
	}
	a.frame_irq = false
	return v
}

// A sample byte arrives from the DMC's DMA.
apu_dmc_fill :: proc(a: ^Apu, v: u8) {
	d := &a.dmc
	if d.remaining == 0 {
		return
	}
	d.buffer = v
	d.full = true
	d.addr += 1
	if d.addr == 0 {
		d.addr = 0x8000
	}
	d.remaining -= 1
	if d.remaining > 0 {
		return
	}
	if d.loop {
		d.addr = d.start
		d.remaining = d.length
	} else if d.irq_on {
		d.irq = true
	}
}

apu_step :: proc(nes: ^Nes) {
	a := &nes.apu
	frame_counter(a)

	// Pulse timers count CPU cycles at twice the register period.
	for &p in a.pulse {
		if p.timer == 0 {
			p.timer = p.period * 2 + 1
			p.step = (p.step + 1) & 7
		} else {
			p.timer -= 1
		}
	}
	t := &a.tri
	if t.timer == 0 {
		t.timer = t.period
		// Periods below 2 are ultrasonic; holding the step avoids pops.
		if t.length > 0 && t.linear > 0 && t.period >= 2 {
			t.step = (t.step + 1) & 31
		}
	} else {
		t.timer -= 1
	}
	n := &a.noise
	if n.timer == 0 {
		n.timer = n.period - 1
		feedback := (n.lfsr ~ (n.lfsr >> (u16(6) if n.mode else 1))) & 1
		n.lfsr = n.lfsr >> 1 | feedback << 14
	} else {
		n.timer -= 1
	}
	d := &a.dmc
	if d.timer == 0 {
		d.timer = d.period - 1
		dmc_clock(d)
	} else {
		d.timer -= 1
	}

	pulses := pulse_out(&a.pulse[0], true) + pulse_out(&a.pulse[1], false)
	noise: u8
	if n.length > 0 && n.lfsr & 1 == 0 {
		noise = env_volume(&n.env)
	}
	tnd := int(TRIANGLE[t.step]) * 3 + int(noise) * 2 + int(d.level)
	a.mix_sum += a.pulse_mix[pulses] + a.tnd_mix[tnd]
	a.mix_n += 1

	a.rate_acc += NES_RATE
	if a.rate_acc < CPU_HZ {
		return
	}
	a.rate_acc -= CPU_HZ
	x := a.mix_sum / f32(a.mix_n)
	a.mix_sum, a.mix_n = 0, 0
	a.hp_out = HIGH_PASS * (a.hp_out + x - a.hp_in)
	a.hp_in = x
	a.lp_out += LOW_PASS * (a.hp_out - a.lp_out)
	if a.sample_count < NES_SAMPLES_MAX {
		a.samples[a.sample_count] = i16(clamp(a.lp_out * 32767, -32768, 32767))
		a.sample_count += 1
	}
}

// NTSC frame sequencer, in CPU cycles after the last reset:
//   4-step: Q 7457, Q+H 14913, Q 22371, IRQ 29828-29830, Q+H 29829
//   5-step: Q 7457, Q+H 14913, Q 22371, Q+H 37281, wrap 37282
@(private = "file")
frame_counter :: proc(a: ^Apu) {
	a.fc_cycle += 1
	switch a.fc_cycle {
	case 7457, 22371:
		frame_clock(a, false)
	case 14913:
		frame_clock(a, true)
	case 29828:
		if !a.five_step {
			frame_irq(a)
		}
	case 29829:
		if !a.five_step {
			frame_irq(a)
			frame_clock(a, true)
		}
	case 29830:
		if !a.five_step {
			frame_irq(a)
			a.fc_cycle = 0
		}
	case 37281:
		frame_clock(a, true)
	case 37282:
		a.fc_cycle = 0
	}
	if a.fc_delay > 0 {
		a.fc_delay -= 1
		if a.fc_delay == 0 {
			a.five_step = a.fc_value & 0x80 != 0
			a.fc_cycle = 0
			// Entering 5-step mode clocks everything immediately.
			if a.five_step {
				frame_clock(a, true)
			}
		}
	}
	if a.fc_block > 0 {
		a.fc_block -= 1
	}
}

@(private = "file")
frame_irq :: proc(a: ^Apu) {
	if !a.irq_inhibit {
		a.frame_irq = true
	}
}

// Quarter frame: envelopes, linear counter. Half frame adds length
// counters and sweeps.
@(private = "file")
frame_clock :: proc(a: ^Apu, half: bool) {
	if a.fc_block > 0 {
		return
	}
	a.fc_block = 2
	env_clock(&a.pulse[0].env)
	env_clock(&a.pulse[1].env)
	env_clock(&a.noise.env)
	t := &a.tri
	if t.linear_reload {
		t.linear = t.linear_period
	} else if t.linear > 0 {
		t.linear -= 1
	}
	if !t.control {
		t.linear_reload = false
	}
	if !half {
		return
	}
	for &p, i in a.pulse {
		if !p.env.loop && p.length > 0 {
			p.length -= 1
		}
		sweep_clock(&p, i == 0)
	}
	if !t.control && t.length > 0 {
		t.length -= 1
	}
	if !a.noise.env.loop && a.noise.length > 0 {
		a.noise.length -= 1
	}
}

// Pulse 1 negates with one's complement (one extra), pulse 2 with two's.
@(private = "file")
sweep_target :: proc(p: ^Pulse, ones: bool) -> int {
	change := int(p.period >> p.sweep_shift)
	if !p.sweep_neg {
		return int(p.period) + change
	}
	return int(p.period) - change - (1 if ones else 0)
}

@(private = "file")
sweep_clock :: proc(p: ^Pulse, ones: bool) {
	target := sweep_target(p, ones)
	if p.sweep_div == 0 &&
	   p.sweep_on &&
	   p.sweep_shift > 0 &&
	   p.period >= 8 &&
	   target >= 0 &&
	   target <= 0x7FF {
		p.period = u16(target)
	}
	if p.sweep_div == 0 || p.sweep_reload {
		p.sweep_div = p.sweep_period
		p.sweep_reload = false
	} else {
		p.sweep_div -= 1
	}
}

// Muted below period 8 or when the sweep would overflow, even with the
// sweep disabled.
@(private = "file")
pulse_out :: #force_inline proc(p: ^Pulse, ones: bool) -> u8 {
	if p.length == 0 || p.period < 8 || DUTY[p.duty] & (u8(0x80) >> p.step) == 0 {
		return 0
	}
	if sweep_target(p, ones) > 0x7FF {
		return 0
	}
	return env_volume(&p.env)
}

@(private = "file")
env_write :: proc(e: ^Envelope, v: u8) {
	e.loop = v & 0x20 != 0
	e.constant = v & 0x10 != 0
	e.period = v & 0x0F
}

@(private = "file")
env_clock :: proc(e: ^Envelope) {
	if e.start {
		e.start = false
		e.decay = 15
		e.divider = e.period
		return
	}
	if e.divider > 0 {
		e.divider -= 1
		return
	}
	e.divider = e.period
	if e.decay > 0 {
		e.decay -= 1
	} else if e.loop {
		e.decay = 15
	}
}

@(private = "file")
env_volume :: #force_inline proc(e: ^Envelope) -> u8 {
	return e.period if e.constant else e.decay
}

// Output unit: one delta bit per timer clock, refilled from the buffer
// every 8 bits.
@(private = "file")
dmc_clock :: proc(d: ^Dmc) {
	if !d.silent {
		if d.shift & 1 != 0 {
			if d.level <= 125 {
				d.level += 2
			}
		} else if d.level >= 2 {
			d.level -= 2
		}
		d.shift >>= 1
	}
	d.bits -= 1
	if d.bits > 0 {
		return
	}
	d.bits = 8
	d.silent = !d.full
	if d.full {
		d.shift = d.buffer
		d.full = false
	}
}
