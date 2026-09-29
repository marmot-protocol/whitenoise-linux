// Namecoin `.bit` NIP-05 resolution. `alice@example.bit`, `example.bit`,
// `d/example`, `id/alice` -> Nostr pubkey hex (+ optional relay hints).
//
// Same closed loop the NIP-05 HTTP verifier serves for DNS names, but
// over Namecoin's censorship-resistant name index (no DNS, no TLS CA)
// via ElectrumX WSS. Users in group settings, the new-chat member field,
// and the invite box can type a `.bit` (or `d/`/`id/`) identifier and the
// resolver hands marmot the hex pubkey.
//
//   InviteBox / NewChat member ──▶ handle_members / handle_new_chat
//                                             │
//                                     nc_resolve_async ──▶ nc_worker
//                                                             │
//                                                   nc_shim.c (WSS)
//                                                             │
//                                             ElectrumX servers (see NC_DEFAULT_SERVERS)
//
// ── TRUST MODEL ───────────────────────────────────────────────────────
//
// This resolver TRUSTS the pinned ElectrumX operators it talks to. It
// asks the server for the latest transaction outputs bound to the name's
// scripthash and reads the `nostr` field out of the value payload. It
// does NOT verify:
//
//   * that the returned transaction is included in the best Namecoin
//     chain (no SPV proof, no block-header chain check),
//   * that the returned transaction actually spends into the claimed
//     scripthash on-chain (only that the server labelled it so in the
//     history response),
//   * that any of the servers it talked to agree with each other (there
//     is no cross-server quorum: the first Resolved wins).
//
// A dishonest, compromised, or MITM'd ElectrumX server can therefore
// return a fabricated name -> pubkey binding, and the invite/new-chat
// action will use whichever pubkey that server claims. TLS pinning
// (CURLOPT_PINNEDPUBLICKEY in nc_shim.c) rules out network-path MITM
// against the pinned servers, but does not rule out the operator
// themselves lying to us.
//
// This matches what the parallel Kotlin, Swift, and TypeScript resolvers
// in the Nostr ecosystem do today: they treat the ElectrumX server as a
// trusted resolver, the same way NIP-05 treats an HTTPS server. The
// mitigation planned for a follow-up is either bundled SPV verification
// (block-header chain + Merkle proof) or dispatch to a local
// `namecoind`; both are out of scope for this PR.
//
// Users who want a stronger trust model should either:
//
//   * run their own ElectrumX / Namecoin full node and add it as a
//     pinned entry in NC_DEFAULT_SERVERS (self-hosted trust), or
//   * wait for the SPV/`namecoind` follow-up.
//
// ponytail: the ifa-0001 `import` chain is walked serially with the
// default depth of 4 (spec minimum). Concurrent walk is fine but not
// worth it until profiles start commonly using nested imports.
package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Monotonic milliseconds since program-start (via core:time's monotonic
// tick source). Used for pending-intent deadlines; wall-clock jumps
// (NTP, DST, sleep/wake) must not expire an intent early.
@(private = "file")
nc_tick_epoch: time.Tick

@(private = "file")
nc_tick_epoch_init: sync.Once

@(private = "file")
nc_now_ms :: proc() -> i64 {
	sync.once_do(&nc_tick_epoch_init, proc() {nc_tick_epoch = time.tick_now()})
	d := time.tick_since(nc_tick_epoch)
	return i64(time.duration_milliseconds(d))
}

foreign import nclib {"../build/libwnws.a", "system:curl"}

@(default_calling_convention = "c")
foreign nclib {
	// One-shot ElectrumX JSON-RPC over WSS. See nc_shim.c.
	// `pin` is a libcurl CURLOPT_PINNEDPUBLICKEY value ("sha256//<b64>")
	// used INSTEAD of chain verification when non-empty; pass "" for a
	// browser-trusted chain.
	wn_nc_call :: proc(url: cstring, req: cstring, pin: cstring, want_id: c.int, out: [^]u8, cap: c.size_t, timeout_ms: c.long) -> c.int ---
}

// ── public surface ─────────────────────────────────────────────────

// True when `identifier` should be routed to Namecoin resolution rather
// than a DNS-based NIP-05 verifier. Cheap enough to gate a hot path.
// Matches the front-door check the gitworkshop TS and Amethyst
// implementations use.
nc_is_bit :: proc(identifier: string) -> bool {
	trimmed := strings.trim_space(identifier)
	if len(trimmed) == 0 {
		return false
	}
	lower := strings.to_lower(trimmed, context.temp_allocator)
	if strings.has_prefix(lower, "nostr:") {
		lower = lower[6:]
	}
	if strings.has_prefix(lower, "d/") {
		return len(lower) > 2
	}
	if strings.has_prefix(lower, "id/") {
		return len(lower) > 3
	}
	return strings.has_suffix(lower, ".bit") && len(lower) > 4
}

// Structured Namecoin lookup request.
Nc_Parsed :: struct {
	namecoin_name: string, // owned, e.g. "d/example"
	local_part:    string, // owned, "_" for the root
	is_domain:     bool, // false for `id/` identity names
}

// Parse `raw` into a structured request. Returns ok=false with no owned
// allocations for non-Namecoin identifiers. Owned strings must be freed
// with nc_parsed_free when discarded outside the tracking allocator.
nc_parse :: proc(raw: string) -> (parsed: Nc_Parsed, ok: bool) {
	input := strings.trim_space(raw)
	if len(input) == 0 {
		return
	}
	// Tolerate a leading NIP-21 `nostr:`.
	if len(input) >= 6 && strings.equal_fold(input[:6], "nostr:") {
		input = input[6:]
	}
	lower := strings.to_lower(input, context.temp_allocator)

	if strings.has_prefix(lower, "d/") {
		if len(lower) == 2 {
			return
		}
		parsed = Nc_Parsed {
			namecoin_name = strings.clone(lower),
			local_part    = strings.clone("_"),
			is_domain     = true,
		}
		ok = true
		return
	}
	if strings.has_prefix(lower, "id/") {
		if len(lower) == 3 {
			return
		}
		parsed = Nc_Parsed {
			namecoin_name = strings.clone(lower),
			local_part    = strings.clone("_"),
			is_domain     = false,
		}
		ok = true
		return
	}

	if strings.contains(input, "@") && strings.has_suffix(lower, ".bit") {
		at_idx := strings.index_byte(input, '@')
		local_raw := input[:at_idx]
		local := len(local_raw) > 0 ? strings.to_lower(local_raw, context.temp_allocator) : "_"
		domain_raw := strings.to_lower(input[at_idx + 1:], context.temp_allocator)
		if !strings.has_suffix(domain_raw, ".bit") {
			return
		}
		domain := domain_raw[:len(domain_raw) - 4]
		if len(domain) == 0 {
			return
		}
		parsed = Nc_Parsed {
			namecoin_name = strings.concatenate({"d/", domain}),
			local_part    = strings.clone(local),
			is_domain     = true,
		}
		ok = true
		return
	}

	if strings.has_suffix(lower, ".bit") {
		domain := lower[:len(lower) - 4]
		if len(domain) == 0 {
			return
		}
		parsed = Nc_Parsed {
			namecoin_name = strings.concatenate({"d/", domain}),
			local_part    = strings.clone("_"),
			is_domain     = true,
		}
		ok = true
		return
	}
	return
}

nc_parsed_free :: proc(p: ^Nc_Parsed) {
	delete(p.namecoin_name)
	delete(p.local_part)
	p^ = {}
}

// Resolution outcome. Distinguishing not-found from unavailable so the
// UI can tell "name doesn't exist" apart from "can't reach ElectrumX".
Nc_Status :: enum {
	Resolved,
	Not_Found,
	Unavailable,
}

Nc_Resolved :: struct {
	pubkey_hex:    string, // 64 lowercase hex, owned
	relays:        []string, // owned entries
	namecoin_name: string, // owned
	local_part:    string, // owned
}

// ── ElectrumX endpoints ────────────────────────────────────────────
//
// The public Namecoin ElectrumX operators ship self-signed certs by
// convention (no browser-trusted CA has issued for these hosts, and
// none is expected to). To trust them safely we pin the leaf public key
// with libcurl's CURLOPT_PINNEDPUBLICKEY (`sha256//<base64>`); the TLS
// handshake succeeds only when the server presents a matching pubkey,
// and any MITM / rotated cert fails handshake before any data flows.
//
// Servers WITHOUT a `pin` require a browser-trusted chain and are
// intended for deployments that eventually run a real CA cert.
//
// Rotation runbook: when a pinned server rotates its cert, regenerate
// the pin with
//
//   echo | openssl s_client -servername <host> -connect <host>:<port> 2>/dev/null \
//     | openssl x509 -pubkey -noout \
//     | openssl pkey -pubin -outform der \
//     | openssl dgst -sha256 -binary | openssl enc -base64
//
// and update the entry. Removing a pin without replacing it opens the
// server to trivial MITM.
Nc_Server :: struct {
	host: string,
	port: int,
	path: string, // "" defaults to "/"
	// libcurl CURLOPT_PINNEDPUBLICKEY value. Empty means "require
	// browser-trusted chain".
	pin:  string,
}

NC_DEFAULT_SERVERS := []Nc_Server {
	// bitcoins.sk community ElectrumX peer (Slovakia). Self-signed;
	// pubkey pin below matches the leaf served on 2026-09-22.
	{
		host = "nmc2.bitcoins.sk",
		port = 57002,
		path = "",
		pin = "sha256//tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ=",
	},
	// testls.space community ElectrumX peer. Self-signed; the leaf CN
	// (`electrum.testls.space`) does not match the deploy hostname
	// (`electrumx.testls.space`), so a chain check would fail anyway.
	// Pinning the pubkey side-steps that mismatch. Pubkey pin below
	// matches the leaf served on 2026-09-22.
	{
		host = "electrumx.testls.space",
		port = 50004,
		path = "",
		pin = "sha256//YQAbKuAPFnlb9hr6x7O20dgjW5HfVRc2juKlhVWH8Ww=",
	},
	// relay.testls.bit peer (Namecoin `.bit` resolved via a separate
	// resolver on the host). Reached only when the host's `.bit` DNS is
	// available; pinned to the leaf served on 2026-09-22.
	{
		host = "relay.testls.bit",
		port = 50004,
		path = "",
		pin = "sha256//Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw=",
	},
}

// Per-server request budget. Applied to the whole "connect + handshake
// + one JSON-RPC round trip" that `wn_nc_call` performs.
NC_REQUEST_TIMEOUT_MS :: 8000
NC_REPLY_MAX :: 128 * 1024
NC_NAME_EXPIRE_DEPTH :: 36000
NC_IMPORT_MAX_DEPTH :: 4

// ── session cache ──────────────────────────────────────────────────

@(private = "file")
nc_cache_mutex: sync.Mutex

// Positive hit: normalized identifier -> owned Nc_Resolved snapshot.
// The resolver clones from these on read.
@(private = "file")
nc_pos_cache: map[string]Nc_Resolved

// Negative hit: identifier -> ok. Presence means "definitively not found".
@(private = "file")
nc_neg_cache: map[string]bool

// Inflight: identifier -> nothing meaningful; presence means "we already
// spawned a worker; do not spawn a second one for the same identifier".
@(private = "file")
nc_inflight: map[string]bool

@(private = "file")
nc_normalize :: proc(identifier: string, allocator := context.temp_allocator) -> string {
	trimmed := strings.trim_space(identifier)
	return strings.to_lower(trimmed, allocator)
}

// Snapshot of the cache for `identifier`. Positive result is cloned into
// the caller's allocator; negative is a nil result with status = .Not_Found.
// status = .Unavailable when no cache entry exists (caller may want to
// spawn a resolve).
//
// The default allocator is `context.allocator` (persistent) because the
// natural consumer is a `Nc_Done` that later travels through
// `nc_done_free` -> `nc_resolved_free`, which delete() with the default
// allocator. Pass `context.temp_allocator` only for read-and-drop uses
// that never round-trip through `nc_done_free`.
nc_cache_lookup :: proc(
	identifier: string,
	allocator := context.allocator,
) -> (
	result: Nc_Resolved,
	status: Nc_Status,
) {
	key := nc_normalize(identifier)
	sync.lock(&nc_cache_mutex)
	defer sync.unlock(&nc_cache_mutex)
	if hit, has := nc_pos_cache[key]; has {
		return nc_resolved_clone(hit, allocator), .Resolved
	}
	if _, has := nc_neg_cache[key]; has {
		return {}, .Not_Found
	}
	return {}, .Unavailable
}

@(private = "file")
nc_cache_put_pos :: proc(identifier: string, r: Nc_Resolved) {
	key := nc_normalize(identifier, context.allocator)
	sync.lock(&nc_cache_mutex)
	defer sync.unlock(&nc_cache_mutex)
	if _, has := nc_pos_cache[key]; has {
		// The existing entry stays; free the passed-in copy.
		nc_resolved_free(r)
		delete(key)
		return
	}
	delete_key(&nc_neg_cache, key)
	nc_pos_cache[key] = r
}

@(private = "file")
nc_cache_put_neg :: proc(identifier: string) {
	key := nc_normalize(identifier, context.allocator)
	sync.lock(&nc_cache_mutex)
	defer sync.unlock(&nc_cache_mutex)
	if _, has := nc_pos_cache[key]; has {
		delete(key)
		return
	}
	if _, has := nc_neg_cache[key]; has {
		delete(key)
		return
	}
	nc_neg_cache[key] = true
}

// Clone an Nc_Resolved into `allocator`; the returned struct is safe to
// hand out beyond the cache mutex.
nc_resolved_clone :: proc(src: Nc_Resolved, allocator := context.allocator) -> Nc_Resolved {
	relays := make([]string, len(src.relays), allocator)
	for r, i in src.relays {
		relays[i] = strings.clone(r, allocator)
	}
	return Nc_Resolved {
		pubkey_hex = strings.clone(src.pubkey_hex, allocator),
		relays = relays,
		namecoin_name = strings.clone(src.namecoin_name, allocator),
		local_part = strings.clone(src.local_part, allocator),
	}
}

nc_resolved_free :: proc(r: Nc_Resolved) {
	delete(r.pubkey_hex)
	for relay in r.relays {
		delete(relay)
	}
	delete(r.relays)
	delete(r.namecoin_name)
	delete(r.local_part)
}

// ── async front-end ───────────────────────────────────────────────

// What the UI wants to do after a resolve lands. `handle_members` and
// `handle_new_chat` set this when the composer field carries a .bit
// name; the frame-loop drain routes to the follow-up action.
Nc_Intent :: enum {
	None,
	Invite,
	New_Chat,
}

// One in-flight resolve waiting to be joined at the frame boundary.
//
// Every intent-specific field is snapshotted at push time so that
// switching the selected chat, logging into a different account, or
// closing the new-chat dialog while a resolve is inflight cannot land
// the follow-up action on the wrong target. The frame-loop drain
// verifies the snapshot still matches before firing.
Nc_Pending :: struct {
	identifier:  string, // owned; the raw user input
	intent:      Nc_Intent,
	// Account under which the intent was staged. Compared against the
	// active account at drain time; a mismatch cancels the intent (the
	// user switched accounts while the resolver ran).
	account:     string, // owned; account_ref hex or npub
	// .Invite only: the group id the invite must land in. Compared
	// against the active chat at drain time; a mismatch cancels the
	// invite (the user switched chats while the resolver ran) rather
	// than sending the invite to whichever chat is now selected.
	group_id:    string, // owned; "" for non-invite intents
	// .New_Chat only: the group name the user typed in the composer.
	group_name:  string, // owned; "" for non-new-chat intents
	// Wall-clock deadline in monotonic milliseconds; intents older than
	// this are dropped by the drain to prevent stale resolves from
	// firing minutes later.
	deadline_ms: i64,
}

// One completion delivered from the worker thread to the frame loop.
Nc_Done :: struct {
	identifier: string, // owned
	status:     Nc_Status,
	result:     Nc_Resolved, // populated only when status == .Resolved
}

// Pending intents live at package scope so the frame-loop drain has
// access without threading them through every handler.
nc_pending: [dynamic]Nc_Pending

// Pending intents older than this are dropped by drain_nc_intents
// without firing their follow-up action. Long enough for a slow
// ElectrumX server to reply (per-server timeout is 8s, up to three
// servers = 24s worst case), short enough that a resolve that lands
// half a minute later does not surprise the user.
NC_PENDING_TTL_MS :: i64(45_000)

// Queue a resolve intent. Callers snapshot the target account/group at
// push time; a repeated push with the same (identifier, intent, account,
// group_id, group_name) is deduped so the drain fires exactly once per
// user Enter even when the user mashes the key.
nc_pending_push :: proc(
	identifier: string,
	intent: Nc_Intent,
	account: string,
	group_id: string = "",
	group_name: string = "",
) {
	norm := strings.trim_space(identifier)
	for existing in nc_pending {
		if existing.intent == intent &&
		   strings.equal_fold(strings.trim_space(existing.identifier), norm) &&
		   existing.account == account &&
		   existing.group_id == group_id &&
		   existing.group_name == group_name {
			return
		}
	}
	append(
		&nc_pending,
		Nc_Pending {
			identifier = strings.clone(identifier),
			intent = intent,
			account = strings.clone(account),
			group_id = strings.clone(group_id),
			group_name = strings.clone(group_name),
			deadline_ms = nc_now_ms() + NC_PENDING_TTL_MS,
		},
	)
}

// Cancel every pending intent for `account` (drop-and-forget). Handlers
// call this on account switch so a stale resolve cannot land on the new
// account.
nc_pending_cancel_account :: proc(account: string) {
	for i := 0; i < len(nc_pending); {
		if nc_pending[i].account == account {
			nc_pending_free(nc_pending[i])
			ordered_remove(&nc_pending, i)
			continue
		}
		i += 1
	}
}

// Cancel every .Invite pending intent for `group_id`. Handlers call
// this on chat switch so a stale invite cannot land on the wrong group
// after the user moved on.
nc_pending_cancel_group :: proc(group_id: string) {
	for i := 0; i < len(nc_pending); {
		p := nc_pending[i]
		if p.intent == .Invite && p.group_id == group_id {
			nc_pending_free(p)
			ordered_remove(&nc_pending, i)
			continue
		}
		i += 1
	}
}

// Drop expired pending intents (drain calls this every frame). Returns
// the number dropped; callers may want to banner if non-zero.
nc_pending_gc :: proc() -> int {
	now := nc_now_ms()
	dropped := 0
	for i := 0; i < len(nc_pending); {
		if nc_pending[i].deadline_ms > 0 && nc_pending[i].deadline_ms < now {
			nc_pending_free(nc_pending[i])
			ordered_remove(&nc_pending, i)
			dropped += 1
			continue
		}
		i += 1
	}
	return dropped
}

nc_pending_free :: proc(p: Nc_Pending) {
	delete(p.identifier)
	delete(p.account)
	delete(p.group_id)
	delete(p.group_name)
}

@(private = "file")
nc_done_mutex: sync.Mutex
@(private = "file")
nc_done: [dynamic]Nc_Done
@(private = "file")
nc_threads: [dynamic]^thread.Thread

// Ask the resolver to fetch `identifier`, dedup against inflight and
// cached lookups. Returns ok=false when the identifier is not a Namecoin
// name; a cache hit is returned inline via `done`. When ok=true and
// done.status is not .Resolved, the caller should retry after a
// nc_drain that surfaces the identifier as `.Resolved` / `.Not_Found`.
nc_resolve_async :: proc(identifier: string) -> (done: Nc_Done, pending: bool, ok: bool) {
	if !nc_is_bit(identifier) {
		return
	}
	ok = true

	// Cache lookups return owned copies that the caller is expected to
	// free with nc_done_free -> nc_resolved_free, which uses the default
	// allocator. Ask for the same allocator on clone so ownership stays
	// consistent across the hand-off (a temp_allocator clone here would
	// leak the alloc pool then double-free on nc_done_free's delete()).
	if cached, status := nc_cache_lookup(identifier, context.allocator); status != .Unavailable {
		done = Nc_Done {
			identifier = strings.clone(identifier),
			status     = status,
			result     = cached,
		}
		return
	}

	key := nc_normalize(identifier, context.allocator)
	sync.lock(&nc_cache_mutex)
	if _, has := nc_inflight[key]; has {
		sync.unlock(&nc_cache_mutex)
		delete(key)
		pending = true
		return
	}
	nc_inflight[key] = true
	sync.unlock(&nc_cache_mutex)

	job := new(Nc_Job)
	job.identifier = strings.clone(identifier)
	t := thread.create(nc_worker)
	t.data = job
	append(&nc_threads, t)
	thread.start(t)
	pending = true
	return
}

// Drain completed resolves at the frame boundary. Callers walk the
// returned slice and copy anything they want to keep; the slice and its
// entries are freed after the copy loop is done.
nc_drain :: proc(allocator := context.temp_allocator) -> []Nc_Done {
	// Reap finished workers.
	for i := 0; i < len(nc_threads); {
		t := nc_threads[i]
		if !thread.is_done(t) {
			i += 1
			continue
		}
		thread.destroy(t)
		ordered_remove(&nc_threads, i)
	}

	sync.lock(&nc_done_mutex)
	defer sync.unlock(&nc_done_mutex)
	if len(nc_done) == 0 {
		return nil
	}
	out := make([]Nc_Done, len(nc_done), allocator)
	for d, i in nc_done {
		out[i] = d
	}
	clear(&nc_done)
	return out
}

nc_done_free :: proc(d: Nc_Done) {
	delete(d.identifier)
	if d.status == .Resolved {
		nc_resolved_free(d.result)
	}
}

// True while any resolver worker has not yet landed. The reload gate
// consults this before unloading the app module: without it, a worker
// still executing against the module's tracked heap would revisit freed
// memory once `wn_app_run` releases the heap.
nc_workers_busy :: proc() -> bool {
	for t in nc_threads {
		if !thread.is_done(t) {
			return true
		}
	}
	return false
}

// Block until every resolver worker has finished. Safe to call from the
// main thread at shutdown or before a module unload. Nc_Done events
// produced by the drained workers stay in `nc_done`; callers may want
// to nc_drain / nc_done_free them or ignore them if the module is
// unloading anyway.
nc_shutdown :: proc() {
	for t in nc_threads {
		thread.join(t)
		thread.destroy(t)
	}
	clear(&nc_threads)

	for p in nc_pending {
		nc_pending_free(p)
	}
	clear(&nc_pending)
}

// ── worker ────────────────────────────────────────────────────────

@(private = "file")
Nc_Job :: struct {
	identifier: string, // owned
}

@(private = "file")
nc_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Nc_Job)(t.data)
	defer free(job)

	status, resolved := nc_worker_lookup(job.identifier)

	// Persist to cache (only for definitive outcomes) then hand the
	// frame loop a done event.
	if status == .Resolved {
		to_cache := nc_resolved_clone(resolved, context.allocator)
		nc_cache_put_pos(job.identifier, to_cache)
	} else if status == .Not_Found {
		nc_cache_put_neg(job.identifier)
	}
	// Unavailable is intentionally not cached — it is retryable.

	key := nc_normalize(job.identifier, context.allocator)
	sync.lock(&nc_cache_mutex)
	delete_key(&nc_inflight, key)
	sync.unlock(&nc_cache_mutex)
	delete(key)

	done := Nc_Done {
		identifier = strings.clone(job.identifier),
		status     = status,
		result     = resolved,
	}
	delete(job.identifier)

	sync.lock(&nc_done_mutex)
	append(&nc_done, done)
	sync.unlock(&nc_done_mutex)
}

