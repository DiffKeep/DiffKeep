const std = @import("std");
const png = @import("image/png-data.zig");
const PngParser = png.PngParser;
const Chunk = png.Chunk;
const ComfyParser = @import("parse/comfy.zig").ComfyParser;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // skip argv[0]
    const dir_path = args.next() orelse {
        std.log.err("usage: test_parse_all_in_dir <directory>", .{});
        return error.MissingArgument;
    };

    var parser = try PngParser.init(allocator, io);
    defer parser.deinit();

    try walkDirectory(allocator, io, dir_path, &parser);
    std.log.info("Done. Parsed {d} files.", .{count});
}

var count: i64 = 0;

fn walkDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, parser: *PngParser) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer dir.close(io);

    var dir_iter = dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        const full_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try walkDirectory(allocator, io, full_path, parser);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            count += 1;
            std.log.debug("Parsing file {d}: {s}", .{ count, full_path });
            try parser.parseFile(full_path);

            var comfy_parser = ComfyParser.init(allocator);
            var a1111_text: ?[]const u8 = null;
            var workflow_text: ?[]const u8 = null;
            var prompt_text: ?[]const u8 = null;
            defer if (a1111_text) |t| allocator.free(t);
            defer if (workflow_text) |t| allocator.free(t);
            defer if (prompt_text) |t| allocator.free(t);

            // Check iTXt chunks for A1111-format parameters
            {
                const itxt_chunks = parser.getITxtChunks() catch &[_]Chunk{};
                defer allocator.free(itxt_chunks);
                for (itxt_chunks) |chunk| {
                    var content = parser.parseITxtChunk(chunk) catch continue;
                    defer content.deinit(allocator);
                    if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed) {
                        if (a1111_text == null)
                            a1111_text = allocator.dupe(u8, content.text) catch null;
                    }
                }
            }

            // Check tEXt chunks for workflow, prompt, and A1111 parameters
            {
                const text_chunks = try parser.getTExtChunks();
                defer allocator.free(text_chunks);
                for (text_chunks) |chunk| {
                    var content = try parser.parseTExtChunk(chunk);
                    defer content.deinit(allocator);
                    if (std.mem.eql(u8, content.keyword, "parameters")) {
                        if (a1111_text == null)
                            a1111_text = allocator.dupe(u8, content.text) catch null;
                    } else if (std.mem.eql(u8, content.keyword, "prompt")) {
                        if (prompt_text == null)
                            prompt_text = allocator.dupe(u8, content.text) catch null;
                    } else if (std.mem.eql(u8, content.keyword, "workflow")) {
                        if (workflow_text == null)
                            workflow_text = allocator.dupe(u8, content.text) catch null;
                    }
                }
            }

            // Priority: A1111 parameters → workflow JSON → prompt JSON
            var maybe_result: ?@import("parse/comfy.zig").ParseResult = null;
            if (a1111_text) |at| {
                maybe_result = comfy_parser.parseA1111Parameters(at) catch null;
            }
            if (maybe_result == null) {
                if (workflow_text) |wt| {
                    maybe_result = comfy_parser.parseWorkflow(wt) catch null;
                }
            }
            if (maybe_result == null) {
                if (prompt_text) |pt| {
                    maybe_result = comfy_parser.parsePromptChunk(pt) catch null;
                }
            }

            if (maybe_result) |*result| {
                defer result.deinit(allocator);
                if (result.positive_prompt) |p| {
                    std.log.debug("Prompt found in {s}:\n{s}", .{ full_path, p });
                } else {
                    std.log.debug("Parsed but no prompt in {s}", .{full_path});
                }
            } else {
                if (a1111_text != null or workflow_text != null or prompt_text != null) {
                    std.log.debug("Could not extract prompt from {s}", .{full_path});
                } else {
                    std.log.debug("No metadata chunks in {s}", .{full_path});
                }
            }
        }
    }
}
