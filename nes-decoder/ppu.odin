package main

// 2C02 PPU, stepped one dot at a time: 341 dots x 262 lines, the
// pre-render line one dot short on odd frames while rendering.
//
//   lines 0-239   visible: one pixel per dot 1-256, tile fetches
//   line  240     idle
//   lines 241-260 vblank (flag + NMI at 241 dot 1)
//   line  261     pre-render: same fetches, no pixels
//
// Background fetches follow the hardware 8-dot pattern into a 64-bit
// shifter of 4-bit pixels. Sprites for the next line are evaluated and
// drawn into spr_line at dot 257, which is all games need since OAM only
// changes in vblank. Pixels are master palette indices (0-63).

Ppu :: struct {
	ctrl:       u8,
	mask:       u8,
	status:     u8,
	oam_addr:   u8,
	v, t:       u16, // loopy scroll registers
	x:          u8, // fine x scroll
	w:          bool, // $2005/$2006 write toggle
	buffer:     u8, // $2007 read buffer
	latch:      u8, // last value on the PPU's CPU-facing bus (open bus)
	scanline:   int,
	dot:        int, // last dot processed on scanline
	odd:        bool,
	short_line: bool, // this pre-render line skips its last dot
	skip_vbl:   bool, // $2002 read the dot before vblank: no flag this frame
	frame_done: bool,
	nt, at:     u8, // fetched tile index and its palette bits << 2
	lo, hi:     u8, // fetched pattern bytes
	tiles:      u64, // 16 pixels (palette << 2 | pattern), current tile high
	spr_line:   [NES_W]u8, // palette address (0 = none) | 0x40 behind bg | 0x80 sprite 0
	oam:        [256]u8,
	palette:    [32]u8,
	ciram:      [0x1000]u8, // 2 KiB console VRAM, 4 KiB for four-screen carts
	screen:     [NES_W * NES_H]u8,
}

ppu_step :: proc(nes: ^Nes) {
	p := &nes.ppu
	rendering := p.mask & 0x18 != 0
	p.dot += 1
	// Odd frames drop the pre-render line's last dot if rendering was on
	// going into dot 338 (339 and 340 are both idle, so just jump ahead).
	if p.scanline == 261 {
		if p.dot == 338 {
			p.short_line = p.odd && rendering
		} else if p.dot == 339 && p.short_line {
			p.dot = 340
		}
	}
	if p.dot > 340 {
		p.dot = 0
		p.scanline += 1
		if p.scanline > 261 {
			p.scanline = 0
			p.odd = !p.odd
		}
	}
	line, dot := p.scanline, p.dot

	if line == 241 && dot == 1 {
		if !p.skip_vbl {
			p.status |= 0x80
		}
		p.skip_vbl = false
		p.frame_done = true
		return
	}
	if line >= 240 && line != 261 {
		return
	}
	pre := line == 261
	if pre && dot == 1 {
		p.status &= 0x1F // clear vblank, sprite 0 hit, overflow
	}

	if !rendering {
		if !pre && dot >= 1 && dot <= 256 {
			// Backdrop, or the palette entry v points at (the "palette hack").
			index := u16(0)
			if p.v & 0x3F00 == 0x3F00 {
				index = pal_index(p.v)
			}
			p.screen[line * NES_W + dot - 1] = color(p, p.palette[index])
		}
		if dot == 257 {
			p.spr_line = {}
		}
		return
	}

	if !pre && dot >= 1 && dot <= 256 {
		render_pixel(p, line, dot - 1)
	}
	if (dot >= 1 && dot <= 256) || (dot >= 321 && dot <= 336) {
		p.tiles <<= 4
		switch dot & 7 {
		case 1:
			p.nt = ppu_read(nes, 0x2000 | (p.v & 0x0FFF))
		case 3:
			v := p.v
			a := ppu_read(nes, 0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x38) | ((v >> 2) & 0x07))
			p.at = ((a >> (((v >> 4) & 4) | (v & 2))) & 3) << 2
		case 5:
			p.lo = ppu_read(nes, bg_pattern(p))
		case 7:
			p.hi = ppu_read(nes, bg_pattern(p) + 8)
		case 0:
			data: u64
			lo, hi := p.lo, p.hi
			for _ in 0 ..< 8 {
				data = data << 4 | u64(p.at | lo >> 7 | (hi >> 6) & 2)
				lo <<= 1
				hi <<= 1
			}
			p.tiles |= data
			// Coarse x, wrapping into the horizontal nametable.
			if p.v & 0x001F == 31 {
				p.v = (p.v & ~u16(0x001F)) ~ 0x0400
			} else {
				p.v += 1
			}
		}
	}
	switch dot {
	case 256:
		increment_y(p)
	case 257:
		p.v = (p.v & ~u16(0x041F)) | (p.t & 0x041F)
		p.spr_line = {}
		if !pre {
			eval_sprites(nes, line)
		}
	case 261:
		// MMC3 sees A12 rise with sprite 0's pattern fetch, right after
		// dot 260 (BG at $0000, sprites at $1000: the common setup).
		cart_scanline(&nes.cart)
	case 280 ..= 304:
		if pre {
			p.v = (p.v & ~u16(0x7BE0)) | (p.t & 0x7BE0)
		}
	}
}

