const std = @import("std");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const comfy_mod = @import("parse/comfy.zig");
const prompt_clean = @import("parse/prompt_clean.zig");
const models = @import("models.zig");
const notifier_mod = @import("notifier.zig");
const embedder_mod = @import("embedder.zig");
const video = @import("video");
const vips = @import("vips");
const media = @import("media.zig");
const log = std.log.scoped(.scan);

/// Gather ComfyUI metadata sections from a non-PNG image's raw bytes. ComfyUI's
/// WebP saver embeds the workflow JSON (prefixed "workflow:") and prompt JSON
/// (prefixed "prompt:") as ASCII in EXIF. We scan the file buffer for those
/// markers and brace-match the JSON object out — reading via libexif instead
/// would truncate these long values. `aa` is an arena; the JSON slices point
/// into `buffer` and are duped into it. ComfyUI writes each marker exactly once.
fn gatherEmbeddedSections(
    aa: std.mem.Allocator,
    buffer: []const u8,
    sections: *std.ArrayList(comfy_mod.ComfyParser.RawSection),
) void {
    const markers = [_]struct { marker: []const u8, keyword: []const u8 }{
        .{ .marker = "workflow:{", .keyword = "workflow" },
        .{ .marker = "prompt:{", .keyword = "prompt" },
    };
    for (markers) |m| {
        const at = std.mem.find(u8, buffer, m.marker) orelse continue;
        // The marker ends with '{', so the JSON object begins at that brace.
        const json = comfy_mod.extractJsonObject(buffer[at + m.marker.len - 1 ..]) orelse continue;
        const kw = aa.dupe(u8, m.keyword) catch continue;
        const tx = aa.dupe(u8, json) catch continue;
        sections.append(aa, .{ .keyword = kw, .text = tx }) catch {};
    }
}

/// Collect a PNG's iTXt then tEXt chunks as parser sections (file order within
/// each kind, so the shared selector picks the first of each; an iTXt
/// "parameters" wins over tEXt). Strings are duped into the arena `aa`.
/// Returns whether the PNG was truncated (ended before IEND; maybe still being
/// written) — its sections are still gathered.
fn gatherPngSections(
    aa: std.mem.Allocator,
    io: std.Io,
    buffer: []const u8,
    sections: *std.ArrayList(comfy_mod.ComfyParser.RawSection),
) !bool {
    var png_parser = try png_mod.PngParser.init(aa, io);
    defer png_parser.deinit();
    try png_parser.parseBuffer(buffer);
    const truncated = png_parser.truncated;
    {
        const itxt = png_parser.getITxtChunks() catch &[_]png_mod.Chunk{};
        defer aa.free(itxt);
        for (itxt) |chunk| {
            var content = png_parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(aa);
            if (content.compressed) continue;
            const kw = aa.dupe(u8, content.keyword) catch continue;
            const tx = aa.dupe(u8, content.text) catch continue;
            sections.append(aa, .{ .keyword = kw, .text = tx }) catch {};
        }
    }
    const text_chunks = try png_parser.getTExtChunks();
    defer aa.free(text_chunks);
    for (text_chunks) |chunk| {
        var content = png_parser.parseTExtChunk(chunk) catch continue;
        defer content.deinit(aa);
        const kw = aa.dupe(u8, content.keyword) catch continue;
        const tx = aa.dupe(u8, content.text) catch continue;
        sections.append(aa, .{ .keyword = kw, .text = tx }) catch {};
    }
    return truncated;
}

/// Overwrite `image`'s generation metadata with `result`, clearing every field
/// when there is none. Strings are duped with `a` (the image's allocator).
fn applyParseResult(a: std.mem.Allocator, image: *models.Image, maybe_result: ?comfy_mod.ParseResult) void {
    const r: comfy_mod.ParseResult = maybe_result orelse .{};
    const dupeOpt = struct {
        fn f(alloc: std.mem.Allocator, v: ?[]const u8) ?[]const u8 {
            return if (v) |x| alloc.dupe(u8, x) catch null else null;
        }
    }.f;
    if (image.positivePromptText) |p| a.free(p);
    image.positivePromptText = dupeOpt(a, r.positive_prompt);
    if (image.negativePromptText) |p| a.free(p);
    image.negativePromptText = dupeOpt(a, r.negative_prompt);
    if (image.model) |m| a.free(m);
    image.model = dupeOpt(a, r.model);
    if (image.sampler) |v| a.free(v);
    image.sampler = dupeOpt(a, r.sampler);
    if (image.scheduler) |v| a.free(v);
    image.scheduler = dupeOpt(a, r.scheduler);
    image.cfg = r.cfg;
    image.steps = r.steps;
    image.seed = r.seed;
    if (image.loras) |l| a.free(l);
    image.loras = lorasToString(a, r.loras);
}

/// Join a slice of lora names into a single newline-separated string.
fn lorasToString(allocator: std.mem.Allocator, loras: ?[]const []const u8) ?[]const u8 {
    const items = loras orelse return null;
    if (items.len == 0) return null;
    var total: usize = 0;
    for (items) |l| total += l.len + 1;
    const buf = allocator.alloc(u8, total - 1) catch return null;
    var pos: usize = 0;
    for (items, 0..) |l, i| {
        @memcpy(buf[pos .. pos + l.len], l);
        pos += l.len;
        if (i < items.len - 1) { buf[pos] = '\n'; pos += 1; }
    }
    return buf;
}

