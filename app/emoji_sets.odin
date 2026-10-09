package main

import marmot "../marmot"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "sdlrl"

@(private)
EMOJI_SET_KIND :: 30030
@(private)
EMOJI_SET_LIMIT :: 60
@(private)
EMOJI_SET_ITEMS :: 200
@(private)
EMOJI_ASSET_LIMIT :: 4 * 1024 * 1024

@(private)
Nostr_Emoji_Item :: struct {
	code, url:    string,
	image:        rl.Image,
	texture:      ^rl.Texture2D,
	preview_done: bool,
}
@(private)
Nostr_Emoji_Set :: struct {
	coordinate, title, author, event, relay, description: string,
	sort_title:                                           string,
	cover_done:                                           bool,
	created_at:                                           u64,
	items:                                                [dynamic]Nostr_Emoji_Item,
	signed:                                               Sticker_Event,
}
@(private)
Emoji_Set_Operation :: enum {
	Browse,
	Cover,
	Preview,
	Import,
}
@(private)
Emoji_Set_Job :: struct {
	op:                        Emoji_Set_Operation,
	progress, total:           int,
	published:                 int, // UI-owned; progress publishes worker-owned images
	worker:                    ^thread.Thread,
	set:                       Nostr_Emoji_Set,
	sets:                      [dynamic]Nostr_Emoji_Set,
	contacts:                  [dynamic]Contact_Ui,
	client:                    ^marmot.Client,
	account:                   string,
	relays:                    [dynamic]string,
	directory:                 string,
	index:                     int,
	item_index:                int, // -1 imports the whole set
	imported, skipped, failed: int,
	error:                     string,
}
@(private)
Emoji_Set_File :: struct {
	name, code, url: string,
}
@(private)
Emoji_Set_Manifest :: struct {
	event: Sticker_Event,
	files: [dynamic]Emoji_Set_File,
}
@(private)
Emoji_Source :: struct {
	name, title, author, coordinate: string,
}
@(private)
emoji_sources: [dynamic]Emoji_Source

@(private, default_calling_convention = "c")
foreign _ {
	wn_ws_fetch_many :: proc(url: cstring, req: cstring, out: [^]u8, cap: c.size_t, timeout_ms: c.long, max_events: c.size_t) -> c.int ---
}

// NIP-30's alphabet is also a safe basename, but a d tag is never a path.
@(private)
emoji_set_code_ok :: proc(code: string) -> bool {
	if len(code) == 0 || len(code) > 64 {return false}
	for c in code {
		if !(c >= 'a' && c <= 'z' ||
			   c >= 'A' && c <= 'Z' ||
			   c >= '0' && c <= '9' ||
			   c == '_' ||
			   c == '-') {return false}
	}
	return true
}

@(private)
emoji_set_filename_ok :: proc(name, code: string) -> bool {
	if !emoji_set_code_ok(code) {return false}
	for ext in ([]string{".png", ".jpg", ".gif", ".webp"}) {
		if name == fmt.tprintf("%s%s", code, ext) {return true}
	}
	return false
}

@(private)
emoji_event_clone :: proc(event: Sticker_Event) -> Sticker_Event {
	result := event
	result.id = strings.clone(event.id); result.pubkey = strings.clone(event.pubkey)
	result.sig = strings.clone(event.sig); result.content = strings.clone(event.content)
	result.tags = make([][]string, len(event.tags))
	for tag, i in event.tags {
		result.tags[i] = make([]string, len(tag))
		for value, j in tag {result.tags[i][j] = strings.clone(value)}
	}
	return result
}

@(private)
emoji_event_free :: proc(event: Sticker_Event) {
	delete(event.id); delete(event.pubkey); delete(event.sig); delete(event.content)
	for tag in event.tags {for value in tag {delete(value)}; delete(tag)}
	delete(event.tags)
}

