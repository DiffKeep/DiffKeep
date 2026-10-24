/// Cross-modal search test: text query → image retrieval, with optional reranking.
///
/// Usage: test_cross_modal_search <images_dir> <vl_model.gguf> <mmproj.gguf>
///          [--max-size N]
///          [--reranker <reranker.gguf> --reranker-mmproj <mmproj.gguf>]
///          [--rerank-k N]   (candidates to rerank per query, default 15)
const std = @import("std");
const png = @import("image/png-data.zig");
const PngParser = png.PngParser;
const Chunk = png.Chunk;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const ParseResult = @import("parse/comfy.zig").ParseResult;
const llama = @import("llama.zig");
const mtmd = @import("mtmd.zig");

// Prefix applied to all text queries. Confirmed best for Qwen3-VL-Embedding-2B.
const QUERY_PREFIX = "search_query: ";

// Instruction passed to the reranker cross-encoder.
const RERANK_INSTRUCTION = "Retrieve AI-generated images that visually match the user's search query.";

// ── Hand-written queries ──────────────────────────────────────────────────────
// `text`     — short natural-language search query
// `relevant` — basenames of images that should match
const Query = struct {
    text:     []const u8,
    relevant: []const []const u8,
};

const QUERIES = [_]Query{
    .{ .text = "sword", .relevant = &.{"05.11.57-80085_00001_.png"} },
    .{ .text = "cloak", .relevant = &.{"05.11.57-80085_00001_.png", "18.30.39-80085_00001_.png"} },
    .{ .text = "unicorn", .relevant = &.{"12.04.07-80085_00001_.png"} },
    .{ .text = "apple", .relevant = &.{"17.57.54-80085_00001_.png"} },
    .{ .text = "bird", .relevant = &.{"18.04.11-80085_00001_.png"} },
    .{ .text = "cat", .relevant = &.{"18.17.12-80085_00001_.png"} },
    .{ .text = "beware", .relevant = &.{"18.17.12-80085_00001_.png"} },
    .{ .text = "wing", .relevant = &.{"21.20.13-80085_00001_.png"} },
    .{ .text = "butterfly", .relevant = &.{"21.20.13-80085_00001_.png"} },
    .{ .text = "monarch", .relevant = &.{"21.20.13-80085_00001_.png"} },
    .{ .text = "nectar", .relevant = &.{"21.20.13-80085_00001_.png"} },
    .{ .text = "cold", .relevant = &.{"21.01.42-80085_00001_.png"} },
    .{ .text = "ramen", .relevant = &.{"18.12.42-80085_00001_.png"} },
    .{ .text = "fantasy", .relevant = &.{"05.11.57-80085_00001_.png", "12.04.07-80085_00001_.png"} },
    .{ .text = "flower", .relevant = &.{"21.20.13-80085_00001_.png", "12.04.07-80085_00001_.png", "18.04.39-80085_00001_.png"} },
    .{ .text = "dock", .relevant = &.{"18.11.21-80085_00001_.png", "18.36.29-80085_00001_.png"} },
    .{ .text = "pier", .relevant = &.{"18.11.21-80085_00001_.png", "18.36.29-80085_00001_.png"} },
    .{ .text = "system error 404", .relevant = &.{"18.05.07-80085_00001_.png"} },
    .{ .text = "japan", .relevant = &.{"18.30.13-80085_00001_.png", "18.12.42-80085_00001_.png"} },
    .{ .text = "water", .relevant = &.{"18.11.21-80085_00001_.png", "18.32.27-80085_00001_.png", "18.36.29-80085_00001_.png", "20.56.20-80085_00001_.png"} },
};