ppu_reg_read :: proc(nes: ^Nes, reg: u16) -> u8 {
	p := &nes.ppu
	switch reg {
	case 2:
		v := (p.status & 0xE0) | (p.latch & 0x1F)
		p.status &= 0x7F
		p.w = false
		// Reading just before the flag would be set loses it (and its NMI).
		if p.scanline == 241 && p.dot == 0 {
			p.skip_vbl = true
		}
		p.latch = v
	case 4:
		p.latch = p.oam[p.oam_addr]
	case 7:
		addr := p.v & 0x3FFF
		if addr >= 0x3F00 {
			// Palette reads are immediate; the buffer gets the nametable below.
			p.latch = (p.palette[pal_index(addr)] & 0x3F) | (p.latch & 0xC0)
			p.buffer = ppu_read(nes, addr - 0x1000)
		} else {
			p.latch = p.buffer
			p.buffer = ppu_read(nes, addr)
		}
		p.v = (p.v + vram_step(p)) & 0x7FFF
	}
	return p.latch
}

ppu_reg_write :: proc(nes: ^Nes, reg: u16, v: u8) {
	p := &nes.ppu
	p.latch = v
	switch reg {
	case 0:
		p.ctrl = v
		p.t = (p.t & 0xF3FF) | u16(v & 3) << 10
	case 1:
		p.mask = v
	case 3:
		p.oam_addr = v
	case 4:
		// Attribute bits 2-4 don't exist.
		p.oam[p.oam_addr] = v & 0xE3 if p.oam_addr & 3 == 2 else v
		p.oam_addr += 1
	case 5:
		if !p.w {
			p.t = (p.t & 0x7FE0) | u16(v >> 3)
			p.x = v & 7
		} else {
			p.t = (p.t & 0x0C1F) | u16(v & 7) << 12 | u16(v & 0xF8) << 2
		}
		p.w = !p.w
	case 6:
		if !p.w {
			p.t = (p.t & 0x00FF) | u16(v & 0x3F) << 8
		} else {
			p.t = (p.t & 0x7F00) | u16(v)
			p.v = p.t
		}
		p.w = !p.w
	case 7:
		ppu_write(nes, p.v & 0x3FFF, v)
		p.v = (p.v + vram_step(p)) & 0x7FFF
	}
}

@(private = "file")
ppu_read :: proc(nes: ^Nes, addr: u16) -> u8 {
	a := addr & 0x3FFF
	if a < 0x2000 {
		return cart_chr_read(&nes.cart, a)
	}
	if a < 0x3F00 {
		return nes.ppu.ciram[nes.cart.nt_map[(a >> 10) & 3] + (a & 0x3FF)]
	}
	return nes.ppu.palette[pal_index(a)]
}

@(private = "file")
ppu_write :: proc(nes: ^Nes, addr: u16, v: u8) {
	switch {
	case addr < 0x2000:
		cart_chr_write(&nes.cart, addr, v)
	case addr < 0x3F00:
		nes.ppu.ciram[nes.cart.nt_map[(addr >> 10) & 3] + (addr & 0x3FF)] = v
	case:
		nes.ppu.palette[pal_index(addr)] = v & 0x3F
	}
}

