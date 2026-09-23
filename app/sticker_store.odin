package main

import marmot "../marmot"
import "core:c"
import "core:c/libc"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import rl "sdlrl"
import stbi "vendor:stb/image"

@(private)
Sticker_Library :: struct {
	items:  [dynamic]Sticker_Item,
	packs:  [dynamic]Sticker_Pack,
	recent: [dynamic]string,
}
@(private)
Sticker_Operation :: enum {
	Load,
	Save,
	Pack,
	Asset,
	Import,
	Send,
	Receive,
}
@(private)
Sticker_Job :: struct {
	op:                          Sticker_Operation,
	worker:                      ^thread.Thread,
	input:                       string,
	item:                        Sticker_Item,
	pack:                        Sticker_Pack,
	items:                       [dynamic]Sticker_Item,
	library:                     Sticker_Library,
	relays:                      []string,
	data:                        []u8,
	image:                       rl.Image,
	error:                       string,
	account, group, reply, root: string,
	dim:                         string,
	effect:                      int,
}
@(private)
sticker_jobs: [dynamic]^Sticker_Job
@(private)
sticker_textures: map[string]^rl.Texture2D
@(private)
sticker_requested: map[string]bool

@(private, default_calling_convention = "c")
foreign _ {
	WebPGetInfo :: proc(bytes: [^]u8, size: c.size_t, w, h: ^c.int) -> c.int ---
}
@(private, default_calling_convention = "c")
foreign _ {
	wn_https_get :: proc(url: cstring, out: [^]u8, cap: c.size_t) -> c.int ---
}

@(private)
sticker_blob_path :: proc(sha: string) -> string {
	assert(sticker_hex(sha))
	return fmt.tprintf("%s/stickers/%s.bin", data_home, sha)
}

@(private)
media_write_sealed :: proc(path: string, data: []u8) -> bool {
	sealed, ok := vault_seal_blob(data, context.temp_allocator)
	if !ok {return false}
	if err := os.make_directory(filepath.dir(path)); err != nil && err != .Exist {return false}
	next := fmt.tprintf("%s.next", path)
	if os.write_entire_file(next, sealed, {.Read_User, .Write_User}) != nil {return false}
	return os.rename(next, path) == nil
}

// Bound input before allocating or decoding. Animated formats remain unsupported.
@(private)
sticker_image :: proc(bytes: []u8, mime: string) -> rl.Image {
	if len(bytes) < 12 || len(bytes) > STICKER_BYTES_LIMIT {return {}}
	w, h, channels: c.int
	if mime == "image/webp" {
		if string(bytes[:4]) != "RIFF" || string(bytes[8:12]) != "WEBP" {return {}}
		if len(bytes) >= 21 && string(bytes[12:16]) == "VP8X" && bytes[20] & 2 != 0 {return {}}
		if WebPGetInfo(raw_data(bytes), uint(len(bytes)), &w, &h) == 0 {return {}}
	} else {
		if mime == "image/png" {
			if string(bytes[:8]) != "\x89PNG\r\n\x1a\n" {return {}}
			for at := 8; at + 12 <= len(bytes); {
				size: u32
				for b in bytes[at:at + 4] {size = size << 8 | u32(b)}
				if u64(size) + 12 > u64(len(bytes) - at) {return {}}
				if string(bytes[at + 4:at + 8]) == "acTL" {return {}}
				at += int(size) + 12
			}
		} else if mime != "image/jpeg" || bytes[0] != 0xff || bytes[1] != 0xd8 {return {}}
		if stbi.info_from_memory(raw_data(bytes), c.int(len(bytes)), &w, &h, &channels) ==
		   0 {return {}}
	}
	if w <= 0 || h <= 0 || w > STICKER_DIM_LIMIT || h > STICKER_DIM_LIMIT {return {}}
	return rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes)))
}

@(private)
sticker_thumb :: proc(image: rl.Image) -> rl.Image {
	if image.data == nil || image.width <= 0 || image.height <= 0 {return image}
	if max(image.width, image.height) <= 256 {return image}
	scale := 256 / f32(max(image.width, image.height))
	w, h := max(1, i32(f32(image.width) * scale)), max(1, i32(f32(image.height) * scale))
	pixels := ([^]u8)(libc.malloc(uint(w * h * 4)))
	if pixels == nil {rl.UnloadImage(image); return {}}
	if stbi.resize_uint8(([^]u8)(image.data), image.width, image.height, 0, pixels, w, h, 0, 4) ==
	   0 {
		libc.free(pixels); rl.UnloadImage(image); return {}
	}
	rl.UnloadImage(image)
	return {data = pixels, width = w, height = h}
}

