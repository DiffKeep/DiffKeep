const std = @import("std");
const llama = @import("llama.zig");
const log = std.log.scoped(.queue);

// Generic Task interface
pub fn Task(comptime Context: type) type {
    return struct {
        context: Context,
        execute: *const fn (Context) void,
    };
}

// Queue implementation
pub fn TaskQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = enum(u8) {
            stopped,
            running,
            paused,
        };

        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        tasks: std.ArrayList(T),
        allocator: std.mem.Allocator,
        workers: ?[]std.Thread,
        state: std.atomic.Value(State),
        worker_count: usize,
        totalTasks: usize,

        pub fn init(allocator: std.mem.Allocator, worker_count: usize) !Self {
            return Self{
                .mutex = .{},
                .condition = .{},
                .tasks = std.ArrayList(T).init(allocator),
                .allocator = allocator,
                .workers = null,
                .state = std.atomic.Value(State).init(.stopped),
                .worker_count = worker_count,
                .totalTasks = 0,
            };
        }

        pub fn start(self: *Self) !void {
            log.debug("Starting queue", .{});
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .stopped) {
                return error.QueueAlreadyStarted;
            }

            var workers = try self.allocator.alloc(std.Thread, self.worker_count);
            errdefer self.allocator.free(workers);

            // Start worker threads
            for (0..self.worker_count) |i| {
                workers[i] = try std.Thread.spawn(.{}, worker, .{self});
            }

            self.workers = workers;
            self.state.store(.running, .release);
        }

        pub fn pause(self: *Self) void {
            if (self.state.load(.acquire) == .running) {
                self.state.store(.paused, .release);
            }
        }

        pub fn unpause(self: *Self) void {
            if (self.state.load(.acquire) == .paused) {
                self.state.store(.running, .release);
                self.condition.broadcast(); // Wake up all waiting workers
            }
        }

        pub fn stop(self: *Self) void {
            if (self.state.load(.acquire) != .stopped) {
                self.state.store(.stopped, .release);
                self.condition.broadcast();

                // Wait for all workers to finish
                if (self.workers) |workers| {
                    for (workers) |worker_thread| {
                        worker_thread.join();
                    }
                    self.allocator.free(workers);
                    self.workers = null;
                }
            }
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.tasks.deinit();
        }

        pub fn submit(self: *Self, task: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) == .stopped) {
                return error.QueueNotStarted;
            }

            try self.tasks.append(task);
            self.totalTasks += 1;
            self.condition.signal();
        }

        pub fn total(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.totalTasks;
        }

        pub fn remaining(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tasks.items.len;
        }

        fn worker(self: *Self) void {
            while (true) {
                self.mutex.lock();

                // Check state and wait if necessary
                while ((self.tasks.items.len == 0 or self.state.load(.acquire) == .paused) and
                       self.state.load(.acquire) != .stopped) {
                    self.condition.wait(&self.mutex);
                }

                // Check if we should exit
                if (self.state.load(.acquire) == .stopped) {
                    self.mutex.unlock();
                    break;
                }

                // Get next task if available
                const task = if (self.tasks.pop()) |t| t else {
                    self.mutex.unlock();
                    continue;
                };
                self.mutex.unlock();

                // Execute the task
                task.execute(task.context);
            }
        }
    };
}
