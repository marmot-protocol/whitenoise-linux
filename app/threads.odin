// Discord-style threads as a sub-route of the chat view.
//
//   thread_stack: []           ["A"]              ["A", "X"]
//   ┌─────────────────┐   ┌──────────────────┐   ┌──────────────────┐
//   │ main timeline   │──▶│ ‹ Thread (A)     │──▶│ ‹ Thread · 2 (X) │
//   │  A  "2 replies" │   │  root plate A    │   │  root plate X    │
//   │                 │   │  X  "1 replies"  │   │  replies to X    │
//   │ composer        │   │  composer        │   │  composer        │
//   └─────────────────┘   └──────────────────┘   └──────────────────┘
//
// One timeline, one composer: the view filters rows by the top of the
// stack (thread_of == thread_cur), and every send routes there. A
// thread message is a kind-1111 custom event tagged ["e", root]; the
// root can itself be a thread message, so threads nest to any depth.
// Back (or Escape with an empty composer) pops one level.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

THREAD_KICK :: f32(26) // px the timeline slides in from on push/pop

thread_cur :: proc(ui: ^Ui_State) -> string {
	return len(ui.thread_stack) > 0 ? ui.thread_stack[len(ui.thread_stack) - 1] : ui.compose_issue
}

thread_push :: proc(ui: ^Ui_State, root_id: string) {
	if root_id == thread_cur(ui) {
		return // the open thread's own root plate can't re-push it
	}
	append(&ui.thread_stack, strings.clone(root_id))
	ui.replying = "" // a reply can't cross into a thread
	ui.scroll_pending = true
	thread_kick()
}

thread_back :: proc(ui: ^Ui_State) {
	if len(ui.thread_stack) == 0 {
		return
	}
	delete(ui.thread_stack[len(ui.thread_stack) - 1])
	pop(&ui.thread_stack)
	ui.scroll_pending = true
	thread_kick()
}

thread_clear :: proc(ui: ^Ui_State) {
	for id in ui.thread_stack {
		delete(id)
	}
	clear(&ui.thread_stack)
}

// The route transition: kick the slide offset, anim_to eases it home.
@(private = "file")
thread_kick :: proc() {
	if motion_on() {
		anim_vals[clay.ID("ThreadSlide").id] = {v = THREAD_KICK, frame = anim_frame}
	}
}

thread_slide :: proc() -> f32 {
	return 0 // the chat box does not animate; routes land in place
}

// Breadcrumb bar under the chat header while a thread is open: back
// chevron, depth, and the root's one-line summary.
thread_bar :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ThreadBar"))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 8, right = 14, top = 6, bottom = 6}, childGap = 8, childAlignment = {y = .Center}}, backgroundColor = RAIL_BG},
	) {
		cast_shade(clay.ID("ThreadBar"), .Down, 14, 0.35)
		if clay.UI(clay.ID("ThreadBack"))(
		{layout = {padding = {left = 10, right = 10, top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
		) {
			clay.Text("‹", {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
		}
		clay.Text(ICON_COMMENTS, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})
		if len(ui.thread_stack) > 1 {
			clay.Text(fmt.tprintf("%s · %d", tr("Thread"), len(ui.thread_stack)), {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
		} else {
			clay.Text(tr("Thread"), {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
		}
		cur := thread_cur(ui)
		for msg in ui.messages {
			if msg.id != cur {
				continue
			}
			snippet := msg.body[:min(len(msg.body), 48)]
			clay.Text(fmt.tprintf("%s: %s", msg.sender, snippet), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
			break
		}
	}
}

// The root message pinned at the top of a thread view, above the
// replies, so the sub-conversation keeps its subject in sight.
thread_root_plate :: proc(ui: ^Ui_State) {
	cur := thread_cur(ui)
	for msg, i in ui.messages {
		if msg.id != cur {
			continue
		}
		message_row(u32(i), msg)
		if clay.UI(clay.ID("ThreadRootRule"))(
		{layout = {padding = {left = 16, right = 16, top = 4, bottom = 2}}},
		) {
			clay.Text("• THREAD •", {fontId = FONT_MONO, fontSize = 10, textColor = ACCENT_DIM, letterSpacing = 2})
		}
		return
	}
}

// ── Cast shadows ────────────────────────────────────────────────────
//
// SDL_Renderer has no shaders; a drop shadow is one gradient quad
// (per-vertex color) mounted floating along the casting edge, the same
// Custom-command ride the glow halos use.

Shade_Dir :: enum u8 {
	Left, // panel casting left onto content (dark at the right edge)
	Down, // header/bar casting down onto content (dark at the top edge)
}

Shade_View :: struct {
	kind:  Model_Kind, // .Shade; must stay the first field
	dir:   Shade_Dir,
	alpha: f32, // 0..1 at the dark edge
}

SHADE_SALT :: u32(0x73686164)

// A shadow along one edge of `parent`, declared inside it. Sized from
// the parent's previous box like the glow, so the first frame is dark.
cast_shade :: proc(parent: clay.ElementId, dir: Shade_Dir, span: f32, alpha: f32) {
	box, ok := element_box(parent)
	if !ok || alpha <= 0.01 || !motion_on() {
		return
	}
	view := new(Shade_View, context.temp_allocator)
	view^ = {kind = .Shade, dir = dir, alpha = clamp(alpha, 0, 1)}
	id := parent
	id.id ~= SHADE_SALT
	down := dir == .Down
	if clay.UI(id)(
	{
		layout = {sizing = {width = clay.SizingFixed(down ? box.width : span), height = clay.SizingFixed(down ? span : box.height)}},
		floating = {
			attachTo = .Parent,
			zIndex = 4,
			attachment = down ? {element = .LeftTop, parent = .LeftBottom} : {element = .RightTop, parent = .LeftTop},
		},
		custom = {customData = view},
	},
	) {}
}

shade_draw :: proc(view: ^Shade_View, bounds: clay.BoundingBox) {
	lucent := rl.FColor{0, 0, 0, 0}
	dark := rl.FColor{0, 0, 0, view.alpha}
	x0, x1 := bounds.x, bounds.x + bounds.width
	y0, y1 := bounds.y, bounds.y + bounds.height
	verts: [6]rl.Vertex
	if view.dir == .Left {
		// Dark against the caster's edge on the right, fading left.
		verts = {
			{position = {x0, y0}, color = lucent},
			{position = {x1, y0}, color = dark},
			{position = {x0, y1}, color = lucent},
			{position = {x1, y0}, color = dark},
			{position = {x1, y1}, color = dark},
			{position = {x0, y1}, color = lucent},
		}
	} else {
		// Dark against the caster's edge on top, fading down.
		verts = {
			{position = {x0, y0}, color = dark},
			{position = {x1, y0}, color = dark},
			{position = {x0, y1}, color = lucent},
			{position = {x1, y0}, color = dark},
			{position = {x1, y1}, color = lucent},
			{position = {x0, y1}, color = lucent},
		}
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, bounds.y, bounds.width, bounds.height)
}
