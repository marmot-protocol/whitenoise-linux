// The webxdc app, in a modal, in this window.
//
// wn-webview (app/webview.c) runs the page in its own process and
// writes frames into a shared-memory buffer; here that buffer becomes
// a streaming texture drawn like any other image, and the modal's own
// bounding box maps the pointer back into page coordinates. Input goes
// back through a ring in the same buffer.
//
// Out of process is not a preference: webkit_web_view_load_uri takes
// over the calling thread's GL context, and in-process it turned this
// app's own renderer black the moment a page loaded.
//
// ponytail: one app at a time, fixed page size, and the child redraws
// on its own 60Hz timer whether the page changed or not.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// The page is rendered at the size it is shown at, in device pixels,
// with the page zoomed to match: a fixed buffer scaled up afterwards
// looked exactly like what it was.
//
// WEB_W/WEB_H are the CSS-pixel viewport the app lays out for; the
// capacity is what the shared buffer can hold, so the modal can grow
// to a 4K window without a reallocation.
WEB_W :: 900
WEB_H :: 620
WEB_CAP_W :: 3840
WEB_CAP_H :: 2160

// Room the modal leaves around the page: its own padding either side,
// plus the title bar above.
WEB_MARGIN :: 48
WEB_BAR :: 40

// Mirrors struct WnEvent / struct WnShm in app/webview.h. Both sides
// must agree on this layout byte for byte.
WEB_EV_CAP :: 256

Web_Event_Kind :: enum u32 {
	Move     = 1,
	Down     = 2,
	Up       = 3,
	Scroll   = 4,
	Key_Down = 5,
	Key_Up   = 6,
}

Web_Event :: struct {
	kind:   Web_Event_Kind,
	arg:    u32, // button number, or GDK keyval
	mods:   u32,
	pad:    u32,
	x, y:   f64, // widget-local pointer position
	dx, dy: f64,
}

Web_Shm :: struct {
	seq:            u32, // bumped by the child after each frame
	quit:           u32, // set here to end the child
	head:           u32, // written here
	tail:           u32, // written by the child
	w, h:           u32, // size of the published frame, written by the child
	want_w, want_h: u32, // size wanted, in device pixels
	zoom_milli:     u32, // page zoom * 1000
	pad:            u32,
	events:         [WEB_EV_CAP]Web_Event,
	// pixels (up to WEB_CAP_W * WEB_CAP_H * 4, RGBA) follow immediately.
}

// GDK button numbers, and the keyvals worth forwarding: everything
// else arrives as text through GetCharPressed.
GDK_BTN_LEFT :: 1
GDK_BTN_RIGHT :: 3
GDK_BACKSPACE :: 0xff08
GDK_RETURN :: 0xff0d
GDK_LEFT :: 0xff51
GDK_UP :: 0xff52
GDK_RIGHT :: 0xff53
GDK_DOWN :: 0xff54
GDK_DELETE :: 0xffff

Web_Key :: struct {
	key:    rl.KeyboardKey,
	keyval: u32,
}

WEB_KEYS :: [?]Web_Key {
	{.BACKSPACE, GDK_BACKSPACE},
	{.ENTER, GDK_RETURN},
	{.DELETE, GDK_DELETE},
	{.LEFT, GDK_LEFT},
	{.RIGHT, GDK_RIGHT},
	{.UP, GDK_UP},
	{.DOWN, GDK_DOWN},
}

Web_Modal :: struct {
	shm:    ^Web_Shm,
	pixels: [^]u8,
	size:   uint, // the whole mapping, for munmap
	path:   string, // the backing file, unlinked on close
	child:  os.Process,
	pipe:   ^os.File, // the child holds the read end; closing it ends the child
	tex:    rl.Texture2D,
	tex_w:  u32, // what the texture currently holds, so a resize rebuilds it
	tex_h:  u32,
	title:  string,
	seen:   u32, // last frame taken from the child
	open:   bool,
	down:   bool, // left button is held on the page
}

web_modal: Web_Modal

