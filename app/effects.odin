// Message effects, the slint pair: inline glyph fx markup inside a
// body, and one-shot particle bursts over a message.
//
// Markup is `{name}…{/name}` with the same eight names the slint
// renderer decodes as bits (src/render.rs apply_effect), so a message
// written in either app reads the same in the other. Motion effects
// split the run per letter, like slint's RunCell, so each glyph moves
// on its own.
//
// Bursts travel as ["effect", <key>] on encrypted kind-9 messages.
// The send queue retains the tag across uploads, replies and retries.
package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// ── Inline glyph effects ────────────────────────────────────────────

FX_BIG :: u8(1)
FX_SMALL :: u8(2)
FX_EXPLODE :: u8(4)
FX_BLOOM :: u8(8)
FX_SHAKE :: u8(16)
FX_NOD :: u8(32)
FX_RIPPLE :: u8(64)
FX_JITTER :: u8(128)

// Anything but big/small moves, and motion is what needs per-letter
// segs.
FX_MOTION :: FX_EXPLODE | FX_BLOOM | FX_SHAKE | FX_NOD | FX_RIPPLE | FX_JITTER

// Longest per-letter run: past this the split would overflow the
// per-seg id space render_segs hands out.
FX_LETTERS_MAX :: 100

FX_NAMES := []struct {
	name: string,
	bit:  u8,
} {
	{"big", FX_BIG},
	{"small", FX_SMALL},
	{"explode", FX_EXPLODE},
	{"bloom", FX_BLOOM},
	{"shake", FX_SHAKE},
	{"nod", FX_NOD},
	{"ripple", FX_RIPPLE},
	{"jitter", FX_JITTER},
}

// `{name}` at `at`: its bit and the offset just past the marker.
fx_open_at :: proc(text: string, at: int) -> (bit: u8, after: int, ok: bool) {
	if at >= len(text) || text[at] != '{' {
		return 0, 0, false
	}
	for entry in FX_NAMES {
		marker := len(entry.name) + 2
		if at + marker <= len(text) &&
		   text[at + 1:at + marker - 1] == entry.name &&
		   text[at + marker - 1] == '}' {
			return entry.bit, at + marker, true
		}
	}
	return 0, 0, false
}

// End of the `{/name}` closing `bit`, searching from `at`. Unclosed
// markup runs to the end of the text, so a stray `{shake}` still
// renders rather than showing its marker.
fx_close :: proc(text: string, at: int, bit: u8) -> (inner_end, after: int) {
	name := ""
	for entry in FX_NAMES {
		if entry.bit == bit {
			name = entry.name
		}
	}
	closer := strings.concatenate({"{/", name, "}"}, context.temp_allocator)
	if idx := strings.index(text[at:], closer); idx >= 0 {
		return at + idx, at + idx + len(closer)
	}
	return len(text), len(text)
}

// Motion budget in px, both axes: render_segs pads a glyph's cell by
// this much on every side and clamps the transform to it, so a moving
// glyph never leaves its cell. Stacked effects (shake + jitter + nod)
// can ask for a little more and get clipped to it.
FX_AMP :: f32(4)

