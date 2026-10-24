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

pub fn moveFile(io: std.Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var cross_device = false;
    std.Io.Dir.rename(cwd, src, cwd, dst, io) catch |err| switch (err) {
        error.CrossDevice => cross_device = true,
        else => return err,
    };
    if (!cross_device) return;
    {
        var src_file = try std.Io.Dir.cwd().openFile(io, src, .{});
        defer src_file.close(io);
        const size = try src_file.length(io);
        const buf = try allocator.alloc(u8, size);
        defer allocator.free(buf);
        _ = try src_file.readPositionalAll(io, buf, 0);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = buf });
    }
    try std.Io.Dir.cwd().deleteFile(io, src);
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
    var i: usize = 0;
    while (i < grid.images.items.len) {
        const e = grid.images.items[i];
        if (ids.contains(e.id)) {
            _ = grid.images.orderedRemove(i);
            _ = grid.selection.remove(e.id);
            // Drop the cached thumbnail: SQLite recycles this row's id for the
            // next inserted image, which would otherwise inherit this thumbnail.
            grid.invalidateThumbnail(e.id);
            grid.allocator.free(e.path);
            if (e.trash_name) |tn| grid.allocator.free(tn);
        } else {
            i += 1;
        }
    }
    if (grid.focused_idx) |fi| {
        if (grid.images.items.len == 0) grid.focused_idx = null
        else if (fi >= grid.images.items.len) grid.focused_idx = grid.images.items.len - 1;
    }
}

pub fn performTrash(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const ctx = g_ctx orelse return;
    const data_dir = ctx.data_dir.* orelse return;
    const prev_focus = grid.focused_idx;
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    const now_s: i64 = @intCast(@divTrunc(
        std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s,
    ));

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;

        var file_size: i64 = 0;
        if (std.Io.Dir.cwd().openFile(io, entry.path, .{})) |f| {
            if (f.length(io)) |len| file_size = @intCast(len) else |_| {}
            f.close(io);
        } else |_| {}

        const basename = std.Io.Dir.path.basename(entry.path);
        var name_buf: [768]u8 = undefined;
        const trash_name = std.mem.print(&name_buf, "{d}_{s}", .{ entry.id, basename }) catch {
            _ = ids.remove(entry.id);
            continue;
        };

        const dst = std.Io.Dir.path.join(allocator, &.{ data_dir, "trash", trash_name }) catch {
            _ = ids.remove(entry.id);
            continue;
        };
        defer allocator.free(dst);

        // Mark the row trashed BEFORE moving the file: anything that sees the
        // file vanish from the library (fs watcher, grid loader) only deletes
        // rows that aren't trashed, so it must never observe a moved file whose
        // row still looks live.
        const db = if (ctx.db.*) |*d| d else {
            _ = ids.remove(entry.id);
            continue;
        };
        db.trashImage(entry.id, trash_name, file_size, now_s) catch |err| {
            log.warn("trashImage {d}: {}", .{ entry.id, err });
            _ = ids.remove(entry.id);
            continue;
        };
        moveFile(io, allocator, entry.path, dst) catch |err| {
            log.warn("trash {s}: {}", .{ basename, err });
            db.restoreImage(entry.id) catch |rerr|
                log.warn("restoreImage {d}: {}", .{ entry.id, rerr });
            _ = ids.remove(entry.id);
            continue;
        };
    }

    removeFromGrid(grid, &ids);
    ctx.on_images_removed(&ids);
    ctx.on_counts_changed();
    maybeReloadDuplicates(grid);
    grid.focusNear(prev_focus);
}

/// In the duplicates view, removing one copy can leave its former partner with no
/// remaining duplicate; reload so those now-unique images drop out immediately.
fn maybeReloadDuplicates(grid: *image_grid_mod.GridState) void {
    if (grid.view_mode != .duplicates) return;
    const ctx = g_ctx orelse return;
    if (ctx.db.*) |*db| {
        // This is an in-place refresh of the same view (not a view change), so
        // keep the user's scroll position rather than snapping back to the top.
        const saved_y = grid.scroll_info.viewport.y;
        grid.reloadImages(db) catch {};
        grid.scroll_info.viewport.y = saved_y;
    }
}

