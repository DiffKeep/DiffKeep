const std = @import("std");
const db_mod = @import("db.zig");
const png_mod = @import("image/png-data.zig");
const comfy_mod = @import("parse/comfy.zig");
const models = @import("models.zig");
const notifier_mod = @import("notifier.zig");
const log = std.log.scoped(.scan);

pub const ScanStats = struct {
    added: u32 = 0,
    updated: u32 = 0,
    removed: u32 = 0,
    unchanged: u32 = 0,
};

const ScanCtx = struct {
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
};

const AtomicStats = struct {
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

    pub fn init(_: std.mem.Allocator, db: *db_mod.VectorDb, notifier: ?*notifier_mod.ImageNotifier) LibraryScanner {
        // c_allocator (glibc malloc) is used throughout because processFile tasks
        // run on concurrent OS threads — the GPA is not thread-safe.
        return .{ .allocator = std.heap.c_allocator, .db = db, .notifier = notifier };
    }

    pub fn deinit(_: *LibraryScanner) void {}

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

        const max_concurrent = std.Thread.getCpuCount() catch 4;
        var group: std.Io.Group = .init;
        var in_flight: usize = 0;
        try self.walkDirectory(
            io, library_id, library_path, &stats, &known,
            stop, files_scanned, thumbnails_in_db, prompt_embeddings, image_embeddings,
            &group, &in_flight, max_concurrent,
        );
        group.await(io) catch |err| log.warn("final group.await: {}", .{err});

        // Reconciliation: any entry not marked seen no longer exists on disk.
        var removed: u32 = 0;
        var kit = known.iterator();
        while (kit.next()) |entry| {
            if (!entry.value_ptr.seen) {
                self.db.deleteImageByPath(library_id, entry.key_ptr.*) catch |err| {
                    log.warn("delete {s}: {}", .{ std.fs.path.basename(entry.key_ptr.*), err });
                };
                removed += 1;
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
        max_concurrent: usize,
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
                    group, in_flight, max_concurrent,
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
                    if (stored_mtime == current_mtime and (!thumbnails_in_db or m.has_thumbnail)) {
                        _ = stats.unchanged.fetchAdd(1, .acq_rel);
                        _ = files_scanned.fetchAdd(1, .acq_rel);
                        self.allocator.free(full_path);
                        continue;
                    }
                }
            }

            // Flush the current batch before exceeding the concurrent cap.
            if (in_flight.* >= max_concurrent) {
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
            }}) catch |err| {
                log.warn("spawn {s}: {}", .{ std.fs.path.basename(full_path), err });
                self.allocator.free(full_path);
                continue;
            };
            in_flight.* += 1;
        }
    }
};

fn processFile(ctx: ScanCtx) void {
    defer ctx.allocator.free(ctx.path);
    defer _ = ctx.files_scanned.fetchAdd(1, .acq_rel);

    if (ctx.stop.load(.acquire)) return;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
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
            // File content unchanged. If thumbnails are now wanted and missing, fill in the
            // gap without re-parsing the whole file.
            if (ctx.thumbnails_in_db and image.thumbnail == null) {
                image.generate_thumbnail(ctx.io, ctx.allocator, ctx.path) catch |err| {
                    log.warn("thumbnail {s}: {}", .{ std.fs.path.basename(ctx.path), err });
                };
                ctx.db.saveImage(&image) catch |err| {
                    log.warn("save thumb {s}: {}", .{ std.fs.path.basename(ctx.path), err });
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
        if (ctx.notifier) |n| n.push(ctx.io, ctx.allocator, image.id, ctx.path);
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

    var a1111_text: ?[]const u8 = null;
    {
        const itxt = png_parser.getITxtChunks() catch &[_]png_mod.Chunk{};
        defer aa.free(itxt);
        for (itxt) |chunk| {
            var content = png_parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(aa);
            if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed) {
                if (a1111_text == null) a1111_text = aa.dupe(u8, content.text) catch null;
            }
        }
    }

    const text_chunks = png_parser.getTExtChunks() catch return;
    defer aa.free(text_chunks);
    var workflow_text: ?[]const u8 = null;
    var prompt_text: ?[]const u8 = null;
    for (text_chunks) |chunk| {
        var content = png_parser.parseTExtChunk(chunk) catch continue;
        defer content.deinit(aa);
        if (std.mem.eql(u8, content.keyword, "prompt") and prompt_text == null)
            prompt_text = aa.dupe(u8, content.text) catch null;
        if (std.mem.eql(u8, content.keyword, "workflow") and workflow_text == null)
            workflow_text = aa.dupe(u8, content.text) catch null;
    }

    var parser = comfy_mod.ComfyParser.init(aa);
    var maybe_result: ?comfy_mod.ParseResult = null;
    if (a1111_text) |t| maybe_result = parser.parseA1111Parameters(t) catch null;
    if (maybe_result == null) {
        if (workflow_text) |t| maybe_result = parser.parseWorkflow(t) catch null;
    }
    if (maybe_result == null) {
        if (prompt_text) |t| maybe_result = parser.parsePromptChunk(t) catch null;
    }

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
    if (image.hash) |h| ctx.allocator.free(h);
    image.hash = ctx.allocator.dupe(u8, &hash_hex) catch null;
    image.mtime = current_mtime;

    // DB write.
    ctx.db.saveImage(&image) catch |err| {
        log.warn("save {s}: {}", .{ std.fs.path.basename(ctx.path), err });
        return;
    };

    if (is_new) {
        _ = ctx.stats.added.fetchAdd(1, .acq_rel);
    } else {
        _ = ctx.stats.updated.fetchAdd(1, .acq_rel);
    }
    log.debug("processed {s}", .{std.fs.path.basename(ctx.path)});
}
