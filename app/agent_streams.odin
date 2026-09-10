package main

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:thread"
import marmot "../marmot"

@(private)
AGENT_STREAM_START :: u64(1200)
@(private)
AGENT_ACTIVITY :: u64(1201)
@(private)
AGENT_OPERATION :: u64(1202)
@(private)
AGENT_PREVIEW_BYTES :: 256 * 1024

@(private)
Agent_Preview :: struct {
	mutex: sync.Mutex,
	client: ^marmot.Client,
	account, group, stream, message, sender: string,
	started_at: u64,
	worker: ^thread.Thread,
	text: [dynamic]u8,
	cancel, done, dirty, failed, final, checkpoint: bool,
}

@(private = "file")
agent_previews: map[string]^Agent_Preview
@(private = "file")
agent_retired: [dynamic]^Agent_Preview
@(private = "file")
agent_account, agent_group: string

@(private)
agent_projection :: proc(record: ^marmot.Timeline_Message_Record) -> (id, status: string) {
	if record.agent_text_stream_json == nil {
		return
	}
	projection: struct { stream_id_hex, status: string }
	if json.unmarshal(transmute([]u8)string(record.agent_text_stream_json), &projection, allocator = context.temp_allocator) != nil {
		return
	}
	if len(projection.stream_id_hex) != 64 {
		return
	}
	for ch in projection.stream_id_hex {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f' || ch >= 'A' && ch <= 'F') {
			return
		}
	}
	return strings.to_lower(projection.stream_id_hex, context.temp_allocator), projection.status
}

// Bound the UTF-8 preview while the authoritative MLS transcript is pending.
@(private)
agent_set_text :: proc(p: ^Agent_Preview, text: string) {
	clear(&p.text)
	start := max(0, len(text) - AGENT_PREVIEW_BYTES)
	for start < len(text) && text[start] & 0xc0 == 0x80 {
		start += 1
	}
	append(&p.text, ..transmute([]u8)text[start:])
	p.dirty = true
}

@(private)
agent_apply :: proc(p: ^Agent_Preview, update: ^marmot.Agent_Stream_Update) {
	if p.cancel || p.final || p.failed {
		return
	}
	switch update.tag {
	case .CHUNK:
		text := string(update.data.chunk.text)
		if len(p.text) + len(text) > AGENT_PREVIEW_BYTES {
			// ponytail: copy only at the 256 KiB ceiling; use a ring if profiling warrants it.
			joined := strings.concatenate({string(p.text[:]), text})
			agent_set_text(p, joined)
			delete(joined)
		} else {
			append(&p.text, ..transmute([]u8)text)
			p.dirty = true
		}
	case .RECORD:
		switch update.data.record.record_type {
		case .CHECKPOINT: // Checkpoints replace the accumulated transcript.
			p.checkpoint = true
			agent_set_text(p, string(update.data.record.text))
		case .ABORT: // Abort: the agent may fall back to a regular chat reply.
			p.failed = true
			p.dirty = true
		case .FINAL_NOTICE:
		case:
		}
	case .FINISHED:
		if !p.checkpoint || len(p.text) == 0 {
			agent_set_text(p, string(update.data.finished.text))
		}
		p.final = true
	case .FAILED:
		p.failed = true
		p.dirty = true
	case .STATUS, .PROGRESS:
	}
}

@(private)
agent_worker :: proc(t: ^thread.Thread) {
	p := (^Agent_Preview)(t.data)
	defer {
		sync.lock(&p.mutex)
		if !p.final {
			p.failed = true
			p.dirty = true
		}
		p.done = true
		sync.unlock(&p.mutex)
	}
	account := strings.clone_to_cstring(p.account)
	group := strings.clone_to_cstring(p.group)
	stream := strings.clone_to_cstring(p.stream)
	defer delete(account)
	defer delete(group)
	defer delete(stream)
	sub: ^marmot.Agent_Stream_Subscription
	if marmot.watch_agent_text_stream(p.client, account, group, stream, nil, 0, 0, &sub) != .OK {
		return
	}
	defer marmot.agent_stream_free(sub)
	for {
		sync.lock(&p.mutex)
		stop := p.cancel || p.final || p.failed
		sync.unlock(&p.mutex)
		if stop {
			return
		}
		update: ^marmot.Agent_Stream_Update
		status := marmot.agent_stream_next(sub, 100, &update)
		if status == .TIMEOUT {
			continue
		}
		if status != .OK {
			return
		}
		sync.lock(&p.mutex)
		agent_apply(p, update)
		sync.unlock(&p.mutex)
		marmot.agent_stream_update_free(update)
	}
}

@(private)
agent_scope :: proc(account, group: string) {
	if account == agent_account && group == agent_group {
		return
	}
	for key, p in agent_previews {
		sync.lock(&p.mutex)
		p.cancel = true
		sync.unlock(&p.mutex)
		append(&agent_retired, p)
		delete(key)
	}
	clear(&agent_previews)
	delete(agent_account)
	delete(agent_group)
	agent_account = strings.clone(account)
	agent_group = strings.clone(group)
}

