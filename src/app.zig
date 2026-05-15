const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const library_manager_mod = @import("library_manager.zig");
const image_grid_mod = @import("image_grid.zig");
const vips_mod = @import("vips");
const SDLBackend = @import("backend");

const noto_cjk_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
const noto_cjk_bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

// Path to the config file: set from --config/-c flag, otherwise resolved from known folders.
var g_config: ?[]const u8 = null;
var g_cfg: config_mod.Config = .{};
var g_db: ?db_mod.VectorDb = null;
// Directory that contains the DB file — also used as root for the trash folder.
var g_data_dir: ?[]const u8 = null;

var g_library_manager: ?library_manager_mod.LibraryManager = null;
var g_grid: ?image_grid_mod.GridState = null;
var g_wakeup_event_type: u32 = 0;

fn wakeupFrame() void {
    var ev: SDLBackend.c.SDL_Event = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ev.type = g_wakeup_event_type;
    _ = SDLBackend.c.SDL_PushEvent(&ev);
}
var g_library_dialog_open: bool = false;
var g_settings_open: bool = false;
var g_db_stats: ?db_mod.DbStats = null;
var g_trash_stats: ?db_mod.TrashStats = null;

// Delete confirmation dialog state
var g_skip_delete_confirm: bool = false;           // don't ask again for single soft-delete
var g_skip_permanent_delete_confirm: bool = false; // don't ask again for single permanent delete
var g_delete_dialog_open: bool = false;
var g_delete_dialog_force: bool = false;  // permanent delete (skip trash)
var g_delete_dialog_count: usize = 0;
var g_delete_dialog_name_buf: [512]u8 = undefined;
var g_delete_dialog_name_len: usize = 0;
const ScanSnapshot = struct { thumbnails_in_db: bool = false, prompt_embeddings: bool = false, image_embeddings: bool = false };
var g_settings_scan_snapshot: ScanSnapshot = .{};
var g_pending_library_buf: [4096]u8 = undefined;
var g_pending_library_len: usize = 0;
var g_libraries: std.ArrayList([]const u8) = .empty;
var g_confirm_remove_idx: ?usize = null;

fn libraryFolderCallback(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    g_library_dialog_open = false;
    const files = filelist orelse return;
    if (files[0] == null) return;
    const path = std.mem.span(files[0].?);
    const len = @min(path.len, g_pending_library_buf.len);
    @memcpy(g_pending_library_buf[0..len], path[0..len]);
    g_pending_library_len = len;
}

// Panel widths in logical pixels.  _open stores the last non-collapsed width.
var g_left_w: f32 = 240;
var g_left_w_open: f32 = 240;
var g_right_w: f32 = 300;
var g_right_w_open: f32 = 300;

const left_w_min: f32 = 160;
const left_w_max: f32 = 400;
const right_w_min: f32 = 220;
const right_w_max: f32 = 480;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = appStart },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = frame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

fn appStart() dvui.App.StartOptions {
    if (dvui.App.main_init) |init| {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.skip(); // skip argv[0] (executable path)
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                if (it.next()) |val| {
                    g_config = std.fs.path.join(init.gpa, &.{ val, "DiffKeep.cfg" }) catch null;
                }
            }
        }
    }

    return .{
        .size = .{ .w = 1200.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .title = "DiffKeep",
        .vsync = true,
    };
}

