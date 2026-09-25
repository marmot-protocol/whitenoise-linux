// Clay renderer over the SDL3 shim (app/sdlrl). Replaced the raylib
// renderer so text input gets IME events and glyphs bake on demand
// (Japanese renders through the Noto CJK fallback stack).
package main

import "core:time"

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

_ :: fmt
_ :: os
_ :: strings

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Glyph atlases rasterize at size*UI_SCALE physical pixels, so glyphs
// are never drawn from an upscaled bitmap.
UI_SCALE: f32 = 1

// Global UI magnification: layout runs at 1/UI_ZOOM of the window and
// the SDL render scale blows the frame back up, so every size scales
// at once. UI_SCALE folds it in so glyph atlases stay crisp.
UI_ZOOM: f32 = 1.5

@(private)
Image_Crop :: struct {
	kind: Model_Kind,
	tex:  ^rl.Texture2D,
}

// Latin faces are bundled. CJK uses each platform's installed fallback
// fonts; Linux installations need the Noto CJK system package.
CJK_CANDIDATES := []cstring {
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
}
CJK_BOLD_CANDIDATES := []cstring {
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Bold.ttc",
}

// dpi * zoom, the density glyphs rasterize at. Re-run whenever UI_ZOOM
// changes: the glyph cache keys on pixel size, so new sizes bake fresh
// and stale bakes just go unused.
refresh_ui_scale :: proc() {
	UI_SCALE = max(rl.GetWindowScaleDPI().x, 1) * UI_ZOOM
	rl.SetPixelScale(UI_SCALE)
}

init_fonts :: proc() {
	timing_start := time.tick_now()
	defer local_timing_end(.fonts_init, timing_start)
	rl.SetPixelScale(UI_SCALE)
	// A packaged build ships its own copy of each face; res_font puts it
	// at the head of the stack so the binary never depends on which
	// fonts the host distro happens to have installed.
	stack :: proc(id: u16, bundled: string, candidates: []cstring, fallbacks: []cstring) {
		paths := make([dynamic]cstring, context.temp_allocator)
		if font := res_font(bundled); font != nil {
			append(&paths, font)
		}
		append(&paths, ..candidates)
		append(&paths, ..fallbacks)
		if id != FONT_ICON {
			when ODIN_OS == .Windows {
				windir := os.get_env("WINDIR", context.temp_allocator)
				for face in ([]string{"msyh.ttc", "meiryo.ttc", "YuGothR.ttc", "malgun.ttf"}) {
					append(
						&paths,
						strings.clone_to_cstring(
							fmt.tprintf("%s/Fonts/%s", windir, face),
							context.temp_allocator,
						),
					)
				}
			} else when ODIN_OS == .Darwin {
				append(
					&paths,
					"/System/Library/Fonts/PingFang.ttc",
					"/System/Library/Fonts/Hiragino Sans GB.ttc",
					"/System/Library/Fonts/AppleSDGothicNeo.ttc",
				)
			}
		}
		if id != FONT_ICON {
			append(
				&paths,
				res_font("NotoSansMath-Regular.ttf"),
				res_font("NotoSansSymbols-Regular.ttf"),
				res_font("NotoSansSymbols2-Regular.ttf"),
			)
		}
		rl.LoadFontStack(id, paths[:], text_emoji)
	}
	stack(FONT_BODY, "LiberationSans-Regular.ttf", FONT_CANDIDATES, CJK_CANDIDATES)
	stack(FONT_TITLE, "LiberationSans-Bold.ttf", TITLE_CANDIDATES, CJK_BOLD_CANDIDATES)
	stack(
		FONT_ITALIC,
		"LiberationSans-Italic.ttf",
		{
			"/usr/share/fonts/liberation/LiberationSans-Italic.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf",
			"/usr/share/fonts/liberation-sans/LiberationSans-Italic.ttf",
		},
		CJK_CANDIDATES,
	)
	stack(
		FONT_BOLD_ITALIC,
		"LiberationSans-BoldItalic.ttf",
		{
			"/usr/share/fonts/liberation/LiberationSans-BoldItalic.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf",
			"/usr/share/fonts/liberation-sans/LiberationSans-BoldItalic.ttf",
		},
		CJK_BOLD_CANDIDATES,
	)
	stack(FONT_MONO, "LiberationMono-Regular.ttf", MONO_CANDIDATES, CJK_CANDIDATES)
	stack(FONT_ICON, "JetBrainsMonoNerdFont-Regular.ttf", ICON_CANDIDATES, nil)
	rl.IconFont = FONT_ICON // ink-boxed, so icons center in their buttons
}

