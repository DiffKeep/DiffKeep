const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");
const icons = @import("icons");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const library_manager_mod = @import("library_manager.zig");
const fs_watch_mod = @import("fs_watch.zig");
const image_grid_mod = @import("image_grid.zig");
const llama_mod = @import("llama.zig");
const mtmd_mod = @import("mtmd.zig");
const vips_mod = @import("vips");
const SDLBackend = @import("backend");
const detail_panel_mod = @import("detail_panel.zig");
const sidebar_mod = @import("sidebar.zig");
const image_viewer_mod = @import("image_viewer.zig");
const dnd_mod = @import("dnd.zig");

const noto_cjk_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
const noto_cjk_bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

// Path to the config file: set from --config/-c flag, otherwise resolved from known folders.
var g_config: ?[]const u8 = null;
var g_cfg: config_mod.Config = .{};
var g_db: ?db_mod.VectorDb = null;
// Directory that contains the DB file — also used as root for the trash folder.
var g_data_dir: ?[]const u8 = null;

var g_library_manager: ?library_manager_mod.LibraryManager = null;
var g_fs_watcher: ?fs_watch_mod.FsWatcher = null;
/// Pending per-file events collected from the watcher, waiting for the short
/// debounce window to expire before being dispatched to LibraryManager.
var g_pending_file_events: std.ArrayList(fs_watch_mod.DirtyEvent) = .empty;
/// Absolute nanosecond timestamp (Io.Clock.real) after which pending file
/// events should be flushed.  0 means nothing is pending.
var g_rescan_deadline_ns: i96 = 0;
var g_grid: ?image_grid_mod.GridState = null;
var g_wakeup_event_type: u32 = 0;

fn wakeupFrame() void {
    var ev: SDLBackend.c.SDL_Event = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ev.type = g_wakeup_event_type;
    _ = SDLBackend.c.SDL_PushEvent(&ev);
}
var g_settings_open: bool = false;
var g_db_stats: ?db_mod.DbStats = null;
var g_trash_stats: ?db_mod.TrashStats = null;
var g_total_image_count: i64 = 0;

var g_sidebar: sidebar_mod.SidebarState = .{};
var g_detail: detail_panel_mod.DetailState = .{};
var g_dnd: ?dnd_mod.DragSource = null;
var g_dnd_drag_cursor: ?*SDLBackend.c.SDL_Cursor = null;

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

// Search state: text buffer written by the textEntry widget each frame.
// g_search_prev mirrors it so we can detect changes and trigger a DB reload.
var g_search_buf: [256]u8 = std.mem.zeroes([256]u8);
var g_search_prev: [256]u8 = std.mem.zeroes([256]u8);

// Search mode
var g_search_mode: image_grid_mod.SearchMode = .combined;

// Per-search model instances for query embedding (separate from scan models)
var g_search_text_pool: ?llama_mod.Pool = null;
var g_search_vl_ctx: ?mtmd_mod.VlContext = null;

// Heap-allocated query embedding (freed on next query change or app exit)
var g_query_embedding: ?[]const f32 = null;

// Model path settings buffers (copied from/to g_cfg on settings open/close)
var g_embedding_model_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8);
var g_embedding_mmproj_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8);
var g_reranker_model_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8);
var g_reranker_mmproj_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8);
// Snapshot of paths when settings opened (detect changes on close)
var g_settings_model_snapshot: struct {
    model: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    mmproj: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    reranker: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    reranker_mmproj: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
} = .{};

// Reranker model instance (separate from scan models, used on main search thread)
var g_search_reranker: ?mtmd_mod.RerankContext = null;

// Background reranking state
var g_rerank_group: std.Io.Group = .init;
var g_rerank_done: std.atomic.Value(bool) = .init(false);
var g_rerank_result_ids: ?[]u64 = null;
var g_rerank_result_gen: u64 = 0;
var g_search_generation: std.atomic.Value(u64) = .init(0);
var g_picker_open: bool = false;
// Must be a global — SDL_ShowOpenFileDialog is async and reads the filter after the call returns.
const g_gguf_filter = SDLBackend.c.SDL_DialogFileFilter{ .name = "GGUF model", .pattern = "gguf" };

// Model download state (one slot per file: embedding, mmproj, reranker, reranker_mmproj)
const download_quant_options = [_][:0]const u8{
    "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
    "Q4_K_S", "Q4_K_M", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
};
var g_download_quant_idx: usize = 9; // Q8_0
var g_download_status: [4]std.atomic.Value(u8) = .{ .init(0), .init(0), .init(0), .init(0) };
var g_download_group: std.Io.Group = .init;

// Active metadata filters
var g_active_filters: std.ArrayList(db_mod.ActiveFilter) = .empty;

// Filter modal state
var g_filter_modal_open: bool = false;
var g_filter_modal_kind: db_mod.FilterColumn = .model;
var g_filter_modal_value_buf: [256]u8 = std.mem.zeroes([256]u8);
var g_filter_modal_options: ?[][]const u8 = null;
var g_filter_modal_options_kind: ?db_mod.FilterColumn = null;