// Per-glyph transform for a set of effect bits: pixel offsets, a font
// scale, and an alpha scale. `slot` is the glyph's index in the run, so
// ripple and jitter differ letter by letter.
fx_transform :: proc(fx: u8, slot: int, t: f64) -> (dx, dy: f32, size_mul, alpha_mul: f32) {
	size_mul = 1
	alpha_mul = 1
	phase := t * 6 + f64(slot) * 0.6

	if fx & FX_BIG != 0 {
		size_mul *= 1.45
	}
	if fx & FX_SMALL != 0 {
		size_mul *= 0.7
	}
	if fx & FX_SHAKE != 0 {
		dx += 1.6 * sin_approx(t * 34 + f64(slot))
	}
	if fx & FX_JITTER != 0 {
		// Two incommensurate rates read as random without a PRNG.
		dx += 1.3 * sin_approx(t * 41 + f64(slot) * 2.3)
		dy += 1.3 * sin_approx(t * 27 + f64(slot) * 5.1)
	}
	if fx & FX_NOD != 0 {
		dy += 1.8 * sin_approx(t * 5 + f64(slot) * 0.15)
	}
	if fx & FX_RIPPLE != 0 {
		dy += 2.4 * sin_approx(phase)
	}
	if fx & FX_BLOOM != 0 {
		alpha_mul *= 0.65 + 0.35 * (0.5 + 0.5 * sin_approx(t * 3 + f64(slot) * 0.4))
		size_mul *= 1 + 0.06 * sin_approx(t * 3 + f64(slot) * 0.4)
	}
	if fx & FX_EXPLODE != 0 {
		// A slow breathe out and back, so the run keeps pulsing rather
		// than blowing apart once and leaving a hole in the line.
		push := 0.5 + 0.5 * sin_approx(t * 2 + f64(slot) * 0.9)
		dy -= 2.5 * push
		size_mul *= 1 + 0.25 * push
	}
	return
}

// ── Particle bursts ─────────────────────────────────────────────────

// (catalog id, wire key, emoji), the slint EFFECTS table.
EFFECTS := []struct {
	id:    int,
	key:   string,
	emoji: string,
} {
	{1, "love", "❤️"},
	{2, "fire", "🔥"},
	{3, "party", "🎉"},
	{4, "star", "⭐"},
	{5, "like", "👍"},
}

EFFECT_TAG :: "effect"

effect_id_from_key :: proc(key: string) -> int {
	for e in EFFECTS {
		if e.key == key {
			return e.id
		}
	}
	return 0
}

effect_emoji :: proc(id: int) -> string {
	for e in EFFECTS {
		if e.id == id {
			return e.emoji
		}
	}
	return ""
}

// The `["effect", <key>]` tag on a record, 0 when there is none. The
// slint app writes it; nothing here can, so this is the receive half.
record_effect :: proc(record: ^marmot.Timeline_Message_Record) -> int {
	for t in 0 ..< record.tags_len {
		tag := &record.tags[t]
		if tag.values_len >= 2 && string(tag.values[0]) == EFFECT_TAG {
			return effect_id_from_key(string(tag.values[1]))
		}
	}
	return 0
}

BURST_PARTICLES :: 24
BURST_SECS :: 1.6
EMITTERS_MAX :: 4

// What the particles are made of.
Emit_Mode :: enum {
	Tile, // an emoji tile: reactions and message effects
	Pill, // a stretched accent streak: the send whoosh
	Shard, // small falling pieces: a deleted message coming apart
}

// One running burst of particles. `anchor` is the message id it hangs
// off, "" for the composer.
Emitter :: struct {
	anchor: string,
	tex:    ^rl.Texture2D,
	start:  f64,
	count:  int,
	rise:   f32, // px travelled up over the burst
	spread: f32, // px fanned across
	secs:   f64,
	mode:   Emit_Mode,
}

// A fixed pool: bursts are transient and overlapping ones are rare, so
// the oldest slot is recycled rather than grown.
emitters: [EMITTERS_MAX]Emitter

emit :: proc(
	anchor: string,
	tex: ^rl.Texture2D,
	count: int,
	rise, spread: f32,
	secs: f64 = BURST_SECS,
	mode: Emit_Mode = .Tile,
) {
	if !motion_on() {
		return
	}
	slot := 0
	for i in 1 ..< EMITTERS_MAX {
		if emitters[i].start < emitters[slot].start {
			slot = i
		}
	}
	delete(emitters[slot].anchor)
	emitters[slot] = {strings.clone(anchor), tex, rl.GetTime(), count, rise, spread, secs, mode}
}

// Message ids whose effect has already played, so a timeline reload
// doesn't replay every effect in the page.
burst_seen: map[string]bool

burst_play :: proc(msg_id: string, effect: int) {
	if effect == 0 {
		return
	}
	emit(msg_id, emoji_tex(effect_emoji(effect)), BURST_PARTICLES, 190, 320)
}

