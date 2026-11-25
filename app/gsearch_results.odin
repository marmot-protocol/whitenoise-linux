package main

import "core:strings"
import "core:unicode/utf8"
import "nendo"
import rl "sdlrl"

@(private)
GS_MODAL_PAD :: 20
@(private)
GS_BODY_PAD :: 6
@(private = "file")
GS_HIT_PAD :: 10
@(private = "file")
GS_HIT_GAP :: 3
@(private = "file")
GS_META_GAP :: 8
@(private = "file")
GS_SNIP_SIZE :: u16(12)
@(private = "file")
GS_META :: [3]struct {
	font, size: u16,
}{{FONT_TITLE, 13}, {FONT_BODY, 12}, {FONT_MONO, 10}}

@(private)
Gs_Layout :: struct {
	rows:     [dynamic]Gs_Row_Plan,
	lines:    [dynamic]Wrap_Line, // byte ranges into the hit's metadata and snippet
	offsets:  [dynamic]f32,
	metrics:  [3]f32, // interior width, text scale, pixel scale
	font_rev: u32,
}

@(private = "file")
Gs_Row_Plan :: struct {
	widths:   [3]f32,
	ends:     [4]int, // one past the last line in each metadata column and the snippet
	match:    [2]int,
	header_h: f32,
}

@(private)
gs_layout_clear :: proc(plan: ^Gs_Layout) {
	clear(&plan.rows)
	clear(&plan.lines)
	clear(&plan.offsets)
}

@(private)
gs_layout_free :: proc(plan: ^Gs_Layout) {
	delete(plan.rows); delete(plan.lines); delete(plan.offsets)
	plan^ = {}
}

@(private = "file")
gs_measure_rows :: proc(ui: ^Ui_State, width: f32) {
	plan := &ui.gs_layout
	metrics := [3]f32{width, rl.TextScale, UI_SCALE}
	if plan.metrics != metrics || plan.font_rev != text_metrics_revision {
		gs_layout_clear(plan)
		plan.metrics, plan.font_rev = metrics, text_metrics_revision
	}
	if len(plan.offsets) == 0 {
		append(&plan.offsets, 0)
	}
	if len(plan.rows) == len(ui.gs_hits) {
		return
	}
	styles := GS_META
	query := string(ui.gs_input[:])
	fonts := make([dynamic]u8, context.temp_allocator)
	for i in len(plan.rows) ..< len(ui.gs_hits) {
		hit := &ui.gs_hits[i]
		labels := [3]string{hit.title, hit.sender, hit.at}
		natural: [3]f32
		for label, k in labels {
			natural[k] = rl.MeasureTextLine(styles[k].font, styles[k].size, label, 0).x
		}
		// A narrow header shares space among long labels. Short ones keep their natural width.
		available := max(1, width - 3 * GS_META_GAP)
		low, high :=
			min(natural[0], natural[1], natural[2]), max(natural[0], natural[1], natural[2])
		cap := max(
			available / 3,
			(available - low) / 2,
			available - (natural[0] + natural[1] + natural[2] - high),
		)
		row: Gs_Row_Plan
		for label, k in labels {
			style := styles[k]
			row.widths[k] = min(natural[k], cap)
			start := len(plan.lines)
			if label != "" {
				if natural[k] <= cap && !strings.contains(label, "\n") {
					append(&plan.lines, Wrap_Line{end = len(label)})
				} else {
					plan_wrap_lines(
						&plan.lines,
						label,
						row.widths[k],
						style.size,
						.Plain,
						plain_font = style.font,
					)
				}
			}
			row.ends[k] = len(plan.lines)
			row.header_h = max(
				row.header_h,
				f32(row.ends[k] - start) * f32(style.size) * rl.TextScale,
			)
		}
		if hit.snippet != "" {
			row.match = gs_snippet_match(hit.snippet, query)
			font_map := ""
			if row.match[0] < row.match[1] {
				resize(&fonts, len(hit.snippet))
				for &font, at in fonts {
					font = row.match[0] <= at && at < row.match[1] ? FONT_TITLE : FONT_BODY
				}
				font_map = string(fonts[:])
			}
			plan_wrap_lines(
				&plan.lines,
				hit.snippet,
				max(1, width),
				GS_SNIP_SIZE,
				.Plain,
				fonts = font_map,
			)
		}
		row.ends[3] = len(plan.lines)
		height :=
			2 * GS_HIT_PAD +
			row.header_h +
			f32(row.ends[3] - row.ends[2]) * (f32(GS_SNIP_SIZE) * rl.TextScale + GS_HIT_GAP)
		append(&plan.rows, row)
		append(&plan.offsets, plan.offsets[i] + height)
	}
}

