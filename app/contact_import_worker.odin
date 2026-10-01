package main

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Contact_Import_Added :: struct {
	contact:  Contact_Ui,
	nickname: string,
	blocked:  bool,
}

@(private)
Contact_Import_Job :: struct {
	worker:                                   ^thread.Thread,
	client:                                   ^marmot.Client,
	account, path:                            string,
	presented:                                bool,
	total, processed, added, skipped, failed: int, // atomic progress
	error:                                    string, // translation key, only read after worker completion
	error_record:                             int,
	failure_record:                           int,
	failure_invalid:                          bool,
	failure_detail:                           string,
	imported:                                 [dynamic]Contact_Import_Added,
}

// Deduplicate decoded public keys, not spellings. Reserve even a failed row:
// the batch attempts each unique contact once, and a later duplicate is skipped.
@(private)
contacts_import_key :: proc(
	npub: string,
	seen: ^map[string]bool,
) -> (
	key: string,
	duplicate, valid: bool,
) {
	hrp, bytes, ok := bech32_decode(npub)
	if !ok || hrp != "npub" || len(bytes) != 32 {return}
	key = string(hex.encode(bytes, context.temp_allocator))
	valid = true
	duplicate = seen^[key]
	seen^[key] = true
	return
}

@(private)
contacts_import_start :: proc(ui: ^Ui_State, client: ^marmot.Client, path: string) {
	ui.picking_contacts = false
	if ui.contact_import != nil || client == nil || ui.account_ref == "" {return}
	job := new(Contact_Import_Job)
	job^ = {
		client  = client,
		account = strings.clone(ui.account_ref),
		path    = strings.clone(path),
		total   = -1,
	}
	ui.contact_import = job
	// Start only after the pending state has been rendered once.
}

@(private)
contacts_import_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Contact_Import_Job)(t.data)
	path := strings.to_lower(job.path, context.temp_allocator)
	kind: Contacts_Kind
	if strings.has_suffix(
		path,
		".csv",
	) {kind = .Csv} else if strings.has_suffix(path, ".json") {kind = .Json} else {job.error = N_("Couldn't import contacts. Choose a contacts CSV or JSON export."); return}
	bytes, read_error := os.read_entire_file(job.path, context.temp_allocator)
	if read_error !=
	   nil {job.error = N_("Couldn't read your contacts file. Check the file permissions and try again."); return}
	rows, parse_error, record := contacts_parse(bytes, kind)
	if parse_error != "" {job.error = parse_error; job.error_record = record; return}
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	follows: ^marmot.String_List
	if marmot.account_follows(job.client, account, &follows) != .OK {
		job.error = N_("Couldn't read your existing contacts. Please try again.")
		return
	}
	seen := make(map[string]bool, allocator = context.temp_allocator)
	seen[job.account] = true
	if follows != nil {
		for id in follows.items[:follows.len] {
			if id != nil {seen[strings.clone(string(id), context.temp_allocator)] = true}
		}
		marmot.string_list_free(follows)
	}
	sync.atomic_store(&job.total, len(rows))
	frame_wake()
	for row, i in rows {
		key, duplicate, valid := contacts_import_key(row.npub, &seen)
		if duplicate {
			sync.atomic_add(&job.skipped, 1)
		} else if !valid {
			sync.atomic_add(&job.failed, 1)
			if job.failure_record == 0 {job.failure_record = i + 1; job.failure_invalid = true}
		} else {
			updated: ^marmot.String_List
			user := strings.clone_to_cstring(key, context.temp_allocator)
			status := marmot.follow_user(job.client, account, user, &updated)
			if updated != nil {marmot.string_list_free(updated)}
			if status != .OK {
				sync.atomic_add(&job.failed, 1)
				if job.failure_record == 0 {
					job.failure_record = i + 1
					job.failure_detail = strings.clone(string(marmot.last_error()))
				}
			} else {
				// Published names belong to the contact, not the importer.
				// The SDK accepts the public key only; nickname/block are local.
				name := short_hex(key)
				resolved: cstring
				if marmot.display_name(job.client, user, &resolved) == .OK &&
				   resolved != nil {name = string(resolved)}
				append(
					&job.imported,
					Contact_Import_Added {
						contact = Contact_Ui {
							id_hex = strings.clone(key),
							name = strings.clone(name),
							npub = strings.clone(row.npub),
						},
						nickname = strings.clone(row.nickname),
						blocked = row.blocked,
					},
				)
				if resolved != nil {marmot.string_free(resolved)}
				sync.atomic_add(&job.added, 1)
			}
		}
		sync.atomic_store(&job.processed, i + 1)
		frame_wake()
	}
}

