const std = @import("std");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const config_mod = @import("config.zig");

const log = std.log.scoped(.image_ops);

pub const AppCtx = struct {
    db: *?db_mod.VectorDb,
    data_dir: *?[]const u8,
    cfg: *const config_mod.Config,
    on_counts_changed: *const fn () void,
    /// Called after images are removed from the grid so open viewer windows can
    /// drop the same images without reopening.
    on_images_removed: *const fn (ids: *const std.AutoHashMap(u64, void)) void,
    /// Wakes the render loop (used to surface background bulk-op completion).
    on_wakeup: *const fn () void,
};

var g_ctx: ?AppCtx = null;

pub fn init(ctx: AppCtx) void {
    g_ctx = ctx;
}

/// Move `src` to `dst`, never replacing an existing `dst` (error.PathAlreadyExists).
/// Falls back to a streamed copy + delete across filesystems.
pub fn moveFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    // rename() silently replaces its target. The window between this check
    // and the rename is tiny; the copy path below is exclusive outright.
    if (cwd.access(io, dst, .{})) |_| return error.PathAlreadyExists else |_| {}
    std.Io.Dir.rename(cwd, src, cwd, dst, io) catch |err| switch (err) {
        error.CrossDevice => {
            try copyExclusive(io, src, dst);
            try cwd.deleteFile(io, src);
        },
        else => return err,
    };
}

/// Stream `src` into a newly created `dst` (fails if it exists), keeping the
/// modification time so the scanner doesn't see a changed file. A failed copy
/// removes the partial `dst`.
fn copyExclusive(io: std.Io, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var in = try cwd.openFile(io, src, .{});
    defer in.close(io);
    const stat = try in.stat(io);
    var out = try cwd.createFile(io, dst, .{ .exclusive = true });
    var ok = false;
    defer {
        out.close(io);
        if (!ok) cwd.deleteFile(io, dst) catch {};
    }
    var buf: [64 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try in.readPositional(io, &.{&buf}, off);
        if (n == 0) break;
        try out.writePositionalAll(io, buf[0..n], off);
        off += n;
    }
    try out.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } });
    ok = true;
}

/// First of `path`, `stem (1).ext`, `stem (2).ext`, … that is neither on disk
/// nor held by a live row. Caller frees.
fn freeRestorePath(io: std.Io, allocator: std.mem.Allocator, conn: *db_mod.VectorDb, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.path.dirname(path) orelse "";
    const base = std.Io.Dir.path.basename(path);
    const ext = std.Io.Dir.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    var n: usize = 0;
    while (n < 10_000) : (n += 1) {
        const candidate = if (n == 0)
            try allocator.dupe(u8, path)
        else blk: {
            const name = try allocator.print("{s} ({d}){s}", .{ stem, n, ext });
            defer allocator.free(name);
            break :blk try std.Io.Dir.path.join(allocator, &.{ dir, name });
        };
        const on_disk = if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| true else |_| false;
        if (!on_disk and !(try conn.livePathExists(candidate))) return candidate;
        allocator.free(candidate);
    }
    return error.PathAlreadyExists;
}

pub fn effectiveIds(grid: *const image_grid_mod.GridState, allocator: std.mem.Allocator) !std.AutoHashMap(u64, void) {
    var ids = std.AutoHashMap(u64, void).init(allocator);
    errdefer ids.deinit();
    if (grid.selection.count() > 0) {
        var it = grid.selection.keyIterator();
        while (it.next()) |id| try ids.put(id.*, {});
    } else if (grid.focused_idx) |fi| {
        if (fi < grid.images.items.len)
            try ids.put(grid.images.items[fi].id, {});
    }
    return ids;
}

pub fn removeFromGrid(grid: *image_grid_mod.GridState, ids: *const std.AutoHashMap(u64, void)) void {
    // A view load already running may still return these; keep them out.
    var it = ids.keyIterator();
    while (it.next()) |id| grid.noteRemoved(id.*);
    // One compaction pass: removing k of n images costs O(n), not O(n·k).
    const items = grid.images.items;
    var kept: usize = 0;
    for (items) |e| {
        if (ids.contains(e.id)) {
            _ = grid.selection.remove(e.id);
            // Drop the cached thumbnail: SQLite recycles this row's id for the
            // next inserted image, which would otherwise inherit this thumbnail.
            grid.invalidateThumbnail(e.id);
            grid.allocator.free(e.path);
            if (e.trash_name) |tn| grid.allocator.free(tn);
        } else {
            items[kept] = e;
            kept += 1;
        }
    }
    grid.images.shrinkRetainingCapacity(kept);
    if (grid.focused_idx) |fi| {
        if (grid.images.items.len == 0) grid.focused_idx = null
        else if (fi >= grid.images.items.len) grid.focused_idx = grid.images.items.len - 1;
    }
    // Indices into the old list no longer mean the same image.
    grid.anchor_idx = null;
}

