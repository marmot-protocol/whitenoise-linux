// Namecoin `.bit` resolver: pure-function tests for the parts that do
// not touch the ElectrumX network. Identifier parsing, script assembly,
// scripthash derivation, name-op vout decoding.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:strings"
import "core:testing"

// Reset the package-global pending queue between tests. `clear` alone
// is not enough here: the odin test runner gives each test a
// rollback-stack arena that is freed wholesale when the test ends, so
// a backing array allocated by an earlier test would dangle into the
// next one (serial runs) or race it (parallel runs). Free every entry,
// delete the array, and drop it to nil so the next push allocates from
// the current test's arena.
nc_pending_reset :: proc() {
	for p in nc_pending {
		nc_pending_free(p)
	}
	delete(nc_pending)
	nc_pending = nil
}

// ── identifier gate ────────────────────────────────────────────────

@(test)
nc_is_bit_positives :: proc(t: ^testing.T) {
	testing.expect(t, nc_is_bit("alice@example.bit"))
	testing.expect(t, nc_is_bit("Alice@Example.BIT"))
	testing.expect(t, nc_is_bit("example.bit"))
	testing.expect(t, nc_is_bit("nostr:example.bit"))
	testing.expect(t, nc_is_bit("d/example"))
	testing.expect(t, nc_is_bit("id/alice"))
	testing.expect(t, nc_is_bit("  d/example  "))
}

@(test)
nc_is_bit_negatives :: proc(t: ^testing.T) {
	testing.expect(t, !nc_is_bit(""))
	testing.expect(t, !nc_is_bit(".bit"))
	testing.expect(t, !nc_is_bit("d/"))
	testing.expect(t, !nc_is_bit("id/"))
	testing.expect(t, !nc_is_bit("example.com"))
	testing.expect(t, !nc_is_bit("alice@example.com"))
	testing.expect(
		t,
		!nc_is_bit("npub1w90qcnzy9pxxaanl7zt50pgn8gj9tnpwd3wkfnq8fj0h4pft2eus5at3v3"),
	)
}

// ── identifier parsing ─────────────────────────────────────────────

@(test)
nc_parse_bare_domain :: proc(t: ^testing.T) {
	p, ok := nc_parse("Example.BIT")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.namecoin_name, "d/example")
	testing.expect_value(t, p.local_part, "_")
	testing.expect(t, p.is_domain)
}

@(test)
nc_parse_user_at_domain :: proc(t: ^testing.T) {
	p, ok := nc_parse("Alice@Example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.namecoin_name, "d/example")
	testing.expect_value(t, p.local_part, "alice")
	testing.expect(t, p.is_domain)
}

@(test)
nc_parse_empty_local_part :: proc(t: ^testing.T) {
	// Empty local-part falls back to the root entry.
	p, ok := nc_parse("@example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.local_part, "_")
}

@(test)
nc_parse_d_slash :: proc(t: ^testing.T) {
	p, ok := nc_parse("d/Foo")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.namecoin_name, "d/foo")
	testing.expect_value(t, p.local_part, "_")
	testing.expect(t, p.is_domain)
}

@(test)
nc_parse_id_slash :: proc(t: ^testing.T) {
	p, ok := nc_parse("id/Alice")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.namecoin_name, "id/alice")
	testing.expect_value(t, p.local_part, "_")
	testing.expect(t, !p.is_domain)
}

