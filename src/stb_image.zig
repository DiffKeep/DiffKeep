const std = @import("std");
const c = @import("stb_image");

pub const Image = struct {
    data: [*]u8,
    width: i32,
    height: i32,
    channels: i32,
    
    pub fn deinit(self: Image) void {
        c.stbi_image_free(self.data);
    }
};

/// Load an image from a file
pub fn loadFromFile(allocator: std.mem.Allocator, filename: []const u8, desired_channels: i32) !Image {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    const data = c.stbi_load(terminated_path, &width, &height, &channels, desired_channels);
    if (data == null) {
        return error.ImageLoadFailed;
    }
    
    return Image{
        .data = data,
        .width = width,
        .height = height,
        .channels = if (desired_channels == 0) channels else desired_channels,
    };
}

/// Load an image from memory
pub fn loadFromMemory(buffer: []const u8, desired_channels: i32) !Image {
    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    const data = c.stbi_load_from_memory(
        buffer.ptr, 
        @as(i32, @intCast(buffer.len)),
        &width, 
        &height, 
        &channels, 
        desired_channels
    );
    
    if (data == null) {
        return error.ImageLoadFailed;
    }
    
    return Image{
        .data = data,
        .width = width,
        .height = height,
        .channels = if (desired_channels == 0) channels else desired_channels,
    };
}

/// Get the last error that occurred
pub fn getError() ?[:0]const u8 {
    const err = c.stbi_failure_reason();
    if (err == null) {
        return null;
    }
    return std.mem.span(err);
}

/// Set flip vertically on load
pub fn setFlipVerticallyOnLoad(flip: bool) void {
    c.stbi_set_flip_vertically_on_load(flip);
}

/// Load a 16-bit image from a file
pub fn load16FromFile(allocator: std.mem.Allocator, filename: []const u8, desired_channels: i32) !struct { data: [*]u16, width: i32, height: i32, channels: i32 } {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    const data = c.stbi_load_16(terminated_path, &width, &height, &channels, desired_channels);
    if (data == null) {
        return error.ImageLoadFailed;
    }
    
    return .{
        .data = data,
        .width = width,
        .height = height,
        .channels = if (desired_channels == 0) channels else desired_channels,
    };
}

/// Load an HDR image from a file
pub fn loadHDRFromFile(allocator: std.mem.Allocator, filename: []const u8, desired_channels: i32) !struct { data: [*]f32, width: i32, height: i32, channels: i32 } {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    const data = c.stbi_loadf(terminated_path, &width, &height, &channels, desired_channels);
    if (data == null) {
        return error.ImageLoadFailed;
    }
    
    return .{
        .data = data,
        .width = width,
        .height = height,
        .channels = if (desired_channels == 0) channels else desired_channels,
    };
}

/// Load an HDR image from memory
pub fn loadHDRFromMemory(buffer: []const u8, desired_channels: i32) !struct { data: [*]f32, width: i32, height: i32, channels: i32 } {
    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    const data = c.stbi_loadf_from_memory(
        buffer.ptr, 
        @as(i32, @intCast(buffer.len)),
        &width, 
        &height, 
        &channels, 
        desired_channels
    );
    
    if (data == null) {
        return error.ImageLoadFailed;
    }
    
    return .{
        .data = data,
        .width = width,
        .height = height,
        .channels = if (desired_channels == 0) channels else desired_channels,
    };
}

/// Check if a file is an HDR file
pub fn isHDR(allocator: std.mem.Allocator, filename: [*:0]const u8) bool {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    return c.stbi_is_hdr(terminated_path) != 0;
}

/// Check if a file in memory is an HDR file
pub fn isHDRFromMemory(buffer: []const u8) bool {
    return c.stbi_is_hdr_from_memory(buffer.ptr, @as(i32, @intCast(buffer.len))) != 0;
}

/// Check if a file is a 16-bit-per-channel image
pub fn is16bit(allocator: std.mem.Allocator, filename: [*:0]const u8) bool {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    return c.stbi_is_16_bit(terminated_path) != 0;
}

/// Information about an image without loading the full data
pub fn info(allocator: std.mem.Allocator, filename: [*:0]const u8) !struct { width: i32, height: i32, channels: i32 } {
    const terminated_path = try allocator.dupeZ(u8, filename);
    defer allocator.free(terminated_path);

    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    if (c.stbi_info(terminated_path, &width, &height, &channels) == 0) {
        return error.InfoFailed;
    }
    
    return .{
        .width = width,
        .height = height,
        .channels = channels,
    };
}

/// Information about an image in memory without loading the full data
pub fn infoFromMemory(buffer: []const u8) !struct { width: i32, height: i32, channels: i32 } {
    var width: i32 = undefined;
    var height: i32 = undefined;
    var channels: i32 = undefined;
    
    if (c.stbi_info_from_memory(buffer.ptr, @as(i32, @intCast(buffer.len)), &width, &height, &channels) == 0) {
        return error.InfoFailed;
    }
    
    return .{
        .width = width,
        .height = height,
        .channels = channels,
    };
}