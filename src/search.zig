const std = @import("std");
const embedder_mod = @import("embedder.zig");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");

const log = std.log.scoped(.search);

// ── FTS5 sanitization ─────────────────────────────────────────────────────────

/// Strip FTS5 syntax characters that cause parse errors in user-supplied queries.
/// Returns null if the result is empty (query was all operators/whitespace).
/// Caller owns the returned slice.
fn sanitizeFtsQuery(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, raw.len);
    for (raw) |c| {
        buf.appendAssumeCapacity(switch (c) {
            '(', ')', '"', '*', '^' => ' ',
            else => c,
        });
    }
    const trimmed = std.mem.trim(u8, buf.items, " \t\n\r");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

// ── Query task ────────────────────────────────────────────────────────────────

const QueryTaskCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *db_mod.VectorDb,
    mode: image_grid_mod.SearchMode,
    fts_query: ?[]u8,           // owned; freed by task
    embeddings: image_grid_mod.QueryEmbeddings, // owned; freed by task
    semantic_min_similarity: f32,
    visual_min_similarity: f32,
    filter_library_id: ?u64,
    filter_folder_path: ?[]u8,  // owned; freed by task
    filters: []db_mod.ActiveFilter, // owned (each .value duped); freed by task
    generation: u64,
    current_gen: *std.atomic.Value(u64),
    result: *?image_grid_mod.LoadedView,
    result_gen: *u64,
    done: *std.atomic.Value(bool),
    wakeup_fn: ?*const fn () void,
};

fn runQuery(ctx: QueryTaskCtx) !image_grid_mod.LoadedView {
    return image_grid_mod.loadView(ctx.db, ctx.allocator, .{
        .view_mode = .library,
        .search_mode = ctx.mode,
        .search_query = ctx.fts_query,
        .embeddings = ctx.embeddings,
        .semantic_min_similarity = ctx.semantic_min_similarity,
        .visual_min_similarity = ctx.visual_min_similarity,
        .filter_library_id = ctx.filter_library_id,
        .filter_folder_path = ctx.filter_folder_path,
        .filters = ctx.filters,
    });
}

fn queryTask(ctx: QueryTaskCtx) void {
    var embeddings = ctx.embeddings;
    defer {
        if (ctx.fts_query) |q| ctx.allocator.free(q);
        embeddings.free(ctx.allocator);
        if (ctx.filter_folder_path) |p| ctx.allocator.free(p);
        for (ctx.filters) |f| ctx.allocator.free(f.value);
        ctx.allocator.free(ctx.filters);
    }
    if (ctx.current_gen.load(.acquire) != ctx.generation) return;

    if (runQuery(ctx)) |view| {
        if (ctx.current_gen.load(.acquire) != ctx.generation) {
            view.deinit(ctx.allocator);
            return;
        }
        ctx.result.* = view;
    } else |err| {
        log.warn("queryTask gen={d} failed: {}", .{ ctx.generation, err });
        ctx.result.* = null;
    }
    ctx.result_gen.* = ctx.generation;
    ctx.done.store(true, .release);
    if (ctx.wakeup_fn) |w| w();
}

// ── Embed task ────────────────────────────────────────────────────────────────

