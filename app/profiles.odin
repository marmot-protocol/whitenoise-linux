// Profile names + pictures, the slint avatar-pipeline port.
//
// Names and picture URLs come from marmot's local kind-0 cache
// (marmot_user_profile), checked in bounded background batches.
// Picture bytes are fetched by one curl worker thread; the
// frame loop drains the results and decodes them into textures
// (texture creation must stay on the render thread), so layout code
// only ever calls url_pic and falls back to the gradient avatar
// while nil.
//
//   layout ── url_pic(url) ──► pic_textures[url]
//                 │ miss: enqueue          ▲
//                 ▼                        │ decode + circle mask
//             pic_queue ──► curl worker ──► pic_done ──► drain_pics (frame loop)
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import cc "../vendor/crop-circles"
import rl "sdlrl"

// One account's cached kind-0 essentials; empty strings when unknown.
Profile_Info :: struct {
	name:    string,
	pic_url: string,
	nip05:   string,
}

// account hex → kind-0 essentials, shared by the visible UI snapshots.
@(private = "file")
profile_cache: map[string]Profile_Info

@(private = "file")
PROFILE_BATCH :: 32
@(private = "file")
Profile_Batch :: struct {
	worker: ^thread.Thread,
	client: ^marmot.Client,
	ids:    []string,
	infos:  []Profile_Info,
	ok:     []bool,
}
@(private = "file")
profile_batch: ^Profile_Batch
@(private = "file")
profile_order: [dynamic]string // borrows the cache's immutable keys
@(private = "file")
profile_pending: [dynamic]string
@(private = "file")
profile_pending_ids: map[string]bool
@(private = "file")
profile_cursor: int

@(private = "file")
profile_queue :: proc(hex: string) {
	if hex == "" || profile_pending_ids[hex] {return}
	if !(hex in profile_cache) {
		key := strings.clone(hex)
		profile_cache[key] = {}
		append(&profile_order, key)
	}
	id := strings.clone(hex)
	profile_pending_ids[id] = true
	append(&profile_pending, id)
}

@(private = "file")
profile_read_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	batch := (^Profile_Batch)(t.data)
	defer frame_wake()
	defer free_all(context.temp_allocator)
	for id, i in batch.ids {
		batch.infos[i], batch.ok[i] = read_profile(batch.client, id)
	}
}

@(private)
profile_reads_stop :: proc() {
	sync.lock(&refresh_mutex)
	refresh_stopping = true
	sync.unlock(&refresh_mutex)
	if refresh_thread != nil {
		thread.join(refresh_thread)
		thread.destroy(refresh_thread)
		refresh_thread = nil
	}
	if batch := profile_batch; batch != nil {
		thread.join(batch.worker)
		thread.destroy(batch.worker)
		for info in batch.infos {delete(info.name); delete(info.pic_url); delete(info.nip05)}
		for id in batch.ids {delete(id)}
		delete(batch.ids); delete(batch.infos); delete(batch.ok); free(batch)
		profile_batch = nil
	}
	for id in profile_pending {delete(id)}
	delete(profile_pending)
	profile_pending = {}
	delete(profile_pending_ids)
	profile_pending_ids = nil
}

profile_info :: proc(client: ^marmot.Client, hex: string) -> Profile_Info {
	if info, ok := profile_cache[hex]; ok {
		return info
	}

	key := strings.clone(hex)
	profile_cache[key] = {}
	append(&profile_order, key)
	if client != nil {profile_queue(hex)}
	return {}
}

// One kind-0 read straight out of marmot's cache, no memo.
@(private = "file")
read_profile :: proc(client: ^marmot.Client, hex: string) -> (Profile_Info, bool) {
	timing_start := time.tick_now()
	defer local_timing_end(.profile_read, timing_start)
	info: Profile_Info
	meta: ^marmot.User_Profile_Metadata
	if marmot.user_profile(client, strings.clone_to_cstring(hex, context.temp_allocator), &meta) !=
	   .OK {
		return {}, false
	}
	if meta != nil {
		if meta.display_name != nil && len(string(meta.display_name)) > 0 {
			info.name = strings.clone(string(meta.display_name))
		} else if meta.name != nil && len(string(meta.name)) > 0 {
			info.name = strings.clone(string(meta.name))
		}
		if meta.picture != nil {
			info.pic_url = strings.clone(string(meta.picture))
		}
		if meta.nip05 != nil {info.nip05 = strings.clone(string(meta.nip05))}
		marmot.user_profile_metadata_free(meta)
	}
	return info, true
}

