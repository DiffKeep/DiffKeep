const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const image_viewer_mod = @import("image_viewer.zig");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");

pub const ViewerWindow = struct {
    back: SDLBackend,
    win: dvui.Window,
    sdl_window_id: u32,
    state: image_viewer_mod.ViewerState,
    fonts_initialized: bool = false,

    pub fn deinit(self: *ViewerWindow) void {
        self.state.deinit();
        self.win.deinit();
        // Destroy the SDL renderer and window manually, then suppress SDL_Quit.
        // SDL3 does not refcount SDL_Init/SDL_Quit — calling SDL_Quit from a
        // viewer deinit would tear down the video subsystem while the main window
        // is still running.  Only the main window's deferred back.deinit() should
        // call SDL_Quit at process exit.
        SDLBackend.c.SDL_DestroyRenderer(self.back.renderer);
        SDLBackend.c.SDL_DestroyWindow(self.back.window);
        self.back.we_own_window = false;
        self.back.deinit();
    }
};

pub const ViewerManager = struct {
    windows: std.ArrayList(*ViewerWindow) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *ViewerManager, gpa: std.mem.Allocator) void {
        for (self.windows.items) |vw| {
            vw.deinit();
            gpa.destroy(vw);
        }
        self.windows.deinit(gpa);
    }

    pub fn open(
        self: *ViewerManager,
        grid: *image_grid_mod.GridState,
        start_id: ?u64,
        data_dir: ?[]const u8,
        db: ?*db_mod.VectorDb,
        wakeup_fn: *const fn () void,
    ) void {
        const init = dvui.App.main_init orelse return;

        var images: std.ArrayList(image_grid_mod.ImageEntry) = .empty;
        const use_selection = grid.selection.count() > 1;
        for (grid.images.items) |e| {
            if (use_selection and !grid.selection.contains(e.id)) continue;
            const path_copy = init.gpa.dupe(u8, e.path) catch continue;
            images.append(init.gpa, .{
                .id = e.id,
                .path = path_copy,
                .filename = std.fs.path.basename(path_copy),
                .mtime = e.mtime,
            }) catch {
                init.gpa.free(path_copy);
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
            for (images.items) |e| init.gpa.free(e.path);
            images.deinit(init.gpa);
            return;
        };

        const back = SDLBackend.initWindow(.{
            .io = init.io,
            .allocator = init.gpa,
            .size = .{ .w = 1200, .h = 800 },
            .min_size = .{ .w = 400, .h = 300 },
            .vsync = true,
            .title = "DiffKeep Viewer",
        }) catch {
            for (images.items) |e| init.gpa.free(e.path);
            images.deinit(init.gpa);
            init.gpa.destroy(vw);
            return;
        };

        vw.* = .{
            .back = back,
            .win = undefined,
            .sdl_window_id = 0,
            .state = image_viewer_mod.ViewerState.init(
                init.gpa, id, images, start_idx, wakeup_fn, data_dir,
                init.io, db,
            ),
        };
        vw.state.sdl_window_ptr = vw.back.window;

        vw.win = dvui.Window.init(@src(), init.gpa, vw.back.backend(), .{ .id_extra = @intCast(id) })
            catch {
                vw.back.deinit();
                vw.state.deinit();
                init.gpa.destroy(vw);
                return;
            };
        vw.sdl_window_id = SDLBackend.c.SDL_GetWindowID(vw.back.window);

        self.windows.append(init.gpa, vw) catch {
            vw.deinit();
            init.gpa.destroy(vw);
        };
    }

    pub fn removeImages(self: *ViewerManager, ids: *const std.AutoHashMap(u64, void)) void {
        for (self.windows.items) |vw| vw.state.removeImages(ids);
    }
};
