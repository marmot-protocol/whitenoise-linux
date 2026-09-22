// Motion primitives. clay is immediate mode: nothing survives a frame,
// so every animation needs one retained float somewhere. That somewhere
// is here, a map keyed by clay element id (or any hash), plus the two
// curves the whole app animates on:
//
//   anim_to  exponential approach, frame-rate independent. Hovers,
//            widths, offsets, anything that must land and stay.
//   anim_pop damped spring with overshoot. Badges, chips, reactions,
//            anything that should feel like it has mass.
//
// Entries untouched for ANIM_STALE frames are dropped, so a scrolled
// away row costs nothing. `anim_moving` counts what is still settling;
// the main loop idles the frame rate when it is zero.
package main

import "core:math"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

ANIM_RATE :: f32(16) // default approach rate, ~1/e per 60ms
HOVER_RATE :: f32(24) // fills and borders: fast enough to feel instant, slow enough to read
ANIM_EPS :: f32(0.0008) // closer than this counts as landed
ANIM_STALE :: u32(240)
ANIM_GC_EVERY :: u32(256)

Anim :: struct {
	v:     f32,
	vel:   f32,
	frame: u32,
}

Anim_Color :: struct {
	v:     [4]f32,
	frame: u32,
}

anim_vals: map[u32]Anim
anim_cols: map[u32]Anim_Color

anim_frame: u32
anim_dt: f32 = 1.0 / 60
anim_moving: int // values still settling this frame

// One id, several animated properties: mix in a slot so a background
// color and a border color on the same element don't share a value.
anim_key :: proc(id: u32, slot: u32) -> u32 {
	return id ~ (slot * 0x9e3779b9)
}

// Frame start: fix the timestep and retire stale entries. A stalled
// frame (a blocking send, a file dialog) is clamped so springs step
// forward rather than teleporting.
anim_tick :: proc(dt: f32) {
	anim_dt = clamp(dt, 0.001, 0.05)
	anim_frame += 1
	anim_moving = 0

	if anim_frame % ANIM_GC_EVERY != 0 {
		return
	}
	dead := make([dynamic]u32, context.temp_allocator)
	for key, entry in anim_vals {
		if anim_frame - entry.frame > ANIM_STALE {
			append(&dead, key)
		}
	}
	for key in dead {
		delete_key(&anim_vals, key)
	}
	clear(&dead)
	for key, entry in anim_cols {
		if anim_frame - entry.frame > ANIM_STALE {
			append(&dead, key)
		}
	}
	for key in dead {
		delete_key(&anim_cols, key)
	}
}

// Exponential approach toward target. The first sighting of a key
// starts there, so an element appearing never animates in from zero.
anim_to :: proc(key: u32, target: f32, rate: f32 = ANIM_RATE) -> f32 {
	entry, seen := anim_vals[key]
	if seen && entry.frame == anim_frame {
		return entry.v // already stepped this frame; two readers, one step
	}
	if !seen || !motion_on() {
		entry.v = target
		entry.vel = 0
	}
	entry.v += (target - entry.v) * (1 - math.exp(-rate * anim_dt))
	if abs(target - entry.v) < ANIM_EPS {
		entry.v = target
		entry.vel = 0
	} else {
		anim_moving += 1
	}
	entry.frame = anim_frame
	anim_vals[key] = entry
	return entry.v
}

// Pin a value without easing. A gutter drag tracks the pointer exactly;
// the entry must follow it, or release replays the whole move from
// where the drag began.
anim_set :: proc(key: u32, v: f32) {
	anim_vals[key] = {
		v     = v,
		frame = anim_frame,
	}
}

// A global geometry discontinuity (a zoom change): every eased value
// would otherwise glide in from coordinates that no longer exist, a
// second animation on top of the instant rescale. Drop them all; the
// first sighting of each key snaps to its target.
anim_snap_all :: proc() {
	clear(&anim_vals)
}

// Damped spring. Overshoots by design: that is what reads as physical.
anim_pop :: proc(key: u32, target: f32, stiff: f32 = 260, damp: f32 = 18) -> f32 {
	entry, seen := anim_vals[key]
	if seen && entry.frame == anim_frame {
		return entry.v
	}
	if !seen || !motion_on() {
		entry.v = target
		entry.vel = 0
	}
	entry.vel += (stiff * (target - entry.v) - damp * entry.vel) * anim_dt
	entry.v += entry.vel * anim_dt
	if abs(target - entry.v) < ANIM_EPS && abs(entry.vel) < ANIM_EPS {
		entry.v = target
		entry.vel = 0
	} else {
		anim_moving += 1
	}
	entry.frame = anim_frame
	anim_vals[key] = entry
	return entry.v
}

