// SDL3 platform shim with a raylib-shaped API, so the app kept its
// call sites when it migrated off raylib (which, sitting on GLFW, has
// no IME text input and no dynamic glyph baking).
//
// What lives here:
//   - window/renderer lifecycle, frame loop, input state (keys, mouse,
//     wheel), clipboard, screenshots
//   - IME: SDL text input events feed a rune queue (GetCharPressed)
//     and a preedit string (Preedit) from SDL_EVENT_TEXT_EDITING
//   - text engine: stb_truetype fonts with a per-font fallback stack
//     (Noto Sans CJK covers Japanese), glyphs rasterized on demand at
//     pixel_scale and cached as one SDL texture each
//     (ponytail: per-glyph textures; pack an atlas if draw calls hurt)
//   - geometry: rounded rects and border arcs ported from clay's
//     official SDL3 renderer (clay_renderer_SDL3.c)
package sdlrl

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

// ── Raylib-shaped public types ──────────────────────────────────────

Vector2 :: struct {
	x, y: f32,
}

Color :: struct {
	r, g, b, a: u8,
}

Texture2D :: struct {
	tex:    ^sdl.Texture,
	width:  i32,
	height: i32,
}

Image :: struct {
	data:   [^]u8, // RGBA8, stb-owned
	width:  i32,
	height: i32,
}

Camera2D :: struct {
	zoom:   f32,
	offset: Vector2, // whole-frame nudge, used by the error shake
}

KeyboardKey :: enum {
	ESCAPE,
	ENTER,
	TAB,
	BACKSPACE,
	DELETE,
	LEFT,
	RIGHT,
	UP,
	DOWN,
	HOME,
	END,
	INSERT,
	A,
	C,
	K,
	P,
	V,
	X,
	Y,
	Z,
	LEFT_CONTROL,
	RIGHT_CONTROL,
	LEFT_SHIFT,
	RIGHT_SHIFT,
	EQUAL,
	MINUS,
	ZERO,
}

MouseButton :: enum {
	LEFT,
	RIGHT,
	MIDDLE,
}

TextureFilter :: enum {
	BILINEAR,
}

// ── State ───────────────────────────────────────────────────────────

@(private)
State :: struct {
	window:        ^sdl.Window,
	renderer:      ^sdl.Renderer,
	quit:          bool,
	fullscreen:    bool,
	// per-frame input
	pressed:       [KeyboardKey]bool,
	repeated:      [KeyboardKey]bool,
	down:          [KeyboardKey]bool,
	m_pressed:     [MouseButton]bool,
	m_released:    [MouseButton]bool,
	m_down:        [MouseButton]bool,
	m_clicks:      u8, // click count of this frame's LEFT press (2 = double)
	wheel:         Vector2,
	chars:         [dynamic]rune,
	preedit:       string,
	// timing
	last_frame_ns: u64,
	frame_dt:      f32,
	density:       f32, // output pixels per window point
	touch:         bool, // a touch screen is attached
	text_input:    bool, // text-input-v3 enabled (raises a phone's keyboard)
	// text engine
	pixel_scale:   f32, // glyph rasterization multiplier (dpi * zoom)
	fonts:         [dynamic]Font_File,
	stacks:        map[u16][]int, // font id -> indices into fonts
	glyphs:        map[u64]Glyph,
	ascents:       map[u64]f32, // (file, px) -> ascent in atlas px
	text_image:    proc(text: string) -> ^Texture2D,
}

@(private)
state: State

@(private)
callback_allocator: mem.Allocator
@(private)
live_textures: map[^sdl.Texture]bool

@(private)
track_texture :: proc(tex: ^sdl.Texture) {
	when #config(WN_RELOAD, false) {
		if tex != nil {live_textures[tex] = true}
	}
}

when #config(WN_RELOAD, false) {
	@(private)
	Dev_Dialog_Kind :: enum c.int {
		Open_One,
		Open_Many,
		Save,
	}
	foreign _ {
		@(private)
		wn_dev_window :: proc "c" (width, height: c.int, title: cstring, renderer: ^^sdl.Renderer) -> ^sdl.Window ---
		@(private)
		wn_dev_dialog :: proc "c" (kind: Dev_Dialog_Kind, callback: sdl.DialogFileCallback, name: cstring) ---
		@(private)
		wn_dev_wait_dialogs :: proc "c" () ---
		@(private)
		wn_dev_dialogs_consumed :: proc "c" (count: c.int) ---
	}
}

@(private)
Font_File :: struct {
	path: string,
	data: []u8,
	info: stbtt.fontinfo,
	ok:   bool,
}

@(private)
Glyph :: struct {
	tex:     ^sdl.Texture, // nil = whitespace or missing
	w, h:    i32,
	xoff:    i32,
	yoff:    i32,
	advance: f32, // atlas px
	file:    int, // which stack font resolved it
	icon:    bool, // laid out and centered by ink (see IconFont)
}

// Font id whose glyphs are icons, set once by the app. Icons are boxed
// by their ink so they center inside square buttons; text keeps the
// font's own advances, which is what makes a line flow correctly.
IconFont: u16 = max(u16)

@(private)
SCANCODES := [KeyboardKey]sdl.Scancode {
	.ESCAPE        = .ESCAPE,
	.ENTER         = .RETURN,
	.TAB           = .TAB,
	.BACKSPACE     = .BACKSPACE,
	.DELETE        = .DELETE,
	.LEFT          = .LEFT,
	.RIGHT         = .RIGHT,
	.UP            = .UP,
	.DOWN          = .DOWN,
	.HOME          = .HOME,
	.END           = .END,
	.INSERT        = .INSERT,
	.A             = .A,
	.C             = .C,
	.K             = .K,
	.P             = .P,
	.V             = .V,
	.X             = .X,
	.Y             = .Y,
	.Z             = .Z,
	.LEFT_CONTROL  = .LCTRL,
	.RIGHT_CONTROL = .RCTRL,
	.LEFT_SHIFT    = .LSHIFT,
	.RIGHT_SHIFT   = .RSHIFT,
	.EQUAL         = .EQUALS,
	.MINUS         = .MINUS,
	.ZERO          = ._0,
}

// ── Window / frame loop ─────────────────────────────────────────────

InitWindow :: proc(width, height: i32, title: cstring) {
	callback_allocator = context.allocator
	when #config(WN_RELOAD, false) {
		state.window = wn_dev_window(c.int(width), c.int(height), title, &state.renderer)
	} else {
		if !sdl.Init({.VIDEO}) {
			fmt.eprintfln("sdl: init failed: %s", sdl.GetError())
			os.exit(1)
		}
		sdl.CreateWindowAndRenderer(
			title,
			c.int(width),
			c.int(height),
			{.RESIZABLE, .HIGH_PIXEL_DENSITY},
			&state.window,
			&state.renderer,
		)
	}
	if state.window == nil || state.renderer == nil {
		fmt.eprintfln("sdl: window failed: %s", sdl.GetError())
		os.exit(1)
	}
	state.density = max(sdl.GetWindowPixelDensity(state.window), 1)
	state.fullscreen = .FULLSCREEN in sdl.GetWindowFlags(state.window)
	// Asked once: SDL synthesizes mouse events from touch, so this is
	// the only way to tell a finger from a pointer.
	n: c.int
	if devices := sdl.GetTouchDevices(&n); devices != nil {
		sdl.free(devices)
	}
	state.touch = n > 0
	_ = sdl.SetRenderVSync(state.renderer, 1)
	_ = sdl.SetRenderDrawBlendMode(state.renderer, {.BLEND})
	// Text input stays off until a field asks for it: on Wayland it
	// drives text-input-v3, and enabling it for the life of the window
	// keeps an on-screen keyboard (squeekboard, and friends) up over
	// the whole app.
	state.pixel_scale = 1
	state.last_frame_ns = sdl.GetTicksNS()
}

