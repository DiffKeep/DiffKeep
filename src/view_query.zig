//! What a grid view shows and how it is loaded: the view/search/sort types,
//! the image list entries, and the queries behind them. No UI: services
//! (search, file operations, tests) use this without the grid widget.

const std = @import("std");
const db_mod = @import("db.zig");

pub const SortMode = enum { date, name, random };
pub const SortDir = enum { asc, desc };
pub const ViewMode = enum { library, trash, duplicates, favorites };
pub const SearchMode = enum { fts, semantic, visual, combined };

/// One query embedding per vector space: `prompt` targets
/// positive_prompt_embeddings (EmbeddingGemma), `visual` targets image_embeddings
/// (SigLIP2 text encoder). Combined mode uses both; the spaces are not
/// interchangeable.
pub const QueryEmbeddings = struct {
    prompt: ?[]const f32 = null,
    visual: ?[]const f32 = null,

    pub fn any(self: QueryEmbeddings) bool {
        return self.prompt != null or self.visual != null;
    }

    pub fn free(self: *QueryEmbeddings, allocator: std.mem.Allocator) void {
        if (self.prompt) |e| allocator.free(e);
        if (self.visual) |e| allocator.free(e);
        self.* = .{};
    }
};

/// A search to show: a library-view load with these parameters. Borrows its
/// text and embeddings; whoever shows it copies them.
pub const Search = struct {
    mode: SearchMode,
    /// Full-text query; null for none.
    text: ?[]const u8 = null,
    embeddings: QueryEmbeddings = .{},
};

pub const ImageEntry = struct {
    id: u64,
    path: []const u8,     // heap-allocated, owned by GridState.images
    filename: []const u8, // slice into path (basename), not separately allocated
    mtime: ?i64,
    trashed_at: ?i64 = null,
    trash_name: ?[]const u8 = null, // heap-allocated, only set in trash view
    favorite: bool = false,
    // Playback classification. Defaults to a plain (static) image; set from the
    // DB via applyMediaTypes. Distinguishes animated webp/gif from static ones,
    // which extension alone cannot.
    media_type: db_mod.VectorDb.MediaType = .image,
};

// ── View loading ──────────────────────────────────────────────────────────────

/// What a grid view shows. Borrows its strings; `ViewQuery.dupe` makes an owned
/// copy for a background load.
pub const ViewQuery = struct {
    view_mode: ViewMode = .library,
    search_mode: SearchMode = .fts,
    /// Passed to the FTS query as-is (search.zig sanitizes before handing it in).
    search_query: ?[]const u8 = null,
    embeddings: QueryEmbeddings = .{},
    semantic_min_similarity: f32 = 0.15,
    visual_min_similarity: f32 = 0.03,
    filter_library_id: ?u64 = null,
    filter_folder_path: ?[]const u8 = null,
    filters: []const db_mod.ActiveFilter = &.{},

    pub fn dupe(q: ViewQuery, a: std.mem.Allocator) !ViewQuery {
        var out: ViewQuery = q;
        out.search_query = null;
        out.embeddings = .{};
        out.filter_folder_path = null;
        out.filters = &.{};
        errdefer out.deinit(a);
        if (q.search_query) |t| out.search_query = try a.dupe(u8, t);
        if (q.embeddings.prompt) |e| out.embeddings.prompt = try a.dupe(f32, e);
        if (q.embeddings.visual) |e| out.embeddings.visual = try a.dupe(f32, e);
        if (q.filter_folder_path) |f| out.filter_folder_path = try a.dupe(u8, f);
        const filters = try a.alloc(db_mod.ActiveFilter, q.filters.len);
        var n: usize = 0;
        errdefer {
            for (filters[0..n]) |f| a.free(f.value);
            a.free(filters);
        }
        for (q.filters) |f| {
            filters[n] = .{ .column = f.column, .value = try a.dupe(u8, f.value) };
            n += 1;
        }
        out.filters = filters;
        return out;
    }

    /// Frees a copy made by `dupe`.
    pub fn deinit(q: *ViewQuery, a: std.mem.Allocator) void {
        if (q.search_query) |t| a.free(t);
        q.embeddings.free(a);
        if (q.filter_folder_path) |f| a.free(f);
        for (q.filters) |f| a.free(f.value);
        a.free(q.filters);
        q.* = .{};
    }
};