// Called only after signature verification; first d/title/description and code win.
@(private)
emoji_set_parse :: proc(event: Sticker_Event, relay: string) -> (set: Nostr_Emoji_Set, ok: bool) {
	if event.kind != EMOJI_SET_KIND ||
	   !sticker_hex(event.id) ||
	   !sticker_hex(event.pubkey) {return}
	d, title, description: string
	has_d, has_title, has_description: bool
	for tag in event.tags {
		if len(tag) < 2 {continue}
		switch tag[0] {
		case "d":
			if !has_d {d = tag[1]; has_d = true}
		case "title":
			if !has_title {title = tag[1]; has_title = true}
		case "description":
			if !has_description {description = tag[1]; has_description = true}
		}
	}
	if !has_d || len(d) > 1024 {return}
	if title == "" || len(title) > 512 {title = d}
	if title == "" {title = N_("Untitled emoji set")}
	if len(description) > 4096 {description = ""}
	set = {
		coordinate  = fmt.aprintf("30030:%s:%s", event.pubkey, d),
		title       = strings.clone(title),
		sort_title  = strings.to_lower(title),
		author      = strings.clone(event.pubkey),
		event       = strings.clone(event.id),
		relay       = strings.clone(relay),
		description = strings.clone(description),
		created_at  = event.created_at,
		signed      = emoji_event_clone(event),
	}
	seen := make(map[string]bool, context.temp_allocator)
	for tag in event.tags {
		if len(tag) < 3 ||
		   tag[0] != "emoji" ||
		   !emoji_set_code_ok(tag[1]) ||
		   !strings.has_prefix(tag[2], "https://") ||
		   len(tag[2]) > 2048 ||
		   seen[tag[1]] {continue}
		seen[tag[1]] = true
		append(
			&set.items,
			Nostr_Emoji_Item{code = strings.clone(tag[1]), url = strings.clone(tag[2])},
		)
		if len(set.items) == EMOJI_SET_ITEMS {break}
	}
	slice.sort_by(set.items[:], proc(a, b: Nostr_Emoji_Item) -> bool {return a.code < b.code})
	return set, true
}

@(private)
emoji_set_free :: proc(set: Nostr_Emoji_Set) {
	for value in ([]string{set.coordinate, set.title, set.author, set.event, set.relay, set.description}) {delete(value)}
	delete(set.sort_title)
	emoji_event_free(set.signed)
	for item in set.items {
		delete(item.code); delete(item.url)
		if item.image.data != nil {rl.UnloadImage(item.image)}
		if item.texture != nil {rl.UnloadTexture(item.texture^); free(item.texture)}
	}
	delete(set.items)
}

@(private)
emoji_set_newer :: proc(a, b: Nostr_Emoji_Set) -> bool {
	return a.created_at == b.created_at ? a.event < b.event : a.created_at > b.created_at
}

@(private)
emoji_set_merge :: proc(sets: ^[dynamic]Nostr_Emoji_Set, set: Nostr_Emoji_Set) {
	for &old in sets^ {
		if old.coordinate != set.coordinate {continue}
		if emoji_set_newer(set, old) {emoji_set_free(old); old = set} else {emoji_set_free(set)}
		return
	}
	append(sets, set)
}