/// Max items an embed consumer drains from the queue into one batched forward,
/// and the number of files parsed/thumbnailed concurrently per CPU batch. 32 gives
/// the CUDA batches enough work to beat CPU (see `test_tp_batch`: gemma 4.7 ms/item
/// at b=32 vs 6.0 on CPU; snowflake/siglip even more) and keeps the queue deep
/// enough that consumers hit full batches. The embedder's per-call router sends
/// batches >= `config.embed_gpu_threshold` to the GPU and single items to the CPU.
pub const EMBED_BATCH_SIZE: usize = 32;

pub const ScanStats = struct {
    added: u32 = 0,
    updated: u32 = 0,
    removed: u32 = 0,
    unchanged: u32 = 0,
};

/// Holds the inputs needed to embed a single file. Pushed by processFile onto the
/// EmbedQueue; an embed consumer drains a mini-batch of these and runs embedBatch.
pub const EmbedInput = struct {
    image_id: u64,
    /// owned; the image's library path, so the vector is only stored while the
    /// row still belongs to this file (it may be deleted and its id recycled
    /// while the item waits in the queue).
    path: [:0]const u8,
    prompt_text: ?[]const u8, // owned; null = no prompt embedding needed
    want_image: bool, // embed the image at `path`
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EmbedInput) void {
        self.allocator.free(self.path);
        if (self.prompt_text) |p| self.allocator.free(p);
    }
};

/// Thread-safe bounded FIFO of EmbedInputs. CPU tasks push; embed consumers
/// pop and call the embedder, so CPU work and inference overlap. When full,
/// `push` waits for the consumers: without that, a slower embedder (CPU) let
/// the scan queue a prompt and path for every file in the library.
pub const EmbedQueue = struct {
    mutex:       std.Io.Mutex                 = .init,
    not_empty:   std.Io.Condition             = .init,
    not_full:    std.Io.Condition             = .init,
    items:       std.Deque(EmbedInput)        = .empty,
    done:        bool                         = false,
    /// Consumers still running. Once there are none (stopped, or none could
    /// start) `push` drops items instead of waiting for room forever.
    consumers:   usize                        = 0,
    allocator:   std.mem.Allocator,
    embed_done:  *std.atomic.Value(u32),
    embed_total: *std.atomic.Value(u32),

    /// Enough for every GPU consumer to take a full batch with as many waiting.
    pub const capacity = 8 * EMBED_BATCH_SIZE;

    pub fn deinit(q: *EmbedQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        while (q.items.popFront()) |item| {
            var it = item;
            it.deinit();
        }
        q.items.deinit(q.allocator);
        q.mutex.unlock(io);
    }

    pub fn push(q: *EmbedQueue, io: std.Io, item: EmbedInput) void {
        var it = item;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        while (q.items.len >= capacity and q.consumers > 0)
            q.not_full.waitUncancelable(io, &q.mutex);
        if (q.consumers == 0) return it.deinit();
        q.items.pushBack(q.allocator, it) catch return it.deinit();
        _ = q.embed_total.fetchAdd(1, .acq_rel);
        q.not_empty.signal(io);
    }

    pub fn finish(q: *EmbedQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        q.done = true;
        log.debug("embed queue: finish called, broadcasting (items remaining: {d})", .{q.items.len});
        q.not_empty.broadcast(io);
        q.mutex.unlock(io);
    }

    /// A consumer is exiting; wake producers waiting for room it won't make.
    pub fn consumerExit(q: *EmbedQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        q.consumers -= 1;
        q.not_full.broadcast(io);
        q.mutex.unlock(io);
    }

    /// Blocks until an item is available. Returns null when done and empty.
    pub fn pop(q: *EmbedQueue, io: std.Io) ?EmbedInput {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        while (q.items.len == 0 and !q.done)
            q.not_empty.waitUncancelable(io, &q.mutex);
        return q.takeLocked(io);
    }

    /// Non-blocking pop: returns an item if one is queued right now, else null
    /// (never waits). Used to grow a batch from whatever is already available.
    pub fn tryPop(q: *EmbedQueue, io: std.Io) ?EmbedInput {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.takeLocked(io);
    }

    fn takeLocked(q: *EmbedQueue, io: std.Io) ?EmbedInput {
        const item = q.items.popFront() orelse return null;
        q.not_full.signal(io);
        return item;
    }
};

pub const ScanCtx = struct {
    path: []const u8,
    library_id: u64,
    db: *db_mod.VectorDb,
    allocator: std.mem.Allocator,
    stats: *AtomicStats,
    io: std.Io,
    stop: *std.atomic.Value(bool),
    files_scanned: *std.atomic.Value(u32),
    thumbnails_in_db: bool,
    prompt_embeddings: bool,
    image_embeddings: bool,
    precomputed_mtime: i64,
    notifier: ?*notifier_mod.ImageNotifier,
    embedder: ?*embedder_mod.Embedder = null,
    has_prompt_embedding: bool = false,
    has_image_embedding: bool = false,
    /// Queue mode: when non-null, processFile pushes EmbedInputs here instead
    /// of calling the embedder inline. A separate consumer goroutine drains
    /// the queue concurrently. Null for single-file watcher paths.
    embed_queue: ?*EmbedQueue = null,
};

