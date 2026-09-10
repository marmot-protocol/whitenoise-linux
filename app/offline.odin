// Offline send queue: pending sends that fail on a transport-shaped
// error persist to disk and auto-retry. The queue is message bodies and
// attachment bytes, so it is sealed with the vault's blob subkey
// (vault.odin) at $home/offline-queue.json, mode 0600.
//
//   drain_sends ──► queued (retryable, attempts < cap)
//        │              │ flush_queued (30s timer + boot)
//        │              ▼
//        └────────► failed (tap to retry) / removed on ack
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import rl "sdlrl"

import marmot "../marmot"

MAX_SEND_ATTEMPTS :: 8
FLUSH_INTERVAL :: 30 * time.Second

// Statuses that read as "network/runtime unreachable" rather than a
// definitive rejection. marmot has no dedicated offline error, so
// this is a heuristic: transport/runtime-shaped failures queue for
// auto-retry, everything else fails outright.
send_retryable :: proc(s: marmot.Status) -> bool {
	#partial switch s {
	case .TIMEOUT, .PUBLISH, .TRANSPORT_CLOSED, .RUNTIME_STOPPING,
	     .STORAGE_BUSY, .IO, .RUNTIME, .RUNTIME_BUSY,
	     .ACCOUNT_SESSION_BUSY, .ACCOUNT_WORKER_BUSY,
	     .ACCOUNT_WORKER_RESPONSE_TIMED_OUT, .GROUP_SEND_QUEUE_FULL:
		return true
	}
	return false
}

// On-disk shapes; media_type is re-derived from the name on load so
// the Pending_Att keeps its static-literal contract.
Offline_Att :: struct {
	name: string,
	dim:  string, // "WxH", "" for non-images
	data: string, // base64 plaintext bytes
}

Offline_Item :: struct {
	group_id: string,
	sender:   string,
	body:     string,
	reply_to: string,
	attempts: int,
	atts:     [dynamic]Offline_Att,
}

offline_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/offline-queue.json", data_home, allocator = allocator)
}

// Persist every pending row that has failed at least once (queued,
// failed, or mid-retry). Fresh first sends stay memory-only; the file
// is removed once the queue drains.
save_offline :: proc(ui: ^Ui_State) {
	items := make([dynamic]Offline_Item, context.temp_allocator)
	for p in ui.pending {
		if p.dismissed {
			continue
		}
		if !p.queued && !p.failed && p.attempts == 0 {
			continue
		}
		item := Offline_Item{
			group_id = p.group_id,
			sender   = p.sender,
			body     = p.body,
			reply_to = p.reply_to,
			attempts = p.attempts,
		}
		item.atts = make([dynamic]Offline_Att, context.temp_allocator)
		for a in p.atts {
			b64 := base64.encode(a.data, base64.ENC_TABLE, context.temp_allocator)
			append(&item.atts, Offline_Att{name = a.name, dim = a.dim, data = b64})
		}
		append(&items, item)
	}

	path := offline_path()
	if len(items) == 0 {
		os.remove(path)
		return
	}
	data, err := json.marshal(items[:], allocator = context.temp_allocator)
	if err != nil {
		return
	}
	sealed, ok := vault_seal_blob(data, context.temp_allocator)
	if !ok {
		return
	}
	_ = os.write_entire_file(path, sealed, perm = {.Read_User, .Write_User})
}

// Restore the queue as queued pending rows on boot; the first
// flush_queued tick re-sends them. Image attachments re-decode their
// thumbnail like the forward path.
load_offline :: proc(ui: ^Ui_State) {
	sealed, read_err := os.read_entire_file(offline_path(), context.temp_allocator)
	if read_err != nil {
		return
	}
	// Sealed under a previous vault password: unreadable, so drop it
	// rather than keep a queue nothing can send.
	data, opened := vault_open_blob(sealed, context.temp_allocator)
	if !opened {
		os.remove(offline_path())
		return
	}

	items: [dynamic]Offline_Item
	if json.unmarshal(data, &items) != nil {
		return
	}

	for &item in items {
		send_ticket += 1
		p := Pending_Send{
			ticket   = send_ticket,
			group_id = item.group_id, // unmarshal allocated; adopt
			sender   = item.sender,
			body     = item.body,
			reply_to = item.reply_to,
			attempts = item.attempts,
			queued   = true,
		}
		for att in item.atts {
			bytes, b64_err := base64.decode(att.data)
			delete(att.data)
			if b64_err != nil {
				delete(att.name)
				delete(att.dim)
				continue
			}
			a := Pending_Att{
				name       = att.name,
				media_type = media_type_for(att.name),
				dim        = att.dim,
				data       = bytes,
			}
			if strings.has_prefix(a.media_type, "image/") {
				ext := strings.clone_to_cstring(fmt.tprintf(".%s", strings.trim_prefix(a.media_type, "image/")), context.temp_allocator)
				image := rl.LoadImageFromMemory(ext, raw_data(a.data), i32(len(a.data)))
				if image.data != nil {
					a.tex = new(rl.Texture2D)
					a.tex^ = rl.LoadTextureFromImage(image)
					rl.UnloadImage(image)
				}
			}
			append(&p.atts, a)
		}
		delete(item.atts)
		append(&ui.pending, p)
	}
	delete(items)
}

next_flush: time.Time

@(private)
delete_pending :: proc(ui: ^Ui_State, index: int) {
	// An active upload still borrows attachment bytes from this row.
	p := &ui.pending[index]
	if !p.failed && !p.queued {
		p.dismissed = true
		save_offline(ui)
		return
	}
	free_pending(p)
	ordered_remove(&ui.pending, index)
	save_offline(ui)
}

// Frame-loop tick: re-send every queued row on a fixed interval. The
// zero next_flush makes the first pass after boot flush immediately.
flush_queued :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 {
		return
	}
	if time.diff(next_flush, time.now()) < 0 {
		return
	}
	next_flush = time.time_add(time.now(), FLUSH_INTERVAL)

	for &p in ui.pending {
		if !p.queued {
			continue
		}
		p.queued = false
		spawn_send(ui, client, &p)
	}
}
