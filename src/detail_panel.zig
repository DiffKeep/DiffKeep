const std = @import("std");
const log = std.log.scoped(.detail_panel);
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const bg = @import("bg.zig");
const png_mod = @import("image/png-data.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const platform = @import("platform.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");

/// Copy the image at `path` to the system clipboard (as image data). Routed
/// through the platform seam so this module stays backend-agnostic.
pub fn copyImageToClipboard(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    platform.copyImageFile(path, gpa, io);
}

pub const BytesFmt = struct { value: f64, unit: []const u8 };

pub fn fmtBytes(bytes: i64) BytesFmt {
    const b: f64 = @floatFromInt(if (bytes < 0) 0 else bytes);
    if (b >= 1024 * 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0 * 1024.0), .unit = i18n.t(.unit_gb) };
    if (b >= 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0), .unit = i18n.t(.unit_mb) };
    if (b >= 1024) return .{ .value = b / 1024.0, .unit = i18n.t(.unit_kb) };
    return .{ .value = b, .unit = i18n.t(.unit_bytes) };
}

fn prettyJson(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    js.write(parsed.value) catch return null;
    return aw.toOwnedSlice() catch null;
}

pub const DetailState = struct {
    id: ?u64 = null,
    detail: ?db_mod.ImageDetails = null,
    reparse_requested: bool = false,
    /// Wakes the render loop when a background load finishes.
    wakeup_fn: ?*const fn () void = null,

    /// Background load of `id`'s details: a new selection supersedes the
    /// load of the previous one.
    load: Load = .{},

    pub fn deinit(self: *DetailState, allocator: std.mem.Allocator) void {
        self.load.deinit();
        if (self.detail) |*d| {
            d.deinit(allocator);
            self.detail = null;
        }
        self.id = null;
    }

    /// Show `focused_id`'s details. The DB row and the file's PNG chunks are
    /// read in the background (file IO never runs on the render thread); until
    /// they arrive the panel shows its loading state.
    pub fn update(
        self: *DetailState,
        focused_id: ?u64,
        db: *db_mod.VectorDb,
        gpa: std.mem.Allocator,
        io: std.Io,
    ) void {
        self.takeLoaded(gpa);
        if (focused_id == self.id) return;

        if (self.detail) |*d| {
            d.deinit(gpa);
            self.detail = null;
        }
        self.id = focused_id;
        const fid = focused_id orelse return self.load.cancel();
        self.load.wakeup_fn = self.wakeup_fn;
        _ = self.load.start(io, gpa, loadTask, .{ db, gpa, io, fid }) catch |err|
            std.log.scoped(.detail_panel).warn("spawn details load: {}", .{err});
    }

    /// Wait for the running load and show it (tests).
    pub fn awaitLoad(self: *DetailState, gpa: std.mem.Allocator) void {
        self.load.awaitAll();
        self.takeLoaded(gpa);
    }

    fn takeLoaded(self: *DetailState, gpa: std.mem.Allocator) void {
        const outcome = self.load.take() orelse return;
        const d = outcome.value orelse return;
        if (self.detail) |*old| old.deinit(gpa);
        self.detail = d;
    }

    const Load = bg.Latest(db_mod.ImageDetails, db_mod.ImageDetails.deinit);

    fn loadTask(_: Load.Ticket, db: *db_mod.VectorDb, gpa: std.mem.Allocator, io: std.Io, id: u64) ?db_mod.ImageDetails {
        var conn = db.getConnection() catch |err| {
            log.warn("details connection: {}", .{err});
            return null;
        };
        defer conn.deinit();
        return loadDetails(&conn, gpa, io, id);
    }

    pub fn renderPanel(self: *DetailState, panel_w: f32, filename: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
        var meta = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = panel_w, .h = 0 },
            .max_size_content = .{ .w = panel_w, .h = 0 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = style.C.rail },
            .border = style.Edge.left,
            .color_border = .{ .color = style.hairline_soft },
        });
        defer meta.deinit();

        {
            // dvui cannot draw a one-edge border without a background
            var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 8, .w = 6, .h = 8 },
                .background = true,
                .color_fill = .{ .color = style.C.rail },
                .border = style.Edge.bottom,
                .color_border = .{ .color = style.hairline_soft },
            });
            defer header.deinit();
            const btn_reserve: f32 = if (self.detail != null) 64 else 0;
            const name_w = @max(@as(f32, 0), panel_w - 20 - btn_reserve);
            const name = if (filename.len > 0) filename else i18n.t(.detail_no_image);
            var name_buf: [512]u8 = undefined;
            fonts.richLine(@src(), style.ellipsize(&name_buf, name, style.F.row_hi, name_w), .{
                .font = style.F.row_hi,
                .color_text = .{ .color = if (filename.len > 0) style.C.text_hi else style.C.text_ghost },
                .gravity_y = 0.5,
                .max_size_content = dvui.Options.MaxSize.width(name_w),
            });
            if (self.detail) |d| {
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                if (dvui.buttonIcon(@src(), i18n.t(.action_reparse), icons.tvg.lucide.@"refresh-cw", .{}, .{}, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .padding = .all(4),
                    .background = false,
                    .corners = style.R.chip,
                    .color_text = .{ .color = style.C.text_dim },
                })) {
                    self.reparse_requested = true;
                }
                if (dvui.buttonIcon(@src(), i18n.t(.action_copy_image), icons.tvg.lucide.@"clipboard-copy", .{}, .{}, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .padding = .all(4),
                    .background = false,
                    .corners = style.R.chip,
                    .color_text = .{ .color = style.C.text_dim },
                })) {
                    copyImageToClipboard(d.library_path, gpa, io);
                }
            }
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
        defer scroll.deinit();

        if (self.detail) |d| {
            renderContent(d);
        } else if (self.id != null) {
            dvui.label(@src(), "{s}", .{i18n.t(.detail_loading)}, .{
                .padding = .all(10),
                .font = style.F.mono,
                .color_text = .{ .color = style.C.text_ghost },
            });
        }
    }
};