/// A loaded view: its entries plus the favorite ids and playable media types
/// used to flag them. Built off the main thread; the grid takes ownership.
pub const LoadedView = struct {
    entries: []db_mod.VectorDb.GridEntry,
    favorite_ids: []u64,
    media: []db_mod.VectorDb.MediaTypeRow,

    pub fn free(v: *LoadedView, a: std.mem.Allocator) void {
        v.deinit(a);
    }

    pub fn deinit(v: LoadedView, a: std.mem.Allocator) void {
        for (v.entries) |e| {
            a.free(e.path);
            if (e.trash_name) |t| a.free(t);
        }
        a.free(v.entries);
        a.free(v.favorite_ids);
        a.free(v.media);
    }
};

/// Run a view's queries. Does DB IO: call it off the main thread.
pub fn loadView(db: *db_mod.VectorDb, a: std.mem.Allocator, q: ViewQuery) !LoadedView {
    const entries = try queryEntries(db, a, q);
    errdefer LoadedView.deinit(.{ .entries = entries, .favorite_ids = &.{}, .media = &.{} }, a);
    const favorite_ids = try db.listFavoriteIds(a);
    errdefer a.free(favorite_ids);
    const media_rows = try db.listNonImageMediaTypes(a);
    return .{ .entries = entries, .favorite_ids = favorite_ids, .media = media_rows };
}

fn queryEntries(db: *db_mod.VectorDb, a: std.mem.Allocator, q: ViewQuery) ![]db_mod.VectorDb.GridEntry {
    switch (q.view_mode) {
        .trash => return db.listTrashImages(a),
        .duplicates => return db.listDuplicateImages(a),
        .favorites => return db.listFavorites(a),
        .library => {},
    }
    // Vector search modes, only when the needed embedding is available.
    // Combined degrades to a single-space search when only one encoder
    // produced an embedding. Every mode is narrowed like a listing.
    const scope: db_mod.Scope = .{ .library_id = q.filter_library_id, .folder_path = q.filter_folder_path, .filters = q.filters };
    switch (q.search_mode) {
        .semantic => if (q.embeddings.prompt) |e|
            return db.searchByPromptEmbedding(a, e, 200, q.semantic_min_similarity, scope),
        .visual => if (q.embeddings.visual) |e|
            return db.searchByImageEmbedding(a, e, 200, q.visual_min_similarity, scope),
        .combined => {
            if (q.embeddings.prompt) |pe| {
                if (q.embeddings.visual) |ve|
                    return db.searchCombined(a, pe, ve, 200, q.semantic_min_similarity, q.visual_min_similarity, scope);
                return db.searchByPromptEmbedding(a, pe, 200, q.semantic_min_similarity, scope);
            }
            if (q.embeddings.visual) |ve|
                return db.searchByImageEmbedding(a, ve, 200, q.visual_min_similarity, scope);
        },
        .fts => {},
    }
    const fts = if (q.search_query) |t| try sanitizeFtsQuery(a, t) else null;
    defer if (fts) |t| a.free(t);
    if (fts != null or q.filters.len > 0) {
        return db.listImagesFiltered(a, q.filter_library_id, q.filter_folder_path, fts, q.filters);
    }
    if (q.filter_folder_path) |fp| {
        const lib_id = q.filter_library_id orelse return db.listAllImages(a);
        return db.listImagesInFolder(a, lib_id, fp);
    }
    if (q.filter_library_id) |lib_id| return db.listLibraryImages(a, lib_id);
    return db.listAllImages(a);
}

