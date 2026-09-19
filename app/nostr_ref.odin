package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

@(private)
Nostr_Kind :: enum { None, Invalid, Profile, Event, Address }

@(private)
Nostr_Ref :: struct {
	kind: Nostr_Kind,
	token, key, author, identifier: string,
	event_kind: u32,
	relays: []string,
}

// Keep malformed public references whole too, so they get an error
// instead of accidentally parsing a valid prefix of a broken token.
@(private)
nostr_at :: proc(text: string, at: int) -> (end: int, ref: Nostr_Ref) {
	if at >= len(text) { return }
	if at > 0 && (text[at - 1] >= 'a' && text[at - 1] <= 'z' || text[at - 1] >= 'A' && text[at - 1] <= 'Z' || text[at - 1] >= '0' && text[at - 1] <= '9') { return }
	start := at
	if text[start] == '@' { start += 1 }
	if strings.has_prefix(text[start:], "nostr:") { start += 6 }
	if strings.has_prefix(text[start:], "https://primal.net/e/") { start += len("https://primal.net/e/") }
	prefix := ""
	for p in ([]string{"npub1", "nprofile1", "note1", "nevent1", "naddr1"}) {
		if len(text) - start >= len(p) && strings.equal_fold(text[start:start + len(p)], p) { prefix = p; break }
	}
	if len(prefix) == 0 { return }
	end = start + len(prefix)
	for end < len(text) {
		c := text[end]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') { break }
		end += 1
	}
	ref.kind, ref.token = .Invalid, text[start:end]
	if len(ref.token) > 5000 { return }
	hrp, data, valid := bech32_decode(ref.token)
	if !valid { return }
	if hrp == "npub" || hrp == "note" {
		if len(data) != 32 { return }
		ref.kind = hrp == "npub" ? .Profile : .Event
		ref.key = string(hex.encode(data, context.temp_allocator))
		return
	}
	hints := make([dynamic]string, context.temp_allocator)
	seen: [4]bool
	special: []u8
	for i := 0; i < len(data); {
		if i + 2 > len(data) { return }
		tag, size := data[i], int(data[i + 1])
		i += 2
		if i + size > len(data) { return }
		value := data[i:i + size]
		i += size
		if tag < 4 && tag != 1 {
			if seen[tag] { return }
			seen[tag] = true
		}
		switch tag {
		case 0:
			if hrp != "naddr" && size != 32 { return }
			special = value
		case 1:
			relay := string(value)
			if strings.has_prefix(relay, "wss://") || strings.has_prefix(relay, "ws://") { append(&hints, relay) }
		case 2:
			if size != 32 { return }
			ref.author = string(hex.encode(value, context.temp_allocator))
		case 3:
			if size != 4 { return }
			for byte in value { ref.event_kind = ref.event_kind << 8 | u32(byte) }
		}
	}
	if !seen[0] { return }
	if hrp == "naddr" {
		if !seen[2] || !seen[3] || !utf8.valid_string(string(special)) { return }
		k := ref.event_kind
		if !(k == 0 || k == 3 || k >= 10000 && k < 20000 || k >= 30000 && k < 40000) { return }
		ref.kind, ref.identifier = .Address, string(special)
		ref.key = strings.to_lower(ref.token, context.temp_allocator)
	} else {
		ref.kind = hrp == "nprofile" ? .Profile : .Event
		ref.key = string(hex.encode(special, context.temp_allocator))
	}
	ref.relays = hints[:]
	return
}

// The identifier is untrusted text. JSON encoding preserves quotes,
// backslashes and empty d-tags without changing the relay filter.
@(private)
nev_request :: proc(key: string) -> string {
	_, ref := nostr_at(key, 0)
	if ref.kind != .Address { return fmt.tprintf(`["REQ","wn",{{"ids":["%s"]}}]`, key) }
	if ref.event_kind < 30000 {
		return fmt.tprintf(`["REQ","wn",{{"authors":["%s"],"kinds":[%d],"limit":1}}]`, ref.author, ref.event_kind)
	}
	identifier, err := json.marshal(ref.identifier, allocator = context.temp_allocator)
	if err != nil { return "" }
	return fmt.tprintf(`["REQ","wn",{{"authors":["%s"],"kinds":[%d],"#d":[%s],"limit":1}}]`, ref.author, ref.event_kind, string(identifier))
}

// NIP-65 write relays locate an author's events after the fetch relays miss.
@(private)
nev_relay_urls :: proc(body: []u8, author: string) -> []string {
	value, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil { return nil }
	defer json.destroy_value(value, allocator = context.temp_allocator)
	message, ok := value.(json.Array)
	if !ok || len(message) != 3 { return nil }
	type, _ := message[0].(json.String)
	subscription, _ := message[1].(json.String)
	if type != "EVENT" || subscription != "wn" { return nil }
	event, is_event := message[2].(json.Object)
	if !is_event { return nil }
	pubkey, _ := event["pubkey"].(json.String)
	kind, _ := event["kind"].(json.Float)
	if pubkey != json.String(author) || kind != 10002 { return nil }
	tags, _ := event["tags"].(json.Array)
	relays := make([dynamic]string, context.temp_allocator)
	for tag in tags {
		parts, ok := tag.(json.Array)
		if !ok || len(parts) < 2 { continue }
		name, _ := parts[0].(json.String)
		url, _ := parts[1].(json.String)
		if name != "r" { continue }
		if len(parts) > 2 {
			mode, _ := parts[2].(json.String)
			if mode != "" && mode != "write" { continue }
		}
		if !strings.has_prefix(string(url), "wss://") && !strings.has_prefix(string(url), "ws://") { continue }
		append(&relays, strings.clone(string(url), context.temp_allocator))
		if len(relays) == 8 { break }
	}
	return relays[:]
}
