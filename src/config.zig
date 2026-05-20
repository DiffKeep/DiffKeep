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

    thumbnails_in_db: bool = false,
    prompt_embeddings: bool = false,
    image_embeddings: bool = false,
    trash_enabled: bool = true,
    embedding_model_path: ?[]const u8 = null,   // path to Qwen3-VL-Embedding-2B text gguf
    embedding_mmproj_path: ?[]const u8 = null,  // path to mmproj gguf for image embeddings
    reranker_model_path: ?[]const u8 = null,    // path to Qwen3-VL-Reranker-2B gguf
    reranker_mmproj_path: ?[]const u8 = null,   // path to reranker mmproj gguf
    rerank_top_k: u32 = 15,                     // number of bi-encoder results to rerank

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.data_path) |p| allocator.free(p);
        if (self.embedding_model_path) |p| allocator.free(p);
        if (self.embedding_mmproj_path) |p| allocator.free(p);
        if (self.reranker_model_path) |p| allocator.free(p);
        if (self.reranker_mmproj_path) |p| allocator.free(p);
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
    if (config.embedding_model_path) |p| config.embedding_model_path = try allocator.dupe(u8, p);
    if (config.embedding_mmproj_path) |p| config.embedding_mmproj_path = try allocator.dupe(u8, p);
    if (config.reranker_model_path) |p| config.reranker_model_path = try allocator.dupe(u8, p);
    if (config.reranker_mmproj_path) |p| config.reranker_mmproj_path = try allocator.dupe(u8, p);
    return config;
}

test "config: missing file returns defaults" {
    var cfg = try load(std.testing.allocator, std.testing.io, "/tmp/diffkeep_test_nonexistent_cfg.json");
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.data_path == null);
    try std.testing.expectEqual(false, cfg.fullscreen);
    try std.testing.expectEqual(@as(u32, 1200), cfg.window_width);
}

test "config: round-trip preserves all fields" {
    const tmp = "/tmp/diffkeep_test_roundtrip.json";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};

    const original = Config{
        .fullscreen = true,
        .window_width = 1920,
        .window_height = 1080,
        .thumbnails_in_db = true,
        .rerank_top_k = 7,
    };
    try save(original, std.testing.io, tmp);

    var loaded = try load(std.testing.allocator, std.testing.io, tmp);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(original.fullscreen, loaded.fullscreen);
    try std.testing.expectEqual(original.window_width, loaded.window_width);
    try std.testing.expectEqual(original.window_height, loaded.window_height);
    try std.testing.expectEqual(original.thumbnails_in_db, loaded.thumbnails_in_db);
    try std.testing.expectEqual(original.rerank_top_k, loaded.rerank_top_k);
}

test "config: unknown keys are ignored" {
    const tmp = "/tmp/diffkeep_test_unknown_keys.json";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = tmp,
        .data = "{\"fullscreen\":true,\"unknown_key_xyz\":42}",
    });
    var cfg = try load(std.testing.allocator, std.testing.io, tmp);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, cfg.fullscreen);
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
