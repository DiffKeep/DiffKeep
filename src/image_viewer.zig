const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");
const detail_panel_mod = @import("detail_panel.zig");
const config_mod = @import("config.zig");
const window_state = @import("window_state.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const vips_mod = @import("vips");

const cache_radius: usize = 2;
const cache_size: usize = cache_radius * 2 + 1; // 5 slots

// One slot in the prefetch cache.
const CacheSlot = struct {
    image_idx: usize = 0,
    active: bool = false, // slot is allocated for this image_idx
    ready: bool = false,  // pixels have been decoded
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
};

pub const ViewerState = struct {
    id: u64,
    gpa: std.mem.Allocator,
    io: std.Io,
    images: std.ArrayList(image_grid_mod.ImageEntry),
    current_idx: usize,

    // Currently displayed image (gpa-owned).
    image_pixels: ?[]u8 = null,
    image_width: u32 = 0,
    image_height: u32 = 0,
    image_texture_hash: u64 = 0,

    // Prefetch cache.  cache_mutex protects both cache_slots and cache_threads.
    // Thread handles are managed only by the main thread.
    cache_slots: [cache_size]CacheSlot,
    cache_threads: [cache_size]?std.Thread,
    cache_mutex: std.Io.Mutex = std.Io.Mutex.init,
    // Handles for evicted threads (can't join immediately); joined at deinit.
    orphan_threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    // Number of load threads that have not yet exited.  Lets the close path defer
    // joining until the (uncancellable) decodes have finished, so it never blocks.
    inflight: std.atomic.Value(u32) = .init(0),

    // Pan/zoom
    zoom: f32 = 1.0,
    zoom_mode: enum { fit, pct100, custom } = .fit,
    pan_x: f32 = 0,
    pan_y: f32 = 0,

    // Info pane
    info_open: bool = false,
    info_w: f32 = 280,
    info_w_open: f32 = 280,
    detail_state: detail_panel_mod.DetailState = .{},
    db: ?*db_mod.VectorDb = null,

    // Window state
    open: bool = true,
    fullscreen: bool = false,
    sdl_window_ptr: ?*SDLBackend.c.SDL_Window = null,

    // Pending actions consumed by app.zig
    delete_requested: bool = false,
    delete_force: bool = false,
    // Set when the toolbar drag handle gesture fires; app.zig starts the native
    // drag of the current image.  dnd_available gates showing the handle at all.
    drag_requested: bool = false,
    dnd_available: bool = false,
    // Confirmation dialog state.  app.zig sets delete_confirm_open; viewer renders
    // the dialog; app.zig consumes delete_confirmed / delete_no_ask.
    delete_confirm_open: bool = false,
    delete_pending_permanent: bool = false,
    delete_pending_id: u64 = 0,
    delete_pending_name_buf: [512]u8 = undefined,
    delete_pending_name_len: usize = 0,
    delete_confirmed: bool = false,
    delete_no_ask: bool = false,
    wakeup_fn: ?*const fn () void = null,
    data_dir: ?[]const u8 = null,
    // Persisted UI preferences (shared with app config). Changes to fullscreen,
    // info_open and info_w are written back here so they survive across viewers
    // and program restarts.
    cfg: ?*config_mod.Config = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        images: std.ArrayList(image_grid_mod.ImageEntry),
        start_idx: usize,
        wakeup_fn: ?*const fn () void,
        data_dir: ?[]const u8,
        io: std.Io,
        db: ?*db_mod.VectorDb,
        cfg: ?*config_mod.Config,
    ) ViewerState {
        var state = ViewerState{
            .id = id,
            .gpa = allocator,
            .io = io,
            .images = images,
            .current_idx = start_idx,
            .wakeup_fn = wakeup_fn,
            .data_dir = data_dir,
            .db = db,
            .cfg = cfg,
            .cache_slots = undefined,
            .cache_threads = undefined,
        };
        for (&state.cache_slots) |*s| s.* = .{};
        for (&state.cache_threads) |*t| t.* = null;
        // Restore remembered UI preferences.
        if (cfg) |c| {
            state.fullscreen = c.viewer_window.fullscreen;
            state.info_open = c.viewer_info_open;
            state.info_w = c.viewer_info_w;
            state.info_w_open = c.viewer_info_w;
        }
        if (db != null and images.items.len > 0) {
            state.detail_state.update(images.items[start_idx].id, db.?, allocator, io);
        }
        // Load threads are spawned on the first render() call, once self is stable.
        return state;
    }

    /// Begin closing: tell in-flight load threads to discard their results so the
    /// window can disappear immediately.  The (uncancellable) decodes still run to
    /// completion in the background; `deinit` joins them later once `inflight`
    /// reaches 0, so neither this call nor the join blocks the UI.
    pub fn beginClose(self: *ViewerState) void {
        self.cache_mutex.lockUncancelable(self.io);
        defer self.cache_mutex.unlock(self.io);
        for (&self.cache_slots) |*slot| {
            slot.active = false;
            slot.ready = false;
        }
    }

    /// True once every background load thread has exited; `deinit` can then join
    /// them without blocking.
    pub fn closeReady(self: *const ViewerState) bool {
        return self.inflight.load(.acquire) == 0;
    }

    pub fn deinit(self: *ViewerState) void {
        // Mark all slots inactive so in-flight threads will discard their results.
        // Collect thread handles while holding the lock, then join without it.
        var threads: [cache_size]?std.Thread = undefined;
        {
            self.cache_mutex.lockUncancelable(self.io);
            for (&self.cache_slots, 0..) |*slot, i| {
                if (slot.pixels) |p| { self.gpa.free(p); slot.pixels = null; }
                slot.active = false;
                slot.ready = false;
                threads[i] = self.cache_threads[i];
                self.cache_threads[i] = null;
            }
            self.cache_mutex.unlock(self.io);
        }
        for (threads) |maybe_t| { if (maybe_t) |t| t.join(); }
        for (self.orphan_threads.items) |t| t.join();
        self.orphan_threads.deinit(self.gpa);

        if (self.image_pixels) |p| self.gpa.free(p);
        for (self.images.items) |e| self.gpa.free(e.path);
        self.images.deinit(self.gpa);
        self.detail_state.deinit(self.gpa);
    }

    // Promote a ready cache entry for current_idx into image_pixels.
    // Called at the top of render() so a prefetched image appears in the same
    // frame as the navigation key-press.
    fn drainCache(self: *ViewerState) void {
        if (self.image_pixels != null) return;

        self.cache_mutex.lockUncancelable(self.io);
        defer self.cache_mutex.unlock(self.io);

        for (&self.cache_slots, 0..) |*slot, i| {
            if (!slot.active or !slot.ready or slot.image_idx != self.current_idx) continue;
            const pixels = slot.pixels orelse continue;

            self.image_pixels = pixels;
            self.image_width = slot.width;
            self.image_height = slot.height;
            slot.pixels = null;
            slot.active = false;
            slot.ready = false;

            const src = dvui.ImageSource{ .pixels = .{
                .rgba = pixels,
                .width = slot.width,
                .height = slot.height,
            } };
            self.image_texture_hash = src.hash();

            // Thread has finished; join it now (it has already exited or will
            // momentarily after releasing the lock it holds here).
            if (self.cache_threads[i]) |t| {
                self.cache_mutex.unlock(self.io);
                t.join();
                self.cache_mutex.lockUncancelable(self.io);
                self.cache_threads[i] = null;
            }
            return;
        }
    }

    // Maintain the cache window [current_idx-2, current_idx+2].
    // Evicts entries that have fallen outside and starts loads for missing ones.
    // Guards against duplicate loads: an index is skipped if it is already
    // active in the cache, or is current_idx and already displayed.
    fn updateCache(self: *ViewerState) void {
        const n = self.images.items.len;
        if (n == 0) return;

        const idx = self.current_idx;
        const lo = idx -| cache_radius;
        const hi = @min(idx + cache_radius, n - 1);

        const LoadTask = struct { slot_i: usize, image_idx: usize, path: [:0]u8 };
        var tasks: [cache_size]LoadTask = undefined;
        var task_count: usize = 0;

        {
            self.cache_mutex.lockUncancelable(self.io);
            defer self.cache_mutex.unlock(self.io);

            // Evict slots that have fallen outside the window.
            for (&self.cache_slots, 0..) |*slot, i| {
                if (!slot.active) continue;
                if (slot.image_idx < lo or slot.image_idx > hi) {
                    if (slot.pixels) |p| { self.gpa.free(p); slot.pixels = null; }
                    slot.active = false;
                    slot.ready = false;
                    if (self.cache_threads[i]) |t| {
                        // Can't join here (we hold the mutex); park for deinit.
                        self.orphan_threads.append(self.gpa, t) catch t.join();
                        self.cache_threads[i] = null;
                    }
                }
            }

            // Queue loads for desired indices not already present.
            var wi = lo;
            while (wi <= hi) : (wi += 1) {
                // Skip if already in cache (loading or ready).
                var found = false;
                for (&self.cache_slots) |*slot| {
                    if (slot.active and slot.image_idx == wi) { found = true; break; }
                }
                if (found) continue;

                // Skip current_idx if it is already displayed.
                if (wi == self.current_idx and self.image_pixels != null) continue;

                // Find a free slot.
                var free_i: ?usize = null;
                for (&self.cache_slots, 0..) |*slot, i| {
                    if (!slot.active) { free_i = i; break; }
                }
                const si = free_i orelse continue;

                const path_copy = self.gpa.dupeZ(u8, self.images.items[wi].path) catch continue;
                self.cache_slots[si] = .{ .active = true, .image_idx = wi };
                if (task_count < cache_size) {
                    tasks[task_count] = .{ .slot_i = si, .image_idx = wi, .path = path_copy };
                    task_count += 1;
                } else {
                    self.gpa.free(path_copy);
                    self.cache_slots[si].active = false;
                }
            }
        }

        // Spawn threads outside the lock.
        for (tasks[0..task_count]) |task| {
            _ = self.inflight.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, loadCacheThread, .{
                self.gpa, self.io, self, task.slot_i, task.image_idx, task.path,
            }) catch {
                _ = self.inflight.fetchSub(1, .acq_rel);
                self.gpa.free(task.path);
                self.cache_mutex.lockUncancelable(self.io);
                self.cache_slots[task.slot_i].active = false;
                self.cache_mutex.unlock(self.io);
                continue;
            };
            self.cache_mutex.lockUncancelable(self.io);
            self.cache_threads[task.slot_i] = t;
            self.cache_mutex.unlock(self.io);
        }
    }

    pub fn navigateTo(self: *ViewerState, idx: usize) void {
        if (self.images.items.len == 0) return;
        self.current_idx = @min(idx, self.images.items.len - 1);
        if (self.image_pixels) |p| {
            dvui.textureInvalidateCache(self.image_texture_hash);
            self.gpa.free(p);
            self.image_pixels = null;
            self.image_texture_hash = 0;
        }
        self.image_width = 0;
        self.image_height = 0;
        self.pan_x = 0;
        self.pan_y = 0;
        self.zoom_mode = .fit;
        if (self.db) |db| {
            self.detail_state.update(self.images.items[self.current_idx].id, db, self.gpa, self.io);
        }
        // drainCache() + updateCache() in the next render() handle the actual load.
    }

    pub fn currentImage(self: *const ViewerState) ?*const image_grid_mod.ImageEntry {
        if (self.images.items.len == 0) return null;
        return &self.images.items[self.current_idx];
    }

    pub fn removeImages(self: *ViewerState, ids: *const std.AutoHashMap(u64, void)) void {
        var i: usize = 0;
        var any_removed = false;
        var removed_current = false;
        while (i < self.images.items.len) {
            const e = self.images.items[i];
            if (ids.contains(e.id)) {
                self.gpa.free(e.path);
                _ = self.images.orderedRemove(i);
                any_removed = true;
                if (i == self.current_idx) removed_current = true else if (i < self.current_idx) self.current_idx -|= 1;
            } else i += 1;
        }
        if (self.images.items.len == 0) { self.open = false; return; }
        if (!any_removed) return;
        // Any removal shifts subsequent indices, invalidating all cache slots.
        self.flushCache();
        if (removed_current) {
            self.current_idx = @min(self.current_idx, self.images.items.len - 1);
            self.navigateTo(self.current_idx);
        }
    }

    // Mark all cache slots inactive and park their threads as orphans.
    // Called when the images list is mutated (indices shift).
    fn flushCache(self: *ViewerState) void {
        var threads: [cache_size]?std.Thread = undefined;
        {
            self.cache_mutex.lockUncancelable(self.io);
            for (&self.cache_slots, 0..) |*slot, i| {
                if (slot.pixels) |p| { self.gpa.free(p); slot.pixels = null; }
                slot.active = false;
                slot.ready = false;
                threads[i] = self.cache_threads[i];
                self.cache_threads[i] = null;
            }
            self.cache_mutex.unlock(self.io);
        }
        for (threads) |maybe_t| {
            if (maybe_t) |t| self.orphan_threads.append(self.gpa, t) catch t.join();
        }
    }

    pub fn render(self: *ViewerState) void {
        self.captureWindowState();
        self.drainCache();
        self.updateCache();
        self.handleKeyEvents();
        if (self.delete_confirm_open) self.renderDeleteConfirmDialog();

        var outer = dvui.box(@src(), .{}, .{ .expand = .both, .background = true });
        defer outer.deinit();

        self.renderToolbar();

        var content_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer content_row.deinit();

        self.renderImageArea();

        if (self.info_open) {
            self.renderInfoHandle();
            self.renderInfoPane();
        }
    }

    fn handleKeyEvents(self: *ViewerState) void {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .key) continue;
            const ke = e.evt.key;
            if (ke.action != .down and ke.action != .repeat) continue;
            switch (ke.code) {
                .left => {
                    e.handled = true;
                    if (self.current_idx > 0) self.navigateTo(self.current_idx - 1);
                },
                .right => {
                    e.handled = true;
                    if (self.current_idx + 1 < self.images.items.len) self.navigateTo(self.current_idx + 1);
                },
                .home => {
                    e.handled = true;
                    if (self.images.items.len > 0) self.navigateTo(0);
                },
                .end => {
                    e.handled = true;
                    if (self.images.items.len > 0) self.navigateTo(self.images.items.len - 1);
                },
                .equal, .kp_add => {
                    e.handled = true;
                    self.zoom = std.math.clamp(self.zoom * 1.25, 0.05, 32.0);
                    self.zoom_mode = .custom;
                },
                .minus, .kp_subtract => {
                    e.handled = true;
                    self.zoom = std.math.clamp(self.zoom * 0.8, 0.05, 32.0);
                    self.zoom_mode = .custom;
                },
                .zero, .kp_0 => {
                    e.handled = true;
                    self.zoom_mode = .fit;
                    self.pan_x = 0;
                    self.pan_y = 0;
                },
                .one, .kp_1 => {
                    e.handled = true;
                    self.zoom = 1.0;
                    self.zoom_mode = .pct100;
                    self.pan_x = 0;
                    self.pan_y = 0;
                },
                .f11, .f => {
                    e.handled = true;
                    self.toggleFullscreen();
                },
                .i => {
                    e.handled = true;
                    self.info_open = !self.info_open;
                    self.persistPrefs();
                },
                .escape => {
                    e.handled = true;
                    self.open = false;
                },
                .delete => {
                    e.handled = true;
                    self.delete_requested = true;
                    self.delete_force = ke.mod.shift();
                },
                else => {},
            }
        }
    }

    fn renderDeleteConfirmDialog(self: *ViewerState) void {
        var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
            .min_size_content = .{ .w = 360, .h = 0 },
        });
        defer float.deinit();
        float.autoSize();

        var content = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(16) });
        defer content.deinit();

        const title = if (self.delete_pending_permanent)
            i18n.t(.confirm_delete_title)
        else
            i18n.t(.confirm_trash_title);
        dvui.label(@src(), "{s}", .{title}, .{ .font = dvui.themeGet().font_heading, .margin = .{ .h = 8 } });

        const name = self.delete_pending_name_buf[0..self.delete_pending_name_len];
        dvui.label(@src(), "{s}", .{name}, .{ .margin = .{ .h = 12 } });

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
        defer btn_row.deinit();

        if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
            self.delete_confirm_open = false;
        }

        const skip_label = if (self.delete_pending_permanent)
            i18n.t(.confirm_delete_no_ask)
        else
            i18n.t(.confirm_trash_no_ask);
        if (dvui.button(@src(), skip_label, .{}, .{ .margin = .all(4) })) {
            self.delete_confirm_open = false;
            self.delete_no_ask = true;
            self.delete_confirmed = true;
        }

        const confirm_label = if (self.delete_pending_permanent)
            i18n.t(.confirm_delete)
        else
            i18n.t(.confirm_move_to_trash);
        if (dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4) })) {
            self.delete_confirm_open = false;
            self.delete_confirmed = true;
        }
    }

    fn renderToolbar(self: *ViewerState) void {
        var tb = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4 },
            .background = true,
            .min_size_content = .{ .h = 28 },
        });
        defer tb.deinit();

        if (iconButton(i18n.t(.viewer_first), icons.tvg.lucide.@"chevrons-left", 1)) {
            if (self.images.items.len > 0) self.navigateTo(0);
        }

        if (iconButton(i18n.t(.viewer_prev), icons.tvg.lucide.@"chevron-left", 2)) {
            if (self.current_idx > 0) self.navigateTo(self.current_idx - 1);
        }

        if (iconButton(i18n.t(.viewer_next), icons.tvg.lucide.@"chevron-right", 3)) {
            if (self.current_idx + 1 < self.images.items.len) self.navigateTo(self.current_idx + 1);
        }

        if (iconButton(i18n.t(.viewer_last), icons.tvg.lucide.@"chevrons-right", 4)) {
            if (self.images.items.len > 0) self.navigateTo(self.images.items.len - 1);
        }

        const filename: []const u8 = if (self.images.items.len > 0)
            self.images.items[self.current_idx].filename
        else "";

        var label_buf: [256]u8 = undefined;
        const label_str = if (self.images.items.len > 0)
            std.fmt.bufPrint(&label_buf, "{s}  \u{00b7}  {d} {s} {d}",
                .{ filename, self.current_idx + 1, i18n.t(.viewer_of), self.images.items.len })
            catch filename
        else filename;

        dvui.label(@src(), "{s}", .{label_str}, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 0 },
        });

        if (self.image_width > 0) {
            var zoom_buf: [16]u8 = undefined;
            const zoom_str = std.fmt.bufPrint(&zoom_buf, "{d:.0}%", .{self.zoom * 100}) catch "";
            dvui.label(@src(), "{s}", .{zoom_str}, .{
                .gravity_y = 0.5,
                .padding = .{ .x = 4, .y = 0 },
            });
        }

        if (textButton(i18n.t(.viewer_zoom_fit), i18n.t(.viewer_zoom_fit_hint), 5)) {
            self.zoom_mode = .fit;
            self.pan_x = 0;
            self.pan_y = 0;
        }

        if (textButton(i18n.t(.viewer_zoom_100), i18n.t(.viewer_zoom_100_hint), 6)) {
            self.zoom = 1.0;
            self.zoom_mode = .pct100;
            self.pan_x = 0;
            self.pan_y = 0;
        }

        const fs_icon = if (self.fullscreen)
            icons.tvg.lucide.minimize
        else
            icons.tvg.lucide.maximize;
        const fs_label = if (self.fullscreen) i18n.t(.viewer_exit_fullscreen) else i18n.t(.viewer_fullscreen);
        if (iconButton(fs_label, fs_icon, 7)) {
            self.toggleFullscreen();
        }

        if (iconButton(i18n.t(.viewer_toggle_info), icons.tvg.lucide.@"panel-right", 8)) {
            self.info_open = !self.info_open;
            self.persistPrefs();
        }

        if (self.images.items.len > 0 and
            iconButton(i18n.t(.action_copy_image), icons.tvg.lucide.@"clipboard-copy", 11))
        {
            if (self.currentImage()) |img|
                detail_panel_mod.copyImageToClipboard(img.path, self.gpa, self.io);
        }

        if (self.dnd_available and self.images.items.len > 0) {
            if (dragButton(i18n.t(.viewer_drag), icons.tvg.lucide.grab, 9)) self.drag_requested = true;
        }

        if (iconButton(i18n.t(.viewer_delete), icons.tvg.lucide.trash, 10)) {
            self.delete_requested = true;
            self.delete_force = false;
        }
    }

    // Shared button styling for the toolbar.  `id_extra` makes each call site a
    // distinct widget (all helpers share one @src()).
    const tb_btn_size: dvui.Size = .{ .w = 22, .h = 22 };

    // Options for an icon-sized toolbar button, matching `dvui.buttonIcon`.
    fn iconBtnOpts(id_extra: usize, label: [:0]const u8) dvui.Options {
        return .{
            .id_extra = id_extra,
            .padding = .all(4),
            .min_size_content = tb_btn_size,
            .gravity_y = 0.5,
            .label = .{ .text = label },
        };
    }

    // The child icon's options, mirroring `dvui.buttonIcon` exactly: start from a
    // STRIPPED copy of the button opts (so the icon inherits no padding/background
    // of its own) then layer the button's hover/press style on top.
    fn iconChildOpts(bw: *dvui.ButtonWidget, opts: dvui.Options) dvui.Options {
        return opts.strip().override(bw.style()).override(.{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = opts.min_size_content,
            .expand = .ratio,
            .color_text = opts.color_text,
            .role = .none,
        });
    }

    fn btnTooltip(bw: *dvui.ButtonWidget, tip: [:0]const u8) void {
        dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 },
            "{s}", .{tip}, .{});
    }

    /// Icon toolbar button matching `dvui.buttonIcon`, with a hover tooltip.
    fn iconButton(label: [:0]const u8, tvg: []const u8, id_extra: usize) bool {
        const opts = iconBtnOpts(id_extra, label);
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, opts);
        bw.processEvents();
        bw.drawBackground();
        dvui.icon(@src(), label, tvg, .{}, iconChildOpts(&bw, opts));
        const click = bw.clicked();
        bw.drawFocus();
        btnTooltip(&bw, label);
        bw.deinit();
        return click;
    }

    /// Text toolbar button (e.g. zoom controls), with a descriptive hover hint.
    /// Sized to match the icon buttons (same padding + content height).
    fn textButton(label: [:0]const u8, hint: [:0]const u8, id_extra: usize) bool {
        const opts = dvui.Options{
            .id_extra = id_extra,
            .padding = .all(4),
            .min_size_content = .{ .h = tb_btn_size.h },
            .gravity_y = 0.5,
            .label = .{ .text = label },
        };
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, opts);
        bw.processEvents();
        bw.drawBackground();
        dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 },
            opts.strip().override(bw.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
        const click = bw.clicked();
        bw.drawFocus();
        btnTooltip(&bw, hint);
        bw.deinit();
        return click;
    }

    /// Like `iconButton`, but instead of a click it reports a drag gesture: the
    /// pointer pressed on the button and moved past the drag threshold.  Used to
    /// drag the current image out to another app via native drag-and-drop.
    fn dragButton(label: [:0]const u8, tvg: []const u8, id_extra: usize) bool {
        const opts = iconBtnOpts(id_extra, label);
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .touch_drag = true }, opts);
        bw.processEvents();
        bw.drawBackground();
        if (bw.hovered()) dvui.cursorSet(.hand);

        // dvui.clicked() (in processEvents) already captured the mouse and armed
        // the drag on press; fire once it crosses the threshold and cancel the
        // pending click so the gesture isn't also treated as one.
        var started = false;
        if (dvui.captured(bw.data().id)) {
            for (dvui.events()) |*e| {
                if (e.handled or e.evt != .mouse) continue;
                const me = e.evt.mouse;
                if (me.action != .motion) continue;
                if (dvui.dragging(me.p, null) != null) {
                    e.handle(@src(), bw.data());
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    started = true;
                }
            }
        }

        dvui.icon(@src(), label, tvg, .{}, iconChildOpts(&bw, opts));
        bw.drawFocus();
        btnTooltip(&bw, label);
        bw.deinit();
        return started;
    }

    fn renderImageArea(self: *ViewerState) void {
        var area = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .r = 15, .g = 15, .b = 15, .a = 255 },
        });
        defer area.deinit();

        const wd = area.data();
        const crs = wd.contentRectScale();

        if (self.zoom_mode == .fit and self.image_width > 0 and self.image_height > 0) {
            const cw = crs.r.w / crs.s;
            const ch = crs.r.h / crs.s;
            self.zoom = @min(cw / @as(f32, @floatFromInt(self.image_width)),
                             ch / @as(f32, @floatFromInt(self.image_height)));
        }

        self.handleAreaMouseEvents(wd, crs);

        if (self.image_pixels) |pixels| {
            const s = crs.s;
            const img_w_p = @as(f32, @floatFromInt(self.image_width)) * self.zoom * s;
            const img_h_p = @as(f32, @floatFromInt(self.image_height)) * self.zoom * s;
            const cx = crs.r.x + crs.r.w / 2.0 + self.pan_x * self.zoom * s;
            const cy = crs.r.y + crs.r.h / 2.0 + self.pan_y * self.zoom * s;
            const img_rect = dvui.Rect.Physical{
                .x = cx - img_w_p / 2.0,
                .y = cy - img_h_p / 2.0,
                .w = img_w_p,
                .h = img_h_p,
            };
            const prev_clip = dvui.clipGet();
            dvui.clipSet(crs.r.intersect(prev_clip));
            dvui.renderImage(
                .{ .pixels = .{
                    .rgba = pixels,
                    .width = self.image_width,
                    .height = self.image_height,
                    .invalidation = .ptr,
                } },
                .{ .r = img_rect, .s = s },
                .{},
            ) catch {};
            dvui.clipSet(prev_clip);
        } else if (self.images.items.len > 0) {
            dvui.spinner(@src(), .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 32, .h = 32 },
            });
        }
    }

    fn handleAreaMouseEvents(self: *ViewerState, wd: *dvui.WidgetData, crs: dvui.RectScale) void {
        const id = wd.id;
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            switch (me.action) {
                .wheel_y => |dy| {
                    if (!dvui.eventMatchSimple(e, wd)) continue;
                    e.handled = true;
                    const s = crs.s;
                    const cx = crs.r.x + crs.r.w / 2.0 + self.pan_x * self.zoom * s;
                    const cy = crs.r.y + crs.r.h / 2.0 + self.pan_y * self.zoom * s;
                    const cursor_img_x = (me.p.x - cx) / (self.zoom * s);
                    const cursor_img_y = (me.p.y - cy) / (self.zoom * s);
                    const factor: f32 = if (dy > 0) 1.12 else (1.0 / 1.12);
                    const new_zoom = std.math.clamp(self.zoom * factor, 0.05, 32.0);
                    self.pan_x += cursor_img_x * (self.zoom - new_zoom);
                    self.pan_y += cursor_img_y * (self.zoom - new_zoom);
                    self.zoom = new_zoom;
                    self.zoom_mode = .custom;
                },
                .press => {
                    if (me.button.pointer() and dvui.eventMatchSimple(e, wd)) {
                        e.handled = true;
                        dvui.captureMouse(wd, e.num);
                        dvui.dragPreStart(me.p, .{});
                    }
                },
                .motion => |delta| {
                    if (dvui.captured(id)) {
                        if (dvui.dragging(me.p, null) != null) {
                            e.handled = true;
                            const s = crs.s;
                            self.pan_x += delta.x / (self.zoom * s);
                            self.pan_y += delta.y / (self.zoom * s);
                            self.zoom_mode = .custom;
                        }
                    }
                },
                .release => {
                    if (dvui.captured(id)) {
                        e.handled = true;
                        dvui.captureMouse(null, e.num);
                    }
                },
                else => {},
            }
        }
    }

    fn renderInfoHandle(self: *ViewerState) void {
        var h = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 8, .h = 0 },
            .expand = .vertical,
            .background = true,
        });
        defer h.deinit();

        const id = h.data().id;
        const scale = h.data().contentRectScale().s;

        for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            switch (me.action) {
                .position => {
                    if (dvui.eventMatchSimple(e, h.data())) dvui.cursorSet(.arrow_w_e);
                },
                .press => {
                    if (me.button.pointer() and dvui.eventMatchSimple(e, h.data())) {
                        e.handled = true;
                        dvui.captureMouse(h.data(), e.num);
                        dvui.dragPreStart(me.p, .{ .cursor = .arrow_w_e });
                    }
                },
                .motion => |delta| {
                    if (dvui.captured(id)) {
                        if (dvui.dragging(me.p, null) != null) {
                            e.handled = true;
                            self.info_w = std.math.clamp(self.info_w - delta.x / scale, 120, 600);
                            self.info_w_open = self.info_w;
                            self.persistPrefs();
                        }
                    }
                },
                .release => {
                    if (dvui.captured(id)) {
                        e.handled = true;
                        dvui.captureMouse(null, e.num);
                    }
                },
                else => {},
            }
        }
    }

    fn renderInfoPane(self: *ViewerState) void {
        const filename: []const u8 = if (self.images.items.len > 0)
            self.images.items[self.current_idx].filename
        else "";
        self.detail_state.renderPanel(self.info_w, filename, self.gpa, self.io);
    }

    fn toggleFullscreen(self: *ViewerState) void {
        if (self.sdl_window_ptr) |win| {
            self.fullscreen = !self.fullscreen;
            _ = SDLBackend.c.SDL_SetWindowFullscreen(win, self.fullscreen);
            self.persistPrefs();
        }
    }

    // Copy the current UI preferences into the shared config so they are
    // remembered by subsequently-opened viewers and saved on program exit.
    fn persistPrefs(self: *ViewerState) void {
        if (self.cfg) |c| {
            c.viewer_window.fullscreen = self.fullscreen;
            c.viewer_info_open = self.info_open;
            c.viewer_info_w = self.info_w;
        }
    }

    // Sample the live SDL window each frame and remember its size, position,
    // maximized and fullscreen state in the shared config.
    fn captureWindowState(self: *ViewerState) void {
        const cfg = self.cfg orelse return;
        const win = self.sdl_window_ptr orelse return;
        window_state.capture(win, &cfg.viewer_window);
    }
};

fn loadCacheThread(
    gpa: std.mem.Allocator,
    io: std.Io,
    state: *ViewerState,
    slot_i: usize,
    image_idx: usize,
    path: [:0]u8,
) void {
    defer _ = state.inflight.fetchSub(1, .acq_rel);
    defer gpa.free(path);
    defer vips_mod.threadShutdown();

    const result = vips_mod.loadImageRgbaWithDims(gpa, path) catch return;

    var should_wakeup = false;
    {
        state.cache_mutex.lockUncancelable(io);
        defer state.cache_mutex.unlock(io);

        const slot = &state.cache_slots[slot_i];
        if (!slot.active or slot.image_idx != image_idx) {
            // Slot was evicted or reused while we were loading; discard result.
            gpa.free(result.pixels);
        } else {
            if (slot.pixels) |old| gpa.free(old);
            slot.pixels = result.pixels;
            slot.width = result.width;
            slot.height = result.height;
            slot.ready = true;
            should_wakeup = true;
        }
    }

    if (should_wakeup) {
        if (state.wakeup_fn) |wakeup| wakeup();
    }
}
