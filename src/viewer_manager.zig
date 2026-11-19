const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const image_viewer_mod = @import("image_viewer.zig");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const window_state = @import("window_state.zig");
const app_icons = @import("app_icons.zig");
const dnd_mod = @import("dnd.zig");

pub const ViewerWindow = struct {
    back: SDLBackend,
    win: dvui.Window,
    sdl_window_id: u32,
    state: image_viewer_mod.ViewerState,
    fonts_initialized: bool = false,
    // The window is created hidden and its saved geometry applied while hidden,
    // then shown after the first frame is presented — so it never flashes at the
    // default position/screen before jumping to the remembered spot.
    shown: bool = false,
    // Native drag source bound to this window, for dragging the current image
    // out to other apps.  null if the platform DnD backend is unavailable.
    dnd: ?dnd_mod.DragSource = null,
    // Fallback "move" cursor shown while a drag is in progress (when the backend
    // does not provide a thumbnail cursor).  Owned here; destroyed at deinit.
    dnd_drag_cursor: ?*SDLBackend.c.SDL_Cursor = null,

    /// Hide the window so it disappears immediately, and tell background loads to
    /// discard their results.  The real teardown (`deinit`) happens later, once
    /// the in-flight decodes have finished, so closing never blocks the UI.
    pub fn beginClose(self: *ViewerWindow) void {
        self.state.beginClose();
        _ = SDLBackend.c.SDL_HideWindow(self.back.window);
    }

    pub fn deinit(self: *ViewerWindow) void {
        if (self.dnd) |*d| d.deinit();
        if (self.dnd_drag_cursor) |c| SDLBackend.c.SDL_DestroyCursor(c);
        self.state.deinit();
        self.win.deinit();
        // Destroys the renderer and window; `sdl_quit` was cleared at creation.
        self.back.deinit();
    }
};

