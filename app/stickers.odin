package main

import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

import marmot "../marmot"

// MDK caps the installed list and each downloaded asset at these sizes.
@(private)
STICKER_PACK_LIMIT :: 100
@(private)
STICKER_BYTES_LIMIT :: 4 * 1024 * 1024
@(private)
STICKER_DIM_LIMIT :: 4096

// MDK owns packs, the kind-10031 installed list and asset validation; pack
// rows are UI-owned copies of its projection. A ref names exact artwork: the
// pack coordinate, its shortcode and the plaintext SHA-256 of the image.
// An empty pack is a personal sticker: vault-sealed on this device and sent
// as an encrypted attachment tagged ["wn-sticker", sha, name].
@(private)
Sticker_Ref :: struct {
	pack, code, sha: string,
}
@(private)
Sticker_Item :: struct {
	ref:         Sticker_Ref,
	label, mime: string,
}
@(private)
Sticker_Pack :: struct {
	coordinate, title: string,
}
// A signed Nostr event; emoji sets verify their kind-30030 events with it.
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
sticker_ref_clone :: proc(ref: Sticker_Ref) -> Sticker_Ref {
	return {strings.clone(ref.pack), strings.clone(ref.code), strings.clone(ref.sha)}
}

@(private)
sticker_ref_free :: proc(ref: Sticker_Ref) {
	for value in ([]string{ref.pack, ref.code, ref.sha}) {delete(value)}
}

@(private)
sticker_item_free :: proc(item: Sticker_Item) {
	sticker_ref_free(item.ref)
	delete(item.label); delete(item.mime)
}

@(private)
sticker_item_clone :: proc(item: Sticker_Item) -> Sticker_Item {
	return {sticker_ref_clone(item.ref), strings.clone(item.label), strings.clone(item.mime)}
}

@(private)
sticker_pack_free :: proc(pack: Sticker_Pack) {
	delete(pack.coordinate); delete(pack.title)
}

// MDK projects exactly one valid kind-9 pack sticker tag. A personal sticker
// is this app's own tag, which MDK leaves to the host.
@(private)
sticker_from_record :: proc(record: ^marmot.Timeline_Message_Record) -> Sticker_Ref {
	if ref := record.sticker; ref != nil {
		return {
			strings.clone(string(ref.pack_coordinate)),
			strings.clone(string(ref.shortcode)),
			strings.clone(string(ref.plaintext_sha256)),
		}
	}
	for tag in record.tags[:record.tags_len] {
		if tag.values_len != 3 || string(tag.values[0]) != "wn-sticker" {continue}
		sha, name := string(tag.values[1]), string(tag.values[2])
		if sticker_hex(sha) &&
		   len(name) <= 256 {return {"", strings.clone(name), strings.clone(sha)}}
	}
	return {}
}

// Only personal stickers carry an app-built tag; MDK writes pack sticker tags.
@(private)
sticker_tags :: proc(ref: Sticker_Ref) -> [][]string {
	if ref.pack != "" || ref.sha == "" {return nil}
	row := make([]string, 3, context.temp_allocator)
	row[0], row[1], row[2] = "wn-sticker", ref.sha, ref.code
	tags := make([][]string, 1, context.temp_allocator)
	tags[0] = row
	return tags
}

// Copy one MDK pack into UI-owned rows, appending its stickers to `items`.
// The label is the sticker's alt text, else its shortcode.
@(private)
sticker_pack_copy :: proc(
	pack: ^marmot.Sticker_Pack,
	items: ^[dynamic]Sticker_Item,
) -> Sticker_Pack {
	for &sticker in pack.stickers[:pack.stickers_len] {
		code := string(sticker.shortcode)
		alt := string(sticker.alt)
		ref := Sticker_Ref{string(sticker.pack_coordinate), code, string(sticker.plaintext_sha256)}
		label := alt != "" ? alt : code
		append(items, sticker_item_clone({ref, label, string(sticker.mime)}))
	}
	return {strings.clone(string(pack.coordinate)), strings.clone(string(pack.title))}
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
