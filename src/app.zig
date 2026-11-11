const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

/// From git at build time (build.zig: tools/git_version.zig).
const app_version = @embedFile("git_version");
const icons = @import("icons");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const library_manager_mod = @import("library_manager.zig");
const counts_mod = @import("counts.zig");
const fs_watch_mod = @import("fs_watch.zig");
const image_grid_mod = @import("image_grid.zig");
const embedder_mod = @import("embedder.zig");
const vips_mod = @import("vips");
const SDLBackend = @import("backend");
const detail_panel_mod = @import("detail_panel.zig");
const sidebar_mod = @import("sidebar.zig");
const image_viewer_mod = @import("image_viewer.zig");
const dnd_mod = @import("dnd.zig");
const filter_modal_mod = @import("filter_modal.zig");
const delete_dialog_mod = @import("delete_dialog.zig");
const settings_modal_mod = @import("settings_modal.zig");
const viewer_manager_mod = @import("viewer_manager.zig");
const window_state = @import("window_state.zig");
const search_mod = @import("search.zig");
const image_ops_mod = @import("image_ops.zig");
const toolbar_mod = @import("toolbar.zig");
const platform = @import("platform.zig");
const platform_sdl = @import("platform_sdl.zig");
const style = @import("style.zig");
const dk = @import("diffkeep.zig");

// Path to the config file: set from --config/-c flag, otherwise resolved from known folders.
var g_config: ?[]const u8 = null;
// Directory that contains the DB file — also used as root for the trash folder.
var g_data_dir: ?[]const u8 = null;
var g_fs_watcher: ?fs_watch_mod.FsWatcher = null;
/// Pending per-file events collected from the watcher, waiting for the short
/// debounce window to expire before being dispatched to LibraryManager.
var g_pending_file_events: library_manager_mod.PendingFileEvents = .{};
/// Absolute nanosecond timestamp (Io.Clock.real) after which pending file
/// events should be flushed.  0 means nothing is pending.
var g_rescan_deadline_ns: i96 = 0;
var g_wakeup_event_type: u32 = 0;

fn wakeupFrame() void {
    // Background work can finish before the event type is registered at startup;
    // the first frame picks its result up anyway.
    if (g_wakeup_event_type == 0) return;
    var ev: SDLBackend.c.SDL_Event = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ev.type = g_wakeup_event_type;
    _ = SDLBackend.c.SDL_PushEvent(&ev);
}
var g_db_stats: ?db_mod.DbStats = null;
var g_trash_stats: ?db_mod.TrashStats = null;
var g_duplicate_count: i64 = 0;
var g_redundant_duplicate_count: i64 = 0;
var g_favorite_count: i64 = 0;
var g_total_image_count: i64 = 0;

var g_sidebar: sidebar_mod.SidebarState = .{};
var g_detail: detail_panel_mod.DetailState = .{};
var g_dnd: ?dnd_mod.DragSource = null;
var g_dnd_drag_cursor: ?*SDLBackend.c.SDL_Cursor = null;

// Delete confirmation dialog state
var g_delete_dialog: delete_dialog_mod.DeleteDialogState = .{};


var g_search: search_mod.SearchState = .{};
// Settings modal state (includes model path buffers, download state)
var g_settings: settings_modal_mod.SettingsModalState = .{};

// Background embedder loader — init runs on a dedicated thread so the main thread never blocks.
var g_embedder_thread: ?std.Thread = null;
var g_embedder_task_result: ?embedder_mod.Embedder = null;
var g_embedder_task_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// Pending reload: set when startEmbedderLoad is called while a thread is already
// in flight. Holds the args (incl. heap-allocated model dirs) for the next load.
var g_embedder_pending: ?EmbedderLoadArgs = null;

// Active metadata filters
var g_active_filters: std.ArrayList(db_mod.ActiveFilter) = .empty;

// Filter modal state
var g_filter_modal: filter_modal_mod.FilterModalState = .{};

/// Background loader for the sidebar/toolbar counts (see counts.zig).
var g_counts: ?counts_mod.CountsLoader = null;

/// Ask for fresh image counts (all libraries, total, trash, duplicates,
/// favorites). Called at init and after anything that changes them; the
/// queries run in the background and `applyCounts` shows the result.
fn refreshCounts() void {
    if (g_counts) |*c| c.request();
}

/// Ask for the settings' database stats (with fresh counts).
fn refreshStats() void {
    if (g_counts) |*c| c.requestStats();
}

/// Main thread, each frame: show counts a background load has finished.
fn applyCounts() void {
    const loader = if (g_counts) |*c| c else return;
    var c = loader.poll() orelse return;
    defer c.deinit(loader.allocator);
    g_total_image_count = c.total;
    g_trash_stats = c.trash;
    g_duplicate_count = c.duplicates;
    g_redundant_duplicate_count = c.redundant_duplicates;
    if (c.db_stats) |st| g_db_stats = st;
    g_favorite_count = c.favorites;
    g_sidebar.applyLibraryCounts(c.libraries);
}

/// Toggle an image's favorite flag (raised from the grid star or the viewer
/// toolbar). Writes the DB, reflects it live in the grid and any open viewers,
/// and refreshes the sidebar count. `path` and `current` come from the entry
/// the user acted on; the update only applies if the row is still that file
/// (ids are recycled).
fn toggleFavorite(id: u64, path: []const u8, current: bool) void {
    const init = dvui.App.main_init orelse return;
    const db = if (dk.g_db) |*d| d else return;
    const new_val = !current;

    const matched = db.setFavorite(id, path, new_val) catch |err| {
        log.warn("setFavorite {d}: {}", .{ id, err });
        return;
    };
    if (!matched) return; // the row is gone; a pending reload drops the entry

    if (dk.g_grid) |*grid| {
        for (grid.images.items) |*e| {
            if (e.id == id) e.favorite = new_val;
        }
        // In the Favorites view an un-favorited image leaves the grid at once.
        if (grid.view_mode == .favorites and !new_val) {
            var ids = std.AutoHashMap(u64, void).init(init.gpa);
            defer ids.deinit();
            ids.put(id, {}) catch {};
            const saved_y = grid.scroll_info.viewport.y;
            image_ops_mod.removeFromGrid(grid, &ids);
            grid.scroll_info.viewport.y = saved_y;
        }
    }
    g_viewer_manager.setFavorite(id, new_val);
    refreshCounts();
}


