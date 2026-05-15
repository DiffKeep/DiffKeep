const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const vips = @import("vips");
const notifier_mod = @import("notifier.zig");

pub const ImageNotifier = notifier_mod.ImageNotifier;

const log = std.log.scoped(.image_grid);

pub const ImageEntry = struct {
    id: u64,
    path: []const u8,     // heap-allocated, owned by GridState.images
    filename: []const u8, // slice into path (basename), not separately allocated
};

// ── Cache ─────────────────────────────────────────────────────────────────────

const CacheEntry = struct {
    bytes: []u8,
    last_seen_s: i64,
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
    path: []const u8, // stable pointer into GridState.images entry's path
};

// ── Layout constants ──────────────────────────────────────────────────────────

pub const thumb_size_min: f32 = 80;
pub const thumb_size_max: f32 = 320;
const max_workers = 8;
const gap: f32 = 8;
const label_h: f32 = 20;
const evict_interval_s: i64 = 5;
const ttl_s: i64 = 45;
const prefetch_screens: usize = 2;

// ── GridState ─────────────────────────────────────────────────────────────────

pub const GridState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    // Image list — main-thread only after startWorker()
    images: std.ArrayList(ImageEntry) = .empty,

    // Incoming images from scan threads — drained each frame in update()
    notifier: ImageNotifier = .{},
    incoming: std.ArrayList(ImageNotifier.Entry) = .empty,

    // Two-tier thumbnail cache
    // committed: main-thread only, no lock needed
    committed: std.AutoHashMap(u64, CacheEntry),
    // pending: worker writes; main drains into committed in update()
    pending: std.AutoHashMap(u64, []u8),
    pending_mutex: std.Io.Mutex = std.Io.Mutex.init,

    last_eviction_s: i64 = 0,

    // Load queues — protected by queue_mutex
    // high = visible range, low = prefetch zone
    high_queue: std.ArrayList(LoadRequest) = .empty,
    low_queue: std.ArrayList(LoadRequest) = .empty,
    queued: std.AutoHashMap(u64, void), // IDs currently in a queue or in-flight
    queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
    queue_cond: std.Io.Condition = std.Io.Condition.init,

    // Dedicated DB connection shared by all loader workers, serialized via mutex
    loader_db: db_mod.VectorDb,
    loader_db_mutex: std.Io.Mutex = std.Io.Mutex.init,
    thumbnails_in_db: bool,

    // Worker thread pool
    workers: [max_workers]std.Thread = undefined,
    worker_count: usize = 0,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Persistent scroll state for the grid's scroll area.  Using vertical=.given
    // prevents the full content height from being reported as min_size.h to the
    // parent layout, which would push the statusbar off-screen.
    scroll_info: dvui.ScrollInfo = .{},

    // Called from worker after each thumbnail is ready, to wake the render loop.
    wakeup_fn: ?*const fn () void = null,

    // UI state
    selected_id: ?u64 = null,
    thumb_fraction: f32 = 0.25, // 0..1 maps to thumb_size_min..thumb_size_max (~140px default)

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, wakeup_fn: ?*const fn () void) !GridState {
        var state = GridState{
            .io = io,
            .allocator = allocator,
            .committed = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .pending = std.AutoHashMap(u64, []u8).init(allocator),
            .queued = std.AutoHashMap(u64, void).init(allocator),
            .loader_db = try db.getConnection(),
            .thumbnails_in_db = thumbnails_in_db,
            .wakeup_fn = wakeup_fn,
        };

        // Populate from DB synchronously so existing images appear immediately
        const entries = try db.listAllImages(allocator);
        defer allocator.free(entries);
        try state.images.ensureTotalCapacity(allocator, entries.len);
        for (entries) |e| {
            state.images.appendAssumeCapacity(.{
                .id = e.id,
                .path = e.path,
                .filename = std.fs.path.basename(e.path),
            });
        }

        state.last_eviction_s = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        return state;
    }

    /// Start the background loader thread pool. Call this after the GridState is at its
    /// final stable address (e.g. stored as a module-level global).
    pub fn startWorker(self: *GridState) !void {
        const n = @min(std.Thread.getCpuCount() catch 4, max_workers);
        for (0..n) |_| {
            self.workers[self.worker_count] = try std.Thread.spawn(.{}, workerFn, .{self});
            self.worker_count += 1;
        }
    }

    pub fn deinit(self: *GridState) void {
        self.stop.store(true, .release);
        self.queue_mutex.lockUncancelable(self.io);
        // Signal once per worker to wake all waiting threads
        for (0..self.worker_count) |_| self.queue_cond.signal(self.io);
        self.queue_mutex.unlock(self.io);
        for (self.workers[0..self.worker_count]) |w| w.join();

        var ci = self.committed.iterator();
        while (ci.next()) |kv| self.allocator.free(kv.value_ptr.bytes);
        self.committed.deinit();

        var pi = self.pending.iterator();
        while (pi.next()) |kv| self.allocator.free(kv.value_ptr.*);
        self.pending.deinit();

        self.high_queue.deinit(self.allocator);
        self.low_queue.deinit(self.allocator);
        self.queued.deinit();

        self.loader_db.deinit();
        self.notifier.deinit(self.allocator);

        for (self.incoming.items) |e| self.allocator.free(e.path);
        self.incoming.deinit(self.allocator);

        for (self.images.items) |e| self.allocator.free(e.path);
        self.images.deinit(self.allocator);
    }

    /// Call once per frame before render(), on the main thread.
    pub fn update(self: *GridState) void {
        // 1. Drain new images from scan threads
        self.notifier.drain(self.io, self.allocator, &self.incoming);
        for (self.incoming.items) |e| {
            self.images.append(self.allocator, .{
                .id = e.id,
                .path = e.path,
                .filename = std.fs.path.basename(e.path),
            }) catch {
                self.allocator.free(e.path);
                continue;
            };
        }
        self.incoming.clearAndFree(self.allocator);

        // 2. Drain pending thumbnails into committed
        const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            var it = self.pending.iterator();
            while (it.next()) |kv| {
                const dims = jpegDimensions(kv.value_ptr.*);
                const entry = CacheEntry{
                    .bytes = kv.value_ptr.*,
                    .last_seen_s = now_s,
                    .width = dims.w,
                    .height = dims.h,
                };
                if (self.committed.fetchPut(kv.key_ptr.*, entry) catch null) |old| {
                    self.allocator.free(old.value.bytes);
                }
            }
            self.pending.clearRetainingCapacity();
        }

        // 3. Periodic eviction (~every 5 seconds)
        if (now_s - self.last_eviction_s >= evict_interval_s) {
            self.last_eviction_s = now_s;
            self.evictStale(now_s - ttl_s);
        }
    }

    fn evictStale(self: *GridState, cutoff_s: i64) void {
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.committed.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_seen_s < cutoff_s) {
                stale.append(self.allocator, kv.key_ptr.*) catch continue;
            }
        }
        for (stale.items) |id| {
            if (self.committed.fetchRemove(id)) |kv| {
                self.allocator.free(kv.value.bytes);
            }
        }
    }

    pub fn thumbSize(self: *const GridState) f32 {
        return thumb_size_min + self.thumb_fraction * (thumb_size_max - thumb_size_min);
    }

    fn requestLoad(self: *GridState, id: u64, path: []const u8, high: bool) void {
        if (self.committed.contains(id)) return;

        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queued.contains(id)) return;

        const req = LoadRequest{ .id = id, .path = path };
        const queue = if (high) &self.high_queue else &self.low_queue;
        queue.append(self.allocator, req) catch return;
        self.queued.put(id, {}) catch {
            _ = queue.pop();
            return;
        };
        self.queue_cond.signal(self.io);
    }

    /// Render the image grid.  Opens its own scroll area using vertical=.given
    /// so the full content height is never reported as min_size.h to the parent
    /// layout (which would push the statusbar off-screen).
    pub fn render(self: *GridState) void {
        const n = self.images.items.len;
        const ts = self.thumbSize();
        const cell_w = ts + gap;
        const cell_h = ts + label_h + gap;

        const scale = dvui.windowNaturalScale();

        // Use the previous frame's viewport width to estimate total_h before
        // opening the scroll area (needed to pre-set virtual_size.h so the
        // scrollbar decision is roughly right on first paint).
        {
            const prev_w = self.scroll_info.viewport.w;
            const est_cols: usize = if (prev_w > 1)
                @max(1, @as(usize, @intFromFloat(@floor(prev_w / cell_w))))
            else
                1;
            const est_rows: usize = if (n == 0) 0 else (n + est_cols - 1) / est_cols;
            self.scroll_info.virtual_size.h = @as(f32, @floatFromInt(est_rows)) * cell_h;
        }
        self.scroll_info.vertical = .given;
        self.scroll_info.horizontal = .none;

        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &self.scroll_info }, .{ .expand = .both });
        defer scroll.deinit();

        // Read avail_w from the INNER clip — this is the scroll container's
        // actual viewport width after the scrollbar (if any) has taken its
        // share.  Using the outer clip would count the scrollbar's column
        // as available space, causing cells to overflow and the right panel
        // to be displaced.
        const clip = dvui.clipGet();
        const avail_w = clip.w / scale;

        if (avail_w < 1) return;

        const cols: usize = @max(1, @as(usize, @intFromFloat(@floor(avail_w / cell_w))));
        const total_rows: usize = if (n == 0) 0 else (n + cols - 1) / cols;
        const total_h = @as(f32, @floatFromInt(total_rows)) * cell_h;

        // Keep virtual_size.h in sync with the actual column count.  If it
        // changed (e.g. after the first frame when we had a 1-col estimate),
        // request a re-render so the scrollbar size corrects itself.
        if (total_h != self.scroll_info.virtual_size.h) {
            self.scroll_info.virtual_size.h = total_h;
            dvui.refresh(null, @src(), scroll.data().id);
        }

        const row_h_phys = cell_h * scale;

        // Distribute remaining horizontal space as equal margins around each cell.
        const h_margin = (avail_w - @as(f32, @floatFromInt(cols)) * ts) / @as(f32, @floatFromInt(cols)) / 2.0;

        // Marker widget at content top to measure scroll offset
        var marker = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = 0 } });
        const marker_y = marker.data().rectScale().r.y;
        marker.deinit();

        const rel_top = clip.y - marker_y;
        const rel_bot = clip.y + clip.h - marker_y;

        const first_row = @as(usize, @intCast(@max(
            0,
            @as(i64, @intFromFloat(@floor(rel_top / row_h_phys))) - 1,
        )));
        const last_row = @min(
            total_rows,
            @as(usize, @intFromFloat(@ceil(rel_bot / row_h_phys))) + 1,
        );
        const visible_rows = if (last_row > first_row) last_row - first_row else 1;

        // Prefetch zone: N screens above and below the viewport
        const buf_rows = visible_rows * prefetch_screens;
        const pf_first = if (first_row > buf_rows) first_row - buf_rows else 0;
        const pf_last = @min(total_rows, last_row + buf_rows);

        // Touch last_seen for visible items; queue loads for prefetch zone
        const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        for (pf_first..pf_last) |row| {
            const is_visible = row >= first_row and row < last_row;
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                const entry = &self.images.items[idx];
                if (self.committed.getPtr(entry.id)) |ce| {
                    if (is_visible) ce.last_seen_s = now_s;
                } else {
                    self.requestLoad(entry.id, entry.path, is_visible);
                }
            }
        }

        // Top spacer
        if (first_row > 0) {
            var sp = dvui.box(@src(), .{}, .{
                .id_extra = std.math.maxInt(usize),
                .min_size_content = .{ .w = 0, .h = @as(f32, @floatFromInt(first_row)) * cell_h },
            });
            sp.deinit();
        }

        // Visible rows
        for (first_row..last_row) |row| {
            var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row,
                .expand = .horizontal,
                // Cap reported min_size.w to avail_w so the ratchet in
                // dvui.minSize() cannot inflate it beyond the scroll
                // container's content width (which breaks the outer layout).
                .max_size_content = .{ .w = avail_w, .h = dvui.max_float_safe },
            });
            defer hrow.deinit();
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                self.renderItem(idx, ts, h_margin);
            }
        }

        // Bottom spacer
        if (last_row < total_rows) {
            const tail = total_rows - last_row;
            var sp = dvui.box(@src(), .{}, .{
                .id_extra = std.math.maxInt(usize) - 1,
                .min_size_content = .{ .w = 0, .h = @as(f32, @floatFromInt(tail)) * cell_h },
            });
            sp.deinit();
        }
    }

    fn renderItem(self: *GridState, idx: usize, ts: f32, h_margin: f32) void {
        const entry = self.images.items[idx];
        const selected = if (self.selected_id) |sel| sel == entry.id else false;

        var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx,
            .min_size_content = .{ .w = ts, .h = ts + label_h },
            .margin = .{ .x = h_margin, .y = gap / 2, .w = h_margin, .h = gap / 2 },
            .border = if (selected) dvui.Rect.all(2) else null,
            .color_border = dvui.themeGet().focus,
        });
        defer cell.deinit();

        if (dvui.clicked(cell.data(), .{})) {
            self.selected_id = entry.id;
        }

        // Fixed ts×ts area; dark background is the letterbox fill and loading placeholder.
        {
            var img_area = dvui.box(@src(), .{}, .{
                .id_extra = idx,
                .min_size_content = .{ .w = ts, .h = ts },
                .background = true,
                .color_fill = .{ .r = 30, .g = 30, .b = 30, .a = 255 },
            });
            defer img_area.deinit();

            if (self.committed.get(entry.id)) |ce| {
                // Scale to fit ts×ts while preserving aspect ratio, then center with margin.
                // Using explicit margin avoids DVUI layout bugs caused by gravity_y=0.5
                // triggering child_positioned mode in the vertical BoxWidget.
                const scale = @min(ts / ce.width, ts / ce.height);
                const rw = ce.width * scale;
                const rh = ce.height * scale;
                const mx = (ts - rw) / 2.0;
                const my = (ts - rh) / 2.0;
                _ = dvui.image(@src(), .{
                    .source = .{ .imageFile = .{ .bytes = ce.bytes } },
                }, .{
                    .id_extra = idx,
                    .min_size_content = .{ .w = rw, .h = rh },
                    .margin = .{ .x = mx, .y = my, .w = mx, .h = my },
                });
            }
        }

        dvui.labelNoFmt(@src(), entry.filename, .{}, .{
            .id_extra = idx,
            .min_size_content = .{ .w = ts, .h = label_h },
            .max_size_content = .{ .w = ts, .h = dvui.max_float_safe },
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 2 },
        });
    }
};

