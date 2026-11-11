//! Entry point: the SDL window, its event loop, and the SDL-only parts of the
//! app (viewer windows, native drag-and-drop, waking the event loop). The
//! rest of the main window lives in app_state.zig, driven from here.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// From git at build time (build.zig: tools/git_version.zig).
const app_version = @embedFile("git_version");
const vips_mod = @import("vips");
const SDLBackend = @import("backend");
const image_grid_mod = @import("image_grid.zig");
const dnd_mod = @import("dnd.zig");
const viewer_manager_mod = @import("viewer_manager.zig");
const window_state = @import("window_state.zig");
const platform = @import("platform.zig");
const platform_sdl = @import("platform_sdl.zig");
const style = @import("style.zig");
const app_state = @import("app_state.zig");

const log = std.log.scoped(.app);

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// dvui's callbacks and SDL's event wakeup carry no context, so these few
// things are module state; everything else is in `g_app`.
var g_app: app_state.AppState = undefined;
var g_app_ready = false;
/// --config / -c: <dir>/DiffKeep.cfg instead of the XDG config dir. Owned
/// until handed to `g_app.init`.
var g_config_arg: ?[]const u8 = null;
var g_wakeup_event_type: u32 = 0;
var g_dnd: ?dnd_mod.DragSource = null;
var g_dnd_drag_cursor: ?*SDLBackend.c.SDL_Cursor = null;
var g_viewer_manager: viewer_manager_mod.ViewerManager = .{};

/// Wake the event loop from any thread (a custom SDL event).
fn wakeupFrame() void {
    // Background work can finish before the event type is registered at
    // startup; the first frame picks its result up anyway.
    if (g_wakeup_event_type == 0) return;
    var ev: SDLBackend.c.SDL_Event = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ev.type = g_wakeup_event_type;
    _ = SDLBackend.c.SDL_PushEvent(&ev);
}

// ── Hooks: what AppState asks of the SDL side ────────────────────────────────

fn openViewer(app: *app_state.AppState, grid: *image_grid_mod.GridState, start_id: ?u64) void {
    g_viewer_manager.open(grid, start_id, app.data_dir, if (app.db) |*db| db else null, wakeupFrame, &app.cfg);
}

fn startDrag(items: []const app_state.DragItem) void {
    const dnd = if (g_dnd) |*d| d else return;
    const gpa = g_app.gpa;
    const native = gpa.alloc(dnd_mod.DragItem, items.len) catch return;
    defer gpa.free(native);
    for (items, native) |it, *n| n.* = .{ .path = it.path, .thumb_jpeg = it.thumb_jpeg };
    dnd.startDrag(native);
}

fn viewersRemove(ids: *const std.AutoHashMap(u64, void)) void {
    g_viewer_manager.removeImages(ids);
}

fn viewersSetFavorite(id: u64, favorite: bool) void {
    g_viewer_manager.setFavorite(id, favorite);
}

// ── dvui callbacks ───────────────────────────────────────────────────────────

fn appStart() dvui.App.StartOptions {
    if (dvui.App.main_init) |init| {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.skip(); // skip argv[0] (executable path)
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                if (it.next()) |val| {
                    g_config_arg = std.Io.Dir.path.join(init.gpa, &.{ val, "DiffKeep.cfg" }) catch null;
                }
            }
        }
    }

    return .{
        .size = .{ .w = 1200.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .title = "DiffKeep",
        .vsync = true,
    };
}

fn appInit(win: *dvui.Window) !void {
    _ = win;
    const init = dvui.App.main_init.?;
    // Install the real SDL-backed platform services (clipboard image data,
    // native folder picker). UI modules call these through the platform seam.
    platform.init(platform_sdl.vtable);
    // VIPS must be initialized before any worker thread calls into it.
    try vips_mod.init();
    // A custom SDL event lets background work wake the render loop (dvui
    // only renders on input otherwise).
    g_wakeup_event_type = SDLBackend.c.SDL_RegisterEvents(1);

    const config_path = g_config_arg;
    g_config_arg = null;
    try g_app.init(init.io, init.gpa, init.environ_map, .{
        .wakeup = wakeupFrame,
        .open_viewer = openViewer,
        .start_drag = startDrag,
        .viewers_remove = viewersRemove,
        .viewers_set_favorite = viewersSetFavorite,
    }, config_path);
    g_app_ready = true;

    log.info("DiffKeep {s} — config: {s}", .{ app_version, g_app.config_path orelse "(none)" });
    style.install();
}