SetWindowTitle :: proc(title: cstring) {
	_ = sdl.SetWindowTitle(state.window, title)
}

// ── Pointer shape ───────────────────────────────────────────────────
// The system cursors, created on first use and kept for the process.
// Ordered by priority, so the caller can keep the highest shape raised
// during a frame and set it once at the end.

Cursor_Shape :: enum {
	Default,
	Pointer, // over something clickable
	Text, // over something selectable
	Grabbing, // dragging the view itself
}

@(private)
CURSOR_IDS := [Cursor_Shape]sdl.SystemCursor {
	.Default  = .DEFAULT,
	.Pointer  = .POINTER,
	.Text     = .TEXT,
	.Grabbing = .MOVE,
}

@(private)
cursors: [Cursor_Shape]^sdl.Cursor
@(private)
cursor_now := Cursor_Shape.Default

SetCursor :: proc(shape: Cursor_Shape) {
	if shape == cursor_now {
		return
	}
	if cursors[shape] == nil {
		// A shape the platform can't supply leaves the current one up
		// rather than falling back to an arrow every frame.
		if cursors[shape] = sdl.CreateSystemCursor(CURSOR_IDS[shape]); cursors[shape] == nil {
			return
		}
	}
	_ = sdl.SetCursor(cursors[shape])
	cursor_now = shape
}

// ── File dialog ─────────────────────────────────────────────────────
// SDL runs the dialog callback on its own thread, so picked paths land
// in a mutex-guarded list the frame loop drains via PickedFiles.

@(private)
picked_mutex: sync.Mutex
@(private)
picked_paths: [dynamic]string
@(private)
picked_callbacks: c.int

@(private)
dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	context.allocator = callback_allocator
	sync.lock(&picked_mutex)
	defer sync.unlock(&picked_mutex)
	picked_callbacks += 1
	if filelist == nil {
		fmt.eprintfln("sdl: file dialog failed: %s", sdl.GetError())
		return
	}
	for i := 0; filelist[i] != nil; i += 1 {
		append(&picked_paths, strings.clone(string(filelist[i])))
	}
}

// Open the native multi-select file picker (async; see PickedFiles).
OpenFileDialog :: proc(allow_many: bool) {
	when #config(WN_RELOAD, false) {
		wn_dev_dialog(allow_many ? .Open_Many : .Open_One, dialog_cb, nil)
	} else {
		sdl.ShowOpenFileDialog(dialog_cb, nil, state.window, nil, 0, nil, allow_many)
	}
}

// Drain the paths picked since the last call. The caller owns the
// returned array and its strings.
PickedFiles :: proc() -> [dynamic]string {
	sync.lock(&picked_mutex)
	defer sync.unlock(&picked_mutex)
	out := picked_paths
	picked_paths = {}
	when #config(WN_RELOAD, false) {wn_dev_dialogs_consumed(picked_callbacks)}
	picked_callbacks = 0
	return out
}

// Save dialog, same async shape as the picker but its own list so a
// save can't be mistaken for a composer attachment. The native dialog
// owns the overwrite confirmation.

@(private)
saved_mutex: sync.Mutex
@(private)
saved_paths: [dynamic]string
@(private)
saved_callbacks: c.int
@(private)
save_name: cstring // suggested filename; kept alive across the async dialog

@(private)
save_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	context.allocator = callback_allocator
	sync.lock(&saved_mutex)
	defer sync.unlock(&saved_mutex)
	saved_callbacks += 1
	if filelist == nil || filelist[0] == nil {
		return // failed or cancelled
	}
	append(&saved_paths, strings.clone(string(filelist[0])))
}

SaveFileDialog :: proc(default_name: string) {
	delete(save_name)
	save_name = strings.clone_to_cstring(default_name)
	when #config(WN_RELOAD, false) {
		wn_dev_dialog(.Save, save_cb, save_name)
	} else {
		sdl.ShowSaveFileDialog(save_cb, nil, state.window, nil, 0, save_name)
	}
}

SavedFiles :: proc() -> [dynamic]string {
	sync.lock(&saved_mutex)
	defer sync.unlock(&saved_mutex)
	out := saved_paths
	saved_paths = {}
	when #config(WN_RELOAD, false) {wn_dev_dialogs_consumed(saved_callbacks)}
	saved_callbacks = 0
	return out
}

// Rasterize sample lines of an in-memory font into owned RGBA pixels (the
// .ttf attachment preview). Returns {} when stb can't parse the file.
FontSpecimen :: proc(
	data: []u8,
	lines: []string,
	sizes: []f32,
	color: Color,
	width: i32,
) -> Image {
	info: stbtt.fontinfo
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
	if offset < 0 || !bool(stbtt.InitFont(&info, raw_data(data), offset)) {
		return {}
	}

	pad: f32 = 14
	total := i32(pad * 2)
	for size in sizes {
		total += i32(size * 1.5)
	}

	canvas := make([]u8, int(width) * int(total) * 4)
	y := pad
	for line, li in lines {
		size := sizes[li]
		scale := stbtt.ScaleForPixelHeight(&info, size)
		ascent, descent, gap: c.int
		stbtt.GetFontVMetrics(&info, &ascent, &descent, &gap)
		base := y + f32(ascent) * scale
		x := pad

		for r in line {
			adv, lsb: c.int
			stbtt.GetCodepointHMetrics(&info, r, &adv, &lsb)
			w, h, xoff, yoff: c.int
			bitmap := stbtt.GetCodepointBitmap(&info, scale, scale, r, &w, &h, &xoff, &yoff)
			if bitmap != nil {
				for row in 0 ..< int(h) {
					py := int(base) + int(yoff) + row
					if py < 0 || py >= int(total) {
						continue
					}
					for col in 0 ..< int(w) {
						px := int(x) + int(xoff) + col
						cov := bitmap[row * int(w) + col]
						if cov == 0 || px < 0 || px >= int(width) {
							continue
						}
						at := (py * int(width) + px) * 4
						canvas[at] = color.r
						canvas[at + 1] = color.g
						canvas[at + 2] = color.b
						canvas[at + 3] = max(canvas[at + 3], cov)
					}
				}
				stbtt.FreeBitmap(bitmap, nil)
			}
			x += f32(adv) * scale
			if x > f32(width) - pad {
				break
			}
		}
		y += size * 1.5
	}

	return {data = raw_data(canvas), width = width, height = total}
}

// ── Tray ────────────────────────────────────────────────────────────
// Minimal status icon for "Start minimized to tray": a solid accent
// square with Show/Quit entries. Show raises the window; Quit pushes
// a QUIT event so the normal loop exit runs.

@(private)
tray: ^sdl.Tray
@(private)
tray_surface: ^sdl.Surface
@(private)
tray_px: [22 * 22]u32 // must outlive the tray; the surface borrows it

@(private)
tray_show_cb :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	_ = sdl.ShowWindow(state.window)
	_ = sdl.RaiseWindow(state.window)
}

@(private)
tray_quit_cb :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	event: sdl.Event
	event.type = .QUIT
	_ = sdl.PushEvent(&event)
}

// abgr is the icon color as 0xAABBGGRR (RGBA32 little-endian).
// Missing tray host (no StatusNotifier): the tray silently doesn't
// appear; the window stays the only surface.
InitTray :: proc(tooltip: cstring, abgr: u32, show_label, quit_label: cstring) {
	if tray != nil {
		return
	}
	for &px in tray_px {
		px = abgr
	}
	tray_surface = sdl.CreateSurfaceFrom(22, 22, .RGBA32, raw_data(tray_px[:]), 22 * 4)
	tray = sdl.CreateTray(tray_surface, tooltip)
	if tray == nil {
		sdl.DestroySurface(tray_surface)
		tray_surface = nil
		return
	}
	menu := sdl.CreateTrayMenu(tray)
	show := sdl.InsertTrayEntryAt(menu, -1, show_label, sdl.TRAYENTRY_BUTTON)
	sdl.SetTrayEntryCallback(show, tray_show_cb, nil)
	quit := sdl.InsertTrayEntryAt(menu, -1, quit_label, sdl.TRAYENTRY_BUTTON)
	sdl.SetTrayEntryCallback(quit, tray_quit_cb, nil)
}