const ImageEntry = struct {
    path:   []const u8, // owned
    prompt: []const u8, // owned

    fn deinit(self: ImageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prompt);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const dir_arg    = args.next() orelse return usage();
    const model_arg  = args.next() orelse return usage();
    const mmproj_arg = args.next() orelse return usage();

    var max_image_size: u32 = 448;
    var reranker_arg:       ?[]const u8 = null;
    var reranker_mmproj:    ?[]const u8 = null;
    var rerank_k: usize = 15;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--max-size")) {
            const val = args.next() orelse return argErr("--max-size requires a value");
            max_image_size = std.fmt.parseInt(u32, val, 10) catch return argErr("--max-size: invalid integer");
        } else if (std.mem.eql(u8, arg, "--reranker")) {
            reranker_arg = args.next() orelse return argErr("--reranker requires a path");
        } else if (std.mem.eql(u8, arg, "--reranker-mmproj")) {
            reranker_mmproj = args.next() orelse return argErr("--reranker-mmproj requires a path");
        } else if (std.mem.eql(u8, arg, "--rerank-k")) {
            const val = args.next() orelse return argErr("--rerank-k requires a value");
            rerank_k = std.fmt.parseInt(usize, val, 10) catch return argErr("--rerank-k: invalid integer");
        }
    }

    // ── Parse all PNGs ────────────────────────────────────────────────
    var entries: std.ArrayList(ImageEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, dir_arg, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".png")) continue;
        const full = try std.Io.Dir.path.join(allocator, &.{ dir_arg, entry.name });
        const prompt = extractPrompt(allocator, io, full) catch |err| {
            std.log.warn("skip {s}: {}", .{ entry.name, err });
            allocator.free(full);
            continue;
        };
        if (prompt) |p| {
            try entries.append(allocator, .{ .path = full, .prompt = p });
        } else {
            std.log.warn("skip {s}: no prompt", .{entry.name});
            allocator.free(full);
        }
    }
    std.log.info("Parsed {d} images with prompts", .{entries.items.len});
    const corpus = entries.items;

    // ── Init embedding models ─────────────────────────────────────────
    var vl = try mtmd.VlContext.init(io, allocator, model_arg, mmproj_arg);
    defer vl.deinit();
    vl.max_image_size = max_image_size;
    std.log.info("Image max size: {d}px", .{max_image_size});

    var text_pool = llama.Pool.init(allocator, .{
        .embeddings   = true,
        .pooling_type = 1,
        .n_ctx        = 4096,
        .n_batch      = 512,
        .n_ubatch     = 512,
        .n_gpu_layers = 999,
    });
    defer text_pool.deinit();
    const text_ctx = try text_pool.get(io, model_arg, 30_000, null);
    defer text_pool.release(text_ctx);

    // ── Optionally init reranker ──────────────────────────────────────
    var reranker: ?mtmd.RerankContext = null;
    defer if (reranker) |*r| r.deinit();
    if (reranker_arg) |rpath| {
        const rmmproj = reranker_mmproj orelse return argErr("--reranker requires --reranker-mmproj");
        std.log.info("Loading reranker: {s}", .{rpath});
        var r = try mtmd.RerankContext.init(io, allocator, rpath, rmmproj);
        r.max_image_size = max_image_size;
        reranker = r;
        std.log.info("Reranker loaded. Reranking top-{d} per query.", .{rerank_k});
    }

    // ── Embed all images ──────────────────────────────────────────────
    std.log.info("Embedding {d} images...", .{corpus.len});
    var img_embds = try allocator.alloc([]f32, corpus.len);
    defer {
        for (img_embds) |e| allocator.free(e);
        allocator.free(img_embds);
    }
    for (corpus, 0..) |e, i| {
        img_embds[i] = try vl.embedImageFile(io, allocator, e.path, "", null);
    }
    std.log.info("Done embedding. Running queries...", .{});

    // ── Evaluate each query ───────────────────────────────────────────
    var ranking = try allocator.alloc(usize, corpus.len);
    defer allocator.free(ranking);
    var sims = try allocator.alloc(f32, corpus.len);
    defer allocator.free(sims);

    var total_rr: f32 = 0;
    var top1: usize = 0;
    var top3: usize = 0;
    var top5: usize = 0;

    // Reranker accumulators (only used when --reranker is set).
    var rr_total_rr: f32 = 0;
    var rr_top1: usize = 0;
    var rr_top3: usize = 0;
    var rr_top5: usize = 0;

    for (QUERIES) |q| {
        // Embed query text with search_query prefix.
        const qt = try allocator.print(QUERY_PREFIX ++ "{s}", .{q.text});
        defer allocator.free(qt);
        var chunks = try llama.createEmbeddingFromPrompt(allocator, text_ctx, qt, 2048);
        const q_emb: []const f32 = blk: {
            const e = chunks.items[0];
            chunks.items.len = 0;
            chunks.deinit(allocator);
            break :blk e;
        };
        defer allocator.free(@constCast(q_emb));

        // Score and rank all images by cosine similarity.
        for (0..corpus.len) |i| {
            ranking[i] = i;
            sims[i] = dot(q_emb, img_embds[i]);
        }
        insertionSortDesc(ranking, sims);

        // Find best rank among relevant images (bi-encoder).
        const best_rank = bestRank(corpus, ranking, q.relevant);

        total_rr += 1.0 / @as(f32, @floatFromInt(best_rank));
        if (best_rank <= 1) top1 += 1;
        if (best_rank <= 3) top3 += 1;
        if (best_rank <= 5) top5 += 1;

        // Print per-query result (bi-encoder).
        try print(io, "\n{s} \"{s}\"  (best: #{d})\n", .{
            if (best_rank <= 5) "✓" else "✗", q.text, best_rank,
        });
        for (ranking[0..@min(5, corpus.len)], 0..) |idx, r| {
            const name = std.Io.Dir.path.basename(corpus[idx].path);
            const is_rel = isRelevant(name, q.relevant);
            const snip = corpus[idx].prompt[0..@min(60, corpus[idx].prompt.len)];
            try print(io, "  {s} #{d} {d:.4}  {s}  {s}...\n", .{
                if (is_rel) "→" else " ", r + 1, sims[idx], name, snip,
            });
        }

        // ── Reranking phase ───────────────────────────────────────────
        if (reranker) |*rr| {
            const k = @min(rerank_k, corpus.len);
            var rr_scores = try allocator.alloc(f32, k);
            defer allocator.free(rr_scores);
            var rr_ranking = try allocator.alloc(usize, k);
            defer allocator.free(rr_ranking);

            for (0..k) |i| {
                rr_ranking[i] = i; // index into top-k, not corpus
                rr_scores[i] = rr.scoreImageFile(
                    io, allocator, q.text, RERANK_INSTRUCTION, corpus[ranking[i]].path,
                ) catch |err| blk: {
                    std.log.warn("rerank failed for {s}: {}", .{ corpus[ranking[i]].path, err });
                    break :blk -std.math.floatMax(f32);
                };
            }
            insertionSortDesc(rr_ranking, rr_scores);

            // Map reranked positions back to corpus indices.
            var rr_corpus_ranking = try allocator.alloc(usize, k);
            defer allocator.free(rr_corpus_ranking);
            for (0..k) |i| rr_corpus_ranking[i] = ranking[rr_ranking[i]];

            const rr_best = bestRank(corpus, rr_corpus_ranking, q.relevant);
            rr_total_rr += 1.0 / @as(f32, @floatFromInt(rr_best));
            if (rr_best <= 1) rr_top1 += 1;
            if (rr_best <= 3) rr_top3 += 1;
            if (rr_best <= 5) rr_top5 += 1;

            try print(io, "  ↳ reranked: {s} (best: #{d})\n", .{
                if (rr_best <= 5) "✓" else "✗", rr_best,
            });
            for (rr_corpus_ranking[0..@min(5, k)], 0..) |idx, r| {
                const name = std.Io.Dir.path.basename(corpus[idx].path);
                const is_rel = isRelevant(name, q.relevant);
                try print(io, "      {s} #{d} {d:.4}  {s}\n", .{
                    if (is_rel) "→" else " ", r + 1, rr_scores[rr_ranking[r]], name,
                });
            }
        }
    }

    // ── Summary ───────────────────────────────────────────────────────
    const n: f32 = @floatFromInt(QUERIES.len);
    try print(io, "\n── Bi-encoder ──────────────────────────────────────────────────\n", .{});
    try print(io, "  MRR={d:.3}  @1={d:.0}%  @3={d:.0}%  @5={d:.0}%\n", .{
        total_rr / n,
        @as(f32, @floatFromInt(top1)) / n * 100,
        @as(f32, @floatFromInt(top3)) / n * 100,
        @as(f32, @floatFromInt(top5)) / n * 100,
    });
    if (reranker != null) {
        try print(io, "── Reranker (top-{d}) ──────────────────────────────────────────\n", .{rerank_k});
        try print(io, "  MRR={d:.3}  @1={d:.0}%  @3={d:.0}%  @5={d:.0}%\n", .{
            rr_total_rr / n,
            @as(f32, @floatFromInt(rr_top1)) / n * 100,
            @as(f32, @floatFromInt(rr_top3)) / n * 100,
            @as(f32, @floatFromInt(rr_top5)) / n * 100,
        });
    }
}

