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

// library.bin holds personal stickers and recents. `packs` is what remains
// of the pack list kept here before MDK owned the installed list.
@(private)
Sticker_Library :: struct {
	items:  [dynamic]Sticker_Item,
	packs:  [dynamic]Sticker_Pack,
	recent: [dynamic]string,
}
// MDK calls and disk work block, so each runs as one queued job on a worker:
//
//   UI ── sticker_job_add ──► sticker_jobs ── one worker ──► marmot_* / disk
//    ▲                                                            │
//    └──────────── drain_stickers (account still active?) ◄───────┘
@(private)
Sticker_Operation :: enum {
	Load, // library.bin, moving its old packs into MDK, then the installed list
	Sync, // kind-10031 and recent packs from relays, then the installed list
	Save, // library.bin
	Pack, // one pack for preview: MDK's local projection first, then relays
	Install,
	Uninstall,
	Asset, // artwork: encrypted local copy, then MDK's validated download
	Import, // a personal sticker from an image file
	Send, // a personal sticker's image, for an attachment send
	Receive, // a received personal sticker, saved from the media cache
}
@(private)
Sticker_Job :: struct {
	op:                      Sticker_Operation,
	worker:                  ^thread.Thread,
	client:                  ^marmot.Client, // set when the worker starts
	account:                 string,
	input:                   string, // pack coordinate, naddr or link; or a file path
	item:                    Sticker_Item, // .Asset, .Import, .Send, .Receive
	pack:                    Sticker_Pack, // .Pack
	items:                   [dynamic]Sticker_Item, // .Pack preview, else installed stickers
	packs:                   [dynamic]Sticker_Pack, // installed packs, when `listed`
	listed, read, moved:     bool,
	library:                 Sticker_Library, // .Load
	data:                    []u8,
	image:                   rl.Image,
	error:                   string,
	group, reply, root, dim: string, // .Send
	effect:                  int,
}
@(private)
sticker_jobs: [dynamic]^Sticker_Job
@(private)
sticker_textures: map[string]^rl.Texture2D
@(private)
sticker_requested: map[string]bool

@(private)
HTTPS_TIMEOUT_MS :: c.long(10_000)

@(private, default_calling_convention = "c")
foreign _ {
	wn_https_get :: proc(url: cstring, out: [^]u8, cap: c.size_t, timeout_ms: c.long) -> c.int ---
}

@(private)
sticker_blob_path :: proc(sha: string) -> string {
	assert(sticker_hex(sha))
	return fmt.tprintf("%s/stickers/%s.bin", data_home, sha)
}