@(private)
emoji_sets_fetch :: proc(job: ^Emoji_Set_Job) {
	snapshot := Ui_State {
		account_ref = job.account,
	}
	if !load_contacts(job.client, &snapshot, .Picker) {
		job.error = N_("Couldn't load your contacts. Please try again.")
		return
	}
	job.contacts = snapshot.contacts
	buffer := make([]u8, EMOJI_ASSET_LIMIT, context.temp_allocator)
	for relay, i in job.relays {
		n := wn_ws_fetch_many(
			strings.clone_to_cstring(relay, context.temp_allocator),
			`["REQ","wn",{"kinds":[30030],"limit":60}]`,
			raw_data(buffer),
			uint(len(buffer)),
			3000,
			EMOJI_SET_LIMIT,
		)
		if n > 0 && int(n) <= len(buffer) {
			for line in strings.split_lines(string(buffer[:n]), context.temp_allocator) {
				if len(line) > NEV_MAX {continue}
				value, err := json.parse(transmute([]u8)line, allocator = context.temp_allocator)
				if err != nil {continue}
				arr, ok := value.(json.Array)
				if !ok || len(arr) != 3 {continue}
				kind, _ := arr[0].(json.String); subscription, _ := arr[1].(json.String)
				if kind != "EVENT" || subscription != "wn" {continue}
				encoded, encode_err := json.marshal(arr[2], allocator = context.temp_allocator)
				if encode_err != nil {continue}
				event: Sticker_Event
				if json.unmarshal(encoded, &event, allocator = context.temp_allocator) != nil ||
				   !sticker_event_valid(event) {continue}
				set, valid := emoji_set_parse(event, relay)
				if valid {emoji_set_merge(&job.sets, set)}
			}
		}
		sync.atomic_store(&job.progress, i + 1)
		frame_wake()
	}
	slice.sort_by(job.sets[:], proc(a, b: Nostr_Emoji_Set) -> bool {
		if a.created_at != b.created_at {return a.created_at > b.created_at}
		if a.event != b.event {return a.event < b.event}
		return a.coordinate < b.coordinate
	})
	for len(job.sets) > EMOJI_SET_LIMIT {emoji_set_free(pop(&job.sets))}
	slice.sort_by(job.sets[:], proc(a, b: Nostr_Emoji_Set) -> bool {
		if a.sort_title != b.sort_title {return a.sort_title < b.sort_title}
		return a.coordinate < b.coordinate
	})
	if len(job.sets) ==
	   0 {job.error = N_("No emoji sets found. Check your fetch relays and try again.")}
}

// Sniff supported formats rather than trusting a URL suffix or MIME header.
@(private)
emoji_asset_image :: proc(bytes: []u8) -> (image: rl.Image, ext: string) {
	if len(bytes) < 12 || len(bytes) > EMOJI_ASSET_LIMIT {return}
	switch {
	case string(bytes[:8]) == "\x89PNG\r\n\x1a\n":
		ext = ".png"
	case bytes[0] == 0xff && bytes[1] == 0xd8:
		ext = ".jpg"
	case string(bytes[:6]) == "GIF87a" || string(bytes[:6]) == "GIF89a":
		ext = ".gif"
	case string(bytes[:4]) == "RIFF" && string(bytes[8:12]) == "WEBP":
		ext = ".webp"
	case:
		return
	}
	image = rl.LoadImageFromMemory(
		"",
		raw_data(bytes),
		i32(len(bytes)),
		max_dimension = 4096,
		max_bytes = 64 * 1024 * 1024,
	)
	if image.data == nil ||
	   image.width <= 0 ||
	   image.height <= 0 ||
	   image.width > 4096 ||
	   image.height > 4096 {
		if image.data != nil {rl.UnloadImage(image)}
		return {}, ""
	}
	return
}

@(private)
emoji_manifest_load :: proc(
	directory, event_id: string,
) -> (
	manifest: Emoji_Set_Manifest,
	ok: bool,
) {
	if !sticker_hex(event_id) {return}
	path := fmt.tprintf("%s/sets/%s/source.json", directory, event_id)
	file, err := os.open(path)
	if err != nil {return}
	defer os.close(file)
	size, size_err := os.file_size(file)
	if size_err != nil || size <= 0 || size > NEV_MAX {return}
	bytes := make([]u8, int(size), context.temp_allocator)
	n, read_err := os.read(file, bytes)
	if read_err != nil ||
	   n != len(bytes) ||
	   json.unmarshal(bytes, &manifest, allocator = context.temp_allocator) != nil ||
	   manifest.event.id != event_id ||
	   manifest.event.kind != EMOJI_SET_KIND ||
	   !sticker_event_valid(manifest.event) ||
	   len(manifest.files) > EMOJI_SET_ITEMS {return {}, false}
	set, valid := emoji_set_parse(manifest.event, "")
	if !valid {return {}, false}
	defer emoji_set_free(set)
	seen := make(map[string]bool, context.temp_allocator)
	urls := make(map[string]string, context.temp_allocator)
	for item in set.items {urls[item.code] = item.url}
	for file in manifest.files {
		if !emoji_set_filename_ok(file.name, file.code) || seen[file.code] {return {}, false}
		seen[file.code] = true
		if url, found := urls[file.code]; !found || url != file.url {return {}, false}
	}
	return manifest, true
}