/// What a directory walk saw, beyond the per-file work it queued.
const WalkState = struct {
    /// Supported media files found (whether processed or unchanged).
    media_seen: usize = 0,
    /// Subdirectories that couldn't be listed. Rows under them are kept: their
    /// files are unreadable, not known to be gone. Paths owned.
    skipped_dirs: std.ArrayList([]const u8) = .empty,

    fn deinit(w: *WalkState, a: std.mem.Allocator) void {
        for (w.skipped_dirs.items) |d| a.free(d);
        w.skipped_dirs.deinit(a);
    }

    fn underSkipped(w: *const WalkState, path: []const u8) bool {
        for (w.skipped_dirs.items) |d| {
            if (path.len > d.len and std.mem.startsWith(u8, path, d) and path[d.len] == '/') return true;
        }
        return false;
    }
};

pub const AtomicStats = struct {
    added: std.atomic.Value(u32) = .init(0),
    updated: std.atomic.Value(u32) = .init(0),
    unchanged: std.atomic.Value(u32) = .init(0),

    fn snapshot(self: *const AtomicStats) ScanStats {
        return .{
            .added = self.added.load(.acquire),
            .updated = self.updated.load(.acquire),
            .unchanged = self.unchanged.load(.acquire),
            .removed = 0,
        };
    }
};