SetTrayTooltip :: proc(tooltip: cstring) {
	if tray != nil {
		sdl.SetTrayTooltip(tray, tooltip)
	}
}

// "Minimize to tray on close": a window-close request hides the window
// instead of quitting. SDL follows that request with a QUIT for the last
// window, so the swallow flag eats exactly that one; the tray's Quit
// entry pushes a QUIT with no close request and still exits.
@(private)
hide_on_close: bool
@(private)
swallow_quit: bool

SetHideOnClose :: proc(on: bool) {
	hide_on_close = on
}

SetWindowSize :: proc(w, h: i32) {
	_ = sdl.SetWindowSize(state.window, c.int(w), c.int(h))
}

HideWindow :: proc() {
	_ = sdl.HideWindow(state.window)
}

ShowWindow :: proc() {
	_ = sdl.ShowWindow(state.window)
	_ = sdl.RaiseWindow(state.window)
}

CloseWindow :: proc() {
	when #config(WN_RELOAD, false) {wn_dev_wait_dialogs()}
	_ = sdl.StopTextInput(state.window)
	if tray != nil {sdl.DestroyTray(tray); tray = nil}
	if tray_surface != nil {sdl.DestroySurface(tray_surface); tray_surface = nil}
	for cursor in cursors {if cursor != nil {sdl.DestroyCursor(cursor)}}
	when #config(WN_RELOAD, false) {
		sdl.SetRenderTarget(state.renderer, nil)
		sdl.SetRenderClipRect(state.renderer, nil)
		sdl.SetRenderViewport(state.renderer, nil)
		sdl.SetRenderScale(state.renderer, 1, 1)
		for tex in live_textures {sdl.DestroyTexture(tex)}
	} else {
		sdl.DestroyRenderer(state.renderer)
		sdl.DestroyWindow(state.window)
		sdl.Quit()
	}
}

SetTargetFPS :: proc(fps: i32) {} 	// vsync paces the loop

// Output pixels per window point. Layout and mouse stay in points;
// the density folds into the render scale and glyph atlases so the
// back buffer runs at full pixel resolution.
GetWindowScaleDPI :: proc() -> Vector2 {
	return {state.density, state.density}
}

// Borderless fill of the current display (SDL3's default fullscreen
// mode); state tracked here so callers can toggle and reset.
SetFullscreen :: proc(on: bool) {
	if on == state.fullscreen {
		return
	}
	state.fullscreen = on
	_ = sdl.SetWindowFullscreen(state.window, on)
}

IsFullscreen :: proc() -> bool {
	return state.fullscreen
}

// Input focus, so an alert only fires for a chat the user isn't
// looking at.
IsWindowFocused :: proc() -> bool {
	return .INPUT_FOCUS in sdl.GetWindowFlags(state.window)
}

// Pumps events and refreshes per-frame input state.
WindowShouldClose :: proc(changed: ^bool = nil) -> bool {
	if changed != nil {changed^ = false}
	for key in KeyboardKey {
		state.pressed[key] = false
		state.repeated[key] = false
	}
	for button in MouseButton {
		state.m_pressed[button] = false
		state.m_released[button] = false
	}
	state.wheel = {}
	clear(&state.chars)

	// The density is not fixed for the window's life: snapping to a
	// monitor with another scale changes it, and everything sized in
	// physical pixels (targets, the render scale) must follow or the
	// content stops matching the window.
	state.density = max(sdl.GetWindowPixelDensity(state.window), 1)

	event: sdl.Event
	for sdl.PollEvent(&event) {
		if changed != nil {changed^ = true}
		#partial switch event.type {
		case .WINDOW_CLOSE_REQUESTED:
			if hide_on_close {
				HideWindow()
				swallow_quit = true
			}
		case .WINDOW_RESIZED:
			// Tiled Wayland: a later state-only configure (a focus swap
			// when a neighbor maps) carries no size, and SDL then falls
			// back to its cached floating size, which is whatever the
			// window measured before the tile. Echoing every real resize
			// into that cache keeps the fallback current, or the layout
			// flaps between the old and new size for a couple of frames.
			_ = sdl.SetWindowSize(state.window, event.window.data1, event.window.data2)
		case .QUIT:
			if swallow_quit {
				swallow_quit = false
			} else {
				state.quit = true
			}
		case .KEY_DOWN:
			for key in KeyboardKey {
				if SCANCODES[key] != event.key.scancode {
					continue
				}
				state.down[key] = true
				if event.key.repeat {
					state.repeated[key] = true
				} else {
					state.pressed[key] = true
				}
			}
		case .KEY_UP:
			for key in KeyboardKey {
				if SCANCODES[key] == event.key.scancode {
					state.down[key] = false
				}
			}
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			button: MouseButton
			switch event.button.button {
			case 1:
				button = .LEFT
			case 2:
				button = .MIDDLE
			case 3:
				button = .RIGHT
			case:
				continue
			}
			if event.type == .MOUSE_BUTTON_DOWN {
				state.m_pressed[button] = true
				state.m_down[button] = true
				if button == .LEFT {
					state.m_clicks = event.button.clicks
				}
			} else {
				state.m_released[button] = true
				state.m_down[button] = false
			}
		case .MOUSE_WHEEL:
			state.wheel.x += event.wheel.x
			state.wheel.y += event.wheel.y
		case .TEXT_INPUT:
			// IME commit or plain typing; either way, runes for the app.
			for r in string(event.text.text) {
				append(&state.chars, r)
			}
			set_preedit("")
		case .TEXT_EDITING:
			set_preedit(string(event.edit.text))
		}
	}
	return state.quit
}

@(private)
set_preedit :: proc(text: string) {
	delete(state.preedit)
	state.preedit = strings.clone(text)
}

// In-progress IME composition, shown at the caret until committed.
Preedit :: proc() -> string {
	return state.preedit
}

BeginDrawing :: proc() {
	sdl.SetRenderScale(state.renderer, 1, 1)
	sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 255)
	sdl.RenderClear(state.renderer)
}

BeginMode2D :: proc(camera: Camera2D) {
	scale := camera.zoom * state.density
	sdl.SetRenderScale(state.renderer, scale, scale)
	// The viewport is the cheapest whole-frame translate: it shifts the
	// origin and clips at the window edge, which is what a shake wants.
	if camera.offset != {} {
		w := f32(GetScreenWidth()) / camera.zoom // viewport rect is in scaled units
		h := f32(GetScreenHeight()) / camera.zoom
		view := sdl.Rect{i32(camera.offset.x), i32(camera.offset.y), i32(w), i32(h)}
		sdl.SetRenderViewport(state.renderer, &view)
	}
}

EndMode2D :: proc() {
	sdl.SetRenderViewport(state.renderer, nil)
	sdl.SetRenderScale(state.renderer, 1, 1)
}

EndDrawing :: proc() {
	sdl.RenderPresent(state.renderer)
	now := sdl.GetTicksNS()
	state.frame_dt = f32(now - state.last_frame_ns) / 1e9
	state.last_frame_ns = now
}

// ponytail: the Wayland half of this is unverified. TODO on a Linux
// phone (phosh + squeekboard): that enabling raises the keyboard and
// disabling dismisses it, and whether the compositor shrinks the window
// or lays the keyboard over it. If it overlays, the composer needs to
// lift by the keyboard's height, which nothing here does yet.
//
// Enable or disable platform text input. On Wayland this is
// text-input-v3: it drives the IME and it is what raises and dismisses
// a phone's on-screen keyboard, so it belongs to whichever field is
// taking keystrokes rather than to the window.
SetTextInput :: proc(on: bool) {
	if on == state.text_input {
		return
	}
	state.text_input = on
	if on {
		_ = sdl.StartTextInput(state.window)
		return
	}
	_ = sdl.StopTextInput(state.window)
	set_preedit("") // a half-composed string has nowhere to land now
}