fn appInit(win: *dvui.Window) !void {
    _ = win;

    if (dvui.App.main_init) |init| {
        if (g_config == null) {
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .local_configuration)) |config_dir| {
                defer init.gpa.free(config_dir);
                g_config = try std.fs.path.join(init.gpa, &.{ config_dir, "DiffKeep", "DiffKeep.cfg"});
            }
        }

        if (g_config) |cfg_path| {
            g_cfg = try config_mod.load(init.gpa, init.io, cfg_path);
        }

        const db_path = blk: {
            if (g_cfg.data_path) |p| {
                break :blk try init.gpa.dupe(u8, p);
            }
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) |data_base| {
                defer init.gpa.free(data_base);
                var data_dir = try std.Io.Dir.openDirAbsolute(init.io, data_base, .{});
                defer data_dir.close(init.io);
                try data_dir.createDirPath(init.io, "DiffKeep");
                break :blk try std.fs.path.join(init.gpa, &.{ data_base, "DiffKeep", "diffkeep.db" });
            }
            break :blk null;
        };
        if (db_path) |p| {
            defer init.gpa.free(p);
            if (std.fs.path.dirname(p)) |dir| {
                g_data_dir = try init.gpa.dupe(u8, dir);
            }
            g_db = try db_mod.VectorDb.init(init.gpa, init.io, p);
        }

        // Ensure trash directory exists and purge entries older than 30 days.
        if (g_data_dir) |data_dir| {
            var dd = try std.Io.Dir.openDirAbsolute(init.io, data_dir, .{});
            defer dd.close(init.io);
            dd.createDirPath(init.io, "trash") catch {};

            if (g_db) |*db| {
                const now_s: i64 = @intCast(@divTrunc(
                    std.Io.Clock.real.now(init.io).nanoseconds, std.time.ns_per_s,
                ));
                const cutoff = now_s - 30 * 24 * 60 * 60;
                const expired = db.purgeExpiredTrash(init.gpa, cutoff) catch &[_][]const u8{};
                defer {
                    for (expired) |n| init.gpa.free(n);
                    init.gpa.free(expired);
                }
                for (expired) |trash_name| {
                    const trash_path = std.fs.path.join(
                        init.gpa, &.{ data_dir, "trash", trash_name },
                    ) catch continue;
                    defer init.gpa.free(trash_path);
                    std.Io.Dir.cwd().deleteFile(init.io, trash_path) catch {};
                }
            }
        }

        // VIPS must be initialized before any worker threads start calling vips_thumbnail.
        try vips_mod.init();

        if (g_db) |*db| {
            const paths = db.listLibraries(init.gpa) catch &[_][]const u8{};
            defer init.gpa.free(paths);
            try g_libraries.appendSlice(init.gpa, paths);

            // Register a custom SDL event so the worker thread can wake the render loop
            // when a thumbnail is ready (dvui only renders on input otherwise).
            g_wakeup_event_type = SDLBackend.c.SDL_RegisterEvents(1);

            // Init grid before library manager so we can pass the notifier pointer.
            // Grid must be at its final global address before startWorker() is called.
            g_grid = try image_grid_mod.GridState.init(init.io, init.gpa, db, g_cfg.thumbnails_in_db, wakeupFrame);
            if (g_grid) |*grid| try grid.startWorker();

            // Assign to global BEFORE calling scanAllLibraries so that enqueue()'s
            // concurrent task receives &g_library_manager.? (stable global address)
            // rather than a pointer to a stack-local that becomes dangling after appInit returns.
            const notifier = if (g_grid) |*grid| &grid.notifier else null;
            g_library_manager = library_manager_mod.LibraryManager.init(init.gpa, db, g_cfg.thumbnails_in_db, g_cfg.prompt_embeddings, g_cfg.image_embeddings, notifier);
            if (g_library_manager) |*mgr| {
                mgr.scanAllLibraries(init.io) catch |err| {
                    std.log.warn("startup scan queue failed: {}", .{err});
                };
            }
        }
    } else {
        try vips_mod.init();
    }

    std.log.info("DiffKeep {s} — config: {s}", .{
        build_options.version,
        g_config orelse "(none)",
    });

    try dvui.addFont("NotoSansCJK", noto_cjk_bytes, null);
    try dvui.addFont("NotoSansCJKBold", noto_cjk_bold_bytes, null);

    var theme = dvui.themeGet();
    theme.font_body = theme.font_body.withFamily("NotoSansCJK");
    theme.font_title = theme.font_title.withFamily("NotoSansCJKBold");
    theme.font_mono = theme.font_mono.withFamily("NotoSansCJK");
    dvui.themeSet(theme);
}

fn appDeinit() void {
    // Stop all threads that use VIPS before calling vips_shutdown().
    if (dvui.App.main_init) |init| {
        if (g_library_manager) |*mgr| mgr.deinit(init.io);
    }
    if (g_grid) |*grid| grid.deinit();
    vips_mod.deinit();
    if (g_db) |*database| {
        database.deinit();
        database.pool.deinit();
    }
    if (dvui.App.main_init) |init| {
        if (g_config) |cfg_path| {
            config_mod.save(g_cfg, init.io, cfg_path) catch |err| {
                std.log.warn("failed to save config: {}", .{err});
            };
            init.gpa.free(cfg_path);
        }
        g_cfg.deinit(init.gpa);
        for (g_libraries.items) |p| init.gpa.free(p);
        g_libraries.deinit(init.gpa);
        if (g_data_dir) |d| init.gpa.free(d);
    }
}

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

