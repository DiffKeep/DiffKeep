const std = @import("std");
const dvui = @import("dvui");
const llama_mod = @import("llama.zig");
const mtmd_mod = @import("mtmd.zig");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");

const log = std.log.scoped(.search);

const RERANK_INSTRUCTION = "Retrieve AI-generated images that visually match the user's search query.";

// ── Rerank task ───────────────────────────────────────────────────────────────

const RerankTaskCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    query: []const u8,
    image_paths: [][]u8,
    image_ids: []u64,
    generation: u64,
    reranker: *?mtmd_mod.RerankContext,
    reranker_model: []const u8,
    reranker_mmproj: []const u8,
    init_mutex: *std.Io.Mutex,
    result_ids: *?[]u64,
    result_gen: *u64,
    done: *std.atomic.Value(bool),
    current_gen: *std.atomic.Value(u64),
};

fn rerankTask(ctx: RerankTaskCtx) void {
    defer {
        ctx.allocator.free(ctx.query);
        for (ctx.image_paths) |p| ctx.allocator.free(p);
        ctx.allocator.free(ctx.image_paths);
        ctx.allocator.free(ctx.image_ids);
    }
    log.info("rerank task start: gen={d} query=\"{s}\" n={d}", .{ ctx.generation, ctx.query, ctx.image_ids.len });
    if (ctx.current_gen.load(.acquire) != ctx.generation) {
        log.info("rerank task gen={d} stale, exiting", .{ctx.generation});
        return;
    }

    ctx.init_mutex.lockUncancelable(ctx.io);
    if (ctx.reranker.* == null) {
        log.info("reranker init starting (gen={d})", .{ctx.generation});
        if (mtmd_mod.RerankContext.init(ctx.io, ctx.allocator, ctx.reranker_model, ctx.reranker_mmproj)) |rr| {
            ctx.reranker.* = rr;
            log.info("reranker init done", .{});
        } else |err| {
            log.warn("reranker init: {}", .{err});
        }
    }
    ctx.init_mutex.unlock(ctx.io);
    const reranker = if (ctx.reranker.*) |*rr| rr else {
        log.warn("reranker unavailable, aborting rerank gen={d}", .{ctx.generation});
        return;
    };

    const ScoreEntry = struct { id: u64, score: f32 };
    var scored: std.ArrayList(ScoreEntry) = .empty;
    defer scored.deinit(ctx.allocator);

    for (ctx.image_paths, ctx.image_ids) |path, id| {
        if (ctx.current_gen.load(.acquire) != ctx.generation) return;
        const score = reranker.scoreImageFile(ctx.io, ctx.allocator, ctx.query, RERANK_INSTRUCTION, path) catch 0.0;
        scored.append(ctx.allocator, .{ .id = id, .score = score }) catch break;
    }
    if (ctx.current_gen.load(.acquire) != ctx.generation) return;

    std.sort.pdq(ScoreEntry, scored.items, {}, struct {
        fn lt(_: void, a: ScoreEntry, b: ScoreEntry) bool { return a.score > b.score; }
    }.lt);

    const ids = ctx.allocator.alloc(u64, scored.items.len) catch return;
    for (scored.items, 0..) |s, i| ids[i] = s.id;

    log.info("rerank task done: gen={d} ranked {d} images", .{ ctx.generation, ids.len });
    ctx.result_ids.* = ids;
    ctx.result_gen.* = ctx.generation;
    ctx.done.store(true, .release);
}

// ── Embed task ────────────────────────────────────────────────────────────────

const EmbedTaskCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    query: []const u8,        // owned; freed by task
    mode: image_grid_mod.SearchMode,
    model_path: []const u8,   // borrowed from config
    mmproj_path: []const u8,  // borrowed from config; used for visual VlContext init
    text_pool: *?llama_mod.Pool,
    vl_ctx: *?mtmd_mod.VlContext,
    init_mutex: *std.Io.Mutex,
    generation: u64,
    current_gen: *std.atomic.Value(u64),
    result: *?[]const f32,
    result_gen: *u64,
    done: *std.atomic.Value(bool),
    wakeup_fn: ?*const fn () void,
};