// ── File operations (trash / delete / restore) ─────────────────────────────
//
// Moving or unlinking files can block (a cross-device trash move copies the
// whole file), so it never runs on the render thread. The perform* functions
// snapshot the affected entries into a job; one worker thread drains the job
// queue, and `fileOpsPoll` (called each frame) drops the images that actually
// succeeded from the grid and any open viewers.

/// `purge_expired`, `empty_trash` and `dedupe` work on the DB's own selection
/// rather than a list of grid items. Every kind runs on the one worker, so a
/// bulk operation can never race a single-image one over the same file.
pub const FileOpKind = enum { trash, delete, restore, purge_expired, empty_trash, dedupe };

fn isBulk(kind: FileOpKind) bool {
    return kind == .purge_expired or kind == .empty_trash or kind == .dedupe;
}

const JobItem = struct {
    id: u64,
    path: []const u8, // library path
    trash_name: ?[]const u8 = null,
};

const Job = struct {
    kind: FileOpKind,
    items: []JobItem,
    /// purge_expired only: trashed_at cutoff (unix seconds).
    cutoff: i64 = 0,
};

const FileOps = struct {
    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(Job) = .empty,
    /// Ids handed to a job and not yet applied; never queued twice.
    pending: std.AutoHashMap(u64, void) = undefined,
    pending_init: bool = false,
    /// Ids whose operation succeeded, waiting for `fileOpsPoll`.
    done: std.ArrayList(u64) = .empty,
    /// A purge finished: counts (and a trash view) need a refresh.
    purged: bool = false,
    /// Empty-trash / dedupe jobs queued or running (for the toolbar indicator).
    user_bulk: std.atomic.Value(u32) = .init(0),
    running: bool = false,
    thread: ?std.Thread = null,
};
var g_ops: FileOps = .{};

// Job data is shared across threads, so it lives on the thread-safe C heap.
const job_alloc = std.heap.c_allocator;

pub fn performTrash(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    enqueueFromGrid(io, allocator, grid, .trash);
}

pub fn performDelete(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    enqueueFromGrid(io, allocator, grid, .delete);
}

pub fn performRestore(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    enqueueFromGrid(io, allocator, grid, .restore);
}

/// Trash (or, for an entry already in the trash, permanently delete) one image
/// shown in a viewer window.
pub fn performOnEntry(io: std.Io, entry: image_grid_mod.ImageEntry, kind: FileOpKind) void {
    const items = job_alloc.alloc(JobItem, 1) catch return;
    items[0] = snapshot(entry) catch {
        job_alloc.free(items);
        return;
    };
    submit(io, .{ .kind = kind, .items = items });
}

/// Permanently delete every trashed image older than `cutoff` (unix seconds).
pub fn startPurgeExpiredTrash(io: std.Io, cutoff: i64) void {
    submit(io, .{ .kind = .purge_expired, .items = &.{}, .cutoff = cutoff });
}

fn enqueueFromGrid(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState, kind: FileOpKind) void {
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    var items: std.ArrayList(JobItem) = .empty;
    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;
        // Restore applies only to trashed entries.
        if (kind == .restore and entry.trash_name == null) continue;
        const item = snapshot(entry) catch continue;
        items.append(job_alloc, item) catch {
            freeItem(item);
            continue;
        };
    }
    const owned = items.toOwnedSlice(job_alloc) catch {
        for (items.items) |it| freeItem(it);
        items.deinit(job_alloc);
        return;
    };
    if (owned.len == 0) {
        job_alloc.free(owned);
        return;
    }
    submit(io, .{ .kind = kind, .items = owned });
}

fn snapshot(entry: image_grid_mod.ImageEntry) !JobItem {
    const path = try job_alloc.dupe(u8, entry.path);
    errdefer job_alloc.free(path);
    const tn = if (entry.trash_name) |t| try job_alloc.dupe(u8, t) else null;
    return .{ .id = entry.id, .path = path, .trash_name = tn };
}

