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

    pub const Entry = struct {
        id: u64,
        path: []const u8, // heap-allocated; ownership transfers on drain
        mtime: i64,
    };

    /// Called from scan worker threads. Uses self.allocator; safe to call concurrently.
    pub fn push(self: *ImageNotifier, io: std.Io, id: u64, path: []const u8, mtime: i64) void {
        const path_copy = self.allocator.dupe(u8, path) catch return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.incoming.append(self.allocator, .{ .id = id, .path = path_copy, .mtime = mtime }) catch {
            self.allocator.free(path_copy);
        };
    }

    /// Drains all pending entries into `out`. Paths are re-duped with `allocator`
    /// so the caller can free them with its own allocator. Caller takes ownership.
    /// Must be called from the main thread only.
    pub fn drain(self: *ImageNotifier, io: std.Io, allocator: std.mem.Allocator, out: *std.ArrayList(Entry)) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.incoming.items) |e| {
            const path = allocator.dupe(u8, e.path) catch {
                self.allocator.free(e.path);
                continue;
            };
            self.allocator.free(e.path);
            out.append(allocator, .{ .id = e.id, .path = path, .mtime = e.mtime }) catch {
                allocator.free(path);
                continue;
            };
        }
        self.incoming.clearRetainingCapacity();
    }

    pub fn deinit(self: *ImageNotifier) void {
        for (self.incoming.items) |e| self.allocator.free(e.path);
        self.incoming.deinit(self.allocator);
    }
};
