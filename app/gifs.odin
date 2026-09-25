package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import rl "sdlrl"

@(private)
GIF_BYTES_LIMIT :: 24 * 1024 * 1024
@(private)
GIF_PAGE_SIZE :: 24
@(private)
GIF_SEARCH_DELAY :: f64(0.3)
@(private)
Gif_Item :: struct {
	title, url, thumb, sha: string,
	width, height:          int,
	failed:                 bool `json:"-"`,
}
@(private)
Gif_Action :: enum {
	Preview,
	Stage,
	Save,
}
@(private)
Gif_Op :: enum {
	Library,
	Search,
	Preview,
	Save,
	Remove,
}
@(private)
Gif_Job :: struct {
	op:                  Gif_Op,
	worker:              ^thread.Thread,
	item:                Gif_Item,
	input, query, error: string,
	data, index:         []u8,
	items:               [dynamic]Gif_Item,
	view:                ^Video_View,
	page:                int,
	more:                bool,
	action:              Gif_Action,
}

@(private)
gif_item_free :: proc(item: Gif_Item) {
	delete(item.title); delete(item.url); delete(item.thumb); delete(item.sha)
}

@(private)
gif_item_clone :: proc(item: Gif_Item) -> Gif_Item {
	return {
		strings.clone(item.title),
		strings.clone(item.url),
		strings.clone(item.thumb),
		strings.clone(item.sha),
		item.width,
		item.height,
		item.failed,
	}
}

@(private)
gif_asset_url :: proc(url: string) -> bool {
	scheme, host, _, _, _ := net.split_url(url, context.temp_allocator)
	return(
		scheme == "https" &&
		(host == "gifsnap.com" || host == "pub-9502c4126a384b90aa92ed45d7f6c379.r2.dev") \
	)
}

@(private)
gif_parse :: proc(bytes: []u8) -> (items: [dynamic]Gif_Item, more, ok: bool) {
	Response :: struct {
		data:       []struct {
			title, url, preview_url: string,
			width, height:           int,
		},
		pagination: struct {
			page:     int,
			has_next: bool,
		},
	}
	response: Response
	if json.unmarshal(bytes, &response, allocator = context.temp_allocator) != nil ||
	   response.pagination.page < 1 {return}
	for hit in response.data[:min(len(response.data), GIF_PAGE_SIZE)] {
		if !gif_asset_url(hit.url) || !gif_asset_url(hit.preview_url) {continue}
		append(
			&items,
			Gif_Item {
				title = strings.clone(hit.title),
				url = strings.clone(hit.url),
				thumb = strings.clone(hit.preview_url),
				width = hit.width,
				height = hit.height,
			},
		)
	}
	return items, response.pagination.has_next, true
}

// Reject oversized logical canvases before either image decoder sees the bytes.
@(private)
gif_valid :: proc(bytes: []u8) -> bool {
	if len(bytes) < 13 || len(bytes) > GIF_BYTES_LIMIT {return false}
	if string(bytes[:6]) != "GIF87a" && string(bytes[:6]) != "GIF89a" {return false}
	w, h := int(bytes[6]) | int(bytes[7]) << 8, int(bytes[8]) | int(bytes[9]) << 8
	return w > 0 && h > 0 && w <= 4096 && h <= 4096 && w * h <= 4096 * 4096
}

// iOS shares a direct GIF URL followed by attribution, not an imeta attachment.
@(private)
giphy_message_url :: proc(body: string) -> string {
	text := strings.trim_space(body)
	end, url, ok := url_at(text, 0)
	if !ok ||
	   !strings.has_prefix(url, "https://") ||
	   end == len(text) ||
	   text[end] > ' ' ||
	   strings.trim_space(text[end:]) != "via GIPHY" {return ""}
	host := url_host(url)
	if host != "media.giphy.com" {
		if !strings.has_prefix(host, "media") ||
		   !strings.has_suffix(host, ".giphy.com") {return ""}
		number := host[len("media"):len(host) - len(".giphy.com")]
		if len(number) == 0 {return ""}
		for digit in number {
			if digit < '0' || digit > '9' {return ""}
		}
	}
	path := url[len("https://") + len(host):]
	if cut := strings.index_any(path, "?#"); cut >= 0 {path = path[:cut]}
	if !strings.has_prefix(path, "/media/") || !strings.has_suffix(path, ".gif") {return ""}
	return url
}