@(private = "file")
nc_worker_lookup :: proc(identifier: string) -> (Nc_Status, Nc_Resolved) {
	parsed, ok := nc_parse(identifier)
	if !ok {
		return .Not_Found, {}
	}
	defer nc_parsed_free(&parsed)

	// Root lookup with server fallback.
	value_status, value_json := nc_name_show_with_fallback(parsed.namecoin_name)
	if value_status == .Unavailable {
		return .Unavailable, {}
	}
	if value_status == .Not_Found {
		return .Not_Found, {}
	}
	defer delete(value_json)

	// Walk ifa-0001 `import` chain. Sub-import unavailability collapses
	// to "empty imported object" — only the root's availability drives
	// the top-level tri-state signal.
	merged, merged_ok := nc_resolve_value_with_imports(value_json, NC_IMPORT_MAX_DEPTH)
	if !merged_ok {
		return .Not_Found, {}
	}
	defer json.destroy_value(merged)

	return nc_extract_nostr(merged, parsed)
}

// ── ElectrumX JSON-RPC layer ──────────────────────────────────────

// Server fallback: walk NC_DEFAULT_SERVERS in order. Any server returning
// a definitive miss latches Not_Found but we continue in case a later
// server has fresher indexing; transport failures try the next server.
// Returns Unavailable only when every server failed transport with no
// definitive miss.
@(private = "file")
nc_name_show_with_fallback :: proc(name: string) -> (Nc_Status, string) {
	definitive_miss := false
	for srv in NC_DEFAULT_SERVERS {
		status, value := nc_name_show(name, srv)
		if status == .Resolved {
			return .Resolved, value
		}
		if status == .Not_Found {
			definitive_miss = true
			continue
		}
		// Unavailable from this server: try the next.
	}
	if definitive_miss {
		return .Not_Found, ""
	}
	return .Unavailable, ""
}