@(private)
contacts_import_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	job := ui.contact_import
	if job == nil {return}
	if job.worker == nil {
		if !job.presented {return}
		job.worker = thread.create(contacts_import_worker)
		job.worker.data = job
		thread.start(job.worker)
		return
	}
	if !thread.is_done(job.worker) {return}
	thread.join(job.worker)
	if job.account == ui.account_ref {
		listed := make(map[string]bool, allocator = context.temp_allocator)
		for contact in ui.contacts {listed[contact.id_hex] = true}
		for &added in job.imported {
			id := added.contact.id_hex
			// A contacts-page refresh can have picked up a successful follow
			// while the batch was still running. Never append a second rail row.
			exists := listed[id]
			if !exists {append(&ui.contacts, added.contact); added.contact = {}}
			listed[id] = true
			old_key, old_value := delete_key(&ui.nicknames, id)
			delete(old_key); delete(old_value)
			if added.nickname != "" {
				ui.nicknames[strings.clone(id)] = strings.clone(added.nickname)
			}
			if _, present := ui.blocked[id]; present {
				ui.blocked[id] = added.blocked
			} else if added.blocked {ui.blocked[strings.clone(id)] = true}
		}
		if len(job.imported) > 0 {save_settings(ui, background = true)}
		if job.error != "" {
			message :=
				job.error_record > 0 ? fmt.aprintf(tr(job.error), job.error_record) : strings.clone(tr(job.error))
			set_status(ui, message, .Error)
			if os.get_env("WN_TEST_CONTACT_IMPORT", context.temp_allocator) !=
			   "" {fmt.printfln("CONTACT_IMPORT error=%s", message)}
		} else {
			result := fmt.tprintf(
				tr("Contacts imported: %d added, %d skipped, %d failed."),
				job.added,
				job.skipped,
				job.failed,
			)
			if job.failed > 0 {
				detail :=
					job.failure_invalid ? fmt.tprintf(tr("Record %d has an invalid npub. Correct it and import again."), job.failure_record) : fmt.tprintf(tr("Couldn't add record %d. %s Check your relay settings and import again."), job.failure_record, job.failure_detail)
				set_status(ui, fmt.aprintf("%s %s", result, detail), .Error)
			} else {set_status(ui, strings.clone(result), .Info)}
			if os.get_env("WN_TEST_CONTACT_IMPORT", context.temp_allocator) != "" {
				fmt.printfln(
					"CONTACT_IMPORT added=%d skipped=%d failed=%d",
					job.added,
					job.skipped,
					job.failed,
				)
			}
		}
	}
	contact_import_stop(ui)
}

@(private)
contact_import_stop :: proc(ui: ^Ui_State) {
	job := ui.contact_import
	ui.picking_contacts = false
	if job == nil {return}
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	for added in job.imported {
		delete(added.contact.id_hex); delete(added.contact.name); delete(added.contact.npub)
		delete(added.nickname)
	}
	delete(job.imported)
	delete(job.account); delete(job.path); delete(job.failure_detail)
	free(job)
	ui.contact_import = nil
}

@(private)
contacts_import_progress :: proc(ui: ^Ui_State) {
	job := ui.contact_import
	if job == nil {return}
	job.presented = true
	total := sync.atomic_load(&job.total)
	processed := sync.atomic_load(&job.processed)
	if clay.UI(clay.ID("ContactsImportProgress"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {12, 12, 8, 8},
			childGap = 6,
		},
		backgroundColor = PANEL,
	},
	) {
		label :=
			total < 0 ? tr("Reading your contacts file and checking existing contacts...") : fmt.tprintf(tr("Importing contacts: %d of %d"), processed, total)
		clay.Text(label, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
		if total < 0 {
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			busy_bar("ContactsImportBusy")
		} else {
			clay.Text(
				fmt.tprintf(
					tr("%d added, %d skipped, %d failed"),
					sync.atomic_load(&job.added),
					sync.atomic_load(&job.skipped),
					sync.atomic_load(&job.failed),
				),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			if clay.UI(clay.ID("ContactsImportTrack"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)}},
				backgroundColor = ROW_BG,
			},
			) {
				if clay.UI(clay.ID("ContactsImportFill"))(
				{
					layout = {
						sizing = {
							width = clay.SizingPercent(
								total > 0 ? f32(processed) / f32(total) : 1,
							),
							height = clay.SizingFixed(4),
						},
					},
					backgroundColor = ACCENT,
				},
				) {}
			}
		}
	}
}
