//! System-clipboard stack: copy/paste with the platform CLI ladder
//! (`wl-copy`/`wl-paste` on Wayland, `xclip`/`xsel` on X11, `pbcopy` on
//! macOS) and arboard as the final fallback. Self-contained: no crate
//! prelude needed. Everything here can block on the display server, so
//! UI callbacks must go through [`copy_to_clipboard_async`] or a worker
//! thread.

/// Run [`copy_to_clipboard`] on a throwaway worker thread and hand the result
/// back on the UI thread. The CLI helpers and arboard can all wait on the
/// display server (wedged compositor, full pipe buffer, slow X11 connect), so
/// the UI thread must never call [`copy_to_clipboard`] directly.
pub(crate) fn copy_to_clipboard_async(
    text: String,
    on_done: impl FnOnce(Result<(), String>) + Send + 'static,
) {
    std::thread::spawn(move || {
        let result = copy_to_clipboard(&text);
        let _ = slint::invoke_from_event_loop(move || on_done(result));
    });
}

/// Push `text` to the system clipboard. Blocking — see
/// [`copy_to_clipboard_async`] for the only form UI callbacks may use.
///
/// On Linux/FreeBSD, arboard's Wayland support is finicky — it depends on
/// the compositor exposing the right data-control protocol, and on some
/// stacks `set_text` returns `Ok` without anyone actually getting the
/// content. Instead, we prefer the standard CLI tools that ship in every
/// desktop install: `wl-copy` for Wayland, `xclip`/`xsel` for X11. On macOS
/// the native `pbcopy` helper is always present (and the Wayland/X11 tools
/// would talk to an XQuartz clipboard, not the system one, so they are
/// skipped entirely). arboard stays as a final fallback everywhere.
pub(crate) fn copy_to_clipboard(text: &str) -> Result<(), String> {
    let preview: String = text.chars().take(24).collect();
    tracing::debug!(
        target: "clipboard", "copy len={} preview={:?}{} WAYLAND_DISPLAY={:?} DISPLAY={:?}",
        text.len(),
        preview,
        if text.len() > 24 { "…" } else { "" },
        std::env::var_os("WAYLAND_DISPLAY"),
        std::env::var_os("DISPLAY"),
    );

    #[cfg(target_os = "macos")]
    {
        match copy_via_command("pbcopy", &[], text) {
            Ok(()) => {
                tracing::debug!(target: "clipboard", "via pbcopy ok");
                return Ok(());
            }
            Err(e) => tracing::warn!(target: "clipboard", "pbcopy failed: {e}"),
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        // Wayland session?
        if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            match copy_via_command("wl-copy", &[], text) {
                Ok(()) => {
                    tracing::debug!(target: "clipboard", "via wl-copy ok");
                    return Ok(());
                }
                Err(e) => tracing::warn!(target: "clipboard", "wl-copy failed: {e}"),
            }
        }

        // X11 session?
        if std::env::var_os("DISPLAY").is_some() {
            for (cmd, args) in [
                ("xclip", &["-selection", "clipboard"][..]),
                ("xsel", &["--clipboard", "--input"][..]),
            ] {
                match copy_via_command(cmd, args, text) {
                    Ok(()) => {
                        tracing::debug!(target: "clipboard", "via {cmd} ok");
                        return Ok(());
                    }
                    Err(e) => tracing::warn!(target: "clipboard", "{cmd} failed: {e}"),
                }
            }
        }
    }

    // Last resort: arboard. Hold a single long-lived Clipboard so we don't
    // immediately drop ownership.
    use std::sync::{Mutex, OnceLock};
    static CLIPBOARD: OnceLock<Mutex<arboard::Clipboard>> = OnceLock::new();
    let cb = CLIPBOARD.get_or_init(|| {
        Mutex::new(arboard::Clipboard::new().expect("clipboard backend init failed"))
    });
    let mut guard = cb.lock().map_err(|e| e.to_string())?;
    match guard.set_text(text.to_string()) {
        Ok(()) => {
            tracing::debug!(target: "clipboard", "via arboard ok");
            Ok(())
        }
        Err(e) => {
            tracing::warn!(target: "clipboard", "arboard failed: {e}");
            Err(e.to_string())
        }
    }
}

/// Spawn a CLI clipboard helper, pipe `text` into its stdin, wait for the
/// parent to exit (these helpers fork themselves into the background after
/// reading stdin, so the parent exits in milliseconds), and surface the
/// exit code if anything went wrong.
///
/// stdout/stderr must NOT be `Stdio::piped()`: the forked background child
/// that keeps serving the clipboard inherits the pipe write ends, so reading
/// them to EOF (e.g. `wait_with_output`) blocks until clipboard ownership is
/// lost — which freezes the UI thread. stderr is inherited instead, so any
/// helper diagnostics still land in our own stderr log.
pub(crate) fn copy_via_command(cmd: &str, args: &[&str], text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    tracing::debug!(target: "clipboard", "spawning: {cmd} {args:?}");
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("spawn: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| format!("write stdin: {e}"))?;
        // dropping stdin closes the pipe so the helper sees EOF
    }
    let status = child.wait().map_err(|e| format!("wait: {e}"))?;
    if !status.success() {
        return Err(format!("{cmd} exited {status} (stderr passed through)"));
    }
    Ok(())
}

