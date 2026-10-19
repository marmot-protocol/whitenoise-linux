package sdlrl

import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

// Applied to the composed view, not individual colors or image assets.
Saturation: f32 = 1
Noir: bool
NoirFrame: u32

@(private)
Saturation_State :: struct {
	device:        ^sdl.GPUDevice,
	shader:        ^sdl.GPUShader,
	gpu:           ^sdl.GPURenderState,
	frame:         Target,
	upload:        ^sdl.Texture,
	pixels:        []u8,
	width, height: i32,
	capturing:     bool,
	applied:       bool,
	software:      bool,
}
@(private)
saturation: Saturation_State

@(private)
create_view_renderer :: proc(window: ^sdl.Window) -> ^sdl.Renderer {
	// Explicit renderer selection remains available for headless runs and diagnosis.
	hint := sdl.GetHint("SDL_RENDER_DRIVER")
	if hint != nil && string(hint) != "gpu" {
		return sdl.CreateRenderer(window, nil)
	}
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	sdl.SetStringProperty(props, "SDL.renderer.create.name", "gpu")
	sdl.SetPointerProperty(props, "SDL.renderer.create.window", window)
	sdl.SetBooleanProperty(props, "SDL.renderer.create.gpu.shaders_spirv", true)
	sdl.SetBooleanProperty(props, "SDL.renderer.create.gpu.shaders_msl", true)
	sdl.SetBooleanProperty(props, "SDL.renderer.create.gpu.shaders_dxil", true)
	if renderer := sdl.CreateRendererWithProperties(props); renderer != nil {
		return renderer
	}
	return sdl.CreateRenderer(window, nil)
}

@(private)
init_saturation :: proc() {
	name := sdl.GetRendererName(state.renderer)
	saturation.software = name != nil && string(name) == "software"
	fmt.eprintfln("sdlrl: renderer=%s", name)
	saturation.device = sdl.GetGPURendererDevice(state.renderer)
	if saturation.device == nil {return}
	formats := sdl.GetGPUShaderFormats(saturation.device)
	code: []u8
	entry: cstring = "main"
	format: sdl.GPUShaderFormat
	if .SPIRV in formats {
		code = #load("shaders/saturation.spv")
		format = {.SPIRV}
	} else if .MSL in formats {
		MSL :: #load("shaders/saturation.metal", string) + "\x00"
		code = (transmute([]u8)MSL)[:len(MSL) - 1]
		format = {.MSL}
		entry = "main0"
	} else if .DXIL in formats {
		code = #load("shaders/saturation.dxil")
		format = {.DXIL}
	}
	if len(code) > 0 {
		info := sdl.GPUShaderCreateInfo {
			code_size           = uint(len(code)),
			code                = raw_data(code),
			entrypoint          = entry,
			format              = format,
			stage               = .FRAGMENT,
			num_samplers        = 1,
			num_uniform_buffers = 1,
		}
		saturation.shader = sdl.CreateGPUShader(saturation.device, info)
		if saturation.shader != nil {
			gpu_info := sdl.GPURenderStateCreateInfo {
				fragment_shader = saturation.shader,
			}
			saturation.gpu = sdl.CreateGPURenderState(state.renderer, gpu_info)
		}
	}
	if saturation.gpu == nil {
		fmt.eprintfln("sdlrl: saturation shader unavailable; using readback: %s", sdl.GetError())
	} else {
		fmt.eprintfln("sdlrl: saturation=gpu")
	}
}

@(private)
begin_saturation :: proc() {
	saturation.applied = false
	saturation.capturing = false
	if (Saturation >= 1 && !Noir) || saturation.gpu == nil {return}
	w, h: c.int
	if !sdl.GetRenderOutputSize(state.renderer, &w, &h) {return}
	if !ensure_target(&saturation.frame, i32(w), i32(h)) {return}
	sdl.SetTextureBlendMode(saturation.frame.tex, {})
	if sdl.SetRenderTarget(state.renderer, saturation.frame.tex) {
		saturation.capturing = true
	}
}

