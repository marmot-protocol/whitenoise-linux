// Optional square crop for native avatar picks. Keep the source draft intact
// until Use so Reset and Cancel never touch the committed avatar.
package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:slice"
import "core:strings"
import "core:thread"
import marmot "../marmot"
import stbi "vendor:stb/image"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Photo_Crop :: struct {
	active: bool,
	x, y, side: i32,
}

@(private)
photo_crop_start :: proc(p: ^Photo_Preview) {
	image := p.draft.image
	side := min(image.width, image.height)
	p.crop = {true, (image.width - side) / 2, (image.height - side) / 2, side}
	p.crop_drag = false
}

@(private)
photo_crop_clamp :: proc(p: ^Photo_Preview) {
	image := p.draft.image
	p.crop.side = clamp(p.crop.side, i32(1), min(image.width, image.height))
	p.crop.x = clamp(p.crop.x, i32(0), image.width - p.crop.side)
	p.crop.y = clamp(p.crop.y, i32(0), image.height - p.crop.side)
}

@(private)
photo_crop_resize :: proc(p: ^Photo_Preview, factor: f32) {
	before := p.crop.side
	p.crop.side = clamp(i32(f32(before) * factor), i32(1), min(p.draft.image.width, p.draft.image.height))
	p.crop.x += (before - p.crop.side) / 2
	p.crop.y += (before - p.crop.side) / 2
	photo_crop_clamp(p)
}

// Pointer coordinates are logical layout pixels; the crop stays in source
// pixels so window size and interface zoom cannot change the encoded region.
@(private)
photo_crop_input :: proc(p: ^Photo_Preview) {
	if !p.crop.active {return}
	box := clay.GetElementData(clay.ID("PhotoImage"))
	if !box.found || box.boundingBox.width <= 0 {return}
	scale := box.boundingBox.width / f32(p.draft.image.width)
	mouse := rl.GetMousePosition()
	mouse.x /= UI_ZOOM; mouse.y /= UI_ZOOM
	if rl.IsMouseButtonPressed(.LEFT) && clay.PointerOver(clay.ID("PhotoCropBox")) {
		p.crop_drag = true
		p.crop_pointer = mouse
		p.crop_origin = {p.crop.x, p.crop.y}
	}
	if p.crop_drag && rl.IsMouseButtonDown(.LEFT) {
		p.crop.x = p.crop_origin.x + i32((mouse.x - p.crop_pointer.x) / scale)
		p.crop.y = p.crop_origin.y + i32((mouse.y - p.crop_pointer.y) / scale)
		photo_crop_clamp(p)
	}
	if !rl.IsMouseButtonDown(.LEFT) {p.crop_drag = false}
	if clay.PointerOver(clay.ID("PhotoImage")) {
		wheel := rl.GetMouseWheelMoveV().y
		if wheel != 0 {photo_crop_resize(p, wheel > 0 ? f32(0.9) : f32(1.1))}
	}
}

@(private = "file")
Photo_Png_Sink :: struct {
	ctx: runtime.Context,
	bytes: ^[dynamic]u8,
}

@(private = "file")
photo_png_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	sink := (^Photo_Png_Sink)(ctx)
	context = sink.ctx
	append(sink.bytes, ..slice.bytes_from_ptr(data, int(size)))
}

// A crop is re-encoded as PNG, retaining alpha. The original bytes cannot
// accompany cropped pixels: workers must upload exactly what was selected.
@(private)
photo_crop_draft :: proc(source: rl.Image, crop: Photo_Crop) -> (draft: Pic_Draft, ok: bool) {
	if source.data == nil || crop.side < 1 || crop.x < 0 || crop.y < 0 ||
	   crop.x + crop.side > source.width || crop.y + crop.side > source.height {return}
	edge := int(crop.side)
	pixels := ([^]u8)(libc.malloc(uint(edge * edge * 4)))
	if pixels == nil {return}
	input := slice.bytes_from_ptr(source.data, int(source.width) * int(source.height) * 4)
	output := pixels[:edge * edge * 4]
	for row in 0..<edge {
		start := ((int(crop.y) + row) * int(source.width) + int(crop.x)) * 4
		copy(output[row * edge * 4:(row + 1) * edge * 4], input[start:start + edge * 4])
	}
	encoded: [dynamic]u8
	sink := Photo_Png_Sink{context, &encoded}
	written := stbi.write_png_to_func(photo_png_sink, &sink, crop.side, crop.side, 4, pixels, crop.side * 4)
	if written == 0 || len(encoded) == 0 {
		delete(encoded); libc.free(pixels)
		return
	}
	return {data = encoded[:], media_type = "image/png", image = {data = pixels, width = crop.side, height = crop.side}}, true
}

@(private)
Photo_Crop_Job :: struct {
	worker: ^thread.Thread,
	source, result: Pic_Draft,
	crop: Photo_Crop,
	ok: bool,
}

@(private = "file")
photo_crop_jobs: [dynamic]^Photo_Crop_Job

@(private)
photo_image :: proc(p: ^Photo_Preview) -> rl.Image {
	if p.crop_job != nil {return p.crop_job.source.image}
	return p.draft.image
}

@(private = "file")
photo_crop_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	job := (^Photo_Crop_Job)(t.data)
	job.result, job.ok = photo_crop_draft(job.source.image, job.crop)
}

@(private)
photo_crop_begin :: proc(p: ^Photo_Preview) {
	job := new(Photo_Crop_Job)
	job.source, job.crop = p.draft, p.crop
	p.draft = {} // worker job owns source until collection, including on Cancel
	p.crop_job = job
	p.crop_drag = false
	job.worker = thread.create(photo_crop_worker)
	job.worker.data = job
	append(&photo_crop_jobs, job)
	thread.start(job.worker)
}

// Cancel detaches the job; collection frees it without any upload. Completed
// active jobs revalidate the original account/group and busy state before Use.
@(private)
photo_crop_drain :: proc(ui: ^Ui_State, client: ^marmot.Client, allow_use := true) {
	for i := 0; i < len(photo_crop_jobs); {
		job := photo_crop_jobs[i]
		// Active confirmation drains after Cancel input, not before routing.
		if !allow_use && ui.photo.crop_job == job {i += 1; continue}
		if !thread.is_done(job.worker) {i += 1; continue}
		thread.join(job.worker); thread.destroy(job.worker)
		ordered_remove(&photo_crop_jobs, i)
		if ui.photo.crop_job == job {
			ui.photo.crop_job = nil
			if job.ok {
				ui.photo.draft = job.result; job.result = {}
				ui.photo.crop = {}
				if photo_can_use(ui) {
					photo_use(ui, client)
				} else {
					photo_cancel(ui)
					set_status(ui, strings.clone(tr("Couldn't use the picture. Wait a moment and try again.")), .Error)
				}
			} else {
				ui.photo.draft = job.source; job.source = {}
				set_status(ui, strings.clone(tr("Couldn't crop the picture. Please try again.")), .Error)
			}
		}
		pic_draft_free(&job.source); pic_draft_free(&job.result); free(job)
	}
}

@(private)
photo_crop_stop :: proc() {
	for job in photo_crop_jobs {
		thread.join(job.worker); thread.destroy(job.worker)
		pic_draft_free(&job.source); pic_draft_free(&job.result); free(job)
	}
	delete(photo_crop_jobs); photo_crop_jobs = {}
}
