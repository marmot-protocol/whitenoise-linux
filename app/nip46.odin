package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Login_Method :: enum {
	Menu,
	Import,
	Create,
	Bunker,
	Pair,
}
@(private)
Account_Signing :: struct {
	local, external: bool,
}
@(private)
Nip46_State :: struct {
	state, detail, auth_url: string,
}
@(private)
Nip46_Account :: struct {
	account:          string,
	client:           ^marmot.Client,
	handle:           ^marmot.Nip46_Session,
	state:            Nip46_State,
	attach:           ^thread.Thread,
	attach_joined:    bool,
	registered:       bool,
	switch_requested: bool,
	attach_error:     string,
	persist:          ^thread.Thread,
	persist_joined:   bool,
	persist_error:    string,
}
@(private)
nip46_accounts: [dynamic]^Nip46_Account
@(private = "file")
nip46_polled: f64

@(private)
nip46_find :: proc(account: string) -> ^Nip46_Account {
	for item in nip46_accounts {if item.account == account {return item}}
	return nil
}
@(private)
account_local :: proc(ui: ^Ui_State) -> bool {
	for id, i in ui.account_ids {if id == ui.account_ref && i < len(ui.account_signing) {return ui.account_signing[i].local && !ui.account_signing[i].external}}
	return false
}
@(private)
nip46_store :: proc(handle: ^marmot.Nip46_Session, account: string) -> string {
	descriptor: cstring
	if marmot.nip46_export(handle, &descriptor) != .OK {return marmot.last_error()}
	defer {if descriptor !=
		   nil {mem.zero_slice(transmute([]u8)string(descriptor)); marmot.string_free(descriptor)}}
	if descriptor ==
	   nil {return strings.clone(tr("Couldn't save your signer session. Please try again."))}
	key := fmt.tprintf("nip46:%s", account)
	old, found := vault_get(key)
	defer {mem.zero_slice(transmute([]u8)old); delete(old)}
	if found && old == string(descriptor) {return ""}
	if vault_set(key, string(descriptor)) !=
	   .None {return strings.clone(tr("Couldn't save your signer session in the encrypted vault. Please try again."))}
	return ""
}
@(private = "file")
nip46_persist_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	item := (^Nip46_Account)(t.data)
	item.persist_error = nip46_store(item.handle, item.account)
}
@(private)
nip46_restore :: proc(client: ^marmot.Client) {
	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) != .OK {return}
	defer marmot.account_summary_list_free(accounts)
	for i in 0 ..< accounts.len {
		row := accounts.items[i]
		if !row.external_signing || row.signed_out {continue}
		account := string(row.account_id_hex)
		descriptor, found := vault_get(fmt.tprintf("nip46:%s", account))
		if !found {continue}
		handle: ^marmot.Nip46_Session
		config := strings.clone_to_cstring(descriptor)
		status := marmot.nip46_new(client, config, &handle)
		mem.zero_slice(transmute([]u8)string(config)); delete(config)
		mem.zero_slice(transmute([]u8)descriptor); delete(descriptor)
		if status != .OK {continue}
		item := new(Nip46_Account)
		item.account, item.handle = strings.clone(account), handle
		item.client = client
		item.state.state = strings.clone("connecting")
		append(&nip46_accounts, item)
	}
}
@(private = "file")
nip46_attach_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	item := (^Nip46_Account)(t.data)
	user: cstring
	if marmot.nip46_connect(item.handle, &user) !=
	   .OK {item.attach_error = marmot.last_error(); return}
	marmot.string_free(user)
	item.attach_error = nip46_store(item.handle, item.account)
	if item.attach_error != "" {return}
	if marmot.nip46_register(
		   item.client,
		   strings.clone_to_cstring(item.account, context.temp_allocator),
		   item.handle,
	   ) !=
	   .OK {item.attach_error = marmot.last_error(); return}
	item.registered = true
}
@(private)
nip46_attach_all :: proc() {
	for item in nip46_accounts {
		nip46_attach_start(item)
	}
}
@(private)
nip46_attach_start :: proc(item: ^Nip46_Account) {
	item.attach_joined = false
	item.attach = thread.create(
		nip46_attach_worker,
	); item.attach.data = item; thread.start(item.attach)
}
@(private)
nip46_cancel_all :: proc() {
	if auth_job != nil && auth_job.session != nil {marmot.nip46_cancel(auth_job.session)}
	for item in nip46_accounts {marmot.nip46_cancel(item.handle)}
}
@(private)
nip46_stop :: proc() {
	for item in nip46_accounts {nip46_account_free(item)}
	delete(nip46_accounts); nip46_accounts = {}; nip46_polled = 0
}
@(private)
nip46_account_free :: proc(item: ^Nip46_Account) {
	if item.attach !=
	   nil {if !item.attach_joined {thread.join(item.attach)}; thread.destroy(item.attach)}
	if item.persist !=
	   nil {if !item.persist_joined {thread.join(item.persist)}; thread.destroy(item.persist)}
	if item.registered {err := nip46_store(item.handle, item.account); delete(err)}
	marmot.nip46_free(item.handle)
	delete(item.account); delete(item.persist_error); delete(item.attach_error)
	nip46_state_free(&item.state); free(item)
}
@(private)
nip46_state_free :: proc(state: ^Nip46_State) {
	delete(state.state); delete(state.detail); delete(state.auth_url); state^ = {}
}
@(private)
nip46_snapshot :: proc(handle: ^marmot.Nip46_Session, state: ^Nip46_State) {
	text: cstring
	if marmot.nip46_state(handle, &text) != .OK || text == nil {return}
	defer marmot.string_free(text)
	value: Nip46_State
	if json.unmarshal(transmute([]u8)string(text), &value) != nil {return}
	nip46_state_free(state); state^ = value
}
@(private)
nip46_tick :: proc(ui: ^Ui_State) {
	account_job_drain(ui)
	for item in nip46_accounts {
		if account_departing(item.account) {continue}
		if item.attach != nil && thread.is_done(item.attach) {
			if !item.attach_joined {thread.join(item.attach)}
			thread.destroy(item.attach); item.attach = nil
			if item.attach_error !=
			   "" {set_status(ui, strings.clone(nip46_detail(item.attach_error)), .Error); delete(item.attach_error); item.attach_error = ""}
			if item.switch_requested {
				item.switch_requested = false
				if item.registered {account_job_start(account_job_new(ui, item.client, .Switch, item.account))}
			}
		}
		if item.persist != nil && thread.is_done(item.persist) {
			if !item.persist_joined {thread.join(item.persist)}
			thread.destroy(item.persist); item.persist = nil
			if item.persist_error !=
			   "" {set_status(ui, strings.clone(nip46_detail(item.persist_error)), .Error); delete(item.persist_error); item.persist_error = ""}
		}
	}
	if rl.GetTime() - nip46_polled < 0.5 {return}
	nip46_polled = rl.GetTime()
	if auth_job != nil &&
	   auth_job.session != nil {nip46_snapshot(auth_job.session, &auth_job.signer_state)}
	for item in nip46_accounts {
		if account_departing(item.account) {continue}
		nip46_snapshot(item.handle, &item.state)
		if item.attach == nil &&
		   item.registered &&
		   item.state.state == "ready" &&
		   item.persist == nil &&
		   int(nip46_polled * 2) % 20 == 0 {
			item.persist_joined = false
			item.persist = thread.create(
				nip46_persist_worker,
			); item.persist.data = item; thread.start(item.persist)
		}
	}
}
@(private)
nip46_label :: proc(state: string) -> string {
	switch state {
	case "ready":
		return tr("Signer connected")
	case "approval":
		return tr("Waiting for signer approval")
	case "connecting":
		return tr("Connecting to your signer")
	case "cancelled":
		return tr("Signer cancelled")
	case "logged_out":
		return tr("Signer signed out")
	}
	return tr("Signer unavailable")
}
@(private)
nip46_auth_url :: proc(ui: ^Ui_State, url: string) {
	if !strings.has_prefix(url, "https://") && !strings.has_prefix(url, "http://") {return}
	// Approval is always explicit, never launched by receiving an event.
	delete(
		ui.link_url,
	); ui.link_url = strings.clone(url); ui.link_trust = false; ui.link_open = true
}

