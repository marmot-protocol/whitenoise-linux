package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Nev_Patch_Line :: struct {
	text: string, // borrows card.content, never interpreted as Markdown
	mark: u8, // '+', '-', '@' (hunk), 'd' (file), or context
}

@(private)
Nev_Patch :: struct {
	repository:            string, // owned repository identifier
	series:                string, // owned mail patch/revision marker
	description:           string, // borrows card.content
	lines:                 [dynamic]Nev_Patch_Line,
	files, added, removed: int,
}

// Hunk ranges distinguish file headers and signatures from changed lines,
// including added lines that themselves start with "++".
@(private = "file")
nev_patch_range :: proc(value: string) -> int {
	comma := strings.index_byte(value, ',')
	if comma < 0 {return 1}
	n, valid := strconv.parse_int(value[comma + 1:])
	return valid ? max(n, 0) : 0
}

@(private)
nev_patch_parse :: proc(card: ^Nev_Card, ev: json.Object) {
	p := &card.patch
	tags, _ := ev["tags"].(json.Array)
	for tag in tags {
		values, ok := tag.(json.Array)
		if !ok || len(values) < 2 {continue}
		name, _ := values[0].(json.String)
		value, valid := values[1].(json.String)
		if name != "a" ||
		   !valid ||
		   len(p.repository) > 0 ||
		   !strings.has_prefix(value, "30617:") {continue}
		if len(value) <= 71 || value[70] != ':' {continue}
		pubkey: [32]u8
		_, decoded := hex.decode_into_buffer(transmute([]u8)value[6:70], pubkey[:])
		if decoded {p.repository = strings.clone(value[71:])}
	}
	body := card.content
	// format-patch folds mail headers with a leading space or tab.
	header_end := strings.index(body, "\n\n")
	separator := 2
	if crlf := strings.index(body, "\r\n\r\n");
	   crlf >= 0 && (header_end < 0 || crlf < header_end) {header_end, separator = crlf, 4}
	title := strings.builder_make(context.temp_allocator)
	if header_end >= 0 {
		headers := body[:header_end]
		fold := false
		for line in strings.split_lines_iterator(&headers) {
			if strings.has_prefix(line, "Subject: ") {
				strings.write_string(&title, strings.trim_space(line[9:]))
				fold = true
			} else if fold && (strings.has_prefix(line, " ") || strings.has_prefix(line, "\t")) {
				strings.write_string(&title, " ")
				strings.write_string(&title, strings.trim_space(line))
			} else {fold = false}
		}
		if len(strings.to_string(title)) > 0 {body = body[header_end + separator:]}
	}
	subject := strings.to_string(title)
	if strings.has_prefix(subject, "[PATCH") {
		if end := strings.index_byte(subject, ']'); end >= 0 {
			p.series = strings.clone(strings.trim_space(subject[6:end]))
			subject = strings.trim_space(subject[end + 1:])
		}
	}
	card.subject = strings.clone(subject)
	font := [1]u8{FONT_TITLE}
	card.subject_fonts = strings.repeat(string(font[:]), len(card.subject))
	diff_at := strings.has_prefix(body, "diff --git ") ? 0 : strings.index(body, "\ndiff --git ")
	if diff_at > 0 {diff_at += 1}
	p.description = diff_at >= 0 ? body[:diff_at] : body
	if divider := strings.index(p.description, "\n---\n");
	   divider >= 0 {p.description = p.description[:divider]}
	if divider := strings.index(p.description, "\r\n---\r\n");
	   divider >= 0 {p.description = p.description[:divider]}
	p.description = strings.trim_space(p.description)
	if diff_at < 0 {return} 	// Cover letters have prose and a diffstat, but no diff.
	diff := body[diff_at:]
	old, fresh := 0, 0
	for source in strings.split_lines_iterator(&diff) {
		line := source
		mark := u8(0)
		if strings.has_prefix(line, "diff --git ") {
			p.files += 1
			old, fresh, mark = 0, 0, 'd'
			if path := strings.last_index(line, " b/"); path >= 0 {line = line[path + 3:]}
		} else if strings.has_prefix(line, "@@ ") {
			ranges := line[3:]
			left_end := strings.index_byte(ranges, ' ')
			if left_end >= 0 {
				left := ranges[:left_end]
				ranges = ranges[left_end + 1:]
				if right_end := strings.index_byte(ranges, ' ');
				   right_end >=
				   0 {old, fresh = nev_patch_range(left), nev_patch_range(ranges[:right_end])}
			}
			mark = '@'
		} else if old > 0 || fresh > 0 {
			if strings.has_prefix(line, "+") && fresh > 0 {p.added += 1; fresh -= 1; mark = '+'}
			if strings.has_prefix(line, "-") && old > 0 {p.removed += 1; old -= 1; mark = '-'}
			if strings.has_prefix(line, " ") {old = max(old - 1, 0); fresh = max(fresh - 1, 0)}
		} else if line == "-- " {break
		} else if strings.has_prefix(line, "index ") ||
		   strings.has_prefix(line, "--- ") ||
		   strings.has_prefix(line, "+++ ") {continue}
		append(&p.lines, Nev_Patch_Line{line, mark})
	}
}

