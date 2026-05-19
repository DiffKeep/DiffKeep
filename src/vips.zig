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

/// Decode a full-resolution image to packed RGBA8 pixels.
/// The returned slice is gpa-owned; caller frees with allocator.free().
pub fn loadImageRgba(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    var w: c_int = 0;
    var h: c_int = 0;

    if (c.diffkeep_load_image_rgba(path.ptr, &buf, &len, &w, &h) != 0)
        return error.VipsLoadFailed;
    defer c.diffkeep_vips_free(buf);

    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}

/// Same as loadImageRgba but also returns the image dimensions.
pub fn loadImageRgbaWithDims(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
) !struct { pixels: []u8, width: u32, height: u32 } {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    var w: c_int = 0;
    var h: c_int = 0;

    if (c.diffkeep_load_image_rgba(path.ptr, &buf, &len, &w, &h) != 0)
        return error.VipsLoadFailed;
    defer c.diffkeep_vips_free(buf);

    const pixels = try allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
    return .{
        .pixels = pixels,
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

pub fn jpegBytesToRgba(
    allocator: std.mem.Allocator,
    jpeg_data: []const u8,
    size: c_int,
) !struct { pixels: []u8, width: u32, height: u32 } {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    var w: c_int = 0;
    var h: c_int = 0;

    if (c.diffkeep_jpeg_bytes_to_rgba(jpeg_data.ptr, jpeg_data.len, size, &buf, &len, &w, &h) != 0)
        return error.VipsDecodeFailed;
    defer c.diffkeep_vips_free(buf);

    return .{
        .pixels = try allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]),
        .width  = @intCast(w),
        .height = @intCast(h),
    };
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
