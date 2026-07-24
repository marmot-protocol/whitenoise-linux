// Crate-wide file-permission helpers. Every consumer of at-rest encryption
// (`vault.rs`, `media_cache.rs`, `offline_queue.rs`, `backup.rs`) writes
// ciphertext that should still be unreadable to any other local user, so
// files land at mode 0600 and directories at 0700. This module holds that
// policy once so a future hardening change (a different tmp-file strategy,
// an fsync) only has to land here.

use std::path::Path;

/// Chmod `path` to 0600 (Unix). No-op elsewhere.
#[cfg(unix)]
pub fn owner_only_file(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

#[cfg(not(unix))]
pub fn owner_only_file(_path: &Path) {}

/// Chmod `path` to 0700 (Unix). No-op elsewhere.
#[cfg(unix)]
pub fn owner_only_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
pub fn owner_only_dir(_path: &Path) {}

/// Write `bytes` to `path`, creating the file `0600` from the outset (Unix) so
/// there is no window where freshly written ciphertext (or, for a backup
/// restore, plaintext like `vault.db`) is world-readable. Also re-tightens
/// perms on an existing file being overwritten.
#[cfg(unix)]
pub fn write_owner_only(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(bytes)?;
    owner_only_file(path);
    Ok(())
}

#[cfg(not(unix))]
pub fn write_owner_only(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

/// `create_dir_all`, then unconditionally re-assert 0700 (Unix) so a
/// directory reused across calls stays tightened even if something else
/// loosened it in between.
pub fn create_dir_all_owner_only(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    owner_only_dir(path);
    Ok(())
}
