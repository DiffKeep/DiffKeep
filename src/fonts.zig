//! Bundled fonts + per-codepoint run splitting, shared by the app and the
//! headless test harness.
//!
//! dvui renders one face per text run (no per-glyph fallback), so any string
//! that leaves one face's coverage shows tofu. `addStyled` is the single place
//! that maps (codepoint, style) -> face: it splits text into same-face runs so
//! every glyph lands somewhere that has it. Use it (or `addRich`/`richLabel`)
//! for ANY text that can carry content we did not write — filenames, prompts,
//! model names, raw PNG metadata.
//!
//! Three tiers, resolved per codepoint:
//!
//!   1. IBM Plex Sans / Plex Mono — the design's face. Latin, Greek, Cyrillic,
//!      Vietnamese. ~900 codepoints, all BMP.
//!   2. Noto Sans CJK — everything else with a glyph: CJK, arrows, math, box
//!      drawing, the long tail.
//!   3. Noto Emoji — monochrome outlines, since dvui's rasterizer is
//!      monochrome and cannot use a color emoji font.
//!
//! Tier 1 membership is decided by parsing each Plex face's own `cmap` at
//! startup (`Coverage`), never by a hand-written codepoint range table: the
//! table drifts the moment a font is updated, and the failure is a tofu box in
//! a screenshot rather than an error.
//!
//! UI affordance marks (`▾ ▸ ✕`) are NOT text here. Plex has none of them, so
//! they are drawn as vector icons (see style.zig `mark`), which also keeps them
//! crisp at any scale.
//!
//! dvui's `Font.size` is the height of a capital M, not an em size. That gives
//! cross-face cap-height normalization for free: Plex and Noto CJK at the same
//! `size` have the same cap height, so a CJK run in a Latin line does not
//! change the line's optical size. See style.zig for the nominal-px conversion.

const std = @import("std");
const dvui = @import("dvui");

/// Sans tier 1. Regular / SemiBold / Italic / SemiBold Italic live under this
/// one family; dvui's `Weight` is binary (normal|bold), so 600 is registered as
/// this family's `.bold`.
pub const sans = "PlexSans";
/// Plex Sans Medium (500). A separate family for the same reason: dvui has no
/// third weight, and the design uses 500 for every UI label and button.
pub const sans_med = "PlexSansMed";
pub const mono = "PlexMono";
pub const mono_med = "PlexMonoMed";
/// Tier 2, the coverage backstop.
pub const cjk = "NotoSansCJK";
pub const cjk_bold_family = "NotoSansCJKBold";
pub const emoji_family = "NotoEmoji";

pub const plex_sans_regular = @embedFile("fonts/IBMPlexSans-Regular.ttf");
pub const plex_sans_medium = @embedFile("fonts/IBMPlexSans-Medium.ttf");
pub const plex_sans_semibold = @embedFile("fonts/IBMPlexSans-SemiBold.ttf");
pub const plex_sans_italic = @embedFile("fonts/IBMPlexSans-Italic.ttf");
pub const plex_sans_semibold_italic = @embedFile("fonts/IBMPlexSans-SemiBoldItalic.ttf");
pub const plex_mono_regular = @embedFile("fonts/IBMPlexMono-Regular.ttf");
pub const plex_mono_medium = @embedFile("fonts/IBMPlexMono-Medium.ttf");
pub const regular_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
pub const bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");
pub const emoji_bytes = @embedFile("fonts/NotoEmoji.ttf");

/// Registered via `Theme.embedded_fonts` (plain `dvui.addFont` can only
/// register normal weight/style). dvui dedups sources by bytes pointer, so one
/// file cannot alias two weights, which is why Medium gets its own family.
///
/// `NotoSansCJKBold` is a second family holding the same bytes as `NotoSansCJK`
/// at `.bold`, kept only because pre-existing call sites look that name up
/// directly; new code should ask for `sans` with `.weight = .bold`.
const sources = [_]dvui.Font.Source{
    .{ .family = dvui.Font.array(sans), .bytes = plex_sans_regular },
    .{ .family = dvui.Font.array(sans), .weight = .bold, .bytes = plex_sans_semibold },
    .{ .family = dvui.Font.array(sans), .style = .italic, .bytes = plex_sans_italic },
    .{ .family = dvui.Font.array(sans), .weight = .bold, .style = .italic, .bytes = plex_sans_semibold_italic },
    .{ .family = dvui.Font.array(sans_med), .bytes = plex_sans_medium },
    .{ .family = dvui.Font.array(mono), .bytes = plex_mono_regular },
    .{ .family = dvui.Font.array(mono_med), .bytes = plex_mono_medium },
    .{ .family = dvui.Font.array(cjk), .bytes = regular_bytes },
    .{ .family = dvui.Font.array(cjk), .weight = .bold, .bytes = bold_bytes },
    .{ .family = dvui.Font.array(cjk_bold_family), .bytes = bold_bytes },
    .{ .family = dvui.Font.array(emoji_family), .bytes = emoji_bytes },
};