// Display label for an account: kind-0 name, else truncated hex.
profile_label :: proc(client: ^marmot.Client, hex: string) -> string {
	info := profile_info(client, hex)
	return len(info.name) > 0 ? info.name : short_hex(hex)
}

// Seed the session caches for a freshly generated account: the
// starter name plus its locally composed face under a starter://
// pseudo-URL (nothing to fetch; the texture registers directly).
// A nil image seeds the name only.
register_starter_pic :: proc(hex: string, name: string, url: string, image: rl.Image) {
	pic_url := ""
	if image.data != nil {
		register_local_pic(url, image)
		pic_url = strings.clone(url)
	}
	if old, ok := profile_cache[hex]; ok {
		delete(old.name); delete(old.pic_url); delete(old.nip05)
		profile_cache[hex] = {
			name    = strings.clone(name),
			pic_url = pic_url,
		}
	} else {
		key := strings.clone(hex)
		profile_cache[key] = {
			name    = strings.clone(name),
			pic_url = pic_url,
		}
		append(&profile_order, key)
	}
}

// Register a locally composed image under a pseudo-URL (starter://,
// group://, blossom://): nothing to fetch, the texture lands in the cache
// directly. Re-registering an URL replaces its texture.
register_local_pic :: proc(url: string, image: rl.Image) {
	tex := photo_texture(image)
	if old, ok := pic_textures[url]; ok {
		if old != nil {
			forget_avatar(old)
			rl.UnloadTexture(old^)
			free(old)
		}
		pic_textures[url] = tex
		return
	}
	pic_textures[strings.clone(url)] = tex
	pic_requested[strings.clone(url)] = true
}

// ── Profile refresh ─────────────────────────────────────────────────
//
// marmot_refresh_profile blocks on a relay round trip, so it runs on
// its own worker; the frame loop re-reads the accounts it finished.

@(private = "file")
refresh_mutex: sync.Mutex
@(private = "file")
refresh_queue: [dynamic]string
@(private = "file")
refresh_done: [dynamic]string
// Accounts already asked about, so a permanent miss is asked once.
@(private = "file")
refresh_asked: map[string]bool
@(private = "file")
refresh_client: ^marmot.Client
@(private = "file")
refresh_thread: ^thread.Thread
@(private = "file")
refresh_stopping: bool

@(private = "file")
queue_refresh :: proc(client: ^marmot.Client, hex: string) {
	if client == nil || refresh_asked[hex] {
		return
	}
	refresh_asked[strings.clone(hex)] = true

	sync.lock(&refresh_mutex)
	refresh_client = client
	append(&refresh_queue, strings.clone(hex))
	sync.unlock(&refresh_mutex)
}

// ponytail: one worker, 100ms poll; the queue only fills on cache
// misses, which is once per unseen account.
@(private = "file")
refresh_worker :: proc(_: ^thread.Thread) {
	context.allocator = reload_allocator()
	for {
		sync.lock(&refresh_mutex)
		if refresh_stopping {
			sync.unlock(&refresh_mutex)
			return
		}
		hex: string
		client := refresh_client
		have := len(refresh_queue) > 0
		if have {
			hex = refresh_queue[0]
			ordered_remove(&refresh_queue, 0)
		}
		sync.unlock(&refresh_mutex)
		if !have {
			time.sleep(100 * time.Millisecond)
			continue
		}

		// Ask the whitenoise fleet plus, for a local account, its own NIP-65
		// relays: another client may publish kind 0 only to those.
		id := strings.clone_to_cstring(hex, context.temp_allocator)
		relays := make([dynamic]cstring, context.temp_allocator)
		append(&relays, ..DEFAULT_RELAYS)
		nip65: ^marmot.String_List
		if marmot.account_nip65_relays(client, id, &nip65) == .OK && nip65 != nil {
			for i in 0 ..< nip65.len {
				url := nip65.items[i]
				if url == nil || slice.contains(DEFAULT_RELAYS, url) {continue}
				append(&relays, strings.clone_to_cstring(string(url), context.temp_allocator))
			}
			marmot.string_list_free(nip65)
		}
		if marmot.refresh_profile(client, id, raw_data(relays), uint(len(relays))) != .OK {
			// marmot's last_error is thread-local, so it is read here.
			fmt.eprintfln("profiles: refresh failed for %s: %s", hex, marmot.last_error())
		}
		free_all(context.temp_allocator)

		sync.lock(&refresh_mutex)
		append(&refresh_done, hex)
		sync.unlock(&refresh_mutex)
		frame_wake()
	}
}

