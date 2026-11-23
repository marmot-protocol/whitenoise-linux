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
import "core:mem"
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
	case .TIMEOUT,
	     .PUBLISH,
	     .TRANSPORT_CLOSED,
	     .RUNTIME_STOPPING,
	     .STORAGE_BUSY,
	     .IO,
	     .RUNTIME,
	     .RUNTIME_BUSY,
	     .ACCOUNT_SESSION_BUSY,
	     .ACCOUNT_WORKER_BUSY,
	     .ACCOUNT_WORKER_RESPONSE_TIMED_OUT,
	     .GROUP_SEND_QUEUE_FULL:
		return true
	}
	return false
}

// On-disk shapes; media_type is re-derived from the name on load so
// the Pending_Att keeps its static-literal contract.
Offline_Att :: struct {
	name:  string,
	dim:   string, // "WxH", "" for non-images
	data:  string, // base64 plaintext bytes
	emoji: string, // NIP-30 shortcode, "" for ordinary attachments
}

Offline_Item :: struct {
	sticker:     Sticker_Ref,
	effect:      int,
	account_ref: string,
	group_id:    string,
	sender:      string,
	body:        string,
	reply_to:    string,
	thread:      string,
	thread_kind: u64, // absent in older queues: unknown, resolved again on send
	attempts:    int,
	atts:        [dynamic]Offline_Att,
}

offline_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/offline-queue.json", data_home, allocator = allocator)
}

@(private)
new_send_paused :: proc(ui: ^Ui_State) -> bool {
	if !account_departing(ui.account_ref) {return false}
	toast(ui, tr("Wait for sign-out to finish before sending."))
	return true
}

@(private)
account_send_paused :: proc(ui: ^Ui_State, account: string) -> bool {
	profile := ui.devices.profiles[account]
	return account_departing(account) || (profile != nil && profile.unlink_check)
}

pending_send_allowed :: proc(ui: ^Ui_State, p: Pending_Send) -> bool {
	return(
		!p.dismissed &&
		!p.purged &&
		!account_departing(p.account_ref) &&
		account_signed_in(ui, p.account_ref) \
	)
}

pending_in_workspace :: proc(ui: ^Ui_State, p: Pending_Send, group: string) -> bool {
	return(
		!p.dismissed &&
		!p.purged &&
		p.account_ref != "" &&
		p.account_ref == ui.account_ref &&
		p.group_id == group &&
		!account_revoked(ui, p.account_ref) \
	)
}

// Persist every pending row that has failed at least once (queued,
// failed, or mid-retry). Fresh first sends stay memory-only; the file
// is removed once the queue drains.
save_offline :: proc(ui: ^Ui_State) {
	items := make([dynamic]Offline_Item, context.temp_allocator)
	append(&items, ..ui.offline_unowned[:])
	for p in ui.pending {
		// Unresolved media preparations have no upload bytes to persist yet.
		if p.dismissed || p.purged || p.gif != nil || p.forward != nil || p.account_ref == "" {
			continue
		}
		if !p.queued && !p.failed && p.attempts == 0 {
			continue
		}
		item := Offline_Item {
			sticker     = p.sticker,
			effect      = p.effect,
			account_ref = p.account_ref,
			group_id    = p.group_id,
			sender      = p.sender,
			body        = p.body,
			reply_to    = p.reply_to,
			thread      = p.thread,
			thread_kind = p.thread_kind,
			attempts    = p.attempts,
		}
		item.atts = make([dynamic]Offline_Att, context.temp_allocator)
		for a in p.atts {
			b64 := base64.encode(a.data, base64.ENC_TABLE, context.temp_allocator)
			append(
				&item.atts,
				Offline_Att{name = a.name, dim = a.dim, data = b64, emoji = a.emoji},
			)
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
	// A failed tag (corrupt file, or a blob from another vault) is
	// unreadable, so drop it rather than keep a queue nothing can send.
	data, opened := vault_open_blob(sealed, context.temp_allocator)
	if !opened {
		os.remove(offline_path())
		return
	}
	defer mem.zero_slice(data)

	items: [dynamic]Offline_Item
	if json.unmarshal(data, &items) != nil {
		return
	}

	for item in items {
		if item.account_ref == "" {
			append(&ui.offline_unowned, item)
			continue
		}
		send_ticket += 1
		p := Pending_Send {
			sticker     = item.sticker,
			effect      = item.effect,
			ticket      = send_ticket,
			account_ref = item.account_ref,
			group_id    = item.group_id, // unmarshal allocated; adopt
			sender      = item.sender,
			body        = item.body,
			reply_to    = item.reply_to,
			thread      = item.thread,
			thread_kind = item.thread_kind,
			attempts    = item.attempts,
			queued      = !account_revoked(ui, item.account_ref),
		}
		p.failed = !p.queued
		for att in item.atts {
			bytes, b64_err := base64.decode(att.data)
			delete(att.data)
			if b64_err != nil {
				delete(att.name)
				delete(att.dim)
				delete(att.emoji)
				continue
			}
			a := Pending_Att {
				name       = att.name,
				media_type = media_type_for(att.name),
				dim        = att.dim,
				data       = bytes,
				emoji      = att.emoji,
			}
			if strings.has_prefix(a.media_type, "image/") {
				ext := strings.clone_to_cstring(
					fmt.tprintf(".%s", strings.trim_prefix(a.media_type, "image/")),
					context.temp_allocator,
				)
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
	if len(ui.offline_unowned) > 0 && !ui.offline_unowned_warned {
		ui.offline_unowned_warned = true
		toast(ui, tr("Old queued messages were kept, but can't be assigned to a profile."))
	}
}

offline_clear :: proc(ui: ^Ui_State) {
	for item in ui.offline_unowned {
		mem.zero_slice(transmute([]u8)item.body)
		sticker_ref_free(item.sticker)
		delete(item.group_id)
		delete(item.sender)
		delete(item.body)
		delete(item.reply_to)
		delete(item.thread)
		for att in item.atts {
			mem.zero_slice(transmute([]u8)att.data)
			delete(att.name)
			delete(att.dim)
			delete(att.data)
			delete(att.emoji)
		}
		delete(item.atts)
	}
	delete(ui.offline_unowned)
	ui.offline_unowned = {}
	ui.offline_unowned_warned = false
}

offline_revoke :: proc(ui: ^Ui_State, account: string) {
	if account == "" {return}
	xdc_revoke(account)
	for &p in ui.pending {
		if p.account_ref == account && p.queued {
			p.queued = false
			p.failed = true
		}
	}
}

@(private)
offline_wipe_persist :: proc(ui: ^Ui_State, account: string) {
	if account == "" {return}
	for &p in ui.pending {if p.account_ref == account {p.purged = true}}
	save_offline(ui)
}

offline_wipe :: proc(ui: ^Ui_State, account: string) {
	if account == "" {return}
	xdc_revoke(account)
	for i := len(ui.pending) - 1; i >= 0; i -= 1 {
		p := &ui.pending[i]
		if p.account_ref != account {continue}
		if !p.failed && !p.queued {continue}
		free_pending(p)
		ordered_remove(&ui.pending, i)
	}
	offline_wipe_persist(ui, account)
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
	forward_settled(ui, p, .Cancelled)
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
		if !p.queued || p.account_ref != ui.account_ref || !pending_send_allowed(ui, p) {
			continue
		}
		p.queued = false
		spawn_send(ui, client, &p)
	}
}
