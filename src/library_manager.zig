const std = @import("std");
const db_mod = @import("db.zig");
const scan_mod = @import("scan.zig");
const notifier_mod = @import("notifier.zig");
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

    pub fn init(allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, prompt_embeddings: bool, image_embeddings: bool, notifier: ?*notifier_mod.ImageNotifier) LibraryManager {
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
        };
    }

    /// Must be called before the io system shuts down (e.g. in appDeinit while
    /// dvui.App.main_init is still valid).
    pub fn deinit(self: *LibraryManager, io: std.Io) void {
        self.stop_scan.store(true, .release);
        self.scan_group.await(io) catch {};
        self.queue_mutex.lockUncancelable(io);
        for (self.pending.items) |req| self.allocator.free(req.library_path);
        self.pending.deinit(self.allocator);
        self.queue_mutex.unlock(io);
    }

    /// Persist to DB and queue a background scan.  Returns the library's DB id.
    pub fn addLibrary(self: *LibraryManager, io: std.Io, path: []const u8) !u64 {
        const id = try self.db.storeLibrary(path);
        try self.enqueue(io, id, path);
        return id;
    }

    /// Remove from DB (cascades to images).
    pub fn removeLibrary(self: *LibraryManager, path: []const u8) !void {
        try self.db.removeLibrary(path);
    }

    /// Queue startup scans for every library already in the DB.
    pub fn scanAllLibraries(self: *LibraryManager, io: std.Io) !void {
        const paths = try self.db.listLibraries(self.allocator);
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        for (paths) |path| {
            const id = try self.db.storeLibrary(path); // find-or-create, returns id
            try self.enqueue(io, id, path);
        }
    }

    pub fn isScanActive(self: *const LibraryManager) bool {
        return self.scan_active.load(.acquire);
    }

    pub fn filesScanned(self: *const LibraryManager) u32 {
        return self.files_scanned.load(.acquire);
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

        var scanner = scan_mod.LibraryScanner.init(manager.allocator, manager.db, manager.notifier);
        defer scanner.deinit();
        _ = scanner.scanLibrary(io, req.library_id, req.library_path, &manager.stop_scan, &manager.files_scanned, manager.thumbnails_in_db, manager.prompt_embeddings, manager.image_embeddings) catch |err| {
            log.err("scan {s}: {}", .{ std.fs.path.basename(req.library_path), err });
        };
    }
}
