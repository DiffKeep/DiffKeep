const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const i18n = @import("i18n.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const detail_panel_mod = @import("detail_panel.zig");
const library_manager_mod = @import("library_manager.zig");
const search_mod = @import("search.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });
const log = std.log.scoped(.settings);

pub const download_quant_options = [_][:0]const u8{
    "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
    "Q4_K_S", "Q4_K_M", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
};

// Must be file-level — SDL_ShowOpenFileDialog is async and reads the filter after the call returns.
var g_picker_open: bool = false;
const g_gguf_filter = SDLBackend.c.SDL_DialogFileFilter{ .name = "GGUF model", .pattern = "gguf" };

pub const ScanSnapshot = struct {
    thumbnails_in_db: bool = false,
    prompt_embeddings: bool = false,
    image_embeddings: bool = false,
};

const DownloadTaskCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_path: []const u8,
    slot: usize,
    status: *std.atomic.Value(u8),
};

fn downloadTask(ctx: DownloadTaskCtx) void {
    defer {
        ctx.allocator.free(ctx.url);
        ctx.allocator.free(ctx.dest_path);
    }
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = &.{ "curl", "-L", "-f", "--create-dirs", "-o", ctx.dest_path, ctx.url },
    }) catch {
        ctx.status.store(3, .release);
        return;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        ctx.status.store(3, .release);
    } else {
        ctx.status.store(2, .release);
    }
}

fn modelFilePickerCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    g_picker_open = false;
    const buf: *[4096:0]u8 = @ptrCast(@alignCast(userdata orelse return));
    const files = filelist orelse return;
    if (files[0] == null) return;
    const path = std.mem.span(files[0].?);
    const len = @min(path.len, 4095);
    @memcpy(buf[0..len], path[0..len]);
    buf[len] = 0;
}

fn pathEntryWithPicker(
    src: std.builtin.SourceLocation,
    buf: *[4096:0]u8,
    placeholder: [:0]const u8,
    id: usize,
) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .margin = .{ .h = 4 },
    });
    defer row.deinit();
    {
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = buf[0..] },
            .placeholder = placeholder,
        }, .{
            .id_extra = id,
            .expand = .horizontal,
            .min_size_content = .{ .h = 22 },
            .corner_radius = dvui.Rect.all(4),
        });
        defer te.deinit();
    }
    if (!g_picker_open and dvui.button(@src(), "...", .{}, .{
        .id_extra = id,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 28, .h = 22 },
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .margin = .{ .x = 4 },
        .corner_radius = dvui.Rect.all(4),
    })) {
        g_picker_open = true;
        const sdl: *SDLBackend = dvui.currentWindow().backend.impl;
        SDLBackend.c.SDL_ShowOpenFileDialog(
            modelFilePickerCallback,
            buf,
            sdl.window,
            &g_gguf_filter,
            1,
            null,
            false,
        );
    }
}