// Kick a spring without moving its target: the pop for something that
// is already on screen (a badge whose count changed).
anim_kick :: proc(key: u32, velocity: f32) {
	entry := anim_vals[key]
	entry.vel += velocity
	entry.frame = anim_frame
	anim_vals[key] = entry
}

anim_color :: proc(key: u32, target: clay.Color, rate: f32 = ANIM_RATE) -> clay.Color {
	entry, seen := anim_cols[key]
	goal := [4]f32{target.r, target.g, target.b, target.a}
	if !seen || !motion_on() {
		entry.v = goal
	}
	step := 1 - math.exp(-rate * anim_dt)
	settled := true
	for i in 0 ..< 4 {
		entry.v[i] += (goal[i] - entry.v[i]) * step
		if abs(goal[i] - entry.v[i]) < 0.4 {
			entry.v[i] = goal[i]
		} else {
			settled = false
		}
	}
	if !settled {
		anim_moving += 1
	}
	entry.frame = anim_frame
	anim_cols[key] = entry
	return {entry.v[0], entry.v[1], entry.v[2], entry.v[3]}
}

// Fraction of a residual to spend this frame for a per-second rate.
anim_drain :: proc(rate: f32) -> f32 {
	return 1 - math.exp(-rate * anim_dt)
}

mix_color :: proc(a, b: clay.Color, t: f32) -> clay.Color {
	k := clamp(t, 0, 1)
	return {
		a.r + (b.r - a.r) * k,
		a.g + (b.g - a.g) * k,
		a.b + (b.b - a.b) * k,
		a.a + (b.a - a.a) * k,
	}
}

fade :: proc(color: clay.Color, alpha: f32) -> clay.Color {
	return {color.r, color.g, color.b, color.a * clamp(alpha, 0, 1)}
}

// 0 at t=0, 1 at t=1, flat at both ends.
ease_out :: proc(t: f32) -> f32 {
	k := 1 - clamp(t, 0, 1)
	return 1 - k * k * k
}

// Whether motion is allowed at all. With the Appearance toggle off,
// every curve below snaps to its target and the one-shot effects
// (flights, bursts, the theme reveal, shake) never start, so the app
// still changes state, it just stops moving.
motion_on :: proc() -> bool {
	return g_prefs == nil || !g_prefs.reduce_motion
}

// Slow at both ends: the curve for something crossing the screen.
ease_in_out :: proc(t: f32) -> f32 {
	k := clamp(t, 0, 1)
	return k < 0.5 ? 4 * k * k * k : 1 - 4 * (1 - k) * (1 - k) * (1 - k)
}

// Overshoots past 1 and comes back: a landing, not an arrival.
ease_back :: proc(t: f32) -> f32 {
	OVERSHOOT :: f32(1.7)
	k := clamp(t, 0, 1) - 1
	return k * k * ((OVERSHOOT + 1) * k + OVERSHOOT) + 1
}

// The box clay gave an element last frame, if it was laid out at all.
element_box :: proc(id: clay.ElementId) -> (clay.BoundingBox, bool) {
	data := clay.GetElementData(id)
	return data.boundingBox, data.found
}

// ── View transitions ────────────────────────────────────────────────

PAGE_SECS :: 0.22
PAGE_SLIDE :: f32(10) // how far the new page rises into place
PAGE_SETTLE :: 0.4 // grace after a switch: arrivals inside it are "already there"

// What counts as a different view: the page, the selected chat, the
// new-chat pane. Anything that swaps the whole main card.
page_view_key :: proc(ui: ^Ui_State) -> u32 {
	key := u32(ui.page) * 131 + u32(ui.selected + 2) * 7919
	if ui.show_members {
		key ~= 0x2ab17e10 // the group-info page swaps the whole chat area
	}
	if ui.group_files_open {key ~= 0x31f19a24}
	return ui.new_chat_open ? key ~ 0x5bf03635 : key
}

page_shown: u32
page_at: f64
page_t: f32 = 1 // 0 on switch, 1 once the new page has landed
page_held: bool // switched this frame: the renderer keeps the old frame

// Called once per frame, at the top of the layout.
page_advance :: proc(ui: ^Ui_State) {
	if key := page_view_key(ui); key != page_shown {
		page_shown = key
		page_at = rl.GetTime()
		page_held = motion_on()
	}
	page_t = motion_on() ? ease_out(f32(clamp((rl.GetTime() - page_at) / PAGE_SECS, 0, 1))) : 1
	if page_t < 1 {
		anim_moving += 1
	}
}