web_open :: proc(url, title: string) -> bool {
	web_close()

	viewer := web_viewer_path()
	if len(viewer) == 0 {
		fmt.eprintfln(
			"webxdc: no wn-webview beside %s (webkit2gtk-4.1 missing at build time?)",
			os.args[0],
		)
		return false
	}

	// A plain file under /dev/shm rather than shm_open, so the child
	// needs nothing but a path.
	path := fmt.tprintf("/dev/shm/wn-web-%d", os.get_pid())
	size := uint(size_of(Web_Shm) + WEB_CAP_W * WEB_CAP_H * 4)
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.RDWR, .CREAT, .TRUNC},
		{.IRUSR, .IWUSR},
	)
	if fd < 0 {
		fmt.eprintfln("webxdc: cannot create %s", path)
		return false
	}
	defer posix.close(fd)
	if posix.ftruncate(fd, posix.off_t(size)) != .OK {
		return false
	}

	mapped := posix.mmap(nil, size, {.READ, .WRITE}, {.SHARED}, fd, 0)
	if mapped == posix.MAP_FAILED {
		return false
	}

	// The child holds the read end of this pipe, so if this process
	// dies the app's window goes with it.
	reader, writer, pipe_err := os.pipe()
	if pipe_err != nil {
		fmt.eprintfln("webxdc: pipe failed: %v", pipe_err)
		posix.munmap(mapped, size)
		return false
	}
	child, err := os.process_start(
	{
		command = {viewer, url, path, fmt.tprintf("%d", WEB_CAP_W), fmt.tprintf("%d", WEB_CAP_H)},
		stdin   = reader,
		// The child's own output (and, under WN_DEBUG, the page's
		// console) lands in the app's log.
		stdout  = os.stderr,
		stderr  = os.stderr,
	},
	)
	os.close(reader)
	if err != nil {
		os.close(writer)
		posix.munmap(mapped, size)
		fmt.eprintfln("webxdc: %s failed to start: %v", viewer, err)
		return false
	}

	web_modal = {
		shm    = (^Web_Shm)(mapped),
		pixels = ([^]u8)(uintptr(mapped) + uintptr(size_of(Web_Shm))),
		size   = size,
		path   = strings.clone(path),
		child  = child,
		pipe   = writer,
		tex    = rl.CreateStreamTexture(WEB_W, WEB_H),
		tex_w  = WEB_W,
		tex_h  = WEB_H,
		title  = strings.clone(title),
		open   = true,
	}
	return true
}

web_close :: proc() {
	if !web_modal.open {
		return
	}
	web_modal.shm.quit = 1
	os.close(web_modal.pipe)
	_, _ = os.process_wait(web_modal.child)

	posix.munmap(rawptr(web_modal.shm), web_modal.size)
	if len(web_modal.path) > 0 {
		posix.unlink(strings.clone_to_cstring(web_modal.path, context.temp_allocator))
		delete(web_modal.path)
	}
	rl.UnloadTexture(web_modal.tex)
	delete(web_modal.title)
	web_modal = {}
}

// wn-webview sits beside the app binary; scripts/build.sh only produces it
// when webkit2gtk-4.1 is installed.
@(private = "file")
web_viewer_path :: proc() -> string {
	dir := "."
	if slash := strings.last_index_byte(os.args[0], '/'); slash >= 0 {
		dir = os.args[0][:slash]
	}
	path := fmt.tprintf("%s/wn-webview", dir)
	return os.is_file(path) ? path : ""
}

// Frame-loop step: take the child's newest frame, if there is one.
web_tick :: proc() {
	if !web_modal.open {
		return
	}
	// Ask for the size the modal actually occupies on screen, in device
	// pixels, and zoom the page so its CSS pixels stay the size the app
	// laid out for.
	w, h := web_fit()
	web_modal.shm.want_w = u32(w * UI_ZOOM)
	web_modal.shm.want_h = u32(h * UI_ZOOM)
	web_modal.shm.zoom_milli = u32(UI_ZOOM * 1000)

	seq := web_modal.shm.seq
	if seq == web_modal.seen {
		return
	}
	web_modal.seen = seq

	frame_w, frame_h := web_modal.shm.w, web_modal.shm.h
	if frame_w < 1 || frame_h < 1 {
		return
	}
	if frame_w != web_modal.tex_w || frame_h != web_modal.tex_h {
		rl.UnloadTexture(web_modal.tex)
		web_modal.tex = rl.CreateStreamTexture(i32(frame_w), i32(frame_h))
		web_modal.tex_w, web_modal.tex_h = frame_w, frame_h
	}
	rl.UpdateTexturePixels(&web_modal.tex, web_modal.pixels)

	// The first frame proves the child mapped the file, so the name
	// can go: the mapping outlives it, and a crash from here on leaves
	// nothing behind in /dev/shm.
	if len(web_modal.path) > 0 {
		posix.unlink(strings.clone_to_cstring(web_modal.path, context.temp_allocator))
		delete(web_modal.path)
		web_modal.path = ""
	}
}

