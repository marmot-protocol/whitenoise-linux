package sdlrl

import "core:mem"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"
import whip "whip:gui"
import whip_model "whip:model"
import proto "whip:proto"

when #config(WN_WHIP, false) {
	@(private)
	whip_ui: ^whip.SDL_UI
	@(private)
	whip_worker: ^thread.Thread
	@(private)
	whip_allocator: mem.Allocator
	@(private)
	whip_started: i32
	@(private)
	whip_failed: bool
	@(private)
	whip_visible: bool

	WhipAvailable :: proc() -> bool {
		path := #config(WN_WHIP_EXE, "")
		return os.is_file(path) && posix.access(cstring(#config(WN_WHIP_EXE, "")), {.X_OK}) == .OK
	}

	// Launch the installed executable, never connect_or_spawn: that API
	// forks /proc/self/exe, which here would start another White Noise.
	@(private)
	whip_start :: proc(t: ^thread.Thread) {
		context.allocator = whip_allocator
		defer free_all(context.temp_allocator)
		fd, ok := proto.connect("default")
		if !ok {
			// The short-lived shell reparents the server so detaching or
			// reloading WN leaves the user's terminal sessions alive.
			child, err := os.process_start(
				{
					command = {
						"/bin/sh",
						"-c",
						`"$1" server default </dev/null &`,
						"sh",
						#config(WN_WHIP_EXE, ""),
					},
					stdout = os.stderr,
					stderr = os.stderr,
				},
			)
			if err != nil {sync.atomic_store(&whip_started, -1); return}
			_, _ = os.process_wait(child)
			fd, ok = proto.connect_retry("default", 2 * time.Second)
		}
		if ok {posix.close(fd)}
		sync.atomic_store(&whip_started, ok ? 1 : -1)
	}

	WhipState :: proc() -> Whip_State {
		if whip_failed || sync.atomic_load(&whip_started) < 0 {return .Failed}
		if whip_ui != nil {return .Ready}
		if whip_worker != nil {return .Starting}
		return .Idle
	}

	// Called after host handlers, so a newly opened modal owns the next input.
	WhipFrame :: proc(visibility: Whip_Visibility) {
		was_visible := whip_visible
		whip_visible = visibility == .Visible
		if whip_visible && WhipState() == .Idle && WhipAvailable() {
			whip_allocator = context.allocator
			whip_worker = thread.create(whip_start)
			if whip_worker == nil {whip_failed = true; return}
			thread.start(whip_worker)
		}
		if whip_ui != nil {
			if whip_visible && !was_visible {whip.set_focus(whip_ui.view, .Focused)}
			if !whip_visible {whip.set_focus(whip_ui.view, .Blurred)}
			whip.update(whip_ui.view)
			if !whip_ui.view.running {whip_failed = true}
		}
	}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {
		if whip_ui != nil && whip_visible && !whip_failed {
			return whip.event(whip_ui.view, event)
		}
		return false
	}

	// Clay supplies logical bounds; Whip uses physical framebuffer pixels.
	DrawWhip :: proc(x, y, w, h: f32) {
		if whip_failed || sync.atomic_load(&whip_started) != 1 {return}
		sx, sy: f32
		sdl.GetRenderScale(state.renderer, &sx, &sy)
		bounds := whip_model.Rect{int(x * sx), int(y * sy), int(w * sx), int(h * sy)}
		if bounds.w <= 0 || bounds.h <= 0 {return}
		if whip_ui == nil {
			whip_ui = whip.create_sdl(state.window, state.renderer, "default", bounds)
			if whip_ui == nil {whip_failed = true; return}
			whip.set_focus(whip_ui.view, .Focused)
		}
		whip.set_bounds(whip_ui.view, bounds)
		if !whip.render_sdl(whip_ui) {whip_failed = true}
	}

	WhipClose :: proc() {
		if whip_worker != nil {
			thread.join(whip_worker)
			thread.destroy(whip_worker)
		}
		if whip_ui != nil {whip.destroy_sdl(whip_ui)}
		whip_ui, whip_worker = nil, nil
		whip_started, whip_failed, whip_visible = 0, false, false
	}
}
