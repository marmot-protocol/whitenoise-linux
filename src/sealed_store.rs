// Shared "one encrypted blob per file" building block, used by the encrypted
// media cache (`media_cache.rs`) and the durable offline send queue
// (`offline_queue.rs`). Both seal entries under the vault's media-cache
// subkey (`Vault::seal_blob`) and write them with the same
// create-dir/temp-write/rename/chmod choreography; this module holds that
// choreography once. Callers keep only their own policy: which directory an
// entry lives in and how a key maps to a filename.

use std::path::Path;
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
    if let Some(dir) = path.parent() {
        create_dir_all_owner_only(dir).map_err(PutError::Io)?;
    }
    let tmp = path.with_extension("bin.tmp");
    write_owner_only(&tmp, &sealed).map_err(PutError::Io)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(PutError::Io(e));
    }
    owner_only_file(path);
    Ok(())
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