@(private)
sticker_read_blob :: proc(sha: string) -> []u8 {
	if !sticker_hex(sha) {return nil}
	sealed, err := os.read_entire_file(sticker_blob_path(sha), context.temp_allocator)
	if err != nil {return nil}
	bytes, ok := vault_open_blob(sealed)
	if !ok {return nil}
	if string(
		   hex.encode(
			   hash.hash_bytes(.SHA256, bytes, context.temp_allocator),
			   context.temp_allocator,
		   ),
	   ) !=
	   sha {
		delete(bytes); return nil
	}
	return bytes
}

@(private)
sticker_job_add :: proc(op: Sticker_Operation) -> ^Sticker_Job {
	job := new(Sticker_Job)
	job.op = op
	append(&sticker_jobs, job)
	return job
}

@(private)
sticker_fetch_pack :: proc(job: ^Sticker_Job) {
	coordinate := job.input
	if !sticker_coordinate(coordinate) {return}
	identifier, _ := json.marshal(coordinate[71:], allocator = context.temp_allocator)
	req := fmt.ctprintf(
		`["REQ","wn",{{"authors":["%s"],"kinds":[30031],"#d":[%s],"limit":1}}]`,
		coordinate[6:70],
		string(identifier),
	)
	buffer := make([]u8, NEV_MAX, context.temp_allocator)
	latest: u64
	for relay in job.relays {
		if !strings.has_prefix(relay, "wss://") {continue}
		n := wn_ws_fetch(
			strings.clone_to_cstring(relay, context.temp_allocator),
			req,
			raw_data(buffer),
			uint(len(buffer)),
			3000,
		)
		if n <= 0 {continue}
		value, err := json.parse(buffer[:n], allocator = context.temp_allocator)
		if err != nil {continue}
		arr, ok := value.(json.Array)
		if !ok || len(arr) != 3 {continue}
		kind, _ := arr[0].(json.String); subscription, _ := arr[1].(json.String)
		if kind != "EVENT" || subscription != "wn" {continue}
		encoded, enc_err := json.marshal(arr[2], allocator = context.temp_allocator)
		if enc_err != nil {continue}
		event: Sticker_Event
		if json.unmarshal(encoded, &event, allocator = context.temp_allocator) != nil ||
		   !sticker_event_valid(event) {continue}
		if job.pack.coordinate != "" &&
		   (event.created_at < latest ||
				   event.created_at == latest && event.id >= job.pack.event) {continue}
		pack, items := sticker_parse_pack(event, coordinate, relay)
		if len(items) == 0 {continue}
		sticker_pack_free(job.pack)
		for item in job.items {sticker_item_free(item)}
		delete(job.items)
		job.pack, job.items, latest = pack, items, event.created_at
	}
	if job.pack.coordinate ==
	   "" {job.error = N_("Couldn't load the pack. Check your relay settings and try again.")}
}

