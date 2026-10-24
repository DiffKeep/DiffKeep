/// Text retrieval quality + speed test for llama.cpp embedding models.
///
/// Usage:
///   test_text_search <images_dir> <model.gguf> [options]
///
/// Options:
///   --n-gpu-layers N   layers to offload (default: 0)
///   --ctx N            context size (default: 2048)
///   --top-k N          results to show per query (default: 5)
///   --verbose          print per-query result details
///
/// The test runs four prefix configurations back-to-back and reports
/// MRR/@1/@3/@5 for each, so one invocation compares all strategies.
///
/// NOTE on the test corpus:
///   32 images, but only 5 have unique prompts (graveyard, dock, sequoia,
///   denim jacket, sword/cloak image). The remaining 27 share an identical
///   "maiden of unicorns" template. Queries are designed to target the 5
///   unique images with both exact-match and semantic queries so we can
///   see whether dense embeddings beat an FTS5 keyword approach.
const std = @import("std");
const png = @import("image/png-data.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const ParseResult = @import("parse/comfy.zig").ParseResult;
const llama = @import("llama.zig");

// ── Prefix configurations to compare ─────────────────────────────────────────
//
// Each config is run on the same corpus; results appear side-by-side in the
// summary.  query_prefix is prepended to every query string; doc_prefix is
// prepended to every document string before embedding.

const PrefixConfig = struct {
    name:         []const u8,
    query_prefix: []const u8,
    doc_prefix:   []const u8,
};

const PREFIX_CONFIGS = [_]PrefixConfig{
    .{ .name = "bare",       .query_prefix = "",                    .doc_prefix = "" },
    .{ .name = "nomic",      .query_prefix = "search_query: ",      .doc_prefix = "search_document: " },
    .{ .name = "e5",         .query_prefix = "query: ",             .doc_prefix = "passage: " },
    .{ .name = "query-only", .query_prefix = "search_query: ",      .doc_prefix = "" },
};

// ── Test queries ──────────────────────────────────────────────────────────────
//
// Two tiers:
//   exact  — the query term appears verbatim in the target document's prompt
//   semantic — the term is a synonym / related concept; good dense models
//              should still rank the right document first

const Query = struct {
    text:     []const u8,
    relevant: []const []const u8,
    tier:     enum { exact, semantic },
};

const QUERIES = [_]Query{
    // ── Exact-match (FTS5 would also get these) ───────────────────────
    .{ .text = "sword",        .relevant = &.{"05.11.57-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "cloak",        .relevant = &.{"05.11.57-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "runic",        .relevant = &.{"05.11.57-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "graveyard",    .relevant = &.{"18.10.26-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "overcoat",     .relevant = &.{"18.10.26-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "dock",         .relevant = &.{"18.11.21-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "auburn hair",  .relevant = &.{"18.11.21-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "sequoia",      .relevant = &.{"18.13.34-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "denim jacket", .relevant = &.{"18.03.17-80085_00001_.png"},                                          .tier = .exact },
    .{ .text = "freckles",     .relevant = &.{"18.11.21-80085_00001_.png"},                                          .tier = .exact },

    // ── Semantic / synonym (only dense embeddings should get these) ───
    .{ .text = "pier",         .relevant = &.{"18.11.21-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "cemetery",     .relevant = &.{"18.10.26-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "redwood tree", .relevant = &.{"18.13.34-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "weapon",       .relevant = &.{"05.11.57-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "jacket",       .relevant = &.{"18.03.17-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "tombstone",    .relevant = &.{"18.10.26-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "waterfront",   .relevant = &.{"18.11.21-80085_00001_.png"},                                          .tier = .semantic },
    .{ .text = "giant tree",   .relevant = &.{"18.13.34-80085_00001_.png"},                                          .tier = .semantic },
};

// ── ImageEntry ────────────────────────────────────────────────────────────────

const ImageEntry = struct {
    path:   []const u8, // owned
    prompt: []const u8, // owned

    fn deinit(self: ImageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prompt);
    }
};

// ── Metrics accumulator ───────────────────────────────────────────────────────

const Metrics = struct {
    mrr:  f32 = 0,
    top1: usize = 0,
    top3: usize = 0,
    top5: usize = 0,

    // Separate exact vs semantic
    exact_mrr:    f32 = 0,
    exact_top1:   usize = 0,
    exact_count:  usize = 0,
    sem_mrr:      f32 = 0,
    sem_top1:     usize = 0,
    sem_count:    usize = 0,

    fn add(self: *Metrics, rank: usize, tier: @TypeOf(QUERIES[0].tier)) void {
        const rr = 1.0 / @as(f32, @floatFromInt(rank));
        self.mrr += rr;
        if (rank <= 1) self.top1 += 1;
        if (rank <= 3) self.top3 += 1;
        if (rank <= 5) self.top5 += 1;
        if (tier == .exact) {
            self.exact_mrr += rr;
            if (rank <= 1) self.exact_top1 += 1;
            self.exact_count += 1;
        } else {
            self.sem_mrr += rr;
            if (rank <= 1) self.sem_top1 += 1;
            self.sem_count += 1;
        }
    }
};

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const images_dir = args.next() orelse return usage();
    const model_path  = args.next() orelse return usage();

    var n_gpu_layers: u32 = 0;
    var ctx_size: u32 = 2048;
    var top_k: usize = 5;
    var verbose = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--n-gpu-layers")) {
            const v = args.next() orelse return argErr("--n-gpu-layers requires a value");
            n_gpu_layers = std.fmt.parseInt(u32, v, 10) catch return argErr("--n-gpu-layers: invalid integer");
        } else if (std.mem.eql(u8, arg, "--ctx")) {
            const v = args.next() orelse return argErr("--ctx requires a value");
            ctx_size = std.fmt.parseInt(u32, v, 10) catch return argErr("--ctx: invalid integer");
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            const v = args.next() orelse return argErr("--top-k requires a value");
            top_k = std.fmt.parseInt(usize, v, 10) catch return argErr("--top-k: invalid integer");
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    // ── Scan images ───────────────────────────────────────────────────
    var entries: std.ArrayList(ImageEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    {
        var dir = try std.Io.Dir.cwd().openDir(io, images_dir, .{ .iterate = true });
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |de| {
            if (de.kind != .file or !std.mem.endsWith(u8, de.name, ".png")) continue;
            const full = try std.Io.Dir.path.join(allocator, &.{ images_dir, de.name });
            errdefer allocator.free(full);
            const prompt = extractPrompt(allocator, io, full) catch |err| {
                std.log.warn("skip {s}: {}", .{ de.name, err });
                allocator.free(full);
                continue;
            };
            if (prompt == null) {
                std.log.warn("skip {s}: no prompt", .{de.name});
                allocator.free(full);
                continue;
            }
            try entries.append(allocator, .{ .path = full, .prompt = prompt.? });
        }
    }

    if (entries.items.len == 0) {
        try println(io, "No images with prompts found in {s}", .{images_dir});
        return;
    }
    try println(io, "Found {d} images with prompts.", .{entries.items.len});

    // ── Init model ────────────────────────────────────────────────────
    var pool = llama.Pool.init(allocator, .{
        .embeddings   = true,
        .pooling_type = 1,
        .n_ctx        = ctx_size,
        .n_batch      = @min(ctx_size, 512),
        .n_ubatch     = @min(ctx_size, 512),
        .n_gpu_layers = n_gpu_layers,
    });
    defer pool.deinit();
    const ctx = try pool.get(io, model_path, 60_000, null);
    defer pool.release(ctx);

    try println(io, "Model loaded. Context size: {d}", .{ctx_size});

    // ── Per-config evaluation ─────────────────────────────────────────
    const corpus = entries.items;

    var ranking  = try allocator.alloc(usize, corpus.len);
    defer allocator.free(ranking);
    var scores   = try allocator.alloc(f32, corpus.len);
    defer allocator.free(scores);

    var all_metrics: [PREFIX_CONFIGS.len]Metrics = @splat(.{});

    for (PREFIX_CONFIGS, 0..) |cfg, cfg_idx| {
        try println(io, "\n── Config: {s} ─────────────────────────────────────────────", .{cfg.name});

        // Embed all documents
        const t0_docs = nanoNow();
        var doc_embs = try allocator.alloc([]const f32, corpus.len);
        defer {
            for (doc_embs) |e| allocator.free(@constCast(e));
            allocator.free(doc_embs);
        }
        for (corpus, 0..) |entry, i| {
            const text = if (cfg.doc_prefix.len > 0)
                try allocator.print("{s}{s}", .{ cfg.doc_prefix, entry.prompt })
            else
                entry.prompt;
            defer if (cfg.doc_prefix.len > 0) allocator.free(text);

            var chunks = try llama.createEmbeddingFromPrompt(allocator, ctx, text, ctx_size);
            defer chunks.deinit(allocator);
            // Use the first chunk for documents (prompt embeddings are already full-context)
            doc_embs[i] = chunks.items[0];
            chunks.items.len = 0;
        }
        const doc_ms = @as(f64, @floatFromInt(nanoNow() - t0_docs)) / 1e6;
        try println(io, "  {d} doc embeddings in {d:.0}ms  ({d:.1}ms avg)",
            .{ corpus.len, doc_ms, doc_ms / @as(f64, @floatFromInt(corpus.len)) });

        // Run each query
        for (QUERIES) |q| {
            const t0_q = nanoNow();
            const qtext = if (cfg.query_prefix.len > 0)
                try allocator.print("{s}{s}", .{ cfg.query_prefix, q.text })
            else
                q.text;
            defer if (cfg.query_prefix.len > 0) allocator.free(qtext);

            var qchunks = try llama.createEmbeddingFromPrompt(allocator, ctx, qtext, ctx_size);
            defer qchunks.deinit(allocator);
            const q_emb = qchunks.items[0];
            qchunks.items.len = 0;
            defer allocator.free(@constCast(q_emb));
            const q_ms = @as(f64, @floatFromInt(nanoNow() - t0_q)) / 1e6;

            for (0..corpus.len) |i| {
                ranking[i] = i;
                scores[i]  = dot(q_emb, doc_embs[i]);
            }
            insertionSortDesc(ranking, scores);

            const rank = bestRank(corpus, ranking, q.relevant);
            all_metrics[cfg_idx].add(rank, q.tier);

            if (verbose) {
                const tier_str: []const u8 = if (q.tier == .exact) "exact" else "sem  ";
                try println(io, "  [{s}] \"{s}\"  rank=#{d}  ({d:.1}ms)", .{ tier_str, q.text, rank, q_ms });
                const show = @min(top_k, corpus.len);
                for (ranking[0..show], 0..) |idx, r| {
                    const name = std.Io.Dir.path.basename(corpus[idx].path);
                    const rel  = isRelevant(name, q.relevant);
                    const snip = corpus[idx].prompt[0..@min(70, corpus[idx].prompt.len)];
                    try println(io, "      {s} #{d} {d:.4}  {s}  {s}...", .{
                        if (rel) "→" else " ", r + 1, scores[idx], name, snip,
                    });
                }
            }
        }

        const m = &all_metrics[cfg_idx];
        const n:  f32 = @floatFromInt(QUERIES.len);
        const ne: f32 = @floatFromInt(m.exact_count);
        const ns: f32 = @floatFromInt(m.sem_count);
        try println(io, "  MRR={d:.3}  @1={d:.0}%  @3={d:.0}%  @5={d:.0}%  (all {d} queries)", .{
            m.mrr / n,
            @as(f32, @floatFromInt(m.top1)) / n * 100,
            @as(f32, @floatFromInt(m.top3)) / n * 100,
            @as(f32, @floatFromInt(m.top5)) / n * 100,
            QUERIES.len,
        });
        try println(io, "    exact:    MRR={d:.3}  @1={d:.0}%  ({d} queries)", .{
            m.exact_mrr / ne, @as(f32, @floatFromInt(m.exact_top1)) / ne * 100, m.exact_count,
        });
        try println(io, "    semantic: MRR={d:.3}  @1={d:.0}%  ({d} queries)", .{
            m.sem_mrr / ns, @as(f32, @floatFromInt(m.sem_top1)) / ns * 100, m.sem_count,
        });
    }

    // ── Cross-config summary table ────────────────────────────────────
    try println(io, "\n── Summary ─────────────────────────────────────────────────────", .{});
    try println(io, "  {s:<12} {s:>7} {s:>6} {s:>6} {s:>6}", .{ "config", "MRR", "@1", "@3", "@5" });
    const n: f32 = @floatFromInt(QUERIES.len);
    for (PREFIX_CONFIGS, all_metrics) |cfg, m| {
        try println(io, "  {s:<12} {d:>7.3} {d:>5.0}% {d:>5.0}% {d:>5.0}%", .{
            cfg.name,
            m.mrr / n,
            @as(f32, @floatFromInt(m.top1)) / n * 100,
            @as(f32, @floatFromInt(m.top3)) / n * 100,
            @as(f32, @floatFromInt(m.top5)) / n * 100,
        });
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

    var parser = try png.PngParser.init(a, io);
    defer parser.deinit();

    const sz = try file.length(io);
    const buf = try a.alloc(u8, sz);
    _ = try file.readPositionalAll(io, buf, 0);
    try parser.parseBuffer(buf);

    var a1111_text: ?[]const u8 = null;
    {
        const chunks = parser.getITxtChunks() catch &[_]png.Chunk{};
        defer a.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(a);
            if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed and a1111_text == null)
                a1111_text = a.dupe(u8, content.text) catch null;
        }
    }
    var workflow_text: ?[]const u8 = null;
    var prompt_text: ?[]const u8 = null;
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
    if (a1111_text) |t|    result = comfy.parseA1111Parameters(t) catch null;
    if (result == null) if (workflow_text) |t| { result = comfy.parseWorkflow(t) catch null; };
    if (result == null) if (prompt_text)   |t| { result = comfy.parsePromptChunk(t) catch null; };

    var pr = result orelse return null;
    defer pr.deinit(a);
    const prompt = pr.positive_prompt orelse return null;
    return try allocator.dupe(u8, prompt);
}

fn nanoNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn println(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.mem.print(&buf, fmt ++ "\n", args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

fn argErr(msg: []const u8) error{InvalidArgument} {
    std.log.err("{s}", .{msg});
    return error.InvalidArgument;
}

fn usage() error{MissingArgument} {
    std.log.err(
        "usage: test_text_search <images_dir> <model.gguf>\n" ++
        "  options: --n-gpu-layers N  --ctx N  --top-k N  --verbose",
        .{},
    );
    return error.MissingArgument;
}
