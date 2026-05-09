const std = @import("std");

const c = @cImport({
    @cInclude("vips_helper.h");
});

pub fn init() !void {
    if (c.diffkeep_vips_init("diffkeep") != 0) return error.VipsInitFailed;
}

pub fn deinit() void {
    c.diffkeep_vips_shutdown();
}

pub fn thumbnailToPng(allocator: std.mem.Allocator, path: [:0]const u8, max_dimension: c_int) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;

    if (c.diffkeep_thumbnail_to_png(path.ptr, max_dimension, &buf, &len) != 0) {
        return error.VipsThumbnailFailed;
    }
    defer c.diffkeep_vips_free(buf);

    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}
