const std = @import("std");
const SDLBackend = @import("backend");
const vips = @import("vips");
const ghost_mod = @import("dnd_ghost.zig");

const xlib = @import("x11_c");
const wl = @import("wayland_c");

// ─── X11 constants ───────────────────────────────────────────────────────────

const XA_ATOM: xlib.Atom = 4;
const XA_WINDOW: xlib.Atom = 33;
const SelectionRequest: c_int = 30;
const SelectionNotify: c_int = 31;
const ClientMessage: c_int = 33;
const GenericEvent: c_int = 35;
const PropModeReplace: c_int = 0;
const Button1Mask: c_uint = 1 << 8;
const CWOverrideRedirect: c_ulong = 1 << 9;
const xdnd_version: c_long = 5;
const cursor_size: c_int = 96;
const XI_RawButtonRelease: c_int = 16;

// ─── Wayland constants ───────────────────────────────────────────────────────

const BTN_LEFT: u32 = 0x110;
const WL_POINTER_BUTTON_STATE_PRESSED: u32 = 1;
const WL_SHM_FORMAT_ARGB8888: u32 = 0;
const WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY: u32 = 1;

// ─── Shared types ────────────────────────────────────────────────────────────

pub const DragItem   = ghost_mod.DragItem;
pub const GhostResult = ghost_mod.GhostResult;

const composeGhost = ghost_mod.composeGhost;

const Phase = enum { idle, dragging, finishing };

// ─── URI list builder (shared) ───────────────────────────────────────────────

fn buildUriList(allocator: std.mem.Allocator, items: []const DragItem) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (items) |item| {
        try list.appendSlice(allocator, "file://");
        for (item.path) |byte| {
            switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' =>
                    try list.append(allocator, byte),
                else => {
                    const hex = "0123456789ABCDEF";
                    try list.append(allocator, '%');
                    try list.append(allocator, hex[byte >> 4]);
                    try list.append(allocator, hex[byte & 0xf]);
                },
            }
        }
        try list.appendSlice(allocator, "\r\n");
    }
    return list.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Wayland drag source
// ═══════════════════════════════════════════════════════════════════════════

// ─── Wayland registry callbacks ──────────────────────────────────────────────

fn wlRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*wl.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        self.compositor = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        self.seat = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_seat_interface, @min(version, 5)));
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        const v = @min(version, 3);
        self.ddm = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_data_device_manager_interface, v));
        self.ddm_version = v;
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        self.shm = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_shm_interface, @min(version, 1)));
    }
}

fn wlRegistryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*wl.struct_wl_registry,
    name: u32,
) callconv(.c) void {
    _ = data; _ = registry; _ = name;
}

const registry_listener = wl.wl_registry_listener{
    .global        = wlRegistryGlobal,
    .global_remove = wlRegistryGlobalRemove,
};

// ─── Wayland pointer callbacks ───────────────────────────────────────────────

fn wlPointerEnter(
    data: ?*anyopaque,
    pointer: ?*wl.struct_wl_pointer,
    serial: u32,
    surface: ?*wl.struct_wl_surface,
    sx: wl.wl_fixed_t,
    sy: wl.wl_fixed_t,
) callconv(.c) void {
    _ = pointer; _ = sx; _ = sy;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    self.surf_focused = (surface == self.sdl_surf);
    if (self.surf_focused) self.last_serial = serial;
}

fn wlPointerLeave(
    data: ?*anyopaque,
    pointer: ?*wl.struct_wl_pointer,
    serial: u32,
    surface: ?*wl.struct_wl_surface,
) callconv(.c) void {
    _ = pointer; _ = serial; _ = surface;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    self.surf_focused = false;
}

fn wlPointerMotion(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, t: u32, x: wl.wl_fixed_t, y: wl.wl_fixed_t) callconv(.c) void { _ = data; _ = p; _ = t; _ = x; _ = y; }

fn wlPointerButton(
    data: ?*anyopaque,
    pointer: ?*wl.struct_wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer; _ = time;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    if (button == BTN_LEFT and state == WL_POINTER_BUTTON_STATE_PRESSED and self.surf_focused) {
        self.last_serial = serial;
        std.log.debug("dnd/wl: captured button serial={d}", .{serial});
    }
}

fn wlPointerAxis(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, t: u32, a: u32, v: wl.wl_fixed_t) callconv(.c) void { _ = data; _ = p; _ = t; _ = a; _ = v; }
fn wlPointerFrame(data: ?*anyopaque, p: ?*wl.struct_wl_pointer) callconv(.c) void { _ = data; _ = p; }
fn wlPointerAxisSource(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, s: u32) callconv(.c) void { _ = data; _ = p; _ = s; }
fn wlPointerAxisStop(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, t: u32, a: u32) callconv(.c) void { _ = data; _ = p; _ = t; _ = a; }
fn wlPointerAxisDiscrete(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, a: u32, d: i32) callconv(.c) void { _ = data; _ = p; _ = a; _ = d; }
fn wlPointerAxisValue120(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, a: u32, v: i32) callconv(.c) void { _ = data; _ = p; _ = a; _ = v; }
fn wlPointerAxisRelativeDirection(data: ?*anyopaque, p: ?*wl.struct_wl_pointer, a: u32, d: u32) callconv(.c) void { _ = data; _ = p; _ = a; _ = d; }

const pointer_listener = wl.wl_pointer_listener{
    .enter                   = wlPointerEnter,
    .leave                   = wlPointerLeave,
    .motion                  = wlPointerMotion,
    .button                  = wlPointerButton,
    .axis                    = wlPointerAxis,
    .frame                   = wlPointerFrame,
    .axis_source             = wlPointerAxisSource,
    .axis_stop               = wlPointerAxisStop,
    .axis_discrete           = wlPointerAxisDiscrete,
    .axis_value120           = wlPointerAxisValue120,
    .axis_relative_direction = wlPointerAxisRelativeDirection,
};

// ─── Wayland data-source callbacks ───────────────────────────────────────────

fn wlDataSourceTarget(data: ?*anyopaque, s: ?*wl.struct_wl_data_source, m: [*c]const u8) callconv(.c) void { _ = data; _ = s; _ = m; }

