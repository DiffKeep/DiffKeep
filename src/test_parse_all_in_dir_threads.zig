const std = @import("std");
const PngParser = @import("image/png-data.zig").PngParser;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const Atomic = std.atomic.Value(i64);

/// WARNING
/// WIP - do not use
/// WARNING
pub fn main() !void {
    const test_dir_path = "/home/qt/genai/comfyui/output/2025"; // Adjust path as needed

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    // Use a fixed buffer allocator for the thread pool to avoid excessive allocations
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = arena.allocator(),
        .n_jobs = 15, // Adjust number of threads as needed
    });
    defer thread_pool.deinit();

    try walkDirectory(gpa.allocator(), test_dir_path, &thread_pool);

    std.debug.print("Done parsing {d} files\n", .{file_count.load(.monotonic)});
}

var file_count = Atomic.init(0);

fn walkDirectory(allocator: std.mem.Allocator, dir_path: []const u8, thread_pool: *std.Thread.Pool) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer dir.close();
    var wg: std.Thread.WaitGroup = .{};

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try walkDirectory(allocator, full_path, thread_pool); // Recurse into subdirectories
            allocator.free(full_path); // Free after the recursive call
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            // full_path will be freed by processFile
            thread_pool.spawnWg(&wg, processFile, .{ allocator, full_path });
        } else {
            allocator.free(full_path); // Free if not used
        }
    }
    wg.wait();
}

fn processFile(
    allocator: std.mem.Allocator,
    full_path: []const u8,
) void {
    _ = file_count.fetchAdd(1, .acq_rel);
    defer allocator.free(full_path);
    //std.debug.print("Parsing file {d}, {s}\n", .{count, full_path });
    var parser = PngParser.init(allocator);
    defer parser.deinit();
    parser.parseFile(full_path) catch return;

    var comfy_parser = ComfyParser.init(allocator);

    // Check if we have any tEXt chunks
    const text_chunks = parser.getTExtChunks();
    defer parser.allocator.free(text_chunks);

    var found: i64 = 0;
    for (text_chunks) |chunk| {
        var content = parser.parseTExtChunk(chunk) catch return;
        defer content.deinit(allocator);

        if (std.mem.eql(u8, content.keyword, "prompt")) {
            found += 1;
        } else if (std.mem.eql(u8, content.keyword, "workflow")) {
            found += 1;
            const prompt = comfy_parser.parseWorkflow(content.text) catch return;
            if (prompt == null) {
                std.debug.print("Found workflow chunk but prompt is null in {s}\n", .{full_path});
                return;
            } else {
                //std.debug.print("Prompt found in {s}:\n{s}\n", .{ full_path, prompt.? });
            }
            allocator.free(prompt.?);
        }
    }

    if (found < 2) {
        std.debug.print("Chunks not found in {s}\n", .{full_path});
        for (parser.chunks.items) |found_chunk| {
            if (std.mem.eql(u8, found_chunk.type[0..4], "tEXt")) {
                var content = parser.parseTExtChunk(found_chunk) catch return;
                defer content.deinit(allocator);
                std.debug.print("{s}: {s} ", .{ found_chunk.type, content.keyword });
            }
            std.debug.print("{s} ", .{found_chunk.type});
        }
        std.debug.print("\n", .{});
        return;
    }
}