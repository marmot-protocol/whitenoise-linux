// Password-encrypted secret vault: one file, $home/vault.db, holding
// every secret this app keeps. There is no OS keyring and no plaintext
// key on disk.
//
//   file:  { version, kdf{argon2id salt + cost}, nonce_hex, ciphertext_hex }
//   plain: XChaCha20-Poly1305(json(map[string]string)) keyed by
//          Argon2id(password, salt)
//
// Version, Argon2id costs, and ciphertext layout are fixed. The blob
// key is an extra map entry. A reader that still derives the historical subkey
// opens account secrets, and opens blobs only while that derivation
// still matches (no password change on this binary, and not a vault
// created here).
//
// Every mutation re-seals the whole map under a fresh nonce and renames
// atomically into place at mode 0600. A wrong password fails the
// Poly1305 tag, which is the only "wrong password" signal there is.
// There is no recovery: the unlock screen's escape hatch deletes the
// vault and starts over from an nsec.
//
// Account secrets live in the map (marmot's per-account signing keys,
// via the marmot-c secret-store vtable). Every other vault-bound file
// is sealed with the blob key stored in that map under VAULT_BLOB_KEY,
// so a password change re-seals this file and leaves the others in
// place. A vault written before that entry still derives the historical
// subkey until the password changes; the change saves the derived key
// in the same persist.
//
// Not migrated: an install made before the vault kept its account keys
// in the OS keychain, which nothing here can read. Those installs sign
// in again with their nsec.
package main

import "core:time"

import "core:crypto"
import "core:crypto/argon2id"
import "core:crypto/chacha20poly1305"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"

_ :: linux
_ :: strconv

VAULT_VERSION :: 1
VAULT_SALT_LEN :: 16
VAULT_NONCE_LEN :: 24 // XChaCha20-Poly1305 takes a 192-bit nonce
VAULT_TAG_LEN :: 16
VAULT_KEY_LEN :: 32

// Argon2id cost: ~19 MiB / 2 passes / 1 lane, the OWASP baseline. Stored
// in the envelope so a future tuning doesn't lock anyone out.
VAULT_M_COST :: 19_456
VAULT_T_COST :: 2
VAULT_P_COST :: 1

// A hostile or corrupt envelope must not turn unlock into a
// multi-gigabyte allocation; legitimate vaults are sealed at the costs
// above.
VAULT_MAX_M_COST :: 1 << 20 // 1 GiB of Argon2 memory
VAULT_MAX_T_COST :: 64
VAULT_MAX_P_COST :: 64

// Domain separation for the historical derived blob subkey. A vault
// with no VAULT_BLOB_KEY entry still uses it, so existing sealed files
// stay readable. Changing the label would derive a different subkey.
VAULT_BLOB_LABEL :: "darkmatter-linux/media-cache/v1"

// 32-byte key, hex, inside the secret map. Not an account secret.
VAULT_BLOB_KEY :: "blob-key"

Vault_Err :: enum {
	None,
	Not_Found, // no vault file
	Wrong_Password, // the AEAD tag failed
	Corrupt, // malformed envelope, bad hex, unsupported version
	Io,
}

// The unlocked vault: the derived key plus the decrypted secret map,
// both held for the session. Mutations re-seal and persist immediately.
Vault :: struct {
	key:      [VAULT_KEY_LEN]u8,
	salt:     [VAULT_SALT_LEN]u8,
	data:     map[string]string,
	unlocked: bool,
}

// Process-wide: the secret-store callbacks run on marmot's worker
// threads, so every touch takes the mutex.
g_vault: Vault
g_vault_lock: sync.Mutex

@(private = "file")
Kdf_Params :: struct {
	algo:     string, // "argon2id"
	salt_hex: string,
	m_cost:   u32,
	t_cost:   u32,
	p_cost:   u32,
}

@(private = "file")
Vault_Envelope :: struct {
	version:        u32,
	kdf:            Kdf_Params,
	nonce_hex:      string,
	ciphertext_hex: string,
}

