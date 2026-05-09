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

// ── corpus ───────────────────────────────────────────────────────────────────

const PROMPTS = [_][]const u8{
    // 0
    "A majestic dragon soaring above snow-capped mountains, " ++
        "scales gleaming in golden sunlight, wings spread wide, " ++
        "fire breathing, photorealistic, 8k, highly detailed",
    // 1
    "Portrait of an elegant elven warrior woman in ornate silver armor, " ++
        "flowing auburn hair, piercing green eyes, forest background, " ++
        "fantasy art, epic composition, dramatic lighting",
    // 2
    "Cyberpunk cityscape at night, neon signs reflecting on rain-slicked streets, " ++
        "flying cars, towering skyscrapers, blade runner aesthetic, " ++
        "cinematic lighting, foggy atmosphere, vibrant colors",
    // 3
    "Serene Japanese zen garden at sunrise, raked gravel patterns, " ++
        "cherry blossom trees in full bloom, stone lanterns, " ++
        "morning mist, watercolor style, peaceful",
    // 4
    "Cute tabby cat sitting on a windowsill in soft afternoon sunlight, " ++
        "warm cozy interior, shallow depth of field, bokeh background, " ++
        "whiskers catching the light, photography",
    // 5
    "Epic space battle between massive starships, laser beams, " ++
        "explosions, colorful nebula background, cinematic composition, " ++
        "science fiction, highly detailed, photorealistic",
    // 6
    "Ancient stone castle on a cliff overlooking the stormy sea, " ++
        "dramatic dark clouds, lightning strike, gothic atmosphere, " ++
        "oil painting style, moody, ominous",
    // 7
    "Hyperrealistic portrait of a wise old wizard with a long grey beard, " ++
        "wearing ornate purple robes covered in arcane symbols, " ++
        "holding a glowing crystal staff, mystical smoke swirling",
    // 8
    "Breathtaking sunset over the African savanna, acacia trees " ++
        "silhouetted against orange and purple sky, giraffes in the distance, " ++
        "golden hour light, wildlife photography",
    // 9
    "Mechanical steampunk butterfly with intricate clockwork wings, " ++
        "brass gears and copper pipes visible, flying over Victorian London " ++
        "rooftops, fog and coal smoke, warm sepia tones",
    // 10
    "Dark enchanted forest path in autumn, fallen leaves in deep crimson and gold, " ++
        "twisted ancient oak trees, mysterious glowing lights in the distance, " ++
        "atmospheric, moody, fantasy",
    // 11
    "Beautiful mermaid sitting on barnacle-covered rocks at the ocean's edge, " ++
        "long iridescent hair flowing in the sea breeze, moonlight reflection, " ++
        "bioluminescent waves, detailed fantasy illustration",
    // 12
    "Futuristic research laboratory interior, holographic data displays, " ++
        "scientist in white lab coat examining samples, blue neon lighting, " ++
        "clean minimalist design, science fiction concept art",
    // 13
    "Traditional Chinese ink painting of towering mountains and misty rivers, " ++
        "bamboo groves, pine trees on rocky cliffs, calligraphic brushwork, " ++
        "Song Dynasty style, minimalist",
    // 14
    "Fierce grey wolf howling at the full moon on a snowy mountain peak, " ++
        "dramatic cold blue lighting, breath visible in freezing air, " ++
        "wildlife photography style, powerful",
    // 15
    "Colorful coral reef underwater scene, tropical fish in vivid blues and yellows, " ++
        "sea turtle gliding past, shafts of sunlight piercing the water surface, " ++
        "ocean photography, serene",
    // 16
    "Steampunk airship fleet sailing through storm clouds above a Victorian city, " ++
        "brass propellers, gasbags with copper fittings, lightning in the distance, " ++
        "detailed concept art",
    // 17
    "Fierce lioness walking through golden savanna grass at dusk, " ++
        "intense amber eyes, powerful muscular form, " ++
        "National Geographic style wildlife photography, backlit",
    // 18
    "Abandoned overgrown greenhouse interior, broken glass ceiling, " ++
        "wild vines and flowers reclaiming the iron structure, " ++
        "soft diffused light, decay and beauty, artistic photography",
    // 19
    "Young knight in shining plate armor standing before a burning castle, " ++
        "sword raised, determined expression, cape billowing in the wind, " ++
        "heroic fantasy illustration, dramatic lighting",
    // --- harder distractors below ---
    // 20: fire+wings but NOT a dragon
    "A radiant phoenix rising from smoldering ash, crimson and gold plumage, " ++
        "wings wreathed in living flame, mythical rebirth, dramatic dark sky, " ++
        "digital painting, epic fantasy",
    // 21: medieval warrior but grimdark, NOT heroic knight
    "Dark armored knight on a black destrier charging through a thunderstorm, " ++
        "lance lowered, heraldic banner streaming, ominous silhouette, " ++
        "grimdark fantasy, oil painting",
    // 22: Victorian + scientific but NOT steampunk
    "Victorian alchemist laboratory, glass alembics and distillation flasks, " ++
        "esoteric charts pinned to the walls, leather-bound grimoires, " ++
        "candlelit, sepia tones, historical fantasy",
    // 23: Japanese garden but NOT zen
    "Traditional koi pond in a moss-covered stone courtyard, " ++
        "autumn maple reflections on still water, stone lanterns, " ++
        "morning mist, tranquil Japanese scene, photography",
    // 24: big cat wildlife but NOT lioness or tabby
    "Snow leopard crouched on a rocky Himalayan ridge, " ++
        "sharp pale amber eyes, thick spotted fur, breath misting in cold air, " ++
        "mountain peaks behind, wildlife photography",
    // 25: ruins + vegetation but NOT a castle or greenhouse
    "Crumbling jungle temple ruins, massive stone idols draped in creeping vines, " ++
        "shafts of golden light through the forest canopy, ancient mystery, " ++
        "adventure concept art",
    // 26: ocean creature + bioluminescent but NOT a mermaid
    "Eldritch tentacled horror emerging from dark churning ocean depths, " ++
        "bioluminescent appendages, crushing a lighthouse, " ++
        "Lovecraftian cosmic dread, stormy sky, dramatic illustration",
    // 27: abandoned interior but NOT greenhouse
    "Abandoned industrial warehouse interior, shafts of light through broken skylights, " ++
        "rusted machinery and collapsed shelving, pigeons in the rafters, " ++
        "urban decay, moody long-exposure photography",
    // 28: large marine animal, ocean, NOT coral reef or mermaid
    "Massive humpback whale breaching at golden hour, " ++
        "ocean spray catching the warm light, remote open sea, " ++
        "epic scale, wildlife photography",
    // 29: arcane + books but NOT a wizard portrait
    "Magical library interior, towering spiral bookshelves reaching the vaulted ceiling, " ++
        "floating illuminated manuscripts, arcane dust motes in warm amber candlelight, " ++
        "fantasy concept art",
};

