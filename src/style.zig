//! The DiffKeep design system: one palette, one type scale, one set of radii,
//! and the handful of primitives every surface shares. Nothing here knows about
//! libraries, grids or metadata — it is the vocabulary the views are written in.
//!
//! Ported from TensorPencil's `src/gui/style.zig` so the two apps read as one
//! family. Two rules the whole UI depends on:
//!
//!   AMBER means the machine is doing something (a scan, an embedding pass, a
//!   model download, a search in flight). BLUE means the user owns it
//!   (selection, focus, an active filter, a value they set). Never amber a
//!   button, never blue a progress indicator. Against neutrals, these two are
//!   the only accents on the screen, which is what makes either of them
//!   readable at a glance.
//!
//!   Hairlines are always white at low alpha over the surface, never a solid
//!   grey, so one edge color works over `chrome`, `rail` and `canvas` alike.
//!
//! Sizes here are NOMINAL px (the size a designer means by "12.5px text"), but
//! dvui's `Font.size` is the height of a capital M. `role` converts, so
//! `cap_ratio` is the single place the two worlds meet. A pleasant side effect:
//! two faces at the same dvui size have the same cap height, so a CJK fallback
//! run cannot change a line's optical size.

const std = @import("std");
const dvui = @import("dvui");
const fonts = @import("fonts.zig");

pub const Color = dvui.Color;

/// Surfaces, text and accents. Reserved meanings are marked; a color with a
/// meaning is never reused for decoration.
pub const C = struct {
    // surfaces
    pub const canvas = Color.fromHex("#0b0d0f"); // grid pane / app ground
    pub const chrome = Color.fromHex("#101317"); // toolbar, status bar, modals
    pub const rail = Color.fromHex("#0e1114"); // sidebar + detail panel
    pub const sunken = Color.fromHex("#12161a"); // search field, thumbnail well
    pub const card = Color.fromHex("#0f1316"); // grid cell, metadata block
    pub const raised = Color.fromHex("#1c2126"); // buttons
    pub const raised_dim = Color.fromHex("#151a1e"); // secondary buttons
    pub const chip = Color.fromHex("#141a1e"); // filter pills, mode chips
    pub const chip_hi = Color.fromHex("#171b1f"); // chips on chrome
    pub const sel_row = Color.fromHex("#1a1f24"); // selected sidebar row
    pub const seg_track = Color.fromHex("#181c20"); // search-mode toggle well
    pub const track = Color.fromHex("#22282d"); // slider / progress track

    // text
    pub const text_hi = Color.fromHex("#e6e8ea"); // primary
    pub const text = Color.fromHex("#c9cdd1"); // body / prompt prose
    pub const text_dim = Color.fromHex("#8b9196"); // secondary / labels
    pub const text_faint = Color.fromHex("#6d7378"); // mono captions
    pub const text_ghost = Color.fromHex("#5c6368"); // placeholders, heads, disabled
    pub const text_ink = Color.fromHex("#0b0d0f"); // on light fills

    // accents — RESERVED MEANINGS, see the module header
    pub const amber = Color.fromHex("#f0a03c");
    pub const blue = Color.fromHex("#6ea8f0");
    pub const danger = Color.fromHex("#d9584f");

    /// The favourite star, and the ONLY sanctioned exception to the two-accent
    /// rule. A star is gold everywhere a user has ever seen one; recolouring it
    /// blue to satisfy "blue = the user owns it" would cost more recognition
    /// than the consistency is worth. Nothing else may use this colour.
    pub const star = Color.fromHex("#ffcd2d");

    /// Behind a thumbnail while it decodes, and behind letterboxed images. Not
    /// `canvas`: a cell must read as a distinct object on the grid ground even
    /// before its picture arrives.
    pub const thumb_well = Color.fromHex("#121417");
};

/// Edges. Always alpha over whatever is beneath.
pub const hairline = Color{ .r = 255, .g = 255, .b = 255, .a = 18 }; // chrome edges
pub const hairline_soft = Color{ .r = 255, .g = 255, .b = 255, .a = 15 }; // inside rails
pub const hairline_hi = Color{ .r = 255, .g = 255, .b = 255, .a = 28 }; // inputs
pub const hover_wash = Color{ .r = 255, .g = 255, .b = 255, .a = 10 }; // row hover