pub const ViewerManager = struct {
    windows: std.ArrayList(*ViewerWindow) = .empty,
    // Windows whose X has been clicked: hidden already, awaiting background loads
    // to finish before the (now non-blocking) teardown in reapClosing().
    closing: std.ArrayList(*ViewerWindow) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *ViewerManager, gpa: std.mem.Allocator) void {
        for (self.windows.items) |vw| {
            vw.deinit();
            gpa.destroy(vw);
        }
        self.windows.deinit(gpa);
        // At process exit, joining the remaining load threads is acceptable.
        for (self.closing.items) |vw| {
            vw.deinit();
            gpa.destroy(vw);
        }
        self.closing.deinit(gpa);
    }

    /// Move a window into the closing set: hide it now, tear it down later.
    pub fn beginClose(self: *ViewerManager, gpa: std.mem.Allocator, vw: *ViewerWindow) void {
        vw.beginClose();
        self.closing.append(gpa, vw) catch {
            // If we can't track it, fall back to a synchronous teardown.
            vw.deinit();
            gpa.destroy(vw);
        };
    }

    /// Tear down closing windows whose background loads have finished.  Returns
    /// true while any window is still pending, so the caller can keep polling.
    pub fn reapClosing(self: *ViewerManager, gpa: std.mem.Allocator) bool {
        var i: usize = 0;
        while (i < self.closing.items.len) {
            const vw = self.closing.items[i];
            if (vw.state.closeReady()) {
                vw.deinit();
                gpa.destroy(vw);
                _ = self.closing.swapRemove(i);
            } else i += 1;
        }
        return self.closing.items.len > 0;
    }

    pub fn open(
        self: *ViewerManager,
        grid: *image_grid_mod.GridState,
        start_id: ?u64,
        data_dir: ?[]const u8,
        db: ?*db_mod.VectorDb,
        wakeup_fn: *const fn () void,
        cfg: ?*config_mod.Config,
    ) void {
        const init = dvui.App.main_init orelse return;

        var images: std.ArrayList(image_grid_mod.ImageEntry) = .empty;
        const use_selection = grid.selection.count() > 1;
        for (grid.images.items) |e| {
            if (use_selection and !grid.selection.contains(e.id)) continue;
            const path_copy = init.gpa.dupe(u8, e.path) catch |err| {
                std.log.warn("viewer: {}", .{err});
                continue;
            };
            // Carry over trash metadata so the viewer can locate trashed files
            // (which live in <data_dir>/trash/<trash_name>, not at e.path).
            const trash_name_copy: ?[]const u8 = if (e.trash_name) |tn|
                init.gpa.dupe(u8, tn) catch {
                    init.gpa.free(path_copy);
                    continue;
                }
            else
                null;
            images.append(init.gpa, .{
                .id = e.id,
                .path = path_copy,
                .filename = std.Io.Dir.path.basename(path_copy),
                .mtime = e.mtime,
                .trashed_at = e.trashed_at,
                .trash_name = trash_name_copy,
                .favorite = e.favorite,
                .media_type = e.media_type,
            }) catch {
                init.gpa.free(path_copy);
                if (trash_name_copy) |tn| init.gpa.free(tn);
                continue;
            };
        }
        if (images.items.len == 0) {
            images.deinit(init.gpa);
            return;
        }

        var start_idx: usize = 0;
        if (start_id) |sid| {
            for (images.items, 0..) |e, i| {
                if (e.id == sid) {
                    start_idx = i;
                    break;
                }
            }
        }

        const id = self.next_id;
        self.next_id += 1;
        const vw = init.gpa.create(ViewerWindow) catch {
            for (images.items) |e| { init.gpa.free(e.path); if (e.trash_name) |tn| init.gpa.free(tn); }
            images.deinit(init.gpa);
            return;
        };

        const init_w: f32 = if (cfg) |c| @floatFromInt(c.viewer_window.width) else 1200;
        const init_h: f32 = if (cfg) |c| @floatFromInt(c.viewer_window.height) else 800;
        var back = SDLBackend.initWindow(.{
            .io = init.io,
            .size = .{ .w = init_w, .h = init_h },
            .min_size = .{ .w = 400, .h = 300 },
            .vsync = true,
            .title = "DiffKeep Viewer",
            .icon = app_icons.app_png,
            // Created hidden; shown after geometry is applied and the first frame
            // is presented (see ViewerWindow.shown).
            .hidden = true,
            // Geometry is persisted in our own config (viewer_window).
            .persist_window_geometry = false,
        }) catch {
            for (images.items) |e| { init.gpa.free(e.path); if (e.trash_name) |tn| init.gpa.free(tn); }
            images.deinit(init.gpa);
            init.gpa.destroy(vw);
            return;
        };
        // SDL3 doesn't refcount SDL_Init/SDL_Quit: a viewer's backend must
        // never call SDL_Quit (on close or on an error path below) while the
        // main window is still running.
        back.sdl_quit = false;

        vw.* = .{
            .back = back,
            .win = undefined,
            .sdl_window_id = 0,
            .state = image_viewer_mod.ViewerState.init(
                init.gpa, id, images, start_idx, wakeup_fn, data_dir,
                init.io, db, cfg,
            ),
        };
        vw.state.window_handle = @ptrCast(vw.back.window);
        // Restore the remembered window geometry now that the window exists.
        if (cfg) |c| {
            window_state.apply(vw.back.window, c.viewer_window);
        }

        vw.win = dvui.Window.init(@src(), init.gpa, vw.back.backend(), .{ .id_extra = @intCast(id) })
            catch {
                vw.back.deinit();
                vw.state.deinit();
                init.gpa.destroy(vw);
                return;
            };
        vw.sdl_window_id = SDLBackend.c.SDL_GetWindowID(vw.back.window);
        vw.dnd = dnd_mod.DragSource.init(init.gpa, vw.back.window);
        vw.state.dnd_available = vw.dnd != null;

        self.windows.append(init.gpa, vw) catch {
            vw.deinit();
            init.gpa.destroy(vw);
        };
    }

    pub fn removeImages(self: *ViewerManager, ids: *const std.AutoHashMap(u64, void)) void {
        for (self.windows.items) |vw| vw.state.removeImages(ids);
    }

    /// Propagate a favorite-flag change to every open viewer.
    pub fn setFavorite(self: *ViewerManager, id: u64, favorite: bool) void {
        for (self.windows.items) |vw| vw.state.setFavorite(id, favorite);
    }

};