// ── Worker thread ─────────────────────────────────────────────────────────────

fn workerFn(state: *GridState) void {
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

        _ = state.queued.remove(req.id);
        state.queue_mutex.unlock(state.io);

        // Try DB first when thumbnails are stored there (serialized: single shared connection)
        var bytes: ?[]u8 = null;
        if (state.thumbnails_in_db) {
            state.loader_db_mutex.lockUncancelable(state.io);
            bytes = state.loader_db.getThumbnailBytes(state.allocator, req.id) catch null;
            state.loader_db_mutex.unlock(state.io);
        }

        // Fall back to on-the-fly VIPS generation
        if (bytes == null) {
            const path_z = state.allocator.dupeZ(u8, req.path) catch continue;
            defer state.allocator.free(path_z);
            bytes = vips.thumbnailToJpeg(state.allocator, path_z, @as(c_int, @intFromFloat(thumb_size_max))) catch |err| blk: {
                log.warn("vips thumbnail {s}: {}", .{ std.fs.path.basename(req.path), err });
                break :blk null;
            };
        }

        const b = bytes orelse continue;

        state.pending_mutex.lockUncancelable(state.io);
        if (state.pending.fetchRemove(req.id)) |old| state.allocator.free(old.value);
        state.pending.put(req.id, b) catch state.allocator.free(b);
        state.pending_mutex.unlock(state.io);

        if (state.wakeup_fn) |wakeup| wakeup();
    }
    vips.threadShutdown();
}