@(private = "file")
nc_name_show :: proc(name: string, srv: Nc_Server) -> (Nc_Status, string) {
	url := nc_server_url(srv)
	defer delete(url)
	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	pin_c: cstring = ""
	if len(srv.pin) > 0 {
		pin_c = strings.clone_to_cstring(srv.pin, context.temp_allocator)
	}

	// server.version handshake — some ElectrumX operators reject calls
	// before it. Non-fatal on failure: they will just close and the
	// next call fails, which we already handle.
	version_req := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":1,"method":"server.version","params":["whitenoise-linux/namecoin","1.4"]}}`,
	)
	if !nc_call_ignore(url_c, pin_c, version_req, 1) {
		return .Unavailable, ""
	}

	// Derive the ElectrumX scripthash key for this name.
	script := nc_build_name_index_script(transmute([]u8)name, context.temp_allocator)
	scripthash := nc_electrum_scripthash(script)

	// blockchain.scripthash.get_history for the name-index scripthash.
	history_req := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":2,"method":"blockchain.scripthash.get_history","params":["%s"]}}`,
		scripthash,
	)
	history_body, hs_ok := nc_call(url_c, pin_c, history_req, 2)
	if !hs_ok {
		return .Unavailable, ""
	}
	defer delete(history_body)

	last_tx_hash, last_height, hist_ok := nc_last_history_entry(history_body)
	if !hist_ok {
		// Empty history is a definitive Namecoin miss (name has never
		// been registered / has no ops).
		return .Not_Found, ""
	}

	// blockchain.transaction.get for the latest tx, verbose=true.
	tx_req := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":3,"method":"blockchain.transaction.get","params":["%s",true]}}`,
		last_tx_hash,
	)
	tx_body, tx_ok := nc_call(url_c, pin_c, tx_req, 3)
	if !tx_ok {
		return .Unavailable, ""
	}
	defer delete(tx_body)

	// Best-effort expiry check via headers.subscribe.
	head_req := `{"jsonrpc":"2.0","id":4,"method":"blockchain.headers.subscribe","params":[]}`
	current_height := i64(0)
	if head_body, head_ok := nc_call(url_c, pin_c, head_req, 4); head_ok {
		current_height = nc_header_height(head_body)
		delete(head_body)
	}
	if current_height > 0 &&
	   last_height > 0 &&
	   current_height - last_height >= NC_NAME_EXPIRE_DEPTH {
		return .Not_Found, ""
	}

	value := nc_extract_value_from_tx(tx_body, name)
	if len(value) == 0 {
		// The tx we got back does not carry this name's value. Treat as
		// definitive miss — the history entry pointed at something that
		// is not our name payload (which shouldn't happen for a real
		// name-index scripthash, but is best-effort here).
		return .Not_Found, ""
	}
	return .Resolved, value
}