@(private)
nip46_detail :: proc(detail: string) -> string {
	switch detail {
	case "remote signer not connected", "remote signer unavailable":
		return tr("Your signer is unavailable.")
	case "connecting to remote signer":
		return tr("Connecting to your signer through its relays.")
	case "remote signer connected":
		return tr("Your signer is connected.")
	case "remote signer approval required":
		return tr("Approve the request in your signer to continue.")
	case "remote signer request cancelled":
		return tr("The signer request was cancelled.")
	case "remote signer session logged out":
		return tr("Your signer session has ended.")
	case "remote signer rejected the request":
		return tr("Your signer rejected the request.")
	case "remote signer request timed out":
		return tr("Couldn't reach your signer. Please try again.")
	case "remote signer public key or signed event mismatch":
		return tr("Couldn't verify your signer. Reconnect to the intended signer.")
	case "remote signer does not support the method":
		return tr(
			"Couldn't complete the signer request. Use a signer that supports this operation.",
		)
	case "invalid NIP-46 configuration or protocol response",
	     "remote signer transport could not start":
		return tr("Couldn't complete the signer request. Please try again.")
	}
	return detail
}

@(private)
nip46_status_ui :: proc(ui: ^Ui_State, account: string, index: u32) {
	item := nip46_find(account)
	if item ==
	   nil {clay.Text(tr("Signer unavailable. Reconnect from Add account."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM}); return}
	state := item.state.state == "ready" && item.attach != nil ? "connecting" : item.state.state
	clay.Text(
		nip46_label(state),
		{fontId = FONT_BODY, fontSize = 11, textColor = state == "ready" ? ACCENT : TEXT_DIM},
	)
	if item.state.detail !=
	   "" {clay.Text(nip46_detail(item.state.detail), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})}
}
@(private)
login_pair_clear :: proc(ui: ^Ui_State) {
	if ui.login_qr != nil {rl.UnloadTexture(ui.login_qr^); free(ui.login_qr); ui.login_qr = nil}
	session_string_forget(&ui.login_uri)
}
@(private)
start_remote_auth :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	method: Login_Method,
	input: string,
) {
	if auth_job != nil {return}
	config: []u8
	if method == .Bunker {
		config, _ = json.marshal(struct {
				uri: string,
			}{input}, allocator = context.temp_allocator)
	} else {
		relays := []string{input}
		config, _ = json.marshal(struct {
				relays: []string,
				name:   string,
			}{relays, "White Noise Linux"}, allocator = context.temp_allocator)
	}
	handle: ^marmot.Nip46_Session
	config_c := strings.clone_to_cstring(string(config))
	defer {mem.zero_slice(config); mem.zero_slice(transmute([]u8)string(config_c))
		delete(config_c)}
	if marmot.nip46_new(client, config_c, &handle) != .OK {
		ui.login_error = marmot.last_error(); return
	}
	uri: cstring
	if marmot.nip46_uri(handle, &uri) !=
	   .OK {ui.login_error = marmot.last_error(); marmot.nip46_free(handle); return}
	login_pair_clear(ui)
	ui.login_uri = strings.clone(
		string(uri),
	); mem.zero_slice(transmute([]u8)string(uri)); marmot.string_free(uri)
	if method == .Pair {
		if image, ok := qr_image(ui.login_uri);
		   ok {ui.login_qr = new(rl.Texture2D); ui.login_qr^ = rl.LoadTextureFromImage(image)}
	}
	start_auth(ui, client, "", method, handle)
}
