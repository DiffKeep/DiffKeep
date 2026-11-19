//! DiffKeep's own icon, and icons the `icons` package ships broken, vendored
//! as correct TVGs.
//!
//! The package's whole heroicons/solid set was converted as outline strokes
//! (`draw_line_path`) instead of fills, so a "solid" icon renders as a thin
//! hollow outline that looks jagged at small sizes. Its entypo (fills) and
//! lucide (strokes by design) sets are fine. Files here are the package's own
//! heroicons/solid SVGs re-converted with `dvui.svgToTvg`.

/// The app icon (256 px PNG, from the DiffKeep logo), set on every window.
/// The Windows executable carries the same artwork in `icons/diffkeep.ico`
/// (through `icons/diffkeep.rc`).
pub const app_png = @embedFile("icons/diffkeep.png");

/// heroicons solid star — the favourite marker.
pub const star = @embedFile("icons/star.tvg");
