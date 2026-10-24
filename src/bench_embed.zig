//! Retrieval-quality and speed A/B: DiffKeep's current encoders vs EmbeddingGemma 2.
//!
//!   current : EmbeddingGemma 300M prompt space + SigLIP2 image space, merged by RRF.
//!             Driven through the production `Embedder`, so prompt cleaning, prefixes,
//!             batching and the long-prompt skip are exactly what the app indexes.
//!   gemma2  : one EmbeddingGemma 2 space for prompts AND images (TensorPencil
//!             `MultimodalEncoder`), per image-token budget, at 768 and 256 dims.
//!
//! Usage (build ReleaseFast; Debug f32 matmul is very slow):
//!   zig build bench_embed -Doptimize=ReleaseFast -- [opts]
//!     --corpus FILE      image corpus JSON (default bench/images32.json; repeatable)
//!     --no-text-corpus   skip the 30-prompt text corpus (search_quality_corpus.zig)
//!     --gemma300 DIR     (default Models/embeddinggemma-300m)
//!     --siglip DIR       (default Models/ViT-B-16-SigLIP2-timm)
//!     --gemma2 DIR       (default Models/embeddinggemma-2)
//!     --backend B        cuda | vulkan | cpu  (default cuda) for batched work
//!     --budgets LIST     gemma2 image tokens, e.g. 280,140,70 (default)
//!     --speed            also time indexing throughput and query latency
//!     --pool-out FILE    write each query's top-K union over all systems (judging pool)
//!     --pool-k K         (default 15)
//!     --verbose          per-query ranks
//!
//! Corpus JSON: { "name": "...", "images": [ { "path": "...", "prompt": "..."? } ],
//!                "queries": [ { "text": "...", "relevant": [ "basename-or-path", ... ] } ] }
//! An image without "prompt" has it read from its PNG metadata. Rankings are full and
//! unthresholded: production's min-similarity floors are tuned per space and gemma2
//! has none yet, so the similarity distributions are printed to calibrate one.
const std = @import("std");
const tp = @import("TensorPencil");
const vips = @import("vips");
const embedder_mod = @import("embedder.zig");
const prompt_clean = @import("parse/prompt_clean.zig");
const text_corpus = @import("search_quality_corpus.zig");
const png = @import("image/png-data.zig");
const comfy = @import("parse/comfy.zig");
const print = @import("util.zig").print;

const Embedder = embedder_mod.Embedder;
const Vec = ?[]f32; // null = not indexed (no prompt, prompt too long, decode failed)

const rrf_k: f32 = 60.0; // same as db.zig searchCombined
const g2_small_dim = 256;

const Opts = struct {
    corpora: std.ArrayList([]const u8) = .empty,
    text_corpus: bool = true,
    gemma300: []const u8 = "Models/embeddinggemma-300m",
    siglip: []const u8 = "Models/ViT-B-16-SigLIP2-timm",
    gemma2: []const u8 = "Models/embeddinggemma-2",
    backend: embedder_mod.GpuBackend = .cuda,
    budgets: std.ArrayList(usize) = .empty,
    speed: bool = false,
    pool_out: ?[]const u8 = null,
    pool_k: usize = 15,
    verbose: bool = false,
};

const Image = struct {
    path: [:0]const u8,
    /// Cleaned prompt document, as the scanner indexes it.
    prompt: ?[]const u8,
};

const Query = struct {
    text: []const u8,
    relevant: []const usize,
};

const Corpus = struct {
    name: []const u8,
    images: []const Image,
    queries: []const Query,
};

/// One retrieval system: a score per (query, image); -inf = not retrievable.
const System = struct {
    name: []const u8,
    scores: []const []const f32,
};

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const opts = try parseArgs(arena, init.minimal.args);
    try vips.init();
    defer vips.deinit();

    var b = try Bench.init(arena, init.gpa, io, opts);
    defer b.deinit();

    if (opts.text_corpus) try b.runTextCorpus();
    for (opts.corpora.items) |path| {
        const corpus = try loadCorpus(arena, io, path);
        try b.runImageCorpus(corpus);
    }
}

// ── Encoders ─────────────────────────────────────────────────────────────────

