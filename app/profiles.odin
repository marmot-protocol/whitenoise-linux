// Profile names + pictures, the slint avatar-pipeline port.
//
// Names and picture URLs come from marmot's local kind-0 cache
// (marmot_user_profile) at load time, memoized per account for the
// session. Picture bytes are fetched by one curl worker thread; the
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

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import rl "sdlrl"
import marmot "../marmot"

// One account's cached kind-0 essentials; empty strings when unknown.
Profile_Info :: struct {
	name:    string,
	pic_url: string,
}

// account hex → kind-0 essentials, one FFI lookup per session.
@(private = "file")
profile_cache: map[string]Profile_Info

profile_info :: proc(client: ^marmot.Client, hex: string) -> Profile_Info {
	if info, ok := profile_cache[hex]; ok {
		return info
	}

	info: Profile_Info
	meta: ^marmot.User_Profile_Metadata
	if marmot.user_profile(client, strings.clone_to_cstring(hex, context.temp_allocator), &meta) == .OK && meta != nil {
		if meta.display_name != nil && len(string(meta.display_name)) > 0 {
			info.name = strings.clone(string(meta.display_name))
		} else if meta.name != nil && len(string(meta.name)) > 0 {
			info.name = strings.clone(string(meta.name))
		}
		if meta.picture != nil {
			info.pic_url = strings.clone(string(meta.picture))
		}
		marmot.user_profile_metadata_free(meta)
	}
	profile_cache[strings.clone(hex)] = info
	return info
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
	profile_cache[strings.clone(hex)] = {name = strings.clone(name), pic_url = pic_url}
}

// Register a locally composed image under a pseudo-URL (starter://,
// group://): nothing to fetch, the round texture lands in the cache
// directly. Re-registering an URL replaces its texture.
register_local_pic :: proc(url: string, image: rl.Image) {
	tex := new(rl.Texture2D)
	tex^ = circle_texture(image)
	if old, ok := pic_textures[url]; ok {
		if old != nil {
			rl.UnloadTexture(old^)
			free(old)
		}
		pic_textures[url] = tex
		return
	}
	pic_textures[strings.clone(url)] = tex
	pic_requested[strings.clone(url)] = true
}

// ── Picture fetch pipeline ──────────────────────────────────────────

@(private = "file")
Fetched_Pic :: struct {
	url:  string,
	data: []u8, // nil = fetch failed
}

@(private = "file")
pic_mutex: sync.Mutex
@(private = "file")
pic_queue: [dynamic]string
@(private = "file")
pic_done: [dynamic]Fetched_Pic
@(private = "file")
pic_requested: map[string]bool
// url → decoded round texture; an entry holding nil means the fetch
// or decode failed (gradient fallback stays).
@(private = "file")
pic_textures: map[string]^rl.Texture2D

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
	for {
		sync.lock(&pic_mutex)
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

		state, out, _, err := os.process_exec(
			{command = {"curl", "-sfL", "--max-time", "15", url}},
			context.allocator,
		)
		data := out
		if err != nil || state.exit_code != 0 || len(out) == 0 {
			fmt.eprintfln("pics: fetch failed: %s", url)
			delete(out)
			data = nil
		}

		sync.lock(&pic_mutex)
		append(&pic_done, Fetched_Pic{url = url, data = data})
		sync.unlock(&pic_mutex)
	}
}

start_pic_worker :: proc() {
	thread.start(thread.create(pic_worker))
}

// Frame-loop drain: decode fetched bytes into round avatar textures.
drain_pics :: proc() {
	sync.lock(&pic_mutex)
	done := pic_done
	pic_done = {}
	sync.unlock(&pic_mutex)

	for f in done {
		tex: ^rl.Texture2D
		if f.data != nil {
			image := rl.LoadImageFromMemory(".img", raw_data(f.data), i32(len(f.data)))
			if image.data != nil {
				tex = new(rl.Texture2D)
				tex^ = circle_texture(image)
				rl.UnloadImage(image)
			}
			delete(f.data)
		}
		pic_textures[f.url] = tex // nil marks a permanent miss
	}
	delete(done)
}

// Center-crop to a square and cut a circular alpha mask, then upload.
// The clay SDL renderer draws images as plain rects (cornerRadius is
// ignored for images), so roundness has to live in the pixels.
@(private = "file")
circle_texture :: proc(image: rl.Image) -> rl.Texture2D {
	side := min(image.width, image.height)
	ox := (image.width - side) / 2
	oy := (image.height - side) / 2
	out := make([]u8, int(side) * int(side) * 4, context.temp_allocator)

	src := image.data
	radius := f32(side) / 2
	for y in 0 ..< side {
		for x in 0 ..< side {
			s := (int(oy + y) * int(image.width) + int(ox + x)) * 4
			d := (int(y) * int(side) + int(x)) * 4
			out[d + 0] = src[s + 0]
			out[d + 1] = src[s + 1]
			out[d + 2] = src[s + 2]
			dx := f32(x) + 0.5 - radius
			dy := f32(y) + 0.5 - radius
			out[d + 3] = dx * dx + dy * dy <= radius * radius ? src[s + 3] : 0
		}
	}
	return rl.LoadTextureFromImage({data = raw_data(out), width = side, height = side})
}
