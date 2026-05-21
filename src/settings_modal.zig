const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const detail_panel_mod = @import("detail_panel.zig");
const library_manager_mod = @import("library_manager.zig");
const search_mod = @import("search.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });
const log = std.log.scoped(.settings);

pub const ScanSnapshot = struct {
    thumbnails_in_db: bool = false,
    prompt_embeddings: bool = false,
    image_embeddings: bool = false,
};

pub const SettingsModalState = struct {
    open: bool = false,
    scan_snapshot: ScanSnapshot = .{},
    model_snapshot: struct {
        text_dir:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
        visual_dir: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    } = .{},
    text_model_dir_buf:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    visual_model_dir_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    /// Set to true by onClosed() when model paths changed; cleared by app.zig.
    model_paths_changed: bool = false,

    pub fn initFromConfig(self: *SettingsModalState, cfg: *const config_mod.Config) void {
        if (cfg.text_model_dir) |p| {
            const len = @min(p.len, self.text_model_dir_buf.len - 1);
            @memcpy(self.text_model_dir_buf[0..len], p[0..len]);
            self.text_model_dir_buf[len] = 0;
        }
        if (cfg.visual_model_dir) |p| {
            const len = @min(p.len, self.visual_model_dir_buf.len - 1);
            @memcpy(self.visual_model_dir_buf[0..len], p[0..len]);
            self.visual_model_dir_buf[len] = 0;
        }
    }

    pub fn awaitDownloads(self: *SettingsModalState, io: std.Io) void {
        _ = self;
        _ = io;
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
                {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = self.text_model_dir_buf[0..] },
                        .placeholder = i18n.t(.settings_model_placeholder),
                    }, .{
                        .expand = .horizontal,
                        .min_size_content = .{ .h = 22 },
                        .corner_radius = dvui.Rect.all(4),
                        .margin = .{ .h = 4 },
                    });
                    defer te.deinit();
                }

                dvui.label(@src(), "{s}", .{i18n.t(.settings_mmproj_path)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
                {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = self.visual_model_dir_buf[0..] },
                        .placeholder = i18n.t(.settings_mmproj_placeholder),
                    }, .{
                        .expand = .horizontal,
                        .min_size_content = .{ .h = 22 },
                        .corner_radius = dvui.Rect.all(4),
                        .margin = .{ .h = 4 },
                    });
                    defer te.deinit();
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
                        .{ .count = stats.prompt_embedding_count, .bytes = stats.prompt_embedding_count * 768 * 4,  .clear_fn = db_mod.VectorDb.clearPromptEmbeddings },
                        .{ .count = stats.image_embedding_count,  .bytes = stats.image_embedding_count * 768 * 4,   .clear_fn = db_mod.VectorDb.clearImageEmbeddings },
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
        _ = self;
        _ = cfg;
        _ = data_dir;
    }

    pub fn onClosed(
        self: *SettingsModalState,
        cfg: *config_mod.Config,
        library_manager: *?library_manager_mod.LibraryManager,
        search: *search_mod.SearchState,
    ) void {
        _ = search;
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

        const model_changed =
            !std.mem.eql(u8, &self.text_model_dir_buf, &self.model_snapshot.text_dir) or
            !std.mem.eql(u8, &self.visual_model_dir_buf, &self.model_snapshot.visual_dir);
        if (model_changed) {
            if (dvui.App.main_init) |init| {
                if (cfg.text_model_dir) |p| init.gpa.free(p);
                const text_str = std.mem.sliceTo(&self.text_model_dir_buf, 0);
                cfg.text_model_dir = if (text_str.len > 0) init.gpa.dupe(u8, text_str) catch null else null;
                if (cfg.visual_model_dir) |p| init.gpa.free(p);
                const visual_str = std.mem.sliceTo(&self.visual_model_dir_buf, 0);
                cfg.visual_model_dir = if (visual_str.len > 0) init.gpa.dupe(u8, visual_str) catch null else null;
            }
            self.model_paths_changed = true;
            if (cfg.prompt_embeddings or cfg.image_embeddings) need_rescan = true;
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
