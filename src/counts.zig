//! Library-wide counts shown in the sidebar, toolbar and settings (total,
//! trash, duplicates, favorites, per library, database size), loaded off the
//! render thread, plus the settings' clear-cache operations.
//!
//! Some of these are full-table aggregates (the duplicate count groups every
//! hash), and they are wanted after every favorite toggle, file operation and
//! scanned image, so they must not run in `frame()`. `request` asks for fresh
//! counts; requests made while a load runs coalesce into one more load.
//! `requestStats` also asks for the database stats (they read every
//! thumbnail, so only while settings are open), and `clear` drops a cache
//! before the next load. `poll` hands the latest result to the main thread.

const std = @import("std");
const db_mod = @import("db.zig");
const bg = @import("bg.zig");

const log = std.log.scoped(.counts);

pub const LibraryCount = struct { id: u64, count: i64 };

pub const Counts = struct {
    total: i64 = 0,
    trash: ?db_mod.TrashStats = null,
    duplicates: i64 = 0,
    /// Copies "remove duplicates" would move to the trash (all but one of each).
    redundant_duplicates: i64 = 0,
    favorites: i64 = 0,
    /// Only when asked for with `requestStats` or `clear`.
    db_stats: ?db_mod.DbStats = null,
    /// Owned (by the loader's allocator); free with `deinit`.
    libraries: []LibraryCount = &.{},

    pub fn deinit(self: *Counts, a: std.mem.Allocator) void {
        a.free(self.libraries);
        self.libraries = &.{};
    }
};

/// A derived-data cache the settings can clear.
pub const Cache = enum { thumbnails, prompt_embeddings, image_embeddings };

/// Which caches to clear on the next load.
pub const ClearSet = std.EnumSet(Cache);

/// Clear `caches` on `db`. Does DB IO: call it off the main thread.
pub fn clearCaches(db: *db_mod.VectorDb, caches: ClearSet) !void {
    var it = caches.iterator();
    while (it.next()) |c| switch (c) {
        .thumbnails => try db.clearThumbnails(),
        .prompt_embeddings => try db.clearPromptEmbeddings(),
        .image_embeddings => try db.clearImageEmbeddings(),
    };
}

/// Compute every count on `db` (and the database stats if `with_stats`).
/// Does DB IO: call it off the main thread.
pub fn load(db: *db_mod.VectorDb, a: std.mem.Allocator, with_stats: bool) !Counts {
    var c: Counts = .{
        .total = try db.getTotalImageCount(),
        .trash = try db.getTrashStats(),
        .duplicates = try db.getDuplicateCount(),
        .redundant_duplicates = try db.getRedundantDuplicateCount(),
        .favorites = try db.getFavoriteCount(),
        .db_stats = if (with_stats) try db.getStats() else null,
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

/// A request for one more load. Queued at most once (`pushUnique`), so any
/// number of requests made while a load runs coalesce into one more load.
const Refresh = struct {
    fn eql(_: Refresh, _: Refresh) bool {
        return true;
    }
};

pub const CountsLoader = struct {
    allocator: std.mem.Allocator,
    /// Pool owner; the worker takes its own connection from it.
    db: *db_mod.VectorDb,
    wakeup_fn: ?*const fn () void = null,
    queue: bg.WorkQueue(Refresh),
    mutex: std.Io.Mutex = .init,
    // Guarded by `mutex`.
    want_stats: bool = false,
    clears: ClearSet = .empty,
    result: ?Counts = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb) CountsLoader {
        return .{ .allocator = allocator, .db = db, .queue = .init(allocator, io, 1, worker, null) };
    }

    /// Wait for a running load; free an unclaimed result.
    pub fn deinit(self: *CountsLoader) void {
        self.queue.deinit();
        if (self.result) |*r| r.deinit(self.allocator);
        self.result = null;
    }

    /// Ask for fresh counts. Main thread; cheap, so call it as often as
    /// anything changes.
    pub fn request(self: *CountsLoader) void {
        _ = self.queue.pushUnique(.{}, Refresh.eql) catch |err| log.warn("queue counts load: {}", .{err});
    }

    /// Ask for fresh counts and database stats. Main thread.
    pub fn requestStats(self: *CountsLoader) void {
        self.lock();
        self.want_stats = true;
        self.unlock();
        self.request();
    }

    /// Clear `cache` in the background, then load fresh counts and stats.
    /// Main thread.
    pub fn clear(self: *CountsLoader, cache: Cache) void {
        self.lock();
        self.clears.insert(cache);
        self.want_stats = true;
        self.unlock();
        self.request();
    }

    /// Wait for queued loads (tests).
    pub fn awaitIdle(self: *CountsLoader) void {
        self.queue.awaitIdle();
    }

    /// The newest counts, if a load finished since the last poll. Main thread;
    /// the caller owns the result (free with `Counts.deinit(loader.allocator)`).
    pub fn poll(self: *CountsLoader) ?Counts {
        self.lock();
        defer self.unlock();
        const r = self.result orelse return null;
        self.result = null;
        return r;
    }

    fn lock(self: *CountsLoader) void {
        self.mutex.lockUncancelable(self.queue.io);
    }
    fn unlock(self: *CountsLoader) void {
        self.mutex.unlock(self.queue.io);
    }

    fn worker(q: *bg.WorkQueue(Refresh)) void {
        const self: *CountsLoader = @fieldParentPtr("queue", q);
        var conn = self.db.getConnection() catch |err| {
            log.warn("counts db connection: {}", .{err});
            while (q.next()) |_| {}
            return;
        };
        defer conn.deinit();
        while (q.next()) |_| {
            self.lock();
            const clears = self.clears;
            const with_stats = self.want_stats;
            self.clears = .empty;
            self.want_stats = false;
            self.unlock();
            clearCaches(&conn, clears) catch |err| log.warn("clear caches: {}", .{err});
            var c = load(&conn, self.allocator, with_stats) catch |err| {
                log.warn("counts load: {}", .{err});
                continue;
            };
            self.lock();
            if (self.result) |*old| {
                // Unclaimed stats survive a newer load that skipped them.
                if (c.db_stats == null) c.db_stats = old.db_stats;
                old.deinit(self.allocator);
            }
            self.result = c;
            self.unlock();
            if (self.wakeup_fn) |w| w();
        }
    }
};