@(private = "file")
gs_snippet_match :: proc(text, query: string) -> [2]int {
	if len(query) == 0 {
		return {}
	}
	match := strings.index(text, query)
	if match < 0 {
		for _, at in text {
			if at + len(query) <= len(text) &&
			   strings.equal_fold(text[at:at + len(query)], query) {
				match = at
				break
			}
		}
	}
	if match < 0 {
		return {}
	}
	// Drawing the match separately must not split a displayed grapheme.
	start, end := match, match + len(query)
	iterator := utf8.decode_grapheme_iterator_make(text)
	for cluster, grapheme in rl.grapheme_iterate(&iterator) {
		at := grapheme.byte_index
		next := at + len(cluster)
		if at <= match && match < next {start = at}
		if end <= next {return {start, next}}
	}
	return {start, end}
}

@(private = "file")
gs_snippet_text :: proc(text: string, match: [2]int, lines: []Wrap_Line, arrived: f32) {
	normal := nendo.Text_Style {
		font  = FONT_BODY,
		size  = GS_SNIP_SIZE,
		color = fade(TEXT_DIM, arrived),
		wrap  = .None,
	}
	highlight := nendo.Text_Style {
		font  = FONT_TITLE,
		size  = GS_SNIP_SIZE,
		color = fade(ACCENT, arrived),
		wrap  = .None,
	}
	height := nendo.fixed(f32(GS_SNIP_SIZE) * rl.TextScale)
	for line, i in lines {
		if nendo.box(nendo.id_local("GsSnippetLine", u32(i)))(
		{width = nendo.grow(), height = height, clip = {x = true}},
		) {
			start, end := line.start, line.end
			if match[0] >= end || match[1] <= start {
				nendo.text(text[start:end], normal)
				continue
			}
			a, b := max(start, match[0]), min(end, match[1])
			if a > start {nendo.text(text[start:a], normal)}
			nendo.text(text[a:b], highlight)
			if b < end {nendo.text(text[b:end], normal)}
		}
	}
}

@(private = "file")
gs_result_row :: proc(ui: ^Ui_State, i: int) {
	plan, hit := &ui.gs_layout, &ui.gs_hits[i]
	row := &plan.rows[i]
	arrived := stagger(nendo.id("GsList").id, i)
	if nendo.box(nendo.id("GsHit", u32(i)))(
	{
		width = nendo.grow(),
		height = nendo.fixed(plan.offsets[i + 1] - plan.offsets[i]),
		direction = .Column,
		padding = nendo.pad(GS_HIT_PAD),
		gap = GS_HIT_GAP,
		color = fade(hovered() ? HOVER : {}, arrived),
		radius = rr(8),
	},
	) {
		if nendo.box(nendo.id("GsHitTop", u32(i)))(
		{
			width = nendo.grow(),
			height = nendo.fixed(row.header_h),
			gap = GS_META_GAP,
			align = {y = .Center},
		},
		) {
			start := i > 0 ? plan.rows[i - 1].ends[3] : 0
			labels := [3]string{hit.title, hit.sender, hit.at}
			inks := [3]nendo.Color{TEXT, TEXT_DIM, TEXT_LO}
			styles := GS_META
			for label, k in labels {
				if k == 2 {
					if nendo.box(nendo.id_local("GsHitGap"))({width = nendo.grow()}) {}
				}
				if nendo.box(nendo.id_local("GsMeta", u32(k)))(
				{width = nendo.fixed(row.widths[k]), direction = .Column, clip = {x = true}},
				) {
					style := nendo.Text_Style {
						font  = styles[k].font,
						size  = styles[k].size,
						color = fade(inks[k], arrived),
						wrap  = .None,
					}
					height := nendo.fixed(f32(style.size) * rl.TextScale)
					for line, j in plan.lines[start:row.ends[k]] {
						if nendo.box(nendo.id_local("GsMetaLine", u32(j)))({height = height}) {
							nendo.text(label[line.start:line.end], style)
						}
					}
				}
				start = row.ends[k]
			}
		}
		gs_snippet_text(hit.snippet, row.match, plan.lines[row.ends[2]:row.ends[3]], arrived)
	}
}

@(private)
gs_results :: proc(ui: ^Ui_State, modal_width: f32) {
	id := nendo.id("GsList")
	if nendo.box(id)(
	{
		width = nendo.grow(),
		height = nendo.fit(min = 44, max = 300),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		gs_measure_rows(ui, modal_width - 2 * GS_MODAL_PAD - GS_BODY_PAD - 2 * GS_HIT_PAD)
		window := nendo.virtual_rows(nendo.id("GsRows"), ui.gs_layout.offsets[:], gap = 2)
		for i in window.first ..< window.end {
			gs_result_row(ui, i)
		}
	}
	scrollbar(id, 14) // the modal floats at 13
}
