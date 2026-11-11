const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const vips = @import("vips");
const notifier_mod = @import("notifier.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const app_icons = @import("app_icons.zig");
const media = @import("media.zig");
const video_player_mod = @import("video_player.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");

pub const ImageNotifier = notifier_mod.ImageNotifier;

const log = std.log.scoped(.image_grid);

pub const SortMode = enum { date, name, random };
pub const SortDir = enum { asc, desc };
pub const ViewMode = enum { library, trash, duplicates, favorites };
pub const SearchMode = enum { fts, semantic, visual, combined };

/// One query embedding per vector space: `prompt` targets
/// positive_prompt_embeddings (Snowflake), `visual` targets image_embeddings
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

// ── Cache ─────────────────────────────────────────────────────────────────────

const CacheEntry = struct {
    bytes: []u8,
    last_seen_s: i64,
    width: f32,  // natural JPEG pixel width
    height: f32, // natural JPEG pixel height
};

/// Parse JPEG SOF marker to get image dimensions without decoding the image.
fn jpegDimensions(bytes: []const u8) struct { w: f32, h: f32 } {
    if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8)
        return .{ .w = 10, .h = 10 };
    var i: usize = 2;
    while (i + 3 < bytes.len) {
        if (bytes[i] != 0xFF) break;
        const marker = bytes[i + 1];
        // SOF markers: C0-CF except C4 (DHT), C8 (JPG), CC (DAC)
        if (marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC)
        {
            if (i + 8 >= bytes.len) break;
            // Segment layout: FF Cn [2-len] [1-precision] [2-height] [2-width]
            const h: f32 = @floatFromInt((@as(u16, bytes[i + 5]) << 8) | bytes[i + 6]);
            const w: f32 = @floatFromInt((@as(u16, bytes[i + 7]) << 8) | bytes[i + 8]);
            if (w > 0 and h > 0) return .{ .w = w, .h = h };
        }
        const seg_len: usize = (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
        if (seg_len < 2) break;
        i += 2 + seg_len;
    }
    return .{ .w = 10, .h = 10 };
}

// ── Load queue ────────────────────────────────────────────────────────────────

const LoadRequest = struct {
    id: u64,
    path: []const u8, // heap-allocated copy; freed by worker after use or by reloadImages on queue clear
};

// ── Layout constants ──────────────────────────────────────────────────────────

pub const thumb_size_min: f32 = 80;
pub const thumb_size_max: f32 = 320;
const max_workers = 8;
// Favorite star overlay (top-right of each thumbnail), in logical px.
const star_sz: f32 = 22;
const star_margin: f32 = 4;
const gap: f32 = 8;
const cell_border: f32 = 2; // border on each side; must be factored into h_margin
const label_h: f32 = 20;
const evict_interval_s: i64 = 5;
const ttl_s: i64 = 45;
const prefetch_screens: usize = 2;

// ── Grid autoplay ──────────────────────────────────────────────────────────────
// Live playback of animated/video cells in the grid (opt-in, muted). Currently
// UNBOUNDED: every visible playable cell gets a player, created as soon as it
// scrolls into view (no concurrency cap or per-frame open throttle). Off-screen
// players are still evicted after a short grace so memory/threads don't grow
// without bound as you scroll.
// Frames decoded to fit this many px (long edge). Kept modest: animated cells are
// decoded whole into an in-memory cache (see the vips anim decoder), so this
// directly bounds per-clip memory, and it's only a grid preview so slight softness
// is fine.
const grid_player_dim = 256;
// Keep a player alive briefly after its cell scrolls off, so scrubbing back and
// forth doesn't thrash open/close (each close joins a decode thread).
const player_evict_grace_frames: u64 = 30;
// Opening a player does file I/O (avformat/vips header read) + spawns a decode
// thread — too slow for the render thread. A small pool opens them off-thread and
// hands the ready player back to be installed on the next frame.
const max_player_openers = 4;

/// A request to open a player for a cell, handed to an opener thread. `path_z` is
/// heap-owned; the opener frees it after use.
const PlayerOpenReq = struct { id: u64, path_z: [:0]u8 };
/// An opened player handed back to the main thread (player == null on open error).
const ReadyPlayer = struct { id: u64, player: ?*video_player_mod.VideoPlayer };

/// A live player bound to one animated/video grid cell. Owns the current decoded
/// frame (packed RGBA8) shown in place of the static thumbnail.
const CellPlayer = struct {
    player: *video_player_mod.VideoPlayer,
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    tex_hash: u64 = 0,
    last_touched: u64 = 0, // player_frame when this cell was last visible
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
    // produced an embedding.
    switch (q.search_mode) {
        .semantic => if (q.embeddings.prompt) |e|
            return db.searchByPromptEmbedding(a, e, 200, q.semantic_min_similarity),
        .visual => if (q.embeddings.visual) |e|
            return db.searchByImageEmbedding(a, e, 200, q.visual_min_similarity),
        .combined => {
            if (q.embeddings.prompt) |pe| {
                if (q.embeddings.visual) |ve|
                    return db.searchCombined(a, pe, ve, 200, q.semantic_min_similarity, q.visual_min_similarity);
                return db.searchByPromptEmbedding(a, pe, 200, q.semantic_min_similarity);
            }
            if (q.embeddings.visual) |ve|
                return db.searchByImageEmbedding(a, ve, 200, q.visual_min_similarity);
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

const LoadCtx = struct {
    grid: *GridState,
    query: ViewQuery, // owned
    generation: u64,
};

fn loadTask(ctx: LoadCtx) void {
    var q = ctx.query;
    defer q.deinit(ctx.grid.allocator);
    const g = ctx.grid;
    if (g.load_gen.load(.acquire) != ctx.generation) return;
    const loaded: ?LoadedView = loadView(&g.view_db, g.allocator, q) catch |err| blk: {
        log.warn("view load failed: {}", .{err});
        break :blk null;
    };
    g.load_mutex.lockUncancelable(g.io);
    defer g.load_mutex.unlock(g.io);
    if (g.load_gen.load(.acquire) != ctx.generation) {
        if (loaded) |v| v.deinit(g.allocator);
        return;
    }
    if (g.load_result) |old| old.deinit(g.allocator);
    g.load_result = loaded;
    g.load_result_gen = ctx.generation;
    if (g.wakeup_fn) |w| w();
}

// ── GridState ─────────────────────────────────────────────────────────────────

pub const GridState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    // Image list — main-thread only after startWorker()
    images: std.ArrayList(ImageEntry) = .empty,

    // Background view loading (reloadImages). load_gen counts requests; a
    // finished load is applied by update() only if it is still the latest.
    load_group: std.Io.Group = .init,
    load_gen: std.atomic.Value(u64) = .init(0),
    load_mutex: std.Io.Mutex = .init,
    load_result: ?LoadedView = null, // guarded by load_mutex
    load_result_gen: u64 = 0, // guarded by load_mutex
    applied_gen: u64 = 0, // main-thread
    load_keep_scroll: bool = false, // main-thread
    // Ids removed while a load was in flight; filtered out of its result so a
    // just-deleted image can't come back. Main-thread.
    load_dropped: std.AutoHashMap(u64, void),
    // Images a scan added while a load was in flight; the load's query may have
    // run before they were inserted, so they are re-added if it lacks them.
    // Owns each path copy. Main-thread.
    load_added: std.ArrayList(ImageNotifier.Entry) = .empty,

    // Incoming images from scan threads — drained each frame in update()
    notifier: ImageNotifier = .{},
    incoming: std.ArrayList(ImageNotifier.Entry) = .empty,
    // IDs of already-present images that were re-notified (reparse / change) this
    // frame. Rebuilt each update(); read by dependent UI (detail panel) so it can
    // reload once the new data has landed. Main-thread only.
    refreshed: std.AutoHashMap(u64, void),

    // Two-tier thumbnail cache
    // committed: main-thread only, no lock needed
    committed: std.AutoHashMap(u64, CacheEntry),
    // pending: worker writes; main drains into committed in update()
    pending: std.AutoHashMap(u64, []u8),
    pending_mutex: std.Io.Mutex = std.Io.Mutex.init,

    last_eviction_s: i64 = 0,

    // Load queues — protected by queue_mutex
    // high = visible range, low = prefetch zone
    high_queue: std.ArrayList(LoadRequest) = .empty,
    low_queue: std.ArrayList(LoadRequest) = .empty,
    queued: std.AutoHashMap(u64, void), // IDs sitting in high_queue/low_queue
    // IDs a worker has popped and is currently loading. Tracked separately from
    // `queued` so the per-frame queue rebuild (which drops stale queued requests)
    // doesn't re-request something already in flight and load it twice.
    in_flight: std.AutoHashMap(u64, void),
    /// In-flight loads whose id was invalidated meanwhile (the id now names
    /// another image): their result is dropped. Guarded by queue_mutex.
    stale_in_flight: std.AutoHashMap(u64, void),
    // Ids whose thumbnail couldn't be produced: not re-requested until
    // invalidateThumbnail (refresh / recycled id). Guarded by queue_mutex.
    load_failed: std.AutoHashMap(u64, void),
    // Ids the loader deleted from the DB because their file is gone. Drained by
    // app.zig each frame to drop them from the grid and viewers. Guarded by queue_mutex.
    missing_ids: std.ArrayList(u64) = .empty,
    queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
    queue_cond: std.Io.Condition = std.Io.Condition.init,

    // Dedicated DB connection shared by all loader workers, serialized via mutex
    loader_db: db_mod.VectorDb,
    loader_db_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Connection for background view loads, so a long list / FTS / KNN query
    /// never holds the main connection's mutex while the UI needs it. Its own
    /// `db_mutex` serializes overlapping loads.
    view_db: db_mod.VectorDb,
    /// Read by the loader workers; the settings screen may change it.
    thumbnails_in_db: std.atomic.Value(bool),

    // Worker thread pool
    workers: [max_workers]std.Thread = undefined,
    worker_count: usize = 0,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Persistent scroll state for the grid's scroll area.  Using vertical=.given
    // prevents the full content height from being reported as min_size.h to the
    // parent layout, which would push the statusbar off-screen.
    scroll_info: dvui.ScrollInfo = .{},
    // Content width (logical px) measured *inside* the scroll area last frame.
    // Reused to estimate the virtual height before the scroll area is opened this
    // frame, so the estimated column count matches the actual one. Keying the
    // estimate off dvui's reconstructed `viewport.w` instead lets the two diverge
    // by a column, which makes the virtual height (and scrollbar) thrash every
    // frame — blank gaps when scrolling and thumbnails that reload forever.
    // 0 until the first paint (estimate falls back to a single column).
    last_avail_w: f32 = 0,

    // Called from worker after each thumbnail is ready, to wake the render loop.
    wakeup_fn: ?*const fn () void = null,

    // ── Grid autoplay ─────────────────────────────────────────────────────────
    // When enabled, visible animated/video cells play live (muted). Mirrored from
    // config each frame by app.zig. Players are created/ticked during render and
    // evicted when their cell scrolls off. Main-thread only.
    autoplay: bool = false,
    grid_players: std.AutoHashMap(u64, CellPlayer) = undefined, // main-thread only
    player_frame: u64 = 0, // bumped once per render for touch/evict
    // Background opener pipeline. player_queue/player_ready/player_in_flight are
    // shared with opener threads (guarded by player_mutex); player_failed is
    // main-thread only. The queue is rebuilt each frame from the visible cells,
    // like the thumbnail loader's high/low queues.
    player_mutex: std.Io.Mutex = std.Io.Mutex.init,
    player_cond: std.Io.Condition = std.Io.Condition.init,
    player_queue: std.ArrayList(PlayerOpenReq) = .empty,
    player_ready: std.ArrayList(ReadyPlayer) = .empty,
    player_in_flight: std.AutoHashMap(u64, void) = undefined,
    player_failed: std.AutoHashMap(u64, void) = undefined, // opens that errored; don't retry
    player_openers: [max_player_openers]std.Thread = undefined,
    player_opener_count: usize = 0,

    // UI state
    view_mode: ViewMode = .library,
    selection: std.AutoHashMap(u64, void), // set of selected image IDs
    focused_idx: ?usize = null,            // keyboard cursor position (grid index)
    scroll_to_focused: bool = false,       // set by keyboard nav; cleared after one viewport adjustment
    anchor_idx: ?usize = null,             // shift-select range anchor
    thumb_fraction: f32 = 0.25, // 0..1 maps to thumb_size_min..thumb_size_max (~140px default)
    sort_mode: SortMode = .date,
    sort_dir: SortDir = .desc,  // newest first by default
    sort_seed: u64 = 0,
    // Pending actions — set by key handlers / context menu, consumed by app.zig each frame
    delete_requested: bool = false,
    delete_force: bool = false,   // true = Shift+Delete or "Delete Permanently": skip trash
    restore_requested: bool = false,
    // Bulk view actions — set by the duplicates/trash banners, consumed by app.zig
    dedupe_requested: bool = false,      // remove all but one of each duplicate
    empty_trash_requested: bool = false, // permanently delete all trashed images
    copy_prompt_requested: bool = false,
    copy_prompt_id: u64 = 0,
    copy_image_requested: bool = false,
    copy_image_id: u64 = 0,
    reparse_requested: bool = false,
    reparse_id: u64 = 0,
    // Favorite toggle — set when a grid star is clicked, consumed by app.zig.
    favorite_toggle_id: ?u64 = null,
    drag_requested: bool = false,
    drag_requested_ids: std.ArrayList(u64) = .empty,
    // Mirrored from config so renderItem can condition the context menu label
    trash_enabled: bool = true,
    // Viewer opening — set by double-click/Enter/context menu, consumed by app.zig each frame
    open_viewer_requested: bool = false,
    viewer_start_id: ?u64 = null,
    // Double-click state stored here (not in dvui data store) for reliability
    dblclick_last_id: u64 = 0,
    dblclick_last_ns: i64 = 0,

    // Filter state — owned by app.zig, not freed by GridState
    filter_library_id: ?u64 = null,
    filter_folder_path: ?[]const u8 = null,
    // Root path of the selected library (borrowed from the sidebar, not owned).
    // Used to decide whether a newly scanned image belongs in the current view.
    filter_library_path: ?[]const u8 = null,
    /// FTS5 search query. Owned; set with `setSearchQuery`.
    search_query: ?[]const u8 = null,
    // Active metadata filters — slice into app.zig's g_active_filters; not owned
    filters: []const db_mod.ActiveFilter = &.{},
    // Search mode and query embeddings for semantic/visual search
    search_mode: SearchMode = .fts,
    query_embeddings: QueryEmbeddings = .{},  // borrowed, not owned
    // Minimum cosine similarity per vector space (from config; set at startup).
    semantic_min_similarity: f32 = 0.15,
    visual_min_similarity: f32 = 0.03,

    // Data directory (e.g. ~/.local/share/DiffKeep) — borrowed from app, not owned.
    // Used to resolve trash file paths: <data_dir>/trash/<trash_name>.
    data_dir: ?[]const u8 = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *db_mod.VectorDb, thumbnails_in_db: bool, wakeup_fn: ?*const fn () void) !GridState {
        var loader_db = try db.getConnection();
        errdefer loader_db.deinit();
        var view_db = try db.getConnection();
        errdefer view_db.deinit();
        var state = GridState{
            .io = io,
            .allocator = allocator,
            .committed = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .pending = std.AutoHashMap(u64, []u8).init(allocator),
            .queued = std.AutoHashMap(u64, void).init(allocator),
            .in_flight = std.AutoHashMap(u64, void).init(allocator),
            .stale_in_flight = std.AutoHashMap(u64, void).init(allocator),
            .load_failed = std.AutoHashMap(u64, void).init(allocator),
            .load_dropped = std.AutoHashMap(u64, void).init(allocator),
            .refreshed = std.AutoHashMap(u64, void).init(allocator),
            .selection = std.AutoHashMap(u64, void).init(allocator),
            .loader_db = loader_db,
            .view_db = view_db,
            .thumbnails_in_db = .init(thumbnails_in_db),
            .wakeup_fn = wakeup_fn,
            .grid_players = std.AutoHashMap(u64, CellPlayer).init(allocator),
            .player_in_flight = std.AutoHashMap(u64, void).init(allocator),
            .player_failed = std.AutoHashMap(u64, void).init(allocator),
        };

        // The image list loads in the background: call reloadImages once the
        // grid is at its final address (the load task points into it).
        const now_ns = std.Io.Clock.real.now(io).nanoseconds;
        state.last_eviction_s = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
        state.sort_seed = @truncate(@abs(now_ns));
        state.applySortOrder();
        return state;
    }

    /// Start the background loader thread pool. Call this after the GridState is at its
    /// final stable address (e.g. stored as a module-level global).
    pub fn startWorker(self: *GridState) !void {
        const n = @min(std.Thread.getCpuCount() catch 4, max_workers);
        for (0..n) |_| {
            self.workers[self.worker_count] = try std.Thread.spawn(.{}, workerFn, .{self});
            self.worker_count += 1;
        }
        // Background player-opener pool (grid autoplay). Idle until autoplay
        // requests opens, so it's cheap to always have running.
        const np = @min(std.Thread.getCpuCount() catch 2, max_player_openers);
        for (0..np) |_| {
            self.player_openers[self.player_opener_count] = try std.Thread.spawn(.{}, playerOpenerFn, .{self});
            self.player_opener_count += 1;
        }
    }

    /// The entry with `id`, if it's in the current list.
    pub fn entryById(self: *const GridState, id: u64) ?*const ImageEntry {
        for (self.images.items) |*e| if (e.id == id) return e;
        return null;
    }

    /// Set the FTS query (copied; the grid owns it). Null clears it.
    pub fn setSearchQuery(self: *GridState, q: ?[]const u8) !void {
        const copy = if (q) |t| try self.allocator.dupe(u8, t) else null;
        if (self.search_query) |old| self.allocator.free(old);
        self.search_query = copy;
    }

    pub fn deinit(self: *GridState) void {
        self.load_group.await(self.io) catch {};
        if (self.search_query) |q| self.allocator.free(q);
        if (self.load_result) |v| v.deinit(self.allocator);
        self.load_dropped.deinit();
        for (self.load_added.items) |e| self.allocator.free(e.path);
        self.load_added.deinit(self.allocator);
        self.stop.store(true, .release);
        self.queue_mutex.lockUncancelable(self.io);
        // Signal once per worker to wake all waiting threads
        for (0..self.worker_count) |_| self.queue_cond.signal(self.io);
        self.queue_mutex.unlock(self.io);
        for (self.workers[0..self.worker_count]) |w| w.join();

        // Stop the player-opener pool (they wait on player_cond).
        self.player_mutex.lockUncancelable(self.io);
        for (0..self.player_opener_count) |_| self.player_cond.signal(self.io);
        self.player_mutex.unlock(self.io);
        for (self.player_openers[0..self.player_opener_count]) |t| t.join();

        // No opener threads left, so the pipeline is now ours alone to tear down.
        // Tear down live players first (clearGridPlayersEx still reads player_failed),
        // then the pipeline maps/lists. deinit runs at shutdown, outside any dvui
        // frame: don't touch the texture cache (the window is already being torn down).
        self.clearGridPlayersEx(false);
        self.grid_players.deinit();
        for (self.player_queue.items) |r| self.allocator.free(r.path_z);
        self.player_queue.deinit(self.allocator);
        for (self.player_ready.items) |rp| if (rp.player) |p| p.deinit();
        self.player_ready.deinit(self.allocator);
        self.player_in_flight.deinit();
        self.player_failed.deinit();

        var ci = self.committed.iterator();
        while (ci.next()) |kv| self.allocator.free(kv.value_ptr.bytes);
        self.committed.deinit();

        var pi = self.pending.iterator();
        while (pi.next()) |kv| self.allocator.free(kv.value_ptr.*);
        self.pending.deinit();

        for (self.high_queue.items) |r| self.allocator.free(r.path);
        for (self.low_queue.items) |r| self.allocator.free(r.path);
        self.high_queue.deinit(self.allocator);
        self.low_queue.deinit(self.allocator);
        self.queued.deinit();
        self.in_flight.deinit();
        self.stale_in_flight.deinit();
        self.load_failed.deinit();
        self.missing_ids.deinit(self.allocator);
        self.refreshed.deinit();

        self.loader_db.deinit();
        self.view_db.deinit();
        self.notifier.deinit();
        self.selection.deinit();
        self.drag_requested_ids.deinit(self.allocator);

        for (self.incoming.items) |e| self.allocator.free(e.path);
        self.incoming.deinit(self.allocator);

        for (self.images.items) |e| {
            self.allocator.free(e.path);
            if (e.trash_name) |tn| self.allocator.free(tn);
        }
        self.images.deinit(self.allocator);
    }

    /// The query for the view the grid currently shows.
    pub fn currentQuery(self: *const GridState) ViewQuery {
        return .{
            .view_mode = self.view_mode,
            .search_mode = self.search_mode,
            .search_query = self.search_query,
            .embeddings = self.query_embeddings,
            .semantic_min_similarity = self.semantic_min_similarity,
            .visual_min_similarity = self.visual_min_similarity,
            .filter_library_id = self.filter_library_id,
            .filter_folder_path = self.filter_folder_path,
            .filters = self.filters,
        };
    }

    pub const ReloadOptions = struct {
        /// Keep the scroll position (an in-place refresh of the same view)
        /// instead of starting at the top.
        keep_scroll: bool = false,
    };

    /// Reload the image list for the current view in the background. The old
    /// list stays on screen until update() swaps the result in; a newer
    /// request supersedes an older one still loading.
    pub fn reloadImages(self: *GridState) !void {
        return self.reloadImagesEx(.{});
    }

    pub fn reloadImagesEx(self: *GridState, opts: ReloadOptions) !void {
        const query = try self.currentQuery().dupe(self.allocator);
        const gen = self.load_gen.fetchAdd(1, .acq_rel) + 1;
        self.load_keep_scroll = opts.keep_scroll;
        self.load_group.concurrent(self.io, loadTask, .{LoadCtx{
            .grid = self,
            .query = query,
            .generation = gen,
        }}) catch |err| {
            var q = query;
            q.deinit(self.allocator);
            return err;
        };
    }

    /// True while a requested reload hasn't been applied yet.
    pub fn reloadPending(self: *const GridState) bool {
        return self.load_gen.load(.acquire) != self.applied_gen;
    }

    /// Wait for in-flight loads and apply the latest. For tests and tools: the
    /// app lets update() apply loads as they finish.
    pub fn awaitReload(self: *GridState) void {
        self.load_group.await(self.io) catch {};
        _ = self.applyReloadIfDone();
    }

    /// Record ids removed from the grid while a load is in flight.
    pub fn noteRemoved(self: *GridState, id: u64) void {
        if (self.reloadPending()) self.load_dropped.put(id, {}) catch {};
    }

    /// Main thread: swap in a finished load if it is the latest request.
    fn applyReloadIfDone(self: *GridState) bool {
        self.load_mutex.lockUncancelable(self.io);
        const ready = self.load_result_gen == self.load_gen.load(.acquire) and self.load_result_gen != self.applied_gen;
        const result = if (ready) self.load_result else null;
        if (ready) {
            self.load_result = null;
            self.applied_gen = self.load_result_gen;
        }
        self.load_mutex.unlock(self.io);
        if (!ready) return false;
        // A failed load (null) keeps the current list.
        if (result) |v| {
            self.replaceImages(v, .{ .keep_scroll = self.load_keep_scroll });
            self.readdScannedImages();
        }
        for (self.load_added.items) |e| self.allocator.free(e.path);
        self.load_added.clearRetainingCapacity();
        self.load_dropped.clearRetainingCapacity();
        return true;
    }

    /// Re-add images scanned in while the applied load was running that its
    /// result doesn't have (it may have queried before they were inserted).
    fn readdScannedImages(self: *GridState) void {
        if (self.load_added.items.len == 0) return;
        var present = std.AutoHashMap(u64, void).init(self.allocator);
        defer present.deinit();
        for (self.images.items) |img| present.put(img.id, {}) catch {};
        var added = false;
        for (self.load_added.items) |*e| {
            if (present.contains(e.id) or self.load_dropped.contains(e.id)) continue;
            if (!self.incomingBelongs(e.path)) continue;
            self.images.append(self.allocator, .{
                .id = e.id,
                .path = e.path,
                .filename = std.Io.Dir.path.basename(e.path),
                .mtime = e.mtime,
            }) catch continue;
            e.path = ""; // ownership moved to the grid
            present.put(e.id, {}) catch {};
            added = true;
        }
        if (added) self.applySortOrder();
    }

    /// Replace the image list with a loaded view. Takes ownership of `view`.
    /// Clears selection and navigation state.
    pub fn replaceImages(self: *GridState, view: LoadedView, opts: ReloadOptions) void {
        defer {
            self.allocator.free(view.entries);
            self.allocator.free(view.favorite_ids);
            self.allocator.free(view.media);
        }
        // Clear queues before freeing images so workers don't access freed path pointers.
        {
            self.queue_mutex.lockUncancelable(self.io);
            for (self.high_queue.items) |r| self.allocator.free(r.path);
            for (self.low_queue.items) |r| self.allocator.free(r.path);
            self.high_queue.clearRetainingCapacity();
            self.low_queue.clearRetainingCapacity();
            self.queued.clearRetainingCapacity();
            self.queue_mutex.unlock(self.io);
        }
        for (self.images.items) |e| {
            self.allocator.free(e.path);
            if (e.trash_name) |tn| self.allocator.free(tn);
        }
        // Live cell players reference image ids; the list is about to change.
        self.clearGridPlayers();
        self.images.clearRetainingCapacity();
        self.selection.clearRetainingCapacity();
        self.focused_idx = null;
        self.anchor_idx = null;
        // Switching to a new view starts at the top.
        if (!opts.keep_scroll) self.scroll_info.viewport.y = 0;

        self.images.ensureTotalCapacity(self.allocator, view.entries.len) catch {};
        for (view.entries) |e| {
            if (self.load_dropped.contains(e.id) or self.images.items.len == self.images.capacity) {
                self.allocator.free(e.path);
                if (e.trash_name) |tn| self.allocator.free(tn);
                continue;
            }
            self.images.appendAssumeCapacity(.{
                .id = e.id,
                .path = e.path,
                .filename = std.Io.Dir.path.basename(e.path),
                .mtime = e.mtime,
                .trashed_at = e.trashed_at,
                .trash_name = e.trash_name,
                .favorite = e.favorite,
            });
        }
        self.applyFavorites(view.favorite_ids);
        self.applyMediaTypes(view.media);
        self.applySortOrder();
    }

    /// Flag which loaded entries are favorites. Keeps the per-entry flag
    /// accurate without threading a column through every grid query.
    pub fn applyFavorites(self: *GridState, fav_ids: []const u64) void {
        if (fav_ids.len == 0) {
            for (self.images.items) |*e| e.favorite = false;
            return;
        }
        var set = std.AutoHashMap(u64, void).init(self.allocator);
        defer set.deinit();
        set.ensureTotalCapacity(@intCast(fav_ids.len)) catch {};
        for (fav_ids) |id| set.put(id, {}) catch {};
        for (self.images.items) |*e| e.favorite = set.contains(e.id);
    }

    /// Set the playback classification (animated / video) of loaded entries
    /// from the (small) list of non-image rows.
    pub fn applyMediaTypes(self: *GridState, rows: []const db_mod.VectorDb.MediaTypeRow) void {
        for (self.images.items) |*e| e.media_type = .image;
        if (rows.len == 0) return;
        var map = std.AutoHashMap(u64, db_mod.VectorDb.MediaType).init(self.allocator);
        defer map.deinit();
        map.ensureTotalCapacity(@intCast(rows.len)) catch {};
        for (rows) |r| map.put(r.id, r.media_type) catch {};
        for (self.images.items) |*e| {
            if (map.get(e.id)) |mt| e.media_type = mt;
        }
    }

    // ── Grid autoplay players ──────────────────────────────────────────────────

    /// Whether an entry is a live-playable type (animated image or video).
    fn isPlayable(e: *const ImageEntry) bool {
        return e.media_type == .animated or e.media_type == .video;
    }

    /// Advance the (already-open) player for a visible cell and return it so its
    /// current frame can be drawn, or null if no player exists yet (opening, or
    /// never requested). Never opens — that happens off-thread via requestPlayer.
    fn drawCellPlayer(self: *GridState, id: u64, now_ns: i128) ?*CellPlayer {
        const cp = self.grid_players.getPtr(id) orelse return null;
        cp.last_touched = self.player_frame;
        if (cp.player.tick(now_ns)) |frame| {
            if (cp.pixels) |old| {
                dvui.textureInvalidateCache(cp.tex_hash);
                self.allocator.free(old);
            }
            cp.pixels = frame.pixels;
            cp.width = frame.width;
            cp.height = frame.height;
            cp.tex_hash = (dvui.ImageSource{ .pixels = .{
                .rgba = frame.pixels, .width = frame.width, .height = frame.height,
            } }).hash();
        }
        return cp;
    }

    /// Queue an off-thread open for a visible playable cell that has no player yet.
    /// No-op if the open is already in flight or previously failed. The queue is
    /// rebuilt each frame (see syncPlayerPipeline), so only currently-visible cells
    /// stay queued.
    fn requestPlayer(self: *GridState, entry: *const ImageEntry) void {
        const id = entry.id;
        if (self.player_failed.contains(id)) return; // main-thread only; no lock
        const path = self.diskPath(entry);
        defer if (path.ptr != entry.path.ptr) self.allocator.free(path);
        const path_z = self.allocator.dupeSentinel(u8, path, 0) catch return;

        self.player_mutex.lockUncancelable(self.io);
        defer self.player_mutex.unlock(self.io);
        if (self.player_in_flight.contains(id)) { self.allocator.free(path_z); return; }
        for (self.player_queue.items) |r| if (r.id == id) { self.allocator.free(path_z); return; };
        self.player_queue.append(self.allocator, .{ .id = id, .path_z = path_z }) catch {
            self.allocator.free(path_z);
            return;
        };
        self.player_cond.signal(self.io);
    }

    /// Per-frame pipeline sync: drop stale open requests (visible cells re-queue
    /// during row render) and take the players the openers finished. When
    /// `install` is true, ready players are installed into grid_players; otherwise
    /// (autoplay off) they're discarded. Runs on the main thread.
    fn syncPlayerPipeline(self: *GridState, install: bool) void {
        self.player_mutex.lockUncancelable(self.io);
        for (self.player_queue.items) |r| self.allocator.free(r.path_z);
        self.player_queue.clearRetainingCapacity();
        var ready = self.player_ready; // move the finished list out from under the lock
        self.player_ready = .empty;
        self.player_mutex.unlock(self.io);
        defer ready.deinit(self.allocator);

        for (ready.items) |rp| {
            const player = rp.player orelse {
                if (install) self.player_failed.put(rp.id, {}) catch {};
                continue;
            };
            if (!install) { player.deinit(); continue; }
            const gop = self.grid_players.getOrPut(rp.id) catch { player.deinit(); continue; };
            if (gop.found_existing) { player.deinit(); continue; } // already have one
            gop.value_ptr.* = .{ .player = player, .last_touched = self.player_frame };
        }
    }

    /// Free a single cell player (joins its decode thread and releases frames).
    /// `invalidate` drops the frame's cached GPU texture — only valid mid-frame
    /// (dvui requires an active window); the deinit path passes false since the
    /// whole window is being torn down.
    fn destroyCellPlayer(self: *GridState, cp: *CellPlayer, invalidate: bool) void {
        cp.player.deinit();
        if (cp.pixels) |p| {
            if (invalidate) dvui.textureInvalidateCache(cp.tex_hash);
            self.allocator.free(p);
        }
    }

    /// Evict players whose cell hasn't been visible for `player_evict_grace_frames`.
    /// Also returns true if any surviving player is still playing (so the render
    /// loop keeps spinning to advance playback).
    fn evictStaleCellPlayers(self: *GridState) bool {
        var any_playing = false;
        // Collect stale keys first — removing during iteration can invalidate the
        // iterator, and (with no cap) any number may go stale in one frame. Only
        // destroy after collecting, so a player is never freed while its map entry
        // survives (that would be a use-after-free next frame).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.grid_players.iterator();
        while (it.next()) |kv| {
            const cp = kv.value_ptr;
            if (self.player_frame - cp.last_touched > player_evict_grace_frames) {
                // If the append fails (OOM), leave the entry: it stays alive and is
                // retried next frame — never destroyed-but-orphaned.
                stale.append(self.allocator, kv.key_ptr.*) catch {};
            } else if (cp.player.isPlaying()) {
                any_playing = true;
            }
        }
        for (stale.items) |id| {
            if (self.grid_players.getPtr(id)) |cp| self.destroyCellPlayer(cp, true);
            _ = self.grid_players.remove(id);
        }
        return any_playing;
    }

    /// Tear down all grid players (autoplay turned off, view reloaded, or deinit).
    /// `invalidate` must be false when called outside a dvui frame (deinit).
    /// Also drops any queued (not-yet-opened) requests and the failed-open set;
    /// in-flight opens still complete but their players are discarded on the next
    /// syncPlayerPipeline. (deinit clears the queue itself after joining openers.)
    fn clearGridPlayersEx(self: *GridState, invalidate: bool) void {
        var it = self.grid_players.iterator();
        while (it.next()) |kv| self.destroyCellPlayer(kv.value_ptr, invalidate);
        self.grid_players.clearRetainingCapacity();
        self.player_failed.clearRetainingCapacity();
    }

    /// Tear down all grid players from within a frame (autoplay off / view reload).
    pub fn clearGridPlayers(self: *GridState) void {
        self.clearGridPlayersEx(true);
    }

    /// Background opener: pops a request, opens the player (file I/O + decode
    /// thread spawn — the work we keep off the render thread), and hands it back.
    fn playerOpenerFn(self: *GridState) void {
        while (true) {
            self.player_mutex.lockUncancelable(self.io);
            while (self.player_queue.items.len == 0 and !self.stop.load(.acquire))
                self.player_cond.waitUncancelable(self.io, &self.player_mutex);
            if (self.stop.load(.acquire)) { self.player_mutex.unlock(self.io); break; }
            const req = self.player_queue.orderedRemove(0);
            self.player_in_flight.put(req.id, {}) catch {};
            self.player_mutex.unlock(self.io);

            const player = video_player_mod.VideoPlayer.init(self.allocator, self.io, req.path_z, .{
                .wakeup_fn = self.wakeup_fn,
                .audio = false,
                .max_dim = grid_player_dim,
            }) catch null;
            self.allocator.free(req.path_z);

            self.player_mutex.lockUncancelable(self.io);
            _ = self.player_in_flight.remove(req.id);
            self.player_ready.append(self.allocator, .{ .id = req.id, .player = player }) catch {
                self.player_mutex.unlock(self.io);
                if (player) |p| p.deinit(); // couldn't hand it back; don't leak
                continue;
            };
            self.player_mutex.unlock(self.io);
            if (self.wakeup_fn) |w| w();
        }
    }

    /// True if `path` names a file directly or transitively inside `root`.
    fn pathInside(path: []const u8, root: []const u8) bool {
        return path.len > root.len and
            std.mem.startsWith(u8, path, root) and
            path[root.len] == '/';
    }

    /// Whether a freshly scanned image at `path` belongs in the current view.
    /// Only the plain library/folder browse views can be updated incrementally;
    /// when a search, embedding, or metadata filter is active we can't cheaply
    /// tell whether the new image matches, so we leave it out — it appears the
    /// next time the query is run.
    pub fn incomingBelongs(self: *const GridState, path: []const u8) bool {
        if (self.query_embeddings.any()) return false;
        if (self.search_query) |q| if (q.len > 0) return false;
        if (self.filters.len > 0) return false;
        if (self.filter_folder_path) |fp| return pathInside(path, fp);
        if (self.filter_library_path) |lp| return pathInside(path, lp);
        return true; // unfiltered "all images" view
    }

    /// Call once per frame before render(), on the main thread.
    pub fn update(self: *GridState) void {
        // Refresh set only reflects this frame's re-notifications; the detail
        // panel consults it later in the same frame.
        self.refreshed.clearRetainingCapacity();

        // 0. Swap in a finished background view load.
        _ = self.applyReloadIfDone();

        // 1. Drain new images from scan threads. Only the library view adds
        // them; the other views (and the library view's next load) read the
        // DB. Elsewhere just drop each id's stale cached thumbnail — the id may
        // be one SQLite recycled — so the queue can't grow during a long scan.
        self.notifier.drain(self.io, self.allocator, &self.incoming);
        if (self.view_mode != .library) {
            for (self.incoming.items) |e| {
                self.invalidateThumbnail(e.id);
                self.allocator.free(e.path);
            }
            self.incoming.clearRetainingCapacity();
        }
        const before_count = self.images.items.len;
        if (self.incoming.items.len > 0) {
            // Build a set of ids already in the grid so re-notified images (e.g.
            // after a reparse) update in place instead of appearing twice.
            var existing = std.AutoHashMap(u64, void).init(self.allocator);
            defer existing.deinit();
            existing.ensureTotalCapacity(@intCast(self.images.items.len)) catch {};
            for (self.images.items) |img| existing.put(img.id, {}) catch {};
            for (self.incoming.items) |e| {
                if (existing.contains(e.id)) {
                    // Already present: a reparse / change re-notified it. Drop the
                    // now-stale cached thumbnail so it regenerates, and flag the id
                    // so the detail panel reloads from the freshly-saved DB row.
                    self.invalidateThumbnail(e.id);
                    self.refreshed.put(e.id, {}) catch {};
                    self.allocator.free(e.path);
                    continue;
                }
                // A newly appearing id may be one SQLite recycled from a just-
                // deleted image; clear any cache entry it left behind (and any
                // stale in-flight load result) so this image loads its own thumb.
                // Do this even when the image isn't shown here, so the stale
                // thumbnail can't resurface when it later appears in its own view.
                self.invalidateThumbnail(e.id);
                // Don't inject images that don't belong in the current view
                // (different folder/library, or not matching the active search).
                if (!self.incomingBelongs(e.path)) {
                    self.allocator.free(e.path);
                    continue;
                }
                self.images.append(self.allocator, .{
                    .id = e.id,
                    .path = e.path,
                    .filename = std.Io.Dir.path.basename(e.path),
                    .mtime = e.mtime,
                }) catch {
                    self.allocator.free(e.path);
                    continue;
                };
                existing.put(e.id, {}) catch {};
                // A load in flight may not include it; remember it until applied.
                if (self.reloadPending()) {
                    if (self.allocator.dupe(u8, e.path)) |copy| {
                        self.load_added.append(self.allocator, .{ .id = e.id, .path = copy, .mtime = e.mtime }) catch self.allocator.free(copy);
                    } else |_| {}
                }
            }
        }
        self.incoming.clearAndFree(self.allocator);
        if (self.images.items.len != before_count) self.applySortOrder();

        // 2. Drain pending thumbnails into committed
        const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            var it = self.pending.iterator();
            while (it.next()) |kv| {
                const dims = jpegDimensions(kv.value_ptr.*);
                const entry = CacheEntry{
                    .bytes = kv.value_ptr.*,
                    .last_seen_s = now_s,
                    .width = dims.w,
                    .height = dims.h,
                };
                if (self.committed.fetchPut(kv.key_ptr.*, entry) catch null) |old| {
                    self.allocator.free(old.value.bytes);
                }
            }
            self.pending.clearRetainingCapacity();
        }

        // 3. Periodic eviction (~every 5 seconds)
        if (now_s - self.last_eviction_s >= evict_interval_s) {
            self.last_eviction_s = now_s;
            self.evictStale(now_s - ttl_s);
        }
    }

    fn evictStale(self: *GridState, cutoff_s: i64) void {
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.committed.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_seen_s < cutoff_s) {
                stale.append(self.allocator, kv.key_ptr.*) catch continue;
            }
        }
        for (stale.items) |id| {
            if (self.committed.fetchRemove(id)) |kv| {
                self.allocator.free(kv.value.bytes);
            }
        }
    }

    /// Drop any cached/queued thumbnail for `id` so the next render re-requests
    /// it. Used when an image's pixels may have changed (reparse / overwrite) and
    /// when an image is removed — SQLite recycles the deleted row's id for the
    /// next insert, so a lingering cache entry would show the old thumbnail under
    /// the new image.
    pub fn invalidateThumbnail(self: *GridState, id: u64) void {
        if (self.committed.fetchRemove(id)) |kv| self.allocator.free(kv.value.bytes);
        {
            // Drop a stale, not-yet-drained worker result so step 2 of update()
            // doesn't re-commit it; an in-flight load regenerates from disk.
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            if (self.pending.fetchRemove(id)) |kv| self.allocator.free(kv.value);
        }
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            _ = self.queued.remove(id);
            _ = self.load_failed.remove(id);
            // A worker still decoding the id's previous file: drop its result.
            if (self.in_flight.contains(id)) self.stale_in_flight.put(id, {}) catch {};
        }
    }

    /// Worker side: hand over a finished load (`bytes` null = it failed),
    /// unless `invalidateThumbnail` made it stale meanwhile.
    pub fn finishLoad(self: *GridState, id: u64, path: []const u8, bytes: ?[]u8) void {
        self.queue_mutex.lockUncancelable(self.io);
        const stale = self.stale_in_flight.remove(id);
        if (stale) {
            self.queue_mutex.unlock(self.io);
            if (bytes) |b| self.allocator.free(b);
            return;
        }
        const b = bytes orelse {
            self.queue_mutex.unlock(self.io);
            self.noteLoadFailure(id, path);
            return;
        };
        // Still under queue_mutex, so an invalidate can't slip in between the
        // stale check and the store (it would then remove the stored result).
        self.pending_mutex.lockUncancelable(self.io);
        if (self.pending.fetchRemove(id)) |old| self.allocator.free(old.value);
        self.pending.put(id, b) catch self.allocator.free(b);
        self.pending_mutex.unlock(self.io);
        self.queue_mutex.unlock(self.io);
        if (self.wakeup_fn) |wakeup| wakeup();
    }

    /// Worker side: no thumbnail could be produced for `id`. A file deleted
    /// outside the app (gone from a directory that still exists) has its row
    /// removed now and its id queued for `drainMissingIds`; anything else (an
    /// undecodable file, or a whole directory missing, e.g. an unmounted drive,
    /// which the library scan reconciles) is just not retried.
    pub fn noteLoadFailure(self: *GridState, id: u64, path: []const u8) void {
        {
            // Covers both outcomes: a deleted id must not be re-requested before
            // the main thread drains it (removal then invalidates it).
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            self.load_failed.put(id, {}) catch {};
        }
        if (fileDeleted(self.io, path)) {
            self.loader_db_mutex.lockUncancelable(self.io);
            const deleted = self.loader_db.deleteMissingImage(id, path) catch |err| blk: {
                log.warn("remove missing {s}: {}", .{ std.Io.Dir.path.basename(path), err });
                break :blk false;
            };
            self.loader_db_mutex.unlock(self.io);
            if (deleted) {
                log.info("removed missing file {s} from the library", .{std.Io.Dir.path.basename(path)});
                self.queue_mutex.lockUncancelable(self.io);
                self.missing_ids.append(self.allocator, id) catch {};
                self.queue_mutex.unlock(self.io);
                if (self.wakeup_fn) |wakeup| wakeup();
            }
        }
    }

    /// Move the ids `noteLoadFailure` deleted from the DB into `out` (which
    /// grows with `gpa`). Main-thread only; called once per frame.
    pub fn drainMissingIds(self: *GridState, gpa: std.mem.Allocator, out: *std.ArrayList(u64)) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (self.missing_ids.items.len == 0) return;
        out.appendSlice(gpa, self.missing_ids.items) catch return;
        self.missing_ids.clearRetainingCapacity();
    }

    /// True if `id` was re-notified (reparsed / changed) during this frame's
    /// update(). Lets the detail panel reload exactly when fresh data is ready.
    pub fn wasRefreshedThisFrame(self: *const GridState, id: u64) bool {
        return self.refreshed.contains(id);
    }

    /// After a removal, focus and single-select a sensible neighbour — the item
    /// now occupying `target` (clamped to the list), i.e. the one that "slid up"
    /// into the deleted item's place, or the new last item if we deleted the end.
    /// Keeps a selected image (and a populated detail panel) instead of leaving
    /// the grid with nothing selected. Scrolls it into view. `target` is the
    /// focused index captured *before* the removal.
    pub fn focusNear(self: *GridState, target: ?usize) void {
        const n = self.images.items.len;
        self.selection.clearRetainingCapacity();
        if (n == 0) {
            self.focused_idx = null;
            self.anchor_idx = null;
            return;
        }
        const i = @min(target orelse 0, n - 1);
        self.focused_idx = i;
        self.anchor_idx = i;
        self.selection.put(self.images.items[i].id, {}) catch {};
        self.scroll_to_focused = true;
    }

    /// Whether the current view is a search, whose DB order is the ranking
    /// (BM25 for text, nearest first or RRF score for vectors). The sort
    /// settings don't apply then, and take effect again once it is cleared.
    /// Mirrors `queryEntries`.
    pub fn isRelevanceRanked(self: *const GridState) bool {
        if (self.view_mode != .library) return false;
        const e = self.query_embeddings;
        const vector = switch (self.search_mode) {
            .fts => false,
            .semantic => e.prompt != null,
            .visual => e.visual != null,
            .combined => e.prompt != null or e.visual != null,
        };
        return vector or hasFtsTerms(self.search_query);
    }

    pub fn applySortOrder(self: *GridState) void {
        // Duplicates view keeps the DB order (grouped by hash) so duplicate sets
        // stay contiguous, and a vector search keeps its relevance ranking;
        // user-facing sort controls don't apply there.
        if (self.view_mode == .duplicates or self.isRelevanceRanked()) return;

        // Remember focused image ID so we can restore focused_idx after reorder.
        const focused_id: ?u64 = if (self.focused_idx) |fi| self.images.items[fi].id else null;

        switch (self.sort_mode) {
            .date => std.mem.sort(ImageEntry, self.images.items, self.sort_dir, imageDateLt),
            .name => std.mem.sort(ImageEntry, self.images.items, self.sort_dir, imageNameLt),
            .random => {
                // Sort by hash(seed, id) so each image has a stable position
                // independent of list size — deleting one image won't reorder the rest.
                std.mem.sort(ImageEntry, self.images.items, self.sort_seed, struct {
                    fn lt(seed: u64, a: ImageEntry, b: ImageEntry) bool {
                        const ha = std.hash.Wyhash.hash(seed, std.mem.asBytes(&a.id));
                        const hb = std.hash.Wyhash.hash(seed, std.mem.asBytes(&b.id));
                        return ha < hb;
                    }
                }.lt);
            },
        }

        // Re-anchor focused_idx to the same image after sort.
        if (focused_id) |fid| {
            self.focused_idx = null;
            for (self.images.items, 0..) |img, i| {
                if (img.id == fid) {
                    self.focused_idx = i;
                    break;
                }
            }
        }
    }

    pub fn thumbSize(self: *const GridState) f32 {
        return thumb_size_min + self.thumb_fraction * (thumb_size_max - thumb_size_min);
    }

    /// Replace the current selection with all items in [from, to] (inclusive, order-independent).
    fn applyRangeSelect(self: *GridState, from: usize, to: usize) void {
        const n = self.images.items.len;
        if (n == 0) return;
        const lo = @min(from, to);
        const hi = @min(@max(from, to), n - 1);
        self.selection.clearRetainingCapacity();
        for (lo..hi + 1) |i| {
            self.selection.put(self.images.items[i].id, {}) catch {};
        }
    }

    /// Returns the actual on-disk path for an entry.
    /// For trash entries this is <data_dir>/trash/<trash_name>; for others it is entry.path.
    /// Caller is responsible for freeing if the returned slice != entry.path.
    fn diskPath(self: *GridState, entry: *const ImageEntry) []const u8 {
        const tn = entry.trash_name orelse return entry.path;
        const dd = self.data_dir orelse return entry.path;
        return std.Io.Dir.path.join(self.allocator, &.{ dd, "trash", tn }) catch entry.path;
    }

    fn requestLoad(self: *GridState, id: u64, path: []const u8, high: bool) void {
        if (self.committed.contains(id)) return;

        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queued.contains(id) or self.in_flight.contains(id) or self.load_failed.contains(id)) return;

        const path_copy = self.allocator.dupe(u8, path) catch return;
        const req = LoadRequest{ .id = id, .path = path_copy };
        const queue = if (high) &self.high_queue else &self.low_queue;
        queue.append(self.allocator, req) catch {
            self.allocator.free(path_copy);
            return;
        };
        self.queued.put(id, {}) catch {
            _ = queue.pop();
            self.allocator.free(path_copy);
            return;
        };
        self.queue_cond.signal(self.io);
    }

    pub fn render(self: *GridState) void {
        const n = self.images.items.len;
        const ts = self.thumbSize();
        const cell_w = ts + gap;
        // Must match the real laid-out cell height: content (ts + label_h) plus
        // the border (cell_border on each side) plus the vertical margin (gap).
        // The label carries no vertical padding so its content fits in label_h.
        const cell_h = ts + label_h + gap + 2 * cell_border;

        // Estimate virtual height before opening so the scrollbar decision is
        // right on the first paint.  Uses the content width measured last frame
        // (the exact basis used for `cols`) so the estimate can't disagree with
        // the actual column count once the width is stable.
        {
            const prev_w = self.last_avail_w;
            const est_cols: usize = if (prev_w > 1)
                @max(1, @as(usize, @intFromFloat(@floor(prev_w / cell_w))))
            else
                1;
            const est_rows: usize = if (n == 0) 0 else (n + est_cols - 1) / est_cols;
            self.scroll_info.virtual_size.h = @as(f32, @floatFromInt(est_rows)) * cell_h;
        }
        self.scroll_info.virtual_size.w = 0;
        self.scroll_info.vertical = .given;
        self.scroll_info.horizontal = .given;

        // Focusable container: receives keyboard events after any cell is clicked.
        var grid_box = dvui.box(@src(), .{}, .{ .expand = .both });
        defer grid_box.deinit();

        if (n == 0) {
            const is_searching = self.search_query != null or
                self.query_embeddings.any() or
                self.filters.len > 0;
            const empty_text = switch (self.view_mode) {
                .trash => i18n.t(.trash_empty),
                .duplicates => i18n.t(.duplicates_empty),
                .favorites => i18n.t(.favorites_empty),
                .library => if (is_searching) i18n.t(.search_no_results) else i18n.t(.library_empty),
            };
            dvui.label(@src(), "{s}", .{empty_text}, .{
                .tag = "grid-empty",
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .expand = .both,
                .color_text = .{ .color = style.C.text_ghost },
            });
            return;
        }

        // grid_id is used for keyboard event routing — only valid when n > 0.
        const grid_id = grid_box.data().id;

        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &self.scroll_info }, .{ .expand = .both });
        defer scroll.deinit();

        // Logical content width as computed by the scroll area itself (natural
        // px, with the scrollbar already subtracted). This is the authoritative
        // width for column layout. The previous `clipGet().w / windowNaturalScale()`
        // did a manual physical→logical conversion that is wrong whenever the
        // cumulative render scale differs from the window's natural scale (e.g.
        // HiDPI / content scaling): too small an avail_w → too few columns → the
        // virtual height (and scrollbar) came out roughly doubled.
        const avail_w = self.scroll_info.viewport.w;
        self.scroll_info.virtual_size.w = avail_w;
        if (avail_w < 1) return;
        // Remember this frame's content width for next frame's pre-open estimate.
        self.last_avail_w = avail_w;

        const cols: usize = @max(1, @as(usize, @intFromFloat(@floor(avail_w / cell_w))));
        const total_rows: usize = if (n == 0) 0 else (n + cols - 1) / cols;
        const total_h = @as(f32, @floatFromInt(total_rows)) * cell_h;

        if (total_h != self.scroll_info.virtual_size.h) {
            self.scroll_info.virtual_size.h = total_h;
            dvui.refresh(null, @src(), scroll.data().id);
        }

        // Clamp focused_idx so it stays valid after image list changes.
        if (self.focused_idx) |fi| {
            if (n == 0) {
                self.focused_idx = null;
            } else if (fi >= n) {
                self.focused_idx = n - 1;
            }
        }

        // ── Keyboard navigation ──────────────────────────────────────────────
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            switch (e.evt) {
                .key => |ke| {
                    if (!dvui.eventMatch(e, .{ .id = grid_id, .r = grid_box.data().borderRectScale().r })) continue;
                    if (ke.action != .down and ke.action != .repeat) continue;
                    if (n == 0) continue;

                    const fi: usize = self.focused_idx orelse 0;

                    switch (ke.code) {
                        .left, .right, .up, .down, .page_up, .page_down, .home, .end => {
                            const new_fi: usize = switch (ke.code) {
                                .home => 0,
                                .end  => n - 1,
                                else  => blk: {
                                    // Rows that fit in the viewport — a page step.
                                    const vp_rows: usize = @max(1, @as(usize,
                                        @intFromFloat(@floor(self.scroll_info.viewport.h / cell_h))));
                                    const delta: i64 = switch (ke.code) {
                                        .left      => -1,
                                        .right     =>  1,
                                        .up        => -@as(i64, @intCast(cols)),
                                        .down      =>  @as(i64, @intCast(cols)),
                                        .page_up   => -@as(i64, @intCast(vp_rows * cols)),
                                        .page_down =>  @as(i64, @intCast(vp_rows * cols)),
                                        else       => unreachable,
                                    };
                                    const raw = @as(i64, @intCast(fi)) + delta;
                                    break :blk if (raw < 0) 0
                                               else @min(@as(usize, @intCast(raw)), n - 1);
                                },
                            };
                            self.focused_idx = new_fi;
                            self.scroll_to_focused = true;

                            if (ke.mod.shift()) {
                                // Extend range from anchor to new position.
                                self.applyRangeSelect(self.anchor_idx orelse fi, new_fi);
                            } else if (ke.mod.control()) {
                                // Move cursor only — selection unchanged.
                            } else {
                                self.selection.clearRetainingCapacity();
                                self.selection.put(self.images.items[new_fi].id, {}) catch {};
                                self.anchor_idx = new_fi;
                            }
                            e.handle(@src(), grid_box.data());
                        },
                        .space => {
                            if (ke.mod.shift()) {
                                self.applyRangeSelect(self.anchor_idx orelse fi, fi);
                            } else {
                                const id = self.images.items[fi].id;
                                if (self.selection.contains(id)) {
                                    _ = self.selection.remove(id);
                                } else {
                                    self.selection.put(id, {}) catch {};
                                }
                                self.anchor_idx = fi;
                            }
                            e.handle(@src(), grid_box.data());
                        },
                        .a => {
                            if (ke.mod.control()) {
                                for (self.images.items) |img| {
                                    self.selection.put(img.id, {}) catch {};
                                }
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .escape => {
                            self.selection.clearRetainingCapacity();
                            e.handle(@src(), grid_box.data());
                        },
                        .delete => {
                            if (self.selection.count() > 0 or self.focused_idx != null) {
                                self.delete_requested = true;
                                self.delete_force = ke.mod.shift();
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .r => {
                            if (self.view_mode == .trash and
                                (self.selection.count() > 0 or self.focused_idx != null))
                            {
                                self.restore_requested = true;
                                e.handle(@src(), grid_box.data());
                            }
                        },
                        .enter => {
                            self.open_viewer_requested = true;
                            self.viewer_start_id = self.images.items[fi].id;
                            e.handle(@src(), grid_box.data());
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // ── Scroll to keep focused item visible (keyboard nav only) ─────────
        if (self.scroll_to_focused) {
            if (self.focused_idx) |fi| {
                const row = fi / cols;
                const item_top = @as(f32, @floatFromInt(row)) * cell_h;
                const item_bot = item_top + cell_h;
                const vp_h = self.scroll_info.viewport.h;
                if (item_top < self.scroll_info.viewport.y) {
                    self.scroll_info.viewport.y = item_top;
                } else if (item_bot > self.scroll_info.viewport.y + vp_h) {
                    self.scroll_info.viewport.y = item_bot - vp_h;
                }
                self.scroll_to_focused = false;
            }
        }

        // ── Visible row range ────────────────────────────────────────────────
        const scroll_y = self.scroll_info.viewport.y;
        const scroll_h = self.scroll_info.viewport.h;
        const first_row: usize = @intCast(@max(
            0,
            @as(i64, @intFromFloat(@floor(scroll_y / cell_h))) - 1,
        ));
        const last_row: usize = @min(
            total_rows,
            @as(usize, @intFromFloat(@ceil((scroll_y + scroll_h) / cell_h))) + 1,
        );
        const visible_rows = if (last_row > first_row) last_row - first_row else 1;

        // Subtract border contribution (2px each side = 4px per cell) so total
        // cell width = h_margin + cell_border + ts + cell_border + h_margin == avail_w/cols.
        const h_margin = (avail_w - @as(f32, @floatFromInt(cols)) * (ts + 2 * cell_border)) / @as(f32, @floatFromInt(cols)) / 2.0;

        // Prefetch zone: N screens above and below the viewport
        const buf_rows = visible_rows * prefetch_screens;
        const pf_first = if (first_row > buf_rows) first_row - buf_rows else 0;
        const pf_last = @min(total_rows, last_row + buf_rows);

        // Drop any still-queued (not yet started) loads before re-queueing the
        // current prefetch zone below. Without this, dragging the scrollbar piles
        // up requests for rows that have scrolled far away, and the worker chews
        // through that stale backlog before it reaches what's now on screen — so
        // visible thumbnails take ages to appear. In-flight loads are tracked
        // separately and finish on their own.
        {
            self.queue_mutex.lockUncancelable(self.io);
            for (self.high_queue.items) |r| {
                _ = self.queued.remove(r.id);
                self.allocator.free(r.path);
            }
            for (self.low_queue.items) |r| {
                _ = self.queued.remove(r.id);
                self.allocator.free(r.path);
            }
            self.high_queue.clearRetainingCapacity();
            self.low_queue.clearRetainingCapacity();
            self.queue_mutex.unlock(self.io);
        }

        // Touch last_seen for visible items; queue loads for prefetch zone
        const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        for (pf_first..pf_last) |row| {
            const is_visible = row >= first_row and row < last_row;
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                const entry = &self.images.items[idx];
                if (self.committed.getPtr(entry.id)) |ce| {
                    if (is_visible) ce.last_seen_s = now_s;
                } else {
                    const path = self.diskPath(entry);
                    defer if (path.ptr != entry.path.ptr) self.allocator.free(path);
                    self.requestLoad(entry.id, path, is_visible);
                }
            }
        }

        // Top spacer.
        // max_size_content must be overridden: dvui clamps every widget's size to
        // max_size (default `max_float_safe` = 2,000,000), so a spacer taller than
        // 2M px is silently capped — which pinned all content past ~2M px (≈50% of
        // a 55k-image library) off-screen and made the grid look half-empty. f32
        // stays integer-exact to 16.7M, so the true height renders fine.
        if (first_row > 0) {
            var sp = dvui.box(@src(), .{}, .{
                .id_extra = std.math.maxInt(usize),
                .min_size_content = .{ .w = 0, .h = @as(f32, @floatFromInt(first_row)) * cell_h },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = std.math.floatMax(f32) },
            });
            sp.deinit();
        }

        // Grid autoplay bookkeeping: bump the frame counter (used to evict players
        // whose cell has scrolled off), install players the openers finished, and
        // drop stale open requests. renderItem ticks/requests the visible cells.
        if (self.autoplay) {
            self.player_frame +%= 1;
            self.syncPlayerPipeline(true);
        } else {
            if (self.grid_players.count() > 0) self.clearGridPlayers(); // just turned off
            self.syncPlayerPipeline(false); // discard any in-flight opens that land
        }

        // Visible rows
        for (first_row..last_row) |row| {
            var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row,
                .expand = .horizontal,
            });
            defer hrow.deinit();
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                const focused = if (self.focused_idx) |fi| fi == idx else false;
                self.renderItem(idx, ts, h_margin, focused, grid_id);
            }
        }

        // Evict players whose cell scrolled off; keep the loop spinning while any
        // survivor is still playing so playback advances without further input.
        if (self.autoplay) {
            if (self.evictStaleCellPlayers()) dvui.refresh(null, @src(), null);
        }

        // Bottom spacer (same max_size_content override as the top spacer).
        if (last_row < total_rows) {
            const tail = total_rows - last_row;
            var sp = dvui.box(@src(), .{}, .{
                .id_extra = std.math.maxInt(usize) - 1,
                .min_size_content = .{ .w = 0, .h = @as(f32, @floatFromInt(tail)) * cell_h },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = std.math.floatMax(f32) },
            });
            sp.deinit();
        }
    }

    fn renderItem(self: *GridState, idx: usize, ts: f32, h_margin: f32, focused: bool, grid_id: dvui.Id) void {
        const entry = self.images.items[idx];
        const selected = self.selection.contains(entry.id);

        // Border: blue when focused (keyboard cursor), the ground colour
        // otherwise so the cell's footprint stays the same either way.
        // Selection is shown via corner marks instead (see below).
        const border_color: dvui.Color = if (focused) style.C.blue else style.C.canvas;

        var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx,
            .min_size_content = .{ .w = ts, .h = ts + label_h },
            .margin = .{ .x = h_margin, .y = gap / 2, .w = h_margin, .h = gap / 2 },
            .border = dvui.Rect.all(cell_border),
            .color_border = .{ .color = border_color },
        });
        defer cell.deinit();

        // ── Context menu (right-click) ────────────────────────────────────
        {
            const ctext = dvui.context(@src(), .{ .rect = cell.data().borderRectScale().r }, .{ .id_extra = idx });
            defer ctext.deinit();

            if (ctext.activePoint()) |cp| {
                // If the right-clicked item is not already in the selection, select only it.
                if (!self.selection.contains(entry.id)) {
                    self.selection.clearRetainingCapacity();
                    self.selection.put(entry.id, {}) catch {};
                    self.anchor_idx = idx;
                    self.focused_idx = idx;
                }

                var fm = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{ .id_extra = idx });
                defer fm.deinit();

                if (dvui.menuItemLabel(@src(), i18n.t(.context_view_image), .{},
                    .{ .expand = .horizontal }) != null)
                {
                    fm.close();
                    self.open_viewer_requested = true;
                    self.viewer_start_id = entry.id;
                }
                if (dvui.menuItemLabel(@src(), i18n.t(.context_copy_prompt), .{},
                    .{ .expand = .horizontal }) != null)
                {
                    fm.close();
                    self.copy_prompt_requested = true;
                    self.copy_prompt_id = entry.id;
                }
                if (dvui.menuItemLabel(@src(), i18n.t(.context_copy_image), .{},
                    .{ .expand = .horizontal }) != null)
                {
                    fm.close();
                    self.copy_image_requested = true;
                    // By id: the entry (and its path) may be gone by the time
                    // app.zig handles the request next frame.
                    self.copy_image_id = entry.id;
                }
                if (self.view_mode != .trash) { // library or duplicates
                    if (dvui.menuItemLabel(@src(), i18n.t(.context_reparse), .{},
                        .{ .expand = .horizontal }) != null)
                    {
                        fm.close();
                        self.reparse_requested = true;
                        self.reparse_id = entry.id;
                    }
                    if (self.trash_enabled) {
                        if (dvui.menuItemLabel(@src(), i18n.t(.context_send_to_trash), .{}, .{ .expand = .horizontal }) != null) {
                            fm.close();
                            self.delete_requested = true;
                            self.delete_force = false;
                        }
                    }
                } else { // .trash
                    if (dvui.menuItemLabel(@src(), i18n.t(.context_restore_from_trash), .{}, .{ .expand = .horizontal }) != null) {
                        fm.close();
                        self.restore_requested = true;
                    }
                }
                if (dvui.menuItemLabel(@src(), i18n.t(.context_delete_permanently), .{}, .{ .expand = .horizontal }) != null) {
                    fm.close();
                    self.delete_requested = true;
                    self.delete_force = true;
                }
            }
        }

        // ── Thumbnail + favorite star ─────────────────────────────────────
        // The star sits at the top-right of the thumbnail; it is shown when the
        // image is favorited (always) or while hovering the cell. It is a real
        // button rendered BEFORE the cell's click handling, so it consumes its
        // own clicks (toggling favorite) and gets hover/press feedback, while a
        // click anywhere else still selects the cell.
        const cell_hovered = cell.data().contentRectScale().r.contains(dvui.currentWindow().mouse_pt);
        const show_star = entry.favorite or cell_hovered;

        var img_rs: dvui.RectScale = undefined;
        {
            // Overlay so the favorite star can sit on top of the thumbnail.
            var img_area = dvui.overlay(@src(), .{
                .id_extra = idx,
                .min_size_content = .{ .w = ts, .h = ts },
                .background = true,
                .color_fill = .{ .color = style.C.thumb_well },
            });
            img_rs = img_area.data().contentRectScale();
            defer img_area.deinit();

            // Autoplay: if this cell is a playable type with a live frame, draw it
            // in place of the static poster. If no player is open yet, request one
            // (opened off-thread) and fall back to the poster until it's ready.
            var drew_live = false;
            if (self.autoplay and isPlayable(&entry)) {
                const now_ns = video_player_mod.VideoPlayer.nowNs(self.io);
                if (self.drawCellPlayer(entry.id, now_ns)) |cp| {
                    if (cp.pixels) |px| {
                        const fw: f32 = @floatFromInt(cp.width);
                        const fh: f32 = @floatFromInt(cp.height);
                        const scale = @min(ts / fw, ts / fh);
                        const rw = fw * scale;
                        const rh = fh * scale;
                        const mx = (ts - rw) / 2.0;
                        const my = (ts - rh) / 2.0;
                        _ = dvui.image(@src(), .{
                            // Pointer-keyed: each frame is a fresh buffer, and the
                            // previous frame's texture is invalidated on swap (see
                            // drawCellPlayer), so exactly one texture lives per cell.
                            .source = .{ .pixels = .{
                                .rgba = px, .width = cp.width, .height = cp.height, .invalidation = .ptr,
                            } },
                        }, .{
                            .id_extra = idx,
                            .min_size_content = .{ .w = rw, .h = rh },
                            .margin = .{ .x = mx, .y = my, .w = mx, .h = my },
                        });
                        drew_live = true;
                    }
                } else {
                    self.requestPlayer(&entry);
                }
            }

            if (!drew_live) if (self.committed.get(entry.id)) |ce| {
                // Scale to fit ts×ts while preserving aspect ratio, then center with margin.
                // Using explicit margin avoids DVUI layout bugs caused by gravity_y=0.5
                // triggering child_positioned mode in the vertical BoxWidget.
                const scale = @min(ts / ce.width, ts / ce.height);
                const rw = ce.width * scale;
                const rh = ce.height * scale;
                const mx = (ts - rw) / 2.0;
                const my = (ts - rh) / 2.0;
                _ = dvui.image(@src(), .{
                    // Key dvui's texture cache on the JPEG *content*, not the byte
                    // pointer. After a thumbnail is freed (delete / reparse) the
                    // allocator can hand the same address to a different image's
                    // bytes; pointer-keyed caching (.ptr, the default) would then
                    // show the stale texture for the new image.
                    .source = .{ .imageFile = .{ .bytes = ce.bytes, .invalidation = .bytes } },
                }, .{
                    .id_extra = idx,
                    .min_size_content = .{ .w = rw, .h = rh },
                    .margin = .{ .x = mx, .y = my, .w = mx, .h = my },
                });
            };

            if (show_star) {
                var bw: dvui.ButtonWidget = undefined;
                bw.init(@src(), .{}, .{
                    .id_extra = idx,
                    .min_size_content = .{ .w = star_sz, .h = star_sz },
                    .gravity_x = 1.0,
                    .gravity_y = 0.0,
                    .margin = .{ .x = star_margin, .y = star_margin, .w = star_margin, .h = star_margin },
                    .padding = dvui.Rect.all(3),
                    .corners = .all(star_sz),
                });
                bw.processEvents();
                // Dark circular backdrop for legibility on any thumbnail; it
                // darkens on hover and again on press (the click feedback).
                const bg_a: u8 = if (bw.pressed()) 150 else if (bw.hovered()) 100 else 50;
                bw.data().borderAndBackground(.{ .fill_color = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = bg_a } } });
                // Favorited → yellow, translucent when idle and solid on
                // hover/press. Not favorited → faint white that brightens on
                // hover/press so it reads as clickable. The icon is tinted via
                // color_text (applied as a colormod) — the reliable way to
                // recolor a currentColor-based icon.
                const star_color: dvui.Color = if (entry.favorite)
                    style.tint(style.C.star, if (bw.hovered() or bw.pressed()) 255 else 150)
                else
                    style.tint(style.C.text_hi, if (bw.pressed()) 255 else if (bw.hovered()) 215 else 120);
                dvui.icon(@src(), "favorite", app_icons.star, .{}, .{
                    .id_extra = idx,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .min_size_content = .{ .w = star_sz - 6, .h = star_sz - 6 },
                    .color_text = .{ .color = star_color },
                });
                if (bw.clicked()) self.favorite_toggle_id = entry.id;
                bw.deinit();
            }
        }

        if (dvui.clickedEx(cell.data(), .{})) |click_evt| {
            // Route subsequent key events to the grid container.
            dvui.focusWidget(grid_id, null, null);

            const mod = switch (click_evt) {
                .mouse => |me| me.mod,
                else => dvui.enums.Mod.none,
            };

            if (mod.control()) {
                // Ctrl+click: toggle this item, keep others.
                if (self.selection.contains(entry.id)) {
                    _ = self.selection.remove(entry.id);
                } else {
                    self.selection.put(entry.id, {}) catch {};
                }
                self.anchor_idx = idx;
            } else if (mod.shift()) {
                // Shift+click: range from anchor to clicked item.
                self.applyRangeSelect(self.anchor_idx orelse idx, idx);
            } else {
                // Plain click: single selection.
                self.selection.clearRetainingCapacity();
                self.selection.put(entry.id, {}) catch {};
                self.anchor_idx = idx;
            }
            self.focused_idx = idx;

            // Double-click detection: same image clicked twice within 400 ms.
            const now_ns: i96 = std.Io.Clock.real.now(self.io).nanoseconds;
            const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
            if (self.dblclick_last_id == entry.id and self.dblclick_last_ns > 0) {
                const delta_ms = now_ms - self.dblclick_last_ns;
                if (delta_ms >= 0 and delta_ms < 400) {
                    self.open_viewer_requested = true;
                    self.viewer_start_id = entry.id;
                    self.dblclick_last_id = 0;
                    self.dblclick_last_ns = 0;
                } else {
                    self.dblclick_last_id = entry.id;
                    self.dblclick_last_ns = now_ms;
                }
            } else {
                self.dblclick_last_id = entry.id;
                self.dblclick_last_ns = now_ms;
            }
        }

        // Drag-to-external: if captured and motion exceeds drag threshold, start XDND.
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .mouse) continue;
            if (e.evt.mouse.action != .motion) continue;
            if (!dvui.captured(cell.data().id)) continue;
            if (dvui.dragging(e.evt.mouse, null) == null) continue;
            e.handled = true;
            dvui.captureMouse(null, e.num);
            dvui.dragEnd(e.evt.mouse.button);
            log.debug("drag gesture fired on id={d}", .{entry.id});
            self.drag_requested = true;
            self.drag_requested_ids.clearRetainingCapacity();
            if (self.selection.contains(entry.id)) {
                // Drag all selected images
                var it = self.selection.keyIterator();
                while (it.next()) |id| {
                    self.drag_requested_ids.append(self.allocator, id.*) catch {};
                }
            } else {
                self.drag_requested_ids.append(self.allocator, entry.id) catch {};
            }
        }

        // Selection indicator: right-triangles in the top-left and bottom-right
        // corners. Blue, because selection is the user's own choice — and blue
        // survives on a thumbnail where white did not, since a photograph is far
        // more likely to be white in a corner than accent-blue.
        if (selected) {
            const sz = 12 * img_rs.s;
            const r = img_rs.r;
            const c = style.C.blue;
            const alloc = dvui.currentWindow().arena();

            var tl = dvui.Path.Builder.init(alloc);
            defer tl.deinit();
            tl.addPoint(.{ .x = r.x,        .y = r.y        });
            tl.addPoint(.{ .x = r.x + sz,   .y = r.y        });
            tl.addPoint(.{ .x = r.x,        .y = r.y + sz   });
            tl.build().fillConvex(.{ .color = .{ .color = c }, .fade = 0 });

            var br = dvui.Path.Builder.init(alloc);
            defer br.deinit();
            br.addPoint(.{ .x = r.x + r.w,        .y = r.y + r.h        });
            br.addPoint(.{ .x = r.x + r.w - sz,   .y = r.y + r.h        });
            br.addPoint(.{ .x = r.x + r.w,        .y = r.y + r.h - sz   });
            br.build().fillConvex(.{ .color = .{ .color = c }, .fade = 0 });
        }

        // A filename is user data and can hold any script, so it goes through
        // the run splitter, and is cut to the cell width with a measured
        // ellipsis rather than wrapped — a wrapped caption would make the cell
        // taller than `cell_h` and desync the virtual scroll height.
        var name_buf: [512]u8 = undefined;
        fonts.richLine(@src(), style.ellipsize(&name_buf, entry.filename, style.F.caption, ts - 4), .{
            .id_extra = idx,
            .min_size_content = .{ .w = ts, .h = label_h },
            .max_size_content = .{ .w = ts, .h = dvui.max_float_safe },
            .expand = .horizontal,
            .font = style.F.caption,
            .color_text = .{ .color = if (focused or selected) style.C.text_hi else style.C.text_dim },
            // Horizontal padding only: vertical padding would make the rendered
            // cell taller than cell_h and desync the virtual scroll height.
            .padding = .{ .x = 2 },
        });
    }
};

