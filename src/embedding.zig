const std = @import("std");
const llama = @import("llama.zig");
const build_options = @import("build_options");

pub fn createEmbedding(allocator: std.mem.Allocator, prompt: []const u8) ![]f32 {
    var pool = llama.Pool.init(allocator, .{});
    defer pool.deinit();

    var ctx = try pool.get("models/msmarco-distilbert-cos-v5.safetensors", 5000);
    defer pool.release(ctx);

    try ctx.prepare(prompt, .{});
    try ctx.eval();

    return ctx.getEmbedding(allocator);
}