const std = @import("std");
const image_grid_mod = @import("image_grid.zig");

pub const ViewerState = struct {
    gpa: std.mem.Allocator,
    images: std.ArrayList(image_grid_mod.ImageEntry),
    open: bool = true,
    delete_requested: bool = false,
    delete_force: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        _id: u64,
        images: std.ArrayList(image_grid_mod.ImageEntry),
        _start_idx: usize,
        _wakeup_fn: ?*const fn () void,
        _data_dir: ?[]const u8,
    ) ViewerState {
        _ = _id;
        _ = _start_idx;
        _ = _wakeup_fn;
        _ = _data_dir;
        return .{ .gpa = allocator, .images = images };
    }

    pub fn deinit(self: *ViewerState) void {
        for (self.images.items) |e| self.gpa.free(e.path);
        self.images.deinit(self.gpa);
    }

    pub fn render(self: *ViewerState) void {
        _ = self;
    }

    pub fn currentImage(self: *const ViewerState) ?*const image_grid_mod.ImageEntry {
        _ = self;
        return null;
    }

    pub fn removeImages(self: *ViewerState, ids: *const std.AutoHashMap(u64, void)) void {
        _ = self;
        _ = ids;
    }
};