/// Everything the detail panel shows for image `id`: the DB row plus, from
/// the file, its size and (PNG only) dimensions and raw text chunks. Does DB
/// and file IO: call it off the main thread.
pub fn loadDetails(db: *db_mod.VectorDb, gpa: std.mem.Allocator, io: std.Io, id: u64) ?db_mod.ImageDetails {
    var det = (db.getImageDetails(gpa, id) catch |err| {
        log.warn("details for {d}: {}", .{ id, err });
        return null;
    }) orelse return null;
    const img_path = det.library_path;

    if (std.Io.Dir.cwd().statFile(io, img_path, .{})) |st| {
        det.file_size = @intCast(st.size);
    } else |_| {}

    // Only PNGs carry chunks; don't read a large video or JPEG for nothing.
    if (!std.ascii.endsWithIgnoreCase(img_path, ".png")) return det;
    var parser = png_mod.PngParser.init(gpa, io) catch return det;
    defer parser.deinit();
    parser.parseFile(img_path) catch return det;

    for (parser.chunks.items) |pc| {
        if (std.mem.eql(u8, &pc.type, &png_mod.ChunkType.IHDR) and pc.data.len >= 8) {
            det.width = std.mem.readInt(u32, pc.data[0..4], .big);
            det.height = std.mem.readInt(u32, pc.data[4..8], .big);
            break;
        }
    }

    var raw_list: std.ArrayList(db_mod.RawChunk) = .empty;
    const text_chunks = parser.getTExtChunks() catch &[_]png_mod.Chunk{};
    defer gpa.free(text_chunks);
    for (text_chunks) |tc| {
        const c = parser.parseTExtChunk(tc) catch continue;
        appendRawChunk(gpa, &raw_list, c.keyword, c.text);
    }
    const itxt_chunks = parser.getITxtChunks() catch &[_]png_mod.Chunk{};
    defer gpa.free(itxt_chunks);
    for (itxt_chunks) |tc| {
        var c = parser.parseITxtChunk(tc) catch continue;
        if (c.compressed) {
            c.deinit(gpa);
            continue;
        }
        gpa.free(c.language);
        gpa.free(c.translated_keyword);
        appendRawChunk(gpa, &raw_list, c.keyword, c.text);
    }

    if (raw_list.items.len > 0) {
        if (raw_list.toOwnedSlice(gpa)) |sl| {
            det.raw_chunks = sl;
            det.raw_chunks_owned = true;
        } else |_| {
            for (raw_list.items) |*rc| {
                gpa.free(rc.keyword);
                gpa.free(rc.display_text);
            }
            raw_list.deinit(gpa);
        }
    }
    return det;
}

