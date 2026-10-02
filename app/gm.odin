package main

import marmot "../marmot"
import "core:strings"
import "core:time"

// What the GM button sends when the user has not set their own text.
GM_DEFAULT :: "GM"

// Local calendar day as days since the epoch, so the button resets at
// the user's midnight rather than at UTC's.
@(private = "file")
gm_today :: proc() -> i64 {
	now := u64(time.time_to_unix(time.now()))
	return i64(local_seconds(now) / 86400)
}

// True once the open chat has had its GM today.
@(private)
gm_sent_today :: proc(ui: ^Ui_State) -> bool {
	if ui.selected < 0 || ui.selected >= len(ui.chats) {return false}
	day, ok := ui.prefs.gm_sent[ui.chats[ui.selected].group_id]
	return ok && day == gm_today()
}

// Send the user's GM into the open chat, at most once per chat per
// local day. The message takes the composer's reply/thread context and
// armed effect, like a sticker.
@(private)
gm_send :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.selected < 0 || ui.editing != "" || ui.compose_issue != "" || gm_sent_today(ui) {return}

	// Only today's entries gate anything, so older days are dropped:
	// the map holds at most one row per chat greeted today.
	today := gm_today()
	stale := make([dynamic]string, context.temp_allocator)
	for group, day in ui.prefs.gm_sent {
		if day != today {append(&stale, group)}
	}
	for group in stale {
		delete_key(&ui.prefs.gm_sent, group)
		delete(group)
	}
	ui.prefs.gm_sent[strings.clone(ui.chats[ui.selected].group_id)] = today

	text := strings.trim_space(ui.prefs.gm_text)
	if text == "" {text = GM_DEFAULT}
	send_arc(ui, text)
	queue_send(ui, client, text)
	ui.replying = ""
	fx_send_armed(ui)
	play_sound(.Send)
	save_settings(ui, background = true)
}