pub const LibraryScanner = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.VectorDb,
    notifier: ?*notifier_mod.ImageNotifier,
    embedder: ?*embedder_mod.Embedder = null,  // borrowed, not owned
    /// When set, `scanLibrary` appends the ids of rows it removes (files gone
    /// from disk) so the caller can drop them from the grid and viewers.
    /// Allocated with `self.allocator`.
    removed_ids: ?*std.ArrayList(u64) = null,

    pub fn init(_: std.mem.Allocator, db: *db_mod.VectorDb, notifier: ?*notifier_mod.ImageNotifier) LibraryScanner {
        // c_allocator (glibc malloc) is used throughout because processFile tasks
        // run on concurrent OS threads — the GPA is not thread-safe.
        return .{ .allocator = std.heap.smp_allocator, .db = db, .notifier = notifier };
    }

    pub fn deinit(_: *LibraryScanner) void {}

    /// Process a single file path that was reported as new or changed by the
    /// fs watcher.  Runs synchronously; caller is responsible for spawning a
    /// background task if needed.
    pub fn processSingleFile(
        self: *LibraryScanner,
        io: std.Io,
        library_id: u64,
        path: []const u8,
        stop: *std.atomic.Value(bool),
        thumbnails_in_db: bool,
        prompt_embeddings: bool,
        image_embeddings: bool,
    ) void {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        const path_owned = self.allocator.dupe(u8, path) catch return;
        var dummy_stats: AtomicStats = .{};
        var dummy_count: std.atomic.Value(u32) = .init(0);
        processFile(.{
            .path = path_owned,
            .library_id = library_id,
            .db = self.db,
            .allocator = self.allocator,
            .stats = &dummy_stats,
            .io = io,
            .stop = stop,
            .files_scanned = &dummy_count,
            .thumbnails_in_db = thumbnails_in_db,
            .prompt_embeddings = prompt_embeddings,
            .image_embeddings = image_embeddings,
            .precomputed_mtime = mtime,
            .notifier = self.notifier,
            .embedder = self.embedder,
        });
    }

    /// Walk `library_path`, process new/changed PNGs, and remove DB entries for
    /// files that no longer exist on disk.
    pub fn scanLibrary(
        self: *LibraryScanner,
        io: std.Io,
        library_id: u64,
        library_path: []const u8,
        stop: *std.atomic.Value(bool),
        files_scanned: *std.atomic.Value(u32),
        embed_done: *std.atomic.Value(u32),
        embed_total: *std.atomic.Value(u32),
        thumbnails_in_db: bool,
        prompt_embeddings: bool,
        image_embeddings: bool,
    ) !ScanStats {
        var stats: AtomicStats = .{};

        // Single-query prefetch: replaces N per-file SELECTs and the seen HashSet.
        var known = try self.db.prefetchLibraryImages(self.allocator, library_id);
        defer {
            var it = known.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            known.deinit();
        }

        // Embed consumer: runs concurrently with CPU tasks, draining the queue
        // as processFile tasks push EmbedInputs into it.
        var embed_queue: EmbedQueue = .{
            .allocator   = self.allocator,
            .embed_done  = embed_done,
            .embed_total = embed_total,
        };
        var embed_group: std.Io.Group = .init;
        if (self.embedder) |emb| {
            // Surface a misconfigured/failed encoder loudly: otherwise the matching
            // sub-batch is silently skipped and the scan looks like it did nothing.
            if (prompt_embeddings and !emb.hasPromptEncoder())
                log.warn("prompt_embeddings on but no text encoder loaded — check text_model_dir; prompts will be skipped", .{});
            if (image_embeddings and !emb.hasVisualEncoder())
                log.warn("image_embeddings on but no visual encoder loaded — check visual_model_dir (needs a timm SigLIP2 dir with open_clip_model.safetensors); images will be skipped", .{});
            // Multiple consumers only pay off on the GPU: the GPU forward is
            // serialized by the embed mutex, but image decode (vips) is CPU-heavy
            // and serial within a batch, so a few consumers decode concurrently to
            // keep the GPU fed (~3 decode streams while one holds the GPU is plenty
            // even for slow decodes). On CPU one consumer already uses every core.
            const n_consumers: usize = if (emb.hasGpu()) 4 else 1;
            // Counted before they start: one could exit (stop) at once.
            embed_queue.consumers = n_consumers;
            var spawned: usize = 0;
            for (0..n_consumers) |_| {
                embed_group.concurrent(io, embedConsumer, .{EmbedConsumerCtx{
                    .queue     = &embed_queue,
                    .db        = self.db,
                    .emb       = emb,
                    .allocator = self.allocator,
                    .stop      = stop,
                    .io        = io,
                }}) catch |err| {
                    log.warn("spawn embed consumer: {}", .{err});
                    embed_queue.consumerExit(io);
                    continue;
                };
                spawned += 1;
            }
            log.debug("embed consumers spawned: {d} (gpu={})", .{ spawned, emb.hasGpu() });
        }

        var group: std.Io.Group = .init;
        var in_flight: usize = 0;
        var walk: WalkState = .{};
        defer walk.deinit(self.allocator);
        const walk_err = self.walkDirectory(
            io, library_id, library_path, &stats, &known,
            stop, files_scanned, thumbnails_in_db, prompt_embeddings, image_embeddings,
            &group, &in_flight, &embed_queue, &walk, true,
        );
        group.await(io) catch |err| log.warn("final cpu group.await: {}", .{err});
        log.debug("scanLibrary: all cpu tasks done, signaling embed consumer", .{});

        // Signal consumer that no more items are coming, then wait for it to drain.
        embed_queue.finish(io);
        embed_group.await(io) catch |err| log.warn("embed group.await: {}", .{err});
        log.debug("scanLibrary: embed consumer joined", .{});
        embed_queue.deinit(io);

        try walk_err;

        // Reconciliation: any entry not marked seen no longer exists on disk.
        // Skip if the scan was stopped early — unseen entries may simply not have
        // been reached yet, not actually missing from disk. Also skip when the
        // walk found no media at all but the library has images: that is an
        // unmounted drive (its empty mount point) or a filesystem we can't
        // list, not the user deleting everything.
        var removed: u32 = 0;
        const stopped = stop.load(.acquire);
        const looks_unmounted = !stopped and walk.media_seen == 0 and known.count() > 0;
        if (looks_unmounted)
            log.warn("{s}: no media found but {d} indexed; keeping them (drive unmounted?)", .{ library_path, known.count() });
        if (!stopped and !looks_unmounted) {
            var kit = known.iterator();
            while (kit.next()) |entry| {
                if (entry.value_ptr.seen or walk.underSkipped(entry.key_ptr.*)) continue;
                const id = self.db.deleteImageByPath(library_id, entry.key_ptr.*) catch |err| {
                    log.warn("delete {s}: {}", .{ std.Io.Dir.path.basename(entry.key_ptr.*), err });
                    continue;
                } orelse continue;
                removed += 1;
                if (self.removed_ids) |out| out.append(self.allocator, id) catch {};
            }
        }

        var s = stats.snapshot();
        s.removed = removed;
        log.info("scan done: +{d} ~{d} -{d} ={d}", .{ s.added, s.updated, s.removed, s.unchanged });
        return s;
    }

    fn walkDirectory(
        self: *LibraryScanner,
        io: std.Io,
        library_id: u64,
        dir_path: []const u8,
        stats: *AtomicStats,
        known: *std.StringHashMap(db_mod.ImageMeta),
        stop: *std.atomic.Value(bool),
        files_scanned: *std.atomic.Value(u32),
        thumbnails_in_db: bool,
        prompt_embeddings: bool,
        image_embeddings: bool,
        group: *std.Io.Group,
        in_flight: *usize,
        embed_queue: *EmbedQueue,
        walk: *WalkState,
        is_root: bool,
    ) !void {
        // A subdirectory that can't be listed is skipped (and its rows kept);
        // only the library root failing fails the scan.
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| {
            if (is_root) return err;
            return skipDir(self.allocator, walk, dir_path, err);
        };
        defer dir.close(io);

        var iter = dir.iterate();

        while (true) {
            const maybe_entry = iter.next(io) catch |err| {
                if (is_root) return err;
                return skipDir(self.allocator, walk, dir_path, err);
            };
            const entry = maybe_entry orelse break;
            // Abort the walk promptly when stopped (window close / rescan) instead
            // of iterating the rest of the tree, so scan_group.await unblocks fast.
            if (stop.load(.acquire)) return;
            const full_path = try std.Io.Dir.path.join(self.allocator, &.{ dir_path, entry.name });

            // Some filesystems (NFS, FUSE, XFS without ftype) don't report entry
            // types; stat those, or every file would be skipped.
            const kind: std.Io.File.Kind = if (entry.kind == .unknown)
                if (std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false })) |st| st.kind else |_| .unknown
            else
                entry.kind;

            if (kind == .directory) {
                defer self.allocator.free(full_path);
                try self.walkDirectory(
                    io, library_id, full_path, stats, known,
                    stop, files_scanned, thumbnails_in_db, prompt_embeddings, image_embeddings,
                    group, in_flight, embed_queue, walk, false,
                );
                continue;
            }

            if (kind != .file or !media.isSupportedMediaFile(entry.name)) {
                self.allocator.free(full_path);
                continue;
            }
            walk.media_seen += 1;

            if (stop.load(.acquire)) {
                self.allocator.free(full_path);
                continue;
            }

            // Mark seen before stat: a stat failure must not cause a false DB deletion.
            const meta_ptr = known.getPtr(full_path);
            if (meta_ptr) |m| m.seen = true;

            const stat = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch {
                self.allocator.free(full_path);
                continue;
            };
            const current_mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));

            // Skip files that are unchanged and already have all requested data.
            // Only an image with a prompt can have a prompt embedding.
            if (meta_ptr) |m| {
                if (m.mtime) |stored_mtime| {
                    if (stored_mtime == current_mtime
                        and (!thumbnails_in_db or m.has_thumbnail)
                        and (!prompt_embeddings or !m.has_prompt or m.has_prompt_embedding)
                        and (!image_embeddings or m.has_image_embedding))
                    {
                        _ = stats.unchanged.fetchAdd(1, .acq_rel);
                        _ = files_scanned.fetchAdd(1, .acq_rel);
                        self.allocator.free(full_path);
                        continue;
                    }
                }
            }

            // Throttle CPU task concurrency: await the current batch before
            // spawning more, so we don't accumulate unlimited in-flight tasks.
            if (in_flight.* >= EMBED_BATCH_SIZE) {
                group.await(io) catch |err| log.warn("group.await: {}", .{err});
                group.* = .init;
                in_flight.* = 0;
            }

            // full_path ownership transfers to the task.
            group.concurrent(io, processFile, .{ScanCtx{
                .path = full_path,
                .library_id = library_id,
                .db = self.db,
                .allocator = self.allocator,
                .stats = stats,
                .io = io,
                .stop = stop,
                .files_scanned = files_scanned,
                .thumbnails_in_db = thumbnails_in_db,
                .prompt_embeddings = prompt_embeddings,
                .image_embeddings = image_embeddings,
                .precomputed_mtime = current_mtime,
                .notifier = self.notifier,
                .embedder = self.embedder,
                .has_prompt_embedding = if (meta_ptr) |m| m.has_prompt_embedding else false,
                .has_image_embedding = if (meta_ptr) |m| m.has_image_embedding else false,
                .embed_queue = if (self.embedder != null) embed_queue else null,
            }}) catch |err| {
                log.warn("spawn {s}: {}", .{ std.Io.Dir.path.basename(full_path), err });
                self.allocator.free(full_path);
                continue;
            };
            in_flight.* += 1;
        }
    }
};

