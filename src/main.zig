const std = @import("std");
const flags = @import("flags");
const db = @import("db.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const PngParser = @import("image/png-data.zig").PngParser;
const llama = @import("llama.zig");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = flags.parseOrExit(args, "stablekeepr", Flags, .{
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

            // Create embedding from the prompt
            const model_path = options.model_path orelse "Models/msmarco-distilbert-cos-v5.safetensors";
            var embeddings = try llama.createEmbeddingFromPrompt(allocator, model_path, prompt);
            defer {
                // Free each embedding slice
                for (embeddings.items) |embd| {
                    allocator.free(embd);
                }
                // Free the ArrayList itself
                embeddings.deinit();
            }

            // Store the embedding in the database
            //var vector_db = try db.VectorDb.init(allocator, "diffkeep.db");
            //defer vector_db.deinit();

            // Store the embedding
            //const image_id = try getImageId(vector_db, options.parse_file.?);
            //try vector_db.storePromptEmbedding(image_id, prompt, embedding.ptr);

            //try log.output("Stored embedding for image ID: {d}\n", .{image_id});

            // output the embeddings
            try log.output("Total embeddings: {d}\n", .{embeddings.items.len});
            for (embeddings.items, 0..) |emb, n| {
                try log.output("embedding {d}:\n", .{n});
                try log.output("Embedding size: {d}\n", .{emb.len});
                try log.output("[", .{});
                for (emb, 0..) |val, i| {
                    if (i > 0) try log.output(", ", .{});
                    try log.output("{d:.4}", .{val});
                }
                try log.output("]\n", .{});
            }
        }

        return;
    }

    // Initialize the vector database
    var vector_db = try db.VectorDb.init(allocator, "diffkeep.db");
    defer vector_db.deinit();
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

const Flags = struct {
    pub const description =
        \\DiffKeep runtime arguments help.
    ;

    // Optional description of some or all of the flags (must match field names in the struct).
    pub const descriptions = .{
        .version = "Print build version and exit.",
        .parse_file = "Path to the file to parse.",
        .model_path = "Path to the model to use for generating embeddings (must product 768 vectors).",
        .search_similar = "Search term to do a search across the image database.",
    };

    parse_file: ?[]const u8,
    version: bool,
    model_path: ?[]const u8 = null,
    search_similar: ?[]const u8 = null,

    // Optional declaration to define shorthands. These can be chained e.g '-fs large'.
    pub const switches = .{
        .version = 'v',
        .parse_file = 'f',
        .model_path = 'm',
        .search_similar = 's',
    };
};
