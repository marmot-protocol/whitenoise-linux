// Encrypted-at-rest disk cache for decrypted media attachments.
//
// Decrypted attachment bytes are sensitive, and this repo deliberately keeps no
// plaintext on disk (see `vault.rs`). So each entry is sealed with the vault's
// media-cache subkey (XChaCha20-Poly1305) before being written to
// `$WN_HOME/media-cache/<file_hash>.bin` (mode 0600). Entries are
// content-addressed by the Blossom blob hash (the `x` field of the NIP-92
// `imeta` tag), so the same attachment referenced from several messages shares
// one entry, and a download whose ciphertext hash mismatches can never collide
// with a good entry.
//
// The whole cache is best-effort: any IO or crypto failure degrades to a miss
// and the caller falls back to a fresh Blossom download + decrypt. We store the
// decrypted *original* bytes (the compressed PNG/JPEG/…), not decoded RGBA —
// far smaller on disk, and re-decoding locally is cheap next to the network
// round-trip and decryption we're avoiding.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::sealed_store;
use crate::vault::Vault;

fn cache_dir() -> PathBuf {
    crate::backend::default_home().join("media-cache")
}

/// Whether `hash_hex` is a safe, hex-only filename component. Guards the path
/// join against traversal even though these values come from parsed imeta tags.
fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn path_for(hash_hex: &str) -> Option<PathBuf> {
    is_hex(hash_hex).then(|| cache_dir().join(format!("{hash_hex}.bin")))
}

/// Look up a previously cached attachment by its blob hash. Returns the
/// decrypted plaintext, or `None` on any miss (absent / unreadable / sealed
/// under a stale key). A stale entry is evicted so a fresh download can
/// repopulate it.
pub fn get(vault: &Arc<Mutex<Vault>>, hash_hex: &str) -> Option<Vec<u8>> {
    let path = path_for(hash_hex)?;
    match sealed_store::get(vault, &path)? {
        Ok(plain) => Some(plain),
        Err(e) => {
            tracing::warn!(target: "media_cache", "open {hash_hex}: {e}; evicting");
            None
        }
    }
}

/// Seal `plaintext` under the vault key and write it to the cache. Best-effort:
/// failures are logged and swallowed — the in-memory cache still holds the live
/// copy for the rest of this session.
pub fn put(vault: &Arc<Mutex<Vault>>, hash_hex: &str, plaintext: &[u8]) {
    let Some(path) = path_for(hash_hex) else {
        return;
    };
    if let Err(e) = sealed_store::put(vault, &path, plaintext) {
        tracing::warn!(target: "media_cache", "put {hash_hex}: {e}");
    }
}

/// Delete the entire media cache. Called when the vault is reset, since entries
/// sealed under the old key are unreadable afterwards anyway.
pub fn clear() {
    let _ = std::fs::remove_dir_all(cache_dir());
}

/// Evict a single cache entry by its blob hash. Called when the message
/// referencing it is deleted (kind-5 retraction or local-only hide), so its
/// decrypted bytes don't keep sitting on disk past the message's own life.
/// Best-effort: a missing entry is not an error.
pub fn remove(hash_hex: &str) {
    if let Some(path) = path_for(hash_hex) {
        let _ = std::fs::remove_file(path);
    }
}

/// Every `ciphertext_sha256` value carried by `tags`' `imeta` entries — the
/// cache key for each attachment on a message (one per image in an album, or
/// the sole attachment). Used to resolve which entries to [`remove`] on
/// delete; unlike [`crate::parse_all_media_references`] this only needs the
/// one field eviction cares about, so it doesn't require every other `imeta`
/// field to be present.
pub fn hashes_from_tags(tags: &[Vec<String>]) -> Vec<String> {
    tags.iter()
        .filter(|t| t.first().map(String::as_str) == Some("imeta"))
        .filter_map(|t| {
            t.iter()
                .find_map(|field| field.strip_prefix("ciphertext_sha256 "))
        })
        .map(str::to_string)
        .collect()
}

/// Total size on disk of the sealed cache entries, in bytes. Walks the cache
/// dir (flat — no subdirs) and sums file lengths. Best-effort: an unreadable
/// dir or entry just contributes nothing. Does IO, so call it off the UI thread.
pub fn size_bytes() -> u64 {
    let Ok(entries) = std::fs::read_dir(cache_dir()) else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}