const Bench = struct {
    /// Results, scores, rankings: freed all at once at exit.
    arena: std.mem.Allocator,
    /// Encoder calls and per-batch buffers. TensorPencil allocates its scratch from
    /// the allocator it's handed, so an arena here would never give it back.
    gpa: std.mem.Allocator,
    /// Vectors returned by the encoders (from `gpa`), freed in deinit.
    owned: std.ArrayList([]f32) = .empty,
    io: std.Io,
    opts: Opts,
    current: Embedder,
    g2: tp.embed.MultimodalEncoder,
    g2_gpu: tp.embed.Backend,
    cuda: ?*tp.gpu.cuda.Backend = null,
    vk: ?*tp.gpu.context.Context = null,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, opts: Opts) !Bench {
        // threshold 4 = production default: single queries on CPU, batches on GPU.
        var current = try Embedder.init(io, gpa, opts.gemma300, opts.siglip, opts.backend, 4);
        errdefer current.deinit();
        if (!current.hasPromptEncoder() or !current.hasVisualEncoder()) return error.CurrentModelsMissing;

        var self: Bench = .{
            .arena = arena,
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .current = current,
            .g2 = undefined,
            .g2_gpu = .cpu,
        };
        switch (opts.backend) {
            .none => {},
            .cuda => {
                self.cuda = try tp.gpu.cuda.Backend.init(gpa);
                self.g2_gpu = .{ .cuda = self.cuda.? };
            },
            .vulkan => {
                self.vk = try tp.gpu.context.Context.init(gpa, io);
                self.g2_gpu = .{ .vulkan = self.vk.? };
            },
        }
        self.g2 = try tp.embed.MultimodalEncoder.open(gpa, io, opts.gemma2, .cpu);
        return self;
    }

    fn deinit(self: *Bench) void {
        for (self.owned.items) |v| self.gpa.free(v);
        self.owned.deinit(self.gpa);
        self.g2.deinit();
        if (self.cuda) |be| be.deinit();
        if (self.vk) |ctx| ctx.deinit();
        self.current.deinit();
    }

    /// Take ownership of an encoder batch result: keep each vector (freed in
    /// deinit) and free the outer slice. Returns the vectors, aligned to input.
    fn keep(self: *Bench, vecs: [][]f32) ![]const []f32 {
        defer self.gpa.free(vecs);
        const out = try self.arena.dupe([]f32, vecs);
        for (vecs) |v| if (v.len != 0) try self.owned.append(self.gpa, v);
        return out;
    }

    fn keepOne(self: *Bench, v: []f32) ![]f32 {
        try self.owned.append(self.gpa, v);
        return v;
    }

    /// Route the gemma2 encoder to `backend` for the next call.
    fn g2On(self: *Bench, backend: tp.embed.Backend) void {
        self.g2.text.backend = backend;
        if (backend == .cuda) backend.cuda.bindThread();
    }

    // current: prompt documents / queries ---------------------------------------

    fn currentPromptDocs(self: *Bench, docs: []const ?[]const u8) ![]Vec {
        const out = try self.arena.alloc(Vec, docs.len);
        @memset(out, null);
        // Mirror scan.embedBatch: prompts that don't fit are skipped, not truncated.
        var texts: std.ArrayList([]const u8) = .empty;
        var slots: std.ArrayList(usize) = .empty;
        for (docs, 0..) |d, i| if (d) |t| if (self.current.promptFits(self.gpa, t)) {
            try texts.append(self.arena, t);
            try slots.append(self.arena, i);
        };
        var start: usize = 0;
        while (start < texts.items.len) : (start += 32) {
            const end = @min(start + 32, texts.items.len);
            const vecs = try self.keep(try self.current.embedPromptBatch(self.gpa, texts.items[start..end]));
            for (vecs, slots.items[start..end]) |v, slot| out[slot] = v;
        }
        return out;
    }

    fn currentPromptQueries(self: *Bench, queries: []const []const u8) ![][]f32 {
        const out = try self.arena.alloc([]f32, queries.len);
        for (queries, out) |q, *v| v.* = try self.keepOne(try self.current.embedPromptQuery(self.gpa, q));
        return out;
    }

    fn currentVisualQueries(self: *Bench, queries: []const []const u8) ![][]f32 {
        const out = try self.arena.alloc([]f32, queries.len);
        for (queries, out) |q, *v| v.* = try self.keepOne(try self.current.embedQueryForVisual(self.gpa, q));
        return out;
    }

    fn currentImages(self: *Bench, images: []const Image) ![]Vec {
        const out = try self.arena.alloc(Vec, images.len);
        var start: usize = 0;
        while (start < images.len) : (start += 32) {
            const end = @min(start + 32, images.len);
            const paths = try self.gpa.alloc([:0]const u8, end - start);
            defer self.gpa.free(paths);
            for (images[start..end], paths) |img, *p| p.* = img.path;
            const vecs = try self.keep(try self.current.embedImageBatch(self.gpa, paths, null));
            for (vecs, out[start..end]) |v, *o| o.* = if (v.len == 0) null else v;
        }
        return out;
    }

    // gemma2 ------------------------------------------------------------------------

    fn g2Texts(self: *Bench, texts: []const ?[]const u8, role: tp.embed.Role) ![]Vec {
        const out = try self.arena.alloc(Vec, texts.len);
        @memset(out, null);
        var present: std.ArrayList([]const u8) = .empty;
        var slots: std.ArrayList(usize) = .empty;
        for (texts, 0..) |t, i| if (t) |s| {
            try present.append(self.arena, s);
            try slots.append(self.arena, i);
        };
        self.g2On(self.g2_gpu);
        var start: usize = 0;
        while (start < present.items.len) : (start += 32) {
            const end = @min(start + 32, present.items.len);
            const vecs = try self.keep(try self.g2.embedTextBatch(self.gpa, present.items[start..end], .{ .role = role }));
            for (vecs, slots.items[start..end]) |v, slot| out[slot] = v;
        }
        return out;
    }

    fn g2Images(self: *Bench, images: []const Image, tokens: usize, batch: usize) ![]Vec {
        try self.g2.setImageTokens(tokens);
        const out = try self.arena.alloc(Vec, images.len);
        @memset(out, null);
        var start: usize = 0;
        while (start < images.len) : (start += batch) {
            const end = @min(start + batch, images.len);
            var rgbs: std.ArrayList(tp.embed.Rgb) = .empty;
            defer {
                for (rgbs.items) |r| self.gpa.free(r.pixels);
                rgbs.deinit(self.gpa);
            }
            var slots: std.ArrayList(usize) = .empty;
            defer slots.deinit(self.gpa);
            for (images[start..end], start..) |img, i| {
                const rgb = loadRgb(self.gpa, img.path) catch |err| {
                    std.log.warn("decode {s}: {}", .{ img.path, err });
                    continue;
                };
                try rgbs.append(self.gpa, rgb);
                try slots.append(self.gpa, i);
            }
            if (rgbs.items.len == 0) continue;
            const t = Timer.start(self.io);
            self.g2On(self.g2_gpu);
            const vecs = try self.keep(try self.g2.embedImageBatch(self.gpa, rgbs.items));
            std.log.info("gemma2 @{d}: images {d}..{d} in {d:.0} ms", .{ tokens, start, end, t.msPer(1) });
            for (vecs, slots.items) |v, slot| out[slot] = v;
        }
        return out;
    }

    // ── Text-only corpus ──────────────────────────────────────────────────────

    fn runTextCorpus(self: *Bench) !void {
        const n = text_corpus.PROMPTS.len;
        const docs = try self.arena.alloc(?[]const u8, n);
        for (text_corpus.PROMPTS, docs) |p, *d| d.* = try cleanedDoc(self.arena, p);
        const queries = try self.arena.alloc(Query, text_corpus.QUERIES.len);
        const qtexts = try self.arena.alloc([]const u8, queries.len);
        for (text_corpus.QUERIES, queries, qtexts) |q, *o, *t| {
            o.* = .{ .text = q.text, .relevant = q.relevant };
            t.* = q.text;
        }

        const g300_docs = try self.currentPromptDocs(docs);
        const g300_q = try self.currentPromptQueries(qtexts);
        const g2_docs = try self.g2Texts(docs, .document);
        const g2_q = try self.g2Texts(asOptional(self.arena, qtexts), .query);

        const systems = [_]System{
            .{ .name = "prompt  gemma300 (current)", .scores = try scoreAll(self.arena, g300_q, g300_docs) },
            .{ .name = "prompt  gemma2-768", .scores = try scoreAll(self.arena, unwrap(self.arena, g2_q), g2_docs) },
            .{ .name = "prompt  gemma2-256", .scores = try scoreAll(self.arena, try truncated(self.arena, unwrap(self.arena, g2_q)), try truncatedOpt(self.arena, g2_docs)) },
        };
        try self.report("text30 (30 prompts, 20 queries; prompt search only)", queries, n, &systems, null);
    }

    // ── Image corpus ──────────────────────────────────────────────────────────

    fn runImageCorpus(self: *Bench, corpus: Corpus) !void {
        const n = corpus.images.len;
        const qtexts = try self.arena.alloc([]const u8, corpus.queries.len);
        for (corpus.queries, qtexts) |q, *t| t.* = q.text;
        const docs = try self.arena.alloc(?[]const u8, n);
        for (corpus.images, docs) |img, *d| d.* = img.prompt;

        std.log.info("{s}: embedding current encoders", .{corpus.name});
        const g300_docs = try self.currentPromptDocs(docs);
        const g300_q = try self.currentPromptQueries(qtexts);
        const sig_imgs = try self.currentImages(corpus.images);
        const sig_q = try self.currentVisualQueries(qtexts);

        std.log.info("{s}: embedding gemma2 text", .{corpus.name});
        const g2_docs = try self.g2Texts(docs, .document);
        const g2_q = unwrap(self.arena, try self.g2Texts(asOptional(self.arena, qtexts), .query));
        const g2_q256 = try truncated(self.arena, g2_q);

        var systems: std.ArrayList(System) = .empty;
        const sem_g300 = try scoreAll(self.arena, g300_q, g300_docs);
        const vis_sig = try scoreAll(self.arena, sig_q, sig_imgs);
        const sem_g2 = try scoreAll(self.arena, g2_q, g2_docs);
        try systems.appendSlice(self.arena, &.{
            .{ .name = "prompt  gemma300 (current semantic)", .scores = sem_g300 },
            .{ .name = "prompt  gemma2-768", .scores = sem_g2 },
            .{ .name = "prompt  gemma2-256", .scores = try scoreAll(self.arena, g2_q256, try truncatedOpt(self.arena, g2_docs)) },
            .{ .name = "image   siglip2 (current visual)", .scores = vis_sig },
            .{ .name = "combo   gemma300+siglip2 RRF (current)", .scores = try rrf(self.arena, &.{ sem_g300, vis_sig }) },
        });
        for (self.opts.budgets.items) |tokens| {
            std.log.info("{s}: embedding gemma2 images @{d} tokens", .{ corpus.name, tokens });
            const g2_imgs = try self.g2Images(corpus.images, tokens, 8);
            const vis_g2 = try scoreAll(self.arena, g2_q, g2_imgs);
            try systems.appendSlice(self.arena, &.{
                .{ .name = try self.label("image   gemma2-768 @{d}", tokens), .scores = vis_g2 },
                .{ .name = try self.label("image   gemma2-256 @{d}", tokens), .scores = try scoreAll(self.arena, g2_q256, try truncatedOpt(self.arena, g2_imgs)) },
                .{ .name = try self.label("combo   gemma2 prompt+image RRF @{d}", tokens), .scores = try rrf(self.arena, &.{ sem_g2, vis_g2 }) },
                .{ .name = try self.label("combo   gemma2 max(prompt,image) @{d}", tokens), .scores = try maxOf(self.arena, sem_g2, vis_g2) },
                .{ .name = try self.label("combo   gemma300+gemma2-image RRF @{d}", tokens), .scores = try rrf(self.arena, &.{ sem_g300, vis_g2 }) },
            });
        }

        const title = try self.arena.print("{s} ({d} images, {d} queries)", .{ corpus.name, n, corpus.queries.len });
        try self.report(title, corpus.queries, n, systems.items, corpus.images);
        if (self.opts.pool_out) |path| try writePool(self.arena, self.io, path, corpus, systems.items, self.opts.pool_k);
        if (self.opts.speed) try self.speed(corpus, qtexts, docs);
    }

    fn label(self: *Bench, comptime fmt: []const u8, tokens: usize) ![]const u8 {
        return self.arena.print(fmt, .{tokens});
    }

    // ── Reporting ─────────────────────────────────────────────────────────────

    fn report(self: *Bench, title: []const u8, queries: []const Query, n: usize, systems: []const System, images: ?[]const Image) !void {
        const io = self.io;
        try print(io, "\n=== {s} ===\n", .{title});
        try print(io, "{s:<44} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>7}\n", .{ "system", "MRR", "hit@1", "hit@5", "hit@10", "R@10", "nDCG10" });
        for (systems) |sys| {
            const m = try metrics(self.arena, sys.scores, queries, n);
            try print(io, "{s:<44} {d:>6.3} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>7.3}\n", .{ sys.name, m.mrr, m.hit1, m.hit5, m.hit10, m.recall10, m.ndcg10 });
        }

        // Similarity distributions of the raw (non-fused) systems, for thresholds.
        try print(io, "\n{s:<44} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "cosine (raw systems)", "rel min", "rel mean", "irr mean", "irr p95" });
        for (systems) |sys| {
            if (std.mem.startsWith(u8, sys.name, "combo")) continue;
            const d = try simDist(self.arena, sys.scores, queries);
            try print(io, "{s:<44} {d:>8.3} {d:>8.3} {d:>8.3} {d:>8.3}\n", .{ sys.name, d.rel_min, d.rel_mean, d.irr_mean, d.irr_p95 });
        }

        if (self.opts.verbose) {
            try print(io, "\nbest rank of a relevant item per query (1 = top):\n", .{});
            for (queries, 0..) |q, qi| {
                try print(io, "  {s:<28}", .{q.text});
                for (systems) |sys| {
                    const ranking = try rank(self.arena, sys.scores[qi]);
                    try print(io, " {d:>3}", .{bestRank(ranking, q.relevant)});
                }
                try print(io, "\n", .{});
            }
            if (images != null) try print(io, "  (columns follow the system order above)\n", .{});
        }
    }

    // ── Speed ─────────────────────────────────────────────────────────────────

    fn speed(self: *Bench, corpus: Corpus, qtexts: []const []const u8, docs: []const ?[]const u8) !void {
        const io = self.io;
        const imgs = corpus.images[0..@min(corpus.images.len, 64)];
        try print(io, "\n--- speed: {s}, {d} images, backend {s} (ms per item, end to end incl. decode) ---\n", .{ corpus.name, imgs.len, @tagName(self.opts.backend) });

        // Warm up every path once so first-use uploads don't count.
        _ = try self.currentImages(imgs[0..@min(imgs.len, 4)]);
        var t = Timer.start(io);
        _ = try self.currentImages(imgs);
        try print(io, "index image   siglip2 (current, batch 32)     {d:>8.1}\n", .{t.msPer(imgs.len)});
        for (self.opts.budgets.items) |tokens| {
            for ([_]usize{ 8, 16 }) |batch| {
                _ = try self.g2Images(imgs[0..@min(imgs.len, 2)], tokens, batch);
                t = Timer.start(io);
                _ = try self.g2Images(imgs, tokens, batch);
                try print(io, "index image   gemma2 @{d:<4} (batch {d:>2})          {d:>8.1}\n", .{ tokens, batch, t.msPer(imgs.len) });
            }
        }

        var n_docs: usize = 0;
        for (docs) |d| n_docs += @intFromBool(d != null);
        _ = try self.currentPromptDocs(docs[0..@min(docs.len, 4)]);
        t = Timer.start(io);
        _ = try self.currentPromptDocs(docs);
        try print(io, "index prompt  gemma300 (current, batch 32)    {d:>8.2}\n", .{t.msPer(n_docs)});
        _ = try self.g2Texts(docs[0..@min(docs.len, 4)], .document);
        t = Timer.start(io);
        _ = try self.g2Texts(docs, .document);
        try print(io, "index prompt  gemma2 (batch 32)               {d:>8.2}\n", .{t.msPer(n_docs)});

        // Query latency: one query at a time, as typed into the search box.
        try print(io, "\nquery latency (single query)        p50 ms   p99 ms\n", .{});
        try self.latency("gemma300 prompt query (CPU)", qtexts, .g300);
        try self.latency("siglip2 text query (CPU)", qtexts, .siglip);
        try self.latency("gemma2 query (CPU)", qtexts, .g2_cpu);
        if (self.g2_gpu != .cpu) try self.latency("gemma2 query (GPU)", qtexts, .g2_gpu);
    }

    const QueryPath = enum { g300, siglip, g2_cpu, g2_gpu };

    fn latency(self: *Bench, name: []const u8, qtexts: []const []const u8, path: QueryPath) !void {
        const reps = 40;
        var samples: [reps]f64 = undefined;
        for (0..reps + 3) |i| {
            const q = qtexts[i % qtexts.len];
            const t = Timer.start(self.io);
            const v = switch (path) {
                .g300 => try self.current.embedPromptQuery(self.gpa, q),
                .siglip => try self.current.embedQueryForVisual(self.gpa, q),
                .g2_cpu, .g2_gpu => blk: {
                    self.g2On(if (path == .g2_cpu) .cpu else self.g2_gpu);
                    break :blk try self.g2.embedText(self.gpa, q, .{ .role = .query });
                },
            };
            const ms = t.msPer(1);
            self.gpa.free(v);
            if (i >= 3) samples[i - 3] = ms; // first 3 are warm-up
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        try print(self.io, "{s:<34} {d:>7.2} {d:>8.2}\n", .{ name, samples[reps / 2], samples[reps - 1] });
    }
};

const Timer = struct {
    io: std.Io,
    start_ns: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .start_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn msPer(t: Timer, items: usize) f64 {
        const ns: f64 = @floatFromInt(std.Io.Clock.awake.now(t.io).nanoseconds - t.start_ns);
        return ns / 1e6 / @as(f64, @floatFromInt(@max(items, 1)));
    }
};

// ── Scoring ──────────────────────────────────────────────────────────────────

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

fn scoreAll(gpa: std.mem.Allocator, queries: []const []const f32, docs: []const Vec) ![]const []const f32 {
    const out = try gpa.alloc([]f32, queries.len);
    for (queries, out) |q, *row| {
        row.* = try gpa.alloc(f32, docs.len);
        for (docs, row.*) |d, *s| s.* = if (d) |v| dot(q, v) else -std.math.inf(f32);
    }
    return out;
}

/// Indices sorted by descending score; ties keep corpus order.
fn rank(gpa: std.mem.Allocator, scores: []const f32) ![]usize {
    const idx = try gpa.alloc(usize, scores.len);
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, scores, struct {
        fn gt(s: []const f32, a: usize, b: usize) bool {
            return s[a] > s[b] or (s[a] == s[b] and a < b);
        }
    }.gt);
    return idx;
}