/// Append a chunk (taking ownership of `kw` and `raw_text`), pretty-printing
/// JSON text.
fn appendRawChunk(gpa: std.mem.Allocator, list: *std.ArrayList(db_mod.RawChunk), kw: []u8, raw_text: []u8) void {
    const maybe_pretty = prettyJson(gpa, raw_text);
    const display = maybe_pretty orelse raw_text;
    if (maybe_pretty != null) gpa.free(raw_text);
    list.append(gpa, .{ .keyword = kw, .display_text = display, .is_json = maybe_pretty != null }) catch {
        gpa.free(kw);
        gpa.free(display);
    };
}

// Shared option presets for the metadata layout.
const meta_bold: dvui.Options = .{
    .font = style.F.mono_hd,
    .color_text = .{ .color = style.C.text_ghost },
    .padding = .{ .x = 10, .y = 8, .w = 10, .h = 2 },
};
const meta_label: dvui.Options = .{
    .padding = .{ .x = 10, .y = 0, .w = 10, .h = 4 },
    .expand = .horizontal,
    .background = false,
    .color_text = .{ .color = style.C.text },
};
const meta_val: dvui.Options = .{
    .padding = .{ .x = 10, .y = 0, .w = 10, .h = 4 },
    .expand = .horizontal,
    .font = style.F.mono_val,
    .color_text = .{ .color = style.C.text_hi },
};

fn copyButton(src: std.builtin.SourceLocation, text: []const u8, tag: ?[]const u8) void {
    if (dvui.buttonIcon(src, i18n.t(.action_copy), icons.tvg.lucide.copy, .{}, .{}, .{
        .min_size_content = .{ .w = 13, .h = 13 },
        .gravity_y = 0.5,
        .padding = .all(4),
        .background = false,
        .corners = style.R.chip,
        .color_text = .{ .color = style.C.text_ghost },
        .tag = tag,
    })) {
        dvui.clipboardTextSet(text);
    }
}

fn prose(src: std.builtin.SourceLocation, text: []const u8) void {
    var tl = dvui.textLayout(src, .{}, meta_label.override(.{ .font = style.F.prose }));
    defer tl.deinit();
    fonts.addStyled(tl, text, .{}, .{ .font = style.F.prose, .color_text = .{ .color = style.C.text } });
}

/// One labelled metadata column: a caption above its value.
fn metaColumn(src: std.builtin.SourceLocation, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    var col = dvui.box(src, .{}, .{ .expand = .horizontal });
    defer col.deinit();
    dvui.label(@src(), "{s}", .{label}, meta_bold);
    dvui.label(@src(), fmt, args, meta_val);
}