// Panel widths in logical pixels.  _open stores the last non-collapsed width.
var g_left_w: f32 = 240;
var g_left_w_open: f32 = 240;
var g_right_w: f32 = 300;
var g_right_w_open: f32 = 300;

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
                    g_config = std.Io.Dir.path.join(init.gpa, &.{ val, "DiffKeep.cfg" }) catch null;
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
    // Install the real SDL-backed platform services (clipboard image data,
    // native folder picker). UI modules call these through the platform seam.
    platform.init(platform_sdl.vtable);
    image_ops_mod.init(.{
        .db = &dk.g_db,
        .data_dir = &g_data_dir,
        .cfg = &dk.g_cfg,
        .on_counts_changed = refreshCounts,
        .on_images_removed = removeImagesFromViewers,
        .on_wakeup = wakeupFrame,
    });

    if (dvui.App.main_init) |init| {
        if (g_config == null) {
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .local_configuration)) |config_dir| {
                defer init.gpa.free(config_dir);
                g_config = try std.Io.Dir.path.join(init.gpa, &.{ config_dir, "DiffKeep", "DiffKeep.cfg"});
            }
        }

        if (g_config) |cfg_path| {
            dk.g_cfg = try config_mod.load(init.gpa, init.io, cfg_path);
        }

        // Restore remembered grid panel widths.
        g_left_w = dk.g_cfg.grid_left_w;
        g_left_w_open = dk.g_cfg.grid_left_w_open;
        g_right_w = dk.g_cfg.grid_right_w;
        g_right_w_open = dk.g_cfg.grid_right_w_open;

        g_settings.initFromConfig(&dk.g_cfg);

        const db_path = blk: {
            if (dk.g_cfg.data_path) |p| {
                break :blk try init.gpa.dupe(u8, p);
            }
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) |data_base| {
                defer init.gpa.free(data_base);
                var data_dir = try std.Io.Dir.openDirAbsolute(init.io, data_base, .{});
                defer data_dir.close(init.io);
                try data_dir.createDirPath(init.io, "DiffKeep");
                break :blk try std.Io.Dir.path.join(init.gpa, &.{ data_base, "DiffKeep", "diffkeep.db" });
            }
            break :blk null;
        };
        if (db_path) |p| {
            defer init.gpa.free(p);
            if (std.Io.Dir.path.dirname(p)) |dir| {
                g_data_dir = try init.gpa.dupe(u8, dir);
            }
            dk.g_db = try db_mod.VectorDb.init(init.gpa, init.io, p);
        }

        // Ensure trash directory exists and purge entries older than 30 days.
        if (g_data_dir) |data_dir| {
            var dd = try std.Io.Dir.openDirAbsolute(init.io, data_dir, .{});
            defer dd.close(init.io);
            dd.createDirPath(init.io, "trash") catch {};

            if (dk.g_db != null) {
                const now_s: i64 = @intCast(@divTrunc(
                    std.Io.Clock.real.now(init.io).nanoseconds, std.time.ns_per_s,
                ));
                image_ops_mod.startPurgeExpiredTrash(init.io, now_s - 30 * 24 * 60 * 60);
            }
        }

        // VIPS must be initialized before any worker threads start calling vips_thumbnail.
        try vips_mod.init();

        if (dk.g_db) |*db| {
            try g_sidebar.loadLibraries(init.gpa, db);

            // Register a custom SDL event so the worker thread can wake the render loop
            // when a thumbnail is ready (dvui only renders on input otherwise).
            g_wakeup_event_type = SDLBackend.c.SDL_RegisterEvents(1);

            // Init grid before library manager so we can pass the notifier pointer.
            // Grid must be at its final global address before startWorker() is called.
            dk.g_grid = try image_grid_mod.GridState.init(init.io, init.gpa, db, dk.g_cfg.thumbnails_in_db, wakeupFrame);
            if (dk.g_grid) |*grid| {
                grid.data_dir = g_data_dir;
                grid.thumb_fraction = std.math.clamp(dk.g_cfg.grid_thumb_fraction, 0, 1);
                grid.autoplay = dk.g_cfg.grid_autoplay;
                grid.semantic_min_similarity = dk.g_cfg.semantic_min_similarity;
                grid.visual_min_similarity = dk.g_cfg.visual_min_similarity;
                try grid.startWorker();
                // The list loads in the background; the grid fills in when it lands.
                try grid.reloadImages();
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
            // concurrent task receives &dk.g_library_manager.? (stable global address)
            // rather than a pointer to a stack-local that becomes dangling after appInit returns.
            const notifier = if (dk.g_grid) |*grid| &grid.notifier else null;
            const watcher_ptr: ?*fs_watch_mod.FsWatcher = if (g_fs_watcher != null) &g_fs_watcher.? else null;
            dk.g_library_manager = library_manager_mod.LibraryManager.init(init.gpa, db, dk.g_cfg.thumbnails_in_db, dk.g_cfg.prompt_embeddings, dk.g_cfg.image_embeddings, notifier, watcher_ptr);
            g_search.wakeup_fn = wakeupFrame;
            g_sidebar.wakeup_fn = wakeupFrame;
            g_sidebar.initFolderLoader(init.gpa, init.io, db);
            g_detail.wakeup_fn = wakeupFrame;
            if (dk.g_library_manager) |*mgr| mgr.data_dir = g_data_dir;

            // Start loading the ONNX embedder on a background thread.
            // search.embedder and mgr.embedder stay null until pollEmbedderLoad() wires them.
            g_search.embedder = null;
            startEmbedderLoad(init.io, init.gpa, &dk.g_cfg);

            if (dk.g_library_manager) |*mgr| {
                mgr.embedder = null;
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

            // Initial counts load in the background.
            g_counts = counts_mod.CountsLoader.init(init.gpa, init.io, db);
            g_counts.?.wakeup_fn = wakeupFrame;
            refreshCounts();
        }
    } else {
        try vips_mod.init();
    }

    std.log.info("DiffKeep {s} — config: {s}", .{
        app_version,
        g_config orelse "(none)",
    });

    try initWindowFontsAndTheme();
}

