// Shared "one encrypted blob per file" building block, used by the encrypted
// media cache (`media_cache.rs`) and the durable offline send queue
// (`offline_queue.rs`). Both seal entries under the vault's media-cache
// subkey (`Vault::seal_blob`) and write them with the same
// create-dir/temp-write/rename/chmod choreography; this module holds that
// choreography once. Callers keep only their own policy: which directory an
// entry lives in and how a key maps to a filename.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::fsperm::{create_dir_all_owner_only, owner_only_file, write_owner_only};
use crate::vault::{Vault, VaultError};

#[derive(Debug)]
pub enum PutError {
    VaultLocked,
    Seal(VaultError),
    Io(std::io::Error),
}

impl std::fmt::Display for PutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PutError::VaultLocked => write!(f, "vault lock poisoned"),
            PutError::Seal(e) => write!(f, "seal: {e}"),
            PutError::Io(e) => write!(f, "io: {e}"),
        }
    }
}

/// Seal `plaintext` under the vault key and durably write it to `path`,
/// creating its parent directory if needed. Temp-then-rename so a crash
/// mid-write can't leave a truncated entry that would fail the auth tag (and
/// waste a re-fetch or re-encode) on every read after.
pub fn put(vault: &Arc<Mutex<Vault>>, path: &Path, plaintext: &[u8]) -> Result<(), PutError> {
    let sealed = {
        let v = vault.lock().map_err(|_| PutError::VaultLocked)?;
        v.seal_blob(plaintext).map_err(PutError::Seal)?
    };
    write_sealed(path, &sealed)
}

fn write_sealed(path: &Path, sealed: &[u8]) -> Result<(), PutError> {
    if let Some(dir) = path.parent() {
        create_dir_all_owner_only(dir).map_err(PutError::Io)?;
    }
    let tmp = path.with_extension("bin.tmp");
    write_owner_only(&tmp, sealed).map_err(PutError::Io)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(PutError::Io(e));
    }
    owner_only_file(path);
    Ok(())
}

/// Decrypt every `.bin` in `dir` under the vault's current media-cache subkey.
/// Used by [`Vault::change_password`] so it can re-seal the same plains after
/// rotating the key. Unreadable files are skipped (not evicted) so a failed
/// password change doesn't throw away cache/queue entries.
pub(crate) fn load_plains(vault: &Vault, dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("bin") {
            continue;
        }
        let Ok(sealed) = std::fs::read(&path) else {
            continue;
        };
        if let Ok(plain) = vault.open_blob(&sealed) {
            out.push((path, plain));
        }
    }
    out
}

/// Re-seal previously loaded plains under the vault's *current* key. Best-effort:
/// a single file failure is logged and the rest still rewrite, matching the
/// rest of this store.
pub(crate) fn rewrite_plains(vault: &Vault, plains: &[(PathBuf, Vec<u8>)]) {
    for (path, plain) in plains {
        match vault.seal_blob(plain) {
            Ok(sealed) => {
                if let Err(e) = write_sealed(path, &sealed) {
                    tracing::warn!(target: "sealed_store", "rewrite {path:?}: {e}");
                }
            }
            Err(e) => {
                tracing::warn!(target: "sealed_store", "re-seal {path:?}: {e}");
            }
        }
    }
}

/// Read and open a previously sealed entry at `path`. Returns `None` on a
/// plain miss (absent, unreadable, or the vault lock is poisoned) — nothing
/// to log there. On an auth-tag failure (corruption, or an entry sealed
/// under a previous vault password) the entry is evicted so a fresh `put`
/// can repopulate it, and the error comes back so the caller can log it with
/// its own id/target.
pub fn get(vault: &Arc<Mutex<Vault>>, path: &Path) -> Option<Result<Vec<u8>, VaultError>> {
    let sealed = std::fs::read(path).ok()?;
    let v = vault.lock().ok()?;
    match v.open_blob(&sealed) {
        Ok(plain) => Some(Ok(plain)),
        Err(e) => {
            let _ = std::fs::remove_file(path);
            Some(Err(e))
        }
    }
}
