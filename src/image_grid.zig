const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const bg = @import("bg.zig");
const vq = @import("view_query.zig");
const thumb_loader = @import("thumb_loader.zig");
const grid_players = @import("grid_players.zig");
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

// The view types live in view_query.zig (no UI); re-exported for the grid's users.
pub const SortMode = vq.SortMode;
pub const SortDir = vq.SortDir;
pub const ViewMode = vq.ViewMode;
pub const SearchMode = vq.SearchMode;
pub const QueryEmbeddings = vq.QueryEmbeddings;
pub const ImageEntry = vq.ImageEntry;
pub const ViewQuery = vq.ViewQuery;
pub const LoadedView = vq.LoadedView;
pub const loadView = vq.loadView;
pub const sanitizeFtsQuery = vq.sanitizeFtsQuery;

// ── Layout constants ──────────────────────────────────────────────────────────

pub const thumb_size_min: f32 = 80;
pub const thumb_size_max: f32 = 320;
// Favorite star overlay (top-right of each thumbnail), in logical px.
const star_sz: f32 = 22;
const star_margin: f32 = 4;
const gap: f32 = 8;
const cell_border: f32 = 2; // border on each side; must be factored into h_margin
const label_h: f32 = 20;
const prefetch_screens: usize = 2;

const ViewLoad = bg.Latest(LoadedView, LoadedView.free);

/// Load `query` (owned; freed here) on the grid's own connection.
fn loadTask(ticket: ViewLoad.Ticket, g: *GridState, query: ViewQuery) ?LoadedView {
    var q = query;
    defer q.deinit(g.allocator);
    // A newer view request is already on its way: don't run this query.
    if (!ticket.current()) return null;
    return loadView(&g.view_db, g.allocator, q) catch |err| {
        log.warn("view load failed: {}", .{err});
        return null;
    };
}

// ── GridState ─────────────────────────────────────────────────────────────────

