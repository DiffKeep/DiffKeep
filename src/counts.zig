//! Library-wide counts shown in the sidebar and toolbar (total, trash,
//! duplicates, favorites, per library), loaded off the render thread.
//!
//! Some of these are full-table aggregates (the duplicate count groups every
//! hash), and they are wanted after every favorite toggle, file operation and
//! scanned image, so they must not run in `frame()`. `request` asks for fresh
//! counts; requests made while a load runs coalesce into one more load.
//! `poll` hands the latest result to the main thread.

const std = @import("std");
const db_mod = @import("db.zig");

const log = std.log.scoped(.counts);

pub const LibraryCount = struct { id: u64, count: i64 };

pub const Counts = struct {
    total: i64 = 0,
    trash: ?db_mod.TrashStats = null,
    duplicates: i64 = 0,
    favorites: i64 = 0,
    /// Owned (by the loader's allocator); free with `deinit`.
    libraries: []LibraryCount = &.{},

    pub fn deinit(self: *Counts, a: std.mem.Allocator) void {
        a.free(self.libraries);
        self.libraries = &.{};
    }
};

/// Compute every count on `db`. Does DB IO: call it off the main thread.
pub fn load(db: *db_mod.VectorDb, a: std.mem.Allocator) !Counts {
    var c: Counts = .{
        .total = try db.getTotalImageCount(),
        .trash = try db.getTrashStats(),
        .duplicates = try db.getDuplicateCount(),
        .favorites = try db.getFavoriteCount(),
    };
    const libs = try db.listLibraries(a);
    defer {
        for (libs) |li| a.free(li.path);
        a.free(libs);
    }
    const out = try a.alloc(LibraryCount, libs.len);
    errdefer a.free(out);
    for (libs, out) |li, *o| o.* = .{ .id = li.id, .count = try db.getLibraryImageCount(li.id) };
    c.libraries = out;
    return c;
}

pub const CountsLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Pool owner; the load task takes its own connection from it.
    db: *db_mod.VectorDb,
    wakeup_fn: ?*const fn () void = null,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    // Guarded by `mutex`.
    running: bool = false,
    again: bool = false,
    result: ?Counts = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb) CountsLoader {
        return .{ .allocator = allocator, .io = io, .db = db };
    }

    /// Wait for a running load; free an unclaimed result.
    pub fn deinit(self: *CountsLoader) void {
        self.group.await(self.io) catch {};
        if (self.result) |*r| r.deinit(self.allocator);
        self.result = null;
    }

    /// Ask for fresh counts. Main thread; cheap, so call it as often as
    /// anything changes.
    pub fn request(self: *CountsLoader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running) {
            self.again = true;
            return;
        }
        self.group.await(self.io) catch {}; // reap the finished task
        self.group = .init;
        self.running = true;
        self.group.concurrent(self.io, loadTask, .{self}) catch |err| {
            log.warn("spawn counts load: {}", .{err});
            self.running = false;
        };
    }

    /// The newest counts, if a load finished since the last poll. Main thread;
    /// the caller owns the result (free with `Counts.deinit(loader.allocator)`).
    pub fn poll(self: *CountsLoader) ?Counts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.result orelse return null;
        self.result = null;
        return r;
    }

    fn loadTask(self: *CountsLoader) void {
        var conn = self.db.getConnection() catch |err| {
            log.warn("counts db connection: {}", .{err});
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            return;
        };
        defer conn.deinit();
        while (true) {
            const loaded: ?Counts = load(&conn, self.allocator) catch |err| blk: {
                log.warn("counts load: {}", .{err});
                break :blk null;
            };
            self.mutex.lockUncancelable(self.io);
            if (loaded) |c| {
                if (self.result) |*old| old.deinit(self.allocator);
                self.result = c;
            }
            const again = self.again;
            self.again = false;
            if (!again) self.running = false;
            self.mutex.unlock(self.io);
            if (loaded != null) if (self.wakeup_fn) |w| w();
            if (!again) return;
        }
    }
};
