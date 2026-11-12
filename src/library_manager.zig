const std = @import("std");
const db_mod = @import("db.zig");
const scan_mod = @import("scan.zig");
const notifier_mod = @import("notifier.zig");
const fs_watch_mod = @import("fs_watch.zig");
const bg = @import("bg.zig");
const embedder_mod = @import("embedder.zig");
const activity = @import("activity.zig");
const embed_worker = @import("embed_worker.zig");
const log = std.log.scoped(.library_manager);

/// `path` without trailing separators (a bare root stays as is), so library
/// paths join with "/" + name the same way the scanner builds file paths.
pub fn normalizeLibraryPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

/// Whether `inner` lies strictly inside directory `outer` (both normalized).
pub fn pathContains(outer: []const u8, inner: []const u8) bool {
    if (inner.len <= outer.len or !std.mem.startsWith(u8, inner, outer)) return false;
    const last = outer[outer.len - 1];
    if (last == '/' or last == '\\') return true; // outer is a root
    return inner[outer.len] == '/' or inner[outer.len] == '\\';
}

/// Watcher events waiting out the debounce, merged per (kind, path): a burst
/// of N events for the same files costs O(N), and only each path's latest
/// state is processed. Owns the event paths.
pub const PendingFileEvents = struct {
    events: std.ArrayList(fs_watch_mod.DirtyEvent) = .empty,
    files: std.StringHashMapUnmanaged(usize) = .empty,
    rescans: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *PendingFileEvents, a: std.mem.Allocator) void {
        self.clear(a);
        self.events.deinit(a);
        self.files.deinit(a);
        self.rescans.deinit(a);
    }

    /// Take ownership of `ev` (its path is freed on error or when merged).
    pub fn add(self: *PendingFileEvents, a: std.mem.Allocator, ev: fs_watch_mod.DirtyEvent) !void {
        errdefer a.free(ev.path);
        const index = if (ev.kind == .file) &self.files else &self.rescans;
        const gop = try index.getOrPut(a, ev.path);
        if (gop.found_existing) {
            self.events.items[gop.value_ptr.*].deleted = ev.deleted;
            a.free(ev.path);
            return;
        }
        errdefer _ = index.remove(ev.path);
        gop.value_ptr.* = self.events.items.len;
        try self.events.append(a, ev);
    }

    fn clear(self: *PendingFileEvents, a: std.mem.Allocator) void {
        for (self.events.items) |ev| a.free(ev.path);
        self.events.clearRetainingCapacity();
        self.files.clearRetainingCapacity();
        self.rescans.clearRetainingCapacity();
    }
};

/// A new or changed file waiting for a file worker.
const FileRequest = struct {
    library_id: u64,
    path: []const u8, // owned
    /// Re-parse: reset this image's stored mtime first, so the file counts as
    /// changed even though it isn't.
    reset_id: ?u64 = null,

    fn eql(a: FileRequest, b: FileRequest) bool {
        return a.library_id == b.library_id and a.reset_id == b.reset_id and std.mem.eql(u8, a.path, b.path);
    }

    fn free(a: std.mem.Allocator, r: FileRequest) void {
        a.free(r.path);
    }

    fn inLibrary(library_id: u64, r: FileRequest) bool {
        return r.library_id == library_id;
    }
};

/// At most this many file workers index watcher-reported files at once, so a
/// burst of thousands of new files can't spawn thousands of tasks (each with
/// its own DB connection).
pub const max_file_workers = 4;

const ScanRequest = struct {
    library_id: u64,
    library_path: []const u8, // owned

    fn eql(a: ScanRequest, b: ScanRequest) bool {
        return a.library_id == b.library_id;
    }

    fn free(a: std.mem.Allocator, r: ScanRequest) void {
        a.free(r.library_path);
    }

    fn inLibrary(library_id: u64, r: ScanRequest) bool {
        return r.library_id == library_id;
    }
};

