// Single-instance guard: an exclusive advisory flock on `$WN_HOME/instance.lock`.
//
// Two processes sharing one data dir lose chats: every vault mutation re-seals
// the whole secret map over `vault.db` (last-writer-wins, so one instance
// silently drops `account:*` secrets the other added), and two processes
// advancing the same MLS group ratchet fork its state irrecoverably. The lock
// is advisory and kernel-owned — released automatically when the process
// exits, so a crash never leaves a stale lock behind.

use std::fs::{File, OpenOptions};
use std::path::Path;

/// Try to become the single instance for the data dir at `home`.
///
/// Returns the held lock — keep it alive for the whole process — or `None`
/// when another live process already holds it. IO errors (unwritable dir,
/// filesystem without flock support) propagate so the caller can decide to
/// fail open.
pub(crate) fn acquire(home: &Path) -> std::io::Result<Option<File>> {
    std::fs::create_dir_all(home)?;
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(home.join("instance.lock"))?;
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            let err = std::io::Error::last_os_error();
            return if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
                Ok(None)
            } else {
                Err(err)
            };
        }
    }
    Ok(Some(file))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_acquire_in_child_process_is_refused() {
        let dir = std::env::temp_dir().join(format!("wn-instance-lock-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let held = acquire(&dir).unwrap();
        assert!(held.is_some(), "first acquire must succeed");

        // flock is per-open-file-description, so a same-process re-acquire
        // wouldn't conflict; probe from a child process like a real second
        // instance would.
        let probe = std::process::Command::new("flock")
            .arg("--nonblock")
            .arg("--exclusive")
            .arg(dir.join("instance.lock"))
            .arg("true")
            .status();
        if let Ok(status) = probe {
            assert!(!status.success(), "child must fail to take the held lock");
        }

        drop(held);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