// ── Panels that open and close ──────────────────────────────────────

OPEN_RATE :: f32(22)
OPEN_SCALE :: f32(0.94) // width a panel starts at, as a share of its own
RISE_PX :: f32(8)
OPEN_GONE :: f32(0.004) // below this it is off screen

Open :: struct {
	v:     f32, // 0 gone, 1 fully open
	frame: u32,
}

opens: map[u32]Open

// Whether a panel is on screen at all: true while it is open, and for
// the moment it spends easing back out afterwards. Call sites use it as
// their mount condition, so a closed panel stays mounted long enough to
// leave. A panel not seen before starts at 0, so it always animates in.
//
// The state behind a closing panel has usually been cleared already,
// which is why the few modals that free their own payload hold it until
// the next open (confirm.odin) and the two index-addressed menus keep
// the index they were opened on (rowactions.odin, menus.odin).
open_now :: proc(id: clay.ElementId, open: bool) -> bool {
	return open_step(id, open) > OPEN_GONE
}

@(private = "file")
open_step :: proc(id: clay.ElementId, open: bool) -> f32 {
	entry := opens[id.id]
	if entry.frame == anim_frame {
		return entry.v // already stepped this frame
	}
	target := open ? f32(1) : 0
	if !motion_on() {
		entry.v = target
	}
	entry.v += (target - entry.v) * anim_drain(OPEN_RATE)
	if abs(target - entry.v) < OPEN_GONE {
		entry.v = target
	} else {
		anim_moving += 1
	}
	entry.frame = anim_frame
	opens[id.id] = entry
	return entry.v
}

// How far open a panel is, for the elements inside it. The mount
// condition stepped it already this frame.
open_t :: proc(id: clay.ElementId) -> f32 {
	return opens[id.id].v
}

// Width of a fixed-width panel, scaled by how far it has opened and
// capped by the window: a modal wider than the screen it floats over
// loses its right edge, and modals are centered, so both edges.
modal_w :: proc(id: clay.ElementId, w: f32) -> f32 {
	return fit_w(w) * (OPEN_SCALE + (1 - OPEN_SCALE) * open_t(id))
}

// Same for a panel with a fixed height. The status bar sits under it.
modal_h :: proc(h: f32) -> f32 {
	return min(h, f32(rl.GetScreenHeight()) / UI_ZOOM - 60)
}

// Vertical offset for a panel that rises the last few px into place.
rise :: proc(id: clay.ElementId, dist: f32 = RISE_PX) -> f32 {
	return (1 - open_t(id)) * dist
}

// ── Lists that arrive ───────────────────────────────────────────────
//
// A list that appears all at once reads as a slab. Landing each row a
// beat after the one above it costs one timestamp per list and carries
// the eye down the results the way they are meant to be read.

STAGGER_STEP :: 0.028 // seconds between one row landing and the next
STAGGER_SECS :: 0.16 // seconds one row takes to land

@(private = "file")
stagger_at: map[u32]f64

// Restart a list's cascade: called when the list appears, not when its
// contents change (a cascade per keystroke is noise, not motion).
stagger_arm :: proc(key: u32) {
	stagger_at[key] = rl.GetTime()
}

// How far row `index` of that list has arrived, 0 to 1.
stagger :: proc(key: u32, index: int) -> f32 {
	at, armed := stagger_at[key]
	if !armed || !motion_on() {
		return 1
	}
	t := f32(clamp(((rl.GetTime() - at) - f64(index) * STAGGER_STEP) / STAGGER_SECS, 0, 1))
	if t < 1 {
		anim_moving += 1
	}
	return ease_out(t)
}

// ── Message arrival ─────────────────────────────────────────────────

MSG_FRESH_SECS :: 0.9
MSG_SEEN_MAX :: 4000

// First time each message id was laid out.
msg_seen: map[string]f64

// 1 the moment a message lands, 0 once it has settled, plus the edge:
// `landed` is true only on the single frame the row first appeared.
// Rows that were already there when the chat opened never light up.
msg_fresh :: proc(id: string) -> (f32, bool) {
	if len(id) == 0 {
		return 0, false
	}
	first := false
	at, ok := msg_seen[id]
	if !ok {
		at = rl.GetTime()
		first = true
		// ponytail: unbounded id set, dropped wholesale when it grows.
		// A per-chat map keyed by the open chat is the upgrade.
		if len(msg_seen) > MSG_SEEN_MAX {
			for key in msg_seen {
				delete(key)
			}
			clear(&msg_seen)
		}
		msg_seen[strings.clone(id)] = at
	}
	// Arrived with the view rather than into it: no glow, no sound.
	if at - page_at < PAGE_SETTLE {
		return 0, false
	}
	t := f32((rl.GetTime() - at) / MSG_FRESH_SECS)
	if t >= 1 {
		return 0, false
	}
	anim_moving += 1
	return 1 - t, first
}