/// Reciprocal Rank Fusion of full rankings (k = 60, as in db.zig). An item a
/// system can't retrieve (-inf) contributes nothing from that system.
fn rrf(gpa: std.mem.Allocator, parts: []const []const []const f32) ![]const []const f32 {
    const nq = parts[0].len;
    const n = parts[0][0].len;
    const out = try gpa.alloc([]f32, nq);
    for (out, 0..) |*row, qi| {
        row.* = try gpa.alloc(f32, n);
        @memset(row.*, 0);
        for (parts) |p| {
            const order = try rank(gpa, p[qi]);
            for (order, 0..) |doc, r| {
                if (p[qi][doc] == -std.math.inf(f32)) continue;
                row.*[doc] += 1.0 / (rrf_k + @as(f32, @floatFromInt(r + 1)));
            }
        }
    }
    return out;
}

fn maxOf(gpa: std.mem.Allocator, a: []const []const f32, b: []const []const f32) ![]const []const f32 {
    const out = try gpa.alloc([]f32, a.len);
    for (out, a, b) |*row, ra, rb| {
        row.* = try gpa.alloc(f32, ra.len);
        for (row.*, ra, rb) |*s, x, y| s.* = @max(x, y);
    }
    return out;
}

const Metrics = struct { mrr: f64, hit1: f64, hit5: f64, hit10: f64, recall10: f64, ndcg10: f64 };

