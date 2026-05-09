const std = @import("std");
const db = @import("db.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const LibraryParser = @import("parse/parse_library.zig").LibraryParser;
const PngParser = @import("image/png-data.zig").PngParser;
const llama = @import("llama.zig");
const cmdFlags = @import("cmd_flags.zig");
const vips = @import("vips");
const util = @import("util.zig");
const clap = @import("clap");
const known_folders = @import("known-folders");

const build_options = @import("build_options");

// Modify the main function where you initialize the database
pub fn main(init: std.process.Init) !void {
    var allocator = init.gpa;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-v, --version          Display the version and exit.
        \\-p, --parse <str>      Parse a file.
        \\-c, --config <str>     Specify a config file. Default is known folders.
        \\
    );

    // Initialize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();


    if (res.args.version != 0) {
        std.log.info("Version: {s}\n", .{build_options.version});
        return;
    }

    if (res.args.parse) |parse_file| {
        std.log.info("Parsing file: {s}\n", .{parse_file});
        const file = try std.Io.Dir.cwd().openFile(init.io, parse_file, .{});
        defer file.close(init.io);
        // parse the file to get the prompt
        var parser = try PngParser.init(allocator, init.io);
        defer parser.deinit();
        var comfy_parser = ComfyParser.init(allocator);
        const file_size = file.length(init.io) catch {
            std.log.info("Failed getting file size of {s}\n", .{parse_file});
            return;
        };
        const buffer = allocator.alloc(u8, file_size) catch {
            std.log.info("OOM error reading file {s}\n", .{parse_file});
            return;
        };
        defer allocator.free(buffer);
        _ = file.readPositionalAll(init.io, buffer, 0) catch {
            std.log.info("error reading file into buffer: {s}\n", .{parse_file});
            return;
        };
        parser.parseBuffer(buffer) catch {
            std.log.info("error parsing reading file {s}\n", .{parse_file});
            return;
        };

        const text_chunks = try parser.getTExtChunks();
        defer allocator.free(text_chunks);
        for (text_chunks) |chunk| {
            var content = parser.parseTExtChunk(chunk) catch return;
            defer content.deinit(allocator);

            if (std.mem.eql(u8, content.keyword, "workflow")) {
                var maybe_result = comfy_parser.parseWorkflow(content.text) catch return;
                if (maybe_result) |*result| {
                    defer result.deinit(allocator);
                    if (result.positive_prompt) |p| std.log.info("Prompt: {s}\n", .{p});
                    if (result.negative_prompt) |p| std.log.info("Negative: {s}\n", .{p});
                    if (result.model) |m| std.log.info("Model: {s}\n", .{m});
                    if (result.steps) |s| std.log.info("Steps: {d}\n", .{s});
                    if (result.cfg) |c| std.log.info("CFG: {d}\n", .{c});
                    if (result.seed) |s| std.log.info("Seed: {d}\n", .{s});
                    if (result.sampler) |s| std.log.info("Sampler: {s}\n", .{s});
                    if (result.scheduler) |s| std.log.info("Scheduler: {s}\n", .{s});
                    if (result.loras) |loras| {
                        for (loras) |lora| std.log.info("LoRA: {s}\n", .{lora});
                    }
                } else {
                    std.log.info("Found workflow chunk but could not extract prompt from {s}\n", .{parse_file});
                }
            }
        }

        return;
    }

    // get the config path
    var config_path: ?[]const u8 = null;
    if (res.args.config) |config| {
        config_path = try allocator.dupe(u8, config);
    } else {
        config_path = try known_folders.getPath(init.io, allocator, init.environ_map, .local_configuration);
        if (config_path == null) {
            return error.UnableToGetConfigPath;
        }
    }
    defer allocator.free(config_path.?);

    // Initialize the vector database with the appropriate path
    const db_path = try util.getDataPath(allocator, init.io, config_path.?, "diffkeep.db");
    defer allocator.free(db_path);

    std.log.info("Using database at: {s}\n", .{db_path});

    var vector_db = try db.VectorDb.init(allocator, init.io, db_path);
    defer vector_db.deinit();

    try vips.init();
    defer vips.deinit();

    // create / get the library
    const library_path = "/home/qt/genai/comfyui/output/2025/04/";
    const id = try vector_db.storeLibrary(library_path);

    // parse the library
    var lib_parser = try LibraryParser.init(allocator, &vector_db, id, library_path);
    defer lib_parser.deinit();
    try lib_parser.parse(init.io);
    std.log.info("Done parsing!\n", .{});
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