// Drag handle between two panels.  Click to collapse/expand; drag to resize.
// `side` indicates which panel the handle controls (its width grows left for
// .left, right for .right).  Width values are in logical pixels.
fn panelHandle(
    src: std.builtin.SourceLocation,
    comptime side: enum { left, right },
    width: *f32,
    width_open: *f32,
    w_min: f32,
    w_max: f32,
) void {
    var h = dvui.box(src, .{}, .{
        .min_size_content = .{ .w = 10, .h = 0 },
        .expand = .vertical,
        .background = true,
    });
    defer h.deinit();

    const id = h.data().id;
    const scale = h.data().contentRectScale().s;

    // Apply any running collapse/expand animation.
    if (dvui.animationGet(id, "_w")) |anim| {
        width.* = anim.value();
    }

    const collapsed = width.* < 2;
    var is_hovered = dvui.dataGet(null, id, "_hov", bool) orelse false;
    var dragged = dvui.dataGet(null, id, "_drag", bool) orelse false;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .position => {
                is_hovered = dvui.eventMatchSimple(e, h.data());
                if (is_hovered) dvui.cursorSet(.arrow_w_e);
            },
            .press => {
                if (me.button.pointer() and dvui.eventMatchSimple(e, h.data())) {
                    e.handle(@src(), h.data());
                    dvui.captureMouse(h.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .cursor = .arrow_w_e });
                    dragged = false;
                }
            },
            .motion => |delta| {
                if (dvui.captured(id)) {
                    if (dvui.dragging(me.p, null) != null) {
                        const dx: f32 = switch (side) {
                            .left => delta.x,
                            .right => -delta.x,
                        };
                        width.* = std.math.clamp(width.* + dx / scale, w_min, w_max);
                        width_open.* = width.*;
                        dragged = true;
                    }
                }
            },
            .release => {
                if (dvui.captured(id)) {
                    dvui.captureMouse(null, e.num);
                    if (!dragged) {
                        if (collapsed) {
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = @max(width_open.*, w_min),
                                .end_time = 200_000,
                                .easing = dvui.easing.outQuad,
                            });
                        } else {
                            width_open.* = width.*;
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = 0,
                                .end_time = 150_000,
                                .easing = dvui.easing.outQuad,
                            });
                        }
                    }
                    dragged = false;
                }
            },
            else => {},
        }
    }

    dvui.dataSet(null, id, "_hov", is_hovered);
    dvui.dataSet(null, id, "_drag", dragged);

    {
        const ch: []const u8 = switch (side) {
            .left => if (collapsed) "›" else "‹",
            .right => if (collapsed) "‹" else "›",
        };
        dvui.label(@src(), "{s}", .{ch}, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .expand = .both,
        });
    }

    const tip: []const u8 = if (collapsed) "Click to expand" else "Click to collapse · Drag to resize";
    dvui.tooltip(@src(), .{ .active_rect = h.data().rectScale().r, .delay = 500_000 }, "{s}", .{tip}, .{});
}

const BytesFmt = struct { value: f64, unit: []const u8 };

fn fmtBytes(bytes: i64) BytesFmt {
    const b: f64 = @floatFromInt(if (bytes < 0) 0 else bytes);
    if (b >= 1024 * 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0 * 1024.0), .unit = "GB" };
    if (b >= 1024 * 1024) return .{ .value = b / (1024.0 * 1024.0), .unit = "MB" };
    if (b >= 1024) return .{ .value = b / 1024.0, .unit = "KB" };
    return .{ .value = b, .unit = "B" };
}

const log = std.log.scoped(.app);

/// Attempt an atomic rename; falls back to copy+delete on cross-device moves.
fn moveFile(io: std.Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var cross_device = false;
    std.Io.Dir.rename(cwd, src, cwd, dst, io) catch |err| switch (err) {
        error.CrossDevice => cross_device = true,
        else => return err,
    };
    if (!cross_device) return; // rename succeeded — done
    // Rename returned CrossDevice — fall back to copy + delete.
    {
        var src_file = try std.Io.Dir.cwd().openFile(io, src, .{});
        defer src_file.close(io);
        const size = try src_file.length(io);
        const buf = try allocator.alloc(u8, size);
        defer allocator.free(buf);
        _ = try src_file.readPositionalAll(io, buf, 0);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = buf });
    }
    try std.Io.Dir.cwd().deleteFile(io, src);
}

/// IDs to act on: the selection set when non-empty, otherwise just the focused item.
fn effectiveIds(grid: *const image_grid_mod.GridState, allocator: std.mem.Allocator) !std.AutoHashMap(u64, void) {
    var ids = std.AutoHashMap(u64, void).init(allocator);
    errdefer ids.deinit();
    if (grid.selection.count() > 0) {
        var it = grid.selection.keyIterator();
        while (it.next()) |id| try ids.put(id.*, {});
    } else if (grid.focused_idx) |fi| {
        if (fi < grid.images.items.len)
            try ids.put(grid.images.items[fi].id, {});
    }
    return ids;
}

/// Remove items with the given IDs from the grid's image list and selection.
fn removeFromGrid(grid: *image_grid_mod.GridState, ids: *const std.AutoHashMap(u64, void)) void {
    var i: usize = 0;
    while (i < grid.images.items.len) {
        const e = grid.images.items[i];
        if (ids.contains(e.id)) {
            _ = grid.images.orderedRemove(i);
            _ = grid.selection.remove(e.id);
            grid.allocator.free(e.path);
            if (e.trash_name) |tn| grid.allocator.free(tn);
        } else {
            i += 1;
        }
    }
    if (grid.focused_idx) |fi| {
        if (grid.images.items.len == 0) grid.focused_idx = null
        else if (fi >= grid.images.items.len) grid.focused_idx = grid.images.items.len - 1;
    }
}