@(private = "file")
PROFILE_CHECK_SECS :: 1.0
@(private = "file")
profile_checked: f64 = -1

// Directory updates have no reliable group event. Read a bounded rotating
// batch on a worker; misses and relay completions enter the same queue.
drain_refresh :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	sync.lock(&refresh_mutex)
	done := refresh_done
	refresh_done = {}
	sync.unlock(&refresh_mutex)
	for hex in done {
		profile_queue(hex)
		// The queued essentials read misses about/handle/lud16, and an open
		// profile page never reloads on its own.
		if client != nil && hex == ui.account_ref && ui.profile.loaded {
			reload_profile(ui, client)
		}
		delete(hex)
	}
	delete(done)
	if client == nil {return}
	changed := false
	if batch := profile_batch; batch != nil && thread.is_done(batch.worker) {
		thread.join(batch.worker)
		thread.destroy(batch.worker)
		for hex, i in batch.ids {
			delete_key(&profile_pending_ids, hex)
			if batch.ok[i] {
				changed = update_profile(ui, hex, batch.infos[i]) || changed
				if batch.infos[i] == (Profile_Info{}) {queue_refresh(client, hex)}
			}
			delete(hex)
		}
		delete(batch.ids); delete(batch.infos); delete(batch.ok); free(batch)
		profile_batch = nil
	}
	if changed {load_timeline(client, ui, string(ui.search_input[:]))}
	now := rl.GetTime()
	if profile_checked < 0 || now - profile_checked >= PROFILE_CHECK_SECS {
		profile_checked = now
		// Own kind 0 once per account per session, whatever the cache holds:
		// an edit made in another client must show up after a restart.
		queue_refresh(client, ui.account_ref)
		profile_queue(ui.account_ref)
		profile_queue(ui.peer_hex)
		for _ in 0 ..< min(PROFILE_BATCH, len(profile_order)) {
			profile_cursor %= len(profile_order)
			profile_queue(profile_order[profile_cursor])
			profile_cursor += 1
		}
	}
	if profile_batch != nil || len(profile_pending) == 0 {return}
	batch := new(Profile_Batch)
	batch.client = client
	n := min(PROFILE_BATCH, len(profile_pending))
	batch.ids = make([]string, n)
	for &id in batch.ids {id = pop(&profile_pending)}
	batch.infos = make([]Profile_Info, n)
	batch.ok = make([]bool, n)
	batch.worker = thread.create(profile_read_worker)
	batch.worker.data = batch
	profile_batch = batch
	thread.start(batch.worker)
}

