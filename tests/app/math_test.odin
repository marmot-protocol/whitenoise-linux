// Math blocks: MicroTeX through app/math_shim.cpp, fed peer-controlled
// TeX. Malformed input must come back as nil (source text), never an
// abort or a hang, and nothing one formula defines may leak into the next.
// Run: tests/odin.sh app
package main

import "core:c"
import "core:strings"
import "core:testing"

// The shim's C symbols, bound here under test-only names so app/math.odin
// keeps its bindings file-private.
foreign import math_test_lib {"../build/libwnmath.a", "../build/microtex/lib/libmicrotex.a", "system:cairo", "system:stdc++", "system:m"}

@(private = "file", default_calling_convention = "c")
foreign math_test_lib {
	@(link_name = "math_shim_init")
	shim_init :: proc(font: [^]u8, len: c.ulong) -> bool ---
	@(link_name = "math_shim_render")
	shim_render :: proc(tex: cstring, size: f32, argb: u32, max_side: c.int, max_area: c.long, w, h: ^c.int) -> [^]u8 ---
	@(link_name = "math_shim_free")
	shim_free :: proc(pixels: [^]u8) ---
}

@(private = "file")
FONT := #load("../vendor/microtex/res/tex-gyre/texgyredejavu-math.clm2")

// MicroTeX's own showcase: \newcommand, \fatalIfCmdConflict, colors,
// matrices, \fcolorbox.
@(private = "file")
SAMPLE :: #load("math_sample.tex", string)

// The app's caps (app/math.odin).
@(private = "file")
MAX_SIDE :: 4096
@(private = "file")
MAX_AREA :: 2 << 20

@(private = "file")
Rendered :: struct {
	ok:    bool, // rendered with some ink
	w, h:  c.int,
	dark:  int, // opaque pixels darker than mid-gray
	blue:  int, // opaque pixels that are mostly blue
	red:   int, // opaque pixels that are mostly red: MicroTeX's "?" for a missing glyph
	light: int, // opaque pixels lighter than mid-gray
}

// Render in white ink, the way a dark theme does.
@(private = "file")
render :: proc(tex: string) -> (r: Rendered) {
	pixels := shim_render(
		strings.clone_to_cstring(tex, context.temp_allocator),
		20,
		0xffffffff,
		MAX_SIDE,
		MAX_AREA,
		&r.w,
		&r.h,
	)
	if pixels == nil {return}
	defer shim_free(pixels)

	for i in 0 ..< int(r.w) * int(r.h) {
		p := pixels[i * 4:][:4]
		if p[3] == 0 {continue}
		r.ok = true
		if p[3] < 250 {continue}
		sum := int(p[0]) + int(p[1]) + int(p[2])
		if sum < 3 * 128 {r.dark += 1} else {r.light += 1}
		if p[2] > 200 && p[0] < 60 && p[1] < 60 {r.blue += 1}
		if p[0] > 200 && p[1] < 60 && p[2] < 60 {r.red += 1}
	}
	return
}

@(test)
math_shim_isolation :: proc(t: ^testing.T) {
	testing.expect(t, shim_init(raw_data(FONT), c.ulong(len(FONT))))

	quadratic := render(`x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}`)
	testing.expect(t, quadratic.ok)
	testing.expect(t, quadratic.w > quadratic.h && quadratic.h > 20)
	pmatrix := render(`\begin{pmatrix} a & b \\ c & d \end{pmatrix}`)
	testing.expect(t, pmatrix.ok)

	// MicroTeX throws on these; the shim must catch, not abort.
	testing.expect(t, !render(`\over\over`).ok)
	testing.expect(t, !render(`\frac{`).ok)

	// 300 nested fractions stack past MAX_SIDE: refused before cairo
	// allocates the surface.
	testing.expect(t, !render(strings.repeat(`\frac{1}{`, 300, context.temp_allocator)).ok)

	// Self-referencing definitions stop at the expansion bound.
	render(`\newcommand{\a}{\a}\a`)
	render(`\newcommand{\b}{\b\b}\b`)

	// The showcase renders whole, and its light \fcolorbox background gets
	// dark ink even though the default ink is white.
	sample := render(SAMPLE)
	testing.expect(t, sample.ok)
	testing.expect(t, sample.h > 10 * quadratic.h)
	testing.expect_value(t, sample.red, 0) // the font covers every glyph it uses
	boxed := render(`\definecolor{gris}{gray}{0.9}\colorbox{gris}{x}`)
	testing.expect(t, boxed.dark > 0)

	// A user definition is gone by the next formula.
	unknown := render(`\foo`)
	render(`\newcommand{\foo}{xxxxxxxxxxxxxxxx}\foo`)
	after := render(`\foo`)
	testing.expect_value(t, after.w, unknown.w)

	// Built-ins can't be replaced, even with conflicts switched off; both
	// natively implemented (\frac) and predefined expansions (pmatrix).
	render(`\fatalIfCmdConflict{false}\renewcommand{\frac}[2]{x}\newcommand{\sqrt}{y}`)
	render(`\fatalIfCmdConflict{false}\renewenvironment{pmatrix}{}{}`)
	again := render(`x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}`)
	testing.expect_value(t, again.w, quadratic.w)
	testing.expect_value(t, again.h, quadratic.h)
	testing.expect_value(t, render(`\begin{pmatrix} a & b \\ c & d \end{pmatrix}`).w, pmatrix.w)

	// A redefined color is back to its default by the next formula.
	render(`\definecolor{white}{rgb}{0,0,1}\color{white}{x}`)
	testing.expect_value(t, render(`\color{white}{xxxx}`).blue, 0)

	// Style and line-break switches don't carry over.
	render(`\everymath{\scriptscriptstyle}\breakEverywhere{true}\mathversion{nope}x`)
	again = render(`x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}`)
	testing.expect_value(t, again.w, quadratic.w)
	testing.expect_value(t, again.h, quadratic.h)
}
