package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"
import "core:time"
import rl "sdlrl"

// Owned C rows survive until the send worker completes. The same tags follow
// text, media, thread and retry paths; imeta remains Marmot's responsibility.
@(private)
send_message_tags :: proc(p: ^Pending_Send) -> []marmot.Message_Tag {
	rows := make([dynamic][]string, context.temp_allocator)
	append(&rows, ..sticker_tags(p.sticker))
	for effect in EFFECTS {if effect.id == p.effect {append(&rows, []string{"effect", effect.key}); break}}
	if p.reply_to != "" {
		append(&rows, []string{"e", p.reply_to}, []string{"q", p.reply_to})
	}
	tags := make([]marmot.Message_Tag, len(rows))
	for row, i in rows {
		values := make([]cstring, len(row))
		for value, j in row {values[j] = strings.clone_to_cstring(value)}
		tags[i] = {raw_data(values), uint(len(values))}
	}
	return tags
}

@(private)
queue_sticker_payload :: proc(ui: ^Ui_State, client: ^marmot.Client, job: ^Sticker_Job) {
	info := profile_info(client, ui.account_ref)
	send_ticket += 1
	tex := new(rl.Texture2D)
	tex^ = sticker_texture_load(job.image)
	name := fmt.aprintf("sticker%s", sticker_extension(job.item.mime))
	att := Pending_Att {
		name       = name,
		media_type = media_type_for(name),
		data       = job.data,
		tex        = tex,
	}
	att.dim = strings.clone(job.dim)
	job.data = nil
	p := Pending_Send {
		ticket        = send_ticket,
		visible_since = time.tick_now(),
		group_id      = strings.clone(job.group),
		sender        = strings.clone(info.name != "" ? info.name : "you"),
		sticker       = sticker_ref_clone(job.item.ref),
		effect        = job.effect,
		reply_to      = strings.clone(job.reply),
		thread        = strings.clone(job.root),
	}
	append(&p.atts, att)
	append(&ui.pending, p)
	spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
	ui.scroll_pending = true
}

@(private)
sticker_extension :: proc(mime: string) -> string {
	switch mime {
	case "image/webp":
		return ".webp"
	case "image/jpeg":
		return ".jpg"
	case:
		return ".png"
	}
}