/// Logs how long each shutdown step takes (debug level), to find what holds
/// up a quit.
const ShutdownTimer = struct {
    io: ?std.Io,
    last: i96 = 0,

    fn start() ShutdownTimer {
        const io = if (dvui.App.main_init) |init| init.io else return .{ .io = null };
        return .{ .io = io, .last = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn lap(t: *ShutdownTimer, step: []const u8) void {
        const io = t.io orelse return;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        log.debug("shutdown: {s} took {d} ms", .{ step, @divTrunc(now - t.last, std.time.ns_per_ms) });
        t.last = now;
    }
};

fn appDeinit() void {
    var timer = ShutdownTimer.start();
    if (g_dnd) |*dnd| dnd.deinit();
    // Stop the fs watcher thread before anything else so it can't fire callbacks
    // against already-freed state.
    if (g_fs_watcher) |*watcher| watcher.deinit();
    timer.lap("fs watcher");
    // Stop all threads that use VIPS before calling vips_shutdown().
    if (dvui.App.main_init) |init| {
        if (dk.g_library_manager) |*mgr| mgr.deinit(init.io);
    }
    timer.lap("library manager (scans)");
    if (dvui.App.main_init) |init| {
        g_search.awaitEmbed(init.io);
        g_search.deinit(init.gpa);
    }
    timer.lap("search");
    // Join the background embedder load thread (if running) and discard any result.
    if (g_embedder_thread) |t| {
        t.join();
        g_embedder_thread = null;
    }
    timer.lap("embedder load thread");
    if (g_embedder_task_result) |*emb| { emb.deinit(); g_embedder_task_result = null; }
    if (dvui.App.main_init) |init| {
        if (g_embedder_pending) |p| {
            if (p.text_dir) |t| init.gpa.free(t);
            if (p.visual_dir) |v| init.gpa.free(v);
        }
    }
    g_embedder_pending = null;
    if (dvui.App.main_init) |init| image_ops_mod.fileOpsJoin(init.io);
    timer.lap("file ops");
    if (dk.g_embedder) |*emb| emb.deinit();
    timer.lap("embedder");
    if (dk.g_grid) |*grid| grid.deinit();
    timer.lap("grid");
    if (g_counts) |*c| c.deinit();
    g_counts = null;
    // These await their background loads, which use the DB: before it closes.
    if (dvui.App.main_init) |init| {
        g_detail.deinit(init.gpa);
        g_sidebar.deinit(init.gpa);
    }
    vips_mod.deinit();
    if (dk.g_db) |*database| database.deinit();
    timer.lap("vips + db");
    if (dvui.App.main_init) |init| {
        g_delete_dialog.deinit(init.gpa);
        if (g_config) |cfg_path| {
            config_mod.save(dk.g_cfg, init.io, cfg_path) catch |err| {
                std.log.warn("failed to save config: {}", .{err});
            };
            init.gpa.free(cfg_path);
        }
        dk.g_cfg.deinit(init.gpa);
        if (g_data_dir) |d| init.gpa.free(d);
        for (g_active_filters.items) |f| init.gpa.free(f.value);
        g_active_filters.deinit(init.gpa);
        g_pending_file_events.deinit(init.gpa);
        g_filter_modal.deinit(init.gpa);
    }
    timer.lap("config + state");
}



const log = std.log.scoped(.app);

/// Open the delete confirmation dialog for the current grid selection.
fn openDeleteDialog(grid: *const image_grid_mod.GridState, force: bool) void {
    var count: usize = grid.selection.count();
    if (count == 0) {
        if (grid.focused_idx) |fi| {
            if (fi < grid.images.items.len) count = 1;
        }
    }
    if (count == 0) return;

    g_delete_dialog.count = count;
    // Items already in the trash can only be permanently deleted, never re-trashed.
    g_delete_dialog.force = force or (grid.view_mode == .trash);

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
        const len = @min(name.len, g_delete_dialog.name_buf.len);
        @memcpy(g_delete_dialog.name_buf[0..len], name[0..len]);
        g_delete_dialog.name_len = len;
    }

    // Items already in the trash (view_mode == .trash) can only ever be deleted
    // permanently — mirror g_delete_dialog.force so the skip-confirm fast path
    // doesn't fall into performTrash (which would no-op on an already-trashed
    // file yet still drop it from the grid, leaving a stale row behind).
    const permanent = g_delete_dialog.force or !dk.g_cfg.trash_enabled;
    if (count == 1) {
        if (!permanent and g_delete_dialog.skip_delete_confirm) {
            if (dk.g_grid) |*grid_mut| {
                if (dvui.App.main_init) |init| image_ops_mod.performTrash(init.io, init.gpa, grid_mut);
            }
            return;
        }
        if (permanent and g_delete_dialog.skip_permanent_delete_confirm) {
            if (dk.g_grid) |*grid_mut| {
                if (dvui.App.main_init) |init| image_ops_mod.performDelete(init.io, init.gpa, grid_mut);
            }
            return;
        }
    }

    if (dvui.App.main_init) |init| g_delete_dialog.snapshot(init.gpa, grid);
    g_delete_dialog.open = true;
}

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    // Drain new images from scan threads and update thumbnail cache
    if (dk.g_grid) |*grid| {
        const prev_len = grid.images.items.len;
        grid.update();
        // Drop images removed by the filesystem watcher from the grid and any open
        // viewers incrementally — no full reload, so scroll/focus are preserved.
        // Same for images the thumbnail loader found deleted from disk.
        if (dvui.App.main_init) |init| {
            var removed: std.ArrayList(u64) = .empty;
            defer removed.deinit(init.gpa);
            if (dk.g_library_manager) |*mgr| mgr.drainRemovedIds(init.io, &removed);
            grid.drainMissingIds(init.gpa, &removed);
            if (removed.items.len > 0) {
                var ids = std.AutoHashMap(u64, void).init(init.gpa);
                defer ids.deinit();
                for (removed.items) |id| ids.put(id, {}) catch {};
                image_ops_mod.removeFromGrid(grid, &ids);
                g_viewer_manager.removeImages(&ids);
            }
        }
        if (grid.images.items.len != prev_len) refreshCounts();
    }
    applyCounts();

    // Apply completed background search tasks
    if (dvui.App.main_init) |init| {
        if (dk.g_grid) |*grid| g_search.applyEmbedIfDone(init.gpa, grid);
    }

    // When a library scan finishes, hand its transient decode/thumbnail memory
    // back to the OS (see trimMemory).
    {
        const scanning = if (dk.g_library_manager) |*mgr| mgr.isScanActive() else false;
        if (g_was_scanning and !scanning) trimMemory();
        g_was_scanning = scanning;
    }

    // Apply completed model downloads (auto-fill config paths)
    g_settings.applyCompletedDownloads(&dk.g_cfg, g_data_dir);
    if (g_settings.model_paths_changed and !g_settings.open) {
        g_settings.model_paths_changed = false;
        if (dvui.App.main_init) |init| {
            releaseEmbedder(init.io);
            startEmbedderLoad(init.io, init.gpa, &dk.g_cfg);
        }
    }

    // Check if background embedder load has completed.
    pollEmbedderLoad();

    // Consume pending delete/restore requests raised by keyboard handlers
    if (dk.g_grid) |*grid| {
        if (grid.delete_requested) {
            grid.delete_requested = false;
            openDeleteDialog(grid, grid.delete_force);
        }
        if (grid.restore_requested) {
            grid.restore_requested = false;
            if (dvui.App.main_init) |init| image_ops_mod.performRestore(init.io, init.gpa, grid);
        }
        if (grid.favorite_toggle_id) |id| {
            grid.favorite_toggle_id = null;
            if (grid.entryById(id)) |e| toggleFavorite(e.id, e.path, e.favorite);
        }
        if (grid.dedupe_requested) {
            grid.dedupe_requested = false;
            g_pending_bulk_count = g_redundant_duplicate_count;
            if (g_pending_bulk_count > 0) g_pending_bulk = .dedupe;
        }
        if (grid.empty_trash_requested or g_settings.empty_trash_requested) {
            grid.empty_trash_requested = false;
            g_settings.empty_trash_requested = false;
            g_pending_bulk_count = if (g_trash_stats) |ts| ts.count else 0;
            if (g_pending_bulk_count > 0) g_pending_bulk = .empty_trash;
        }
        // Surface completion of a background bulk op (reloads grid + counts).
        if (dvui.App.main_init) |init| _ = image_ops_mod.fileOpsPoll(init.io, init.gpa, grid);
        if (grid.open_viewer_requested) {
            grid.open_viewer_requested = false;
            g_viewer_manager.open(grid, grid.viewer_start_id, g_data_dir, if (dk.g_db) |*db| db else null, wakeupFrame, &dk.g_cfg);
            grid.viewer_start_id = null;
        }
        if (grid.copy_prompt_requested) {
            grid.copy_prompt_requested = false;
            if (dvui.App.main_init) |init| {
                if (dk.g_db) |*db| {
                    if (db.getPositivePromptText(init.gpa, grid.copy_prompt_id) catch null) |prompt| {
                        defer init.gpa.free(prompt);
                        if (init.gpa.dupeSentinel(u8, prompt, 0)) |c_str| {
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
                if (grid.entryById(grid.copy_image_id)) |e|
                    detail_panel_mod.copyImageToClipboard(e.path, init.gpa, init.io);
            }
        }
        if (grid.reparse_requested) {
            grid.reparse_requested = false;
            if (dvui.App.main_init) |init| {
                if (dk.g_db) |*db| {
                    if (dk.g_library_manager) |*mgr| {
                        // Look up the library id + path for this image, then queue a
                        // background re-parse (resets mtime so the scanner re-reads it).
                        if (db.getImageDetails(init.gpa, grid.reparse_id) catch null) |det| {
                            var d = det;
                            defer d.deinit(init.gpa);
                            mgr.reparseImage(init.io, d.id, d.library_id, d.library_path);
                            // The detail panel reloads once the background reparse
                            // lands its new data (driven by the grid refresh set).
                        }
                    }
                }
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

    // Detect search text changes — debounced 300 ms after the last keystroke.
    // Mode-button clicks set force_search=true to bypass the timer entirely.
    if (dvui.App.main_init) |init| {
        const now_ns: i96 = std.Io.Clock.real.now(init.io).nanoseconds;
        if (!std.mem.eql(u8, &g_search.buf, &g_search.last_buf)) {
            g_search.debounce_deadline_ns = now_ns + 300 * std.time.ns_per_ms;
            @memcpy(&g_search.last_buf, &g_search.buf);
        }
        const fire_search = g_search.force_search or
            (g_search.debounce_deadline_ns != 0 and now_ns >= g_search.debounce_deadline_ns);
        if (fire_search) {
            g_search.force_search = false;
            g_search.debounce_deadline_ns = 0;
            if (dk.g_grid) |*grid| g_search.fire(init.io, init.gpa, grid);
        }
    }

    if (dvui.App.main_init) |init| {
        try g_sidebar.drainPendingLibrary(
            init.gpa,
            init.io,
            if (dk.g_library_manager) |*mgr| mgr else null,
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
                for (new_events.items) |ev| g_pending_file_events.add(init.gpa, ev) catch {};
            }
        }
        if (g_rescan_deadline_ns != 0) {
            const now_ns = std.Io.Clock.real.now(init.io).nanoseconds;
            if (now_ns >= g_rescan_deadline_ns) {
                g_rescan_deadline_ns = 0;
                if (dk.g_library_manager) |*mgr| {
                    mgr.flushFileEvents(init.io, &g_pending_file_events);
                } else {
                    g_pending_file_events.deinit(init.gpa);
                    g_pending_file_events = .{};
                }
            } else {
                // Deadline not yet elapsed: keep frame() running so we don't miss it.
                wakeupFrame();
            }
        }
    }

    // ── Main column ──────────────────────────────────────────────────────
    // The app ground. Every band below paints its own surface on top; this is
    // what shows through the gaps and behind the grid.
    var col = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.C.canvas },
    });
    defer col.deinit();

    const render_ctx: toolbar_mod.RenderCtx = .{
        .search = &g_search,
        .active_filters = &g_active_filters,
        .filter_modal = &g_filter_modal,
        .grid = &dk.g_grid,
        .db = &dk.g_db,
        .cfg = &dk.g_cfg,
        .settings = &g_settings,
        .db_stats = &g_db_stats,
        .trash_stats = &g_trash_stats,
        .duplicate_count = &g_duplicate_count,
        .favorite_count = &g_favorite_count,
        .sidebar = &g_sidebar,
        .detail = &g_detail,
        .library_manager = &dk.g_library_manager,
        .left_w = &g_left_w,
        .left_w_open = &g_left_w_open,
        .right_w = &g_right_w,
        .right_w_open = &g_right_w_open,
        .total_image_count = &g_total_image_count,
        .on_refresh_counts = refreshCounts,
        .on_settings_opened = refreshStats,
        .embedder_loading = g_embedder_thread != null,
    };
    toolbar_mod.renderToolbar(render_ctx);
    try toolbar_mod.renderContent(render_ctx);
    toolbar_mod.renderStatusBar(render_ctx);

    // ── Settings modal ────────────────────────────────────────────────────────
    const settings_was_open = g_settings.open;
    try g_settings.render(&dk.g_cfg, &g_db_stats, &g_trash_stats, g_data_dir,
        dk.g_db != null,
        wakeupFrame);
    if (g_settings.clear_requested) |cache| {
        g_settings.clear_requested = null;
        if (g_counts) |*c| c.clear(cache);
    }
    if (settings_was_open and !g_settings.open) {
        g_settings.onClosed(&dk.g_cfg, &dk.g_library_manager, &g_search);
        if (dk.g_grid) |*grid| grid.thumbnails_in_db.store(dk.g_cfg.thumbnails_in_db, .release);
        if (g_settings.model_paths_changed) {
            g_settings.model_paths_changed = false;
            if (dvui.App.main_init) |init| {
                releaseEmbedder(init.io);
                startEmbedderLoad(init.io, init.gpa, &dk.g_cfg);
            }
        }
        // Persist config as soon as the settings screen closes
        if (dvui.App.main_init) |init| {
            if (g_config) |cfg_path| config_mod.save(dk.g_cfg, init.io, cfg_path) catch |err|
                log.warn("config save on settings close failed: {}", .{err});
        }
    }

    // ── Delete confirmation modal ─────────────────────────────────────────────
    try g_delete_dialog.render(dk.g_cfg.trash_enabled,
        if (dk.g_grid) |*g| g else null,
        image_ops_mod.performTrash, image_ops_mod.performDelete);

    // ── Bulk action (dedupe / empty trash) confirmation modal ─────────────────
    renderBulkConfirm();

    // ── Filter modal ──────────────────────────────────────────────────────────
    try g_filter_modal.render(
        &g_active_filters,
        if (dk.g_db) |*db| db else null,
        if (dk.g_grid) |*g| g else null,
    );

    // Mirror remembered grid layout into the config (flushed to disk on exit).
    if (dk.g_grid) |*grid| {
        dk.g_cfg.grid_thumb_fraction = grid.thumb_fraction;
        dk.g_cfg.grid_autoplay = grid.autoplay;
    }
    dk.g_cfg.grid_left_w = g_left_w;
    dk.g_cfg.grid_left_w_open = g_left_w_open;
    dk.g_cfg.grid_right_w = g_right_w;
    dk.g_cfg.grid_right_w_open = g_right_w_open;

    return .ok;
}

fn initWindowFontsAndTheme() !void {
    style.install();
}

var g_viewer_manager: viewer_manager_mod.ViewerManager = .{};

/// Drop images from any open viewer windows after they are removed from the grid.
fn removeImagesFromViewers(ids: *const std.AutoHashMap(u64, void)) void {
    g_viewer_manager.removeImages(ids);
}

fn routeAllSDLEvents(main_back: *SDLBackend, main_win: *dvui.Window) void {
    if (g_dnd) |*dnd| dnd.pumpEvents();
    for (g_viewer_manager.windows.items) |vw| {
        if (vw.dnd) |*dnd| dnd.pumpEvents();
    }
    const main_id = SDLBackend.c.SDL_GetWindowID(main_back.window);
    var event: SDLBackend.c.SDL_Event = undefined;
    while (SDLBackend.c.SDL_PollEvent(&event)) {
        // Notify the active DnD of button release before routing — SDL's event is
        // more timely than XQueryPointer on XWayland.  Only one drag is ever in
        // progress, so notify whichever source is currently dragging.
        if (event.type == SDLBackend.c.SDL_EVENT_MOUSE_BUTTON_UP and
            event.button.button == 1)
        {
            if (g_dnd) |*dnd| { if (dnd.isDragging()) dnd.notifyButtonUp(); }
            for (g_viewer_manager.windows.items) |vw| {
                if (vw.dnd) |*dnd| { if (dnd.isDragging()) dnd.notifyButtonUp(); }
            }
        }
        const eid = sdlEventWindowID(event);
        if (eid == 0 or eid == main_id) {
            _ = main_back.addEvent(main_win, event) catch {};
            continue;
        }
        for (g_viewer_manager.windows.items) |vw| {
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




/// Trash or delete an image shown in a viewer (not the grid selection). Runs on
/// the file-op worker; fileOpsPoll drops it from the grid and viewers when done.
fn performViewerDeleteEntry(io: std.Io, entry: image_grid_mod.ImageEntry, force: bool) void {
    // A trashed entry (trash_name set) is already in the trash; it can only be
    // deleted permanently, never re-trashed.
    const permanent = force or entry.trash_name != null or !dk.g_cfg.trash_enabled;
    image_ops_mod.performOnEntry(io, entry, if (permanent) .delete else .trash);
}

fn openViewerDeleteDialog(state: *image_viewer_mod.ViewerState, force: bool) void {
    const init = dvui.App.main_init orelse return;
    const img = state.currentImage() orelse return;

    // Must match performViewerDeleteEntry: an image already in the trash can
    // only be deleted permanently, so it gets the permanent-delete prompt.
    const permanent = force or img.trash_name != null or !dk.g_cfg.trash_enabled;

    if (!permanent and g_delete_dialog.skip_delete_confirm) {
        performViewerDeleteEntry(init.io, img.*, force);
        return;
    }
    if (permanent and g_delete_dialog.skip_permanent_delete_confirm) {
        performViewerDeleteEntry(init.io, img.*, force);
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

const EmbedderLoadArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    text_dir: ?[]const u8,   // heap-allocated, freed by the thread
    visual_dir: ?[]const u8, // heap-allocated, freed by the thread
    gpu_backend: embedder_mod.GpuBackend,
    threshold: usize,
};

fn embedderLoadThread(args: EmbedderLoadArgs) void {
    defer if (args.text_dir) |p| args.gpa.free(p);
    defer if (args.visual_dir) |p| args.gpa.free(p);
    g_embedder_task_result = embedder_mod.Embedder.init(
        args.io, args.gpa, args.text_dir, args.visual_dir, args.gpu_backend, args.threshold,
    ) catch |err| blk: {
        log.warn("embedder init failed: {}", .{err});
        break :blk null;
    };
    g_embedder_task_done.store(true, .release);
    wakeupFrame();
}

/// Kicks off a background thread to initialize the ONNX embedder.
/// Non-blocking: if a load is already in flight, the new config is queued
/// and the thread will pick it up after it finishes the current load.
fn startEmbedderLoad(io: std.Io, gpa: std.mem.Allocator, cfg: *const config_mod.Config) void {
    if (cfg.text_model_dir == null and cfg.visual_model_dir == null) return;
    if (g_embedder_thread != null) {
        // Already loading: queue a pending reload with the new paths.
        if (g_embedder_pending) |old| {
            if (old.text_dir) |p| gpa.free(p);
            if (old.visual_dir) |p| gpa.free(p);
        }
        g_embedder_pending = .{
            .io = io,
            .gpa = gpa,
            .text_dir = if (cfg.text_model_dir) |d| gpa.dupe(u8, d) catch null else null,
            .visual_dir = if (cfg.visual_model_dir) |d| gpa.dupe(u8, d) catch null else null,
            .gpu_backend = cfg.embed_gpu_backend,
            .threshold = cfg.embed_gpu_threshold,
        };
        return;
    }
    g_embedder_task_done.store(false, .release);
    g_embedder_task_result = null;
    const args = EmbedderLoadArgs{
        .io = io,
        .gpa = gpa,
        .text_dir = if (cfg.text_model_dir) |d| gpa.dupe(u8, d) catch null else null,
        .visual_dir = if (cfg.visual_model_dir) |d| gpa.dupe(u8, d) catch null else null,
        .gpu_backend = cfg.embed_gpu_backend,
        .threshold = cfg.embed_gpu_threshold,
    };
    g_embedder_thread = std.Thread.spawn(.{}, embedderLoadThread, .{args}) catch |err| {
        log.warn("embedder thread spawn failed: {}", .{err});
        if (args.text_dir) |p| gpa.free(p);
        if (args.visual_dir) |p| gpa.free(p);
        return;
    };
}

/// Unhook and free the current embedder. Scans, watcher file tasks and search
/// query embeds hold a raw pointer to it, so they are stopped and awaited first
/// (interrupted scans resume without an embedder; the backfill scan after the
/// next load fills in what they skipped).
fn releaseEmbedder(io: std.Io) void {
    g_search.embedder = null;
    g_search.awaitEmbed(io);
    if (dk.g_library_manager) |*mgr| {
        mgr.embedder = null;
        mgr.quiesce(io);
    }
    if (dk.g_embedder) |*emb| emb.deinit();
    dk.g_embedder = null;
}

/// Called each frame to check whether the background embedder load has completed.
/// When done, swaps the new embedder into g_embedder and re-wires search/library_manager.
fn pollEmbedderLoad() void {
    if (!g_embedder_task_done.load(.acquire)) return;
    g_embedder_task_done.store(false, .release);
    if (g_embedder_thread) |t| {
        t.join();
        g_embedder_thread = null;
    }
    if (dvui.App.main_init) |init| releaseEmbedder(init.io);
    dk.g_embedder = g_embedder_task_result;
    g_embedder_task_result = null;
    const emb_ptr: ?*embedder_mod.Embedder = if (dk.g_embedder) |*e| e else null;
    g_search.embedder = emb_ptr;
    if (dk.g_library_manager) |*mgr| mgr.embedder = emb_ptr;
    // If a reload was queued while this load was in flight, kick it off now.
    // The next pollEmbedderLoad() after that reload will handle the backfill scan.
    if (g_embedder_pending) |args| {
        g_embedder_pending = null;
        g_embedder_task_done.store(false, .release);
        g_embedder_task_result = null;
        g_embedder_thread = std.Thread.spawn(.{}, embedderLoadThread, .{args}) catch |err| {
            log.warn("embedder thread respawn failed: {}", .{err});
            if (args.text_dir) |p| args.gpa.free(p);
            if (args.visual_dir) |p| args.gpa.free(p);
            return;
        };
        return;
    }
    // Trigger a backfill scan so any embeddings missed while the embedder was loading
    // get generated now. Files that already have embeddings are fast-pathed in the scanner.
    if (emb_ptr != null) {
        if (dk.g_library_manager) |*mgr| {
            if (mgr.prompt_embeddings or mgr.image_embeddings) {
                if (dvui.App.main_init) |init| {
                    mgr.scanAllLibraries(init.io) catch |err| {
                        log.warn("embedder-ready backfill scan failed: {}", .{err});
                    };
                }
            }
        }
    }
}

// Sample the live main window each frame and remember its geometry in the
// shared config (flushed to disk on exit by appDeinit).
fn captureMainWindowState(back: *SDLBackend) void {
    window_state.capture(back.window, &dk.g_cfg.main_window);
}

/// Cap glibc's per-thread malloc arenas. DiffKeep runs ~60 threads (libvips
/// threadpool, grid loaders, library scanners, the fs watcher); glibc's default
/// of up to 8×CPU arenas leaves each thread hoarding freed memory it never
/// returns to the OS — about 150 MB of idle slack in practice. Capping the arena
/// count reclaims most of that; 4 keeps enough concurrency that the vips
/// threadpool isn't serialised on a single malloc lock during scans. Linux/glibc
/// only (mallopt is a no-op or absent elsewhere); must run before threads spawn.
fn tuneAllocator() void {
    if (builtin.target.os.tag != .linux) return;
    const glibc = struct {
        extern "c" fn mallopt(param: c_int, value: c_int) c_int;
    };
    _ = glibc.mallopt(-8, 4); // -8 == M_ARENA_MAX
}

/// Return free heap memory to the OS. A library scan allocates large transient
/// buffers (full-image decode + thumbnail generation) that glibc otherwise keeps
/// in its arenas; calling this once a scan finishes hands that slack back.
fn trimMemory() void {
    if (builtin.target.os.tag != .linux) return;
    const glibc = struct {
        extern "c" fn malloc_trim(pad: usize) c_int;
    };
    _ = glibc.malloc_trim(0);
}

/// Tracks the scan-active edge so trimMemory() runs once when a scan completes.
var g_was_scanning: bool = false;

/// Confirmation state for the destructive bulk actions (duplicates / trash banner).
const PendingBulk = enum { none, dedupe, empty_trash };
var g_pending_bulk: PendingBulk = .none;
var g_pending_bulk_count: i64 = 0;

/// Render the bulk-action confirmation modal (no-op unless one is pending). On
/// confirm it kicks off the background op; the grid + counts refresh when it
/// finishes (image_ops.fileOpsPoll).
fn renderBulkConfirm() void {
    if (g_pending_bulk == .none) return;
    const init = dvui.App.main_init orelse return;

    var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{ .min_size_content = .{ .w = 400, .h = 0 } });
    defer float.deinit();
    float.autoSize();

    var content = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(18) });
    defer content.deinit();

    const title, const body, const confirm_label = switch (g_pending_bulk) {
        .dedupe => .{ i18n.t(.confirm_dedupe_title), i18n.t(.confirm_dedupe_body), i18n.t(.action_remove) },
        .empty_trash => .{ i18n.t(.confirm_empty_trash_title), i18n.t(.confirm_empty_trash_body), i18n.t(.confirm_delete) },
        .none => unreachable,
    };

    style.modalTitle(@src(), title);
    {
        // "<count> <count-free i18n body>" — fmt must be comptime, so the count
        // and the translatable text are rendered as two labels on one line.
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 14 } });
        defer line.deinit();
        dvui.label(@src(), "{d} ", .{g_pending_bulk_count}, .{
            .font = style.F.mono_val, .color_text = .{ .color = style.C.text_hi }, .gravity_y = 0.5,
        });
        dvui.label(@src(), "{s}", .{body}, .{ .color_text = .{ .color = style.C.text_dim }, .gravity_y = 0.5 });
    }

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
    defer btn_row.deinit();
    if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
        g_pending_bulk = .none;
    }
    if (dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4), .style = .err })) {
        switch (g_pending_bulk) {
            .dedupe => image_ops_mod.startRemoveRedundantDuplicates(init.io),
            .empty_trash => image_ops_mod.startEmptyTrash(init.io),
            .none => unreachable,
        }
        g_pending_bulk = .none;
    }
}