@(private)
emoji_sources_clear :: proc() {
	for source in emoji_sources {delete(source.name); delete(source.title); delete(source.author); delete(source.coordinate)}
	delete(emoji_sources); emoji_sources = {}
}

@(private)
emoji_source_for :: proc(name: string) -> (title, author, coordinate: string) {
	for source in emoji_sources {if source.name == name {return source.title, source.author, source.coordinate}}
	return
}

// Deterministic local precedence, then event-id order. Only manifest-tracked
// regular files are exposed; neither relay identifiers nor metadata are paths.
@(private)
emoji_scan_files :: proc(
	directory: string,
	names: ^[dynamic]string,
	sources: ^[dynamic]Emoji_Source = nil,
) {
	dir, err := os.open(directory)
	if err != nil {return}
	defer os.close(dir)
	entries, read_err := os.read_dir(dir, -1, context.temp_allocator)
	if read_err != nil {return}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	seen := make(map[string]bool, context.temp_allocator)
	for entry in entries {
		if entry.type != .Regular || !emoji_set_code_ok(emoji_code(entry.name)) {continue}
		append(names, strings.clone(entry.name)); seen[emoji_code(entry.name)] = true
	}
	for builtin in BUILTIN_EMOJI {seen[builtin.code] = true}
	sets_dir, sets_err := os.open(fmt.tprintf("%s/sets", directory))
	if sets_err != nil {return}
	defer os.close(sets_dir)
	sets, sets_read_err := os.read_dir(sets_dir, -1, context.temp_allocator)
	if sets_read_err != nil {return}
	slice.sort_by(sets, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in sets {
		if entry.type != .Directory || !sticker_hex(entry.name) {continue}
		manifest, valid := emoji_manifest_load(directory, entry.name)
		if !valid {continue}
		set, _ := emoji_set_parse(manifest.event, "")
		defer emoji_set_free(set)
		folder, folder_err := os.open(fmt.tprintf("%s/sets/%s", directory, entry.name))
		if folder_err != nil {continue}
		files, files_err := os.read_dir(folder, -1, context.temp_allocator)
		os.close(folder)
		if files_err != nil {continue}
		regular := make(map[string]bool, context.temp_allocator)
		for disk in files {if disk.type == .Regular {regular[disk.name] = true}}
		slice.sort_by(
			manifest.files[:],
			proc(a, b: Emoji_Set_File) -> bool {return a.name < b.name},
		)
		for file in manifest.files {
			if seen[file.code] {continue}
			if !regular[file.name] {continue}
			seen[file.code] = true
			name := fmt.aprintf("sets/%s/%s", entry.name, file.name)
			append(names, name)
			if sources != nil {
				append(
					sources,
					Emoji_Source {
						strings.clone(name),
						strings.clone(set.title),
						strings.clone(set.author),
						strings.clone(set.coordinate),
					},
				)
			}
		}
	}
}

@(private)
emoji_manifest_write :: proc(path: string, manifest: Emoji_Set_Manifest) -> bool {
	bytes, err := json.marshal(manifest, allocator = context.temp_allocator)
	if err != nil || len(bytes) > NEV_MAX {return false}
	next := fmt.tprintf("%s.next", path)
	if os.write_entire_file(next, bytes, {.Read_User, .Write_User}) !=
	   nil {os.remove(next); return false}
	if os.rename(next, path) != nil {os.remove(next); return false}
	return true
}

// Record the immutable signed source before publishing the asset. A crash can
// leave a missing recorded asset (ignored on scan), never an unattributed one.
@(private)
emoji_import_asset :: proc(
	directory: string,
	set: Nostr_Emoji_Set,
	item: Nostr_Emoji_Item,
	bytes: []u8,
	ext: string,
) -> bool {
	if !sticker_hex(set.event) ||
	   !emoji_set_filename_ok(fmt.tprintf("%s%s", item.code, ext), item.code) {return false}
	folder := fmt.tprintf("%s/sets/%s", directory, set.event)
	for path in ([]string{directory, fmt.tprintf("%s/sets", directory), folder}) {
		if err := os.make_directory(path); err != nil && err != .Exist {return false}
	}
	name := fmt.tprintf("%s%s", item.code, ext)
	path := fmt.tprintf("%s/%s", folder, name)
	if os.exists(path) {return false}
	manifest, loaded := emoji_manifest_load(directory, set.event)
	if !loaded {
		if os.exists(fmt.tprintf("%s/source.json", folder)) {return false}
		manifest.event = set.signed
		manifest.files = make([dynamic]Emoji_Set_File, context.temp_allocator)
	}
	// Recover a recorded-but-missing file from an interrupted earlier import.
	for file, i in manifest.files {
		if file.code == item.code {ordered_remove(&manifest.files, i); break}
	}
	append(&manifest.files, Emoji_Set_File{name, item.code, item.url})
	next := fmt.tprintf("%s.next", path)
	if os.write_entire_file(next, bytes, {.Read_User, .Write_User}) !=
	   nil {os.remove(next); return false}
	if !emoji_manifest_write(
		fmt.tprintf("%s/source.json", folder),
		manifest,
	) {os.remove(next); return false}
	if os.rename(next, path) != nil {os.remove(next); return false}
	return true
}

@(private)
emoji_sets_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Emoji_Set_Job)(t.data)
	if job.op == .Browse {emoji_sets_fetch(job); return}
	existing: [dynamic]string
	if job.op == .Import {emoji_scan_files(job.directory, &existing)}
	defer {for name in existing {delete(name)}; delete(existing)}
	codes := make(map[string]bool, context.temp_allocator)
	for name in existing {codes[emoji_code(name)] = true}
	for builtin in BUILTIN_EMOJI {codes[builtin.code] = true}
	buffer := make([]u8, EMOJI_ASSET_LIMIT, context.temp_allocator)
	processed := 0
	for &item, i in job.set.items {
		if job.op == .Import && job.item_index >= 0 && i != job.item_index {continue}
		if job.op == .Cover && i >= 3 {break}
		if job.op == .Import && codes[item.code] {
			job.skipped += 1
		} else {
			n := wn_https_get(
				strings.clone_to_cstring(item.url, context.temp_allocator),
				raw_data(buffer),
				uint(len(buffer)),
				HTTPS_TIMEOUT_MS,
			)
			image: rl.Image
			ext: string
			if n > 0 && int(n) <= len(buffer) {image, ext = emoji_asset_image(buffer[:n])}
			if image.data == nil {
				job.failed += 1
			} else if job.op == .Import {
				rl.UnloadImage(image)
				if emoji_import_asset(
					job.directory,
					job.set,
					item,
					buffer[:n],
					ext,
				) {job.imported += 1} else {job.failed += 1}
			} else {
				item.image = image_fit(image, 256)
				if item.image.data == nil {job.failed += 1}
			}
		}
		processed += 1
		sync.atomic_store(&job.progress, processed)
		frame_wake()
		if job.op == .Cover && item.image.data != nil {break}
	}
}