fn skipDir(a: std.mem.Allocator, walk: *WalkState, dir_path: []const u8, err: anyerror) !void {
    log.warn("skipping unreadable folder {s}: {}", .{ dir_path, err });
    const owned = try a.dupe(u8, dir_path);
    walk.skipped_dirs.append(a, owned) catch |e| {
        a.free(owned);
        return e;
    };
}

const EmbedConsumerCtx = struct {
    queue:     *EmbedQueue,
    db:        *db_mod.VectorDb,
    emb:       *embedder_mod.Embedder,
    allocator: std.mem.Allocator,
    stop:      *std.atomic.Value(bool),
    io:        std.Io,
};

/// Runs as a concurrent goroutine alongside CPU tasks. Drains a mini-batch from
/// the EmbedQueue (one blocking pop, then whatever else is already queued up to
/// EMBED_BATCH_SIZE) and embeds it in one batched forward, so the embedder can
/// route the batch to the GPU. Batch size = queue depth, so a lone new image
/// stays on the CPU and a bulk scan batches onto the GPU (see embedder.zig).
fn embedConsumer(ctx: EmbedConsumerCtx) void {
    log.debug("embed consumer: started", .{});
    defer ctx.queue.consumerExit(ctx.io);
    var n: u32 = 0;
    var buf: [EMBED_BATCH_SIZE]EmbedInput = undefined;
    while (!ctx.stop.load(.acquire)) {
        const first = ctx.queue.pop(ctx.io) orelse break;
        var count: usize = 1;
        buf[0] = first;
        while (count < EMBED_BATCH_SIZE) {
            buf[count] = ctx.queue.tryPop(ctx.io) orelse break;
            count += 1;
        }
        const batch = buf[0..count];
        defer for (batch) |*it| it.deinit();
        // Stopped while draining: drop this batch and bail — embed_queue.deinit
        // frees whatever is still queued, so shutdown/cancel isn't blocked.
        if (ctx.stop.load(.acquire)) break;
        embedBatch(ctx.allocator, ctx.db, ctx.emb, batch, ctx.stop);
        n += @intCast(count);
        _ = ctx.queue.embed_done.fetchAdd(@intCast(count), .acq_rel);
    }
    log.debug("embed consumer: exiting after {d} items", .{n});
}

