//! QR-code rasterization for profile deep links.
//!
//! Kept separate from the chat-model row builders: its only tie to the rest of
//! the app is that it produces a `slint::Image`, which the QR modals consume.

/// Rasterize `text` into a QR code image. Black modules on an opaque white
/// field with a 4-module quiet zone baked in, so the code scans regardless of
/// the app theme behind it. Rendered at 3px/module so the native size stays
/// below the on-screen size — `image-rendering: pixelated` then only ever
/// upscales, which can't thin or drop module rows the way a nearest-neighbor
/// downscale can. Must run on the UI thread (`slint::Image` is `!Send`).
pub(crate) fn qr_image(text: &str) -> slint::Image {
    let Ok(code) = qrcode::QrCode::new(text.as_bytes()) else {
        return slint::Image::default();
    };
    const QUIET: usize = 4;
    const SCALE: usize = 3;
    let n = code.width();
    let side = (n + 2 * QUIET) * SCALE;
    let mut buf = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::new(side as u32, side as u32);
    let px = buf.make_mut_slice();
    px.fill(slint::Rgba8Pixel {
        r: 255,
        g: 255,
        b: 255,
        a: 255,
    });
    let modules = code.to_colors();
    for y in 0..n {
        for x in 0..n {
            if modules[y * n + x] != qrcode::Color::Dark {
                continue;
            }
            let (x0, y0) = ((QUIET + x) * SCALE, (QUIET + y) * SCALE);
            for row in y0..y0 + SCALE {
                px[row * side + x0..row * side + x0 + SCALE].fill(slint::Rgba8Pixel {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 255,
                });
            }
        }
    }
    slint::Image::from_rgba8(buf)
}