fn appDeinit() void {
    if (g_dnd) |*dnd| dnd.deinit();
    if (g_app_ready) g_app.deinit();
    g_app_ready = false;
    // After everything that uses VIPS has stopped.
    vips_mod.deinit();
}

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }
    try g_app.frame();
    return .ok;
}

// ── SDL event routing ────────────────────────────────────────────────────────

fn routeAllSDLEvents(main_back: *SDLBackend, main_win: *dvui.Window) void {
    if (g_dnd) |*dnd| dnd.pumpEvents();
    for (g_viewer_manager.windows.items) |vw| {
        if (vw.dnd) |*dnd| dnd.pumpEvents();
    }
    const main_id = SDLBackend.c.SDL_GetWindowID(main_back.window);
    var event: SDLBackend.c.SDL_Event = undefined;
    while (SDLBackend.c.SDL_PollEvent(&event)) {
        // Notify the active DnD of button release before routing — SDL's event is
        // more timely than XQueryPointer on XWayland.  Only one drag is ever in
        // progress, so notify whichever source is currently dragging.
        if (event.type == SDLBackend.c.SDL_EVENT_MOUSE_BUTTON_UP and
            event.button.button == 1)
        {
            if (g_dnd) |*dnd| { if (dnd.isDragging()) dnd.notifyButtonUp(); }
            for (g_viewer_manager.windows.items) |vw| {
                if (vw.dnd) |*dnd| { if (dnd.isDragging()) dnd.notifyButtonUp(); }
            }
        }
        const eid = sdlEventWindowID(event);
        if (eid == 0 or eid == main_id) {
            _ = main_back.addEvent(main_win, event) catch {};
            continue;
        }
        for (g_viewer_manager.windows.items) |vw| {
            if (vw.sdl_window_id == eid) {
                _ = vw.back.addEvent(&vw.win, event) catch {};
                break;
            }
        }
    }
}

fn sdlEventWindowID(event: SDLBackend.c.SDL_Event) u32 {
    const SDL = SDLBackend.c;
    return switch (event.type) {
        SDL.SDL_EVENT_KEY_DOWN, SDL.SDL_EVENT_KEY_UP             => event.key.windowID,
        SDL.SDL_EVENT_TEXT_INPUT, SDL.SDL_EVENT_TEXT_EDITING     => event.text.windowID,
        SDL.SDL_EVENT_MOUSE_MOTION                               => event.motion.windowID,
        SDL.SDL_EVENT_MOUSE_BUTTON_DOWN,
        SDL.SDL_EVENT_MOUSE_BUTTON_UP                            => event.button.windowID,
        SDL.SDL_EVENT_MOUSE_WHEEL                                => event.wheel.windowID,
        SDL.SDL_EVENT_WINDOW_RESIZED,
        SDL.SDL_EVENT_WINDOW_FOCUS_GAINED,
        SDL.SDL_EVENT_WINDOW_FOCUS_LOST,
        SDL.SDL_EVENT_WINDOW_MOUSE_ENTER,
        SDL.SDL_EVENT_WINDOW_MOUSE_LEAVE,
        SDL.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        SDL.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED               => event.window.windowID,
        else                                                     => 0,
    };
}

fn pickMinWait(a: ?u32, b: ?u32) ?u32 {
    const av = a orelse return b;
    const bv = b orelse return a;
    return @min(av, bv);
}

