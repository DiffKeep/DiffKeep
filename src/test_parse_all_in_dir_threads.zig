const std = @import("std");
const PngParser = @import("image/png-data.zig").PngParser;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const Atomic = std.atomic.Value(i64);

/// WARNING
/// WIP - do not use
/// WARNING
pub fn main() !void {
    const test_dir_path = "/home/qt/genai/comfyui/output"; // Adjust path as needed

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    //defer arena.deinit();
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = gpa.allocator(),
        .n_jobs = 16, // Adjust number of threads as needed
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
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try walkDirectory(allocator, full_path, thread_pool); // Recurse into subdirectories
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            // Spawn a thread to process the file
            thread_pool.spawnWg(&wg, processFile, .{ allocator, try allocator.dupe(u8, full_path) });
        }
    }
    wg.wait();
}

fn processFile(
    allocator: std.mem.Allocator,
    full_path: []const u8,
) void {
    defer allocator.free(full_path);

    _ = file_count.fetchAdd(1, .acq_rel);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file = std.fs.cwd().openFile(full_path, .{}) catch return;
    defer file.close();

    var parser = PngParser.init(arena_allocator);
    defer parser.deinit();

    const file_size = file.getEndPos() catch {
        std.debug.print("Failed getting files size of {s}", .{full_path});
        return;
    };
    const buffer = arena_allocator.alloc(u8, file_size) catch {
        std.debug.print("OOM error reading file {s}", .{full_path});
        return;
    };
    _ = file.read(buffer) catch {
        std.debug.print("error reading file into buffer: {s}", .{full_path});
        return;
    };
    parser.parseBuffer(buffer) catch {
        std.debug.print("error parsing reading file {s}", .{full_path});
        return;
    };

    var comfy_parser = ComfyParser.init(arena_allocator);

    // Check if we have any tEXt chunks
    const text_chunks = parser.getTExtChunks();

    var found: i64 = 0;
    for (text_chunks) |chunk| {
        var content = parser.parseTExtChunk(chunk) catch return;
        defer content.deinit(arena_allocator);

        if (std.mem.eql(u8, content.keyword, "prompt")) {
            found += 1;
        } else if (std.mem.eql(u8, content.keyword, "workflow")) {
            found += 1;
            const prompt = comfy_parser.parseWorkflow(content.text) catch return;
            if (prompt == null) {
                std.debug.print("Found workflow chunk but prompt is null in {s}\n", .{full_path});
                return;
            }
            // No need to free prompt, as it's allocated using the arena allocator
        }
    }

    if (found < 2) {
        std.debug.print("Chunks not found in {s}\n", .{full_path});
        for (parser.chunks.items) |found_chunk| {
            if (std.mem.eql(u8, found_chunk.type[0..4], "tEXt")) {
                var content = parser.parseTExtChunk(found_chunk) catch return;
                defer content.deinit(arena_allocator);
                std.debug.print("{s}: {s} ", .{ found_chunk.type, content.keyword });
            }
            std.debug.print("{s} ", .{found_chunk.type});
        }
        std.debug.print("\n", .{});
    }
}