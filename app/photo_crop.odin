// Square crop and image jobs for native photo picks.
package main

import marmot "../marmot"
import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/endian"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "nendo"
import rl "sdlrl"
import stbi "vendor:stb/image"

@(private)
Photo_Crop :: struct {
	active:     bool,
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
	p.crop.side = clamp(
		i32(f32(before) * factor),
		i32(1),
		min(p.draft.image.width, p.draft.image.height),
	)
	p.crop.x += (before - p.crop.side) / 2
	p.crop.y += (before - p.crop.side) / 2
	photo_crop_clamp(p)
}

// Keep the opposite corner anchored. Project the pointer onto the square's
// diagonal, then limit the side before computing x/y so edges never drift.
@(private)
photo_crop_drag_to :: proc(p: ^Photo_Preview, dx, dy: f32) {
	origin := p.crop_origin
	if p.crop_corner == 0 {
		p.crop.x = origin.x + i32(dx)
		p.crop.y = origin.y + i32(dy)
		photo_crop_clamp(p)
		return
	}
	left := p.crop_corner == 1 || p.crop_corner == 3
	top := p.crop_corner == 1 || p.crop_corner == 2
	anchor_x := origin.x + (left ? origin.side : 0)
	anchor_y := origin.y + (top ? origin.side : 0)
	limit_x := left ? anchor_x : p.draft.image.width - anchor_x
	limit_y := top ? anchor_y : p.draft.image.height - anchor_y
	delta := ((left ? -dx : dx) + (top ? -dy : dy)) / 2
	p.crop.side = clamp(origin.side + i32(delta), i32(1), min(limit_x, limit_y))
	p.crop.x = left ? anchor_x - p.crop.side : anchor_x
	p.crop.y = top ? anchor_y - p.crop.side : anchor_y
}

// Pointer coordinates are logical layout pixels; the crop stays in source
// pixels so window size and interface zoom cannot change the encoded region.
@(private)
photo_crop_input :: proc(p: ^Photo_Preview) {
	if !p.crop.active {return}
	box := nendo.element(nendo.id("PhotoImage"))
	if !box.found || box.rect.width <= 0 {return}
	scale := box.rect.width / f32(p.draft.image.width)
	mouse := rl.GetMousePosition()
	mouse.x /= UI_ZOOM; mouse.y /= UI_ZOOM
	if rl.IsMouseButtonPressed(.LEFT) {
		corner := 0
		nearest := f32(1e30)
		pointer := nendo.pointer().position
		// Handles win over moving the interior. At very small crop sizes,
		// choose the nearest corner rather than letting overlapping hits
		// make the bottom/right handles unreachable.
		for i in 1 ..= 4 {
			id := nendo.id("PhotoCropHandle", u32(i))
			if !nendo.pointer_over(id) {continue}
			handle := nendo.element(id).rect
			dx := pointer.x - (handle.x + handle.width / 2)
			dy := pointer.y - (handle.y + handle.height / 2)
			distance := dx * dx + dy * dy
			if distance < nearest {corner, nearest = i, distance}
		}
		if corner != 0 || nendo.pointer_over(nendo.id("PhotoCropBox")) {
			p.crop_drag = true
			p.crop_corner = corner
			p.crop_pointer = mouse
			p.crop_origin = p.crop
		}
	}
	if p.crop_drag && rl.IsMouseButtonDown(.LEFT) {
		photo_crop_drag_to(
			p,
			(mouse.x - p.crop_pointer.x) / scale,
			(mouse.y - p.crop_pointer.y) / scale,
		)
	}
	if !rl.IsMouseButtonDown(.LEFT) {p.crop_drag = false}
	if !p.crop_drag && nendo.pointer_over(nendo.id("PhotoImage")) {
		wheel := rl.GetMouseWheelMoveV().y
		if wheel != 0 {photo_crop_resize(p, wheel > 0 ? f32(0.9) : f32(1.1))}
	}
}

@(private = "file")
Photo_Png_Sink :: struct {
	ctx:   runtime.Context,
	bytes: ^[dynamic]u8,
}

@(private = "file")
photo_png_sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	sink := (^Photo_Png_Sink)(ctx)
	context = sink.ctx
	append(sink.bytes, ..slice.bytes_from_ptr(data, int(size)))
}