fn bestRank(ranking: []const usize, relevant: []const usize) usize {
    for (ranking, 1..) |doc, r| {
        if (std.mem.findScalar(usize, relevant, doc) != null) return r;
    }
    return ranking.len + 1;
}

fn metrics(gpa: std.mem.Allocator, scores: []const []const f32, queries: []const Query, n: usize) !Metrics {
    var m: Metrics = .{ .mrr = 0, .hit1 = 0, .hit5 = 0, .hit10 = 0, .recall10 = 0, .ndcg10 = 0 };
    var counted: f64 = 0;
    for (queries, scores) |q, row| {
        if (q.relevant.len == 0) continue;
        counted += 1;
        const order = try rank(gpa, row);
        const best = bestRank(order, q.relevant);
        if (best <= n) m.mrr += 1.0 / @as(f64, @floatFromInt(best));
        m.hit1 += @floatFromInt(@intFromBool(best <= 1));
        m.hit5 += @floatFromInt(@intFromBool(best <= 5));
        m.hit10 += @floatFromInt(@intFromBool(best <= 10));
        var found: f64 = 0;
        var dcg: f64 = 0;
        for (order[0..@min(10, order.len)], 0..) |doc, i| {
            if (std.mem.findScalar(usize, q.relevant, doc) == null) continue;
            found += 1;
            dcg += 1.0 / std.math.log2(@as(f64, @floatFromInt(i + 2)));
        }
        var idcg: f64 = 0;
        for (0..@min(10, q.relevant.len)) |i| idcg += 1.0 / std.math.log2(@as(f64, @floatFromInt(i + 2)));
        m.recall10 += found / @as(f64, @floatFromInt(q.relevant.len));
        m.ndcg10 += dcg / idcg;
    }
    if (counted == 0) return m;
    inline for (@typeInfo(Metrics).@"struct".field_names) |f| @field(m, f) /= counted;
    return m;
}