// Takes ownership of info. Keep unchanged strings and UI editor indices stable.
@(private)
update_profile :: proc(ui: ^Ui_State, hex: string, info: Profile_Info) -> bool {
	old := profile_cache[hex]
	if old == info {
		delete(info.name)
		delete(info.pic_url)
		delete(info.nip05)
		return false
	}
	profile_cache[hex] = info
	wrap_flush = true
	name := len(info.name) > 0 ? info.name : short_hex(hex)
	for &member in ui.members {
		if member.id_hex != hex {
			continue
		}
		label := len(info.name) == 0 && member.is_self ? "you" : name
		if nick := ui.nicknames[hex]; len(nick) > 0 && !member.is_self {
			label = nick
		}
		delete(member.name)
		delete(member.pic_url)
		member.name = strings.clone(label)
		member.pic_url = strings.clone(info.pic_url)
	}
	for &contact in ui.contacts {
		if contact.id_hex != hex {
			continue
		}
		delete(contact.name)
		delete(contact.pic_url)
		contact.name = strings.clone(name)
		contact.pic_url = strings.clone(info.pic_url)
	}
	if ui.profile_contact.id_hex == hex {
		delete(ui.profile_contact.name)
		delete(ui.profile_contact.pic_url)
		ui.profile_contact.name = strings.clone(name)
		ui.profile_contact.pic_url = strings.clone(info.pic_url)
	}
	if ui.peer_hex == hex {
		delete(ui.peer_name)
		delete(ui.peer_pic)
		ui.peer_name = strings.clone(len(ui.nicknames[hex]) > 0 ? ui.nicknames[hex] : name)
		ui.peer_pic = strings.clone(info.pic_url)
	}
	if ui.account_ref == hex {
		// my_pic_url can borrow the old memo; replace it before freeing that memo.
		ui.my_pic_url = info.pic_url
	}
	for id, i in ui.account_ids {
		if id != hex {
			continue
		}
		delete(ui.accounts[i])
		delete(ui.account_pics[i])
		ui.accounts[i] = strings.clone(name)
		ui.account_pics[i] = strings.clone(info.pic_url)
	}
	delete(old.name)
	delete(old.pic_url)
	delete(old.nip05)
	return true
}

// ── Picture fetch pipeline ──────────────────────────────────────────

@(private = "file")
Fetched_Pic :: struct {
	url:  string,
	data: []u8, // nil = fetch failed
	side: i32, // generated RGBA pixels; zero means encoded image bytes
}

@(private = "file")
pic_mutex: sync.Mutex
@(private = "file")
pic_queue: [dynamic]string
@(private = "file")
pic_done: [dynamic]Fetched_Pic
@(private = "file")
pic_requested: map[string]bool
@(private = "file")
pic_thread: ^thread.Thread
@(private = "file")
pic_stopping: bool
// url → decoded round texture; an entry holding nil means the fetch
// or decode failed (gradient fallback stays).
@(private = "file")
pic_textures: map[string]^rl.Texture2D

// Texture for a pseudo-URL somebody else registers (starter://,
// group://, blossom://): a plain lookup, never a fetch.
local_pic :: proc(url: string) -> ^rl.Texture2D {
	return pic_textures[url]
}

// GIFs share the image queue, but only visible tiles request a thumbnail.
@(private)
gif_thumb :: proc(item: Gif_Item, index: int) -> (tex: ^rl.Texture2D, loading, failed: bool) {
	if item.sha == "" && item.thumb == "" {return}
	key := item.sha != "" ? fmt.tprintf("gif:%s", item.sha) : fmt.tprintf("image:%s", item.thumb)
	if cached, ready := pic_textures[key]; ready {return cached, false, cached == nil}
	if !gif_visible(index) {return}
	return url_pic(key), true, false
}

@(private)
gif_retry :: proc(ui: ^Ui_State) {
	for &item in ui.gif_hits {item.failed = false}
	for &item in ui.gif_library {item.failed = false}
	sync.lock(&pic_mutex)
	defer sync.unlock(&pic_mutex)
	for key, tex in pic_textures {
		if tex != nil ||
		   !(strings.has_prefix(key, "image:") || strings.has_prefix(key, "gif:")) {continue}
		delete_key(&pic_textures, key)
		pic_requested[key] = false
		delete(key)
	}
	for key, requested in pic_requested {
		if !requested {delete_key(&pic_requested, key); delete(key)}
	}
	ui.gif_error = ""
}

// Layout-side accessor: the picture texture once fetched, nil while
// the gradient fallback should render. First sight queues the fetch.
url_pic :: proc(url: string) -> ^rl.Texture2D {
	if len(url) == 0 {
		return nil
	}
	if tex, ok := pic_textures[url]; ok {
		return tex
	}

	sync.lock(&pic_mutex)
	defer sync.unlock(&pic_mutex)
	if !pic_requested[url] {
		pic_requested[strings.clone(url)] = true
		append(&pic_queue, strings.clone(url))
	}
	return nil
}

