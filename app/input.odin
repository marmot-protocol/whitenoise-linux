package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

key_hit :: proc(k: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)
}

// ── Text editing (core:text/edit over the shared ed state) ─────────

ctrl_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

shift_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
}

// Clipboard hooks for core:text/edit. Paste strips control characters
// but keeps newlines, matching the old Ctrl+V path.
clip_set :: proc(_: rawptr, text: string) -> (ok: bool) {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	return true
}

clip_get :: proc(_: rawptr) -> (text: string, ok: bool) {
	clip := rl.GetClipboardText()
	if clip == nil {
		return "", false
	}
	return clean_paste(string(clip)), true
}

clean_paste :: proc(raw: string) -> string {
	cleaned := strings.builder_make(context.temp_allocator)
	for r in raw {
		if r >= 32 || r == '\n' {
			strings.write_rune(&cleaned, r)
		}
	}
	return strings.to_string(cleaned)
}

// Snap a byte offset back onto a UTF-8 rune boundary.
rune_snap :: proc(text: string, pos: int) -> int {
	p := clamp(pos, 0, len(text))
	for p > 0 && p < len(text) && text[p] >= 0x80 && text[p] < 0xc0 {
		p -= 1
	}
	return p
}

// Byte offset of the grapheme-cluster boundary before/after pos.
// core:text/edit's own grapheme mode (translate_by_grapheme) subtracts
// the monospace-cell width (2 for CJK) instead of the byte width and
// corrupts the text (寝る + backspace left "寝" plus a stray byte), so
// boundaries come from the grapheme iterator's byte_index instead.
prev_grapheme :: proc(text: string, pos: int) -> int {
	p := rune_snap(text, pos)
	if p == 0 {
		return 0
	}
	it := utf8.decode_grapheme_iterator_make(text[:p])
	last := 0
	for {
		_, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok {
			break
		}
		last = g.byte_index
	}
	return last
}

next_grapheme :: proc(text: string, pos: int) -> int {
	p := rune_snap(text, pos)
	if p >= len(text) {
		return len(text)
	}
	it := utf8.decode_grapheme_iterator_make(text[p:])
	_, _, ok := utf8.decode_grapheme_iterate(&it)
	if !ok {
		return len(text)
	}
	_, second, ok2 := utf8.decode_grapheme_iterate(&it)
	return ok2 ? p + second.byte_index : len(text)
}

// Point the shared edit state at buf (wrapping it as ed_view) so the
// core:text/edit ops can run; ed_end writes the buffer back. Switching
// fields moves the caret to the end and drops the old undo history.
ed_begin :: proc(ui: ^Ui_State, buf: ^[dynamic]u8) {
	if ui.ed_target != buf {
		ui.ed_target = buf
		n := len(buf)
		ui.ed.selection = {n, n}
		edit.undo_clear(&ui.ed, &ui.ed.undo)
		edit.undo_clear(&ui.ed, &ui.ed.redo)
	}
	ui.ed_view.buf = buf^
	ui.ed.builder = &ui.ed_view
	// Owners clear()/append() buffers directly; re-clamp on entry.
	ui.ed.selection[0] = rune_snap(string(buf[:]), ui.ed.selection[0])
	ui.ed.selection[1] = rune_snap(string(buf[:]), ui.ed.selection[1])
	edit.update_time(&ui.ed)
}

ed_end :: proc(ui: ^Ui_State, buf: ^[dynamic]u8) {
	buf^ = ui.ed_view.buf
	ui.ed.builder = nil
	ui.ed_view.buf = {}
}

// Insert at the caret (replacing any selection), retargeting to buf.
ed_insert :: proc(ui: ^Ui_State, buf: ^[dynamic]u8, text: string) {
	ed_begin(ui, buf)
	edit.input_text(&ui.ed, text)
	ed_end(ui, buf)
}

// Replace buf's content and put the caret at the end.
ed_set :: proc(ui: ^Ui_State, buf: ^[dynamic]u8, text: string) {
	clear(buf)
	append(buf, text)
	if ui.ed_target == buf {
		n := len(buf)
		ui.ed.selection = {n, n}
	}
}