/// Move selected images to the trash folder and mark them in the DB.
fn performTrash(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const data_dir = g_data_dir orelse return;
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    const now_s: i64 = @intCast(@divTrunc(
        std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s,
    ));

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;

        // Get file size
        var file_size: i64 = 0;
        if (std.Io.Dir.cwd().openFile(io, entry.path, .{})) |f| {
            if (f.length(io)) |len| file_size = @intCast(len) else |_| {}
            f.close(io);
        } else |_| {}

        // Use "{id}_{basename}" as the trash filename to guarantee uniqueness.
        const basename = std.fs.path.basename(entry.path);
        var name_buf: [768]u8 = undefined;
        const trash_name = std.fmt.bufPrint(&name_buf, "{d}_{s}", .{ entry.id, basename }) catch continue;

        const dst = std.fs.path.join(allocator, &.{ data_dir, "trash", trash_name }) catch continue;
        defer allocator.free(dst);

        moveFile(io, allocator, entry.path, dst) catch |err| {
            log.warn("trash {s}: {}", .{ basename, err });
            continue;
        };

        if (g_db) |*db| {
            db.trashImage(entry.id, trash_name, file_size, now_s) catch |err| {
                log.warn("trashImage {d}: {}", .{ entry.id, err });
            };
        }
    }

    removeFromGrid(grid, &ids);
}

/// Permanently delete selected images from disk and DB.
fn performDelete(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const data_dir = g_data_dir orelse "";
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;

        // Determine where the file currently lives (trash vs library).
        const file_path: []const u8 = if (entry.trash_name) |tn| blk: {
            break :blk std.fs.path.join(allocator, &.{ data_dir, "trash", tn }) catch continue;
        } else entry.path;
        defer if (entry.trash_name != null) allocator.free(file_path);

        std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| {
            log.warn("delete {s}: {}", .{ entry.filename, err });
        };

        if (g_db) |*db| {
            db.deleteImage(entry.id) catch |err| {
                log.warn("deleteImage {d}: {}", .{ entry.id, err });
            };
        }
    }

    removeFromGrid(grid, &ids);
}

/// Restore selected trash items back to their original library paths.
fn performRestore(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const data_dir = g_data_dir orelse return;
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;
        const trash_name = entry.trash_name orelse continue;

        const src = std.fs.path.join(allocator, &.{ data_dir, "trash", trash_name }) catch continue;
        defer allocator.free(src);

        moveFile(io, allocator, src, entry.path) catch |err| {
            log.warn("restore {s}: {}", .{ entry.filename, err });
            continue;
        };

        if (g_db) |*db| {
            db.restoreImage(entry.id) catch |err| {
                log.warn("restoreImage {d}: {}", .{ entry.id, err });
            };
        }
    }

    removeFromGrid(grid, &ids);
}

/// Open the delete confirmation dialog for the current grid selection.
fn openDeleteDialog(grid: *const image_grid_mod.GridState, force: bool) void {
    var count: usize = grid.selection.count();
    if (count == 0) {
        if (grid.focused_idx) |fi| {
            if (fi < grid.images.items.len) count = 1;
        }
    }
    if (count == 0) return;

    g_delete_dialog_count = count;
    g_delete_dialog_force = force;

    // Snapshot the filename for the single-file label.
    if (count == 1) {
        const name: []const u8 = if (grid.selection.count() > 0) blk: {
            var it = grid.selection.keyIterator();
            const id = it.next().?.*;
            for (grid.images.items) |e| {
                if (e.id == id) break :blk e.filename;
            }
            break :blk "";
        } else if (grid.focused_idx) |fi|
            grid.images.items[fi].filename
        else
            "";
        const len = @min(name.len, g_delete_dialog_name_buf.len);
        @memcpy(g_delete_dialog_name_buf[0..len], name[0..len]);
        g_delete_dialog_name_len = len;
    }

    const permanent = force or !g_cfg.trash_enabled;
    if (count == 1) {
        if (!permanent and g_skip_delete_confirm) {
            if (g_grid) |*grid_mut| {
                if (dvui.App.main_init) |init| performTrash(init.io, init.gpa, grid_mut);
            }
            return;
        }
        if (permanent and g_skip_permanent_delete_confirm) {
            if (g_grid) |*grid_mut| {
                if (dvui.App.main_init) |init| performDelete(init.io, init.gpa, grid_mut);
            }
            return;
        }
    }

    g_delete_dialog_open = true;
}

