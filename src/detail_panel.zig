const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const platform = @import("platform.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

/// Copy the image at `path` to the system clipboard (as image data). Routed
/// through the platform seam so this module stays backend-agnostic.
pub fn copyImageToClipboard(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    platform.copyImageFile(path, gpa, io);
}

pub const BytesFmt = struct { value: f64, unit: []const u8 };

pub fn fmtBytes(bytes: i64) BytesFmt {
    const b: f64 = @floatFromInt(if (bytes < 0) 0 else bytes);
    if (b >= 1024 * 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0 * 1024.0), .unit = "GB" };
    if (b >= 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0), .unit = "MB" };
    if (b >= 1024) return .{ .value = b / 1024.0, .unit = "KB" };
    return .{ .value = b, .unit = "B" };
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

    pub fn deinit(self: *DetailState, allocator: std.mem.Allocator) void {
        if (self.detail) |*d| {
            d.deinit(allocator);
            self.detail = null;
        }
        self.id = null;
    }

    pub fn update(
        self: *DetailState,
        focused_id: ?u64,
        db: *db_mod.VectorDb,
        gpa: std.mem.Allocator,
        io: std.Io,
    ) void {
        if (focused_id == self.id) return;

        if (self.detail) |*d| {
            d.deinit(gpa);
            self.detail = null;
        }
        self.id = focused_id;

        const fid = focused_id orelse return;

        if (db.getImageDetails(gpa, fid) catch null) |det| {
            self.detail = det;
            const img_path = self.detail.?.library_path;

            // File size (best-effort).
            if (std.Io.Dir.cwd().openFile(io, img_path, .{})) |f| {
                defer f.close(io);
                if (f.length(io)) |sz| {
                    self.detail.?.file_size = @intCast(sz);
                } else |_| {}
            } else |_| {}

            // PNG dims + raw text chunks (best-effort).
            var maybe_parser: ?png_mod.PngParser = png_mod.PngParser.init(gpa, io) catch null;
            if (maybe_parser) |*parser| {
                defer parser.deinit();
                if (parser.parseFile(img_path)) |_| {
                    for (parser.chunks.items) |pc| {
                        if (std.mem.eql(u8, &pc.type, &png_mod.ChunkType.IHDR) and pc.data.len >= 8) {
                            self.detail.?.width = std.mem.readInt(u32, pc.data[0..4], .big);
                            self.detail.?.height = std.mem.readInt(u32, pc.data[4..8], .big);
                            break;
                        }
                    }

                    var raw_list: std.ArrayList(db_mod.RawChunk) = .empty;

                    const text_chunks = parser.getTExtChunks() catch &[_]png_mod.Chunk{};
                    defer gpa.free(text_chunks);
                    for (text_chunks) |tc| {
                        const c = parser.parseTExtChunk(tc) catch continue;
                        const kw = c.keyword;
                        const raw_text = c.text;
                        const maybe_pretty = prettyJson(gpa, raw_text);
                        const display = maybe_pretty orelse raw_text;
                        if (maybe_pretty != null) gpa.free(raw_text);
                        raw_list.append(gpa, .{
                            .keyword = kw,
                            .display_text = display,
                            .is_json = maybe_pretty != null,
                        }) catch {
                            gpa.free(kw);
                            gpa.free(display);
                        };
                    }

                    const itxt_chunks = parser.getITxtChunks() catch &[_]png_mod.Chunk{};
                    defer gpa.free(itxt_chunks);
                    for (itxt_chunks) |tc| {
                        var c = parser.parseITxtChunk(tc) catch continue;
                        if (c.compressed) { c.deinit(gpa); continue; }
                        const kw = c.keyword;
                        const raw_text = c.text;
                        gpa.free(c.language);
                        gpa.free(c.translated_keyword);
                        const maybe_pretty = prettyJson(gpa, raw_text);
                        const display = maybe_pretty orelse raw_text;
                        if (maybe_pretty != null) gpa.free(raw_text);
                        raw_list.append(gpa, .{
                            .keyword = kw,
                            .display_text = display,
                            .is_json = maybe_pretty != null,
                        }) catch {
                            gpa.free(kw);
                            gpa.free(display);
                        };
                    }

                    if (raw_list.items.len > 0) {
                        if (raw_list.toOwnedSlice(gpa)) |sl| {
                            self.detail.?.raw_chunks = sl;
                            self.detail.?.raw_chunks_owned = true;
                        } else |_| {
                            for (raw_list.items) |*rc| {
                                gpa.free(rc.keyword);
                                gpa.free(rc.display_text);
                            }
                            raw_list.deinit(gpa);
                        }
                    }
                } else |_| {}
            }
        }
    }

    pub fn renderPanel(self: *DetailState, panel_w: f32, filename: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
        var meta = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = panel_w, .h = 0 },
            .max_size_content = .{ .w = panel_w, .h = 0 },
            .expand = .vertical,
            .background = true,
        });
        defer meta.deinit();

        {
            var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 6 },
            });
            defer header.deinit();
            // Cap the filename width so a long (often space-less) name clips
            // instead of overflowing and pushing the action buttons off-panel.
            // A plain label (not textLayout) avoids a stray scrollbar in the header.
            const btn_reserve: f32 = if (self.detail != null) 64 else 0;
            const name_w = @max(@as(f32, 0), panel_w - 16 - btn_reserve);
            const name = if (filename.len > 0) filename else i18n.t(.detail_no_image);
            dvui.label(@src(), "{s}", .{name}, .{
                .font = bold,
                .gravity_y = 0.5,
                .max_size_content = dvui.Options.MaxSize.width(name_w),
            });
            if (self.detail) |d| {
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                if (dvui.buttonIcon(@src(), i18n.t(.action_reparse), icons.tvg.lucide.@"refresh-cw", .{}, .{},
                    .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .padding = .all(4) }))
                {
                    self.reparse_requested = true;
                }
                if (dvui.buttonIcon(@src(), i18n.t(.action_copy_image), icons.tvg.lucide.@"clipboard-copy", .{}, .{},
                    .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .padding = .all(4) }))
                {
                    copyImageToClipboard(d.library_path, gpa, io);
                }
            }
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        if (self.detail) |d| {
            renderContent(d);
        } else if (self.id != null) {
            dvui.label(@src(), "(loading\u{2026})", .{}, .{ .padding = .all(8) });
        }
    }
};

