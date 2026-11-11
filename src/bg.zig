//! Background-task building blocks. Every "run it off the render thread and
//! hand the result back" piece of the app is one of two shapes:
//!
//! * `Latest(T)`: each request supersedes the previous one and only the newest
//!   result is applied (a grid view load, a search's query embedding, the
//!   detail panel's load). Results of superseded requests are freed, never
//!   shown.
//! * `WorkQueue(Item)`: a FIFO drained by up to N workers (folder lists, files
//!   reported by the watcher, file operations, count refreshes). A worker is
//!   the owner's function; it does its own setup (a DB connection, say) and
//!   then takes items with `next()` until there are none.
//!
//! Both start their tasks on a `std.Io.Group` and wake the render loop through
//! an optional `wakeup_fn`. Neither needs anything but `std`, so they are unit
//! tested on their own (src/test.zig).

const std = @import("std");

/// One request at a time wins: `start` supersedes everything before it. The
/// main thread polls `take` and gets the newest generation's outcome once.
/// `free` releases a `T` that is superseded or never taken.
pub fn Latest(comptime T: type, comptime free: fn (*T, std.mem.Allocator) void) type {
    return struct {
        const Self = @This();

        /// What a finished generation produced: `value` is null when the task
        /// failed or had nothing to deliver (the generation is still done).
        pub const Outcome = struct { value: ?T };

        /// Passed to every task as its first argument: whether its request is
        /// still the newest, so a superseded task can stop early (it still
        /// runs, and so can free what it owns).
        pub const Ticket = struct {
            latest: *const Self,
            gen: u64,

            pub fn current(t: Ticket) bool {
                return t.latest.isCurrent(t.gen);
            }
        };

        /// Set by the first `start`; until then nothing runs.
        io: ?std.Io = null,
        allocator: ?std.mem.Allocator = null,
        wakeup_fn: ?*const fn () void = null,
        group: std.Io.Group = .init,
        /// Generation of the newest `start` (or `cancel`).
        gen: std.atomic.Value(u64) = .init(0),
        mutex: std.Io.Mutex = .init,
        // Guarded by `mutex`.
        outcome: ?Outcome = null,
        outcome_gen: u64 = 0,
        /// Main thread: the generation last taken (or cancelled).
        taken_gen: u64 = 0,

        /// Wait for running tasks; free an untaken result.
        pub fn deinit(self: *Self) void {
            const io = self.io orelse return;
            self.group.await(io) catch {};
            self.group = .init;
            if (self.outcome) |*o| if (o.value) |*v| free(v, self.allocator.?);
            self.outcome = null;
        }

        /// Run `function(ticket, args...)` in the background as a new
        /// generation, superseding every earlier one. `function` returns `?T`
        /// (or `T`); null completes the generation with no value. Main thread.
        /// Returns the new generation. On error nothing was started and the
        /// caller still owns what `args` hold.
        pub fn start(self: *Self, io: std.Io, allocator: std.mem.Allocator, comptime function: anytype, args: anytype) !u64 {
            const Args = @TypeOf(args);
            const Task = struct {
                fn run(s: *Self, g: u64, a: Args) void {
                    const v: ?T = @call(.auto, function, .{Ticket{ .latest = s, .gen = g }} ++ a);
                    _ = s.deliver(g, v);
                }
            };
            const gen = self.begin(io, allocator);
            self.group.concurrent(io, Task.run, .{ self, gen, args }) catch |err| {
                // Nothing runs for `gen`; leave nothing pending.
                self.taken_gen = gen;
                return err;
            };
            return gen;
        }

        /// Start a new generation whose result the caller will `deliver`
        /// itself (`start` does both). Main thread.
        pub fn begin(self: *Self, io: std.Io, allocator: std.mem.Allocator) u64 {
            self.io = io;
            self.allocator = allocator;
            const gen = self.gen.load(.acquire) + 1;
            self.gen.store(gen, .release);
            return gen;
        }

        /// Supersede whatever runs without starting anything; `pending` is
        /// false afterwards. Main thread.
        pub fn cancel(self: *Self) void {
            const gen = self.gen.fetchAdd(1, .acq_rel) + 1;
            self.taken_gen = gen;
            const io = self.io orelse return;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.outcome) |*o| if (o.value) |*v| free(v, self.allocator.?);
            self.outcome = null;
        }

        /// Whether `gen` is still the newest generation (tasks may check this
        /// to stop early).
        pub fn isCurrent(self: *const Self, gen: u64) bool {
            return self.gen.load(.acquire) == gen;
        }

        /// Whether the newest generation hasn't been taken yet. Main thread.
        pub fn pending(self: *const Self) bool {
            return self.gen.load(.acquire) != self.taken_gen;
        }

        /// The newest generation's outcome, once, when it has finished. Main
        /// thread; the caller owns the value.
        pub fn take(self: *Self) ?Outcome {
            const io = self.io orelse return null;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const o = self.outcome orelse return null;
            self.outcome = null;
            if (self.outcome_gen != self.gen.load(.acquire)) {
                // Raced with a newer `start`: that one will deliver.
                var stale = o;
                if (stale.value) |*v| free(v, self.allocator.?);
                return null;
            }
            self.taken_gen = self.outcome_gen;
            return o;
        }

        /// Wait for every running task (tests, and before freeing what tasks
        /// borrow).
        pub fn awaitAll(self: *Self) void {
            const io = self.io orelse return;
            self.group.await(io) catch {};
            self.group = .init;
        }

        /// Hand generation `gen`'s outcome to the main thread (any thread).
        /// Returns false, and frees `value`, when `gen` was superseded.
        pub fn deliver(self: *Self, gen: u64, value: ?T) bool {
            const io = self.io.?;
            var v = value;
            self.mutex.lockUncancelable(io);
            // Checked under the mutex, which `cancel` also holds: a superseded
            // task never stores a result the main thread has moved past.
            if (!self.isCurrent(gen)) {
                self.mutex.unlock(io);
                if (v) |*x| free(x, self.allocator.?);
                return false;
            }
            if (self.outcome) |*old| if (old.value) |*x| free(x, self.allocator.?);
            self.outcome = .{ .value = v };
            self.outcome_gen = gen;
            self.mutex.unlock(io);
            if (self.wakeup_fn) |w| w();
            return true;
        }
    };
}