/// Render all metadata fields for one image.
pub fn renderContent(d: db_mod.ImageDetails) void {
    const bp = meta_bold;
    const lp = meta_label;
    const sp = meta_val;

    if (d.positive_prompt_text) |v| {
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_prompt)}, bp.override(.{ .expand = .horizontal }));
            copyButton(@src(), v, "copy-prompt");
        }
        prose(@src(), v);
    }
    if (d.negative_prompt_text) |v| {
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_negative_prompt)}, bp.override(.{ .expand = .horizontal }));
            copyButton(@src(), v, null);
        }
        prose(@src(), v);
    }

    if (d.model) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_model)}, bp);
        var tl = dvui.textLayout(@src(), .{}, lp.override(.{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_hi } }));
        fonts.addStyled(tl, v, .{ .code = true }, .{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_hi } });
        tl.deinit();
    }

    if (d.sampler != null or d.scheduler != null) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        if (d.sampler) |v| metaColumn(@src(), i18n.t(.detail_sampler), "{s}", .{v});
        if (d.scheduler) |v| metaColumn(@src(), i18n.t(.detail_scheduler), "{s}", .{v});
    }

    if (d.cfg != null or d.steps != null or d.seed != null) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        if (d.cfg) |v| metaColumn(@src(), i18n.t(.detail_cfg), "{d:.1}", .{v});
        if (d.steps) |v| metaColumn(@src(), i18n.t(.detail_steps), "{d}", .{v});
        if (d.seed) |v| metaColumn(@src(), i18n.t(.detail_seed), "{d}", .{v});
    }

    if (d.width != null or d.file_size != null) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        if (d.width) |w| {
            if (d.height) |h| metaColumn(@src(), i18n.t(.detail_resolution), "{d}\u{00d7}{d}", .{ w, h });
        }
        if (d.file_size) |sz| {
            const fb = fmtBytes(sz);
            metaColumn(@src(), i18n.t(.detail_size), "{d:.1} {s}", .{ fb.value, fb.unit });
        }
    }

    if (d.loras) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_loras)}, bp);
        var tl = dvui.textLayout(@src(), .{}, lp.override(.{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_hi } }));
        fonts.addStyled(tl, v, .{ .code = true }, .{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_hi } });
        tl.deinit();
    }

    if (d.trashed_at) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_trashed_at)}, bp);
        dvui.label(@src(), "{s}", .{v}, sp);
    }
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        dvui.label(@src(), "{s}", .{i18n.t(.detail_path)}, bp.override(.{ .expand = .horizontal }));
        copyButton(@src(), d.library_path, null);
    }
    {
        var tl = dvui.textLayout(@src(), .{}, lp.override(.{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_faint } }));
        fonts.addStyled(tl, d.library_path, .{ .code = true }, .{ .font = style.F.mono_wrap, .color_text = .{ .color = style.C.text_faint } });
        tl.deinit();
    }
    if (d.creation_date) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_date)}, bp);
        dvui.label(@src(), "{s}", .{v}, sp);
    }

    if (d.raw_chunks.len > 0) {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_raw_metadata)}, bp);
        for (d.raw_chunks, 0..) |rc, ci| {
            if (dvui.expander(@src(), rc.keyword, .{ .default_expanded = false }, .{
                .expand = .horizontal,
                .id_extra = ci,
                .padding = .{ .x = 10, .y = 3, .w = 6, .h = 3 },
                .font = style.F.mono,
                .color_text = .{ .color = style.C.text_dim },
            })) {
                var well = dvui.box(@src(), .{}, .{
                    .id_extra = ci,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = style.C.sunken },
                    .corners = style.R.chip,
                    .margin = .{ .x = 10, .y = 2, .w = 10, .h = 8 },
                    .padding = .all(8),
                });
                defer well.deinit();
                _ = drawLongCode(rc.display_text, ci);
            }
        }
    }
}

/// Lines per separately laid-out block of `drawLongCode`.
const code_block_lines = 40;

/// Draw `text` (pretty-printed metadata: often thousands of lines) as code,
/// laying out only the blocks of lines on screen. One text layout of all of
/// it was re-measured every frame while expanded. A block out of view keeps
/// the height it measured at this width; until it has one, it is laid out.
/// Returns how many blocks were laid out (tests).
pub fn drawLongCode(text: []const u8, id_extra: usize) usize {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id_extra, .expand = .horizontal });
    defer col.deinit();
    const w = col.data().contentRect().w;
    const clip = dvui.clipGet();

    var laid_out: usize = 0;
    var start: usize = 0;
    var block: usize = 0;
    while (start < text.len) : (block += 1) {
        var end = start;
        for (0..code_block_lines) |_| {
            end = if (std.mem.indexOfScalarPos(u8, text, end, '\n')) |nl| nl + 1 else text.len;
            if (end == text.len) break;
        }
        // The block's text without its final newline (the next block starts a line).
        const chunk = std.mem.trimEnd(u8, text[start..end], "\n");
        start = end;

        const src = @src();
        const id = dvui.parentGet().extendId(src, block);
        const known_h: ?f32 = if (dvui.dataGet(null, id, "w", f32) == w) dvui.dataGet(null, id, "h", f32) else null;
        var b = dvui.box(src, .{ .dir = .vertical }, .{
            .id_extra = block,
            .expand = .horizontal,
            .min_size_content = .{ .h = known_h orelse 0 },
        });
        defer b.deinit();
        // Laid out at this width last frame: its height now is the text's.
        if (dvui.dataGet(null, id, "laid_w", f32) == w) {
            dvui.dataSet(null, id, "h", b.data().contentRect().h);
            dvui.dataSet(null, id, "w", w);
        }
        if (known_h != null and b.data().rectScale().r.intersect(clip).empty()) continue;

        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .padding = .{},
        });
        fonts.addStyled(tl, chunk, .{ .code = true }, .{
            .font = style.F.code,
            .color_text = .{ .color = style.C.text_dim },
        });
        tl.deinit();
        dvui.dataSet(null, id, "laid_w", w);
        laid_out += 1;
    }
    return laid_out;
}