@(private)
Vault_Unlock :: enum {
	Password,
	Dev_Cache,
}

// The Linux development watcher keeps this cache in an inherited memfd.
// Release builds on every platform always authenticate the vault password.
when ODIN_OS == .Linux {
	@(private = "file")
	dev_vault_fd :: proc() -> linux.Fd {
		when !#config(WN_DEV, false) {return -1}
		value, ok := strconv.parse_int(os.get_env("WN_DEV_VAULT_FD", context.temp_allocator))
		if !ok || value < 3 || value > int(max(i32)) {return -1}
		fd := linux.Fd(value)
		if _, err := linux.fcntl_get_seals(fd, .GET_SEALS); err != .NONE {return -1}
		FD_CLOEXEC :: linux.Fd(1)
		if linux.fcntl_setfd(fd, .SETFD, FD_CLOEXEC) != .NONE {return -1}
		return fd
	}
}

@(private = "file")
dev_vault_store :: proc(v: ^Vault) {
	when ODIN_OS == .Linux {
		fd := dev_vault_fd()
		if fd < 0 {return}
		if linux.ftruncate(fd, 0) != .NONE {return}
		if !v.unlocked {return}
		// Salt binds the cached key to this vault generation.
		cache: [VAULT_SALT_LEN + VAULT_KEY_LEN]u8
		defer mem.zero_slice(cache[:])
		copy(cache[:VAULT_SALT_LEN], v.salt[:])
		copy(cache[VAULT_SALT_LEN:], v.key[:])
		if n, err := linux.pwrite(fd, cache[:], 0); err != .NONE || n != len(cache) {
			linux.ftruncate(fd, 0)
		}
	}
}

@(private = "file")
dev_vault_read :: proc(cache: []u8) -> bool {
	when ODIN_OS == .Linux {
		fd := dev_vault_fd()
		if fd < 0 {return false}
		n, err := linux.pread(fd, cache, 0)
		return err == .NONE && n == len(cache)
	} else {
		return false
	}
}

// A one-byte marker survives watcher process replacement. An empty cache
// is also used before first unlock, so truncating alone cannot tell the
// next process to refuse its inherited WN_VAULT_PW startup automation.
dev_vault_revoke :: proc() {
	when ODIN_OS == .Linux {
		fd := dev_vault_fd()
		if fd < 0 {return}
		marker := [1]u8{1}
		linux.ftruncate(fd, 0)
		linux.pwrite(fd, marker[:], 0)
	}
}

dev_vault_manual_locked :: proc() -> bool {
	when ODIN_OS == .Linux {
		fd := dev_vault_fd()
		if fd < 0 {return false}
		marker: [2]u8
		n, err := linux.pread(fd, marker[:], 0)
		return err == .NONE && n == 1 && marker[0] == 1
	} else {
		return false
	}
}

vault_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/vault.db", data_home, allocator = allocator)
}

vault_exists :: proc() -> bool {
	return os.exists(vault_path())
}

// ── Container ───────────────────────────────────────────────────────

@(private = "file")
derive_key :: proc(password: string, salt: []u8, m_cost, t_cost, p_cost: u32, dst: []u8) {
	timing_start := time.tick_now()
	defer local_timing_end(.linux_vault_derive_key, timing_start)
	params := argon2id.Parameters {
		memory_size = m_cost,
		passes      = t_cost,
		parallelism = p_cost,
	}
	_ = argon2id.derive(&params, transmute([]u8)password, salt, dst)
}

// Seal `plain` under `key` as nonce(24) || ciphertext || tag(16), the
// layout both the envelope body and every sealed blob use.
@(private = "file")
seal_xchacha :: proc(key: []u8, plain: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, VAULT_NONCE_LEN + len(plain) + VAULT_TAG_LEN, allocator)
	crypto.rand_bytes(out[:VAULT_NONCE_LEN])

	body := VAULT_NONCE_LEN + len(plain)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	chacha20poly1305.seal(
		&ctx,
		out[VAULT_NONCE_LEN:body],
		out[body:],
		out[:VAULT_NONCE_LEN],
		nil,
		plain,
	)
	return out
}

