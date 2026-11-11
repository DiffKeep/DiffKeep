//! The grid's thumbnail loader: a two-tier cache of JPEG thumbnails and a
//! pool of worker threads that fill it from the DB (or libvips), visible cells
//! first. The grid asks for thumbnails with `request` while it renders, and
//! moves finished ones into the cache with `commitPending` each frame.
//!
//! Its queue is rebuilt every frame from what is on screen (so it has two
//! priorities and drops scrolled-away requests), which is why it keeps its own
//! threads rather than a `bg.WorkQueue`.

const std = @import("std");
const db_mod = @import("db.zig");
const vips = @import("vips");
const media = @import("media.zig");

const log = std.log.scoped(.thumb_loader);

pub const max_workers = 8;
/// Default cap on cached JPEG bytes. A screenful plus the prefetch zone is a
/// few hundred thumbnails (~10-20 MB); past the cap the least recently shown
/// go first.
pub const default_max_bytes: usize = 64 * 1024 * 1024;

// ── Cache ─────────────────────────────────────────────────────────────────────

pub const CacheEntry = struct {
    bytes: []u8,
    /// `ThumbLoader.frame` when the grid last showed or prefetched it.
    last_seen: u64,
    /// The dvui texture-cache key the grid drew it under (0 = not drawn yet).
    /// Textures are keyed by the bytes' address, so when the bytes are freed
    /// the key is handed back (`takeReleasedKeys`) for the grid to invalidate
    /// before that address can show another image.
    tex_key: u64 = 0,
    width: f32,  // natural JPEG pixel width
    height: f32, // natural JPEG pixel height
};

/// Parse JPEG SOF marker to get image dimensions without decoding the image.
fn jpegDimensions(bytes: []const u8) struct { w: f32, h: f32 } {
    if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8)
        return .{ .w = 10, .h = 10 };
    var i: usize = 2;
    while (i + 3 < bytes.len) {
        if (bytes[i] != 0xFF) break;
        const marker = bytes[i + 1];
        // SOF markers: C0-CF except C4 (DHT), C8 (JPG), CC (DAC)
        if (marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC)
        {
            if (i + 8 >= bytes.len) break;
            // Segment layout: FF Cn [2-len] [1-precision] [2-height] [2-width]
            const h: f32 = @floatFromInt((@as(u16, bytes[i + 5]) << 8) | bytes[i + 6]);
            const w: f32 = @floatFromInt((@as(u16, bytes[i + 7]) << 8) | bytes[i + 8]);
            if (w > 0 and h > 0) return .{ .w = w, .h = h };
        }
        const seg_len: usize = (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
        if (seg_len < 2) break;
        i += 2 + seg_len;
    }
    return .{ .w = 10, .h = 10 };
}

// ── Load queue ────────────────────────────────────────────────────────────────

const LoadRequest = struct {
    id: u64,
    path: []const u8, // heap-allocated copy; freed by worker after use or by reloadImages on queue clear
};