// $3F10/$3F14/$3F18/$3F1C mirror the background entries below them.
@(private = "file")
pal_index :: #force_inline proc(addr: u16) -> u16 {
	i := addr & 0x1F
	if i & 0x13 == 0x10 {
		i &= 0x0F
	}
	return i
}

@(private = "file")
vram_step :: #force_inline proc(p: ^Ppu) -> u16 {
	return 32 if p.ctrl & 0x04 != 0 else 1
}

@(private = "file")
color :: #force_inline proc(p: ^Ppu, entry: u8) -> u8 {
	return entry & (0x30 if p.mask & 0x01 != 0 else 0x3F) // greyscale
}

@(private = "file")
bg_pattern :: #force_inline proc(p: ^Ppu) -> u16 {
	table := u16(0x1000) if p.ctrl & 0x10 != 0 else 0
	return table + u16(p.nt) * 16 + (p.v >> 12) & 7
}

// Fine y, then coarse y wrapping at row 29 into the vertical nametable.
@(private = "file")
increment_y :: proc(p: ^Ppu) {
	if p.v & 0x7000 != 0x7000 {
		p.v += 0x1000
		return
	}
	p.v &= ~u16(0x7000)
	y := (p.v & 0x03E0) >> 5
	switch y {
	case 29:
		y = 0
		p.v ~= 0x0800
	case 31:
		y = 0
	case:
		y += 1
	}
	p.v = (p.v & ~u16(0x03E0)) | y << 5
}

@(private = "file")
render_pixel :: #force_inline proc(p: ^Ppu, line: int, x: int) {
	bg: u8
	if p.mask & 0x08 != 0 && (x >= 8 || p.mask & 0x02 != 0) {
		bg = u8(p.tiles >> (32 + uint(7 - p.x) * 4)) & 0x0F
		if bg & 3 == 0 {
			bg = 0
		}
	}
	index := bg
	if p.mask & 0x10 != 0 && (x >= 8 || p.mask & 0x04 != 0) {
		sp := p.spr_line[x]
		if sp != 0 {
			if bg != 0 && sp & 0x80 != 0 && x != 255 {
				p.status |= 0x40
			}
			if bg == 0 || sp & 0x40 == 0 {
				index = sp & 0x1F
			}
		}
	}
	p.screen[line * NES_W + x] = color(p, p.palette[index])
}

// Finds the first 8 sprites on line + 1 (OAM y is one less than the first
// line drawn) and draws them into spr_line; lower OAM index wins.
@(private = "file")
eval_sprites :: proc(nes: ^Nes, line: int) {
	p := &nes.ppu
	height := 16 if p.ctrl & 0x20 != 0 else 8
	count := 0
	for i in 0 ..< 64 {
		row := line - int(p.oam[i * 4])
		if row < 0 || row >= height {
			continue
		}
		if count == 8 {
			p.status |= 0x20 // ponytail: no hardware overflow-scan bug
			break
		}
		count += 1
		tile, attr, sx := p.oam[i * 4 + 1], p.oam[i * 4 + 2], int(p.oam[i * 4 + 3])
		if attr & 0x80 != 0 {
			row = height - 1 - row
		}
		addr: u16
		if height == 8 {
			table := u16(0x1000) if p.ctrl & 0x08 != 0 else 0
			addr = table + u16(tile) * 16 + u16(row)
		} else {
			addr = u16(tile & 1) * 0x1000 + u16(tile & 0xFE) * 16 + u16(row & 7) + u16(row & 8) * 2
		}
		lo := ppu_read(nes, addr)
		hi := ppu_read(nes, addr + 8)
		flags :=
			0x10 |
			(attr & 3) << 2 |
			(u8(0x40) if attr & 0x20 != 0 else 0) |
			(u8(0x80) if i == 0 else 0)
		for px in 0 ..< 8 {
			x := sx + px
			if x >= NES_W {
				break
			}
			bit := uint(px if attr & 0x40 != 0 else 7 - px)
			c := (lo >> bit) & 1 | ((hi >> bit) & 1) << 1
			if c != 0 && p.spr_line[x] == 0 {
				p.spr_line[x] = flags | c
			}
		}
	}
}