@(private = "file")
open_xchacha :: proc(key: []u8, sealed: []u8, allocator := context.allocator) -> ([]u8, bool) {
	if len(sealed) < VAULT_NONCE_LEN + VAULT_TAG_LEN {
		return nil, false
	}
	body := len(sealed) - VAULT_TAG_LEN

	plain := make([]u8, body - VAULT_NONCE_LEN, allocator)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key)
	if !chacha20poly1305.open(
		&ctx,
		plain,
		sealed[:VAULT_NONCE_LEN],
		nil,
		sealed[VAULT_NONCE_LEN:body],
		sealed[body:],
	) {
		delete(plain, allocator)
		return nil, false
	}
	return plain, true
}

// Encrypt the current map under a fresh nonce and atomically write the
// file: a crash mid-write can't truncate the existing vault.
@(private = "file")
vault_persist :: proc(v: ^Vault) -> Vault_Err {
	timing_start := time.tick_now()
	defer local_timing_end(.linux_vault_persist, timing_start)
	plain, marshal_err := json.marshal(v.data, allocator = context.temp_allocator)
	if marshal_err != nil {
		return .Io
	}
	defer mem.zero_slice(plain)

	sealed := seal_xchacha(v.key[:], plain, context.temp_allocator)
	nonce_hex, _ := hex.encode(sealed[:VAULT_NONCE_LEN], context.temp_allocator)
	cipher_hex, _ := hex.encode(sealed[VAULT_NONCE_LEN:], context.temp_allocator)
	salt_hex, _ := hex.encode(v.salt[:], context.temp_allocator)

	env := Vault_Envelope {
		version = VAULT_VERSION,
		kdf = {
			algo = "argon2id",
			salt_hex = string(salt_hex),
			m_cost = VAULT_M_COST,
			t_cost = VAULT_T_COST,
			p_cost = VAULT_P_COST,
		},
		nonce_hex = string(nonce_hex),
		ciphertext_hex = string(cipher_hex),
	}
	bytes, env_err := json.marshal(env, allocator = context.temp_allocator)
	if env_err != nil {
		return .Io
	}

	path := vault_path()
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, bytes, perm = {.Read_User, .Write_User}) != nil {
		return .Io
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return .Io
	}
	dev_vault_store(v)
	return .None
}

// Create a fresh empty vault sealed with `password`, replacing whatever
// g_vault held.
vault_create :: proc(password: string) -> Vault_Err {
	timing_start := time.tick_now()
	defer local_timing_end(.linux_vault_create, timing_start)
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)

	vault_wipe(&g_vault)
	crypto.rand_bytes(g_vault.salt[:])
	derive_key(password, g_vault.salt[:], VAULT_M_COST, VAULT_T_COST, VAULT_P_COST, g_vault.key[:])
	g_vault.unlocked = true
	if !vault_generate_blob_key(&g_vault) {
		vault_wipe(&g_vault)
		return .Io
	}

	if err := vault_persist(&g_vault); err != .None {
		vault_wipe(&g_vault)
		return err
	}
	return .None
}

