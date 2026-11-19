const std = @import("std");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const comfy_mod = @import("parse/comfy.zig");
const generator_mod = @import("parse/generator.zig");
const models = @import("models.zig");
const notifier_mod = @import("notifier.zig");
const embed_worker = @import("embed_worker.zig");
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
) error{OutOfMemory}!void {
    const markers = [_]struct { marker: []const u8, keyword: []const u8 }{
        .{ .marker = "workflow:{", .keyword = "workflow" },
        .{ .marker = "prompt:{", .keyword = "prompt" },
    };
    for (markers) |m| {
        const at = std.mem.find(u8, buffer, m.marker) orelse continue;
        // The marker ends with '{', so the JSON object begins at that brace.
        const json = comfy_mod.extractJsonObject(buffer[at + m.marker.len - 1 ..]) orelse continue;
        try sections.append(aa, .{ .keyword = try aa.dupe(u8, m.keyword), .text = try aa.dupe(u8, json) });
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
        const itxt = try png_parser.getITxtChunks();
        defer aa.free(itxt);
        for (itxt) |chunk| {
            // A malformed chunk is skipped; running out of memory is not.
            var content = png_parser.parseITxtChunk(chunk) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer content.deinit(aa);
            if (content.compressed) continue;
            try sections.append(aa, .{ .keyword = try aa.dupe(u8, content.keyword), .text = try aa.dupe(u8, content.text) });
        }
    }
    const text_chunks = try png_parser.getTExtChunks();
    defer aa.free(text_chunks);
    for (text_chunks) |chunk| {
        var content = png_parser.parseTExtChunk(chunk) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer content.deinit(aa);
        try sections.append(aa, .{ .keyword = try aa.dupe(u8, content.keyword), .text = try aa.dupe(u8, content.text) });
    }
    return truncated;
}

/// Overwrite `image`'s generation metadata with `result`, clearing every field
/// when there is none. Strings are duped with `a` (the image's allocator). On
/// error the image is left half updated (but safe to free): don't save it.
fn applyParseResult(a: std.mem.Allocator, image: *models.Image, maybe_result: ?comfy_mod.ParseResult) error{OutOfMemory}!void {
    const r: comfy_mod.ParseResult = maybe_result orelse .{};
    const set = struct {
        fn f(alloc: std.mem.Allocator, field: *?[]const u8, v: ?[]const u8) !void {
            if (field.*) |old| alloc.free(old);
            field.* = null;
            if (v) |x| field.* = try alloc.dupe(u8, x);
        }
    }.f;
    try set(a, &image.positivePromptText, r.positive_prompt);
    try set(a, &image.negativePromptText, r.negative_prompt);
    try set(a, &image.model, r.model);
    try set(a, &image.sampler, r.sampler);
    try set(a, &image.scheduler, r.scheduler);
    image.cfg = r.cfg;
    image.steps = r.steps;
    image.seed = r.seed;
    if (image.loras) |l| a.free(l);
    image.loras = null;
    image.loras = try lorasToString(a, r.loras);
}

/// Join a slice of lora names into a single newline-separated string.
fn lorasToString(allocator: std.mem.Allocator, loras: ?[]const []const u8) !?[]const u8 {
    const items = loras orelse return null;
    if (items.len == 0) return null;
    var total: usize = 0;
    for (items) |l| total += l.len + 1;
    const buf = try allocator.alloc(u8, total - 1);
    var pos: usize = 0;
    for (items, 0..) |l, i| {
        @memcpy(buf[pos .. pos + l.len], l);
        pos += l.len;
        if (i < items.len - 1) { buf[pos] = '\n'; pos += 1; }
    }
    return buf;
}

/// Files parsed/thumbnailed concurrently: the walk awaits each batch of this
/// many before spawning more, so in-flight tasks stay bounded.
const cpu_batch_size: usize = 32;