@(private = "file")
nc_server_url :: proc(srv: Nc_Server, allocator := context.allocator) -> string {
	path := srv.path
	if len(path) == 0 {
		path = "/"
	} else if path[0] != '/' {
		path = strings.concatenate({"/", path}, context.temp_allocator)
	}
	return fmt.aprintf("wss://%s:%d%s", srv.host, srv.port, path, allocator = allocator)
}

// One JSON-RPC round trip; ok=true iff the shim returned a body carrying
// the matching id. The returned buffer is owned by the caller.
@(private = "file")
nc_call :: proc(url_c, pin_c: cstring, req: string, want_id: int) -> (body: string, ok: bool) {
	buf := make([]u8, NC_REPLY_MAX)
	req_c := strings.clone_to_cstring(req, context.temp_allocator)
	n := wn_nc_call(
		url_c,
		req_c,
		pin_c,
		c.int(want_id),
		raw_data(buf),
		c.size_t(NC_REPLY_MAX),
		c.long(NC_REQUEST_TIMEOUT_MS),
	)
	if n <= 0 {
		delete(buf)
		return "", false
	}
	// The shim's id filter is a byte-level walker (see nc_message_id in
	// nc_shim.c). Re-parse the envelope with the Odin JSON parser here
	// so a hostile/broken server can't sneak a non-object reply into the
	// caller (`nc_last_history_entry` / `nc_extract_value_from_tx` etc.
	// re-parse for their own extraction; this check makes the guarantee
	// explicit at the RPC boundary).
	body_str := string(buf[:n])
	value, err := json.parse(transmute([]u8)body_str, allocator = context.temp_allocator)
	if err != nil {
		delete(buf)
		return "", false
	}
	defer json.destroy_value(value, allocator = context.temp_allocator)
	root, is_obj := value.(json.Object)
	if !is_obj {
		delete(buf)
		return "", false
	}
	reply_id, has_id := root["id"].(json.Float)
	if !has_id || int(reply_id) != want_id {
		delete(buf)
		return "", false
	}
	return body_str, true
}

