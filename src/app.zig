const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");
const icons = @import("icons");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
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
var g_total_image_count: i64 = 0;

// Sidebar filter state
var g_filter_library_id: ?u64 = null;
var g_filter_folder: ?[]const u8 = null; // heap-allocated owned copy

const LibraryState = struct {
    id: u64,
    path: []const u8,           // owned
    image_count: i64 = 0,
    expanded: bool = false,
    top_folders: []FolderNode = &.{},  // immediate subdirs of library root; owned
    top_loaded: bool = false,

    fn deinit(self: *LibraryState, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        freeFolderNodes(allocator, self.top_folders);
    }
};

/// A node in the library folder tree. Populated lazily when the user expands a node.
const FolderNode = struct {
    path: []const u8,         // full absolute path, heap-allocated, owned
    count: i64,               // images in this subtree (all descendants)
    children: []FolderNode = &.{},  // heap-allocated; empty until loaded
    loaded: bool = false,     // true once children have been fetched
    expanded: bool = false,
};

fn freeFolderNodes(allocator: std.mem.Allocator, nodes: []FolderNode) void {
    for (nodes) |*n| {
        allocator.free(n.path);
        freeFolderNodes(allocator, n.children);
    }
    if (nodes.len > 0) allocator.free(nodes);
}

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
var g_libraries: std.ArrayList(LibraryState) = .empty;
var g_confirm_remove_idx: ?usize = null;

// Search state: text buffer written by the textEntry widget each frame.
// g_search_prev mirrors it so we can detect changes and trigger a DB reload.
var g_search_buf: [256]u8 = std.mem.zeroes([256]u8);
var g_search_prev: [256]u8 = std.mem.zeroes([256]u8);

// Active metadata filters
var g_active_filters: std.ArrayList(db_mod.ActiveFilter) = .empty;

// Filter modal state
var g_filter_modal_open: bool = false;
var g_filter_modal_kind: db_mod.FilterColumn = .model;
var g_filter_modal_value_buf: [256]u8 = std.mem.zeroes([256]u8);
var g_filter_modal_options: ?[][]const u8 = null;
var g_filter_modal_options_kind: ?db_mod.FilterColumn = null;

// Right-panel detail: tracks the currently-displayed image so we only re-query on change.
var g_detail_id: ?u64 = null;
var g_detail: ?db_mod.ImageDetails = null;

/// Refresh image counts for all libraries, total count, and trash stats.
/// Called at init and after any operation that changes counts.
fn refreshCounts() void {
    if (dvui.App.main_init) |init| {
        if (g_db) |*db| {
            g_total_image_count = db.getTotalImageCount() catch 0;
            g_trash_stats = db.getTrashStats() catch null;
            for (g_libraries.items) |*lib| {
                lib.image_count = db.getLibraryImageCount(lib.id) catch 0;
                // Invalidate cached folder tree so next expansion reloads it.
                if (lib.top_loaded) {
                    freeFolderNodes(init.gpa, lib.top_folders);
                    lib.top_folders = &.{};
                    lib.top_loaded = false;
                }
            }
        }
    }
}

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
            if (db.listLibraries(init.gpa)) |libs| {
                defer {
                    for (libs) |li| init.gpa.free(li.path);
                    init.gpa.free(libs);
                }
                for (libs) |li| {
                    const count = db.getLibraryImageCount(li.id) catch 0;
                    try g_libraries.append(init.gpa, .{
                        .id = li.id,
                        .path = try init.gpa.dupe(u8, li.path),
                        .image_count = count,
                    });
                }
            } else |_| {}

            // Register a custom SDL event so the worker thread can wake the render loop
            // when a thumbnail is ready (dvui only renders on input otherwise).
            g_wakeup_event_type = SDLBackend.c.SDL_RegisterEvents(1);

            // Init grid before library manager so we can pass the notifier pointer.
            // Grid must be at its final global address before startWorker() is called.
            g_grid = try image_grid_mod.GridState.init(init.io, init.gpa, db, g_cfg.thumbnails_in_db, wakeupFrame);
            if (g_grid) |*grid| {
                grid.data_dir = g_data_dir;
                try grid.startWorker();
            }

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

            // Initialize counts and trash stats.
            g_total_image_count = db.getTotalImageCount() catch 0;
            g_trash_stats = db.getTrashStats() catch null;
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
    if (g_detail) |*d| {
        if (dvui.App.main_init) |init| d.deinit(init.gpa);
        g_detail = null;
    }
    if (dvui.App.main_init) |init| {
        if (g_config) |cfg_path| {
            config_mod.save(g_cfg, init.io, cfg_path) catch |err| {
                std.log.warn("failed to save config: {}", .{err});
            };
            init.gpa.free(cfg_path);
        }
        g_cfg.deinit(init.gpa);
        for (g_libraries.items) |*lib| lib.deinit(init.gpa);
        g_libraries.deinit(init.gpa);
        if (g_filter_folder) |f| init.gpa.free(f);
        if (g_data_dir) |d| init.gpa.free(d);
        for (g_active_filters.items) |f| init.gpa.free(f.value);
        g_active_filters.deinit(init.gpa);
        if (g_filter_modal_options) |opts| {
            for (opts) |s| init.gpa.free(s);
            init.gpa.free(opts);
        }
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
        const tvg = switch (side) {
            .left  => if (collapsed) icons.tvg.lucide.@"chevron-right" else icons.tvg.lucide.@"chevron-left",
            .right => if (collapsed) icons.tvg.lucide.@"chevron-left"  else icons.tvg.lucide.@"chevron-right",
        };
        dvui.icon(@src(), "pane_toggle", tvg, .{}, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .min_size_content = .{ .w = 10, .h = 10 },
        });
    }

    const tip = if (collapsed) i18n.t(.pane_click_to_expand) else i18n.t(.pane_drag_to_resize);
    dvui.tooltip(@src(), .{ .active_rect = h.data().rectScale().r, .delay = 500_000 }, "{s}", .{tip}, .{});
}

