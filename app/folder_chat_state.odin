package main

import "core:time"

@(private)
Folder_Async_Fact :: enum {
	Mention,
	Pending,
}

@(private)
Folder_Async_Facts :: bit_set[Folder_Async_Fact]

@(private = "file")
folder_set_async_facts :: proc(set: Folder_Rules) -> Folder_Async_Facts {
	facts: Folder_Async_Facts
	for rule in set.rules {
		if rule.kind == .Group_Node {
			facts += folder_set_async_facts(rule.nested)
		} else if rule.kind == .Unread_Mention {
			facts += {.Mention}
		} else if rule.kind == .Pending_Send {
			facts += {.Pending}
		}
	}
	return facts
}

@(private)
folder_async_facts :: proc(prefs: Prefs) -> Folder_Async_Facts {
	facts: Folder_Async_Facts
	for _, set in prefs.folder_rules {facts += folder_set_async_facts(set)}
	return facts
}

@(private)
Folder_Lookup :: struct {
	slots:   map[string]int,
	pending: map[string]bool,
	now_ms:  i64,
}

@(private)
folder_lookup :: proc(ui: ^Ui_State) -> Folder_Lookup {
	lookup := Folder_Lookup {
		slots  = make(map[string]int, len(ui.prefs.folders), context.temp_allocator),
		now_ms = time.now()._nsec / 1_000_000,
	}
	for name, index in ui.prefs.folders {lookup.slots[name] = index}
	if len(ui.pending) == 0 ||
	   ui.account_ref == "" ||
	   account_revoked(ui, ui.account_ref) ||
	   .Pending not_in folder_async_facts(ui.prefs) {return lookup}
	lookup.pending = make(map[string]bool, context.temp_allocator)
	for &send in ui.pending {
		if send.account_ref != ui.account_ref ||
		   send.dismissed ||
		   send.purged ||
		   send.failed ||
		   send.thread_unavailable ||
		   send.acknowledged {continue}
		lookup.pending[send.group_id] = true
	}
	return lookup
}