fn freeItem(it: JobItem) void {
    job_alloc.free(it.path);
    if (it.trash_name) |t| job_alloc.free(t);
}

fn freeJob(job: Job) void {
    for (job.items) |it| freeItem(it);
    job_alloc.free(job.items);
}

/// Queue `job` (dropping ids already in flight) and make sure a worker runs.
fn submit(io: std.Io, job_in: Job) void {
    var job = job_in;
    g_ops.mutex.lockUncancelable(io);
    defer g_ops.mutex.unlock(io);
    if (!g_ops.pending_init) {
        g_ops.pending = .init(job_alloc);
        g_ops.pending_init = true;
    }
    // Drop items already being processed (e.g. Delete pressed twice).
    var kept: std.ArrayList(JobItem) = .empty;
    for (job_in.items) |it| {
        const fresh = !g_ops.pending.contains(it.id) and
            g_ops.pending.put(it.id, {}) != error.OutOfMemory;
        if (fresh and kept.append(job_alloc, it) != error.OutOfMemory) continue;
        if (fresh) _ = g_ops.pending.remove(it.id);
        freeItem(it);
    }
    job_alloc.free(job_in.items);
    job.items = kept.toOwnedSlice(job_alloc) catch {
        for (kept.items) |it| {
            _ = g_ops.pending.remove(it.id);
            freeItem(it);
        }
        kept.deinit(job_alloc);
        return;
    };
    if (job.items.len == 0 and !isBulk(job.kind)) return;
    // Asking for the same bulk operation again while one waits is a no-op.
    if (isBulk(job.kind)) for (g_ops.queue.items) |q| {
        if (q.kind == job.kind) {
            freeJob(job);
            return;
        }
    };
    g_ops.queue.append(job_alloc, job) catch {
        for (job.items) |it| _ = g_ops.pending.remove(it.id);
        freeJob(job);
        return;
    };
    if (job.kind == .empty_trash or job.kind == .dedupe) _ = g_ops.user_bulk.fetchAdd(1, .acq_rel);
    if (g_ops.running) return;
    // The previous worker has already marked itself done; reap it.
    if (g_ops.thread) |t| t.join();
    g_ops.thread = std.Thread.spawn(.{}, fileOpsWorker, .{io}) catch |err| blk: {
        log.warn("spawn file-op worker: {}", .{err});
        break :blk null;
    };
    g_ops.running = g_ops.thread != null;
}

fn fileOpsWorker(io: std.Io) void {
    while (true) {
        g_ops.mutex.lockUncancelable(io);
        if (g_ops.queue.items.len == 0) {
            g_ops.running = false;
            g_ops.mutex.unlock(io);
            return;
        }
        const job = g_ops.queue.orderedRemove(0);
        g_ops.mutex.unlock(io);

        var succeeded: std.ArrayList(u64) = .empty;
        defer succeeded.deinit(job_alloc);
        runJob(io, job, &succeeded);

        g_ops.mutex.lockUncancelable(io);
        g_ops.done.appendSlice(job_alloc, succeeded.items) catch {};
        if (job.kind == .purge_expired or job.kind == .empty_trash) g_ops.purged = true;
        if (job.kind == .empty_trash or job.kind == .dedupe) _ = g_ops.user_bulk.fetchSub(1, .acq_rel);
        // Failed items stay in the grid; let them be retried.
        for (job.items) |it| {
            if (std.mem.findScalar(u64, succeeded.items, it.id) == null) _ = g_ops.pending.remove(it.id);
        }
        g_ops.mutex.unlock(io);
        freeJob(job);
        if (g_ctx) |ctx| ctx.on_wakeup();
    }
}