// Hand-drawn themes re-jitter every outline eight times a second, the
// "boiling line" of cel animation: nothing sits still, so the chrome
// reads as drawn rather than printed. Each edge gets its own offset
// from a hash of (element, edge, time slot), so there is no state.
BOIL_HZ :: 8
BOIL_AMP :: f32(0.9)

boil :: proc(id: u32, edge: u32) -> f32 {
	if !PAPER_DECOR {
		return 0
	}
	frame_deadline = min(frame_deadline, (f64(u64(rl.GetTime() * BOIL_HZ)) + 1) / BOIL_HZ)
	h := (id ~ (edge * 0x9e3779b9) ~ (u32(rl.GetTime() * BOIL_HZ) * 0x85ebca6b)) * 0xc2b2ae35
	h ~= h >> 15
	return (f32(h % 1000) / 500 - 1) * BOIL_AMP
}

clay_color :: proc(color: clay.Color) -> rl.Color {
	return {u8(color.r), u8(color.g), u8(color.b), u8(color.a)}
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	context = runtime.default_context()
	context.allocator = reload_allocator()
	size := rl.MeasureTextLine(
		config.fontId,
		config.fontSize,
		string(text.chars[:text.length]),
		f32(config.letterSpacing),
	)
	return {width = size.x, height = size.y}
}

// ── The frame, in two layers ────────────────────────────────────────
//
// clay emits one flat command list, and the modal veil (shell.odin) is
// the only thing in it that separates the page from what is over the
// page: it mounts at zIndex 9, under every centered modal and over
// everything else. Splitting the list there and rendering each half
// into its own target buys the two effects clay cannot express, a blur
// of the page behind a modal and one opacity over the whole modal
// layer, for one texture round trip while a modal is open and nothing
// at all when none is.

SCENE_SLOT :: 0
LAYER_SLOT :: 1
FRAME_SLOT :: 2
HOLD_SLOT :: 3
TRAIL_SLOT :: 4
PUSH_SLOT :: 5 // incoming view while FRAME retains the displayed composite
MODAL_LIFT :: f32(0.04) // how far the modal layer scales in from
PAGE_PUSH :: f32(0.03) // how far the outgoing page pulls away from the eye

// The whole frame, composited. Everything is drawn into a target rather
// than straight at the window for one reason: the target still holds
// the frame that was on screen a moment ago, so a page switch can copy
// it aside while the next page takes its place. clay is
// immediate mode and keeps nothing, and a GPU→CPU readback (CaptureFrame)
// is far too slow per frame; a texture that simply isn't cleared yet
// costs nothing.
draw_frame :: proc(render_commands: ^clay.ClayArray(clay.RenderCommand)) {
	if page_held {
		page_held = false
		if !rl.CopyTarget(HOLD_SLOT, FRAME_SLOT) {
			page_t = 1
		}
	}
	pushing := page_push && page_t < 1
	slot := pushing ? PUSH_SLOT : FRAME_SLOT
	if !rl.BeginTarget(slot) {
		clay_raylib_render(render_commands)
		reveal_step()
		return
	}
	clay_raylib_render(render_commands)
	reveal_step() // holds the old theme's frame while the new one opens
	rl.EndTarget()
	// Retain the actual moving pair, not just its destination. A second
	// navigation click can push the partially finished transition away.
	if pushing && rl.BeginTarget(FRAME_SLOT) {
		rl.DrawTarget(PUSH_SLOT, 1)
		draw_page_transition()
		rl.EndTarget()
		slot = FRAME_SLOT
	}
	rl.DrawTarget(slot, 1)
	scroll_smear()
	if !page_push {
		draw_page_transition()
	}
}

// Motion blur on a thrown timeline. TRAIL keeps a decayed history of
// the frame, and the faster the content is moving the more of that
// history goes back over the sharp frame, so a fling smears and a slow
// scroll does not. Only the timeline's own rectangle: the rail and the
// header are not moving and must not blur with it.
SMEAR_FROM :: f32(4) // px/frame of scroll where a trail starts to show
SMEAR_TO :: f32(26) // and where it is as strong as it gets
SMEAR_MAX :: f32(0.5)
TRAIL_MIX :: f32(0.45) // weight of the newest frame in the history