/// Show the drag cursor (the thumbnail, or a generic move cursor) while a
/// drag from this window is in progress; restore the normal one after.
fn updateDragCursor(dnd: *dnd_mod.DragSource, fallback: *?*SDLBackend.c.SDL_Cursor) void {
    if (dnd.isDragging()) {
        if (dnd.getSdlCursor()) |thumb_cursor| {
            _ = SDLBackend.c.SDL_SetCursor(thumb_cursor);
        } else {
            if (fallback.* == null)
                fallback.* = SDLBackend.c.SDL_CreateSystemCursor(SDLBackend.c.SDL_SYSTEM_CURSOR_MOVE);
            if (fallback.*) |c| _ = SDLBackend.c.SDL_SetCursor(c);
        }
    } else if (fallback.*) |c| {
        _ = SDLBackend.c.SDL_SetCursor(null);
        SDLBackend.c.SDL_DestroyCursor(c);
        fallback.* = null;
    }
}

/// One frame of a viewer window, and what it asked the app to do. Returns
/// whether the window should close, and how long it may wait.
fn renderViewerWindow(vw: *viewer_manager_mod.ViewerWindow, nstime: i128, io: std.Io) !struct { close: bool, wait: ?u32 } {
    try vw.win.begin(nstime);
    if (vw.dnd) |*d| d.tick(io);
    if (!vw.fonts_initialized) {
        vw.fonts_initialized = true;
        style.install();
    }

    _ = SDLBackend.c.SDL_SetRenderDrawColor(vw.back.renderer, 0, 0, 0, 255);
    _ = SDLBackend.c.SDL_RenderClear(vw.back.renderer);
    vw.state.render();

    if (vw.state.delete_requested) {
        vw.state.delete_requested = false;
        g_app.openViewerDeleteDialog(&vw.state, vw.state.delete_force);
    }
    if (vw.state.favorite_toggle_requested) {
        vw.state.favorite_toggle_requested = false;
        if (vw.state.currentImage()) |img| g_app.toggleFavorite(img.id, img.path, img.favorite);
    }
    if (vw.state.delete_confirmed) {
        vw.state.delete_confirmed = false;
        if (vw.state.delete_no_ask) {
            vw.state.delete_no_ask = false;
            if (vw.state.delete_pending_permanent) g_app.delete_dialog.skip_permanent_delete_confirm = true
            else g_app.delete_dialog.skip_delete_confirm = true;
        }
        const iid = vw.state.delete_pending_id;
        for (vw.state.images.items) |e| {
            if (e.id == iid) {
                g_app.performViewerDeleteEntry(e, vw.state.delete_pending_permanent);
                break;
            }
        }
    }
    if (vw.state.drag_requested) {
        vw.state.drag_requested = false;
        if (vw.dnd) |*d| if (vw.state.currentImage()) |img| {
            const thumb = if (g_app.grid) |*grid| grid.thumbs.committed.get(img.id) else null;
            d.startDrag(&.{dnd_mod.DragItem{
                .path = img.path,
                .thumb_jpeg = if (thumb) |t| t.bytes else &.{},
            }});
        };
    }

    var close = !vw.state.open;
    for (dvui.events()) |*e| {
        if (!e.handled and e.evt == .window and e.evt.window.action == .close)
            close = true;
    }
    const wait: ?u32 = try vw.win.end(.{ .manage_backend = false });
    vw.back.setCursor(vw.win.cursorRequested());
    if (vw.dnd) |*d| updateDragCursor(d, &vw.dnd_drag_cursor);
    vw.back.renderPresent();

    // Reveal the window only after its first frame has been drawn and its
    // saved geometry applied (in viewer_manager.open, while hidden). This
    // avoids it appearing at the default position/screen and then jumping.
    if (!vw.shown) {
        vw.shown = true;
        _ = SDLBackend.c.SDL_ShowWindow(vw.back.window);
    }
    return .{ .close = close, .wait = wait };
}

/// Cap glibc's per-thread malloc arenas. DiffKeep runs ~60 threads (libvips
/// threadpool, grid loaders, library scanners, the fs watcher); glibc's default
/// of up to 8×CPU arenas leaves each thread hoarding freed memory it never
/// returns to the OS — about 150 MB of idle slack in practice. Capping the arena
/// count reclaims most of that; 4 keeps enough concurrency that the vips
/// threadpool isn't serialised on a single malloc lock during scans. Linux/glibc
/// only (mallopt is a no-op or absent elsewhere); must run before threads spawn.
fn tuneAllocator() void {
    if (builtin.target.os.tag != .linux) return;
    const glibc = struct {
        extern "c" fn mallopt(param: c_int, value: c_int) c_int;
    };
    _ = glibc.mallopt(-8, 4); // -8 == M_ARENA_MAX
}