// Worker: curl each queued URL (no TLS stack in Odin; curl is always
// present on the target systems). Bytes land in pic_done for the
// frame loop.
// ponytail: one worker, 100ms poll; parallel fetches when a large
// contact list makes the trickle visible.
@(private = "file")
pic_worker :: proc(_: ^thread.Thread) {
	context.allocator = reload_allocator()
	for {
		sync.lock(&pic_mutex)
		if pic_stopping {sync.unlock(&pic_mutex); return}
		url: string
		have := len(pic_queue) > 0
		if have {
			url = pic_queue[0]
			ordered_remove(&pic_queue, 0)
		}
		sync.unlock(&pic_mutex)
		if !have {
			time.sleep(100 * time.Millisecond)
			continue
		}

		data: []u8
		side: i32
		if strings.has_prefix(url, "crop-circle:") {
			data, side = crop_circle_pixels(url[len("crop-circle:"):])
		} else if strings.has_prefix(url, "crop-square:") {
			data, side = crop_circle_pixels(url[len("crop-square:"):], .Square)
		} else if strings.has_prefix(url, "crop-round:") {
			data, side = crop_circle_pixels(url[len("crop-round:"):], .Circle)
		} else if strings.has_prefix(url, "crop-rounded:") {
			data, side = crop_circle_pixels(url[len("crop-rounded:"):], .Rounded)
		} else if strings.has_prefix(url, "gif:") {
			data = gif_read(url[len("gif:"):])
		} else if strings.has_prefix(url, "image:") {
			// Transient picker thumbnails use the bounded HTTPS fetch, without avatar cropping.
			buffer := make([]u8, 4 * 1024 * 1024, context.temp_allocator)
			n := wn_https_get(
				strings.clone_to_cstring(url[len("image:"):], context.temp_allocator),
				raw_data(buffer),
				uint(len(buffer)),
			)
			if n > 0 {data = make([]u8, int(n)); copy(data, buffer[:n])}
		} else {
			data = pic_load(url)
		}
		free_all(context.temp_allocator)

		sync.lock(&pic_mutex)
		append(&pic_done, Fetched_Pic{url = url, data = data, side = side})
		sync.unlock(&pic_mutex)
		frame_wake()
	}
}

@(private)
pic_cache_path :: proc(url: string) -> string {
	digest: [32]u8
	hash.hash(.SHA256, url, digest[:])
	key, _ := hex.encode(digest[:], context.temp_allocator)
	return fmt.tprintf("%s/profile-%s.bin", media_cache_dir(), key)
}

// Share the encrypted media cache and its clear action. Refresh mutable
// URLs after a day; retain the last image when its server is unavailable.
@(private)
pic_load :: proc(url: string) -> []u8 {
	path := pic_cache_path(url)
	cached: []u8
	if sealed, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		cached, _ = vault_open_blob(sealed)
		if len(cached) > 0 {
			if info, err := os.stat(path, context.temp_allocator);
			   err == nil && time.since(info.modification_time) < 24 * time.Hour {
				return cached
			}
		}
	}
	state, data, stderr, err := os.process_exec(
		{command = {curl_path(), "-sfL", "--max-time", "15", "--", url}},
		context.allocator,
	)
	defer delete(stderr)
	if err != nil || state.exit_code != 0 || len(data) == 0 {
		delete(data)
		return cached
	}
	delete(cached)
	if sealed, ok := vault_seal_blob(data, context.temp_allocator); ok {
		os.make_directory(media_cache_dir())
		tmp := fmt.tprintf("%s.tmp", path)
		if os.write_entire_file(tmp, sealed, {.Read_User, .Write_User}) == nil {
			if os.rename(tmp, path) != nil {os.remove(tmp)}
		}
	}
	return data
}

start_pic_worker :: proc() {
	context.allocator = reload_allocator()
	pic_thread = thread.create(pic_worker)
	thread.start(pic_thread)
	refresh_thread = thread.create(refresh_worker)
	thread.start(refresh_thread)
}

@(private)
stop_pic_worker :: proc() {
	context.allocator = reload_allocator()
	if pic_thread == nil {return}
	sync.lock(&pic_mutex)
	pic_stopping = true
	sync.unlock(&pic_mutex)
	thread.join(pic_thread)
	thread.destroy(pic_thread)
	pic_thread = nil
	profile_reads_stop()
}