const Query = struct {
    text: []const u8,
    relevant: []const usize,
};

// Queries go from easy (exact vocabulary) to hard (requires inference,
// cultural knowledge, or disambiguation between similar prompts).
const QUERIES = [_]Query{
    // easy: exact vocab present in the prompt
    .{ .text = "dragon",                          .relevant = &.{0} },
    .{ .text = "mermaid",                         .relevant = &.{11} },
    // medium: vocabulary mismatch, single clear answer
    .{ .text = "fire-breathing reptile",           .relevant = &.{0} },
    .{ .text = "lunar canine",                     .relevant = &.{14} },
    .{ .text = "holographic interface",            .relevant = &.{12} },
    .{ .text = "interstellar combat",              .relevant = &.{5} },
    .{ .text = "ink wash brushwork",               .relevant = &.{13} },
    // medium-hard: two valid answers
    .{ .text = "Victorian clockwork",              .relevant = &.{9, 16} },
    // hard: three valid answers (all Felidae)
    .{ .text = "feline",                           .relevant = &.{4, 17, 24} },
    // hard: two valid (both bioluminescent ocean creatures)
    .{ .text = "bioluminescent ocean creature",    .relevant = &.{11, 26} },
    // hard: two valid (vegetation reclaiming ruins)
    .{ .text = "nature reclaims ruin",             .relevant = &.{18, 25} },
    // hard: requires inference (wizard = spellcasting scholar)
    .{ .text = "spellcasting scholar",             .relevant = &.{7} },
    // hard: taxonomic vocabulary
    .{ .text = "African ungulate",                 .relevant = &.{8} },
    // hard: genre knowledge required
    .{ .text = "Cthulhu mythos",                   .relevant = &.{26} },
    // hard: mythological knowledge
    .{ .text = "mythical firebird",                .relevant = &.{20} },
    .{ .text = "mounted grimdark cavalry",         .relevant = &.{21} },
    .{ .text = "alchemical distillation",          .relevant = &.{22} },
    // hard: taxonomic synonym
    .{ .text = "cetacean breach",                  .relevant = &.{28} },
    .{ .text = "high altitude spotted felid",      .relevant = &.{24} },
    // hard: Japanese cultural concept; two valid (zen garden + koi pond)
    .{ .text = "wabi-sabi",                        .relevant = &.{3, 23} },
};

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
            const n: f32 = @floatFromInt(QUERIES.len);
            _ = n;
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

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
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

        const ctx = try pool.get(model_path, 60_000);
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