pub fn performDelete(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const ctx = g_ctx orelse return;
    const data_dir = ctx.data_dir.* orelse "";
    const prev_focus = grid.focused_idx;
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;

        const file_path: []const u8 = if (entry.trash_name) |tn| blk: {
            break :blk std.Io.Dir.path.join(allocator, &.{ data_dir, "trash", tn }) catch continue;
        } else entry.path;
        defer if (entry.trash_name != null) allocator.free(file_path);

        std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| {
            log.warn("delete {s}: {}", .{ entry.filename, err });
        };

        if (ctx.db.*) |*db| {
            db.deleteImage(entry.id) catch |err| {
                log.warn("deleteImage {d}: {}", .{ entry.id, err });
            };
        }
    }

    removeFromGrid(grid, &ids);
    ctx.on_images_removed(&ids);
    ctx.on_counts_changed();
    maybeReloadDuplicates(grid);
    grid.focusNear(prev_focus);
}

pub fn performRestore(io: std.Io, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
    const ctx = g_ctx orelse return;
    const data_dir = ctx.data_dir.* orelse return;
    const prev_focus = grid.focused_idx;
    var ids = effectiveIds(grid, allocator) catch return;
    defer ids.deinit();
    if (ids.count() == 0) return;

    for (grid.images.items) |entry| {
        if (!ids.contains(entry.id)) continue;
        const trash_name = entry.trash_name orelse continue;

        const src = std.Io.Dir.path.join(allocator, &.{ data_dir, "trash", trash_name }) catch continue;
        defer allocator.free(src);

        moveFile(io, allocator, src, entry.path) catch |err| {
            log.warn("restore {s}: {}", .{ entry.filename, err });
            continue;
        };

        if (ctx.db.*) |*db| {
            db.restoreImage(entry.id) catch |err| {
                log.warn("restoreImage {d}: {}", .{ entry.id, err });
            };
        }
    }

    removeFromGrid(grid, &ids);
    ctx.on_images_removed(&ids);
    ctx.on_counts_changed();
    grid.focusNear(prev_focus);
}

// ── Background bulk operations ──────────────────────────────────────────────
//
// "Empty trash" and "remove all but one duplicate" can touch thousands of files
// and DB rows. Doing that on the render thread would freeze the UI, so they run
// on a dedicated thread; the main loop polls `bulkPoll` each frame and refreshes
// the grid + counts once the worker finishes. Only one bulk op runs at a time.

const BulkKind = enum { empty_trash, dedupe };

const Bulk = struct {
    thread: ?std.Thread = null,
    kind: BulkKind = .empty_trash,
    done: std.atomic.Value(bool) = .init(false),
    count: std.atomic.Value(u32) = .init(0),
};
var g_bulk: Bulk = .{};

pub fn bulkActive() bool {
    return g_bulk.thread != null;
}

/// Move every redundant duplicate copy (all but the lowest-id one of each hash
/// group) to the trash, on a background thread. Safe: only copies that still have
/// a surviving sibling are moved, and they go to the trash (recoverable).
pub fn startRemoveRedundantDuplicates(io: std.Io) void {
    startBulk(io, .dedupe);
}

/// Permanently delete every trashed image (DB row + file) on a background thread.
pub fn startEmptyTrash(io: std.Io) void {
    startBulk(io, .empty_trash);
}

/// Wait for a running bulk op to finish. Call at shutdown, before the DB it
/// holds a connection from is torn down.
pub fn bulkJoin() void {
    if (g_bulk.thread) |t| {
        t.join();
        g_bulk.thread = null;
    }
}

fn startBulk(io: std.Io, kind: BulkKind) void {
    if (g_bulk.thread != null) return; // already running
    g_bulk.kind = kind;
    g_bulk.done.store(false, .release);
    g_bulk.count.store(0, .release);
    g_bulk.thread = std.Thread.spawn(.{}, bulkWorker, .{io}) catch |err| blk: {
        log.warn("spawn bulk op: {}", .{err});
        break :blk null;
    };
}