fn runJob(io: std.Io, job: Job, succeeded: *std.ArrayList(u64)) void {
    const ctx = g_ctx orelse return;
    const data_dir = ctx.data_dir.* orelse return;
    const db_ptr = if (ctx.db.*) |*d| d else return;
    var conn = db_ptr.getConnection() catch |err| {
        log.warn("file op db connection: {}", .{err});
        return;
    };
    defer conn.deinit();

    switch (job.kind) {
        .trash => {
            const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
            for (job.items) |it| {
                if (trashOne(io, &conn, data_dir, it.id, it.path, now_s))
                    succeeded.append(job_alloc, it.id) catch {};
            }
        },
        .delete => for (job.items) |it| {
            const file_path = if (it.trash_name) |tn|
                std.Io.Dir.path.join(job_alloc, &.{ data_dir, "trash", tn }) catch continue
            else
                job_alloc.dupe(u8, it.path) catch continue;
            defer job_alloc.free(file_path);
            // Row first, matched on the path we saw: a stale entry (row gone or
            // id recycled) must not delete anything.
            const matched = conn.deleteImage(it.id, it.path) catch |err| {
                log.warn("deleteImage {d}: {}", .{ it.id, err });
                continue;
            };
            if (!matched) {
                log.warn("delete {s}: image no longer in the library", .{std.Io.Dir.path.basename(it.path)});
                continue;
            }
            std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| switch (err) {
                error.FileNotFound => {},
                // The row is gone; a library file left behind is re-indexed by the next scan.
                else => log.warn("delete {s}: {}", .{ std.Io.Dir.path.basename(file_path), err }),
            };
            succeeded.append(job_alloc, it.id) catch {};
        },
        .restore => for (job.items) |it| {
            if (restoreOne(io, &conn, data_dir, it)) succeeded.append(job_alloc, it.id) catch {};
        },
        .purge_expired, .empty_trash => {
            // empty_trash: every trashed row, whatever its age.
            const cutoff = if (job.kind == .empty_trash) std.math.maxInt(i64) else job.cutoff;
            const names = conn.purgeExpiredTrash(job_alloc, cutoff) catch return;
            defer {
                for (names) |n| job_alloc.free(n);
                job_alloc.free(names);
            }
            for (names) |trash_name| {
                const p = std.Io.Dir.path.join(job_alloc, &.{ data_dir, "trash", trash_name }) catch continue;
                defer job_alloc.free(p);
                std.Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => log.warn("purge {s}: {}", .{ trash_name, err }),
                };
            }
            if (names.len > 0) log.info("{s}: {d} trash items deleted", .{ @tagName(job.kind), names.len });
        },
        .dedupe => {
            // Every redundant copy (a separate file with the same hash as a
            // kept one) goes to the trash, so this is recoverable.
            const reds = conn.listRedundantDuplicates(job_alloc) catch return;
            defer {
                for (reds) |r| job_alloc.free(r.path);
                job_alloc.free(reds);
            }
            const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
            for (reds) |r| {
                if (trashOne(io, &conn, data_dir, r.id, r.path, now_s))
                    succeeded.append(job_alloc, r.id) catch {};
            }
            log.info("dedupe: {d} copies moved to the trash", .{succeeded.items.len});
        },
    }
}

/// Move a trashed image back into its library. When its old path is now taken
/// (ComfyUI reused the name), it comes back beside it as `name (1).ext`.
fn restoreOne(io: std.Io, conn: *db_mod.VectorDb, data_dir: []const u8, it: JobItem) bool {
    const tn = it.trash_name orelse return false;
    const src = std.Io.Dir.path.join(job_alloc, &.{ data_dir, "trash", tn }) catch return false;
    defer job_alloc.free(src);
    const dst = freeRestorePath(io, job_alloc, conn, it.path) catch |err| {
        log.warn("restore {s}: {}", .{ std.Io.Dir.path.basename(it.path), err });
        return false;
    };
    defer job_alloc.free(dst);
    moveFile(io, src, dst) catch |err| {
        log.warn("restore {s}: {}", .{ std.Io.Dir.path.basename(it.path), err });
        return false;
    };
    const matched = conn.restoreImage(it.id, tn, dst) catch |err| blk: {
        log.warn("restoreImage {d}: {}", .{ it.id, err });
        break :blk false;
    };
    if (!matched) {
        // The row changed under us: put the file back where it was.
        moveFile(io, dst, src) catch |err| log.warn("restore rollback {s}: {}", .{ tn, err });
        return false;
    }
    return true;
}

