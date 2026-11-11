const std = @import("std");
const embedder_mod = @import("embedder.zig");
const vq = @import("view_query.zig");
const bg = @import("bg.zig");

const log = std.log.scoped(.search);

// ── Embed task ────────────────────────────────────────────────────────────────

const EmbedLoad = bg.Latest(vq.QueryEmbeddings, vq.QueryEmbeddings.free);

/// Embed `query` (owned; freed here) in each vector space `mode` searches.
fn embedTask(
    ticket: EmbedLoad.Ticket,
    allocator: std.mem.Allocator,
    query: []const u8,
    mode: vq.SearchMode,
    embedder: *embedder_mod.Embedder,
) ?vq.QueryEmbeddings {
    defer allocator.free(query);
    if (!ticket.current()) return null; // the user typed on

    // Each vector space needs a query embedding from its own encoder;
    // combined mode needs both.
    var embeddings: vq.QueryEmbeddings = .{};
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
    mode: vq.SearchMode = .fts,
    embedder: ?*embedder_mod.Embedder = null,
    query_embeddings: vq.QueryEmbeddings = .{},

    // Debounce: fire search 300 ms after the last keystroke.
    // Set to 1 to fire on the very next frame (used by mode-button clicks).
    debounce_deadline_ns: i96 = 0,
    // Set by mode-button clicks to bypass the debounce timer entirely.
    force_search: bool = false,

    /// The query embedding: a new query supersedes the one still embedding.
    embed: EmbedLoad = .{},
    wakeup_fn: ?*const fn () void = null,

    // The view load generation the latest search requested; the search is
    // still loading until the view has applied it (`noteShown`).
    search_gen: u64 = 0,

    pub fn deinit(self: *SearchState, gpa: std.mem.Allocator) void {
        self.embed.deinit();
        self.query_embeddings.free(gpa);
    }

    /// Whether the latest search is still embedding, or its view load
    /// (generation `search_gen`) hasn't been applied: `applied_gen` is the
    /// view's applied generation, null when there is no view.
    pub fn isSearchLoading(self: *const SearchState, applied_gen: ?u64) bool {
        if (self.embed.pending()) return true;
        const g = applied_gen orelse return false;
        return g < self.search_gen;
    }

    /// The view started load `gen` to show this search's results.
    pub fn noteShown(self: *SearchState, gen: u64) void {
        self.search_gen = gen;
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
    pub fn deliverEmbedding(self: *SearchState, gen: u64, embeddings: vq.QueryEmbeddings) bool {
        return self.embed.deliver(gen, embeddings);
    }

    /// A query embedding that landed since the last call, as the search to
    /// show (borrowing this state's embeddings until the next one). Main
    /// thread, every frame.
    pub fn takeEmbedded(self: *SearchState, allocator: std.mem.Allocator) ?vq.Search {
        const outcome = self.embed.take() orelse return null;
        const taken = outcome.value orelse return null;
        self.query_embeddings.free(allocator);
        self.query_embeddings = taken;
        return .{ .mode = self.mode, .embeddings = self.query_embeddings };
    }

    /// The search for the current text box and mode (debounce elapsed or a
    /// mode button was clicked), to show now; null while its query embedding
    /// is computed (`takeEmbedded` hands it over then; meanwhile the current
    /// results stay). Borrows the text box. Main thread.
    pub fn fire(self: *SearchState, io: std.Io, gpa: std.mem.Allocator) ?vq.Search {
        @memcpy(&self.prev, &self.buf);
        const q = std.mem.sliceTo(&self.buf, 0);
        if (self.mode == .fts or q.len == 0) {
            // Nothing to embed: a text search, or an empty box (everything).
            self.cancelEmbed();
            return .{ .mode = self.mode, .text = if (self.mode == .fts and q.len > 0) q else null };
        }
        self.spawnEmbedQuery(io, gpa, q, self.mode) catch |err| {
            log.warn("search embed spawn: {}", .{err});
            self.cancelEmbed();
        };
        return null;
    }

    /// Spawn a background task to compute a query embedding.
    /// Returns immediately; the result is handed over by `takeEmbedded`.
    pub fn spawnEmbedQuery(
        self: *SearchState,
        io: std.Io,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: vq.SearchMode,
    ) !void {
        if (mode == .fts) return;
        const embedder = self.embedder orelse return error.NoEmbedder;
        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);
        self.embed.wakeup_fn = self.wakeup_fn;
        _ = try self.embed.start(io, allocator, embedTask, .{ allocator, query_copy, mode, embedder });
    }
};