// ---------------------------------------------------------------- coverage

/// A face's BMP coverage as a bitset. Plex is BMP-only (its `cmap` has a single
/// format-4 subtable and no codepoint above U+FFFD), so a BMP bitset is exact
/// for tier 1, and anything above U+FFFF goes to tier 2 or 3 without a lookup.
const Coverage = struct {
    words: [0x10000 / 64]u64 = @splat(0),

    fn mark(self: *Coverage, cp: u16) void {
        self.words[cp >> 6] |= @as(u64, 1) << @truncate(cp);
    }
    pub fn has(self: *const Coverage, cp: u21) bool {
        if (cp > 0xFFFF) return false;
        return self.words[cp >> 6] & (@as(u64, 1) << @truncate(cp)) != 0;
    }
    fn count(self: *const Coverage) usize {
        var n: usize = 0;
        for (self.words) |w| n += @popCount(w);
        return n;
    }
};

var cov_sans: Coverage = .{};
var cov_mono: Coverage = .{};
var cov_ready = false;

fn rdU16(b: []const u8, off: usize) u16 {
    if (off + 2 > b.len) return 0;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}
fn rdU32(b: []const u8, off: usize) u32 {
    if (off + 4 > b.len) return 0;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

/// Byte offset of an sfnt table, or null. Plain TTF/OTF only (the Plex faces);
/// the Noto collections are tier 2 and never need a coverage lookup.
fn tableOffset(ttf: []const u8, tag: *const [4]u8) ?usize {
    const n = rdU16(ttf, 4);
    for (0..n) |i| {
        const rec = 12 + 16 * i;
        if (rec + 16 > ttf.len) return null;
        if (std.mem.eql(u8, ttf[rec..][0..4], tag)) return rdU32(ttf, rec + 8);
    }
    return null;
}

/// Fill `out` from a face's Windows-BMP (platform 3, encoding 1) format-4
/// subtable. Codepoints that map to glyph 0 are NOT coverage: a font may map a
/// whole range and resolve most of it to .notdef, which renders as tofu just
/// like no mapping at all.
fn parseCoverage(ttf: []const u8, out: *Coverage) void {
    const cmap = tableOffset(ttf, "cmap") orelse return;
    const n_sub = rdU16(ttf, cmap + 2);
    var sub: ?usize = null;
    for (0..n_sub) |i| {
        const rec = cmap + 4 + 8 * i;
        const plat = rdU16(ttf, rec);
        const enc = rdU16(ttf, rec + 2);
        const off = cmap + rdU32(ttf, rec + 4);
        if (plat == 3 and enc == 1 and rdU16(ttf, off) == 4) sub = off;
    }
    const t = sub orelse return;

    const seg2 = rdU16(ttf, t + 6);
    const seg = seg2 / 2;
    const ends = t + 14;
    const starts = ends + seg2 + 2;
    const deltas = starts + seg2;
    const ranges = deltas + seg2;

    for (0..seg) |i| {
        const end = rdU16(ttf, ends + 2 * i);
        const start = rdU16(ttf, starts + 2 * i);
        if (start > end or start == 0xFFFF) continue;
        const delta = rdU16(ttf, deltas + 2 * i);
        const ro = rdU16(ttf, ranges + 2 * i);
        var cp: u32 = start;
        while (cp <= end) : (cp += 1) {
            const gid: u16 = if (ro == 0)
                @truncate(cp +% delta)
            else blk: {
                // The offset is from the range-offset slot itself, in glyph
                // ids, hence the doubled index arithmetic.
                const gi = ranges + 2 * i + ro + 2 * (cp - start);
                const g = rdU16(ttf, gi);
                break :blk if (g == 0) 0 else @truncate(g +% delta);
            };
            if (gid != 0) out.mark(@truncate(cp));
        }
    }
}

/// Build the tier-1 coverage index. Idempotent; `install` calls it, and the
/// tests call it directly so they do not need a dvui window.
pub fn buildCoverage() void {
    if (cov_ready) return;
    parseCoverage(plex_sans_regular, &cov_sans);
    parseCoverage(plex_mono_regular, &cov_mono);
    cov_ready = true;
}

// ------------------------------------------------------------ tier routing

/// How one role's runs escalate when tier 1 lacks a codepoint. `fallback_weight`
/// exists because Plex Medium has no Noto twin: a 500-weight run drops to Noto
/// Regular rather than jumping to Bold.
const Chain = struct {
    cover: *const Coverage,
    fallback: []const u8,
    fallback_weight: dvui.Font.Weight = .normal,
};

// Mono's tier 2 is the PROPORTIONAL CJK face, not a monospaced one. Noto's
// mono CJK is a 16 MB file on top of the 39 MB of CJK already bundled, and the
// mono roles here render figures, ids and units — nothing that lines up into
// columns across a CJK/Latin boundary. A proportional CJK run beats both a
// tofu row and a 40% larger binary.
const sans_chain: Chain = .{ .cover = &cov_sans, .fallback = cjk };
const sans_bold_chain: Chain = .{ .cover = &cov_sans, .fallback = cjk, .fallback_weight = .bold };
const mono_chain: Chain = .{ .cover = &cov_mono, .fallback = cjk };

fn chainFor(fam: []const u8, weight: dvui.Font.Weight) Chain {
    if (std.mem.eql(u8, fam, mono) or std.mem.eql(u8, fam, mono_med)) return mono_chain;
    return if (weight == .bold) sans_bold_chain else sans_chain;
}

/// Register the bundled fonts and build the tier-1 coverage index. Must run
/// inside a `Window.begin`/`end` pair; `themeSet` pulls `embedded_fonts` into
/// the window's font database.
///
/// Callers should prefer `style.install()`, which calls this and then installs
/// the palette-derived theme on top.
pub fn register() void {
    buildCoverage();
    var theme = dvui.themeGet();
    theme.embedded_fonts = &sources;
    dvui.themeSet(theme);
}

/// Inline text style. `addStyled` turns this plus per-codepoint coverage into a
/// concrete face per run.
pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
};