/// Move one library image into the trash. The row is marked trashed BEFORE the
/// move: anything that sees the file vanish from the library (fs watcher, grid
/// loader) only deletes rows that aren't trashed, so it can never observe a
/// moved file whose row still looks live. A failed move rolls the row back.
fn trashOne(io: std.Io, conn: *db_mod.VectorDb, data_dir: []const u8, id: u64, path: []const u8, now_s: i64) bool {
    var file_size: i64 = 0;
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
        if (f.length(io)) |len| file_size = @intCast(len) else |_| {}
        f.close(io);
    } else |_| {}

    const basename = std.Io.Dir.path.basename(path);
    var name_buf: [768]u8 = undefined;
    const trash_name = std.mem.print(&name_buf, "{d}_{s}", .{ id, basename }) catch return false;
    const dst = std.Io.Dir.path.join(job_alloc, &.{ data_dir, "trash", trash_name }) catch return false;
    defer job_alloc.free(dst);

    // Matched on the path too: a stale entry (row gone, or its id recycled for
    // another image) must not move a file the DB no longer tracks.
    const matched = conn.trashImage(id, path, trash_name, file_size, now_s) catch |err| {
        log.warn("trashImage {d}: {}", .{ id, err });
        return false;
    };
    if (!matched) {
        log.warn("trash {s}: image no longer in the library", .{basename});
        return false;
    }
    moveFile(io, path, dst) catch |err| {
        log.warn("trash {s}: {}", .{ basename, err });
        _ = conn.restoreImage(id, trash_name, path) catch |rerr| log.warn("restoreImage {d}: {}", .{ id, rerr });
        return false;
    };
    return true;
}

/// Call once per frame on the main thread: applies finished file operations to
/// the grid and open viewers. Returns true if anything changed.
pub fn fileOpsPoll(io: std.Io, allocator: std.mem.Allocator, grid: ?*image_grid_mod.GridState) bool {
    const ctx = g_ctx orelse return false;
    var ids = std.AutoHashMap(u64, void).init(allocator);
    defer ids.deinit();
    var purged = false;
    {
        g_ops.mutex.lockUncancelable(io);
        defer g_ops.mutex.unlock(io);
        for (g_ops.done.items) |id| {
            ids.put(id, {}) catch {};
            _ = g_ops.pending.remove(id);
        }
        g_ops.done.clearRetainingCapacity();
        purged = g_ops.purged;
        g_ops.purged = false;
    }
    if (ids.count() == 0 and !purged) return false;

    if (grid) |g| {
        if (ids.count() > 0) {
            // Refocus where the first removed image was, so focus "slides up".
            const first_removed: ?usize = for (g.images.items, 0..) |e, i| {
                if (ids.contains(e.id)) break i;
            } else null;
            const had_focus = g.focused_idx != null;
            removeFromGrid(g, &ids);
            if (first_removed != null and had_focus) g.focusNear(first_removed);
            maybeReloadDuplicates(g);
        }
        if (purged and g.view_mode == .trash) {
            g.reloadImages() catch {};
        }
    }
    if (ids.count() > 0) ctx.on_images_removed(&ids);
    ctx.on_counts_changed();
    return true;
}

/// Finish queued file operations. Call at shutdown, before the DB is torn down.
pub fn fileOpsJoin(io: std.Io) void {
    g_ops.mutex.lockUncancelable(io);
    const t = g_ops.thread;
    g_ops.thread = null;
    g_ops.mutex.unlock(io);
    if (t) |th| th.join();
    // A job submitted after the worker exited would have spawned a new thread;
    // shutdown submits none, so one join suffices.
    for (g_ops.queue.items) |job| freeJob(job);
    g_ops.queue.deinit(job_alloc);
    g_ops.done.deinit(job_alloc);
    if (g_ops.pending_init) g_ops.pending.deinit();
    g_ops = .{};
}

/// In the duplicates view, removing one copy can leave its former partner with no
/// remaining duplicate; reload so those now-unique images drop out immediately.
fn maybeReloadDuplicates(grid: *image_grid_mod.GridState) void {
    if (grid.view_mode != .duplicates) return;
    // This is an in-place refresh of the same view (not a view change), so
    // keep the user's scroll position rather than snapping back to the top.
    grid.reloadImagesEx(.{ .keep_scroll = true }) catch {};
}

// ── Bulk operations ─────────────────────────────────────────────────────────
//
// "Empty trash" and "remove all but one duplicate" can touch thousands of files
// and rows. They are jobs on the file-op worker like any other, so they never
// block the render thread and never run concurrently with a single-image trash
// or delete of the same file. `fileOpsPoll` applies their results.

/// Whether an empty-trash or dedupe job is queued or running.
pub fn bulkActive() bool {
    return g_ops.user_bulk.load(.acquire) > 0;
}

/// Move every redundant duplicate copy to the trash (recoverable). Only copies
/// whose content survives in another file are moved.
pub fn startRemoveRedundantDuplicates(io: std.Io) void {
    submit(io, .{ .kind = .dedupe, .items = &.{} });
}

/// Permanently delete every trashed image (DB row + file).
pub fn startEmptyTrash(io: std.Io) void {
    submit(io, .{ .kind = .empty_trash, .items = &.{} });
}
