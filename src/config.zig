const std = @import("std");
const log = std.log.scoped(.config);

/// Remembered SDL window geometry (size, position, maximized, fullscreen).
/// Lives here so config stays free of any SDL dependency; window_state.zig
/// aliases this type for its capture/apply helpers.
pub const WindowState = struct {
    fullscreen: bool = false,
    maximized: bool = false,
    width: u32 = 1200,
    height: u32 = 800,
    x: ?i32 = null,
    y: ?i32 = null,
};

/// Which GPU backend the embedder prefers for batched work. Per-call routing
/// falls back to CPU for small batches (below `embed_gpu_threshold`) and entirely
/// when the device/driver is unavailable at init (see embedder.zig).
pub const GpuBackend = enum { none, vulkan, cuda };

pub const Config = struct {
    /// Override for the database FILE path (its directory becomes the data dir,
    /// holding trash/ and models/). Falls back to <XDG data dir>/DiffKeep/diffkeep.db.
    data_path: ?[]const u8 = null,

    // Remembered window geometry, persisted across sessions.
    main_window: WindowState = .{},
    /// Zero-based index of the display to open the window on.
    screen: u32 = 0,
    viewer_window: WindowState = .{},
    viewer_info_open: bool = false,
    viewer_info_w: f32 = 280,

    // Remembered main-grid layout, persisted across sessions.
    grid_thumb_fraction: f32 = 0.25, // 0..1 maps to min..max thumbnail size
    grid_autoplay: bool = false,      // live-play animated/video cells in the grid (muted)
    grid_left_w: f32 = 240,           // current tree-pane width (< 2 = collapsed)
    grid_left_w_open: f32 = 240,      // last non-collapsed tree-pane width
    grid_right_w: f32 = 300,          // current info-pane width (< 2 = collapsed)
    grid_right_w_open: f32 = 300,     // last non-collapsed info-pane width

    thumbnails_in_db: bool = false,
    prompt_embeddings: bool = false,
    image_embeddings: bool = false,
    trash_enabled: bool = true,
    text_model_dir: ?[]const u8 = null,    // path to embeddinggemma-300m dir
    visual_model_dir: ?[]const u8 = null,  // path to ViT-B-16-SigLIP2 timm dir (open_clip safetensors)
    // Minimum cosine similarity for vector search hits; anything below is
    // dropped instead of padding the grid with the irrelevant KNN tail.
    semantic_min_similarity: f32 = 0.25,
    visual_min_similarity: f32 = 0.03,
    // Embedding compute backend for batched work, and the batch size at/above
    // which a call uses the GPU.
    embed_gpu_backend: GpuBackend = .cuda,
    embed_gpu_threshold: usize = 4,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.data_path) |p| allocator.free(p);
        if (self.text_model_dir) |p| allocator.free(p);
        if (self.visual_model_dir) |p| allocator.free(p);
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
    if (config.text_model_dir) |p| config.text_model_dir = try allocator.dupe(u8, p);
    if (config.visual_model_dir) |p| config.visual_model_dir = try allocator.dupe(u8, p);
    return config;
}

test "config: missing file returns defaults" {
    var cfg = try load(std.testing.allocator, std.testing.io, "/tmp/diffkeep_test_nonexistent_cfg.json");
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.data_path == null);
    try std.testing.expectEqual(false, cfg.main_window.fullscreen);
    try std.testing.expectEqual(@as(u32, 1200), cfg.main_window.width);
}

test "config: round-trip preserves all fields" {
    const tmp = "/tmp/diffkeep_test_roundtrip.json";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};

    const original = Config{
        .main_window = .{
            .fullscreen = true,
            .maximized = true,
            .width = 1920,
            .height = 1080,
            .x = -7,
            .y = 42,
        },
        .viewer_window = .{
            .fullscreen = true,
            .maximized = true,
            .width = 1600,
            .height = 900,
            .x = 100,
            .y = 50,
        },
        .viewer_info_open = true,
        .viewer_info_w = 333,
        .grid_thumb_fraction = 0.6,
        .grid_autoplay = true,
        .grid_left_w = 200,
        .grid_left_w_open = 260,
        .grid_right_w = 0,
        .grid_right_w_open = 360,
        .thumbnails_in_db = true,
    };
    try save(original, std.testing.io, tmp);

    var loaded = try load(std.testing.allocator, std.testing.io, tmp);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(original.main_window, loaded.main_window);
    try std.testing.expectEqual(original.viewer_window, loaded.viewer_window);
    try std.testing.expectEqual(original.viewer_info_open, loaded.viewer_info_open);
    try std.testing.expectEqual(original.viewer_info_w, loaded.viewer_info_w);
    try std.testing.expectEqual(original.grid_thumb_fraction, loaded.grid_thumb_fraction);
    try std.testing.expectEqual(original.grid_autoplay, loaded.grid_autoplay);
    try std.testing.expectEqual(original.grid_left_w, loaded.grid_left_w);
    try std.testing.expectEqual(original.grid_left_w_open, loaded.grid_left_w_open);
    try std.testing.expectEqual(original.grid_right_w, loaded.grid_right_w);
    try std.testing.expectEqual(original.grid_right_w_open, loaded.grid_right_w_open);
    try std.testing.expectEqual(original.thumbnails_in_db, loaded.thumbnails_in_db);
}

test "config: unknown keys are ignored" {
    const tmp = "/tmp/diffkeep_test_unknown_keys.json";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = tmp,
        .data = "{\"main_window\":{\"fullscreen\":true},\"unknown_key_xyz\":42}",
    });
    var cfg = try load(std.testing.allocator, std.testing.io, tmp);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, cfg.main_window.fullscreen);
}

/// Writes the config to `path`, creating parent directories as needed.
pub fn save(config: Config, io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |dir| {
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
