const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");
const detail_panel_mod = @import("detail_panel.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");

pub const ViewerState = struct {
    id: u64,
    gpa: std.mem.Allocator,
    io: std.Io,
    images: std.ArrayList(image_grid_mod.ImageEntry),
    current_idx: usize,

    // Full-res image data (owned by this struct)
    image_bytes: ?[]u8 = null,
    image_width: u32 = 0,
    image_height: u32 = 0,

    // Pending image from load thread
    pending_bytes: ?[]u8 = null,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    pending_mutex: std.Io.Mutex = std.Io.Mutex.init,
    load_thread: ?std.Thread = null,
    stop_load: std.atomic.Value(bool) = .init(false),

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
    wakeup_fn: ?*const fn () void = null,
    data_dir: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        images: std.ArrayList(image_grid_mod.ImageEntry),
        start_idx: usize,
        wakeup_fn: ?*const fn () void,
        data_dir: ?[]const u8,
        io: std.Io,
        db: ?*db_mod.VectorDb,
    ) ViewerState {
        var state: ViewerState = .{
            .id = id,
            .gpa = allocator,
            .io = io,
            .images = images,
            .current_idx = start_idx,
            .wakeup_fn = wakeup_fn,
            .data_dir = data_dir,
            .db = db,
        };
        if (db != null and images.items.len > 0) {
            state.detail_state.update(images.items[start_idx].id, db.?, allocator, io);
        }
        // spawnLoadThread() is intentionally NOT called here: init() returns by value,
        // and spawning a thread with &state before the caller places the struct at its
        // final address would give the thread a dangling pointer.  The first render()
        // call spawns the thread once self is stable.
        return state;
    }

    pub fn deinit(self: *ViewerState) void {
        self.stop_load.store(true, .release);
        if (self.load_thread) |t| {
            t.join();
            self.load_thread = null;
        }
        self.pending_mutex.lockUncancelable(self.io);
        if (self.pending_bytes) |b| self.gpa.free(b);
        self.pending_bytes = null;
        self.pending_mutex.unlock(self.io);
        if (self.image_bytes) |b| self.gpa.free(b);
        self.image_bytes = null;
        for (self.images.items) |e| self.gpa.free(e.path);
        self.images.deinit(self.gpa);
        self.detail_state.deinit(self.gpa);
    }

    fn spawnLoadThread(self: *ViewerState) void {
        if (self.images.items.len == 0) return;
        const entry = self.images.items[self.current_idx];
        self.stop_load.store(true, .release);
        if (self.load_thread) |t| {
            t.join();
            self.load_thread = null;
        }
        self.stop_load.store(false, .release);
        const path_copy = self.gpa.dupe(u8, entry.path) catch return;
        self.load_thread = std.Thread.spawn(.{}, loadImageThread, .{
            self.gpa, self.io, self, path_copy,
        }) catch {
            self.gpa.free(path_copy);
            return;
        };
    }

    fn drainPendingLoad(self: *ViewerState) void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        const bytes = self.pending_bytes orelse return;
        self.pending_bytes = null;
        if (self.image_bytes) |old| self.gpa.free(old);
        self.image_bytes = bytes;
        self.image_width = self.pending_width;
        self.image_height = self.pending_height;
    }

    pub fn navigateTo(self: *ViewerState, idx: usize) void {
        if (self.images.items.len == 0) return;
        self.current_idx = @min(idx, self.images.items.len - 1);
        if (self.image_bytes) |b| { self.gpa.free(b); self.image_bytes = null; }
        self.image_width = 0;
        self.image_height = 0;
        self.pan_x = 0;
        self.pan_y = 0;
        self.zoom_mode = .fit;
        if (self.db) |db| {
            self.detail_state.update(self.images.items[self.current_idx].id, db, self.gpa, self.io);
        }
        self.spawnLoadThread();
    }

    pub fn currentImage(self: *const ViewerState) ?*const image_grid_mod.ImageEntry {
        if (self.images.items.len == 0) return null;
        return &self.images.items[self.current_idx];
    }

    pub fn removeImages(self: *ViewerState, ids: *const std.AutoHashMap(u64, void)) void {
        var i: usize = 0;
        var removed_current = false;
        while (i < self.images.items.len) {
            const e = self.images.items[i];
            if (ids.contains(e.id)) {
                self.gpa.free(e.path);
                _ = self.images.orderedRemove(i);
                if (i == self.current_idx) removed_current = true else if (i < self.current_idx) self.current_idx -|= 1;
            } else i += 1;
        }
        if (self.images.items.len == 0) { self.open = false; return; }
        if (removed_current) {
            self.current_idx = @min(self.current_idx, self.images.items.len - 1);
            self.navigateTo(self.current_idx);
        }
    }

    pub fn render(self: *ViewerState) void {
        // Spawn the initial load thread on the first render, when self is stable.
        if (self.load_thread == null and self.image_bytes == null and self.images.items.len > 0) {
            self.spawnLoadThread();
        }
        self.drainPendingLoad();
        self.handleKeyEvents();

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

    fn renderToolbar(self: *ViewerState) void {
        var tb = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4 },
            .background = true,
            .min_size_content = .{ .h = 28 },
        });
        defer tb.deinit();

        if (dvui.buttonIcon(@src(), "prev", icons.tvg.lucide.@"chevron-left", .{}, .{},
            .{ .min_size_content = .{ .w = 22, .h = 22 }, .gravity_y = 0.5 }))
        {
            if (self.current_idx > 0) self.navigateTo(self.current_idx - 1);
        }

        if (dvui.buttonIcon(@src(), "next", icons.tvg.lucide.@"chevron-right", .{}, .{},
            .{ .min_size_content = .{ .w = 22, .h = 22 }, .gravity_y = 0.5 }))
        {
            if (self.current_idx + 1 < self.images.items.len) self.navigateTo(self.current_idx + 1);
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

        if (dvui.button(@src(), i18n.t(.viewer_zoom_fit), .{}, .{ .gravity_y = 0.5 })) {
            self.zoom_mode = .fit;
            self.pan_x = 0;
            self.pan_y = 0;
        }

        if (dvui.button(@src(), i18n.t(.viewer_zoom_100), .{}, .{ .gravity_y = 0.5 })) {
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
        if (dvui.buttonIcon(@src(), fs_label, fs_icon, .{}, .{},
            .{ .min_size_content = .{ .w = 22, .h = 22 }, .gravity_y = 0.5 }))
        {
            self.toggleFullscreen();
        }

        if (dvui.buttonIcon(@src(), i18n.t(.viewer_toggle_info), icons.tvg.lucide.info, .{}, .{},
            .{ .min_size_content = .{ .w = 22, .h = 22 }, .gravity_y = 0.5 }))
        {
            self.info_open = !self.info_open;
        }

        if (dvui.buttonIcon(@src(), i18n.t(.viewer_delete), icons.tvg.lucide.trash, .{}, .{},
            .{ .min_size_content = .{ .w = 22, .h = 22 }, .gravity_y = 0.5 }))
        {
            self.delete_requested = true;
            self.delete_force = false;
        }
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

        if (self.image_bytes) |bytes| {
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
                .{ .imageFile = .{ .bytes = bytes, .invalidation = .ptr } },
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
        self.detail_state.renderPanel(self.info_w, filename);
    }

    fn toggleFullscreen(self: *ViewerState) void {
        if (self.sdl_window_ptr) |win| {
            self.fullscreen = !self.fullscreen;
            _ = SDLBackend.c.SDL_SetWindowFullscreen(win, self.fullscreen);
        }
    }
};

fn parseDimsFromBytes(bytes: []const u8) struct { w: u32, h: u32 } {
    // PNG: 8-byte signature followed by IHDR (length 4 + type 4 + width 4 + height 4)
    if (bytes.len >= 24 and
        bytes[0] == 137 and bytes[1] == 80 and bytes[2] == 78 and bytes[3] == 71 and
        bytes[4] == 13 and bytes[5] == 10 and bytes[6] == 26 and bytes[7] == 10)
    {
        const w = std.mem.readInt(u32, bytes[16..20], .big);
        const h = std.mem.readInt(u32, bytes[20..24], .big);
        if (w > 0 and h > 0) return .{ .w = w, .h = h };
    }
    // JPEG SOF scan
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8) {
        var i: usize = 2;
        while (i + 3 < bytes.len) {
            if (bytes[i] != 0xFF) break;
            const marker = bytes[i + 1];
            if (marker >= 0xC0 and marker <= 0xCF and
                marker != 0xC4 and marker != 0xC8 and marker != 0xCC)
            {
                if (i + 8 < bytes.len) {
                    const h: u32 = (@as(u32, bytes[i + 5]) << 8) | bytes[i + 6];
                    const w: u32 = (@as(u32, bytes[i + 7]) << 8) | bytes[i + 8];
                    if (w > 0 and h > 0) return .{ .w = w, .h = h };
                }
                break;
            }
            const seg_len: usize = (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
            if (seg_len < 2) break;
            i += 2 + seg_len;
        }
    }
    return .{ .w = 0, .h = 0 };
}

fn loadImageThread(
    gpa: std.mem.Allocator,
    io: std.Io,
    state: *ViewerState,
    path: []const u8,
) void {
    defer gpa.free(path);

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    const file_size = file.length(io) catch return;
    if (file_size > 256 * 1024 * 1024) return;
    const bytes = gpa.alloc(u8, file_size) catch return;
    _ = file.readPositionalAll(io, bytes, 0) catch {
        gpa.free(bytes);
        return;
    };

    if (state.stop_load.load(.acquire)) {
        gpa.free(bytes);
        return;
    }

    const dims = parseDimsFromBytes(bytes);

    state.pending_mutex.lockUncancelable(io);
    defer state.pending_mutex.unlock(io);
    if (state.pending_bytes) |old| gpa.free(old);
    state.pending_bytes = bytes;
    state.pending_width = dims.w;
    state.pending_height = dims.h;

    if (state.wakeup_fn) |wakeup| wakeup();
}