// Where the text being edited sits, in window points. The compositor
// puts the IME candidate list (and a keyboard's own suggestions) beside
// it rather than over it.
SetTextInputArea :: proc(x, y, w, h: i32) {
	r := sdl.Rect{c.int(x), c.int(y), c.int(w), c.int(h)}
	_ = sdl.SetTextInputArea(state.window, &r, 0)
}

// True when the machine has a touch screen. Taps already arrive as
// mouse events; this is for the controls that have to be bigger and
// the gestures that have no mouse equivalent.
HasTouch :: proc() -> bool {
	return state.touch
}

GetScreenWidth :: proc() -> i32 {
	w, h: c.int
	sdl.GetWindowSize(state.window, &w, &h)
	return i32(w)
}

GetScreenHeight :: proc() -> i32 {
	w, h: c.int
	sdl.GetWindowSize(state.window, &w, &h)
	return i32(h)
}

// Leave events queued for WindowShouldClose, waking immediately on input.
Wait :: proc(ms: u32) {
	_ = sdl.WaitEventTimeout(nil, i32(ms))
}

GetFrameTime :: proc() -> f32 {
	return state.frame_dt
}

GetTime :: proc() -> f64 {
	return f64(sdl.GetTicksNS()) / 1e9
}

TakeScreenshot :: proc(path: cstring) {
	surface := sdl.RenderReadPixels(state.renderer, nil)
	if surface == nil {
		fmt.eprintfln("sdl: screenshot failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	if rgba == nil {
		return
	}
	defer sdl.DestroySurface(rgba)
	stbi.write_png(path, rgba.w, rgba.h, 4, rgba.pixels, rgba.pitch)
	fmt.eprintfln("sdlrl: screenshot saved to %s", path)
}

// ── Input queries ───────────────────────────────────────────────────

IsKeyPressed :: proc(key: KeyboardKey) -> bool {
	return state.pressed[key]
}

IsKeyPressedRepeat :: proc(key: KeyboardKey) -> bool {
	return state.repeated[key]
}

IsKeyDown :: proc(key: KeyboardKey) -> bool {
	return state.down[key]
}

GetCharPressed :: proc() -> rune {
	if len(state.chars) == 0 {
		return 0
	}
	r := state.chars[0]
	ordered_remove(&state.chars, 0)
	return r
}

// Test hook: inject a rune as if it arrived from TEXT_INPUT, so a
// headless run can type.
PushChar :: proc(r: rune) {
	append(&state.chars, r)
}

// Test hooks: inject key, button and wheel state as if the event pump had
// seen it. WindowShouldClose clears the per-frame flags at the top of the
// next iteration, so a value set from inside the frame loop lasts exactly
// that frame, which is what a real press does.
PushKey :: proc(key: KeyboardKey, down: bool) {
	state.pressed[key] = down
	state.down[key] = down
}

PushMouseButton :: proc(button: MouseButton, down: bool) {
	state.m_pressed[button] = down
	state.m_released[button] = !down
	state.m_down[button] = down
}

PushWheel :: proc(delta: Vector2) {
	state.wheel = delta
}

IsMouseButtonPressed :: proc(button: MouseButton) -> bool {
	return state.m_pressed[button]
}

IsMouseButtonReleased :: proc(button: MouseButton) -> bool {
	return state.m_released[button]
}

IsMouseButtonDown :: proc(button: MouseButton) -> bool {
	return state.m_down[button]
}

GetMousePosition :: proc() -> Vector2 {
	x, y: f32
	_ = sdl.GetMouseState(&x, &y)
	return {x, y}
}

GetMouseWheelMoveV :: proc() -> Vector2 {
	return state.wheel
}

// Click count of this frame's LEFT press (2 = double, 3 = triple).
GetMouseClicks :: proc() -> int {
	return int(state.m_clicks)
}

GetClipboardText :: proc() -> cstring {
	return cstring(sdl.GetClipboardText())
}

SetClipboardText :: proc(text: cstring) {
	sdl.SetClipboardText(text)
}

// X11/Wayland primary selection (select-to-copy, middle-click paste).
GetPrimaryText :: proc() -> cstring {
	return cstring(sdl.GetPrimarySelectionText())
}

SetPrimaryText :: proc(text: cstring) {
	sdl.SetPrimarySelectionText(text)
}

// Clipboard payload for one MIME type ("image/png" when a screenshot
// tool copied a picture, "text/uri-list" for files copied in a file
// manager). Empty when the clipboard holds no such type.
GetClipboardBytes :: proc(mime: cstring, allocator := context.allocator) -> []u8 {
	if !sdl.HasClipboardData(mime) {
		return nil
	}
	size: uint
	p := sdl.GetClipboardData(mime, &size)
	if p == nil {
		return nil
	}
	defer sdl.free(p)
	out := make([]u8, size, allocator)
	runtime.mem_copy(raw_data(out), p, int(size))
	return out
}

// ── Textures / images ───────────────────────────────────────────────

LoadImageFromMemory :: proc(ext: cstring, data: [^]u8, size: i32) -> Image {
	if size >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return decode_webp(data, size)
	}
	w, h, comp: c.int
	pixels := stbi.load_from_memory(data, size, &w, &h, &comp, 4)
	return {data = pixels, width = i32(w), height = i32(h)}
}

LoadImage :: proc(path: cstring) -> Image {
	data, err := os.read_entire_file(string(path), context.allocator)
	if err != nil {return {}}
	defer delete(data)
	return LoadImageFromMemory("", raw_data(data), i32(len(data)))
}

UnloadImage :: proc(image: Image) {
	if image.data != nil {
		stbi.image_free(image.data)
	}
}

LoadTextureFromImage :: proc(image: Image) -> Texture2D {
	if image.data == nil {
		return {}
	}
	tex := sdl.CreateTexture(state.renderer, .RGBA32, .STATIC, image.width, image.height)
	track_texture(tex)
	if tex == nil {
		return {}
	}
	sdl.UpdateTexture(tex, nil, image.data, image.width * 4)
	sdl.SetTextureBlendMode(tex, {.BLEND})
	sdl.SetTextureScaleMode(tex, .LINEAR)
	return {tex = tex, width = image.width, height = image.height}
}

UnloadTexture :: proc(texture: Texture2D) {
	if texture.tex != nil {
		when #config(WN_RELOAD, false) {delete_key(&live_textures, texture.tex)}
		sdl.DestroyTexture(texture.tex)
	}
}

// Streaming texture for the video embeds. Without blending the format
// is RGBX, not RGBA: mpv's "rgb0" frames carry 0 in the padding byte,
// and BLENDMODE_NONE writes that byte through to the target the whole
// frame is composited from, punching a transparent hole where the
// video should be. An X format has no alpha to write, so the blit
// lands opaque.
CreateStreamTexture :: proc(w, h: i32, blend := false) -> Texture2D {
	tex := sdl.CreateTexture(state.renderer, blend ? .RGBA32 : .RGBX32, .STREAMING, w, h)
	track_texture(tex)
	if tex == nil {
		return {}
	}
	sdl.SetTextureBlendMode(tex, blend ? {.BLEND} : {})
	sdl.SetTextureScaleMode(tex, .LINEAR)
	return {tex = tex, width = w, height = h}
}