@(private = "file")
web_push :: proc(event: Web_Event) {
	shm := web_modal.shm
	shm.events[shm.head % WEB_EV_CAP] = event
	shm.head += 1
}

// Pointer, wheel and keys, mapped from the page element's box. Runs in
// the handler pass, after layout, so GetElementData is current.
handle_web_input :: proc(ui: ^Ui_State) {
	if !web_modal.open {
		return
	}
	if rl.IsKeyPressed(.ESCAPE) || clicked("WebClose") {
		web_close()
		return
	}

	box := clay.GetElementData(clay.ID("WebPage")).boundingBox
	if box.width <= 0 {
		return
	}
	// The texture is 1:1 with the child's widget, so the pointer maps
	// straight into it in device pixels.
	mouse := rl.GetMousePosition()
	if test_pointer_on {
		mouse = transmute(rl.Vector2)test_pointer
	}
	x, y := f64(mouse.x - box.x * UI_ZOOM), f64(mouse.y - box.y * UI_ZOOM)
	over := x >= 0 && y >= 0 && x < f64(web_modal.tex_w) && y < f64(web_modal.tex_h)

	// A drag that started on the page keeps receiving motion after the
	// pointer leaves it, the way a real page behaves.
	if over || web_modal.down {
		web_push({kind = .Move, x = x, y = y})
	}
	if over && (rl.IsMouseButtonPressed(.LEFT) || forced_press) {
		web_push({kind = .Down, arg = GDK_BTN_LEFT, x = x, y = y})
		web_modal.down = true
	}
	if web_modal.down && (rl.IsMouseButtonReleased(.LEFT) || forced_release) {
		web_push({kind = .Up, arg = GDK_BTN_LEFT, x = x, y = y})
		web_modal.down = false
	}
	if over && rl.IsMouseButtonPressed(.RIGHT) {
		web_push({kind = .Down, arg = GDK_BTN_RIGHT, x = x, y = y})
		web_push({kind = .Up, arg = GDK_BTN_RIGHT, x = x, y = y})
	}

	if wheel := rl.GetMouseWheelMoveV(); over && (wheel.x != 0 || wheel.y != 0) {
		// GDK scrolls in the opposite sense to the wheel delta.
		web_push({kind = .Scroll, x = x, y = y, dx = f64(-wheel.x), dy = f64(-wheel.y)})
	}

	for entry in WEB_KEYS {
		if rl.IsKeyPressed(entry.key) {
			web_push({kind = .Key_Down, arg = entry.keyval})
			web_push({kind = .Key_Up, arg = entry.keyval})
		}
	}
	for r := rl.GetCharPressed(); r != 0; r = rl.GetCharPressed() {
		// Latin-1 and ASCII map straight onto GDK keyvals; anything
		// else takes the Unicode escape GDK defines for it.
		keyval := u32(r) <= 0xff ? u32(r) : u32(r) + 0x01000000
		web_push({kind = .Key_Down, arg = keyval})
		web_push({kind = .Key_Up, arg = keyval})
	}
}

// The page keeps its aspect and shrinks to fit the window; the child
// always renders WEB_W x WEB_H, so this is a scale, not a resize.
@(private = "file")
web_fit :: proc() -> (w, h: f32) {
	max_w := f32(rl.GetScreenWidth()) / UI_ZOOM - WEB_MARGIN
	max_h := f32(rl.GetScreenHeight()) / UI_ZOOM - WEB_MARGIN - WEB_BAR
	scale := min(f32(1), max_w / WEB_W, max_h / WEB_H)
	return WEB_W * scale, WEB_H * scale
}

// The modal: title bar, close, and the page.
web_modal_draw :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("WebModal"))(
	{
		layout = {layoutDirection = .TopToBottom, childGap = 8, padding = clay.PaddingAll(12)},
		floating = {
			attachTo = .Root,
			zIndex = 10,
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
	},
	) {
		if clay.UI(clay.ID("WebBar"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			clay.Text(web_modal.title, {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
			if clay.UI(clay.ID("WebPad"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("WebClose"))(
			{
				layout = {padding = {left = 10, right = 10, top = 4, bottom = 4}},
				backgroundColor = hovered() ? HOVER : ROW_BG,
				cornerRadius = rr(6),
			},
			) {
				clay.Text(tr("Close"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
			}
		}
		w, h := web_fit()
		if clay.UI(clay.ID("WebPage"))(
		{
			layout = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)}},
			image = {imageData = &web_modal.tex},
			cornerRadius = rr(8),
		},
		) {}
	}
}
