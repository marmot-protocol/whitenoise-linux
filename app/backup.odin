// Password-sealed backup of everything this port owns locally: the
// settings blob (themes, drafts, nicknames, blocked, prefs), the
// hidden-message ids, the custom emoji, and any user themes. The
// offline send queue is left out: it is sealed with this device's vault
// key, so a restore elsewhere could only drop it.
//
// marmot-c exposes no store export/import, so the account keys, the
// MLS state, and the message history are NOT in here. A backup
// restores this device's preferences, not its identity (PORT.md).
//
//   files ──manifest json──► plaintext ──XChaCha20-Poly1305──► .wnbk
//                                             ▲
//                       password ──scrypt─────┘  (nip49.odin's scrypt)
package main

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// "WNBK" | ver | log_n | salt[16] | nonce[24] | tag[16] | ciphertext
BACKUP_MAGIC :: "WNBK"
BACKUP_VERSION :: 1
BACKUP_LOG_N :: 16
BACKUP_HEADER :: 4 + 1 + 1 + 16 + 24 + 16
BACKUP_MAX_LOG_N :: 20 // a hostile file can't ask for gigabytes of ROMix
BACKUP_FILE_NAME :: "whitenoise-backup.wnbk"

// The header doubles as the AEAD associated data, so a flipped
// version or cost byte fails the tag instead of steering the KDF.
@(private = "file")
BACKUP_AD_LEN :: 6

Backup_Entry :: struct {
	path: string, // manifest label, e.g. "settings.json" or "emoji/cat.png"
	data: string, // base64 of the file bytes
}

// ── Container ───────────────────────────────────────────────────────

backup_seal :: proc(plain: []u8, password: string, allocator := context.allocator) -> []u8 {
	out := make([]u8, BACKUP_HEADER + len(plain), allocator)
	copy(out[0:4], BACKUP_MAGIC)
	out[4] = BACKUP_VERSION
	out[5] = BACKUP_LOG_N
	crypto.rand_bytes(out[6:22]) // salt
	crypto.rand_bytes(out[22:46]) // nonce

	sym: [32]u8
	scrypt_r8p1(transmute([]u8)password, out[6:22], BACKUP_LOG_N, sym[:])

	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, sym[:])
	chacha20poly1305.seal(&ctx, out[BACKUP_HEADER:], out[46:62], out[22:46], out[0:BACKUP_AD_LEN], plain)
	return out
}

// nil on a wrong password, a truncated file, or a foreign format.
backup_open :: proc(blob: []u8, password: string, allocator := context.allocator) -> ([]u8, bool) {
	if len(blob) < BACKUP_HEADER || string(blob[0:4]) != BACKUP_MAGIC || blob[4] != BACKUP_VERSION {
		return nil, false
	}
	if uint(blob[5]) > BACKUP_MAX_LOG_N {
		return nil, false
	}

	sym: [32]u8
	scrypt_r8p1(transmute([]u8)password, blob[6:22], uint(blob[5]), sym[:])

	plain := make([]u8, len(blob) - BACKUP_HEADER, allocator)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, sym[:])
	if !chacha20poly1305.open(&ctx, plain, blob[22:46], blob[0:BACKUP_AD_LEN], blob[BACKUP_HEADER:], blob[46:62]) {
		delete(plain, allocator)
		return nil, false
	}
	return plain, true
}

// ── Manifest ────────────────────────────────────────────────────────

config_dir :: proc(allocator := context.temp_allocator) -> string {
	path := settings_path(allocator)
	return path[:len(path) - len("/settings.json")]
}

@(private = "file")
pack_file :: proc(entries: ^[dynamic]Backup_Entry, label: string, path: string) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	encoded, enc_err := base64.encode(data, base64.ENC_TABLE, context.temp_allocator)
	if enc_err != nil {
		return
	}
	append(entries, Backup_Entry{label, encoded})
}

@(private = "file")
pack_dir :: proc(entries: ^[dynamic]Backup_Entry, label: string, dir: string) {
	files, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	for file in files {
		if file.type == .Directory {
			continue
		}
		pack_file(entries, fmt.tprintf("%s/%s", label, file.name), file.fullpath)
	}
}

// The manifest JSON, temp-allocated. Missing files are simply absent.
backup_pack :: proc() -> ([]u8, bool) {
	entries := make([dynamic]Backup_Entry, context.temp_allocator)
	cfg := config_dir()

	pack_file(&entries, "settings.json", fmt.tprintf("%s/settings.json", cfg))
	pack_file(&entries, "hidden.json", fmt.tprintf("%s/hidden.json", cfg))
	pack_dir(&entries, "emoji", emoji_dir())
	pack_dir(&entries, "themes", fmt.tprintf("%s/themes", data_home))

	data, err := json.marshal(entries[:], allocator = context.temp_allocator)
	return data, err == nil
}

// Map a manifest label onto the file it may overwrite. The archive is
// untrusted input, so only the exact shapes backup_pack writes are
// accepted and the name may not walk out of its directory.
backup_target :: proc(label: string, allocator := context.temp_allocator) -> (string, bool) {
	dir, name: string
	switch {
	case label == "settings.json", label == "hidden.json":
		dir, name = config_dir(allocator), label
	case strings.has_prefix(label, "emoji/"):
		dir, name = emoji_dir(allocator), label[len("emoji/"):]
	case strings.has_prefix(label, "themes/"):
		dir, name = fmt.aprintf("%s/themes", data_home, allocator = allocator), label[len("themes/"):]
	case:
		return "", false
	}
	if len(name) == 0 || strings.contains(name, "/") || strings.contains(name, "\\") || strings.contains(name, "..") {
		return "", false
	}
	return fmt.aprintf("%s/%s", dir, name, allocator = allocator), true
}

// Write the manifest back to disk. Returns how many files landed.
backup_restore :: proc(plain: []u8) -> (written: int, ok: bool) {
	entries: []Backup_Entry
	if json.unmarshal(plain, &entries, allocator = context.temp_allocator) != nil {
		return 0, false
	}

	os.make_directory(config_dir())
	os.make_directory(emoji_dir())
	os.make_directory(fmt.tprintf("%s/themes", data_home))

	for entry in entries {
		path, target_ok := backup_target(entry.path)
		if !target_ok {
			continue
		}
		bytes, dec_err := base64.decode(entry.data, base64.DEC_TABLE, nil, context.temp_allocator)
		if dec_err != nil {
			continue
		}
		if os.write_entire_file(path, bytes, {.Read_User, .Write_User}) == nil {
			written += 1
		}
	}
	return written, true
}