fn settingsModal() !void {
    var float = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &g_settings_open,
        .resize = .none,
    }, .{
        .min_size_content = .{ .w = 560, .h = 0 },
    });
    defer float.deinit();
    float.autoSize();
    float.dragAreaSet(dvui.Rect.Physical{});

    var content = dvui.box(@src(), .{}, .{
        .expand = .both,
        .padding = .all(16),
    });
    defer content.deinit();

    dvui.label(@src(), "Settings", .{}, .{ .font = bold, .margin = .{ .h = 12 } });

    {
        var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer cols.deinit();

        // ── Left column: config toggles ───────────────────────────────────
        {
            var left = dvui.box(@src(), .{}, .{
                .expand = .both,
                .min_size_content = .{ .w = 240, .h = 0 },
                .padding = .{ .w = 16 },
            });
            defer left.deinit();

            dvui.label(@src(), "Scan", .{}, .{ .font = bold, .margin = .{ .h = 8 } });
            _ = dvui.checkbox(@src(), &g_cfg.thumbnails_in_db, "Store thumbnails in database", .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.prompt_embeddings, "Generate prompt embeddings", .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.image_embeddings, "Generate image embeddings", .{ .margin = .{ .h = 6 } });

            dvui.label(@src(), "Trash", .{}, .{ .font = bold, .margin = .{ .y = 16, .h = 8 } });
            _ = dvui.checkbox(@src(), &g_cfg.trash_enabled, "Enable trash (30-day auto-purge)", .{ .margin = .{ .h = 6 } });
            if (g_cfg.trash_enabled) {
                if (g_trash_stats) |ts| {
                    const tb = fmtBytes(ts.total_bytes);
                    var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer trash_row.deinit();
                    dvui.label(@src(), "{d} items ({d:.1} {s})", .{ ts.count, tb.value, tb.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), "Empty Trash", .{}, .{
                        .gravity_y = 0.5,
                        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_data_dir) |data_dir| {
                            if (g_db) |*db| {
                                if (dvui.App.main_init) |init| {
                                    const names = db.purgeExpiredTrash(init.gpa, std.math.maxInt(i64)) catch &[_][]const u8{};
                                    defer {
                                        for (names) |n| init.gpa.free(n);
                                        init.gpa.free(names);
                                    }
                                    for (names) |trash_name| {
                                        const p = std.fs.path.join(init.gpa, &.{ data_dir, "trash", trash_name }) catch continue;
                                        defer init.gpa.free(p);
                                        std.Io.Dir.cwd().deleteFile(init.io, p) catch {};
                                    }
                                    g_trash_stats = db.getTrashStats() catch null;
                                    // If grid is in trash view, reload it
                                    if (g_grid) |*grid| {
                                        if (grid.view_mode == .trash)
                                            grid.reloadImages(db) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            }

            dvui.label(@src(), "Data path", .{}, .{ .font = bold, .margin = .{ .y = 16, .h = 6 } });
            if (g_cfg.data_path) |p| {
                dvui.label(@src(), "{s}", .{p}, .{});
            } else {
                dvui.label(@src(), "(default XDG data directory)", .{}, .{});
            }
        }

        // ── Right column: DB overview ─────────────────────────────────────
        {
            var right = dvui.box(@src(), .{}, .{
                .expand = .both,
                .min_size_content = .{ .w = 240, .h = 0 },
                .padding = .{ .x = 16 },
            });
            defer right.deinit();

            dvui.label(@src(), "Database", .{}, .{ .font = bold, .margin = .{ .h = 8 } });

            if (g_db_stats) |stats| {
                const total = fmtBytes(stats.total_bytes);
                dvui.label(@src(), "Total size: {d:.1} {s}", .{ total.value, total.unit }, .{ .margin = .{ .h = 10 } });

                // Thumbnails
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer row.deinit();
                    const tb = fmtBytes(stats.thumbnail_bytes);
                    dvui.label(@src(), "Thumbnails: {d} ({d:.1} {s})", .{ stats.thumbnail_count, tb.value, tb.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), "Clear", .{}, .{
                        .gravity_y = 0.5,
                        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_db) |*db| {
                            db.clearThumbnails() catch {};
                            g_db_stats = db.getStats() catch null;
                        }
                    }
                }

                // Prompt embeddings
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer row.deinit();
                    const pe = fmtBytes(stats.prompt_embedding_count * 2048 * 4);
                    dvui.label(@src(), "Prompt embeddings: {d} ({d:.1} {s})", .{ stats.prompt_embedding_count, pe.value, pe.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), "Clear", .{}, .{
                        .gravity_y = 0.5,
                        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_db) |*db| {
                            db.clearPromptEmbeddings() catch {};
                            g_db_stats = db.getStats() catch null;
                        }
                    }
                }

                // Image embeddings
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer row.deinit();
                    const ie = fmtBytes(stats.image_embedding_count * 2048 * 4);
                    dvui.label(@src(), "Image embeddings: {d} ({d:.1} {s})", .{ stats.image_embedding_count, ie.value, ie.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), "Clear", .{}, .{
                        .gravity_y = 0.5,
                        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_db) |*db| {
                            db.clearImageEmbeddings() catch {};
                            g_db_stats = db.getStats() catch null;
                        }
                    }
                }
            } else {
                dvui.label(@src(), "(no database)", .{}, .{});
            }
        }
    }

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .margin = .{ .y = 12 } });
        defer btn_row.deinit();
        if (dvui.button(@src(), "Close", .{}, .{ .margin = .all(4) })) {
            g_settings_open = false;
        }
    }
}