@(private)
giphy_message :: proc(index: u32, body: string) -> bool {
	if g_ui != nil && g_ui.prefs.disable_link_previews {
		return false
	}
	url := giphy_message_url(body)
	if url == "" {return false}
	cached, seen := media_cached(.Loop, url)
	if !seen && !media_inflight[Media_Key{url, .Loop}] {
		job := new(Media_Job)
		job^ = {
			key          = strings.clone(url),
			kind         = .Loop,
			external_gif = true,
			queued_at    = time.tick_now(),
		}
		media_inflight[Media_Key{job.key, .Loop}] = true
		append(&media_jobs, job)
	}
	view := (^Video_View)(cached)
	if view == nil || view.failed || view.w <= 0 || view.h <= 0 {return false}
	ratio := f32(view.w) / f32(view.h)
	if clay.UI(clay.ID("MsgGiphy", index))(
	{
		layout = {sizing = {width = clay.SizingFixed(min(att_w(), 320 * ratio))}},
		aspectRatio = {ratio},
		image = {imageData = &view.tex},
		cornerRadius = rr(8),
	},
	) {
		if hovered() {video_hover = view}
	}
	if clay.UI(clay.ID("MsgGiphySource", index))({}) {
		clay.Text(
			strings.trim_space(strings.trim_space(body)[len(url):]),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		if hovered() {link_hover = url}
	}
	return true
}

@(private)
gif_path :: proc(sha: string) -> string {
	assert(sticker_hex(sha))
	return fmt.tprintf("%s/gifs/%s.bin", data_home, sha)
}

@(private)
gif_read :: proc(sha: string) -> []u8 {
	if !sticker_hex(sha) {return nil}
	sealed, err := os.read_entire_file(gif_path(sha), context.temp_allocator)
	if err != nil {return nil}
	data, ok := vault_open_blob(sealed)
	if !ok {return nil}
	actual := string(
		hex.encode(hash.hash_bytes(.SHA256, data, context.temp_allocator), context.temp_allocator),
	)
	if actual != sha || !gif_valid(data) {delete(data); return nil}
	return data
}

@(private)
gif_start :: proc(ui: ^Ui_State, op: Gif_Op) -> ^Gif_Job {
	assert(ui.gif_job == nil)
	job := new(Gif_Job)
	job.op = op
	ui.gif_job, ui.gif_error = job, ""
	// Start on the next drain, after the caller fills the immutable inputs.
	return job
}

@(private)
gif_open :: proc(ui: ^Ui_State) {
	ui.gif_focus = -1
	ui.gif_hover = -1
	if ui.gif_job == nil && !ui.gif_loaded {gif_start(ui, .Library)}
	if ui.gif_job == nil && !ui.gif_saved && len(ui.gif_hits) == 0 {gif_search(ui)}
}

@(private)
gif_search :: proc(ui: ^Ui_State, page := 1) {
	if ui.gif_job != nil {return}
	query := strings.trim_space(string(ui.picker_filter[:]))
	if len(query) > 512 {ui.gif_due = 0; ui.gif_error = N_("Use a shorter search."); return}
	job := gif_start(ui, .Search)
	ui.gif_due = 0
	delete(ui.gif_filter); ui.gif_filter = strings.clone(string(ui.picker_filter[:]))
	job.query = strings.clone(query)
	job.page = max(1, page)
	job.input = fmt.aprintf(
		"https://gifsnap.com/api/v1/gifs/%s?q=%s&limit=%d&page=%d",
		query == "" ? "trending" : "search",
		net.percent_encode(query, context.temp_allocator),
		GIF_PAGE_SIZE,
		job.page,
	)
	if page == 1 {
		for item in ui.gif_hits {gif_item_free(item)}
		clear(&ui.gif_hits)
		ui.gif_focus = -1
		ui.gif_hover = -1
		ui.gif_page = 0
	}
	ui.gif_more = false
}

@(private)
gif_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Gif_Job)(t.data)
	index_path := fmt.tprintf("%s/gifs/library.bin", data_home)
	switch job.op {
	case .Search:
		buffer := make([]u8, 2 * 1024 * 1024, context.temp_allocator)
		n := wn_https_get(
			strings.clone_to_cstring(job.input, context.temp_allocator),
			raw_data(buffer),
			uint(len(buffer)),
		)
		ok: bool
		if n > 0 {job.items, job.more, ok = gif_parse(buffer[:n])}
		if !ok {job.error = N_("Couldn't search GIFs. Please try again.")}
	case .Library:
		sealed, err := os.read_entire_file(index_path, context.temp_allocator)
		if err == .Not_Exist {return}
		job.error = N_("Couldn't load your GIFs. Please try again.")
		if err != nil {return}
		plain, ok := vault_open_blob(sealed, context.temp_allocator)
		if !ok || json.unmarshal(plain, &job.items) != nil {return}
		job.error = ""
	case .Preview:
		job.error = N_("Couldn't load GIFs. Please try again.")
		if job.item.sha != "" {
			job.data = gif_read(job.item.sha)
		} else if gif_asset_url(job.item.url) {
			buffer := make([]u8, GIF_BYTES_LIMIT, context.temp_allocator)
			n := wn_https_get(
				strings.clone_to_cstring(job.item.url, context.temp_allocator),
				raw_data(buffer),
				uint(len(buffer)),
			)
			if n > 0 {job.data = slice.clone(buffer[:n])}
		}
		if !gif_valid(job.data) {return}
		job.view = video_view_make(job.data, .Loop, .Prepare)
		job.data = nil
		if job.view.failed {return}
		job.error = ""
	case .Save:
		if !media_write_sealed(gif_path(job.item.sha), job.data) ||
		   !media_write_sealed(index_path, job.index) {
			job.error = N_("Couldn't save the GIF. Please try again."); return
		}
	case .Remove:
		if !media_write_sealed(
			index_path,
			job.index,
		) {job.error = N_("Couldn't remove the GIF. Please try again."); return}
		if err := os.remove(gif_path(job.item.sha)); err != nil && err != .Not_Exist {
			job.error = N_("Couldn't remove the saved file. Please try again.")
		}
	}
}