/// Read PNG image dimensions from the IHDR chunk (first 24 bytes of a PNG file).
fn parsePngDims(buf: []const u8) ?struct { w: u32, h: u32 } {
    if (buf.len < 24) return null;
    const sig = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (!std.mem.eql(u8, buf[0..8], &sig)) return null;
    if (!std.mem.eql(u8, buf[12..16], "IHDR")) return null;
    const w: u32 = (@as(u32, buf[16]) << 24) | (@as(u32, buf[17]) << 16) |
                   (@as(u32, buf[18]) << 8)  | @as(u32, buf[19]);
    const h: u32 = (@as(u32, buf[20]) << 24) | (@as(u32, buf[21]) << 16) |
                   (@as(u32, buf[22]) << 8)  | @as(u32, buf[23]);
    return .{ .w = w, .h = h };
}

/// Try to parse `text` as JSON and return a pretty-printed copy; returns null if
/// the text is not valid JSON or allocation fails. Caller owns the returned slice.
fn prettyJson(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit(); // no-op after toOwnedSlice; cleans up on error paths
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    js.write(parsed.value) catch return null;
    return aw.toOwnedSlice() catch null;
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
    refreshCounts();
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
    refreshCounts();
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
    refreshCounts();
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
    // Items already in the trash can only be permanently deleted, never re-trashed.
    g_delete_dialog_force = force or (grid.view_mode == .trash);

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

    dvui.label(@src(), "{s}", .{i18n.t(.settings_heading)}, .{ .font = bold, .margin = .{ .h = 12 } });

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

            dvui.label(@src(), "{s}", .{i18n.t(.settings_scan_section)}, .{ .font = bold, .margin = .{ .h = 8 } });
            _ = dvui.checkbox(@src(), &g_cfg.thumbnails_in_db, i18n.t(.settings_thumbnails_in_db), .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.prompt_embeddings, i18n.t(.settings_prompt_embeddings), .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.image_embeddings, i18n.t(.settings_image_embeddings), .{ .margin = .{ .h = 6 } });

            dvui.label(@src(), "{s}", .{i18n.t(.settings_trash_section)}, .{ .font = bold, .margin = .{ .y = 16, .h = 8 } });
            _ = dvui.checkbox(@src(), &g_cfg.trash_enabled, i18n.t(.settings_trash_enable), .{ .margin = .{ .h = 6 } });
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
                    if (dvui.button(@src(), i18n.t(.settings_empty_trash), .{}, .{
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

            dvui.label(@src(), "{s}", .{i18n.t(.settings_data_path)}, .{ .font = bold, .margin = .{ .y = 16, .h = 6 } });
            if (g_cfg.data_path) |p| {
                dvui.label(@src(), "{s}", .{p}, .{});
            } else {
                dvui.label(@src(), "{s}", .{i18n.t(.settings_data_path_default)}, .{});
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

            dvui.label(@src(), "{s}", .{i18n.t(.settings_database_section)}, .{ .font = bold, .margin = .{ .h = 8 } });

            if (g_db_stats) |stats| {
                const total = fmtBytes(stats.total_bytes);
                dvui.label(@src(), "{s}{d:.1} {s}", .{ i18n.t(.settings_db_total_size_label), total.value, total.unit }, .{ .margin = .{ .h = 10 } });

                // Thumbnails
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 6 },
                    });
                    defer row.deinit();
                    const tb = fmtBytes(stats.thumbnail_bytes);
                    dvui.label(@src(), "{s}{d} ({d:.1} {s})", .{ i18n.t(.settings_db_thumbnails_label), stats.thumbnail_count, tb.value, tb.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), i18n.t(.action_clear), .{}, .{
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
                    dvui.label(@src(), "{s}{d} ({d:.1} {s})", .{ i18n.t(.settings_db_prompt_embeddings_label), stats.prompt_embedding_count, pe.value, pe.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), i18n.t(.action_clear), .{}, .{
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
                    dvui.label(@src(), "{s}{d} ({d:.1} {s})", .{ i18n.t(.settings_db_image_embeddings_label), stats.image_embedding_count, ie.value, ie.unit }, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });
                    if (dvui.button(@src(), i18n.t(.action_clear), .{}, .{
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
                dvui.label(@src(), "{s}", .{i18n.t(.settings_db_no_database)}, .{});
            }
        }
    }

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .margin = .{ .y = 12 } });
        defer btn_row.deinit();
        if (dvui.button(@src(), i18n.t(.action_close), .{}, .{ .margin = .all(4) })) {
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
    const title = if (permanent) i18n.t(.confirm_delete_title) else i18n.t(.confirm_trash_title);
    dvui.label(@src(), "{s}", .{title}, .{ .font = bold, .margin = .{ .h = 8 } });

    if (g_delete_dialog_count == 1) {
        const name = g_delete_dialog_name_buf[0..g_delete_dialog_name_len];
        dvui.label(@src(), "{s}", .{name}, .{ .margin = .{ .h = 12 } });
    } else {
        dvui.label(@src(), "{d} files selected", .{g_delete_dialog_count}, .{ .margin = .{ .h = 12 } });
    }

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
    defer btn_row.deinit();

    if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
        g_delete_dialog_open = false;
    }

    if (g_delete_dialog_count == 1) {
        const skip_label = if (permanent) i18n.t(.confirm_delete_no_ask) else i18n.t(.confirm_trash_no_ask);
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

    const confirm_label = if (permanent) i18n.t(.confirm_delete) else i18n.t(.confirm_move_to_trash);
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

/// Render one folder node and recursively its expanded children.
/// Called from the sidebar; nodes are siblings (not inside each other).
fn renderFolderNode(node: *FolderNode, lib: *LibraryState, depth: usize) void {
    const in_lib_view = if (g_grid) |*g| g.view_mode == .library else false;
    const indent_x: f32 = 8.0 + @as(f32, @floatFromInt(depth)) * 14.0;

    // Stable id per node: hash of the path string.
    const node_id_extra: usize = @truncate(std.hash.Fnv1a_32.hash(node.path));

    const is_selected = in_lib_view and
        g_filter_library_id == lib.id and
        g_filter_folder != null and
        std.mem.eql(u8, g_filter_folder.?, node.path);

    const row_bg: dvui.Options = if (is_selected) .{
        .background = true,
        .color_fill = dvui.themeGet().focus,
    } else .{};

    const may_have_children = node.children.len > 0 or !node.loaded;

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, row_bg.override(.{
            .id_extra = node_id_extra,
            .expand = .horizontal,
            .padding = .{ .x = indent_x, .y = 1, .w = 4, .h = 1 },
        }));
        defer row.deinit();

        // Clicking anywhere on the row: toggle expand (if applicable) and set filter.
        if (dvui.clickedEx(row.data(), .{})) |_| {
            if (may_have_children or node.expanded) {
                node.expanded = !node.expanded;
                if (node.expanded and !node.loaded) {
                    if (dvui.App.main_init) |init| {
                        if (g_db) |*db| {
                            if (db.listImmediateSubdirs(init.gpa, lib.id, node.path)) |subs| {
                                if (init.gpa.alloc(FolderNode, subs.len)) |new_nodes| {
                                    for (subs, 0..) |s, i| {
                                        new_nodes[i] = .{ .path = s.path, .count = s.count };
                                    }
                                    init.gpa.free(subs);
                                    node.children = new_nodes;
                                } else |_| {
                                    for (subs) |s| init.gpa.free(s.path);
                                    init.gpa.free(subs);
                                }
                            } else |_| {}
                            node.loaded = true;
                        }
                    }
                }
            }
            if (dvui.App.main_init) |init| {
                if (g_filter_folder) |f| init.gpa.free(f);
                g_filter_folder = init.gpa.dupe(u8, node.path) catch null;
                g_filter_library_id = lib.id;
            }
            if (g_grid) |*grid| {
                grid.filter_library_id = lib.id;
                grid.filter_folder_path = g_filter_folder;
                grid.view_mode = .library;
                if (g_db) |*db| grid.reloadImages(db) catch {};
            }
        }

        // Visual expand indicator (non-interactive icon).
        if (may_have_children or node.expanded) {
            const tvg = if (node.expanded) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right";
            dvui.icon(@src(), "expand", tvg, .{}, .{
                .id_extra = node_id_extra,
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
            });
        } else {
            _ = dvui.spacer(@src(), .{
                .id_extra = node_id_extra,
                .min_size_content = .{ .w = 12, .h = 0 },
            });
        }

        dvui.label(@src(), "{s}", .{std.fs.path.basename(node.path)}, .{
            .id_extra = node_id_extra,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        dvui.label(@src(), "{d}", .{node.count}, .{
            .id_extra = node_id_extra +% 1,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .w = 0 },
        });
    }

    if (node.expanded) {
        for (node.children) |*child| {
            renderFolderNode(child, lib, depth + 1);
        }
    }
}

fn filterColumnLabel(kind: db_mod.FilterColumn) [:0]const u8 {
    return switch (kind) {
        .model => i18n.t(.detail_model),
        .sampler => i18n.t(.detail_sampler),
        .scheduler => i18n.t(.detail_scheduler),
    };
}

fn filterMatchesTyped(opt: []const u8, typed: []const u8) bool {
    if (typed.len == 0) return true;
    if (typed.len > opt.len) return false;
    var i: usize = 0;
    outer: while (i + typed.len <= opt.len) : (i += 1) {
        for (typed, 0..) |c, j| {
            if (std.ascii.toLower(c) != std.ascii.toLower(opt[i + j])) continue :outer;
        }
        return true;
    }
    return false;
}

fn filterModal() !void {
    if (!g_filter_modal_open) return;

    // Fetch autocomplete options when kind changes or first open.
    if (g_filter_modal_options_kind == null or g_filter_modal_options_kind.? != g_filter_modal_kind) {
        if (dvui.App.main_init) |init| {
            if (g_filter_modal_options) |opts| {
                for (opts) |s| init.gpa.free(s);
                init.gpa.free(opts);
                g_filter_modal_options = null;
            }
            if (g_db) |*db| {
                g_filter_modal_options = db.getDistinctColumnValues(init.gpa, g_filter_modal_kind) catch null;
            }
        }
        g_filter_modal_options_kind = g_filter_modal_kind;
    }

    var float = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &g_filter_modal_open,
        .resize = .none,
    }, .{
        .min_size_content = .{ .w = 380, .h = 0 },
    });
    defer float.deinit();
    float.autoSize();
    float.dragAreaSet(dvui.Rect.Physical{});

    var content = dvui.box(@src(), .{}, .{
        .expand = .both,
        .padding = .all(16),
    });
    defer content.deinit();

    dvui.label(@src(), "{s}", .{i18n.t(.filter_heading)}, .{ .font = bold, .margin = .{ .h = 10 } });

    // Kind selector chips
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .h = 8 },
        });
        defer row.deinit();

        const chip_base: dvui.Options = .{
            .corner_radius = dvui.Rect.all(12),
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = .{ .w = 4 },
            .gravity_y = 0.5,
        };

        const kinds = [_]db_mod.FilterColumn{ .model, .sampler, .scheduler };
        for (kinds) |kind| {
            const selected = g_filter_modal_kind == kind;
            const chip_opts = if (selected)
                chip_base.override(.{
                    .id_extra = @intFromEnum(kind),
                    .background = true,
                    .color_fill = dvui.themeGet().focus,
                })
            else
                chip_base.override(.{ .id_extra = @intFromEnum(kind) });
            if (dvui.button(@src(), filterColumnLabel(kind), .{}, chip_opts)) {
                if (g_filter_modal_kind != kind) {
                    g_filter_modal_kind = kind;
                    g_filter_modal_value_buf = std.mem.zeroes([256]u8);
                    g_filter_modal_options_kind = null; // trigger re-fetch
                }
            }
        }
    }

    // Value text entry
    {
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = g_filter_modal_value_buf[0..] },
            .placeholder = i18n.t(.filter_search_placeholder),
        }, .{
            .expand = .horizontal,
            .corner_radius = dvui.Rect.all(4),
            .margin = .{ .h = 4 },
        });
        te.deinit();
    }

    // Autocomplete options
    {
        const typed = std.mem.sliceTo(&g_filter_modal_value_buf, 0);
        const opts = g_filter_modal_options orelse &.{};
        var shown: usize = 0;
        for (opts, 0..) |opt, oi| {
            if (shown >= 8) break;
            if (!filterMatchesTyped(opt, typed)) continue;
            shown += 1;
            if (dvui.button(@src(), opt, .{}, .{
                .id_extra = oi,
                .expand = .horizontal,
                .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                .margin = .{ .h = 1 },
            })) {
                @memset(&g_filter_modal_value_buf, 0);
                const len = @min(opt.len, g_filter_modal_value_buf.len - 1);
                @memcpy(g_filter_modal_value_buf[0..len], opt[0..len]);
            }
        }
    }

    // Action buttons
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 1.0,
            .margin = .{ .y = 12 },
        });
        defer btn_row.deinit();

        if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
            g_filter_modal_open = false;
        }

        const val = std.mem.sliceTo(&g_filter_modal_value_buf, 0);
        const can_add = val.len > 0;
        const theme = dvui.themeGet();
        if (dvui.button(@src(), i18n.t(.filter_add), .{}, .{
            .margin = .all(4),
            .color_fill = if (!can_add) theme.fill else null,
            .color_fill_hover = if (!can_add) theme.fill else null,
            .color_fill_press = if (!can_add) theme.fill else null,
            .color_text = if (!can_add) theme.border else null,
            .color_text_hover = if (!can_add) theme.border else null,
            .color_text_press = if (!can_add) theme.border else null,
        }) and can_add) {
            if (dvui.App.main_init) |init| {
                const owned_val = try init.gpa.dupe(u8, val);
                try g_active_filters.append(init.gpa, .{
                    .column = g_filter_modal_kind,
                    .value = owned_val,
                });
                if (g_grid) |*grid| {
                    grid.filters = g_active_filters.items;
                    if (g_db) |*db| grid.reloadImages(db) catch {};
                }
            }
            g_filter_modal_open = false;
        }
    }
}

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    // Drain new images from scan threads and update thumbnail cache
    if (g_grid) |*grid| {
        const prev_len = grid.images.items.len;
        grid.update();
        if (grid.images.items.len != prev_len) {
            if (g_db) |*db| {
                g_total_image_count = db.getTotalImageCount() catch g_total_image_count;
                for (g_libraries.items) |*lib| {
                    lib.image_count = db.getLibraryImageCount(lib.id) catch lib.image_count;
                }
            }
        }
    }

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

    // Detect search text changes and reload the grid via FTS5
    if (!std.mem.eql(u8, &g_search_buf, &g_search_prev)) {
        @memcpy(&g_search_prev, &g_search_buf);
        const q = std.mem.sliceTo(&g_search_buf, 0);
        if (g_grid) |*grid| {
            grid.search_query = if (q.len > 0) q else null;
            if (g_db) |*db| grid.reloadImages(db) catch {};
        }
    }

    if (g_pending_library_len > 0) {
        const path = g_pending_library_buf[0..g_pending_library_len];
        g_pending_library_len = 0;
        if (dvui.App.main_init) |init| {
            const duped = try init.gpa.dupe(u8, path);
            const lib_id: u64 = if (g_library_manager) |*mgr|
                mgr.addLibrary(init.io, duped) catch 0
            else if (g_db) |*db|
                db.storeLibrary(duped) catch 0
            else
                0;
            try g_libraries.append(init.gpa, .{
                .id = lib_id,
                .path = duped,
                .image_count = 0,
            });
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
                .text = .{ .buffer = g_search_buf[0..] },
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
        // Active filter pills
        var filter_remove_idx: ?usize = null;
        for (g_active_filters.items, 0..) |f, fi| {
            var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = fi,
                .corner_radius = dvui.Rect.all(12),
                .padding = .{ .x = 8, .y = 3, .w = 4, .h = 3 },
                .margin = .{ .x = 2, .w = 2 },
                .gravity_y = 0.5,
                .background = true,
                .color_fill = dvui.themeGet().focus,
            });
            defer pill.deinit();
            dvui.label(@src(), "{s}: {s}", .{ filterColumnLabel(f.column), f.value }, .{
                .id_extra = fi,
                .gravity_y = 0.5,
            });
            if (dvui.buttonIcon(@src(), "remove_filter", dvui.entypo.cross, .{}, .{}, .{
                .id_extra = fi,
                .min_size_content = .{ .w = 10, .h = 10 },
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(2),
                .margin = .{ .x = 4 },
            })) {
                filter_remove_idx = fi;
            }
        }
        if (filter_remove_idx) |ri| {
            if (dvui.App.main_init) |init| {
                const f = g_active_filters.orderedRemove(ri);
                init.gpa.free(f.value);
            }
            if (g_grid) |*grid| {
                grid.filters = g_active_filters.items;
                if (g_db) |*db| grid.reloadImages(db) catch {};
            }
        }

        // Add filter button
        if (dvui.button(@src(), i18n.t(.toolbar_add_filter), .{}, chip.override(.{ .id_extra = 4 }))) {
            g_filter_modal_open = true;
            g_filter_modal_value_buf = std.mem.zeroes([256]u8);
            g_filter_modal_kind = .model;
            g_filter_modal_options_kind = null; // trigger re-fetch
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // Thumbnail size slider + sort controls
        if (g_grid) |*grid| {
            _ = dvui.slider(@src(), .{ .fraction = &grid.thumb_fraction }, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 80, .h = 16 },
            });

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

            // Sort mode chip — cycles date → name → random on click
            {
                const sort_mode_tvg = switch (grid.sort_mode) {
                    .date   => icons.tvg.lucide.calendar,
                    .name   => icons.tvg.lucide.@"a-arrow-down",
                    .random => icons.tvg.entypo.shuffle,
                };
                const sort_mode_tip = switch (grid.sort_mode) {
                    .date   => i18n.t(.toolbar_sort_by_date),
                    .name   => i18n.t(.toolbar_sort_by_name),
                    .random => i18n.t(.toolbar_sort_randomly),
                };
                var bw: dvui.ButtonWidget = undefined;
                bw.init(@src(), .{}, chip.override(.{ .id_extra = 5, .min_size_content = .{ .w = 16, .h = 16 } }));
                defer bw.deinit();
                bw.processEvents();
                bw.drawBackground();
                dvui.icon(@src(), "sort_mode_icon", sort_mode_tvg, .{}, .{
                    .gravity_x = 0.5, .gravity_y = 0.5,
                    .min_size_content = .{ .w = 16, .h = 16 },
                    .expand = .ratio,
                });
                if (bw.clicked()) {
                    grid.sort_mode = switch (grid.sort_mode) {
                        .date => .name,
                        .name => .random,
                        .random => .date,
                    };
                    grid.applySortOrder();
                }
                bw.drawFocus();
                dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{sort_mode_tip}, .{});
            }

            // Direction toggle (date/name) or re-randomize button (random)
            if (grid.sort_mode == .random) {
                var bw: dvui.ButtonWidget = undefined;
                bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .min_size_content = .{ .w = 16, .h = 16 } }));
                defer bw.deinit();
                bw.processEvents();
                bw.drawBackground();
                dvui.icon(@src(), "reshuffle_icon", icons.tvg.lucide.dices, .{}, .{
                    .gravity_x = 0.5, .gravity_y = 0.5,
                    .min_size_content = .{ .w = 16, .h = 16 },
                    .expand = .ratio,
                });
                if (bw.clicked()) {
                    grid.sort_seed +%= 1;
                    grid.applySortOrder();
                }
                bw.drawFocus();
                dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{i18n.t(.toolbar_reshuffle)}, .{});
            } else {
                const dir_tvg = if (grid.sort_dir == .asc) icons.tvg.lucide.@"arrow-up" else icons.tvg.lucide.@"arrow-down";
                const dir_tip = if (grid.sort_dir == .asc) i18n.t(.toolbar_sort_ascending) else i18n.t(.toolbar_sort_descending);
                var bw: dvui.ButtonWidget = undefined;
                bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .min_size_content = .{ .w = 16, .h = 16 } }));
                defer bw.deinit();
                bw.processEvents();
                bw.drawBackground();
                dvui.icon(@src(), "sort_dir_icon", dir_tvg, .{}, .{
                    .gravity_x = 0.5, .gravity_y = 0.5,
                    .min_size_content = .{ .w = 16, .h = 16 },
                    .expand = .ratio,
                });
                if (bw.clicked()) {
                    grid.sort_dir = if (grid.sort_dir == .asc) .desc else .asc;
                    grid.applySortOrder();
                }
                bw.drawFocus();
                dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{dir_tip}, .{});
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

            // ── "Library" master header (clears filter, shows all) ───────────
            {
                const in_library = if (g_grid) |*g| g.view_mode == .library else true;
                const unfiltered = g_filter_library_id == null and g_filter_folder == null;
                const bg: dvui.Options = if (in_library and unfiltered) .{
                    .background = true,
                    .color_fill = dvui.themeGet().focus,
                } else .{};
                var lib_hdr = dvui.box(@src(), .{ .dir = .horizontal }, bg.override(.{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 4, .h = 4 },
                }));
                defer lib_hdr.deinit();
                {
                    var lbl_area = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 0.5 });
                    defer lbl_area.deinit();
                    if (dvui.clickedEx(lbl_area.data(), .{})) |_| {
                        if (dvui.App.main_init) |init| {
                            if (g_filter_folder) |f| init.gpa.free(f);
                            g_filter_folder = null;
                            g_filter_library_id = null;
                        }
                        if (g_grid) |*grid| {
                            grid.filter_library_id = null;
                            grid.filter_folder_path = null;
                            grid.view_mode = .library;
                            if (g_db) |*db| grid.reloadImages(db) catch {};
                        }
                    }
                    dvui.label(@src(), "{s}", .{i18n.t(.nav_library)}, .{ .font = bold, .gravity_y = 0.5 });
                    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                }
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
                for (g_libraries.items, 0..) |*lib, idx| {
                    const in_lib_view = if (g_grid) |*g| g.view_mode == .library else false;
                    const lib_selected = g_filter_library_id == lib.id and g_filter_folder == null;

                    // ── Library header row (horizontal, closed by block) ──
                    var row_hov = false;
                    {
                        const lib_bg: dvui.Options = if (lib_selected and in_lib_view) .{
                            .background = true,
                            .color_fill = dvui.themeGet().focus,
                        } else .{};
                        var lib_row = dvui.box(@src(), .{ .dir = .horizontal }, lib_bg.override(.{
                            .id_extra = idx,
                            .expand = .horizontal,
                            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                        }));
                        defer lib_row.deinit();

                        const row_id = lib_row.data().id;
                        row_hov = dvui.dataGet(null, row_id, "_hov", bool) orelse false;
                        for (dvui.events()) |*e| {
                            if (e.evt == .mouse and e.evt.mouse.action == .position)
                                row_hov = dvui.eventMatchSimple(e, lib_row.data());
                        }
                        dvui.dataSet(null, row_id, "_hov", row_hov);

                        // Expand/collapse toggle
                        const expand_tvg = if (lib.expanded) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right";
                        if (dvui.buttonIcon(@src(), "expand", expand_tvg, .{}, .{}, .{
                            .id_extra = idx,
                            .min_size_content = .{ .w = 14, .h = 14 },
                            .gravity_y = 0.5,
                            .padding = dvui.Rect.all(2),
                            .margin = .{},
                        })) {
                            lib.expanded = !lib.expanded;
                            if (lib.expanded and !lib.top_loaded) {
                                if (dvui.App.main_init) |init| {
                                    if (g_db) |*db| {
                                        if (db.listImmediateSubdirs(init.gpa, lib.id, lib.path)) |subs| {
                                            if (init.gpa.alloc(FolderNode, subs.len)) |new_nodes| {
                                                for (subs, 0..) |s, i| {
                                                    new_nodes[i] = .{ .path = s.path, .count = s.count };
                                                }
                                                init.gpa.free(subs);
                                                lib.top_folders = new_nodes;
                                            } else |_| {
                                                for (subs) |s| init.gpa.free(s.path);
                                                init.gpa.free(subs);
                                            }
                                        } else |_| {}
                                        lib.top_loaded = true;
                                    }
                                }
                            }
                        }

                        // Library name (click to filter to this library)
                        {
                            var name_area = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .id_extra = idx,
                                .expand = .horizontal,
                                .gravity_y = 0.5,
                            });
                            defer name_area.deinit();
                            if (dvui.clickedEx(name_area.data(), .{})) |_| {
                                if (dvui.App.main_init) |init| {
                                    if (g_filter_folder) |f| init.gpa.free(f);
                                    g_filter_folder = null;
                                    g_filter_library_id = lib.id;
                                }
                                if (g_grid) |*grid| {
                                    grid.filter_library_id = lib.id;
                                    grid.filter_folder_path = null;
                                    grid.view_mode = .library;
                                    if (g_db) |*db| grid.reloadImages(db) catch {};
                                }
                            }
                            dvui.label(@src(), "{s}", .{std.fs.path.basename(lib.path)}, .{
                                .id_extra = idx,
                                .expand = .horizontal,
                                .gravity_y = 0.5,
                            });
                        }

                        // Image count badge
                        dvui.label(@src(), "{d}", .{lib.image_count}, .{
                            .id_extra = idx,
                            .gravity_y = 0.5,
                            .padding = .{ .x = 4, .w = 0 },
                        });

                        // Remove button (shown on hover)
                        if (row_hov) {
                            if (dvui.buttonIcon(@src(), "remove library", dvui.entypo.minus, .{}, .{}, .{
                                .id_extra = idx,
                                .min_size_content = .{ .w = 10, .h = 10 },
                                .gravity_y = 0.5,
                                .padding = dvui.Rect.all(2),
                            })) {
                                g_confirm_remove_idx = idx;
                            }
                        }
                    } // lib_row closed here

                    // ── Folder tree (sibling rows, indented) ─────────────
                    if (lib.expanded) {
                        for (lib.top_folders) |*node| {
                            renderFolderNode(node, lib, 1);
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
                dvui.label(@src(), "{s}", .{i18n.t(.sidebar_trash)}, .{ .font = bold, .gravity_y = 0.5 });
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
                grid.trash_enabled = g_cfg.trash_enabled;
                grid.render();
            } else {
                dvui.label(@src(), "(no library)", .{}, .{ .padding = .all(8) });
            }
        }

        panelHandle(@src(), .right, &g_right_w, &g_right_w_open, right_w_min, right_w_max);

        // ── Right: metadata panel ─────────────────────────────────────────
        if (g_right_w >= 2) {
            // Refresh detail when the focused image changes.
            const focused_id: ?u64 = if (g_grid) |*grid|
                if (grid.focused_idx) |fi|
                    (if (fi < grid.images.items.len) grid.images.items[fi].id else null)
                else null
            else null;

            if (focused_id != g_detail_id) {
                if (g_detail) |*d| {
                    if (dvui.App.main_init) |init| d.deinit(init.gpa);
                    g_detail = null;
                }
                g_detail_id = focused_id;
                if (focused_id) |fid| {
                    if (g_db) |*db| {
                        if (dvui.App.main_init) |init| {
                            if (db.getImageDetails(init.gpa, fid) catch null) |det| {
                                g_detail = det;
                                const img_path = g_detail.?.library_path;
                                // File size (best-effort).
                                if (std.Io.Dir.cwd().openFile(init.io, img_path, .{})) |f| {
                                    defer f.close(init.io);
                                    if (f.length(init.io)) |sz| {
                                        g_detail.?.file_size = @intCast(sz);
                                    } else |_| {}
                                } else |_| {}
                                // PNG dims + raw text chunks (best-effort).
                                var maybe_parser: ?png_mod.PngParser = png_mod.PngParser.init(init.gpa, init.io) catch null;
                                if (maybe_parser) |*parser| {
                                    defer parser.deinit();
                                    if (parser.parseFile(img_path)) |_| {
                                        // Dims from IHDR chunk.
                                        for (parser.chunks.items) |pc| {
                                            if (std.mem.eql(u8, &pc.type, &png_mod.ChunkType.IHDR) and pc.data.len >= 8) {
                                                g_detail.?.width = std.mem.readInt(u32, pc.data[0..4], .big);
                                                g_detail.?.height = std.mem.readInt(u32, pc.data[4..8], .big);
                                                break;
                                            }
                                        }
                                        // Raw text chunks.
                                        var raw_list: std.ArrayList(db_mod.RawChunk) = .empty;
                                        const text_chunks = parser.getTExtChunks() catch &[_]png_mod.Chunk{};
                                        defer init.gpa.free(text_chunks);
                                        for (text_chunks) |tc| {
                                            const c = parser.parseTExtChunk(tc) catch continue;
                                            const kw = c.keyword;
                                            const raw_text = c.text;
                                            const maybe_pretty = prettyJson(init.gpa, raw_text);
                                            const display = maybe_pretty orelse raw_text;
                                            if (maybe_pretty != null) init.gpa.free(raw_text);
                                            raw_list.append(init.gpa, .{
                                                .keyword = kw,
                                                .display_text = display,
                                                .is_json = maybe_pretty != null,
                                            }) catch {
                                                init.gpa.free(kw);
                                                init.gpa.free(display);
                                            };
                                        }
                                        const itxt_chunks = parser.getITxtChunks() catch &[_]png_mod.Chunk{};
                                        defer init.gpa.free(itxt_chunks);
                                        for (itxt_chunks) |tc| {
                                            var c = parser.parseITxtChunk(tc) catch continue;
                                            if (c.compressed) { c.deinit(init.gpa); continue; }
                                            const kw = c.keyword;
                                            const raw_text = c.text;
                                            init.gpa.free(c.language);
                                            init.gpa.free(c.translated_keyword);
                                            const maybe_pretty = prettyJson(init.gpa, raw_text);
                                            const display = maybe_pretty orelse raw_text;
                                            if (maybe_pretty != null) init.gpa.free(raw_text);
                                            raw_list.append(init.gpa, .{
                                                .keyword = kw,
                                                .display_text = display,
                                                .is_json = maybe_pretty != null,
                                            }) catch {
                                                init.gpa.free(kw);
                                                init.gpa.free(display);
                                            };
                                        }
                                        if (raw_list.items.len > 0) {
                                            if (raw_list.toOwnedSlice(init.gpa)) |sl| {
                                                g_detail.?.raw_chunks = sl;
                                                g_detail.?.raw_chunks_owned = true;
                                            } else |_| {
                                                for (raw_list.items) |*rc| {
                                                    init.gpa.free(rc.keyword);
                                                    init.gpa.free(rc.display_text);
                                                }
                                                raw_list.deinit(init.gpa);
                                            }
                                        }
                                    } else |_| {}
                                }
                            }
                        }
                    }
                }
            }

            var meta = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = g_right_w, .h = 0 },
                .max_size_content = .{ .w = g_right_w, .h = 0 },
                .expand = .vertical,
                .background = true,
            });
            defer meta.deinit();

            // Header: filename of the focused image.
            {
                var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 6 },
                });
                defer header.deinit();
                const title: []const u8 = if (g_grid) |*grid|
                    if (grid.focused_idx) |fi|
                        (if (fi < grid.images.items.len) grid.images.items[fi].filename else "")
                    else ""
                else "";
                if (title.len > 0) {
                    var tl = dvui.textLayout(@src(), .{}, .{
                        .font = bold,
                        .expand = .horizontal,
                        .background = false,
                    });
                    tl.addText(title, .{});
                    tl.deinit();
                } else {
                    dvui.label(@src(), "{s}", .{i18n.t(.detail_no_image)}, .{ .font = bold });
                }
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            if (g_detail) |d| {
                // Bold section header style.
                const bp: dvui.Options = .{ .font = bold, .padding = .{ .x = 8, .y = 4, .h = 0 } };
                // Value for block (multi-line) fields — uses textLayout for wrapping.
                const lp: dvui.Options = .{
                    .padding = .{ .x = 8, .y = 2, .h = 6 },
                    .expand = .horizontal,
                    .background = false,
                };
                // Value for compact single-line fields inside horizontal rows.
                const sp: dvui.Options = .{
                    .padding = .{ .x = 8, .y = 2, .h = 6 },
                    .expand = .horizontal,
                };

                // ── Prompts (block, wrapping) ────────────────────────────────
                if (d.positive_prompt_text) |v| {
                    dvui.label(@src(), "{s}", .{i18n.t(.detail_prompt)}, bp);
                    var tl = dvui.textLayout(@src(), .{}, lp);
                    tl.addText(v, .{});
                    tl.deinit();
                }
                if (d.negative_prompt_text) |v| {
                    dvui.label(@src(), "{s}", .{i18n.t(.detail_negative_prompt)}, bp);
                    var tl = dvui.textLayout(@src(), .{}, lp);
                    tl.addText(v, .{});
                    tl.deinit();
                }

                // ── Model (block) ────────────────────────────────────────────
                if (d.model) |v| {
                    dvui.label(@src(), "{s}", .{i18n.t(.detail_model)}, bp);
                    var tl = dvui.textLayout(@src(), .{}, lp);
                    tl.addText(v, .{});
                    tl.deinit();
                }

                // ── Sampler + Scheduler (side by side) ───────────────────────
                if (d.sampler != null or d.scheduler != null) {
                    var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hrow.deinit();
                    if (d.sampler) |v| {
                        var sampler_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer sampler_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_sampler)}, bp);
                        dvui.label(@src(), "{s}", .{v}, sp);
                    }
                    if (d.scheduler) |v| {
                        var scheduler_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer scheduler_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_scheduler)}, bp);
                        dvui.label(@src(), "{s}", .{v}, sp);
                    }
                }

                // ── CFG / Steps / Seed (compact row) ────────────────────────
                if (d.cfg != null or d.steps != null or d.seed != null) {
                    var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hrow.deinit();
                    if (d.cfg) |v| {
                        var cfg_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer cfg_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_cfg)}, bp);
                        dvui.label(@src(), "{d:.1}", .{v}, sp);
                    }
                    if (d.steps) |v| {
                        var steps_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer steps_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_steps)}, bp);
                        dvui.label(@src(), "{d}", .{v}, sp);
                    }
                    if (d.seed) |v| {
                        var seed_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer seed_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_seed)}, bp);
                        dvui.label(@src(), "{d}", .{v}, sp);
                    }
                }

                // ── Resolution + File Size (compact row) ─────────────────────
                if (d.width != null or d.file_size != null) {
                    var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hrow.deinit();
                    if (d.width) |w| {
                        if (d.height) |h| {
                            var res_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                            defer res_col.deinit();
                            dvui.label(@src(), "{s}", .{i18n.t(.detail_resolution)}, bp);
                            dvui.label(@src(), "{d}\u{00d7}{d}", .{ w, h }, sp);
                        }
                    }
                    if (d.file_size) |sz| {
                        const fb = fmtBytes(sz);
                        var size_col = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                        defer size_col.deinit();
                        dvui.label(@src(), "{s}", .{i18n.t(.detail_size)}, bp);
                        dvui.label(@src(), "{d:.1} {s}", .{ fb.value, fb.unit }, sp);
                    }
                }

                // ── LoRAs (block) ────────────────────────────────────────────
                if (d.loras) |v| {
                    dvui.label(@src(), "{s}", .{i18n.t(.detail_loras)}, bp);
                    var tl = dvui.textLayout(@src(), .{}, lp);
                    tl.addText(v, .{});
                    tl.deinit();
                }

                // ── Trashed / Path / Date (single-line rows) ─────────────────
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

                // ── Raw metadata (collapsible per chunk) ─────────────────────
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
            } else if (focused_id != null) {
                dvui.label(@src(), "(loading…)", .{}, .{ .padding = .all(8) });
            }
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
                dvui.label(@src(), "scanning\u{2026} {d} files", .{mgr.filesScanned()}, .{
                    .gravity_y = 0.5,
                    .margin = .{ .x = 4 },
                });
            }
            const displayed: usize = if (g_grid) |*grid| grid.images.items.len else 0;
            const is_filtered = g_filter_library_id != null or g_filter_folder != null;
            if (is_filtered) {
                dvui.label(@src(), "{d} {s} ({s} {d})", .{
                    displayed,
                    i18n.t(.status_images),
                    i18n.t(.status_out_of),
                    g_total_image_count,
                }, .{ .gravity_y = 0.5 });
            } else {
                dvui.label(@src(), "{d} {s}", .{ displayed, i18n.t(.status_images) }, .{ .gravity_y = 0.5 });
            }
        } else {
            dvui.label(@src(), "{s}", .{i18n.t(.status_no_database)}, .{ .gravity_y = 0.5 });
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
            const lib = &g_libraries.items[idx];
            const name = std.fs.path.basename(lib.path);

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

            dvui.label(@src(), "{s}", .{i18n.t(.library_remove_title)}, .{ .font = bold, .margin = .{ .h = 6 } });
            dvui.label(@src(), "{s}", .{name}, .{});
            dvui.label(@src(), "{s}", .{lib.path}, .{ .margin = .{ .h = 14 } });

            {
                var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
                defer btn_row.deinit();

                if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                }
                if (dvui.button(@src(), i18n.t(.action_remove), .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                    if (dvui.App.main_init) |init| {
                        var removed = g_libraries.orderedRemove(idx);
                        const removed_id = removed.id;
                        if (g_library_manager) |*mgr| {
                            mgr.removeLibrary(removed.path) catch {};
                        } else if (g_db) |*db| {
                            _ = db.removeLibrary(removed.path) catch {};
                        }
                        removed.deinit(init.gpa);
                        // Clear filter if it was pointing at the removed library.
                        if (g_filter_library_id == removed_id) {
                            if (g_filter_folder) |f| init.gpa.free(f);
                            g_filter_folder = null;
                            g_filter_library_id = null;
                            if (g_grid) |*grid| {
                                grid.filter_library_id = null;
                                grid.filter_folder_path = null;
                            }
                        }
                        if (g_grid) |*grid| {
                            if (g_db) |*db| grid.reloadImages(db) catch {};
                        }
                        refreshCounts();
                    }
                }
            }
        } else {
            g_confirm_remove_idx = null;
        }
    }

    // ── Delete confirmation modal ─────────────────────────────────────────────
    if (g_delete_dialog_open) try deleteConfirmDialog();

    // ── Filter modal ──────────────────────────────────────────────────────────
    if (g_filter_modal_open) try filterModal();

    return .ok;
}