// ── Changed values ──────────────────────────────────────────────────

ROLL_SECS :: 0.3

Bump :: struct {
	token: string, // what the element showed last
	prev:  string, // what it showed before that
	at:    f64,
}

bumps: map[u32]Bump

// Notice that a label changed. Returns the spring to scale the element
// by (1 at rest, overshooting after a change), plus the old label and
// how far the roll from old to new has come, for callers that show the
// change as a digit roll. The first sighting never kicks: an element
// appearing is not an element changing.
// ponytail: one entry per element that ever bumped, never collected.
// Bounded by the UI's own size, so nothing to do until it isn't.
bump :: proc(key: u32, token: string) -> (v: f32, prev: string, t: f32) {
	entry, seen := bumps[key]
	if !seen {
		entry = {strings.clone(token), "", 0}
		bumps[key] = entry
	} else if entry.token != token {
		delete(entry.prev)
		entry = {strings.clone(token), entry.token, rl.GetTime()}
		bumps[key] = entry
		anim_kick(key, 9)
	}
	t = f32(clamp((rl.GetTime() - entry.at) / ROLL_SECS, 0, 1))
	if t < 1 {
		anim_moving += 1
	}
	return anim_pop(key, 1, 300, 17), entry.prev, ease_out(t)
}

// A bump as extra padding: 0 at rest, a few px at the peak.
bump_pad :: proc(v: f32, scale: f32 = 5) -> u16 {
	return u16(clamp((v - 1) * scale, 0, 6))
}

// ── Press feedback ──────────────────────────────────────────────────

// A held pointer over a control. Buttons shift their label down by a
// pixel while it is true, which is the whole of "it depressed".
press_down :: proc(id: clay.ElementId) -> u16 {
	return rl.IsMouseButtonDown(.LEFT) && clay.PointerOver(id) ? 1 : 0
}

// ── Scrolling ───────────────────────────────────────────────────────

SCROLL_DRAIN :: f32(18) // how fast a wheel notch is spent
CLAY_SCROLL_PIXELS :: f32(10) // clay's own delta-to-pixels factor

// Undrained wheel input, spent a fraction per frame.
scroll_residual: clay.Vector2

// Containers with something to scroll this frame, registered by
// scrollbar() during the build. A finger drag has to know which
// container it is over and clay has no query for that, so the list the
// scrollbars already walk stands in for one.
drag_targets: [dynamic]clay.ElementId

// How far the timeline is pulled past its end: + past the top, - past
// the bottom. Applied as extra padding and sprung back to zero, which
// is the only rubber band available when clay clamps scroll itself.
overscroll: f32

update_overscroll :: proc(step_y: f32) {
	_ = step_y
	overscroll = 0 // the chat box does not animate; no rubber band
}

// ── Dragging the view ───────────────────────────────────────────────
//
// A finger has no wheel. On a touch machine a press that did not land on
// a message body (that one selects text) grabs the view itself: the
// content follows the pointer, and letting go throws it, so the last
// flick keeps running and settles into the same rubber band a wheel
// scroll does. With a mouse there is a wheel, and this is off.

DRAG_MIN :: f32(3) // px of travel before a press stops being a click
DRAG_VEL_RATE :: f32(30) // smoothing on the throw speed, in 1/s

@(private = "file")
drag_at: f32
@(private = "file")
drag_vel: f32
@(private = "file")
drag_on: bool
@(private = "file")
drag_id: clay.ElementId // the container this drag grabbed

// A press that turned into a drag opens no link on release.
drag_moved: bool