@(private)
gif_job_free :: proc(job: ^Gif_Job) {
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	gif_item_free(
		job.item,
	); delete(job.input); delete(job.query); delete(job.data); delete(job.index)
	for item in job.items {gif_item_free(item)}
	delete(job.items)
	if job.view != nil {video_view_free(job.view)}
	free(job)
}

@(private)
gif_hide :: proc(ui: ^Ui_State, failed: Gif_Item) {
	for &item in ui.gif_hits {if gif_same(item, failed) {item.failed = true}}
	for &item in ui.gif_library {if gif_same(item, failed) {item.failed = true}}
}

@(private)
gif_drain :: proc(ui: ^Ui_State) {
	if ui.gif_view != nil && ui.gif_view.failed {
		gif_hide(ui, ui.gif_selected)
		video_view_free(ui.gif_view); ui.gif_view = nil
	}
	if ui.gif_view != nil && (!ui.picker_open || !ui.gif_tab) {
		video_view_free(ui.gif_view); ui.gif_view = nil
	}
	job := ui.gif_job
	if job == nil {
		if ui.gif_due > 0 &&
		   rl.GetTime() >= ui.gif_due &&
		   ui.picker_open &&
		   ui.gif_tab &&
		   !ui.gif_saved {gif_search(ui)}
		return
	}
	if job.worker == nil {
		job.worker = thread.create(
			gif_worker,
		); job.worker.data = job; thread.start(job.worker); return
	}
	if !thread.is_done(job.worker) {return}
	thread.join(job.worker)
	stale := job.op == .Search && job.query != strings.trim_space(string(ui.picker_filter[:]))
	if !stale {ui.gif_error = job.error}
	if job.op == .Preview && job.error != "" {
		gif_hide(ui, job.item)
		ui.gif_error = ""
	}
	if job.op == .Search && len(ui.gif_hits) > 0 {ui.gif_error = ""}
	if job.error == "" && !stale {
		switch job.op {
		case .Search:
			append(&ui.gif_hits, ..job.items[:])
			ui.gif_page, ui.gif_more = job.page, job.more && len(job.items) > 0
			clear(&job.items)
			if job.page == 1 && clay.GetCurrentContext() != nil {
				if scroll := clay.GetScrollContainerData(clay.ID("GifGrid"));
				   scroll.found {scroll.scrollPosition^ = {}}
			}
		case .Library:
			ui.gif_library, job.items = job.items, nil
			ui.gif_loaded = true
		case .Preview:
			if !ui.picker_open || !ui.gif_tab {break}
			if ui.gif_view != nil {video_view_free(ui.gif_view)}
			ui.gif_view, job.view = job.view, nil
			ui.gif_view.tex = rl.CreateStreamTexture(ui.gif_view.w, ui.gif_view.h)
			gif_item_free(ui.gif_selected); ui.gif_selected, job.item = job.item, {}
			sha := string(
				hex.encode(
					hash.hash_bytes(.SHA256, ui.gif_view.data, context.temp_allocator),
					context.temp_allocator,
				),
			)
			for item in ui.gif_library {
				if item.sha ==
				   sha {delete(ui.gif_selected.sha); ui.gif_selected.sha = strings.clone(sha); break}
			}
		case .Save:
			append(&ui.gif_library, gif_item_clone(job.item))
			delete(ui.gif_selected.sha); ui.gif_selected.sha = strings.clone(job.item.sha)
		case .Remove:
			for item, i in ui.gif_library {
				if item.sha != job.item.sha {continue}
				gif_item_free(item); ordered_remove(&ui.gif_library, i); break
			}
			if ui.gif_view != nil {video_view_free(ui.gif_view); ui.gif_view = nil}
			gif_item_free(ui.gif_selected); ui.gif_selected = {}
		}
	}
	action := job.action
	use_pick :=
		job.op == .Preview && job.error == "" && ui.gif_view != nil && ui.picker_open && ui.gif_tab
	load_trending :=
		job.op == .Library && job.error == "" && ui.picker_open && ui.gif_tab && !ui.gif_saved
	gif_job_free(job); ui.gif_job = nil
	if use_pick && action != .Preview {gif_choose(ui, ui.gif_selected, action)}
	if load_trending {gif_search(ui)}
}

