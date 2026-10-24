/// inotify-based file system watcher (Linux only).
///
/// Watches each library's root directory recursively.  inotify is per-directory,
/// so the watch set has to be kept in step with the tree by hand: new and moved
/// subdirectories get watches of their own, a renamed directory has the path
/// stored for its watch refreshed (the watch descriptor does not change), and a
/// directory moved out of a library has its watches dropped.
///
/// Callers receive DirtyEvent values.  Most name a single media file to
/// process, with no library rescan needed.  Directory moves are the exception:
/// inotify says nothing about the files such a directory contains, so those
/// raise a `.rescan_library` event instead.
const std = @import("std");
const linux = std.os.linux;
const media = @import("media.zig");
const log = std.log.scoped(.fs_watch);

/// Events that indicate a file is ready to read (fully written).
const MASK_MODIFY: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO;
/// Events that indicate a file has been removed.
const MASK_DELETE: u32 = linux.IN.DELETE | linux.IN.MOVED_FROM;
/// Events that indicate a new subdirectory appeared.
const MASK_NEW_DIR: u32 = linux.IN.CREATE | linux.IN.MOVED_TO;

const WATCH_MASK: u32 = MASK_MODIFY | MASK_DELETE | linux.IN.CREATE |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

const Spinlock = @import("spinlock.zig").Spinlock;

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
    /// The changed file for `.file`, the library root for `.rescan_library`.
    path: []u8,
    deleted: bool,
    kind: Kind = .file,

    pub const Kind = enum {
        /// One file changed or disappeared.
        file,
        /// A directory moved into, out of, or within the library.  inotify says
        /// nothing about the files such a directory contains, so the library has
        /// to be reconciled by a scan.
        rescan_library,
    };
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

    /// Ask the app to reconcile a whole library with a scan.  Deduplicated by
    /// path on the app side, so a burst of directory moves costs one scan.
    fn pushRescan(self: *FsWatcher, library_id: u64, library_path: []const u8) void {
        const path = self.allocator.dupe(u8, library_path) catch return;
        log.info("rescan requested for library {} ({s})", .{ library_id, library_path });
        self.pushEvent(.{
            .library_id = library_id,
            .path = path,
            .deleted = false,
            .kind = .rescan_library,
        });
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

    // Library root paths, so a rescan request can name the library to scan.
    var lib_root = std.AutoHashMap(u64, []u8).init(allocator);
    defer {
        var it = lib_root.valueIterator();
        while (it.next()) |p| allocator.free(p.*);
        lib_root.deinit();
    }

    // Directories that left a watched parent and have not (yet) turned up under
    // another one.  See finalizePendingMoves.
    var pending_moves: std.ArrayList(PendingMove) = .empty;
    defer {
        for (pending_moves.items) |pm| allocator.free(pm.path);
        pending_moves.deinit(allocator);
    }

    // Watches we dropped ourselves and whose IN_IGNORED is still in flight.
    var self_ignored: std.ArrayList(i32) = .empty;
    defer self_ignored.deinit(allocator);

    log.info("watcher thread started", .{});

    var pollfds = [2]linux.pollfd{
        .{ .fd = self.inotify_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = self.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };

    var generation: u64 = 0;

    outer: while (true) {
        // A pending move has to be given one more poll round to be matched with
        // its MOVED_TO, so don't block indefinitely while one is outstanding.
        const timeout: i32 = if (pending_moves.items.len > 0) MOVE_GRACE_MS else -1;
        _ = linux.poll(@ptrCast(&pollfds), 2, timeout);
        generation += 1;

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
                            _ = watchAllSubdirs(self.inotify_fd, a.library_id, a.path,
                                &wd_lib, &wd_path, &lib_wds, allocator);
                            log.info("library {} path={s}: {} watch(es) added",
                                .{ a.library_id, a.path, wd_lib.count() - before });
                            if (allocator.dupe(u8, a.path)) |root| {
                                if (lib_root.fetchPut(a.library_id, root)) |replaced| {
                                    if (replaced) |kv| allocator.free(kv.value);
                                } else |_| allocator.free(root);
                            } else |_| {}
                        }
                        allocator.free(a.path);
                    },
                    .remove => |r| {
                        if (!stop_requested) {
                            removeWatches(self.inotify_fd, r.library_id,
                                &wd_lib, &wd_path, &lib_wds, &self_ignored, allocator);
                            if (lib_root.fetchRemove(r.library_id)) |kv| allocator.free(kv.value);
                        }
                    },
                }
            }
            local.deinit(allocator);
            if (stop_requested) break :outer;
        }

        // ── inotify events ───────────────────────────────────────────────────
        if (pollfds[0].revents & linux.POLL.IN != 0) read_events: {
            var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
            const n = linux.read(self.inotify_fd, &buf, buf.len);
            if (@as(isize, @bitCast(n)) <= 0) break :read_events;

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= n) {
                const event: *const linux.inotify_event =
                    @ptrCast(@alignCast(&buf[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;

                const mask = event.mask;
                const wd = event.wd;
                const name = event.getName();

                if (mask & linux.IN.IGNORED != 0) {
                    // A watch we dropped ourselves.  Its bookkeeping is already
                    // gone and the kernel may have handed the wd number to a
                    // different directory since, so leave the maps alone.
                    if (takeSelfIgnored(&self_ignored, wd)) continue;
                    forgetWatch(wd, &wd_lib, &wd_path, &lib_wds, allocator);
                    continue;
                }

                if (mask & linux.IN.ISDIR != 0) {
                    handleDirEvent(self, event, &wd_lib, &wd_path, &lib_wds,
                        &lib_root, &pending_moves, generation, allocator);
                    continue; // directory events never describe a single file
                }

                // Only process named, non-directory events for supported media.
                const filename = name orelse continue;
                if (!media.isSupportedMediaFile(filename)) continue;

                const deleted = mask & MASK_DELETE != 0;

                // Act only on fully-written files (CLOSE_WRITE / MOVED_TO) or
                // removals. A bare IN.CREATE fires the instant the file appears,
                // before the writer has finished, so the PNG is still truncated
                // and would fail to parse with EndOfStream. The matching
                // CLOSE_WRITE arrives once writing completes and we handle it
                // then. (IN.CREATE is watched only to detect new subdirectories.)
                if (!deleted and mask & MASK_MODIFY == 0) continue;

                const parent = wd_path.get(wd) orelse continue;
                const lib_id = wd_lib.get(wd) orelse continue;

                const full_path = std.Io.Dir.path.join(allocator, &.{ parent, filename }) catch continue;

                log.info("file event: {s} deleted={}", .{ full_path, deleted });
                self.pushEvent(.{ .library_id = lib_id, .path = full_path, .deleted = deleted });
            }
        }

        // Any move that is still unmatched after a full extra round took the
        // directory out of the library for good.
        finalizePendingMoves(self.inotify_fd, generation, &pending_moves,
            &wd_lib, &wd_path, &lib_wds, &self_ignored, allocator);
    }

    log.info("watcher thread stopped", .{});
}

