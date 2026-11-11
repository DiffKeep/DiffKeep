const std = @import("std");
const embedder_mod = @import("embedder.zig");
const image_grid_mod = @import("image_grid.zig");

const log = std.log.scoped(.search);

// ── Embed task ────────────────────────────────────────────────────────────────

const EmbedTaskCtx = struct {
    allocator: std.mem.Allocator,
    query: []const u8, // owned; freed by task
    mode: image_grid_mod.SearchMode,
    embedder: *embedder_mod.Embedder,
    generation: u64,
    state: *SearchState,
};

fn embedTask(ctx: EmbedTaskCtx) void {
    defer ctx.allocator.free(ctx.query);
    if (ctx.state.embed_generation.load(.acquire) != ctx.generation) return; // superseded

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
    if (ctx.state.deliverEmbedding(ctx.generation, embeddings)) {
        if (ctx.state.wakeup_fn) |w| w();
    }
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

    // Async query embedding. Only the task of the latest generation may
    // deliver; delivery and the generation bump both happen under
    // `result_mutex`, so a superseded task can never store (or race the main
    // thread freeing) a result.
    embed_group: std.Io.Group = .init,
    embed_generation: std.atomic.Value(u64) = .init(0),
    embed_pending: bool = false, // main thread: the latest generation hasn't delivered
    result_mutex: std.Io.Mutex = .init,
    result: ?image_grid_mod.QueryEmbeddings = null, // guarded by result_mutex
    /// Allocator of a delivered-but-unapplied result (the spawn's allocator).
    result_alloc: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    wakeup_fn: ?*const fn () void = null,

    // The grid load generation the latest search requested; the search is
    // still loading until the grid has applied it.
    search_gen: u64 = 0,

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        self.query_embeddings.free(gpa);
        if (self.result) |*r| r.free(gpa);
        self.result = null;
    }

    pub fn isSearchLoading(self: *const SearchState, grid: ?*const image_grid_mod.GridState) bool {
        if (self.embed_pending) return true;
        const g = grid orelse return false;
        return g.applied_gen < self.search_gen;
    }

    /// Wait for every query-embed task to finish (they hold the embedder).
    pub fn awaitEmbed(self: *SearchState, io: std.Io) void {
        self.embed_group.await(io) catch {};
    }

    fn lock(self: *SearchState) void {
        if (self.io) |io| self.result_mutex.lockUncancelable(io);
    }
    fn unlock(self: *SearchState) void {
        if (self.io) |io| self.result_mutex.unlock(io);
    }

    /// Start a new query-embed generation, superseding (and freeing the
    /// result of) any earlier one. Main thread. Returns the new generation.
    pub fn startEmbedGeneration(self: *SearchState, io: std.Io, gpa: std.mem.Allocator) u64 {
        self.io = io;
        self.lock();
        self.result_alloc = gpa;
        defer self.unlock();
        const gen = self.embed_generation.fetchAdd(1, .acq_rel) + 1;
        if (self.result) |*r| r.free(gpa);
        self.result = null;
        self.embed_pending = true;
        return gen;
    }

    /// Supersede any query embedding in flight without starting a new one
    /// (the user switched to a text search or cleared the box). Main thread.
    pub fn cancelEmbed(self: *SearchState, io: std.Io, gpa: std.mem.Allocator) void {
        _ = self.startEmbedGeneration(io, gpa);
        self.embed_pending = false;
    }

    /// Hand a finished query embedding to the main thread. Called by the embed
    /// task; returns false (and frees `embeddings`) when `gen` was superseded.
    pub fn deliverEmbedding(self: *SearchState, gen: u64, embeddings: image_grid_mod.QueryEmbeddings) bool {
        self.lock();
        const a = self.result_alloc.?; // set by the startEmbedGeneration that made `gen`
        defer self.unlock();
        var e = embeddings;
        if (self.embed_generation.load(.acquire) != gen) {
            e.free(a);
            return false;
        }
        if (self.result) |*r| r.free(a);
        self.result = e;
        return true;
    }

    /// Called from the main thread every frame; applies a delivered query
    /// embedding to the grid and runs the search.
    pub fn applyEmbedIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
        grid: *image_grid_mod.GridState,
    ) void {
        const taken = blk: {
            self.lock();
            defer self.unlock();
            const r = self.result orelse return;
            self.result = null;
            break :blk r;
        };
        self.embed_pending = false;
        self.query_embeddings.free(allocator);
        self.query_embeddings = taken;
        grid.query_embeddings = self.query_embeddings;
        // The user left the library while the embedding computed: keep it for
        // when they return rather than pulling them back.
        if (grid.view_mode != .library) return;
        self.run(grid);
    }

    /// Show the results of the grid's current search parameters. Searches are
    /// library-view loads, so they go through the grid's own background load
    /// and supersede (or are superseded by) any other view change.
    pub fn run(self: *SearchState, grid: *image_grid_mod.GridState) void {
        grid.view_mode = .library;
        grid.reloadImages() catch |err| {
            log.warn("search load: {}", .{err});
            return;
        };
        self.search_gen = grid.load_gen.load(.acquire);
    }

    /// Run the search for the current text box and mode (debounce elapsed or a
    /// mode button was clicked). Main thread.
    pub fn fire(self: *SearchState, io: std.Io, gpa: std.mem.Allocator, grid: *image_grid_mod.GridState) void {
        @memcpy(&self.prev, &self.buf);
        const q = std.mem.sliceTo(&self.buf, 0);
        grid.search_mode = self.mode;
        grid.query_embeddings = .{};
        self.query_embeddings.free(gpa);
        switch (self.mode) {
            .fts => {
                self.cancelEmbed(io, gpa);
                grid.setSearchQuery(if (q.len > 0) q else null) catch |err| {
                    log.warn("search query: {}", .{err});
                    return;
                };
                self.run(grid);
            },
            .semantic, .visual, .combined => {
                grid.setSearchQuery(null) catch {};
                if (q.len == 0) {
                    // Empty query: show all/library images without embedding.
                    self.cancelEmbed(io, gpa);
                    self.run(grid);
                    return;
                }
                // Keep showing the current results while the embedding is
                // computed; applyEmbedIfDone runs the search when it lands.
                self.spawnEmbedQuery(io, gpa, q, self.mode) catch |err| {
                    log.warn("search embed spawn: {}", .{err});
                    self.cancelEmbed(io, gpa);
                };
            },
        }
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
        const embedder = self.embedder orelse return error.NoEmbedder;
        const gen = self.startEmbedGeneration(io, allocator);

        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);
        try self.embed_group.concurrent(io, embedTask, .{EmbedTaskCtx{
            .allocator = allocator,
            .query = query_copy,
            .mode = mode,
            .embedder = embedder,
            .generation = gen,
            .state = self,
        }});
    }
};
