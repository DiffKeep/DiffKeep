//! Everything the main window holds and does each frame, without SDL: the
//! config, database, grid, library manager, embedder, background loaders,
//! panels and dialogs, and the per-frame logic that ties them together.
//!
//! app.zig owns one AppState and drives it from dvui's callbacks; what needs
//! SDL itself (viewer windows, native drag-and-drop, waking the event loop)
//! comes in through `Hooks`. Because nothing here needs SDL, the integration
//! tests can run whole frames against dvui's headless backend.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const library_manager_mod = @import("library_manager.zig");
const counts_mod = @import("counts.zig");
const fs_watch_mod = @import("fs_watch.zig");
const image_grid_mod = @import("image_grid.zig");
const embedder_mod = @import("embedder.zig");
const detail_panel_mod = @import("detail_panel.zig");
const sidebar_mod = @import("sidebar.zig");
const image_viewer_mod = @import("image_viewer.zig");
const filter_modal_mod = @import("filter_modal.zig");
const delete_dialog_mod = @import("delete_dialog.zig");
const settings_modal_mod = @import("settings_modal.zig");
const search_mod = @import("search.zig");
const image_ops_mod = @import("image_ops.zig");
const toolbar_mod = @import("toolbar.zig");
const style = @import("style.zig");

const log = std.log.scoped(.app);

/// A file handed to a native drag (see dnd.zig).
pub const DragItem = struct { path: []const u8, thumb_jpeg: []const u8 };

/// What the SDL side does for the app. The defaults do nothing, which is what
/// the headless tests want.
pub const Hooks = struct {
    /// Wake the render loop from any thread (background work finished).
    wakeup: *const fn () void = noop,
    /// Open viewer windows on the grid's images, starting at `start_id`.
    open_viewer: *const fn (app: *AppState, grid: *image_grid_mod.GridState, start_id: ?u64) void = noopOpenViewer,
    /// Start a native drag of these files.
    start_drag: *const fn (items: []const DragItem) void = noopDrag,
    /// Drop removed images from the viewer windows.
    viewers_remove: *const fn (ids: *const std.AutoHashMap(u64, void)) void = noopRemove,
    /// Show a favorite change in the viewer windows.
    viewers_set_favorite: *const fn (id: u64, favorite: bool) void = noopFavorite,

    fn noop() void {}
    fn noopOpenViewer(_: *AppState, _: *image_grid_mod.GridState, _: ?u64) void {}
    fn noopDrag(_: []const DragItem) void {}
    fn noopRemove(_: *const std.AutoHashMap(u64, void)) void {}
    fn noopFavorite(_: u64, _: bool) void {}
};

/// Loads the embedder on its own thread (it reads model weights: seconds of
/// IO and CPU), so the render thread never waits for it.
const EmbedderLoad = struct {
    thread: ?std.Thread = null,
    result: ?embedder_mod.Embedder = null,
    done: std.atomic.Value(bool) = .init(false),
    /// A reload asked for while one is in flight; started when it finishes.
    pending: ?Args = null,

    const Args = struct {
        text_dir: ?[]const u8, // owned; freed by the thread
        visual_dir: ?[]const u8, // owned; freed by the thread
        gpu_backend: embedder_mod.GpuBackend,
        threshold: usize,
    };
};

/// Confirmation state for the destructive bulk actions (duplicates / trash banner).
pub const PendingBulk = enum { none, dedupe, empty_trash };