@(private)
gif_save :: proc(ui: ^Ui_State, op: Gif_Op) {
	if ui.gif_job != nil || ui.gif_view == nil {return}
	if !ui.gif_loaded {ui.gif_error = N_("Couldn't load your GIFs. Please try again."); return}
	sha := string(
		hex.encode(
			hash.hash_bytes(.SHA256, ui.gif_view.data, context.temp_allocator),
			context.temp_allocator,
		),
	)
	items := make([dynamic]Gif_Item, context.temp_allocator)
	for item in ui.gif_library {
		if item.sha == sha {
			if op == .Save {return}
			continue
		}
		append(&items, item)
	}
	item := ui.gif_selected; item.sha = sha
	if op == .Save {append(&items, item)}
	index, err := json.marshal(items[:])
	if err != nil {ui.gif_error = N_("Couldn't save the GIF. Please try again."); return}
	job := gif_start(ui, op); job.index = index; job.item = gif_item_clone(item)
	if op == .Save {job.data = slice.clone(ui.gif_view.data)}
}

@(private)
gif_stop :: proc(ui: ^Ui_State) {
	ui.picker_open = false
	if job := ui.gif_job; job != nil {
		if job.worker == nil {gif_drain(ui)}
		thread.join(job.worker); gif_drain(ui)
	}
	if ui.gif_view != nil {video_view_free(ui.gif_view); ui.gif_view = nil}
	gif_item_free(ui.gif_selected)
	for item in ui.gif_hits {gif_item_free(item)}
	for item in ui.gif_library {gif_item_free(item)}
	delete(ui.gif_hits); delete(ui.gif_library)
	delete(ui.gif_filter)
}

@(private)
gif_matches :: proc(ui: ^Ui_State) -> []int {
	items := ui.gif_saved ? ui.gif_library[:] : ui.gif_hits[:]
	filter := strings.to_lower(string(ui.picker_filter[:]), context.temp_allocator)
	indices := make([dynamic]int, context.temp_allocator)
	for item, i in items {
		if item.failed {continue}
		if ui.gif_saved &&
		   filter != "" &&
		   !strings.contains(
				   strings.to_lower(item.title, context.temp_allocator),
				   filter,
			   ) {continue}
		append(&indices, i)
	}
	return indices[:]
}