/// Refresh image counts for all libraries, total count, and trash stats.
/// Called at init and after any operation that changes counts.
fn refreshCounts() void {
    if (dvui.App.main_init) |init| {
        if (g_db) |*db| {
            g_total_image_count = db.getTotalImageCount() catch 0;
            g_trash_stats = db.getTrashStats() catch null;
            g_sidebar.refreshLibraryCounts(db, init.gpa);
        }
    }
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

        if (g_cfg.embedding_model_path) |p| {
            const len = @min(p.len, g_embedding_model_buf.len - 1);
            @memcpy(g_embedding_model_buf[0..len], p[0..len]);
            g_embedding_model_buf[len] = 0;
        }
        if (g_cfg.embedding_mmproj_path) |p| {
            const len = @min(p.len, g_embedding_mmproj_buf.len - 1);
            @memcpy(g_embedding_mmproj_buf[0..len], p[0..len]);
            g_embedding_mmproj_buf[len] = 0;
        }
        if (g_cfg.reranker_model_path) |p| {
            const len = @min(p.len, g_reranker_model_buf.len - 1);
            @memcpy(g_reranker_model_buf[0..len], p[0..len]);
            g_reranker_model_buf[len] = 0;
        }
        if (g_cfg.reranker_mmproj_path) |p| {
            const len = @min(p.len, g_reranker_mmproj_buf.len - 1);
            @memcpy(g_reranker_mmproj_buf[0..len], p[0..len]);
            g_reranker_mmproj_buf[len] = 0;
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
            try g_sidebar.loadLibraries(init.gpa, db);

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

            // Start the fs watcher before the library manager so it's ready to
            // receive addLibrary commands as soon as the manager is created.
            // init() only creates fds; start() spawns the thread.  start() must
            // be called AFTER the value is stored in g_fs_watcher so the thread
            // receives a stable pointer (same rule as GridState.startWorker).
            g_fs_watcher = fs_watch_mod.FsWatcher.init(init.gpa) catch |err| blk: {
                std.log.warn("fs_watch init failed: {}; live watching disabled", .{err});
                break :blk null;
            };
            if (g_fs_watcher) |*watcher| {
                watcher.start() catch |err| {
                    std.log.warn("fs_watch start failed: {}; live watching disabled", .{err});
                    watcher.deinit();
                    g_fs_watcher = null;
                };
                // Wake dvui's event loop whenever the watcher pushes a new file event,
                // so frame() is called even when the user isn't moving the mouse.
                if (g_fs_watcher != null) g_fs_watcher.?.on_dirty = wakeupFrame;
            }

            // Assign to global BEFORE calling scanAllLibraries so that enqueue()'s
            // concurrent task receives &g_library_manager.? (stable global address)
            // rather than a pointer to a stack-local that becomes dangling after appInit returns.
            const notifier = if (g_grid) |*grid| &grid.notifier else null;
            const watcher_ptr: ?*fs_watch_mod.FsWatcher = if (g_fs_watcher != null) &g_fs_watcher.? else null;
            g_library_manager = library_manager_mod.LibraryManager.init(init.gpa, db, g_cfg.thumbnails_in_db, g_cfg.prompt_embeddings, g_cfg.image_embeddings, notifier, watcher_ptr);
            if (g_library_manager) |*mgr| {
                mgr.embedding_model_path = g_cfg.embedding_model_path;
                mgr.embedding_mmproj_path = g_cfg.embedding_mmproj_path;
                mgr.wakeup_fn = wakeupFrame;
                mgr.scanAllLibraries(init.io) catch |err| {
                    std.log.warn("startup scan queue failed: {}", .{err});
                };
            }

            // Register all existing libraries with the watcher.
            if (g_fs_watcher) |*watcher| {
                const libs = db.listLibraries(init.gpa) catch &[_]db_mod.LibraryInfo{};
                defer {
                    for (libs) |li| init.gpa.free(li.path);
                    init.gpa.free(libs);
                }
                for (libs) |li| {
                    watcher.addLibrary(li.id, li.path) catch {};
                }
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

    try initWindowFontsAndTheme();
}

fn appDeinit() void {
    if (g_dnd) |*dnd| dnd.deinit();
    // Stop the fs watcher thread before anything else so it can't fire callbacks
    // against already-freed state.
    if (g_fs_watcher) |*watcher| watcher.deinit();
    // Stop all threads that use VIPS before calling vips_shutdown().
    if (dvui.App.main_init) |init| {
        if (g_library_manager) |*mgr| mgr.deinit(init.io);
    }
    if (dvui.App.main_init) |init| {
        g_rerank_group.await(init.io) catch {};
        g_download_group.await(init.io) catch {};
    }
    if (g_rerank_result_ids) |ids| {
        if (dvui.App.main_init) |init| init.gpa.free(ids);
        g_rerank_result_ids = null;
    }
    if (g_search_reranker) |*rr| rr.deinit();
    if (g_search_vl_ctx) |*vc| vc.deinit();
    if (g_search_text_pool) |*tp| tp.deinit();
    if (dvui.App.main_init) |init| {
        if (g_query_embedding) |emb| init.gpa.free(emb);
    }
    if (g_grid) |*grid| grid.deinit();
    vips_mod.deinit();
    if (g_db) |*database| {
        database.deinit();
        database.pool.deinit();
    }
    if (dvui.App.main_init) |init| {
        g_detail.deinit(init.gpa);
        g_sidebar.deinit(init.gpa);
        if (g_config) |cfg_path| {
            config_mod.save(g_cfg, init.io, cfg_path) catch |err| {
                std.log.warn("failed to save config: {}", .{err});
            };
            init.gpa.free(cfg_path);
        }
        g_cfg.deinit(init.gpa);
        if (g_data_dir) |d| init.gpa.free(d);
        for (g_active_filters.items) |f| init.gpa.free(f.value);
        g_active_filters.deinit(init.gpa);
        for (g_pending_file_events.items) |ev| init.gpa.free(ev.path);
        g_pending_file_events.deinit(init.gpa);
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

fn applyRerankResults(allocator: std.mem.Allocator) void {
    const ids = g_rerank_result_ids orelse return;
    defer {
        allocator.free(ids);
        g_rerank_result_ids = null;
    }
    if (g_rerank_result_gen != g_search_generation.load(.acquire)) return;
    const grid = if (g_grid) |*g| g else return;

    var pos_map = std.AutoHashMap(u64, usize).init(allocator);
    defer pos_map.deinit();
    for (grid.images.items, 0..) |entry, i| {
        pos_map.put(entry.id, i) catch {};
    }

    var reordered: std.ArrayList(image_grid_mod.ImageEntry) = .empty;
    defer reordered.deinit(allocator);
    reordered.ensureTotalCapacity(allocator, grid.images.items.len) catch return;
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    for (ids) |id| {
        if (pos_map.get(id)) |pos| {
            reordered.append(allocator, grid.images.items[pos]) catch {};
            seen.put(id, {}) catch {};
        }
    }
    for (grid.images.items) |entry| {
        if (!seen.contains(entry.id)) {
            reordered.append(allocator, entry) catch {};
        }
    }
    if (reordered.items.len == grid.images.items.len) {
        @memcpy(grid.images.items, reordered.items);
        grid.focused_idx = null;
        grid.selection.clearRetainingCapacity();
    }
}

// ── Background reranking ───────────────────────────────────────────────────

const RerankTaskCtx = struct {
    allocator: std.mem.Allocator,
    query: []const u8,         // owned, freed after task
    image_paths: [][]u8,       // owned, freed after task
    image_ids: []u64,          // owned, freed after task
    generation: u64,
    reranker: *mtmd_mod.RerankContext,
    result_ids: *?[]u64,
    result_gen: *u64,
    done: *std.atomic.Value(bool),
    current_gen: *std.atomic.Value(u64),
};

const RERANK_INSTRUCTION = "Retrieve AI-generated images that visually match the user's search query.";

fn rerankTask(ctx: RerankTaskCtx) void {
    defer {
        ctx.allocator.free(ctx.query);
        for (ctx.image_paths) |p| ctx.allocator.free(p);
        ctx.allocator.free(ctx.image_paths);
        ctx.allocator.free(ctx.image_ids);
    }
    if (ctx.current_gen.load(.acquire) != ctx.generation) return;

    const ScoreEntry = struct { id: u64, score: f32 };
    var scored: std.ArrayList(ScoreEntry) = .empty;
    defer scored.deinit(ctx.allocator);

    for (ctx.image_paths, ctx.image_ids) |path, id| {
        if (ctx.current_gen.load(.acquire) != ctx.generation) return;
        const score = ctx.reranker.scoreImageFile(ctx.allocator, ctx.query, RERANK_INSTRUCTION, path) catch 0.0;
        scored.append(ctx.allocator, .{ .id = id, .score = score }) catch break;
    }
    if (ctx.current_gen.load(.acquire) != ctx.generation) return;

    std.sort.pdq(ScoreEntry, scored.items, {}, struct {
        fn lt(_: void, a: ScoreEntry, b: ScoreEntry) bool { return a.score > b.score; }
    }.lt);

    const ids = ctx.allocator.alloc(u64, scored.items.len) catch return;
    for (scored.items, 0..) |s, i| ids[i] = s.id;

    ctx.result_ids.* = ids;
    ctx.result_gen.* = ctx.generation;
    ctx.done.store(true, .release);
}

/// Spawns a background rerank task for the current grid results (top rerank_top_k entries).
/// No-op if the reranker is not configured or mode is FTS.
fn maybeSpawnRerank(grid: *image_grid_mod.GridState, query: []const u8) void {
    const init = dvui.App.main_init orelse return;
    const reranker_model = g_cfg.reranker_model_path orelse return;
    const reranker_mmproj = g_cfg.reranker_mmproj_path orelse return;
    if (g_search_mode == .fts) return;
    if (grid.images.items.len == 0) return;

    if (g_search_reranker == null) {
        g_search_reranker = mtmd_mod.RerankContext.init(init.gpa, reranker_model, reranker_mmproj) catch |err| {
            log.warn("reranker init: {}", .{err});
            return;
        };
    }

    const gen = g_search_generation.fetchAdd(1, .acq_rel) + 1;
    g_rerank_done.store(false, .release);
    if (g_rerank_result_ids) |ids| { init.gpa.free(ids); g_rerank_result_ids = null; }

    const top_k = @min(grid.images.items.len, g_cfg.rerank_top_k);
    var image_paths = init.gpa.alloc([]u8, top_k) catch return;
    const image_ids = init.gpa.alloc(u64, top_k) catch { init.gpa.free(image_paths); return; };
    var n: usize = 0;
    for (grid.images.items[0..top_k]) |entry| {
        image_paths[n] = init.gpa.dupe(u8, entry.path) catch break;
        image_ids[n] = entry.id;
        n += 1;
    }
    if (n < top_k) {
        for (image_paths[0..n]) |p| init.gpa.free(p);
        init.gpa.free(image_paths);
        init.gpa.free(image_ids);
        return;
    }

    const query_copy = init.gpa.dupe(u8, query) catch {
        for (image_paths) |p| init.gpa.free(p);
        init.gpa.free(image_paths);
        init.gpa.free(image_ids);
        return;
    };

    const ctx = RerankTaskCtx{
        .allocator = init.gpa,
        .query = query_copy,
        .image_paths = image_paths,
        .image_ids = image_ids,
        .generation = gen,
        .reranker = &g_search_reranker.?,
        .result_ids = &g_rerank_result_ids,
        .result_gen = &g_rerank_result_gen,
        .done = &g_rerank_done,
        .current_gen = &g_search_generation,
    };
    g_rerank_group.concurrent(init.io, rerankTask, .{ctx}) catch |err| {
        log.warn("spawn rerank task: {}", .{err});
        init.gpa.free(query_copy);
        for (image_paths) |p| init.gpa.free(p);
        init.gpa.free(image_paths);
        init.gpa.free(image_ids);
    };
}

// ── Model download ─────────────────────────────────────────────────────────

const DownloadTaskCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,       // owned
    dest_path: []const u8, // owned
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
        ctx.status.store(3, .release); // failed
        return;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        ctx.status.store(3, .release); // failed
    } else {
        ctx.status.store(2, .release); // done
    }
}

/// Spawns a curl download for the given slot. Does nothing if already running.
fn spawnDownload(
    init: std.process.Init,
    slot: usize,
    url: []const u8,
    dest_path: []const u8,
) void {
    if (g_download_status[slot].load(.acquire) == 1) return; // already running
    const url_copy = init.gpa.dupe(u8, url) catch return;
    const dest_copy = init.gpa.dupe(u8, dest_path) catch { init.gpa.free(url_copy); return; };
    const ctx = DownloadTaskCtx{
        .allocator = init.gpa,
        .io = init.io,
        .url = url_copy,
        .dest_path = dest_copy,
        .slot = slot,
        .status = &g_download_status[slot],
    };
    g_download_status[slot].store(1, .release);
    g_download_group.concurrent(init.io, downloadTask, .{ctx}) catch |err| {
        log.warn("spawn download task: {}", .{err});
        g_download_status[slot].store(0, .release);
        init.gpa.free(url_copy);
        init.gpa.free(dest_copy);
    };
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

fn settingsModal() !void {
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
        .open_flag = &g_settings_open,
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
            _ = dvui.checkbox(@src(), &g_cfg.thumbnails_in_db, i18n.t(.settings_thumbnails_in_db), .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.prompt_embeddings, i18n.t(.settings_prompt_embeddings), .{ .margin = .{ .h = 6 } });
            _ = dvui.checkbox(@src(), &g_cfg.image_embeddings, i18n.t(.settings_image_embeddings), .{ .margin = .{ .h = 6 } });

            // Embedding model paths
            dvui.label(@src(), "{s}", .{i18n.t(.settings_model_path)}, .{ .font = bold, .margin = .{ .y = 12, .h = 4 } });
            pathEntryWithPicker(@src(), &g_embedding_model_buf, i18n.t(.settings_model_placeholder), 0);

            dvui.label(@src(), "{s}", .{i18n.t(.settings_mmproj_path)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
            pathEntryWithPicker(@src(), &g_embedding_mmproj_buf, i18n.t(.settings_mmproj_placeholder), 1);

            // Reranker section
            dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_section)}, .{ .font = bold, .margin = .{ .y = 16, .h = 4 } });

            dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_model_path)}, .{ .font = bold, .margin = .{ .y = 4, .h = 4 } });
            pathEntryWithPicker(@src(), &g_reranker_model_buf, i18n.t(.settings_reranker_model_placeholder), 2);

            dvui.label(@src(), "{s}", .{i18n.t(.settings_reranker_mmproj_path)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
            pathEntryWithPicker(@src(), &g_reranker_mmproj_buf, i18n.t(.settings_reranker_mmproj_placeholder), 3);

            dvui.label(@src(), "{s}", .{i18n.t(.settings_rerank_top_k)}, .{ .font = bold, .margin = .{ .y = 8, .h = 4 } });
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 4 } });
                defer row.deinit();
                if (dvui.button(@src(), "-", .{}, .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 28, .h = 24 },
                    .corner_radius = dvui.Rect.all(4),
                })) {
                    if (g_cfg.rerank_top_k > 1) g_cfg.rerank_top_k -= 1;
                }
                dvui.label(@src(), " {d} ", .{g_cfg.rerank_top_k}, .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 44 },
                });
                if (dvui.button(@src(), "+", .{}, .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 28, .h = 24 },
                    .corner_radius = dvui.Rect.all(4),
                })) {
                    if (g_cfg.rerank_top_k < 200) g_cfg.rerank_top_k += 1;
                }
            }

            // Trash section
            dvui.label(@src(), "{s}", .{i18n.t(.settings_trash_section)}, .{ .font = bold, .margin = .{ .y = 20, .h = 8 } });
            _ = dvui.checkbox(@src(), &g_cfg.trash_enabled, i18n.t(.settings_trash_enable), .{ .margin = .{ .h = 6 } });
            if (g_cfg.trash_enabled) {
                if (g_trash_stats) |ts| {
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
                                    if (g_grid) |*grid| {
                                        if (grid.view_mode == .trash) grid.reloadImages(db) catch {};
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

        // ── Right column ──────────────────────────────────────────────────
        {
            var right_col = dvui.box(@src(), .{}, .{
                .expand = .both,
                .min_size_content = .{ .w = 280 },
                .padding = .{ .x = 12 },
            });
            defer right_col.deinit();

            // Database section
            dvui.label(@src(), "{s}", .{i18n.t(.settings_database_section)}, .{ .font = bold, .margin = .{ .h = 8 } });
            if (g_db_stats) |stats| {
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
                        if (g_db) |*db| {
                            r.clear_fn(db) catch {};
                            g_db_stats = db.getStats() catch null;
                        }
                    }
                }
            } else {
                dvui.label(@src(), "{s}", .{i18n.t(.settings_db_no_database)}, .{});
            }

            // Download section
            dvui.label(@src(), "{s}", .{i18n.t(.settings_download_section)}, .{ .font = bold, .margin = .{ .y = 20, .h = 8 } });
            if (g_data_dir) |data_dir| {
                // Quantization selector
                dvui.label(@src(), "{s}", .{i18n.t(.settings_download_quantization)}, .{ .font = bold, .margin = .{ .h = 4 } });
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 8 } });
                    defer row.deinit();
                    if (dvui.button(@src(), "◀", .{}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 28, .h = 24 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_download_quant_idx > 0) g_download_quant_idx -= 1;
                    }
                    dvui.label(@src(), " {s} ", .{download_quant_options[g_download_quant_idx]}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 56 },
                    });
                    if (dvui.button(@src(), "▶", .{}, .{
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 28, .h = 24 },
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (g_download_quant_idx + 1 < download_quant_options.len) g_download_quant_idx += 1;
                    }
                }
                const quant = download_quant_options[g_download_quant_idx];
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
                    const status: u8 = g_download_status[fi].load(.acquire);
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
                            const dest = std.fs.path.join(init.gpa, &.{ data_dir, "models", "search", filename }) catch continue;
                            defer init.gpa.free(dest);
                            spawnDownload(init, fi, url, dest);
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