@(private)
sticker_library_path :: proc() -> string {
	return fmt.tprintf("%s/stickers/library.bin", data_home)
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

// Bound input before allocating or decoding. The format comes from the
// bytes, since a message reference carries no MIME type. Animated PNG and
// WebP, and GIF, remain unsupported.
@(private)
sticker_image :: proc(bytes: []u8) -> rl.Image {
	if len(bytes) < 12 || len(bytes) > STICKER_BYTES_LIMIT {return {}}
	switch {
	case string(bytes[:4]) == "RIFF" && string(bytes[8:12]) == "WEBP":
		if len(bytes) >= 21 && string(bytes[12:16]) == "VP8X" && bytes[20] & 2 != 0 {return {}}
	case string(bytes[:8]) == "\x89PNG\r\n\x1a\n":
		for at := 8; at + 12 <= len(bytes); {
			size: u32
			for b in bytes[at:at + 4] {size = size << 8 | u32(b)}
			if u64(size) + 12 > u64(len(bytes) - at) {return {}}
			if string(bytes[at + 4:at + 8]) == "acTL" {return {}}
			at += int(size) + 12
		}
	case bytes[0] == 0xff && bytes[1] == 0xd8:
	case:
		return {}
	}
	return rl.LoadImageFromMemory(
		"",
		raw_data(bytes),
		i32(len(bytes)),
		max_dimension = STICKER_DIM_LIMIT,
	)
}

// Sticker cells draw at most 256 px.
@(private)
STICKER_PX :: 256

// Shrink an image so its longest side fits `side`, keeping the aspect ratio.
// Takes ownership: returns the input when it already fits, {} on failure.
@(private)
image_fit :: proc(image: rl.Image, side: i32) -> rl.Image {
	if image.data == nil || image.width <= 0 || image.height <= 0 {return image}
	if max(image.width, image.height) <= side {return image}
	scale := f32(side) / f32(max(image.width, image.height))
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
sticker_job_add :: proc(op: Sticker_Operation, account := "") -> ^Sticker_Job {
	job := new(Sticker_Job)
	job.op = op
	job.account = strings.clone(account)
	append(&sticker_jobs, job)
	return job
}

// Replace the job's installed rows with MDK's projection, in install order.
@(private)
sticker_list_installed :: proc(job: ^Sticker_Job, account: cstring) {
	list: ^marmot.Sticker_Pack_List
	if marmot.sticker_packs(job.client, account, 1, nil, 1, STICKER_PACK_LIMIT, &list) != .OK {
		if job.error == "" {job.error = N_("Couldn't load your stickers. Please try again.")}
		return
	}
	defer marmot.sticker_pack_list_free(list)
	for &pack in list.items[:list.len] {append(&job.packs, sticker_pack_copy(&pack, &job.items))}
	job.listed = true
}

// Read library.bin. Its pack stickers belong to MDK now, so only personal
// ones stay. Old packs move into MDK's installed list, in their order, on
// the first account to open stickers; one MDK cannot reach stays for the
// next open, and installing a pack twice is harmless. False means the file
// is unreadable and must not be overwritten.
@(private)
sticker_library_load :: proc(job: ^Sticker_Job, account: cstring) -> bool {
	sealed, err := os.read_entire_file(sticker_library_path(), context.temp_allocator)
	if err == .Not_Exist {job.read = true; return true}
	if err != nil {job.error = N_("Couldn't load your stickers. Please try again."); return false}
	plain, ok := vault_open_blob(sealed, context.temp_allocator)
	if !ok || json.unmarshal(plain, &job.library) != nil {
		job.error = N_("Couldn't load your stickers. Please try again."); return false
	}
	for i := len(job.library.items) - 1; i >= 0; i -= 1 {
		if job.library.items[i].ref.pack == "" {continue}
		sticker_item_free(job.library.items[i]); ordered_remove(&job.library.items, i)
		job.moved = true
	}
	unmoved: [dynamic]Sticker_Pack
	for pack in job.library.packs {
		out: ^marmot.Sticker_Pack
		status := marmot.install_sticker_pack(
			job.client,
			account,
			strings.clone_to_cstring(pack.coordinate, context.temp_allocator),
			&out,
		)
		if out != nil {marmot.sticker_pack_free(out)}
		if status == .STICKER_NETWORK {append(&unmoved, pack); continue}
		sticker_pack_free(pack)
		job.moved = true
	}
	delete(job.library.packs)
	job.library.packs = unmoved
	job.read = true
	return true
}

@(private)
sticker_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Sticker_Job)(t.data)
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	input := strings.clone_to_cstring(job.input, context.temp_allocator)
	switch job.op {
	case .Load:
		if sticker_library_load(job, account) {sticker_list_installed(job, account)}
	case .Sync:
		result: ^marmot.Sticker_Sync_Result
		if marmot.sync_sticker_packs(job.client, account, &result) == .OK {
			marmot.sticker_sync_result_free(result)
		} else {job.error = N_(
				"Couldn't sync your sticker packs. Check your relay settings and try again.",
			)}
		sticker_list_installed(job, account)
	case .Save:
		if !media_write_sealed(
			sticker_library_path(),
			job.data,
		) {job.error = N_("Couldn't save your stickers. Please try again.")}
	case .Pack:
		pack: ^marmot.Sticker_Pack
		status := marmot.sticker_pack(job.client, account, input, &pack)
		if status == .OK && pack == nil {
			status = marmot.fetch_sticker_pack(job.client, account, input, &pack)
		}
		if status != .OK || pack == nil {
			job.error =
				status == .INVALID_STICKER ? N_("Enter a valid pack link or address.") : N_("Couldn't load the pack. Check your relay settings and try again.")
			return
		}
		job.pack = sticker_pack_copy(pack, &job.items)
		marmot.sticker_pack_free(pack)
	case .Install:
		pack: ^marmot.Sticker_Pack
		if marmot.install_sticker_pack(job.client, account, input, &pack) != .OK {
			job.error = N_("Couldn't add the pack. Please try again."); return
		}
		marmot.sticker_pack_free(pack)
		sticker_list_installed(job, account)
	case .Uninstall:
		if marmot.uninstall_sticker_pack(job.client, account, input) != .OK {
			job.error = N_("Couldn't remove the pack. Please try again."); return
		}
		sticker_list_installed(job, account)
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
		// Pack art is MDK's to download and check against its exact reference.
		if len(job.data) == 0 && job.op == .Asset && job.item.ref.pack != "" {
			asset: ^marmot.Sticker_Asset
			if marmot.fetch_sticker_asset(
				   job.client,
				   account,
				   strings.clone_to_cstring(job.item.ref.pack, context.temp_allocator),
				   strings.clone_to_cstring(job.item.ref.code, context.temp_allocator),
				   strings.clone_to_cstring(job.item.ref.sha, context.temp_allocator),
				   &asset,
			   ) ==
			   .OK {
				job.data = make([]u8, asset.bytes_len)
				copy(job.data, asset.bytes[:asset.bytes_len])
				marmot.sticker_asset_free(asset)
			}
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
		job.image = sticker_image(job.data)
		if job.image.data ==
		   nil {job.error = N_("Couldn't use the sticker. Choose a static PNG, WebP or JPEG up to 4096 pixels."); return}
		job.dim = fmt.aprintf("%dx%d", job.image.width, job.image.height)
		if job.op != .Send && !media_write_sealed(sticker_blob_path(job.item.ref.sha), job.data) {
			job.error = N_("Couldn't save your stickers. Please try again."); return
		}
		job.image = image_fit(job.image, STICKER_PX)
	}
}

// The texture for exact artwork, or nil while it loads (or after it failed).
@(private)
sticker_texture :: proc(ref: Sticker_Ref) -> ^rl.Texture2D {
	if !sticker_hex(ref.sha) {return nil}
	if tex, ok := sticker_textures[ref.sha]; ok {return tex}
	if !sticker_requested[ref.sha] {
		sticker_requested[strings.clone(ref.sha)] = true
		job := sticker_job_add(.Asset)
		job.item.ref = sticker_ref_clone(ref)
	}
	return nil
}

@(private)
sticker_save_library :: proc(ui: ^Ui_State) {
	personal := make([dynamic]Sticker_Item, context.temp_allocator)
	for item in ui.stickers {if item.ref.pack == "" {append(&personal, item)}}
	bytes, err := json.marshal(Sticker_Library{personal, ui.sticker_unmoved, ui.sticker_recent})
	if err != nil {ui.sticker_error = N_("Couldn't save your stickers. Please try again."); return}
	job := sticker_job_add(.Save)
	job.data = bytes
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

// Load the library once per account, then sync its packs from relays.
@(private)
sticker_library_open :: proc(ui: ^Ui_State) {
	if ui.sticker_account != ui.account_ref {
		for item in ui.stickers {sticker_item_free(item)}
		for pack in ui.sticker_packs {sticker_pack_free(pack)}
		clear(&ui.stickers); clear(&ui.sticker_packs)
		ui.sticker_loaded = false
	}
	if ui.sticker_loaded {return}
	if sticker_busy(ui, .Load) {return}
	sticker_job_add(.Load, ui.account_ref)
	sticker_job_add(.Sync, ui.account_ref)
}

// True while the active account has `op` queued or running. A pack lookup
// counts only for the pack on screen.
@(private)
sticker_busy :: proc(ui: ^Ui_State, op: Sticker_Operation) -> bool {
	for job in sticker_jobs {
		if job.op != op || job.account != ui.account_ref {continue}
		if op == .Pack && job.input != ui.sticker_pack.coordinate {continue}
		return true
	}
	return false
}

@(private)
sticker_job_free :: proc(job: ^Sticker_Job) {
	delete(job.account); delete(job.input); delete(job.data)
	delete(job.group); delete(job.reply); delete(job.root); delete(job.dim)
	sticker_item_free(job.item); sticker_pack_free(job.pack)
	for item in job.items {sticker_item_free(item)}
	delete(job.items)
	for pack in job.packs {sticker_pack_free(pack)}
	delete(job.packs)
	for item in job.library.items {sticker_item_free(item)}
	for pack in job.library.packs {sticker_pack_free(pack)}
	for sha in job.library.recent {delete(sha)}
	delete(job.library.items); delete(job.library.packs); delete(job.library.recent)
	if job.image.data != nil {rl.UnloadImage(job.image)}
	free(job)
}

// Swap in MDK's installed list, keeping personal stickers first.
@(private)
sticker_take_installed :: proc(ui: ^Ui_State, job: ^Sticker_Job) {
	for i := len(ui.stickers) - 1; i >= 0; i -= 1 {
		if ui.stickers[i].ref.pack == "" {continue}
		sticker_item_free(ui.stickers[i]); ordered_remove(&ui.stickers, i)
	}
	append(&ui.stickers, ..job.items[:]); clear(&job.items)
	ui.sticker_packs, job.packs = job.packs, ui.sticker_packs
	if ui.sticker_account != job.account {
		delete(ui.sticker_account); ui.sticker_account = strings.clone(job.account)
	}
	ui.sticker_loaded = true
}

@(private)
drain_stickers :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := 0; i < len(sticker_jobs); {
		job := sticker_jobs[i]
		if job.worker == nil || !thread.is_done(job.worker) {i += 1; continue}
		thread.join(job.worker); thread.destroy(job.worker)
		ordered_remove(&sticker_jobs, i)
		defer sticker_job_free(job)
		if job.op == .Asset || job.op == .Import || job.op == .Receive {
			if !(job.item.ref.sha in sticker_textures) && (job.error == "" || job.op == .Asset) {
				tex: ^rl.Texture2D // nil marks a failure until Retry
				if job.error == "" {
					tex = new(rl.Texture2D)
					tex^ = sticker_texture_load(job.image)
					rl.SetTextureFilter(tex^, .BILINEAR)
				}
				sticker_textures[strings.clone(job.item.ref.sha)] = tex
			}
		}
		if job.op == .Send &&
		   job.account !=
			   ui.account_ref {job.error = N_("Couldn't send the sticker. Switch back to your account and try again.")}
		if job.error != "" {
			if job.op == .Send {sticker_show(ui, job.item.ref)}
			ui.sticker_error = job.error
		}
		switch job.op {
		case .Asset, .Save:
		case .Import, .Receive:
			if job.error != "" {break}
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
			if job.error == "" {queue_sticker_payload(ui, client, job)}
		case .Load, .Sync, .Pack, .Install, .Uninstall:
			// Account results land only while that account is active.
			if job.account != ui.account_ref {break}
			if job.op == .Load && job.read {
				for item in ui.stickers {sticker_item_free(item)}
				delete(ui.stickers)
				ui.stickers, job.library.items = job.library.items, {}
				ui.sticker_recent, job.library.recent = job.library.recent, ui.sticker_recent
				ui.sticker_unmoved, job.library.packs = job.library.packs, ui.sticker_unmoved
			}
			if job.op == .Pack && job.input == ui.sticker_pack.coordinate && job.error == "" {
				ui.sticker_page = .Pack
				sticker_pack_free(ui.sticker_pack)
				ui.sticker_pack, job.pack = job.pack, {}
				ui.sticker_preview, job.items = job.items, ui.sticker_preview
			}
			if job.listed {sticker_take_installed(ui, job)}
			if job.moved {sticker_save_library(ui)}
		}
	}
	// ponytail: one bounded IO job at a time; use two asset workers if packs need it.
	for job in sticker_jobs {if job.worker != nil {return}}
	if len(sticker_jobs) == 0 {return}
	job := sticker_jobs[0]
	for candidate in sticker_jobs {if candidate.op != .Asset {job = candidate; break}}
	job.client = client
	if job.account == "" {job.account = strings.clone(ui.account_ref)}
	job.worker = thread.create(sticker_worker)
	job.worker.data = job
	thread.start(job.worker)
}

@(private)
sticker_stop :: proc() {
	// Join owned workers before unloading; finish queued library writes in order.
	for job in sticker_jobs {
		if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
		if job.op == .Save && job.worker == nil {
			if !media_write_sealed(
				sticker_library_path(),
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
	sticker_jobs = {}
	sticker_textures = {}
	sticker_requested = {}
}