/// A translucent accent, for BORDERS and hairlines, where sitting over an
/// unknown surface is the point.
pub fn tint(c: Color, alpha: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = alpha };
}

/// An accent laid over a known surface at `t`, resolved to an OPAQUE color.
/// Use this for FILLS. dvui fills a widget's whole border rect with the border
/// color and then insets the background, so a translucent background over a
/// colored border shows the border rather than the blend — which is how a 5%
/// blue wash renders as a solid blue slab.
pub fn over(base: Color, accent: Color, t: f32) Color {
    var c = base.lerp(accent, t);
    c.a = 255;
    return c;
}

// ---------------------------------------------------------------- type

/// Cap height as a fraction of the em, for the bundled Plex faces. Every
/// nominal size in the app passes through this; a test reads it back out of the
/// font file so a face swap cannot silently resize the UI.
pub const cap_ratio: f32 = 0.698;

/// The hhea ascent-to-descent span, in ems, of the bundled Plex faces (all
/// seven share 1025/-275). dvui's `line_height_factor` multiplies THIS, not the
/// cap height, so a designer's "1.65 line height" is 1.65/1.30 as a factor.
/// Getting this wrong is invisible in a unit test and doubles every paragraph's
/// leading on screen.
pub const natural_line: f32 = 1.30;

/// One knob over the whole scale, so the roles keep their ratios to each other.
///
/// The nominal sizes below come from a design drawn for a 1200×705 window. This
/// is a library browser that runs maximised, and a nominal px is only ~0.7 px of
/// cap height, so those numbers land well under dvui's own default of cap 10 —
/// the body role would read at cap 8. This lifts body to roughly that default
/// and carries everything else with it. Change this, not the roles, to resize
/// the UI.
pub const ui_scale: f32 = 1.3;

/// A type role: nominal px, plus the line height as a multiple of that nominal
/// size (i.e. what a designer means by "12.5/1.65"), converted into dvui's two
/// different worlds — cap height for size, hhea span for leading.
fn role(family: []const u8, nominal: f32, line: f32, weight: dvui.Font.Weight) dvui.Font {
    return (dvui.Font{})
        .withFamily(family)
        .withSize(nominal * ui_scale * cap_ratio)
        .withWeight(weight)
        .withLineHeight(line / natural_line);
}

/// The type scale. Names are roles, never faces: a call site asks for `F.ui`,
/// not for Plex Sans Medium 11.
pub const F = struct {
    /// App name / modal title, 12/600.
    pub const app = role(fonts.sans, 12, 1.0, .bold);
    /// UI label / button, 11/500.
    pub const ui = role(fonts.sans, 11, 1.0, .normal);
    /// Smaller UI label, 10.5/500.
    pub const ui_sm = role(fonts.sans_med, 10.5, 1.0, .normal);
    /// Emphasised UI label — a section title inside a panel, 11/600.
    pub const ui_hi = role(fonts.sans, 11, 1.0, .bold);
    /// List row title (sidebar folders, libraries), 11.5/400.
    pub const row = role(fonts.sans, 11.5, 1.35, .normal);
    /// Row title in a rail that must not reflow, 11/500.
    pub const row_hi = role(fonts.sans_med, 11, 1.2, .normal);
    /// Prompt text and other long prose, 12.5/1.65. The one role that carries
    /// text read left to right for more than a line.
    pub const prose = role(fonts.sans, 12.5, 1.65, .normal);
    /// Text-entry contents, 12.5/1.2.
    pub const input = role(fonts.sans, 12.5, 1.2, .normal);
    /// Metadata / params, 10.5/400. A SCANNING role: chips, one-line captions,
    /// figures compared against each other. Not for anything read left to right.
    pub const mono = role(fonts.mono, 10.5, 1.0, .normal);
    /// `mono` for a value that WRAPS — a filesystem path, a lora list. Same
    /// size, real leading: at 1.0 the second line sits on the first and runs
    /// into whatever field comes next.
    pub const mono_wrap = role(fonts.mono, 10.5, 1.45, .normal);
    /// Monospaced text that is READ, not scanned: a raw PNG metadata chunk, a
    /// pretty-printed workflow JSON. Sized against `prose` and given real
    /// leading, since it wraps to many lines.
    pub const code = role(fonts.mono, 12, 1.45, .normal);
    /// The smallest role, for dense captions that are scanned, not read.
    pub const mono_sm = role(fonts.mono, 10.5, 1.0, .normal);
    /// Section head (LIBRARY, TRASH), 10/500 uppercase. A head has to stay
    /// legible at a glance even though it is the smallest thing on screen, so it
    /// sits half a step above the design's 9.5.
    pub const mono_hd = role(fonts.mono_med, 10, 1.0, .normal);
    /// A figure a user compares against another (image counts, file sizes).
    pub const mono_val = role(fonts.mono_med, 11, 1.0, .normal);
    /// A grid cell's filename caption, 10.5/1.15. Long generated filenames are
    /// scanned for the one differing digit, so they get a step over `mono_sm`.
    pub const caption = role(fonts.sans, 10.5, 1.15, .normal);
};