// Upload generated fingerprints and decode photos into round avatar textures.
drain_pics :: proc() {
	sync.lock(&pic_mutex)
	done := pic_done
	pic_done = {}
	sync.unlock(&pic_mutex)

	for f in done {
		tex: ^rl.Texture2D
		if f.data != nil && f.side > 0 {
			tex = new(rl.Texture2D)
			tex^ = rl.LoadTextureFromImage(
				{data = raw_data(f.data), width = f.side, height = f.side},
			)
			delete(f.data)
		} else if f.data != nil {
			image := rl.LoadImageFromMemory(".img", raw_data(f.data), i32(len(f.data)))
			if image.data != nil {
				if strings.has_prefix(f.url, "image:") || strings.has_prefix(f.url, "gif:") {
					tex = new(rl.Texture2D)
					tex^ = rl.LoadTextureFromImage(image)
				} else {tex = photo_texture(image)}
				rl.UnloadImage(image)
			}
			delete(f.data)
		}
		pic_textures[f.url] = tex // nil marks a permanent miss
		if tex != nil && f.side == 0 {wrap_flush = true}
	}
	delete(done)
}

@(private)
Crop_Shape :: enum {
	Slanted,
	Square,
	Circle,
	Rounded,
}

@(private)
CROP_SHAPE_PREFIX := [Crop_Shape]string {
	.Slanted = "crop-circle",
	.Square  = "crop-square",
	.Circle  = "crop-round",
	.Rounded = "crop-rounded",
}

@(private)
CROP_SHAPE_NAMES := [Crop_Shape]string {
	.Slanted = N_("Slanted"),
	.Square  = N_("Square"),
	.Circle  = N_("Circle"),
	.Rounded = N_("Rounded"),
}

// Public keys are already 32-byte digests. MLS's 16-byte IDs need SHA-256.
@(private)
crop_circle_pixels :: proc(key: string, shape := Crop_Shape.Slanted) -> ([]u8, i32) {
	if len(key) != 64 && len(key) != 32 {return nil, 0}
	digest: [32]u8
	bytes, valid := hex.decode_into_buffer(transmute([]u8)key, digest[:])
	if !valid {return nil, 0}
	if len(bytes) == 16 {
		group := digest
		hash.hash(.SHA256, group[:16], digest[:])
	}
	image := cc.make_from_digest(digest, .Detailed, module_size = 2, alpha = .Opaque)
	if shape == .Square {return image.pixels, i32(image.width)}
	defer cc.image_destroy(image)
	if shape == .Circle || shape == .Rounded {
		mask := shape == .Circle ? "circle" : "rounded"
		return avatar_mask_pixels(
			{data = raw_data(image.pixels), width = i32(image.width), height = i32(image.height)},
			mask,
		), i32(image.width)
	}
	pixels := make([]u8, len(image.pixels))
	// Fit every row into a left-leaning trapezoid without cropping the fingerprint.
	for y in 0 ..< image.height {
		t := (f32(y) + 0.5) / f32(image.height)
		left := f32(image.width) * 0.15 * t
		right := f32(image.width) * (0.75 + 0.25 * t)
		for x in 0 ..< image.width {
			coverage := clamp(min(f32(x + 1) - left, right - f32(x)), 0, 1)
			sx := clamp(
				int((f32(x) + 0.5 - left) / (right - left) * f32(image.width)),
				0,
				image.width - 1,
			)
			dst, src := (y * image.width + x) * 4, (y * image.width + sx) * 4
			copy(pixels[dst:dst + 3], image.pixels[src:src + 3])
			pixels[dst + 3] = u8(coverage * 255)
		}
	}
	return pixels, i32(image.width)
}

@(private)
crop_circle :: proc(
	id: string,
	index: u32,
	key: string,
	size: f32,
	shape: Crop_Shape = Crop_Shape(-1),
) {
	shape := shape
	if shape == Crop_Shape(-1) {shape = g_ui != nil ? g_ui.prefs.crop_avatar_shape : .Slanted}
	tex := url_pic(fmt.tprintf("%s:%s", CROP_SHAPE_PREFIX[shape], key))
	if clay.UI(clay.ID(id, index))(
	{
		layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
		image = {imageData = tex},
	},
	) {}
}