UpdateTexturePixels :: proc(texture: ^Texture2D, rgba: [^]u8) {
	if texture.tex == nil {
		return
	}
	// A rejected upload leaves the texture at whatever it held before
	// (black, for a fresh one), which is invisible without this.
	if !sdl.UpdateTexture(texture.tex, nil, rgba, texture.width * 4) {
		fmt.eprintfln(
			"sdlrl: UpdateTexture %dx%d failed: %s",
			texture.width,
			texture.height,
			sdl.GetError(),
		)
	}
}

SetTextureFilter :: proc(texture: Texture2D, filter: TextureFilter) {} 	// LINEAR set at load

// Vertex-colored triangle soup for the STL viewer, in layout coords
// (the render scale applies). Clips to the given rect intersected
// with the active clay scissor, and restores that scissor after, so
// a zoomed model can't paint over neighboring timeline rows.
Vertex :: sdl.Vertex
FColor :: sdl.FColor

// A texture, when given, is sampled with each vertex's tex_coord and
// modulated by its color (the inspector's UV-checker view).
DrawTrianglesClipped :: proc(vertices: []Vertex, x, y, w, h: f32, texture: ^Texture2D = nil) {
	prev: sdl.Rect
	had_prev :=
		sdl.RenderClipEnabled(state.renderer) && sdl.GetRenderClipRect(state.renderer, &prev)

	clip := sdl.Rect{c.int(x), c.int(y), c.int(w), c.int(h)}
	if had_prev && !sdl.GetRectIntersection(prev, clip, &clip) {
		return // tile fully scrolled out of the scissor
	}
	sdl.SetRenderClipRect(state.renderer, &clip)
	tex := texture != nil ? texture.tex : nil
	sdl.RenderGeometry(state.renderer, tex, raw_data(vertices), c.int(len(vertices)), nil, 0)
	sdl.SetRenderClipRect(state.renderer, had_prev ? &prev : nil)
}

// ── Drawing (called by the clay renderer) ───────────────────────────

@(private)
set_color :: proc(color: Color) {
	sdl.SetRenderDrawColor(state.renderer, color.r, color.g, color.b, color.a)
}

DrawRectangleRec :: proc(x, y, w, h: f32, color: Color) {
	set_color(color)
	rect := sdl.FRect{x, y, w, h}
	sdl.RenderFillRect(state.renderer, &rect)
}

DrawTextureRect :: proc(texture: ^Texture2D, x, y, w, h: f32, tint: Color) {
	sdl.SetTextureColorMod(texture.tex, tint.r, tint.g, tint.b)
	sdl.SetTextureAlphaMod(texture.tex, tint.a)
	dest := sdl.FRect{x, y, w, h}
	sdl.RenderTexture(state.renderer, texture.tex, nil, &dest)
}

@(private)
Clip_State :: struct {
	rect:    sdl.Rect,
	enabled: bool,
}

@(private)
clip_stack: [dynamic]Clip_State

BeginScissorMode :: proc(x, y, w, h: i32) {
	// Nested text clips must preserve the enclosing scroll viewport.
	prev: sdl.Rect
	enabled := sdl.RenderClipEnabled(state.renderer)
	if enabled {
		sdl.GetRenderClipRect(state.renderer, &prev)
	}
	append(&clip_stack, Clip_State{prev, enabled})
	rect := sdl.Rect{c.int(x), c.int(y), c.int(w), c.int(h)}
	if enabled && !sdl.GetRectIntersection(prev, rect, &rect) {
		rect = {}
	}
	sdl.SetRenderClipRect(state.renderer, &rect)
}

EndScissorMode :: proc() {
	prev := pop(&clip_stack)
	sdl.SetRenderClipRect(state.renderer, prev.enabled ? &prev.rect : nil)
}

// Filled rounded rectangle, ported from clay_renderer_SDL3.c.
DrawRectangleRoundedPx :: proc(x, y, w, h, corner_radius: f32, color: Color) {
	fcolor := sdl.FColor {
		f32(color.r) / 255,
		f32(color.g) / 255,
		f32(color.b) / 255,
		f32(color.a) / 255,
	}
	radius := min(corner_radius, min(w, h) / 2)
	segments := max(16, int(radius * 0.5))

	vertices := make([dynamic]sdl.Vertex, context.temp_allocator)
	indices := make([dynamic]c.int, context.temp_allocator)
	push :: proc(vertices: ^[dynamic]sdl.Vertex, px, py: f32, fcolor: sdl.FColor) -> c.int {
		append(vertices, sdl.Vertex{position = {px, py}, color = fcolor})
		return c.int(len(vertices) - 1)
	}
	tri :: proc(indices: ^[dynamic]c.int, a, b, cc: c.int) {
		append(indices, a, b, cc)
	}

	// center quad
	tl := push(&vertices, x + radius, y + radius, fcolor)
	tr := push(&vertices, x + w - radius, y + radius, fcolor)
	br := push(&vertices, x + w - radius, y + h - radius, fcolor)
	bl := push(&vertices, x + radius, y + h - radius, fcolor)
	tri(&indices, tl, tr, bl)
	tri(&indices, tr, br, bl)

	// corner fans
	step := (math.PI / 2) / f32(segments)
	corners := [4]struct {
		cx, cy, sx, sy: f32,
		center:         c.int,
	} {
		{x + radius, y + radius, -1, -1, tl},
		{x + w - radius, y + radius, 1, -1, tr},
		{x + w - radius, y + h - radius, 1, 1, br},
		{x + radius, y + h - radius, -1, 1, bl},
	}
	for corner in corners {
		for i in 0 ..< segments {
			a1 := f32(i) * step
			a2 := f32(i + 1) * step
			v1 := push(
				&vertices,
				corner.cx + math.cos(a1) * radius * corner.sx,
				corner.cy + math.sin(a1) * radius * corner.sy,
				fcolor,
			)
			v2 := push(
				&vertices,
				corner.cx + math.cos(a2) * radius * corner.sx,
				corner.cy + math.sin(a2) * radius * corner.sy,
				fcolor,
			)
			tri(&indices, corner.center, v1, v2)
		}
	}

	// edge quads
	et1 := push(&vertices, x + radius, y, fcolor)
	et2 := push(&vertices, x + w - radius, y, fcolor)
	tri(&indices, tl, et1, et2)
	tri(&indices, tr, tl, et2)
	er1 := push(&vertices, x + w, y + radius, fcolor)
	er2 := push(&vertices, x + w, y + h - radius, fcolor)
	tri(&indices, tr, er1, er2)
	tri(&indices, br, tr, er2)
	eb1 := push(&vertices, x + w - radius, y + h, fcolor)
	eb2 := push(&vertices, x + radius, y + h, fcolor)
	tri(&indices, br, eb1, eb2)
	tri(&indices, bl, br, eb2)
	el1 := push(&vertices, x, y + h - radius, fcolor)
	el2 := push(&vertices, x, y + radius, fcolor)
	tri(&indices, bl, el1, el2)
	tri(&indices, tl, bl, el2)

	sdl.RenderGeometry(
		state.renderer,
		nil,
		raw_data(vertices),
		c.int(len(vertices)),
		raw_data(indices),
		c.int(len(indices)),
	)
}

// Border corner arc as a filled annular sector (triangle strip), so
// it stays solid at any render scale.
DrawArc :: proc(cx, cy, radius, start_deg, end_deg, thickness: f32, color: Color) {
	fcolor := sdl.FColor {
		f32(color.r) / 255,
		f32(color.g) / 255,
		f32(color.b) / 255,
		f32(color.a) / 255,
	}
	outer := radius
	inner := max(radius - max(thickness, 1), 0)
	rad_start := start_deg * math.PI / 180
	rad_end := end_deg * math.PI / 180
	segments := max(16, int(radius * 1.5))
	angle_step := (rad_end - rad_start) / f32(segments)

	vertices := make([dynamic]sdl.Vertex, context.temp_allocator)
	indices := make([dynamic]c.int, context.temp_allocator)
	for i in 0 ..= segments {
		angle := rad_start + f32(i) * angle_step
		cos := math.cos(angle)
		sin := math.sin(angle)
		append(
			&vertices,
			sdl.Vertex{position = {cx + cos * outer, cy + sin * outer}, color = fcolor},
		)
		append(
			&vertices,
			sdl.Vertex{position = {cx + cos * inner, cy + sin * inner}, color = fcolor},
		)
	}
	for i in 0 ..< segments {
		o0 := c.int(i * 2)
		i0 := o0 + 1
		o1 := o0 + 2
		i1 := o0 + 3
		append(&indices, o0, i0, o1, i0, i1, o1)
	}
	sdl.RenderGeometry(
		state.renderer,
		nil,
		raw_data(vertices),
		c.int(len(vertices)),
		raw_data(indices),
		c.int(len(indices)),
	)
}

