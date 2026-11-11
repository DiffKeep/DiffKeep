const std = @import("std");
const db_mod = @import("db.zig");
const scan_mod = @import("scan.zig");
const notifier_mod = @import("notifier.zig");
const fs_watch_mod = @import("fs_watch.zig");
const embedder_mod = @import("embedder.zig");
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
};

/// At most this many file workers index watcher-reported files at once, so a
/// burst of thousands of new files can't spawn thousands of tasks (each with
/// its own DB connection).
pub const max_file_workers = 4;

const ScanRequest = struct {
    library_id: u64,
    library_path: []const u8, // owned; freed by drain worker
};

/// Owns library scanning lifecycle.  app.zig calls addLibrary/removeLibrary instead
/// of touching the DB directly; scans run as io concurrent tasks so frame() is never
/// blocked.
pub const LibraryManager = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.VectorDb,
    pending: std.ArrayList(ScanRequest),
    queue_mutex: std.Io.Mutex,
    scan_active: std.atomic.Value(bool),
    scan_group: std.Io.Group,
    stop_scan: std.atomic.Value(bool),
    files_scanned: std.atomic.Value(u32),
    thumbnails_in_db: bool,
    prompt_embeddings: bool,
    image_embeddings: bool,
    notifier: ?*notifier_mod.ImageNotifier,
    watcher: ?*fs_watch_mod.FsWatcher,
    /// Called from any thread after a single-file task completes, to wake the render loop.
    wakeup_fn: ?*const fn () void = null,
    /// Image ids removed by the watcher (file deleted on disk).  Drained by frame()
    /// to drop them from the grid and viewers incrementally — no full reload.
    removed_ids: std.ArrayList(u64) = .empty,
    removed_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Embedding progress counters — updated by the scan embed consumer.
    embed_done:  std.atomic.Value(u32) = .init(0),
    embed_total: std.atomic.Value(u32) = .init(0),
    /// Separate io group for the file workers and deletion/removal tasks.
    file_group: std.Io.Group,
    /// New or changed files for the file workers, oldest first. Guarded by
    /// `file_mutex`, as is `file_workers` (workers running).
    file_queue: std.ArrayList(FileRequest) = .empty,
    file_workers: u32 = 0,
    file_mutex: std.Io.Mutex = .init,
    embedder: ?*embedder_mod.Embedder = null,  // borrowed from dk.g_embedder, not owned
    /// The app's data dir (holds `trash/`); needed to delete a removed
    /// library's trashed files. Borrowed.
    data_dir: ?[]const u8 = null,
    /// Library being scanned by the drain worker right now (0 = none).
    active_library: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, prompt_embeddings: bool, image_embeddings: bool, notifier: ?*notifier_mod.ImageNotifier, watcher: ?*fs_watch_mod.FsWatcher) LibraryManager {
        return .{
            .allocator = allocator,
            .db = db,
            .pending = .empty,
            .queue_mutex = std.Io.Mutex.init,
            .scan_active = .init(false),
            .scan_group = .init,
            .stop_scan = .init(false),
            .files_scanned = .init(0),
            .thumbnails_in_db = thumbnails_in_db,
            .prompt_embeddings = prompt_embeddings,
            .image_embeddings = image_embeddings,
            .notifier = notifier,
            .watcher = watcher,
            .file_group = .init,
        };
    }

    /// Must be called before the io system shuts down (e.g. in appDeinit while
    /// dvui.App.main_init is still valid).
    pub fn deinit(self: *LibraryManager, io: std.Io) void {
        self.stop_scan.store(true, .release);
        self.scan_group.await(io) catch {};
        self.file_group.await(io) catch {};
        self.queue_mutex.lockUncancelable(io);
        for (self.pending.items) |req| self.allocator.free(req.library_path);
        self.pending.deinit(self.allocator);
        self.queue_mutex.unlock(io);
        for (self.file_queue.items) |req| self.allocator.free(req.path);
        self.file_queue.deinit(self.allocator);
        self.removed_ids.deinit(self.allocator);
    }

    /// Move all watcher-removed image ids into `out` (owned by `self.allocator`).
    /// Main-thread only; called once per frame.
    pub fn drainRemovedIds(self: *LibraryManager, io: std.Io, out: *std.ArrayList(u64)) void {
        self.removed_mutex.lockUncancelable(io);
        defer self.removed_mutex.unlock(io);
        if (self.removed_ids.items.len == 0) return;
        out.appendSlice(self.allocator, self.removed_ids.items) catch {};
        self.removed_ids.clearRetainingCapacity();
    }

    /// Queue ids of rows deleted in the background for `drainRemovedIds`, and
    /// wake the render loop to drain them.
    pub fn pushRemovedIds(self: *LibraryManager, io: std.Io, ids: []const u64) void {
        if (ids.len == 0) return;
        self.removed_mutex.lockUncancelable(io);
        self.removed_ids.appendSlice(self.allocator, ids) catch {};
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
                .rescan_library => self.rescanLibrary(io, ev.library_id, path),
                .file => if (ev.deleted) {
                    deletions.append(self.allocator, .{ .library_id = ev.library_id, .path = path }) catch
                        self.allocator.free(path);
                } else self.processFileEvent(io, ev.library_id, path),
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
        self.file_group.await(io) catch {};
        self.file_group = .init;
    }

    /// (Re)index one new or changed file in the background. `path` is
    /// heap-allocated and owned by this call. The file joins a queue drained by
    /// up to `max_file_workers` workers; a file already queued isn't queued
    /// again. Deletions go through `flushFileEvents`.
    pub fn processFileEvent(
        self: *LibraryManager,
        io: std.Io,
        library_id: u64,
        path: []const u8,
    ) void {
        self.file_mutex.lockUncancelable(io);
        defer self.file_mutex.unlock(io);
        for (self.file_queue.items) |req| {
            if (req.library_id == library_id and std.mem.eql(u8, req.path, path)) {
                self.allocator.free(path);
                return;
            }
        }
        self.file_queue.append(self.allocator, .{ .library_id = library_id, .path = path }) catch {
            self.allocator.free(path);
            return;
        };
        self.startFileWorkersLocked(io);
    }

    /// Start workers for the queued files, up to `max_file_workers`. Caller
    /// holds `file_mutex`.
    fn startFileWorkersLocked(self: *LibraryManager, io: std.Io) void {
        while (self.file_workers < max_file_workers and self.file_workers < self.file_queue.items.len) {
            self.file_group.concurrent(io, fileWorker, .{ self, io }) catch |err| {
                log.warn("spawn file worker: {}", .{err});
                return;
            };
            self.file_workers += 1;
        }
    }

    /// Queue a full scan of one library, to reconcile changes the watcher can
    /// only report in the aggregate (a directory moved into, out of, or within
    /// the tree).  `path` is heap-allocated and owned by this call.
    pub fn rescanLibrary(self: *LibraryManager, io: std.Io, library_id: u64, path: []const u8) void {
        defer self.allocator.free(path);
        log.info("rescanning library {} ({s})", .{ library_id, path });
        self.enqueue(io, library_id, path) catch |err|
            log.warn("queue rescan of {s}: {}", .{ std.Io.Dir.path.basename(path), err });
    }

    /// Force re-parse of a single image: resets its mtime in the DB (so the
    /// scanner treats it as changed) then dispatches a background file-event task.
    pub fn reparseImage(self: *LibraryManager, io: std.Io, id: u64, library_id: u64, path: []const u8) void {
        self.db.resetImageMtimeById(id) catch |err|
            log.warn("resetImageMtime {s}: {}", .{ std.Io.Dir.path.basename(path), err });
        const path_owned = self.allocator.dupe(u8, path) catch return;
        self.processFileEvent(io, library_id, path_owned);
    }

    pub const AddError = error{ LibraryExists, LibraryOverlaps };

    /// Persist to DB, queue a background scan, and register with the watcher.
    /// Returns the library's DB id. `path` is stored without a trailing
    /// separator (see `normalizeLibraryPath`). A path equal to, inside, or
    /// containing an existing library is refused: the same file would get two
    /// rows, which duplicate removal would then see as two copies.
    pub fn addLibrary(self: *LibraryManager, io: std.Io, path_in: []const u8) !u64 {
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
        try self.enqueue(io, id, path);
        if (self.watcher) |w| w.addLibrary(id, path) catch {};
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
    fn cancelLibraryScans(self: *LibraryManager, io: std.Io, lib_id: u64) void {
        if (self.active_library.load(.acquire) == lib_id) {
            self.quiesceDropping(io, lib_id);
            return;
        }
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);
        dropPending(self, lib_id);
    }

    /// Queue startup scans for every library already in the DB.
    pub fn scanAllLibraries(self: *LibraryManager, io: std.Io) !void {
        const libs = try self.db.listLibraries(self.allocator);
        defer {
            for (libs) |li| self.allocator.free(li.path);
            self.allocator.free(libs);
        }
        for (libs) |li| {
            try self.enqueue(io, li.id, li.path);
        }
    }

    pub fn isScanActive(self: *const LibraryManager) bool {
        return self.scan_active.load(.acquire);
    }

    pub fn filesScanned(self: *const LibraryManager) u32 {
        return self.files_scanned.load(.acquire);
    }

    pub fn embedsDone(self: *const LibraryManager) u32 {
        return self.embed_done.load(.acquire);
    }

    pub fn embedsTotal(self: *const LibraryManager) u32 {
        return self.embed_total.load(.acquire);
    }

    /// Stop every running scan and single-file task and wait for them, so
    /// nothing holds the embedder (or other borrowed state) when this returns.
    /// Main thread. Interrupted and queued scans start again afterwards; set
    /// `embedder` first if they must not use the old one.
    pub fn quiesce(self: *LibraryManager, io: std.Io) void {
        self.quiesceDropping(io, null);
    }

    /// `quiesce`, discarding the queued scans of library `drop` before resuming.
    fn quiesceDropping(self: *LibraryManager, io: std.Io, drop: ?u64) void {
        self.stop_scan.store(true, .release);
        self.scan_group.await(io) catch {};
        self.file_group.await(io) catch {};
        self.scan_group = .init;
        self.file_group = .init;
        self.stop_scan.store(false, .release);
        // File workers stop early when told to; pick their queue up again.
        self.file_mutex.lockUncancelable(io);
        if (drop) |id| {
            var i: usize = 0;
            while (i < self.file_queue.items.len) {
                if (self.file_queue.items[i].library_id == id) {
                    self.allocator.free(self.file_queue.orderedRemove(i).path);
                } else i += 1;
            }
        }
        self.startFileWorkersLocked(io);
        self.file_mutex.unlock(io);
        self.queue_mutex.lockUncancelable(io);
        if (drop) |id| dropPending(self, id);
        const resume_scans = self.pending.items.len > 0 and !self.scan_active.load(.acquire);
        if (resume_scans) self.scan_active.store(true, .release);
        self.queue_mutex.unlock(io);
        if (resume_scans) self.startDrain(io) catch |err| log.warn("resume scans: {}", .{err});
    }

    /// Whether a scan task may currently be running (and using the embedder).
    pub fn scanUsesEmbedder(self: *const LibraryManager) bool {
        return self.scan_active.load(.acquire) and self.embedder != null;
    }

    /// Queue a scan of `library_id`, unless one is already waiting.
    fn enqueue(self: *LibraryManager, io: std.Io, library_id: u64, path: []const u8) !void {
        self.queue_mutex.lockUncancelable(io);
        for (self.pending.items) |req| {
            if (req.library_id == library_id) {
                self.queue_mutex.unlock(io);
                return;
            }
        }
        const path_copy = self.allocator.dupe(u8, path) catch |err| {
            self.queue_mutex.unlock(io);
            return err;
        };
        self.pending.append(self.allocator, .{
            .library_id = library_id,
            .library_path = path_copy,
        }) catch |err| {
            self.queue_mutex.unlock(io);
            self.allocator.free(path_copy);
            return err;
        };
        const already_active = self.scan_active.load(.acquire);
        if (!already_active) self.scan_active.store(true, .release);
        self.queue_mutex.unlock(io);

        if (!already_active) try self.startDrain(io);
    }

    /// Start the drain worker; the caller has just set `scan_active`.
    fn startDrain(self: *LibraryManager, io: std.Io) !void {
        self.stop_scan.store(false, .release);
        self.files_scanned.store(0, .release);
        self.embed_done.store(0, .release);
        self.embed_total.store(0, .release);
        // Clean up the previous drain task (it has just set active=false and is
        // returning, so this await completes almost instantly).
        self.scan_group.await(io) catch {};
        self.scan_group = .init;
        self.scan_group.concurrent(io, drainQueue, .{ self, io }) catch |err| {
            self.scan_active.store(false, .release);
            return err;
        };
    }
};

