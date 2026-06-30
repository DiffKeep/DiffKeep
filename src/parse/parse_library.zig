const std = @import("std");
const db = @import("../db.zig");
const png = @import("../image/png-data.zig");
const PngParser = png.PngParser;
const Chunk = png.Chunk;
const ComfyParser = @import("comfy.zig").ComfyParser;
const llama = @import("../llama.zig");
const models = @import("../models.zig");
const log = std.log.scoped(.library_parser);
const Atomic = std.atomic.Value(i64);

pub const LibraryParser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *db.VectorDb,
    library_id: u32,
    library_path: []const u8,
    file_count: Atomic,

    pub fn init(allocator: std.mem.Allocator, vdb: *db.VectorDb, library_id: u32, library_path: []const u8) !LibraryParser {
        return LibraryParser{
            .allocator = allocator,
            .io = undefined, // set before use via parse()
            .db = vdb,
            .library_id = library_id,
            .library_path = library_path,
            .file_count = Atomic.init(0),
        };
    }

    pub fn deinit(_: *LibraryParser) void {}

    pub fn parse(self: *LibraryParser, io: std.Io) !void {
        self.io = io;
        try self.walkDirectory(self.library_path);
        log.debug("{d} files parsed.", .{self.file_count.load(.acquire)});
    }

    fn walkDirectory(self: *LibraryParser, dir_path: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        });
        defer dir.close(self.io);

        var group: std.Io.Group = .init;
        var dir_iter = dir.iterate();

        while (try dir_iter.next(self.io)) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });

            if (entry.kind == .directory) {
                try self.walkDirectory(full_path);
                self.allocator.free(full_path);
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
                log.debug("Queueing file {d}: {s}", .{ self.file_count.fetchAdd(1, .acq_rel) + 1, full_path });
                group.concurrent(self.io, processFile, .{
                    full_path,
                    self.db,
                    self.allocator,
                    self.library_id,
                    self.io,
                }) catch |err| {
                    log.warn("Failed to spawn task for {s}: {}", .{ full_path, err });
                    self.allocator.free(full_path);
                };
            } else {
                self.allocator.free(full_path);
            }
        }

        log.debug("Done queueing files", .{});
        group.await(self.io) catch {};
    }
};

fn generate_image_hash(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator) ![]const u8 {
    log.debug("Starting generating hash", .{});
    const t0 = std.Io.Timestamp.now(io, .awake);

    const file_size = try file.length(io);
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);
    _ = try file.readPositionalAll(io, buffer, 0);

    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(buffer);

    var digest: [32]u8 = undefined;
    hash.final(&digest);

    const hex_digest = try allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    log.debug("Finished generating hash in {d:.3}s", .{elapsedSec(io, t0)});
    return hex_digest;
}

fn complete_image_data(io: std.Io, image: *models.Image, hash: []const u8, allocator: std.mem.Allocator, _: *db.VectorDb) !void {
    log.debug("Starting image completing step for {s}", .{image.libraryPath});
    const t0 = std.Io.Timestamp.now(io, .awake);
    image.hash = hash;
    try image.generate_thumbnail(io, allocator, image.libraryPath);
    log.debug("Completed image completing step for {s} in {d:.3}s", .{ image.libraryPath, elapsedSec(io, t0) });
}

fn processFile(path: []const u8, conn: *db.VectorDb, allocator: std.mem.Allocator, library_id: u32, io: std.Io) void {
    log.debug("Processing file {s}", .{path});
    const t0 = std.Io.Timestamp.now(io, .awake);
    defer allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    var pngParser = PngParser.init(arena_allocator, io) catch return;
    defer pngParser.deinit();

    var parser = ComfyParser.init(arena_allocator);

    const file_size = file.length(io) catch {
        log.debug("Failed getting file size of {s}", .{path});
        return;
    };
    const buffer = arena_allocator.alloc(u8, file_size) catch {
        log.debug("OOM error reading file {s}", .{path});
        return;
    };
    _ = file.readPositionalAll(io, buffer, 0) catch {
        log.debug("error reading file into buffer: {s}", .{path});
        return;
    };
    pngParser.parseBuffer(buffer) catch {
        log.debug("error parsing file {s}", .{path});
        return;
    };

    // Gather all readable text sections (iTXt first, then tEXt) and let the
    // shared selector pick the best source (parameters → workflow → prompt),
    // independent of the order they appear in the file.
    var sections: std.ArrayListUnmanaged(ComfyParser.RawSection) = .empty;
    {
        const itxt_chunks = pngParser.getITxtChunks() catch &[_]Chunk{};
        defer arena_allocator.free(itxt_chunks);
        for (itxt_chunks) |chunk| {
            var content = pngParser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(arena_allocator);
            if (content.compressed) continue;
            const kw = arena_allocator.dupe(u8, content.keyword) catch continue;
            const tx = arena_allocator.dupe(u8, content.text) catch continue;
            sections.append(arena_allocator, .{ .keyword = kw, .text = tx }) catch {};
        }
    }
    {
        const text_chunks = pngParser.getTExtChunks() catch return;
        defer arena_allocator.free(text_chunks);
        for (text_chunks) |chunk| {
            var content = pngParser.parseTExtChunk(chunk) catch continue;
            defer content.deinit(arena_allocator);
            const kw = arena_allocator.dupe(u8, content.keyword) catch continue;
            const tx = arena_allocator.dupe(u8, content.text) catch continue;
            sections.append(arena_allocator, .{ .keyword = kw, .text = tx }) catch {};
        }
    }

    const maybe_result: ?@import("comfy.zig").ParseResult =
        parser.parseImageMetadata(sections.items) catch null;

    if (maybe_result == null) {
        log.debug("Could not extract prompt from {s}", .{path});
        return;
    }

    {
        var parse_result = maybe_result.?;
        defer parse_result.deinit(arena_allocator);
        if (parse_result.positive_prompt == null) {
            log.debug("No prompt extracted from {s}", .{path});
            return;
        }
        log.debug("Processing {s}", .{path});

        const hash = generate_image_hash(io, file, arena_allocator) catch |err| {
            log.debug("Failed to generate hash for {s}: {any}", .{ path, err });
            return;
        };

        var image = conn.findOrCreateImage(library_id, path) catch |err| {
            log.debug("Failed to find or create DB image for {s}: {any}", .{ path, err });
            return;
        };

        if (image.hash) |existing_hash| {
            if (!std.mem.eql(u8, existing_hash, hash)) {
                log.debug("Hash is different for image {s}", .{path});
                complete_image_data(io, &image, hash, arena_allocator, conn) catch |err| {
                    log.debug("Failed to update changed image {s}: {any}", .{ path, err });
                    return;
                };
            } else {
                log.debug("Not updating existing image {s}", .{path});
            }
        } else {
            log.debug("Hash is empty, new image {s}", .{path});
            complete_image_data(io, &image, hash, arena_allocator, conn) catch |err| {
                log.debug("Failed to update new image {s}: {any}", .{ path, err });
                return;
            };
        }
    }

    log.debug("Done processing image {s} in {d:.3}s", .{ path, elapsedSec(io, t0) });
}

fn elapsedSec(io: std.Io, t0: std.Io.Timestamp) f64 {
    const elapsed = t0.durationTo(std.Io.Timestamp.now(io, .awake));
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / @as(f64, std.time.ns_per_s);
}
