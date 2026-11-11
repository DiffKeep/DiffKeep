//! Icons the `icons` package ships broken, vendored as correct TVGs.
//!
//! The package's whole heroicons/solid set was converted as outline strokes
//! (`draw_line_path`) instead of fills, so a "solid" icon renders as a thin
//! hollow outline that looks jagged at small sizes. Its entypo (fills) and
//! lucide (strokes by design) sets are fine. Files here are the package's own
//! heroicons/solid SVGs re-converted with `dvui.svgToTvg`.

/// heroicons solid star — the favourite marker.
pub const star = @embedFile("icons/star.tvg");
