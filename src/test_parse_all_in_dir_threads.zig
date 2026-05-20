/// Concurrent PNG metadata parser with optional embedding benchmark.
///
/// Usage: test_parse_all_in_dir_threads <directory>
///            [--text-model <path>]
///            [--vl-model <path> --mmproj <path>]
///
/// Phase 1: single-threaded directory walk → flat list of .png paths.
/// Phase 2: all files processed concurrently via std.Io.Group, each task
///           writing to its own pre-assigned result slot — no mutex needed.
/// Phase 3: (optional) sequential embedding of parsed results — discarded,
///           used only for throughput benchmarking.
const std = @import("std");
const png = @import("image/png-data.zig");
const PngParser = png.PngParser;
const Chunk = png.Chunk;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const ParseResult = @import("parse/comfy.zig").ParseResult;
const llama = @import("llama.zig");
const mtmd = @import("mtmd.zig");

/// One successfully parsed image with its extracted prompt.
pub const ParsedImage = struct {
    path: []const u8,   // owned
    prompt: []const u8, // owned

    pub fn deinit(self: ParsedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prompt);
    }
};

const Stats = struct {
    n_no_meta:   std.atomic.Value(u64) = .init(0),
    n_no_prompt: std.atomic.Value(u64) = .init(0),
    n_error:     std.atomic.Value(u64) = .init(0),
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var dir_path: ?[]const u8 = null;
    var text_model_path: ?[]const u8 = null;
    var vl_model_path: ?[]const u8 = null;
    var mmproj_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--text-model")) {
            text_model_path = args.next() orelse {
                std.log.err("--text-model requires a path argument", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--vl-model")) {
            vl_model_path = args.next() orelse {
                std.log.err("--vl-model requires a path argument", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--mmproj")) {
            mmproj_path = args.next() orelse {
                std.log.err("--mmproj requires a path argument", .{});
                return error.MissingArgument;
            };
        } else if (dir_path == null) {
            dir_path = arg;
        } else {
            std.log.err("unexpected argument: {s}", .{arg});
            return error.UnexpectedArgument;
        }
    }

    const dir = dir_path orelse {
        std.log.err("usage: test_parse_all_in_dir_threads <directory> [--text-model <path>] [--vl-model <path> --mmproj <path>]", .{});
        return error.MissingArgument;
    };

    if (vl_model_path != null and mmproj_path == null) {
        std.log.err("--vl-model requires --mmproj", .{});
        return error.MissingArgument;
    }

    // ── Phase 1: collect paths ─────────────────────────────────────────
    const t0 = std.Io.Timestamp.now(io, .awake);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try collectPaths(allocator, io, dir, &paths);

    const t1 = std.Io.Timestamp.now(io, .awake);
    std.log.info("Walk: found {d} PNGs in {d:.2}s", .{
        paths.items.len,
        nsToSec(t0.durationTo(t1).nanoseconds),
    });

    // ── Phase 2: parse concurrently ────────────────────────────────────
    // Pre-allocate one result slot per file. Each concurrent task writes
    // to its own slot → zero shared mutable state, no locking needed.
    const results = try allocator.alloc(?ParsedImage, paths.items.len);
    defer {
        for (results) |r| if (r) |item| item.deinit(allocator);
        allocator.free(results);
    }
    @memset(results, null);

    var stats: Stats = .{};
    var group: std.Io.Group = .init;

    for (paths.items, results) |path, *slot| {
        group.concurrent(io, processFile, .{ path, slot, &stats, allocator, io }) catch |err| {
            std.log.warn("Failed to spawn task for {s}: {}", .{ path, err });
            _ = stats.n_error.fetchAdd(1, .acq_rel);
        };
    }
    group.await(io) catch {};

    const t2 = std.Io.Timestamp.now(io, .awake);

    // ── Results ────────────────────────────────────────────────────────
    var n_ok: usize = 0;
    for (results) |r| if (r != null) { n_ok += 1; };

    const parse_s = nsToSec(t1.durationTo(t2).nanoseconds);
    const total   = paths.items.len;

    std.log.info("Parse: {d} files in {d:.2}s  ({d:.0} files/s)", .{
        total, parse_s,
        @as(f64, @floatFromInt(total)) / @max(parse_s, 0.001),
    });
    std.log.info("  Prompt extracted    : {d}", .{n_ok});
    std.log.info("  No AI metadata      : {d}", .{stats.n_no_meta.load(.acquire)});
    std.log.info("  Metadata, no prompt : {d}", .{stats.n_no_prompt.load(.acquire)});
    std.log.info("  Parse errors        : {d}", .{stats.n_error.load(.acquire)});

    const n_show = @min(5, n_ok);
    if (n_show > 0) {
        std.log.info("\nSample prompts:", .{});
        var shown: usize = 0;
        for (results) |r| {
            if (shown >= n_show) break;
            if (r) |item| {
                const snippet = item.prompt[0..@min(100, item.prompt.len)];
                std.log.info("  [{s}]\n    \"{s}...\"", .{
                    std.fs.path.basename(item.path), snippet,
                });
                shown += 1;
            }
        }
    }

    // ── Phase 3: embed (sequential) ───────────────────────────────────
    if (text_model_path != null or vl_model_path != null) {
        std.log.info("\nEmbedding {d} parsed images...", .{n_ok});
        try embedResults(allocator, results, text_model_path, vl_model_path, mmproj_path, io);
    }
}

fn embedResults(
    allocator: std.mem.Allocator,
    results: []?ParsedImage,
    text_model_path: ?[]const u8,
    vl_model_path: ?[]const u8,
    mmproj_path: ?[]const u8,
    io: std.Io,
) !void {
    // ── Text embedding ─────────────────────────────────────────────────
    if (text_model_path) |model_path| {
        var pool = llama.Pool.init(allocator, .{
            .embeddings   = true,
            .pooling_type = 1, // mean pooling
            .n_ctx        = 2048,
            .n_batch      = 512,
            .n_ubatch     = 512,
        });
        defer pool.deinit();

        const ctx = try pool.get(io, model_path, 30_000, null);
        defer pool.release(ctx);

        const t0 = std.Io.Timestamp.now(io, .awake);
        var n_ok: usize = 0;
        var n_err: usize = 0;

        for (results) |r| {
            const item = r orelse continue;
            var chunks = llama.createEmbeddingFromPrompt(allocator, ctx, item.prompt, 2048) catch {
                n_err += 1;
                continue;
            };
            defer {
                for (chunks.items) |e| allocator.free(e);
                chunks.deinit(allocator);
            }
            n_ok += 1;
        }

        const elapsed = nsToSec(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
        std.log.info("Text embed: {d} ok, {d} err, {d:.2}s  ({d:.1} img/s)", .{
            n_ok, n_err, elapsed,
            @as(f64, @floatFromInt(n_ok)) / @max(elapsed, 0.001),
        });
    }

    // ── VL image embedding ─────────────────────────────────────────────
    if (vl_model_path) |model_path| {
        var vl = try mtmd.VlContext.init(io, allocator, model_path, mmproj_path.?);
        defer vl.deinit();

        const t0 = std.Io.Timestamp.now(io, .awake);
        var n_ok: usize = 0;
        var n_err: usize = 0;

        for (results) |r| {
            const item = r orelse continue;
            const embd = vl.embedImageFile(io, allocator, item.path, "", null) catch {
                n_err += 1;
                continue;
            };
            allocator.free(embd);
            n_ok += 1;
        }

        const elapsed = nsToSec(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
        std.log.info("VL embed:   {d} ok, {d} err, {d:.2}s  ({d:.1} img/s)", .{
            n_ok, n_err, elapsed,
            @as(f64, @floatFromInt(n_ok)) / @max(elapsed, 0.001),
        });
    }
}

// ── Phase 1: directory walk ────────────────────────────────────────────────

fn collectPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            try collectPaths(allocator, io, full_path, out);
            allocator.free(full_path);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            try out.append(allocator, full_path);
        } else {
            allocator.free(full_path);
        }
    }
}

// ── Phase 2: concurrent file processing ───────────────────────────────────

fn processFile(
    path: []const u8,        // borrowed — owned by paths list, not freed here
    slot: *?ParsedImage,     // pre-assigned output slot
    stats: *Stats,
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const outcome = parseFile(arena.allocator(), io, path, stats) catch |err| {
        std.log.debug("Error parsing {s}: {}", .{ path, err });
        _ = stats.n_error.fetchAdd(1, .acq_rel);
        return;
    };

    const prompt = outcome orelse return; // counter already bumped inside parseFile

    const owned_path = allocator.dupe(u8, path) catch {
        _ = stats.n_error.fetchAdd(1, .acq_rel);
        return;
    };
    const owned_prompt = allocator.dupe(u8, prompt) catch {
        allocator.free(owned_path);
        _ = stats.n_error.fetchAdd(1, .acq_rel);
        return;
    };

    slot.* = .{ .path = owned_path, .prompt = owned_prompt };
}

/// Returns the positive prompt (arena-owned) or null if absent.
/// Bumps the appropriate Stats counter when returning null.
fn parseFile(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stats: *Stats,
) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var parser = try PngParser.init(arena, io);
    defer parser.deinit();

    const file_size = try file.length(io);
    const buffer = try arena.alloc(u8, file_size);
    _ = try file.readPositionalAll(io, buffer, 0);
    try parser.parseBuffer(buffer);

    // A1111 parameters from iTXt chunks
    var a1111_text: ?[]const u8 = null;
    {
        const chunks = parser.getITxtChunks() catch &[_]Chunk{};
        defer arena.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(arena);
            if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed and a1111_text == null)
                a1111_text = arena.dupe(u8, content.text) catch null;
        }
    }

    // ComfyUI workflow / prompt, A1111 fallback from tEXt chunks
    var workflow_text: ?[]const u8 = null;
    var prompt_text: ?[]const u8   = null;
    {
        const chunks = try parser.getTExtChunks();
        defer arena.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseTExtChunk(chunk) catch continue;
            defer content.deinit(arena);
            if (std.mem.eql(u8, content.keyword, "workflow")) {
                if (workflow_text == null) workflow_text = arena.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "prompt")) {
                if (prompt_text == null) prompt_text = arena.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "parameters")) {
                if (a1111_text == null) a1111_text = arena.dupe(u8, content.text) catch null;
            }
        }
    }

    if (a1111_text == null and workflow_text == null and prompt_text == null) {
        _ = stats.n_no_meta.fetchAdd(1, .acq_rel);
        return null;
    }

    // Priority: A1111 → ComfyUI workflow → ComfyUI prompt chunk
    var comfy = ComfyParser.init(arena);
    var result: ?ParseResult = null;
    if (a1111_text) |t| result = comfy.parseA1111Parameters(t) catch null;
    if (result == null) if (workflow_text) |t| { result = comfy.parseWorkflow(t) catch null; };
    if (result == null) if (prompt_text) |t| { result = comfy.parsePromptChunk(t) catch null; };

    var pr = result orelse {
        _ = stats.n_no_prompt.fetchAdd(1, .acq_rel);
        return null;
    };
    defer pr.deinit(arena);

    const prompt = pr.positive_prompt orelse {
        _ = stats.n_no_prompt.fetchAdd(1, .acq_rel);
        return null;
    };
    return try arena.dupe(u8, prompt);
}

fn nsToSec(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}
