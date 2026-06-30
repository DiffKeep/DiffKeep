const std = @import("std");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const comfy_mod = @import("parse/comfy.zig");
const models = @import("models.zig");
const notifier_mod = @import("notifier.zig");
const onnx_mod = @import("onnx_embedder.zig");
const log = std.log.scoped(.scan);

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

/// Number of files processed concurrently per batch. After each batch of CPU
/// work (parse + thumbnail) completes, embeddings are run in a single GPU call.
pub const EMBED_BATCH_SIZE: usize = 8;

pub const ScanStats = struct {
    added: u32 = 0,
    updated: u32 = 0,
    removed: u32 = 0,
    unchanged: u32 = 0,
};

/// Holds the inputs needed to embed a single file. Written by processFile in
/// batch mode; consumed by batchEmbedAndStore after the concurrent group completes.
pub const EmbedInput = struct {
    image_id: u64,
    prompt_text:  ?[]const u8,    // owned; null = no prompt embedding needed
    image_path_z: ?[:0]const u8,  // owned; null = no image embedding needed
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EmbedInput) void {
        if (self.prompt_text)  |p| self.allocator.free(p);
        if (self.image_path_z) |p| self.allocator.free(p);
    }
};

/// Thread-safe FIFO queue of EmbedInputs. CPU tasks push; a dedicated embed
/// consumer goroutine pops and calls the embedder, letting CPU work and GPU
/// inference overlap instead of running strictly serially.
const EmbedQueue = struct {
    mutex:       std.Io.Mutex                 = .init,
    cond:        std.Io.Condition             = .init,
    items:       std.ArrayList(EmbedInput)    = .empty,
    done:        bool                         = false,
    allocator:   std.mem.Allocator,
    embed_done:  *std.atomic.Value(u32),
    embed_total: *std.atomic.Value(u32),

    fn deinit(q: *EmbedQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        for (q.items.items) |*item| item.deinit();
        q.items.deinit(q.allocator);
        q.mutex.unlock(io);
    }

    fn push(q: *EmbedQueue, io: std.Io, item: EmbedInput) void {
        q.mutex.lockUncancelable(io);
        q.items.append(q.allocator, item) catch {
            q.mutex.unlock(io);
            var it = item;
            it.deinit();
            return;
        };
        _ = q.embed_total.fetchAdd(1, .acq_rel);
        q.cond.signal(io);
        q.mutex.unlock(io);
    }

    fn finish(q: *EmbedQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        q.done = true;
        log.debug("embed queue: finish called, broadcasting (items remaining: {d})", .{q.items.items.len});
        q.cond.broadcast(io);
        q.mutex.unlock(io);
    }

    /// Blocks until an item is available. Returns null when done and empty.
    fn pop(q: *EmbedQueue, io: std.Io) ?EmbedInput {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        while (q.items.items.len == 0 and !q.done)
            q.cond.waitUncancelable(io, &q.mutex);
        if (q.items.items.len > 0) return q.items.pop();
        return null;
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
    embedder: ?*onnx_mod.OnnxEmbedder = null,
    has_prompt_embedding: bool = false,
    has_image_embedding: bool = false,
    /// Queue mode: when non-null, processFile pushes EmbedInputs here instead
    /// of calling the embedder inline. A separate consumer goroutine drains
    /// the queue concurrently. Null for single-file watcher paths.
    embed_queue: ?*EmbedQueue = null,
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
    embedder: ?*onnx_mod.OnnxEmbedder = null,  // borrowed, not owned

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
            embed_group.concurrent(io, embedConsumer, .{EmbedConsumerCtx{
                .queue     = &embed_queue,
                .db        = self.db,
                .emb       = emb,
                .allocator = self.allocator,
                .stop      = stop,
                .io        = io,
            }}) catch |err| log.warn("spawn embed consumer: {}", .{err});
        }

        var group: std.Io.Group = .init;
        var in_flight: usize = 0;
        const walk_err = self.walkDirectory(
            io, library_id, library_path, &stats, &known,
            stop, files_scanned, thumbnails_in_db, prompt_embeddings, image_embeddings,
            &group, &in_flight, &embed_queue,
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
        // been reached yet, not actually missing from disk.
        var removed: u32 = 0;
        if (!stop.load(.acquire)) {
            var kit = known.iterator();
            while (kit.next()) |entry| {
                if (!entry.value_ptr.seen) {
                    _ = self.db.deleteImageByPath(library_id, entry.key_ptr.*) catch |err| {
                        log.warn("delete {s}: {}", .{ std.fs.path.basename(entry.key_ptr.*), err });
                    };
                    removed += 1;
                }
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
    ) !void {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        });
        defer dir.close(io);

        var iter = dir.iterate();

        while (try iter.next(io)) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });

            if (entry.kind == .directory) {
                defer self.allocator.free(full_path);
                try self.walkDirectory(
                    io, library_id, full_path, stats, known,
                    stop, files_scanned, thumbnails_in_db, prompt_embeddings, image_embeddings,
                    group, in_flight, embed_queue,
                );
                continue;
            }

            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".png")) {
                self.allocator.free(full_path);
                continue;
            }

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
            if (meta_ptr) |m| {
                if (m.mtime) |stored_mtime| {
                    if (stored_mtime == current_mtime
                        and (!thumbnails_in_db or m.has_thumbnail)
                        and (!prompt_embeddings or m.has_prompt_embedding)
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
                log.warn("spawn {s}: {}", .{ std.fs.path.basename(full_path), err });
                self.allocator.free(full_path);
                continue;
            };
            in_flight.* += 1;
        }
    }
};

