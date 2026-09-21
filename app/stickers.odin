package main

import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

import marmot "../marmot"

@(private)
STICKER_PACK_KIND :: 30031
@(private)
STICKER_PACK_LIMIT :: 200
@(private)
STICKER_BYTES_LIMIT :: 4 * 1024 * 1024
@(private)
STICKER_DIM_LIMIT :: 4096

// Pack coordinates identify collections; hashes identify the exact artwork.
// Empty pack means a personal sticker, carried by the wn-sticker extension.
@(private)
Sticker_Ref :: struct {
	pack, code, sha, event, relay: string,
}
@(private)
Sticker_Item :: struct {
	ref:              Sticker_Ref,
	label, mime, url: string,
}
@(private)
Sticker_Pack :: struct {
	coordinate, title, author, event, relay: string,
}
@(private)
Sticker_Event :: struct {
	id, pubkey, sig, content: string,
	kind, created_at:         u64,
	tags:                     [][]string,
}

// Reuse the secp256k1 already linked by the pinned marmot-c bundle.
// The symbol version must follow secp256k1-sys when DEPS_PIN changes.
@(private, default_calling_convention = "c", link_prefix = "rustsecp256k1_v0_10_0_")
foreign _ {
	context_static: rawptr
	xonly_pubkey_parse :: proc(ctx: rawptr, key: ^[64]u8, bytes: [^]u8) -> c.int ---
	schnorrsig_verify :: proc(ctx: rawptr, sig, msg: [^]u8, size: c.size_t, key: ^[64]u8) -> c.int ---
}

@(private)
sticker_hex :: proc(value: string) -> bool {
	if len(value) != 64 {return false}
	for c in value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return true
}

@(private)
Sticker_Name :: enum {
	Code,
	Pack,
}

@(private)
sticker_name_ok :: proc(value: string, kind: Sticker_Name) -> bool {
	if len(value) == 0 || len(value) > (kind == .Code ? 64 : 80) {return false}
	for c in value {
		if c >= 'a' && c <= 'z' ||
		   c >= 'A' && c <= 'Z' ||
		   c >= '0' && c <= '9' ||
		   c == '_' {continue}
		if kind == .Pack && (c == '.' || c == '-') {continue}
		return false
	}
	return true
}

@(private)
sticker_coordinate :: proc(value: string) -> bool {
	return(
		len(value) > 71 &&
		strings.has_prefix(value, "30031:") &&
		sticker_hex(value[6:70]) &&
		value[70] == ':' &&
		sticker_name_ok(value[71:], .Pack) \
	)
}

@(private)
sticker_pack_input :: proc(value: string) -> (coordinate, relay: string) {
	value := strings.trim_space(value)
	if sticker_coordinate(value) {return value, ""}
	end, ref := nostr_at(value, 0)
	if end != len(value) ||
	   ref.kind != .Address ||
	   ref.event_kind != STICKER_PACK_KIND ||
	   !sticker_name_ok(ref.identifier, .Pack) {return}
	coordinate = fmt.tprintf("30031:%s:%s", ref.author, ref.identifier)
	if len(ref.relays) > 0 {relay = ref.relays[0]}
	return
}

@(private)
sticker_ref_clone :: proc(ref: Sticker_Ref) -> Sticker_Ref {
	return {
		strings.clone(ref.pack),
		strings.clone(ref.code),
		strings.clone(ref.sha),
		strings.clone(ref.event),
		strings.clone(ref.relay),
	}
}

@(private)
sticker_ref_free :: proc(ref: Sticker_Ref) {
	for value in ([]string{ref.pack, ref.code, ref.sha, ref.event, ref.relay}) {delete(value)}
}

@(private)
sticker_item_free :: proc(item: Sticker_Item) {
	sticker_ref_free(item.ref)
	delete(item.label); delete(item.mime); delete(item.url)
}

@(private)
sticker_pack_free :: proc(pack: Sticker_Pack) {
	for value in ([]string{pack.coordinate, pack.title, pack.author, pack.event, pack.relay}) {delete(value)}
}

@(private)
sticker_ref_tag :: proc(tag: []string) -> Sticker_Ref {
	if len(tag) == 3 && tag[0] == "wn-sticker" && sticker_hex(tag[1]) && len(tag[2]) <= 256 {
		return {sha = tag[1], code = tag[2]}
	}
	if len(tag) < 4 ||
	   len(tag) > 5 ||
	   tag[0] != "sticker" ||
	   !sticker_coordinate(tag[1]) ||
	   !sticker_name_ok(tag[2], .Code) ||
	   !sticker_hex(tag[3]) {return {}}
	if len(tag) == 5 && !sticker_hex(tag[4]) {return {}}
	return {pack = tag[1], code = tag[2], sha = tag[3], event = len(tag) == 5 ? tag[4] : ""}
}

@(private)
sticker_from_record :: proc(record: ^marmot.Timeline_Message_Record) -> Sticker_Ref {
	for tag in record.tags[:record.tags_len] {
		if tag.values_len > 5 {continue}
		values: [5]string
		for i in 0 ..< tag.values_len {values[i] = string(tag.values[i])}
		ref := sticker_ref_tag(values[:tag.values_len])
		if ref.sha == "" {continue}
		for hint in record.tags[:record.tags_len] {
			if hint.values_len == 3 &&
			   string(hint.values[0]) == "sticker-relay" &&
			   string(hint.values[1]) == ref.pack &&
			   strings.has_prefix(string(hint.values[2]), "wss://") {
				ref.relay = string(hint.values[2]); break
			}
		}
		return sticker_ref_clone(ref)
	}
	return {}
}