@(private)
emoji_sets_job_start :: proc(
	ui: ^Ui_State,
	op: Emoji_Set_Operation,
	index: int = -1,
	item_index: int = -1,
) {
	if ui.emoji_sets_job != nil {return}
	if op != .Browse && (index < 0 || index >= len(ui.emoji_sets)) {return}
	if item_index < -1 ||
	   (item_index >= 0 &&
			   (op != .Import || item_index >= len(ui.emoji_sets[index].items))) {return}
	job := new(Emoji_Set_Job)
	job.op, job.index = op, index
	job.item_index = item_index
	job.directory = strings.clone(emoji_dir())
	if op == .Browse {
		job.client = g_client
		job.account = strings.clone(ui.account_ref)
		for relay in ui.prefs.fetch_relays {
			if !strings.has_prefix(relay, "wss://") ||
			   slice.contains(job.relays[:], relay) {continue}
			append(&job.relays, strings.clone(relay))
			if len(job.relays) == 4 {break}
		}
		sync.atomic_store(&job.total, len(job.relays))
	} else {
		job.set, _ = emoji_set_parse(ui.emoji_sets[index].signed, ui.emoji_sets[index].relay)
		sync.atomic_store(&job.total, item_index >= 0 ? 1 : len(job.set.items))
		if op == .Preview {
			for &item in ui.emoji_sets[index].items {item.preview_done = false}
		}
	}
	delete(ui.emoji_sets_notice); ui.emoji_sets_notice = ""
	ui.emoji_sets_error = ""
	ui.emoji_sets_job = job
	job.worker = thread.create(emoji_sets_worker)
	job.worker.data = job
	thread.start(job.worker)
}