/// A directory that disappeared from a watched parent (IN_MOVED_FROM).  The
/// matching IN_MOVED_TO tells us it only moved elsewhere inside the library; if
/// none arrives, it left the library and its watches must go.
const PendingMove = struct {
    cookie: u32,
    /// Heap-allocated path the directory had before the move.
    path: []u8,
    /// Poll round the move was seen in.
    generation: u64,
};

/// How long to wait for the IN_MOVED_TO half of a rename.  Both halves are
/// queued by the same rename(2), so they normally arrive in one read; this only
/// covers a read that split them.
const MOVE_GRACE_MS: i32 = 50;

/// Handle one IN_ISDIR event: keep the watch set in step with the tree, and ask
/// for a library rescan whenever files may have appeared or vanished without
/// individual events of their own.
fn handleDirEvent(
    self: *FsWatcher,
    event: *const linux.inotify_event,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    lib_root: *std.AutoHashMap(u64, []u8),
    pending_moves: *std.ArrayList(PendingMove),
    generation: u64,
    allocator: std.mem.Allocator,
) void {
    const child = event.getName() orelse return;
    const parent = wd_path.get(event.wd) orelse return;
    const lib_id = wd_lib.get(event.wd) orelse return;
    const root = lib_root.get(lib_id) orelse return;

    const sub = std.Io.Dir.path.join(allocator, &.{ parent, child }) catch return;
    var sub_owned = true;
    defer if (sub_owned) allocator.free(sub);

    if (event.mask & MASK_NEW_DIR != 0) {
        log.info("new subdir watch: {s}", .{sub});
        const has_media = watchAllSubdirs(self.inotify_fd, lib_id, sub,
            wd_lib, wd_path, lib_wds, allocator);

        if (event.mask & linux.IN.MOVED_TO != 0) {
            // Moved in from somewhere.  Whatever it holds arrived without any
            // per-file event, and if it came from elsewhere in this library the
            // stored paths of those files are now wrong.
            resolvePendingMove(pending_moves, event.cookie, allocator);
            self.pushRescan(lib_id, root);
        } else if (has_media) {
            // Created, and already holds media: those files landed in the gap
            // between the directory appearing and the watch being set up, so
            // nothing will report them.
            self.pushRescan(lib_id, root);
        }
        return;
    }

    if (event.mask & linux.IN.MOVED_FROM != 0) {
        pending_moves.append(allocator, .{
            .cookie = event.cookie,
            .path = sub,
            .generation = generation,
        }) catch return;
        sub_owned = false;
        // Files under the old path are gone from where the DB expects them,
        // whether the directory left the library or just moved within it.
        self.pushRescan(lib_id, root);
    }
    // IN_DELETE of a directory needs nothing: its contents each raised their own
    // delete event, and its watch is dropped by the IN_IGNORED that follows.
}

