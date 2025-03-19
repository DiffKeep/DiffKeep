const std = @import("std");
const PngParser = @import("image/png-data.zig").PngParser;

pub fn main() !void {
    const file = "/home/qt/genai/comfyui/output/2024/06/27/16:26:14-1850508668_00001_.png"; // Adjust path as needed

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    var parser = PngParser.init(gpa.allocator());
    defer parser.deinit();

    try getWorkflow(gpa.allocator(), file, &parser);
}

fn getWorkflow(allocator: std.mem.Allocator, file: []const u8, parser: *PngParser) !void {
    std.log.debug("Parsing file {s}\n", .{ file });
    try parser.parseFile(file);

    // Check if we have any tEXt chunks
    const text_chunks = parser.getTExtChunks();
    defer parser.allocator.free(text_chunks);
    // Process tEXt chunks as needed
    var found = false;
    for (text_chunks) |chunk| {
        var content = try parser.parseTExtChunk(chunk);
        defer content.deinit(allocator);
        if (std.mem.eql(u8, content.keyword, "workflow")) {
            found = true;
            std.log.debug("Found workflow chunk: {s}\n", .{content.keyword});
            std.log.debug("{s}\n", .{content.text});
        }
    }
    if (!found) {
        std.log.debug("Chunks not found in {s}\n", .{file});
        // loop over all the found chunk types and print them
        std.log.debug("Found {d} chunks: ", .{parser.chunks.items.len});
        var text = false;
        var workflow = false;
        for (parser.chunks.items) |found_chunk| {
            if (std.mem.eql(u8, &found_chunk.type, "tEXt")) {
                text = true;
                var content = try parser.parseTExtChunk(found_chunk);
                defer content.deinit(allocator);
                std.log.debug("{s}: {s} ", .{ found_chunk.type, content.keyword });
                // bypass if we have only a prompt for now
                if (std.mem.eql(u8, content.keyword, "workflow")) {
                    workflow = true;
                }
            } else {
                std.log.debug("{s} ", .{found_chunk.type});
            }
        }
        std.log.debug("\n", .{});
    }
}