@(private = "file")
nc_call_ignore :: proc(url_c, pin_c: cstring, req: string, want_id: int) -> bool {
	body, ok := nc_call(url_c, pin_c, req, want_id)
	if ok {
		delete(body)
	}
	return ok
}

// ── JSON extraction helpers ───────────────────────────────────────

// Pull the last entry of history: array of {tx_hash, height}.
@(private = "file")
nc_last_history_entry :: proc(body: string) -> (tx_hash: string, height: i64, ok: bool) {
	value, err := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	defer json.destroy_value(value, allocator = context.temp_allocator)
	root, is_obj := value.(json.Object)
	if !is_obj {
		return
	}
	arr, is_arr := root["result"].(json.Array)
	if !is_arr || len(arr) == 0 {
		return
	}
	last, is_last_obj := arr[len(arr) - 1].(json.Object)
	if !is_last_obj {
		return
	}
	tx, tx_ok := last["tx_hash"].(json.String)
	h, h_ok := last["height"].(json.Float)
	if !tx_ok || !h_ok {
		return
	}
	return strings.clone(string(tx), context.temp_allocator), i64(h), true
}

@(private = "file")
nc_header_height :: proc(body: string) -> i64 {
	value, err := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	if err != nil {
		return 0
	}
	defer json.destroy_value(value, allocator = context.temp_allocator)
	root, is_obj := value.(json.Object)
	if !is_obj {
		return 0
	}
	result, is_result_obj := root["result"].(json.Object)
	if !is_result_obj {
		return 0
	}
	h, has_height := result["height"].(json.Float)
	if !has_height {
		return 0
	}
	return i64(h)
}