/// Whether `raw` has anything left to search after `sanitizeFtsQuery`.
fn hasFtsTerms(raw: ?[]const u8) bool {
    for (raw orelse return false) |c| switch (c) {
        '(', ')', '"', '*', '^', ' ', '\t', '\n', '\r' => {},
        else => return true,
    };
    return false;
}

/// Strip FTS5 syntax characters that cause parse errors in user-typed queries.
/// Returns null when nothing searchable is left. Caller owns the result.
pub fn sanitizeFtsQuery(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const buf = try a.dupe(u8, raw);
    defer a.free(buf);
    for (buf) |*c| switch (c.*) {
        '(', ')', '"', '*', '^' => c.* = ' ',
        else => {},
    };
    const trimmed = std.mem.trim(u8, buf, " \t\n\r");
    if (trimmed.len == 0) return null;
    return try a.dupe(u8, trimmed);
}

/// Whether a view's DB order is its ranking (BM25 for text, nearest first or
/// RRF score for vectors), so the user's sort doesn't apply. Mirrors
/// `queryEntries`.
pub fn isRelevanceRanked(q: ViewQuery) bool {
    if (q.view_mode != .library) return false;
    const e = q.embeddings;
    const vector = switch (q.search_mode) {
        .fts => false,
        .semantic => e.prompt != null,
        .visual => e.visual != null,
        .combined => e.prompt != null or e.visual != null,
    };
    return vector or hasFtsTerms(q.search_query);
}

/// A user sort order (not used for relevance-ranked or duplicates views).
pub const Order = struct {
    mode: SortMode,
    dir: SortDir,
    /// Orders `.random`: each image gets a position from hash(seed, id), so
    /// removing one doesn't reorder the rest.
    seed: u64,

    pub fn lessThan(o: Order, a: ImageEntry, b: ImageEntry) bool {
        return switch (o.mode) {
            .date => {
                // null mtime sorts to the end regardless of direction
                if (b.mtime == null) return a.mtime != null;
                if (a.mtime == null) return false;
                return if (o.dir == .desc) a.mtime.? > b.mtime.? else a.mtime.? < b.mtime.?;
            },
            .name => {
                const cmp = std.mem.order(u8, a.filename, b.filename);
                return if (o.dir == .asc) cmp == .lt else cmp == .gt;
            },
            .random => std.hash.Wyhash.hash(o.seed, std.mem.asBytes(&a.id)) <
                std.hash.Wyhash.hash(o.seed, std.mem.asBytes(&b.id)),
        };
    }
};

pub fn sortEntries(entries: []ImageEntry, order: Order) void {
    std.mem.sort(ImageEntry, entries, order, Order.lessThan);
}

/// Sort the entries appended at `split` into the already-sorted
/// `entries[0..split]`: the same order `sortEntries` would give the whole
/// slice (both are stable), in O(n + k log k) for k appended instead of
/// O(n log n). The grid gets a few new images most frames of a scan.
pub fn sortAppended(a: std.mem.Allocator, entries: []ImageEntry, split: usize, order: Order) void {
    const tail = entries[split..];
    sortEntries(tail, order);
    if (split == 0 or tail.len == 0) return;
    if (!order.lessThan(tail[0], entries[split - 1])) return; // already in place
    const added = a.dupe(ImageEntry, tail) catch return sortEntries(entries, order);
    defer a.free(added);
    // Merge from the back. On a tie the earlier (head) entry stays first, as
    // in a stable sort. The write slot is always past the unread head.
    var i = split; // head entries left: entries[0..i]
    var j = added.len; // appended entries left: added[0..j]
    var w = entries.len;
    while (j > 0) {
        w -= 1;
        if (i > 0 and order.lessThan(added[j - 1], entries[i - 1])) {
            i -= 1;
            entries[w] = entries[i];
        } else {
            j -= 1;
            entries[w] = added[j];
        }
    }
}


