const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const vips = @import("vips");
const notifier_mod = @import("notifier.zig");
const i18n = @import("i18n.zig");

pub const ImageNotifier = notifier_mod.ImageNotifier;

const log = std.log.scoped(.image_grid);

pub const SortMode = enum { date, name, random };
pub const SortDir = enum { asc, desc };
pub const ViewMode = enum { library, trash };

pub const ImageEntry = struct {
    id: u64,
    path: []const u8,     // heap-allocated, owned by GridState.images
    filename: []const u8, // slice into path (basename), not separately allocated
    mtime: ?i64,
    trashed_at: ?i64 = null,
    trash_name: ?[]const u8 = null, // heap-allocated, only set in trash view
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
    path: []const u8, // heap-allocated copy; freed by worker after use or by reloadImages on queue clear
};

// ── Layout constants ──────────────────────────────────────────────────────────

pub const thumb_size_min: f32 = 80;
pub const thumb_size_max: f32 = 320;
const max_workers = 8;
const gap: f32 = 8;
const cell_border: f32 = 2; // border on each side; must be factored into h_margin
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
    view_mode: ViewMode = .library,
    selection: std.AutoHashMap(u64, void), // set of selected image IDs
    focused_idx: ?usize = null,            // keyboard cursor position (grid index)
    scroll_to_focused: bool = false,       // set by keyboard nav; cleared after one viewport adjustment
    anchor_idx: ?usize = null,             // shift-select range anchor
    thumb_fraction: f32 = 0.25, // 0..1 maps to thumb_size_min..thumb_size_max (~140px default)
    sort_mode: SortMode = .date,
    sort_dir: SortDir = .desc,  // newest first by default
    sort_seed: u64 = 0,
    // Pending actions — set by key handlers / context menu, consumed by app.zig each frame
    delete_requested: bool = false,
    delete_force: bool = false,   // true = Shift+Delete or "Delete Permanently": skip trash
    restore_requested: bool = false,
    // Mirrored from config so renderItem can condition the context menu label
    trash_enabled: bool = true,
    // Viewer opening — set by double-click/Enter/context menu, consumed by app.zig each frame
    open_viewer_requested: bool = false,
    viewer_start_id: ?u64 = null,
    // Double-click state stored here (not in dvui data store) for reliability
    dblclick_last_id: u64 = 0,
    dblclick_last_ns: i64 = 0,

    // Filter state — owned by app.zig, not freed by GridState
    filter_library_id: ?u64 = null,
    filter_folder_path: ?[]const u8 = null,
    // FTS5 search query — points into app.zig's g_search_buf; not owned
    search_query: ?[]const u8 = null,
    // Active metadata filters — slice into app.zig's g_active_filters; not owned
    filters: []const db_mod.ActiveFilter = &.{},

    // Data directory (e.g. ~/.local/share/DiffKeep) — borrowed from app, not owned.
    // Used to resolve trash file paths: <data_dir>/trash/<trash_name>.
    data_dir: ?[]const u8 = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, wakeup_fn: ?*const fn () void) !GridState {
        var state = GridState{
            .io = io,
            .allocator = allocator,
            .committed = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .pending = std.AutoHashMap(u64, []u8).init(allocator),
            .queued = std.AutoHashMap(u64, void).init(allocator),
            .selection = std.AutoHashMap(u64, void).init(allocator),
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
                .mtime = e.mtime,
            });
        }

        const now_ns = std.Io.Clock.real.now(io).nanoseconds;
        state.last_eviction_s = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
        state.sort_seed = @truncate(@abs(now_ns));
        state.applySortOrder();
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

        for (self.high_queue.items) |r| self.allocator.free(r.path);
        for (self.low_queue.items) |r| self.allocator.free(r.path);
        self.high_queue.deinit(self.allocator);
        self.low_queue.deinit(self.allocator);
        self.queued.deinit();

        self.loader_db.deinit();
        self.notifier.deinit();
        self.selection.deinit();

        for (self.incoming.items) |e| self.allocator.free(e.path);
        self.incoming.deinit(self.allocator);

        for (self.images.items) |e| {
            self.allocator.free(e.path);
            if (e.trash_name) |tn| self.allocator.free(tn);
        }
        self.images.deinit(self.allocator);
    }

    /// Reload the image list from DB for the current view_mode.
    /// Clears selection and resets navigation state.
    pub fn reloadImages(self: *GridState, db: *db_mod.VectorDb) !void {
        // Clear queues before freeing images so workers don't access freed path pointers.
        {
            self.queue_mutex.lockUncancelable(self.io);
            for (self.high_queue.items) |r| self.allocator.free(r.path);
            for (self.low_queue.items) |r| self.allocator.free(r.path);
            self.high_queue.clearRetainingCapacity();
            self.low_queue.clearRetainingCapacity();
            self.queued.clearRetainingCapacity();
            self.queue_mutex.unlock(self.io);
        }
        for (self.images.items) |e| {
            self.allocator.free(e.path);
            if (e.trash_name) |tn| self.allocator.free(tn);
        }
        self.images.clearRetainingCapacity();
        self.selection.clearRetainingCapacity();
        self.focused_idx = null;
        self.anchor_idx = null;

        const entries = switch (self.view_mode) {
            .library => blk: {
                const has_search = if (self.search_query) |q| q.len > 0 else false;
                if (has_search or self.filters.len > 0) {
                    break :blk try db.listImagesFiltered(
                        self.allocator,
                        self.filter_library_id,
                        self.filter_folder_path,
                        if (has_search) self.search_query else null,
                        self.filters,
                    );
                }
                if (self.filter_folder_path) |fp| {
                    const lib_id = self.filter_library_id orelse break :blk try db.listAllImages(self.allocator);
                    break :blk try db.listImagesInFolder(self.allocator, lib_id, fp);
                } else if (self.filter_library_id) |lib_id| {
                    break :blk try db.listLibraryImages(self.allocator, lib_id);
                } else {
                    break :blk try db.listAllImages(self.allocator);
                }
            },
            .trash => try db.listTrashImages(self.allocator),
        };
        defer self.allocator.free(entries);
        try self.images.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |e| {
            self.images.appendAssumeCapacity(.{
                .id = e.id,
                .path = e.path,
                .filename = std.fs.path.basename(e.path),
                .mtime = e.mtime,
                .trashed_at = e.trashed_at,
                .trash_name = e.trash_name,
            });
        }
        self.applySortOrder();
    }

    /// Call once per frame before render(), on the main thread.
    pub fn update(self: *GridState) void {
        // 1. Drain new images from scan threads (library view only)
        if (self.view_mode == .library) {
            self.notifier.drain(self.io, self.allocator, &self.incoming);
        }
        const before_count = self.images.items.len;
        for (self.incoming.items) |e| {
            self.images.append(self.allocator, .{
                .id = e.id,
                .path = e.path,
                .filename = std.fs.path.basename(e.path),
                .mtime = e.mtime,
            }) catch {
                self.allocator.free(e.path);
                continue;
            };
        }
        self.incoming.clearAndFree(self.allocator);
        if (self.images.items.len != before_count) self.applySortOrder();

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

    pub fn applySortOrder(self: *GridState) void {
        switch (self.sort_mode) {
            .date => std.mem.sort(ImageEntry, self.images.items, self.sort_dir, imageDateLt),
            .name => std.mem.sort(ImageEntry, self.images.items, self.sort_dir, imageNameLt),
            .random => {
                var prng = std.Random.DefaultPrng.init(self.sort_seed);
                prng.random().shuffle(ImageEntry, self.images.items);
            },
        }
    }

    pub fn thumbSize(self: *const GridState) f32 {
        return thumb_size_min + self.thumb_fraction * (thumb_size_max - thumb_size_min);
    }

    /// Replace the current selection with all items in [from, to] (inclusive, order-independent).
    fn applyRangeSelect(self: *GridState, from: usize, to: usize) void {
        const n = self.images.items.len;
        if (n == 0) return;
        const lo = @min(from, to);
        const hi = @min(@max(from, to), n - 1);
        self.selection.clearRetainingCapacity();
        for (lo..hi + 1) |i| {
            self.selection.put(self.images.items[i].id, {}) catch {};
        }
    }

    /// Returns the actual on-disk path for an entry.
    /// For trash entries this is <data_dir>/trash/<trash_name>; for others it is entry.path.
    /// Caller is responsible for freeing if the returned slice != entry.path.
    fn diskPath(self: *GridState, entry: *const ImageEntry) []const u8 {
        const tn = entry.trash_name orelse return entry.path;
        const dd = self.data_dir orelse return entry.path;
        return std.fs.path.join(self.allocator, &.{ dd, "trash", tn }) catch entry.path;
    }

    fn requestLoad(self: *GridState, id: u64, path: []const u8, high: bool) void {
        if (self.committed.contains(id)) return;

        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queued.contains(id)) return;

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

    pub fn render(self: *GridState) void {
        const n = self.images.items.len;
        const ts = self.thumbSize();
        const cell_w = ts + gap;
        const cell_h = ts + label_h + gap;

        // Estimate virtual height before opening so the scrollbar decision is
        // right on the first paint.  Uses the previous frame's viewport width.
        {
            const prev_w = self.scroll_info.viewport.w;
            const est_cols: usize = if (prev_w > 1)
                @max(1, @as(usize, @intFromFloat(@floor(prev_w / cell_w))))
            else
                1;
            const est_rows: usize = if (n == 0) 0 else (n + est_cols - 1) / est_cols;
            self.scroll_info.virtual_size.h = @as(f32, @floatFromInt(est_rows)) * cell_h;
        }
        self.scroll_info.virtual_size.w = 0;
        self.scroll_info.vertical = .given;
        self.scroll_info.horizontal = .given;

        // Focusable container: receives keyboard events after any cell is clicked.
        var grid_box = dvui.box(@src(), .{}, .{ .expand = .both });
        defer grid_box.deinit();
        const grid_id = grid_box.data().id;

        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &self.scroll_info }, .{ .expand = .both });
        defer scroll.deinit();

        const avail_w = dvui.clipGet().w / dvui.windowNaturalScale();
        self.scroll_info.virtual_size.w = avail_w;
        if (avail_w < 1) return;

        const cols: usize = @max(1, @as(usize, @intFromFloat(@floor(avail_w / cell_w))));
        const total_rows: usize = if (n == 0) 0 else (n + cols - 1) / cols;
        const total_h = @as(f32, @floatFromInt(total_rows)) * cell_h;

        if (total_h != self.scroll_info.virtual_size.h) {
            self.scroll_info.virtual_size.h = total_h;
            dvui.refresh(null, @src(), scroll.data().id);
        }

        // Clamp focused_idx so it stays valid after image list changes.
        if (self.focused_idx) |fi| {
            if (n == 0) {
                self.focused_idx = null;
            } else if (fi >= n) {
                self.focused_idx = n - 1;
            }
        }

        // ── Keyboard navigation ──────────────────────────────────────────────
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            switch (e.evt) {
                .key => |ke| {
                    if (!dvui.eventMatch(e, .{ .id = grid_id, .r = grid_box.data().borderRectScale().r })) continue;
                    if (ke.action != .down and ke.action != .repeat) continue;
                    if (n == 0) continue;

                    const fi: usize = self.focused_idx orelse 0;

                    switch (ke.code) {
                        .left, .right, .up, .down => {
                            const delta: i64 = switch (ke.code) {
                                .left  => -1,
                                .right =>  1,
                                .up    => -@as(i64, @intCast(cols)),
                                .down  =>  @as(i64, @intCast(cols)),
                                else   => unreachable,
                            };
                            const raw = @as(i64, @intCast(fi)) + delta;
                            const new_fi: usize = if (raw < 0) 0
                                                  else @min(@as(usize, @intCast(raw)), n - 1);
                            self.focused_idx = new_fi;
                            self.scroll_to_focused = true;

                            if (ke.mod.shift()) {
                                // Extend range from anchor to new position.
                                self.applyRangeSelect(self.anchor_idx orelse fi, new_fi);
                            } else if (ke.mod.control()) {
                                // Move cursor only — selection unchanged.
                            } else {
                                self.selection.clearRetainingCapacity();
                                self.selection.put(self.images.items[new_fi].id, {}) catch {};
                                self.anchor_idx = new_fi;
                            }
                            e.handle(@src(), grid_box.data());
                        },
                        .space => {
                            if (ke.mod.shift()) {
                                self.applyRangeSelect(self.anchor_idx orelse fi, fi);
                            } else {
                                const id = self.images.items[fi].id;
                                if (self.selection.contains(id)) {
                                    _ = self.selection.remove(id);
                                } else {
                                    self.selection.put(id, {}) catch {};
                                }
                                self.anchor_idx = fi;
                            }
                            e.handle(@src(), grid_box.data());
                        },
                        .a => {
                            if (ke.mod.control()) {
                                for (self.images.items) |img| {
                                    self.selection.put(img.id, {}) catch {};
                                }
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .escape => {
                            self.selection.clearRetainingCapacity();
                            e.handle(@src(), grid_box.data());
                        },
                        .delete => {
                            if (self.selection.count() > 0 or self.focused_idx != null) {
                                self.delete_requested = true;
                                self.delete_force = ke.mod.shift();
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .r => {
                            if (self.view_mode == .trash and
                                (self.selection.count() > 0 or self.focused_idx != null))
                            {
                                self.restore_requested = true;
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .enter => {
                            self.open_viewer_requested = true;
                            self.viewer_start_id = self.images.items[fi].id;
                            e.handle(@src(), grid_box.data());
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // ── Scroll to keep focused item visible (keyboard nav only) ─────────
        if (self.scroll_to_focused) {
            if (self.focused_idx) |fi| {
                const row = fi / cols;
                const item_top = @as(f32, @floatFromInt(row)) * cell_h;
                const item_bot = item_top + cell_h;
                const vp_h = self.scroll_info.viewport.h;
                if (item_top < self.scroll_info.viewport.y) {
                    self.scroll_info.viewport.y = item_top;
                } else if (item_bot > self.scroll_info.viewport.y + vp_h) {
                    self.scroll_info.viewport.y = item_bot - vp_h;
                }
                self.scroll_to_focused = false;
            }
        }

        // ── Visible row range ────────────────────────────────────────────────
        const scroll_y = self.scroll_info.viewport.y;
        const scroll_h = self.scroll_info.viewport.h;
        const first_row: usize = @intCast(@max(
            0,
            @as(i64, @intFromFloat(@floor(scroll_y / cell_h))) - 1,
        ));
        const last_row: usize = @min(
            total_rows,
            @as(usize, @intFromFloat(@ceil((scroll_y + scroll_h) / cell_h))) + 1,
        );
        const visible_rows = if (last_row > first_row) last_row - first_row else 1;

        // Subtract border contribution (2px each side = 4px per cell) so total
        // cell width = h_margin + cell_border + ts + cell_border + h_margin == avail_w/cols.
        const h_margin = (avail_w - @as(f32, @floatFromInt(cols)) * (ts + 2 * cell_border)) / @as(f32, @floatFromInt(cols)) / 2.0;

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
                    const path = self.diskPath(entry);
                    defer if (path.ptr != entry.path.ptr) self.allocator.free(path);
                    self.requestLoad(entry.id, path, is_visible);
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
            });
            defer hrow.deinit();
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                const focused = if (self.focused_idx) |fi| fi == idx else false;
                self.renderItem(idx, ts, h_margin, focused, grid_id);
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

    fn renderItem(self: *GridState, idx: usize, ts: f32, h_margin: f32, focused: bool, grid_id: dvui.Id) void {
        const entry = self.images.items[idx];
        const selected = self.selection.contains(entry.id);

        // Border: blue when focused (keyboard cursor), invisible otherwise.
        // Selection is shown via a corner square instead (see below).
        const bg_color = dvui.themeGet().fill;
        const border_color: dvui.Color = if (focused) dvui.themeGet().focus else bg_color;

        var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx,
            .min_size_content = .{ .w = ts, .h = ts + label_h },
            .margin = .{ .x = h_margin, .y = gap / 2, .w = h_margin, .h = gap / 2 },
            .border = dvui.Rect.all(cell_border),
            .color_border = border_color,
        });
        defer cell.deinit();

        // ── Context menu (right-click) ────────────────────────────────────
        {
            const ctext = dvui.context(@src(), .{ .rect = cell.data().borderRectScale().r }, .{ .id_extra = idx });
            defer ctext.deinit();

            if (ctext.activePoint()) |cp| {
                // If the right-clicked item is not already in the selection, select only it.
                if (!self.selection.contains(entry.id)) {
                    self.selection.clearRetainingCapacity();
                    self.selection.put(entry.id, {}) catch {};
                    self.anchor_idx = idx;
                    self.focused_idx = idx;
                }

                var fm = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{ .id_extra = idx });
                defer fm.deinit();

                if (dvui.menuItemLabel(@src(), i18n.t(.context_view_image), .{},
                    .{ .expand = .horizontal }) != null)
                {
                    fm.close();
                    self.open_viewer_requested = true;
                    self.viewer_start_id = entry.id;
                }
                if (self.view_mode == .library) {
                    if (self.trash_enabled) {
                        if (dvui.menuItemLabel(@src(), i18n.t(.context_send_to_trash), .{}, .{ .expand = .horizontal }) != null) {
                            fm.close();
                            self.delete_requested = true;
                            self.delete_force = false;
                        }
                    }
                } else { // .trash
                    if (dvui.menuItemLabel(@src(), i18n.t(.context_restore_from_trash), .{}, .{ .expand = .horizontal }) != null) {
                        fm.close();
                        self.restore_requested = true;
                    }
                }
                if (dvui.menuItemLabel(@src(), i18n.t(.context_delete_permanently), .{}, .{ .expand = .horizontal }) != null) {
                    fm.close();
                    self.delete_requested = true;
                    self.delete_force = true;
                }
            }
        }

        if (dvui.clickedEx(cell.data(), .{})) |click_evt| {
            // Route subsequent key events to the grid container.
            dvui.focusWidget(grid_id, null, null);

            const mod = switch (click_evt) {
                .mouse => |me| me.mod,
                else => dvui.enums.Mod.none,
            };

            if (mod.control()) {
                // Ctrl+click: toggle this item, keep others.
                if (self.selection.contains(entry.id)) {
                    _ = self.selection.remove(entry.id);
                } else {
                    self.selection.put(entry.id, {}) catch {};
                }
                self.anchor_idx = idx;
            } else if (mod.shift()) {
                // Shift+click: range from anchor to clicked item.
                self.applyRangeSelect(self.anchor_idx orelse idx, idx);
            } else {
                // Plain click: single selection.
                self.selection.clearRetainingCapacity();
                self.selection.put(entry.id, {}) catch {};
                self.anchor_idx = idx;
            }
            self.focused_idx = idx;

            // Double-click detection: same image clicked twice within 400 ms.
            const now_ns: i96 = std.Io.Clock.real.now(self.io).nanoseconds;
            const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
            if (self.dblclick_last_id == entry.id and self.dblclick_last_ns > 0) {
                const delta_ms = now_ms - self.dblclick_last_ns;
                if (delta_ms >= 0 and delta_ms < 400) {
                    self.open_viewer_requested = true;
                    self.viewer_start_id = entry.id;
                    self.dblclick_last_id = 0;
                    self.dblclick_last_ns = 0;
                } else {
                    self.dblclick_last_id = entry.id;
                    self.dblclick_last_ns = now_ms;
                }
            } else {
                self.dblclick_last_id = entry.id;
                self.dblclick_last_ns = now_ms;
            }
        }

        // Fixed ts×ts area; dark background is the letterbox fill and loading placeholder.
        var img_rs: dvui.RectScale = undefined;
        {
            var img_area = dvui.box(@src(), .{}, .{
                .id_extra = idx,
                .min_size_content = .{ .w = ts, .h = ts },
                .background = true,
                .color_fill = .{ .r = 30, .g = 30, .b = 30, .a = 255 },
            });
            img_rs = img_area.data().contentRectScale();
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

        // Selection indicator: white right-triangle in the top-left and bottom-right corners.
        if (selected) {
            const sz = 12 * img_rs.s;
            const r = img_rs.r;
            const white = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 220 };
            const alloc = dvui.currentWindow().arena();

            var tl = dvui.Path.Builder.init(alloc);
            defer tl.deinit();
            tl.addPoint(.{ .x = r.x,        .y = r.y        });
            tl.addPoint(.{ .x = r.x + sz,   .y = r.y        });
            tl.addPoint(.{ .x = r.x,        .y = r.y + sz   });
            tl.build().fillConvex(.{ .color = white, .fade = 0 });

            var br = dvui.Path.Builder.init(alloc);
            defer br.deinit();
            br.addPoint(.{ .x = r.x + r.w,        .y = r.y + r.h        });
            br.addPoint(.{ .x = r.x + r.w - sz,   .y = r.y + r.h        });
            br.addPoint(.{ .x = r.x + r.w,        .y = r.y + r.h - sz   });
            br.build().fillConvex(.{ .color = white, .fade = 0 });
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

// ── Sort comparators ──────────────────────────────────────────────────────────

fn imageDateLt(dir: SortDir, a: ImageEntry, b: ImageEntry) bool {
    // null mtime sorts to end regardless of direction
    if (a.mtime == null and b.mtime == null) return false;
    if (a.mtime == null) return false;
    if (b.mtime == null) return true;
    return if (dir == .desc) a.mtime.? > b.mtime.? else a.mtime.? < b.mtime.?;
}

fn imageNameLt(dir: SortDir, a: ImageEntry, b: ImageEntry) bool {
    const cmp = std.mem.order(u8, a.filename, b.filename);
    return if (dir == .asc) cmp == .lt else cmp == .gt;
}

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
        defer state.allocator.free(req.path);

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