// The send whoosh: a short accent streak rising off the composer, so a
// message visibly leaves rather than just appearing above.
WHOOSH_TRAILS :: 3
WHOOSH_SECS :: 0.45

whoosh :: proc() {
	emit("", nil, WHOOSH_TRAILS, 120, 26, WHOOSH_SECS, .Pill)
}

// A deleted message coming apart: the row shrinks into its tombstone
// (delete_collapse) while the body it held falls out of it.
DISSOLVE_SHARDS :: 26
DISSOLVE_SECS :: 0.7

dissolve :: proc(msg_id: string) {
	emit(msg_id, nil, DISSOLVE_SHARDS, 40, 520, DISSOLVE_SECS, .Shard)
}

// A reaction the user just added, popping off the message it lands on.
react_burst :: proc(msg_id: string, emoji: string) {
	if tex := emoji_tex(emoji); tex != nil {
		emit(msg_id, tex, 8, 70, 90, 0.8)
	}
}

// When the local burst played for an own send, so the confirmed record
// coming back with its tag doesn't replay it.
@(private = "file")
burst_local_at: f64 = -100

BURST_ECHO_SECS :: 20.0

// Play an effect the first time its message is seen.
burst_arrive :: proc(msg_id: string, effect: int, mine: bool) {
	if effect == 0 || len(msg_id) == 0 || burst_seen[msg_id] {
		return
	}
	burst_seen[strings.clone(msg_id)] = true
	// Your own send already burst when you hit Enter; the record
	// arriving with the tag is the same event coming home.
	if mine && rl.GetTime() - burst_local_at < BURST_ECHO_SECS {
		return
	}
	burst_play(msg_id, effect)
}

// Particles float up and out from the message row, fading as they go.
// They are floating elements offset per particle: clay has no free
// positioning, and a floating child takes an arbitrary offset.
burst_layer :: proc(index: u32, msg_id: string) {
	if len(msg_id) == 0 {
		return
	}
	for slot in 0 ..< EMITTERS_MAX {
		if emitters[slot].anchor == msg_id {
			burst_particles(index, slot)
		}
	}
}

// Bursts with no message to hang off rise from the composer: an own
// send has no id yet, and the whoosh belongs to the composer anyway.
burst_pane_layer :: proc() {
	for slot in 0 ..< EMITTERS_MAX {
		if len(emitters[slot].anchor) == 0 {
			burst_particles(0xB000 + u32(slot), slot)
		}
	}
}

@(private = "file")
burst_particles :: proc(index: u32, slot: int) {
	e := &emitters[slot]
	if e.count == 0 {
		return
	}
	elapsed := rl.GetTime() - e.start
	if elapsed > e.secs {
		return
	}
	anim_moving += 1

	progress := f32(elapsed / e.secs)
	for i in 0 ..< e.count {
		// Fan the particles across the row, each with its own speed.
		spread := e.count > 1 ? f32(i) / f32(e.count - 1) : 0.5 // 0..1
		speed := 0.6 + 0.4 * (0.5 + 0.5 * sin_approx(f64(i) * 1.7))
		x := (spread - 0.5) * e.spread * (0.35 + progress * speed)
		y := -progress * speed * e.rise + 40 * progress * progress
		size := 14 + 10 * (1 - progress)
		alpha := clamp(255 * (1 - progress * progress), 0, 255)
		id := clay.ID("BurstDot", (index * EMITTERS_MAX + u32(slot)) * 64 + u32(i))
		if e.mode == .Shard {
			// Pieces of the row: fanned across its width, falling under
			// their own gravity and thinning as they go.
			drift := (spread - 0.5) * e.spread
			fall := progress * progress * 90 * speed
			side := 5 + 7 * (1 - progress)
			if clay.UI(id)(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(side),
						height = clay.SizingFixed(side * 0.7),
					},
				},
				floating = {
					attachTo = .Parent,
					zIndex = 9,
					offset = {drift, fall - 10},
					attachment = {element = .CenterCenter, parent = .CenterCenter},
				},
				backgroundColor = {TEXT_LO.r, TEXT_LO.g, TEXT_LO.b, alpha},
				cornerRadius = rr(2),
			},
			) {}
			continue
		}
		if e.mode == .Pill {
			// The whoosh: a stretched accent pill, thinning as it rises.
			if clay.UI(id)(
			{
				layout = {
					sizing = {width = clay.SizingFixed(3), height = clay.SizingFixed(size * 1.6)},
				},
				floating = {
					attachTo = .Parent,
					zIndex = 9,
					offset = {x, y},
					attachment = {element = .CenterCenter, parent = .CenterCenter},
				},
				backgroundColor = {ACCENT.r, ACCENT.g, ACCENT.b, alpha * 0.7},
				cornerRadius = rr(2),
			},
			) {}
			continue
		}
		if clay.UI(id)(
		{
			layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
			floating = {
				attachTo = .Parent,
				zIndex = 9,
				offset = {x, y},
				attachment = {element = .CenterCenter, parent = .CenterCenter},
			},
			image = {imageData = e.tex},
			overlayColor = {255, 255, 255, alpha}, // the renderer's image tint
		},
		) {}
	}
}

