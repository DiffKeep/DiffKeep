/// Evaluates semantic search quality for short queries against AI image prompts.
///
/// Usage: test_search_quality <model.gguf> [model2.gguf ...]
///
/// Runs all prefix modes for each model and prints a comparison table.
/// Per-query detail is shown for the best mode of each model.
///
/// Prefix modes tested:
///   none    - plain text on both sides (BGE-M3 native)
///   mxbai   - search_document: / search_query:  (mxbai-embed-large style)
///   qwen3   - Instruct:...Query: on queries, plain doc
///   qwen3d  - Instruct:...Query: on queries, search_document: on doc
const std = @import("std");
const llama = @import("llama.zig");
const corpus = @import("search_quality_corpus.zig");
const print = @import("util.zig").print;

const Query   = corpus.Query;
const PROMPTS = corpus.PROMPTS;
const QUERIES = corpus.QUERIES;

// ── prefix constants ────────────────────────────────────────────────────────

const DOC_PREFIX = "search_document: ";
const QUERY_PREFIX = "search_query: ";
const QWEN3_TASK = "Given a short keyword or phrase, retrieve AI image generation prompts that match the concept";
const QWEN3_QUERY_PREFIX = "Instruct: " ++ QWEN3_TASK ++ "\nQuery: ";

const PrefixMode = enum { none, mxbai, qwen3, qwen3d };
const ALL_MODES = [_]PrefixMode{ .none, .mxbai, .qwen3, .qwen3d };