@(private)
sticker_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Sticker_Job)(t.data)
	switch job.op {
	case .Pack:
		sticker_fetch_pack(job)
	case .Load:
		sealed, err := os.read_entire_file(
			fmt.tprintf("%s/stickers/library.bin", data_home),
			context.temp_allocator,
		)
		if err == .Not_Exist {return}
		if err != nil {job.error = N_("Couldn't load your stickers. Please try again."); return}
		plain, ok := vault_open_blob(sealed, context.temp_allocator)
		if !ok ||
		   json.unmarshal(plain, &job.library) !=
			   nil {job.error = N_("Couldn't load your stickers. Please try again.")}
	case .Save:
		if !media_write_sealed(
			fmt.tprintf("%s/stickers/library.bin", data_home),
			job.data,
		) {job.error = N_("Couldn't save your stickers. Please try again.")}
	case .Import:
		file, err := os.open(job.input)
		if err != nil {job.error = N_("Couldn't read the image. Please try again."); return}
		defer os.close(file)
		size, size_err := os.file_size(file)
		if size_err != nil ||
		   size <= 0 ||
		   size >
			   STICKER_BYTES_LIMIT {job.error = N_("Couldn't import the sticker. Choose an image under 4 MiB."); return}
		job.data = make([]u8, int(size))
		n, read_err := os.read(file, job.data)
		if read_err != nil ||
		   n !=
			   len(job.data) {job.error = N_("Couldn't read the image. Please try again."); return}
		name := job.input[strings.last_index_byte(job.input, '/') + 1:]
		job.item = {
			ref = {
				sha = string(
					hex.encode(hash.hash_bytes(.SHA256, job.data, context.temp_allocator)),
				),
				code = strings.clone(emoji_code(name)),
			},
			label = strings.clone(emoji_code(name)),
			mime = strings.clone(media_type_for(name)),
		}
		fallthrough
	case .Asset, .Send, .Receive:
		if job.op != .Import {job.data = sticker_read_blob(job.item.ref.sha)}
		if len(job.data) == 0 && job.op == .Receive {
			sealed, err := os.read_entire_file(
				fmt.tprintf("%s/%s.bin", media_cache_dir(), job.item.ref.sha),
				context.temp_allocator,
			)
			if err == nil {job.data, _ = vault_open_blob(sealed)}
		}
		if len(job.data) == 0 && job.op == .Asset && strings.has_prefix(job.item.url, "https://") {
			buffer := make([]u8, STICKER_BYTES_LIMIT, context.temp_allocator)
			n := wn_https_get(
				strings.clone_to_cstring(job.item.url, context.temp_allocator),
				raw_data(buffer),
				uint(len(buffer)),
			)
			if n > 0 {job.data = make([]u8, int(n)); copy(job.data, buffer[:n])}
		}
		if len(job.data) == 0 ||
		   string(
			   hex.encode(
				   hash.hash_bytes(.SHA256, job.data, context.temp_allocator),
				   context.temp_allocator,
			   ),
		   ) !=
			   job.item.ref.sha {
			job.error = N_("Couldn't load the sticker. Please try again."); return
		}
		job.image = sticker_image(job.data, job.item.mime)
		if job.image.data ==
		   nil {job.error = N_("Couldn't use the sticker. Choose a static PNG, WebP or JPEG up to 4096 pixels."); return}
		job.dim = fmt.aprintf("%dx%d", job.image.width, job.image.height)
		if job.op != .Send && !media_write_sealed(sticker_blob_path(job.item.ref.sha), job.data) {
			job.error = N_("Couldn't save your stickers. Please try again."); return
		}
		job.image = sticker_thumb(job.image)
	}
}

@(private)
sticker_item_clone :: proc(item: Sticker_Item) -> Sticker_Item {
	return {
		sticker_ref_clone(item.ref),
		strings.clone(item.label),
		strings.clone(item.mime),
		strings.clone(item.url),
	}
}

@(private)
sticker_texture :: proc(item: Sticker_Item) -> ^rl.Texture2D {
	if !sticker_hex(item.ref.sha) {return nil}
	if tex, ok := sticker_textures[item.ref.sha]; ok {return tex}
	if item.mime == "image/gif" ||
	   item.mime == "image/apng" {sticker_textures[strings.clone(item.ref.sha)] = nil; return nil}
	if !sticker_requested[item.ref.sha] {
		sticker_requested[strings.clone(item.ref.sha)] = true
		job := sticker_job_add(.Asset)
		job.item = sticker_item_clone(item)
	}
	return nil
}

@(private)
sticker_save_library :: proc(ui: ^Ui_State) {
	bytes, err := json.marshal(Sticker_Library{ui.stickers, ui.sticker_packs, ui.sticker_recent})
	if err != nil {ui.sticker_error = N_("Couldn't save your stickers. Please try again."); return}
	job := sticker_job_add(.Save)
	job.data = bytes
}

@(private)
sticker_library_open :: proc(ui: ^Ui_State) {
	if ui.sticker_loaded {return}
	for job in sticker_jobs {if job.op == .Load {return}}
	sticker_job_add(.Load)
}

@(private)
sticker_add_item :: proc(ui: ^Ui_State, item: Sticker_Item) {
	for old in ui.stickers {
		if old.ref.pack == item.ref.pack &&
		   old.ref.code == item.ref.code &&
		   old.ref.sha == item.ref.sha {return}
	}
	append(&ui.stickers, sticker_item_clone(item))
}