/// The bundled emoji font at the current body text size.
pub fn emojiFont() dvui.Font {
    return dvui.themeGet().font_body.withFamily(emoji_family);
}

/// Codepoints routed to the emoji face ahead of any coverage test, because the
/// text faces map some of them to flat, wrong-looking glyphs. Kept to clearly
/// pictographic blocks; arrows and punctuation stay on the text tiers.
fn isEmoji(cp: u21) bool {
    return switch (cp) {
        0x1F000...0x1FAFF => true, // emoji + pictographs (incl. flags, skin tones)
        0x23E9...0x23FA => true, // media controls (⏸ ⏯ ⏹ ...), no text face has these
        0x2600...0x27BF => true, // misc symbols + dingbats (⚙ ✅ ...)
        0x2B00...0x2BFF => true, // misc symbols & arrows (emoji-presentation)
        0xFE00...0xFE0F => true, // variation selectors, keep with the emoji run
        0x200D => true, // ZWJ, keep emoji sequences together
        else => false,
    };
}

/// Resolve the face for one codepoint under `style`, deriving size (and any
/// strike the caller set) from `base`. Public so the tests can assert the
/// routing without going through a text layout.
pub fn fontFor(cp: u21, style: Style, base: dvui.Font) dvui.Font {
    var f = base;
    if (style.strike) f = f.withStrike(.{});
    if (isEmoji(cp)) return f.withFamily(emoji_family);

    if (style.code) {
        const fam: []const u8 = if (std.mem.eql(u8, base.familyName(), mono_med)) mono_med else mono;
        const c = chainFor(fam, .normal);
        if (c.cover.has(cp)) return f.withFamily(fam).withWeight(.normal);
        return f.withFamily(c.fallback).withWeight(.normal);
    }

    const bold = style.bold or base.weight == .bold;
    const fam = base.familyName();
    // Medium (500) is its own family, and only in the upright roman: a bold or
    // italic run inside 500-weight text resolves to the regular family's own
    // SemiBold / Italic face rather than a face that does not exist.
    const primary: []const u8 = if (std.mem.eql(u8, fam, sans_med) and !bold and !style.italic)
        sans_med
    else if (std.mem.eql(u8, fam, mono) or std.mem.eql(u8, fam, mono_med))
        fam
    else
        sans;

    const c = chainFor(primary, if (bold) .bold else .normal);
    if (c.cover.has(cp)) {
        var r = f.withFamily(primary);
        if (!std.mem.eql(u8, primary, sans_med)) r = r.withWeight(if (bold) .bold else .normal);
        return if (style.italic) r.withStyle(.italic) else r;
    }
    // Tier 2. Italic is dropped rather than faked: Noto CJK ships no italic,
    // and CJK is conventionally emphasized without one.
    return f.withFamily(c.fallback).withWeight(c.fallback_weight);
}