// ── Text engine ─────────────────────────────────────────────────────

// dpi * zoom factor glyphs rasterize at; drawing divides it back out
// so the render scale re-magnifies to exact pixels.
SetPixelScale :: proc(scale: f32) {
	state.pixel_scale = max(scale, 0.1)
}

// Register a font id as an ordered fallback stack of files (first hit
// per glyph wins). Missing files are skipped. The optional image resolver
// shares the app's emoji cache between text measurement and drawing.
LoadFontStack :: proc(
	font_id: u16,
	paths: []cstring,
	text_image: proc(text: string) -> ^Texture2D = nil,
) {
	if text_image != nil {
		state.text_image = text_image
	}
	indices := make([dynamic]int)
	for path in paths {
		if !os.exists(string(path)) {
			continue
		}
		found := -1
		for file, i in state.fonts {
			if file.path == string(path) {
				found = i
				break
			}
		}
		if found < 0 {
			data, err := os.read_entire_file(string(path), context.allocator)
			if err != nil {
				continue
			}
			file := Font_File {
				path = strings.clone(string(path)),
				data = data,
			}
			offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
			file.ok = bool(stbtt.InitFont(&file.info, raw_data(data), offset))
			append(&state.fonts, file)
			found = len(state.fonts) - 1
		}
		if state.fonts[found].ok {
			append(&indices, found)
		}
	}
	state.stacks[font_id] = indices[:]
}

@(private)
glyph_key :: proc(file: int, px: u16, r: rune) -> u64 {
	return u64(file) << 56 | u64(px) << 40 | u64(u32(r))
}

@(private)
font_ascent :: proc(file: int, px: u16) -> f32 {
	key := u64(file) << 16 | u64(px)
	if cached, ok := state.ascents[key]; ok {
		return cached
	}
	info := &state.fonts[file].info
	ascent, descent, gap: c.int
	stbtt.GetFontVMetrics(info, &ascent, &descent, &gap)
	scale := stbtt.ScaleForPixelHeight(info, f32(px))
	value := f32(ascent) * scale
	state.ascents[key] = value
	return value
}

// Resolve one rune through the font id's stack, rasterizing on first
// use. Returns a whitespace/missing glyph with just an advance when no
// stack font covers it.
@(private)
get_glyph :: proc(font_id: u16, px: u16, r: rune) -> (Glyph, int) {
	stack, ok := state.stacks[font_id]
	if !ok || len(stack) == 0 {
		return {advance = f32(px) / 2}, 0
	}

	file := stack[0]
	for candidate in stack {
		if stbtt.FindGlyphIndex(&state.fonts[candidate].info, r) != 0 {
			file = candidate
			break
		}
	}

	key := glyph_key(file, px, r)
	if cached, hit := state.glyphs[key]; hit {
		return cached, file
	}

	info := &state.fonts[file].info
	scale := stbtt.ScaleForPixelHeight(info, f32(px))
	advance, lsb: c.int
	stbtt.GetCodepointHMetrics(info, r, &advance, &lsb)

	glyph := Glyph {
		advance = f32(advance) * scale,
		file    = file,
	}
	w, h, xoff, yoff: c.int
	bitmap := stbtt.GetCodepointBitmap(info, scale, scale, r, &w, &h, &xoff, &yoff)
	if bitmap != nil && w > 0 && h > 0 {
		defer stbtt.FreeBitmap(bitmap, nil)
		rgba := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
		for i in 0 ..< int(w) * int(h) {
			rgba[i * 4 + 0] = 255
			rgba[i * 4 + 1] = 255
			rgba[i * 4 + 2] = 255
			rgba[i * 4 + 3] = bitmap[i]
		}
		tex := sdl.CreateTexture(state.renderer, .RGBA32, .STATIC, i32(w), i32(h))
		track_texture(tex)
		if tex != nil {
			sdl.UpdateTexture(tex, nil, raw_data(rgba), w * 4)
			sdl.SetTextureBlendMode(tex, {.BLEND})
			sdl.SetTextureScaleMode(tex, .LINEAR)
			glyph.tex = tex
			glyph.w = i32(w)
			glyph.h = i32(h)
			glyph.xoff = i32(xoff)
			glyph.yoff = i32(yoff)

			// Icon glyphs are laid out by their ink, not by the font's
			// advance: Nerd Font cells carry wide, asymmetric bearings,
			// so an advance-sized box leaves the mark visibly off-centre
			// inside a square button. The box becomes the ink plus a
			// symmetric bearing, and DrawTextLine centers the ink in it
			// vertically too.
			if font_id == IconFont {
				pad := f32(px) / 8
				glyph.advance = f32(w) + 2 * pad
				glyph.xoff = i32(pad)
				glyph.icon = true
			}
		}
	}
	state.glyphs[key] = glyph
	return glyph, file
}

// Width/height of one line at the given logical size, matching what
// DrawTextLine paints. Height is the font size, clay's convention.
MeasureTextLine :: proc(font_id: u16, size: u16, text: string, letter_spacing: f32) -> Vector2 {
	px := u16(f32(size) * state.pixel_scale + 0.5)
	width: f32 = 0
	it := utf8.decode_grapheme_iterator_make(text)
	for cluster, _ in utf8.decode_grapheme_iterate(&it) {
		if font_id != IconFont && state.text_image != nil && state.text_image(cluster) != nil {
			width += f32(size) + letter_spacing
			continue
		}
		for r in cluster {
			if r == 0xFE0E || r == 0xFE0F || r == 0x200D {continue}
			glyph, _ := get_glyph(font_id, px, r)
			width += glyph.advance / state.pixel_scale + letter_spacing
		}
	}
	return {width, f32(size)}
}

// Draw one line of text with per-rune font fallback. Coordinates are
// in the scaled drawing space; glyphs are baked pixel_scale denser so
// the render scale lands them 1:1 on output pixels.
DrawTextLine :: proc(
	font_id: u16,
	size: u16,
	text: string,
	x, y: f32,
	letter_spacing: f32,
	color: Color,
) {
	px := u16(f32(size) * state.pixel_scale + 0.5)
	pen := x
	it := utf8.decode_grapheme_iterator_make(text)
	for cluster, _ in utf8.decode_grapheme_iterate(&it) {
		if font_id != IconFont && state.text_image != nil {
			if tex := state.text_image(cluster); tex != nil {
				DrawTextureRect(tex, pen, y, f32(size), f32(size), {255, 255, 255, color.a})
				pen += f32(size) + letter_spacing
				continue
			}
		}
		for r in cluster {
			if r == 0xFE0E || r == 0xFE0F || r == 0x200D {continue}
			glyph, file := get_glyph(font_id, px, r)
			if glyph.tex != nil {
				sdl.SetTextureColorMod(glyph.tex, color.r, color.g, color.b)
				sdl.SetTextureAlphaMod(glyph.tex, color.a)
				ascent := font_ascent(file, px)
				// Snap to the output pixel grid so 1:1 glyphs never sample
				// between pixels.
				ps := state.pixel_scale
				// Text sits on the baseline; an icon is centered in the
				// line box instead, so a square button holds it dead center.
				top := y + (ascent + f32(glyph.yoff)) / ps
				if glyph.icon {
					top = y + (f32(size) - f32(glyph.h) / ps) / 2
				}
				dest := sdl.FRect {
					math.round((pen + f32(glyph.xoff) / ps) * ps) / ps,
					math.round(top * ps) / ps,
					f32(glyph.w) / ps,
					f32(glyph.h) / ps,
				}
				sdl.RenderTexture(state.renderer, glyph.tex, nil, &dest)
			}
			pen += glyph.advance / state.pixel_scale + letter_spacing
		}
	}
}