fn embedTask(ctx: EmbedTaskCtx) void {
    defer ctx.allocator.free(ctx.query);
    log.info("embed task start: gen={d} mode={s} query=\"{s}\"", .{ ctx.generation, @tagName(ctx.mode), ctx.query });
    if (ctx.current_gen.load(.acquire) != ctx.generation) {
        log.info("embed task gen={d} stale on entry, exiting", .{ctx.generation});
        return;
    }

    const q_text = std.fmt.allocPrint(ctx.allocator, "search_query: {s}", .{ctx.query}) catch return;
    defer ctx.allocator.free(q_text);

    var embedding: ?[]const f32 = null;
    switch (ctx.mode) {
        .fts => {},
        .semantic, .combined => embed: {
            ctx.init_mutex.lockUncancelable(ctx.io);
            if (ctx.text_pool.* == null) {
                log.info("text pool init starting (gen={d})", .{ctx.generation});
                ctx.text_pool.* = llama_mod.Pool.init(ctx.allocator, .{
                    .embeddings   = true,
                    .pooling_type = 1,
                    .n_ctx        = 2048,
                    .n_batch      = 512,
                    .n_ubatch     = 512,
                    .n_gpu_layers = 999,
                });
                log.info("text pool init done", .{});
            }
            ctx.init_mutex.unlock(ctx.io);
            const tp = if (ctx.text_pool.*) |*p| p else break :embed;
            log.info("loading text model (gen={d})", .{ctx.generation});
            const tc = tp.get(ctx.io, ctx.model_path, 60_000, null) catch |err| {
                log.warn("text pool.get failed: {}", .{err});
                break :embed;
            };
            defer tp.release(tc);
            if (ctx.current_gen.load(.acquire) != ctx.generation) {
                log.info("embed task gen={d} stale after model load", .{ctx.generation});
                break :embed;
            }
            log.info("creating text embedding (gen={d})", .{ctx.generation});
            var chunks = llama_mod.createEmbeddingFromPrompt(ctx.allocator, tc, q_text, 2048) catch |err| {
                log.warn("createEmbeddingFromPrompt failed: {}", .{err});
                break :embed;
            };
            defer {
                for (chunks.items) |e| ctx.allocator.free(e);
                chunks.deinit(ctx.allocator);
            }
            if (chunks.items.len > 0) embedding = chunks.orderedRemove(0);
            log.info("text embedding done: dim={d}", .{if (embedding) |e| e.len else 0});
        },
        .visual => embed: {
            ctx.init_mutex.lockUncancelable(ctx.io);
            if (ctx.vl_ctx.* == null) {
                log.info("vl_ctx init starting (gen={d})", .{ctx.generation});
                if (mtmd_mod.VlContext.init(ctx.io, ctx.allocator, ctx.model_path, ctx.mmproj_path)) |vc| {
                    ctx.vl_ctx.* = vc;
                    log.info("vl_ctx init done", .{});
                } else |err| {
                    log.warn("vl_ctx init: {}", .{err});
                }
            }
            ctx.init_mutex.unlock(ctx.io);
            const vc = if (ctx.vl_ctx.*) |*v| v else {
                log.warn("vl_ctx unavailable, aborting embed gen={d}", .{ctx.generation});
                break :embed;
            };
            log.info("loading vl model context (gen={d})", .{ctx.generation});
            const tc = vc.pool.get(ctx.io, ctx.model_path, 60_000, null) catch |err| {
                log.warn("vl pool.get failed: {}", .{err});
                break :embed;
            };
            defer vc.pool.release(tc);
            if (ctx.current_gen.load(.acquire) != ctx.generation) {
                log.info("embed task gen={d} stale after vl model load", .{ctx.generation});
                break :embed;
            }
            log.info("creating visual text embedding (gen={d})", .{ctx.generation});
            var chunks = llama_mod.createEmbeddingFromPrompt(ctx.allocator, tc, q_text, 2048) catch |err| {
                log.warn("visual createEmbeddingFromPrompt failed: {}", .{err});
                break :embed;
            };
            defer {
                for (chunks.items) |e| ctx.allocator.free(e);
                chunks.deinit(ctx.allocator);
            }
            if (chunks.items.len > 0) embedding = chunks.orderedRemove(0);
            log.info("visual embedding done: dim={d}", .{if (embedding) |e| e.len else 0});
        },
    }

    if (ctx.current_gen.load(.acquire) != ctx.generation) {
        log.info("embed task gen={d} stale after embedding, discarding", .{ctx.generation});
        if (embedding) |e| ctx.allocator.free(e);
        return;
    }
    log.info("embed task gen={d} complete, embedding={s}", .{ ctx.generation, if (embedding != null) "present" else "null" });
    ctx.result.* = embedding;
    ctx.result_gen.* = ctx.generation;
    ctx.done.store(true, .release);
    if (ctx.wakeup_fn) |w| w();
}