/// Discard the pending move with this cookie — its directory turned up again
/// under a watched parent, so it never left the library.
fn resolvePendingMove(
    pending_moves: *std.ArrayList(PendingMove),
    cookie: u32,
    allocator: std.mem.Allocator,
) void {
    for (pending_moves.items, 0..) |pm, i| {
        if (pm.cookie != cookie) continue;
        allocator.free(pm.path);
        _ = pending_moves.orderedRemove(i);
        return;
    }
}

/// Drop the watches of every directory that has been moved out of its library.
fn finalizePendingMoves(
    inotify_fd: i32,
    generation: u64,
    pending_moves: *std.ArrayList(PendingMove),
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    self_ignored: *std.ArrayList(i32),
    allocator: std.mem.Allocator,
) void {
    var i: usize = 0;
    while (i < pending_moves.items.len) {
        const pm = pending_moves.items[i];
        if (pm.generation >= generation) {
            i += 1; // seen this round; it may still be matched
            continue;
        }
        _ = pending_moves.orderedRemove(i);
        log.info("directory left the library: {s}", .{pm.path});
        removeSubtreeWatches(inotify_fd, pm.path, wd_lib, wd_path, lib_wds, self_ignored, allocator);
        allocator.free(pm.path);
    }
}

/// Remove the watch on `root` and on every directory below it.
fn removeSubtreeWatches(
    inotify_fd: i32,
    root: []const u8,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    self_ignored: *std.ArrayList(i32),
    allocator: std.mem.Allocator,
) void {
    var doomed: std.ArrayList(i32) = .empty;
    defer doomed.deinit(allocator);

    var it = wd_path.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr.*;
        if (!std.mem.startsWith(u8, p, root)) continue;
        if (p.len != root.len and p[root.len] != std.Io.Dir.path.sep) continue;
        doomed.append(allocator, entry.key_ptr.*) catch {};
    }

    for (doomed.items) |wd| {
        _ = linux.inotify_rm_watch(inotify_fd, wd);
        self_ignored.append(allocator, wd) catch {};
        forgetWatch(wd, wd_lib, wd_path, lib_wds, allocator);
    }
}

/// True if `wd` was removed by us, consuming the record of it.
fn takeSelfIgnored(self_ignored: *std.ArrayList(i32), wd: i32) bool {
    for (self_ignored.items, 0..) |w, i| {
        if (w != wd) continue;
        _ = self_ignored.orderedRemove(i); // oldest first: IN_IGNORED arrives in order
        return true;
    }
    return false;
}

