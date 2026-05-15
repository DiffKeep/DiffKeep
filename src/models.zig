const std = @import("std");
const vips = @import("vips");

pub const Library = struct {
    id: u64,
    path: []const u8,

    pub fn deinit(self: *Library, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Image = struct {
    id: u64,
    libraryPath: []const u8,
    libraryId: u64,
    creationDate: []const u8,
    positivePromptText: ?[]const u8,
    negativePromptText: ?[]const u8,
    generatedDescription: ?[]const u8,
    thumbnail: ?[]u8,
    hash: ?[]const u8,
    mtime: ?i64,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.libraryPath);
        allocator.free(self.creationDate);
        if (self.positivePromptText) |p| allocator.free(p);
        if (self.negativePromptText) |p| allocator.free(p);
        if (self.generatedDescription) |d| allocator.free(d);
        if (self.thumbnail) |t| allocator.free(t);
        if (self.hash) |h| allocator.free(h);
    }

    pub fn generate_thumbnail(self: *Image, _: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.thumbnail) |t| {
            allocator.free(t);
            self.thumbnail = null;
        }

        const terminated_path = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated_path);

        self.thumbnail = try vips.thumbnailToJpeg(allocator, terminated_path, 320);
    }
};