// Spend the armed effect on the send that just left. Own sends have no
// message id yet (the row on screen is the optimistic one), so the
// burst anchors to the pane and rises from the composer instead.
fx_send_armed :: proc(ui: ^Ui_State) {
	whoosh()
	if ui.fx_armed == 0 {
		return
	}
	burst_play("", ui.fx_armed)
	burst_local_at = rl.GetTime()
	ui.fx_armed = 0
}

// ── Composer picker ─────────────────────────────────────────────────

// Small popover over the composer: pick an effect for the next send.
effect_picker :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("FxPanel"))(
	{
		// Right-anchored: the star sits near the window's right edge, so
		// a left-anchored panel would run off-screen.
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(300)},
			padding = clay.PaddingAll(12),
			childGap = 8,
		},
		floating = {
			attachTo = .Parent,
			zIndex = 12,
			offset = {0, -10 + rise(clay.ID("FxPanel"))},
			attachment = {element = .RightBottom, parent = .RightTop},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		eyebrow("SEND WITH EFFECT")
		if clay.UI(clay.ID("FxRow"))({layout = {childGap = 6}}) {
			for e, i in EFFECTS {
				armed := ui.fx_armed == e.id
				if clay.UI(clay.ID("FxOpt", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(38), height = clay.SizingFixed(38)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = armed ? SELECTED : (hovered() ? HOVER : ROW_BG),
					cornerRadius = rr(10),
					border = armed ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
				},
				) {
					if tex := emoji_tex(e.emoji); tex != nil {
						if clay.UI(clay.ID("FxOptImg", u32(i)))(
						{
							layout = {sizing = {width = clay.SizingFixed(20)}},
							aspectRatio = {1},
							image = {imageData = tex},
						},
						) {}
					} else {
						clay.Text(e.emoji, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
					}
				}
			}
		}
		if ui.fx_armed != 0 {
			micro_button("FxClear", "Clear effect")
		}
	}
}

handle_effects :: proc(ui: ^Ui_State) -> bool {
	if !ui.fx_open {
		return false
	}
	if rl.IsKeyPressed(.ESCAPE) {
		ui.fx_open = false
		return true
	}
	if !mouse_released() {
		return true
	}
	for e, i in EFFECTS {
		if clay.PointerOver(clay.ID("FxOpt", u32(i))) {
			ui.fx_armed = ui.fx_armed == e.id ? 0 : e.id
			ui.fx_open = false
			return true
		}
	}
	if clicked("FxClear") {
		ui.fx_armed = 0
		ui.fx_open = false
		return true
	}
	if !clay.PointerOver(clay.ID("FxPanel")) {
		ui.fx_open = false
	}
	return true
}
