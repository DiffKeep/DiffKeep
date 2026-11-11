const std = @import("std");
const embedder_mod = @import("embedder.zig");
const image_grid_mod = @import("image_grid.zig");
const bg = @import("bg.zig");

const log = std.log.scoped(.search);

// ── Embed task ────────────────────────────────────────────────────────────────

const EmbedLoad = bg.Latest(image_grid_mod.QueryEmbeddings, image_grid_mod.QueryEmbeddings.free);

/// Embed `query` (owned; freed here) in each vector space `mode` searches.
fn embedTask(
    ticket: EmbedLoad.Ticket,
    allocator: std.mem.Allocator,
    query: []const u8,
    mode: image_grid_mod.SearchMode,
    embedder: *embedder_mod.Embedder,
) ?image_grid_mod.QueryEmbeddings {
    defer allocator.free(query);
    if (!ticket.current()) return null; // the user typed on

    // Each vector space needs a query embedding from its own encoder;
    // combined mode needs both.
    var embeddings: image_grid_mod.QueryEmbeddings = .{};
    if (mode == .semantic or mode == .combined) {
        embeddings.prompt = embedder.embedPromptQuery(allocator, query) catch |err| blk: {
            log.warn("embedPromptQuery failed: {}", .{err});
            break :blk null;
        };
    }
    if (mode == .visual or mode == .combined) {
        embeddings.visual = embedder.embedQueryForVisual(allocator, query) catch |err| blk: {
            log.warn("embedQueryForVisual failed: {}", .{err});
            break :blk null;
        };
    }
    return embeddings;
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

    /// The query embedding: a new query supersedes the one still embedding.
    embed: EmbedLoad = .{},
    wakeup_fn: ?*const fn () void = null,

    // The grid load generation the latest search requested; the search is
    // still loading until the grid has applied it.
    search_gen: u64 = 0,

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        self.embed.deinit();
        self.query_embeddings.free(gpa);
    }

    pub fn isSearchLoading(self: *const SearchState, grid: ?*const image_grid_mod.GridState) bool {
        if (self.embed.pending()) return true;
        const g = grid orelse return false;
        return g.appliedGen() < self.search_gen;
    }

    /// Wait for every query-embed task to finish (they hold the embedder).
    pub fn awaitEmbed(self: *SearchState) void {
        self.embed.awaitAll();
    }

    /// Start a new query-embed generation, superseding (and freeing the
    /// result of) any earlier one. Main thread. Returns the new generation.
    /// (`spawnEmbedQuery` does this; tests use it to stand in for a task.)
    pub fn startEmbedGeneration(self: *SearchState, io: std.Io, gpa: std.mem.Allocator) u64 {
        return self.embed.begin(io, gpa);
    }

    /// Supersede any query embedding in flight without starting a new one
    /// (the user switched to a text search or cleared the box). Main thread.
    pub fn cancelEmbed(self: *SearchState) void {
        self.embed.cancel();
    }

    /// Hand a finished query embedding to the main thread. Returns false (and
    /// frees `embeddings`) when `gen` was superseded.
    pub fn deliverEmbedding(self: *SearchState, gen: u64, embeddings: image_grid_mod.QueryEmbeddings) bool {
        return self.embed.deliver(gen, embeddings);
    }

    /// Called from the main thread every frame; applies a delivered query
    /// embedding to the grid and runs the search.
    pub fn applyEmbedIfDone(
        self: *SearchState,
        allocator: std.mem.Allocator,
        grid: *image_grid_mod.GridState,
    ) void {
        const outcome = self.embed.take() orelse return;
        const taken = outcome.value orelse return;
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
        grid.reloadImages();
        self.search_gen = grid.requestedGen();
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
                self.cancelEmbed();
                if (q.len == 0) grid.clearSearchQuery() else grid.setSearchQuery(q) catch |err| {
                    log.warn("search query: {}", .{err});
                    grid.showLoadError(err);
                    return;
                };
                self.run(grid);
            },
            .semantic, .visual, .combined => {
                grid.clearSearchQuery();
                if (q.len == 0) {
                    // Empty query: show all/library images without embedding.
                    self.cancelEmbed();
                    self.run(grid);
                    return;
                }
                // Keep showing the current results while the embedding is
                // computed; applyEmbedIfDone runs the search when it lands.
                self.spawnEmbedQuery(io, gpa, q, self.mode) catch |err| {
                    log.warn("search embed spawn: {}", .{err});
                    self.cancelEmbed();
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
        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);
        self.embed.wakeup_fn = self.wakeup_fn;
        _ = try self.embed.start(io, allocator, embedTask, .{ allocator, query_copy, mode, embedder });
    }
};