@(private)
emoji_sets_job_free :: proc(job: ^Emoji_Set_Job) {
	emoji_set_free(job.set)
	for set in job.sets {emoji_set_free(set)}
	delete(job.sets)
	nc_contacts_free(&job.contacts)
	delete(job.account)
	for relay in job.relays {delete(relay)}
	delete(job.relays); delete(job.directory); free(job)
}

@(private)
emoji_sets_drain :: proc(ui: ^Ui_State) {
	emoji_covers_drain(ui)
	job := ui.emoji_sets_job
	if job == nil {return}
	done := thread.is_done(job.worker)
	if done {thread.join(job.worker)}
	if job.op == .Preview &&
	   job.index >= 0 &&
	   job.index < len(ui.emoji_sets) &&
	   ui.emoji_sets[job.index].event == job.set.event {
		// The atomic completed count makes each preceding image immutable.
		// Only the UI creates textures and consumes those completed images.
		completed := sync.atomic_load(&job.progress)
		for i in job.published ..< completed {
			item := &job.set.items[i]
			target := &ui.emoji_sets[job.index].items[i]
			target.preview_done = true
			if item.image.data == nil {continue}
			if target.texture != nil {rl.UnloadTexture(target.texture^); free(target.texture)}
			target.texture = new(rl.Texture2D)
			target.texture^ = rl.LoadTextureFromImage(item.image)
			rl.SetTextureFilter(target.texture^, .BILINEAR)
			rl.UnloadImage(item.image); item.image = {}
		}
		job.published = completed
	}
	if !done {return}
	thread.destroy(job.worker)
	ui.emoji_sets_job = nil
	ui.emoji_sets_error = job.error
	switch job.op {
	case .Cover:
	case .Browse:
		if ui.account_ref == job.account && job.error == "" {
			selected_hex: string
			if ui.selected_contact >= 0 &&
			   ui.selected_contact <
				   len(
					   ui.contacts,
				   ) {selected_hex = strings.clone(ui.contacts[ui.selected_contact].id_hex, context.temp_allocator)}
			nc_contacts_free(&ui.contacts)
			ui.contacts, job.contacts = job.contacts, nil
			ui.selected_contact = -1
			for contact, i in ui.contacts {if contact.id_hex == selected_hex {ui.selected_contact = i; break}}
		}
		for set in ui.emoji_sets {emoji_set_free(set)}
		delete(ui.emoji_sets)
		ui.emoji_sets, job.sets = job.sets, nil
		ui.emoji_sets_selected = -1
		ui.emoji_sets_page = 0
		clear(&ui.emoji_sets_order)
	case .Preview:
		if job.index >= 0 &&
		   job.index < len(ui.emoji_sets) &&
		   ui.emoji_sets[job.index].event == job.set.event {
			ui.emoji_sets[job.index].cover_done = true
		}
		if job.failed >
		   0 {ui.emoji_sets_notice = fmt.aprintf(tr("%d emoji previews couldn't be loaded."), job.failed)}
	case .Import:
		custom_emoji_scan()
		ui.emoji_sets_notice = fmt.aprintf(
			tr("Imported %d emoji; skipped %d existing shortcodes; failed %d."),
			job.imported,
			job.skipped,
			job.failed,
		)
	}
	emoji_sets_job_free(job)
}