// Sorted selection plus caret head for rendering buf. A field that
// isn't the edit target has no live caret: everything sits at the end.
field_sel :: proc(ui: ^Ui_State, buf: ^[dynamic]u8) -> (lo, hi, head: int) {
	n := len(buf)
	if ui.ed_target != buf {
		return n, n, n
	}
	text := string(buf[:])
	a := rune_snap(text, ui.ed.selection[0])
	b := rune_snap(text, ui.ed.selection[1])
	return min(a, b), max(a, b), a
}

// Soft-line bounds and Up/Down targets around the caret, feeding the
// Line_Start/Line_End/Up/Down translations. Single-line fields treat
// the whole buffer as one line.
set_lines :: proc(ed: ^edit.State, multiline: bool) {
	text := string(ed.builder.buf[:])
	head := clamp(ed.selection[0], 0, len(text))

	ls := 0
	le := len(text)
	if multiline {
		ls = strings.last_index_byte(text[:head], '\n') + 1
		if nl := strings.index_byte(text[head:], '\n'); nl >= 0 {
			le = head + nl
		}
	}
	ed.line_start = ls
	ed.line_end = le

	// Up/Down: the same byte column in the neighbour physical line
	// (byte column approximates the visual one; good enough).
	col := head - ls
	ed.up_index = head
	ed.down_index = head
	if !multiline {
		return
	}
	if ls > 0 {
		pls := strings.last_index_byte(text[:ls - 1], '\n') + 1
		ed.up_index = rune_snap(text, min(pls + col, ls - 1))
	}
	if le < len(text) {
		nls := le + 1
		nle := len(text)
		if nl := strings.index_byte(text[nls:], '\n'); nl >= 0 {
			nle = nls + nl
		}
		ed.down_index = rune_snap(text, min(nls + col, nle))
	}
}

