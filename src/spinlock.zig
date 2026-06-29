const std = @import("std");

/// Minimal spinlock for very short critical sections (e.g. swapping a small
/// buffer between a watcher thread and the main thread). Shared by the
/// platform-specific fs_watch implementations.
pub const Spinlock = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

test "spinlock: lock then unlock toggles state" {
    var sl: Spinlock = .{};
    try std.testing.expectEqual(@as(u8, 0), sl.state.load(.monotonic));
    sl.lock();
    try std.testing.expectEqual(@as(u8, 1), sl.state.load(.monotonic));
    sl.unlock();
    try std.testing.expectEqual(@as(u8, 0), sl.state.load(.monotonic));
}

test "spinlock: serializes a counter across threads" {
    var sl: Spinlock = .{};
    var counter: u64 = 0;

    const Worker = struct {
        fn run(lock_ptr: *Spinlock, count_ptr: *u64) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                lock_ptr.lock();
                count_ptr.* += 1;
                lock_ptr.unlock();
            }
        }
    };

    var t0 = try std.Thread.spawn(.{}, Worker.run, .{ &sl, &counter });
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ &sl, &counter });
    t0.join();
    t1.join();

    try std.testing.expectEqual(@as(u64, 20_000), counter);
}