/// True when `path` no longer exists but its directory does, i.e. the file
/// was deleted. A missing directory is not treated as a deletion.
pub fn fileDeleted(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const dir = std.Io.Dir.path.dirname(path) orelse return false;
            cwd.access(io, dir, .{}) catch return false;
            return true;
        },
        else => return false,
    };
    return false;
}

/// Whether a path is a video DiffKeep indexes (poster thumbnail stored in DB).
pub fn isVideoPath(path: []const u8) bool {
    return media.isVideoFile(path);
}

// ── Sort comparators ──────────────────────────────────────────────────────────

fn imageDateLt(dir: SortDir, a: ImageEntry, b: ImageEntry) bool {
    // null mtime sorts to end regardless of direction
    if (a.mtime == null and b.mtime == null) return false;
    if (a.mtime == null) return false;
    if (b.mtime == null) return true;
    return if (dir == .desc) a.mtime.? > b.mtime.? else a.mtime.? < b.mtime.?;
}

fn imageNameLt(dir: SortDir, a: ImageEntry, b: ImageEntry) bool {
    const cmp = std.mem.order(u8, a.filename, b.filename);
    return if (dir == .asc) cmp == .lt else cmp == .gt;
}

// ── Worker thread ─────────────────────────────────────────────────────────────

fn workerFn(state: *GridState) void {
    while (true) {
        state.queue_mutex.lockUncancelable(state.io);
        while (!state.stop.load(.acquire) and
            state.high_queue.items.len == 0 and
            state.low_queue.items.len == 0)
        {
            state.queue_cond.waitUncancelable(state.io, &state.queue_mutex);
        }

        if (state.stop.load(.acquire)) {
            state.queue_mutex.unlock(state.io);
            break;
        }

        const req: LoadRequest = if (state.high_queue.items.len > 0)
            state.high_queue.orderedRemove(0)
        else
            state.low_queue.orderedRemove(0);

        // Move from queued → in_flight so requestLoad won't re-queue it while the
        // per-frame queue rebuild is dropping stale requests.
        _ = state.queued.remove(req.id);
        state.in_flight.put(req.id, {}) catch {};
        state.queue_mutex.unlock(state.io);
        defer {
            state.queue_mutex.lockUncancelable(state.io);
            _ = state.in_flight.remove(req.id);
            _ = state.stale_in_flight.remove(req.id);
            state.queue_mutex.unlock(state.io);
        }
        defer state.allocator.free(req.path);

        // Video posters live in the DB (libvips can't open mp4/webm); for those,
        // always read the stored blob. Otherwise use the DB only when configured.
        const is_video = isVideoPath(req.path);
        var bytes: ?[]u8 = null;
        if (state.thumbnails_in_db.load(.acquire) or is_video) {
            state.loader_db_mutex.lockUncancelable(state.io);
            bytes = state.loader_db.getThumbnailBytes(state.allocator, req.id) catch null;
            state.loader_db_mutex.unlock(state.io);
        }

        // Fall back to on-the-fly VIPS generation (images only).
        if (bytes == null and !is_video) {
            const path_z = state.allocator.dupeSentinel(u8, req.path, 0) catch continue;
            defer state.allocator.free(path_z);
            bytes = vips.thumbnailToJpeg(state.allocator, path_z, @as(c_int, @intFromFloat(thumb_size_max))) catch |err| blk: {
                log.warn("vips thumbnail {s}: {}", .{ std.Io.Dir.path.basename(req.path), err });
                break :blk null;
            };
        }

        state.finishLoad(req.id, req.path, bytes);
    }
    vips.threadShutdown();
}