// ---------------------------------------------------------------- geometry

pub const R = struct {
    pub const chip: dvui.CornerRect = .all(5);
    pub const button: dvui.CornerRect = .all(6);
    pub const panel: dvui.CornerRect = .all(7);
    pub const seg: dvui.CornerRect = .all(8); // segmented-toggle well
    pub const card: dvui.CornerRect = .all(9);
    pub const input: dvui.CornerRect = .all(10);
    pub const track: dvui.CornerRect = .all(2);
    pub const none: dvui.CornerRect = .all(0);
};

/// A 1px border on one edge only, as `Options.border` wants it.
pub const Edge = struct {
    pub const top = dvui.Rect{ .y = 1 };
    pub const bottom = dvui.Rect{ .h = 1 };
    pub const left = dvui.Rect{ .x = 1 };
    pub const right = dvui.Rect{ .w = 1 };
    pub const all = dvui.Rect.all(1);
};

// ---------------------------------------------------------------- theme

/// Build the dvui theme from the palette, so stock widgets (buttons, text
/// entries, scrollbars, menus, dialogs, expanders) land in the same world as
/// the hand-drawn chrome instead of fighting it.
pub fn theme() dvui.Theme {
    return .{
        .name = "DiffKeep",
        .dark = true,
        .focus = C.blue,
        .text_select = tint(C.blue, 70),
        .fill = C.canvas,
        .fill_hover = C.raised_dim,
        .fill_press = C.raised,
        .text = C.text,
        .border = hairline,
        .font_body = role(fonts.sans, 11.5, 1.35, .normal),
        .font_heading = role(fonts.sans, 11.5, 1.2, .bold),
        .font_title = role(fonts.sans, 14, 1.3, .bold),
        .font_mono = F.mono,
        .control = .{
            .fill = C.raised,
            .fill_hover = C.raised.lighten(6),
            .fill_press = C.raised.lighten(12),
            .text = C.text_hi,
            .border = hairline_hi,
        },
        .window = .{
            .fill = C.chrome,
            .text = C.text,
            .border = hairline,
        },
        .highlight = .{
            .fill = tint(C.blue, 40),
            .fill_hover = tint(C.blue, 60),
            .text = C.text_hi,
            .border = tint(C.blue, 90),
        },
        .err = .{
            .fill = tint(C.danger, 40),
            .fill_hover = tint(C.danger, 70),
            .text = C.text_hi,
            .border = C.danger,
        },
    };
}

/// A copy of the theme with a TRANSPARENT focus color, for text entries that
/// sit inside our own chrome.
///
/// `TextEntryWidget` unconditionally strokes a 2px focus ring on its OWN border
/// rect. An entry stripped of background and padding relies on the surrounding
/// chip or frame for its chrome, which puts that ring a pixel from the glyphs
/// and makes selected text unreadable. Handing the entry this theme removes the
/// ring; the caller then draws focus on the outer edge, where there is room for
/// it. The caret survives, because `drawCursor` reads the CURRENT theme rather
/// than the widget's.
var no_focus: dvui.Theme = undefined;

pub fn noFocusTheme() *const dvui.Theme {
    return &no_focus;
}

