const std = @import("std");

/// Passed to the library scanner so it can notify the grid of new images
/// as they are discovered, without importing dvui or image_grid.
pub const ImageNotifier = struct {
    incoming: std.ArrayList(Entry) = .empty,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub const Entry = struct {
        id: u64,
        path: []const u8, // heap-allocated; ownership transfers on drain
        mtime: i64,
    };

    /// Called from scan worker threads. Duplicates path; safe to call concurrently.
    pub fn push(self: *ImageNotifier, io: std.Io, allocator: std.mem.Allocator, id: u64, path: []const u8, mtime: i64) void {
        const path_copy = allocator.dupe(u8, path) catch return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.incoming.append(allocator, .{ .id = id, .path = path_copy, .mtime = mtime }) catch {
            allocator.free(path_copy);
        };
    }

    /// Drains all pending entries into `out`. Caller takes ownership of Entry.path.
    /// Must be called from the main thread only.
    pub fn drain(self: *ImageNotifier, io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList(Entry)) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.incoming.items) |e| {
            out.append(allocator, e) catch {
                allocator.free(e.path);
                continue;
            };
        }
        self.incoming.clearAndFree(allocator);
    }

    pub fn deinit(self: *ImageNotifier, allocator: std.mem.Allocator) void {
        for (self.incoming.items) |e| allocator.free(e.path);
        self.incoming.deinit(allocator);
    }
};
