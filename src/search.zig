const std = @import("std");
const embedder_mod = @import("embedder.zig");
const image_grid_mod = @import("image_grid.zig");
const db_mod = @import("db.zig");

const log = std.log.scoped(.search);

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

    // The grid load generation the latest search requested; the search is
    // still loading until the grid has applied it.
    search_gen: u64 = 0,

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        self.query_embeddings.free(gpa);
        self.pending_embeddings.free(gpa);
    }

    pub fn isSearchLoading(self: *const SearchState, grid: ?*const image_grid_mod.GridState) bool {
        if (self.embed_pending) return true;
        const g = grid orelse return false;
        return g.applied_gen < self.search_gen;
    }

    pub fn awaitEmbed(self: *SearchState, io: std.Io) void {
        // std.Io.Group.await() waits for ONE task at a time (semaphore semantics).
        // Drain exactly as many times as we spawned to avoid leaving tasks untracked.
        while (self.embed_in_flight > 0) {
            self.embed_group.await(io) catch {};
            self.embed_in_flight -= 1;
        }
    }

    /// Called from the main thread every frame; applies a completed query
    /// embedding to the grid and runs the search.
    pub fn applyEmbedIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
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

        log.info("applyEmbedIfDone: running search, embeddings={s}", .{if (self.query_embeddings.any()) "present" else "null"});
        grid.query_embeddings = self.query_embeddings;
        // The user left the library while the embedding computed: keep it for
        // when they return rather than pulling them back.
        if (grid.view_mode != .library) return;
        self.run(grid, db);
    }

    /// Show the results of the grid's current search parameters. Searches are
    /// library-view loads, so they go through the grid's own background load
    /// and supersede (or are superseded by) any other view change.
    pub fn run(self: *SearchState, grid: *image_grid_mod.GridState, db: *db_mod.VectorDb) void {
        grid.view_mode = .library;
        grid.reloadImages(db) catch |err| {
            log.warn("search load: {}", .{err});
            return;
        };
        self.search_gen = grid.load_gen.load(.acquire);
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
