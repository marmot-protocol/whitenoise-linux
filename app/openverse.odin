// Openverse remote image search, the slint image_search.rs port:
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
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"
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
	thread.create_and_start(ov_worker, self_cleanup = true)
}

// One-shot worker: curl the search endpoint (-G --data-urlencode
// handles the query escaping) and parse the results.
@(private = "file")
ov_worker :: proc() {
	q := fmt.aprintf("q=%s", ov_query)
	defer delete(q)
	ps := fmt.aprintf("page_size=%d", OV_PAGE_SIZE)
	defer delete(ps)
	state, out, _, err := os.process_exec(
		{command = {"curl", "-sfG", "--max-time", "15", "--data-urlencode", q, "--data-urlencode", ps, OV_ENDPOINT}},
		context.allocator,
	)
	defer delete(out)

	hits: [dynamic]Ov_Hit
	fail: string
	if err != nil || state.exit_code != 0 || len(out) == 0 {
		fail = strings.clone("Couldn't search. Please try again.")
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
// either are dropped, like the slint image_search.rs.
ov_parse :: proc(body: []u8) -> (hits: [dynamic]Ov_Hit, fail: string) {
	val, perr := json.parse(body)
	if perr != nil {
		return hits, strings.clone("Couldn't search. Please try again.")
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
		fail = strings.clone("No results. Try another search.")
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
	ov_err = ov_fresh_err
	ov_fresh_err = ""
	ov_fresh_ready = false
	ov_busy = false
}

OV_CELL :: 96
OV_COLS :: 4

openverse_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("OvModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("OvModal"), OV_CELL * OV_COLS + 8 * (OV_COLS - 1) + 40))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("OvModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("OvHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text("Search images", {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			if clay.UI(clay.ID("OvHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("OvClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("OvRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
			if clay.UI(clay.ID("OvField"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)}, padding = {left = 12, right = 12}, childAlignment = {y = .Center}},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
				border = {color = ui.focus == .Ov ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				field_text(ui, "OvField", &ui.ov_input, "Search openly licensed images", ui.focus == .Ov, 13, TEXT_LO)
			}
			micro_button("OvGo", ov_busy ? "Searching…" : "Search")
		}

		if len(ov_err) > 0 {
			clay.Text(ov_err, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		}

		if clay.UI(clay.ID("OvList"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 320})}, layoutDirection = .TopToBottom, childGap = 8},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for row_start := 0; row_start < len(ov_hits); row_start += OV_COLS {
				if clay.UI(clay.ID("OvGridRow", u32(row_start)))({layout = {childGap = 8}}) {
					for i in row_start ..< min(row_start + OV_COLS, len(ov_hits)) {
						tex := url_pic(ov_hits[i].thumb)
						if clay.UI(clay.ID("OvCell", u32(i)))(
						{
							layout = {sizing = {width = clay.SizingFixed(OV_CELL), height = clay.SizingFixed(OV_CELL)}},
							backgroundColor = tex == nil ? ROW_BG : {},
							cornerRadius = rr(8),
							image = tex != nil ? clay.ImageElementConfig{imageData = tex} : {},
							border = hovered() ? clay.BorderElementConfig{color = ACCENT, width = {2, 2, 2, 2, 0}} : {},
						},
						) {}
					}
				}
			}
		}
		scrollbar(clay.ID("OvList"))
	}
}

// Modal input: Escape/backdrop closes, Enter/Search queries, a cell
// click publishes the pick as the group photo.
handle_openverse :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) || (mouse_released() && (clicked("OvClose") || !clay.PointerOver(clay.ID("OvModal")))) {
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
			if clay.PointerOver(clay.ID("OvCell", u32(i))) {
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
	summary: ^marmot.Send_Summary
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
	url := strings.clone_to_cstring(full_url, context.temp_allocator)
	if marmot.update_group_avatar_url(client, account, group, url, nil, nil, &summary) != .OK {
		delete(ov_err)
		ov_err = fmt.aprintf("Couldn't set the photo. %s", marmot.last_error())
		return
	}
	marmot.send_summary_free(summary)

	// A published photo supersedes any session-local one.
	gid := ui.chats[ui.selected].group_id
	if local, ok := gpic_local[gid]; ok {
		delete(local)
		delete_key(&gpic_local, gid)
	}
	ov_close(ui)
	refresh_after_action(ui, client)
}