fn wlDataSourceSend(
    data: ?*anyopaque,
    source: ?*wl.struct_wl_data_source,
    mime_type: [*c]const u8,
    fd: i32,
) callconv(.c) void {
    _ = source;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    // The compositor transfers fd ownership to us; it must always be closed.
    if (!std.mem.eql(u8, std.mem.span(mime_type), "text/uri-list")) {
        _ = std.os.linux.close(@intCast(fd));
        return;
    }
    // Write from a thread: the reader may be this very thread (a drop onto our
    // own window), and a list bigger than the pipe buffer would then block
    // forever. The thread owns a copy of the list and the fd.
    const copy = std.heap.c_allocator.dupe(u8, self.uri_list) catch {
        _ = std.os.linux.close(@intCast(fd));
        return;
    };
    const t = std.Thread.spawn(.{}, writeAllAndClose, .{ fd, copy }) catch {
        writeAllAndClose(fd, copy);
        return;
    };
    t.detach();
}

fn writeAllAndClose(fd: i32, bytes: []u8) void {
    defer std.heap.c_allocator.free(bytes);
    defer _ = std.os.linux.close(@intCast(fd));
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.os.linux.write(@intCast(fd), bytes[off..].ptr, bytes.len - off);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR, .AGAIN => continue,
            else => return, // reader went away
        }
    }
}

fn wlDataSourceCancelled(
    data: ?*anyopaque,
    source: ?*wl.struct_wl_data_source,
) callconv(.c) void {
    _ = source;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    std.log.debug("dnd/wl: data_source cancelled", .{});
    self.resetToIdle();
}

fn wlDataSourceDndDropPerformed(data: ?*anyopaque, s: ?*wl.struct_wl_data_source) callconv(.c) void {
    _ = s;
    std.log.debug("dnd/wl: dnd_drop_performed", .{});
    // Do not destroy the source yet; wait for dnd_finished.
    _ = data;
}

fn wlDataSourceDndFinished(
    data: ?*anyopaque,
    source: ?*wl.struct_wl_data_source,
) callconv(.c) void {
    _ = source;
    const self: *WaylandDragSource = @ptrCast(@alignCast(data.?));
    std.log.debug("dnd/wl: dnd_finished", .{});
    self.resetToIdle();
}

fn wlDataSourceAction(data: ?*anyopaque, s: ?*wl.struct_wl_data_source, a: u32) callconv(.c) void { _ = data; _ = s; _ = a; }

const data_source_listener = wl.wl_data_source_listener{
    .target             = wlDataSourceTarget,
    .send               = wlDataSourceSend,
    .cancelled          = wlDataSourceCancelled,
    .dnd_drop_performed = wlDataSourceDndDropPerformed,
    .dnd_finished       = wlDataSourceDndFinished,
    .action             = wlDataSourceAction,
};

// ─── Wayland data-device callbacks (source-only: destroy all offers) ─────────

fn wlDataDeviceDataOffer(
    data: ?*anyopaque,
    dd: ?*wl.struct_wl_data_device,
    offer: ?*wl.struct_wl_data_offer,
) callconv(.c) void {
    _ = data; _ = dd;
    if (offer) |o| wl.wl_data_offer_destroy(o);
}
fn wlDataDeviceEnter(data: ?*anyopaque, dd: ?*wl.struct_wl_data_device, serial: u32, surface: ?*wl.struct_wl_surface, x: wl.wl_fixed_t, y: wl.wl_fixed_t, offer: ?*wl.struct_wl_data_offer) callconv(.c) void { _ = data; _ = dd; _ = serial; _ = surface; _ = x; _ = y; _ = offer; }
fn wlDataDeviceLeave(data: ?*anyopaque, dd: ?*wl.struct_wl_data_device) callconv(.c) void { _ = data; _ = dd; }
fn wlDataDeviceMotion(data: ?*anyopaque, dd: ?*wl.struct_wl_data_device, t: u32, x: wl.wl_fixed_t, y: wl.wl_fixed_t) callconv(.c) void { _ = data; _ = dd; _ = t; _ = x; _ = y; }
fn wlDataDeviceDrop(data: ?*anyopaque, dd: ?*wl.struct_wl_data_device) callconv(.c) void { _ = data; _ = dd; }
fn wlDataDeviceSelection(data: ?*anyopaque, dd: ?*wl.struct_wl_data_device, offer: ?*wl.struct_wl_data_offer) callconv(.c) void { _ = data; _ = dd; _ = offer; }

const data_device_listener = wl.wl_data_device_listener{
    .data_offer = wlDataDeviceDataOffer,
    .enter      = wlDataDeviceEnter,
    .leave      = wlDataDeviceLeave,
    .motion     = wlDataDeviceMotion,
    .drop       = wlDataDeviceDrop,
    .selection  = wlDataDeviceSelection,
};

// ─── WaylandDragSource ───────────────────────────────────────────────────────

