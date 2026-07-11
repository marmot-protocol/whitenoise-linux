// User-defined themes loaded from disk.
//
// A user drops a TOML file at `$DM_HOME/themes/<mode>.toml`. Each file names a
// `base` built-in theme and overrides only the fields it cares about, so a
// whole theme can be a few lines and still render coherently: everything left
// unspecified inherits the base pack. At startup [`load_user_themes`] scans the
// directory, reads the base `ThemeColors`/`ThemeStyle` straight from the
// compiled Slint registry, overlays the file, and pushes the result back into
// `Theme.user-color-packs` / `Theme.user-style-packs` (plus the picker's
// name/mode lists). Ids at and beyond the built-in count select into those,
// so a user theme is a first-class pick with no rebuild.
//
// Defensive by construction, matching how `settings.rs` swallows bad input: a
// file that fails to read, parse, or that collides with an existing mode is
// logged and skipped, never blocking the others.

// Color, Model, ModelRc, SharedString, VecModel, Rc, and the generated Theme /
// ThemeColors / ThemeStyle / DarkMatterLinux types all come from the crate
// prelude re-exports in main.rs.
use crate::*;

/// The directory scanned for user theme files: `$DM_HOME/themes/`.
fn themes_dir() -> std::path::PathBuf {
    crate::backend::default_home().join("themes")
}

/// One theme file. `name`/`base` are top-level; the overrides live under
/// `[colors]` and `[style]`. Unknown keys are ignored so a typo drops one
/// field rather than the whole theme.
#[derive(serde::Deserialize)]
struct ThemeFile {
    name: Option<String>,
    base: Option<String>,
    #[serde(default)]
    colors: ColorOverlay,
    #[serde(default)]
    style: StyleOverlay,
}

/// Every `ThemeColors` field as an optional override. Field names map to the
/// TOML keys as kebab-case (`bubble_in` reads `bubble-in`), matching the Slint
/// struct. Colors are hex strings (`#rrggbb` or `#rrggbbaa`); the five accent
/// tables are lists of five hex strings, one per accent.
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "kebab-case", default)]
struct ColorOverlay {
    bg: Option<String>,
    panel: Option<String>,
    panel_2: Option<String>,
    rail: Option<String>,
    banner: Option<String>,
    border: Option<String>,
    border_2: Option<String>,
    bubble_in: Option<String>,
    bubble_inset: Option<String>,
    bubble_inset_strong: Option<String>,
    code_plate: Option<String>,
    media_backdrop: Option<String>,
    bubble_inset_out: Option<String>,
    bubble_inset_out_strong: Option<String>,
    code_plate_out: Option<String>,
    media_backdrop_out: Option<String>,
    bubble_selection_out: Option<String>,
    text_hi: Option<String>,
    text_mid: Option<String>,
    text_lo: Option<String>,
    text_vlo: Option<String>,
    hover: Option<String>,
    bubble_out_fg: Option<String>,
    bevel_hi: Option<String>,
    bevel_lo: Option<String>,
    danger: Option<String>,
    danger_soft: Option<String>,
    danger_border: Option<String>,
    danger_soft_hover: Option<String>,
    danger_border_hover: Option<String>,
    warning: Option<String>,
    warning_soft: Option<String>,
    warning_border: Option<String>,
    field: Option<String>,
    field_hover: Option<String>,
    field_border: Option<String>,
    field_border_hover: Option<String>,
    divider: Option<String>,
    elevated: Option<String>,
    elevated_border: Option<String>,
    top_glint: Option<String>,
    canvas_top: Option<String>,
    banner_edge: Option<String>,
    card_border: Option<String>,
    status_bar: Option<String>,
    card_well: Option<String>,
    overlay: Option<String>,
    shadow_soft: Option<String>,
    shadow_card: Option<String>,
    shadow_popover: Option<String>,
    shadow_float: Option<String>,
    shadow_bubble_in: Option<String>,
    vignette: Option<String>,
    avatar_ring: Option<String>,
    selected_uses_base: Option<bool>,
    accent_base: Option<Vec<String>>,
    accent_hi: Option<Vec<String>>,
    accent_dim: Option<Vec<String>>,
    accent_glow: Option<Vec<String>>,
    accent_surface: Option<Vec<String>>,
}