// Full keyboard editing for the focused field: typed runes and IME
// commits insert at the caret; selection (Shift), word ops (Ctrl),
// clipboard (Ctrl+C/X/V, Shift+Insert), undo/redo (Ctrl+Z/Y), and
// Select All (Ctrl+A). Backspace/Delete and Left/Right are
// grapheme-aware. The masked login field never copies out.
edit_text :: proc(ui: ^Ui_State, buf: ^[dynamic]u8, multiline := false) {
	ed_begin(ui, buf)
	defer ed_end(ui, buf)
	ed := &ui.ed
	prev_sel := ed.selection
	prev_len := len(buf)

	for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
		if ch >= 32 {
			edit.input_rune(ed, ch)
		}
	}

	ctrl := ctrl_down()
	shift := shift_down()
	masked := buf == &ui.login_input || buf == &ui.export_pw || buf == &ui.backup_pw || buf == &gate_pw || buf == &gate_pw2
	set_lines(ed, multiline)

	if key_hit(.BACKSPACE) {
		switch {
		case ctrl:
			edit.perform_command(ed, .Delete_Word_Left)
		case edit.has_selection(ed):
			edit.selection_delete(ed)
		case:
			pos := ed.selection[0]
			lo := prev_grapheme(string(ed.builder.buf[:]), pos)
			if lo < pos {
				edit.remove(ed, lo, pos)
				ed.selection = {lo, lo}
			}
		}
	}
	if key_hit(.DELETE) && !(shift && !ctrl) { // Shift+Delete is cut below
		switch {
		case ctrl:
			edit.perform_command(ed, .Delete_Word_Right)
		case edit.has_selection(ed):
			edit.selection_delete(ed)
		case:
			pos := ed.selection[0]
			hi := next_grapheme(string(ed.builder.buf[:]), pos)
			if hi > pos {
				edit.remove(ed, pos, hi)
			}
		}
	}
	if key_hit(.LEFT) {
		switch {
		case ctrl && shift:
			edit.perform_command(ed, .Select_Word_Left)
		case ctrl:
			edit.perform_command(ed, .Word_Left)
		case shift:
			ed.selection[0] = prev_grapheme(string(ed.builder.buf[:]), ed.selection[0])
		case edit.has_selection(ed):
			lo, _ := edit.sorted_selection(ed)
			ed.selection = {lo, lo}
		case:
			pos := prev_grapheme(string(ed.builder.buf[:]), ed.selection[0])
			ed.selection = {pos, pos}
		}
	}
	if key_hit(.RIGHT) {
		switch {
		case ctrl && shift:
			edit.perform_command(ed, .Select_Word_Right)
		case ctrl:
			edit.perform_command(ed, .Word_Right)
		case shift:
			ed.selection[0] = next_grapheme(string(ed.builder.buf[:]), ed.selection[0])
		case edit.has_selection(ed):
			_, hi := edit.sorted_selection(ed)
			ed.selection = {hi, hi}
		case:
			pos := next_grapheme(string(ed.builder.buf[:]), ed.selection[0])
			ed.selection = {pos, pos}
		}
	}
	if multiline && key_hit(.UP) {
		edit.perform_command(ed, shift ? edit.Command.Select_Up : .Up)
	}
	if multiline && key_hit(.DOWN) {
		edit.perform_command(ed, shift ? edit.Command.Select_Down : .Down)
	}
	if rl.IsKeyPressed(.HOME) {
		cmd := ctrl ? (shift ? edit.Command.Select_Start : .Start) : (shift ? edit.Command.Select_Line_Start : .Line_Start)
		edit.perform_command(ed, cmd)
	}
	if rl.IsKeyPressed(.END) {
		cmd := ctrl ? (shift ? edit.Command.Select_End : .End) : (shift ? edit.Command.Select_Line_End : .Line_End)
		edit.perform_command(ed, cmd)
	}

	if ctrl && rl.IsKeyPressed(.A) {
		edit.perform_command(ed, .Select_All)
	}
	if !masked && ((ctrl && rl.IsKeyPressed(.C)) || (ctrl && rl.IsKeyPressed(.INSERT))) {
		edit.perform_command(ed, .Copy)
	}
	if !masked && ((ctrl && key_hit(.X)) || (shift && !ctrl && key_hit(.DELETE))) {
		edit.perform_command(ed, .Cut)
	}
	if (ctrl && key_hit(.V)) || (shift && key_hit(.INSERT)) {
		edit.perform_command(ed, .Paste)
	}
	if ctrl && !shift && key_hit(.Z) {
		edit.perform_command(ed, .Undo)
	}
	if ctrl && (key_hit(.Y) || (shift && key_hit(.Z))) {
		edit.perform_command(ed, .Redo)
	}

	// ed_view is the live buffer; buf only gets it back in ed_end.
	if ed.selection != prev_sel || len(ui.ed_view.buf) != prev_len {
		caret_wake()
	}

	// Select-to-copy, the Linux primary selection.
	if !masked && ed.selection != prev_sel && edit.has_selection(ed) {
		rl.SetPrimaryText(strings.clone_to_cstring(edit.current_selected_text(ed), context.temp_allocator))
	}
}

// ── Mouse: click-to-caret, drag selection, middle-click paste ───────

// Buffer currently being drag-selected (cleared in the frame loop).
text_drag: rawptr

// Byte offset nearest to x in a plain single-line text run.
hit_plain :: proc(text: string, x: f32, font_size: u16) -> int {
	pen: f32 = 0
	i := 0
	for i < len(text) {
		_, w := utf8.decode_rune_in_string(text[i:])
		adv := rl.MeasureTextLine(FONT_BODY, font_size, text[i:i + w], 0).x
		if x < pen + adv / 2 {
			return i
		}
		pen += adv
		i += w
	}
	return len(text)
}

// Select the word around the caret (double-click).
select_word_at :: proc(ed: ^edit.State, at: int) {
	ed.selection = {at, at}
	word_end := edit.translate_position(ed, .Word_End)
	word_start := edit.translate_position(ed, .Word_Start)
	ed.selection = {word_end, word_start}
}