// ── Additive light (the soft sprite) ────────────────────────────────
//
// SDL_Renderer has no shaders, so every "glow" in the app is one
// pre-blurred sprite drawn with additive blending. The sprite is a
// rounded box whose alpha falls off over SOFT_PAD pixels; 9-slicing it
// stretches the flat middle and keeps the falloff, so any rectangle
// gets a halo without a blur pass.
//
//   ┌──┬────┬──┐   corners: SOFT_PAD*2 of sprite, drawn at spread*2
//   ├──┼────┼──┤   edges:   stretched along one axis
//   └──┴────┴──┘   middle:  the flat core

SOFT_PX :: 96
SOFT_PAD :: 16 // falloff width in sprite pixels; the 9-slice inset is 2x it,
// which leaves SOFT_PX - SOFT_PAD*4 for the stretched middle band

@(private)
soft_tex: ^sdl.Texture

// Alpha = squared falloff from the inner box, so the halo reads as
// light rather than as a second rectangle.
@(private)
soft_sprite :: proc() -> ^sdl.Texture {
	if soft_tex != nil {
		return soft_tex
	}
	pixels: [SOFT_PX * SOFT_PX * 4]u8
	for y in 0 ..< SOFT_PX {
		for x in 0 ..< SOFT_PX {
			dx := max(f32(SOFT_PAD - x), f32(x - (SOFT_PX - SOFT_PAD - 1)), 0)
			dy := max(f32(SOFT_PAD - y), f32(y - (SOFT_PX - SOFT_PAD - 1)), 0)
			d := math.sqrt(dx * dx + dy * dy) / SOFT_PAD
			a := clamp(1 - d, 0, 1)
			i := (y * SOFT_PX + x) * 4
			pixels[i], pixels[i + 1], pixels[i + 2] = 255, 255, 255
			pixels[i + 3] = u8(a * a * 255)
		}
	}
	soft_tex = sdl.CreateTexture(state.renderer, .RGBA32, .STATIC, SOFT_PX, SOFT_PX)
	track_texture(soft_tex)
	if soft_tex == nil {
		return nil
	}
	sdl.UpdateTexture(soft_tex, nil, &pixels[0], SOFT_PX * 4)
	sdl.SetTextureBlendMode(soft_tex, {.ADD})
	sdl.SetTextureScaleMode(soft_tex, .LINEAR)
	return soft_tex
}

// A halo `spread` px wide around the given box.
DrawGlow :: proc(x, y, w, h, spread: f32, color: Color) {
	tex := soft_sprite()
	if tex == nil || w <= 0 || h <= 0 {
		return
	}
	sdl.SetTextureColorMod(tex, color.r, color.g, color.b)
	sdl.SetTextureAlphaMod(tex, color.a)

	// The sprite's corner quadrant is SOFT_PAD*2 wide, half falloff and
	// half core, so a spread of s draws it at 2s and the stretched
	// middle covers whatever is left of the box.
	s := max(min(spread, w / 2, h / 2), 1)
	src_c := f32(SOFT_PAD * 2)
	src_m := f32(SOFT_PX - SOFT_PAD * 4)
	x0, y0 := x - s, y - s
	mid_w := w + s * 2 - s * 4
	mid_h := h + s * 2 - s * 4
	cols := [3]f32{x0, x0 + s * 2, x0 + s * 2 + mid_w}
	rows := [3]f32{y0, y0 + s * 2, y0 + s * 2 + mid_h}
	ws := [3]f32{s * 2, mid_w, s * 2}
	hs := [3]f32{s * 2, mid_h, s * 2}
	src_x := [3]f32{0, src_c, src_c + src_m}
	src_w := [3]f32{src_c, src_m, src_c}

	for r in 0 ..< 3 {
		for c in 0 ..< 3 {
			// The middle cell is the element itself: light belongs
			// around it, not washed over its content.
			if (r == 1 && c == 1) || ws[c] <= 0 || hs[r] <= 0 {
				continue
			}
			src := sdl.FRect{src_x[c], src_x[r], src_w[c], src_w[r]}
			dest := sdl.FRect{cols[c], rows[r], ws[c], hs[r]}
			sdl.RenderTexture(state.renderer, tex, &src, &dest)
		}
	}
}

// The current backbuffer as a texture. One GPU→CPU→GPU round trip, so
// this is for one-shot transitions (the theme reveal), not per frame.
CaptureFrame :: proc() -> Texture2D {
	surface := sdl.RenderReadPixels(state.renderer, nil)
	if surface == nil {
		return {}
	}
	defer sdl.DestroySurface(surface)
	tex := sdl.CreateTextureFromSurface(state.renderer, surface)
	track_texture(tex)
	if tex == nil {
		return {}
	}
	sdl.SetTextureBlendMode(tex, {.BLEND})
	sdl.SetTextureScaleMode(tex, .LINEAR)
	return {tex = tex, width = surface.w, height = surface.h}
}

// ── Off-screen targets ──────────────────────────────────────────────
//
// SDL_Renderer has no shaders, but it does have render targets, and a
// target is enough for the two things the app could not do without one:
// draw a whole subtree at an opacity, and blur what is behind a modal.
//
// The blur is a bilinear downsample chain. Halving with LINEAR sampling
// lands each destination pixel exactly between four source texels, so
// one step is an exact 2x2 box filter; four steps and one stretch back
// is a ~16px radius blur for the cost of five textured quads.
//
//   frame ──▶ 1/2 ──▶ 1/4 ──▶ 1/8 ──▶ 1/16 ──stretch──▶ screen

TARGET_SLOTS :: 6 // named by the SLOT constants in renderer.odin
BLUR_STEPS :: 4
TARGET_DEPTH :: 2 // the frame, and the layer split inside it

@(private)
Target :: struct {
	tex:  ^sdl.Texture,
	w, h: i32,
}

@(private)
targets: [TARGET_SLOTS]Target
@(private)
blur_chain: [BLUR_STEPS]Target

// The view state under each bound target, so leaving one puts back
// exactly what the caller had.
@(private)
View_State :: struct {
	target:   ^sdl.Texture,
	scale:    Vector2,
	viewport: sdl.Rect,
	had_vp:   bool,
	clip:     sdl.Rect,
	had_clip: bool,
}

@(private)
target_stack: [TARGET_DEPTH]View_State
@(private)
target_depth: int

@(private)
ensure_target :: proc(t: ^Target, w, h: i32) -> bool {
	if t.tex != nil && t.w == w && t.h == h {
		return true
	}
	if t.tex != nil {
		when #config(WN_RELOAD, false) {delete_key(&live_textures, t.tex)}
		sdl.DestroyTexture(t.tex)
		t.tex = nil
	}
	if w <= 0 || h <= 0 {
		return false
	}
	tex := sdl.CreateTexture(state.renderer, .RGBA32, .TARGET, w, h)
	track_texture(tex)
	if tex == nil {
		return false
	}
	sdl.SetTextureBlendMode(tex, {.BLEND})
	sdl.SetTextureScaleMode(tex, .LINEAR)
	t^ = {tex, w, h}
	return true
}