// Read $home/vault.db and decrypt it with `password`.
vault_open :: proc(password: string, source: Vault_Unlock = .Password) -> Vault_Err {
	timing_start := time.tick_now()
	defer local_timing_end(.linux_vault_open, timing_start)
	bytes, read_err := os.read_entire_file(vault_path(), context.temp_allocator)
	if read_err != nil {
		return .Not_Found
	}

	env: Vault_Envelope
	if json.unmarshal(bytes, &env, allocator = context.temp_allocator) != nil {
		return .Corrupt
	}
	if env.version != VAULT_VERSION || env.kdf.algo != "argon2id" {
		return .Corrupt
	}
	if env.kdf.m_cost > VAULT_MAX_M_COST ||
	   env.kdf.t_cost > VAULT_MAX_T_COST ||
	   env.kdf.p_cost > VAULT_MAX_P_COST {
		return .Corrupt
	}

	salt, salt_ok := hex.decode(transmute([]u8)env.kdf.salt_hex, context.temp_allocator)
	nonce, nonce_ok := hex.decode(transmute([]u8)env.nonce_hex, context.temp_allocator)
	cipher, cipher_ok := hex.decode(transmute([]u8)env.ciphertext_hex, context.temp_allocator)
	if !salt_ok ||
	   !nonce_ok ||
	   !cipher_ok ||
	   len(salt) != VAULT_SALT_LEN ||
	   len(nonce) != VAULT_NONCE_LEN {
		return .Corrupt
	}

	key: [VAULT_KEY_LEN]u8
	defer mem.zero(&key, size_of(key))
	if source == .Dev_Cache {
		cache: [VAULT_SALT_LEN + VAULT_KEY_LEN]u8
		defer mem.zero_slice(cache[:])
		if !dev_vault_read(cache[:]) || string(cache[:VAULT_SALT_LEN]) != string(salt) {
			return .Wrong_Password
		}
		copy(key[:], cache[VAULT_SALT_LEN:])
	} else {
		derive_key(password, salt, env.kdf.m_cost, env.kdf.t_cost, env.kdf.p_cost, key[:])
	}

	// The on-disk split (nonce, ciphertext) rejoins into the one layout
	// open_xchacha reads.
	sealed := make([]u8, len(nonce) + len(cipher), context.temp_allocator)
	copy(sealed[:len(nonce)], nonce)
	copy(sealed[len(nonce):], cipher)

	plain, opened := open_xchacha(key[:], sealed, context.temp_allocator)
	if !opened {
		return .Wrong_Password
	}
	defer mem.zero_slice(plain)

	data: map[string]string
	if json.unmarshal(plain, &data, allocator = context.allocator) != nil {
		delete(data)
		return .Corrupt
	}

	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	vault_wipe(&g_vault)
	g_vault.key = key
	copy(g_vault.salt[:], salt)
	g_vault.data = data
	g_vault.unlocked = true
	dev_vault_store(&g_vault)
	return .None
}

// True when `password` is the one the vault is sealed with right now.
// The vault is already unlocked when this runs, so it is not a
// cryptographic gate: it checks that the person at the keyboard is the
// one who opened it before letting them rotate the password.
vault_verify :: proc(password: string) -> bool {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	if !g_vault.unlocked {
		return false
	}

	key: [VAULT_KEY_LEN]u8
	defer mem.zero(&key, size_of(key))
	derive_key(password, g_vault.salt[:], VAULT_M_COST, VAULT_T_COST, VAULT_P_COST, key[:])
	return crypto.compare_constant_time(key[:], g_vault.key[:]) == 1
}

// Re-seal the vault under a new password: fresh salt, fresh master key,
// same secret map. A legacy map with no blob key gains the derived key
// in this same persist, so files sealed under it stay readable. The
// write is atomic. On failure the session master key, salt, and a blob
// key inserted by this call go back to matching the file still on disk.
vault_rekey :: proc(password: string) -> Vault_Err {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	if !g_vault.unlocked {
		return .Not_Found
	}

	inserted := false
	if !(VAULT_BLOB_KEY in g_vault.data) {
		derived: [VAULT_KEY_LEN]u8
		defer mem.zero(&derived, size_of(derived))
		blob_key_derive(g_vault.key[:], derived[:])
		if !vault_put_blob_key(&g_vault, derived[:]) {
			return .Io
		}
		inserted = true
	}

	old_key, old_salt := g_vault.key, g_vault.salt
	defer mem.zero(&old_key, size_of(old_key))
	crypto.rand_bytes(g_vault.salt[:])
	derive_key(password, g_vault.salt[:], VAULT_M_COST, VAULT_T_COST, VAULT_P_COST, g_vault.key[:])

	if err := vault_persist(&g_vault); err != .None {
		g_vault.key, g_vault.salt = old_key, old_salt
		if inserted {
			vault_drop_blob_key(&g_vault)
		}
		return err
	}
	return .None
}

