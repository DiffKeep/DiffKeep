const std = @import("std");
const log = std.log.scoped(.config);

pub const Config = struct {
    /// Override for the database directory. Falls back to the XDG data dir.
    data_path: ?[]const u8 = null,

    fullscreen: bool = false,
    /// Zero-based index of the display to open the window on.
    screen: u32 = 0,
    window_width: u32 = 1200,
    window_height: u32 = 800,
    window_x: ?i32 = null,
    window_y: ?i32 = null,

    thumbnails_in_db: bool = true,
    prompt_embeddings: bool = true,
    image_embeddings: bool = true,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.data_path) |p| allocator.free(p);
    }
};

/// Reads the config file at `path`. Returns defaults if the file does not exist.
/// The caller owns any heap-allocated fields in the returned Config (free with deinit).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    var buf: [16384]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };

    const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var config = parsed.value;
    if (config.data_path) |p| config.data_path = try allocator.dupe(u8, p);
    return config;
}

/// Writes the config to `path`, creating parent directories as needed.
pub fn save(config: Config, io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var buf: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    var js: std.json.Stringify = .{
        .writer = &out,
        .options = .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        },
    };
    try js.write(config);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.buffered() });
    log.info("config saved to {s}", .{path});
}
