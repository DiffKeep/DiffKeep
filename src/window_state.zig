//! Shared helpers for remembering and restoring SDL window geometry
//! (size, position, maximized and fullscreen state).  Used by both the main
//! application window and the image-viewer windows so the behaviour stays
//! identical between them.
const SDLBackend = @import("backend");

/// Window geometry lives in config.zig (which has no SDL dependency) so it can
/// be serialized; this is just a convenient local alias.
pub const State = @import("config.zig").WindowState;

/// Sample the live window into `s`.  The maximized/fullscreen flags are always
/// refreshed; size and position are only updated while the window is in its
/// normal (restorable) state.  A maximized or fullscreen window reports the
/// expanded geometry, which would otherwise clobber the size/position we want
/// to reopen at.
pub fn capture(win: *SDLBackend.c.SDL_Window, s: *State) void {
    const flags = SDLBackend.c.SDL_GetWindowFlags(win);
    s.maximized = (flags & SDLBackend.c.SDL_WINDOW_MAXIMIZED) != 0;
    s.fullscreen = (flags & SDLBackend.c.SDL_WINDOW_FULLSCREEN) != 0;
    if (s.maximized or s.fullscreen) return;

    var w: c_int = 0;
    var h: c_int = 0;
    if (SDLBackend.c.SDL_GetWindowSize(win, &w, &h) and w > 0 and h > 0) {
        s.width = @intCast(w);
        s.height = @intCast(h);
    }

    var x: c_int = 0;
    var y: c_int = 0;
    if (SDLBackend.c.SDL_GetWindowPosition(win, &x, &y)) {
        s.x = @intCast(x);
        s.y = @intCast(y);
    }
}

/// Apply remembered geometry to a freshly created (normal-state) window.  Sets
/// the restore size/position first, then maximizes or goes fullscreen so the
/// window manager keeps the normal geometry to restore to.  Fullscreen takes
/// priority over maximized.
pub fn apply(win: *SDLBackend.c.SDL_Window, s: State) void {
    _ = SDLBackend.c.SDL_SetWindowSize(win, @intCast(s.width), @intCast(s.height));
    if (s.x) |x| {
        if (s.y) |y| _ = SDLBackend.c.SDL_SetWindowPosition(win, @intCast(x), @intCast(y));
    }
    if (s.fullscreen) {
        _ = SDLBackend.c.SDL_SetWindowFullscreen(win, true);
    } else if (s.maximized) {
        _ = SDLBackend.c.SDL_MaximizeWindow(win);
    }
}