fn deleteConfirmDialog() !void {
    var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .min_size_content = .{ .w = 360, .h = 0 },
    });
    defer float.deinit();
    float.autoSize();

    var content = dvui.box(@src(), .{}, .{
        .expand = .both,
        .padding = .all(16),
    });
    defer content.deinit();

    const permanent = g_delete_dialog_force or !g_cfg.trash_enabled;
    const title: []const u8 = if (permanent) "Delete permanently?" else "Move to Trash?";
    dvui.label(@src(), "{s}", .{title}, .{ .font = bold, .margin = .{ .h = 8 } });

    if (g_delete_dialog_count == 1) {
        const name = g_delete_dialog_name_buf[0..g_delete_dialog_name_len];
        dvui.label(@src(), "{s}", .{name}, .{ .margin = .{ .h = 12 } });
    } else {
        dvui.label(@src(), "{d} files selected", .{g_delete_dialog_count}, .{ .margin = .{ .h = 12 } });
    }

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
    defer btn_row.deinit();

    if (dvui.button(@src(), "Cancel", .{}, .{ .margin = .all(4) })) {
        g_delete_dialog_open = false;
    }

    if (g_delete_dialog_count == 1) {
        const skip_label: []const u8 = if (permanent)
            "Delete, don't ask again"
        else
            "Move to Trash, don't ask again";
        if (dvui.button(@src(), skip_label, .{}, .{ .margin = .all(4) })) {
            g_delete_dialog_open = false;
            if (permanent) g_skip_permanent_delete_confirm = true
            else           g_skip_delete_confirm = true;
            if (g_grid) |*grid| {
                if (dvui.App.main_init) |init| {
                    if (permanent) performDelete(init.io, init.gpa, grid)
                    else           performTrash(init.io, init.gpa, grid);
                }
            }
        }
    }

    const confirm_label: []const u8 = if (permanent) "Delete" else "Move to Trash";
    if (dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4) })) {
        g_delete_dialog_open = false;
        if (g_grid) |*grid| {
            if (dvui.App.main_init) |init| {
                if (permanent) performDelete(init.io, init.gpa, grid)
                else           performTrash(init.io, init.gpa, grid);
            }
        }
    }
}

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    // Drain new images from scan threads and update thumbnail cache
    if (g_grid) |*grid| grid.update();

    // Consume pending delete/restore requests raised by keyboard handlers
    if (g_grid) |*grid| {
        if (grid.delete_requested) {
            grid.delete_requested = false;
            openDeleteDialog(grid, grid.delete_force);
        }
        if (grid.restore_requested) {
            grid.restore_requested = false;
            if (dvui.App.main_init) |init| performRestore(init.io, init.gpa, grid);
        }
    }

    if (g_pending_library_len > 0) {
        const path = g_pending_library_buf[0..g_pending_library_len];
        g_pending_library_len = 0;
        if (dvui.App.main_init) |init| {
            const duped = try init.gpa.dupe(u8, path);
            if (g_library_manager) |*mgr| {
                _ = mgr.addLibrary(init.io, duped) catch {};
            } else if (g_db) |*db| {
                _ = db.storeLibrary(duped) catch {};
            }
            try g_libraries.append(init.gpa, duped);
        }
    }

    // ── Main column ──────────────────────────────────────────────────────
    var col = dvui.box(@src(), .{}, .{ .expand = .both });
    defer col.deinit();

    // ── Toolbar ──────────────────────────────────────────────────────────
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .background = true,
        });
        defer toolbar.deinit();

        // Search field — expands to fill available width
        {
            var te = dvui.textEntry(@src(), .{
                .text = .{ .internal = .{} },
                .placeholder = i18n.t(.search_placeholder),
            }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(5),
                .min_size_content = .{ .h = 22 },
            });
            defer te.deinit();
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // Filter chips
        const chip: dvui.Options = .{
            .corner_radius = dvui.Rect.all(12),
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = .{ .x = 2, .w = 2 },
            .gravity_y = 0.5,
        };
        _ = dvui.button(@src(), "model: any \u{25bc}", .{}, chip.override(.{ .id_extra = 1 }));
        _ = dvui.button(@src(), "aspect: 1:1 \u{25bc}", .{}, chip.override(.{ .id_extra = 2 }));
        _ = dvui.button(@src(), "date: 30d \u{25bc}", .{}, chip.override(.{ .id_extra = 3 }));
        _ = dvui.button(@src(), "+ filter", .{}, chip.override(.{ .id_extra = 4 }));

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // Thumbnail size slider + sort controls
        if (g_grid) |*grid| {
            _ = dvui.slider(@src(), .{ .fraction = &grid.thumb_fraction }, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 80, .h = 16 },
            });

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

            // Sort mode chip — cycles date → name → random on click
            const sort_chip_label: []const u8 = switch (grid.sort_mode) {
                .date => "sort: date \u{25bc}",
                .name => "sort: name \u{25bc}",
                .random => "sort: random \u{25bc}",
            };
            if (dvui.button(@src(), sort_chip_label, .{}, chip.override(.{ .id_extra = 5 }))) {
                grid.sort_mode = switch (grid.sort_mode) {
                    .date => .name,
                    .name => .random,
                    .random => .date,
                };
                grid.applySortOrder();
            }

            // Direction toggle (date/name) or re-randomize button (random)
            if (grid.sort_mode == .random) {
                if (dvui.button(@src(), "~", .{}, chip.override(.{ .id_extra = 6 }))) {
                    grid.sort_seed +%= 1;
                    grid.applySortOrder();
                }
            } else {
                const dir_ch: []const u8 = if (grid.sort_dir == .asc) "\u{2191}" else "\u{2193}";
                if (dvui.button(@src(), dir_ch, .{}, chip.override(.{ .id_extra = 6 }))) {
                    grid.sort_dir = if (grid.sort_dir == .asc) .desc else .asc;
                    grid.applySortOrder();
                }
            }
        }
    }

    // ── Content row: [left panel] [handle] [center] [handle] [right panel] ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true });
        defer row.deinit();

        // ── Left sidebar ──────────────────────────────────────────────────
        if (g_left_w >= 2) {
            var sidebar = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = g_left_w, .h = 0 },
                .expand = .vertical,
                .background = true,
            });
            defer sidebar.deinit();

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            // Library view selector
            {
                const in_library = if (g_grid) |*g| g.view_mode == .library else true;
                const bg: dvui.Options = if (in_library) .{
                    .background = true,
                    .color_fill = dvui.themeGet().focus,
                } else .{};
                var lib_hdr = dvui.box(@src(), .{ .dir = .horizontal }, bg.override(.{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 4, .h = 4 },
                }));
                defer lib_hdr.deinit();
                if (dvui.clickedEx(lib_hdr.data(), .{})) |_| {
                    if (g_grid) |*grid| {
                        if (grid.view_mode != .library) {
                            grid.view_mode = .library;
                            if (g_db) |*db| grid.reloadImages(db) catch {};
                        }
                    }
                }
                dvui.label(@src(), "{s}", .{i18n.t(.nav_library)}, .{ .font = bold, .gravity_y = 0.5 });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                if (dvui.buttonIcon(@src(), "add library", dvui.entypo.plus, .{}, .{}, .{
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(3),
                })) {
                    if (!g_library_dialog_open) {
                        g_library_dialog_open = true;
                        const sdl: *SDLBackend = dvui.currentWindow().backend.impl;
                        SDLBackend.c.SDL_ShowOpenFolderDialog(
                            libraryFolderCallback,
                            null,
                            sdl.window,
                            null,
                            false,
                        );
                    }
                }
            }

            if (g_libraries.items.len == 0) {
                dvui.label(@src(), "{s}", .{i18n.t(.library_empty)}, .{ .padding = .all(8) });
            } else {
                for (g_libraries.items, 0..) |lib_path, idx| {
                    var lib_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = idx,
                        .expand = .horizontal,
                        .padding = .{ .x = 8, .y = 2, .w = 4, .h = 2 },
                    });
                    defer lib_row.deinit();

                    const row_id = lib_row.data().id;
                    var row_hov = dvui.dataGet(null, row_id, "_hov", bool) orelse false;
                    for (dvui.events()) |*e| {
                        if (e.evt == .mouse and e.evt.mouse.action == .position)
                            row_hov = dvui.eventMatchSimple(e, lib_row.data());
                    }
                    dvui.dataSet(null, row_id, "_hov", row_hov);

                    dvui.label(@src(), "{s}", .{std.fs.path.basename(lib_path)}, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });

                    if (row_hov) {
                        if (dvui.buttonIcon(@src(), "remove library", dvui.entypo.minus, .{}, .{}, .{
                            .min_size_content = .{ .w = 10, .h = 10 },
                            .gravity_y = 0.5,
                            .padding = dvui.Rect.all(2),
                        })) {
                            g_confirm_remove_idx = idx;
                        }
                    }
                }
            }

            // ── Trash section ─────────────────────────────────────────────
            if (g_cfg.trash_enabled) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 8 } });

                const in_trash = if (g_grid) |*g| g.view_mode == .trash else false;
                const trash_bg: dvui.Options = if (in_trash) .{
                    .background = true,
                    .color_fill = dvui.themeGet().focus,
                } else .{};
                var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, trash_bg.override(.{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                }));
                defer trash_row.deinit();
                if (dvui.clickedEx(trash_row.data(), .{})) |_| {
                    if (g_grid) |*grid| {
                        if (grid.view_mode != .trash) {
                            grid.view_mode = .trash;
                            if (g_db) |*db| grid.reloadImages(db) catch {};
                        }
                    }
                }
                dvui.label(@src(), "Trash", .{}, .{ .font = bold, .gravity_y = 0.5 });
                if (g_trash_stats) |ts| {
                    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                    dvui.label(@src(), "{d}", .{ts.count}, .{ .gravity_y = 0.5 });
                }
            }
        }

        panelHandle(@src(), .left, &g_left_w, &g_left_w_open, left_w_min, left_w_max);

        // ── Center: image grid ────────────────────────────────────────────
        {
            var grid_area = dvui.box(@src(), .{}, .{ .expand = .both });
            defer grid_area.deinit();

            if (g_grid) |*grid| {
                grid.render();
            } else {
                dvui.label(@src(), "(no library)", .{}, .{ .padding = .all(8) });
            }
        }

        panelHandle(@src(), .right, &g_right_w, &g_right_w_open, right_w_min, right_w_max);

        // ── Right: metadata panel ─────────────────────────────────────────
        if (g_right_w >= 2) {
            var meta = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = g_right_w, .h = 0 },
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
                dvui.label(@src(), "(image title)", .{}, .{ .font = bold });
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            // TODO: metadata fields for selected image
            const lp: dvui.Options = .{ .padding = .{ .x = 8, .y = 2 } };
            const bp: dvui.Options = .{ .font = bold, .padding = .{ .x = 8, .y = 2 } };
            dvui.label(@src(), "{s}", .{i18n.t(.detail_model)},   bp);
            dvui.label(@src(), "(model)",   .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_sampler)}, bp);
            dvui.label(@src(), "(sampler)", .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_steps)},   bp);
            dvui.label(@src(), "(steps)",   .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_size)},    bp);
            dvui.label(@src(), "(size)",    .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_seed)},    bp);
            dvui.label(@src(), "(seed)",    .{}, lp);
        }
    }

    // ── Statusbar ──────────────────────────────────────────────────────────
    {
        var statusbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 2, .w = 4, .h = 2 },
            .background = true,
        });
        defer statusbar.deinit();

        if (g_library_manager) |*mgr| {
            if (mgr.isScanActive()) {
                _ = dvui.spinner(@src(), .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 12, .h = 12 },
                });
                dvui.label(@src(), "scanning… {d} files", .{mgr.filesScanned()}, .{
                    .gravity_y = 0.5,
                    .margin = .{ .x = 4 },
                });
            } else {
                dvui.label(@src(), "{d} images", .{0}, .{ .gravity_y = 0.5 });
            }
        } else {
            dvui.label(@src(), "no database", .{}, .{ .gravity_y = 0.5 });
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dvui.buttonIcon(@src(), "settings", dvui.entypo.cog, .{}, .{}, .{
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(3),
            .margin = .{ .w = 2 },
        })) {
            g_settings_open = !g_settings_open;
            if (g_settings_open) {
                if (g_db) |*db| {
                    g_db_stats = db.getStats() catch null;
                    g_trash_stats = db.getTrashStats() catch null;
                }
                g_settings_scan_snapshot = .{
                    .thumbnails_in_db = g_cfg.thumbnails_in_db,
                    .prompt_embeddings = g_cfg.prompt_embeddings,
                    .image_embeddings = g_cfg.image_embeddings,
                };
            }
        }
    }

    // ── Settings modal ────────────────────────────────────────────────────────
    const settings_was_open = g_settings_open;
    if (g_settings_open) try settingsModal();
    if (settings_was_open and !g_settings_open) {
        const changed = g_cfg.thumbnails_in_db != g_settings_scan_snapshot.thumbnails_in_db or
            g_cfg.prompt_embeddings != g_settings_scan_snapshot.prompt_embeddings or
            g_cfg.image_embeddings != g_settings_scan_snapshot.image_embeddings;
        if (changed) {
            if (g_library_manager) |*mgr| {
                mgr.thumbnails_in_db = g_cfg.thumbnails_in_db;
                mgr.prompt_embeddings = g_cfg.prompt_embeddings;
                mgr.image_embeddings = g_cfg.image_embeddings;
                if (dvui.App.main_init) |init| {
                    mgr.scanAllLibraries(init.io) catch |err| {
                        std.log.warn("rescan after config change: {}", .{err});
                    };
                }
            }
        }
    }

    // ── Library removal confirmation modal ────────────────────────────────────
    if (g_confirm_remove_idx) |idx| {
        if (idx < g_libraries.items.len) {
            const path = g_libraries.items[idx];
            const name = std.fs.path.basename(path);

            var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
                .min_size_content = .{ .w = 360, .h = 0 },
            });
            defer float.deinit();
            float.autoSize();

            var content = dvui.box(@src(), .{}, .{
                .expand = .both,
                .padding = .all(16),
            });
            defer content.deinit();

            dvui.label(@src(), "Remove library?", .{}, .{ .font = bold, .margin = .{ .h = 6 } });
            dvui.label(@src(), "{s}", .{name}, .{});
            dvui.label(@src(), "{s}", .{path}, .{ .margin = .{ .h = 14 } });

            {
                var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
                defer btn_row.deinit();

                if (dvui.button(@src(), "Cancel", .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                }
                if (dvui.button(@src(), "Remove", .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                    if (dvui.App.main_init) |init| {
                        const removed = g_libraries.orderedRemove(idx);
                        if (g_library_manager) |*mgr| {
                            mgr.removeLibrary(removed) catch {};
                        } else if (g_db) |*db| {
                            _ = db.removeLibrary(removed) catch {};
                        }
                        init.gpa.free(removed);
                    }
                }
            }
        } else {
            g_confirm_remove_idx = null;
        }
    }

    // ── Delete confirmation modal ─────────────────────────────────────────────
    if (g_delete_dialog_open) try deleteConfirmDialog();

    return .ok;
}
