const std = @import("std");
const PngParser = @import("image/png-data.zig").PngParser;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;

pub fn main() !void {
    const test_dir_path = "/home/qt/genai/comfyui/output"; // Adjust path as needed

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    var parser = PngParser.init(gpa.allocator());
    defer parser.deinit();

    try walkDirectory(gpa.allocator(), test_dir_path, &parser);
}

var count: i64 = 0;

fn walkDirectory(allocator: std.mem.Allocator, dir_path: []const u8, parser: *PngParser) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer dir.close();


    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try walkDirectory(allocator, full_path, parser); // Recurse into subdirectories
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            count += 1;
            std.log.debug("Parsing file {d}, {s}\n", .{count, full_path});
            try parser.parseFile(full_path);

            var comfy_parser = ComfyParser.init(allocator);

            // Check if we have any tEXt chunks
            const text_chunks = parser.getTExtChunks();
            defer parser.allocator.free(text_chunks);
            // Process tEXt chunks as needed
            var found = false;
            for (text_chunks) |chunk| {
                var content = try parser.parseTExtChunk(chunk);
                defer content.deinit(allocator);

                // Check for prompt and workflow chunks
                if (std.mem.eql(u8, content.keyword, "parameters")) {
                    std.log.debug("parameters (automatic1111?) found in {s}\n", .{ full_path });
                    found = true;
                } else if (std.mem.eql(u8, content.keyword, "workflow")) {
                    found = true;
                    const prompt = try comfy_parser.parseWorkflow(content.text);
                    if (prompt == null) {
                        std.log.debug("Found workflow chunk but prompt is null in {s}\n", .{ full_path });
                        return error.MissingValue;
                    } else {
                        std.log.debug("Prompt found in {s}:\n{s}\n", .{ full_path, prompt.? });
                    }
                    allocator.free(prompt.?);
                }
            }
            if (!found) {
                std.log.debug("Chunks not found in {s}\n", .{ full_path });
                // loop over all the found chunk types and print them
                std.log.debug("Found {d} chunks: ", .{parser.chunks.items.len});
                var text = false;
                var workflow = false;
                for (parser.chunks.items) |found_chunk| {
                    if (std.mem.eql(u8, &found_chunk.type, "tEXt")) {
                        text = true;
                        var content = try parser.parseTExtChunk(found_chunk);
                        defer content.deinit(allocator);
                        std.log.debug("{s}: {s} ", .{found_chunk.type, content.keyword});
                        // bypass if we have only a prompt for now
                        if (std.mem.eql(u8, content.keyword, "workflow")) {
                            workflow = true;
                        }
                    } else {
                        std.log.debug("{s} ", .{found_chunk.type});
                    }
                }
                std.log.debug("\n", .{});
                if (text and workflow) {
                    return error.MissingValue;
                } else {
                    // we didn't find any workflow chunks, so there's nothing for us to do
                    continue;
                }
            }
        }
    }
}