pub fn main(init: std.process.Init) !void {
    tuneAllocator();
    dvui.App.main_init = init;
    SDLBackend.c.SDL_SetMainReady();

    const opts = appStart();
    var back = try SDLBackend.initWindow(.{
        .io = init.io,
        .size = opts.size,
        .min_size = opts.min_size,
        .vsync = opts.vsync,
        .title = opts.title,
        .environ_map = init.environ_map,
        // Geometry is persisted in our own config (window_state.zig).
        .persist_window_geometry = false,
    });
    defer back.deinit();

    var win = try dvui.Window.init(@src(), init.gpa, back.backend(), .{});
    defer win.deinit();

    try win.begin(win.frame_time_ns);
    try appInit(&win);
    _ = try win.end(.{});
    // Restore the remembered main-window geometry (config is now loaded).
    window_state.apply(back.window, g_app.cfg.main_window);
    g_dnd = dnd_mod.DragSource.init(init.gpa, back.window);
    defer appDeinit();
    defer g_viewer_manager.deinit(init.gpa);

    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        routeAllSDLEvents(&back, &win);
        if (g_dnd) |*dnd| dnd.tick(init.io);

        // ── Main window ───────────────────────────────────────────────────────
        try win.begin(nstime);
        _ = SDLBackend.c.SDL_SetRenderDrawColor(back.renderer, 0, 0, 0, 255);
        _ = SDLBackend.c.SDL_RenderClear(back.renderer);
        var res = try frame();
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if ((e.evt == .window and e.evt.window.action == .close) or
                (e.evt == .app and e.evt.app.action == .quit)) res = .close;
        }
        // Remember the window geometry (saved with the config on exit).
        window_state.capture(back.window, &g_app.cfg.main_window);
        // Backend is managed by hand below: the DnD cursor overrides dvui's.
        var end_micros: ?u32 = try win.end(.{ .manage_backend = false });
        back.setCursor(win.cursorRequested());
        if (g_dnd) |*dnd| updateDragCursor(dnd, &g_dnd_drag_cursor);
        back.textInputRect(win.textInputRequested());
        back.renderPresent();
        if (res == .close) {
            // Hide right away: shutdown below waits for background work, and a
            // window that stays up looks hung.
            _ = SDLBackend.c.SDL_HideWindow(back.window);
            for (g_viewer_manager.windows.items) |vw| _ = SDLBackend.c.SDL_HideWindow(vw.back.window);
            break :main_loop;
        }

        // ── Viewer windows ────────────────────────────────────────────────────
        var vi: usize = 0;
        while (vi < g_viewer_manager.windows.items.len) {
            const vw = g_viewer_manager.windows.items[vi];
            const r = try renderViewerWindow(vw, nstime, init.io);
            end_micros = pickMinWait(end_micros, r.wait);
            if (r.close) {
                // Hide immediately and defer the (thread-joining) teardown so the
                // window vanishes at once instead of freezing while loads finish.
                g_viewer_manager.beginClose(init.gpa, vw);
                _ = g_viewer_manager.windows.swapRemove(vi);
            } else {
                vi += 1;
            }
        }

        // Reap closed windows once their background loads have exited.  Poll
        // briefly while any remain pending so cleanup isn't stranded until the
        // next user event.
        if (g_viewer_manager.reapClosing(init.gpa)) {
            end_micros = pickMinWait(end_micros, 30_000);
        }

        // If a search debounce is pending, cap the event-wait to the deadline so
        // the render loop fires even when the user has stopped generating events.
        if (g_app.search.debounce_deadline_ns != 0) {
            const now = std.Io.Clock.real.now(init.io).nanoseconds;
            const remaining_ns = g_app.search.debounce_deadline_ns - now;
            const cap_us: u32 = if (remaining_ns <= 0) 0 else @intCast(@min(@divTrunc(remaining_ns, 1000) + 1, std.math.maxInt(u32)));
            end_micros = pickMinWait(end_micros, cap_us);
        }

        const wait_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_micros);
    }
}