/// Owns library scanning lifecycle.  app.zig calls addLibrary/removeLibrary instead
/// of touching the DB directly; scans run as io concurrent tasks so frame() is never
/// blocked.
pub const LibraryManager = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.VectorDb,
    /// Library scans, one at a time (`scanWorker`); a library is queued at
    /// most once.
    scans: bg.WorkQueue(ScanRequest),
    stop_scan: std.atomic.Value(bool),
    /// Files the current run of scans has looked at, for the status bar.
    files_scanned: std.atomic.Value(u32) = .init(0),
    thumbnails_in_db: bool,
    /// Computes the embeddings indexed rows are missing; scans and file
    /// workers tell it about each row they save.
    embeds: embed_worker.EmbedWorker,
    notifier: ?*notifier_mod.ImageNotifier,
    watcher: ?*fs_watch_mod.FsWatcher,
    /// Called from any thread after a single-file task completes, to wake the render loop.
    wakeup_fn: ?*const fn () void = null,
    /// Image ids removed by the watcher (file deleted on disk).  Drained by frame()
    /// to drop them from the grid and viewers incrementally — no full reload.
    removed_ids: std.ArrayList(u64) = .empty,
    /// Removed ids that couldn't be queued (out of memory): views reload from
    /// the DB instead. Guarded by `removed_mutex`.
    removed_lost: bool = false,
    removed_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Separate io group for the file workers and deletion/removal tasks.
    file_group: std.Io.Group,
    /// New or changed files reported by the watcher, indexed by up to
    /// `max_file_workers` workers (`fileWorker`).
    file_queue: bg.WorkQueue(FileRequest),
    /// The app's data dir (holds `trash/`); needed to delete a removed
    /// library's trashed files. Borrowed.
    data_dir: ?[]const u8 = null,
    /// Library being scanned by the drain worker right now (0 = none).
    active_library: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb, thumbnails_in_db: bool, prompt_embeddings: bool, image_embeddings: bool, notifier: ?*notifier_mod.ImageNotifier, watcher: ?*fs_watch_mod.FsWatcher) LibraryManager {
        return .{
            .allocator = allocator,
            .db = db,
            .scans = .init(allocator, io, 1, scanWorker, ScanRequest.free),
            .stop_scan = .init(false),
            .thumbnails_in_db = thumbnails_in_db,
            .embeds = .init(allocator, io, db, .{ .prompt = prompt_embeddings, .image = image_embeddings }),
            .notifier = notifier,
            .watcher = watcher,
            .file_group = .init,
            .file_queue = .init(allocator, io, max_file_workers, fileWorker, FileRequest.free),
        };
    }

    /// Must be called before the io system shuts down (e.g. in appDeinit while
    /// dvui.App.main_init is still valid).
    pub fn deinit(self: *LibraryManager, io: std.Io) void {
        self.stop_scan.store(true, .release);
        self.scans.deinit();
        self.file_group.await(io) catch {};
        self.file_queue.deinit();
        // After everything that tells it about rows.
        self.embeds.deinit();
        self.removed_ids.deinit(self.allocator);
    }

    /// Move all watcher-removed image ids into `out` (owned by `self.allocator`).
    /// Returns true when some removals couldn't be recorded, so the views must
    /// reload from the DB. Main-thread only; called once per frame.
    pub fn drainRemovedIds(self: *LibraryManager, io: std.Io, out: *std.ArrayList(u64)) bool {
        self.removed_mutex.lockUncancelable(io);
        defer self.removed_mutex.unlock(io);
        const lost = self.removed_lost;
        self.removed_lost = false;
        if (self.removed_ids.items.len == 0) return lost;
        // On failure the ids stay queued for the next frame.
        out.appendSlice(self.allocator, self.removed_ids.items) catch |err| {
            log.warn("drain removed ids: {}", .{err});
            return lost;
        };
        self.removed_ids.clearRetainingCapacity();
        return lost;
    }

    /// Queue ids of rows deleted in the background for `drainRemovedIds`, and
    /// wake the render loop to drain them.
    pub fn pushRemovedIds(self: *LibraryManager, io: std.Io, ids: []const u64) void {
        if (ids.len == 0) return;
        self.removed_mutex.lockUncancelable(io);
        self.removed_ids.appendSlice(self.allocator, ids) catch |err| {
            log.warn("queue removed ids: {}", .{err});
            self.removed_lost = true;
        };
        self.removed_mutex.unlock(io);
        if (self.wakeup_fn) |wake| wake();
    }

    /// Process (and empty) a debounced batch of watcher events. Deletions go to
    /// one background task that removes their rows in a single transaction;
    /// they used to run one by one on the render thread.
    pub fn flushFileEvents(self: *LibraryManager, io: std.Io, batch: *PendingFileEvents) void {
        var deletions: std.ArrayList(DeletedFile) = .empty;
        for (batch.events.items) |*ev| {
            const path = ev.path;
            ev.path = &.{}; // ownership moves on
            switch (ev.kind) {
                .rescan_library => self.rescanLibrary(ev.library_id, path),
                .file => if (ev.deleted) {
                    deletions.append(self.allocator, .{ .library_id = ev.library_id, .path = path }) catch
                        self.allocator.free(path);
                } else self.processFileEvent(ev.library_id, path),
            }
        }
        batch.clear(self.allocator);
        if (deletions.items.len == 0) return deletions.deinit(self.allocator);
        const owned = deletions.toOwnedSlice(self.allocator) catch {
            for (deletions.items) |d| self.allocator.free(d.path);
            return deletions.deinit(self.allocator);
        };
        self.file_group.concurrent(io, removeFilesTask, .{ self, io, owned }) catch |err| {
            log.warn("spawn delete task: {}", .{err});
            freeDeletions(self.allocator, owned);
        };
    }

    /// Wait for background single-file and deletion tasks (tests, shutdown).
    pub fn awaitFileTasks(self: *LibraryManager, io: std.Io) void {
        self.file_queue.awaitIdle();
        self.file_group.await(io) catch {};
        self.file_group = .init;
    }

    /// (Re)index one new or changed file in the background. `path` is
    /// heap-allocated and owned by this call. The file joins a queue drained by
    /// up to `max_file_workers` workers; a file already queued isn't queued
    /// again. Deletions go through `flushFileEvents`.
    pub fn processFileEvent(
        self: *LibraryManager,
        library_id: u64,
        path: []const u8,
    ) void {
        const req: FileRequest = .{ .library_id = library_id, .path = path };
        _ = self.file_queue.pushUnique(req, FileRequest.eql) catch self.allocator.free(path);
    }

    /// Queue a full scan of one library, to reconcile changes the watcher can
    /// only report in the aggregate (a directory moved into, out of, or within
    /// the tree).  `path` is heap-allocated and owned by this call.
    pub fn rescanLibrary(self: *LibraryManager, library_id: u64, path: []const u8) void {
        defer self.allocator.free(path);
        log.info("rescanning library {} ({s})", .{ library_id, path });
        self.enqueue(library_id, path) catch |err|
            log.warn("queue rescan of {s}: {}", .{ std.Io.Dir.path.basename(path), err });
    }

    /// Force re-parse of a single image: a file worker resets its stored
    /// mtime (so the scanner treats it as changed) and then indexes it.
    pub fn reparseImage(self: *LibraryManager, id: u64, library_id: u64, path: []const u8) void {
        const path_owned = self.allocator.dupe(u8, path) catch |err| return log.warn("reparse: {}", .{err});
        const req: FileRequest = .{ .library_id = library_id, .path = path_owned, .reset_id = id };
        _ = self.file_queue.pushUnique(req, FileRequest.eql) catch |err| {
            self.allocator.free(path_owned);
            log.warn("reparse: {}", .{err});
        };
    }

    pub const AddError = error{ LibraryExists, LibraryOverlaps };

    /// Persist to DB, queue a background scan, and register with the watcher.
    /// Returns the library's DB id. `path` is stored without a trailing
    /// separator (see `normalizeLibraryPath`). A path equal to, inside, or
    /// containing an existing library is refused: the same file would get two
    /// rows, which duplicate removal would then see as two copies.
    pub fn addLibrary(self: *LibraryManager, path_in: []const u8) !u64 {
        const path = normalizeLibraryPath(path_in);
        const existing = try self.db.listLibraries(self.allocator);
        defer {
            for (existing) |li| self.allocator.free(li.path);
            self.allocator.free(existing);
        }
        for (existing) |li| {
            if (std.mem.eql(u8, li.path, path)) return error.LibraryExists;
            if (pathContains(li.path, path) or pathContains(path, li.path)) return error.LibraryOverlaps;
        }
        const id = try self.db.storeLibrary(path);
        try self.enqueue(id, path);
        if (self.watcher) |w| w.addLibrary(id, path) catch |err|
            log.warn("watch library {s}: {} (changes show up on the next scan)", .{ path, err });
        return id;
    }

    /// Forget a library: stop watching and scanning it, then (in the
    /// background) delete its rows and its trashed files, and report its image
    /// ids through `drainRemovedIds` so the grid and viewers drop them.
    pub fn removeLibrary(self: *LibraryManager, io: std.Io, path: []const u8) !void {
        const lib_id = (try self.db.getLibraryIdByPath(path)) orelse return;
        if (self.watcher) |w| w.removeLibrary(lib_id);
        self.cancelLibraryScans(io, lib_id);
        self.file_group.concurrent(io, removeLibraryTask, .{ self, io, lib_id }) catch |err| {
            log.warn("spawn remove-library task: {}", .{err});
            return err;
        };
    }

    /// Library the drain worker is scanning right now, or 0.
    pub fn activeLibrary(self: *const LibraryManager) u64 {
        return self.active_library.load(.acquire);
    }

    /// Drop queued scans of `lib_id`, and stop (and wait for) the running one.
    /// A worker takes a request off the queue before it records which library
    /// it is scanning, so "is `lib_id` active?" can't be answered reliably:
    /// any running scan is stopped, `lib_id`'s requests (including the one it
    /// puts back) dropped, and the rest resumed.
    fn cancelLibraryScans(self: *LibraryManager, io: std.Io, lib_id: u64) void {
        if (self.scans.busy()) return self.quiesceDropping(io, lib_id);
        self.file_queue.removeIf(lib_id, FileRequest.inLibrary);
    }

    /// Queue startup scans for every library already in the DB.
    pub fn scanAllLibraries(self: *LibraryManager) !void {
        const libs = try self.db.listLibraries(self.allocator);
        defer {
            for (libs) |li| self.allocator.free(li.path);
            self.allocator.free(libs);
        }
        for (libs) |li| {
            try self.enqueue(li.id, li.path);
        }
    }

    /// Whether a library scan is queued or running.
    pub fn isScanActive(self: *LibraryManager) bool {
        return self.scans.busy();
    }

    /// What the scans are doing, for the status bar.
    pub fn scanActivity(self: *LibraryManager) activity.Scan {
        return .{
            .active = self.isScanActive(),
            .files_scanned = self.files_scanned.load(.acquire),
        };
    }

    /// What the embed worker is doing, for the status bar.
    pub fn embedActivity(self: *LibraryManager) activity.Embed {
        const p = self.embeds.progress();
        return .{ .active = p.active, .done = p.done, .total = p.total };
    }

    /// Hand the embed worker a new embedder (null: none). When this returns
    /// nothing uses the old one, so it can be freed. Main thread.
    pub fn setEmbedder(self: *LibraryManager, embedder: ?*embedder_mod.Embedder) void {
        self.embeds.configure(embedder, self.embeds.kinds);
    }

    /// Which embeddings to compute (config switches). Main thread.
    pub fn setEmbedKinds(self: *LibraryManager, prompt: bool, image: bool) void {
        self.embeds.configure(self.embeds.embedder, .{ .prompt = prompt, .image = image });
    }

    /// Stop every running scan and single-file task and wait for them. Main
    /// thread. Interrupted and queued scans start again afterwards.
    pub fn quiesce(self: *LibraryManager, io: std.Io) void {
        self.quiesceDropping(io, null);
    }

    /// `quiesce`, discarding the queued scans of library `drop` before resuming.
    fn quiesceDropping(self: *LibraryManager, io: std.Io, drop: ?u64) void {
        self.stop_scan.store(true, .release);
        self.scans.pause();
        self.file_queue.pause();
        self.scans.awaitIdle();
        self.file_queue.awaitIdle();
        self.file_group.await(io) catch {};
        self.file_group = .init;
        self.stop_scan.store(false, .release);
        if (drop) |id| {
            self.scans.removeIf(id, ScanRequest.inLibrary);
            self.file_queue.removeIf(id, FileRequest.inLibrary);
        }
        // An interrupted scan put itself back at the front; it runs again.
        self.scans.unpause();
        self.file_queue.unpause();
    }

    /// Queue a scan of `library_id`, unless one is already waiting.
    fn enqueue(self: *LibraryManager, library_id: u64, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        const req: ScanRequest = .{ .library_id = library_id, .library_path = path_copy };
        _ = self.scans.pushUnique(req, ScanRequest.eql) catch |err| {
            self.allocator.free(path_copy);
            return err;
        };
    }
};