/// Embed a drained mini-batch: prompt documents and images are gathered into
/// separate sub-batches and run through the batched embedder, then each vector is
/// stored against its image_id. On a batch-level failure we retry that sub-batch
/// per item (single items route to CPU) so one bad file can't sink the batch.
fn embedBatch(
    allocator: std.mem.Allocator,
    db:        *db_mod.VectorDb,
    emb:       *embedder_mod.Embedder,
    items:     []EmbedInput,
    stop:      *std.atomic.Value(bool),
) void {
    // ── Prompt sub-batch ──────────────────────────────────────────────────────
    // Guarded on the encoder being loaded: skip entirely (no work, no warnings)
    // when there is no text encoder, rather than failing every item.
    if (emb.hasPromptEncoder()) {
        var texts:    [EMBED_BATCH_SIZE][]const u8 = undefined;
        var text_ids: [EMBED_BATCH_SIZE]u64        = undefined;
        var text_paths: [EMBED_BATCH_SIZE][]const u8 = undefined;
        var nt: usize = 0;
        for (items) |*it| {
            const raw = it.prompt_text orelse continue;
            // Strip ComfyUI/A1111 markup so the embedder sees natural language.
            const cleaned = prompt_clean.cleanPrompt(allocator, raw) catch continue;
            if (cleaned.len == 0) {
                allocator.free(cleaned);
                continue;
            }
            // Skip prompts too long for the text encoder's window (would panic in TP).
            if (!emb.promptFits(allocator, cleaned)) {
                log.warn("prompt too long for image {d}; skipping prompt embedding", .{it.image_id});
                allocator.free(cleaned);
                continue;
            }
            texts[nt] = cleaned;
            text_ids[nt] = it.image_id;
            text_paths[nt] = it.path;
            nt += 1;
        }
        defer for (texts[0..nt]) |t| allocator.free(t);
        // Skip the GPU embed on stop (close/cancel) — the gathered texts are still
        // freed by the defer above.
        if (nt > 0 and !stop.load(.acquire)) {
            if (emb.embedPromptBatch(allocator, texts[0..nt])) |vecs| {
                defer {
                    for (vecs) |v| allocator.free(v);
                    allocator.free(vecs);
                }
                for (vecs, text_ids[0..nt], text_paths[0..nt]) |vec, id, path|
                    storePrompt(db, id, path, vec);
            } else |err| {
                log.warn("prompt embed batch failed ({}); retrying per item", .{err});
                for (texts[0..nt], text_ids[0..nt], text_paths[0..nt]) |t, id, path| embedOnePrompt(allocator, db, emb, id, path, t);
            }
        }
    }

    // ── Image sub-batch ───────────────────────────────────────────────────────
    // Bail before the expensive image decode + GPU forward if we've been stopped.
    if (stop.load(.acquire)) return;
    if (emb.hasVisualEncoder()) {
        var paths:   [EMBED_BATCH_SIZE][:0]const u8 = undefined;
        var img_ids: [EMBED_BATCH_SIZE]u64          = undefined;
        var ni: usize = 0;
        for (items) |*it| {
            if (!it.want_image) continue;
            paths[ni] = it.path;
            img_ids[ni] = it.image_id;
            ni += 1;
        }
        if (ni > 0) {
            if (emb.embedImageBatch(allocator, paths[0..ni], stop)) |vecs| {
                defer {
                    for (vecs) |v| if (v.len != 0) allocator.free(v);
                    allocator.free(vecs);
                }
                // Empty vec = that image failed to decode (skipped, not fatal to the
                // batch); the rest still embedded on the GPU in one forward.
                for (vecs, img_ids[0..ni], 0..) |vec, id, i| {
                    if (vec.len == 0) {
                        // Empty slots are also what a stopped batch returns.
                        if (!stop.load(.acquire)) log.warn("image decode failed for image {d}; skipped", .{id});
                        continue;
                    }
                    storeImage(db, id, paths[i], vec);
                }
            } else |err| {
                log.warn("image embed batch failed ({}); retrying per item", .{err});
                for (paths[0..ni], img_ids[0..ni]) |p, id| embedOneImage(allocator, db, emb, id, p);
            }
        }
    }
}

fn storePrompt(db: *db_mod.VectorDb, id: u64, path: []const u8, vec: []const f32) void {
    const stored = db.storePromptEmbedding(id, path, vec) catch |err| {
        log.warn("store prompt embed: {}", .{err});
        return;
    };
    if (!stored) log.debug("prompt embed for {s} dropped: image removed", .{std.Io.Dir.path.basename(path)});
}

fn storeImage(db: *db_mod.VectorDb, id: u64, path: []const u8, vec: []const f32) void {
    const stored = db.storeImageEmbedding(id, path, vec) catch |err| {
        log.warn("store image embed: {}", .{err});
        return;
    };
    if (!stored) log.debug("image embed for {s} dropped: image removed", .{std.Io.Dir.path.basename(path)});
}

/// Fallback: embed one already-cleaned prompt (routes to CPU, n=1) and store it.
fn embedOnePrompt(allocator: std.mem.Allocator, db: *db_mod.VectorDb, emb: *embedder_mod.Embedder, id: u64, path: []const u8, cleaned: []const u8) void {
    if (emb.embedPrompt(allocator, cleaned)) |vec| {
        defer allocator.free(vec);
        storePrompt(db, id, path, vec);
    } else |err| log.warn("prompt embed failed ({}); skipped", .{err});
}

/// Fallback: embed one image (routes to CPU, n=1) and store it.
fn embedOneImage(allocator: std.mem.Allocator, db: *db_mod.VectorDb, emb: *embedder_mod.Embedder, id: u64, path: [:0]const u8) void {
    if (emb.embedImage(allocator, path)) |vec| {
        defer allocator.free(vec);
        storeImage(db, id, path, vec);
    } else |err| log.warn("image embed failed ({}); skipped", .{err});
}

/// Embed prompt and/or image inline (single-file watcher path) and store the
/// resulting vectors. `do_prompt`/`do_image` gate each half. Returns true if any
/// embedding was stored. Errors are logged and swallowed (best-effort). Shared
/// by the backfill and new-file branches of processFile.
fn embedAndStoreInline(ctx: ScanCtx, image: *const models.Image, do_prompt: bool, do_image: bool) bool {
    var did_work = false;
    prompt: {
        if (!do_prompt) break :prompt;
        const emb = ctx.embedder orelse break :prompt;
        const prompt = image.positivePromptText orelse break :prompt;
        if (ctx.stop.load(.acquire)) break :prompt;
        // Strip ComfyUI/A1111 markup so the embedder sees natural language.
        const cleaned = prompt_clean.cleanPrompt(ctx.allocator, prompt) catch break :prompt;
        defer ctx.allocator.free(cleaned);
        if (cleaned.len == 0) break :prompt;
        const vec = emb.embedPrompt(ctx.allocator, cleaned) catch break :prompt;
        defer ctx.allocator.free(vec);
        storePrompt(ctx.db, image.id, ctx.path, vec);
        did_work = true;
    }
    image_blk: {
        if (!do_image) break :image_blk;
        if (ctx.stop.load(.acquire)) break :image_blk;
        const emb = ctx.embedder orelse break :image_blk;
        const path_z = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch break :image_blk;
        defer ctx.allocator.free(path_z);
        const vec = emb.embedImage(ctx.allocator, path_z) catch break :image_blk;
        defer ctx.allocator.free(vec);
        storeImage(ctx.db, image.id, ctx.path, vec);
        did_work = true;
    }
    return did_work;
}