fn embedSearchQuery(allocator: std.mem.Allocator, query: []const u8, mode: image_grid_mod.SearchMode) !void {
    const model_path = g_cfg.embedding_model_path orelse return error.NoModelPath;
    switch (mode) {
        .fts => {},
        // semantic and combined both use the text pool (mean pooling) for query embedding
        .semantic, .combined => {
            if (g_search_text_pool == null) {
                g_search_text_pool = llama_mod.Pool.init(allocator, .{
                    .embeddings   = true,
                    .pooling_type = 1,
                    .n_ctx        = 2048,
                    .n_batch      = 512,
                    .n_ubatch     = 512,
                    .n_gpu_layers = 999,
                });
            }
            const tp = &g_search_text_pool.?;
            const q_text = try std.fmt.allocPrint(allocator, "search_query: {s}", .{query});
            defer allocator.free(q_text);
            const tc = try tp.get(model_path, 60_000, null);
            defer tp.release(tc);
            var chunks = try llama_mod.createEmbeddingFromPrompt(allocator, tc, q_text, 2048);
            defer {
                for (chunks.items) |e| allocator.free(e);
                chunks.deinit(allocator);
            }
            if (chunks.items.len > 0) {
                g_query_embedding = chunks.orderedRemove(0);
                if (g_grid) |*grid| grid.query_embedding = g_query_embedding.?;
            }
        },
        .visual => {
            const mmproj_path = g_cfg.embedding_mmproj_path orelse return error.NoMmprojPath;
            if (g_search_vl_ctx == null) {
                g_search_vl_ctx = try mtmd_mod.VlContext.init(allocator, model_path, mmproj_path);
            }
            const vc = &g_search_vl_ctx.?;
            const q_text = try std.fmt.allocPrint(allocator, "search_query: {s}", .{query});
            defer allocator.free(q_text);
            // For visual mode: embed the text query through the VL text encoder
            const tc = try vc.pool.get(model_path, 60_000, null);
            defer vc.pool.release(tc);
            var chunks = try llama_mod.createEmbeddingFromPrompt(allocator, tc, q_text, 2048);
            defer {
                for (chunks.items) |e| allocator.free(e);
                chunks.deinit(allocator);
            }
            if (chunks.items.len > 0) {
                g_query_embedding = chunks.orderedRemove(0);
                if (g_grid) |*grid| grid.query_embedding = g_query_embedding.?;
            }
        },
    }
}