const SimDist = struct { rel_min: f32, rel_mean: f32, irr_mean: f32, irr_p95: f32 };

fn simDist(gpa: std.mem.Allocator, scores: []const []const f32, queries: []const Query) !SimDist {
    var rel_min: f32 = std.math.inf(f32);
    var rel_sum: f64 = 0;
    var rel_n: f64 = 0;
    var irr: std.ArrayList(f32) = .empty;
    for (queries, scores) |q, row| {
        for (row, 0..) |s, doc| {
            if (s == -std.math.inf(f32)) continue;
            if (std.mem.findScalar(usize, q.relevant, doc) != null) {
                rel_min = @min(rel_min, s);
                rel_sum += s;
                rel_n += 1;
            } else try irr.append(gpa, s);
        }
    }
    std.mem.sort(f32, irr.items, {}, std.sort.asc(f32));
    var irr_sum: f64 = 0;
    for (irr.items) |s| irr_sum += s;
    const ni = irr.items.len;
    return .{
        .rel_min = rel_min,
        .rel_mean = @floatCast(rel_sum / @max(rel_n, 1)),
        .irr_mean = @floatCast(irr_sum / @as(f64, @floatFromInt(@max(ni, 1)))),
        .irr_p95 = if (ni == 0) 0 else irr.items[@min(ni - 1, ni * 95 / 100)],
    };
}

