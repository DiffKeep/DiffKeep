//! Loads the sidebar's folder lists (the immediate subfolders of a library or
//! folder, with image counts) off the render thread.
//!
//! `listImmediateSubdirs` walks every image row under the folder, which on a
//! large library is far too slow for `frame()`. `request` queues a folder;
//! one worker drains the queue on its own connection; `take` hands the
//! finished lists to the main thread.

const std = @import("std");
const db_mod = @import("db.zig");
const bg = @import("bg.zig");

const log = std.log.scoped(.folder_loader);

pub const FolderCount = db_mod.FolderCount;

pub const Result = struct {
    library_id: u64,
    /// The folder whose children these are (owned).
    path: []const u8,
    /// Owned, as are their paths. Null when the query failed.
    folders: ?[]FolderCount,

    pub fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.folders) |fs| {
            for (fs) |f| a.free(f.path);
            a.free(fs);
        }
    }
};

const Request = struct {
    library_id: u64,
    path: []const u8, // owned

    fn eql(a: Request, b: Request) bool {
        return a.library_id == b.library_id and std.mem.eql(u8, a.path, b.path);
    }

    fn free(a: std.mem.Allocator, r: Request) void {
        a.free(r.path);
    }
};

pub const FolderLoader = struct {
    allocator: std.mem.Allocator,
    /// Pool owner; the worker takes its own connection from it.
    db: *db_mod.VectorDb,
    wakeup_fn: ?*const fn () void = null,
    queue: bg.WorkQueue(Request),
    mutex: std.Io.Mutex = .init,
    done: std.ArrayList(Result) = .empty, // guarded by `mutex`

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb) FolderLoader {
        return .{
            .allocator = allocator,
            .db = db,
            .queue = .init(allocator, io, 1, worker, Request.free),
        };
    }

    /// Drop queued requests, wait for the worker, free unclaimed results.
    pub fn deinit(self: *FolderLoader) void {
        self.queue.deinit();
        for (self.done.items) |r| r.deinit(self.allocator);
        self.done.deinit(self.allocator);
    }

    /// Queue loading the subfolders of `path` (copied). A folder already
    /// queued is not queued twice. Main thread; cheap.
    pub fn request(self: *FolderLoader, library_id: u64, path: []const u8) void {
        const owned = self.allocator.dupe(u8, path) catch return;
        const req: Request = .{ .library_id = library_id, .path = owned };
        _ = self.queue.pushUnique(req, Request.eql) catch self.allocator.free(owned);
    }

    /// The lists finished since the last call, oldest first. Main thread; the
    /// caller owns them (free each with `Result.deinit(loader.allocator)`, then
    /// the slice).
    pub fn take(self: *FolderLoader) []Result {
        const io = self.queue.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.done.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Wait until every queued request has finished (tests).
    pub fn awaitIdle(self: *FolderLoader) void {
        self.queue.awaitIdle();
    }

    fn worker(q: *bg.WorkQueue(Request)) void {
        const self: *FolderLoader = @fieldParentPtr("queue", q);
        const io = q.io;
        var conn = self.db.getConnection() catch |err| {
            log.warn("folder loader db connection: {}", .{err});
            while (q.next()) |r| Request.free(self.allocator, r);
            return;
        };
        defer conn.deinit();
        while (q.next()) |req| {
            const folders: ?[]FolderCount = conn.listImmediateSubdirs(self.allocator, req.library_id, req.path) catch |err| blk: {
                log.warn("list folders of {s}: {}", .{ req.path, err });
                break :blk null;
            };
            const result: Result = .{ .library_id = req.library_id, .path = req.path, .folders = folders };
            self.mutex.lockUncancelable(io);
            self.done.append(self.allocator, result) catch result.deinit(self.allocator);
            self.mutex.unlock(io);
            if (self.wakeup_fn) |w| w();
        }
    }
};