pub const ThumbLoader = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Called from a worker after each thumbnail is ready, to wake the render loop.
    wakeup_fn: ?*const fn () void = null,
    /// Longest side of generated thumbnails, in pixels.
    thumb_px: c_int,

    // Two-tier thumbnail cache
    // committed: main-thread only, no lock needed
    committed: std.AutoHashMap(u64, CacheEntry),
    // pending: worker writes; main drains into committed in commitPending()
    pending: std.AutoHashMap(u64, []u8),
    pending_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Bumped by each `commitPending` (once per frame): the LRU clock.
    frame: u64 = 0,
    /// Sum of `committed` bytes, kept under `max_bytes`.
    total_bytes: usize = 0,
    max_bytes: usize = default_max_bytes,
    /// Texture keys of freed entries (see `CacheEntry.tex_key`). Main thread.
    released_keys: std.ArrayList(u64) = .empty,

    // Load queues — protected by queue_mutex
    // high = visible range, low = prefetch zone
    high_queue: std.ArrayList(LoadRequest) = .empty,
    low_queue: std.ArrayList(LoadRequest) = .empty,
    queued: std.AutoHashMap(u64, void), // IDs sitting in high_queue/low_queue
    // IDs a worker has popped and is currently loading. Tracked separately from
    // `queued` so the per-frame queue rebuild (which drops stale queued requests)
    // doesn't re-request something already in flight and load it twice.
    in_flight: std.AutoHashMap(u64, void),
    /// In-flight loads whose id was invalidated meanwhile (the id now names
    /// another image): their result is dropped. Guarded by queue_mutex.
    stale_in_flight: std.AutoHashMap(u64, void),
    // Ids whose thumbnail couldn't be produced: not re-requested until
    // invalidate (refresh / recycled id). Guarded by queue_mutex.
    load_failed: std.AutoHashMap(u64, void),
    // Ids the loader deleted from the DB because their file is gone. Drained by
    // app.zig each frame to drop them from the grid and viewers. Guarded by queue_mutex.
    missing_ids: std.ArrayList(u64) = .empty,
    queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
    queue_cond: std.Io.Condition = std.Io.Condition.init,

    // Dedicated DB connection shared by all loader workers, serialized via mutex
    loader_db: db_mod.VectorDb,
    loader_db_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Read by the loader workers; the settings screen may change it.
    thumbnails_in_db: std.atomic.Value(bool),

    // Worker thread pool
    workers: [max_workers]std.Thread = undefined,
    worker_count: usize = 0,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, thumb_px: c_int, wakeup_fn: ?*const fn () void) !ThumbLoader {
        const loader_db = try db.getConnection();
        return .{
            .io = io,
            .allocator = allocator,
            .wakeup_fn = wakeup_fn,
            .thumb_px = thumb_px,
            .committed = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .pending = std.AutoHashMap(u64, []u8).init(allocator),
            .queued = std.AutoHashMap(u64, void).init(allocator),
            .in_flight = std.AutoHashMap(u64, void).init(allocator),
            .stale_in_flight = std.AutoHashMap(u64, void).init(allocator),
            .load_failed = std.AutoHashMap(u64, void).init(allocator),
            .loader_db = loader_db,
            .thumbnails_in_db = .init(thumbnails_in_db),
        };
    }

    /// Start the worker threads. Call once the loader is at its final address.
    pub fn start(self: *ThumbLoader) !void {
        const n = @min(std.Thread.getCpuCount() catch 4, max_workers);
        for (0..n) |_| {
            self.workers[self.worker_count] = try std.Thread.spawn(.{}, workerFn, .{self});
            self.worker_count += 1;
        }
    }

    /// Stop the workers and free everything.
    pub fn deinit(self: *ThumbLoader) void {
        self.stop.store(true, .release);
        self.queue_mutex.lockUncancelable(self.io);
        // Signal once per worker to wake all waiting threads
        for (0..self.worker_count) |_| self.queue_cond.signal(self.io);
        self.queue_mutex.unlock(self.io);
        for (self.workers[0..self.worker_count]) |w| w.join();

        var ci = self.committed.iterator();
        while (ci.next()) |kv| self.allocator.free(kv.value_ptr.bytes);
        self.committed.deinit();
        self.released_keys.deinit(self.allocator);

        var pi = self.pending.iterator();
        while (pi.next()) |kv| self.allocator.free(kv.value_ptr.*);
        self.pending.deinit();

        for (self.high_queue.items) |r| self.allocator.free(r.path);
        for (self.low_queue.items) |r| self.allocator.free(r.path);
        self.high_queue.deinit(self.allocator);
        self.low_queue.deinit(self.allocator);
        self.queued.deinit();
        self.in_flight.deinit();
        self.stale_in_flight.deinit();
        self.load_failed.deinit();
        self.missing_ids.deinit(self.allocator);
        self.loader_db.deinit();
    }

    /// Drop every request not yet started (the grid shows a new list, or is
    /// about to re-request what is on screen). In-flight loads finish.
    pub fn clearQueued(self: *ThumbLoader) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        for (self.high_queue.items) |r| self.allocator.free(r.path);
        for (self.low_queue.items) |r| self.allocator.free(r.path);
        self.high_queue.clearRetainingCapacity();
        self.low_queue.clearRetainingCapacity();
        self.queued.clearRetainingCapacity();
    }

    /// Main thread, each frame: move finished thumbnails into the cache, and
    /// evict the least recently seen ones once it is over `max_bytes`.
    pub fn commitPending(self: *ThumbLoader) void {
        self.frame += 1;
        {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            var it = self.pending.iterator();
            while (it.next()) |kv| {
                const dims = jpegDimensions(kv.value_ptr.*);
                const entry = CacheEntry{
                    .bytes = kv.value_ptr.*,
                    .last_seen = self.frame,
                    .width = dims.w,
                    .height = dims.h,
                };
                const old = self.committed.fetchPut(kv.key_ptr.*, entry) catch {
                    self.allocator.free(entry.bytes);
                    continue;
                };
                self.total_bytes += entry.bytes.len;
                if (old) |o| self.release(o.value);
            }
            self.pending.clearRetainingCapacity();
        }
        if (self.total_bytes > self.max_bytes) self.evictLeastRecent();
    }

    /// Mark `id`'s cached thumbnail as in use (on screen or prefetched), so
    /// eviction keeps it. Returns the entry, or null if it isn't cached.
    pub fn touch(self: *ThumbLoader, id: u64) ?*CacheEntry {
        const ce = self.committed.getPtr(id) orelse return null;
        ce.last_seen = self.frame;
        return ce;
    }

    /// Texture keys of thumbnails freed since `clearReleasedKeys`; the grid
    /// invalidates them before drawing, then clears them.
    pub fn releasedKeys(self: *const ThumbLoader) []const u64 {
        return self.released_keys.items;
    }

    pub fn clearReleasedKeys(self: *ThumbLoader) void {
        self.released_keys.clearRetainingCapacity();
    }

    /// Free an entry that has left `committed`.
    fn release(self: *ThumbLoader, e: CacheEntry) void {
        self.total_bytes -= e.bytes.len;
        if (e.tex_key != 0) self.released_keys.append(self.allocator, e.tex_key) catch {};
        self.allocator.free(e.bytes);
    }

    /// Evict down to 3/4 of `max_bytes` (so this doesn't run every frame),
    /// oldest first, never what the grid used last frame.
    fn evictLeastRecent(self: *ThumbLoader) void {
        const Old = struct { id: u64, seen: u64 };
        var olds: std.ArrayList(Old) = .empty;
        defer olds.deinit(self.allocator);
        var it = self.committed.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_seen + 1 >= self.frame) continue;
            olds.append(self.allocator, .{ .id = kv.key_ptr.*, .seen = kv.value_ptr.last_seen }) catch return;
        }
        std.mem.sort(Old, olds.items, {}, struct {
            fn lt(_: void, a: Old, b: Old) bool {
                return a.seen < b.seen;
            }
        }.lt);
        const target = self.max_bytes / 4 * 3;
        for (olds.items) |o| {
            if (self.total_bytes <= target) break;
            if (self.committed.fetchRemove(o.id)) |kv| self.release(kv.value);
        }
    }

    /// Drop any cached/queued thumbnail for `id` so the next render re-requests
    /// it. Used when an image's pixels may have changed (reparse / overwrite) and
    /// when an image is removed — SQLite recycles the deleted row's id for the
    /// next insert, so a lingering cache entry would show the old thumbnail under
    /// the new image.
    pub fn invalidate(self: *ThumbLoader, id: u64) void {
        if (self.committed.fetchRemove(id)) |kv| self.release(kv.value);
        {
            // Drop a stale, not-yet-drained worker result so commitPending
            // doesn't re-commit it; an in-flight load regenerates from disk.
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            if (self.pending.fetchRemove(id)) |kv| self.allocator.free(kv.value);
        }
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            _ = self.queued.remove(id);
            _ = self.load_failed.remove(id);
            // A worker still decoding the id's previous file: drop its result.
            if (self.in_flight.contains(id)) self.stale_in_flight.put(id, {}) catch {};
        }
    }

    /// Worker side: hand over a finished load (`bytes` null = it failed),
    /// unless `invalidateThumbnail` made it stale meanwhile.
    pub fn finishLoad(self: *ThumbLoader, id: u64, path: []const u8, bytes: ?[]u8) void {
        self.queue_mutex.lockUncancelable(self.io);
        const stale = self.stale_in_flight.remove(id);
        if (stale) {
            self.queue_mutex.unlock(self.io);
            if (bytes) |b| self.allocator.free(b);
            return;
        }
        const b = bytes orelse {
            self.queue_mutex.unlock(self.io);
            self.noteLoadFailure(id, path);
            return;
        };
        // Still under queue_mutex, so an invalidate can't slip in between the
        // stale check and the store (it would then remove the stored result).
        self.pending_mutex.lockUncancelable(self.io);
        if (self.pending.fetchRemove(id)) |old| self.allocator.free(old.value);
        self.pending.put(id, b) catch self.allocator.free(b);
        self.pending_mutex.unlock(self.io);
        self.queue_mutex.unlock(self.io);
        if (self.wakeup_fn) |wakeup| wakeup();
    }

    /// Worker side: no thumbnail could be produced for `id`. A file deleted
    /// outside the app (gone from a directory that still exists) has its row
    /// removed now and its id queued for `drainMissingIds`; anything else (an
    /// undecodable file, or a whole directory missing, e.g. an unmounted drive,
    /// which the library scan reconciles) is just not retried.
    pub fn noteLoadFailure(self: *ThumbLoader, id: u64, path: []const u8) void {
        {
            // Covers both outcomes: a deleted id must not be re-requested before
            // the main thread drains it (removal then invalidates it).
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            self.load_failed.put(id, {}) catch {};
        }
        if (fileDeleted(self.io, path)) {
            self.loader_db_mutex.lockUncancelable(self.io);
            const deleted = self.loader_db.deleteMissingImage(id, path) catch |err| blk: {
                log.warn("remove missing {s}: {}", .{ std.Io.Dir.path.basename(path), err });
                break :blk false;
            };
            self.loader_db_mutex.unlock(self.io);
            if (deleted) {
                log.info("removed missing file {s} from the library", .{std.Io.Dir.path.basename(path)});
                self.queue_mutex.lockUncancelable(self.io);
                self.missing_ids.append(self.allocator, id) catch {};
                self.queue_mutex.unlock(self.io);
                if (self.wakeup_fn) |wakeup| wakeup();
            }
        }
    }

    /// Move the ids `noteLoadFailure` deleted from the DB into `out` (which
    /// grows with `gpa`). Main-thread only; called once per frame.
    pub fn drainMissingIds(self: *ThumbLoader, gpa: std.mem.Allocator, out: *std.ArrayList(u64)) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (self.missing_ids.items.len == 0) return;
        out.appendSlice(gpa, self.missing_ids.items) catch return;
        self.missing_ids.clearRetainingCapacity();
    }

    /// True if `id` was re-notified (reparsed / changed) during this frame's
    /// update(). Lets the detail panel reload exactly when fresh data is ready.
    pub fn request(self: *ThumbLoader, id: u64, path: []const u8, high: bool) void {
        if (self.committed.contains(id)) return;

        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queued.contains(id) or self.in_flight.contains(id) or self.load_failed.contains(id)) return;

        const path_copy = self.allocator.dupe(u8, path) catch return;
        const req = LoadRequest{ .id = id, .path = path_copy };
        const queue = if (high) &self.high_queue else &self.low_queue;
        queue.append(self.allocator, req) catch {
            self.allocator.free(path_copy);
            return;
        };
        self.queued.put(id, {}) catch {
            _ = queue.pop();
            self.allocator.free(path_copy);
            return;
        };
        self.queue_cond.signal(self.io);
    }
};