// ── Vector helpers ───────────────────────────────────────────────────────────

fn asOptional(gpa: std.mem.Allocator, texts: []const []const u8) []const ?[]const u8 {
    const out = gpa.alloc(?[]const u8, texts.len) catch @panic("OOM");
    for (texts, out) |t, *o| o.* = t;
    return out;
}

/// Query vectors are always present; drop the optional.
fn unwrap(gpa: std.mem.Allocator, vecs: []const Vec) []const []const f32 {
    const out = gpa.alloc([]const f32, vecs.len) catch @panic("OOM");
    for (vecs, out) |v, *o| o.* = v.?;
    return out;
}

/// Matryoshka copies at `g2_small_dim` (renormalized), leaving the originals intact.
fn truncated(gpa: std.mem.Allocator, vecs: []const []const f32) ![]const []const f32 {
    const out = try gpa.alloc([]const f32, vecs.len);
    for (vecs, out) |v, *o| o.* = tp.embed.truncate(try gpa.dupe(f32, v), g2_small_dim);
    return out;
}

fn truncatedOpt(gpa: std.mem.Allocator, vecs: []const Vec) ![]Vec {
    const out = try gpa.alloc(Vec, vecs.len);
    for (vecs, out) |v, *o| o.* = if (v) |x| tp.embed.truncate(try gpa.dupe(f32, x), g2_small_dim) else null;
    return out;
}

