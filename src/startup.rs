use std::fs;
use std::path::{Path, PathBuf};

const AUTOSTART_FILE: &str = "whitenoise-linux.desktop";
const AUTOSTART_DESKTOP_ENTRY: &str = include_str!("../assets/whitenoise-linux.desktop");
const AUTOSTART_MARKER: &str = "X-WhitenoiseLinux-Autostart=true";

pub(crate) fn set_launch_at_login(enabled: bool) -> std::io::Result<()> {
    let Some(path) = autostart_path() else {
        return Ok(());
    };
    if enabled {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, AUTOSTART_DESKTOP_ENTRY)
    } else {
        remove_autostart_file(&path)
    }
}

fn autostart_path() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|d| d.config_dir().join("autostart").join(AUTOSTART_FILE))
}

fn remove_autostart_file(path: &Path) -> std::io::Result<()> {
    match fs::read_to_string(path) {
        Ok(contents) if contents.contains(AUTOSTART_MARKER) => fs::remove_file(path),
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn autostart_entry_is_the_checked_in_desktop_file_and_marks_ownership() {
        assert!(AUTOSTART_DESKTOP_ENTRY.starts_with("[Desktop Entry]\n"));
        assert!(AUTOSTART_DESKTOP_ENTRY.contains("Name=White Noise\n"));
        assert!(AUTOSTART_DESKTOP_ENTRY.contains("Exec=whitenoise-linux %u\n"));
        assert!(AUTOSTART_DESKTOP_ENTRY.contains("X-GNOME-Autostart-enabled=true\n"));
        assert!(AUTOSTART_DESKTOP_ENTRY.contains("X-WhitenoiseLinux-Autostart=true\n"));
    }
}
