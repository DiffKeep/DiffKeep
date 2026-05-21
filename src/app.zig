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
const filter_modal_mod = @import("filter_modal.zig");
const delete_dialog_mod = @import("delete_dialog.zig");
const settings_modal_mod = @import("settings_modal.zig");
const viewer_manager_mod = @import("viewer_manager.zig");
const search_mod = @import("search.zig");
const image_ops_mod = @import("image_ops.zig");
const toolbar_mod = @import("toolbar.zig");
const dk = @import("diffkeep.zig");

const noto_cjk_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
const noto_cjk_bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

// Path to the config file: set from --config/-c flag, otherwise resolved from known folders.
var g_config: ?[]const u8 = null;
// Directory that contains the DB file — also used as root for the trash folder.
var g_data_dir: ?[]const u8 = null;
var g_fs_watcher: ?fs_watch_mod.FsWatcher = null;
/// Pending per-file events collected from the watcher, waiting for the short
/// debounce window to expire before being dispatched to LibraryManager.
var g_pending_file_events: std.ArrayList(fs_watch_mod.DirtyEvent) = .empty;
/// Absolute nanosecond timestamp (Io.Clock.real) after which pending file
/// events should be flushed.  0 means nothing is pending.
var g_rescan_deadline_ns: i96 = 0;
var g_wakeup_event_type: u32 = 0;

fn wakeupFrame() void {
    var ev: SDLBackend.c.SDL_Event = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ev.type = g_wakeup_event_type;
    _ = SDLBackend.c.SDL_PushEvent(&ev);
}
var g_db_stats: ?db_mod.DbStats = null;
var g_trash_stats: ?db_mod.TrashStats = null;
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

// Active metadata filters
var g_active_filters: std.ArrayList(db_mod.ActiveFilter) = .empty;

// Filter modal state
var g_filter_modal: filter_modal_mod.FilterModalState = .{};