const WaylandDragSource = struct {
    allocator:   std.mem.Allocator,
    display:     *wl.struct_wl_display,
    sdl_surf:    *wl.struct_wl_surface,
    registry:    *wl.struct_wl_registry,

    compositor:  ?*wl.struct_wl_compositor = null,
    seat:        ?*wl.struct_wl_seat = null,
    ddm:         ?*wl.struct_wl_data_device_manager = null,
    shm:         ?*wl.struct_wl_shm = null,
    ddm_version: u32 = 0,

    pointer:     ?*wl.struct_wl_pointer = null,
    data_device: ?*wl.struct_wl_data_device = null,

    last_serial:  u32 = 0,
    surf_focused: bool = false,

    phase:       Phase = .idle,
    data_source: ?*wl.struct_wl_data_source = null,

    icon_surface:  ?*wl.struct_wl_surface = null,
    icon_buffer:   ?*wl.struct_wl_buffer = null,
    icon_shm_fd:   std.posix.fd_t = -1,
    icon_shm_size: usize = 0,
    icon_shm_ptr:  ?[]align(std.heap.page_size_min) u8 = null,

    uri_list: []u8 = &.{},

    fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?*WaylandDragSource {
        const props = SDLBackend.c.SDL_GetWindowProperties(sdl_window);
        const dpy_raw = SDLBackend.c.SDL_GetPointerProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) orelse return null;
        const surf_raw = SDLBackend.c.SDL_GetPointerProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return null;

        const display: *wl.struct_wl_display = @ptrCast(@alignCast(dpy_raw));
        const sdl_surf: *wl.struct_wl_surface = @ptrCast(@alignCast(surf_raw));

        const registry = wl.wl_display_get_registry(display) orelse return null;

        const self = allocator.create(WaylandDragSource) catch {
            wl.wl_registry_destroy(registry);
            return null;
        };
        self.* = .{
            .allocator = allocator,
            .display   = display,
            .sdl_surf  = sdl_surf,
            .registry  = registry,
        };

        _ = wl.wl_registry_add_listener(registry, &registry_listener, self);
        _ = wl.wl_display_roundtrip(display);

        if (self.seat == null or self.ddm == null or self.shm == null or self.compositor == null) {
            std.log.warn("dnd/wl: missing globals (seat={} ddm={} shm={} comp={})",
                .{ self.seat != null, self.ddm != null, self.shm != null, self.compositor != null });
            wl.wl_registry_destroy(registry);
            allocator.destroy(self);
            return null;
        }

        self.pointer = wl.wl_seat_get_pointer(self.seat.?);
        if (self.pointer) |ptr| {
            _ = wl.wl_pointer_add_listener(ptr, &pointer_listener, self);
        }

        self.data_device = wl.wl_data_device_manager_get_data_device(self.ddm.?, self.seat.?);
        if (self.data_device) |dd| {
            _ = wl.wl_data_device_add_listener(dd, &data_device_listener, self);
        }

        _ = wl.wl_display_roundtrip(display);

        std.log.debug("dnd/wl: init ok (ddm_ver={d})", .{self.ddm_version});
        return self;
    }

    fn deinit(self: *WaylandDragSource) void {
        if (self.phase != .idle) self.resetToIdle();
        self.freeUriList();
        if (self.pointer)     |p| { wl.wl_pointer_destroy(p);               self.pointer     = null; }
        if (self.data_device) |d| { wl.wl_data_device_destroy(d);           self.data_device = null; }
        if (self.ddm)         |d| { wl.wl_data_device_manager_destroy(d);   self.ddm         = null; }
        if (self.shm)         |s| { wl.wl_shm_destroy(s);                   self.shm         = null; }
        if (self.compositor)  |c| { wl.wl_compositor_destroy(c);            self.compositor  = null; }
        if (self.seat)        |s| { wl.wl_seat_destroy(s);                  self.seat        = null; }
        wl.wl_registry_destroy(self.registry);
        _ = wl.wl_display_flush(self.display);
        self.allocator.destroy(self);
    }

    fn isDragging(self: *const WaylandDragSource) bool {
        return self.phase != .idle;
    }

    fn startDrag(self: *WaylandDragSource, items: []const DragItem) void {
        if (self.phase != .idle or items.len == 0) return;
        if (self.last_serial == 0) {
            std.log.warn("dnd/wl: startDrag called with no button serial — ignored", .{});
            return;
        }

        self.freeUriList();
        self.uri_list = buildUriList(self.allocator, items) catch return;

        const source = wl.wl_data_device_manager_create_data_source(self.ddm.?) orelse {
            self.freeUriList();
            return;
        };
        wl.wl_data_source_offer(source, "text/uri-list");
        if (self.ddm_version >= 3)
            wl.wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        self.data_source = source;

        // Build ghost icon (best-effort; null → compositor shows default cursor).
        var icon_surf: ?*wl.struct_wl_surface = null;
        if (composeGhost(self.allocator, items)) |ghost| {
            defer self.allocator.free(ghost.pixels);
            icon_surf = self.buildIconSurface(ghost.pixels, ghost.width, ghost.height) catch |err| blk: {
                std.log.warn("dnd/wl: icon surface failed: {}", .{err});
                break :blk null;
            };
        }

        wl.wl_data_device_start_drag(
            self.data_device.?,
            source,
            self.sdl_surf,
            icon_surf,
            self.last_serial,
        );
        _ = wl.wl_display_flush(self.display);

        self.phase = .dragging;
        std.log.debug("dnd/wl: startDrag {d} item(s) serial={d}", .{ items.len, self.last_serial });
    }

    fn pumpEvents(self: *WaylandDragSource) void {
        _ = wl.wl_display_dispatch_pending(self.display);
    }

    fn tick(self: *WaylandDragSource, io: std.Io) void {
        _ = io;
        // Wayland is event-driven; state transitions happen in data_source callbacks.
        // pumpEvents() drives dispatch; nothing to poll here.
        _ = self;
    }

    fn getSdlCursor(_: *const WaylandDragSource) ?*SDLBackend.c.SDL_Cursor {
        return null; // compositor renders the icon surface
    }

    fn notifyButtonUp(_: *WaylandDragSource) void {}

    // ── private ──────────────────────────────────────────────────────────────

    fn buildIconSurface(
        self: *WaylandDragSource,
        rgba: []const u8,
        w: u32,
        h: u32,
    ) !*wl.struct_wl_surface {
        const size = w * h * 4;

        const fd = try std.posix.memfd_create("diffkeep-dnd-icon", 0);
        errdefer _ = std.os.linux.close(fd);
        const ftr = std.os.linux.ftruncate(fd, @intCast(size));
        if (std.posix.errno(ftr) != .SUCCESS) return error.FtruncateFailed;

        const ptr = try std.posix.mmap(
            null, size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd, 0,
        );
        errdefer std.posix.munmap(ptr);

        // RGBA → Wayland ARGB8888 (wire format is little-endian BGRA in memory)
        for (0..w * h) |px| {
            ptr[px * 4 + 0] = rgba[px * 4 + 2]; // B
            ptr[px * 4 + 1] = rgba[px * 4 + 1]; // G
            ptr[px * 4 + 2] = rgba[px * 4 + 0]; // R
            ptr[px * 4 + 3] = rgba[px * 4 + 3]; // A
        }

        const pool = wl.wl_shm_create_pool(self.shm.?, fd, @intCast(size)) orelse
            return error.WlShmPoolFailed;
        defer wl.wl_shm_pool_destroy(pool);

        const buf = wl.wl_shm_pool_create_buffer(
            pool, 0, @intCast(w), @intCast(h), @intCast(w * 4), WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.WlBufferFailed;

        const surf = wl.wl_compositor_create_surface(self.compositor.?) orelse {
            wl.wl_buffer_destroy(buf);
            return error.WlSurfaceFailed;
        };
        wl.wl_surface_attach(surf, buf, 0, 0);
        wl.wl_surface_damage(surf, 0, 0, @intCast(w), @intCast(h));
        wl.wl_surface_commit(surf);

        self.icon_surface  = surf;
        self.icon_buffer   = buf;
        self.icon_shm_fd   = fd;
        self.icon_shm_size = size;
        self.icon_shm_ptr  = ptr;
        return surf;
    }

    fn destroyIconSurface(self: *WaylandDragSource) void {
        if (self.icon_surface) |s| { wl.wl_surface_destroy(s); self.icon_surface = null; }
        if (self.icon_buffer)  |b| { wl.wl_buffer_destroy(b);  self.icon_buffer  = null; }
        if (self.icon_shm_ptr) |p| { std.posix.munmap(p);      self.icon_shm_ptr = null; }
        if (self.icon_shm_fd >= 0) { _ = std.os.linux.close(self.icon_shm_fd); self.icon_shm_fd = -1; }
        self.icon_shm_size = 0;
    }

    fn resetToIdle(self: *WaylandDragSource) void {
        if (self.data_source) |s| { wl.wl_data_source_destroy(s); self.data_source = null; }
        self.destroyIconSurface();
        _ = wl.wl_display_flush(self.display);
        self.phase = .idle;
        self.freeUriList();
    }

    fn freeUriList(self: *WaylandDragSource) void {
        if (self.uri_list.len > 0) {
            self.allocator.free(self.uri_list);
            self.uri_list = &.{};
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// X11 drag source
// ═══════════════════════════════════════════════════════════════════════════

const Atoms = struct {
    XdndAware:      xlib.Atom,
    XdndProxy:      xlib.Atom,
    XdndSelection:  xlib.Atom,
    XdndEnter:      xlib.Atom,
    XdndPosition:   xlib.Atom,
    XdndStatus:     xlib.Atom,
    XdndLeave:      xlib.Atom,
    XdndDrop:       xlib.Atom,
    XdndFinished:   xlib.Atom,
    XdndActionCopy: xlib.Atom,
    text_uri_list:  xlib.Atom,
    MULTIPLE:       xlib.Atom,
    TARGETS:        xlib.Atom,
};

const X11DragSource = struct {
    allocator: std.mem.Allocator,
    dnd_dpy:  *xlib.Display,
    src_win:  xlib.Window,
    sdl_win:  xlib.Window,
    root_win: xlib.Window,
    atoms:    Atoms,

    xi_opcode: c_int = 0,

    phase:           Phase = .idle,
    target:          xlib.Window = 0,
    accepted:        bool = false,
    uri_list:        []u8 = &.{},
    finish_ns:       i96 = 0,
    button_released: bool = false,
    drag_x11_cursor: xlib.Cursor = 0,
    drag_sdl_cursor: ?*SDLBackend.c.SDL_Cursor = null,
    wakeup_event_type: u32 = 0,
    watcher_stop:      std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The watcher pushed a wakeup the main thread hasn't pumped yet.
    wake_pending:      std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    watcher_thread:    ?std.Thread = null,

    fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?X11DragSource {
        const props = SDLBackend.c.SDL_GetWindowProperties(sdl_window);
        const dpy_opaque = SDLBackend.c.SDL_GetPointerProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null) orelse return null;
        const win_num = SDLBackend.c.SDL_GetNumberProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (win_num == 0) return null;

        const sdl_dpy: *xlib.Display = @ptrCast(@alignCast(dpy_opaque));
        const sdl_win: xlib.Window = @intCast(win_num);

        const sdl_aware = xlib.XInternAtom(sdl_dpy, "XdndAware", 0);
        var ver: c_long = xdnd_version;
        _ = xlib.XChangeProperty(sdl_dpy, sdl_win, sdl_aware, XA_ATOM, 32,
            PropModeReplace, @ptrCast(&ver), 1);
        _ = xlib.XFlush(sdl_dpy);

        const dnd_dpy = xlib.XOpenDisplay(null) orelse return null;
        XErrors.register(dnd_dpy);
        const root_win = xlib.DefaultRootWindow(dnd_dpy);

        const src_win = xlib.XCreateSimpleWindow(dnd_dpy, root_win, -2, -2, 1, 1, 0, 0, 0);
        var attrs = std.mem.zeroes(xlib.XSetWindowAttributes);
        attrs.override_redirect = 1;
        _ = xlib.XChangeWindowAttributes(dnd_dpy, src_win, CWOverrideRedirect, &attrs);

        const atoms = Atoms{
            .XdndAware      = xlib.XInternAtom(dnd_dpy, "XdndAware",      0),
            .XdndProxy      = xlib.XInternAtom(dnd_dpy, "XdndProxy",      0),
            .XdndSelection  = xlib.XInternAtom(dnd_dpy, "XdndSelection",  0),
            .XdndEnter      = xlib.XInternAtom(dnd_dpy, "XdndEnter",      0),
            .XdndPosition   = xlib.XInternAtom(dnd_dpy, "XdndPosition",   0),
            .XdndStatus     = xlib.XInternAtom(dnd_dpy, "XdndStatus",     0),
            .XdndLeave      = xlib.XInternAtom(dnd_dpy, "XdndLeave",      0),
            .XdndDrop       = xlib.XInternAtom(dnd_dpy, "XdndDrop",       0),
            .XdndFinished   = xlib.XInternAtom(dnd_dpy, "XdndFinished",   0),
            .XdndActionCopy = xlib.XInternAtom(dnd_dpy, "XdndActionCopy", 0),
            .text_uri_list  = xlib.XInternAtom(dnd_dpy, "text/uri-list",  0),
            .MULTIPLE       = xlib.XInternAtom(dnd_dpy, "MULTIPLE",       0),
            .TARGETS        = xlib.XInternAtom(dnd_dpy, "TARGETS",        0),
        };

        _ = xlib.XChangeProperty(dnd_dpy, src_win, atoms.XdndAware, XA_ATOM, 32,
            PropModeReplace, @ptrCast(&ver), 1);

        var xi_opcode: c_int = 0;
        var xi_event_base: c_int = 0;
        var xi_error_base: c_int = 0;
        if (xlib.XQueryExtension(dnd_dpy, "XInputExtension",
                &xi_opcode, &xi_event_base, &xi_error_base) != 0)
        {
            var major: c_int = 2;
            var minor: c_int = 0;
            if (xlib.XIQueryVersion(dnd_dpy, &major, &minor) == 0) {
                var mask_bytes = [_]u8{ 0, 0, 1, 0 };
                var evmask = xlib.XIEventMask{
                    .deviceid = xlib.XIAllMasterDevices,
                    .mask_len = mask_bytes.len,
                    .mask     = &mask_bytes,
                };
                _ = xlib.XISelectEvents(dnd_dpy, root_win, &evmask, 1);
            } else {
                xi_opcode = 0;
            }
        }
        _ = xlib.XFlush(dnd_dpy);

        const wakeup_type: u32 = @bitCast(SDLBackend.c.SDL_RegisterEvents(1));

        std.log.debug("dnd: X11 DragSource init sdl_win=0x{x} src_win=0x{x} xi2={}", .{ sdl_win, src_win, xi_opcode != 0 });
        return .{
            .allocator         = allocator,
            .dnd_dpy           = dnd_dpy,
            .src_win           = src_win,
            .sdl_win           = sdl_win,
            .root_win          = root_win,
            .atoms             = atoms,
            .xi_opcode         = xi_opcode,
            .wakeup_event_type = wakeup_type,
        };
    }

    fn deinit(self: *X11DragSource) void {
        if (self.phase != .idle) self.abort();
        self.freeUriList();
        self.freeDragCursors();
        _ = xlib.XDestroyWindow(self.dnd_dpy, self.src_win);
        _ = xlib.XCloseDisplay(self.dnd_dpy);
        XErrors.unregister(self.dnd_dpy);
    }

    fn getSdlCursor(self: *const X11DragSource) ?*SDLBackend.c.SDL_Cursor {
        return self.drag_sdl_cursor;
    }

    fn notifyButtonUp(self: *X11DragSource) void {
        if (self.phase == .dragging) self.button_released = true;
    }

    fn isDragging(self: *const X11DragSource) bool {
        return self.phase != .idle;
    }

    fn startDrag(self: *X11DragSource, items: []const DragItem) void {
        if (self.phase != .idle or items.len == 0) return;
        self.freeUriList();
        self.uri_list = buildUriList(self.allocator, items) catch return;
        _ = xlib.XSetSelectionOwner(self.dnd_dpy, self.atoms.XdndSelection, self.src_win, 0);
        _ = xlib.XFlush(self.dnd_dpy);
        self.createDragCursors(items[0].thumb_jpeg);
        self.phase    = .dragging;
        self.target   = 0;
        self.accepted = false;
        self.watcher_stop.store(false, .release);
        self.watcher_thread = std.Thread.spawn(.{}, dndWatcher, .{self}) catch null;
        std.log.debug("dnd: startDrag {d} item(s), uri_list={d}b", .{ items.len, self.uri_list.len });
    }

    fn pumpEvents(self: *X11DragSource) void {
        self.wake_pending.store(false, .release);
        var event: xlib.XEvent = undefined;
        while (xlib.XCheckIfEvent(self.dnd_dpy, &event, xdndPredicate, @ptrCast(self)) != 0) {
            self.handleX11Event(&event);
        }
        if (self.phase == .dragging) {
            while (xlib.XCheckIfEvent(self.dnd_dpy, &event, anyEventPredicate, null) != 0) {
                std.log.debug("dnd: unhandled event type={d} window=0x{x}", .{ event.type, event.xany.window });
            }
        }
    }

    fn tick(self: *X11DragSource, io: std.Io) void {
        switch (self.phase) {
            .idle      => {},
            .dragging  => self.tickDragging(io),
            .finishing => {
                const now = std.Io.Clock.real.now(io).nanoseconds;
                if (now - self.finish_ns > 2 * std.time.ns_per_s) self.resetToIdle();
            },
        }
    }

    // ── private ──────────────────────────────────────────────────────────────

    fn tickDragging(self: *X11DragSource, io: std.Io) void {
        var dummy: xlib.Window = undefined;
        var top_child: xlib.Window = 0;
        var rx: c_int = 0; var ry: c_int = 0;
        var wx: c_int = 0; var wy: c_int = 0;
        var mask: c_uint = 0;

        if (xlib.XQueryPointer(self.dnd_dpy, self.root_win,
                &dummy, &top_child, &rx, &ry, &wx, &wy, &mask) == 0) {
            std.log.debug("dnd: XQueryPointer failed", .{});
            return;
        }

        const sdl_buttons = SDLBackend.c.SDL_GetGlobalMouseState(null, null);
        if (self.button_released or sdl_buttons & 1 == 0 or mask & Button1Mask == 0) {
            self.button_released = false;
            self.finishDrag(io);
            return;
        }

        const new_target = self.findTarget(top_child, rx, ry);
        if (new_target != self.target) {
            std.log.debug("dnd: target 0x{x} → 0x{x}", .{ self.target, new_target });
            if (self.target != 0) _ = xlib.XUndefineCursor(self.dnd_dpy, self.target);
            if (new_target != 0) _ = xlib.XDefineCursor(self.dnd_dpy, new_target, self.drag_x11_cursor);
            if (self.target != 0)
                self.sendMsg(self.target, self.atoms.XdndLeave,
                    @bitCast(self.src_win), 0, 0, 0, 0);
            self.target   = new_target;
            self.accepted = false;
            if (new_target != 0)
                self.sendMsg(new_target, self.atoms.XdndEnter,
                    @bitCast(self.src_win),
                    xdnd_version << 24,
                    @intCast(self.atoms.text_uri_list),
                    0, 0);
        }
        if (self.target != 0)
            self.sendMsg(self.target, self.atoms.XdndPosition,
                @bitCast(self.src_win), 0,
                (@as(c_long, rx) << 16) | @as(c_long, @intCast(ry & 0xffff)),
                0,
                @intCast(self.atoms.XdndActionCopy));
        _ = xlib.XFlush(self.dnd_dpy);
    }

    fn finishDrag(self: *X11DragSource, io: std.Io) void {
        std.log.debug("dnd: finishDrag target=0x{x} accepted={}", .{ self.target, self.accepted });
        if (self.target != 0 and self.accepted) {
            self.sendMsg(self.target, self.atoms.XdndDrop,
                @bitCast(self.src_win), 0,
                0, 0, 0);
            self.phase     = .finishing;
            self.finish_ns = std.Io.Clock.real.now(io).nanoseconds;
        } else {
            if (self.target != 0)
                self.sendMsg(self.target, self.atoms.XdndLeave,
                    @bitCast(self.src_win), 0, 0, 0, 0);
            self.resetToIdle();
        }
        _ = xlib.XFlush(self.dnd_dpy);
    }

    fn abort(self: *X11DragSource) void {
        if (self.target != 0)
            self.sendMsg(self.target, self.atoms.XdndLeave,
                @bitCast(self.src_win), 0, 0, 0, 0);
        _ = xlib.XFlush(self.dnd_dpy);
        self.resetToIdle();
    }

    fn resetToIdle(self: *X11DragSource) void {
        self.watcher_stop.store(true, .release);
        if (self.watcher_thread) |t| { t.join(); self.watcher_thread = null; }
        _ = xlib.XSetSelectionOwner(self.dnd_dpy, self.atoms.XdndSelection, 0, 0);
        if (self.target != 0) _ = xlib.XUndefineCursor(self.dnd_dpy, self.target);
        _ = xlib.XFlush(self.dnd_dpy);
        self.phase  = .idle;
        self.target = 0;
        self.freeUriList();
        self.freeDragCursors();
    }

    fn createDragCursors(self: *X11DragSource, thumb_jpeg: []const u8) void {
        if (thumb_jpeg.len == 0) return;

        const decoded = vips.jpegBytesToRgba(self.allocator, thumb_jpeg, cursor_size)
            catch return;
        defer self.allocator.free(decoded.pixels);

        const w = decoded.width;
        const h = decoded.height;
        const hot_x: c_int = @intCast(w / 2);
        const hot_y: c_int = @intCast(h / 2);

        const surface = SDLBackend.c.SDL_CreateSurfaceFrom(
            @intCast(w), @intCast(h),
            SDLBackend.c.SDL_PIXELFORMAT_RGBA32,
            decoded.pixels.ptr,
            @intCast(w * 4),
        );
        if (surface != null) {
            self.drag_sdl_cursor = SDLBackend.c.SDL_CreateColorCursor(surface, hot_x, hot_y);
            SDLBackend.c.SDL_DestroySurface(surface);
        }

        const ximg = xlib.XcursorImageCreate(@intCast(w), @intCast(h)) orelse return;
        defer xlib.XcursorImageDestroy(ximg);
        ximg.*.xhot = @intCast(w / 2);
        ximg.*.yhot = @intCast(h / 2);
        const pixels = decoded.pixels;
        var i: usize = 0;
        while (i < w * h) : (i += 1) {
            const r = pixels[i * 4 + 0];
            const g = pixels[i * 4 + 1];
            const b = pixels[i * 4 + 2];
            const a = pixels[i * 4 + 3];
            ximg.*.pixels[i] = (@as(u32, a) << 24) | (@as(u32, r) << 16) |
                                (@as(u32, g) << 8)  |  @as(u32, b);
        }
        self.drag_x11_cursor = xlib.XcursorImageLoadCursor(self.dnd_dpy, ximg);
    }

    fn freeDragCursors(self: *X11DragSource) void {
        if (self.drag_x11_cursor != 0) {
            _ = xlib.XFreeCursor(self.dnd_dpy, self.drag_x11_cursor);
            self.drag_x11_cursor = 0;
        }
        if (self.drag_sdl_cursor) |c| {
            _ = SDLBackend.c.SDL_SetCursor(null);
            SDLBackend.c.SDL_DestroyCursor(c);
            self.drag_sdl_cursor = null;
        }
    }

    fn freeUriList(self: *X11DragSource) void {
        if (self.uri_list.len > 0) {
            self.allocator.free(self.uri_list);
            self.uri_list = &.{};
        }
    }

    fn findTarget(self: *X11DragSource, top_win: xlib.Window, root_x: c_int, root_y: c_int) xlib.Window {
        if (top_win == 0 or top_win == self.sdl_win) return 0;

        var candidate: xlib.Window = 0;
        var current = top_win;
        while (current != 0) {
            if (current != self.src_win and current != self.sdl_win
                    and self.xdndVersion(current) != null)
                candidate = current;
            var child: xlib.Window = 0;
            var wx: c_int = 0; var wy: c_int = 0;
            _ = xlib.XTranslateCoordinates(self.dnd_dpy, self.root_win, current,
                root_x, root_y, &wx, &wy, &child);
            current = child;
        }
        if (candidate != 0) return candidate;

        return self.getXdndProxy(top_win);
    }

    fn xdndVersion(self: *X11DragSource, win: xlib.Window) ?u32 {
        var actual_type: xlib.Atom = undefined;
        var actual_fmt: c_int = undefined;
        var nitems: c_ulong = undefined;
        var after: c_ulong = undefined;
        var data: [*c]u8 = null;
        const r = xlib.XGetWindowProperty(self.dnd_dpy, win, self.atoms.XdndAware,
            0, 1, 0, XA_ATOM,
            &actual_type, &actual_fmt, &nitems, &after, @ptrCast(&data));
        defer { if (data != null) _ = xlib.XFree(data); }
        if (r != 0 or nitems == 0) return null;
        const ver: c_long = @as(*c_long, @ptrCast(@alignCast(data))).*;
        return @intCast(ver);
    }

    fn getXdndProxy(self: *X11DragSource, win: xlib.Window) xlib.Window {
        var actual_type: xlib.Atom = undefined;
        var actual_fmt: c_int = undefined;
        var nitems: c_ulong = undefined;
        var after: c_ulong = undefined;
        var data: [*c]u8 = null;
        const r = xlib.XGetWindowProperty(self.dnd_dpy, win, self.atoms.XdndProxy,
            0, 1, 0, XA_WINDOW,
            &actual_type, &actual_fmt, &nitems, &after, @ptrCast(&data));
        defer { if (data != null) _ = xlib.XFree(data); }
        if (r != 0 or nitems == 0) return 0;
        const proxy: xlib.Window = @as(*xlib.Window, @ptrCast(@alignCast(data))).*;
        return if (self.xdndVersion(proxy) != null) proxy else 0;
    }

    fn sendMsg(self: *X11DragSource, win: xlib.Window, kind: xlib.Atom,
        d0: c_long, d1: c_long, d2: c_long, d3: c_long, d4: c_long) void
    {
        var ev = std.mem.zeroes(xlib.XEvent);
        ev.xclient.type         = ClientMessage;
        ev.xclient.display      = self.dnd_dpy;
        ev.xclient.window       = win;
        ev.xclient.message_type = kind;
        ev.xclient.format       = 32;
        ev.xclient.data.l[0]    = d0;
        ev.xclient.data.l[1]    = d1;
        ev.xclient.data.l[2]    = d2;
        ev.xclient.data.l[3]    = d3;
        ev.xclient.data.l[4]    = d4;
        _ = xlib.XSendEvent(self.dnd_dpy, win, 0, 0, &ev);
    }

    fn handleX11Event(self: *X11DragSource, ev: *xlib.XEvent) void {
        switch (ev.type) {
            ClientMessage => {
                const mt = ev.xclient.message_type;
                if (mt == self.atoms.XdndStatus) {
                    const prev = self.accepted;
                    self.accepted = (ev.xclient.data.l[1] & 0x1) != 0;
                    if (self.accepted != prev)
                        std.log.debug("dnd: XdndStatus accepted={} from 0x{x}", .{ self.accepted, ev.xclient.data.l[0] });
                } else if (mt == self.atoms.XdndFinished) {
                    std.log.debug("dnd: XdndFinished received", .{});
                    self.resetToIdle();
                }
            },
            SelectionRequest => {
                if (ev.xselectionrequest.selection == self.atoms.XdndSelection)
                    self.answerSelectionRequest(ev.xselectionrequest);
            },
            GenericEvent => {
                if (xlib.XGetEventData(self.dnd_dpy, &ev.xcookie) != 0) {
                    defer xlib.XFreeEventData(self.dnd_dpy, &ev.xcookie);
                    if (ev.xcookie.evtype == XI_RawButtonRelease) {
                        const re: *xlib.XIRawEvent = @ptrCast(@alignCast(ev.xcookie.data));
                        if (re.detail == 1 and self.phase == .dragging) {
                            self.button_released = true;
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn answerSelectionRequest(self: *X11DragSource, sr: xlib.XSelectionRequestEvent) void {
        var resp = std.mem.zeroes(xlib.XEvent);
        resp.xselection.type      = SelectionNotify;
        resp.xselection.requestor = sr.requestor;
        resp.xselection.selection = sr.selection;
        resp.xselection.target    = sr.target;
        resp.xselection.time      = sr.time;
        resp.xselection.property  = 0;

        if (sr.target == self.atoms.TARGETS) {
            var supported = [_]xlib.Atom{ self.atoms.text_uri_list, self.atoms.TARGETS };
            _ = xlib.XChangeProperty(self.dnd_dpy, sr.requestor, sr.property,
                XA_ATOM, 32, PropModeReplace,
                @ptrCast(&supported), supported.len);
            resp.xselection.property = sr.property;
        } else if (sr.target == self.atoms.text_uri_list and self.uri_list.len > 0) {
            std.log.debug("dnd: SelectionRequest → answering text/uri-list ({d}b)", .{self.uri_list.len});
            _ = xlib.XChangeProperty(self.dnd_dpy, sr.requestor, sr.property,
                self.atoms.text_uri_list, 8, PropModeReplace,
                self.uri_list.ptr, @intCast(self.uri_list.len));
            resp.xselection.property = sr.property;
        } else if (sr.target == self.atoms.MULTIPLE) {
            self.answerMultiple(sr, &resp);
            return;
        } else {
            std.log.debug("dnd: SelectionRequest unknown atom={d}", .{sr.target});
        }

        _ = xlib.XSendEvent(self.dnd_dpy, sr.requestor, 0, 0, &resp);
        _ = xlib.XFlush(self.dnd_dpy);
    }

    fn answerMultiple(self: *X11DragSource, sr: xlib.XSelectionRequestEvent, resp: *xlib.XEvent) void {
        var actual_type: xlib.Atom = undefined;
        var actual_fmt: c_int = undefined;
        var nitems: c_ulong = undefined;
        var after: c_ulong = undefined;
        var data: [*c]u8 = null;
        const r = xlib.XGetWindowProperty(self.dnd_dpy, sr.requestor, sr.property,
            0, 256, 0, 0,
            &actual_type, &actual_fmt, &nitems, &after, @ptrCast(&data));
        defer { if (data != null) _ = xlib.XFree(data); }

        if (r != 0 or actual_fmt != 32 or nitems < 2) {
            _ = xlib.XSendEvent(self.dnd_dpy, sr.requestor, 0, 0, resp);
            _ = xlib.XFlush(self.dnd_dpy);
            return;
        }

        const pairs: [*]xlib.Atom = @ptrCast(@alignCast(data));
        var i: usize = 0;
        while (i + 1 < nitems) : (i += 2) {
            if (pairs[i] == self.atoms.TARGETS) {
                var supported = [_]xlib.Atom{ self.atoms.text_uri_list, self.atoms.TARGETS };
                _ = xlib.XChangeProperty(self.dnd_dpy, sr.requestor, pairs[i + 1],
                    XA_ATOM, 32, PropModeReplace,
                    @ptrCast(&supported), supported.len);
            } else if (pairs[i] == self.atoms.text_uri_list and self.uri_list.len > 0) {
                _ = xlib.XChangeProperty(self.dnd_dpy, sr.requestor, pairs[i + 1],
                    self.atoms.text_uri_list, 8, PropModeReplace,
                    self.uri_list.ptr, @intCast(self.uri_list.len));
            } else {
                pairs[i + 1] = 0;
            }
        }
        _ = xlib.XChangeProperty(self.dnd_dpy, sr.requestor, sr.property,
            actual_type, 32, PropModeReplace,
            @ptrCast(data), @intCast(nitems));
        resp.xselection.property = sr.property;
        _ = xlib.XSendEvent(self.dnd_dpy, sr.requestor, 0, 0, resp);
        _ = xlib.XFlush(self.dnd_dpy);
    }
};

/// X errors on our drag connections are expected: the window under the
/// pointer (a tooltip, a menu) can vanish between our XQueryPointer and the
/// next request, giving BadWindow. Xlib's default handler exits the process,
/// so errors on these displays are swallowed; others go to the previous
/// handler. Xlib handlers are process-wide. Main thread only.
const XErrors = struct {
    var displays: [16]?*xlib.Display = @splat(null);
    var prev: xlib.XErrorHandler = null;
    var installed = false;

    fn register(dpy: *xlib.Display) void {
        for (&displays) |*d| if (d.* == null) {
            d.* = dpy;
            break;
        };
        if (!installed) {
            prev = xlib.XSetErrorHandler(handler);
            installed = true;
        }
    }

    fn unregister(dpy: *xlib.Display) void {
        for (&displays) |*d| if (d.* == dpy) {
            d.* = null;
        };
    }

    fn handler(dpy: ?*xlib.Display, ev: [*c]xlib.XErrorEvent) callconv(.c) c_int {
        for (displays) |d| if (d != null and d == dpy) {
            std.log.debug("dnd: ignored X error code={d}", .{ev.*.error_code});
            return 0;
        };
        if (prev) |h| return h(dpy, ev);
        return 0;
    }
};

fn dndWatcher(self: *X11DragSource) void {
    const fd = xlib.XConnectionNumber(self.dnd_dpy);
    var pfd = std.posix.pollfd{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    while (!self.watcher_stop.load(.acquire)) {
        // poll is level-triggered and only the main thread reads the socket:
        // after one wakeup, wait for pumpEvents to take it before polling
        // again, or this loop spins and floods SDL's event queue.
        if (self.wake_pending.load(.acquire)) {
            var none: [0]std.posix.pollfd = .{};
            _ = std.posix.poll(&none, 2) catch break; // sleep 2 ms
            continue;
        }
        _ = std.posix.poll(@as(*[1]std.posix.pollfd, &pfd)[0..1], 50) catch break;
        if (pfd.revents & std.posix.POLL.IN != 0) {
            self.wake_pending.store(true, .release);
            var ev = std.mem.zeroes(SDLBackend.c.SDL_Event);
            ev.type = self.wakeup_event_type;
            _ = SDLBackend.c.SDL_PushEvent(&ev);
            pfd.revents = 0;
        }
    }
}

fn anyEventPredicate(dpy: ?*xlib.Display, ev: ?*xlib.XEvent, arg: xlib.XPointer) callconv(.c) xlib.Bool {
    _ = dpy; _ = arg; _ = ev;
    return 1;
}

fn xdndPredicate(dpy: ?*xlib.Display, ev: ?*xlib.XEvent, arg: xlib.XPointer) callconv(.c) xlib.Bool {
    _ = dpy;
    const self: *X11DragSource = @ptrCast(@alignCast(arg));
    const e = ev orelse return 0;
    if (e.type == ClientMessage) {
        const mt = e.xclient.message_type;
        if (mt == self.atoms.XdndStatus or mt == self.atoms.XdndFinished) return 1;
    }
    if (e.type == SelectionRequest and
        e.xselectionrequest.selection == self.atoms.XdndSelection) return 1;
    if (e.type == GenericEvent and self.xi_opcode != 0 and
        e.xcookie.extension == self.xi_opcode and
        e.xcookie.evtype == XI_RawButtonRelease) return 1;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Public dispatch
// ═══════════════════════════════════════════════════════════════════════════

const Backend = union(enum) {
    x11:     X11DragSource,
    wayland: *WaylandDragSource,
};

pub const DragSource = struct {
    backend: Backend,

    pub fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?DragSource {
        if (X11DragSource.init(allocator, sdl_window)) |x11|
            return .{ .backend = .{ .x11 = x11 } };
        if (WaylandDragSource.init(allocator, sdl_window)) |wld|
            return .{ .backend = .{ .wayland = wld } };
        return null;
    }

    pub fn deinit(self: *DragSource) void {
        switch (self.backend) {
            .x11     => |*x| x.deinit(),
            .wayland => |w|  w.deinit(),
        }
    }

    pub fn isDragging(self: *const DragSource) bool {
        return switch (self.backend) {
            .x11     => |*x| x.isDragging(),
            .wayland => |w|  w.isDragging(),
        };
    }

    pub fn startDrag(self: *DragSource, items: []const DragItem) void {
        switch (self.backend) {
            .x11     => |*x| x.startDrag(items),
            .wayland => |w|  w.startDrag(items),
        }
    }

    pub fn pumpEvents(self: *DragSource) void {
        switch (self.backend) {
            .x11     => |*x| x.pumpEvents(),
            .wayland => |w|  w.pumpEvents(),
        }
    }

    pub fn tick(self: *DragSource, io: std.Io) void {
        switch (self.backend) {
            .x11     => |*x| x.tick(io),
            .wayland => |w|  w.tick(io),
        }
    }

    pub fn getSdlCursor(self: *const DragSource) ?*SDLBackend.c.SDL_Cursor {
        return switch (self.backend) {
            .x11     => |*x| x.getSdlCursor(),
            .wayland => |w|  w.getSdlCursor(),
        };
    }

    pub fn notifyButtonUp(self: *DragSource) void {
        switch (self.backend) {
            .x11     => |*x| x.notifyButtonUp(),
            .wayland => |w|  w.notifyButtonUp(),
        }
    }
};