@(private)
sticker_job_free :: proc(job: ^Sticker_Job) {
	delete(job.input); delete(job.data)
	delete(job.account); delete(job.group); delete(job.reply); delete(job.root)
	delete(job.dim)
	sticker_item_free(job.item); sticker_pack_free(job.pack)
	for item in job.items {sticker_item_free(item)}
	delete(job.items)
	for item in job.library.items {sticker_item_free(item)}
	for pack in job.library.packs {sticker_pack_free(pack)}
	for sha in job.library.recent {delete(sha)}
	delete(job.library.items); delete(job.library.packs); delete(job.library.recent)
	for relay in job.relays {delete(relay)}
	delete(job.relays)
	if job.image.data != nil {rl.UnloadImage(job.image)}
	free(job)
}

@(private)
drain_stickers :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := 0; i < len(sticker_jobs); {
		job := sticker_jobs[i]
		if job.worker == nil || !thread.is_done(job.worker) {i += 1; continue}
		thread.join(job.worker); thread.destroy(job.worker)
		ordered_remove(&sticker_jobs, i)
		if job.op == .Send &&
		   job.account !=
			   ui.account_ref {job.error = N_("Couldn't send the sticker. Switch back to your account and try again.")}
		if job.error != "" {
			if job.op == .Send {sticker_show(ui, job.item.ref)}
			ui.sticker_error = job.error
		}
		if job.op == .Pack && job.input == ui.sticker_pack.coordinate {
			ui.sticker_loading = false
			if job.error == "" {
				sticker_pack_free(ui.sticker_pack)
				ui.sticker_pack, job.pack = job.pack, {}
				for item in ui.sticker_preview {sticker_item_free(item)}
				delete(ui.sticker_preview)
				ui.sticker_preview, job.items = job.items, nil
			}
		}
		if job.error == "" {
			switch job.op {
			case .Load:
				ui.stickers, ui.sticker_packs, ui.sticker_recent =
					job.library.items, job.library.packs, job.library.recent
				job.library = {}
				ui.sticker_loaded = true
			case .Import, .Receive:
				sticker_add_item(ui, job.item)
				sticker_save_library(ui)
				ui.sticker_tab = true
				if job.op == .Import {
					sticker_ref_free(ui.sticker_selected)
					ui.sticker_selected = sticker_ref_clone(job.item.ref)
					clear(&ui.sticker_name); append(&ui.sticker_name, job.item.label)
					ui.sticker_open = true
					ui.sticker_page = .Detail
				}
			case .Send:
				queue_sticker_payload(ui, client, job)
			case .Save, .Asset, .Pack:
			}
		}
		if job.op == .Asset || job.op == .Import || job.op == .Receive {
			if job.image.data != nil &&
			   job.error == "" &&
			   sticker_textures[job.item.ref.sha] == nil {
				tex := new(rl.Texture2D)
				tex^ = sticker_texture_load(job.image)
				rl.SetTextureFilter(tex^, .BILINEAR)
				sticker_textures[strings.clone(job.item.ref.sha)] = tex
			} else if job.op == .Asset && job.error != "" {
				sticker_textures[strings.clone(job.item.ref.sha)] = nil
			}
		}
		sticker_job_free(job)
	}
	if ui.sticker_installing {sticker_finish_install(ui)}
	// ponytail: one bounded IO job at a time; use two asset workers if packs need it.
	for job in sticker_jobs {if job.worker != nil {return}}
	if len(sticker_jobs) == 0 {return}
	job := sticker_jobs[0]
	for candidate in sticker_jobs {if candidate.op != .Asset {job = candidate; break}}
	job.worker = thread.create(sticker_worker)
	job.worker.data = job
	thread.start(job.worker)
}

@(private)
sticker_stop :: proc() {
	// Join owned workers before unloading; finish queued index writes in order.
	for job in sticker_jobs {
		if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
		if job.op == .Save && job.worker == nil {
			if !media_write_sealed(
				fmt.tprintf("%s/stickers/library.bin", data_home),
				job.data,
			) {fmt.eprintln("Couldn't save sticker library during shutdown.")}
		}
		sticker_job_free(job)
	}
	delete(sticker_jobs)
	for key, tex in sticker_textures {
		if tex != nil {sticker_texture_free(tex^); free(tex)}
		delete(key)
	}
	delete(sticker_textures)
	for _, mask in sticker_masks {rl.UnloadTexture(mask)}
	delete(sticker_masks); sticker_masks = {}
	for key in sticker_requested {delete(key)}
	delete(sticker_requested)
}