@(private = "file")
smearing: bool

@(private = "file")
scroll_smear :: proc() {
	// A modal owns the screen while it is up, and the page behind it is
	// already blurred by the veil; a second blur over the top is mud.
	// Only app-driven travel smears (scroll_glide); the user's own wheel
	// and drag stay sharp.
	strength := clamp((abs(scroll_vel) - SMEAR_FROM) / (SMEAR_TO - SMEAR_FROM), 0, 1) * SMEAR_MAX
	if !scroll_glide || strength <= 0 || open_t(clay.ID("ModalVeil")) > 0 {
		smearing = false
		return
	}
	box, ok := element_box(clay.ID("Timeline"))
	if !ok {
		smearing = false
		return
	}
	// The first smeared frame has no history yet, so it seeds one
	// instead of ghosting whatever was in the texture.
	if !smearing {
		smearing = rl.CopyTarget(TRAIL_SLOT, FRAME_SLOT)
		return
	}
	rl.FadeTargetInto(TRAIL_SLOT, FRAME_SLOT, TRAIL_MIX)
	rl.DrawTargetRegion(
		TRAIL_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		box.width * UI_ZOOM,
		box.height * UI_ZOOM,
		strength,
	)
}

// Adjacent, opaque panes share one moving edge. Tab changes push the sidebar
// and content in opposite directions; the navigation column stays anchored.
// Chat changes move only the content. Other views retain their depth fade.
@(private = "file")
draw_page_transition :: proc() {
	if page_t >= 1 {
		return
	}
	if page_push {
		if box, ok := element_box(clay.ID("MainCard")); ok {
			push_region(box, -1)
		}
		if page_tab_push {
			if box, ok := element_box(clay.ID("RailContent")); ok {
				push_region(box, 1)
			}
		}
		return
	}
	box, ok := element_box(clay.ID("MainCard"))
	if !ok {
		return
	}
	rl.DrawTargetRegion(
		HOLD_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		box.width * UI_ZOOM,
		box.height * UI_ZOOM,
		1 - page_t,
		1 + PAGE_PUSH * page_t,
	)
}

@(private = "file")
push_region :: proc(box: clay.BoundingBox, direction: f32) {
	width := box.width * UI_ZOOM
	travel := width * page_t
	rl.DrawTargetRegion(
		HOLD_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		width,
		box.height * UI_ZOOM,
		1,
		offset_x = direction * travel,
	)
	rl.DrawTargetRegion(
		PUSH_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		width,
		box.height * UI_ZOOM,
		1,
		offset_x = direction * (travel - width),
	)
}

// Index of the veil's own rectangle, or -1 when no modal is mounted.
@(private = "file")
veil_split :: proc(commands: ^clay.ClayArray(clay.RenderCommand)) -> i32 {
	veil := clay.ID("ModalVeil").id
	for i in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(commands, i)
		if command.id == veil && command.commandType == .Rectangle {
			return i
		}
	}
	return -1
}

clay_raylib_render :: proc(
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	split := veil_split(render_commands)
	if split < 0 {
		render_range(render_commands, 0, render_commands.length, allocator)
		return
	}
	veil := open_t(clay.ID("ModalVeil"))
	if !rl.BeginTarget(SCENE_SLOT) {
		render_range(render_commands, 0, render_commands.length, allocator)
		return
	}
	render_range(render_commands, 0, split, allocator)
	rl.EndTarget()
	rl.DrawTarget(SCENE_SLOT, 1)
	rl.DrawTargetBlurred(SCENE_SLOT, veil)

	if !rl.BeginTarget(LAYER_SLOT) {
		render_range(render_commands, split, render_commands.length, allocator)
		return
	}
	render_range(render_commands, split, render_commands.length, allocator)
	rl.EndTarget()
	rl.DrawTarget(LAYER_SLOT, veil, 1 - MODAL_LIFT * (1 - veil))
}