// List artwork has its own worker so selecting or importing a set never
// waits behind other sets' image hosts. Failed covers keep a placeholder.
@(private)
emoji_covers_drain :: proc(ui: ^Ui_State) {
	if job := ui.emoji_sets_cover; job != nil {
		if !thread.is_done(job.worker) {return}
		thread.join(job.worker); thread.destroy(job.worker)
		ui.emoji_sets_cover = nil
		if job.index < len(ui.emoji_sets) && ui.emoji_sets[job.index].event == job.set.event {
			for item, i in job.set.items {
				if item.image.data == nil {continue}
				target := &ui.emoji_sets[job.index].items[i]
				if target.texture != nil {continue}
				target.texture = new(rl.Texture2D)
				target.texture^ = rl.LoadTextureFromImage(item.image)
				rl.SetTextureFilter(target.texture^, .BILINEAR)
			}
		}
		emoji_sets_job_free(job)
	}
	if !ui.emoji_sets_open ||
	   (ui.emoji_sets_job != nil && ui.emoji_sets_job.op == .Browse) {return}
	for i in ui.emoji_sets_order {
		if i >= len(ui.emoji_sets) {continue}
		set := &ui.emoji_sets[i]
		if set.cover_done {continue}
		set.cover_done = true
		job := new(Emoji_Set_Job)
		job.op, job.index = .Cover, i
		job.set.event = strings.clone(set.event)
		for item in set.items[:min(3, len(set.items))] {
			append(
				&job.set.items,
				Nostr_Emoji_Item{code = strings.clone(item.code), url = strings.clone(item.url)},
			)
		}
		ui.emoji_sets_cover = job
		job.worker = thread.create(emoji_sets_worker)
		job.worker.data = job
		thread.start(job.worker)
		return
	}
}

@(private)
emoji_sets_order :: proc(ui: ^Ui_State) {
	if ui.emoji_sets_contacts == nil {ui.emoji_sets_contacts = make(map[string]bool)}
	clear(&ui.emoji_sets_contacts)
	for contact in ui.contacts {ui.emoji_sets_contacts[contact.id_hex] = true}
	clear(&ui.emoji_sets_order)
	// Discovery is already A-Z. Stable partitions keep contacts first without
	// moving set storage underneath preview/import jobs.
	for set, i in ui.emoji_sets {
		if ui.emoji_sets_contacts[set.author] {append(&ui.emoji_sets_order, i)}
	}
	if ui.prefs.emoji_contacts_only {return}
	for set, i in ui.emoji_sets {
		if !ui.emoji_sets_contacts[set.author] {append(&ui.emoji_sets_order, i)}
	}
}

@(private)
emoji_sets_stop :: proc(ui: ^Ui_State) {
	if job := ui.emoji_sets_cover; job != nil {
		thread.join(job.worker); thread.destroy(job.worker)
		emoji_sets_job_free(job); ui.emoji_sets_cover = nil
	}
	if ui.emoji_sets_job != nil {
		thread.join(ui.emoji_sets_job.worker); thread.destroy(ui.emoji_sets_job.worker)
		emoji_sets_job_free(ui.emoji_sets_job); ui.emoji_sets_job = nil
	}
	for set in ui.emoji_sets {emoji_set_free(set)}
	delete(ui.emoji_sets); ui.emoji_sets = {}
	delete(ui.emoji_sets_contacts); ui.emoji_sets_contacts = nil
	delete(ui.emoji_sets_order); ui.emoji_sets_order = {}
	ui.emoji_sets_page = 0
	delete(ui.emoji_sets_query); ui.emoji_sets_query = {}
	delete(ui.emoji_sets_notice); ui.emoji_sets_notice = ""
	ui.emoji_sets_error = ""; ui.emoji_sets_selected = -1; ui.emoji_sets_open = false
	emoji_sources_clear()
}