fn renderToolbar() void {
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

    // Search mode buttons
    {
        const modes = [_]struct { mode: image_grid_mod.SearchMode, label: [:0]const u8 }{
            .{ .mode = .fts,      .label = i18n.t(.search_mode_fts) },
            .{ .mode = .semantic, .label = i18n.t(.search_mode_semantic) },
            .{ .mode = .visual,   .label = i18n.t(.search_mode_visual) },
            .{ .mode = .combined, .label = i18n.t(.search_mode_combined) },
        };
        for (modes, 0..) |m, mi| {
            const active = g_search_mode == m.mode;
            if (dvui.button(@src(), m.label, .{}, .{
                .id_extra = mi,
                .gravity_y = 0.5,
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 2, .w = 2 },
                .color_fill = if (active) dvui.themeGet().focus else null,
            })) {
                if (g_search_mode != m.mode) {
                    g_search_mode = m.mode;
                    // Force reload with new mode
                    if (g_grid) |*grid| {
                        grid.search_mode = m.mode;
                        // Clear embedding if switching to FTS
                        if (m.mode == .fts) {
                            grid.query_embedding = null;
                        }
                        if (g_db) |*db| grid.reloadImages(db) catch {};
                    }
                    // Trigger re-embed on mode switch
                    g_search_prev = std.mem.zeroes([256]u8);
                }
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 0 } });

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

fn renderContent() !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true });
    defer row.deinit();

    // ── Left sidebar ──────────────────────────────────────────────────
    if (g_left_w >= 2) {
        if (dvui.App.main_init) |init| {
            if (try g_sidebar.render(
                g_left_w,
                init.gpa,
                if (g_db) |*db| db else null,
                if (g_grid) |*g| g else null,
                if (g_library_manager) |*mgr| mgr else null,
                g_cfg.trash_enabled,
                g_trash_stats,
            )) refreshCounts();
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
        const focused_id: ?u64 = if (g_grid) |*grid|
            if (grid.focused_idx) |fi|
                (if (fi < grid.images.items.len) grid.images.items[fi].id else null)
            else null
        else null;
        const filename: []const u8 = if (g_grid) |*grid|
            if (grid.focused_idx) |fi|
                (if (fi < grid.images.items.len) grid.images.items[fi].filename else "")
            else ""
        else "";
        if (dvui.App.main_init) |init| {
            if (g_db) |*db| g_detail.update(focused_id, db, init.gpa, init.io);
            g_detail.renderPanel(g_right_w, filename, init.gpa, init.io);
        }
    }
}