const EmbedTaskCtx = struct {
    allocator: std.mem.Allocator,
    query: []const u8,        // owned; freed by task
    mode: image_grid_mod.SearchMode,
    embedder: *embedder_mod.Embedder,
    generation: u64,
    current_gen: *std.atomic.Value(u64),
    result: *image_grid_mod.QueryEmbeddings,
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

    // Each vector space needs a query embedding from its own encoder;
    // combined mode needs both.
    var embeddings: image_grid_mod.QueryEmbeddings = .{};
    if (ctx.mode == .semantic or ctx.mode == .combined) {
        embeddings.prompt = ctx.embedder.embedPromptQuery(ctx.allocator, ctx.query) catch |err| blk: {
            log.warn("embedPromptQuery failed: {}", .{err});
            break :blk null;
        };
    }
    if (ctx.mode == .visual or ctx.mode == .combined) {
        embeddings.visual = ctx.embedder.embedQueryForVisual(ctx.allocator, ctx.query) catch |err| blk: {
            log.warn("embedQueryForVisual failed: {}", .{err});
            break :blk null;
        };
    }

    if (ctx.current_gen.load(.acquire) != ctx.generation) {
        log.info("embed task gen={d} stale after embedding, discarding", .{ctx.generation});
        embeddings.free(ctx.allocator);
        return;
    }
    log.info("embed task gen={d} complete: prompt={s} visual={s}", .{
        ctx.generation,
        if (embeddings.prompt != null) "present" else "null",
        if (embeddings.visual != null) "present" else "null",
    });
    ctx.result.* = embeddings;
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
    mode: image_grid_mod.SearchMode = .fts,
    embedder: ?*embedder_mod.Embedder = null,
    query_embeddings: image_grid_mod.QueryEmbeddings = .{},

    // Debounce: fire search 300 ms after the last keystroke.
    // Set to 1 to fire on the very next frame (used by mode-button clicks).
    debounce_deadline_ns: i96 = 0,
    // Set by mode-button clicks to bypass the debounce timer entirely.
    force_search: bool = false,

    // Async embedding generation
    embed_group: std.Io.Group = .init,
    embed_done: std.atomic.Value(bool) = .init(false),
    embed_generation: std.atomic.Value(u64) = .init(0),
    embed_in_flight: usize = 0,  // tasks spawned since last full drain
    embed_pending: bool = false,  // true while an embed task is in flight
    pending_embeddings: image_grid_mod.QueryEmbeddings = .{},
    pending_embeddings_gen: u64 = 0,
    wakeup_fn: ?*const fn () void = null,

    // Async DB query (runs after embed for vector modes, immediately for FTS)
    query_group: std.Io.Group = .init,
    query_done: std.atomic.Value(bool) = .init(false),
    query_result: ?image_grid_mod.LoadedView = null,
    query_result_gen: u64 = 0,
    query_generation: std.atomic.Value(u64) = .init(0),
    query_in_flight: usize = 0,
    query_pending: bool = false,  // true while a query task is in flight

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        self.query_embeddings.free(gpa);
        self.pending_embeddings.free(gpa);
        if (self.query_result) |r| r.deinit(gpa);
    }

    pub fn isSearchLoading(self: *const SearchState) bool {
        return self.embed_pending or self.query_pending;
    }

    pub fn awaitEmbed(self: *SearchState, io: std.Io) void {
        // std.Io.Group.await() waits for ONE task at a time (semaphore semantics).
        // Drain exactly as many times as we spawned to avoid leaving tasks untracked.
        while (self.embed_in_flight > 0) {
            self.embed_group.await(io) catch {};
            self.embed_in_flight -= 1;
        }
    }

    pub fn awaitQuery(self: *SearchState, io: std.Io) void {
        while (self.query_in_flight > 0) {
            self.query_group.await(io) catch {};
            self.query_in_flight -= 1;
        }
    }

    /// Called from the main thread every frame; applies a completed query
    /// embedding to the grid and spawns the DB query task.
    pub fn applyEmbedIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
        io: std.Io,
        grid: *image_grid_mod.GridState,
        db: *db_mod.VectorDb,
    ) void {
        if (!self.embed_done.load(.acquire)) return;
        self.embed_done.store(false, .release);
        self.embed_pending = false;
        log.info("applyEmbedIfDone: pending_gen={d} current_gen={d}", .{ self.pending_embeddings_gen, self.embed_generation.load(.acquire) });

        self.query_embeddings.free(allocator);

        if (self.pending_embeddings_gen == self.embed_generation.load(.acquire)) {
            self.query_embeddings = self.pending_embeddings;
            self.pending_embeddings = .{};
        } else {
            log.info("applyEmbedIfDone: discarding stale embeddings", .{});
            self.pending_embeddings.free(allocator);
        }

        log.info("applyEmbedIfDone: spawning query task, embeddings={s}", .{if (self.query_embeddings.any()) "present" else "null"});
        grid.query_embeddings = self.query_embeddings;
        self.spawnQueryTask(io, allocator, db, grid) catch |err| {
            log.warn("applyEmbedIfDone: spawnQueryTask failed: {}", .{err});
        };
    }

    /// Spawn a background task that runs the DB search query.
    /// Snapshots all parameters from `grid`; keeps the old results visible
    /// until applyQueryIfDone() swaps them in.
    pub fn spawnQueryTask(
        self: *SearchState,
        io: std.Io,
        allocator: std.mem.Allocator,
        db: *db_mod.VectorDb,
        grid: *const image_grid_mod.GridState,
    ) !void {
        const fts_query: ?[]u8 = if (grid.search_query) |q| blk: {
            break :blk try sanitizeFtsQuery(allocator, q) orelse null;
        } else null;
        errdefer if (fts_query) |q| allocator.free(q);

        const folder_path: ?[]u8 = if (grid.filter_folder_path) |p|
            try allocator.dupe(u8, p)
        else null;
        errdefer if (folder_path) |p| allocator.free(p);

        const filters_copy = try allocator.alloc(db_mod.ActiveFilter, grid.filters.len);
        errdefer allocator.free(filters_copy);
        var n: usize = 0;
        errdefer for (filters_copy[0..n]) |f| allocator.free(f.value);
        for (grid.filters) |f| {
            filters_copy[n] = .{ .column = f.column, .value = try allocator.dupe(u8, f.value) };
            n += 1;
        }

        var embeddings: image_grid_mod.QueryEmbeddings = .{};
        errdefer embeddings.free(allocator);
        if (grid.query_embeddings.prompt) |e| embeddings.prompt = try allocator.dupe(f32, e);
        if (grid.query_embeddings.visual) |e| embeddings.visual = try allocator.dupe(f32, e);

        const gen = self.query_generation.fetchAdd(1, .acq_rel) + 1;
        self.query_done.store(false, .release);
        if (self.query_result) |r| r.deinit(allocator);
        self.query_result = null;
        self.query_pending = true;

        const ctx = QueryTaskCtx{
            .io = io,
            .allocator = allocator,
            .db = db,
            .mode = grid.search_mode,
            .fts_query = fts_query,
            .embeddings = embeddings,
            .semantic_min_similarity = grid.semantic_min_similarity,
            .visual_min_similarity = grid.visual_min_similarity,
            .filter_library_id = grid.filter_library_id,
            .filter_folder_path = folder_path,
            .filters = filters_copy,
            .generation = gen,
            .current_gen = &self.query_generation,
            .result = &self.query_result,
            .result_gen = &self.query_result_gen,
            .done = &self.query_done,
            .wakeup_fn = self.wakeup_fn,
        };
        try self.query_group.concurrent(io, queryTask, .{ctx});
        self.query_in_flight += 1;
        log.info("query task spawned: gen={d} mode={s} fts={s} embed={s}", .{
            gen, @tagName(grid.search_mode),
            if (fts_query != null) "yes" else "no",
            if (grid.query_embeddings.any()) "yes" else "no",
        });
    }

    /// Apply a completed background query result to the grid.
    pub fn applyQueryIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
        grid: *image_grid_mod.GridState,
    ) void {
        if (!self.query_done.load(.acquire)) return;
        self.query_done.store(false, .release);
        self.query_pending = false;

        const result = self.query_result;
        self.query_result = null;

        if (self.query_result_gen != self.query_generation.load(.acquire)) {
            if (result) |r| r.deinit(allocator);
            return;
        }

        if (result) |r| grid.replaceImages(r, .{});
        // null result = query failed; keep stale grid intact.
    }

    /// Spawn a background task to compute a query embedding.
    /// Returns immediately; the result is applied to the grid via applyEmbedIfDone().
    pub fn spawnEmbedQuery(
        self: *SearchState,
        io: std.Io,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: image_grid_mod.SearchMode,
    ) !void {
        if (mode == .fts) return;
        const embedder = self.embedder orelse {
            log.warn("spawnEmbedQuery: no embedder configured", .{});
            return error.NoEmbedder;
        };

        const gen = self.embed_generation.fetchAdd(1, .acq_rel) + 1;
        self.embed_done.store(false, .release);
        self.embed_pending = true;
        self.pending_embeddings.free(allocator);

        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);

        const task_ctx = EmbedTaskCtx{
            .allocator = allocator,
            .query = query_copy,
            .mode = mode,
            .embedder = embedder,
            .generation = gen,
            .current_gen = &self.embed_generation,
            .result = &self.pending_embeddings,
            .result_gen = &self.pending_embeddings_gen,
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