pub const AppState = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    hooks: Hooks,

    /// The config file (from --config, else the XDG config dir). Owned.
    config_path: ?[]const u8 = null,
    /// Directory holding the DB file and the trash folder. Owned.
    data_dir: ?[]const u8 = null,
    cfg: config_mod.Config = .{},
    db: ?db_mod.VectorDb = null,
    grid: ?image_grid_mod.GridState = null,
    library_manager: ?library_manager_mod.LibraryManager = null,
    embedder: ?embedder_mod.Embedder = null,
    emb_load: EmbedderLoad = .{},
    fs_watcher: ?fs_watch_mod.FsWatcher = null,
    file_ops: ?image_ops_mod.FileOps = null,

    /// Watcher events waiting out the debounce before going to the library
    /// manager; `rescan_deadline_ns` (Io.Clock.real) is when, 0 = none pending.
    pending_file_events: library_manager_mod.PendingFileEvents = .{},
    rescan_deadline_ns: i96 = 0,

    counts: ?counts_mod.CountsLoader = null,
    db_stats: ?db_mod.DbStats = null,
    trash_stats: ?db_mod.TrashStats = null,
    duplicate_count: i64 = 0,
    redundant_duplicate_count: i64 = 0,
    favorite_count: i64 = 0,
    total_image_count: i64 = 0,

    sidebar: sidebar_mod.SidebarState = .{},
    detail: detail_panel_mod.DetailState = .{},
    delete_dialog: delete_dialog_mod.DeleteDialogState = .{},
    search: search_mod.SearchState = .{},
    settings: settings_modal_mod.SettingsModalState = .{},
    active_filters: std.ArrayList(db_mod.ActiveFilter) = .empty,
    filter_modal: filter_modal_mod.FilterModalState = .{},
    pending_bulk: PendingBulk = .none,
    pending_bulk_count: i64 = 0,

    // Panel widths in logical pixels.  _open stores the last non-collapsed width.
    left_w: f32 = 240,
    left_w_open: f32 = 240,
    right_w: f32 = 300,
    right_w_open: f32 = 300,

    /// The scan-active edge, so trimMemory() runs once when a scan completes.
    was_scanning: bool = false,

    /// Load the config, open the database and start every background service.
    /// `self` must be at its final address: background threads point into it.
    /// `config_path` (owned, may be null) overrides the XDG location.
    pub fn init(
        self: *AppState,
        io: std.Io,
        gpa: std.mem.Allocator,
        environ_map: ?*const std.process.Environ.Map,
        hooks: Hooks,
        config_path: ?[]const u8,
    ) !void {
        self.* = .{ .io = io, .gpa = gpa, .hooks = hooks, .config_path = config_path };
        self.file_ops = .init(io, .{
            .db = &self.db,
            .data_dir = &self.data_dir,
            .context = self,
            .on_counts_changed = onCountsChanged,
            .on_images_removed = onImagesRemoved,
            .on_wakeup = hooks.wakeup,
        });

        if (self.config_path == null) if (environ_map) |env| {
            if (try @import("known-folders").getPath(io, gpa, env, .local_configuration)) |config_dir| {
                defer gpa.free(config_dir);
                self.config_path = try std.Io.Dir.path.join(gpa, &.{ config_dir, "DiffKeep", "DiffKeep.cfg" });
            }
        };
        if (self.config_path) |cfg_path| self.cfg = try config_mod.load(gpa, io, cfg_path);

        // Restore remembered grid panel widths.
        self.left_w = self.cfg.grid_left_w;
        self.left_w_open = self.cfg.grid_left_w_open;
        self.right_w = self.cfg.grid_right_w;
        self.right_w_open = self.cfg.grid_right_w_open;
        self.settings.initFromConfig(&self.cfg);

        const db_path = blk: {
            if (self.cfg.data_path) |p| break :blk try gpa.dupe(u8, p);
            const env = environ_map orelse break :blk null;
            if (try @import("known-folders").getPath(io, gpa, env, .data)) |data_base| {
                defer gpa.free(data_base);
                var data_dir = try std.Io.Dir.openDirAbsolute(io, data_base, .{});
                defer data_dir.close(io);
                try data_dir.createDirPath(io, "DiffKeep");
                break :blk try std.Io.Dir.path.join(gpa, &.{ data_base, "DiffKeep", "diffkeep.db" });
            }
            break :blk null;
        };
        if (db_path) |p| {
            defer gpa.free(p);
            if (std.Io.Dir.path.dirname(p)) |dir| self.data_dir = try gpa.dupe(u8, dir);
            self.db = try db_mod.VectorDb.init(gpa, io, p);
        }

        // Ensure the trash directory exists and purge entries older than 30 days.
        if (self.data_dir) |data_dir| {
            var dd = try std.Io.Dir.openDirAbsolute(io, data_dir, .{});
            defer dd.close(io);
            dd.createDirPath(io, "trash") catch {};
            if (self.db != null) {
                const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
                self.file_ops.?.startPurgeExpiredTrash(now_s - 30 * 24 * 60 * 60);
            }
        }

        const db = if (self.db) |*d| d else return;
        // The grid's own load fails the same way and says so on screen.
        self.sidebar.loadLibraries(gpa, db) catch |err| log.warn("library list: {}", .{err});

        // The grid comes first so the library manager can take its notifier.
        self.grid = try image_grid_mod.GridState.init(io, gpa, db, self.cfg.thumbnails_in_db, hooks.wakeup);
        const grid = &self.grid.?;
        grid.data_dir = self.data_dir;
        grid.thumb_fraction = std.math.clamp(self.cfg.grid_thumb_fraction, 0, 1);
        grid.autoplay = self.cfg.grid_autoplay;
        grid.semantic_min_similarity = self.cfg.semantic_min_similarity;
        grid.visual_min_similarity = self.cfg.visual_min_similarity;
        try grid.startWorker();
        // The list loads in the background; the grid fills in when it lands.
        grid.reloadImages();

        // The watcher comes before the library manager, so it can take
        // addLibrary commands as soon as the manager exists.
        self.fs_watcher = fs_watch_mod.FsWatcher.init(gpa) catch |err| blk: {
            log.warn("fs_watch init failed: {}; live watching disabled", .{err});
            break :blk null;
        };
        if (self.fs_watcher) |*watcher| {
            if (watcher.start()) {
                // Wake the event loop whenever the watcher pushes a file event.
                watcher.events.on_dirty = hooks.wakeup;
            } else |err| {
                log.warn("fs_watch start failed: {}; live watching disabled", .{err});
                watcher.deinit();
                self.fs_watcher = null;
            }
        }

        const watcher_ptr: ?*fs_watch_mod.FsWatcher = if (self.fs_watcher) |*w| w else null;
        self.library_manager = library_manager_mod.LibraryManager.init(gpa, io, db, self.cfg.thumbnails_in_db, self.cfg.prompt_embeddings, self.cfg.image_embeddings, &grid.notifier, watcher_ptr);
        const mgr = &self.library_manager.?;
        mgr.data_dir = self.data_dir;
        mgr.wakeup_fn = hooks.wakeup;
        self.search.wakeup_fn = hooks.wakeup;
        self.sidebar.wakeup_fn = hooks.wakeup;
        self.sidebar.initFolderLoader(gpa, io, db);
        self.detail.wakeup_fn = hooks.wakeup;

        // The embedder loads in the background; search and scans run without
        // it until pollEmbedderLoad() wires it in.
        self.startEmbedderLoad();
        mgr.scanAllLibraries() catch |err| log.warn("startup scan queue failed: {}", .{err});

        // Register all existing libraries with the watcher.
        if (self.fs_watcher) |*watcher| {
            const libs = db.listLibraries(gpa) catch |err| blk: {
                log.warn("libraries not watched: {}", .{err});
                break :blk &[_]db_mod.LibraryInfo{};
            };
            defer {
                for (libs) |li| gpa.free(li.path);
                gpa.free(libs);
            }
            for (libs) |li| watcher.addLibrary(li.id, li.path) catch |err|
                log.warn("watch library {s}: {} (changes show up on the next scan)", .{ li.path, err });
        }

        self.counts = counts_mod.CountsLoader.init(gpa, io, db);
        self.counts.?.wakeup_fn = hooks.wakeup;
        self.refreshCounts();
    }

    /// Stop everything, in an order where nothing still running can touch
    /// what has been freed, and save the config.
    pub fn deinit(self: *AppState) void {
        const gpa = self.gpa;
        var timer = ShutdownTimer.start(self.io);
        // The watcher thread goes first so it can't call back into freed state.
        if (self.fs_watcher) |*watcher| watcher.deinit();
        timer.lap("fs watcher");
        if (self.library_manager) |*mgr| mgr.deinit(self.io);
        timer.lap("library manager (scans)");
        self.search.awaitEmbed();
        self.search.deinit(gpa);
        timer.lap("search");
        // Join the embedder load thread (if running) and discard any result.
        if (self.emb_load.thread) |t| t.join();
        self.emb_load.thread = null;
        if (self.emb_load.result) |*emb| emb.deinit();
        self.emb_load.result = null;
        if (self.emb_load.pending) |p| freeLoadArgs(gpa, p);
        self.emb_load.pending = null;
        timer.lap("embedder load thread");
        if (self.file_ops) |*ops| ops.deinit();
        self.file_ops = null;
        timer.lap("file ops");
        if (self.embedder) |*emb| emb.deinit();
        timer.lap("embedder");
        if (self.grid) |*grid| grid.deinit();
        timer.lap("grid");
        if (self.counts) |*c| c.deinit();
        self.counts = null;
        // These await their background loads, which use the DB: before it closes.
        self.detail.deinit(gpa);
        self.sidebar.deinit(gpa);
        if (self.db) |*database| database.deinit();
        timer.lap("db");
        self.delete_dialog.deinit(gpa);
        if (self.config_path) |cfg_path| {
            config_mod.save(self.cfg, self.io, cfg_path) catch |err| log.warn("failed to save config: {}", .{err});
            gpa.free(cfg_path);
        }
        self.cfg.deinit(gpa);
        if (self.data_dir) |d| gpa.free(d);
        for (self.active_filters.items) |f| gpa.free(f.value);
        self.active_filters.deinit(gpa);
        self.pending_file_events.deinit(gpa);
        self.filter_modal.deinit(gpa);
        timer.lap("config + state");
    }

    // ── Counts ────────────────────────────────────────────────────────────

    /// Ask for fresh image counts; they load in the background and
    /// `applyCounts` shows them.
    pub fn refreshCounts(self: *AppState) void {
        if (self.counts) |*c| c.request();
    }

    fn onCountsChanged(context: ?*anyopaque) void {
        const self: *AppState = @ptrCast(@alignCast(context.?));
        self.refreshCounts();
    }

    fn onImagesRemoved(context: ?*anyopaque, ids: *const std.AutoHashMap(u64, void)) void {
        const self: *AppState = @ptrCast(@alignCast(context.?));
        self.hooks.viewers_remove(ids);
    }

    /// Show counts a background load has finished.
    fn applyCounts(self: *AppState) void {
        const loader = if (self.counts) |*c| c else return;
        var c = loader.poll() orelse return;
        defer c.deinit(loader.allocator);
        self.total_image_count = c.total;
        self.trash_stats = c.trash;
        self.duplicate_count = c.duplicates;
        self.redundant_duplicate_count = c.redundant_duplicates;
        if (c.db_stats) |st| self.db_stats = st;
        self.favorite_count = c.favorites;
        self.sidebar.applyLibraryCounts(c.libraries);
    }

    // ── Actions ───────────────────────────────────────────────────────────

    /// Toggle an image's favorite flag (raised from the grid star or the
    /// viewer toolbar). `path` and `current` come from the entry the user
    /// acted on; the update only applies if the row is still that file (ids
    /// are recycled).
    pub fn toggleFavorite(self: *AppState, id: u64, path: []const u8, current: bool) void {
        const db = if (self.db) |*d| d else return;
        const new_val = !current;
        const matched = db.setFavorite(id, path, new_val) catch |err| {
            log.warn("setFavorite {d}: {}", .{ id, err });
            return;
        };
        if (!matched) return; // the row is gone; a pending reload drops the entry

        if (self.grid) |*grid| {
            for (grid.images.items) |*e| {
                if (e.id == id) e.favorite = new_val;
            }
            // In the Favorites view an un-favorited image leaves the grid at once.
            if (grid.view_mode == .favorites and !new_val) {
                var ids = std.AutoHashMap(u64, void).init(self.gpa);
                defer ids.deinit();
                ids.put(id, {}) catch return grid.reloadImagesEx(.{ .keep_scroll = true });
                const saved_y = grid.scroll_info.viewport.y;
                image_ops_mod.removeFromGrid(grid, &ids);
                grid.scroll_info.viewport.y = saved_y;
            }
        }
        self.hooks.viewers_set_favorite(id, new_val);
        self.refreshCounts();
    }

    /// Open the delete confirmation for the grid's selection (or act at once
    /// when the user asked not to be asked).
    fn openDeleteDialog(self: *AppState, grid: *image_grid_mod.GridState, force: bool) void {
        var count: usize = grid.selection.count();
        if (count == 0) {
            if (grid.focused_idx) |fi| {
                if (fi < grid.images.items.len) count = 1;
            }
        }
        if (count == 0) return;

        const dlg = &self.delete_dialog;
        dlg.count = count;
        // Items already in the trash can only be permanently deleted, never re-trashed.
        dlg.force = force or (grid.view_mode == .trash);

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
            const len = @min(name.len, dlg.name_buf.len);
            @memcpy(dlg.name_buf[0..len], name[0..len]);
            dlg.name_len = len;
        }

        // Trashed items can only be deleted permanently: mirror dlg.force so
        // the skip-confirm fast path never tries to re-trash one.
        const permanent = dlg.force or !self.cfg.trash_enabled;
        if (count == 1) {
            const ops = if (self.file_ops) |*o| o else return;
            if (!permanent and dlg.skip_delete_confirm) return ops.performTrash(self.gpa, grid);
            if (permanent and dlg.skip_permanent_delete_confirm) return ops.performDelete(self.gpa, grid);
        }
        dlg.snapshot(self.gpa, grid);
        dlg.open = true;
    }

    /// Trash or delete an image shown in a viewer (not the grid selection).
    pub fn performViewerDeleteEntry(self: *AppState, entry: image_grid_mod.ImageEntry, force: bool) void {
        // A trashed entry (trash_name set) is already in the trash; it can only be
        // deleted permanently, never re-trashed.
        const permanent = force or entry.trash_name != null or !self.cfg.trash_enabled;
        if (self.file_ops) |*ops| ops.performOnEntry(entry, if (permanent) .delete else .trash);
    }

    /// The viewer's delete request: act at once, or set up its confirmation
    /// (rendered inside the viewer window).
    pub fn openViewerDeleteDialog(self: *AppState, state: *image_viewer_mod.ViewerState, force: bool) void {
        const img = state.currentImage() orelse return;
        // Must match performViewerDeleteEntry: an image already in the trash
        // can only be deleted permanently, so it gets the permanent prompt.
        const permanent = force or img.trash_name != null or !self.cfg.trash_enabled;
        if (!permanent and self.delete_dialog.skip_delete_confirm) return self.performViewerDeleteEntry(img.*, force);
        if (permanent and self.delete_dialog.skip_permanent_delete_confirm) return self.performViewerDeleteEntry(img.*, force);

        state.delete_pending_id = img.id;
        state.delete_pending_permanent = permanent;
        const len = @min(img.filename.len, state.delete_pending_name_buf.len);
        @memcpy(state.delete_pending_name_buf[0..len], img.filename[0..len]);
        state.delete_pending_name_len = len;
        state.delete_confirm_open = true;
    }

    // ── Per frame ─────────────────────────────────────────────────────────

    /// One frame of the main window: apply what background work finished,
    /// act on what the user asked for, then draw.
    pub fn frame(self: *AppState) !void {
        self.applyBackgroundResults();
        if (self.grid) |*grid| self.handleGridRequests(grid);
        self.fireSearchIfDue();
        try self.sidebar.drainPendingLibrary(self.gpa, if (self.library_manager) |*m| m else null);
        self.flushWatcherEvents();
        try self.render();
    }

    fn applyBackgroundResults(self: *AppState) void {
        if (self.grid) |*grid| {
            const prev_len = grid.images.items.len;
            grid.update();
            // Images the watcher saw deleted, or the thumbnail loader found
            // missing, leave the grid and viewers in place: no full reload,
            // so scroll and focus are kept.
            var removed: std.ArrayList(u64) = .empty;
            defer removed.deinit(self.gpa);
            var lost = false;
            if (self.library_manager) |*mgr| lost = mgr.drainRemovedIds(self.io, &removed);
            if (grid.thumbs.drainMissingIds(self.gpa, &removed)) lost = true;
            if (removed.items.len > 0) {
                var ids = std.AutoHashMap(u64, void).init(self.gpa);
                defer ids.deinit();
                if (ids.ensureTotalCapacity(@intCast(removed.items.len))) {
                    for (removed.items) |id| ids.putAssumeCapacity(id, {});
                    image_ops_mod.removeFromGrid(grid, &ids);
                    self.hooks.viewers_remove(&ids);
                } else |err| {
                    log.warn("removed images: {}", .{err});
                    lost = true;
                }
            }
            // Some removals couldn't be applied here: reload from the DB.
            if (lost) grid.reloadImagesEx(.{ .keep_scroll = true });
            if (grid.images.items.len != prev_len) self.refreshCounts();
            self.search.applyEmbedIfDone(self.gpa, grid);
            // Finished file operations leave the grid (and viewers).
            if (self.file_ops) |*ops| _ = ops.poll(self.gpa, grid);
        }
        self.applyCounts();

        // When a library scan finishes, hand its transient decode/thumbnail
        // memory back to the OS (see trimMemory).
        const scanning = if (self.library_manager) |*mgr| mgr.isScanActive() else false;
        if (self.was_scanning and !scanning) trimMemory();
        self.was_scanning = scanning;

        // Completed model downloads fill in the config's model paths.
        self.settings.applyCompletedDownloads(&self.cfg, self.data_dir);
        if (self.settings.model_paths_changed and !self.settings.open) {
            self.settings.model_paths_changed = false;
            self.releaseEmbedder();
            self.startEmbedderLoad();
        }
        self.pollEmbedderLoad();
    }

    /// Act on what the grid's keyboard shortcuts, menus and banners asked for.
    fn handleGridRequests(self: *AppState, grid: *image_grid_mod.GridState) void {
        if (grid.delete_requested) {
            grid.delete_requested = false;
            self.openDeleteDialog(grid, grid.delete_force);
        }
        if (grid.restore_requested) {
            grid.restore_requested = false;
            if (self.file_ops) |*ops| ops.performRestore(self.gpa, grid);
        }
        if (grid.favorite_toggle_id) |id| {
            grid.favorite_toggle_id = null;
            if (grid.entryById(id)) |e| self.toggleFavorite(e.id, e.path, e.favorite);
        }
        if (grid.dedupe_requested) {
            grid.dedupe_requested = false;
            self.pending_bulk_count = self.redundant_duplicate_count;
            if (self.pending_bulk_count > 0) self.pending_bulk = .dedupe;
        }
        if (grid.empty_trash_requested or self.settings.empty_trash_requested) {
            grid.empty_trash_requested = false;
            self.settings.empty_trash_requested = false;
            self.pending_bulk_count = if (self.trash_stats) |ts| ts.count else 0;
            if (self.pending_bulk_count > 0) self.pending_bulk = .empty_trash;
        }
        if (grid.open_viewer_requested) {
            grid.open_viewer_requested = false;
            self.hooks.open_viewer(self, grid, grid.viewer_start_id);
            grid.viewer_start_id = null;
        }
        if (grid.copy_prompt_requested) {
            grid.copy_prompt_requested = false;
            // A point query on the main connection.
            if (self.db) |*db| if (db.getPositivePromptText(self.gpa, grid.copy_prompt_id) catch |err| blk: {
                log.warn("copy prompt: {}", .{err});
                break :blk null;
            }) |prompt| {
                defer self.gpa.free(prompt);
                dvui.clipboardTextSet(prompt);
            };
        }
        if (grid.copy_image_requested) {
            grid.copy_image_requested = false;
            if (grid.entryById(grid.copy_image_id)) |e|
                detail_panel_mod.copyImageToClipboard(e.path, self.gpa, self.io);
        }
        if (grid.reparse_requested) {
            grid.reparse_requested = false;
            if (self.db) |*db| if (self.library_manager) |*mgr| {
                // A file worker resets the image's mtime and re-reads it; the
                // detail panel reloads once the new data lands.
                if (db.getImageDetails(self.gpa, grid.reparse_id) catch |err| blk: {
                    log.warn("reparse: {}", .{err});
                    break :blk null;
                }) |det| {
                    var d = det;
                    defer d.deinit(self.gpa);
                    mgr.reparseImage(d.id, d.library_id, d.library_path);
                }
            };
        }
        if (grid.drag_requested) {
            grid.drag_requested = false;
            var items: std.ArrayList(DragItem) = .empty;
            defer items.deinit(self.gpa);
            // A drag of fewer files than were picked up would be wrong: none.
            if (items.ensureTotalCapacity(self.gpa, grid.drag_requested_ids.items.len)) {
                for (grid.drag_requested_ids.items) |id| {
                    const entry = grid.entryById(id) orelse continue;
                    const thumb = grid.thumbs.committed.get(id);
                    items.appendAssumeCapacity(.{
                        .path = entry.path,
                        .thumb_jpeg = if (thumb) |t| t.bytes else &.{},
                    });
                }
                if (items.items.len > 0) self.hooks.start_drag(items.items);
            } else |err| log.warn("drag: {}", .{err});
            grid.drag_requested_ids.clearRetainingCapacity();
        }
    }

    /// Run the search 300 ms after the last keystroke, or at once when a mode
    /// button asked for it.
    fn fireSearchIfDue(self: *AppState) void {
        const s = &self.search;
        const now_ns: i96 = std.Io.Clock.real.now(self.io).nanoseconds;
        if (!std.mem.eql(u8, &s.buf, &s.last_buf)) {
            s.debounce_deadline_ns = now_ns + 300 * std.time.ns_per_ms;
            @memcpy(&s.last_buf, &s.buf);
        }
        const due = s.force_search or (s.debounce_deadline_ns != 0 and now_ns >= s.debounce_deadline_ns);
        if (!due) return;
        s.force_search = false;
        s.debounce_deadline_ns = 0;
        if (self.grid) |*grid| s.fire(self.io, self.gpa, grid);
    }

    /// Collect watcher events, and hand them to the library manager once
    /// 200 ms pass without more (a burst is merged per file).
    fn flushWatcherEvents(self: *AppState) void {
        if (self.fs_watcher) |*watcher| {
            var new_events = watcher.drainEvents();
            defer new_events.deinit(self.gpa);
            var lost = watcher.takeLost();
            if (new_events.items.len > 0) {
                self.rescan_deadline_ns = std.Io.Clock.real.now(self.io).nanoseconds + 200 * std.time.ns_per_ms;
                for (new_events.items) |ev| self.pending_file_events.add(self.gpa, ev) catch |err| {
                    log.warn("watcher event: {}", .{err});
                    lost = true;
                };
            }
            // A change was dropped: a scan of every library finds it.
            if (lost) if (self.library_manager) |*mgr|
                mgr.scanAllLibraries() catch |err| log.warn("rescan after dropped events: {}", .{err});
        }
        if (self.rescan_deadline_ns == 0) return;
        if (std.Io.Clock.real.now(self.io).nanoseconds < self.rescan_deadline_ns) {
            // Keep frames coming so the deadline isn't missed.
            self.hooks.wakeup();
            return;
        }
        self.rescan_deadline_ns = 0;
        if (self.library_manager) |*mgr| {
            mgr.flushFileEvents(self.io, &self.pending_file_events);
        } else {
            self.pending_file_events.deinit(self.gpa);
            self.pending_file_events = .{};
        }
    }

    fn render(self: *AppState) !void {
        // The app ground. Every band below paints its own surface on top;
        // this is what shows through the gaps and behind the grid.
        var col = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = style.C.canvas },
        });
        defer col.deinit();

        const render_ctx: toolbar_mod.RenderCtx = .{
            .search = &self.search,
            .active_filters = &self.active_filters,
            .filter_modal = &self.filter_modal,
            .grid = &self.grid,
            .db = &self.db,
            .cfg = &self.cfg,
            .settings = &self.settings,
            .db_stats = &self.db_stats,
            .trash_stats = &self.trash_stats,
            .duplicate_count = &self.duplicate_count,
            .favorite_count = &self.favorite_count,
            .sidebar = &self.sidebar,
            .detail = &self.detail,
            .library_manager = &self.library_manager,
            .left_w = &self.left_w,
            .left_w_open = &self.left_w_open,
            .right_w = &self.right_w,
            .right_w_open = &self.right_w_open,
            .total_image_count = &self.total_image_count,
            .counts = if (self.counts) |*c| c else null,
            .file_ops = if (self.file_ops) |*o| o else null,
            .embedder_loading = self.emb_load.thread != null,
        };
        toolbar_mod.renderToolbar(render_ctx);
        try toolbar_mod.renderContent(render_ctx);
        toolbar_mod.renderStatusBar(render_ctx);

        // ── Settings modal ────────────────────────────────────────────────
        const settings_was_open = self.settings.open;
        try self.settings.render(&self.cfg, &self.db_stats, &self.trash_stats, self.data_dir, self.db != null, self.hooks.wakeup);
        if (self.settings.clear_requested) |cache| {
            self.settings.clear_requested = null;
            if (self.counts) |*c| c.clear(cache);
        }
        if (settings_was_open and !self.settings.open) self.onSettingsClosed();

        // ── Delete confirmation, bulk confirmation, filters ───────────────
        try self.delete_dialog.render(self.cfg.trash_enabled, if (self.grid) |*g| g else null, if (self.file_ops) |*o| o else null, self.gpa);
        self.renderBulkConfirm();
        try self.filter_modal.render(&self.active_filters, if (self.db) |*db| db else null, if (self.grid) |*g| g else null);

        // Mirror remembered grid layout into the config (saved on exit).
        if (self.grid) |*grid| {
            self.cfg.grid_thumb_fraction = grid.thumb_fraction;
            self.cfg.grid_autoplay = grid.autoplay;
        }
        self.cfg.grid_left_w = self.left_w;
        self.cfg.grid_left_w_open = self.left_w_open;
        self.cfg.grid_right_w = self.right_w;
        self.cfg.grid_right_w_open = self.right_w_open;
    }

    fn onSettingsClosed(self: *AppState) void {
        self.settings.onClosed(&self.cfg, &self.library_manager, &self.search);
        if (self.grid) |*grid| grid.thumbs.thumbnails_in_db.store(self.cfg.thumbnails_in_db, .release);
        if (self.settings.model_paths_changed) {
            self.settings.model_paths_changed = false;
            self.releaseEmbedder();
            self.startEmbedderLoad();
        }
        // Persist config as soon as the settings screen closes.
        if (self.config_path) |cfg_path| config_mod.save(self.cfg, self.io, cfg_path) catch |err|
            log.warn("config save on settings close failed: {}", .{err});
    }

    /// The bulk-action confirmation (no-op unless one is pending). On confirm
    /// it starts the background operation; `FileOps.poll` applies the result.
    fn renderBulkConfirm(self: *AppState) void {
        if (self.pending_bulk == .none) return;

        var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{ .min_size_content = .{ .w = 400, .h = 0 } });
        defer float.deinit();
        float.autoSize();

        var content = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(18) });
        defer content.deinit();

        const title, const body, const confirm_label = switch (self.pending_bulk) {
            .dedupe => .{ i18n.t(.confirm_dedupe_title), i18n.t(.confirm_dedupe_body), i18n.t(.action_remove) },
            .empty_trash => .{ i18n.t(.confirm_empty_trash_title), i18n.t(.confirm_empty_trash_body), i18n.t(.confirm_delete) },
            .none => unreachable,
        };

        style.modalTitle(@src(), title);
        {
            // "<count> <count-free i18n body>": fmt must be comptime, so the
            // count and the translatable text are two labels on one line.
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 14 } });
            defer line.deinit();
            dvui.label(@src(), "{d} ", .{self.pending_bulk_count}, .{
                .font = style.F.mono_val, .color_text = .{ .color = style.C.text_hi }, .gravity_y = 0.5,
            });
            dvui.label(@src(), "{s}", .{body}, .{ .color_text = .{ .color = style.C.text_dim }, .gravity_y = 0.5 });
        }

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
        defer btn_row.deinit();
        if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
            self.pending_bulk = .none;
        }
        if (dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4), .style = .err })) {
            if (self.file_ops) |*ops| switch (self.pending_bulk) {
                .dedupe => ops.startRemoveRedundantDuplicates(),
                .empty_trash => ops.startEmptyTrash(),
                .none => unreachable,
            };
            self.pending_bulk = .none;
        }
    }

    // ── Embedder loading ──────────────────────────────────────────────────

    fn loadArgs(self: *AppState) !EmbedderLoad.Args {
        const text_dir = if (self.cfg.text_model_dir) |d| try self.gpa.dupe(u8, d) else null;
        errdefer if (text_dir) |d| self.gpa.free(d);
        return .{
            .text_dir = text_dir,
            .visual_dir = if (self.cfg.visual_model_dir) |d| try self.gpa.dupe(u8, d) else null,
            .gpu_backend = self.cfg.embed_gpu_backend,
            .threshold = self.cfg.embed_gpu_threshold,
        };
    }

    fn freeLoadArgs(gpa: std.mem.Allocator, args: EmbedderLoad.Args) void {
        if (args.text_dir) |p| gpa.free(p);
        if (args.visual_dir) |p| gpa.free(p);
    }

    fn embedderLoadThread(self: *AppState, args: EmbedderLoad.Args) void {
        defer freeLoadArgs(self.gpa, args);
        self.emb_load.result = embedder_mod.Embedder.init(
            self.io, self.gpa, args.text_dir, args.visual_dir, args.gpu_backend, args.threshold,
        ) catch |err| blk: {
            log.warn("embedder init failed: {}", .{err});
            break :blk null;
        };
        self.emb_load.done.store(true, .release);
        self.hooks.wakeup();
    }

    fn spawnEmbedderLoad(self: *AppState, args: EmbedderLoad.Args) void {
        self.emb_load.done.store(false, .release);
        self.emb_load.result = null;
        self.emb_load.thread = std.Thread.spawn(.{}, embedderLoadThread, .{ self, args }) catch |err| {
            log.warn("embedder thread spawn failed: {}", .{err});
            freeLoadArgs(self.gpa, args);
            return;
        };
    }

    /// Load the embedder for the configured models in the background. If a
    /// load is already running, this one starts when it finishes.
    fn startEmbedderLoad(self: *AppState) void {
        if (self.cfg.text_model_dir == null and self.cfg.visual_model_dir == null) return;
        const args = self.loadArgs() catch |err| {
            log.warn("embedder not loaded: {}", .{err});
            return;
        };
        if (self.emb_load.thread != null) {
            if (self.emb_load.pending) |old| freeLoadArgs(self.gpa, old);
            self.emb_load.pending = args;
            return;
        }
        self.spawnEmbedderLoad(args);
    }

    /// Unhook and free the current embedder. Scans, watcher file workers and
    /// search query embeds hold a raw pointer to it, so they are stopped and
    /// awaited first (interrupted scans resume without an embedder; the
    /// backfill scan after the next load fills in what they skipped).
    fn releaseEmbedder(self: *AppState) void {
        self.search.embedder = null;
        self.search.awaitEmbed();
        if (self.library_manager) |*mgr| {
            mgr.embedder = null;
            mgr.quiesce(self.io);
        }
        if (self.embedder) |*emb| emb.deinit();
        self.embedder = null;
    }

    /// Swap in a finished embedder load and wire it to search and scans.
    fn pollEmbedderLoad(self: *AppState) void {
        if (!self.emb_load.done.load(.acquire)) return;
        self.emb_load.done.store(false, .release);
        if (self.emb_load.thread) |t| t.join();
        self.emb_load.thread = null;
        self.releaseEmbedder();
        self.embedder = self.emb_load.result;
        self.emb_load.result = null;
        const emb_ptr: ?*embedder_mod.Embedder = if (self.embedder) |*e| e else null;
        self.search.embedder = emb_ptr;
        if (self.library_manager) |*mgr| mgr.embedder = emb_ptr;
        // A reload asked for meanwhile starts now; its own completion runs
        // the backfill scan.
        if (self.emb_load.pending) |args| {
            self.emb_load.pending = null;
            self.spawnEmbedderLoad(args);
            return;
        }
        // Backfill embeddings skipped while the embedder was loading. Files
        // that already have them are fast-pathed by the scanner.
        if (emb_ptr == null) return;
        if (self.library_manager) |*mgr| {
            if (mgr.prompt_embeddings or mgr.image_embeddings) {
                mgr.scanAllLibraries() catch |err| log.warn("embedder-ready backfill scan failed: {}", .{err});
            }
        }
    }
};

/// Return free heap memory to the OS. A library scan allocates large transient
/// buffers (full-image decode + thumbnail generation) that glibc otherwise keeps
/// in its arenas; calling this once a scan finishes hands that slack back.
fn trimMemory() void {
    if (builtin.target.os.tag != .linux or builtin.abi.isMusl()) return;
    const glibc = struct {
        extern "c" fn malloc_trim(pad: usize) c_int;
    };
    _ = glibc.malloc_trim(0);
}

/// Logs how long each shutdown step takes (debug level), to find what holds
/// up a quit.
const ShutdownTimer = struct {
    io: std.Io,
    last: i96,

    fn start(io: std.Io) ShutdownTimer {
        return .{ .io = io, .last = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn lap(t: *ShutdownTimer, step: []const u8) void {
        const now = std.Io.Clock.awake.now(t.io).nanoseconds;
        log.debug("shutdown: {s} took {d} ms", .{ step, @divTrunc(now - t.last, std.time.ns_per_ms) });
        t.last = now;
    }
};
