// Project photos are local, folder-bound assets, independent of accounts.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import rl "sdlrl"

@(private)
WHIP_AVATAR_PREFIX :: "wn-whip-avatar:"

@(private)
Whip_Avatar_Key :: struct {
	folder, crop, basename, url, inbox: string,
}

@(private = "file")
whip_avatar_keys: map[string]^Whip_Avatar_Key

// Cache lexical normalization and SHA256 once per borrowed model directory.
// Neither this path nor target validation resolves symlinks or touches disk.
@(private)
whip_avatar_key :: proc(dir: string) -> ^Whip_Avatar_Key {
	if key, found := whip_avatar_keys[dir]; found {return key}
	key := new(Whip_Avatar_Key)
	if dir != "" {
		key.folder, _ = filepath.clean(dir, context.allocator)
		digest: [32]u8
		hash.hash(.SHA256, key.folder, digest[:])
		encoded, _ := hex.encode(digest[:], context.allocator)
		key.crop = string(encoded)
	}
	whip_avatar_keys[strings.clone(dir)] = key
	return key
}

@(private)
whip_avatar_valid :: proc(folder: string) -> bool {
	if folder == "" {return false}
	for project in rl.WhipProjects() {
		if whip_avatar_key(project.dir).folder == folder {return true}
	}
	return false
}

@(private)
whip_avatar_name :: proc(name: string) -> bool {
	if len(name) != 68 || !strings.has_suffix(name, ".img") {return false}
	for c in name[:64] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return true
}

// Only the picture worker reads this private scheme. Never treat its suffix
// as an arbitrary file path, even when it originated in preferences.
@(private)
whip_avatar_read :: proc(name: string) -> []u8 {
	if !whip_avatar_name(name) {return nil}
	root := settings_path(context.temp_allocator, "whip-avatars")
	if root == "" {return nil}
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", root, name), context.allocator)
	if err != nil {delete(data); return nil}
	return data
}

@(private)
whip_project_avatar :: proc(ui: ^Ui_State, id: u32, dir, name: string, size: f32) {
	key := whip_avatar_key(dir)
	basename := ui.prefs.whip_avatars[key.folder]
	if basename != key.basename {
		delete(key.basename); delete(key.url)
		key.basename = strings.clone(basename)
		key.url =
			whip_avatar_name(basename) ? fmt.aprintf("%s%s", WHIP_AVATAR_PREFIX, basename) : ""
	}
	tex := key.url != "" ? url_pic(key.url) : nil
	// No initials while the crop-circle worker is preparing its texture.
	avatar("WhipProjectAvatar", id, key.crop, tex != nil ? name : "", size, tex)
}

@(private)
Whip_Avatar_Job :: struct {
	worker:           ^thread.Thread,
	folder, basename: string,
	path, error:      string,
	draft:            Pic_Draft,
	ok:               bool,
	loading:          bool,
}

@(private = "file")
whip_avatar_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Whip_Avatar_Job)(t.data)
	if job.loading {
		whip_avatar_decode(job)
		return
	}
	root := settings_path(context.temp_allocator, "whip-avatars")
	if root == "" || len(job.draft.data) == 0 {return}
	digest: [32]u8
	hash.hash(.SHA256, job.draft.data, digest[:])
	encoded, _ := hex.encode(digest[:], context.temp_allocator)
	job.basename = fmt.aprintf("%s.img", encoded)
	path := fmt.tprintf("%s/%s", root, job.basename)
	next := fmt.tprintf("%s.tmp", path)
	defer os.remove(next)
	if os.make_directory_all(root) != nil {return}
	if os.write_entire_file(next, job.draft.data, {.Read_User, .Write_User}) != nil {return}
	job.ok = os.rename(next, path) == nil
}