// ── SearchState ───────────────────────────────────────────────────────────────

pub const SearchState = struct {
    buf: [256]u8 = std.mem.zeroes([256]u8),
    prev: [256]u8 = std.mem.zeroes([256]u8),
    // Tracks buf from the previous frame to detect actual keystrokes.
    // Only changes to buf (vs last_buf) reset the debounce deadline.
    last_buf: [256]u8 = std.mem.zeroes([256]u8),
    mode: image_grid_mod.SearchMode = .combined,
    text_pool: ?llama_mod.Pool = null,
    vl_ctx: ?mtmd_mod.VlContext = null,
    query_embedding: ?[]const f32 = null,
    reranker: ?mtmd_mod.RerankContext = null,
    rerank_group: std.Io.Group = .init,
    rerank_done: std.atomic.Value(bool) = .init(false),
    rerank_result_ids: ?[]u64 = null,
    rerank_result_gen: u64 = 0,
    generation: std.atomic.Value(u64) = .init(0),

    // Debounce: fire search 300 ms after the last keystroke.
    // Set to 1 to fire on the very next frame (used by mode-button clicks).
    debounce_deadline_ns: i96 = 0,
    // Set by mode-button clicks to bypass the debounce timer entirely.
    force_search: bool = false,

    // Async query embedding
    embed_group: std.Io.Group = .init,
    embed_done: std.atomic.Value(bool) = .init(false),
    embed_generation: std.atomic.Value(u64) = .init(0),
    embed_in_flight: usize = 0,  // tasks spawned since last full drain
    pending_embedding: ?[]const f32 = null,
    pending_embedding_gen: u64 = 0,
    wakeup_fn: ?*const fn () void = null,
    embed_init_mutex: std.Io.Mutex = std.Io.Mutex.init,
    rerank_init_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        if (self.reranker) |*rr| rr.deinit();
        if (self.vl_ctx) |*vc| vc.deinit();
        if (self.text_pool) |*tp| tp.deinit();
        if (self.query_embedding) |emb| gpa.free(emb);
        if (self.rerank_result_ids) |ids| gpa.free(ids);
        if (self.pending_embedding) |emb| gpa.free(emb);
    }

    pub fn awaitRerank(self: *SearchState, io: std.Io) void {
        self.rerank_group.await(io) catch {};
    }

    pub fn awaitEmbed(self: *SearchState, io: std.Io) void {
        // std.Io.Group.await() waits for ONE task at a time (semaphore semantics).
        // Drain exactly as many times as we spawned to avoid leaving tasks untracked.
        while (self.embed_in_flight > 0) {
            self.embed_group.await(io) catch {};
            self.embed_in_flight -= 1;
        }
    }

    pub fn applyResultsIfDone(self: *SearchState, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
        if (!self.rerank_done.load(.acquire)) return;
        self.rerank_done.store(false, .release);
        self.applyRerankResults(allocator, grid);
    }

    fn applyRerankResults(self: *SearchState, allocator: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
        const ids = self.rerank_result_ids orelse return;
        defer {
            allocator.free(ids);
            self.rerank_result_ids = null;
        }
        if (self.rerank_result_gen != self.generation.load(.acquire)) return;

        var pos_map = std.AutoHashMap(u64, usize).init(allocator);
        defer pos_map.deinit();
        for (grid.images.items, 0..) |entry, i| {
            pos_map.put(entry.id, i) catch {};
        }

        var reordered: std.ArrayList(image_grid_mod.ImageEntry) = .empty;
        defer reordered.deinit(allocator);
        reordered.ensureTotalCapacity(allocator, grid.images.items.len) catch return;
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();

        for (ids) |id| {
            if (pos_map.get(id)) |pos| {
                reordered.append(allocator, grid.images.items[pos]) catch {};
                seen.put(id, {}) catch {};
            }
        }
        for (grid.images.items) |entry| {
            if (!seen.contains(entry.id)) {
                reordered.append(allocator, entry) catch {};
            }
        }
        if (reordered.items.len == grid.images.items.len) {
            @memcpy(grid.images.items, reordered.items);
            grid.focused_idx = null;
            grid.selection.clearRetainingCapacity();
        }
    }

    /// Called from the main thread every frame; applies a completed query
    /// embedding to the grid and triggers a reload + optional rerank.
    pub fn applyEmbedIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
        grid: *image_grid_mod.GridState,
        db: *db_mod.VectorDb,
        cfg: *const config_mod.Config,
    ) void {
        if (!self.embed_done.load(.acquire)) return;
        self.embed_done.store(false, .release);
        log.info("applyEmbedIfDone: pending_gen={d} current_gen={d}", .{ self.pending_embedding_gen, self.embed_generation.load(.acquire) });

        if (self.query_embedding) |old| allocator.free(old);
        self.query_embedding = null;

        if (self.pending_embedding_gen == self.embed_generation.load(.acquire)) {
            self.query_embedding = self.pending_embedding;
            self.pending_embedding = null;
        } else {
            log.info("applyEmbedIfDone: discarding stale embedding", .{});
            if (self.pending_embedding) |e| allocator.free(e);
            self.pending_embedding = null;
        }

        log.info("applyEmbedIfDone: reloading grid, embedding={s}", .{if (self.query_embedding != null) "present" else "null"});
        grid.query_embedding = self.query_embedding;
        grid.reloadImages(db) catch |err| {
            log.warn("reloadImages failed: {}", .{err});
        };

        const q = std.mem.sliceTo(&self.buf, 0);
        if (q.len > 0) self.maybeSpawnRerank(grid, q, cfg);
    }

    pub fn maybeSpawnRerank(self: *SearchState, grid: *image_grid_mod.GridState, query: []const u8, cfg: *const config_mod.Config) void {
        const init = dvui.App.main_init orelse return;
        const reranker_model = cfg.reranker_model_path orelse {
            log.info("maybeSpawnRerank: no reranker_model_path, skipping", .{});
            return;
        };
        const reranker_mmproj = cfg.reranker_mmproj_path orelse {
            log.info("maybeSpawnRerank: no reranker_mmproj_path, skipping", .{});
            return;
        };
        if (self.mode == .fts) return;
        if (grid.images.items.len == 0) {
            log.info("maybeSpawnRerank: grid empty, skipping", .{});
            return;
        }
        log.info("maybeSpawnRerank: spawning rerank gen query=\"{s}\" n={d}", .{ query, grid.images.items.len });

        const gen = self.generation.fetchAdd(1, .acq_rel) + 1;
        self.rerank_done.store(false, .release);
        if (self.rerank_result_ids) |ids| { init.gpa.free(ids); self.rerank_result_ids = null; }

        const top_k = @min(grid.images.items.len, cfg.rerank_top_k);
        var image_paths = init.gpa.alloc([]u8, top_k) catch return;
        const image_ids = init.gpa.alloc(u64, top_k) catch { init.gpa.free(image_paths); return; };
        var n: usize = 0;
        for (grid.images.items[0..top_k]) |entry| {
            image_paths[n] = init.gpa.dupe(u8, entry.path) catch break;
            image_ids[n] = entry.id;
            n += 1;
        }
        if (n < top_k) {
            for (image_paths[0..n]) |p| init.gpa.free(p);
            init.gpa.free(image_paths);
            init.gpa.free(image_ids);
            return;
        }

        const query_copy = init.gpa.dupe(u8, query) catch {
            for (image_paths) |p| init.gpa.free(p);
            init.gpa.free(image_paths);
            init.gpa.free(image_ids);
            return;
        };

        const ctx = RerankTaskCtx{
            .io = init.io,
            .allocator = init.gpa,
            .query = query_copy,
            .image_paths = image_paths,
            .image_ids = image_ids,
            .generation = gen,
            .reranker = &self.reranker,
            .reranker_model = reranker_model,
            .reranker_mmproj = reranker_mmproj,
            .init_mutex = &self.rerank_init_mutex,
            .result_ids = &self.rerank_result_ids,
            .result_gen = &self.rerank_result_gen,
            .done = &self.rerank_done,
            .current_gen = &self.generation,
        };
        self.rerank_group.concurrent(init.io, rerankTask, .{ctx}) catch |err| {
            log.warn("spawn rerank task: {}", .{err});
            init.gpa.free(query_copy);
            for (image_paths) |p| init.gpa.free(p);
            init.gpa.free(image_paths);
            init.gpa.free(image_ids);
        };
    }

    /// Spawn a background task to compute a query embedding.
    /// Returns immediately; the result is applied to the grid via applyEmbedIfDone().
    pub fn spawnEmbedQuery(
        self: *SearchState,
        io: std.Io,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: image_grid_mod.SearchMode,
        cfg: *const config_mod.Config,
    ) !void {
        if (mode == .fts) return;
        const model_path = cfg.embedding_model_path orelse {
            log.warn("spawnEmbedQuery: no embedding_model_path configured", .{});
            return error.NoModelPath;
        };
        const mmproj_path = cfg.embedding_mmproj_path orelse "";
        log.info("spawnEmbedQuery: mode={s} query=\"{s}\" model={s}", .{ @tagName(mode), query, model_path });

        const gen = self.embed_generation.fetchAdd(1, .acq_rel) + 1;
        self.embed_done.store(false, .release);
        if (self.pending_embedding) |e| {
            allocator.free(e);
            self.pending_embedding = null;
        }

        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);

        const task_ctx = EmbedTaskCtx{
            .io = io,
            .allocator = allocator,
            .query = query_copy,
            .mode = mode,
            .model_path = model_path,
            .mmproj_path = mmproj_path,
            .text_pool = &self.text_pool,
            .vl_ctx = &self.vl_ctx,
            .init_mutex = &self.embed_init_mutex,
            .generation = gen,
            .current_gen = &self.embed_generation,
            .result = &self.pending_embedding,
            .result_gen = &self.pending_embedding_gen,
            .done = &self.embed_done,
            .wakeup_fn = self.wakeup_fn,
        };
        self.embed_group.concurrent(io, embedTask, .{task_ctx}) catch |err| {
            log.warn("embed_group.concurrent failed: {}", .{err});
            allocator.free(query_copy);
            return err;
        };
        self.embed_in_flight += 1;
        log.info("embed task spawned: gen={d} in_flight={d}", .{ task_ctx.generation, self.embed_in_flight });
    }
};