pub const ScanStats = struct {
    added: u32 = 0,
    updated: u32 = 0,
    removed: u32 = 0,
    unchanged: u32 = 0,
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
    precomputed_mtime: i64,
    notifier: ?*notifier_mod.ImageNotifier,
    /// Told when a file's row is saved, to embed what it needs. Null: nothing
    /// is embedded (tests, benchmarks without models).
    embeds: ?*embed_worker.EmbedWorker = null,
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
    /// Told about each saved row (see `ScanCtx.embeds`). Borrowed.
    embeds: ?*embed_worker.EmbedWorker = null,
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
    ) void {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        const path_owned = self.allocator.dupe(u8, path) catch return oom(path);
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
            .precomputed_mtime = mtime,
            .notifier = self.notifier,
            .embeds = self.embeds,
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
        thumbnails_in_db: bool,
    ) !ScanStats {
        var stats: AtomicStats = .{};

        // Single-query prefetch: replaces N per-file SELECTs and the seen HashSet.
        var known = try self.db.prefetchLibraryImages(self.allocator, library_id);
        defer {
            var it = known.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            known.deinit();
        }

        var group: std.Io.Group = .init;
        var in_flight: usize = 0;
        var walk: WalkState = .{};
        defer walk.deinit(self.allocator);
        const walk_err = self.walkDirectory(
            io, library_id, library_path, &stats, &known,
            stop, files_scanned, thumbnails_in_db,
            &group, &in_flight, &walk, true,
        );
        group.await(io) catch |err| log.warn("final cpu group.await: {}", .{err});
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
        // Every removed row must be reported, or it stays in the grid: make
        // the room first. Without it the rows stay until the next scan.
        const room_ok = if (self.removed_ids) |out| blk: {
            out.ensureUnusedCapacity(self.allocator, known.count()) catch |err| {
                log.warn("{s}: reconcile skipped: {}", .{ library_path, err });
                break :blk false;
            };
            break :blk true;
        } else true;
        if (!stopped and !looks_unmounted and room_ok) {
            var kit = known.iterator();
            while (kit.next()) |entry| {
                if (entry.value_ptr.seen or walk.underSkipped(entry.key_ptr.*)) continue;
                const id = self.db.deleteImageByPath(library_id, entry.key_ptr.*) catch |err| {
                    log.warn("delete {s}: {}", .{ std.Io.Dir.path.basename(entry.key_ptr.*), err });
                    continue;
                } orelse continue;
                removed += 1;
                if (self.removed_ids) |out| out.appendAssumeCapacity(id);
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
        group: *std.Io.Group,
        in_flight: *usize,
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
                    stop, files_scanned, thumbnails_in_db,
                    group, in_flight, walk, false,
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

            // Skip files that are unchanged and already have all requested
            // data. (Embeddings are the embed worker's: it finds what's missing
            // in the DB.)
            if (meta_ptr) |m| {
                if (m.mtime) |stored_mtime| {
                    if (stored_mtime == current_mtime and (!thumbnails_in_db or m.has_thumbnail)) {
                        _ = stats.unchanged.fetchAdd(1, .acq_rel);
                        _ = files_scanned.fetchAdd(1, .acq_rel);
                        self.allocator.free(full_path);
                        continue;
                    }
                }
            }

            // Throttle CPU task concurrency: await the current batch before
            // spawning more, so we don't accumulate unlimited in-flight tasks.
            if (in_flight.* >= cpu_batch_size) {
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
                .precomputed_mtime = current_mtime,
                .notifier = self.notifier,
                .embeds = self.embeds,
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

/// gif/webp can be animated; persist media_type accordingly. Gated on those two
/// extensions so it never loads the (many) PNG/JPEG files — only the handful of
/// gif/webp pay the cheap header read. Idempotent, so it also repairs the
/// media_type of already-indexed animated images on a later rescan.
fn classifyAnimatedImage(ctx: ScanCtx, image_id: u64) void {
    if (!media.isAnimatableImage(ctx.path)) return;
    const path_z = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch return;
    defer ctx.allocator.free(path_z);
    const pages = vips.nPages(path_z) catch return;
    ctx.db.setMediaType(image_id, if (pages > 1) .animated else .image) catch |err|
        log.warn("media type {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
}

/// Log a file left unsaved for lack of memory (the next scan retries it).
fn oom(path: []const u8) void {
    log.warn("{s}: out of memory, not saved (the next scan retries it)", .{std.Io.Dir.path.basename(path)});
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
    const path_z = ctx.allocator.dupeSentinel(u8, ctx.path, 0) catch return oom(ctx.path);
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
        // Out of memory, the row isn't saved: the next scan reads it again.
        if (data.workflow) |w| sections.append(aa, .{ .keyword = "workflow", .text = w }) catch return oom(ctx.path);
        if (data.prompt) |p| sections.append(aa, .{ .keyword = "prompt", .text = p }) catch return oom(ctx.path);
        if (data.parameters) |p| sections.append(aa, .{ .keyword = "parameters", .text = p }) catch return oom(ctx.path);
    } else |err| log.warn("video open {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });

    var parser = comfy_mod.ComfyParser.init(aa);
    const result = parser.parseImageMetadata(sections.items) catch return oom(ctx.path);
    applyParseResult(ctx.allocator, image, result) catch return oom(ctx.path);
    image.generator = generator_mod.detect(sections.items);

    // Hash the file for duplicate detection, streamed: videos can be huge.
    if (hashFile(ctx.io, ctx.path)) |hash_hex| {
        if (image.hash) |h| ctx.allocator.free(h);
        image.hash = null;
        image.hash = ctx.allocator.dupe(u8, &hash_hex) catch return oom(ctx.path);
    } else |err| log.warn("hash {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });

    image.mtime = current_mtime;
    ctx.db.saveImage(image) catch |err| {
        log.warn("save video {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        return;
    };
    ctx.db.setMediaType(image.id, .video) catch |err|
        log.warn("setMediaType {d}: {}", .{ image.id, err });
    if (ctx.embeds) |e| e.poke();

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
            if (ctx.thumbnails_in_db and image.thumbnail == null) {
                image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
                    log.warn("thumbnail {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
                };
                ctx.db.saveImage(&image) catch |err| {
                    log.warn("save thumb {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
                };
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
    const buffer = aa.alloc(u8, file_size) catch return oom(ctx.path);
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
        parse_failed = gatherPngSections(aa, ctx.io, buffer, &sections) catch |err| switch (err) {
            // Out of memory, the row isn't saved: the next scan reads it again.
            error.OutOfMemory => return oom(ctx.path),
            else => blk: {
                log.warn("parse failed {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
                break :blk true;
            },
        };
    } else {
        gatherEmbeddedSections(aa, buffer, &sections) catch return oom(ctx.path);
    }

    var parser = comfy_mod.ComfyParser.init(aa);
    const maybe_result: ?comfy_mod.ParseResult = parser.parseImageMetadata(sections.items) catch return oom(ctx.path);
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
    applyParseResult(ctx.allocator, &image, maybe_result) catch return oom(ctx.path);
    image.generator = generator_mod.detect(sections.items);
    if (image.hash) |h| ctx.allocator.free(h);
    image.hash = null;
    image.hash = ctx.allocator.dupe(u8, &hash_hex) catch return oom(ctx.path);
    image.mtime = if (parse_failed) null else current_mtime;

    // DB write.
    ctx.db.saveImage(&image) catch |err| {
        log.warn("save {s}: {}", .{ std.Io.Dir.path.basename(ctx.path), err });
        return;
    };

    if (ctx.embeds) |e| e.poke();

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
