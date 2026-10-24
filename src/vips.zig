const std = @import("std");

pub const c = @import("vips_c");

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

/// Number of pages/frames in an image (>1 means animated, e.g. GIF/WebP).
/// Returns 1 if not animated; error if the file can't be opened.
pub fn nPages(path: [:0]const u8) !u32 {
    const n = c.diffkeep_image_n_pages(path.ptr);
    if (n < 0) return error.VipsLoadFailed;
    return @intCast(@max(1, n));
}

/// Encode a packed RGBA8 buffer to a JPEG, downscaled to fit `size` on the long
/// edge. Used to turn a decoded video poster frame into a grid thumbnail.
pub fn rgbaToJpeg(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, size: c_int) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    if (c.diffkeep_rgba_to_jpeg(rgba.ptr, @intCast(width), @intCast(height), size, &buf, &len) != 0)
        return error.VipsEncodeFailed;
    defer c.diffkeep_vips_free(buf);
    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}

/// A decoded animation frame; `pixels` is packed RGBA8, allocator-owned.
/// Field-compatible with `video.DecodedFrame` so both feed the same player.
pub const DecodedFrame = struct { pixels: []u8, width: u32, height: u32, pts_ms: i64 };

/// Stateful decoder for animated images (GIF / animated WebP), which libav*
/// cannot fully decode. Forward-only; seeking backward reopens the file.
/// Not thread-safe — use from one thread. Mirrors `video.Decoder`.
pub const AnimDecoder = struct {
    handle: *c.DiffkeepAnimDecoder,

    /// Returns error.NotAnimated if the file has <= 1 page (or can't be opened).
    /// `max_dim` downscales frames to fit that many px on the long edge (for the
    /// grid); 0 keeps native resolution.
    pub fn open(path: [:0]const u8, max_dim: u32) !AnimDecoder {
        const h = c.diffkeep_anim_open(path.ptr, @intCast(max_dim)) orelse return error.NotAnimated;
        return .{ .handle = h };
    }

    pub fn close(self: AnimDecoder) void {
        c.diffkeep_anim_close(self.handle);
    }

    pub fn fps(self: AnimDecoder) f64 {
        return c.diffkeep_anim_fps(self.handle);
    }

    pub fn durationMs(self: AnimDecoder) i64 {
        return @intCast(c.diffkeep_anim_duration_ms(self.handle));
    }

    pub fn frameCount(self: AnimDecoder) u32 {
        return @intCast(@max(0, c.diffkeep_anim_frame_count(self.handle)));
    }

    /// Decode the next page (allocator-owned pixels), or null at end-of-stream.
    pub fn next(self: AnimDecoder, allocator: std.mem.Allocator) !?DecodedFrame {
        var buf: ?*anyopaque = null;
        var w: c_int = 0;
        var h: c_int = 0;
        var pts: c_long = 0;
        const r = c.diffkeep_anim_next(self.handle, &buf, &w, &h, &pts);
        if (r == 0) return null;
        if (r < 0) return error.AnimDecodeFailed;
        defer c.diffkeep_vips_free(buf);
        const len: usize = @intCast(w * h * 4);
        return .{
            .pixels = try allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]),
            .width = @intCast(w),
            .height = @intCast(h),
            .pts_ms = @intCast(pts),
        };
    }

    /// Reposition so the next frame is the page at/before ts_ms.
    pub fn seek(self: AnimDecoder, ts_ms: i64) void {
        _ = c.diffkeep_anim_seek(self.handle, @intCast(ts_ms));
    }
};

pub fn thumbnailToJpeg(allocator: std.mem.Allocator, path: [:0]const u8, size: c_int) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;

    if (c.diffkeep_thumbnail_to_jpeg(path.ptr, size, &buf, &len) != 0) {
        return error.VipsThumbnailFailed;
    }
    defer c.diffkeep_vips_free(buf);

    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}