fn removeLibraryTask(manager: *LibraryManager, io: std.Io, lib_id: u64) void {
    var conn = manager.db.getConnection() catch |err| {
        log.warn("remove library db connection: {}", .{err});
        return;
    };
    defer conn.deinit();
    const removed = conn.removeLibraryById(manager.allocator, lib_id) catch |err| {
        log.warn("remove library {d}: {}", .{ lib_id, err });
        return;
    };
    defer removed.deinit(manager.allocator);
    // Its trashed files are no longer reachable from any row: delete them.
    if (manager.data_dir) |data_dir| {
        for (removed.trash_names) |name| {
            const p = std.Io.Dir.path.join(manager.allocator, &.{ data_dir, "trash", name }) catch continue;
            defer manager.allocator.free(p);
            std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("delete trashed {s}: {}", .{ name, err }),
            };
        }
    }
    manager.pushRemovedIds(io, removed.ids);
}

const DeletedFile = struct { library_id: u64, path: []const u8 };

fn freeDeletions(a: std.mem.Allocator, items: []DeletedFile) void {
    for (items) |d| a.free(d.path);
    a.free(items);
}

fn removeFilesTask(manager: *LibraryManager, io: std.Io, items: []DeletedFile) void {
    defer freeDeletions(manager.allocator, items);
    var conn = manager.db.getConnection() catch |err| {
        log.warn("delete task db connection: {}", .{err});
        return;
    };
    defer conn.deinit();
    var removed: std.ArrayList(u64) = .empty;
    defer removed.deinit(manager.allocator);
    // Every deleted row must be reported, or it stays in the grid: make the
    // room before deleting any. Without it the events stay unprocessed until
    // the next scan.
    removed.ensureTotalCapacity(manager.allocator, items.len) catch |err| {
        log.warn("delete task: {}", .{err});
        return;
    };
    // One transaction: thousands of deletions (rm -r) commit once.
    const in_tx = if (conn.db.exec("BEGIN IMMEDIATE")) |_| true else |_| false;
    for (items) |d| {
        const id = conn.deleteImageByPath(d.library_id, d.path) catch |err| {
            log.warn("delete {s}: {}", .{ std.Io.Dir.path.basename(d.path), err });
            continue;
        } orelse continue;
        removed.appendAssumeCapacity(id);
    }
    if (in_tx) conn.db.exec("COMMIT") catch |err| {
        log.warn("delete commit: {}", .{err});
        conn.db.exec("ROLLBACK") catch {};
        return;
    };
    manager.pushRemovedIds(io, removed.items);
}

