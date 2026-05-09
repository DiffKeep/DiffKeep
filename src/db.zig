const std = @import("std");
const sqlite = @import("sqlite");
const models = @import("models.zig");
const log = std.log.scoped(.db);

/// Result struct for vector searches
pub const SearchResult = struct {
    id: u64,
    distance: f32,
    prompt: ?[]const u8 = null,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        if (self.prompt) |p| {
            allocator.free(p);
        }
    }
};

pub const VectorDb = struct {
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    pool: sqlite.ConnectionPool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !VectorDb {
        var pool = try sqlite.ConnectionPool.init(allocator, io, path, 16);
        errdefer pool.deinit();

        var db = try pool.acquire();

        // Initialize the database

        try db.exec(
            \\CREATE TABLE IF NOT EXISTS libraries (
            \\  id INTEGER PRIMARY KEY,
            \\  path TEXT UNIQUE NOT NULL
            \\) STRICT;
            \\CREATE TABLE IF NOT EXISTS images (
            \\  id INTEGER PRIMARY KEY,
            \\  library_path TEXT NOT NULL,
            \\  library_id INTEGER,
            \\  creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  positive_prompt_text TEXT,
            \\  negative_prompt_text TEXT,
            \\  generated_description TEXT,
            \\  thumbnail BLOB,
            \\  hash TEXT,
            \\  FOREIGN KEY (library_id) REFERENCES libraries(id) ON DELETE CASCADE
            \\) STRICT;
        );

        // Create vector tables
        try db.createVectorTable("image_embeddings", 1024);
        try db.createVectorTable("positive_prompt_embeddings", 1024);

        return VectorDb{
            .db = db,
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn getConnection(self: *VectorDb) !VectorDb {
        log.debug("Getting a new connection", .{});
        return VectorDb{
            .db = try self.pool.acquire(),
            .pool = self.pool,
            .allocator = self.allocator,
        };
    }

    pub fn deinit(self: *VectorDb) void {
        log.debug("Releasing connection", .{});
        self.pool.release(&self.db) catch {};
    }

    pub fn storeImageEmbedding(self: *VectorDb, id: usize, embedding: []const f32) !void {
        try self.db.insertVector("image_embeddings", id, embedding);
    }

    pub fn findSimilarImages(self: *VectorDb, query_embedding: []const f32, limit: usize) !std.ArrayList(sqlite.VecResult) {
        return try self.db.searchNearestVectors("image_embeddings", query_embedding, limit);
    }

    pub fn storeLibrary(self: *VectorDb, library_path: []const u8) !u32 {
        // First, try to find if the library already exists
        {
            var stmt = self.db.statements.find_library;
            try stmt.reset();

            try stmt.bind(1, library_path);

            if (try stmt.step()) {
                // Library found, return the ID
                return @intCast(stmt.columnInt64(0));
            }
        }

        // Library not found, insert it
        {
            var stmt = self.db.statements.insert_library;
            try stmt.reset();

            try stmt.bind(1, library_path);
            _ = try stmt.step();
        }

        // Return the ID of the newly inserted library
        return @intCast(self.db.getLastInsertRowID());
    }

    /// Store a prompt embedding in the database
    pub fn storePromptEmbedding(self: *VectorDb, image_id: u64, embedding: []const f32, positive: bool) !void {
        var stmt: sqlite.PreparedStatement = undefined;
        if (positive) {
            stmt = try self.db.prepare("INSERT OR REPLACE INTO positive_prompt_embeddings (image_id, embedding) VALUES (?, vector_embed(?, 1024))");
        } else {
            stmt = try self.db.prepare("INSERT OR REPLACE INTO negative_prompt_embeddings (image_id, embedding) VALUES (?, vector_embed(?, 1024))");
        }
        defer stmt.deinit();

        try stmt.bind(1, image_id);
        try stmt.bindBlob(2, std.mem.sliceAsBytes(embedding[0..1024]));

        _ = try stmt.step();
    }

    /// Find similar images based on a prompt embedding
    pub fn findSimilarPrompts(self: *VectorDb, query_embedding: [*]const f32, limit: usize) !std.ArrayList(SearchResult) {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer results.deinit();

        const sql =
            \\SELECT p.image_id, p.prompt_text, vector_distance(pe.embedding, vector_embed(?)) as distance
            \\FROM prompt_embeddings pe
            \\JOIN prompts p ON p.image_id = pe.image_id
            \\ORDER BY distance ASC
            \\LIMIT ?
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        try stmt.bindBlob(1, std.mem.sliceAsBytes(query_embedding[0..768]));
        try stmt.bind(2, @as(i64, @intCast(limit)));

        while (try stmt.step()) {
            try results.append(.{
                .id = @intCast(stmt.columnInt64(0)),
                .distance = stmt.columnFloat(2),
                .prompt = try self.allocator.dupe(u8, stmt.columnText(1)),
            });
        }

        return results;
    }

    pub fn findOrCreateImage(self: *VectorDb, library_id: u64, image_path: []const u8) !models.Image {

        // Temporarally return a fake image object to avoid the db hit
        return models.Image{
            .id = 1,
            .libraryId = library_id,
            .libraryPath = try self.allocator.dupe(u8, image_path),
            .creationDate = "2024-03-21 15:30:45",
            .positivePromptText = null,
            .negativePromptText = null,
            .generatedDescription = null,
            .thumbnail = null,
            .hash = null,
        };
        // First check if the image already exists by checking the path
        // {
        //     var stmt = self.db.statements.find_image;
        //     try stmt.reset();
        //
        //     try stmt.bind(1, library_id);
        //     try stmt.bind(2, image_path);
        //
        //     if (try stmt.step()) {
        //         // Image found, return it
        //         log.debug("Found existing image, id {d}\n", .{stmt.columnInt64(0)});
        //         return models.Image{
        //             .id = @intCast(stmt.columnInt64(0)),
        //             .libraryId = @intCast(stmt.columnInt64(1)),
        //             .libraryPath = try self.allocator.dupe(u8, stmt.columnText(2)),
        //             .creationDate = try self.allocator.dupe(u8, stmt.columnText(3)),
        //             .positivePromptText = if (stmt.columnIsNull(4)) null else try self.allocator.dupe(u8, stmt.columnText(4)),
        //             .negativePromptText = if (stmt.columnIsNull(5)) null else try self.allocator.dupe(u8, stmt.columnText(5)),
        //             .generatedDescription = if (stmt.columnIsNull(6)) null else try self.allocator.dupe(u8, stmt.columnText(6)),
        //             .thumbnail = if (stmt.columnIsNull(7)) null else try self.allocator.dupe(u8, stmt.columnBlob(7)),
        //             .hash = if (stmt.columnIsNull(8)) null else try self.allocator.dupe(u8, stmt.columnText(8)),
        //         };
        //     }
        // }
        //
        // // Image not found, create a new entry
        // {
        //     var stmt = self.db.statements.insert_image;
        //     try stmt.reset();
        //
        //     try stmt.bind(1, library_id);
        //     try stmt.bind(2, image_path);
        //
        //     _ = try stmt.step();
        //     log.debug("Created new image for {s}\n", .{image_path});
        // }
        //
        // // Return the new image object
        // return models.Image{
        //     .id = @intCast(self.db.getLastInsertRowID()),
        //     .libraryId = library_id,
        //     .libraryPath = try self.allocator.dupe(u8, image_path),
        //     .creationDate = try self.allocator.dupe(u8, try self.getCurrentTimestamp()),
        //     .positivePromptText = null,
        //     .negativePromptText = null,
        //     .generatedDescription = null,
        //     .thumbnail = null,
        //     .hash = null,
        // };
    }

    pub fn saveImage(self: *VectorDb, image: *const models.Image) !void {
        var stmt = self.db.statements.update_image;
        try stmt.reset();

        // Handle nullable text fields
        if (image.positivePromptText) |text| {
            try stmt.bind(1, text);
        } else {
            try stmt.bindNull(1);
        }

        if (image.negativePromptText) |text| {
            try stmt.bind(2, text);
        } else {
            try stmt.bindNull(2);
        }

        if (image.generatedDescription) |text| {
            try stmt.bind(3, text);
        } else {
            try stmt.bindNull(3);
        }

        if (image.thumbnail) |thumb| {
            try stmt.bindBlob(4, thumb);
        } else {
            try stmt.bindNull(4);
        }

        if (image.hash) |hash| {
            try stmt.bind(5, hash);
        } else {
            try stmt.bindNull(5);
        }

        try stmt.bind(6, image.id);

        _ = try stmt.step();
    }

    // Helper method to get current timestamp in the format used by the database
    fn getCurrentTimestamp(self: *VectorDb) ![]const u8 {
        var stmt = try self.db.prepare("SELECT CURRENT_TIMESTAMP");
        defer stmt.deinit();

        if (try stmt.step()) {
            return try self.allocator.dupe(u8, stmt.columnText(0));
        }

        return error.FailedToGetTimestamp;
    }
};
