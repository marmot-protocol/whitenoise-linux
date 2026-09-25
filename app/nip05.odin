package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

@(private)
nip05_parts :: proc(ref: string) -> (name, domain: string) {
	ref := strings.trim_space(ref)
	at := strings.index_byte(ref, '@')
	if at <= 0 {return "", ""}
	name, domain = ref[:at], ref[at + 1:]
	if len(domain) > 253 {return "", ""}
	for c in name {
		if !(c >= 'a' && c <= 'z' ||
			   c >= '0' && c <= '9' ||
			   c == '-' ||
			   c == '_' ||
			   c == '.') {return "", ""}
	}
	// Validate DNS labels before interpolating the host into an HTTPS URL.
	labels := domain
	for label in strings.split_iterator(&labels, ".") {
		if len(label) == 0 ||
		   len(label) > 63 ||
		   label[0] == '-' ||
		   label[len(label) - 1] == '-' {return "", ""}
		for c in label {
			if !(c >= 'a' && c <= 'z' ||
				   c >= 'A' && c <= 'Z' ||
				   c >= '0' && c <= '9' ||
				   c == '-') {return "", ""}
		}
	}
	if domain == "" || strings.has_suffix(domain, ".") {return "", ""}
	return name, domain
}

@(private)
nip05_parse :: proc(body: []u8, name: string) -> string {
	val, err := json.parse(body)
	if err != nil {return ""}
	defer json.destroy_value(val)
	root, ok := val.(json.Object)
	if !ok {return ""}
	names, valid := root["names"].(json.Object)
	if !valid {return ""}
	key, _ := names[name].(json.String)
	if len(key) != 64 {return ""}
	for c in key {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return ""}
	}
	return strings.clone(key)
}

@(private)
nip05_lookup :: proc(ref: string) -> string {
	name, domain := nip05_parts(ref)
	if name == "" {return ""}
	url := fmt.aprintf("https://%s/.well-known/nostr.json?name=%s", domain, name)
	defer delete(url)
	// NIP-05 forbids redirects. Ignore curlrc so it cannot enable them.
	state, out, stderr, err := os.process_exec(
		{
			command = {
				curl_path(),
				"-q",
				"-sf",
				"--proto",
				"=https",
				"--max-time",
				"10",
				"--max-filesize",
				"1048576",
				"--write-out",
				"\n%{http_code}",
				"--",
				url,
			},
		},
		context.allocator,
	)
	defer delete(out)
	defer delete(stderr)
	if err != nil || state.exit_code != 0 || !strings.has_suffix(string(out), "\n200") {return ""}
	return nip05_parse(out[:len(out) - 4], name)
}

@(private)
nip05_complete :: proc(ui: ^Ui_State, done: Op_Done) {
	defer edit_result_free(done)
	if ui.nip05_ticket != done.ticket {return}
	ui.nip05_ticket = 0
	if ui.account_ref != done.account || ui.page != .Chats {return}
	buf := &ui.nc_member
	if done.group == "" {
		if !ui.new_chat_open {return}
	} else {
		if ui.new_chat_open ||
		   !ui.show_members ||
		   ui.selected < 0 ||
		   ui.chats[ui.selected].group_id != done.group {return}
		buf = &ui.invite_input
	}
	if string(buf[:]) != done.target {return}
	if done.content == "" {
		ui.client_status = strings.clone(
			tr("Couldn't look up that NIP-05 address. Double-check it and try again."),
		)
		return
	}
	ed_set(ui, buf, done.content)
}
