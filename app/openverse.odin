// Openverse remote image search.
// "Search images" in the group hero opens a centered modal with a
// query box and a thumbnail grid. Openverse indexes openly licensed
// images and needs no key for basic search. A one-shot curl worker
// fetches the JSON; thumbnails ride the shared url_pic pipeline; a
// click applies the hit's full URL as the group's published avatar
// (marmot_update_group_avatar_url).
//
// The search itself is picker-agnostic (ov_show/ov_hits carry no
// group state); only ov_apply is group-photo specific, so a profile
// picture flow can reuse the modal later.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

OV_ENDPOINT :: "https://api.openverse.org/v1/images/"
OV_PAGE_SIZE :: 20 // Openverse's unauthenticated page_size cap

Ov_Hit :: struct {
	thumb: string, // fetched by the url_pic pipeline
	full:  string, // what a pick applies
}

// Worker → frame-loop handoff; drain_ov moves fresh results into the
// render-side ov_hits.
@(private = "file")
ov_mutex: sync.Mutex
@(private = "file")
ov_fresh: [dynamic]Ov_Hit
@(private = "file")
ov_fresh_err: string
@(private = "file")
ov_fresh_ready: bool
@(private = "file")
ov_query: string // owned handoff to the one-shot worker

ov_hits: [dynamic]Ov_Hit
ov_err: string
ov_busy: bool

ov_show :: proc(ui: ^Ui_State) {
	ui.ov_open = true
	ui.focus = .Ov
	clear(&ui.ov_input)
}

@(private = "file")
ov_close :: proc(ui: ^Ui_State) {
	ui.ov_open = false
	ui.focus = .Invite
}

// Kick a search for the query box; one in flight at a time.
@(private = "file")
ov_search :: proc(ui: ^Ui_State) {
	query := strings.trim_space(string(ui.ov_input[:]))
	if len(query) == 0 || ov_busy {
		return
	}
	ov_busy = true
	delete(ov_err)
	ov_err = ""
	delete(ov_query)
	ov_query = strings.clone(query)
	append(&send_threads, thread.create_and_start(ov_worker))
}

// One-shot worker: curl the search endpoint (-G --data-urlencode
// handles the query escaping) and parse the results.
@(private = "file")
ov_worker :: proc() {
	context.allocator = reload_allocator()
	defer frame_wake() // results or the error repaint without waiting for input
	q := fmt.aprintf("q=%s", ov_query)
	defer delete(q)
	ps := fmt.aprintf("page_size=%d", OV_PAGE_SIZE)
	defer delete(ps)
	state, out, _, err := tool_exec(
		{
			command = {
				curl_path(),
				"-sfG",
				"--max-time",
				"15",
				"--data-urlencode",
				q,
				"--data-urlencode",
				ps,
				OV_ENDPOINT,
			},
		},
		context.allocator,
	)
	defer delete(out)

	hits: [dynamic]Ov_Hit
	fail: string
	if err != nil || state.exit_code != 0 || len(out) == 0 {
		fail = N_("Couldn't search. Please try again.")
	} else {
		hits, fail = ov_parse(out)
	}

	sync.lock(&ov_mutex)
	ov_fresh = hits
	ov_fresh_err = fail
	ov_fresh_ready = true
	sync.unlock(&ov_mutex)
}

// Parse an Openverse response body into hits: results[].url (the
// pick) and results[].thumbnail (the grid cell); entries missing
// either are dropped.
ov_parse :: proc(body: []u8) -> (hits: [dynamic]Ov_Hit, fail: string) {
	val, perr := json.parse(body)
	if perr != nil {
		return hits, N_("Couldn't search. Please try again.")
	}
	defer json.destroy_value(val)

	if root, ok := val.(json.Object); ok {
		if results, ok2 := root["results"].(json.Array); ok2 {
			for r in results {
				obj, ok3 := r.(json.Object)
				if !ok3 {
					continue
				}
				full, has_full := obj["url"].(json.String)
				thumb, has_thumb := obj["thumbnail"].(json.String)
				if !has_full || !has_thumb || len(full) == 0 || len(thumb) == 0 {
					continue
				}
				append(&hits, Ov_Hit{thumb = strings.clone(thumb), full = strings.clone(full)})
			}
		}
	}
	if len(hits) == 0 {
		fail = N_("No results. Try another search.")
	}
	return hits, fail
}