/// Register the fonts and install the theme. Must run inside a
/// `Window.begin`/`end` pair.
pub fn install() void {
    fonts.register(); // registers the sources + builds tier-1 coverage
    var t = theme();
    t.embedded_fonts = dvui.themeGet().embedded_fonts; // keep what fonts.register put there
    dvui.themeSet(t);
    no_focus = t;
    no_focus.focus = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

// ---------------------------------------------------------------- marks

/// UI affordance marks. These are vector icons, NOT text: Plex has none of
/// `▾ ▸ ✕`, so as glyphs they would be tofu. As icons they also stay crisp at
/// any scale.
pub const Mark = enum {
    /// A dropdown's "there is a menu here".
    caret_down,
    /// A collapsed disclosure.
    disclosure,
    /// An expanded disclosure.
    disclosure_open,
    close,
    check,
    plus,
    minus,
    gear,

    fn tvg(self: Mark) []const u8 {
        return switch (self) {
            .caret_down => dvui.entypo.chevron_small_down,
            .disclosure => dvui.entypo.triangle_right,
            .disclosure_open => dvui.entypo.triangle_down,
            .close => dvui.entypo.cross,
            .check => dvui.entypo.check,
            .plus => dvui.entypo.plus,
            .minus => dvui.entypo.minus,
            .gear => dvui.entypo.cog,
        };
    }
};

/// Draw a mark inline at `size` logical px in `color`.
pub fn mark(src: std.builtin.SourceLocation, m: Mark, size: f32, color: Color, opts: dvui.Options) void {
    var o = opts;
    o.min_size_content = .{ .w = size, .h = size };
    o.color_text = .{ .color = color };
    if (o.gravity_y == null) o.gravity_y = 0.5;
    dvui.icon(src, @tagName(m), m.tvg(), .{}, o);
}

// ---------------------------------------------------------------- widgets

pub const ChipOpts = struct {
    /// Show a caret and report clicks.
    dropdown: bool = false,
    font: dvui.Font = F.mono,
    fill: Color = C.chip,
    border: Color = hairline,
    text: Color = C.text_dim,
    id_extra: usize = 0,
    /// Left gap, for chips laid out in a row.
    margin_x: f32 = 0,
};

/// A small bordered pill: filter tags, mode markers, counts. Returns true when
/// clicked, so a caller can make one interactive.
pub fn chip(src: std.builtin.SourceLocation, text: []const u8, o: ChipOpts) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, .{
        .id_extra = o.id_extra,
        .background = true,
        .color_fill = .{ .color = o.fill },
        .color_fill_hover = .{ .color = o.fill.lighten(5) },
        .color_fill_press = .{ .color = o.fill.lighten(10) },
        .border = Edge.all,
        .color_border = .{ .color = o.border },
        .corners = R.button,
        .padding = .{ .x = 9, .y = 6, .w = if (o.dropdown) 6 else 9, .h = 6 },
        .margin = .{ .x = o.margin_x },
        .gravity_y = 0.5,
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.labelNoFmt(@src(), text, .{}, .{
        .font = o.font,
        .color_text = .{ .color = o.text },
        .padding = .{},
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    if (o.dropdown) mark(@src(), .caret_down, 11, o.text, .{ .margin = .{ .x = 4 } });
    const clicked = bw.clicked();
    bw.drawFocus();
    return clicked;
}

pub const SegmentOpts = struct {
    /// Per-segment enablement; a disabled segment is ghosted and unclickable.
    /// `null` means every segment is enabled.
    enabled: ?[]const bool = null,
    font: dvui.Font = F.ui,
    id_extra: usize = 0,
};

/// A sunken track with one lit segment — the search-mode picker. `active` is an
/// index into `labels`; returns the index the user picked, or null.
pub fn segmented(
    src: std.builtin.SourceLocation,
    labels: []const []const u8,
    active: usize,
    o: SegmentOpts,
) ?usize {
    var picked: ?usize = null;
    var well = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = o.id_extra,
        .background = true,
        .color_fill = .{ .color = C.seg_track },
        .border = Edge.all,
        .color_border = .{ .color = hairline },
        .corners = R.seg,
        .padding = dvui.Rect.all(2),
        .gravity_y = 0.5,
    });
    defer well.deinit();

    for (labels, 0..) |lbl, i| {
        const on = i == active;
        const enabled = if (o.enabled) |e| (i < e.len and e[i]) else true;
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i,
            .background = on,
            .color_fill = .{ .color = C.text_hi },
            .color_fill_hover = .{ .color = if (on) C.text_hi else hover_wash },
            .color_fill_press = .{ .color = if (on) C.text_hi else hover_wash },
            .corners = R.button,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = if (i == 0) .{} else .{ .x = 2 },
        });
        defer bw.deinit();
        bw.processEvents();
        bw.drawBackground();
        dvui.labelNoFmt(@src(), lbl, .{}, .{
            .font = o.font,
            .color_text = .{ .color = if (on) C.text_ink else if (enabled) C.text_dim else C.text_ghost },
            .padding = .{},
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        if (bw.clicked() and enabled) picked = i;
        bw.drawFocus();
    }
    return picked;
}

/// The content size for a text entry of `chars` characters in `font`.
///
/// A text entry sizes itself with `Font.sizeM(14, 1)` and then, for single-line
/// entries, CLAMPS `max_size_content` to whatever `min_size_content` ends up
/// being. So passing a width without a height does not merely widen the field —
/// it clamps the height to zero and the field collapses to an empty pill. Any
/// call site that narrows an entry must go through this.
pub fn entrySize(font: dvui.Font, chars: f32) dvui.Size {
    return font.sizeM(chars, 1);
}

/// The affirmative button of a dialog: a light slab with ink-coloured text, the
/// one high-contrast fill on the screen. Its counterpart is a stock
/// `dvui.button` (secondary) or one with `.style = .err` (destructive).
pub fn primaryButton(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, opts.override(.{
        .background = true,
        .color_fill = .{ .color = C.text_hi },
        .color_fill_hover = .{ .color = C.text_hi.lighten(-6) },
        .color_fill_press = .{ .color = C.text_hi.lighten(-12) },
        .corners = R.button,
        .padding = .{ .x = 14, .y = 7, .w = 14, .h = 7 },
    }));
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .font = F.ui,
        .color_text = .{ .color = C.text_ink },
        .padding = .{},
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    const clicked = bw.clicked();
    bw.drawFocus();
    return clicked;
}