fn bulkWorker(io: std.Io) void {
    // c_allocator: this runs off the main thread, so it must not touch a
    // non-thread-safe app allocator.
    const alloc = std.heap.c_allocator;
    defer {
        g_bulk.done.store(true, .release);
        if (g_ctx) |ctx| ctx.on_wakeup();
    }

    const ctx = g_ctx orelse return;
    const data_dir = ctx.data_dir.* orelse return;
    const db_ptr = if (ctx.db.*) |*d| d else return;
    var conn = db_ptr.getConnection() catch |err| {
        log.warn("bulk op db connection: {}", .{err});
        return;
    };
    defer conn.deinit();

    switch (g_bulk.kind) {
        .empty_trash => {
            // purgeExpiredTrash with a max cutoff deletes every trashed row and
            // returns their trash file names so we can unlink the files.
            const names = conn.purgeExpiredTrash(alloc, std.math.maxInt(i64)) catch return;
            defer {
                for (names) |n| alloc.free(n);
                alloc.free(names);
            }
            for (names) |trash_name| {
                const p = std.Io.Dir.path.join(alloc, &.{ data_dir, "trash", trash_name }) catch continue;
                defer alloc.free(p);
                std.Io.Dir.cwd().deleteFile(io, p) catch |err|
                    log.warn("empty trash unlink {s}: {}", .{ trash_name, err });
            }
            g_bulk.count.store(@intCast(names.len), .release);
        },
        .dedupe => {
            const reds = conn.listRedundantDuplicates(alloc) catch return;
            defer {
                for (reds) |r| alloc.free(r.path);
                alloc.free(reds);
            }
            const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
            var moved: u32 = 0;
            for (reds) |r| {
                var file_size: i64 = 0;
                if (std.Io.Dir.cwd().openFile(io, r.path, .{})) |f| {
                    if (f.length(io)) |len| file_size = @intCast(len) else |_| {}
                    f.close(io);
                } else |_| {}

                var name_buf: [768]u8 = undefined;
                const trash_name = std.mem.print(&name_buf, "{d}_{s}", .{ r.id, std.Io.Dir.path.basename(r.path) }) catch continue;
                const dst = std.Io.Dir.path.join(alloc, &.{ data_dir, "trash", trash_name }) catch continue;
                defer alloc.free(dst);

                // Mark trashed BEFORE moving. The move fires the fs-watcher's
                // delete handler on another thread; with the row already trashed,
                // deleteImageByPath skips it instead of permanently deleting, so a
                // move-vs-watcher race can never lose an image.
                conn.trashImage(r.id, trash_name, file_size, now_s) catch |err| {
                    log.warn("dedupe trashImage {d}: {}", .{ r.id, err });
                    continue;
                };
                moveFile(io, alloc, r.path, dst) catch |err| {
                    // Row stays trashed; file remains in the library (recoverable).
                    log.warn("dedupe move {s}: {}", .{ std.Io.Dir.path.basename(r.path), err });
                    continue;
                };
                moved += 1;
            }
            g_bulk.count.store(moved, .release);
        },
    }
}

/// Call once per frame. When a background bulk op has finished, joins the worker,
/// refreshes counts, and reloads the current view. Returns true if it just
/// completed (so the caller can e.g. log the count).
pub fn bulkPoll(grid: *image_grid_mod.GridState) bool {
    const t = g_bulk.thread orelse return false;
    if (!g_bulk.done.load(.acquire)) return false;
    t.join();
    g_bulk.thread = null;
    const ctx = g_ctx orelse return true;
    if (ctx.db.*) |*db| grid.reloadImages(db) catch {};
    ctx.on_counts_changed();
    log.info("bulk {s}: {d} images", .{ @tagName(g_bulk.kind), g_bulk.count.load(.acquire) });
    return true;
}