/// Queue embedding work for one image. Returns false when there was nothing to
/// embed (no prompt and no image wanted) or the item couldn't be allocated.
fn pushEmbed(ctx: ScanCtx, q: *EmbedQueue, id: u64, prompt: ?[]const u8, want_image: bool) bool {
    if (prompt == null and !want_image) return false;
    const path = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch return false;
    const text = if (prompt) |p| ctx.allocator.dupe(u8, p) catch {
        ctx.allocator.free(path);
        return false;
    } else null;
    q.push(ctx.io, .{
        .image_id = id,
        .path = path,
        .prompt_text = text,
        .want_image = want_image,
        .allocator = ctx.allocator,
    });
    return true;
}

/// gif/webp can be animated; persist media_type accordingly. Gated on those two
/// extensions so it never loads the (many) PNG/JPEG files — only the handful of
/// gif/webp pay the cheap header read. Idempotent, so it also repairs the
/// media_type of already-indexed animated images on a later rescan.
fn classifyAnimatedImage(ctx: ScanCtx, image_id: u64) void {
    if (!media.isAnimatableImage(ctx.path)) return;
    const path_z = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch return;
    defer ctx.allocator.free(path_z);
    const pages = vips.nPages(path_z) catch return;
    ctx.db.setMediaType(image_id, if (pages > 1) .animated else .image) catch {};
}