// Extract the raw name value string from a verbose transaction reply by
// walking its `vout[]` and matching the OP_NAME_UPDATE / FIRSTUPDATE
// vout carrying `name`. Returned string is owned.
@(private = "file")
nc_extract_value_from_tx :: proc(body: string, name: string) -> string {
	value, err := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	if err != nil {
		return ""
	}
	defer json.destroy_value(value, allocator = context.temp_allocator)
	root, is_obj := value.(json.Object)
	if !is_obj {
		return ""
	}
	tx, is_tx_obj := root["result"].(json.Object)
	if !is_tx_obj {
		return ""
	}
	vout_arr, is_arr := tx["vout"].(json.Array)
	if !is_arr {
		return ""
	}
	hexes := make([dynamic]string, context.temp_allocator)
	for entry in vout_arr {
		obj, ok := entry.(json.Object)
		if !ok {
			continue
		}
		spk, has_spk := obj["scriptPubKey"].(json.Object)
		if !has_spk {
			continue
		}
		hex_str, has_hex := spk["hex"].(json.String)
		if !has_hex {
			continue
		}
		append(&hexes, string(hex_str))
	}
	extracted := nc_extract_name_value(hexes[:], name)
	if len(extracted) == 0 {
		return ""
	}
	return strings.clone(extracted)
}

// ── ifa-0001 import chain ─────────────────────────────────────────

// Parse `value_json` and, if it carries an `import` directive, walk it
// per ifa-0001 §"import" with importer-wins precedence. Returns a
// Parses `value_json` and, if it declares any `import`, returns a fresh
// object graph with those imports expanded and merged in
// importer-wins order. The returned value is owned by the caller and
// must be released with a single `json.destroy_value`.
//
// Ownership contract (this used to be broken): the parsed `value` is
// ALWAYS destroyed inside this function; the returned tree is a
// separately-allocated clone-and-merge result. Neither aliases the
// other, so no double-free is possible even when the input's
// children are large or the import chain is deep.
//
// Package-visible so tests/app can drive the import expansion directly
// (see tests/app/namecoin_test.odin). Callers outside this file must
// not use it — route through the resolver entry points instead.
nc_resolve_value_with_imports :: proc(value_json: string, max_depth: int) -> (json.Value, bool) {
	value, err := json.parse(transmute([]u8)value_json, allocator = context.allocator)
	if err != nil {
		return {}, false
	}
	defer json.destroy_value(value)

	root, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}
	visited := make(map[string]bool, context.temp_allocator)
	expanded := nc_expand_imports(root, max_depth, &visited)
	return json.Value(expanded), true
}

// Recursive import expansion. Non-destructive: `obj` is READ ONLY.
// The returned Object is a fresh allocation whose keys and values are
// clones (via `json.clone_value`) of either `obj`'s non-import entries
// or of the sub-object selected out of an imported record. Callers
// destroy the returned Object with a single `json.destroy_value`.
//
// Previously this proc moved children out of `obj` and destroyed the
// `import` subtree in-place, leaving the caller's `json.destroy_value`
// on the original tree to revisit freed memory. The clone-based
// rewrite keeps the two trees fully independent so ownership is
// self-evident.
@(private = "file")
nc_expand_imports :: proc(
	obj: json.Object,
	budget: int,
	visited: ^map[string]bool,
) -> json.Object {
	// Start with a clone of everything in `obj` except `import`.
	base := nc_object_clone_without_import(obj)

	import_val, has_import := obj["import"]
	if !has_import || budget <= 0 {
		return base
	}
	ops := nc_parse_import_item(import_val)
	if len(ops) == 0 {
		return base
	}
	accumulator := make(json.Object, context.allocator)
	for op in ops {
		key := fmt.tprintf("%s|%s", op.name, op.selector)
		if visited[key] {
			continue
		}
		visited[key] = true
		defer delete_key(visited, key)

		imported_value, ok := nc_fetch_import(op.name)
		if !ok {
			continue
		}
		defer json.destroy_value(imported_value)

		imported_root, is_obj := imported_value.(json.Object)
		if !is_obj {
			continue
		}
		selected, ok_sel := nc_apply_selector(imported_root, op.selector)
		if !ok_sel {
			continue
		}
		// Recurse to expand nested imports. `expanded` is a fresh tree
		// independent of `imported_value`, safe to consume into the
		// accumulator; `imported_value` is destroyed by our defer.
		expanded := nc_expand_imports(selected, budget - 1, visited)
		nc_merge_importer_wins(&accumulator, expanded)
	}
	nc_merge_importer_wins(&base, accumulator)
	return base
}

