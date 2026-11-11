const std = @import("std");

/// Passed to the library scanner so it can notify the grid of new images
/// as they are discovered, without importing dvui or image_grid.
pub const ImageNotifier = struct {
    incoming: std.ArrayList(Entry) = .empty,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    // Internal allocator for the backing array and path strings.
    // Defaults to c_allocator so push() is safe from any thread without
    // knowing the caller's allocator.
    allocator: std.mem.Allocator = std.heap.c_allocator,

    /// An image couldn't be passed on (out of memory): the grid reloads from
    /// the DB instead. Guarded by `mutex`.
    lost: bool = false,

    pub const Entry = struct {
        id: u64,
        path: []const u8, // heap-allocated; ownership transfers on drain
        mtime: i64,
    };

    /// Called from scan worker threads. Uses self.allocator; safe to call concurrently.
    pub fn push(self: *ImageNotifier, io: std.Io, id: u64, path: []const u8, mtime: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const path_copy = self.allocator.dupe(u8, path) catch {
            self.lost = true;
            return;
        };
        self.incoming.append(self.allocator, .{ .id = id, .path = path_copy, .mtime = mtime }) catch {
            self.allocator.free(path_copy);
            self.lost = true;
        };
    }

    /// Drains all pending entries into `out`. Paths are re-duped with `allocator`
    /// so the caller can free them with its own allocator. Caller takes ownership.
    /// Returns true when some images couldn't be passed on, so the view must
    /// reload from the DB. Must be called from the main thread only.
    pub fn drain(self: *ImageNotifier, io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList(Entry)) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var lost = self.lost;
        self.lost = false;
        out.ensureUnusedCapacity(allocator, self.incoming.items.len) catch {
            for (self.incoming.items) |e| self.allocator.free(e.path);
            self.incoming.clearRetainingCapacity();
            return true;
        };
        for (self.incoming.items) |e| {
            defer self.allocator.free(e.path);
            const path = allocator.dupe(u8, e.path) catch {
                lost = true;
                continue;
            };
            out.appendAssumeCapacity(.{ .id = e.id, .path = path, .mtime = e.mtime });
        }
        self.incoming.clearRetainingCapacity();
        return lost;
    }

    pub fn deinit(self: *ImageNotifier) void {
        for (self.incoming.items) |e| self.allocator.free(e.path);
        self.incoming.deinit(self.allocator);
    }
};