/// Blake3 of a file's bytes as lowercase hex, read in fixed-size pieces.
fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buf}, off);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        off += n;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Process a video file: poster-frame thumbnail (always stored in the DB so the
/// grid loader can read it — libvips can't open video) + ComfyUI metadata from
/// the container's format tags. `aa` is the per-file arena.
/// Long edge of a video's poster thumbnail.
const video_thumb_px = 320;

fn processVideo(ctx: ScanCtx, image: *models.Image, current_mtime: i64, aa: std.mem.Allocator, is_new: bool) void {
    const path_z = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch return;
    defer ctx.allocator.free(path_z);

    // One open of the file for the poster frame (already scaled to thumbnail
    // size) and the ComfyUI metadata, which is stored as mp4 format tags.
    var sections: std.ArrayList(comfy_mod.ComfyParser.RawSection) = .empty;
    if (video.scanFile(aa, path_z, video_thumb_px)) |data| {
        if (data.frame) |frame| {
            if (vips.rgbaToJpeg(ctx.allocator, frame.pixels, frame.width, frame.height, video_thumb_px)) |jpeg| {
                if (image.thumbnail) |t| ctx.allocator.free(t);
                image.thumbnail = jpeg;
            } else |err| log.warn("video thumb encode {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        } else log.warn("video decode {s}: no first frame", .{std.Io.Dir.path.basename(ctx.path)});
        if (data.workflow) |w| sections.append(aa, .{ .keyword = "workflow", .text = w }) catch {};
        if (data.prompt) |p| sections.append(aa, .{ .keyword = "prompt", .text = p }) catch {};
    } else |err| log.warn("video open {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });

    var parser = comfy_mod.ComfyParser.init(aa);
    applyParseResult(ctx.allocator, image, parser.parseImageMetadata(sections.items) catch null);

    // Hash the file for duplicate detection, streamed: videos can be huge.
    if (hashFile(ctx.io, ctx.path)) |hash_hex| {
        if (image.hash) |h| ctx.allocator.free(h);
        image.hash = ctx.allocator.dupe(u8, &hash_hex) catch null;
    } else |err| log.warn("hash {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });

    image.mtime = current_mtime;
    ctx.db.saveImage(image) catch |err| {
        log.warn("save video {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        return;
    };
    ctx.db.setMediaType(image.id, .video) catch |err|
        log.warn("setMediaType {d}: {}", .{ image.id, err });

    if (is_new) _ = ctx.stats.added.fetchAdd(1, .acq_rel)
    else _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
    if (ctx.notifier) |n| n.push(ctx.io, image.id, ctx.path, current_mtime);
    log.debug("processed video {s}", .{std.Io.Dir.path.basename(ctx.path)});
}

pub fn processFile(ctx: ScanCtx) void {
    defer ctx.allocator.free(ctx.path);
    defer _ = ctx.files_scanned.fetchAdd(1, .acq_rel);

    if (ctx.stop.load(.acquire)) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const current_mtime = ctx.precomputed_mtime;

    // DB read — fetch existing record (or create new placeholder).
    var image = ctx.db.findOrCreateImage(ctx.allocator, ctx.library_id, ctx.path) catch |err| {
        log.warn("db find {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        return;
    };
    defer image.deinit(ctx.allocator);

    if (image.mtime) |stored| {
        if (stored == current_mtime) {
            // File content unchanged. Fill in any data now wanted but missing.
            // (Re)classify gif/webp so animated images indexed before media_type
            // existed get repaired on a normal rescan.
            classifyAnimatedImage(ctx, image.id);
            var did_work = false;
            if (ctx.thumbnails_in_db and image.thumbnail == null) {
                image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
                    log.warn("thumbnail {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
                };
                ctx.db.saveImage(&image) catch |err| {
                    log.warn("save thumb {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
                };
                did_work = true;
            }
            const needs_prompt_backfill = ctx.prompt_embeddings and !ctx.has_prompt_embedding and
                image.positivePromptText != null;
            const needs_image_backfill  = ctx.image_embeddings  and !ctx.has_image_embedding;

            if (ctx.embed_queue) |q| {
                // Queue mode: push embedding inputs to the concurrent consumer.
                if (needs_prompt_backfill or needs_image_backfill) {
                    if (pushEmbed(ctx, q, image.id, if (needs_prompt_backfill) image.positivePromptText else null, needs_image_backfill))
                        did_work = true;
                }
            } else {
                // Inline mode (single-file from watcher): embed directly.
                if (embedAndStoreInline(ctx, &image, needs_prompt_backfill, needs_image_backfill))
                    did_work = true;
            }
            if (did_work) {
                _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
            } else {
                _ = ctx.stats.unchanged.fetchAdd(1, .acq_rel);
            }
            return;
        }
    }
    const is_new = image.hash == null;

    // Notify the grid of new images immediately so they appear without waiting
    // for the full scan to complete.
    if (is_new) {
        if (ctx.notifier) |n| n.push(ctx.io, image.id, ctx.path, current_mtime);
    }

    // Video files take a separate path: libav* for the poster frame + metadata.
    if (media.isVideoFile(ctx.path)) {
        processVideo(ctx, &image, current_mtime, aa, is_new);
        return;
    }

    // Classify gif/webp as static vs animated.
    classifyAnimatedImage(ctx, image.id);

    // Read file into arena buffer.
    var file = std.Io.Dir.cwd().openFile(ctx.io, ctx.path, .{}) catch return;
    defer file.close(ctx.io);

    const file_size = file.length(ctx.io) catch return;
    const buffer = aa.alloc(u8, file_size) catch return;
    // A short read means the file shrank under us (being rewritten): leave the
    // row as it was and let the next event or scan pick up the final file.
    const n_read = file.readPositionalAll(ctx.io, buffer, 0) catch return;
    if (n_read != file_size) return;

    // Gather metadata "sections" (keyword + text) for the shared ComfyUI/A1111
    // parser. ComfyUI PNGs carry the workflow/prompt JSON in tEXt/iTXt chunks;
    // other formats (notably ComfyUI WebP) carry the same JSON in EXIF.
    var sections: std.ArrayList(comfy_mod.ComfyParser.RawSection) = .empty;
    // A PNG that doesn't parse may be mid-write (ComfyUI still saving it): its
    // mtime is not stored, so the next event or scan reads it again.
    var parse_failed = false;
    if (std.ascii.endsWithIgnoreCase(ctx.path, ".png")) {
        parse_failed = gatherPngSections(aa, ctx.io, buffer, &sections) catch |err| blk: {
            log.warn("parse failed {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
            break :blk true;
        };
    } else {
        gatherEmbeddedSections(aa, buffer, &sections);
    }

    var parser = comfy_mod.ComfyParser.init(aa);
    const maybe_result: ?comfy_mod.ParseResult = parser.parseImageMetadata(sections.items) catch null;
    if (maybe_result == null) log.debug("no metadata: {s}", .{std.Io.Dir.path.basename(ctx.path)});

    // Hash the raw file bytes (every image: duplicate detection needs it
    // whether or not the image has generation metadata).
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(buffer);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hash_hex = std.fmt.bytesToHex(digest, .lower);

    if (ctx.thumbnails_in_db) {
        image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
            log.warn("thumbnail {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        };
    }

    // Replace the stored metadata with what this version of the file carries
    // (none, if it was rewritten without any).
    applyParseResult(ctx.allocator, &image, maybe_result);
    if (image.hash) |h| ctx.allocator.free(h);
    image.hash = ctx.allocator.dupe(u8, &hash_hex) catch null;
    image.mtime = if (parse_failed) null else current_mtime;

    // DB write.
    ctx.db.saveImage(&image) catch |err| {
        log.warn("save {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        return;
    };

    if (ctx.embed_queue) |q| {
        // Queue mode: push embedding inputs to the concurrent consumer.
        _ = pushEmbed(ctx, q, image.id, if (ctx.prompt_embeddings) image.positivePromptText else null, ctx.image_embeddings);
        if (is_new) _ = ctx.stats.added.fetchAdd(1, .acq_rel)
        else _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
        log.debug("processed {s}", .{std.Io.Dir.path.basename(ctx.path)});
        return;
    }

    // Inline mode (single-file from watcher): embed directly.
    _ = embedAndStoreInline(ctx, &image, ctx.prompt_embeddings, ctx.image_embeddings);

    if (is_new) {
        _ = ctx.stats.added.fetchAdd(1, .acq_rel);
    } else {
        _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
    }
    // Notify the grid now that the parsed metadata and thumbnail are saved. This
    // second push (new images also get an early one at line ~535 so they appear
    // instantly) carries the now-complete data: the grid drops its stale cached
    // thumbnail and the detail panel reloads from the fresh DB row. Critically,
    // this also fires for a reparse of a previously-unparsed image (is_new=true),
    // which otherwise only got the pre-parse push and showed stale data until a
    // second reparse.
    if (ctx.notifier) |n| n.push(ctx.io, image.id, ctx.path, current_mtime);
    log.debug("processed {s}", .{std.Io.Dir.path.basename(ctx.path)});
}