/// True when `path` no longer exists but its directory does, i.e. the file
/// was deleted. A missing directory is not treated as a deletion.
pub fn fileDeleted(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const dir = std.Io.Dir.path.dirname(path) orelse return false;
            cwd.access(io, dir, .{}) catch return false;
            return true;
        },
        else => return false,
    };
    return false;
}


// ── Worker thread ─────────────────────────────────────────────────────────────

fn workerFn(state: *ThumbLoader) void {
    while (true) {
        state.queue_mutex.lockUncancelable(state.io);
        while (!state.stop.load(.acquire) and
            state.high_queue.items.len == 0 and
            state.low_queue.items.len == 0)
        {
            state.queue_cond.waitUncancelable(state.io, &state.queue_mutex);
        }

        if (state.stop.load(.acquire)) {
            state.queue_mutex.unlock(state.io);
            break;
        }

        const req: LoadRequest = if (state.high_queue.items.len > 0)
            state.high_queue.orderedRemove(0)
        else
            state.low_queue.orderedRemove(0);

        // Move from queued → in_flight so requestLoad won't re-queue it while the
        // per-frame queue rebuild is dropping stale requests.
        _ = state.queued.remove(req.id);
        state.in_flight.put(req.id, {}) catch {};
        state.queue_mutex.unlock(state.io);
        defer {
            state.queue_mutex.lockUncancelable(state.io);
            _ = state.in_flight.remove(req.id);
            _ = state.stale_in_flight.remove(req.id);
            state.queue_mutex.unlock(state.io);
        }
        defer state.allocator.free(req.path);

        // Video posters live in the DB (libvips can't open mp4/webm); for those,
        // always read the stored blob. Otherwise use the DB only when configured.
        const is_video = media.isVideoFile(req.path);
        var bytes: ?[]u8 = null;
        if (state.thumbnails_in_db.load(.acquire) or is_video) {
            state.loader_db_mutex.lockUncancelable(state.io);
            bytes = state.loader_db.getThumbnailBytes(state.allocator, req.id) catch null;
            state.loader_db_mutex.unlock(state.io);
        }

        // Fall back to on-the-fly VIPS generation (images only).
        if (bytes == null and !is_video) {
            const path_z = state.allocator.dupeSentinel(u8, req.path, 0) catch continue;
            defer state.allocator.free(path_z);
            bytes = vips.thumbnailToJpeg(state.allocator, path_z, state.thumb_px) catch |err| blk: {
                log.warn("vips thumbnail {s}: {}", .{ std.Io.Dir.path.basename(req.path), err });
                break :blk null;
            };
        }

        state.finishLoad(req.id, req.path, bytes);
    }
    vips.threadShutdown();
}