@(test)
nc_parse_nostr_prefix :: proc(t: ^testing.T) {
	p, ok := nc_parse("nostr:example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&p)
	testing.expect_value(t, p.namecoin_name, "d/example")
}

@(test)
nc_parse_rejects_non_bit :: proc(t: ^testing.T) {
	_, ok := nc_parse("example.com")
	testing.expect(t, !ok)
	_, ok2 := nc_parse("d/")
	testing.expect(t, !ok2)
	_, ok3 := nc_parse("")
	testing.expect(t, !ok3)
}

// ── script assembly + scripthash ───────────────────────────────────

@(test)
nc_script_layout_for_short_name :: proc(t: ^testing.T) {
	// Short names use the direct-length push opcode: the first byte
	// after OP_NAME_UPDATE is the name length, not a PUSHDATA opcode.
	name := transmute([]u8)string("d/example")
	script := nc_build_name_index_script(name)
	defer delete(script)
	// OP_NAME_UPDATE (0x53) | len=9 | name bytes | 0x00 (empty value push)
	// | OP_2DROP (0x6d) | OP_DROP (0x75) | OP_RETURN (0x6a)
	testing.expect_value(t, script[0], u8(0x53))
	testing.expect_value(t, script[1], u8(len(name)))
	for b, i in name {
		testing.expect_value(t, script[2 + i], b)
	}
	tail_at := 2 + len(name)
	testing.expect_value(t, script[tail_at], u8(0x00))
	testing.expect_value(t, script[tail_at + 1], u8(0x6d))
	testing.expect_value(t, script[tail_at + 2], u8(0x75))
	testing.expect_value(t, script[tail_at + 3], u8(0x6a))
}

@(test)
nc_scripthash_deterministic :: proc(t: ^testing.T) {
	// The scripthash is stable across calls; regression guard.
	name := transmute([]u8)string("d/example")
	script := nc_build_name_index_script(name)
	defer delete(script)
	h1 := nc_electrum_scripthash(script)
	h2 := nc_electrum_scripthash(script)
	testing.expect_value(t, h1, h2)
	testing.expect(t, len(h1) == 64)
}

// ── name-op vout decoding ──────────────────────────────────────────

@(test)
nc_parse_op_name_update :: proc(t: ^testing.T) {
	// OP_NAME_UPDATE <push "d/example"> <push "hello"> <trailer>
	name := transmute([]u8)string("d/example")
	value := transmute([]u8)string("hello")
	script := make([dynamic]u8)
	defer delete(script)
	append(&script, u8(0x53))
	append(&script, u8(len(name)))
	for b in name {append(&script, b)}
	append(&script, u8(len(value)))
	for b in value {append(&script, b)}
	// Trailer (unused by the parser once it has the two pushes).
	append(&script, u8(0x6d), u8(0x75), u8(0x6a))
	got_name, got_value, ok := nc_parse_name_script(script[:])
	testing.expect(t, ok)
	testing.expect_value(t, got_name, "d/example")
	testing.expect_value(t, got_value, "hello")
}

@(test)
nc_parse_op_name_firstupdate :: proc(t: ^testing.T) {
	// OP_NAME_FIRSTUPDATE <push name> <push 20-byte rand> <push value> <trailer>
	name := transmute([]u8)string("d/mstrofnone")
	value := transmute([]u8)string(`{"nostr":"deadbeef"}`)
	script := make([dynamic]u8)
	defer delete(script)
	append(&script, u8(0x52))
	append(&script, u8(len(name)))
	for b in name {append(&script, b)}
	append(&script, u8(20)) // rand push length
	for _ in 0 ..< 20 {append(&script, u8(0xAA))}
	append(&script, u8(len(value)))
	for b in value {append(&script, b)}
	append(&script, u8(0x6d), u8(0x6d), u8(0x75), u8(0x6a))
	got_name, got_value, ok := nc_parse_name_script(script[:])
	testing.expect(t, ok)
	testing.expect_value(t, got_name, "d/mstrofnone")
	testing.expect_value(t, got_value, `{"nostr":"deadbeef"}`)
}

@(test)
nc_parse_rejects_op_name_new :: proc(t: ^testing.T) {
	// OP_NAME_NEW (0x51) carries no visible value.
	script := []u8{0x51, 0x02, 0xaa, 0xbb, 0x75, 0x6a}
	_, _, ok := nc_parse_name_script(script)
	testing.expect(t, !ok)
}

@(test)
nc_hex_decode_roundtrip :: proc(t: ^testing.T) {
	input := []u8{0x00, 0x53, 0xff, 0xa1, 0x0d}
	as_hex := hex.encode(input, context.temp_allocator)
	back := nc_hex_decode(string(as_hex))
	testing.expect_value(t, len(back), len(input))
	for b, i in back {
		testing.expect_value(t, b, input[i])
	}
	testing.expect(t, nc_hex_decode("0xnothex") == nil)
	testing.expect(t, nc_hex_decode("abc") == nil) // odd length
}

@(test)
nc_extract_name_value_matches :: proc(t: ^testing.T) {
	// Build a vout: OP_NAME_UPDATE push "d/x" push "V".
	script := []u8{0x53, 3, 'd', '/', 'x', 1, 'V', 0x6d, 0x75, 0x6a}
	as_hex := string(hex.encode(script, context.temp_allocator))
	// A second vout that pays a p2pkh; front-door filter should skip it.
	p2pkh := "76a914aabbccddeeff112233445566778899aabbccddee88ac"
	testing.expect_value(t, nc_extract_name_value({p2pkh, as_hex}, "d/x"), "V")
	// Non-matching name returns empty.
	testing.expect_value(t, nc_extract_name_value({as_hex}, "d/y"), "")
}

// ── nc_extract_from_domain: fail closed ────────────────────────────
//
// These tests exercise the security-critical branch that previously
// silently substituted `_` (root) or "first valid entry" for a missing
// requested identity. Both fallbacks were removed; a missing entry now
// resolves to Not_Found instead of another party's pubkey.

@(test)
nc_extract_from_domain_missing_local_part_fails_closed :: proc(t: ^testing.T) {
	// Looking up alice@example.bit against a record that only names bob
	// and `_` must return Not_Found — falling back to `_` (the domain
	// owner) would silently attach the wrong identity to alice's invite.
	raw := `{"names":{"bob":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","_":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}`
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("alice@example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, _ := nc_extract_from_domain(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Not_Found)
}

@(test)
nc_extract_from_domain_root_without_underscore_fails_closed :: proc(t: ^testing.T) {
	// Looking up the root of a domain whose `names` map has entries but
	// no `_` must return Not_Found. Picking "the first valid key" would
	// have been an attacker-controlled substitution.
	raw := `{"names":{"alice":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","bob":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}`
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, _ := nc_extract_from_domain(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Not_Found)
}

@(test)
nc_extract_from_domain_exact_match_resolves :: proc(t: ^testing.T) {
	// Positive control: alice@example.bit returns alice's pubkey.
	pk := "1111111111111111111111111111111111111111111111111111111111111111"
	raw := fmt_domain_names_map([]Names_Pair{{"alice", pk}})
	defer delete(raw)
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("alice@example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, res := nc_extract_from_domain(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Resolved)
	testing.expect_value(t, res.pubkey_hex, pk)
	testing.expect_value(t, res.local_part, "alice")
	nc_resolved_free(res)
}

@(test)
nc_extract_from_domain_root_with_underscore_resolves :: proc(t: ^testing.T) {
	pk := "2222222222222222222222222222222222222222222222222222222222222222"
	bob := "3333333333333333333333333333333333333333333333333333333333333333"
	raw := fmt_domain_names_map([]Names_Pair{{"_", pk}, {"bob", bob}})
	defer delete(raw)
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("example.bit")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, res := nc_extract_from_domain(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Resolved)
	testing.expect_value(t, res.pubkey_hex, pk)
	testing.expect_value(t, res.local_part, "_")
	nc_resolved_free(res)
}

// Helper: format a `{"names": {...}}` JSON string from an ordered pair
// slice; keeps the assertions above deterministic (Odin map iteration
// is not).
@(private = "file")
Names_Pair :: struct {
	key:    string,
	pubkey: string,
}

@(private = "file")
fmt_domain_names_map :: proc(pairs: []Names_Pair) -> string {
	sb: strings.Builder
	strings.builder_init(&sb)
	strings.write_string(&sb, `{"names":{`)
	for pair, i in pairs {
		if i > 0 {strings.write_byte(&sb, ',')}
		strings.write_byte(&sb, '"')
		strings.write_string(&sb, pair.key)
		strings.write_string(&sb, `":"`)
		strings.write_string(&sb, pair.pubkey)
		strings.write_byte(&sb, '"')
	}
	strings.write_string(&sb, `}}`)
	return strings.to_string(sb)
}

// ── pending queue: dedup + snapshot + cancellation ─────────────────

// One @(test) proc for the whole pending-queue lifecycle, by design:
// `nc_pending` is package-global state owned by the (single-threaded)
// frame loop, and odin's test runner executes @(test) procs
// concurrently. Three separate procs would mutate the shared queue
// from parallel threads and fail spuriously — exactly what happened
// when these were split. Any future test that touches `nc_pending`
// must be added HERE (or otherwise serialized), never as its own
// @(test) proc.
@(test)
nc_pending_queue_lifecycle :: proc(t: ^testing.T) {
	// ── dedup: identical intents collapse; distinct ones append ──
	nc_pending_reset()

	nc_pending_push("alice@example.bit", .Invite, "acct-hex", "group-A")
	nc_pending_push("alice@example.bit", .Invite, "acct-hex", "group-A")
	nc_pending_push("  Alice@Example.BIT  ", .Invite, "acct-hex", "group-A")
	testing.expect_value(t, len(nc_pending), 1)

	// Different intent -> not a dup.
	nc_pending_push("alice@example.bit", .New_Chat, "acct-hex", "", "New group")
	testing.expect_value(t, len(nc_pending), 2)

	// Different account -> not a dup.
	nc_pending_push("alice@example.bit", .Invite, "other-acct", "group-A")
	testing.expect_value(t, len(nc_pending), 3)

	// Different group -> not a dup.
	nc_pending_push("alice@example.bit", .Invite, "acct-hex", "group-B")
	testing.expect_value(t, len(nc_pending), 4)

	// ── cancel by account: only that account's intents drop ──
	nc_pending_reset()

	nc_pending_push("alice@example.bit", .Invite, "acct-A", "group-1")
	nc_pending_push("bob@example.bit", .New_Chat, "acct-A", "", "G")
	nc_pending_push("carol@example.bit", .Invite, "acct-B", "group-1")
	testing.expect_value(t, len(nc_pending), 3)

	nc_pending_cancel_account("acct-A")
	testing.expect_value(t, len(nc_pending), 1)
	testing.expect_value(t, nc_pending[0].account, "acct-B")

	// ── cancel by group: only .Invite intents for that group drop ──
	nc_pending_reset()

	nc_pending_push("alice@example.bit", .Invite, "acct-A", "group-1")
	nc_pending_push("bob@example.bit", .Invite, "acct-A", "group-2")
	nc_pending_push("carol@example.bit", .New_Chat, "acct-A", "", "G")
	testing.expect_value(t, len(nc_pending), 3)

	nc_pending_cancel_group("group-1")
	testing.expect_value(t, len(nc_pending), 2)
	// New_Chat and the other invite survive.
	found_new_chat := false
	found_group_2 := false
	for p in nc_pending {
		if p.intent == .New_Chat {found_new_chat = true}
		if p.intent == .Invite && p.group_id == "group-2" {found_group_2 = true}
	}
	testing.expect(t, found_new_chat)
	testing.expect(t, found_group_2)

	nc_pending_reset()

	// Closing the form must not let a late lookup create a chat.
	nc_pending_push("alice.bit", .New_Chat, "acct-A", "", "Cancelled")
	nc_pending_push("bob.bit", .Invite, "acct-A", "group-1")
	nc_pending_push("carol.bit", .New_Chat, "acct-B", "", "Other account")
	ui := Ui_State {
		account_ref   = "acct-A",
		new_chat_open = true,
		nip05_ticket  = 7,
	}
	close_new_chat(&ui)
	testing.expect(t, !ui.new_chat_open && ui.nip05_ticket == 0)
	testing.expect_value(t, len(nc_pending), 2)
	testing.expect_value(t, nc_pending[0].identifier, "bob.bit")
	testing.expect_value(t, nc_pending[1].identifier, "carol.bit")
	nc_pending_reset()
}

// ── id/ identity records: no cross-shape substitution ─────────────
//
// Guards a subtler variant of #3 from the reviewer's second round: an
// id/ record that carries a `names` sub-object (which does not belong
// in an identity-shape record) must not resolve — accepting `names._`
// there would silently return whatever key that map holds instead of
// the identity's own `pubkey`.

@(test)
nc_extract_from_identity_rejects_names_fallback :: proc(t: ^testing.T) {
	// `id/alice` record with only a `names` sub-object (no top-level
	// `pubkey`). Must Not_Found.
	raw := `{"names":{"_":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}`
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("id/alice")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, _ := nc_extract_from_identity(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Not_Found)
}

@(test)
nc_extract_from_identity_accepts_flat_pubkey :: proc(t: ^testing.T) {
	pk := "9999999999999999999999999999999999999999999999999999999999999999"
	raw := strings.concatenate({`{"pubkey":"`, pk, `"}`})
	defer delete(raw)
	v, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	defer json.destroy_value(v, allocator = context.temp_allocator)
	obj := v.(json.Object)
	parsed, ok := nc_parse("id/alice")
	testing.expect(t, ok)
	defer nc_parsed_free(&parsed)
	status, res := nc_extract_from_identity(obj, parsed)
	testing.expect_value(t, status, Nc_Status.Resolved)
	testing.expect_value(t, res.pubkey_hex, pk)
	nc_resolved_free(res)
}

// ── nc_resolve_value_with_imports: no double-free ──────────────────
//
// Reviewer #5: expansion previously moved children out of the parsed
// value and then the caller destroyed the (now-partially-freed) tree,
// aborting with `free(): invalid pointer` on cache-populated paths.
// Even `"import": []` reproduced. The rewrite builds a fresh output
// via `json.clone_value` so the input tree stays self-owned; the
// caller's own `json.destroy_value` after this proc used to be part
// of the bug and has been removed. These tests confirm the two
// destroys (one implicit inside the proc, one explicit on the
// return) walk disjoint memory.

@(test)
nc_resolve_value_no_import_returns_owned :: proc(t: ^testing.T) {
	raw := `{"nostr":{"pubkey":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}`
	v, ok := nc_resolve_value_with_imports(raw, 4)
	testing.expect(t, ok)
	// Must not crash — was a double-free before the rewrite.
	json.destroy_value(v)
}

@(test)
nc_resolve_value_empty_import_returns_owned :: proc(t: ^testing.T) {
	// The reviewer explicitly called out `"import":[]` aborting with
	// free(): invalid pointer. Guard it.
	raw := `{"import":[],"nostr":{"pubkey":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}`
	v, ok := nc_resolve_value_with_imports(raw, 4)
	testing.expect(t, ok)
	// The returned tree contains everything except `import`.
	obj, is_obj := v.(json.Object)
	testing.expect(t, is_obj)
	_, has_import := obj["import"]
	testing.expect(t, !has_import)
	_, has_nostr := obj["nostr"]
	testing.expect(t, has_nostr)
	json.destroy_value(v)
}

@(test)
nc_resolve_value_nested_map_survives_destroy :: proc(t: ^testing.T) {
	// Nested objects and arrays exercise the recursive clone path.
	raw := `{"import":[],"nostr":{"names":{"alice":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"relays":{"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc":["wss://one","wss://two"]}}}`
	v, ok := nc_resolve_value_with_imports(raw, 4)
	testing.expect(t, ok)
	json.destroy_value(v)
}