@(private)
sticker_tags :: proc(ref: Sticker_Ref) -> [][]string {
	if ref.sha == "" {return nil}
	tags := make([dynamic][]string, context.temp_allocator)
	if ref.pack == "" {
		append(&tags, []string{"wn-sticker", ref.sha, ref.code})
	} else {
		if ref.event ==
		   "" {append(&tags, []string{"sticker", ref.pack, ref.code, ref.sha})} else {append(&tags, []string{"sticker", ref.pack, ref.code, ref.sha, ref.event})}
		if ref.relay != "" {append(&tags, []string{"sticker-relay", ref.pack, ref.relay})}
	}
	for &row in tags {owned := make([]string, len(row), context.temp_allocator); copy(owned, row); row = owned}
	return tags[:]
}

@(private)
sticker_event_valid :: proc(event: Sticker_Event) -> bool {
	if !sticker_hex(event.id) || !sticker_hex(event.pubkey) || len(event.sig) != 128 {return false}
	sig, ok := hex.decode(transmute([]u8)event.sig, context.temp_allocator)
	if !ok {return false}
	pk, _ := hex.decode(transmute([]u8)event.pubkey, context.temp_allocator)
	tags, tags_err := json.marshal(event.tags, allocator = context.temp_allocator)
	content, content_err := json.marshal(event.content, allocator = context.temp_allocator)
	if tags_err != nil || content_err != nil {return false}
	bytes := fmt.tprintf(
		`[0,"%s",%d,%d,%s,%s]`,
		event.pubkey,
		event.created_at,
		event.kind,
		string(tags),
		string(content),
	)
	digest := hash.hash_bytes(.SHA256, transmute([]u8)bytes, context.temp_allocator)
	if string(hex.encode(digest, context.temp_allocator)) != event.id {return false}
	key: [64]u8
	return(
		xonly_pubkey_parse(context_static, &key, raw_data(pk)) == 1 &&
		schnorrsig_verify(
			context_static,
			raw_data(sig),
			raw_data(digest),
			uint(len(digest)),
			&key,
		) ==
			1 \
	)
}

@(private)
sticker_dim_ok :: proc(dim: string) -> bool {
	if dim == "" {return true}
	x := strings.index_byte(dim, 'x')
	if x <= 0 {return false}
	w, wok := strconv.parse_uint(dim[:x]); h, hok := strconv.parse_uint(dim[x + 1:])
	return wok && hok && w > 0 && h > 0 && w <= STICKER_DIM_LIMIT && h <= STICKER_DIM_LIMIT
}

// Return borrowed fields. Invalid entries are skipped; the first valid code wins.
@(private)
sticker_pack_entry :: proc(tag: []string) -> (item: Sticker_Item, ok: bool) {
	if len(tag) < 5 || tag[0] != "sticker" || !sticker_name_ok(tag[1], .Code) {return}
	fields := make(map[string]string, context.temp_allocator)
	for part in tag[2:] {
		space := strings.index_byte(part, ' ')
		if space <= 0 {return}
		key, value := part[:space], part[space + 1:]
		if !(key in fields) {fields[key] = value}
	}
	mime := fields["m"]
	if !strings.has_prefix(fields["url"], "https://") ||
	   len(fields["url"]) > 2048 ||
	   !sticker_hex(fields["x"]) ||
	   !sticker_dim_ok(fields["dim"]) ||
	   (mime != "image/png" &&
			   mime != "image/webp" &&
			   mime != "image/apng" &&
			   mime != "image/gif") {return}
	item = {
		ref = {code = tag[1], sha = fields["x"]},
		label = fields["alt"],
		mime = mime,
		url = fields["url"],
	}
	if item.label == "" {item.label = tag[1]}
	if len(item.label) > 256 {item.label = tag[1]}
	return item, true
}

@(private)
sticker_parse_pack :: proc(
	event: Sticker_Event,
	coordinate, relay: string,
) -> (
	pack: Sticker_Pack,
	items: [dynamic]Sticker_Item,
) {
	if !sticker_coordinate(coordinate) ||
	   event.kind != STICKER_PACK_KIND ||
	   event.pubkey != coordinate[6:70] ||
	   event.content != "" {return}
	meta := make(map[string]string, context.temp_allocator)
	for tag in event.tags {
		if len(tag) < 2 {continue}
		if tag[0] == "d" || tag[0] == "title" || tag[0] == "pack_format" {
			if tag[0] in meta {return}
			meta[tag[0]] = tag[1]
		}
	}
	if meta["d"] != coordinate[71:] ||
	   meta["title"] == "" ||
	   len(meta["title"]) > 256 ||
	   meta["pack_format"] != "sonar-sticker-pack-v1" {return}
	seen := make(map[string]bool, context.temp_allocator)
	for tag in event.tags {
		item, ok := sticker_pack_entry(tag)
		if !ok || seen[item.ref.code] {continue}
		seen[item.ref.code] = true
		item.ref.pack, item.ref.event, item.ref.relay = coordinate, event.id, relay
		item.ref = sticker_ref_clone(item.ref)
		item.label, item.mime, item.url =
			strings.clone(item.label), strings.clone(item.mime), strings.clone(item.url)
		append(&items, item)
		if len(items) == STICKER_PACK_LIMIT {break}
	}
	if len(items) == 0 {return}
	pack = {
		strings.clone(coordinate),
		strings.clone(meta["title"]),
		strings.clone(event.pubkey),
		strings.clone(event.id),
		strings.clone(relay),
	}
	return
}
