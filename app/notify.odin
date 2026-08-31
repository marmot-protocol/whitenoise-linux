// Desktop notifications for incoming messages, the slint src/notify.rs
// path. One `notify-send` per arrival plus an optional freedesktop
// sound, both fire-and-forget shell spawns.
//
//   live event ──► drain_live ──► should_notify ──► do_notify
//                  (chat rows)     (pure gate)      (notify-send)
package main

import "core:fmt"
import "core:strings"

// Chat message; everything else on a group (kind-1009 edits, kind-5
// deletes, kind-7 reactions, kind-1210 system rows) must not notify.
KIND_CHAT_MESSAGE :: 9

NOTIFY_SOUND :: "paplay /usr/share/sounds/freedesktop/stereo/message.oga || canberra-gtk-play -i message-new-instant"

// group id → the message id last notified for it. Dedupes a refire on
// the same latest message: an edit or reaction rewrites the chat row
// without changing the row's latest message id.
// ponytail: unbounded in group count (one short string per chat, and
// chats are already all resident in ui.chats); cap it if that changes.
@(private = "file")
notify_seen: map[string]string

// Everything the gate reads, so it stays a pure predicate one test can
// drive.
Notify_Gate :: struct {
	enabled: bool, // prefs.notify_desktop
	focused: bool, // the app window has input focus
	viewing: bool, // this chat is the open conversation
	muted:   bool, // marmot's per-chat mute
	from_me: bool, // own send, already on screen
	fresh:   bool, // the chat's unread count went up in this update
	kind:    u64, // latest message's event kind
	msg_id:  string, // latest message id, "" = none
	seen_id: string, // last id notified for this group
}

should_notify :: proc(g: Notify_Gate) -> bool {
	if !g.enabled || g.muted || g.from_me || !g.fresh {
		return false
	}
	// A focused window showing the chat is not a missed message;
	// anything else (another chat, or the app in the background) is.
	if g.focused && g.viewing {
		return false
	}
	if g.kind != KIND_CHAT_MESSAGE || len(g.msg_id) == 0 {
		return false
	}
	return g.msg_id != g.seen_id
}

notify_seen_id :: proc(group_id: string) -> string {
	return notify_seen[group_id]
}

// Record a chat's latest message id whether or not it notified, so
// switching away from an open chat later doesn't re-announce it.
notify_mark :: proc(group_id: string, msg_id: string) {
	if len(msg_id) == 0 || notify_seen[group_id] == msg_id {
		return
	}
	if old, ok := notify_seen[group_id]; ok {
		delete(old)
		notify_seen[group_id] = strings.clone(msg_id)
		return
	}
	notify_seen[strings.clone(group_id)] = strings.clone(msg_id)
}

// The test button fires past the master toggle, so the user can see
// and hear what they'd be enabling.
Notify_Force :: enum {
	Respect_Toggle,
	Always,
}

do_notify :: proc(ui: ^Ui_State, title: string, body: string, force := Notify_Force.Respect_Toggle) {
	if !ui.prefs.notify_desktop && force == .Respect_Toggle {
		return
	}
	shown := ui.prefs.notify_preview ? body : tr("New message")
	spawn_cmd(fmt.tprintf("notify-send -a 'White Noise' %q %q", title, shown))
	if ui.prefs.notify_sound {
		spawn_cmd(NOTIFY_SOUND)
	}
}