// Shared option presets for the metadata layout.
const meta_bold: dvui.Options = .{ .font = bold, .padding = .{ .x = 8, .y = 4, .h = 0 } };
const meta_label: dvui.Options = .{ .padding = .{ .x = 8, .y = 2, .h = 6 }, .expand = .horizontal, .background = false };
const meta_val: dvui.Options = .{ .padding = .{ .x = 8, .y = 2, .h = 6 }, .expand = .horizontal };

/// One labelled metadata column: a bold caption above its value. `src` must be
/// unique per call site (pass @src()) so dvui gives each column a distinct id.
fn metaColumn(src: std.builtin.SourceLocation, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    var col = dvui.box(src, .{}, .{ .expand = .horizontal });
    defer col.deinit();
    dvui.label(@src(), "{s}", .{label}, meta_bold);
    dvui.label(@src(), fmt, args, meta_val);
}

/// Render all metadata fields for one image. Called by renderPanel and by the
/// viewer's info pane so the same layout is reused without duplication.
pub fn renderContent(d: db_mod.ImageDetails) void {
    const bp = meta_bold;
    const lp = meta_label;
    const sp = meta_val;

    if (d.positive_prompt_text) |v| {
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_prompt)}, bp.override(.{ .expand = .horizontal }));
            if (dvui.buttonIcon(@src(), i18n.t(.action_copy), icons.tvg.lucide.@"copy", .{}, .{},
                .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .padding = .all(4), .tag = "copy-prompt" }))
            {
                dvui.clipboardTextSet(v);
            }
        }
        var tl = dvui.textLayout(@src(), .{}, lp);
        tl.addText(v, .{});
        tl.deinit();
    }
    if (d.negative_prompt_text) |v| {
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_negative_prompt)}, bp.override(.{ .expand = .horizontal }));
            if (dvui.buttonIcon(@src(), i18n.t(.action_copy), icons.tvg.lucide.@"copy", .{}, .{},
                .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .padding = .all(4) }))
            {
                dvui.clipboardTextSet(v);
            }
        }
        var tl = dvui.textLayout(@src(), .{}, lp);
        tl.addText(v, .{});
        tl.deinit();
    }

    if (d.model) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_model)}, bp);
        var tl = dvui.textLayout(@src(), .{}, lp);
        tl.addText(v, .{});
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
        var tl = dvui.textLayout(@src(), .{}, lp);
        tl.addText(v, .{});
        tl.deinit();
    }

    if (d.trashed_at) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_trashed_at)}, bp);
        dvui.label(@src(), "{s}", .{v}, sp);
    }
    dvui.label(@src(), "{s}", .{i18n.t(.detail_path)}, bp);
    {
        var tl = dvui.textLayout(@src(), .{}, lp);
        tl.addText(d.library_path, .{});
        tl.deinit();
    }
    if (d.creation_date) |v| {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_date)}, bp);
        dvui.label(@src(), "{s}", .{v}, sp);
    }

    if (d.raw_chunks.len > 0) {
        dvui.label(@src(), "{s}", .{i18n.t(.detail_raw_metadata)}, bp);
        for (d.raw_chunks, 0..) |rc, ci| {
            if (dvui.expander(@src(), rc.keyword, .{ .default_expanded = false }, .{ .expand = .horizontal, .id_extra = ci })) {
                var tl = dvui.textLayout(@src(), .{}, lp.override(.{ .id_extra = ci }));
                tl.addText(rc.display_text, .{});
                tl.deinit();
            }
        }
    }
}
