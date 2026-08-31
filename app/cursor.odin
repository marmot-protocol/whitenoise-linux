// The pointer's own feedback. clay has no cursor concept and nothing it
// builds survives a frame, so the shape is raised by whatever sits under
// the pointer during the build and set once at the end of the frame.
//
// Highest raise wins (the enum is ordered): text beats a button, because
// an input's row is hovered too and the I-beam is the truer answer, and
// a drag in progress beats both.
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

cursor_want: rl.Cursor_Shape

cursor_raise :: proc(shape: rl.Cursor_Shape) {
	if shape > cursor_want {
		cursor_want = shape
	}
}

// clay.Hovered(), plus the pointer that goes with it. Every interactive
// element in the app already asks this to draw its hover fill, so
// wrapping it is the whole of "the app looks clickable".
hovered :: proc() -> bool {
	if !clay.Hovered() {
		return false
	}
	cursor_raise(.Pointer)
	return true
}

// End of frame, after the handlers have had their say.
cursor_apply :: proc() {
	rl.SetCursor(cursor_want)
	cursor_want = .Default
}