/// Choose an image MIME target from a clipboard target list, applying the
/// image-intent rule: any plain-text target wins (returns `None` — the
/// native text paste already handled it, and sources that offer *both*
/// mean text), otherwise `image/png` is preferred over whatever other
/// `image/*` target comes first.
pub(crate) fn pick_image_target(types: &[&str]) -> Option<String> {
    let has_text = types
        .iter()
        .any(|t| *t == "UTF8_STRING" || *t == "STRING" || t.starts_with("text/plain"));
    if has_text {
        return None;
    }
    if types.contains(&"image/png") {
        return Some("image/png".to_string());
    }
    types
        .iter()
        .find(|t| t.starts_with("image/"))
        .map(|t| t.to_string())
}

/// Read image bytes off the system clipboard, but only when the clipboard
/// looks image-intent (see [`pick_image_target`]). Mirrors
/// [`copy_to_clipboard`]'s platform ladder: `wl-paste` on Wayland,
/// `xclip` on X11, arboard as the fallback everywhere and the primary
/// path on macOS (`pbpaste` is text-only). Blocking — subprocess /
/// display-server round-trips — so never call on the UI thread. Returns
/// `(bytes, media_type)`.
pub(crate) fn paste_image_from_clipboard() -> Option<(Vec<u8>, String)> {
    #[cfg(not(target_os = "macos"))]
    {
        if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            match paste_via_command("wl-paste", &["--list-types"]) {
                Ok(out) => {
                    let listing = String::from_utf8_lossy(&out).into_owned();
                    let types: Vec<&str> = listing.lines().map(str::trim).collect();
                    // wl-paste answered: it owns the truth about this
                    // clipboard, so no image target (or text intent) is a
                    // final no — don't fall through to arboard.
                    let mime = pick_image_target(&types)?;
                    return match paste_via_command("wl-paste", &["--no-newline", "--type", &mime]) {
                        Ok(bytes) if !bytes.is_empty() => {
                            tracing::debug!(
                                target: "clipboard", "image via wl-paste ({mime}, {} bytes)",
                                bytes.len()
                            );
                            Some((bytes, mime))
                        }
                        Ok(_) => None,
                        Err(e) => {
                            tracing::warn!(target: "clipboard", "wl-paste read failed: {e}");
                            None
                        }
                    };
                }
                Err(e) => tracing::warn!(target: "clipboard", "wl-paste list-types failed: {e}"),
            }
        }
        if std::env::var_os("DISPLAY").is_some() {
            match paste_via_command("xclip", &["-selection", "clipboard", "-t", "TARGETS", "-o"]) {
                Ok(out) => {
                    let listing = String::from_utf8_lossy(&out).into_owned();
                    let types: Vec<&str> = listing.lines().map(str::trim).collect();
                    let mime = pick_image_target(&types)?;
                    return match paste_via_command(
                        "xclip",
                        &["-selection", "clipboard", "-t", &mime, "-o"],
                    ) {
                        Ok(bytes) if !bytes.is_empty() => {
                            tracing::debug!(
                                target: "clipboard", "image via xclip ({mime}, {} bytes)",
                                bytes.len()
                            );
                            Some((bytes, mime))
                        }
                        Ok(_) => None,
                        Err(e) => {
                            tracing::warn!(target: "clipboard", "xclip read failed: {e}");
                            None
                        }
                    };
                }
                Err(e) => tracing::warn!(target: "clipboard", "xclip targets failed: {e}"),
            }
        }
    }

    // arboard fallback. It hands back raw RGBA, so re-encode as PNG for the
    // upload path (which wants original compressed bytes).
    let mut cb = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(target: "clipboard", "arboard init failed: {e}");
            return None;
        }
    };
    if matches!(cb.get_text(), Ok(t) if !t.is_empty()) {
        return None; // text intent — native paste already handled it
    }
    let img = cb.get_image().ok()?;
    let (w, h) = (img.width as u32, img.height as u32);
    let rgba = image::RgbaImage::from_raw(w, h, img.bytes.into_owned())?;
    let mut png = Vec::new();
    if let Err(e) = image::DynamicImage::ImageRgba8(rgba)
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
    {
        tracing::warn!(target: "clipboard", "png encode failed: {e}");
        return None;
    }
    tracing::debug!(target: "clipboard", "image via arboard ({w}x{h})");
    Some((png, "image/png".to_string()))
}

/// Run a CLI clipboard *reader* and capture its stdout bytes. Unlike the
/// copy helpers these don't fork into the background, so a plain
/// `output()` is safe.
pub(crate) fn paste_via_command(cmd: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    use std::process::{Command, Stdio};
    let out = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("spawn: {e}"))?;
    if !out.status.success() {
        return Err(format!("{cmd} exited {}", out.status));
    }
    Ok(out.stdout)
}