/// Index queued files one at a time on one connection until the queue is
/// empty or the manager is told to stop (shutdown, `quiesce`); a stopped
/// worker leaves the rest queued.
fn fileWorker(q: *bg.WorkQueue(FileRequest)) void {
    const manager: *LibraryManager = @fieldParentPtr("file_queue", q);
    const io = q.io;
    var file_db = manager.db.getConnection() catch |err| {
        log.warn("file worker db connection: {}", .{err});
        while (q.next()) |req| FileRequest.free(manager.allocator, req);
        return;
    };
    defer file_db.deinit();
    var scanner = scan_mod.LibraryScanner.init(manager.allocator, &file_db, manager.notifier);
    defer scanner.deinit();
    scanner.embeds = &manager.embeds;
    while (q.next()) |req| {
        defer manager.allocator.free(req.path);
        if (req.reset_id) |id| file_db.resetImageMtimeById(id) catch |err|
            log.warn("resetImageMtime {s}: {}", .{ std.Io.Dir.path.basename(req.path), err });
        scanner.processSingleFile(
            io,
            req.library_id,
            req.path,
            &manager.stop_scan,
            manager.thumbnails_in_db,
        );
        // Wake the render loop so grid.update() drains the notifier and shows the new image.
        if (manager.wakeup_fn) |wake| wake();
    }
}