@(private = "file")
CONTACT_PHOTO_INPUT_BYTES :: 32 * 1024 * 1024
@(private = "file")
CONTACT_PHOTO_SOURCE_EDGE :: 8192
@(private = "file")
CONTACT_PHOTO_SOURCE_BYTES :: 64 * 1024 * 1024

// The sandboxed decoder validates dimensions before decoding, but returns
// unrotated RGBA. Read only the EXIF orientation tag from the original bytes.
@(private)
photo_orientation :: proc(data: []u8) -> u16 {
	if len(data) >= 2 && data[0] == 0xff && data[1] == 0xd8 {
		remaining := data[2:]
		for len(remaining) > 0 && remaining[0] == 0xff {
			remaining = remaining[1:]
			if len(remaining) == 0 {break}
			marker := remaining[0]
			if marker == 0xff {continue} 	// fill byte
			remaining = remaining[1:]
			if marker == 0xda || marker == 0xd9 {break}
			if marker == 0x01 || (0xd0 <= marker && marker <= 0xd7) {continue}
			size, ok := endian.get_u16(remaining, .Big)
			if !ok || size < 2 || int(size) > len(remaining) {break}
			payload := remaining[2:int(size)]
			if marker == 0xe1 && len(payload) >= 6 && string(payload[:6]) == "Exif\x00\x00" {
				return photo_tiff_orientation(payload[6:])
			}
			remaining = remaining[int(size):]
		}
	} else if len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n" {
		for remaining := data[8:]; len(remaining) >= 12; {
			size := endian.unchecked_get_u32be(remaining)
			if u64(size) > u64(len(remaining) - 12) {break}
			switch string(remaining[4:8]) {
			case "eXIf":
				return photo_tiff_orientation(remaining[8:8 + int(size)])
			case "IEND":
				return 1
			}
			remaining = remaining[12 + int(size):]
		}
	} else if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		size := endian.unchecked_get_u32le(data[4:])
		if size < 4 || u64(size) > u64(len(data) - 8) {return 1}
		for remaining := data[12:8 + int(size)]; len(remaining) >= 8; {
			length := endian.unchecked_get_u32le(remaining[4:])
			padded := u64(length) + u64(length & 1)
			if padded > u64(len(remaining) - 8) {break}
			if string(remaining[:4]) == "EXIF" {
				payload := remaining[8:8 + int(length)]
				if len(payload) >= 6 &&
				   string(payload[:6]) == "Exif\x00\x00" {payload = payload[6:]}
				return photo_tiff_orientation(payload)
			}
			remaining = remaining[8 + int(padded):]
		}
	}
	return 1
}

@(private = "file")
photo_tiff_orientation :: proc(data: []u8) -> u16 {
	if len(data) < 8 {return 1}
	order: endian.Byte_Order
	switch string(data[:2]) {
	case "II":
		order = .Little
	case "MM":
		order = .Big
	case:
		return 1
	}
	magic, _ := endian.get_u16(data[2:], order)
	if magic != 42 {return 1}
	offset, _ := endian.get_u32(data[4:], order)
	if offset < 8 || u64(offset) > u64(len(data) - 2) {return 1}
	fields := data[int(offset):]
	count, _ := endian.get_u16(fields, order)
	fields = fields[2:]
	if int(count) > len(fields) / 12 {return 1}
	for i in 0 ..< int(count) {
		field := fields[i * 12:]
		tag, _ := endian.get_u16(field, order)
		if tag != 0x0112 {continue}
		kind, _ := endian.get_u16(field[2:], order)
		values, _ := endian.get_u32(field[4:], order)
		value, _ := endian.get_u16(field[8:], order)
		if kind == 3 && values == 1 && 1 <= value && value <= 8 {return value}
		return 1
	}
	return 1
}