@(private)
gif_same :: proc(a, b: Gif_Item) -> bool {
	if a.sha != "" && b.sha != "" {return a.sha == b.sha}
	return a.url != "" && a.url == b.url
}

@(private)
gif_choose :: proc(ui: ^Ui_State, item: Gif_Item, action: Gif_Action) {
	if ui.gif_job != nil {return}
	if action == .Stage &&
	   (ui.selected < 0 ||
			   ui.selected >= len(ui.chats) ||
			   ui.editing != "" ||
			   ui.compose_issue != "") {return}
	if ui.gif_view == nil || ui.gif_view.failed || !gif_same(item, ui.gif_selected) {
		job := gif_start(ui, .Preview); job.item = gif_item_clone(item); job.action = action
		return
	}
	switch action {
	case .Preview:
	case .Stage:
		stage_bytes(ui, "animation.gif", slice.clone(ui.gif_view.data))
		ui.picker_open = false; ui.focus = .Compose
		video_view_free(ui.gif_view); ui.gif_view = nil
	case .Save:
		gif_save(ui, ui.gif_selected.sha == "" ? .Save : .Remove)
	}
}

@(private)
gif_visible :: proc(index: int) -> bool {
	grid := clay.GetElementData(clay.ID("GifGrid"))
	tile := clay.GetElementData(clay.ID("GifTile", u32(index)))
	a, b := grid.boundingBox, tile.boundingBox
	return(
		grid.found &&
		tile.found &&
		b.y < a.y + a.height &&
		b.y + b.height > a.y &&
		b.x < a.x + a.width &&
		b.x + b.width > a.x \
	)
}