/// Full-resolution RGB8 for gemma2 (the encoder resizes itself).
fn loadRgb(gpa: std.mem.Allocator, path: [:0]const u8) !tp.embed.Rgb {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (vips.c.diffkeep_load_image_rgba(path.ptr, &buf, &len, &w, &h) != 0) return error.VipsLoadFailed;
    defer vips.c.diffkeep_vips_free(buf);
    const n: usize = @intCast(w * h);
    const rgba: [*]const u8 = @ptrCast(buf.?);
    const rgb = try gpa.alloc(u8, n * 3);
    for (0..n) |p| @memcpy(rgb[p * 3 ..][0..3], rgba[p * 4 ..][0..3]);
    return .{ .pixels = rgb, .width = @intCast(w), .height = @intCast(h) };
}

// ── Corpus loading ───────────────────────────────────────────────────────────

const CorpusJson = struct {
    name: []const u8,
    images: []const struct { path: []const u8, prompt: ?[]const u8 = null },
    queries: []const struct { text: []const u8, relevant: []const []const u8 },
};

fn loadCorpus(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Corpus {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    const j = try std.json.parseFromSliceLeaky(CorpusJson, arena, bytes, .{ .ignore_unknown_fields = true });

    const images = try arena.alloc(Image, j.images.len);
    var with_prompt: usize = 0;
    for (j.images, images) |src, *img| {
        const raw = src.prompt orelse (extractPrompt(arena, io, src.path) catch null);
        img.* = .{
            .path = try arena.dupeSentinel(u8, src.path, 0),
            .prompt = if (raw) |r| try cleanedDoc(arena, r) else null,
        };
        with_prompt += @intFromBool(img.prompt != null);
    }

    const queries = try arena.alloc(Query, j.queries.len);
    for (j.queries, queries) |src, *q| {
        var rel: std.ArrayList(usize) = .empty;
        for (src.relevant) |want| {
            const idx = for (images, 0..) |img, i| {
                const by_name = std.mem.findScalar(u8, want, '/') == null;
                const have = if (by_name) std.Io.Dir.path.basename(img.path) else img.path;
                if (std.mem.eql(u8, have, want)) break i;
            } else {
                std.log.warn("{s}: query \"{s}\": relevant {s} not in corpus", .{ j.name, src.text, want });
                continue;
            };
            try rel.append(arena, idx);
        }
        q.* = .{ .text = src.text, .relevant = rel.items };
    }
    std.log.info("{s}: {d} images ({d} with prompts), {d} queries", .{ j.name, images.len, with_prompt, queries.len });
    return .{ .name = j.name, .images = images, .queries = queries };
}

/// The prompt document the scanner indexes, or null when cleaning leaves
/// nothing (scan.zig skips those, so the image has no prompt vector).
fn cleanedDoc(arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const cleaned = try prompt_clean.cleanPrompt(arena, raw);
    return if (cleaned.len == 0) null else cleaned;
}

/// Positive prompt from PNG metadata (A1111 parameters, ComfyUI workflow or prompt).
fn extractPrompt(arena: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const buffer = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20));
    var parser = try png.PngParser.init(arena, io);
    defer parser.deinit();
    try parser.parseBuffer(buffer);

    var a1111: ?[]const u8 = null;
    var workflow: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    for (parser.getITxtChunks() catch &.{}) |chunk| {
        var content = parser.parseITxtChunk(chunk) catch continue;
        if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed and a1111 == null)
            a1111 = try arena.dupe(u8, content.text);
        content.deinit(arena);
    }
    for (parser.getTExtChunks() catch &.{}) |chunk| {
        var content = parser.parseTExtChunk(chunk) catch continue;
        defer content.deinit(arena);
        const slot: *?[]const u8 = if (std.mem.eql(u8, content.keyword, "workflow"))
            &workflow
        else if (std.mem.eql(u8, content.keyword, "prompt"))
            &prompt
        else if (std.mem.eql(u8, content.keyword, "parameters"))
            &a1111
        else
            continue;
        if (slot.* == null) slot.* = try arena.dupe(u8, content.text);
    }

    var cp = comfy.ComfyParser.init(arena);
    var result: ?comfy.ParseResult = null;
    if (a1111) |t| result = cp.parseA1111Parameters(t) catch null;
    if (result == null) if (workflow) |t| {
        result = cp.parseWorkflow(t) catch null;
    };
    if (result == null) if (prompt) |t| {
        result = cp.parsePromptChunk(t) catch null;
    };
    const pr = result orelse return null;
    return pr.positive_prompt;
}