// Zero the key and free the secret map. Caller holds the lock.
@(private = "file")
vault_wipe :: proc(v: ^Vault) {
	for key, value in v.data {
		delete(key)
		mem.zero_slice(transmute([]u8)value)
		delete(value)
	}
	delete(v.data)
	v.data = nil
	mem.zero(&v.key, size_of(v.key))
	v.unlocked = false
}

@(private)
vault_lock :: proc() {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	vault_wipe(&g_vault)
}

// A user lock is different from a development module restart: revoke the
// inherited key as well, so the watcher cannot reopen this vault unattended.
vault_relock :: proc() {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	vault_wipe(&g_vault)
	dev_vault_revoke()
}

// Vault-bound paths. Password change leaves every row except vault.db
// on the persisted blob key. Reset removes all of them. backup_pack
// includes none of them. cache_clear removes media-cache only.
//
//   vault.db               account secrets and the blob key
//   offline-queue.json     unsent sends
//   stickers/              library.bin and personal images
//   gifs/                  library.bin and saved GIF blobs
//   media-cache/           attachments, profile-*.bin avatars, *.stt transcripts
//
// The unlock gate joins blob writers, then calls this. session_stop
// has already joined them on the lock path; vault_stores_quiesce runs
// again so a queued sticker save cannot land after the directories go.
vault_delete :: proc() {
	sync.lock(&g_vault_lock)
	vault_wipe(&g_vault)
	dev_vault_store(&g_vault)
	sync.unlock(&g_vault_lock)

	os.remove(vault_path())
	os.remove(offline_path())
	os.remove_all(media_cache_dir())
	os.remove_all(fmt.tprintf("%s/stickers", data_home))
	os.remove_all(fmt.tprintf("%s/gifs", data_home))
}

// Join blob writers. Safe when none are running.
@(private)
vault_stores_quiesce :: proc() {
	sticker_stop()
	media_stop()
	stop_pic_worker()
	if g_ui != nil {
		gif_stop(g_ui)
		stt_stop(g_ui)
	}
}

vault_has :: proc(key: string) -> bool {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	return key in g_vault.data
}

// The value cloned into `allocator`; "" and false when absent.
vault_get :: proc(key: string, allocator := context.allocator) -> (string, bool) {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)

	value, found := g_vault.data[key]
	if !found {
		return "", false
	}
	return strings.clone(value, allocator), true
}

// Insert/overwrite a secret and re-seal the file.
vault_set :: proc(key: string, value: string) -> Vault_Err {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	if !g_vault.unlocked {
		return .Not_Found
	}

	// The map owns its strings. Assigning over an existing entry keeps
	// the key already in the map, so only a fresh entry clones one.
	if old_value, found := g_vault.data[key]; found {
		mem.zero_slice(transmute([]u8)old_value)
		delete(old_value)
		g_vault.data[key] = strings.clone(value)
	} else {
		g_vault.data[strings.clone(key)] = strings.clone(value)
	}
	return vault_persist(&g_vault)
}

vault_remove :: proc(key: string) -> Vault_Err {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)

	if !(key in g_vault.data) {
		return .None
	}
	old_key, old_value := delete_key(&g_vault.data, key)
	delete(old_key)
	mem.zero_slice(transmute([]u8)old_value)
	delete(old_value)
	return vault_persist(&g_vault)
}

// ── Blob sealing ────────────────────────────────────────────────────