pub fn main(init: std.process.Init) !void {
    tuneAllocator();
    dvui.App.main_init = init;
    SDLBackend.c.SDL_SetMainReady();

    const opts = appStart();
    var back = try SDLBackend.initWindow(.{
        .io = init.io,
        .size = opts.size,
        .min_size = opts.min_size,
        .vsync = opts.vsync,
        .title = opts.title,
        .environ_map = init.environ_map,
        // Geometry is persisted in our own config (window_state.zig).
        .persist_window_geometry = false,
    });
    defer back.deinit();

    var win = try dvui.Window.init(@src(), init.gpa, back.backend(), .{});
    defer win.deinit();

    try win.begin(win.frame_time_ns);
    try appInit(&win);
    _ = try win.end(.{});
    // Restore the remembered main-window geometry (config is now loaded).
    window_state.apply(back.window, dk.g_cfg.main_window);
    g_dnd = dnd_mod.DragSource.init(init.gpa, back.window);
    defer appDeinit();
    defer g_viewer_manager.deinit(init.gpa);

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
        captureMainWindowState(&back);
        // Backend is managed by hand below: the DnD cursor overrides dvui's.
        var end_micros: ?u32 = try win.end(.{ .manage_backend = false });
        back.setCursor(win.cursorRequested());
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
        back.textInputRect(win.textInputRequested());
        back.renderPresent();
        if (res == .close) {
            // Hide right away: shutdown below waits for background work, and a
            // window that stays up looks hung.
            _ = SDLBackend.c.SDL_HideWindow(back.window);
            for (g_viewer_manager.windows.items) |vw| _ = SDLBackend.c.SDL_HideWindow(vw.back.window);
            break :main_loop;
        }

        // ── Viewer windows ────────────────────────────────────────────────────
        var vi: usize = 0;
        while (vi < g_viewer_manager.windows.items.len) {
            const vw = g_viewer_manager.windows.items[vi];
            try vw.win.begin(nstime);
            if (vw.dnd) |*d| d.tick(init.io);

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

            if (vw.state.favorite_toggle_requested) {
                vw.state.favorite_toggle_requested = false;
                if (vw.state.currentImage()) |img| toggleFavorite(img.id, img.path, img.favorite);
            }

            if (vw.state.delete_confirmed) {
                vw.state.delete_confirmed = false;
                if (vw.state.delete_no_ask) {
                    vw.state.delete_no_ask = false;
                    if (vw.state.delete_pending_permanent) g_delete_dialog.skip_permanent_delete_confirm = true
                    else g_delete_dialog.skip_delete_confirm = true;
                }
                if (dvui.App.main_init) |main_init| {
                    const iid = vw.state.delete_pending_id;
                    for (vw.state.images.items) |e| {
                        if (e.id == iid) {
                            performViewerDeleteEntry(main_init.io, e, vw.state.delete_pending_permanent);
                            break;
                        }
                    }
                }
            }

            if (vw.state.drag_requested) {
                vw.state.drag_requested = false;
                if (vw.dnd) |*d| {
                    if (vw.state.currentImage()) |img| {
                        const thumb = if (dk.g_grid) |*grid| grid.committed.get(img.id) else null;
                        const drag_item = dnd_mod.DragItem{
                            .path = img.path,
                            .thumb_jpeg = if (thumb) |t| t.bytes else &.{},
                        };
                        d.startDrag(&.{drag_item});
                    }
                }
            }

            var close = !vw.state.open;
            for (dvui.events()) |*e| {
                if (!e.handled and e.evt == .window and e.evt.window.action == .close)
                    close = true;
            }
            const vw_end: ?u32 = try vw.win.end(.{ .manage_backend = false });
            vw.back.setCursor(vw.win.cursorRequested());
            if (vw.dnd) |*d| {
                if (d.isDragging()) {
                    if (d.getSdlCursor()) |thumb_cursor| {
                        _ = SDLBackend.c.SDL_SetCursor(thumb_cursor);
                    } else {
                        if (vw.dnd_drag_cursor == null)
                            vw.dnd_drag_cursor = SDLBackend.c.SDL_CreateSystemCursor(SDLBackend.c.SDL_SYSTEM_CURSOR_MOVE);
                        if (vw.dnd_drag_cursor) |c| _ = SDLBackend.c.SDL_SetCursor(c);
                    }
                } else if (vw.dnd_drag_cursor) |c| {
                    _ = SDLBackend.c.SDL_SetCursor(null);
                    SDLBackend.c.SDL_DestroyCursor(c);
                    vw.dnd_drag_cursor = null;
                }
            }
            vw.back.renderPresent();

            // Reveal the window only after its first frame has been drawn and its
            // saved geometry applied (in viewer_manager.open, while hidden). This
            // avoids it appearing at the default position/screen and then jumping.
            if (!vw.shown) {
                vw.shown = true;
                _ = SDLBackend.c.SDL_ShowWindow(vw.back.window);
            }

            end_micros = pickMinWait(end_micros, vw_end);

            if (close) {
                // Hide immediately and defer the (thread-joining) teardown so the
                // window vanishes at once instead of freezing while loads finish.
                g_viewer_manager.beginClose(init.gpa, vw);
                _ = g_viewer_manager.windows.swapRemove(vi);
            } else {
                vi += 1;
            }
        }

        // Reap closed windows once their background loads have exited.  Poll
        // briefly while any remain pending so cleanup isn't stranded until the
        // next user event.
        if (g_viewer_manager.reapClosing(init.gpa)) {
            end_micros = pickMinWait(end_micros, 30_000);
        }

        // If a search debounce is pending, cap the event-wait to the deadline so
        // the render loop fires even when the user has stopped generating events.
        if (g_search.debounce_deadline_ns != 0) {
            if (dvui.App.main_init) |app_init| {
                const now = std.Io.Clock.real.now(app_init.io).nanoseconds;
                const remaining_ns = g_search.debounce_deadline_ns - now;
                const cap_us: u32 = if (remaining_ns <= 0) 0 else @intCast(@min(@divTrunc(remaining_ns, 1000) + 1, std.math.maxInt(u32)));
                end_micros = pickMinWait(end_micros, cap_us);
            }
        }

        const wait_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_micros);
    }
}
