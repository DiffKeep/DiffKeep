const std = @import("std");
const db_mod = @import("db.zig");
const scan_mod = @import("scan.zig");
const notifier_mod = @import("notifier.zig");
const fs_watch_mod = @import("fs_watch.zig");
const onnx_mod = @import("onnx_embedder.zig");
const log = std.log.scoped(.library_manager);

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
    /// Set to true when a file is deleted so frame() can call grid.reloadImages().
    reload_requested: std.atomic.Value(bool) = .init(false),
    /// Embedding progress counters — updated by the scan embed consumer.
    embed_done:  std.atomic.Value(u32) = .init(0),
    embed_total: std.atomic.Value(u32) = .init(0),
    /// Separate io group for single-file processing tasks spawned by the watcher.
    file_group: std.Io.Group,
    embedder: ?*onnx_mod.OnnxEmbedder = null,  // borrowed from dk.g_embedder, not owned

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
    }

    /// Process one file reported by the fs watcher.  `path` is heap-allocated
    /// and owned by this call (freed when the background task completes).
    /// Pass `deleted = true` to remove the file from the DB instead.
    pub fn processFileEvent(
        self: *LibraryManager,
        io: std.Io,
        library_id: u64,
        path: []const u8,
        deleted: bool,
    ) void {
        if (deleted) {
            self.db.deleteImageByPath(library_id, path) catch |err|
                log.warn("delete {s}: {}", .{ std.fs.path.basename(path), err });
            self.allocator.free(path);
            self.reload_requested.store(true, .release);
            if (self.wakeup_fn) |wake| wake();
            return;
        }
        const ctx = FileEventCtx{
            .manager = self,
            .io = io,
            .library_id = library_id,
            .path = path,
        };
        self.file_group.concurrent(io, processFileEventTask, .{ctx}) catch |err| {
            log.warn("spawn file event task: {}", .{err});
            self.allocator.free(path);
        };
    }

    /// Force re-parse of a single image: resets its mtime in the DB (so the
    /// scanner treats it as changed) then dispatches a background file-event task.
    pub fn reparseImage(self: *LibraryManager, io: std.Io, id: u64, library_id: u64, path: []const u8) void {
        self.db.resetImageMtimeById(id) catch |err|
            log.warn("resetImageMtime {s}: {}", .{ std.fs.path.basename(path), err });
        const path_owned = self.allocator.dupe(u8, path) catch return;
        self.processFileEvent(io, library_id, path_owned, false);
    }

    /// Persist to DB, queue a background scan, and register with the watcher.
    /// Returns the library's DB id.
    pub fn addLibrary(self: *LibraryManager, io: std.Io, path: []const u8) !u64 {
        const id = try self.db.storeLibrary(path);
        try self.enqueue(io, id, path);
        if (self.watcher) |w| w.addLibrary(id, path) catch {};
        return id;
    }

    /// Remove from DB (cascades to images) and unregister from the watcher.
    pub fn removeLibrary(self: *LibraryManager, path: []const u8) !void {
        if (self.watcher) |w| {
            if (self.db.getLibraryIdByPath(path) catch null) |lib_id|
                w.removeLibrary(lib_id);
        }
        try self.db.removeLibrary(path);
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

    fn enqueue(self: *LibraryManager, io: std.Io, library_id: u64, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        self.queue_mutex.lockUncancelable(io);
        self.pending.append(self.allocator, .{
            .library_id = library_id,
            .library_path = path_copy,
        }) catch |err| {
            self.queue_mutex.unlock(io);
            return err;
        };
        const already_active = self.scan_active.load(.acquire);
        if (!already_active) self.scan_active.store(true, .release);
        self.queue_mutex.unlock(io);

        if (!already_active) {
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
    }
};

const FileEventCtx = struct {
    manager: *LibraryManager,
    io: std.Io,
    library_id: u64,
    path: []const u8, // owned; freed here
};

fn processFileEventTask(ctx: FileEventCtx) void {
    defer ctx.manager.allocator.free(ctx.path);
    var file_db = ctx.manager.db.getConnection() catch |err| {
        log.warn("file event db connection: {}", .{err});
        return;
    };
    defer file_db.deinit();
    var scanner = scan_mod.LibraryScanner.init(ctx.manager.allocator, &file_db, ctx.manager.notifier);
    defer scanner.deinit();
    scanner.embedder = ctx.manager.embedder;
    scanner.processSingleFile(
        ctx.io,
        ctx.library_id,
        ctx.path,
        &ctx.manager.stop_scan,
        ctx.manager.thumbnails_in_db,
        ctx.manager.prompt_embeddings,
        ctx.manager.image_embeddings,
    );
    // Wake the render loop so grid.update() drains the notifier and shows the new image.
    if (ctx.manager.wakeup_fn) |wake| wake();
}

fn drainQueue(manager: *LibraryManager, io: std.Io) void {
    while (true) {
        manager.queue_mutex.lockUncancelable(io);
        const maybe_req: ?ScanRequest = if (manager.pending.items.len > 0)
            manager.pending.orderedRemove(0)
        else blk: {
            // Set inactive while still holding the lock so a concurrent enqueue()
            // cannot miss the transition and skip starting a new drain worker.
            manager.scan_active.store(false, .release);
            break :blk null;
        };
        manager.queue_mutex.unlock(io);

        const req = maybe_req orelse break;
        defer manager.allocator.free(req.library_path);

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
        _ = scanner.scanLibrary(io, req.library_id, req.library_path, &manager.stop_scan, &manager.files_scanned, &manager.embed_done, &manager.embed_total, manager.thumbnails_in_db, manager.prompt_embeddings, manager.image_embeddings) catch |err| {
            log.err("scan {s}: {}", .{ std.fs.path.basename(req.library_path), err });
        };
    }
}