/// A modal's heading. Dialogs are the one place a title is allowed to outsize
/// the UI scale; everything under it stays at body size.
pub fn modalTitle(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{
        .font = F.app,
        .color_text = .{ .color = C.text_hi },
        .padding = .{},
        .margin = .{ .h = 10 },
    });
}

/// Truncate `text` to `max_w` logical px in `font`, appending an ellipsis.
/// Returns a slice of `buf`, or `text` itself when it already fits.
///
/// MEASURED, never counted: an ideograph is twice the width of a Latin letter,
/// so a character budget cuts a Japanese filename at half the room it has and
/// lets a Latin one overflow. Only valid between `Window.begin`/`end`.
pub fn ellipsize(buf: []u8, text: []const u8, font: dvui.Font, max_w: f32) []const u8 {
    if (font.textSize(text).w <= max_w) return text;
    const ell = "…";
    const ell_w = font.textSize(ell).w;
    if (max_w <= ell_w) return "";

    // Walk whole codepoints so a cut never lands inside a UTF-8 sequence.
    var end: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const next = @min(text.len, i + n);
        if (font.textSize(text[0..next]).w + ell_w > max_w) break;
        end = next;
        i = next;
    }
    if (end + ell.len > buf.len) end = @min(end, buf.len -| ell.len);
    @memcpy(buf[0..end], text[0..end]);
    @memcpy(buf[end..][0..ell.len], ell);
    return buf[0 .. end + ell.len];
}

/// An uppercase mono section head (LIBRARY, TRASH, DUPLICATES). The caller may
/// brighten it — a head that doubles as a selectable row does — but never
/// chooses its face.
pub fn sectionHead(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    var o = opts;
    o.font = F.mono_hd;
    if (o.color_text == null) o.color_text = .{ .color = C.text_ghost };
    if (o.padding == null) o.padding = .{ .x = 8, .h = 7 };
    dvui.labelNoFmt(src, text, .{}, o);
}

/// A vertical hairline the height of its parent's content, for splitting groups
/// inside a bar.
pub fn vsep(src: std.builtin.SourceLocation) void {
    var b = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = 1 },
        .background = true,
        .color_fill = .{ .color = hairline },
        .margin = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
    });
    b.deinit();
}

/// A horizontal hairline across its parent's content width.
pub fn hsep(src: std.builtin.SourceLocation) void {
    var b = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .background = true,
        .color_fill = .{ .color = hairline_soft },
        .margin = .{ .y = 6, .h = 6 },
    });
    b.deinit();
}
