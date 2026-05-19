/// inotify-based file system watcher (Linux only).
///
/// Watches each library's root directory recursively.  When a new
/// subdirectory is created the watcher adds a watch for it too, so images
/// written into freshly-created date-based output folders are caught.
///
/// Only .png files trigger events.  Callers receive a list of DirtyEvent
/// values describing exactly which file changed; they process that file
/// directly without a full library rescan.
const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.fs_watch);

/// Events that indicate a file is ready to read (fully written).
const MASK_MODIFY: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO;
/// Events that indicate a file has been removed.
const MASK_DELETE: u32 = linux.IN.DELETE | linux.IN.MOVED_FROM;
/// Events that indicate a new subdirectory appeared.
const MASK_NEW_DIR: u32 = linux.IN.CREATE | linux.IN.MOVED_TO;

const WATCH_MASK: u32 = MASK_MODIFY | MASK_DELETE | linux.IN.CREATE |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

// ── Spinlock ──────────────────────────────────────────────────────────────────

const Spinlock = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

// ── Command channel (main → watcher thread) ──────────────────────────────────

const Cmd = union(enum) {
    add: struct { library_id: u64, path: []const u8 },
    remove: struct { library_id: u64 },
    stop,
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const DirtyEvent = struct {
    library_id: u64,
    /// Heap-allocated absolute path.  Caller must free after processing.
    path: []u8,
    deleted: bool,
};

// ── Public API ────────────────────────────────────────────────────────────────

pub const FsWatcher = struct {
    allocator: std.mem.Allocator,
    inotify_fd: i32,
    wake_pipe: [2]i32,
    started: bool = false,

    cmd_lock: Spinlock = .{},
    cmds: std.ArrayList(Cmd) = .empty,

    dirty_lock: Spinlock = .{},
    dirty_events: std.ArrayList(DirtyEvent) = .empty,
    on_dirty: ?*const fn () void = null,

    thread: std.Thread = undefined,

    pub fn init(allocator: std.mem.Allocator) !FsWatcher {
        const ifd = linux.inotify_init1(linux.IN.CLOEXEC);
        if (@as(isize, @bitCast(ifd)) < 0) return error.InotifyInit;
        const inotify_fd: i32 = @intCast(ifd);
        errdefer _ = linux.close(inotify_fd);

        var wp: [2]i32 = undefined;
        if (@as(isize, @bitCast(linux.pipe2(&wp, .{ .CLOEXEC = true }))) < 0)
            return error.PipeCreate;

        log.info("initialized (inotify_fd={})", .{inotify_fd});
        return .{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .wake_pipe = wp,
        };
    }

    /// Spawn the watcher thread.  Must be called AFTER the FsWatcher is stored
    /// at its final stable address (global / heap).
    pub fn start(self: *FsWatcher) !void {
        self.thread = try std.Thread.spawn(.{}, watcherFn, .{self});
        self.started = true;
    }

    pub fn deinit(self: *FsWatcher) void {
        if (self.started) {
            self.pushCmd(.stop);
            self.thread.join();
        }
        _ = linux.close(self.wake_pipe[1]);
        _ = linux.close(self.wake_pipe[0]);
        _ = linux.close(self.inotify_fd);
        for (self.cmds.items) |cmd| freeCmd(self.allocator, cmd);
        self.cmds.deinit(self.allocator);
        for (self.dirty_events.items) |ev| self.allocator.free(ev.path);
        self.dirty_events.deinit(self.allocator);
    }

    pub fn addLibrary(self: *FsWatcher, library_id: u64, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        log.info("queuing add library {} path={s}", .{ library_id, path });
        self.pushCmd(.{ .add = .{ .library_id = library_id, .path = path_copy } });
    }

    pub fn removeLibrary(self: *FsWatcher, library_id: u64) void {
        log.info("queuing remove library {}", .{library_id});
        self.pushCmd(.{ .remove = .{ .library_id = library_id } });
    }

    /// Drain all pending file events.  The caller owns each DirtyEvent.path
    /// slice and must free it after processing.
    pub fn drainEvents(self: *FsWatcher) std.ArrayList(DirtyEvent) {
        self.dirty_lock.lock();
        const list = self.dirty_events;
        self.dirty_events = .empty;
        self.dirty_lock.unlock();
        return list;
    }

    fn pushCmd(self: *FsWatcher, cmd: Cmd) void {
        self.cmd_lock.lock();
        self.cmds.append(self.allocator, cmd) catch {
            self.cmd_lock.unlock();
            freeCmd(self.allocator, cmd);
            return;
        };
        self.cmd_lock.unlock();
        const byte: [1]u8 = .{1};
        _ = linux.write(self.wake_pipe[1], &byte, 1);
    }

    fn pushEvent(self: *FsWatcher, ev: DirtyEvent) void {
        self.dirty_lock.lock();
        self.dirty_events.append(self.allocator, ev) catch {
            self.dirty_lock.unlock();
            self.allocator.free(ev.path);
            return;
        };
        self.dirty_lock.unlock();
        if (self.on_dirty) |cb| cb();
    }
};

fn freeCmd(allocator: std.mem.Allocator, cmd: Cmd) void {
    if (cmd == .add) allocator.free(cmd.add.path);
}

// ── Watcher thread ────────────────────────────────────────────────────────────

fn watcherFn(self: *FsWatcher) void {
    const allocator = self.allocator;

    var wd_lib = std.AutoHashMap(i32, u64).init(allocator);
    defer wd_lib.deinit();

    var wd_path = std.AutoHashMap(i32, []u8).init(allocator);
    defer {
        var it = wd_path.valueIterator();
        while (it.next()) |p| allocator.free(p.*);
        wd_path.deinit();
    }

    var lib_wds = std.AutoHashMap(u64, std.ArrayList(i32)).init(allocator);
    defer {
        var it = lib_wds.valueIterator();
        while (it.next()) |wds| wds.deinit(allocator);
        lib_wds.deinit();
    }

    log.info("watcher thread started", .{});

    var pollfds = [2]linux.pollfd{
        .{ .fd = self.inotify_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };

    outer: while (true) {
        _ = linux.poll(@ptrCast(&pollfds), 2, -1);

        // ── Commands ─────────────────────────────────────────────────────────
        if (pollfds[1].revents & linux.POLL.IN != 0) {
            var drain: [64]u8 = undefined;
            _ = linux.read(self.wake_pipe[0], &drain, drain.len);

            self.cmd_lock.lock();
            var local = self.cmds;
            self.cmds = .empty;
            self.cmd_lock.unlock();

            var stop_requested = false;
            for (local.items) |cmd| {
                switch (cmd) {
                    .stop => stop_requested = true,
                    .add => |a| {
                        if (!stop_requested) {
                            const before = wd_lib.count();
                            watchAllSubdirs(self.inotify_fd, a.library_id, a.path,
                                &wd_lib, &wd_path, &lib_wds, allocator);
                            log.info("library {} path={s}: {} watch(es) added",
                                .{ a.library_id, a.path, wd_lib.count() - before });
                        }
                        allocator.free(a.path);
                    },
                    .remove => |r| {
                        if (!stop_requested)
                            removeWatches(self.inotify_fd, r.library_id,
                                &wd_lib, &wd_path, &lib_wds, allocator);
                    },
                }
            }
            local.deinit(allocator);
            if (stop_requested) break :outer;
        }

        // ── inotify events ───────────────────────────────────────────────────
        if (pollfds[0].revents & linux.POLL.IN != 0) {
            var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
            const n = linux.read(self.inotify_fd, &buf, buf.len);
            if (@as(isize, @bitCast(n)) <= 0) continue;

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= n) {
                const event: *const linux.inotify_event =
                    @ptrCast(@alignCast(&buf[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;

                const mask = event.mask;
                const wd = event.wd;
                const name = event.getName();

                if (mask & linux.IN.IGNORED != 0) {
                    if (wd_path.fetchRemove(wd)) |kv| allocator.free(kv.value);
                    _ = wd_lib.remove(wd);
                    continue;
                }

                // New subdirectory: add a watch so files inside are caught.
                if (mask & linux.IN.ISDIR != 0 and mask & MASK_NEW_DIR != 0) {
                    if (name) |n_| {
                        if (wd_path.get(wd)) |parent| {
                            if (wd_lib.get(wd)) |lib_id| {
                                const sub = std.fs.path.join(allocator, &.{ parent, n_ }) catch null;
                                if (sub) |s| {
                                    defer allocator.free(s);
                                    log.info("new subdir watch: {s}", .{s});
                                    watchOneDir(self.inotify_fd, lib_id, s,
                                        &wd_lib, &wd_path, &lib_wds, allocator);
                                }
                            }
                        }
                    }
                    continue; // directory events don't need further processing
                }

                // Only process named, non-directory events for .png files.
                const filename = name orelse continue;
                if (!std.mem.endsWith(u8, filename, ".png")) continue;

                const parent = wd_path.get(wd) orelse continue;
                const lib_id = wd_lib.get(wd) orelse continue;

                const full_path = std.fs.path.join(allocator, &.{ parent, filename }) catch continue;
                const deleted = mask & MASK_DELETE != 0;

                log.info("file event: {s} deleted={}", .{ full_path, deleted });
                self.pushEvent(.{ .library_id = lib_id, .path = full_path, .deleted = deleted });
            }
        }
    }

    log.info("watcher thread stopped", .{});
}

// ── Watch helpers ─────────────────────────────────────────────────────────────

/// Recursively watch `root_path` and all of its subdirectories using BFS.
fn watchAllSubdirs(
    inotify_fd: i32,
    library_id: u64,
    root_path: []const u8,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    allocator: std.mem.Allocator,
) void {
    // BFS queue of paths to visit.  Each entry is an allocator-owned slice.
    var queue: std.ArrayList([]u8) = .empty;
    defer {
        // Free any paths remaining in the queue (those beyond `head`).
        for (queue.items) |p| allocator.free(p);
        queue.deinit(allocator);
    }

    const root_dupe = allocator.dupe(u8, root_path) catch return;
    queue.append(allocator, root_dupe) catch {
        allocator.free(root_dupe);
        return;
    };

    var head: usize = 0;
    while (head < queue.items.len) {
        const current = queue.items[head];
        head += 1;

        // Watch this directory.
        watchOneDir(inotify_fd, library_id, current, wd_lib, wd_path, lib_wds, allocator);

        // Open the directory to enumerate subdirectories.
        const path_z = allocator.dupeZ(u8, current) catch {
            allocator.free(current);
            continue;
        };
        defer allocator.free(path_z);

        const fd_rc = linux.open(path_z, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (@as(isize, @bitCast(fd_rc)) < 0) {
            allocator.free(current);
            continue;
        }
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);

        var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const n = linux.getdents64(fd, &buf, buf.len);
            if (@as(isize, @bitCast(n)) <= 0) break;
            var offset: usize = 0;
            while (offset < @as(usize, @intCast(n))) {
                const entry: *const linux.dirent64 = @ptrCast(@alignCast(&buf[offset]));
                offset += entry.reclen;
                if (entry.type != linux.DT.DIR) continue;
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const sub = std.fs.path.join(allocator, &.{ current, name }) catch continue;
                queue.append(allocator, sub) catch {
                    allocator.free(sub);
                    continue;
                };
            }
        }

        allocator.free(current);
    }

    // Clear the slice so the deferred free-loop above doesn't double-free.
    queue.clearRetainingCapacity();
}

fn watchOneDir(
    inotify_fd: i32,
    library_id: u64,
    path: []const u8,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    allocator: std.mem.Allocator,
) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const wd_rc = linux.inotify_add_watch(inotify_fd, path_z, WATCH_MASK);
    if (@as(isize, @bitCast(wd_rc)) < 0) {
        log.warn("inotify_add_watch({s}) failed: errno={d}", .{ path, -@as(isize, @bitCast(wd_rc)) });
        return;
    }
    const wd: i32 = @intCast(wd_rc);
    log.debug("watching {s} (wd={})", .{ path, wd });

    if (wd_lib.contains(wd)) return; // already watched

    const path_owned = allocator.dupe(u8, path) catch return;
    wd_lib.put(wd, library_id) catch { allocator.free(path_owned); return; };
    wd_path.put(wd, path_owned) catch {
        _ = wd_lib.remove(wd);
        allocator.free(path_owned);
        return;
    };

    const gop = lib_wds.getOrPut(library_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    gop.value_ptr.append(allocator, wd) catch {};
}

fn removeWatches(
    inotify_fd: i32,
    library_id: u64,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    allocator: std.mem.Allocator,
) void {
    const entry = lib_wds.fetchRemove(library_id) orelse return;
    var wds = entry.value;
    for (wds.items) |wd| {
        _ = linux.inotify_rm_watch(inotify_fd, wd);
        _ = wd_lib.remove(wd);
        if (wd_path.fetchRemove(wd)) |kv| allocator.free(kv.value);
    }
    wds.deinit(allocator);
    log.info("library {}: all watches removed", .{library_id});
}