pub const GridState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    // Image list — main-thread only after startWorker()
    images: std.ArrayList(ImageEntry) = .empty,

    // Background view loading (reloadImages): a newer request supersedes an
    // older one, and update() applies only the latest.
    load: ViewLoad = .{},
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

    /// Connection for background view loads, so a long list / FTS / KNN query
    /// never holds the main connection's mutex while the UI needs it. Its own
    /// `db_mutex` serializes overlapping loads.
    view_db: db_mod.VectorDb,
    /// Thumbnail cache and its loader threads.
    thumbs: thumb_loader.ThumbLoader,

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
    // config each frame by app.zig. Main-thread only.
    autoplay: bool = false,
    players: grid_players.PlayerPool,

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
        var thumbs = try thumb_loader.ThumbLoader.init(io, allocator, db, thumbnails_in_db, @intFromFloat(thumb_size_max), wakeup_fn);
        errdefer thumbs.deinit();
        var view_db = try db.getConnection();
        errdefer view_db.deinit();
        var state = GridState{
            .io = io,
            .allocator = allocator,
            .load_dropped = std.AutoHashMap(u64, void).init(allocator),
            .refreshed = std.AutoHashMap(u64, void).init(allocator),
            .selection = std.AutoHashMap(u64, void).init(allocator),
            .thumbs = thumbs,
            .view_db = view_db,
            .wakeup_fn = wakeup_fn,
            .players = .init(io, allocator, wakeup_fn),
        };

        // The image list loads in the background: call reloadImages once the
        // grid is at its final address (the load task points into it).
        const now_ns = std.Io.Clock.real.now(io).nanoseconds;
        state.sort_seed = @truncate(@abs(now_ns));
        state.applySortOrder();
        return state;
    }

    /// Start the background loader thread pool. Call this after the GridState is at its
    /// final stable address (e.g. stored as a module-level global).
    pub fn startWorker(self: *GridState) !void {
        try self.thumbs.start();
        try self.players.start();
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
        self.load.deinit();
        if (self.search_query) |q| self.allocator.free(q);
        self.load_dropped.deinit();
        for (self.load_added.items) |e| self.allocator.free(e.path);
        self.load_added.deinit(self.allocator);
        self.thumbs.deinit();
        self.players.deinit();

        self.refreshed.deinit();

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
        self.load_keep_scroll = opts.keep_scroll;
        self.load.wakeup_fn = self.wakeup_fn;
        _ = self.load.start(self.io, self.allocator, loadTask, .{ self, query }) catch |err| {
            var q = query;
            q.deinit(self.allocator);
            return err;
        };
    }

    /// True while a requested reload hasn't been applied yet.
    pub fn reloadPending(self: *const GridState) bool {
        return self.load.pending();
    }

    /// Generation of the newest reload request, and of the last one applied
    /// (a search is loading until the second reaches the first).
    pub fn requestedGen(self: *const GridState) u64 {
        return self.load.gen.load(.acquire);
    }
    pub fn appliedGen(self: *const GridState) u64 {
        return self.load.taken_gen;
    }

    /// Wait for in-flight loads and apply the latest. For tests and tools: the
    /// app lets update() apply loads as they finish.
    pub fn awaitReload(self: *GridState) void {
        self.load.awaitAll();
        _ = self.applyReloadIfDone();
    }

    /// Record ids removed from the grid while a load is in flight.
    pub fn noteRemoved(self: *GridState, id: u64) void {
        if (self.reloadPending()) self.load_dropped.put(id, {}) catch {};
    }

    /// Main thread: swap in a finished load if it is the latest request.
    fn applyReloadIfDone(self: *GridState) bool {
        const outcome = self.load.take() orelse return false;
        // A failed load (null) keeps the current list.
        if (outcome.value) |v| {
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
        self.thumbs.clearQueued();
        for (self.images.items) |e| {
            self.allocator.free(e.path);
            if (e.trash_name) |tn| self.allocator.free(tn);
        }
        // Live cell players reference image ids; the list is about to change.
        self.players.clear();
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

    /// Whether an entry is a live-playable type (animated image or video).
    fn isPlayable(e: *const ImageEntry) bool {
        return e.media_type == .animated or e.media_type == .video;
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
                self.thumbs.invalidate(e.id);
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
                    self.thumbs.invalidate(e.id);
                    self.refreshed.put(e.id, {}) catch {};
                    self.allocator.free(e.path);
                    continue;
                }
                // A newly appearing id may be one SQLite recycled from a just-
                // deleted image; clear any cache entry it left behind (and any
                // stale in-flight load result) so this image loads its own thumb.
                // Do this even when the image isn't shown here, so the stale
                // thumbnail can't resurface when it later appears in its own view.
                self.thumbs.invalidate(e.id);
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

        // 2. Move finished thumbnails into the cache; evict old ones.
        self.thumbs.commitPending();
    }

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
        return vq.isRelevanceRanked(self.currentQuery());
    }

    pub fn applySortOrder(self: *GridState) void {
        // Duplicates view keeps the DB order (grouped by hash) so duplicate sets
        // stay contiguous, and a search keeps its relevance ranking;
        // user-facing sort controls don't apply there.
        if (self.view_mode == .duplicates or self.isRelevanceRanked()) return;

        // Remember focused image ID so we can restore focused_idx after reorder.
        const focused_id: ?u64 = if (self.focused_idx) |fi| self.images.items[fi].id else null;
        vq.sortEntries(self.images.items, self.sort_mode, self.sort_dir, self.sort_seed);

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
        self.thumbs.clearQueued();

        // Touch last_seen for visible items; queue loads for prefetch zone
        const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        for (pf_first..pf_last) |row| {
            const is_visible = row >= first_row and row < last_row;
            for (0..cols) |col| {
                const idx = row * cols + col;
                if (idx >= n) break;
                const entry = &self.images.items[idx];
                if (self.thumbs.committed.getPtr(entry.id)) |ce| {
                    if (is_visible) ce.last_seen_s = now_s;
                } else {
                    const path = self.diskPath(entry);
                    defer if (path.ptr != entry.path.ptr) self.allocator.free(path);
                    self.thumbs.request(entry.id, path, is_visible);
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
        self.players.beginFrame(self.autoplay);

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
            if (self.players.endFrame()) dvui.refresh(null, @src(), null);
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
                if (self.players.draw(entry.id, now_ns)) |cp| {
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
                    const path = self.diskPath(&entry);
                    defer if (path.ptr != entry.path.ptr) self.allocator.free(path);
                    self.players.request(entry.id, path);
                }
            }

            if (!drew_live) if (self.thumbs.committed.get(entry.id)) |ce| {
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
