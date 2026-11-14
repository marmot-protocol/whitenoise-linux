package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:thread"

import marmot "../marmot"
import "nendo"
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
Nip46_State :: struct {
	state, detail, auth_url: string,
}
// The permission snapshot MDK requires the user to review, then approve
// verbatim, before a session may pair or connect.
@(private)
Nip46_Grants :: struct {
	version: u32,
	grants:  []string,
}
@(private)
Nip46_Account :: struct {
	account:          string,
	client:           ^marmot.Client,
	handle:           ^marmot.Nip46_Session,
	state:            Nip46_State,
	// Non-empty while a vault export from before MDK owned signer
	// credentials waits for approval; allowed is the user's click.
	grants:           Nip46_Grants,
	allowed:          bool,
	attach:           ^thread.Thread,
	attach_joined:    bool,
	registered:       bool,
	switch_requested: bool,
	attach_error:     string,
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
// account defaults to the active one.
@(private)
account_local :: proc(ui: ^Ui_State, account := "") -> bool {
	ref := account != "" ? account : ui.account_ref
	for row in ui.accounts {if row.id_hex == ref {return row.local && !row.external}}
	return false
}
@(private)
nip46_review :: proc(handle: ^marmot.Nip46_Session) -> (grants: Nip46_Grants, err: string) {
	text: cstring
	if marmot.nip46_review_grants(handle, &text) != .OK {return {}, marmot.last_error()}
	defer marmot.string_free(text)
	if json.unmarshal(transmute([]u8)string(text), &grants) != nil {
		nip46_grants_free(&grants)
		return {}, strings.clone(tr("Couldn't read the signer permissions. Please try again."))
	}
	return grants, ""
}
@(private)
nip46_approve :: proc(handle: ^marmot.Nip46_Session, grants: Nip46_Grants) -> string {
	list := make([]cstring, len(grants.grants), context.temp_allocator)
	for grant, i in grants.grants {list[i] = strings.clone_to_cstring(grant, context.temp_allocator)}
	if marmot.nip46_approve_grants(handle, grants.version, raw_data(list), uint(len(list))) !=
	   .OK {return marmot.last_error()}
	return ""
}
@(private)
nip46_grants_free :: proc(grants: ^Nip46_Grants) {
	for grant in grants.grants {delete(grant)}
	delete(grants.grants); grants^ = {}
}
// Boot, after client_start restored MDK-owned sessions. A session saved
// only in the vault predates that; it is imported once the user approves
// its permissions, then the vault copy is removed.
@(private)
nip46_restore :: proc(client: ^marmot.Client) {
	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(client, &accounts) != .OK {return}
	defer marmot.account_summary_list_free(accounts)
	for i in 0 ..< accounts.len {
		row := accounts.items[i]
		if !row.external_signing || row.signed_out {continue}
		account := string(row.account_id_hex)
		item := new(Nip46_Account)
		item.account, item.client = strings.clone(account), client
		item.state.state = strings.clone("connecting")
		if marmot.nip46_resume(client, row.account_id_hex, &item.handle) == .OK {
			item.registered = true
			append(&nip46_accounts, item)
			continue
		}
		descriptor, found := vault_get(fmt.tprintf("nip46:%s", account))
		status := marmot.Status.SECRET_NOT_FOUND
		if found {
			config := strings.clone_to_cstring(descriptor)
			status = marmot.nip46_new(client, config, &item.handle)
			mem.zero_slice(transmute([]u8)string(config)); delete(config)
			mem.zero_slice(transmute([]u8)descriptor); delete(descriptor)
		}
		err: string
		if status == .OK {item.grants, err = nip46_review(item.handle)}
		if status != .OK || err != "" {
			delete(err)
			nip46_account_free(item)
			continue
		}
		append(&nip46_accounts, item)
	}
}
@(private = "file")
nip46_attach_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	item := (^Nip46_Account)(t.data)
	if item.allowed {
		item.attach_error = nip46_approve(item.handle, item.grants)
		if item.attach_error != "" {return}
	}
	user: cstring
	if marmot.nip46_connect(item.handle, &user) !=
	   .OK {item.attach_error = marmot.last_error(); return}
	marmot.string_free(user)
	if marmot.nip46_register(
		   item.client,
		   strings.clone_to_cstring(item.account, context.temp_allocator),
		   item.handle,
	   ) !=
	   .OK {item.attach_error = marmot.last_error(); return}
	item.registered = true
	// MDK now keeps the credentials; the vault copy only served the import.
	if vault_remove(fmt.tprintf("nip46:%s", item.account)) !=
	   .None {item.attach_error = strings.clone(tr("Your signer is connected, but its old record could not be removed from the encrypted vault."))}
}
// The user allowed a pending import's permissions: approve, connect, register.
@(private)
nip46_allow :: proc(item: ^Nip46_Account) {
	if item.attach != nil || len(item.grants.grants) == 0 {return}
	item.allowed = true
	nip46_attach_start(item)
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
	marmot.nip46_free(item.handle)
	delete(item.account); delete(item.attach_error)
	nip46_grants_free(&item.grants)
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
			if item.registered {nip46_grants_free(&item.grants)}
			item.allowed = false
			if item.attach_error != "" {
				set_status(ui, strings.clone(nip46_detail(item.attach_error)), .Error)
				delete(item.attach_error); item.attach_error = ""
				item.switch_requested = item.switch_requested && item.registered
			}
		}
		// Boot asks to open the last account once its signer is usable.
		if item.switch_requested && item.attach == nil && item.registered {
			item.switch_requested = false
			account_job_start(account_job_new(ui, item.client, .Switch, item.account))
		}
	}
	if rl.GetTime() - nip46_polled < 0.5 {return}
	nip46_polled = rl.GetTime()
	if auth_job != nil &&
	   auth_job.session != nil {nip46_snapshot(auth_job.session, &auth_job.signer_state)}
	for item in nip46_accounts {
		if account_departing(item.account) {continue}
		nip46_snapshot(item.handle, &item.state)
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
	case "reconnecting":
		return tr("Reconnecting to your signer")
	case "listening":
		return tr("Waiting for your signer")
	case "permission_approval":
		return tr("Review signer permissions")
	case "disconnected":
		return tr("Signer disconnected")
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

// detail is MDK's NIP-46 error text, from state JSON or last_error.
@(private)
nip46_detail :: proc(detail: string) -> string {
	if strings.contains(detail, "directory lookup did not complete") {
		return tr(
			"Couldn't find your account on the relays. Check your relay settings and try again.",
		)
	}
	switch detail {
	case "remote signer unavailable":
		return tr("Your signer is unavailable.")
	case "remote signer disconnected":
		return tr("Your signer is disconnected.")
	case "NIP-46 permissions require explicit approval":
		return tr("Allow the signer permissions to continue.")
	case "remote signer request cancelled":
		return tr("The signer request was cancelled.")
	case "remote signer session logged out":
		return tr("Your signer session has ended.")
	case "remote signer rejected the request":
		return tr("Your signer rejected the request.")
	case "remote signer request timed out":
		return tr("Couldn't reach your signer. Please try again.")
	case "remote signer identity or signed event mismatch":
		return tr("Couldn't verify your signer. Reconnect to the intended signer.")
	case "remote signer method unsupported":
		return tr(
			"Couldn't complete the signer request. Use a signer that supports this operation.",
		)
	case "remote signer request queue full":
		return tr("Couldn't send the signer request. Wait a moment and try again.")
	case "NIP-46 credential storage failed":
		return tr("Couldn't save your signer session in the encrypted vault. Please try again.")
	case "invalid NIP-46 configuration or protocol response",
	     "NIP-46 relay publication failed",
	     "no matching active NIP-46 request":
		return tr("Couldn't complete the signer request. Please try again.")
	}
	return detail
}

// One line per grant kind; MDK's grants are sign_event:<kind> and nip44_*.
@(private)
nip46_grants_ui :: proc(grants: Nip46_Grants) {
	kinds := make([dynamic]string, context.temp_allocator)
	for grant in grants.grants {
		if strings.has_prefix(grant, "sign_event:") {append(&kinds, grant[len("sign_event:"):])}
	}
	style := nendo.Text_Style {
		font  = FONT_BODY,
		size  = 12,
		color = TEXT_DIM,
	}
	if len(kinds) > 0 {
		nendo.text(
			fmt.tprintf(
				tr("Sign events of these kinds: %s"),
				strings.join(kinds[:], ", ", context.temp_allocator),
			),
			style,
		)
	}
	for grant in grants.grants {
		switch {
		case strings.has_prefix(grant, "sign_event:"):
		case grant == "nip44_encrypt":
			nendo.text(tr("Encrypt with NIP-44"), style)
		case grant == "nip44_decrypt":
			nendo.text(tr("Decrypt with NIP-44"), style)
		case:
			nendo.text(grant, style)
		}
	}
}

@(private)
nip46_status_ui :: proc(ui: ^Ui_State, account: string, index: u32) {
	item := nip46_find(account)
	if item ==
	   nil {nendo.text(tr("Signer unavailable. Reconnect from Add account."), {font = FONT_BODY, size = 11, color = TEXT_DIM}); return}
	state := item.state.state == "ready" && item.attach != nil ? "connecting" : item.state.state
	nendo.text(
		nip46_label(state),
		{font = FONT_BODY, size = 11, color = state == "ready" ? ACCENT : TEXT_DIM},
	)
	if item.state.detail !=
	   "" {nendo.text(nip46_detail(item.state.detail), {font = FONT_BODY, size = 11, color = TEXT_DIM})}
}
@(private)
login_pair_clear :: proc(ui: ^Ui_State) {
	if ui.login_qr != nil {rl.UnloadTexture(ui.login_qr^); free(ui.login_qr); ui.login_qr = nil}
	session_string_forget(&ui.login_uri)
}
// Opens the session offline and stops on the permission review; the
// sign-in worker approves, pairs and connects after "Allow and connect".
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
	grants, err := nip46_review(handle)
	if err != "" {ui.login_error = err; marmot.nip46_free(handle); return}
	login_pair_clear(ui)
	start_auth(ui, client, "", method, handle)
	auth_job.grants = grants
}

// The pairing offer landed: show its code while the worker connects.
@(private)
login_pair_show :: proc(ui: ^Ui_State, uri: string) {
	login_pair_clear(ui)
	ui.login_uri = strings.clone(uri)
	if image, ok := qr_image(ui.login_uri);
	   ok {ui.login_qr = new(rl.Texture2D); ui.login_qr^ = rl.LoadTextureFromImage(image)}
}
