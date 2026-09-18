package main

import "core:fmt"
import marmot "../marmot"

@(private)
failed_edits: [dynamic]Op_Done

@(private)
queue_edit :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.edit_ticket != 0 || ui.selected < 0 || ui.editing == "" { return }
	ui.edit_ticket = spawn_op(ui, client, .Edit, ui.editing, string(ui.compose[:]))
}

@(private)
edit_complete :: proc(ui: ^Ui_State, done: Op_Done) {
	if ui.edit_ticket == done.ticket { ui.edit_ticket = 0 }
	if done.err != "" {
		ui.client_status = fmt.aprintf("%s %s", tr("Couldn't save the edit. Please try again."), done.err)
		append(&failed_edits, done) // switching chats must not discard a failed edit
		shake()
		return
	}
	if ui.account_ref == done.account && ui.selected >= 0 && ui.chats[ui.selected].group_id == done.group &&
		ui.editing == done.target && string(ui.compose[:]) == done.content {
		ui.editing = ""
		ed_set(ui, &ui.compose, ui.drafts[done.group])
	}
	for i := len(failed_edits) - 1; i >= 0; i -= 1 {
		old := failed_edits[i]
		if old.account == done.account && old.group == done.group && old.target == done.target {
			edit_result_free(old)
			ordered_remove(&failed_edits, i)
		}
	}
	edit_result_free(done)
}

@(private)
edit_restore :: proc(ui: ^Ui_State) {
	if ui.selected < 0 { return }
	for i := len(failed_edits) - 1; i >= 0; i -= 1 {
		done := failed_edits[i]
		if done.account == ui.account_ref && done.group == ui.chats[ui.selected].group_id {
			for msg in ui.messages {
				if msg.id == done.target {
					ui.editing = msg.id
					ed_set(ui, &ui.compose, done.content)
					return
				}
			}
		}
	}
}

@(private)
edit_result_free :: proc(done: Op_Done) {
	delete(done.account); delete(done.group); delete(done.target)
	delete(done.content); delete(done.err)
}
