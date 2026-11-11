//! What every file-watcher backend (inotify, FSEvents, ReadDirectoryChangesW)
//! shares: the event type handed to the app, and the queue that carries
//! events from the watcher's thread to the main thread.

const std = @import("std");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const DirtyEvent = struct {
    library_id: u64,
    /// Heap-allocated absolute path.  Caller must free after processing.
    /// The changed file for `.file`, the library root for `.rescan_library`.
    path: []u8,
    deleted: bool,
    kind: Kind = .file,

    pub const Kind = enum {
        /// One file changed or disappeared.
        file,
        /// Something only a scan can reconcile: a directory moved into, out
        /// of, or within the library (the watcher says nothing about the files
        /// it holds), or events the OS dropped or coalesced.
        rescan_library,
    };
};

/// Events from the watcher's thread, drained by the main thread. A spinlock,
/// not `std.Io.Mutex`: the backends' callbacks run on threads with no
/// `std.Io` (GCD queues, plain threads), and each critical section is a list
/// append or swap.
pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    lock: Spinlock = .{},
    events: std.ArrayList(DirtyEvent) = .empty,
    /// Called after each push (from the watcher's thread) to wake the app.
    on_dirty: ?*const fn () void = null,

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return .{ .allocator = allocator };
    }

    /// Free undrained events.
    pub fn deinit(self: *EventQueue) void {
        for (self.events.items) |ev| self.allocator.free(ev.path);
        self.events.deinit(self.allocator);
    }

    /// Queue `ev`, taking ownership of its path (freed if it can't be queued).
    pub fn push(self: *EventQueue, ev: DirtyEvent) void {
        self.lock.lock();
        self.events.append(self.allocator, ev) catch {
            self.lock.unlock();
            self.allocator.free(ev.path);
            return;
        };
        self.lock.unlock();
        if (self.on_dirty) |cb| cb();
    }

    /// Ask the app to reconcile a whole library with a scan. The app merges
    /// these per library, so a burst of them costs one scan.
    pub fn pushRescan(self: *EventQueue, library_id: u64, library_path: []const u8) void {
        const path = self.allocator.dupe(u8, library_path) catch return;
        std.log.scoped(.fs_watch).info("rescan requested for library {} ({s})", .{ library_id, library_path });
        self.push(.{ .library_id = library_id, .path = path, .deleted = false, .kind = .rescan_library });
    }

    /// Take every queued event. The caller owns the list and each path.
    pub fn drain(self: *EventQueue) std.ArrayList(DirtyEvent) {
        self.lock.lock();
        const list = self.events;
        self.events = .empty;
        self.lock.unlock();
        return list;
    }
};

var test_wakes: u32 = 0;
fn testWake() void {
    test_wakes += 1;
}

test "EventQueue: push, rescan and drain hand over every event once" {
    const a = std.testing.allocator;
    var q: EventQueue = .init(a);
    defer q.deinit();
    q.on_dirty = testWake;
    test_wakes = 0;
    q.push(.{ .library_id = 1, .path = try a.dupe(u8, "/lib/a.png"), .deleted = false });
    q.pushRescan(1, "/lib");
    try std.testing.expectEqual(@as(u32, 2), test_wakes);

    var got = q.drain();
    defer {
        for (got.items) |ev| a.free(ev.path);
        got.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqual(DirtyEvent.Kind.file, got.items[0].kind);
    try std.testing.expectEqual(DirtyEvent.Kind.rescan_library, got.items[1].kind);
    try std.testing.expectEqualStrings("/lib", got.items[1].path);
    try std.testing.expectEqual(@as(usize, 0), q.drain().items.len);

    // Undrained events are freed by deinit (the testing allocator checks).
    q.push(.{ .library_id = 1, .path = try a.dupe(u8, "/lib/b.png"), .deleted = true });
}