@(private)
photo_apply_orientation :: proc(image: ^rl.Image, orientation: u16) -> bool {
	if orientation < 2 || orientation > 8 {return true}
	w, h := int(image.width), int(image.height)
	pixels := ([^][4]u8)(image.data)[:w * h]
	switch orientation {
	case 2:
		for y in 0 ..< h {slice.reverse(pixels[y * w:(y + 1) * w])}
	case 3:
		slice.reverse(pixels)
	case 4:
		for y in 0 ..< h / 2 {
			a, b := y * w, (h - 1 - y) * w
			for x in 0 ..< w {pixels[a + x], pixels[b + x] = pixels[b + x], pixels[a + x]}
		}
	case 5, 6, 7, 8:
		rotated := ([^][4]u8)(libc.malloc(uint(w * h * 4)))
		if rotated == nil {return false}
		// In a transposed image, adjacent output pixels come from adjacent source rows.
		flip_x := orientation == 6 || orientation == 7
		flip_y := orientation == 7 || orientation == 8
		for y in 0 ..< w {
			sx := flip_y ? w - 1 - y : y
			for x in 0 ..< h {
				sy := flip_x ? h - 1 - x : x
				rotated[y * h + x] = pixels[sy * w + sx]
			}
		}
		rl.UnloadImage(image^)
		image.data, image.width, image.height = ([^]u8)(rotated), image.height, image.width
	}
	return true
}

@(private = "file")
photo_contact_read :: proc(path: string) -> []u8 {
	file, err := os.open(path, {.Read, .Non_Blocking})
	if err != nil {return nil}
	defer os.close(file)
	info, stat_err := os.fstat(file, context.temp_allocator)
	if stat_err != nil ||
	   info.type != .Regular ||
	   info.size <= 0 ||
	   info.size > CONTACT_PHOTO_INPUT_BYTES {
		return nil
	}
	bytes := make([]u8, int(info.size))
	n, read_err := os.read_full(file, bytes)
	if n != len(bytes) || read_err != nil {delete(bytes); return nil}
	extra: [1]u8
	n, read_err = os.read(file, extra[:])
	if n != 0 || (read_err != .EOF && read_err != nil) {delete(bytes); return nil}
	return bytes
}

@(private)
photo_contact_decode :: proc(bytes: []u8) -> Pic_Draft {
	if len(bytes) == 0 {return {}}
	image := rl.LoadImageFromMemory(
		"",
		raw_data(bytes),
		i32(len(bytes)),
		CONTACT_PHOTO_SOURCE_EDGE,
		CONTACT_PHOTO_SOURCE_BYTES,
	)
	if image.data == nil {return {}}
	if !photo_apply_orientation(
		&image,
		photo_orientation(bytes),
	) {rl.UnloadImage(image); return {}}
	return {image = image}
}

// Encode only the crop's pixels. The Contact path also caps the square's size.
@(private)
photo_crop_draft :: proc(
	source: rl.Image,
	crop: Photo_Crop,
	kind: Photo_Job_Kind = .Crop,
) -> (
	draft: Pic_Draft,
	ok: bool,
) {
	if source.data == nil ||
	   crop.side < 1 ||
	   crop.x < 0 ||
	   crop.y < 0 ||
	   crop.x > source.width - crop.side ||
	   crop.y > source.height - crop.side {return}
	contact := kind == .Contact_Crop
	side := contact ? min(crop.side, i32(CONTACT_PHOTO_EDGE)) : crop.side
	edge := int(side)
	pixels := ([^]u8)(libc.malloc(uint(edge * edge * 4)))
	if pixels == nil {return}
	input := slice.bytes_from_ptr(source.data, int(source.width) * int(source.height) * 4)
	start := (int(crop.y) * int(source.width) + int(crop.x)) * 4
	if side == crop.side {
		output := pixels[:edge * edge * 4]
		for row in 0 ..< edge {
			off := start + row * int(source.width) * 4
			copy(output[row * edge * 4:(row + 1) * edge * 4], input[off:off + edge * 4])
		}
	} else if stbi.resize_uint8_srgb(
		   raw_data(input[start:]),
		   crop.side,
		   crop.side,
		   source.width * 4,
		   pixels,
		   side,
		   side,
		   0,
		   4,
		   3,
		   0,
	   ) ==
	   0 {
		libc.free(pixels)
		return
	}
	encoded: [dynamic]u8
	sink := Photo_Png_Sink{context, &encoded}
	written := stbi.write_png_to_func(photo_png_sink, &sink, side, side, 4, pixels, side * 4)
	if written == 0 || len(encoded) == 0 || (contact && len(encoded) > CONTACT_PNG_MAX) {
		delete(encoded); libc.free(pixels)
		return
	}
	return {
			data = encoded[:],
			media_type = "image/png",
			image = {data = pixels, width = side, height = side},
		},
		true
}