/// Every `ThemeStyle` field as an optional override (capability flags plus the
/// per-family skin selectors). Unset fields inherit the base pack.
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "kebab-case", default)]
struct StyleOverlay {
    hard_shadow: Option<bool>,
    focus_glow: Option<bool>,
    char_wrap: Option<bool>,
    motion_fast: Option<bool>,
    bubble_bounce: Option<bool>,
    bevel: Option<bool>,
    pixel_icons: Option<bool>,
    selected_inverts_text: Option<bool>,
    pixel_select_marker: Option<bool>,
    pixel_metrics: Option<bool>,
    outline_surfaces: Option<bool>,
    soft_decor: Option<bool>,
    skin_message: Option<i32>,
    skin_button: Option<i32>,
    skin_list: Option<i32>,
    skin_avatar: Option<i32>,
    skin_modal: Option<i32>,
    shell: Option<i32>,
    bracket_labels: Option<bool>,
    paper_doodles: Option<bool>,
    sketch_bubbles: Option<bool>,
    synth_grid: Option<bool>,
}

/// Parse `#rgb`, `#rrggbb`, or `#rrggbbaa` into a Slint color. Returns None on
/// anything else so the caller keeps the base pack's value for that field.
fn parse_color(s: &str) -> Option<Color> {
    let h = s.trim().trim_start_matches('#');
    let hx = |sl: &str| u8::from_str_radix(sl, 16).ok();
    let (r, g, b, a) = match h.len() {
        3 => {
            let d = |c: &str| hx(c).map(|v| v * 17);
            (d(&h[0..1])?, d(&h[1..2])?, d(&h[2..3])?, 255)
        }
        6 => (hx(&h[0..2])?, hx(&h[2..4])?, hx(&h[4..6])?, 255),
        8 => (hx(&h[0..2])?, hx(&h[2..4])?, hx(&h[4..6])?, hx(&h[6..8])?),
        _ => return None,
    };
    Some(Color::from_argb_u8(a, r, g, b))
}

/// An accent table must supply exactly five colors (one per accent) and all
/// must parse; otherwise the base pack's table is kept unchanged.
fn parse_accent_table(list: &[String]) -> Option<ModelRc<Color>> {
    if list.len() != 5 {
        return None;
    }
    let colors: Option<Vec<Color>> = list.iter().map(|s| parse_color(s)).collect();
    Some(ModelRc::from(Rc::new(VecModel::from(colors?))))
}

/// Set `$base.$field` from each overlay entry that parses. Scalar colors.
macro_rules! overlay_colors {
    ($base:ident, $ov:ident, $($f:ident),+ $(,)?) => {
        $( if let Some(ref s) = $ov.$f {
            if let Some(c) = parse_color(s) { $base.$f = c; }
        } )+
    };
}

/// Set `$base.$field` from each present overlay entry. Copy values (bool/int).
macro_rules! overlay_values {
    ($base:ident, $ov:ident, $($f:ident),+ $(,)?) => {
        $( if let Some(v) = $ov.$f { $base.$f = v; } )+
    };
}

/// Replace `$base.$field` (an accent `[color]` table) from each overlay entry
/// that supplies a valid five-color list; otherwise the base table is kept.
macro_rules! overlay_accents {
    ($base:ident, $ov:ident, $($f:ident),+ $(,)?) => {
        $( if let Some(ref l) = $ov.$f {
            if let Some(m) = parse_accent_table(l) { $base.$f = m; }
        } )+
    };
}

fn apply_colors(base: &mut ThemeColors, ov: &ColorOverlay) {
    overlay_colors!(
        base,
        ov,
        bg,
        panel,
        panel_2,
        rail,
        banner,
        border,
        border_2,
        bubble_in,
        bubble_inset,
        bubble_inset_strong,
        code_plate,
        media_backdrop,
        bubble_inset_out,
        bubble_inset_out_strong,
        code_plate_out,
        media_backdrop_out,
        bubble_selection_out,
        text_hi,
        text_mid,
        text_lo,
        text_vlo,
        hover,
        bubble_out_fg,
        bevel_hi,
        bevel_lo,
        danger,
        danger_soft,
        danger_border,
        danger_soft_hover,
        danger_border_hover,
        warning,
        warning_soft,
        warning_border,
        field,
        field_hover,
        field_border,
        field_border_hover,
        divider,
        elevated,
        elevated_border,
        top_glint,
        canvas_top,
        banner_edge,
        card_border,
        status_bar,
        card_well,
        overlay,
        shadow_soft,
        shadow_card,
        shadow_popover,
        shadow_float,
        shadow_bubble_in,
        vignette,
        avatar_ring,
    );
    overlay_values!(base, ov, selected_uses_base);
    overlay_accents!(
        base,
        ov,
        accent_base,
        accent_hi,
        accent_dim,
        accent_glow,
        accent_surface,
    );
}