/// Add `text` to a text layout, split into same-face runs. `opts` applies to
/// every run (colors, background for inline code, ...); `opts.font` (or the
/// theme body font) sets the base size and role.
pub fn addStyled(tl: *dvui.TextLayoutWidget, text: []const u8, style: Style, opts: dvui.Options) void {
    const base = opts.font orelse dvui.themeGet().font_body;
    var start: usize = 0;
    var i: usize = 0;
    var cur: dvui.Font = undefined;
    var have = false;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp: u21 = if (n > 1 and i + n <= text.len)
            (std.unicode.utf8Decode(text[i..][0..n]) catch 0xFFFD)
        else
            text[i];
        const f = fontFor(cp, style, base);
        if (!have) {
            cur = f;
            have = true;
        } else if (!std.meta.eql(f, cur)) {
            var o = opts;
            o.font = cur;
            tl.addText(text[start..i], o);
            start = i;
            cur = f;
        }
        i += n;
    }
    if (start < text.len) {
        var o = opts;
        o.font = cur;
        tl.addText(text[start..], o);
    }
}

/// Plain-styled `addStyled`, for the common "show this string with full
/// coverage" case.
pub fn addRich(tl: *dvui.TextLayoutWidget, text: []const u8) void {
    addStyled(tl, text, .{}, .{});
}

/// Whether `text` needs more than one face — i.e. whether any codepoint leaves
/// the base font. Almost every string in this app is ASCII, and a plain label
/// is far cheaper than a text layout, so `richLine` and `richLabel` check this
/// first: it turns the fallback machinery into something a grid can afford to
/// call once per visible cell.
fn needsSplit(text: []const u8, style: Style, base: dvui.Font) bool {
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        // ASCII below DEL is in every face we would resolve to; skip the
        // decode and the font comparison for the overwhelmingly common case.
        if (n == 1 and text[i] < 0x7F) {
            i += 1;
            continue;
        }
        const cp: u21 = if (i + n <= text.len)
            (std.unicode.utf8Decode(text[i..][0..n]) catch 0xFFFD)
        else
            0xFFFD;
        if (!std.meta.eql(fontFor(cp, style, base), base)) return true;
        i += n;
    }
    return false;
}

/// A label is a label, not a panel. `TextLayoutWidget.defaults` sets
/// `.background = true` with `.style = .content`, so a text layout left alone
/// paints a canvas-coloured block behind itself — which over a sidebar row or
/// any other surface covers what it is sitting on. A caller that genuinely
/// wants a background still says so.
fn noBackground(opts: dvui.Options) dvui.Options {
    var o = opts;
    if (o.background == null) o.background = false;
    if (o.padding == null) o.padding = .{};
    return o;
}

/// A wrapping label that may leave tier 1, rendered through a text layout so
/// the per-run fallback applies. Drop-in for `dvui.label` at such sites (a
/// plain label cannot mix faces within a run).
pub fn richLabel(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    var tl = dvui.textLayout(src, .{}, noBackground(opts));
    defer tl.deinit();
    addStyled(tl, text, .{}, .{ .font = opts.font, .color_text = opts.color_text });
}

/// `richLabel` that never wraps: for row titles and other single-line slots in
/// a fixed-width rail, where wrapping would reflow the whole list. Pair it with
/// `style.ellipsize` so the overflow is cut deliberately rather than clipped.
pub fn richLine(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    const base = opts.font orelse dvui.themeGet().font_body;
    if (!needsSplit(text, .{}, base)) {
        dvui.labelNoFmt(src, text, .{}, noBackground(opts));
        return;
    }
    // Built by hand rather than via `dvui.textLayout`, purely to SKIP
    // `processEvents`. A text layout claims the mouse to support text
    // selection, so a row title drawn with one swallows every click that lands
    // on the words — you would have to aim at the gap between the text and the
    // row's edge to select a folder. A one-line label in a rail has nothing
    // worth selecting, and being inert lets the click reach the row.
    //
    // The id comes from `src` either way, so a string that gains or loses a
    // CJK character between frames swaps widget kinds under one id. That is
    // fine here: neither widget keeps state across frames.
    var tl: dvui.TextLayoutWidget = undefined;
    tl.init(src, .{ .break_lines = false }, noBackground(opts));
    defer tl.deinit();
    addStyled(&tl, text, .{}, .{ .font = opts.font, .color_text = opts.color_text });
}