/// Run the queued library scans one after another. A scan stopped by
/// `quiesce` puts itself back at the front of the queue to run again; at
/// shutdown the queue frees whatever is left.
fn scanWorker(q: *bg.WorkQueue(ScanRequest)) void {
    const manager: *LibraryManager = @fieldParentPtr("scans", q);
    const io = q.io;
    // Progress counts from the start of this run of scans.
    manager.files_scanned.store(0, .release);
    while (q.next()) |req| {
        var requeue = false;
        defer if (!requeue) manager.allocator.free(req.library_path);

        // Use a dedicated DB connection for the scan so its long-running queries
        // (prefetch, per-file inserts) don't share a mutex with the main thread.
        var scan_db = manager.db.getConnection() catch |err| {
            log.err("scan db connection: {}", .{err});
            continue;
        };
        defer scan_db.deinit();
        var scanner = scan_mod.LibraryScanner.init(manager.allocator, &scan_db, manager.notifier);
        defer scanner.deinit();
        scanner.embeds = &manager.embeds;
        var removed: std.ArrayList(u64) = .empty;
        defer removed.deinit(scanner.allocator);
        scanner.removed_ids = &removed;
        defer manager.pushRemovedIds(io, removed.items);
        manager.active_library.store(req.library_id, .release);
        defer manager.active_library.store(0, .release);
        _ = scanner.scanLibrary(io, req.library_id, req.library_path, &manager.stop_scan, &manager.files_scanned, manager.thumbnails_in_db) catch |err| {
            log.err("scan {s}: {}", .{ std.Io.Dir.path.basename(req.library_path), err });
        };
        if (manager.stop_scan.load(.acquire)) {
            q.requeueFront(req, ScanRequest.eql);
            requeue = true;
        }
    }
}
