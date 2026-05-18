const std = @import("std");
const SDLBackend = @import("backend");

const xlib = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
});

const XA_ATOM: xlib.Atom = 4;
const XA_WINDOW: xlib.Atom = 33;
const SelectionRequest: c_int = 30;
const SelectionNotify: c_int = 31;
const ClientMessage: c_int = 33;
const PropModeReplace: c_int = 0;
const Button1Mask: c_uint = 1 << 8;
const CWOverrideRedirect: c_ulong = 1 << 9;
const XC_hand2: c_uint = 60;
const xdnd_version: c_long = 5;

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

const Phase = enum { idle, dragging, finishing };

pub const DragItem = struct {
    path:       []const u8,
    thumb_jpeg: []const u8,
};

pub const DragSource = struct {
    allocator:       std.mem.Allocator,
    // Private display — SDL3 never touches this queue, so XCheckIfEvent always wins.
    dnd_dpy:         *xlib.Display,
    src_win:         xlib.Window, // helper window; targets send responses here
    sdl_win:         xlib.Window, // SDL3's window (skip as drag target)
    root_win:        xlib.Window,
    atoms:           Atoms,
    // Pre-created font cursor; applied via XDefineCursor to the window we enter.
    drag_x11_cursor: xlib.Cursor,

    phase:     Phase = .idle,
    target:    xlib.Window = 0,
    accepted:  bool = false,
    uri_list:  []u8 = &.{},
    finish_ns: i96 = 0,

    pub fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?DragSource {
        const props = SDLBackend.c.SDL_GetWindowProperties(sdl_window);
        const dpy_opaque = SDLBackend.c.SDL_GetPointerProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null) orelse return null;
        const win_num = SDLBackend.c.SDL_GetNumberProperty(
            props, SDLBackend.c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (win_num == 0) return null;

        const sdl_dpy: *xlib.Display = @ptrCast(@alignCast(dpy_opaque));
        const sdl_win: xlib.Window = @intCast(win_num);

        // Mark the SDL3 window XdndAware so DiffKeep can receive drops from other apps.
        const sdl_aware = xlib.XInternAtom(sdl_dpy, "XdndAware", 0);
        var ver: c_long = xdnd_version;
        _ = xlib.XChangeProperty(sdl_dpy, sdl_win, sdl_aware, XA_ATOM, 32,
            PropModeReplace, @ptrCast(&ver), 1);
        _ = xlib.XFlush(sdl_dpy);

        // Private display connection — SDL3 only drains its own connection, so
        // XdndStatus, XdndFinished, and SelectionRequest land here undisturbed.
        const dnd_dpy = xlib.XOpenDisplay(null) orelse return null;
        const root_win = xlib.DefaultRootWindow(dnd_dpy);

        // Tiny invisible override-redirect window on dnd_dpy.
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
        _ = xlib.XFlush(dnd_dpy);

        // Create the drag cursor once; reused for every drag.
        const drag_x11_cursor = xlib.XCreateFontCursor(dnd_dpy, XC_hand2);

        std.log.debug("dnd: X11 DragSource init sdl_win=0x{x} src_win=0x{x}", .{ sdl_win, src_win });
        return .{
            .allocator       = allocator,
            .dnd_dpy         = dnd_dpy,
            .src_win         = src_win,
            .sdl_win         = sdl_win,
            .root_win        = root_win,
            .atoms           = atoms,
            .drag_x11_cursor = drag_x11_cursor,
        };
    }

    pub fn deinit(self: *DragSource) void {
        if (self.phase != .idle) self.abort();
        self.freeUriList();
        _ = xlib.XFreeCursor(self.dnd_dpy, self.drag_x11_cursor);
        _ = xlib.XDestroyWindow(self.dnd_dpy, self.src_win);
        _ = xlib.XCloseDisplay(self.dnd_dpy);
    }

    pub fn isDragging(self: *const DragSource) bool {
        return self.phase != .idle;
    }

    pub fn startDrag(self: *DragSource, items: []const DragItem) void {
        if (self.phase != .idle or items.len == 0) return;
        self.freeUriList();
        self.uri_list = buildUriList(self.allocator, items) catch return;
        _ = xlib.XSetSelectionOwner(self.dnd_dpy, self.atoms.XdndSelection, self.src_win, 0);
        _ = xlib.XFlush(self.dnd_dpy);
        self.phase    = .dragging;
        self.target   = 0;
        self.accepted = false;
        std.log.debug("dnd: startDrag {d} item(s), uri_list={d}b", .{ items.len, self.uri_list.len });
    }

    pub fn pumpEvents(self: *DragSource) void {
        var event: xlib.XEvent = undefined;
        while (xlib.XCheckIfEvent(self.dnd_dpy, &event, xdndPredicate, @ptrCast(self)) != 0) {
            self.handleX11Event(&event);
        }
    }

    pub fn tick(self: *DragSource, io: std.Io) void {
        switch (self.phase) {
            .idle      => {},
            .dragging  => self.tickDragging(io),
            .finishing => {
                const now = std.Io.Clock.real.now(io).nanoseconds;
                if (now - self.finish_ns > 2 * std.time.ns_per_s) self.resetToIdle();
            },
        }
    }

    // ── private ───────────────────────────────────────────────────────────────

    fn tickDragging(self: *DragSource, io: std.Io) void {
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

        if (mask & Button1Mask == 0) {
            self.finishDrag(io);
            return;
        }

        const new_target = self.findTarget(top_child, rx, ry);
        if (new_target != self.target) {
            std.log.debug("dnd: target 0x{x} → 0x{x}", .{ self.target, new_target });
            // Update cursor: remove from old target, set on new target.
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

    fn finishDrag(self: *DragSource, io: std.Io) void {
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

    fn abort(self: *DragSource) void {
        if (self.target != 0)
            self.sendMsg(self.target, self.atoms.XdndLeave,
                @bitCast(self.src_win), 0, 0, 0, 0);
        _ = xlib.XFlush(self.dnd_dpy);
        self.resetToIdle();
    }

    fn resetToIdle(self: *DragSource) void {
        _ = xlib.XSetSelectionOwner(self.dnd_dpy, self.atoms.XdndSelection, 0, 0);
        if (self.target != 0) _ = xlib.XUndefineCursor(self.dnd_dpy, self.target);
        _ = xlib.XFlush(self.dnd_dpy);
        self.phase  = .idle;
        self.target = 0;
        self.freeUriList();
    }

    fn freeUriList(self: *DragSource) void {
        if (self.uri_list.len > 0) {
            self.allocator.free(self.uri_list);
            self.uri_list = &.{};
        }
    }

    fn findTarget(self: *DragSource, top_win: xlib.Window, root_x: c_int, root_y: c_int) xlib.Window {
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

    fn xdndVersion(self: *DragSource, win: xlib.Window) ?u32 {
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

    fn getXdndProxy(self: *DragSource, win: xlib.Window) xlib.Window {
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

    fn sendMsg(self: *DragSource, win: xlib.Window, kind: xlib.Atom,
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

    fn handleX11Event(self: *DragSource, ev: *xlib.XEvent) void {
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
            else => {},
        }
    }

    fn answerSelectionRequest(self: *DragSource, sr: xlib.XSelectionRequestEvent) void {
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

    fn answerMultiple(self: *DragSource, sr: xlib.XSelectionRequestEvent, resp: *xlib.XEvent) void {
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

/// Build a text/uri-list payload.  Each path is percent-encoded as "file:///path\r\n".
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

fn xdndPredicate(dpy: ?*xlib.Display, ev: ?*xlib.XEvent, arg: xlib.XPointer) callconv(.c) xlib.Bool {
    _ = dpy;
    const self: *DragSource = @ptrCast(@alignCast(arg));
    const e = ev orelse return 0;
    if (e.type == ClientMessage) {
        const mt = e.xclient.message_type;
        if (mt == self.atoms.XdndStatus or mt == self.atoms.XdndFinished) return 1;
    }
    if (e.type == SelectionRequest and
        e.xselectionrequest.selection == self.atoms.XdndSelection) return 1;
    return 0;
}
