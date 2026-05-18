const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

const ClipboardImageData = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
};

fn clipboardImageCallback(userdata: ?*anyopaque, mime_type: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    _ = mime_type;
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    size.* = d.bytes.len;
    return d.bytes.ptr;
}

fn clipboardImageCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    d.gpa.free(d.bytes);
    d.gpa.destroy(d);
}

pub fn copyImageToClipboard(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    copyImageToClipboardImpl(path, gpa, io) catch {};
}

fn copyImageToClipboardImpl(path: []const u8, gpa: std.mem.Allocator, io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len: usize = @intCast(try file.length(io));
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    const d = try gpa.create(ClipboardImageData);
    d.* = .{ .gpa = gpa, .bytes = bytes };
    var mime: [*c]const u8 = "image/png";
    _ = SDLBackend.c.SDL_SetClipboardData(clipboardImageCallback, clipboardImageCleanup, d, &mime, 1);
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

    pub fn renderPanel(self: *const DetailState, panel_w: f32, filename: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
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
            if (filename.len > 0) {
                var tl = dvui.textLayout(@src(), .{}, .{
                    .font = bold,
                    .expand = .horizontal,
                    .background = false,
                });
                tl.addText(filename, .{});
                tl.deinit();
            } else {
                dvui.label(@src(), "{s}", .{i18n.t(.detail_no_image)}, .{ .font = bold, .expand = .horizontal });
            }
            if (self.detail) |d| {
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

/// Render all metadata fields for one image. Called by renderPanel and by the
/// viewer's info pane so the same layout is reused without duplication.
pub fn renderContent(d: db_mod.ImageDetails) void {
    const bp: dvui.Options = .{ .font = bold, .padding = .{ .x = 8, .y = 4, .h = 0 } };
    const lp: dvui.Options = .{
        .padding = .{ .x = 8, .y = 2, .h = 6 },
        .expand = .horizontal,
        .background = false,
    };
    const sp: dvui.Options = .{
        .padding = .{ .x = 8, .y = 2, .h = 6 },
        .expand = .horizontal,
    };

    if (d.positive_prompt_text) |v| {
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hdr.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_prompt)}, bp.override(.{ .expand = .horizontal }));
            if (dvui.buttonIcon(@src(), i18n.t(.action_copy), icons.tvg.lucide.@"copy", .{}, .{},
                .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .padding = .all(4) }))
            {
                if (dvui.currentWindow().arena().dupeZ(u8, v)) |c_str| {
                    _ = SDLBackend.c.SDL_SetClipboardText(c_str.ptr);
                } else |_| {}
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
                if (dvui.currentWindow().arena().dupeZ(u8, v)) |c_str| {
                    _ = SDLBackend.c.SDL_SetClipboardText(c_str.ptr);
                } else |_| {}
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
        if (d.sampler) |v| {
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_sampler)}, bp);
            dvui.label(@src(), "{s}", .{v}, sp);
        }
        if (d.scheduler) |v| {
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_scheduler)}, bp);
            dvui.label(@src(), "{s}", .{v}, sp);
        }
    }

    if (d.cfg != null or d.steps != null or d.seed != null) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        if (d.cfg) |v| {
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_cfg)}, bp);
            dvui.label(@src(), "{d:.1}", .{v}, sp);
        }
        if (d.steps) |v| {
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_steps)}, bp);
            dvui.label(@src(), "{d}", .{v}, sp);
        }
        if (d.seed) |v| {
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_seed)}, bp);
            dvui.label(@src(), "{d}", .{v}, sp);
        }
    }

    if (d.width != null or d.file_size != null) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        if (d.width) |w| {
            if (d.height) |h| {
                var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                defer col.deinit();
                dvui.label(@src(), "{s}", .{i18n.t(.detail_resolution)}, bp);
                dvui.label(@src(), "{d}\u{00d7}{d}", .{ w, h }, sp);
            }
        }
        if (d.file_size) |sz| {
            const fb = fmtBytes(sz);
            var col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer col.deinit();
            dvui.label(@src(), "{s}", .{i18n.t(.detail_size)}, bp);
            dvui.label(@src(), "{d:.1} {s}", .{ fb.value, fb.unit }, sp);
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
