const std = @import("std");
const db = @import("../db.zig");
const PngParser = @import("../image/png-data.zig").PngParser;
const ComfyParser = @import("comfy.zig").ComfyParser;
const cmdFlags = @import("../cmd_flags.zig");
const llama = @import("../llama.zig");
const models = @import("../models.zig");
const util = @import("../util.zig");
const log = std.log.scoped(.library_parser);
const Atomic = std.atomic.Value(i64);

pub const LibraryParser = struct {
    allocator: std.mem.Allocator,
    db: *db.VectorDb,
    options: *const cmdFlags.Flags,
    library_id: u32,
    library_path: []const u8,

    //llama_pool: *llama.Pool,
    //llama_context: *llama.Context,
    llama_context_size: u32,
    queue: *std.Thread.Pool,
    file_count: Atomic,

    pub fn init(allocator: std.mem.Allocator, vdb: *db.VectorDb, options: *const cmdFlags.Flags, library_id: u32, library_path: []const u8) !LibraryParser {
        // Initialize llama options
        var poolOptions = llama.PoolOptions{
            .n_ctx = 512,
            .n_batch = 2048,
            .n_ubatch = 2048,
            .n_threads = null,
            .embeddings = true,
            .pooling_type = 0,
        };

        if (poolOptions.n_batch < poolOptions.n_ctx) {
            log.warn("Setting batch size to {d}", .{poolOptions.n_ctx});
            poolOptions.n_batch = poolOptions.n_ctx;
        }

        // For non-causal models, batch size must be equal to ubatch size
        poolOptions.n_ubatch = poolOptions.n_batch;

        //var pool = llama.Pool.init(allocator, poolOptions);

        // Get the model path
        const model_path = options.model_path orelse try util.getDataPath(allocator, options, "Models/gte-large.Q6_K.gguf");
        //defer allocator.free(model_path);
        log.debug("Loading model {s}", .{model_path});
        // Get the model context
        //const ctx = try pool.get(model_path, 5000); // 5 second timeout

        var thread_pool = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(thread_pool);
        try thread_pool.init(.{
            .allocator = allocator,
            .n_jobs = 16, // Adjust number of threads as needed
        });

        return LibraryParser{
            .allocator = allocator,
            .db = vdb,
            .options = options,
            .library_id = library_id,
            .library_path = library_path,
            //.llama_pool = &pool,
            //.llama_context = ctx,
            .llama_context_size = 512,
            .queue = thread_pool,
            .file_count = Atomic.init(0),
        };
    }

    pub fn deinit(self: *LibraryParser) void {
        log.debug("Freeing queue", .{});
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        //log.debug("Freeing llama pool", .{});
        //self.llama_pool.deinit();
    }

    pub fn parse(self: *LibraryParser) !void {
        try self.walkDirectory(self.library_path);

        log.debug("{d} files parsed.", .{self.file_count.load(.acquire)});
    }

    fn walkDirectory(self: *LibraryParser, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        });
        defer dir.close();
        var wg: std.Thread.WaitGroup = .{};

        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });

            if (entry.kind == .directory) {
                try self.walkDirectory(full_path); // Recurse into subdirectories
                self.allocator.free(full_path);
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
                // Insert the file into the queue
                log.debug("Queueing file {d}: {s}", .{self.file_count.fetchAdd(1, .acq_rel) + 1, full_path});
                self.queue.spawnWg(&wg, processFile, .{
                    full_path,
                    self.db,
                    self.allocator,
                    self.library_id,
                });
            } else {
                self.allocator.free(full_path);
            }
        }
        log.debug("Done queueing files", .{});
        wg.wait();
    }
};

fn generate_image_hash(file: std.fs.File, allocator: std.mem.Allocator) ![]const u8 {
    try file.seekTo(0);
    var hash = std.crypto.hash.Blake3.init(.{});

    // Use a buffer for reading the file in chunks
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;

        hash.update(buffer[0..bytes_read]);
    }

    var digest: [32]u8 = undefined;
    hash.final(&digest);

    // Convert the binary hash to a hex string
    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});

    return hex_digest;
}

fn complete_image_data(image: *models.Image, hash: []const u8, allocator: std.mem.Allocator, vdb: *db.VectorDb) !void {
    image.hash = hash;
    try image.generate_thumbnail(allocator, image.libraryPath);

    try vdb.saveImage(image);
}