fn apply_style(base: &mut ThemeStyle, ov: &StyleOverlay) {
    overlay_values!(
        base,
        ov,
        hard_shadow,
        focus_glow,
        char_wrap,
        motion_fast,
        bubble_bounce,
        bevel,
        pixel_icons,
        selected_inverts_text,
        pixel_select_marker,
        pixel_metrics,
        outline_surfaces,
        soft_decor,
        skin_message,
        skin_button,
        skin_list,
        skin_avatar,
        skin_modal,
        shell,
        bracket_labels,
        paper_doodles,
        sketch_bubbles,
        synth_grid,
    );
}

/// Scan `$DM_HOME/themes/`, build the user packs, push them into the `Theme`
/// global, and return the loaded modes' stable names in id order (empty when
/// the directory is missing or holds no valid theme). The returned names extend
/// the built-in `THEME_MODES` registry in [`crate::state`].
pub(crate) fn load_user_themes(ui: &DarkMatterLinux) -> Vec<String> {
    let dir = themes_dir();
    let mut entries: Vec<std::path::PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("toml"))
            .collect(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => {
            tracing::warn!(target: "themes", "cannot read {} ({e})", dir.display());
            return Vec::new();
        }
    };
    // Stable order so ids stay put across restarts (a persisted user theme
    // keeps its id as long as the same files are present).
    entries.sort();

    let theme = ui.global::<Theme>();
    let base_packs = theme.get_color_packs();
    let base_styles = theme.get_style_packs();
    let builtin_count = base_packs.row_count();

    let mut colors: Vec<ThemeColors> = Vec::new();
    let mut styles: Vec<ThemeStyle> = Vec::new();
    let mut names: Vec<SharedString> = Vec::new();
    let mut modes: Vec<String> = Vec::new();

    for path in &entries {
        let Some(mode) = path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(str::to_string)
        else {
            continue;
        };
        if crate::state::THEME_MODES.contains(&mode.as_str()) || modes.contains(&mode) {
            tracing::warn!(target: "themes", "skipping {}: mode name '{mode}' already in use", path.display());
            continue;
        }
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!(target: "themes", "cannot read {} ({e}); skipped", path.display());
                continue;
            }
        };
        let file: ThemeFile = match toml::from_str(&text) {
            Ok(f) => f,
            Err(e) => {
                tracing::warn!(target: "themes", "{} is invalid ({e}); skipped", path.display());
                continue;
            }
        };

        let base_id = file
            .base
            .as_deref()
            .map(crate::state::theme_mode_idx)
            .filter(|id| (0..builtin_count as i32).contains(id))
            .unwrap_or(0) as usize;
        let (Some(mut c), Some(mut s)) =
            (base_packs.row_data(base_id), base_styles.row_data(base_id))
        else {
            continue;
        };
        apply_colors(&mut c, &file.colors);
        apply_style(&mut s, &file.style);

        let display = file
            .name
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| mode.clone());
        colors.push(c);
        styles.push(s);
        names.push(display.into());
        modes.push(mode);
    }

    if !colors.is_empty() {
        tracing::info!(target: "themes", "loaded {} user theme(s) from {}", colors.len(), dir.display());
    }
    theme.set_user_color_packs(ModelRc::from(Rc::new(VecModel::from(colors))));
    theme.set_user_style_packs(ModelRc::from(Rc::new(VecModel::from(styles))));
    theme.set_user_theme_names(ModelRc::from(Rc::new(VecModel::from(names))));
    theme.set_user_theme_modes(ModelRc::from(Rc::new(VecModel::from(
        modes
            .iter()
            .map(|m| SharedString::from(m.as_str()))
            .collect::<Vec<_>>(),
    ))));
    modes
}