update_drag_scroll :: proc(ui: ^Ui_State, blocked: bool) {
	// Touch only. A mouse has a wheel, and grabbing the view with the
	// left button fights click, text selection, and the link guard.
	if !rl.HasTouch() {
		return
	}
	y := rl.GetMousePosition().y / UI_ZOOM

	if rl.IsMouseButtonReleased(.LEFT) {
		// Hand the throw to the wheel residual, which already knows how
		// to spend it and where the ends of the content are.
		if drag_on && abs(drag_vel) > DRAG_MIN {
			scroll_residual.y += drag_vel / (CLAY_SCROLL_PIXELS * anim_drain(SCROLL_DRAIN))
		}
		drag_on, drag_vel = false, 0
		return
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		drag_moved = false
		return
	}
	if !drag_on {
		if blocked || !motion_on() || !rl.IsMouseButtonPressed(.LEFT) {
			return
		}
		// The timeline is blocked while a body selection is running
		// (`blocked`); every other container is fair game.
		for target in drag_targets {
			if clay.PointerOver(target) {
				drag_id = target
				drag_on, drag_at, drag_vel, drag_moved = true, y, 0, false
				return
			}
		}
		return
	}

	cursor_raise(.Grabbing)
	step := y - drag_at
	drag_at = y
	drag_vel += (step - drag_vel) * anim_drain(DRAG_VEL_RATE)
	if abs(step) > DRAG_MIN {
		drag_moved = true
	}
	data := clay.GetScrollContainerData(drag_id)
	if !data.found {
		return
	}
	overflow := max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0)
	data.scrollPosition.y = clamp(data.scrollPosition.y + step, -overflow, 0)
	ui.scroll_pending = false // the user is driving; stop chasing the bottom
	anim_moving += 1
}

// ── Scroll velocity ─────────────────────────────────────────────────
//
// A uniform lag would be invisible (everything shifts together), so the
// lag is weighted by how far a row sits from the middle of the view:
// the centre holds, the edges trail. The timeline stretches while it is
// dragged and settles when it stops, which is what reads as matter.

SCROLL_LAG_MAX :: f32(5) // px, and the padding budget a row can spend
SCROLL_LAG_K :: f32(0.09) // px of lag per px/frame of scroll
MSG_PAD_Y :: u16(6) // the row's resting vertical padding

scroll_vel: f32

// Set by anything that teleports the scroll position (a reply jump, a
// search hit): the move must not read as velocity, or the smear ghosts
// the pre-jump content over the timeline.
scroll_jumped: bool

// True only on frames where the app itself is animating the timeline
// (the glide to a newly arrived message). The smear is for that kind of
// travel; the user's own wheel and drag stay sharp.
scroll_glide: bool

@(private = "file")
scroll_prev_y: f32

// Called once per frame, before the layout that reads it.
update_scroll_vel :: proc() {
	// The chat box does not animate: no velocity means no row lag and
	// no smear, whatever moved the scroll position.
	scroll_glide = false
	scroll_jumped = false
	scroll_vel, scroll_prev_y = 0, 0
}

// Vertical padding for one message row: the same total height, shifted
// by its share of the lag.
scroll_lag :: proc(index: u32) -> (top, bottom: u16) {
	if scroll_vel == 0 {
		return MSG_PAD_Y, MSG_PAD_Y
	}
	row, row_ok := element_box(clay.ID("MsgRow", index))
	view, view_ok := element_box(clay.ID("Timeline"))
	if !row_ok || !view_ok || view.height <= 0 {
		return MSG_PAD_Y, MSG_PAD_Y
	}
	from_mid := ((row.y + row.height / 2) - (view.y + view.height / 2)) / (view.height / 2)
	lag :=
		clamp(scroll_vel * SCROLL_LAG_K, -SCROLL_LAG_MAX, SCROLL_LAG_MAX) *
		abs(clamp(from_mid, -1, 1))
	return lag_pads(lag)
}

// Split the row's padding budget around `lag`. The bottom is derived,
// never rounded on its own: two independent truncations lost up to 1px
// of row height each, and ~50 rows of that resized the timeline enough
// to shove a bottom-pinned view back up off the newest message.
lag_pads :: proc(lag: f32) -> (top, bottom: u16) {
	top = u16(math.round(f32(MSG_PAD_Y) + clamp(lag, -SCROLL_LAG_MAX, SCROLL_LAG_MAX)))
	return top, 2 * MSG_PAD_Y - top
}

// ── Screen shake ────────────────────────────────────────────────────

// One global impulse, decayed per frame and applied as a render offset
// (main.odin). Errors shake the window rather than only coloring a
// label red: it is the one feedback nobody misses.
shake_amount: f32

SHAKE_DECAY :: f32(6)

shake :: proc(strength: f32 = 7) {
	if !motion_on() {
		return
	}
	shake_amount = max(shake_amount, strength)
}

// Pixel offset for this frame, decaying toward rest.
shake_offset :: proc() -> (dx, dy: f32) {
	if shake_amount < 0.15 {
		shake_amount = 0
		return 0, 0
	}
	anim_moving += 1
	t := f64(anim_frame)
	dx = shake_amount * sin_approx(t * 1.7)
	dy = shake_amount * 0.5 * sin_approx(t * 2.6 + 1.1)
	shake_amount -= shake_amount * SHAKE_DECAY * anim_dt
	return
}