fn generate_embeddings(self: *LibraryParser, allocator: std.mem.Allocator, prompt: []const u8, ctx_size: u32) !std.ArrayList([]const f32) {
    // Create embedding from the prompt
    const model_path = self.options.model_path orelse "Models/gte-large.Q6_K.gguf";
    return llama.createEmbeddingFromPrompt(allocator, model_path, prompt, ctx_size);
}

fn processFile(path: []const u8, vdb: *db.VectorDb, allocator: std.mem.Allocator, library_id: u32) void {
    log.debug("Processing file {s}", .{path});
    defer allocator.free(path);

    // get a db connection we can use
    var conn = vdb.getConnection() catch |err| {
        log.err("Failed to get DB connection: {}", .{err});
        return;
    };
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    var pngParser = PngParser.init(arena_allocator);

    var parser = ComfyParser.init(arena_allocator);

    const file_size = file.getEndPos() catch {
        log.debug("Failed getting files size of {s}", .{path});
        return;
    };
    const buffer = arena_allocator.alloc(u8, file_size) catch {
        log.debug("OOM error reading file {s}", .{path});
        return;
    };
    _ = file.read(buffer) catch {
        log.debug("error reading file into buffer: {s}", .{path});
        return;
    };
    pngParser.parseBuffer(buffer) catch {
        log.debug("error parsing reading file {s}", .{path});
        return;
    };

    // Check if we have any tEXt chunks
    const text_chunks = pngParser.getTExtChunks();

    var found: i64 = 0;
    for (text_chunks) |chunk| {
        const content = pngParser.parseTExtChunk(chunk) catch return;

        if (std.mem.eql(u8, content.keyword, "prompt")) {
            found += 1;
        } else if (std.mem.eql(u8, content.keyword, "workflow")) {
            found += 1;
            const prompt = parser.parseWorkflow(content.text) catch return;
            if (prompt == null) {
                log.debug("Found workflow chunk but prompt is null in {s}", .{path});
                return;
            } else {
                log.debug("Processing workflow chunk for {s}", .{path});
                // generate hash for image
                const hash = generate_image_hash(file, arena_allocator) catch |err| {
                    log.debug("Failed to generate hash for {s}: {any}", .{ path, err });
                    return;
                };

                // find or store image in database
                var image = conn.findOrCreateImage(library_id, path) catch |err| {
                    log.debug("Failed to find or create DB image for {s}: {any}", .{ path, err });
                    return;
                };
                // image resources are created in db, which isn't using the arena allocator
                //defer image.deinit(allocator);

                // make sure the file is the same
                if (image.hash) |existing_hash| {
                    if (!std.mem.eql(u8, existing_hash, hash)) {
                        log.debug("Hash is different for image {s}", .{path});
                        complete_image_data(&image, hash, arena_allocator, &conn) catch |err| {
                            log.debug("Failed to updated changed image {s}: {any}", .{ path, err });
                            return;
                        };
                    } else {
                        log.debug("Not updating existing image {s}", .{path});
                    }
                } else {
                    log.debug("Hash is empty, new image {s}", .{path});
                    complete_image_data(&image, hash, arena_allocator, &conn) catch |err| {
                        log.debug("Failed to updated new image {s}: {any}", .{ path, err });
                        return;
                    };
                }
            }
        }
    }

    if (found < 2) {
        log.debug("Chunks not found in {s}", .{path});
        for (pngParser.chunks.items) |found_chunk| {
            if (std.mem.eql(u8, found_chunk.type[0..4], "tEXt")) {
                const content = pngParser.parseTExtChunk(found_chunk) catch return;
                log.debug("{s}: {s} ", .{ found_chunk.type, content.keyword });
            }
            log.debug("{s} ", .{found_chunk.type});
        }
    }
    log.debug("Done processing image {s}", .{path});
}

const PromptEmbeddingContext = struct {
    ctx: *llama.Context,
    text: []const u8,
    result: ?[]f32 = null,
};

fn generateEmbedding(context: PromptEmbeddingContext) void {
    // Your embedding generation logic here
    context.result = context.model.generate_embedding(context.text);
}
