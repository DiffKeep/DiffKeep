// models.zig
const std = @import("std");
const zstbi = @import("zstbi");

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
    creationDate: []const u8, // Or use a proper time type
    positivePromptText: ?[]const u8,
    negativePromptText: ?[]const u8,
    generatedDescription: ?[]const u8,
    thumbnail: ?[]u8, // For BLOB data
    hash: ?[]const u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.libraryPath);
        allocator.free(self.creationDate);
        if (self.positivePromptText) |p| allocator.free(p);
        if (self.negativePromptText) |p| allocator.free(p);
        if (self.generatedDescription) |d| allocator.free(d);
        if (self.thumbnail) |t| allocator.free(t);
        if (self.hash) |h| allocator.free(h);
    }

    /// Generates a thumbnail from the file and puts it in image.thumbnail
    pub fn generate_thumbnail(self: *Image, allocator: std.mem.Allocator, path: []const u8) !void {
        // Free the existing thumbnail if it exists
        if (self.thumbnail) |t| {
            allocator.free(t);
            self.thumbnail = null;
        }

        const terminated_path = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated_path);

        var img = try zstbi.Image.loadFromFile(terminated_path, 4);
        defer img.deinit();

        // Calculate new dimensions maintaining aspect ratio
        const max_dimension: u32 = 256;
        const aspect_ratio = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));
        var new_width: u32 = undefined;
        var new_height: u32 = undefined;

        if (img.width > img.height) {
            new_width = max_dimension;
            new_height = @intFromFloat(@as(f32, @floatFromInt(max_dimension)) / aspect_ratio);
        } else {
            new_height = max_dimension;
            new_width = @intFromFloat(@as(f32, @floatFromInt(max_dimension)) * aspect_ratio);
        }

        var resized = zstbi.Image.resize(&img, new_width, new_height);
        defer resized.deinit();

        // Create an ArrayList to store our buffer
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Create a context struct to hold our ArrayList
        const Context = struct {
            buffer: *std.ArrayList(u8),
        };

        // Write function that will be called by writeToFn
        const writeCallback = struct {
            fn callback(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.C) void {
                const context: *Context = @ptrCast(@alignCast(ctx.?));
                const bytes = @as([*]const u8, @ptrCast(data.?))[0..@as(usize, @intCast(size))];
                context.buffer.appendSlice(bytes) catch unreachable;
            }
        }.callback;

        // Create our context
        var context = Context{ .buffer = &buffer };

        // Write the image to our buffer
        try resized.writeToFn(writeCallback, &context, .png);

        // Store the buffer in the thumbnail field
        self.thumbnail = try buffer.toOwnedSlice();
    }
};