// Clone an object minus its `import` key. Non-destructive; the source
// stays valid for the caller's `json.destroy_value`.
@(private = "file")
nc_object_clone_without_import :: proc(obj: json.Object) -> json.Object {
	out := make(json.Object, context.allocator)
	for k, v in obj {
		if k == "import" {
			continue
		}
		out[strings.clone(k)] = json.clone_value(v)
	}
	return out
}

@(private = "file")
Nc_Import_Op :: struct {
	name:     string, // owned
	selector: string, // owned
}

@(private = "file")
nc_parse_import_item :: proc(item: json.Value) -> []Nc_Import_Op {
	ops := make([dynamic]Nc_Import_Op, context.temp_allocator)
	// Shorthand string form: `"import": "d/foo"`.
	if s, is_str := item.(json.String); is_str {
		trimmed := strings.trim_space(string(s))
		if len(trimmed) > 0 {
			append(
				&ops,
				Nc_Import_Op{name = strings.clone(trimmed, context.temp_allocator), selector = ""},
			)
		}
		return ops[:]
	}
	arr, is_arr := item.(json.Array)
	if !is_arr || len(arr) == 0 {
		return ops[:]
	}
	// Distinguish canonical [[name, sel], ...] from shorthand [name, sel].
	if _, is_nested := arr[0].(json.Array); is_nested {
		for entry in arr {
			inner, ok := entry.(json.Array)
			if !ok {
				continue
			}
			if op, opok := nc_op_from_array(inner); opok {
				append(&ops, op)
			}
		}
		return ops[:]
	}
	if op, opok := nc_op_from_array(arr); opok {
		append(&ops, op)
	}
	return ops[:]
}

@(private = "file")
nc_op_from_array :: proc(arr: json.Array) -> (Nc_Import_Op, bool) {
	if len(arr) == 0 {
		return {}, false
	}
	name_val, name_ok := arr[0].(json.String)
	if !name_ok {
		return {}, false
	}
	name := strings.trim_space(string(name_val))
	if len(name) == 0 {
		return {}, false
	}
	selector := ""
	if len(arr) >= 2 {
		sel_val, sel_ok := arr[1].(json.String)
		if !sel_ok {
			return {}, false
		}
		selector = strings.trim_space(string(sel_val))
	}
	if strings.has_suffix(selector, ".") {
		return {}, false
	}
	return Nc_Import_Op {
			name = strings.clone(name, context.temp_allocator),
			selector = strings.clone(selector, context.temp_allocator),
		},
		true
}

// Walk a DNS-dotted selector into `root.map`, priority
// exact -> `*` wildcard -> `""` default. Returned object is a reference
// into `root` (json.Object is a distinct map, so returning by value does
// not copy the entries — do not free it independently). `ok=false` for a
// selector that walks off the tree.
@(private = "file")
nc_apply_selector :: proc(root: json.Object, selector: string) -> (json.Object, bool) {
	if len(selector) == 0 {
		return root, true
	}
	labels_temp := strings.split(selector, ".", context.temp_allocator)
	labels := make([dynamic]string, context.temp_allocator)
	for l in labels_temp {
		if len(l) > 0 {
			append(&labels, l)
		}
	}
	if len(labels) == 0 {
		return root, true
	}
	current := root
	for i := len(labels) - 1; i >= 0; i -= 1 {
		label := labels[i]
		map_obj, has_map := current["map"].(json.Object)
		if !has_map {
			return {}, false
		}
		if exact, ok := map_obj[label].(json.Object); ok {
			current = exact
			continue
		}
		if wildcard, ok := map_obj["*"].(json.Object); ok {
			current = wildcard
			continue
		}
		if fallback, ok := map_obj[""].(json.Object); ok {
			current = fallback
			continue
		}
		return {}, false
	}
	return current, true
}

// Merge `imported` underneath `importer` with importer-wins semantics.
// Consumes `imported`: its keys and values are either moved into
// `importer` (miss on `importer`) or destroyed (hit on `importer`).
// The `imported` map itself is deleted. `importer` retains sole
// ownership of its own entries and gains ownership of moved-in entries.
@(private = "file")
nc_merge_importer_wins :: proc(importer: ^json.Object, imported: json.Object) {
	imported := imported
	for k, v in imported {
		if _, present := importer[k]; present {
			// Importer wins; drop the imported entry.
			json.destroy_value(v)
			delete(k)
			continue
		}
		importer[k] = v
	}
	delete(imported)
}

// Fetch an imported name and return its parsed value tree. `unavailable`
// or `not-found` both collapse to `ok=false` here per gitworkshop semantics.
@(private = "file")
nc_fetch_import :: proc(name: string) -> (json.Value, bool) {
	status, raw := nc_name_show_with_fallback(name)
	if status != .Resolved {
		return {}, false
	}
	defer delete(raw)
	value, err := json.parse(transmute([]u8)raw, allocator = context.allocator)
	if err != nil {
		return {}, false
	}
	return value, true
}

// ── nostr field extraction ─────────────────────────────────────────

@(private = "file")
NC_HEX_LEN :: 64

@(private = "file")
nc_is_hex_pubkey :: proc(s: string) -> bool {
	if len(s) != NC_HEX_LEN {
		return false
	}
	for c in s {
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex {
			return false
		}
	}
	return true
}

