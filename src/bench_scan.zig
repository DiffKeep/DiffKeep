//! Dev tool: time a full library scan (parse, hash, thumbnail; embeddings
//! only when given model dirs) of a folder into a throwaway DB.
//!
//!   zig build bench_scan -Doptimize=ReleaseFast -- DIR [--db FILE] [--runs N]
//!       [--text-model DIR] [--visual-model DIR] [--gpu none|cuda|vulkan]
//!
//! With a model dir, the scan also computes those embeddings (prompt / image).
//!
//! Each run starts from an empty DB (the file is deleted first), so every file
//! is new. Prints wall time, files/s and peak RSS. Peak threads can be sampled
//! from outside: `grep Threads /proc/<pid>/status`.

const std = @import("std");
const db_mod = @import("db.zig");
const scan = @import("scan.zig");
const vips = @import("vips");
const embedder_mod = @import("embedder.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir: ?[]const u8 = null;
    var db_path: []const u8 = "/tmp/diffkeep_bench_scan.db";
    var runs: u32 = 1;
    var text_model: ?[]const u8 = null;
    var visual_model: ?[]const u8 = null;
    var gpu: embedder_mod.GpuBackend = .cuda;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--db")) {
            db_path = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--runs")) {
            runs = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--text-model")) {
            text_model = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--visual-model")) {
            visual_model = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--gpu")) {
            gpu = std.meta.stringToEnum(embedder_mod.GpuBackend, args.next() orelse return error.MissingArg) orelse return error.BadArg;
        } else dir = a;
    }
    const lib_path = dir orelse {
        std.debug.print("usage: bench_scan DIR [--db FILE] [--runs N] [--text-model DIR] [--visual-model DIR] [--gpu none|cuda|vulkan]\n", .{});
        return error.MissingArg;
    };

    try vips.init();
    defer vips.deinit();

    var embedder: ?embedder_mod.Embedder = if (text_model != null or visual_model != null)
        try embedder_mod.Embedder.init(io, gpa, text_model, visual_model, gpu, 4)
    else
        null;
    defer if (embedder) |*e| e.deinit();

    for (0..runs) |run| {
        inline for (.{ "", "-wal", "-shm" }) |suffix| {
            const p = try std.fmt.allocPrint(arena, "{s}{s}", .{ db_path, suffix });
            std.Io.Dir.cwd().deleteFile(io, p) catch {};
        }
        var db = try db_mod.VectorDb.init(gpa, io, db_path);
        defer db.deinit();
        const lib_id = try db.storeLibrary(lib_path);

        var scanner = scan.LibraryScanner.init(gpa, &db, null);
        defer scanner.deinit();
        if (embedder) |*e| scanner.embedder = e;
        var stop: std.atomic.Value(bool) = .init(false);
        var scanned: std.atomic.Value(u32) = .init(0);
        var embed_done: std.atomic.Value(u32) = .init(0);
        var embed_total: std.atomic.Value(u32) = .init(0);

        const t0 = std.Io.Clock.awake.now(io);
        const stats = try scanner.scanLibrary(io, lib_id, lib_path, &stop, &scanned, &embed_done, &embed_total, true, text_model != null, visual_model != null);
        const ms = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds())) / 1e6;

        const files = stats.added + stats.updated + stats.unchanged;
        std.debug.print("run {d}: {d} files in {d:.0} ms ({d:.1} files/s), {d}/{d} embedded, peak RSS {d} MB\n", .{
            run + 1, files, ms, @as(f64, @floatFromInt(files)) * 1000.0 / ms, embed_done.load(.acquire), embed_total.load(.acquire), peakRssMb(),
        });
    }
}

fn peakRssMb() i64 {
    var ru: std.posix.rusage = undefined;
    ru = std.posix.getrusage(std.posix.rusage.SELF);
    return @divTrunc(ru.maxrss, 1024);
}