/// Remove queued scan requests for `lib_id`. Caller holds queue_mutex.
fn dropPending(self: *LibraryManager, lib_id: u64) void {
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].library_id == lib_id) {
            const req = self.pending.orderedRemove(i);
            self.allocator.free(req.library_path);
        } else i += 1;
    }
}

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
    // One transaction: thousands of deletions (rm -r) commit once.
    const in_tx = if (conn.db.exec("BEGIN IMMEDIATE")) |_| true else |_| false;
    for (items) |d| {
        const id = conn.deleteImageByPath(d.library_id, d.path) catch |err| {
            log.warn("delete {s}: {}", .{ std.Io.Dir.path.basename(d.path), err });
            continue;
        } orelse continue;
        removed.append(manager.allocator, id) catch {};
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
fn fileWorker(manager: *LibraryManager, io: std.Io) void {
    var file_db = manager.db.getConnection() catch |err| {
        log.warn("file worker db connection: {}", .{err});
        manager.file_mutex.lockUncancelable(io);
        manager.file_workers -= 1;
        manager.file_mutex.unlock(io);
        return;
    };
    defer file_db.deinit();
    var scanner = scan_mod.LibraryScanner.init(manager.allocator, &file_db, manager.notifier);
    defer scanner.deinit();
    scanner.embedder = manager.embedder;
    while (true) {
        manager.file_mutex.lockUncancelable(io);
        if (manager.stop_scan.load(.acquire) or manager.file_queue.items.len == 0) {
            manager.file_workers -= 1;
            manager.file_mutex.unlock(io);
            return;
        }
        const req = manager.file_queue.orderedRemove(0);
        manager.file_mutex.unlock(io);
        defer manager.allocator.free(req.path);
        scanner.processSingleFile(
            io,
            req.library_id,
            req.path,
            &manager.stop_scan,
            manager.thumbnails_in_db,
            manager.prompt_embeddings,
            manager.image_embeddings,
        );
        // Wake the render loop so grid.update() drains the notifier and shows the new image.
        if (manager.wakeup_fn) |wake| wake();
    }
}

fn drainQueue(manager: *LibraryManager, io: std.Io) void {
    while (true) {
        manager.queue_mutex.lockUncancelable(io);
        // Once stopped (quit), start no further libraries; deinit frees the rest.
        const stopped = manager.stop_scan.load(.acquire);
        const maybe_req: ?ScanRequest = if (!stopped and manager.pending.items.len > 0)
            manager.pending.orderedRemove(0)
        else blk: {
            // Set inactive while still holding the lock so a concurrent enqueue()
            // cannot miss the transition and skip starting a new drain worker.
            manager.scan_active.store(false, .release);
            break :blk null;
        };
        manager.queue_mutex.unlock(io);

        const req = maybe_req orelse break;
        // A scan cut short by `quiesce` goes back to the front of the queue to
        // run again; at shutdown, deinit frees whatever is still queued.
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
        scanner.embedder = manager.embedder;
        var removed: std.ArrayList(u64) = .empty;
        defer removed.deinit(scanner.allocator);
        scanner.removed_ids = &removed;
        defer manager.pushRemovedIds(io, removed.items);
        manager.active_library.store(req.library_id, .release);
        defer manager.active_library.store(0, .release);
        _ = scanner.scanLibrary(io, req.library_id, req.library_path, &manager.stop_scan, &manager.files_scanned, &manager.embed_done, &manager.embed_total, manager.thumbnails_in_db, manager.prompt_embeddings, manager.image_embeddings) catch |err| {
            log.err("scan {s}: {}", .{ std.Io.Dir.path.basename(req.library_path), err });
        };
        if (manager.stop_scan.load(.acquire)) {
            manager.queue_mutex.lockUncancelable(io);
            defer manager.queue_mutex.unlock(io);
            const dup = for (manager.pending.items) |p| {
                if (p.library_id == req.library_id) break true;
            } else false;
            if (!dup) {
                manager.pending.insert(manager.allocator, 0, req) catch {};
                requeue = true;
            }
        }
    }
}
