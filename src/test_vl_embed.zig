/// Smoke-test for Qwen3-VL-Embedding image embedding.
///
/// Usage:
///   test_vl_embed [--max-size N] <model.gguf> <mmproj.gguf> <image1.png> [image2.png ...]
///
/// --max-size N   Resize longest edge to N pixels before encoding (default: 448, 0 = no resize).
///
/// Prints the first 8 embedding values for each image plus the cosine
/// similarity between consecutive pairs so you can check that different
/// images produce different embeddings and visually similar images score
/// higher than dissimilar ones.
const std = @import("std");
const mtmd = @import("mtmd.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // exe name

    var max_size: u32 = 448;

    // Parse optional --max-size flag.
    const model_path = blk: {
        while (true) {
            const arg = args.next() orelse return printUsageErr(io);
            if (std.mem.eql(u8, arg, "--max-size")) {
                const val = args.next() orelse return printUsageErr(io);
                max_size = std.fmt.parseInt(u32, val, 10) catch {
                    try println(io, "error: --max-size must be a non-negative integer", .{});
                    return error.BadArgument;
                };
            } else {
                break :blk arg;
            }
        }
    };

    const mmproj_path = args.next() orelse return printUsageErr(io);

    var image_paths = std.ArrayList([]const u8).empty;
    defer image_paths.deinit(allocator);
    while (args.next()) |p| try image_paths.append(allocator, p);
    if (image_paths.items.len == 0) return printUsageErr(io);

    try println(io, "Loading model: {s}", .{model_path});
    try println(io, "Loading mmproj: {s}", .{mmproj_path});
    if (max_size > 0) {
        try println(io, "Max image size: {d}px (longest edge)", .{max_size});
    } else {
        try println(io, "Max image size: none (no resize)", .{});
    }

    var vl = try mtmd.VlContext.init(allocator, model_path, mmproj_path);
    defer vl.deinit();
    vl.max_image_size = max_size;

    const n_embd: usize = @intCast(mtmd.c.llama_model_n_embd(vl.pool.model.?.ptr));
    try println(io, "Embedding dim: {d}\n", .{n_embd});

    var embeddings = std.ArrayList([]f32).empty;
    defer {
        for (embeddings.items) |e| allocator.free(e);
        embeddings.deinit(allocator);
    }

    for (image_paths.items) |path| {
        try println(io, "Embedding: {s}", .{path});
        const embd = try vl.embedImageFile(allocator, path, "");
        try embeddings.append(allocator, embd);

        // Print first 8 values as a sanity check.
        try print(io, "  [", .{});
        for (embd[0..@min(8, embd.len)], 0..) |v, i| {
            if (i > 0) try print(io, ", ", .{});
            try print(io, "{d:.4}", .{v});
        }
        try println(io, " ...]", .{});
    }

    // Print pairwise cosine similarities.
    if (embeddings.items.len >= 2) {
        try println(io, "\nPairwise cosine similarities:", .{});
        for (0..embeddings.items.len) |i| {
            for (i + 1..embeddings.items.len) |j| {
                const sim = dot(embeddings.items[i], embeddings.items[j]);
                const short_i = shortName(image_paths.items[i]);
                const short_j = shortName(image_paths.items[j]);
                try println(io, "  {s} × {s}  →  {d:.4}", .{ short_i, short_j, sim });
            }
        }
    }
}

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |av, bv| s += av * bv;
    return s;
}

fn shortName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1..];
    return path;
}

fn printUsageErr(io: std.Io) !void {
    try println(io, "usage: test_vl_embed [--max-size N] <model.gguf> <mmproj.gguf> <image.png> [...]", .{});
    return error.MissingArgument;
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

fn println(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    try print(io, fmt ++ "\n", args);
}