// Discover starts before building rows. Scan finals first so page order cannot
// resurrect a preview. Sender is part of the key: another member cannot retire it.
@(private)
agent_collect :: proc(client: ^marmot.Client, ui: ^Ui_State, page: ^marmot.Timeline_Page) {
	agent_scope(ui.account_ref, ui.chats[ui.selected].group_id)
	for pass in 0 ..< 2 {
		for i in 0 ..< page.messages_len {
			r := &page.messages[i]
			id, status := agent_projection(r)
			if len(id) == 0 || r.sender == nil || (status != "started" && status != "finalized") || (status == "started" && r.kind != AGENT_STREAM_START) {
				continue
			}
			is_final := status == "finalized"
			if (pass == 0) != is_final {
				continue
			}
			key := strings.concatenate({string(r.sender), ":", id}, context.temp_allocator)
			p := agent_previews[key]
			if p == nil {
				p = new(Agent_Preview)
				p.client = client
				p.account = strings.clone(agent_account)
				p.group = strings.clone(agent_group)
				p.stream = strings.clone(id)
				p.sender = strings.clone(string(r.sender))
				p.message = strings.clone(string(r.message_id_hex))
				p.started_at = r.timeline_at
				agent_previews[strings.clone(key)] = p
				if !is_final && !r.deleted && r.invalidation_status == nil && !ui.hidden[p.message] {
					p.worker = thread.create(agent_worker)
					p.worker.data = p
					thread.start(p.worker)
				}
			}
			if is_final || r.deleted || r.invalidation_status != nil || ui.hidden[string(r.message_id_hex)] {
				sync.lock(&p.mutex)
				p.cancel = true
				sync.unlock(&p.mutex)
			}
		}
	}
	// A plain reply is the mobile fallback for an agent that abandons QUIC.
	// Only retire an unambiguous preview from the same authenticated sender.
	by_sender := make(map[string]struct { count: int, preview: ^Agent_Preview }, context.temp_allocator)
	for _, p in agent_previews {
		sync.lock(&p.mutex)
		active := !p.cancel && !p.failed && !p.final
		sync.unlock(&p.mutex)
		if active {
			entry := by_sender[p.sender]
			entry.count += 1
			entry.preview = p
			by_sender[p.sender] = entry
		}
	}
	for i in 0 ..< page.messages_len {
		r := &page.messages[i]
		if r.kind != 9 || r.agent_text_stream_json != nil || r.deleted || r.invalidation_status != nil {
			continue
		}
		entry := by_sender[string(r.sender)]
		if entry.count == 1 && r.timeline_at > entry.preview.started_at {
			sync.lock(&entry.preview.mutex)
			entry.preview.cancel = true
			sync.unlock(&entry.preview.mutex)
		}
	}
}

@(private)
agent_body :: proc(record: ^marmot.Timeline_Message_Record) -> (string, bool) {
	id, _ := agent_projection(record)
	key := strings.concatenate({string(record.sender), ":", id}, context.temp_allocator)
	p := agent_previews[key]
	if p == nil {
		return "", false
	}
	sync.lock(&p.mutex)
	defer sync.unlock(&p.mutex)
	if p.cancel || p.failed {
		return "", false
	}
	return len(p.text) > 0 ? strings.clone(string(p.text[:]), context.temp_allocator) : "…", true
}

@(private)
agent_tick :: proc(ui: ^Ui_State, scroll: enum { Follow, Hold }) {
	group := ui.selected >= 0 ? ui.chats[ui.selected].group_id : ""
	agent_scope(ui.account_ref, group)
	changed: map[string]^Agent_Preview
	for _, p in agent_previews {
		sync.lock(&p.mutex)
		if p.dirty && !sel_dragging {
			changed[p.message] = p
			p.dirty = false
		}
		done := p.done
		sync.unlock(&p.mutex)
		if done && p.worker != nil {
			thread.join(p.worker)
			thread.destroy(p.worker)
			p.worker = nil
		}
	}
	defer delete(changed)
	for i := len(ui.messages) - 1; i >= 0 && len(changed) > 0; i -= 1 {
		msg := &ui.messages[i]
		p := changed[msg.id]
		if p == nil {
			continue
		}
		sel_clear(ui)
		sync.lock(&p.mutex)
		if p.cancel || p.failed {
			ordered_remove(&ui.messages, i)
		} else {
			delete(msg.body)
			msg.body = strings.clone(string(p.text[:]))
		}
		sync.unlock(&p.mutex)
		if scroll == .Follow {
			ui.scroll_pending = true
		}
	}
	agent_reap()
}

@(private)
agent_reap :: proc() {
	for i := len(agent_retired) - 1; i >= 0; i -= 1 {
		p := agent_retired[i]
		sync.lock(&p.mutex)
		done := p.done || p.worker == nil
		sync.unlock(&p.mutex)
		if !done {
			continue
		}
		if p.worker != nil {
			thread.join(p.worker)
			thread.destroy(p.worker)
		}
		delete(p.account)
		delete(p.group)
		delete(p.stream)
		delete(p.sender)
		delete(p.message)
		delete(p.text)
		free(p)
		ordered_remove(&agent_retired, i)
	}
}

@(private)
agent_shutdown :: proc() {
	agent_scope("", "")
	for p in agent_retired {
		if p.worker != nil {
			thread.join(p.worker)
			thread.destroy(p.worker)
			p.worker = nil
		}
	}
	agent_reap()
	delete(agent_previews)
	delete(agent_retired)
}
