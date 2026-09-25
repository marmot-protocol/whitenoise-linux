// Native desktop notifications for incoming messages. Notification helpers
// are fire-and-forget; message text is quoted as data, never shell code.
package main

import "core:fmt"
import "core:strings"

_ :: fmt

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

do_notify :: proc(
	ui: ^Ui_State,
	title: string,
	body: string,
	force := Notify_Force.Respect_Toggle,
) {
	if !ui.prefs.notify_desktop && force == .Respect_Toggle {
		return
	}
	shown := ui.prefs.notify_preview ? body : tr("New message")
	when ODIN_OS == .Windows {
		// A transient tray icon works for unpacked releases without requiring
		// a Store identity or an installed Start Menu shortcut.
		sound := ui.prefs.notify_sound ? "[System.Media.SystemSounds]::Asterisk.Play();" : ""
		spawn_cmd(
			fmt.tprintf(
				"Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Information; $n.Visible = $true; $n.BalloonTipTitle = %s; $n.BalloonTipText = %s; $n.ShowBalloonTip(10000); %s Start-Sleep -Seconds 10; $n.Dispose()",
				shell_quote(title),
				shell_quote(shown),
				sound,
			),
		)
	} else when ODIN_OS == .Darwin {
		script := `on run argv
display notification (item 2 of argv) with title (item 1 of argv)
end run`
		spawn_argv({"osascript", "-e", script, "--", title, shown})
		if ui.prefs.notify_sound {spawn_argv({"afplay", "/System/Library/Sounds/Glass.aiff"})}
	} else {
		spawn_argv({"notify-send", "-a", "White Noise", "--", title, shown})
		if ui.prefs.notify_sound {spawn_cmd(NOTIFY_SOUND)}
	}
}