@(private)
gif_picker :: proc(ui: ^Ui_State) {
	width := modal_w(clay.ID("PickerPanel"), 560) - 24
	columns := width >= 440 ? 3 : 2
	cell := (width - f32(columns - 1) * 6) / f32(columns)
	input_box(ui, "PickerSearch", &ui.picker_filter, tr("Search GIFs"), ui.gif_focus < 0, 0)
	busy := ui.gif_job != nil || ui.gif_due > 0 && !ui.gif_saved
	if clay.UI(clay.ID("GifSources"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 16,
			childAlignment = {y = .Center},
		},
	},
	) {
		for saved, i in ([]bool{false, true}) {
			selected := ui.gif_saved == saved
			if clay.UI(clay.ID("GifSource", u32(i)))(
			{
				layout = {padding = {top = 4, bottom = 7}},
				border = {color = selected ? ACCENT : clay.Color{}, width = {bottom = 2}},
			},
			) {
				if hovered() {cursor_raise(.Pointer)}
				clay.Text(
					saved ? tr("Saved") : tr("Discover"),
					{fontId = FONT_BODY, fontSize = 13, textColor = selected ? TEXT : TEXT_DIM},
				)
			}
		}
		if clay.UI(clay.ID("GifSourceGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if busy {
			clay.Text(
				ui.gif_job == nil || ui.gif_job.op == .Search ? tr("Searching…") : tr("Loading…"),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
		}
	}
	items := ui.gif_saved ? ui.gif_library[:] : ui.gif_hits[:]
	matches := gif_matches(ui)
	// Queue in reading order, so the first visible rows load before lower columns.
	thumbs := make([]^rl.Texture2D, len(items), context.temp_allocator)
	loading := make([]bool, len(items), context.temp_allocator)
	for i in matches {thumbs[i], loading[i], items[i].failed = gif_thumb(items[i], i)}
	matches = gif_matches(ui)
	failed := 0
	for item in items {if item.failed {failed += 1}}
	all_failed := len(items) > 0 && failed == len(items) && (ui.gif_saved || !ui.gif_more)
	if ui.gif_error != "" && len(matches) > 0 {
		clay.Text(tr(ui.gif_error), {fontId = FONT_BODY, fontSize = 12, textColor = DANGER})
	}
	saved_urls := make(map[string]bool, context.temp_allocator)
	for item in ui.gif_library {if item.url != "" {saved_urls[item.url] = true}}
	if clay.UI(clay.ID("GifGrid"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = 6},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		if len(matches) == 0 && !busy {
			if clay.UI(clay.ID("GifEmpty"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					childAlignment = {x = .Center, y = .Center},
				},
			},
			) {
				clay.Text(
					ui.gif_error != "" ? tr(ui.gif_error) : all_failed ? tr("Couldn't load GIFs. Please try again.") : ui.gif_saved ? tr("Save GIFs with the star to find them here.") : tr("No GIFs found. Try another search."),
					{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
				)
			}
		}
		for column in 0 ..< columns {
			if len(matches) == 0 {break}
			if clay.UI(clay.ID("GifColumn", u32(column)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(cell)},
					layoutDirection = .TopToBottom,
					childGap = 6,
				},
			},
			) {
				for at := column; at < len(matches); at += columns {
					i := matches[at]; item := items[i]
					tex := thumbs[i]
					playing :=
						ui.gif_view != nil &&
						!ui.gif_view.failed &&
						gif_same(item, ui.gif_selected)
					if playing {tex = &ui.gif_view.tex}
					ratio :=
						item.width > 0 && item.height > 0 ? f32(item.width) / f32(item.height) : f32(1)
					height := clamp(cell / ratio, 72, 210)
					if clay.UI(clay.ID("GifTile", u32(i)))(
					{
						layout = {
							sizing = {clay.SizingFixed(cell), clay.SizingFixed(height)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = ROW_BG,
						cornerRadius = rr(7),
						border = {
							color = ui.gif_focus == at || hovered() ? ACCENT : clay.Color{},
							width = bw(),
						},
					},
					) {
						if hovered() {cursor_raise(.Pointer); tooltip(item.title)}
						if tex != nil && tex.width > 0 {
							if clay.UI(clay.ID_LOCAL("GifThumb"))(
							{
								layout = {
									sizing = {width = clay.SizingFixed(min(cell, height * ratio))},
								},
								aspectRatio = {ratio},
								image = {imageData = tex},
								cornerRadius = rr(7),
							},
							) {}
						} else if loading[i] {
							progress_dots(fmt.tprintf("GifTileLoading%d", i)); anim_moving += 1
						} else {clay.Text(
								"GIF",
								{fontId = FONT_BODY, fontSize = 18, textColor = TEXT_LO},
							)}
						saved := item.sha != "" || saved_urls[item.url]
						if clay.UI(clay.ID("GifSave", u32(i)))(
						{
							layout = {
								sizing = {clay.SizingFixed(28), clay.SizingFixed(28)},
								childAlignment = {x = .Center, y = .Center},
							},
							floating = {
								attachTo = .Parent,
								clipTo = .AttachedParent,
								zIndex = 13,
								offset = {-5, 5},
								attachment = {element = .RightTop, parent = .RightTop},
							},
							backgroundColor = MEDIA_CHIP_BG,
							cornerRadius = rr(14),
						},
						) {
							if hovered() {
								cursor_raise(.Pointer)
								tooltip(saved ? tr("Remove saved GIF") : tr("Save GIF"))
							}
							clay.Text(
								ICON_STAR,
								{
									fontId = FONT_ICON,
									fontSize = 12,
									textColor = saved ? ACCENT : MEDIA_CHIP_FG,
								},
							)
						}
					}
				}
			}
		}
	}
	scrollbar(clay.ID("GifGrid"), 14)
	if clay.UI(clay.ID("GifFooter"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 12,
			childAlignment = {y = .Center},
		},
	},
	) {
		clay.Text(
			ui.gif_saved ? tr("Available offline") : "GifSnap",
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		if clay.UI(clay.ID("GifFooterGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if busy {progress_dots("GifLoading"); anim_moving += 1}
		if (ui.gif_error != "" || all_failed) &&
		   ui.gif_job == nil {micro_button("GifRetry", tr("Retry"))}
	}
}

@(private)
handle_gif_picker :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) || mouse_released() && !clay.PointerOver(clay.ID("PickerPanel")) {
		ui.picker_open = false; ui.focus = .Compose; return
	}
	if clicked("GifRetry") {
		gif_retry(ui)
		if !ui.gif_loaded {gif_open(ui)} else if !ui.gif_saved {gif_search(ui)}
		return
	}
	for saved, i in ([]bool{false, true}) {
		if !clicked_indexed("GifSource", u32(i)) {continue}
		ui.gif_saved = saved; ui.gif_focus = -1; ui.gif_hover = -1; ui.gif_error = ""
		if scroll := clay.GetScrollContainerData(clay.ID("GifGrid"));
		   scroll.found {scroll.scrollPosition^ = {}}
		if ui.gif_view != nil {video_view_free(ui.gif_view); ui.gif_view = nil}
		ed_set(ui, &ui.picker_filter, "")
		ui.gif_due = saved ? 0 : rl.GetTime() + GIF_SEARCH_DELAY
		return
	}
	if field_mouse(ui, &ui.picker_filter, "PickerSearch") {ui.gif_focus = -1}
	if rl.IsKeyPressed(.TAB) {ui.gif_focus = ui.gif_focus < 0 ? 0 : -1}
	if ui.gif_focus < 0 {edit_text(ui, &ui.picker_filter)}
	if ui.gif_filter != string(ui.picker_filter[:]) {
		delete(ui.gif_filter); ui.gif_filter = strings.clone(string(ui.picker_filter[:]))
		ui.gif_due = ui.gif_saved ? 0 : rl.GetTime() + GIF_SEARCH_DELAY
		ui.gif_error = ""; ui.gif_page = 0; ui.gif_more = false
	}
	if ui.gif_job != nil {return}
	matches := gif_matches(ui)
	old_focus := ui.gif_focus
	columns := modal_w(clay.ID("PickerPanel"), 560) - 24 >= 440 ? 3 : 2
	if rl.IsKeyPressed(.DOWN) {ui.gif_focus = ui.gif_focus < 0 ? 0 : ui.gif_focus + columns}
	if ui.gif_focus >= 0 {
		if rl.IsKeyPressed(.UP) {ui.gif_focus -= columns}
		if rl.IsKeyPressed(.LEFT) {ui.gif_focus -= 1}
		if rl.IsKeyPressed(.RIGHT) {ui.gif_focus += 1}
		ui.gif_focus = clamp(ui.gif_focus, -1, len(matches) - 1)
	}
	if ui.gif_focus >= 0 && ui.gif_focus != old_focus {
		grid := clay.GetElementData(clay.ID("GifGrid")).boundingBox
		tile := clay.GetElementData(clay.ID("GifTile", u32(matches[ui.gif_focus]))).boundingBox
		scroll := clay.GetScrollContainerData(clay.ID("GifGrid"))
		if scroll.found {
			if tile.y < grid.y {scroll.scrollPosition.y += grid.y - tile.y}
			if tile.y + tile.height >
			   grid.y +
				   grid.height {scroll.scrollPosition.y -= tile.y + tile.height - grid.y - grid.height}
		}
	}
	if rl.IsKeyPressed(.ENTER) && ui.gif_focus < 0 && !ui.gif_saved {gif_search(ui); return}
	items := ui.gif_saved ? ui.gif_library[:] : ui.gif_hits[:]
	hover := -1
	for i, at in matches {
		if clicked_indexed("GifSave", u32(i)) {gif_choose(ui, items[i], .Save); return}
		if clicked_indexed("GifTile", u32(i)) ||
		   rl.IsKeyPressed(.ENTER) && ui.gif_focus == at {gif_choose(ui, items[i], .Stage); return}
		if gif_visible(i) &&
		   (clay.PointerOver(clay.ID("GifTile", u32(i))) || ui.gif_focus == at) {hover = i}
	}
	if hover != ui.gif_hover {ui.gif_hover = hover; ui.gif_hover_at = rl.GetTime()}
	// ponytail: animate one hovered GIF; a shared decoder can replace per-view mpv if simultaneous playback is needed.
	if hover >= 0 &&
	   ui.gif_error == "" &&
	   !ui.prefs.reduce_motion &&
	   rl.GetTime() - ui.gif_hover_at >= GIF_SEARCH_DELAY {
		gif_choose(ui, items[hover], .Preview)
	}
	if !ui.gif_saved && ui.gif_more && ui.gif_due == 0 && ui.gif_job == nil && ui.gif_error == "" {
		scroll := clay.GetScrollContainerData(clay.ID("GifGrid"))
		if scroll.found &&
		   scroll.contentDimensions.height + scroll.scrollPosition.y <=
			   scroll.scrollContainerDimensions.height + 160 {
			gif_search(ui, ui.gif_page + 1)
		}
	}
}
