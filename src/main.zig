const std = @import("std");
const flags = @import("flags");
const db = @import("db.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const LibraryParser = @import("parse/parse_library.zig").LibraryParser;
const PngParser = @import("image/png-data.zig").PngParser;
const llama = @import("llama.zig");
const cmdFlags = @import("cmd_flags.zig");
const zstbi = @import("zstbi");
const util = @import("util.zig");

const build_options = @import("build_options");

const log = if (@import("builtin").target.os.tag == .windows)
    struct {
        pub fn output(comptime fmt: []const u8, args: anytype) !void {
            // On Windows GUI, write to a log file instead
            const log_file = try std.fs.cwd().createFile("debug.log", .{});
            defer log_file.close();
            try log_file.writer().print(fmt, args);
        }
        pub fn log(comptime fmt: []const u8, args: anytype) !void {
            return .output(fmt, args);
        }
    }
else
    struct {
        pub fn output(comptime fmt: []const u8, args: anytype) !void {
            // output to stdout
            try std.io.getStdOut().writer().print(fmt, args);
        }
        pub fn log(comptime fmt: []const u8, args: anytype) !void {
            // output to stderr
            try std.io.getStdErr().writer().print(fmt, args);
        }
    };

// Modify the main function where you initialize the database
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = flags.parseOrExit(args, "stablekeepr", cmdFlags.Flags, .{
        // Use the `colors` option to provide a colorscheme for the error/help messages.
        // Specifying this as empty: `.colors = .{}` will disable colors.
        // Each field is a list of type `std.io.tty.Color`.
        .colors = &.{
            .error_label = &.{ .bright_red, .bold },
            .command_name = &.{.bright_green},
            .header = &.{ .yellow, .bold },
            .usage = &.{.dim},
        },
    });

    if (options.version == true) {
        try log.output("Version: {s}\n", .{build_options.version});
        return;
    }

    if (options.parse_file != null) {
        try log.output("Parsing file: {?s}\n", .{options.parse_file});
        const file = try std.fs.cwd().openFile(options.parse_file orelse "", .{});
        defer file.close();
        // parse the file to get the prompt
        var parser = PngParser.init(allocator);
        defer parser.deinit();
        var comfy_parser = ComfyParser.init(allocator);
        const file_size = file.getEndPos() catch {
            try log.output("Failed getting file size of {?s}\n", .{options.parse_file});
            return;
        };
        const buffer = allocator.alloc(u8, file_size) catch {
            try log.output("OOM error reading file {?s}\n", .{options.parse_file});
            return;
        };
        defer allocator.free(buffer);
        _ = file.read(buffer) catch {
            try log.output("error reading file into buffer: {?s}\n", .{options.parse_file});
            return;
        };
        parser.parseBuffer(buffer) catch {
            try log.output("error parsing reading file {?s}\n", .{options.parse_file});
            return;
        };

        var found_prompt: ?[]const u8 = null;
        defer if (found_prompt != null) allocator.free(found_prompt.?);

        const text_chunks = parser.getTExtChunks();
        defer allocator.free(text_chunks);
        for (text_chunks) |chunk| {
            var content = parser.parseTExtChunk(chunk) catch return;
            defer content.deinit(allocator);

            if (std.mem.eql(u8, content.keyword, "workflow")) {
                const prompt = comfy_parser.parseWorkflow(content.text) catch return;
                defer if (prompt != null) allocator.free(prompt.?);

                if (prompt) |p| {
                    found_prompt = try allocator.dupe(u8, p);
                } else {
                    try log.output("Found workflow chunk but prompt is null in {?s}\n", .{options.parse_file});
                }
            }
        }

        if (found_prompt) |prompt| {
            try log.output("Prompt: {s}\n", .{prompt});
        }

        return;
    }

    // Initialize the vector database with the appropriate path
    const db_path = try util.getDataPath(allocator, &options, "diffkeep.db");
    defer allocator.free(db_path);

    try log.output("Using database at: {s}\n", .{db_path});

    var vector_db = try db.VectorDb.init(allocator, db_path);
    defer vector_db.deinit();

    zstbi.init(allocator);
    defer zstbi.deinit();

    // create / get the library
    const library_path = "/home/qt/genai/comfyui/output/2025/04/";
    const id = try vector_db.storeLibrary(library_path);

    // parse the library
    var lib_parser = try LibraryParser.init(allocator, &vector_db, &options, id, library_path);
    defer lib_parser.deinit();
    try lib_parser.parse();
    try log.output("Done parsing!\n", .{});
}

// Helper function to get or create an image ID
fn getImageId(vdb: *db.VectorDb, filepath: []const u8) !u64 {
    // Check if the image already exists
    const sql = "SELECT id FROM images WHERE path = ?";
    var stmt = try vdb.db.prepare(sql);
    defer stmt.deinit();

    try stmt.bind(1, filepath);

    if (try stmt.step()) {
        // Image exists, return its ID
        return stmt.columnInt64(0);
    } else {
        // Image doesn't exist, insert it
        const insert_sql = "INSERT INTO images (path) VALUES (?)";
        var insert_stmt = try vdb.db.prepare(insert_sql);
        defer insert_stmt.deinit();

        try insert_stmt.bind(1, filepath);
        _ = try insert_stmt.step();

        return vdb.db.getLastInsertRowID();
    }
}

// Function to store the embedding in the SQLite database
fn storeEmbeddingInDatabase(vdb: *db.VectorDb, prompt: []const u8, emb: []const f32) !void {
    const sql = "INSERT INTO embeddings (prompt, embedding) VALUES (?, ?)";
    var stmt = try vdb.db.prepare(sql);
    defer stmt.deinit();

    try stmt.bind(1, prompt);
    try stmt.bindBlob(2, std.mem.sliceAsBytes(emb));

    const ok = try stmt.step();
    if (!ok) {
        std.log.err("Error executing prepared statement", .{});
    }
}