// Mouse interactions for one single-line field box: press focuses and
// places the caret (Shift extends, double-click selects the word,
// triple selects all), drag extends the selection, middle-click pastes
// the primary selection. Returns true when a press landed in the box
// so the caller can set keyboard focus. Call every frame the field is
// visible; runs after layout, so clay bounds are current.
field_mouse :: proc(ui: ^Ui_State, buf: ^[dynamic]u8, id_str: string, font_size: u16 = 13) -> bool {
	box := clay.GetElementData(clay.ID(id_str))
	if !box.found {
		return false
	}
	text_box := clay.GetElementData(clay.ID(id_str, 1))
	origin := text_box.found ? text_box.boundingBox.x : box.boundingBox.x
	mx := rl.GetMousePosition().x / UI_ZOOM
	hit := hit_plain(string(buf[:]), mx - origin, font_size)
	over := clay.PointerOver(clay.ID(id_str))

	if over && mouse_pressed() {
		ed_begin(ui, buf)
		switch {
		case rl.GetMouseClicks() >= 3:
			edit.perform_command(&ui.ed, .Select_All)
		case rl.GetMouseClicks() == 2:
			select_word_at(&ui.ed, hit)
		case shift_down():
			ui.ed.selection[0] = hit
		case:
			ui.ed.selection = {hit, hit}
		}
		ed_end(ui, buf)
		text_drag = buf
		return true
	}
	if text_drag == buf && rl.IsMouseButtonDown(.LEFT) && ui.ed_target == buf {
		ui.ed.selection[0] = hit
	}
	if over && rl.IsMouseButtonPressed(.MIDDLE) {
		primary := rl.GetPrimaryText()
		ed_begin(ui, buf)
		ui.ed.selection = {hit, hit}
		if primary != nil {
			edit.input_text(&ui.ed, clean_paste(string(primary)))
		}
		ed_end(ui, buf)
		return true
	}
	return false
}

// Byte offset nearest to x in one composer line, mirroring the widths
// compose_line draws: emoji clusters as 18px tiles plus the 1px child
// gap, text per rune. Span-split gaps are ignored (±1px).
hit_compose_line :: proc(line: string, x: f32) -> int {
	pen: f32 = 0
	i := 0
	for i < len(line) {
		r, w := utf8.decode_rune_in_string(line[i:])
		j := i + w
		adv: f32
		if is_emoji_rune(r) {
			for j < len(line) {
				r2, w2 := utf8.decode_rune_in_string(line[j:])
				if !is_emoji_rune(r2) && r2 != 0xFE0F && r2 != 0x200D {
					break
				}
				j += w2
			}
			adv = 19
		} else {
			adv = rl.MeasureTextLine(FONT_BODY, BODY_FS, line[i:j], 0).x
		}
		if x < pen + adv / 2 {
			return i
		}
		pen += adv
		i = j
	}
	return len(line)
}