// ── Judging pool ─────────────────────────────────────────────────────────────

/// Per query, the union of every system's top `k` — the candidates a judge labels.
fn writePool(gpa: std.mem.Allocator, io: std.Io, path: []const u8, corpus: Corpus, systems: []const System, k: usize) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    try js.beginObject();
    try js.objectField("name");
    try js.write(corpus.name);
    try js.objectField("queries");
    try js.beginArray();
    for (corpus.queries, 0..) |q, qi| {
        var seen: std.array_hash_map.Auto(usize, void) = .empty;
        for (systems) |sys| {
            const order = try rank(gpa, sys.scores[qi]);
            for (order[0..@min(k, order.len)]) |doc| try seen.put(gpa, doc, {});
        }
        try js.beginObject();
        try js.objectField("text");
        try js.write(q.text);
        try js.objectField("candidates");
        try js.beginArray();
        for (seen.keys()) |doc| try js.write(corpus.images[doc].path);
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
    std.log.info("judging pool written to {s}", .{path});
}

// ── Args ─────────────────────────────────────────────────────────────────────

fn parseArgs(arena: std.mem.Allocator, args_in: std.process.Args) !Opts {
    var o: Opts = .{};
    var it = std.process.Args.Iterator.init(args_in);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--corpus")) {
            try o.corpora.append(arena, it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--no-text-corpus")) {
            o.text_corpus = false;
        } else if (std.mem.eql(u8, arg, "--gemma300")) {
            o.gemma300 = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--siglip")) {
            o.siglip = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--gemma2")) {
            o.gemma2 = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            const v = it.next() orelse return error.MissingValue;
            o.backend = if (std.mem.eql(u8, v, "cpu")) .none else std.meta.stringToEnum(embedder_mod.GpuBackend, v) orelse return error.BadBackend;
        } else if (std.mem.eql(u8, arg, "--budgets")) {
            var parts = std.mem.splitScalar(u8, it.next() orelse return error.MissingValue, ',');
            while (parts.next()) |p| try o.budgets.append(arena, try std.fmt.parseInt(usize, p, 10));
        } else if (std.mem.eql(u8, arg, "--speed")) {
            o.speed = true;
        } else if (std.mem.eql(u8, arg, "--pool-out")) {
            o.pool_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--pool-k")) {
            o.pool_k = try std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            o.verbose = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.BadArgument;
        }
    }
    if (o.corpora.items.len == 0) try o.corpora.append(arena, "bench/images32.json");
    if (o.budgets.items.len == 0) try o.budgets.appendSlice(arena, &.{ 280, 140, 70 });
    return o;
}
