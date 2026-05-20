const std = @import("std");
const llama = @import("llama.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const model_path = args.next() orelse {
        std.log.err("usage: test_embed <model.gguf> [\"text to embed\"]", .{});
        return error.MissingArgument;
    };
    const text = args.next() orelse "A photo of a dog playing in the park.";

    std.log.info("Model: {s}", .{model_path});
    std.log.info("Text:  {s}", .{text});

    var pool = llama.Pool.init(allocator, .{
        .embeddings    = true,
        .pooling_type  = 1, // mean pooling
        .n_ctx         = 512,
        .n_batch       = 512,
        .n_ubatch      = 512,
        .n_gpu_layers  = 999,
    });
    defer pool.deinit();

    const ctx = try pool.get(init.io, model_path, 30_000, null);
    defer pool.release(ctx);

    var embeddings = try llama.createEmbeddingFromPrompt(allocator, ctx, text, 512);
    defer {
        for (embeddings.items) |e| allocator.free(e);
        embeddings.deinit(allocator);
    }

    for (embeddings.items, 0..) |emb, chunk_idx| {
        std.log.info("Chunk {d}: {d} dims, first 8 values:", .{ chunk_idx, emb.len });
        const n = @min(8, emb.len);
        for (emb[0..n]) |v| {
            std.log.info("  {d:.6}", .{v});
        }

        // Verify L2 norm ≈ 1.0 (already normalized in createEmbeddingFromPrompt)
        var norm: f32 = 0;
        for (emb) |v| norm += v * v;
        std.log.info("  L2 norm: {d:.6}", .{@sqrt(norm)});
    }
}
