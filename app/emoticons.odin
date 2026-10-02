// Classic ASCII emoticons become emoji in the composer once the token
// is finished: a typed space, a Shift+Enter newline, or the send.
//
//   "hi :)"  --space-->  "hi 🙂 "
//   "ok :D"  --Enter-->  sends "ok 😃"
//
// The token is everything back to the previous whitespace, so it must
// match a whole entry: "C:D", "http://", and "(:)" stay literal. Ctrl+Z
// right after the swap restores the typed characters.
package main

import "core:strings"
import "core:text/edit"

@(private = "file")
EMOTICONS := [?]struct {
	text, emoji: string,
} {
	{":)", "🙂"},
	{":-)", "🙂"},
	{"=)", "🙂"},
	{":(", "🙁"},
	{":-(", "🙁"},
	{"=(", "🙁"},
	{":D", "😃"},
	{":-D", "😃"},
	{"=D", "😃"},
	{"xD", "😆"},
	{"XD", "😆"},
	{";)", "😉"},
	{";-)", "😉"},
	{":P", "😛"},
	{":-P", "😛"},
	{":p", "😛"},
	{":-p", "😛"},
	{";P", "😜"},
	{";p", "😜"},
	{":O", "😮"},
	{":-O", "😮"},
	{":o", "😮"},
	{":-o", "😮"},
	{":'(", "😢"},
	{":|", "😐"},
	{":-|", "😐"},
	{":/", "😕"},
	{":-/", "😕"},
	{":*", "😘"},
	{":-*", "😘"},
	{">:(", "😠"},
	{"O:)", "😇"},
	{"O:-)", "😇"},
	{"B-)", "😎"},
	{"8-)", "😎"},
	{"^_^", "😊"},
	{"-_-", "😑"},
	{"<3", "❤️"},
	{"</3", "💔"},
}

// Replace the emoticon ending at the caret with its emoji. Runs between
// ed_begin and ed_end on the composer, before the boundary is inserted.
@(private)
emoticon_swap :: proc(ed: ^edit.State) {
	if edit.has_selection(ed) {
		return
	}
	head := ed.selection[0]
	before := string(ed.builder.buf[:head])
	start := strings.last_index_any(before, " \t\n") + 1
	token := before[start:]
	for e in EMOTICONS {
		if token != e.text {
			continue
		}
		// Own undo step, so Ctrl+Z brings back the literal ":)".
		edit.undo_state_push(ed, &ed.undo)
		ed.last_edit_time = ed.current_time
		ed.selection = {start, head}
		edit.input_text(ed, e.emoji)
		return
	}
}