fn modeName(m: PrefixMode) []const u8 {
    return switch (m) {
        .none   => "none  ",
        .mxbai  => "mxbai ",
        .qwen3  => "qwen3 ",
        .qwen3d => "qwen3d",
    };
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn dotProduct(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |av, bv| s += av * bv;
    return s;
}

fn reciprocalRank(ranking: []const usize, relevant: []const usize) f32 {
    for (ranking, 0..) |idx, rank| {
        for (relevant) |r| if (idx == r) return 1.0 / @as(f32, @floatFromInt(rank + 1));
    }
    return 0;
}

fn isInTopK(ranking: []const usize, k: usize, relevant: []const usize) bool {
    for (ranking[0..@min(k, ranking.len)]) |idx| {
        for (relevant) |r| if (idx == r) return true;
    }
    return false;
}

fn embed(allocator: std.mem.Allocator, ctx: *llama.Context, text: []const u8) ![]const f32 {
    var embs = try llama.createEmbeddingFromPrompt(allocator, ctx, text, 512);
    defer embs.deinit(allocator);
    const e = embs.items[0];
    embs.items.len = 0;
    return e;
}

fn docText(allocator: std.mem.Allocator, prompt: []const u8, mode: PrefixMode) ![]const u8 {
    return switch (mode) {
        .none, .qwen3 => allocator.dupe(u8, prompt),
        .mxbai, .qwen3d => std.fmt.allocPrint(allocator, DOC_PREFIX ++ "{s}", .{prompt}),
    };
}

fn queryText(allocator: std.mem.Allocator, q: []const u8, mode: PrefixMode) ![]const u8 {
    return switch (mode) {
        .none   => allocator.dupe(u8, q),
        .mxbai  => std.fmt.allocPrint(allocator, QUERY_PREFIX ++ "{s}", .{q}),
        .qwen3, .qwen3d => std.fmt.allocPrint(allocator, QWEN3_QUERY_PREFIX ++ "{s}", .{q}),
    };
}

// ── scoring ───────────────────────────────────────────────────────────────────

const ModeResult = struct {
    mrr: f32,
    top1: f32,
    top3: f32,
    top5: f32,
};

fn scoreMode(
    allocator: std.mem.Allocator,
    ctx: *llama.Context,
    mode: PrefixMode,
    io: std.Io,
    verbose: bool,
) !ModeResult {
    // Embed all prompts.
    var prompt_embs: [PROMPTS.len][]const f32 = undefined;
    for (PROMPTS, 0..) |p, i| {
        const t = try docText(allocator, p, mode);
        defer allocator.free(t);
        prompt_embs[i] = try embed(allocator, ctx, t);
    }
    defer for (prompt_embs) |e| allocator.free(e);

    var ranking: [PROMPTS.len]usize = undefined;
    var total_rr: f32 = 0;
    var top1: usize = 0;
    var top3: usize = 0;
    var top5: usize = 0;

    for (QUERIES) |query| {
        const qt = try queryText(allocator, query.text, mode);
        defer allocator.free(qt);
        const q_emb = try embed(allocator, ctx, qt);
        defer allocator.free(q_emb);

        var sims: [PROMPTS.len]f32 = undefined;
        for (0..PROMPTS.len) |i| {
            sims[i] = dotProduct(q_emb, prompt_embs[i]);
            ranking[i] = i;
        }
        // Insertion sort descending.
        for (1..PROMPTS.len) |i| {
            const key = ranking[i];
            var j = i;
            while (j > 0 and sims[ranking[j - 1]] < sims[key]) {
                ranking[j] = ranking[j - 1];
                j -= 1;
            }
            ranking[j] = key;
        }

        total_rr += reciprocalRank(&ranking, query.relevant);
        if (isInTopK(&ranking, 1, query.relevant)) top1 += 1;
        if (isInTopK(&ranking, 3, query.relevant)) top3 += 1;
        if (isInTopK(&ranking, 5, query.relevant)) top5 += 1;

        if (verbose) {
            try printQuery(io, query, &ranking, &sims);
        }
    }

    const n: f32 = @floatFromInt(QUERIES.len);
    return .{
        .mrr  = total_rr / n,
        .top1 = @as(f32, @floatFromInt(top1)) / n,
        .top3 = @as(f32, @floatFromInt(top3)) / n,
        .top5 = @as(f32, @floatFromInt(top5)) / n,
    };
}

fn printQuery(io: std.Io, query: Query, ranking: []const usize, sims: []const f32) !void {
    try print(io, "  Query: \"{s}\"\n", .{query.text});
    const show = @min(5, ranking.len);
    for (ranking[0..show], 0..) |idx, rank| {
        const is_rel = for (query.relevant) |r| { if (r == idx) break true; } else false;
        const marker: []const u8 = if (is_rel) "✓" else " ";
        const snip_len = @min(55, PROMPTS[idx].len);
        try print(io, "  {s} #{d} {d:.4}  [{d:02}] {s}...\n", .{
            marker, rank + 1, sims[idx], idx, PROMPTS[idx][0..snip_len],
        });
    }
    try print(io, "\n", .{});
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Collect model paths from args.
    var model_paths = std.ArrayList([]const u8).empty;
    defer model_paths.deinit(allocator);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        try model_paths.append(allocator, arg);
    }

    if (model_paths.items.len == 0) {
        std.log.err("usage: test_search_quality <model.gguf> [model2.gguf ...]", .{});
        return error.MissingArgument;
    }

    // Results[model_idx][mode_idx]
    const n_models = model_paths.items.len;
    const n_modes = ALL_MODES.len;
    var results = try allocator.alloc(ModeResult, n_models * n_modes);
    defer allocator.free(results);
    var model_names = try allocator.alloc([]const u8, n_models);
    defer allocator.free(model_names);

    for (model_paths.items, 0..) |model_path, mi| {
        // Extract basename for display.
        model_names[mi] = std.fs.path.stem(std.fs.path.basename(model_path));

        try print(io, "\n=== Model: {s} ===\n", .{model_names[mi]});

        var pool = llama.Pool.init(allocator, .{
            .embeddings   = true,
            .pooling_type = 1,
            .n_ctx        = 1024,
            .n_batch      = 512,
            .n_ubatch     = 512,
            .n_gpu_layers = 999,
        });
        defer pool.deinit();

        const ctx = try pool.get(io, model_path, 60_000, null);
        defer pool.release(ctx);

        for (ALL_MODES, 0..) |mode, moi| {
            try print(io, "  [{d}/{d}] mode={s}  embedding {d} prompts + {d} queries...\n", .{
                moi + 1, n_modes, modeName(mode), PROMPTS.len, QUERIES.len,
            });
            const r = try scoreMode(allocator, ctx, mode, io, false);
            results[mi * n_modes + moi] = r;
            try print(io, "         MRR={d:.3} @1={d:.0}% @3={d:.0}% @5={d:.0}%\n", .{
                r.mrr, r.top1 * 100, r.top3 * 100, r.top5 * 100,
            });
        }

        // Verbose output for best mode.
        const best_mode_idx = blk: {
            var best: usize = 0;
            for (1..n_modes) |moi| {
                if (results[mi * n_modes + moi].mrr > results[mi * n_modes + best].mrr)
                    best = moi;
            }
            break :blk best;
        };
        const best_mode = ALL_MODES[best_mode_idx];
        try print(io, "\n  Best mode: {s} — per-query detail:\n\n", .{modeName(best_mode)});

        // Re-run best mode with verbose=true to print ranked results.
        _ = try scoreMode(allocator, ctx, best_mode, io, true);
    }

    // ── comparison table ──────────────────────────────────────────────────────

    try print(io, "\n╔══ Comparison table ═══════════════════════════════════════════════════════╗\n", .{});
    try print(io, "║ {s:<32} {s:<8} {s:>6} {s:>6} {s:>6} {s:>6} ║\n", .{ "Model", "Mode", "MRR", "@1", "@3", "@5" });
    try print(io, "╠═══════════════════════════════════════════════════════════════════════════╣\n", .{});

    for (0..n_models) |mi| {
        for (ALL_MODES, 0..) |mode, moi| {
            const r = results[mi * n_modes + moi];
            try print(io, "║ {s:<32} {s:<8} {d:>5.3} {d:>5.0}% {d:>5.0}% {d:>5.0}% ║\n", .{
                model_names[mi][0..@min(32, model_names[mi].len)],
                modeName(mode),
                r.mrr, r.top1 * 100, r.top3 * 100, r.top5 * 100,
            });
        }
        if (mi + 1 < n_models)
            try print(io, "╠═══════════════════════════════════════════════════════════════════════════╣\n", .{});
    }
    try print(io, "╚═══════════════════════════════════════════════════════════════════════════╝\n", .{});
}