// Physical pixels, which is what a target must cover: the render scale
// folds the DPI density in, so the window's logical size is smaller.
@(private)
frame_size :: proc() -> (w, h: i32) {
	return i32(f32(GetScreenWidth()) * state.density), i32(f32(GetScreenHeight()) * state.density)
}

// Send everything drawn from here until EndTarget into slot instead of
// the window. The scale and viewport carry over, so the caller's
// coordinates mean the same thing they did on screen. False means the
// GPU refused the texture and the caller should just draw normally.
BeginTarget :: proc(slot: int) -> bool {
	w, h := frame_size()
	if target_depth >= TARGET_DEPTH || !ensure_target(&targets[slot], w, h) {
		return false
	}
	saved := &target_stack[target_depth]
	saved^ = capture_view()
	if !sdl.SetRenderTarget(state.renderer, targets[slot].tex) {
		return false
	}
	target_depth += 1
	sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
	sdl.RenderClear(state.renderer)
	sdl.SetRenderScale(state.renderer, saved.scale.x, saved.scale.y)
	if saved.had_vp {
		sdl.SetRenderViewport(state.renderer, &saved.viewport)
	}
	return true
}

EndTarget :: proc() {
	if target_depth == 0 {
		return
	}
	target_depth -= 1
	restore_view(target_stack[target_depth])
}

@(private)
capture_view :: proc() -> (saved: View_State) {
	if current, bound := sdl.GetRenderTarget(state.renderer).?; bound {
		saved.target = current
	}
	sdl.GetRenderScale(state.renderer, &saved.scale.x, &saved.scale.y)
	saved.had_vp = sdl.RenderViewportSet(state.renderer)
	sdl.GetRenderViewport(state.renderer, &saved.viewport)
	saved.had_clip = sdl.RenderClipEnabled(state.renderer)
	sdl.GetRenderClipRect(state.renderer, &saved.clip)
	return
}

@(private)
restore_view :: proc(saved: View_State) {
	view := saved // the rects go back by pointer, so they need an address
	sdl.SetRenderTarget(state.renderer, view.target)
	sdl.SetRenderScale(state.renderer, view.scale.x, view.scale.y)
	sdl.SetRenderViewport(state.renderer, view.had_vp ? &view.viewport : nil)
	sdl.SetRenderClipRect(state.renderer, view.had_clip ? &view.clip : nil)
}

// Physical pixels, no viewport, no clip: a target is a picture of the
// window, so it goes back on 1:1 whatever the layout scale is.
@(private)
begin_raw :: proc() -> View_State {
	saved := capture_view()
	sdl.SetRenderScale(state.renderer, 1, 1)
	sdl.SetRenderViewport(state.renderer, nil)
	sdl.SetRenderClipRect(state.renderer, nil)
	return saved
}

// Put a target back on the window. `scale` grows or shrinks it about
// the center, which is how a whole modal layer lifts in and falls away.
DrawTarget :: proc(slot: int, alpha: f32, scale: f32 = 1) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)
	sdl.SetTextureAlphaMod(t.tex, u8(clamp(alpha, 0, 1) * 255))
	w, h := f32(t.w) * scale, f32(t.h) * scale
	dest := sdl.FRect{(f32(t.w) - w) / 2, (f32(t.h) - h) / 2, w, h}
	sdl.RenderTexture(state.renderer, t.tex, nil, &dest)
	sdl.SetTextureAlphaMod(t.tex, 255)
}

// The same target, out of focus. Drawn over the sharp one at a rising
// alpha, this is a lens pulling off the page rather than a cut.
DrawTargetBlurred :: proc(slot: int, alpha: f32) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)

	src := t
	built := 0
	for i in 0 ..< BLUR_STEPS {
		w, h := max(t.w >> u32(i + 1), 1), max(t.h >> u32(i + 1), 1)
		if !ensure_target(&blur_chain[i], w, h) {
			break
		}
		sdl.SetRenderTarget(state.renderer, blur_chain[i].tex)
		sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
		sdl.RenderClear(state.renderer)
		dest := sdl.FRect{0, 0, f32(w), f32(h)}
		sdl.SetTextureAlphaMod(src.tex, 255)
		sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
		src = blur_chain[i]
		built = i + 1
	}
	// Walk back up the chain: one straight 16x stretch shows its texel
	// grid as blocky gradients, while doubling through the levels
	// bilinear-filters the reconstruction at every step.
	for i := built - 2; i >= 0; i -= 1 {
		sdl.SetRenderTarget(state.renderer, blur_chain[i].tex)
		sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
		sdl.RenderClear(state.renderer)
		dest := sdl.FRect{0, 0, f32(blur_chain[i].w), f32(blur_chain[i].h)}
		sdl.SetTextureAlphaMod(src.tex, 255)
		sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
		src = blur_chain[i]
	}
	sdl.SetRenderTarget(state.renderer, saved.target)
	if src.tex == t.tex {
		return // no scratch texture: leave the sharp frame alone
	}
	sdl.SetTextureAlphaMod(src.tex, u8(clamp(alpha, 0, 1) * 255))
	dest := sdl.FRect{0, 0, f32(t.w), f32(t.h)}
	sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
	sdl.SetTextureAlphaMod(src.tex, 255)
}

// Copy one target onto another, whole. Used to hold the frame that was
// on screen a moment ago while the next one takes its place.
CopyTarget :: proc(dst_slot, src_slot: int) -> bool {
	src := targets[src_slot]
	if src.tex == nil || !ensure_target(&targets[dst_slot], src.w, src.h) {
		return false
	}
	saved := begin_raw()
	defer restore_view(saved)
	sdl.SetRenderTarget(state.renderer, targets[dst_slot].tex)
	sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
	sdl.RenderClear(state.renderer)
	sdl.SetTextureAlphaMod(src.tex, 255)
	sdl.RenderTexture(state.renderer, src.tex, nil, nil)
	return true
}

// Draw src over dst at an alpha, without clearing dst first. Repeated
// every frame this makes dst an exponentially decayed history of src,
// which is the whole of the motion trail: each frame is worth `alpha`,
// the one before it `alpha*(1-alpha)`, and so on back.
FadeTargetInto :: proc(dst_slot, src_slot: int, alpha: f32) -> bool {
	src := targets[src_slot]
	if src.tex == nil || !ensure_target(&targets[dst_slot], src.w, src.h) {
		return false
	}
	saved := begin_raw()
	defer restore_view(saved)
	sdl.SetRenderTarget(state.renderer, targets[dst_slot].tex)
	sdl.SetTextureAlphaMod(src.tex, u8(clamp(alpha, 0, 1) * 255))
	sdl.RenderTexture(state.renderer, src.tex, nil, nil)
	sdl.SetTextureAlphaMod(src.tex, 255)
	return true
}

// One rectangle of a target, scaled about its centre and translated within
// its original clip. Geometry is in window points; DPI density stays here.
DrawTargetRegion :: proc(
	slot: int,
	x, y, w, h: f32,
	alpha: f32,
	scale: f32 = 1,
	offset_x: f32 = 0,
) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 || w <= 0 || h <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)
	src := sdl.FRect{x * state.density, y * state.density, w * state.density, h * state.density}
	grow := sdl.FRect{src.w * (scale - 1) / 2, src.h * (scale - 1) / 2, 0, 0}
	dest := sdl.FRect{src.x - grow.x, src.y - grow.y, src.w * scale, src.h * scale}
	dest.x += offset_x * state.density
	// Clipped to where it belongs, so a scaled-up region can't spill
	// past the card it is dissolving inside.
	clip := sdl.Rect{i32(src.x), i32(src.y), i32(src.w), i32(src.h)}
	sdl.SetRenderClipRect(state.renderer, &clip)
	sdl.SetTextureAlphaMod(t.tex, u8(clamp(alpha, 0, 1) * 255))
	sdl.RenderTexture(state.renderer, t.tex, &src, &dest)
	sdl.SetTextureAlphaMod(t.tex, 255)
}
