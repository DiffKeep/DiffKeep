//! Loads the sidebar's folder lists (the immediate subfolders of a library or
//! folder, with image counts) off the render thread.
//!
//! `listImmediateSubdirs` walks every image row under the folder, which on a
//! large library is far too slow for `frame()`. `request` queues a folder;
//! one worker task drains the queue on its own connection; `take` hands the
//! finished lists to the main thread.

const std = @import("std");
const db_mod = @import("db.zig");

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

const Request = struct { library_id: u64, path: []const u8 };

pub const FolderLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Pool owner; the worker takes its own connection from it.
    db: *db_mod.VectorDb,
    wakeup_fn: ?*const fn () void = null,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    // Guarded by `mutex`.
    running: bool = false,
    pending: std.ArrayList(Request) = .empty,
    done: std.ArrayList(Result) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb) FolderLoader {
        return .{ .allocator = allocator, .io = io, .db = db };
    }

    /// Drop queued requests, wait for the worker, free unclaimed results.
    pub fn deinit(self: *FolderLoader) void {
        self.mutex.lockUncancelable(self.io);
        for (self.pending.items) |r| self.allocator.free(r.path);
        self.pending.clearRetainingCapacity();
        self.mutex.unlock(self.io);
        self.group.await(self.io) catch {};
        self.pending.deinit(self.allocator);
        for (self.done.items) |r| r.deinit(self.allocator);
        self.done.deinit(self.allocator);
    }

    /// Queue loading the subfolders of `path` (copied). A folder already
    /// queued is not queued twice. Main thread; cheap.
    pub fn request(self: *FolderLoader, library_id: u64, path: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |r| {
            if (r.library_id == library_id and std.mem.eql(u8, r.path, path)) return;
        }
        const owned = self.allocator.dupe(u8, path) catch return;
        self.pending.append(self.allocator, .{ .library_id = library_id, .path = owned }) catch {
            self.allocator.free(owned);
            return;
        };
        if (self.running) return;
        self.group.await(self.io) catch {}; // reap the finished worker
        self.group = .init;
        self.running = true;
        self.group.concurrent(self.io, worker, .{self}) catch |err| {
            log.warn("spawn folder load: {}", .{err});
            self.running = false;
        };
    }

    /// The lists finished since the last call, oldest first. Main thread; the
    /// caller owns them (free each with `Result.deinit(loader.allocator)`, then
    /// the slice).
    pub fn take(self: *FolderLoader) []Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Wait until every queued request has finished (tests).
    pub fn awaitIdle(self: *FolderLoader) void {
        self.group.await(self.io) catch {};
    }

    fn worker(self: *FolderLoader) void {
        var conn = self.db.getConnection() catch |err| {
            log.warn("folder loader db connection: {}", .{err});
            self.mutex.lockUncancelable(self.io);
            for (self.pending.items) |r| self.allocator.free(r.path);
            self.pending.clearRetainingCapacity();
            self.running = false;
            self.mutex.unlock(self.io);
            return;
        };
        defer conn.deinit();
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.pending.items.len == 0) {
                self.running = false;
                self.mutex.unlock(self.io);
                return;
            }
            const req = self.pending.orderedRemove(0);
            self.mutex.unlock(self.io);

            const folders: ?[]FolderCount = conn.listImmediateSubdirs(self.allocator, req.library_id, req.path) catch |err| blk: {
                log.warn("list folders of {s}: {}", .{ req.path, err });
                break :blk null;
            };
            const result: Result = .{ .library_id = req.library_id, .path = req.path, .folders = folders };
            self.mutex.lockUncancelable(self.io);
            self.done.append(self.allocator, result) catch result.deinit(self.allocator);
            self.mutex.unlock(self.io);
            if (self.wakeup_fn) |w| w();
        }
    }
};