@(private = "file")
nc_lower_clone :: proc(s: string, allocator := context.allocator) -> string {
	return strings.to_lower(s, allocator)
}

// Pull pubkey + relays out of the merged value tree.
@(private = "file")
nc_extract_nostr :: proc(value: json.Value, parsed: Nc_Parsed) -> (Nc_Status, Nc_Resolved) {
	root, is_obj := value.(json.Object)
	if !is_obj {
		return .Not_Found, {}
	}
	field, has_field := root["nostr"]
	if !has_field {
		return .Not_Found, {}
	}

	// Simple form: "nostr": "hex-pubkey".
	if s, is_str := field.(json.String); is_str {
		if parsed.is_domain && parsed.local_part != "_" {
			return .Not_Found, {}
		}
		if !nc_is_hex_pubkey(string(s)) {
			return .Not_Found, {}
		}
		return .Resolved, Nc_Resolved {
			pubkey_hex = nc_lower_clone(string(s)),
			relays = nil,
			namecoin_name = strings.clone(parsed.namecoin_name),
			local_part = strings.clone("_"),
		}
	}

	nostr_obj, is_nostr_obj := field.(json.Object)
	if !is_nostr_obj {
		return .Not_Found, {}
	}

	if parsed.is_domain {
		return nc_extract_from_domain(nostr_obj, parsed)
	}
	return nc_extract_from_identity(nostr_obj, parsed)
}

// Package-visible so tests/app can drive it directly (see
// tests/app/namecoin_test.odin). Callers outside this file must not use
// it — route through the resolver entry points instead.
nc_extract_from_domain :: proc(nostr: json.Object, parsed: Nc_Parsed) -> (Nc_Status, Nc_Resolved) {
	names_obj, has_names := nostr["names"].(json.Object)
	if !has_names {
		// Some d/ records use the identity-style flat shape (bare
		// `"pubkey":...` at the root of the `nostr` object). Accept it
		// only when the caller asked for the root (`_`) — for any other
		// local part the identity-style shape does not name them.
		if parsed.local_part != "_" {
			return .Not_Found, {}
		}
		return nc_extract_from_identity(nostr, parsed)
	}

	// FAIL CLOSED. `alice@example.bit` must resolve to alice's entry, or
	// to nothing. Never fall back to `_`: that would silently substitute
	// the domain owner's identity for a user the record does not name.
	// Never scan for "first valid entry": that would substitute an
	// arbitrary other user's identity for the root when the record has
	// no `_`.
	key := parsed.local_part
	entry, has_entry := names_obj[key]
	if !has_entry {
		return .Not_Found, {}
	}
	pk_str, is_str := entry.(json.String)
	if !is_str || !nc_is_hex_pubkey(string(pk_str)) {
		return .Not_Found, {}
	}
	picked_key := string(pk_str)

	relays := nc_extract_relays(nostr, picked_key)
	return .Resolved, Nc_Resolved {
		pubkey_hex = nc_lower_clone(picked_key),
		relays = relays,
		namecoin_name = strings.clone(parsed.namecoin_name),
		local_part = strings.clone(key),
	}
}

// Identity-shape extraction: accept the top-level `pubkey` binding
// only. Reject any `names` sub-object; those belong to domain (`d/`)
// records, and treating them as identity-owner keys silently
// substitutes somebody else's identity for the requested name.
//
// For a `d/` root lookup whose record happens to use the identity
// shape (`{"nostr":{"pubkey":...}}`) this proc is also called; the
// caller has already checked `parsed.local_part == "_"` before
// routing here, so accepting the flat `pubkey` is well-defined.
//
// Package-visible so tests/app can drive it directly (see
// tests/app/namecoin_test.odin). Callers outside this file must not
// use it — route through the resolver entry points instead.
nc_extract_from_identity :: proc(
	nostr: json.Object,
	parsed: Nc_Parsed,
) -> (
	Nc_Status,
	Nc_Resolved,
) {
	if pk, ok := nostr["pubkey"].(json.String); ok && nc_is_hex_pubkey(string(pk)) {
		relays: []string
		if arr, is_arr := nostr["relays"].(json.Array); is_arr {
			tmp := make([dynamic]string)
			for entry in arr {
				if s, ok := entry.(json.String); ok {
					append(&tmp, strings.clone(string(s)))
				}
			}
			if len(tmp) > 0 {
				relays = tmp[:]
			} else {
				delete(tmp)
			}
		}
		return .Resolved, Nc_Resolved {
			pubkey_hex = nc_lower_clone(string(pk)),
			relays = relays,
			namecoin_name = strings.clone(parsed.namecoin_name),
			local_part = strings.clone("_"),
		}
	}
	return .Not_Found, {}
}

@(private = "file")
nc_extract_relays :: proc(nostr: json.Object, pubkey: string) -> []string {
	raw, has_raw := nostr["relays"]
	if !has_raw {
		return nil
	}
	// Domain shape: map keyed by pubkey.
	if m, is_map := raw.(json.Object); is_map {
		lower_key := strings.to_lower(pubkey, context.temp_allocator)
		arr_val, has_arr := m[lower_key]
		if !has_arr {
			arr_val, has_arr = m[pubkey]
			if !has_arr {
				return nil
			}
		}
		arr, is_arr := arr_val.(json.Array)
		if !is_arr {
			return nil
		}
		out := make([dynamic]string)
		for entry in arr {
			if s, ok := entry.(json.String); ok {
				append(&out, strings.clone(string(s)))
			}
		}
		if len(out) == 0 {
			delete(out)
			return nil
		}
		return out[:]
	}
	// Identity shape: flat array.
	if arr, is_arr := raw.(json.Array); is_arr {
		out := make([dynamic]string)
		for entry in arr {
			if s, ok := entry.(json.String); ok {
				append(&out, strings.clone(string(s)))
			}
		}
		if len(out) == 0 {
			delete(out)
			return nil
		}
		return out[:]
	}
	return nil
}