fn dot(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    var s: f32 = 0;
    for (a[0..len], b[0..len]) |av, bv| s += av * bv;
    return s;
}

fn insertionSortDesc(ranking: []usize, scores: []f32) void {
    for (1..ranking.len) |i| {
        const key = ranking[i];
        var j = i;
        while (j > 0 and scores[ranking[j - 1]] < scores[key]) {
            ranking[j] = ranking[j - 1];
            j -= 1;
        }
        ranking[j] = key;
    }
}

fn bestRank(corpus: []const ImageEntry, ranking: []const usize, relevant: []const []const u8) usize {
    var best: usize = corpus.len + 1;
    for (relevant) |rel| {
        for (ranking, 0..) |idx, r| {
            if (std.mem.eql(u8, std.Io.Dir.path.basename(corpus[idx].path), rel)) {
                if (r + 1 < best) best = r + 1;
                break;
            }
        }
    }
    return best;
}

fn isRelevant(name: []const u8, relevant: []const []const u8) bool {
    for (relevant) |rel| {
        if (std.mem.eql(u8, name, rel)) return true;
    }
    return false;
}

fn extractPrompt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parser = try PngParser.init(a, io);
    defer parser.deinit();

    const file_size = try file.length(io);
    const buffer = try a.alloc(u8, file_size);
    _ = try file.readPositionalAll(io, buffer, 0);
    try parser.parseBuffer(buffer);

    var a1111_text: ?[]const u8 = null;
    {
        const chunks = parser.getITxtChunks() catch &[_]Chunk{};
        defer a.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(a);
            if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed and a1111_text == null)
                a1111_text = a.dupe(u8, content.text) catch null;
        }
    }
    var workflow_text: ?[]const u8 = null;
    var prompt_text: ?[]const u8   = null;
    {
        const chunks = try parser.getTExtChunks();
        defer a.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseTExtChunk(chunk) catch continue;
            defer content.deinit(a);
            if (std.mem.eql(u8, content.keyword, "workflow")) {
                if (workflow_text == null) workflow_text = a.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "prompt")) {
                if (prompt_text == null) prompt_text = a.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "parameters")) {
                if (a1111_text == null) a1111_text = a.dupe(u8, content.text) catch null;
            }
        }
    }

    var comfy = ComfyParser.init(a);
    var result: ?ParseResult = null;
    if (a1111_text) |t| result = comfy.parseA1111Parameters(t) catch null;
    if (result == null) if (workflow_text) |t| { result = comfy.parseWorkflow(t) catch null; };
    if (result == null) if (prompt_text) |t| { result = comfy.parsePromptChunk(t) catch null; };

    var pr = result orelse return null;
    defer pr.deinit(a);

    const prompt = pr.positive_prompt orelse return null;
    return try allocator.dupe(u8, prompt);
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.mem.print(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

fn argErr(msg: []const u8) error{InvalidArgument} {
    std.log.err("{s}", .{msg});
    return error.InvalidArgument;
}

fn usage() error{MissingArgument} {
    std.log.err(
        "usage: test_cross_modal_search <images_dir> <vl_model.gguf> <mmproj.gguf>" ++
        " [--max-size N] [--reranker <path> --reranker-mmproj <path>] [--rerank-k N]",
        .{},
    );
    return error.MissingArgument;
}
