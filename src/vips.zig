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

/// Call at the end of any OS thread that has used VIPS to release GLib thread-local state.
pub fn threadShutdown() void {
    c.diffkeep_vips_thread_shutdown();
}

pub fn thumbnailToJpeg(allocator: std.mem.Allocator, path: [:0]const u8, size: c_int) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;

    if (c.diffkeep_thumbnail_to_jpeg(path.ptr, size, &buf, &len) != 0) {
        return error.VipsThumbnailFailed;
    }
    defer c.diffkeep_vips_free(buf);

    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}