// Screenshots and presentation share the same finalization guard. A screenshot
// therefore sees the same filtered pixels as the window, never a second pass.
ApplySaturation :: proc() {
	if saturation.applied {return}
	if Saturation >= 1 && !Noir && !saturation.capturing {
		saturation.applied = true
		return
	}
	saved := begin_raw()
	saved.target = nil
	defer restore_view(saved)
	amount := clamp(Saturation, 0, 1)
	defer {
		if !saturation.applied {
			fmt.eprintfln("sdlrl: saturation composition failed: %s", sdl.GetError())
		}
	}
	if saturation.capturing {
		if !sdl.SetRenderTarget(state.renderer, nil) {return}
		uniform := [4]f32 {
			amount,
			Noir ? f32((NoirFrame & 0xffff) + 1) : 0,
			f32(saturation.frame.w),
			f32(saturation.frame.h),
		}
		bound :=
			sdl.SetGPURenderStateFragmentUniforms(saturation.gpu, 0, &uniform, size_of(uniform)) &&
			sdl.SetGPURenderState(state.renderer, saturation.gpu)
		if bound {
			drawn := sdl.RenderTexture(state.renderer, saturation.frame.tex, nil, nil)
			if !sdl.SetGPURenderState(state.renderer, nil) {return}
			if drawn {
				saturation.applied = true
				return
			}
		}
		// A failed shader state still presents the actual view and applies the
		// software path below, rather than silently leaving it at full saturation.
		if !sdl.SetGPURenderState(state.renderer, nil) {return}
		if !sdl.RenderTexture(state.renderer, saturation.frame.tex, nil, nil) {return}
	}
	if amount < 1 || Noir {
		if saturation.software {
			sdl.FlushRenderer(state.renderer)
			if surface := sdl.GetWindowSurface(state.window); surface != nil {
				if filter_surface(surface, amount) {
					saturation.applied = true
					return
				}
			}
		}
		// SDL has no read-into-buffer renderer API. Only this compatibility path
		// allocates SDL's required readback surface; our pixel/upload storage is reused.
		surface := sdl.RenderReadPixels(state.renderer, nil)
		if surface == nil {return}
		defer sdl.DestroySurface(surface)
		if !ensure_saturation_upload(i32(surface.w), i32(surface.h)) {return}
		pixels, pitch := surface.pixels, surface.pitch
		if surface.format == .RGBA32 {
			if !filter_surface(surface, amount) {return}
		} else {
			ensure_saturation_pixels(i32(surface.w), i32(surface.h))
			pixels, pitch = raw_data(saturation.pixels), surface.w * 4
			if !sdl.ConvertPixels(
				surface.w,
				surface.h,
				surface.format,
				surface.pixels,
				surface.pitch,
				.RGBA32,
				pixels,
				pitch,
			) {return}
			filter_rgba(saturation.pixels, amount, {int(surface.w), int(surface.h)})
		}
		if !sdl.UpdateTexture(saturation.upload, nil, pixels, pitch) {return}
		if !sdl.RenderTexture(state.renderer, saturation.upload, nil, nil) {return}
	}
	saturation.applied = true
}

@(private)
ensure_saturation_pixels :: proc(w, h: i32) {
	count := int(w) * int(h) * 4
	if len(saturation.pixels) != count {
		delete(saturation.pixels)
		saturation.pixels = make([]u8, count)
	}
}

@(private)
ensure_saturation_upload :: proc(w, h: i32) -> bool {
	if saturation.upload != nil && saturation.width == w && saturation.height == h {return true}
	if saturation.upload != nil {
		when #config(WN_RELOAD, false) {delete_key(&live_textures, saturation.upload)}
		sdl.DestroyTexture(saturation.upload)
		saturation.upload = nil
	}
	saturation.upload = sdl.CreateTexture(state.renderer, .RGBA32, .STREAMING, w, h)
	track_texture(saturation.upload)
	if saturation.upload == nil {return false}
	sdl.SetTextureBlendMode(saturation.upload, {})
	saturation.width, saturation.height = w, h
	return true
}

@(private)
filter_surface :: proc(surface: ^sdl.Surface, amount: f32) -> bool {
	if !sdl.LockSurface(surface) {return false}
	defer sdl.UnlockSurface(surface)
	if surface.format == .RGBA32 {
		pixels := ([^]u8)(surface.pixels)
		for y in 0 ..< int(surface.h) {
			filter_rgba(
				pixels[y * int(surface.pitch):y * int(surface.pitch) + int(surface.w) * 4],
				amount,
				{int(surface.w), int(surface.h)},
				y,
			)
		}
		return true
	}
	ensure_saturation_pixels(i32(surface.w), i32(surface.h))
	if !sdl.ConvertPixels(
		surface.w,
		surface.h,
		surface.format,
		surface.pixels,
		surface.pitch,
		.RGBA32,
		raw_data(saturation.pixels),
		surface.w * 4,
	) {return false}
	filter_rgba(saturation.pixels, amount, {int(surface.w), int(surface.h)})
	return sdl.ConvertPixels(
		surface.w,
		surface.h,
		.RGBA32,
		raw_data(saturation.pixels),
		surface.w * 4,
		surface.format,
		surface.pixels,
		surface.pitch,
	)
}

@(private)
filter_rgba :: proc(pixels: []u8, amount: f32, size: [2]int, row_offset: int = 0) {
	for i := 0; i < len(pixels); i += 4 {
		r, g, b := f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])
		gray := r * 0.2126 + g * 0.7152 + b * 0.0722
		grain: f32
		if Noir {
			x, y := (i / 4) % size[0], (i / 4) / size[0] + row_offset
			h := u32(x / 2) ~ (u32(y / 2) * 0x9e3779b9) ~ ((NoirFrame & 0xffff) * 0xc2b2ae35)
			h = (h ~ (h >> 16)) * 0x85ebca6b
			h ~= h >> 13
			fine := (h >> (u32(x % 2 + y % 2 * 2) * 8)) & 255
			grain = ((f32(h & 255) / 255 - 0.5) * 0.12 + (f32(fine) / 255 - 0.5) * 0.035) * 255
		}
		pixels[i] = u8(clamp(gray + (r - gray) * amount + grain + 0.5, 0, 255))
		pixels[i + 1] = u8(clamp(gray + (g - gray) * amount + grain + 0.5, 0, 255))
		pixels[i + 2] = u8(clamp(gray + (b - gray) * amount + grain + 0.5, 0, 255))
	}
}

@(private)
close_saturation :: proc() {
	// Flush queued draws before destroying shader/state; the renderer may outlive
	// this library during reload, while every texture is owned by its registry.
	sdl.FlushRenderer(state.renderer)
	if saturation.gpu != nil {
		_ = sdl.SetGPURenderState(state.renderer, nil)
		sdl.DestroyGPURenderState(saturation.gpu)
	}
	if saturation.shader != nil {sdl.ReleaseGPUShader(saturation.device, saturation.shader)}
	delete(saturation.pixels)
	saturation = {}
}