@(private)
Photo_Job_Kind :: enum {
	Crop,
	Contact_Crop,
	Contact_Decode,
}

@(private)
Photo_Crop_Job :: struct {
	worker:         ^thread.Thread,
	allocator:      mem.Allocator,
	source, result: Pic_Draft,
	crop:           Photo_Crop,
	kind:           Photo_Job_Kind,
	path:           string,
	done:           bool,
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
	job := (^Photo_Crop_Job)(t.data)
	context.allocator = job.allocator
	defer {
		free_all(context.temp_allocator)
		sync.atomic_store(&job.done, true)
		frame_wake()
	}
	if job.kind == .Contact_Decode {
		bytes := photo_contact_read(job.path)
		session_string_forget(&job.path)
		defer {mem.zero_slice(bytes); delete(bytes)}
		job.result = photo_contact_decode(bytes)
	} else {
		job.result, _ = photo_crop_draft(job.source.image, job.crop, job.kind)
	}
}

@(private = "file")
photo_job_start :: proc(p: ^Photo_Preview, job: ^Photo_Crop_Job) {
	job.allocator = reload_allocator()
	p.crop_job = job
	p.crop_drag = false
	job.worker = thread.create(photo_crop_worker)
	job.worker.data = job
	append(&photo_crop_jobs, job)
	thread.start(job.worker)
	if job.kind != .Crop {frame_wake()}
}

@(private)
photo_contact_decode_begin :: proc(p: ^Photo_Preview, path: string) {
	job := new(Photo_Crop_Job)
	job.kind, job.path = .Contact_Decode, strings.clone(path)
	photo_job_start(p, job)
}

@(private)
photo_crop_begin :: proc(p: ^Photo_Preview) {
	job := new(Photo_Crop_Job)
	job.source, job.crop = p.draft, p.crop
	if p.kind == .Contact {job.kind = .Contact_Crop}
	p.draft = {} // the job owns its source even if the preview is canceled
	photo_job_start(p, job)
}

// Cancel detaches the job. Collect detached results without touching the editor.
@(private)
photo_crop_drain :: proc(ui: ^Ui_State, client: ^marmot.Client, allow_use := true) {
	for i := 0; i < len(photo_crop_jobs); {
		job := photo_crop_jobs[i]
		// Cancel gets the frame before a completed job can change the modal.
		if !allow_use && ui.photo.crop_job == job {i += 1; continue}
		if !sync.atomic_load(&job.done) {i += 1; continue}
		thread.join(job.worker); thread.destroy(job.worker)
		ordered_remove(&photo_crop_jobs, i)
		if ui.photo.crop_job == job {
			ui.photo.crop_job = nil
			photo_job_finish(ui, client, job)
		}
		pic_draft_free(&job.source); pic_draft_free(&job.result); free(job)
	}
}

@(private = "file")
photo_job_finish :: proc(ui: ^Ui_State, client: ^marmot.Client, job: ^Photo_Crop_Job) {
	if job.kind != .Crop && !photo_target_valid(ui) {photo_cancel(ui); return}
	if job.result.image.data == nil {
		if job.kind == .Contact_Decode {
			photo_cancel(ui)
			set_status(
				ui,
				strings.clone(
					tr("Couldn't open that photo. Try a smaller image or a different file."),
				),
				.Error,
			)
		} else {
			ui.photo.draft = job.source; job.source = {}
			set_status(
				ui,
				strings.clone(tr("Couldn't crop the picture. Please try again.")),
				.Error,
			)
		}
		return
	}
	draft := job.result
	job.result = {}
	switch job.kind {
	case .Contact_Decode:
		photo_show_draft(ui, draft)
	case .Contact_Crop:
		photo_cancel(ui)
		contact_edit_photo(ui, draft)
	case .Crop:
		ui.photo.draft = draft
		ui.photo.crop = {}
		if photo_can_use(ui) {
			photo_use(ui, client)
		} else {
			photo_cancel(ui)
			set_status(
				ui,
				strings.clone(tr("Couldn't use the picture. Wait a moment and try again.")),
				.Error,
			)
		}
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