pub const SettingsModalState = struct {
    open: bool = false,
    scan_snapshot: ScanSnapshot = .{},
    model_snapshot: struct {
        model:           [4096:0]u8 = std.mem.zeroes([4096:0]u8),
        mmproj:          [4096:0]u8 = std.mem.zeroes([4096:0]u8),
        reranker:        [4096:0]u8 = std.mem.zeroes([4096:0]u8),
        reranker_mmproj: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    } = .{},
    embedding_model_buf:  [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    embedding_mmproj_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    reranker_model_buf:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    reranker_mmproj_buf:  [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    download_quant_idx: usize = 9,
    download_status: [4]std.atomic.Value(u8) = .{ .init(0), .init(0), .init(0), .init(0) },
    download_group: std.Io.Group = .init,

    pub fn initFromConfig(self: *SettingsModalState, cfg: *const config_mod.Config) void {
        if (cfg.embedding_model_path) |p| {
            const len = @min(p.len, self.embedding_model_buf.len - 1);
            @memcpy(self.embedding_model_buf[0..len], p[0..len]);
            self.embedding_model_buf[len] = 0;
        }
        if (cfg.embedding_mmproj_path) |p| {
            const len = @min(p.len, self.embedding_mmproj_buf.len - 1);
            @memcpy(self.embedding_mmproj_buf[0..len], p[0..len]);
            self.embedding_mmproj_buf[len] = 0;
        }
        if (cfg.reranker_model_path) |p| {
            const len = @min(p.len, self.reranker_model_buf.len - 1);
            @memcpy(self.reranker_model_buf[0..len], p[0..len]);
            self.reranker_model_buf[len] = 0;
        }
        if (cfg.reranker_mmproj_path) |p| {
            const len = @min(p.len, self.reranker_mmproj_buf.len - 1);
            @memcpy(self.reranker_mmproj_buf[0..len], p[0..len]);
            self.reranker_mmproj_buf[len] = 0;
        }
    }

    pub fn awaitDownloads(self: *SettingsModalState, io: std.Io) void {
        self.download_group.await(io) catch {};
    }

    fn spawnDownload(
        self: *SettingsModalState,
        init: std.process.Init,
        slot: usize,
        url: []const u8,
        dest_path: []const u8,
    ) void {
        if (self.download_status[slot].load(.acquire) == 1) return;
        const url_copy = init.gpa.dupe(u8, url) catch return;
        const dest_copy = init.gpa.dupe(u8, dest_path) catch { init.gpa.free(url_copy); return; };
        const ctx = DownloadTaskCtx{
            .allocator = init.gpa,
            .io = init.io,
            .url = url_copy,
            .dest_path = dest_copy,
            .slot = slot,
            .status = &self.download_status[slot],
        };
        self.download_status[slot].store(1, .release);
        self.download_group.concurrent(init.io, downloadTask, .{ctx}) catch |err| {
            log.warn("spawn download task: {}", .{err});
            self.download_status[slot].store(0, .release);
            init.gpa.free(url_copy);
            init.gpa.free(dest_copy);
        };
    }

    pub fn render(
        self: *SettingsModalState,
        cfg: *config_mod.Config,
        db_stats: *?db_mod.DbStats,
        trash_stats: *?db_mod.TrashStats,
        data_dir: ?[]const u8,
        db: ?*db_mod.VectorDb,
        grid: ?*image_grid_mod.GridState,
    ) !void {
        if (!self.open) return;

        const win = dvui.windowRect();
        const margin_x = @max(60, win.w * 0.07);
        const margin_y = @max(40, win.h * 0.07);
        var modal_rect = dvui.Rect{
            .x = margin_x,
            .y = margin_y,
            .w = win.w - 2 * margin_x,
            .h = win.h - 2 * margin_y,
        };
        var float = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &self.open,
            .resize = .none,
            .rect = &modal_rect,
        }, .{
            .min_size_content = .{ .w = 600, .h = 300 },
        });
        defer float.deinit();

        var outer = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(16),
        });
        defer outer.deinit();

        dvui.label(@src(), "{s}", .{i18n.t(.settings_heading)}, .{ .font = bold, .margin = .{ .h = 12 } });

        {
            var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .expand = .both,
                .max_size_content = dvui.Options.MaxSize.height(0),
            });
            defer scroll.deinit();

            var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer cols.deinit();

            // ── Left column ───────────────────────────────────────────────────
            {
                var left_col = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 280 },
                    .padding = .{ .w = 12 },
                });
                defer left_col.deinit();

                dvui.label(@src(), "{s}", .{i18n.t(.settings_scan_section)}, .{ .font = bold, .margin = .{ .h = 8 } });
                _ = dvui.checkbox(@src(), &cfg.thumbnails_in_db, i18n.t(.settings_thumbnails_in_db), .{ .margin = .{ .h = 6 } });
                _ = dvui.checkbox(@src(), &cfg.prompt_embeddings, i18n.t(.settings_prompt_embeddings), .{ .margin = .{ .h = 6 } });
                _ = dvui.checkbox(@src(), &cfg.image_embeddings, i18n.t(.settings_image_embeddings), .{ .margin = .{ .h = 6 } });

                dvui.label(@src(), "{s}", .{i18n.t(.settings_model_path)}, .{ .font = bold, .margin = .{ .y = 12, .h = 4 } });
                pathEntryWithPicker(@src(), &self.embedding_model_buf, i18n.t(.settings_model_placeholder), 0);

                dvui.label(@src(), "{s}", .{i18n.t(.settings_mmproj_path)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
                pathEntryWithPicker(@src(), &self.embedding_mmproj_buf, i18n.t(.settings_mmproj_placeholder), 1);

                dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_section)}, .{ .font = bold, .margin = .{ .y = 16, .h = 4 } });

                dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_model_path)}, .{ .font = bold, .margin = .{ .y = 4, .h = 4 } });
                pathEntryWithPicker(@src(), &self.reranker_model_buf, i18n.t(.settings_reranker_model_placeholder), 2);

                dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_mmproj_path)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
                pathEntryWithPicker(@src(), &self.reranker_mmproj_buf, i18n.t(.settings_reranker_mmproj_placeholder), 3);

                dvui.label(@src(), "{s}", .{i18n.t(.settings_rerank_top_k)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 4 } });
                    defer row.deinit();
                    if (dvui.button(@src(), "-", .{}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 28, .h = 24 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (cfg.rerank_top_k > 1) cfg.rerank_top_k -= 1;
                    }
                    dvui.label(@src(), " {d} ", .{cfg.rerank_top_k}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 44 },
                    });
                    if (dvui.button(@src(), "+", .{}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 28, .h = 24 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (cfg.rerank_top_k < 200) cfg.rerank_top_k += 1;
                    }
                }

                dvui.label(@src(), "{s}", .{i18n.t(.settings_trash_section)}, .{ .font = bold, .margin = .{ .y = 20, .h = 8 } });
                _ = dvui.checkbox(@src(), &cfg.trash_enabled, i18n.t(.settings_trash_enable), .{ .margin = .{ .h = 6 } });
                if (cfg.trash_enabled) {
                    if (trash_stats.*) |ts| {
                        const tb = detail_panel_mod.fmtBytes(ts.total_bytes);
                        var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .expand = .horizontal,
                            .margin = .{ .h = 6 },
                        });
                        defer trash_row.deinit();
                        dvui.label(@src(), "{d} items ({d:.1} {s})", .{ ts.count, tb.value, tb.unit }, .{
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                        });
                        if (dvui.button(@src(), i18n.t(.settings_empty_trash), .{}, .{
                            .gravity_y = 0.5,
                            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                            .corner_radius = dvui.Rect.all(4),
                        })) {
                            if (data_dir) |dd| {
                                if (db) |d| {
                                    if (dvui.App.main_init) |init| {
                                        const names = d.purgeExpiredTrash(init.gpa, std.math.maxInt(i64)) catch &[_][]const u8{};
                                        defer {
                                            for (names) |n| init.gpa.free(n);
                                            init.gpa.free(names);
                                        }
                                        for (names) |trash_name| {
                                            const p = std.fs.path.join(init.gpa, &.{ dd, "trash", trash_name }) catch continue;
                                            defer init.gpa.free(p);
                                            std.Io.Dir.cwd().deleteFile(init.io, p) catch {};
                                        }
                                        trash_stats.* = d.getTrashStats() catch null;
                                        if (grid) |g| {
                                            if (g.view_mode == .trash) g.reloadImages(d) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                dvui.label(@src(), "{s}", .{i18n.t(.settings_data_path)}, .{ .font = bold, .margin = .{ .y = 16, .h = 6 } });
                if (cfg.data_path) |p| {
                    dvui.label(@src(), "{s}", .{p}, .{});
                } else {
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_data_path_default)}, .{});
                }
            }

            // ── Right column ──────────────────────────────────────────────────
            {
                var right_col = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 280 },
                    .padding = .{ .x = 12 },
                });
                defer right_col.deinit();

                dvui.label(@src(), "{s}", .{i18n.t(.settings_database_section)}, .{ .font = bold, .margin = .{ .h = 8 } });
                if (db_stats.*) |stats| {
                    const total = detail_panel_mod.fmtBytes(stats.total_bytes);
                    dvui.label(@src(), "{s}{d:.1} {s}", .{ i18n.t(.settings_db_total_size_label), total.value, total.unit }, .{ .margin = .{ .h = 10 } });

                    const db_label_keys = [_]std.meta.FieldEnum(i18n.Strings){
                        .settings_db_thumbnails_label,
                        .settings_db_prompt_embeddings_label,
                        .settings_db_image_embeddings_label,
                    };
                    const db_rows = [_]struct {
                        count: i64,
                        bytes: i64,
                        clear_fn: *const fn (*db_mod.VectorDb) anyerror!void,
                    }{
                        .{ .count = stats.thumbnail_count,        .bytes = stats.thumbnail_bytes,                   .clear_fn = db_mod.VectorDb.clearThumbnails },
                        .{ .count = stats.prompt_embedding_count, .bytes = stats.prompt_embedding_count * 2048 * 4, .clear_fn = db_mod.VectorDb.clearPromptEmbeddings },
                        .{ .count = stats.image_embedding_count,  .bytes = stats.image_embedding_count * 2048 * 4,  .clear_fn = db_mod.VectorDb.clearImageEmbeddings },
                    };
                    inline for (db_label_keys, db_rows, 0..) |label_key, r, ri| {
                        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = ri,
                            .expand = .horizontal,
                            .margin = .{ .h = 6 },
                        });
                        defer row.deinit();
                        const sz = detail_panel_mod.fmtBytes(r.bytes);
                        dvui.label(@src(), "{s}{d} ({d:.1} {s})", .{ i18n.t(label_key), r.count, sz.value, sz.unit }, .{
                            .id_extra = ri,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                        });
                        if (dvui.button(@src(), i18n.t(.action_clear), .{}, .{
                            .id_extra = ri,
                            .gravity_y = 0.5,
                            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                            .corner_radius = dvui.Rect.all(4),
                        })) {
                            if (db) |d| {
                                r.clear_fn(d) catch {};
                                db_stats.* = d.getStats() catch null;
                            }
                        }
                    }
                } else {
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_db_no_database)}, .{});
                }

                dvui.label(@src(), "{s}", .{i18n.t(.settings_download_section)}, .{ .font = bold, .margin = .{ .y = 20, .h = 8 } });
                if (data_dir) |dd| {
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_download_quantization)}, .{ .font = bold, .margin = .{ .h = 4 } });
                    {
                        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 8 } });
                        defer row.deinit();
                        if (dvui.button(@src(), "◀", .{}, .{
                            .gravity_y = 0.5,
                            .min_size_content = .{ .w = 28, .h = 24 },
                            .corner_radius = dvui.Rect.all(4),
                        })) {
                            if (self.download_quant_idx > 0) self.download_quant_idx -= 1;
                        }
                        dvui.label(@src(), " {s} ", .{download_quant_options[self.download_quant_idx]}, .{
                            .gravity_y = 0.5,
                            .min_size_content = .{ .w = 56 },
                        });
                        if (dvui.button(@src(), "▶", .{}, .{
                            .gravity_y = 0.5,
                            .min_size_content = .{ .w = 28, .h = 24 },
                            .corner_radius = dvui.Rect.all(4),
                        })) {
                            if (self.download_quant_idx + 1 < download_quant_options.len) self.download_quant_idx += 1;
                        }
                    }
                    const quant = download_quant_options[self.download_quant_idx];
                    const dl_labels = [4][:0]const u8{
                        i18n.t(.settings_download_embedding),
                        i18n.t(.settings_download_mmproj),
                        i18n.t(.settings_download_reranker),
                        i18n.t(.settings_download_reranker_mmproj),
                    };
                    for (dl_labels, 0..) |label, fi| {
                        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = fi,
                            .expand = .horizontal,
                            .margin = .{ .h = 5 },
                        });
                        defer row.deinit();
                        dvui.label(@src(), "{s}", .{label}, .{
                            .id_extra = fi,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                        });
                        const status: u8 = self.download_status[fi].load(.acquire);
                        const btn_label: [:0]const u8 = switch (status) {
                            1 => i18n.t(.settings_download_running),
                            2 => i18n.t(.settings_download_done),
                            3 => i18n.t(.settings_download_failed),
                            else => i18n.t(.settings_download_idle),
                        };
                        if (dvui.button(@src(), btn_label, .{}, .{
                            .id_extra = fi,
                            .gravity_y = 0.5,
                            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                            .corner_radius = dvui.Rect.all(4),
                        }) and status == 0) {
                            if (dvui.App.main_init) |init| {
                                const url: []const u8 = switch (fi) {
                                    0 => std.fmt.allocPrint(init.gpa,
                                        "https://huggingface.co/DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF/resolve/main/Qwen.Qwen3-VL-Embedding-2B.{s}.gguf",
                                        .{quant}) catch continue,
                                    1 => init.gpa.dupe(u8,
                                        "https://huggingface.co/DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF/resolve/main/mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf") catch continue,
                                    2 => std.fmt.allocPrint(init.gpa,
                                        "https://huggingface.co/mradermacher/Qwen3-VL-Reranker-2B-GGUF/resolve/main/Qwen3-VL-Reranker-2B.{s}.gguf",
                                        .{quant}) catch continue,
                                    3 => init.gpa.dupe(u8,
                                        "https://huggingface.co/mradermacher/Qwen3-VL-Reranker-2B-GGUF/resolve/main/Qwen3-VL-Reranker-2B.mmproj-f16.gguf") catch continue,
                                    else => continue,
                                };
                                defer init.gpa.free(url);
                                const filename: []const u8 = switch (fi) {
                                    0 => std.fmt.allocPrint(init.gpa, "Qwen.Qwen3-VL-Embedding-2B.{s}.gguf", .{quant}) catch continue,
                                    1 => init.gpa.dupe(u8, "mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf") catch continue,
                                    2 => std.fmt.allocPrint(init.gpa, "Qwen3-VL-Reranker-2B.{s}.gguf", .{quant}) catch continue,
                                    3 => init.gpa.dupe(u8, "Qwen3-VL-Reranker-2B.mmproj-f16.gguf") catch continue,
                                    else => continue,
                                };
                                defer init.gpa.free(filename);
                                const dest = std.fs.path.join(init.gpa, &.{ dd, "models", "search", filename }) catch continue;
                                defer init.gpa.free(dest);
                                self.spawnDownload(init, fi, url, dest);
                            }
                        }
                    }
                } else {
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_db_no_database)}, .{});
                }
            }
        }

        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .margin = .{ .y = 12 } });
            defer btn_row.deinit();
            if (dvui.button(@src(), i18n.t(.action_close), .{}, .{ .margin = .all(4) })) {
                self.open = false;
            }
        }
    }

    pub fn applyCompletedDownloads(self: *SettingsModalState, cfg: *config_mod.Config, data_dir: ?[]const u8) void {
        const init = dvui.App.main_init orelse return;
        const dd = data_dir orelse return;
        const slots = [_]struct { slot: usize, cfg_field: enum { emb, mmproj, rr, rr_mmproj } }{
            .{ .slot = 0, .cfg_field = .emb },
            .{ .slot = 1, .cfg_field = .mmproj },
            .{ .slot = 2, .cfg_field = .rr },
            .{ .slot = 3, .cfg_field = .rr_mmproj },
        };
        const quant = download_quant_options[self.download_quant_idx];
        for (slots) |s| {
            if (self.download_status[s.slot].load(.acquire) == 2) {
                const filename: []const u8 = switch (s.cfg_field) {
                    .emb       => std.fmt.allocPrint(init.gpa, "Qwen.Qwen3-VL-Embedding-2B.{s}.gguf", .{quant}) catch continue,
                    .mmproj    => init.gpa.dupe(u8, "mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf") catch continue,
                    .rr        => std.fmt.allocPrint(init.gpa, "Qwen3-VL-Reranker-2B.{s}.gguf", .{quant}) catch continue,
                    .rr_mmproj => init.gpa.dupe(u8, "Qwen3-VL-Reranker-2B.mmproj-f16.gguf") catch continue,
                };
                defer init.gpa.free(filename);
                const dest = std.fs.path.join(init.gpa, &.{ dd, "models", "search", filename }) catch continue;
                defer init.gpa.free(dest);
                switch (s.cfg_field) {
                    .emb => if (cfg.embedding_model_path == null) {
                        cfg.embedding_model_path = init.gpa.dupe(u8, dest) catch null;
                        const len = @min(dest.len, self.embedding_model_buf.len - 1);
                        @memcpy(self.embedding_model_buf[0..len], dest[0..len]);
                        self.embedding_model_buf[len] = 0;
                    },
                    .mmproj => if (cfg.embedding_mmproj_path == null) {
                        cfg.embedding_mmproj_path = init.gpa.dupe(u8, dest) catch null;
                        const len = @min(dest.len, self.embedding_mmproj_buf.len - 1);
                        @memcpy(self.embedding_mmproj_buf[0..len], dest[0..len]);
                        self.embedding_mmproj_buf[len] = 0;
                    },
                    .rr => if (cfg.reranker_model_path == null) {
                        cfg.reranker_model_path = init.gpa.dupe(u8, dest) catch null;
                        const len = @min(dest.len, self.reranker_model_buf.len - 1);
                        @memcpy(self.reranker_model_buf[0..len], dest[0..len]);
                        self.reranker_model_buf[len] = 0;
                    },
                    .rr_mmproj => if (cfg.reranker_mmproj_path == null) {
                        cfg.reranker_mmproj_path = init.gpa.dupe(u8, dest) catch null;
                        const len = @min(dest.len, self.reranker_mmproj_buf.len - 1);
                        @memcpy(self.reranker_mmproj_buf[0..len], dest[0..len]);
                        self.reranker_mmproj_buf[len] = 0;
                    },
                }
            }
        }
    }

    pub fn onClosed(
        self: *SettingsModalState,
        cfg: *config_mod.Config,
        library_manager: *?library_manager_mod.LibraryManager,
        search: *search_mod.SearchState,
    ) void {
        var need_rescan = false;

        const changed = cfg.thumbnails_in_db != self.scan_snapshot.thumbnails_in_db or
            cfg.prompt_embeddings != self.scan_snapshot.prompt_embeddings or
            cfg.image_embeddings != self.scan_snapshot.image_embeddings;
        if (changed) {
            if (library_manager.*) |*mgr| {
                mgr.thumbnails_in_db = cfg.thumbnails_in_db;
                mgr.prompt_embeddings = cfg.prompt_embeddings;
                mgr.image_embeddings = cfg.image_embeddings;
            }
            need_rescan = true;
        }

        const model_changed = !std.mem.eql(u8, &self.embedding_model_buf, &self.model_snapshot.model) or
            !std.mem.eql(u8, &self.embedding_mmproj_buf, &self.model_snapshot.mmproj);
        if (model_changed) {
            if (dvui.App.main_init) |init| {
                if (cfg.embedding_model_path) |p| init.gpa.free(p);
                const model_str = std.mem.sliceTo(&self.embedding_model_buf, 0);
                cfg.embedding_model_path = if (model_str.len > 0) init.gpa.dupe(u8, model_str) catch null else null;
                if (cfg.embedding_mmproj_path) |p| init.gpa.free(p);
                const mmproj_str = std.mem.sliceTo(&self.embedding_mmproj_buf, 0);
                cfg.embedding_mmproj_path = if (mmproj_str.len > 0) init.gpa.dupe(u8, mmproj_str) catch null else null;
                if (library_manager.*) |*mgr| {
                    mgr.embedding_model_path = cfg.embedding_model_path;
                    mgr.embedding_mmproj_path = cfg.embedding_mmproj_path;
                    mgr.vl_ctx_initialized.store(false, .release);
                    if (mgr.text_pool) |*tp| { tp.deinit(); mgr.text_pool = null; }
                }
                if (search.vl_ctx) |*vc| { vc.deinit(); search.vl_ctx = null; }
                if (search.text_pool) |*tp| { tp.deinit(); search.text_pool = null; }
            }
            if (cfg.prompt_embeddings or cfg.image_embeddings) need_rescan = true;
        }

        const reranker_changed = !std.mem.eql(u8, &self.reranker_model_buf, &self.model_snapshot.reranker) or
            !std.mem.eql(u8, &self.reranker_mmproj_buf, &self.model_snapshot.reranker_mmproj);
        if (reranker_changed) {
            if (dvui.App.main_init) |init| {
                if (cfg.reranker_model_path) |p| init.gpa.free(p);
                const rr_str = std.mem.sliceTo(&self.reranker_model_buf, 0);
                cfg.reranker_model_path = if (rr_str.len > 0) init.gpa.dupe(u8, rr_str) catch null else null;
                if (cfg.reranker_mmproj_path) |p| init.gpa.free(p);
                const rr_mmproj_str = std.mem.sliceTo(&self.reranker_mmproj_buf, 0);
                cfg.reranker_mmproj_path = if (rr_mmproj_str.len > 0) init.gpa.dupe(u8, rr_mmproj_str) catch null else null;
                if (search.reranker) |*rr| { rr.deinit(); search.reranker = null; }
            }
        }

        if (need_rescan) {
            if (library_manager.*) |*mgr| {
                if (dvui.App.main_init) |init| {
                    mgr.scanAllLibraries(init.io) catch |err| {
                        std.log.warn("rescan after config change: {}", .{err});
                    };
                }
            }
        }
    }
};