// Frame-loop drain: publish the worker's results to the render side.
drain_ov :: proc() {
	sync.lock(&ov_mutex)
	defer sync.unlock(&ov_mutex)
	if !ov_fresh_ready {
		return
	}
	for h in ov_hits {
		delete(h.thumb)
		delete(h.full)
	}
	delete(ov_hits)
	ov_hits = ov_fresh
	ov_fresh = {}
	delete(ov_err)
	// The worker hands over a static N_ msgid; translate on the UI thread.
	ov_err = len(ov_fresh_err) > 0 ? strings.clone(tr(ov_fresh_err)) : ""
	ov_fresh_err = ""
	ov_fresh_ready = false
	ov_busy = false
}

OV_CELL :: 96
OV_COLS :: 4

@(private)
ov_grid :: proc(width: f32) -> (columns: int, cell: f32) {
	columns = max(1, min(OV_COLS, int((width - 32) / (OV_CELL + 8))))
	cell = max(1, min(f32(OV_CELL), (width - 40 - f32(columns - 1) * 8) / f32(columns)))
	return
}

openverse_modal :: proc(ui: ^Ui_State) {
	width := modal_w(nendo.id("OvModal"), OV_CELL * OV_COLS + 8 * (OV_COLS - 1) + 40)
	columns, cell := ov_grid(width)
	if nendo.box(nendo.id("OvModal"))(
	{
		width = nendo.fixed(width),
		height = nendo.fixed(modal_h(500)),
		direction = .Column,
		padding = nendo.pad(20),
		gap = 12,
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("OvModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		if nendo.box(nendo.id("OvHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Search images"), {font = FONT_TITLE, size = 20, color = TEXT})
			if nendo.box(nendo.id("OvHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("OvClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 26),
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(7),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}

		if nendo.box(nendo.id("OvRow"))({width = nendo.grow(), gap = 8, align = {y = .Center}}) {
			if nendo.box(nendo.id("OvField"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? tap_min() : 36),
				padding = {left = 12, right = 12},
				align = {y = .Center},
				color = ROW_BG,
				radius = rr(8),
				border = {color = ui.focus == .Ov ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				field_text(
					ui,
					"OvField",
					&ui.ov_input,
					tr("Search openly licensed images"),
					ui.focus == .Ov,
					13,
					TEXT_LO,
				)
			}
			micro_button("OvGo", ov_busy ? tr("Searching…") : tr("Search"))
		}

		if len(ov_err) > 0 {
			nendo.text(ov_err, {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}

		if nendo.box(nendo.id("OvList"))(
		{
			width = nendo.grow(),
			height = nendo.grow(min = 44),
			direction = .Column,
			gap = 8,
			clip = {y = true, scroll = true},
		},
		) {
			for row_start := 0; row_start < len(ov_hits); row_start += columns {
				if nendo.box(nendo.id("OvGridRow", u32(row_start)))({gap = 8}) {
					for i in row_start ..< min(row_start + columns, len(ov_hits)) {
						tex := url_pic(ov_hits[i].thumb)
						if nendo.box(nendo.id("OvCell", u32(i)))(
						{
							width = nendo.fixed(cell),
							height = nendo.fixed(cell),
							color = tex == nil ? ROW_BG : {},
							radius = rr(8),
							image = tex,
							border = hovered() ? nendo.Border{color = ACCENT, width = {2, 2, 2, 2, 0}} : {},
						},
						) {}
					}
				}
			}
		}
		scrollbar(nendo.id("OvList"), 14) // the modal floats at 13
	}
	scrollbar(nendo.id("OvModal"), 14)
}

// Modal input: Escape/backdrop closes, Enter/Search queries, a cell
// click publishes the pick as the group photo.
handle_openverse :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) ||
	   (mouse_released() && (clicked("OvClose") || !nendo.pointer_over(nendo.id("OvModal")))) {
		ov_close(ui)
		return
	}
	edit_text(ui, &ui.ov_input)
	if field_mouse(ui, &ui.ov_input, "OvField") {
		ui.focus = .Ov
		return
	}
	if rl.IsKeyPressed(.ENTER) || clicked("OvGo") {
		ov_search(ui)
		return
	}
	if mouse_released() {
		for hit, i in ov_hits {
			if nendo.pointer_over(nendo.id("OvCell", u32(i))) {
				ov_apply(ui, client, hit.full)
				return
			}
		}
	}
}

// Publish the picked URL as the group's avatar; the chat-list reload
// then carries it like any other avatar_url.
@(private = "file")
ov_apply :: proc(ui: ^Ui_State, client: ^marmot.Client, full_url: string) {
	job := account_job_new(ui, client, .Avatar); if job == nil {return}
	job.target = strings.clone(full_url); account_job_start(job)
}