/// Refresh image counts for all libraries, total count, and trash stats.
/// Called at init and after any operation that changes counts.
fn refreshCounts() void {
    if (dvui.App.main_init) |init| {
        if (dk.g_db) |*db| {
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
    image_ops_mod.init(.{
        .db = &dk.g_db,
        .data_dir = &g_data_dir,
        .cfg = &dk.g_cfg,
        .on_counts_changed = refreshCounts,
    });

    if (dvui.App.main_init) |init| {
        if (g_config == null) {
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .local_configuration)) |config_dir| {
                defer init.gpa.free(config_dir);
                g_config = try std.fs.path.join(init.gpa, &.{ config_dir, "DiffKeep", "DiffKeep.cfg"});
            }
        }

        if (g_config) |cfg_path| {
            dk.g_cfg = try config_mod.load(init.gpa, init.io, cfg_path);
        }

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
                break :blk try std.fs.path.join(init.gpa, &.{ data_base, "DiffKeep", "diffkeep.db" });
            }
            break :blk null;
        };
        if (db_path) |p| {
            defer init.gpa.free(p);
            if (std.fs.path.dirname(p)) |dir| {
                g_data_dir = try init.gpa.dupe(u8, dir);
            }
            dk.g_db = try db_mod.VectorDb.init(init.gpa, init.io, p);
        }

        // Ensure trash directory exists and purge entries older than 30 days.
        if (g_data_dir) |data_dir| {
            var dd = try std.Io.Dir.openDirAbsolute(init.io, data_dir, .{});
            defer dd.close(init.io);
            dd.createDirPath(init.io, "trash") catch {};

            if (dk.g_db) |*db| {
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
            // concurrent task receives &dk.g_library_manager.? (stable global address)
            // rather than a pointer to a stack-local that becomes dangling after appInit returns.
            const notifier = if (dk.g_grid) |*grid| &grid.notifier else null;
            const watcher_ptr: ?*fs_watch_mod.FsWatcher = if (g_fs_watcher != null) &g_fs_watcher.? else null;
            dk.g_library_manager = library_manager_mod.LibraryManager.init(init.gpa, db, dk.g_cfg.thumbnails_in_db, dk.g_cfg.prompt_embeddings, dk.g_cfg.image_embeddings, notifier, watcher_ptr);
            g_search.wakeup_fn = wakeupFrame;

            if (dk.g_library_manager) |*mgr| {
                mgr.embedding_model_path = dk.g_cfg.embedding_model_path;
                mgr.embedding_mmproj_path = dk.g_cfg.embedding_mmproj_path;
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
        if (dk.g_library_manager) |*mgr| mgr.deinit(init.io);
    }
    if (dvui.App.main_init) |init| {
        g_search.awaitEmbed(init.io);
        g_search.awaitRerank(init.io);
        g_settings.awaitDownloads(init.io);
        g_search.deinit(init.gpa);
    }
    if (dk.g_grid) |*grid| grid.deinit();
    vips_mod.deinit();
    if (dk.g_db) |*database| {
        database.deinit();
        database.pool.deinit();
    }
    if (dvui.App.main_init) |init| {
        g_detail.deinit(init.gpa);
        g_sidebar.deinit(init.gpa);
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
        for (g_pending_file_events.items) |ev| init.gpa.free(ev.path);
        g_pending_file_events.deinit(init.gpa);
        g_filter_modal.deinit(init.gpa);
    }
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

    const permanent = force or !dk.g_cfg.trash_enabled;
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
        // Reload grid when a watcher-triggered deletion has been committed to the DB.
        if (dk.g_library_manager) |*mgr| {
            if (mgr.reload_requested.load(.acquire)) {
                mgr.reload_requested.store(false, .release);
                if (dk.g_db) |*db| grid.reloadImages(db) catch {};
            }
        }
        if (grid.images.items.len != prev_len) {
            if (dk.g_db) |*db| {
                g_total_image_count = db.getTotalImageCount() catch g_total_image_count;
                for (g_sidebar.libraries.items) |*lib| {
                    lib.image_count = db.getLibraryImageCount(lib.id) catch lib.image_count;
                }
            }
        }
    }

    // Apply completed background search tasks (rerank + query embedding)
    if (dvui.App.main_init) |init| {
        if (dk.g_grid) |*grid| {
            g_search.applyResultsIfDone(init.gpa, grid);
            if (dk.g_db) |*db| g_search.applyEmbedIfDone(init.gpa, grid, db, &dk.g_cfg);
        }
    }

    // Apply completed model downloads (auto-fill config paths)
    g_settings.applyCompletedDownloads(&dk.g_cfg, g_data_dir);

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
        if (grid.open_viewer_requested) {
            grid.open_viewer_requested = false;
            g_viewer_manager.open(grid, grid.viewer_start_id, g_data_dir, if (dk.g_db) |*db| db else null, wakeupFrame);
            grid.viewer_start_id = null;
        }
        if (grid.copy_prompt_requested) {
            grid.copy_prompt_requested = false;
            if (dvui.App.main_init) |init| {
                if (dk.g_db) |*db| {
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
            @memcpy(&g_search.prev, &g_search.buf);
            const q = std.mem.sliceTo(&g_search.buf, 0);
            log.info("search fired: mode={s} query=\"{s}\"", .{ @tagName(g_search.mode), q });
            if (dk.g_grid) |*grid| {
                grid.search_mode = g_search.mode;
                switch (g_search.mode) {
                    .fts => {
                        grid.search_query = if (q.len > 0) q else null;
                        grid.query_embedding = null;
                        if (g_search.query_embedding) |emb| {
                            init.gpa.free(emb);
                            g_search.query_embedding = null;
                        }
                        log.info("fts reload: query={?s}", .{grid.search_query});
                        if (dk.g_db) |*db| grid.reloadImages(db) catch {};
                    },
                    .semantic, .visual, .combined => {
                        grid.search_query = null;
                        if (g_search.query_embedding) |emb| {
                            init.gpa.free(emb);
                            g_search.query_embedding = null;
                        }
                        grid.query_embedding = null;
                        if (q.len > 0) {
                            log.info("spawning embed query: mode={s}", .{@tagName(g_search.mode)});
                            g_search.spawnEmbedQuery(init.io, init.gpa, q, g_search.mode, &dk.g_cfg) catch |err| {
                                log.warn("search embed spawn: {}", .{err});
                            };
                        }
                        // Show empty/cleared results immediately; applyEmbedIfDone
                        // will reload the grid with results once the embedding arrives.
                        if (dk.g_db) |*db| grid.reloadImages(db) catch {};
                    },
                }
            } else {
                log.warn("search fired but g_grid is null", .{});
            }
        }
    }

    if (dvui.App.main_init) |init| {
        try g_sidebar.drainPendingLibrary(
            init.gpa,
            init.io,
            if (dk.g_library_manager) |*mgr| mgr else null,
            if (dk.g_db) |*db| db else null,
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
                if (dk.g_library_manager) |*mgr| {
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
        .sidebar = &g_sidebar,
        .detail = &g_detail,
        .library_manager = &dk.g_library_manager,
        .left_w = &g_left_w,
        .left_w_open = &g_left_w_open,
        .right_w = &g_right_w,
        .right_w_open = &g_right_w_open,
        .total_image_count = &g_total_image_count,
        .on_refresh_counts = refreshCounts,
    };
    toolbar_mod.renderToolbar(render_ctx);
    try toolbar_mod.renderContent(render_ctx);
    toolbar_mod.renderStatusBar(render_ctx);

    // ── Settings modal ────────────────────────────────────────────────────────
    const settings_was_open = g_settings.open;
    try g_settings.render(&dk.g_cfg, &g_db_stats, &g_trash_stats, g_data_dir,
        if (dk.g_db) |*db| db else null,
        if (dk.g_grid) |*g| g else null);
    if (settings_was_open and !g_settings.open)
        g_settings.onClosed(&dk.g_cfg, &dk.g_library_manager, &g_search);

    // ── Delete confirmation modal ─────────────────────────────────────────────
    try g_delete_dialog.render(dk.g_cfg.trash_enabled,
        if (dk.g_grid) |*g| g else null,
        image_ops_mod.performTrash, image_ops_mod.performDelete);

    // ── Filter modal ──────────────────────────────────────────────────────────
    try g_filter_modal.render(
        &g_active_filters,
        if (dk.g_db) |*db| db else null,
        if (dk.g_grid) |*g| g else null,
    );

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

var g_viewer_manager: viewer_manager_mod.ViewerManager = .{};

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




/// Perform trash/delete on a specific image entry owned by a viewer (not grid selection).
fn performViewerDeleteEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: image_grid_mod.ImageEntry,
    force: bool,
) void {
    const data_dir = g_data_dir orelse return;

    if (force or !dk.g_cfg.trash_enabled) {
        const file_path: []const u8 = if (entry.trash_name) |tn|
            std.fs.path.join(allocator, &.{ data_dir, "trash", tn }) catch return
        else
            entry.path;
        defer if (entry.trash_name != null) allocator.free(file_path);
        std.Io.Dir.cwd().deleteFile(io, file_path) catch |err|
            log.warn("delete {s}: {}", .{ entry.filename, err });
        if (dk.g_db) |*db| db.deleteImage(entry.id) catch |err|
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
        image_ops_mod.moveFile(io, allocator, entry.path, dst) catch |err| {
            log.warn("trash {s}: {}", .{ entry.filename, err });
            return;
        };
        if (dk.g_db) |*db| db.trashImage(entry.id, trash_name, file_size, now_s) catch |err|
            log.warn("trashImage {d}: {}", .{ entry.id, err });
    }

    var ids = std.AutoHashMap(u64, void).init(allocator);
    defer ids.deinit();
    ids.put(entry.id, {}) catch {};
    if (dk.g_grid) |*grid| image_ops_mod.removeFromGrid(grid, &ids);
    g_viewer_manager.removeImages(&ids);
    refreshCounts();
}

fn openViewerDeleteDialog(state: *image_viewer_mod.ViewerState, force: bool) void {
    const init = dvui.App.main_init orelse return;
    const img = state.currentImage() orelse return;

    const permanent = force or !dk.g_cfg.trash_enabled;

    if (!permanent and g_delete_dialog.skip_delete_confirm) {
        performViewerDeleteEntry(init.io, init.gpa, img.*, force);
        return;
    }
    if (permanent and g_delete_dialog.skip_permanent_delete_confirm) {
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
        while (vi < g_viewer_manager.windows.items.len) {
            const vw = g_viewer_manager.windows.items[vi];
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
                    if (vw.state.delete_pending_permanent) g_delete_dialog.skip_permanent_delete_confirm = true
                    else g_delete_dialog.skip_delete_confirm = true;
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
                _ = g_viewer_manager.windows.swapRemove(vi);
            } else {
                vi += 1;
            }
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