// Historical subkey: SHA-256(label || master key). The master key is
// already 32 high-entropy bytes, so one SHA-256 is a sound KDF here.
@(private = "file")
blob_key_derive :: proc(master: []u8, dst: []u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)string(VAULT_BLOB_LABEL))
	sha2.update(&ctx, master)
	sha2.final(&ctx, dst)
}

@(private = "file")
blob_key_decode :: proc(raw: string, dst: []u8) -> bool {
	if len(raw) != VAULT_KEY_LEN * 2 {
		return false
	}
	decoded, ok := hex.decode(transmute([]u8)raw, context.temp_allocator)
	if !ok || len(decoded) != VAULT_KEY_LEN {
		return false
	}
	copy(dst, decoded)
	mem.zero_slice(decoded)
	return true
}

// Caller holds the vault lock. The map owns both strings.
@(private = "file")
vault_put_blob_key :: proc(v: ^Vault, raw: []u8) -> bool {
	if len(raw) != VAULT_KEY_LEN {
		return false
	}
	if v.data == nil {
		v.data = make(map[string]string)
	}
	encoded, enc_err := hex.encode(raw, context.temp_allocator)
	if enc_err != nil {
		return false
	}
	defer mem.zero_slice(encoded)
	cloned := strings.clone(string(encoded))
	if old, found := v.data[VAULT_BLOB_KEY]; found {
		mem.zero_slice(transmute([]u8)old)
		delete(old)
		v.data[VAULT_BLOB_KEY] = cloned
	} else {
		v.data[strings.clone(VAULT_BLOB_KEY)] = cloned
	}
	return true
}

@(private = "file")
vault_generate_blob_key :: proc(v: ^Vault) -> bool {
	raw: [VAULT_KEY_LEN]u8
	defer mem.zero(&raw, size_of(raw))
	crypto.rand_bytes(raw[:])
	return vault_put_blob_key(v, raw[:])
}

// Caller holds the vault lock.
@(private = "file")
vault_drop_blob_key :: proc(v: ^Vault) {
	if !(VAULT_BLOB_KEY in v.data) {
		return
	}
	old_key, old_value := delete_key(&v.data, VAULT_BLOB_KEY)
	delete(old_key)
	mem.zero_slice(transmute([]u8)old_value)
	delete(old_value)
}

// Stored blob key when the map has one. Otherwise the historical
// derivation, so a vault that has never changed its password on this
// binary still opens the files it already sealed. A present but unusable
// entry fails closed: falling through to the derived key would seal new
// files under a different key than the one already on disk.
@(private = "file")
blob_key :: proc(dst: []u8) -> bool {
	sync.lock(&g_vault_lock)
	defer sync.unlock(&g_vault_lock)
	if !g_vault.unlocked || len(dst) != VAULT_KEY_LEN {
		return false
	}
	if raw, found := g_vault.data[VAULT_BLOB_KEY]; found {
		return blob_key_decode(raw, dst)
	}
	blob_key_derive(g_vault.key[:], dst)
	return true
}

// Seal arbitrary bytes for disk (decrypted attachments, the offline
// queue). nil when the vault is locked, which no caller reaches: both
// consumers only run behind an unlocked vault.
vault_seal_blob :: proc(plain: []u8, allocator := context.allocator) -> ([]u8, bool) {
	key: [VAULT_KEY_LEN]u8
	defer mem.zero(&key, size_of(key))
	if !blob_key(key[:]) {
		return nil, false
	}
	return seal_xchacha(key[:], plain, allocator), true
}

// Reverse of vault_seal_blob. False on a truncated blob or a failed tag
// (corruption, or a blob sealed under a previous vault password).
vault_open_blob :: proc(sealed: []u8, allocator := context.allocator) -> ([]u8, bool) {
	key: [VAULT_KEY_LEN]u8
	defer mem.zero(&key, size_of(key))
	if !blob_key(key[:]) {
		return nil, false
	}
	return open_xchacha(key[:], sealed, allocator)
}