const EmbedConsumerCtx = struct {
    queue:     *EmbedQueue,
    db:        *db_mod.VectorDb,
    emb:       *onnx_mod.OnnxEmbedder,
    allocator: std.mem.Allocator,
    stop:      *std.atomic.Value(bool),
    io:        std.Io,
};

/// Runs as a concurrent goroutine alongside CPU tasks. Drains the EmbedQueue
/// and calls the embedder for each item, then stores the result in the DB.
fn embedConsumer(ctx: EmbedConsumerCtx) void {
    log.debug("embed consumer: started", .{});
    var n: u32 = 0;
    while (ctx.queue.pop(ctx.io)) |item| {
        var ei = item;
        defer ei.deinit();
        n += 1;
        if (!ctx.stop.load(.acquire)) embedSingle(ctx.allocator, ctx.db, ctx.emb, &ei);
        _ = ctx.queue.embed_done.fetchAdd(1, .acq_rel);
    }
    log.debug("embed consumer: exiting after {d} items", .{n});
}

fn embedSingle(
    allocator: std.mem.Allocator,
    db:        *db_mod.VectorDb,
    emb:       *onnx_mod.OnnxEmbedder,
    item:      *const EmbedInput,
) void {
    if (item.prompt_text) |text| {
        if (emb.embedPrompt(allocator, text)) |vec| {
            defer allocator.free(vec);
            db.storePromptEmbedding(item.image_id, vec) catch |err|
                log.warn("store prompt embed: {}", .{err});
        } else |err| {
            log.warn("prompt embed failed ({}); skipped", .{err});
        }
    }
    if (item.image_path_z) |path| {
        if (emb.embedImage(allocator, path)) |vec| {
            defer allocator.free(vec);
            db.storeImageEmbedding(item.image_id, vec) catch |err|
                log.warn("store image embed: {}", .{err});
        } else |err| {
            log.warn("image embed failed ({}); skipped", .{err});
        }
    }
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
        const vec = emb.embedPrompt(ctx.allocator, prompt) catch break :prompt;
        defer ctx.allocator.free(vec);
        ctx.db.storePromptEmbedding(image.id, vec) catch |err| {
            log.warn("store prompt embed {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        };
        did_work = true;
    }
    image_blk: {
        if (!do_image) break :image_blk;
        if (ctx.stop.load(.acquire)) break :image_blk;
        const emb = ctx.embedder orelse break :image_blk;
        const path_z = ctx.allocator.dupeZ(u8, ctx.path) catch break :image_blk;
        defer ctx.allocator.free(path_z);
        const vec = emb.embedImage(ctx.allocator, path_z) catch break :image_blk;
        defer ctx.allocator.free(vec);
        ctx.db.storeImageEmbedding(image.id, vec) catch |err| {
            log.warn("store image embed {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        };
        did_work = true;
    }
    return did_work;
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
        log.warn("db find {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        return;
    };
    defer image.deinit(ctx.allocator);

    if (image.mtime) |stored| {
        if (stored == current_mtime) {
            // File content unchanged. Fill in any data now wanted but missing.
            var did_work = false;
            if (ctx.thumbnails_in_db and image.thumbnail == null) {
                image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
                    log.warn("thumbnail {s}: {}", .{ std.fs.path.basename(ctx.path), err });
                };
                ctx.db.saveImage(&image) catch |err| {
                    log.warn("save thumb {s}: {}", .{ std.fs.path.basename(ctx.path), err });
                };
                did_work = true;
            }
            const needs_prompt_backfill = ctx.prompt_embeddings and !ctx.has_prompt_embedding;
            const needs_image_backfill  = ctx.image_embeddings  and !ctx.has_image_embedding;

            if (ctx.embed_queue) |q| {
                // Queue mode: push embedding inputs to the concurrent consumer.
                if (needs_prompt_backfill or needs_image_backfill) {
                    q.push(ctx.io, EmbedInput{
                        .image_id     = image.id,
                        .prompt_text  = if (needs_prompt_backfill)
                            if (image.positivePromptText) |p| ctx.allocator.dupe(u8, p) catch null else null
                            else null,
                        .image_path_z = if (needs_image_backfill)
                            ctx.allocator.dupeZ(u8, ctx.path) catch null
                            else null,
                        .allocator    = ctx.allocator,
                    });
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

    // Read file into arena buffer.
    var file = std.Io.Dir.cwd().openFile(ctx.io, ctx.path, .{}) catch return;
    defer file.close(ctx.io);

    const file_size = file.length(ctx.io) catch return;
    const buffer = aa.alloc(u8, file_size) catch return;
    _ = file.readPositionalAll(ctx.io, buffer, 0) catch return;

    // Parse PNG metadata.
    var png_parser = png_mod.PngParser.init(aa, ctx.io) catch return;
    defer png_parser.deinit();
    png_parser.parseBuffer(buffer) catch |err| {
        log.warn("parse failed {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        image.mtime = current_mtime;
        ctx.db.saveImage(&image) catch {};
        _ = ctx.stats.unchanged.fetchAdd(1, .acq_rel);
        return;
    };

    // Gather all readable text sections (keyword + text), preserving file order
    // so the shared selector can pick the first of each kind.  iTXt is collected
    // before tEXt to match prior behaviour (an iTXt "parameters" wins over tEXt).
    var sections: std.ArrayListUnmanaged(comfy_mod.ComfyParser.RawSection) = .empty;
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
    {
        const text_chunks = png_parser.getTExtChunks() catch return;
        defer aa.free(text_chunks);
        for (text_chunks) |chunk| {
            var content = png_parser.parseTExtChunk(chunk) catch continue;
            defer content.deinit(aa);
            const kw = aa.dupe(u8, content.keyword) catch continue;
            const tx = aa.dupe(u8, content.text) catch continue;
            sections.append(aa, .{ .keyword = kw, .text = tx }) catch {};
        }
    }

    var parser = comfy_mod.ComfyParser.init(aa);
    const maybe_result: ?comfy_mod.ParseResult = parser.parseImageMetadata(sections.items) catch null;

    var result = maybe_result orelse {
        log.debug("no metadata: {s}", .{std.fs.path.basename(ctx.path)});
        // Persist mtime so this file is skipped on future scans.
        image.mtime = current_mtime;
        ctx.db.saveImage(&image) catch {};
        _ = ctx.stats.unchanged.fetchAdd(1, .acq_rel);
        return;
    };
    defer result.deinit(aa);
    if (result.positive_prompt == null) {
        image.mtime = current_mtime;
        ctx.db.saveImage(&image) catch {};
        _ = ctx.stats.unchanged.fetchAdd(1, .acq_rel);
        return;
    }

    // Hash the raw file bytes.
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(buffer);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hash_hex = std.fmt.bytesToHex(digest, .lower);

    if (ctx.thumbnails_in_db) {
        image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
            log.warn("thumbnail {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        };
    }

    // Update image fields with parsed data.
    if (image.positivePromptText) |p| ctx.allocator.free(p);
    image.positivePromptText = if (result.positive_prompt) |p| ctx.allocator.dupe(u8, p) catch null else null;
    if (image.negativePromptText) |p| ctx.allocator.free(p);
    image.negativePromptText = if (result.negative_prompt) |p| ctx.allocator.dupe(u8, p) catch null else null;
    if (image.model) |m| ctx.allocator.free(m);
    image.model = if (result.model) |m| ctx.allocator.dupe(u8, m) catch null else null;
    if (image.sampler) |s| ctx.allocator.free(s);
    image.sampler = if (result.sampler) |s| ctx.allocator.dupe(u8, s) catch null else null;
    if (image.scheduler) |s| ctx.allocator.free(s);
    image.scheduler = if (result.scheduler) |s| ctx.allocator.dupe(u8, s) catch null else null;
    image.cfg = result.cfg;
    image.steps = result.steps;
    image.seed = result.seed;
    if (image.loras) |l| ctx.allocator.free(l);
    image.loras = lorasToString(ctx.allocator, result.loras);
    if (image.hash) |h| ctx.allocator.free(h);
    image.hash = ctx.allocator.dupe(u8, &hash_hex) catch null;
    image.mtime = current_mtime;

    // DB write.
    ctx.db.saveImage(&image) catch |err| {
        log.warn("save {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        return;
    };

    if (ctx.embed_queue) |q| {
        // Queue mode: push embedding inputs to the concurrent consumer.
        if (ctx.prompt_embeddings or ctx.image_embeddings) {
            q.push(ctx.io, EmbedInput{
                .image_id     = image.id,
                .prompt_text  = if (ctx.prompt_embeddings)
                    if (image.positivePromptText) |p| ctx.allocator.dupe(u8, p) catch null else null
                    else null,
                .image_path_z = if (ctx.image_embeddings)
                    ctx.allocator.dupeZ(u8, ctx.path) catch null
                    else null,
                .allocator    = ctx.allocator,
            });
        }
        if (is_new) _ = ctx.stats.added.fetchAdd(1, .acq_rel)
        else _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
        log.debug("processed {s}", .{std.fs.path.basename(ctx.path)});
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
    log.debug("processed {s}", .{std.fs.path.basename(ctx.path)});
}