fn renderStatusBar() void {
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
        const is_filtered = g_sidebar.filter_library_id != null or g_sidebar.filter_folder != null;
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
            @memcpy(&g_settings_model_snapshot.model, &g_embedding_model_buf);
            @memcpy(&g_settings_model_snapshot.mmproj, &g_embedding_mmproj_buf);
            @memcpy(&g_settings_model_snapshot.reranker, &g_reranker_model_buf);
            @memcpy(&g_settings_model_snapshot.reranker_mmproj, &g_reranker_mmproj_buf);
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
        // Reload grid when a watcher-triggered deletion has been committed to the DB.
        if (g_library_manager) |*mgr| {
            if (mgr.reload_requested.load(.acquire)) {
                mgr.reload_requested.store(false, .release);
                if (g_db) |*db| grid.reloadImages(db) catch {};
            }
        }
        if (grid.images.items.len != prev_len) {
            if (g_db) |*db| {
                g_total_image_count = db.getTotalImageCount() catch g_total_image_count;
                for (g_sidebar.libraries.items) |*lib| {
                    lib.image_count = db.getLibraryImageCount(lib.id) catch lib.image_count;
                }
            }
        }
    }

    // Apply rerank results when the background task completes
    if (g_rerank_done.load(.acquire)) {
        g_rerank_done.store(false, .release);
        if (dvui.App.main_init) |init| {
            applyRerankResults(init.gpa);
        }
    }

    // Apply completed model downloads (auto-fill config paths)
    if (dvui.App.main_init) |init| {
        if (g_data_dir) |data_dir| {
            const slots = [_]struct { slot: usize, cfg_field: enum { emb, mmproj, rr, rr_mmproj } }{
                .{ .slot = 0, .cfg_field = .emb },
                .{ .slot = 1, .cfg_field = .mmproj },
                .{ .slot = 2, .cfg_field = .rr },
                .{ .slot = 3, .cfg_field = .rr_mmproj },
            };
            const quant = download_quant_options[g_download_quant_idx];
            for (slots) |s| {
                if (g_download_status[s.slot].load(.acquire) == 2) {
                    // Build the expected dest path and auto-fill if config is empty
                    const filename: []const u8 = switch (s.cfg_field) {
                        .emb  => std.fmt.allocPrint(init.gpa, "Qwen.Qwen3-VL-Embedding-2B.{s}.gguf", .{quant}) catch continue,
                        .mmproj => init.gpa.dupe(u8, "mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf") catch continue,
                        .rr   => std.fmt.allocPrint(init.gpa, "Qwen3-VL-Reranker-2B.{s}.gguf", .{quant}) catch continue,
                        .rr_mmproj => init.gpa.dupe(u8, "Qwen3-VL-Reranker-2B.mmproj-f16.gguf") catch continue,
                    };
                    defer init.gpa.free(filename);
                    const dest = std.fs.path.join(init.gpa, &.{ data_dir, "models", "search", filename }) catch continue;
                    defer init.gpa.free(dest);
                    switch (s.cfg_field) {
                        .emb => if (g_cfg.embedding_model_path == null) {
                            g_cfg.embedding_model_path = init.gpa.dupe(u8, dest) catch null;
                            const len = @min(dest.len, g_embedding_model_buf.len - 1);
                            @memcpy(g_embedding_model_buf[0..len], dest[0..len]);
                            g_embedding_model_buf[len] = 0;
                        },
                        .mmproj => if (g_cfg.embedding_mmproj_path == null) {
                            g_cfg.embedding_mmproj_path = init.gpa.dupe(u8, dest) catch null;
                            const len = @min(dest.len, g_embedding_mmproj_buf.len - 1);
                            @memcpy(g_embedding_mmproj_buf[0..len], dest[0..len]);
                            g_embedding_mmproj_buf[len] = 0;
                        },
                        .rr => if (g_cfg.reranker_model_path == null) {
                            g_cfg.reranker_model_path = init.gpa.dupe(u8, dest) catch null;
                            const len = @min(dest.len, g_reranker_model_buf.len - 1);
                            @memcpy(g_reranker_model_buf[0..len], dest[0..len]);
                            g_reranker_model_buf[len] = 0;
                        },
                        .rr_mmproj => if (g_cfg.reranker_mmproj_path == null) {
                            g_cfg.reranker_mmproj_path = init.gpa.dupe(u8, dest) catch null;
                            const len = @min(dest.len, g_reranker_mmproj_buf.len - 1);
                            @memcpy(g_reranker_mmproj_buf[0..len], dest[0..len]);
                            g_reranker_mmproj_buf[len] = 0;
                        },
                    }
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
        if (grid.open_viewer_requested) {
            grid.open_viewer_requested = false;
            openViewer(grid, grid.viewer_start_id);
            grid.viewer_start_id = null;
        }
        if (grid.copy_prompt_requested) {
            grid.copy_prompt_requested = false;
            if (dvui.App.main_init) |init| {
                if (g_db) |*db| {
                    if (db.getPositivePromptText(init.gpa, grid.copy_prompt_id) catch null) |prompt| {
                        defer init.gpa.free(prompt);
                        if (init.gpa.dupeZ(u8, prompt)) |c_str| {
                            defer init.gpa.free(c_str);
                            _ = SDLBackend.c.SDL_SetClipboardText(c_str.ptr);
                        } else |_| {}
                    }
                }
            }
        }
        if (grid.copy_image_requested) {
            grid.copy_image_requested = false;
            if (dvui.App.main_init) |init| {
                detail_panel_mod.copyImageToClipboard(grid.copy_image_path, init.gpa, init.io);
            }
        }
        if (grid.drag_requested) {
            grid.drag_requested = false;
            if (g_dnd) |*dnd| {
                if (dvui.App.main_init) |init| {
                    var items: std.ArrayList(dnd_mod.DragItem) = .empty;
                    defer items.deinit(init.gpa);
                    for (grid.drag_requested_ids.items) |id| {
                        for (grid.images.items) |entry| {
                            if (entry.id != id) continue;
                            const thumb = grid.committed.get(id);
                            items.append(init.gpa, .{
                                .path       = entry.path,
                                .thumb_jpeg = if (thumb) |t| t.bytes else &.{},
                            }) catch break;
                            break;
                        }
                    }
                    dnd.startDrag(items.items);
                }
            }
            grid.drag_requested_ids.clearRetainingCapacity();
        }
    }

    // Detect search text changes and reload the grid
    if (!std.mem.eql(u8, &g_search_buf, &g_search_prev)) {
        @memcpy(&g_search_prev, &g_search_buf);
        const q = std.mem.sliceTo(&g_search_buf, 0);
        if (g_grid) |*grid| {
            grid.search_mode = g_search_mode;
            switch (g_search_mode) {
                .fts => {
                    grid.search_query = if (q.len > 0) q else null;
                    grid.query_embedding = null;
                    if (g_query_embedding) |emb| {
                        if (dvui.App.main_init) |init| init.gpa.free(emb);
                        g_query_embedding = null;
                    }
                    if (g_db) |*db| grid.reloadImages(db) catch {};
                },
                .semantic, .visual, .combined => {
                    grid.search_query = null;
                    if (g_query_embedding) |emb| {
                        if (dvui.App.main_init) |init| init.gpa.free(emb);
                        g_query_embedding = null;
                    }
                    grid.query_embedding = null;
                    if (q.len > 0) {
                        if (dvui.App.main_init) |init| {
                            embedSearchQuery(init.gpa, q, g_search_mode) catch |err| {
                                log.warn("search embed: {}", .{err});
                            };
                        }
                    }
                    if (g_db) |*db| grid.reloadImages(db) catch {};
                    if (q.len > 0) maybeSpawnRerank(grid, q);
                },
            }
        }
    }

    if (dvui.App.main_init) |init| {
        try g_sidebar.drainPendingLibrary(
            init.gpa,
            init.io,
            if (g_library_manager) |*mgr| mgr else null,
            if (g_db) |*db| db else null,
        );
    }

    // ── Watcher-driven per-file processing (200 ms debounce) ─────────────
    if (dvui.App.main_init) |init| {
        if (g_fs_watcher) |*watcher| {
            var new_events = watcher.drainEvents();
            defer new_events.deinit(init.gpa);
            if (new_events.items.len > 0) {
                const now_ns = std.Io.Clock.real.now(init.io).nanoseconds;
                g_rescan_deadline_ns = now_ns + 200 * std.time.ns_per_ms;
                // Merge into pending list, deduplicating by path.
                for (new_events.items) |ev| {
                    var dup = false;
                    for (g_pending_file_events.items) |*existing| {
                        if (std.mem.eql(u8, existing.path, ev.path)) {
                            existing.deleted = ev.deleted;
                            init.gpa.free(ev.path);
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        g_pending_file_events.append(init.gpa, ev) catch {
                            init.gpa.free(ev.path);
                        };
                    }
                }
            }
        }
        if (g_rescan_deadline_ns != 0) {
            const now_ns = std.Io.Clock.real.now(init.io).nanoseconds;
            if (now_ns >= g_rescan_deadline_ns) {
                g_rescan_deadline_ns = 0;
                if (g_library_manager) |*mgr| {
                    for (g_pending_file_events.items) |ev| {
                        mgr.processFileEvent(init.io, ev.library_id, ev.path, ev.deleted);
                    }
                } else {
                    for (g_pending_file_events.items) |ev| init.gpa.free(ev.path);
                }
                g_pending_file_events.clearRetainingCapacity();
            } else {
                // Deadline not yet elapsed: keep frame() running so we don't miss it.
                wakeupFrame();
            }
        }
    }

    // ── Main column ──────────────────────────────────────────────────────
    var col = dvui.box(@src(), .{}, .{ .expand = .both });
    defer col.deinit();

    renderToolbar();
    try renderContent();
    renderStatusBar();

    // ── Settings modal ────────────────────────────────────────────────────────
    const settings_was_open = g_settings_open;
    if (g_settings_open) try settingsModal();
    if (settings_was_open and !g_settings_open) {
        var need_rescan = false;

        const changed = g_cfg.thumbnails_in_db != g_settings_scan_snapshot.thumbnails_in_db or
            g_cfg.prompt_embeddings != g_settings_scan_snapshot.prompt_embeddings or
            g_cfg.image_embeddings != g_settings_scan_snapshot.image_embeddings;
        if (changed) {
            if (g_library_manager) |*mgr| {
                mgr.thumbnails_in_db = g_cfg.thumbnails_in_db;
                mgr.prompt_embeddings = g_cfg.prompt_embeddings;
                mgr.image_embeddings = g_cfg.image_embeddings;
            }
            need_rescan = true;
        }
        const model_changed = !std.mem.eql(u8, &g_embedding_model_buf, &g_settings_model_snapshot.model) or
            !std.mem.eql(u8, &g_embedding_mmproj_buf, &g_settings_model_snapshot.mmproj);
        if (model_changed) {
            if (dvui.App.main_init) |init| {
                // Update config strings
                if (g_cfg.embedding_model_path) |p| init.gpa.free(p);
                const model_str = std.mem.sliceTo(&g_embedding_model_buf, 0);
                g_cfg.embedding_model_path = if (model_str.len > 0) init.gpa.dupe(u8, model_str) catch null else null;
                if (g_cfg.embedding_mmproj_path) |p| init.gpa.free(p);
                const mmproj_str = std.mem.sliceTo(&g_embedding_mmproj_buf, 0);
                g_cfg.embedding_mmproj_path = if (mmproj_str.len > 0) init.gpa.dupe(u8, mmproj_str) catch null else null;
                // Update library manager paths and reset cached model state
                if (g_library_manager) |*mgr| {
                    mgr.embedding_model_path = g_cfg.embedding_model_path;
                    mgr.embedding_mmproj_path = g_cfg.embedding_mmproj_path;
                    mgr.vl_ctx_initialized.store(false, .release);
                    if (mgr.text_pool) |*tp| { tp.deinit(); mgr.text_pool = null; }
                }
                // Reset search models so they're re-initialized on next use
                if (g_search_vl_ctx) |*vc| { vc.deinit(); g_search_vl_ctx = null; }
                if (g_search_text_pool) |*tp| { tp.deinit(); g_search_text_pool = null; }
            }
            // Rescan so images missing embeddings get them with the new model.
            if (g_cfg.prompt_embeddings or g_cfg.image_embeddings) need_rescan = true;
        }
        const reranker_changed = !std.mem.eql(u8, &g_reranker_model_buf, &g_settings_model_snapshot.reranker) or
            !std.mem.eql(u8, &g_reranker_mmproj_buf, &g_settings_model_snapshot.reranker_mmproj);
        if (reranker_changed) {
            if (dvui.App.main_init) |init| {
                if (g_cfg.reranker_model_path) |p| init.gpa.free(p);
                const rr_str = std.mem.sliceTo(&g_reranker_model_buf, 0);
                g_cfg.reranker_model_path = if (rr_str.len > 0) init.gpa.dupe(u8, rr_str) catch null else null;
                if (g_cfg.reranker_mmproj_path) |p| init.gpa.free(p);
                const rr_mmproj_str = std.mem.sliceTo(&g_reranker_mmproj_buf, 0);
                g_cfg.reranker_mmproj_path = if (rr_mmproj_str.len > 0) init.gpa.dupe(u8, rr_mmproj_str) catch null else null;
                // Reset cached reranker so it's re-initialized on next use
                if (g_search_reranker) |*rr| { rr.deinit(); g_search_reranker = null; }
            }
        }
        // Trigger rescan after all path/flag updates are applied.
        if (need_rescan) {
            if (g_library_manager) |*mgr| {
                if (dvui.App.main_init) |init| {
                    mgr.scanAllLibraries(init.io) catch |err| {
                        std.log.warn("rescan after config change: {}", .{err});
                    };
                }
            }
        }
    }

    // ── Delete confirmation modal ─────────────────────────────────────────────
    if (g_delete_dialog_open) try deleteConfirmDialog();

    // ── Filter modal ──────────────────────────────────────────────────────────
    if (g_filter_modal_open) try filterModal();

    return .ok;
}

fn initWindowFontsAndTheme() !void {
    try dvui.addFont("NotoSansCJK", noto_cjk_bytes, null);
    try dvui.addFont("NotoSansCJKBold", noto_cjk_bold_bytes, null);
    var theme = dvui.themeGet();
    theme.font_body = theme.font_body.withFamily("NotoSansCJK");
    theme.font_title = theme.font_title.withFamily("NotoSansCJKBold");
    theme.font_mono = theme.font_mono.withFamily("NotoSansCJK");
    dvui.themeSet(theme);
}

const ViewerWindow = struct {
    back: SDLBackend,
    win: dvui.Window,
    sdl_window_id: u32,
    state: image_viewer_mod.ViewerState,
    fonts_initialized: bool = false,

    fn deinit(self: *ViewerWindow) void {
        self.state.deinit();
        self.win.deinit();
        // Destroy the SDL renderer and window manually, then suppress SDL_Quit.
        // SDL3 does not refcount SDL_Init/SDL_Quit — calling SDL_Quit from a
        // viewer deinit would tear down the video subsystem while the main window
        // is still running.  Only the main window's deferred back.deinit() should
        // call SDL_Quit at process exit.
        SDLBackend.c.SDL_DestroyRenderer(self.back.renderer);
        SDLBackend.c.SDL_DestroyWindow(self.back.window);
        self.back.we_own_window = false;
        self.back.deinit();
    }
};

var g_viewer_windows: std.ArrayList(*ViewerWindow) = .empty;
var g_viewer_next_id: u64 = 1;

fn routeAllSDLEvents(main_back: *SDLBackend, main_win: *dvui.Window) void {
    if (g_dnd) |*dnd| dnd.pumpEvents();
    const main_id = SDLBackend.c.SDL_GetWindowID(main_back.window);
    var event: SDLBackend.c.SDL_Event = undefined;
    while (SDLBackend.c.SDL_PollEvent(&event)) {
        // Notify DnD of button release before routing — SDL's event is more
        // timely than XQueryPointer on XWayland.
        if (event.type == SDLBackend.c.SDL_EVENT_MOUSE_BUTTON_UP and
            event.button.button == 1)
        {
            if (g_dnd) |*dnd| dnd.notifyButtonUp();
        }
        const eid = sdlEventWindowID(event);
        if (eid == 0 or eid == main_id) {
            _ = main_back.addEvent(main_win, event) catch {};
            continue;
        }
        for (g_viewer_windows.items) |vw| {
            if (vw.sdl_window_id == eid) {
                _ = vw.back.addEvent(&vw.win, event) catch {};
                break;
            }
        }
    }
}

fn sdlEventWindowID(event: SDLBackend.c.SDL_Event) u32 {
    const SDL = SDLBackend.c;
    return switch (event.type) {
        SDL.SDL_EVENT_KEY_DOWN, SDL.SDL_EVENT_KEY_UP             => event.key.windowID,
        SDL.SDL_EVENT_TEXT_INPUT, SDL.SDL_EVENT_TEXT_EDITING     => event.text.windowID,
        SDL.SDL_EVENT_MOUSE_MOTION                               => event.motion.windowID,
        SDL.SDL_EVENT_MOUSE_BUTTON_DOWN,
        SDL.SDL_EVENT_MOUSE_BUTTON_UP                            => event.button.windowID,
        SDL.SDL_EVENT_MOUSE_WHEEL                                => event.wheel.windowID,
        SDL.SDL_EVENT_WINDOW_RESIZED,
        SDL.SDL_EVENT_WINDOW_FOCUS_GAINED,
        SDL.SDL_EVENT_WINDOW_FOCUS_LOST,
        SDL.SDL_EVENT_WINDOW_MOUSE_ENTER,
        SDL.SDL_EVENT_WINDOW_MOUSE_LEAVE,
        SDL.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        SDL.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED               => event.window.windowID,
        else                                                     => 0,
    };
}

fn cleanupViewers(gpa: std.mem.Allocator) void {
    for (g_viewer_windows.items) |vw| {
        vw.deinit();
        gpa.destroy(vw);
    }
    g_viewer_windows.deinit(gpa);
}

fn openViewer(grid: *image_grid_mod.GridState, start_id: ?u64) void {
    const init = dvui.App.main_init orelse return;

    var images: std.ArrayList(image_grid_mod.ImageEntry) = .empty;
    const use_selection = grid.selection.count() > 1;
    for (grid.images.items) |e| {
        if (use_selection and !grid.selection.contains(e.id)) continue;
        const path_copy = init.gpa.dupe(u8, e.path) catch continue;
        images.append(init.gpa, .{
            .id = e.id,
            .path = path_copy,
            .filename = std.fs.path.basename(path_copy),
            .mtime = e.mtime,
        }) catch {
            init.gpa.free(path_copy);
            continue;
        };
    }
    if (images.items.len == 0) {
        images.deinit(init.gpa);
        return;
    }

    var start_idx: usize = 0;
    if (start_id) |sid| {
        for (images.items, 0..) |e, i| {
            if (e.id == sid) {
                start_idx = i;
                break;
            }
        }
    }

    const id = g_viewer_next_id;
    g_viewer_next_id += 1;
    const vw = init.gpa.create(ViewerWindow) catch {
        for (images.items) |e| init.gpa.free(e.path);
        images.deinit(init.gpa);
        return;
    };

    const title = "DiffKeep Viewer";

    const back = SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = .{ .w = 1200, .h = 800 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = true,
        .title = title,
    }) catch {
        for (images.items) |e| init.gpa.free(e.path);
        images.deinit(init.gpa);
        init.gpa.destroy(vw);
        return;
    };

    vw.* = .{
        .back = back,
        .win = undefined,
        .sdl_window_id = 0,
        .state = image_viewer_mod.ViewerState.init(
            init.gpa, id, images, start_idx, wakeupFrame, g_data_dir,
            init.io, if (g_db) |*db| db else null,
        ),
    };
    vw.state.sdl_window_ptr = vw.back.window;

    vw.win = dvui.Window.init(@src(), init.gpa, vw.back.backend(), .{ .id_extra = @intCast(id) })
        catch {
            vw.back.deinit();
            vw.state.deinit();
            init.gpa.destroy(vw);
            return;
        };
    vw.sdl_window_id = SDLBackend.c.SDL_GetWindowID(vw.back.window);

    g_viewer_windows.append(init.gpa, vw) catch {
        vw.deinit();
        init.gpa.destroy(vw);
    };
}

fn removeFromViewers(ids: *const std.AutoHashMap(u64, void)) void {
    for (g_viewer_windows.items) |vw| vw.state.removeImages(ids);
}

/// Perform trash/delete on a specific image entry owned by a viewer (not grid selection).
fn performViewerDeleteEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: image_grid_mod.ImageEntry,
    force: bool,
) void {
    const data_dir = g_data_dir orelse return;

    if (force or !g_cfg.trash_enabled) {
        const file_path: []const u8 = if (entry.trash_name) |tn|
            std.fs.path.join(allocator, &.{ data_dir, "trash", tn }) catch return
        else
            entry.path;
        defer if (entry.trash_name != null) allocator.free(file_path);
        std.Io.Dir.cwd().deleteFile(io, file_path) catch |err|
            log.warn("delete {s}: {}", .{ entry.filename, err });
        if (g_db) |*db| db.deleteImage(entry.id) catch |err|
            log.warn("deleteImage {d}: {}", .{ entry.id, err });
    } else {
        const now_s: i64 = @intCast(@divTrunc(
            std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s,
        ));
        var file_size: i64 = 0;
        if (std.Io.Dir.cwd().openFile(io, entry.path, .{})) |f| {
            if (f.length(io)) |len| file_size = @intCast(len) else |_| {}
            f.close(io);
        } else |_| {}
        const basename = std.fs.path.basename(entry.path);
        var name_buf: [768]u8 = undefined;
        const trash_name = std.fmt.bufPrint(&name_buf, "{d}_{s}", .{ entry.id, basename }) catch return;
        const dst = std.fs.path.join(allocator, &.{ data_dir, "trash", trash_name }) catch return;
        defer allocator.free(dst);
        moveFile(io, allocator, entry.path, dst) catch |err| {
            log.warn("trash {s}: {}", .{ entry.filename, err });
            return;
        };
        if (g_db) |*db| db.trashImage(entry.id, trash_name, file_size, now_s) catch |err|
            log.warn("trashImage {d}: {}", .{ entry.id, err });
    }

    var ids = std.AutoHashMap(u64, void).init(allocator);
    defer ids.deinit();
    ids.put(entry.id, {}) catch {};
    if (g_grid) |*grid| removeFromGrid(grid, &ids);
    removeFromViewers(&ids);
    refreshCounts();
}

fn openViewerDeleteDialog(state: *image_viewer_mod.ViewerState, force: bool) void {
    const init = dvui.App.main_init orelse return;
    const img = state.currentImage() orelse return;

    const permanent = force or !g_cfg.trash_enabled;

    if (!permanent and g_skip_delete_confirm) {
        performViewerDeleteEntry(init.io, init.gpa, img.*, force);
        return;
    }
    if (permanent and g_skip_permanent_delete_confirm) {
        performViewerDeleteEntry(init.io, init.gpa, img.*, force);
        return;
    }

    // Populate viewer state; the dialog renders inside the viewer window.
    state.delete_pending_id = img.id;
    state.delete_pending_permanent = permanent;
    const len = @min(img.filename.len, state.delete_pending_name_buf.len);
    @memcpy(state.delete_pending_name_buf[0..len], img.filename[0..len]);
    state.delete_pending_name_len = len;
    state.delete_confirm_open = true;
}

fn pickMinWait(a: ?u32, b: ?u32) ?u32 {
    const av = a orelse return b;
    const bv = b orelse return a;
    return @min(av, bv);
}

pub fn main(init: std.process.Init) !void {
    dvui.App.main_init = init;
    SDLBackend.c.SDL_SetMainReady();

    const opts = appStart();
    var back = try SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = opts.size,
        .min_size = opts.min_size,
        .vsync = opts.vsync,
        .title = opts.title,
        .environ_map = init.environ_map,
    });
    defer back.deinit();

    var win = try dvui.Window.init(@src(), init.gpa, back.backend(), .{});
    defer win.deinit();

    try win.begin(win.frame_time_ns);
    try appInit(&win);
    _ = try win.end(.{});
    g_dnd = dnd_mod.DragSource.init(init.gpa, back.window);
    defer appDeinit();
    defer cleanupViewers(init.gpa);

    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        routeAllSDLEvents(&back, &win);
        if (g_dnd) |*dnd| dnd.tick(init.io);

        // ── Main window ───────────────────────────────────────────────────────
        try win.begin(nstime);
        _ = SDLBackend.c.SDL_SetRenderDrawColor(back.renderer, 0, 0, 0, 255);
        _ = SDLBackend.c.SDL_RenderClear(back.renderer);
        var res = try frame();
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if ((e.evt == .window and e.evt.window.action == .close) or
                (e.evt == .app and e.evt.app.action == .quit)) res = .close;
        }
        var end_micros: ?u32 = try win.end(.{});
        try back.setCursor(win.cursorRequested());
        if (g_dnd) |*dnd| {
            if (dnd.isDragging()) {
                const thumb_cursor = dnd.getSdlCursor();
                if (thumb_cursor != null) {
                    _ = SDLBackend.c.SDL_SetCursor(thumb_cursor);
                } else {
                    if (g_dnd_drag_cursor == null)
                        g_dnd_drag_cursor = SDLBackend.c.SDL_CreateSystemCursor(SDLBackend.c.SDL_SYSTEM_CURSOR_MOVE);
                    if (g_dnd_drag_cursor) |c| _ = SDLBackend.c.SDL_SetCursor(c);
                }
            } else if (g_dnd_drag_cursor) |c| {
                _ = SDLBackend.c.SDL_SetCursor(null);
                SDLBackend.c.SDL_DestroyCursor(c);
                g_dnd_drag_cursor = null;
            }
        }
        try back.textInputRect(win.textInputRequested());
        try back.renderPresent();
        if (res == .close) break :main_loop;

        // ── Viewer windows ────────────────────────────────────────────────────
        var vi: usize = 0;
        while (vi < g_viewer_windows.items.len) {
            const vw = g_viewer_windows.items[vi];
            try vw.win.begin(nstime);

            if (!vw.fonts_initialized) {
                vw.fonts_initialized = true;
                try initWindowFontsAndTheme();
            }

            _ = SDLBackend.c.SDL_SetRenderDrawColor(vw.back.renderer, 0, 0, 0, 255);
            _ = SDLBackend.c.SDL_RenderClear(vw.back.renderer);
            vw.state.render();

            if (vw.state.delete_requested) {
                vw.state.delete_requested = false;
                openViewerDeleteDialog(&vw.state, vw.state.delete_force);
            }

            if (vw.state.delete_confirmed) {
                vw.state.delete_confirmed = false;
                if (vw.state.delete_no_ask) {
                    vw.state.delete_no_ask = false;
                    if (vw.state.delete_pending_permanent) g_skip_permanent_delete_confirm = true
                    else g_skip_delete_confirm = true;
                }
                if (dvui.App.main_init) |main_init| {
                    const iid = vw.state.delete_pending_id;
                    for (vw.state.images.items) |e| {
                        if (e.id == iid) {
                            performViewerDeleteEntry(main_init.io, main_init.gpa, e, vw.state.delete_pending_permanent);
                            break;
                        }
                    }
                }
            }

            var close = !vw.state.open;
            for (dvui.events()) |*e| {
                if (!e.handled and e.evt == .window and e.evt.window.action == .close)
                    close = true;
            }
            const vw_end: ?u32 = try vw.win.end(.{});
            try vw.back.setCursor(vw.win.cursorRequested());
            try vw.back.renderPresent();

            end_micros = pickMinWait(end_micros, vw_end);

            if (close) {
                vw.deinit();
                init.gpa.destroy(vw);
                _ = g_viewer_windows.swapRemove(vi);
            } else {
                vi += 1;
            }
        }

        const wait_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_micros);
    }
}