@(private)
nev_patch_card :: proc(id: u32, key: string, card: Nev_Card, width: f32) {
	p := card.patch
	base := 0x2c000000 + id * 64
	if len(card.subject) == 0 {body_text(base, tr("Untitled patch"), 20, TEXT, wrap_w = width)}
	if len(p.repository) >
	   0 {body_text(base + 1, p.repository, 12, ACCENT, wrap_w = width, max_lines = 2)}
	if len(p.series) >
	   0 {body_text(base + 4, p.series, 11, TEXT_LO, wrap_w = width, max_lines = 1)}
	if p.files > 0 {
		if clay.UI(clay.ID("NevPatchStats", id))(
		{layout = {childGap = 12, layoutDirection = width < 180 ? .TopToBottom : .LeftToRight}},
		) {
			clay.Text(
				fmt.tprintf(tr(p.files == 1 ? N_("%d file") : N_("%d files")), p.files),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			clay.Text(
				fmt.tprintf("+%d", p.added),
				{fontId = FONT_MONO, fontSize = 12, textColor = ACCENT_DIM},
			)
			clay.Text(
				fmt.tprintf("-%d", p.removed),
				{fontId = FONT_MONO, fontSize = 12, textColor = DANGER},
			)
		}
	}
	limit := card.excerpt.expanded ? max(int) : message_line_limit()
	description_lines := 0
	if len(p.description) >
	   0 {description_lines = body_text(base + 2, p.description, 13, TEXT_DIM, wrap_w = width, max_lines = limit)}
	// ponytail: cap wrapped rows at the source viewer's ceiling to bound Clay
	// elements. Open in client has the complete patch; virtualize for larger diffs.
	rows_left := min(limit, CODE_MODAL_LINES)
	shown := 0
	if len(p.lines) > 0 {
		if clay.UI(clay.ID("NevPatchDiff", id))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(width)},
				padding = clay.PaddingAll(10),
				childGap = 3,
			},
			backgroundColor = CODE_PLATE,
			cornerRadius = rr(7),
		},
		) {
			for line, index in p.lines {
				if rows_left <= 0 {break}
				color :=
					line.mark == '+' ? ACCENT_DIM : (line.mark == '-' ? DANGER : (line.mark == '@' || line.mark == 'd' ? ACCENT : TEXT_LO))
				complete := false
				if clay.UI(clay.ID("NevPatchLine", id * (CODE_MODAL_LINES + 1) + u32(index)))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingGrow()},
						padding = {left = 4, right = 4, top = 2, bottom = 2},
					},
					backgroundColor = line.mark == '+' ? fade(ACCENT_DIM, 0.08) : (line.mark == '-' ? fade(DANGER, 0.08) : clay.Color{}),
				},
				) {
					used: int
					used, complete = mono_lines(line.text, max(width - 28, 1), color, rows_left)
					rows_left -= max(used, 1)
				}
				if !complete {break}
				shown += 1
			}
			if len(p.lines) > shown &&
			   (card.excerpt.expanded ||
					   limit ==
						   max(
							   int,
						   )) {body_text(base + 3, fmt.tprintf(tr("and %d more lines"), len(p.lines) - shown), 11, TEXT_LO, wrap_w = max(width - 20, 1))}
		}
	}
	if message_line_limit() != max(int) &&
	   (shown < len(p.lines) ||
			   description_lines >= message_line_limit() ||
			   card.excerpt.expanded) {
		if clay.UI(clay.ID("NevMore", id))(
		{layout = {padding = {top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}},
		) {
			if hovered() {nev_more_hover, nev_more_id = key, base + 2}
			clay.Text(
				card.excerpt.expanded ? tr("Show less") : tr("Read more"),
				{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
			)
		}
	}
}