// ── Watch helpers ─────────────────────────────────────────────────────────────

/// Recursively watch `root_path` and all of its subdirectories using BFS.
/// Returns true if the subtree already contains at least one media file.
fn watchAllSubdirs(
    inotify_fd: i32,
    library_id: u64,
    root_path: []const u8,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    allocator: std.mem.Allocator,
) bool {
    var has_media = false;

    // BFS queue of paths to visit.  Each entry is an allocator-owned slice.
    var queue: std.ArrayList([]u8) = .empty;
    defer {
        // Free any paths remaining in the queue (those beyond `head`).
        for (queue.items) |p| allocator.free(p);
        queue.deinit(allocator);
    }

    const root_dupe = allocator.dupe(u8, root_path) catch return false;
    queue.append(allocator, root_dupe) catch {
        allocator.free(root_dupe);
        return false;
    };

    var head: usize = 0;
    while (head < queue.items.len) {
        const current = queue.items[head];
        head += 1;

        // Watch this directory.
        watchOneDir(inotify_fd, library_id, current, wd_lib, wd_path, lib_wds, allocator);

        // Open the directory to enumerate subdirectories.
        const path_z = allocator.dupeSentinel(u8, current, 0) catch {
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
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (entry.type != linux.DT.DIR) {
                    if (!has_media and entry.type == linux.DT.REG and
                        media.isSupportedMediaFile(name)) has_media = true;
                    continue;
                }
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const sub = std.Io.Dir.path.join(allocator, &.{ current, name }) catch continue;
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
    return has_media;
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
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(path_z);

    const wd_rc = linux.inotify_add_watch(inotify_fd, path_z, WATCH_MASK);
    if (@as(isize, @bitCast(wd_rc)) < 0) {
        const errno = -@as(isize, @bitCast(wd_rc));
        // ENOENT just means the directory went away again before we got to it
        // (created then immediately renamed or deleted) — not worth a warning.
        if (errno == @backingInt(linux.E.NOENT)) {
            log.debug("inotify_add_watch({s}): directory no longer exists", .{path});
        } else {
            log.warn("inotify_add_watch({s}) failed: errno={d}", .{ path, errno });
        }
        return;
    }
    const wd: i32 = @intCast(wd_rc);

    // inotify identifies a watch by inode, so re-watching a directory returns
    // the wd it already has.  After a rename that wd is still valid but the
    // path we stored for it is not, so refresh it rather than keeping the old
    // one — otherwise every file event in the directory is reported under its
    // former name and the file can't be found on disk.
    if (wd_path.getPtr(wd)) |slot| {
        if (!std.mem.eql(u8, slot.*, path)) {
            const renamed = allocator.dupe(u8, path) catch return;
            log.debug("watch wd={} re-pathed: {s} -> {s}", .{ wd, slot.*, path });
            allocator.free(slot.*);
            slot.* = renamed;
        }
        // The move may also have crossed from one library into another; the
        // events it produces belong to the library it lives in now.
        const owner = wd_lib.get(wd);
        if (owner == null or owner.? != library_id) {
            if (owner) |old| detachWd(lib_wds, old, wd);
            wd_lib.put(wd, library_id) catch return;
            attachWd(lib_wds, library_id, wd, allocator);
        }
        return;
    }
    log.debug("watching {s} (wd={})", .{ path, wd });

    const path_owned = allocator.dupe(u8, path) catch return;
    wd_lib.put(wd, library_id) catch { allocator.free(path_owned); return; };
    wd_path.put(wd, path_owned) catch {
        _ = wd_lib.remove(wd);
        allocator.free(path_owned);
        return;
    };
    attachWd(lib_wds, library_id, wd, allocator);
}

fn attachWd(
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    library_id: u64,
    wd: i32,
    allocator: std.mem.Allocator,
) void {
    const gop = lib_wds.getOrPut(library_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    gop.value_ptr.append(allocator, wd) catch {};
}

fn detachWd(lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)), library_id: u64, wd: i32) void {
    const wds = lib_wds.getPtr(library_id) orelse return;
    for (wds.items, 0..) |w, i| {
        if (w != wd) continue;
        _ = wds.swapRemove(i);
        return;
    }
}

/// Drop all bookkeeping for a watch the kernel has discarded (IN_IGNORED).
/// The wd number can be handed out again for a different directory, so it must
/// not be left behind in the library's list.
fn forgetWatch(
    wd: i32,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    allocator: std.mem.Allocator,
) void {
    if (wd_path.fetchRemove(wd)) |kv| allocator.free(kv.value);
    if (wd_lib.fetchRemove(wd)) |kv| detachWd(lib_wds, kv.value, wd);
}

fn removeWatches(
    inotify_fd: i32,
    library_id: u64,
    wd_lib: *std.AutoHashMap(i32, u64),
    wd_path: *std.AutoHashMap(i32, []u8),
    lib_wds: *std.AutoHashMap(u64, std.ArrayList(i32)),
    self_ignored: *std.ArrayList(i32),
    allocator: std.mem.Allocator,
) void {
    const entry = lib_wds.fetchRemove(library_id) orelse return;
    var wds = entry.value;
    for (wds.items) |wd| {
        _ = linux.inotify_rm_watch(inotify_fd, wd);
        self_ignored.append(allocator, wd) catch {};
        _ = wd_lib.remove(wd);
        if (wd_path.fetchRemove(wd)) |kv| allocator.free(kv.value);
    }
    wds.deinit(allocator);
    log.info("library {}: all watches removed", .{library_id});
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The three watch maps the watcher thread keeps, for tests that drive the
/// watch helpers directly.
const TestMaps = struct {
    wd_lib: std.AutoHashMap(i32, u64),
    wd_path: std.AutoHashMap(i32, []u8),
    lib_wds: std.AutoHashMap(u64, std.ArrayList(i32)),

    fn init() TestMaps {
        const allocator = testing.allocator;
        return .{
            .wd_lib = std.AutoHashMap(i32, u64).init(allocator),
            .wd_path = std.AutoHashMap(i32, []u8).init(allocator),
            .lib_wds = std.AutoHashMap(u64, std.ArrayList(i32)).init(allocator),
        };
    }

    fn deinit(self: *TestMaps) void {
        const allocator = testing.allocator;
        self.wd_lib.deinit();
        var pit = self.wd_path.valueIterator();
        while (pit.next()) |p| allocator.free(p.*);
        self.wd_path.deinit();
        var wit = self.lib_wds.valueIterator();
        while (wit.next()) |wds| wds.deinit(allocator);
        self.lib_wds.deinit();
    }

    fn watch(self: *TestMaps, fd: i32, library_id: u64, path: []const u8) bool {
        return watchAllSubdirs(fd, library_id, path,
            &self.wd_lib, &self.wd_path, &self.lib_wds, testing.allocator);
    }

    fn hasPath(self: *TestMaps, path: []const u8) bool {
        var it = self.wd_path.valueIterator();
        while (it.next()) |p| if (std.mem.eql(u8, p.*, path)) return true;
        return false;
    }
};

/// Recreate `path` empty.
fn testMakeTree(path: []const u8) !void {
    const io = testing.io;
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn testInotifyFd() !i32 {
    const rc = linux.inotify_init1(linux.IN.CLOEXEC);
    if (@as(isize, @bitCast(rc)) < 0) return error.InotifyInit;
    return @intCast(rc);
}

test "fs_watch: re-watching a renamed directory refreshes its stored path" {
    const io = testing.io;

    const root = "/tmp/diffkeep_test_fswatch_repath";
    const before = root ++ "/before";
    const after = root ++ "/after";
    try testMakeTree(before);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const ifd = try testInotifyFd();
    defer _ = linux.close(ifd);

    var maps = TestMaps.init();
    defer maps.deinit();

    _ = maps.watch(ifd, 7, root);
    try testing.expectEqual(@as(u32, 2), maps.wd_path.count()); // root + before

    // The rename keeps the inode, so inotify hands back the same wd.
    try std.Io.Dir.renameAbsolute(before, after, io);
    _ = maps.watch(ifd, 7, after);

    try testing.expectEqual(@as(u32, 2), maps.wd_path.count()); // no extra watch
    try testing.expectEqual(@as(usize, 2), maps.lib_wds.get(7).?.items.len);
    try testing.expect(!maps.hasPath(before)); // stale path is gone
    try testing.expect(maps.hasPath(after));
}

test "fs_watch: watching a subtree reports whether it already holds media" {
    const io = testing.io;

    const root = "/tmp/diffkeep_test_fswatch_media";
    const empty = root ++ "/empty";
    const nested = root ++ "/outer/inner";
    try testMakeTree(empty);
    try std.Io.Dir.cwd().createDirPath(io, nested);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const ifd = try testInotifyFd();
    defer _ = linux.close(ifd);

    var maps = TestMaps.init();
    defer maps.deinit();

    try testing.expect(!maps.watch(ifd, 7, empty));
    // Notes and the like don't count — only files the scanner would index.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nested ++ "/readme.txt", .data = "x" });
    try testing.expect(!maps.watch(ifd, 7, root ++ "/outer"));
    // A media file anywhere below the directory does.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nested ++ "/a.png", .data = "x" });
    try testing.expect(maps.watch(ifd, 7, root ++ "/outer"));
}

test "fs_watch: removing a subtree's watches drops only that subtree" {
    const io = testing.io;

    const root = "/tmp/diffkeep_test_fswatch_subtree";
    const keep = root ++ "/keep";
    const drop = root ++ "/drop";
    const drop_child = drop ++ "/child";
    const decoy = root ++ "/dropped"; // shares a prefix with `drop`
    try testMakeTree(root);
    for ([_][]const u8{ keep, drop_child, decoy }) |p|
        try std.Io.Dir.cwd().createDirPath(io, p);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const ifd = try testInotifyFd();
    defer _ = linux.close(ifd);

    var maps = TestMaps.init();
    defer maps.deinit();
    _ = maps.watch(ifd, 7, root);
    try testing.expectEqual(@as(u32, 5), maps.wd_path.count());

    var self_ignored: std.ArrayList(i32) = .empty;
    defer self_ignored.deinit(testing.allocator);
    removeSubtreeWatches(ifd, drop, &maps.wd_lib, &maps.wd_path, &maps.lib_wds,
        &self_ignored, testing.allocator);

    try testing.expect(!maps.hasPath(drop));
    try testing.expect(!maps.hasPath(drop_child));
    try testing.expect(maps.hasPath(keep));
    try testing.expect(maps.hasPath(decoy)); // prefix match must respect path separators
    try testing.expectEqual(@as(u32, 3), maps.wd_path.count());
    try testing.expectEqual(@as(usize, 3), maps.lib_wds.get(7).?.items.len);
    try testing.expectEqual(@as(usize, 2), self_ignored.items.len);
}

// ── End-to-end tests (real watcher thread) ───────────────────────────────────

const TEST_LIB_ID: u64 = 7;

/// A running watcher plus every event drained from it so far.  Draining is
/// destructive, so tests that look for more than one event must collect.
const TestWatcher = struct {
    watcher: FsWatcher,
    events: std.ArrayList(DirtyEvent) = .empty,

    fn start(self: *TestWatcher, root: []const u8) !void {
        self.watcher = try FsWatcher.init(testing.allocator);
        try self.watcher.start();
        try self.watcher.addLibrary(TEST_LIB_ID, root);
    }

    fn deinit(self: *TestWatcher) void {
        self.watcher.deinit();
        for (self.events.items) |ev| testing.allocator.free(ev.path);
        self.events.deinit(testing.allocator);
    }

    /// Forget everything drained so far, so a later assertion can only be
    /// satisfied by events the next step produces.
    fn clear(self: *TestWatcher) void {
        self.sleepATick();
        self.collect();
        for (self.events.items) |ev| testing.allocator.free(ev.path);
        self.events.clearRetainingCapacity();
    }

    fn collect(self: *TestWatcher) void {
        var drained = self.watcher.drainEvents();
        defer drained.deinit(testing.allocator);
        self.events.appendSlice(testing.allocator, drained.items) catch {};
    }

    fn sleepATick(_: *TestWatcher) void {
        std.Io.sleep(testing.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .real) catch {};
    }

    fn fileEvent(self: *TestWatcher, path: []const u8) ?DirtyEvent {
        for (self.events.items) |ev| {
            if (ev.kind == .file and std.mem.eql(u8, ev.path, path)) return ev;
        }
        return null;
    }

    /// Any file event for a file of this name, whatever path it was reported
    /// under — a watch left behind on a directory that is gone reports events
    /// under its old path, and that counts as reporting.
    fn sawFileNamed(self: *TestWatcher, name: []const u8) bool {
        for (self.events.items) |ev| {
            if (ev.kind == .file and std.mem.eql(u8, std.Io.Dir.path.basename(ev.path), name))
                return true;
        }
        return false;
    }

    fn sawRescan(self: *TestWatcher, root: []const u8) bool {
        for (self.events.items) |ev| {
            if (ev.kind == .rescan_library and std.mem.eql(u8, ev.path, root)) return true;
        }
        return false;
    }

    /// Write `dir/name` until the watcher reports it, so the caller knows the
    /// directory is really being watched rather than guessing at a delay.
    /// Returns the reported event, or null after ~5s.
    fn waitForFile(self: *TestWatcher, dir: std.Io.Dir, dir_path: []const u8, name: []const u8) !?DirtyEvent {
        const full = try std.Io.Dir.path.join(testing.allocator, &.{ dir_path, name });
        defer testing.allocator.free(full);
        var attempt: usize = 0;
        while (attempt < 250) : (attempt += 1) {
            try dir.writeFile(testing.io, .{ .sub_path = name, .data = "not really a png" });
            self.sleepATick();
            self.collect();
            if (self.fileEvent(full)) |ev| return ev;
        }
        return null;
    }

    /// Wait for a rescan request naming `root` (~2s).
    fn waitForRescan(self: *TestWatcher, root: []const u8) bool {
        var attempt: usize = 0;
        while (attempt < 100) : (attempt += 1) {
            self.collect();
            if (self.sawRescan(root)) return true;
            self.sleepATick();
        }
        return false;
    }
};

test "fs_watch: file events in a renamed directory carry the new path" {
    const io = testing.io;

    const root = "/tmp/diffkeep_test_fswatch_events";
    const before = root ++ "/before";
    const after = root ++ "/after";
    try testMakeTree(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var tw: TestWatcher = .{ .watcher = undefined };
    try tw.start(root);
    defer tw.deinit();

    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);

    // Wait until the root watch is live: write a probe file until it is seen.
    // Without this the watcher could process the library only after the rename
    // below, which would hide a stale-path bug instead of exposing it.
    try testing.expect(try tw.waitForFile(root_dir, root, "probe.png") != null);

    try root_dir.createDirPath(io, "before");
    {
        // Likewise, the subdirectory must actually be watched under its
        // original name before the rename — that is the case where inotify
        // hands back the wd it already has and the stored path goes stale.
        var before_dir = try std.Io.Dir.openDirAbsolute(io, before, .{});
        defer before_dir.close(io);
        try testing.expect(try tw.waitForFile(before_dir, before, "probe.png") != null);
        try before_dir.deleteFile(io, "probe.png");
    }

    tw.clear(); // only events caused by the rename itself count from here
    try std.Io.Dir.renameAbsolute(before, after, io);

    var after_dir = try std.Io.Dir.openDirAbsolute(io, after, .{});
    defer after_dir.close(io);
    const ev = try tw.waitForFile(after_dir, after, "img.png");
    try testing.expect(ev != null);

    // The rename moved files the DB knows by their old path, so the library
    // also has to be reconciled.
    try testing.expect(tw.sawRescan(root));
}

test "fs_watch: a directory moved into a library is watched and triggers a rescan" {
    const io = testing.io;

    const base = "/tmp/diffkeep_test_fswatch_movein";
    const root = base ++ "/library";
    const staging = base ++ "/staging";
    const moved = root ++ "/staging";
    try testMakeTree(base);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().createDirPath(io, staging ++ "/nested");
    // Prepared outside the library, so its contents never raise events of
    // their own once it lands inside.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging ++ "/nested/old.png", .data = "x" });
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var tw: TestWatcher = .{ .watcher = undefined };
    try tw.start(root);
    defer tw.deinit();

    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    try testing.expect(try tw.waitForFile(root_dir, root, "probe.png") != null);

    try std.Io.Dir.renameAbsolute(staging, moved, io);

    // The files it brought with it are only discoverable by a scan.
    try testing.expect(tw.waitForRescan(root));

    // Its subdirectories are watched too, so later writes are picked up.
    const nested = moved ++ "/nested";
    var nested_dir = try std.Io.Dir.openDirAbsolute(io, nested, .{});
    defer nested_dir.close(io);
    try testing.expect(try tw.waitForFile(nested_dir, nested, "new.png") != null);
}

test "fs_watch: a directory moved between libraries changes hands" {
    const io = testing.io;

    const base = "/tmp/diffkeep_test_fswatch_crosslib";
    const lib_a = base ++ "/a";
    const lib_b = base ++ "/b";
    const in_a = lib_a ++ "/sub";
    const in_b = lib_b ++ "/sub";
    try testMakeTree(base);
    try std.Io.Dir.cwd().createDirPath(io, in_a);
    try std.Io.Dir.cwd().createDirPath(io, lib_b);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const other_lib: u64 = TEST_LIB_ID + 1;
    var tw: TestWatcher = .{ .watcher = undefined };
    try tw.start(lib_a);
    defer tw.deinit();
    try tw.watcher.addLibrary(other_lib, lib_b);

    {
        var in_a_dir = try std.Io.Dir.openDirAbsolute(io, in_a, .{});
        defer in_a_dir.close(io);
        const ev = try tw.waitForFile(in_a_dir, in_a, "probe.png");
        try testing.expect(ev != null);
        try testing.expectEqual(TEST_LIB_ID, ev.?.library_id);
        try in_a_dir.deleteFile(io, "probe.png");
    }

    try std.Io.Dir.renameAbsolute(in_a, in_b, io);

    var in_b_dir = try std.Io.Dir.openDirAbsolute(io, in_b, .{});
    defer in_b_dir.close(io);
    const ev = try tw.waitForFile(in_b_dir, in_b, "img.png");
    try testing.expect(ev != null);
    // Its watch survived the move, so it has to answer to its new library now.
    try testing.expectEqual(other_lib, ev.?.library_id);
    try testing.expect(tw.sawRescan(lib_a));
    try testing.expect(tw.sawRescan(lib_b));
}

test "fs_watch: a directory moved out of a library is unwatched and triggers a rescan" {
    const io = testing.io;

    const base = "/tmp/diffkeep_test_fswatch_moveout";
    const root = base ++ "/library";
    const inside = root ++ "/sub";
    const outside = base ++ "/sub";
    try testMakeTree(base);
    try std.Io.Dir.cwd().createDirPath(io, inside);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var tw: TestWatcher = .{ .watcher = undefined };
    try tw.start(root);
    defer tw.deinit();

    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    {
        var inside_dir = try std.Io.Dir.openDirAbsolute(io, inside, .{});
        defer inside_dir.close(io);
        try testing.expect(try tw.waitForFile(inside_dir, inside, "probe.png") != null);
        try inside_dir.deleteFile(io, "probe.png");
    }

    try std.Io.Dir.renameAbsolute(inside, outside, io);
    try testing.expect(tw.waitForRescan(root));

    // Give the unmatched move its grace period, then confirm the directory is
    // no longer reported on: it is not part of the library any more.
    var waited: usize = 0;
    while (waited < 15) : (waited += 1) tw.sleepATick(); // ~300ms, 6x MOVE_GRACE_MS

    var outside_dir = try std.Io.Dir.openDirAbsolute(io, outside, .{});
    defer outside_dir.close(io);
    try outside_dir.writeFile(io, .{ .sub_path = "stray.png", .data = "x" });
    waited = 0;
    while (waited < 10) : (waited += 1) tw.sleepATick();
    tw.collect();
    try testing.expect(!tw.sawFileNamed("stray.png"));

    // ...and that the watcher is still reporting on the library itself, so the
    // check above isn't passing because everything went quiet.
    try testing.expect(try tw.waitForFile(root_dir, root, "still_here.png") != null);
}