/// A FIFO of `Item`s drained by up to `max_workers` concurrent workers.
/// `worker_fn` is the owner's worker body: it sets up what it needs, then
/// calls `next()` until it returns null (and must then return). Owners usually
/// embed the queue and reach themselves with `@fieldParentPtr`.
pub fn WorkQueue(comptime Item: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        max_workers: u32,
        worker_fn: *const fn (*Self) void,
        /// Frees an item that is dropped unprocessed (deinit, `removeIf`, a
        /// duplicate in `pushUnique`).
        free_item: ?*const fn (std.mem.Allocator, Item) void = null,
        group: std.Io.Group = .init,
        mutex: std.Io.Mutex = .init,
        // Guarded by `mutex`.
        items: std.ArrayList(Item) = .empty,
        workers: u32 = 0,
        paused: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            max_workers: u32,
            worker_fn: *const fn (*Self) void,
            free_item: ?*const fn (std.mem.Allocator, Item) void,
        ) Self {
            return .{ .allocator = allocator, .io = io, .max_workers = max_workers, .worker_fn = worker_fn, .free_item = free_item };
        }

        /// Stop taking items, wait for the workers, free what is left.
        pub fn deinit(self: *Self) void {
            self.pause();
            self.awaitIdle();
            for (self.items.items) |it| self.freeItem(it);
            self.items.deinit(self.allocator);
        }

        /// Queue `item` (ownership moves to the queue) and start a worker if
        /// one is free. On error the caller still owns `item`.
        pub fn push(self: *Self, item: Item) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.items.append(self.allocator, item);
            self.startWorkersLocked();
        }

        /// `push`, unless an item `eql` to it is already queued (not yet taken
        /// by a worker); then `item` is freed. Returns whether it was queued.
        pub fn pushUnique(self: *Self, item: Item, comptime eql: fn (Item, Item) bool) !bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.items.items) |q| {
                if (eql(q, item)) {
                    self.freeItem(item);
                    return false;
                }
            }
            try self.items.append(self.allocator, item);
            self.startWorkersLocked();
            return true;
        }

        /// Worker: put back an item it could not finish (it was stopped), at
        /// the front, to run first once the queue runs again. Freed instead
        /// if an item `eql` to it is queued. Starts no worker.
        pub fn requeueFront(self: *Self, item: Item, comptime eql: fn (Item, Item) bool) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.items.items) |q| {
                if (eql(q, item)) return self.freeItem(item);
            }
            self.items.insert(self.allocator, 0, item) catch self.freeItem(item);
        }

        /// Whether anything is queued or running.
        pub fn busy(self: *Self) bool {
            const l = self.load();
            return l.queued > 0 or l.workers > 0;
        }

        /// Worker: the next item, or null when the queue is empty or paused
        /// (the worker must return then; it no longer counts as running).
        pub fn next(self: *Self) ?Item {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.paused or self.items.items.len == 0) {
                self.workers -= 1;
                return null;
            }
            return self.items.orderedRemove(0);
        }

        /// Workers finish their current item and stop; queued items stay.
        pub fn pause(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.paused = true;
        }

        /// Undo `pause` and start workers for whatever is queued.
        pub fn unpause(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.paused = false;
            self.startWorkersLocked();
        }

        /// Wait until no worker runs (the queue may still hold items if paused).
        pub fn awaitIdle(self: *Self) void {
            self.group.await(self.io) catch {};
            self.group = .init;
        }

        /// Drop (and free) every queued item `pred` matches.
        pub fn removeIf(self: *Self, ctx: anytype, comptime pred: fn (@TypeOf(ctx), Item) bool) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var i: usize = 0;
            while (i < self.items.items.len) {
                if (pred(ctx, self.items.items[i])) {
                    self.freeItem(self.items.orderedRemove(i));
                } else i += 1;
            }
        }

        /// Whether any queued item matches `pred`.
        pub fn anyQueued(self: *Self, ctx: anytype, comptime pred: fn (@TypeOf(ctx), Item) bool) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.items.items) |it| if (pred(ctx, it)) return true;
            return false;
        }

        /// Items queued plus workers running (tests, status).
        pub fn load(self: *Self) struct { queued: usize, workers: u32 } {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return .{ .queued = self.items.items.len, .workers = self.workers };
        }

        fn runWorker(self: *Self) void {
            self.worker_fn(self);
        }

        fn freeItem(self: *Self, item: Item) void {
            if (self.free_item) |f| f(self.allocator, item);
        }

        fn startWorkersLocked(self: *Self) void {
            if (self.paused) return;
            while (self.workers < self.max_workers and self.workers < self.items.items.len) {
                self.group.concurrent(self.io, runWorker, .{self}) catch |err| {
                    std.log.scoped(.bg).warn("spawn worker: {}", .{err});
                    return;
                };
                self.workers += 1;
            }
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn freeSlice(s: *[]u8, a: std.mem.Allocator) void {
    a.free(s.*);
}

fn makeSlice(_: Latest([]u8, freeSlice).Ticket, a: std.mem.Allocator, n: usize) ?[]u8 {
    const s = a.alloc(u8, n) catch return null;
    @memset(s, @intCast(n));
    return s;
}

test "Latest: only the newest generation is taken; older results are freed" {
    const io = testing.io;
    const a = testing.allocator;
    var l: Latest([]u8, freeSlice) = .{};
    defer l.deinit();
    try testing.expect(!l.pending());
    try testing.expect(l.take() == null);

    _ = try l.start(io, a, makeSlice, .{ a, 1 });
    _ = try l.start(io, a, makeSlice, .{ a, 2 });
    _ = try l.start(io, a, makeSlice, .{ a, 3 });
    try testing.expect(l.pending());
    l.awaitAll();
    var o = l.take().?;
    defer if (o.value) |*v| freeSlice(v, a);
    try testing.expectEqual(@as(usize, 3), o.value.?.len);
    try testing.expect(!l.pending());
    try testing.expect(l.take() == null);
}

fn nothing(_: Latest([]u8, freeSlice).Ticket, _: std.mem.Allocator) ?[]u8 {
    return null;
}

test "Latest: a failed generation completes with no value; cancel drops results" {
    const io = testing.io;
    const a = testing.allocator;
    var l: Latest([]u8, freeSlice) = .{};
    defer l.deinit();

    _ = try l.start(io, a, nothing, .{a});
    l.awaitAll();
    const o = l.take().?;
    try testing.expect(o.value == null);
    try testing.expect(!l.pending());

    _ = try l.start(io, a, makeSlice, .{ a, 4 });
    l.awaitAll();
    l.cancel(); // frees the delivered value
    try testing.expect(!l.pending());
    try testing.expect(l.take() == null);
}

const Summer = struct {
    queue: WorkQueue(u32),
    total: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),
    running: std.atomic.Value(u32) = .init(0),

    fn worker(q: *WorkQueue(u32)) void {
        const self: *Summer = @fieldParentPtr("queue", q);
        while (q.next()) |n| {
            const r = self.running.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak.fetchMax(r, .acq_rel);
            _ = self.total.fetchAdd(n, .acq_rel);
            _ = self.running.fetchSub(1, .acq_rel);
        }
    }

    fn eql(x: u32, y: u32) bool {
        return x == y;
    }

    fn isOdd(_: void, x: u32) bool {
        return x % 2 == 1;
    }
};