@(private = "file")
render_range :: proc(
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	from, to: i32,
	allocator := context.temp_allocator,
) {
	overlay_colors := make([dynamic]clay.Color, allocator)
	for i in from ..< to {
		render_command := clay.RenderCommandArray_Get(render_commands, i)
		bounds := render_command.boundingBox

		switch render_command.commandType {
		case .None:
		case .Text:
			config := render_command.renderData.text
			text := string(config.stringContents.chars[:config.stringContents.length])
			style := u8(uintptr(render_command.userData))
			if style & (TEXT_CODE | TEXT_MATH | TEXT_ADDED | TEXT_REMOVED) != 0 {
				plate := CODE_PLATE
				if style & TEXT_ADDED != 0 {plate = fade(ACCENT, 0.22)}
				if style & TEXT_REMOVED != 0 {plate = fade(DANGER, 0.22)}
				rl.DrawRectangleRoundedPx(
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					2,
					clay_color(plate),
				)
			}
			rl.DrawTextLine(
				config.fontId,
				config.fontSize,
				text,
				bounds.x,
				bounds.y,
				f32(config.letterSpacing),
				clay_color(config.textColor),
			)
			if style & (TEXT_STRIKE | TEXT_REMOVED) != 0 {
				rl.DrawRectangleRec(
					bounds.x,
					bounds.y + bounds.height / 2,
					bounds.width,
					1,
					clay_color(config.textColor),
				)
			}
		case .Image:
			config := render_command.renderData.image
			tint := clay.Color{255, 255, 255, 255}
			if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
				tint = overlay_colors[len(overlay_colors) - 1]
			}
			texture := (^rl.Texture2D)(config.imageData)
			if uintptr(render_command.userData) == STICKER_IMAGE {
				sticker_draw(texture, bounds, render_command.id, clay_color(tint))
				continue
			}
			rl.DrawTextureRect(
				texture,
				bounds.x,
				bounds.y,
				bounds.width,
				bounds.height,
				clay_color(tint),
			)
		case .ScissorStart:
			rl.BeginScissorMode(
				i32(math.round(bounds.x)),
				i32(math.round(bounds.y)),
				i32(math.round(bounds.width)),
				i32(math.round(bounds.height)),
			)
		case .ScissorEnd:
			rl.EndScissorMode()
		case .Rectangle:
			// Every fill eases toward its new color instead of swapping.
			// Doing it here rather than at the call sites is what makes
			// hover, selection and theme changes animate app-wide for
			// free: clay hands the renderer a stable element id, which
			// is exactly the key the motion store wants.
			config := render_command.renderData.rectangle
			fill := clay_color(anim_color(render_command.id, config.backgroundColor, HOVER_RATE))
			if config.cornerRadius.topLeft > 0 {
				rl.DrawRectangleRoundedPx(
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					config.cornerRadius.topLeft,
					fill,
				)
			} else {
				rl.DrawRectangleRec(bounds.x, bounds.y, bounds.width, bounds.height, fill)
			}
		case .Border:
			config := render_command.renderData.border
			color := clay_color(
				anim_color(anim_key(render_command.id, 1), config.color, HOVER_RATE),
			)
			min_radius := min(bounds.width, bounds.height) / 2
			tl := min(config.cornerRadius.topLeft, min_radius)
			tr := min(config.cornerRadius.topRight, min_radius)
			bl := min(config.cornerRadius.bottomLeft, min_radius)
			br := min(config.cornerRadius.bottomRight, min_radius)

			id := render_command.id
			if config.width.left > 0 {
				rl.DrawRectangleRec(
					bounds.x + boil(id, 0),
					bounds.y + tl,
					f32(config.width.left),
					bounds.height - tl - bl,
					color,
				)
			}
			if config.width.right > 0 {
				rl.DrawRectangleRec(
					bounds.x + bounds.width - f32(config.width.right) + boil(id, 1),
					bounds.y + tr,
					f32(config.width.right),
					bounds.height - tr - br,
					color,
				)
			}
			if config.width.top > 0 {
				rl.DrawRectangleRec(
					bounds.x + tl,
					bounds.y + boil(id, 2),
					bounds.width - tl - tr,
					f32(config.width.top),
					color,
				)
			}
			if config.width.bottom > 0 {
				rl.DrawRectangleRec(
					bounds.x + bl,
					bounds.y + bounds.height - f32(config.width.bottom) + boil(id, 3),
					bounds.width - bl - br,
					f32(config.width.bottom),
					color,
				)
			}

			// Arc centers sit exactly radius-in from the box corner so
			// the annular band lines up with the straight edge rects.
			if tl > 0 {
				rl.DrawArc(
					bounds.x + tl,
					bounds.y + tl,
					tl,
					180,
					270,
					f32(config.width.top),
					color,
				)
			}
			if tr > 0 {
				rl.DrawArc(
					bounds.x + bounds.width - tr,
					bounds.y + tr,
					tr,
					270,
					360,
					f32(config.width.top),
					color,
				)
			}
			if bl > 0 {
				rl.DrawArc(
					bounds.x + bl,
					bounds.y + bounds.height - bl,
					bl,
					90,
					180,
					f32(config.width.bottom),
					color,
				)
			}
			if br > 0 {
				rl.DrawArc(
					bounds.x + bounds.width - br,
					bounds.y + bounds.height - br,
					br,
					0,
					90,
					f32(config.width.bottom),
					color,
				)
			}
		case .OverlayColorStart:
			config := render_command.renderData.overlayColor
			append(&overlay_colors, config.color)
		case .OverlayColorEnd:
			pop(&overlay_colors)
		case .Custom:
			// 3D tiles; the payload's first field says which kind.
			data := render_command.renderData.custom.customData
			switch (^Model_Kind)(data)^ {
			case .Mesh:
				stl_draw((^Stl_View)(data), bounds)
			case .Gcode:
				gcode_draw((^Gcode_View)(data), bounds)
			case .Synth:
				synth_draw(bounds)
			case .Dust:
				dust_draw(bounds)
			case .Scan:
				scan_draw(bounds)
			case .Wash:
				wash_draw(bounds)
			case .Deco:
				deco_draw(bounds)
			case .Blinds:
				blinds_draw(bounds)
			case .Stripes:
				stripes_draw(bounds)
			case .Waves:
				waves_draw(bounds)
			case .Airmail:
				airmail_draw(bounds)
			case .Check:
				check_draw((^Check_View)(data), bounds)
			case .Glow:
				glow_draw((^Glow_View)(data), bounds)
			case .Shade:
				shade_draw((^Shade_View)(data), bounds)
			case .Hidden_Border:
				hidden_border_draw(bounds)
			case .Profile_Background:
				tint := clay.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 &&
				   overlay_colors[len(overlay_colors) - 1] !=
					   0 {tint = overlay_colors[len(overlay_colors) - 1]}
				profile_background_draw((^Profile_Background)(data), bounds, clay_color(tint))
			case .Avatar_Hinge:
				view := (^Avatar_Hinge)(data)
				angle := view.angle * math.PI / 180
				sin, cos := math.sin(angle), math.cos(angle)
				tint := clay.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
					tint = overlay_colors[len(overlay_colors) - 1]
				}
				// The top-center hinge stays fixed. Rotate the opaque cover
				// and its photo together, clipped to the original avatar slot.
				uvs := [6]rl.Vector2{{0, 0}, {1, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 1}}
				vertices: [6]rl.Vertex
				for uv, k in uvs {
					dx := (uv.x - 0.5) * bounds.width
					dy := uv.y * bounds.height
					vertices[k] = {
						position  = {
							bounds.x + bounds.width / 2 + dx * cos - dy * sin,
							bounds.y + dx * sin + dy * cos,
						},
						color     = {
							view.back.r / 255,
							view.back.g / 255,
							view.back.b / 255,
							tint.a / 255,
						},
						tex_coord = {uv.x, uv.y},
					}
				}
				rl.DrawTrianglesClipped(
					vertices[:],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
				)
				for &vertex in vertices {
					vertex.color = {tint.r / 255, tint.g / 255, tint.b / 255, tint.a / 255}
				}
				rl.DrawTrianglesClipped(
					vertices[:],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					view.tex,
				)
			case .Image_Crop:
				tex := (^Image_Crop)(data).tex
				if tex.width <= 0 || tex.height <= 0 {continue}
				scale := max(bounds.width / f32(tex.width), bounds.height / f32(tex.height))
				tint := clay.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 &&
				   overlay_colors[len(overlay_colors) - 1] !=
					   0 {tint = overlay_colors[len(overlay_colors) - 1]}
				// Crop from the top left to preserve the beginning of screenshots.
				// Renderer clipping leaves wheel scrolling with the timeline.
				rl.BeginScissorMode(
					i32(bounds.x),
					i32(bounds.y),
					i32(bounds.width),
					i32(bounds.height),
				)
				rl.DrawTextureRect(
					tex,
					bounds.x,
					bounds.y,
					f32(tex.width) * scale,
					f32(tex.height) * scale,
					clay_color(tint),
				)
				rl.EndScissorMode()
			}
		}
	}
}