// Composer mouse: press focuses and places the caret in the tapped
// line (Shift extends, double-click selects the word, triple the
// line), drag selects, middle-click pastes the primary selection.
compose_mouse :: proc(ui: ^Ui_State) {
	box := clay.GetElementData(clay.ID("ComposeBox"))
	if !box.found {
		return
	}
	over := clay.PointerOver(clay.ID("ComposeBox")) && !clay.PointerOver(clay.ID("EmojiBtn"))
	left := over && rl.IsMouseButtonPressed(.LEFT)
	middle := over && rl.IsMouseButtonPressed(.MIDDLE)
	dragging := text_drag == &ui.compose && rl.IsMouseButtonDown(.LEFT) && !left
	if !left && !middle && !dragging {
		return
	}

	m := rl.GetMousePosition()
	mx := m.x / UI_ZOOM
	my := m.y / UI_ZOOM
	text := string(ui.compose[:])

	// The first line row whose bottom edge is under the pointer takes
	// the hit; past the last row the caret lands in the last line.
	hit := len(text)
	line_start := 0
	for i := u32(0); ; i += 1 {
		line_end := len(text)
		if nl := strings.index_byte(text[line_start:], '\n'); nl >= 0 {
			line_end = line_start + nl
		}
		row := clay.GetElementData(clay.ID("ComposeLine", i))
		if !row.found || my < row.boundingBox.y + row.boundingBox.height || line_end == len(text) {
			origin := row.found ? row.boundingBox.x : box.boundingBox.x
			hit = line_start + hit_compose_line(text[line_start:line_end], mx - origin)
			break
		}
		line_start = line_end + 1
	}

	switch {
	case left:
		ui.focus = .Compose
		ed_begin(ui, &ui.compose)
		switch {
		case rl.GetMouseClicks() >= 3:
			lls := strings.last_index_byte(text[:hit], '\n') + 1
			lle := len(text)
			if nl := strings.index_byte(text[hit:], '\n'); nl >= 0 {
				lle = hit + nl
			}
			ui.ed.selection = {lle, lls}
		case rl.GetMouseClicks() == 2:
			select_word_at(&ui.ed, hit)
		case shift_down():
			ui.ed.selection[0] = hit
		case:
			ui.ed.selection = {hit, hit}
		}
		ed_end(ui, &ui.compose)
		text_drag = &ui.compose
	case dragging:
		if ui.ed_target == &ui.compose {
			ui.ed.selection[0] = hit
		}
	case middle:
		ui.focus = .Compose
		primary := rl.GetPrimaryText()
		ed_begin(ui, &ui.compose)
		ui.ed.selection = {hit, hit}
		if primary != nil {
			edit.input_text(&ui.ed, clean_paste(string(primary)))
		}
		ed_end(ui, &ui.compose)
	}
}

// Test hook: WN_TEST_CLICK forces one synthetic release (position is
// injected into SetPointerState in the frame loop). The press fires
// two frames earlier so press-driven paths (field focus) see it too.
forced_release := false
forced_press := false

mouse_pressed :: proc() -> bool {
	return rl.IsMouseButtonPressed(.LEFT) || forced_press
}

// Test hook: WN_TEST_COMPOSE="N:text" fills the composer at frame N
// and forces the send branch, exercising the optimistic path.
test_send_now := false

// Data home dir (marmot root), shown on the Storage settings page.
data_home: string

// Session cache of decoded attachment textures by plaintext sha256;
// nil marks a failed download. Owns every message-row texture.
media_textures: map[string]^rl.Texture2D

// Plaintext byte size per blob key, learned whenever a download passes
// through (the imeta tag carries no size, so this is best-effort
// session knowledge, like the slint app's attachment_size_cache).
blob_sizes: map[string]i64

// Same cache shape for parsed STL attachments; the views also carry
// their orbit state, so orientation survives timeline reloads.
stl_views: map[string]^Stl_View

// And for video embeds; playback position survives reloads because
// the mpv instance lives in the cached view.
video_views: map[string]^Video_View

// And for g-code extrusion previews (orbit + slider state persist).
gcode_views: map[string]^Gcode_View

// And for PDFs (current page persists).
pdf_views: map[string]^Pdf_View

// And for archives (the listing is parsed once).
arc_views: map[string]^Arc_View

// And for webxdc apps (icon texture + manifest name).
xdc_views: map[string]^Xdc_View

// And for text/markdown and font specimens.
txt_views: map[string]^Txt_View
code_views: map[string]^Code_View
ttf_views: map[string]^Ttf_View

// Prefs pointer for free helpers (time/date formatting) that have no
// Ui_State parameter; set once in main.
g_prefs: ^Prefs

mouse_released :: proc() -> bool {
	// A release ending a scrollbar drag must not click what's under
	// the pointer; the drag clears one frame later in the main loop.
	return (rl.IsMouseButtonReleased(.LEFT) && scroll_drag.container == 0) || forced_release
}

clicked :: proc(id_str: string) -> bool {
	return mouse_released() && clay.PointerOver(clay.ID(id_str))
}

// Keyboard editing + click actions for the login pane. Runs after the
// frame's layout so PointerOver uses current bounds.
// Login/create run on the sign-in worker (workers.odin); the pane shows
// its progress card and swallows input until drain_auth lands.