test "WorkQueue: every item is processed by at most max_workers workers" {
    var s: Summer = .{ .queue = .init(testing.allocator, testing.io, 3, Summer.worker, null) };
    defer s.queue.deinit();
    var expect: u32 = 0;
    for (1..201) |n| {
        try s.queue.push(@intCast(n));
        expect += @intCast(n);
        try testing.expect(s.queue.load().workers <= 3);
    }
    s.queue.awaitIdle();
    try testing.expectEqual(expect, s.total.load(.acquire));
    try testing.expect(s.peak.load(.acquire) <= 3);
    const l = s.queue.load();
    try testing.expectEqual(@as(usize, 0), l.queued);
    try testing.expectEqual(@as(u32, 0), l.workers);
}

test "WorkQueue: paused queues keep their items; pushUnique and removeIf" {
    var s: Summer = .{ .queue = .init(testing.allocator, testing.io, 1, Summer.worker, null) };
    defer s.queue.deinit();
    s.queue.pause();
    try s.queue.push(1);
    try testing.expect(!try s.queue.pushUnique(1, Summer.eql));
    try testing.expect(try s.queue.pushUnique(2, Summer.eql));
    try s.queue.push(3);
    try testing.expectEqual(@as(usize, 3), s.queue.load().queued);
    try testing.expect(s.queue.anyQueued({}, Summer.isOdd));
    s.queue.removeIf({}, Summer.isOdd);
    try testing.expectEqual(@as(usize, 1), s.queue.load().queued);
    s.queue.requeueFront(7, Summer.eql);
    s.queue.requeueFront(2, Summer.eql); // already queued: dropped
    try testing.expectEqual(@as(usize, 2), s.queue.load().queued);
    try testing.expect(s.queue.busy());
    s.queue.unpause();
    s.queue.awaitIdle();
    try testing.expectEqual(@as(u32, 9), s.total.load(.acquire));
    try testing.expect(!s.queue.busy());
}