@(private = "file")
whip_avatar_decode :: proc(job: ^Whip_Avatar_Job) {
	data, err := os.read_entire_file(job.path, context.allocator)
	if err != nil {
		delete(data)
		job.error = N_("Couldn't read the project photo. Please try again.")
		return
	}
	media := media_type_for(job.path)
	if !strings.has_prefix(media, "image/") {
		delete(data)
		job.error = N_("Couldn't use that file. Choose a PNG or JPEG.")
		return
	}
	ext := strings.clone_to_cstring(
		fmt.tprintf(".%s", strings.trim_prefix(media, "image/")),
		context.temp_allocator,
	)
	image := rl.LoadImageFromMemory(ext, raw_data(data), i32(len(data)))
	if image.data == nil {
		delete(data)
		job.error = N_("Couldn't decode the image. Choose a PNG or JPEG.")
		return
	}
	job.draft = {
		data       = data,
		media_type = media,
		image      = image,
	}
	job.ok = true
}

@(private)
whip_avatar_load :: proc(ui: ^Ui_State, path: string) {
	job := new(Whip_Avatar_Job)
	job.folder = strings.clone(ui.photo.folder)
	job.path = strings.clone(path)
	job.loading = true
	job.worker = thread.create(whip_avatar_worker)
	job.worker.data = job
	ui.whip_avatar_job = job
	thread.start(job.worker)
}

@(private = "file")
whip_avatar_preview :: proc(ui: ^Ui_State, job: ^Whip_Avatar_Job) {
	if ui.photo.kind != .Whip || ui.photo.folder != job.folder || !photo_target_valid(ui) {return}
	if !job.ok {
		photo_cancel(ui)
		set_status(ui, strings.clone(tr(job.error)), .Error)
		return
	}
	texture := rl.LoadTextureFromImage(job.draft.image)
	if texture.tex == nil {
		photo_cancel(ui)
		set_status(
			ui,
			strings.clone(tr("Couldn't preview the picture. Please try again.")),
			.Error,
		)
		return
	}
	ui.photo.draft, ui.photo.texture = job.draft, texture
	job.draft = {}
}

// Takes the draft's sole ownership, including its decoded pixels. The worker
// only saves bytes; texture installation and preference mutation stay on frame.
@(private)
whip_avatar_save :: proc(ui: ^Ui_State, folder: string, draft: Pic_Draft) {
	job := new(Whip_Avatar_Job)
	job.folder = strings.clone(folder)
	job.draft = draft
	job.worker = thread.create(whip_avatar_worker)
	job.worker.data = job
	ui.whip_avatar_job = job
	thread.start(job.worker)
}

@(private)
whip_avatar_drain :: proc(ui: ^Ui_State) {
	job := ui.whip_avatar_job
	if job == nil || !thread.is_done(job.worker) {return}
	thread.join(job.worker); thread.destroy(job.worker)
	ui.whip_avatar_job = nil
	if job.loading {
		whip_avatar_preview(ui, job)
	} else if job.ok && whip_avatar_valid(job.folder) {
		if old, found := &ui.prefs.whip_avatars[job.folder]; found {
			delete(old^); old^ = job.basename
		} else {
			ui.prefs.whip_avatars[strings.clone(job.folder)] = job.basename
		}
		job.basename = "" // moved into preferences, only after the atomic rename
		url := fmt.tprintf("%s%s", WHIP_AVATAR_PREFIX, ui.prefs.whip_avatars[job.folder])
		register_local_pic(url, job.draft.image)
		ui.settings_dirty = true
	} else if !job.ok {
		set_status(
			ui,
			strings.clone(tr("Couldn't save the project photo. Please try again.")),
			.Error,
		)
	}
	pic_draft_free(&job.draft)
	delete(job.folder); delete(job.basename); delete(job.path); free(job)
}

@(private)
whip_avatar_reset :: proc(ui: ^Ui_State, folder: string) {
	if key, image := delete_key(&ui.prefs.whip_avatars, folder); key != "" {
		delete(key); delete(image)
		ui.settings_dirty = true
	}
}

@(private)
whip_avatar_stop :: proc(ui: ^Ui_State) {
	if job := ui.whip_avatar_job; job != nil {
		thread.join(job.worker)
		whip_avatar_drain(ui)
	}
	for dir, key in whip_avatar_keys {
		delete(dir); delete(key.folder); delete(key.crop)
		delete(key.basename); delete(key.url); delete(key.inbox); free(key)
	}
	delete(whip_avatar_keys); whip_avatar_keys = nil
}
