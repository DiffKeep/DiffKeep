const std = @import("std");
const sqlite = @import("sqlite");

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

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !VectorDb {
        var db = try sqlite.Database.open(allocator, path);
        errdefer db.close();

        // Initialize the database with vector tables
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA synchronous = NORMAL");

        try db.exec(
            \\CREATE TABLE IF NOT EXISTS images (
            \\  id INTEGER PRIMARY KEY,
            \\  path TEXT UNIQUE NOT NULL,
            \\  creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  positive_prompt_text TEXT NOT NULL,
            \\  negative_prompt_text TEXT NOT NULL
            \\);
        );


        // Create vector tables
        try db.createVectorTable("image_embeddings", 1024);
        try db.createVectorTable("prompt_embeddings", 1024);

        return VectorDb{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorDb) void {
        self.db.close();
    }

    pub fn storeImageEmbedding(self: *VectorDb, id: usize, embedding: []const f32) !void {
        try self.db.insertVector("image_embeddings", id, embedding);
    }

    pub fn findSimilarImages(self: *VectorDb, query_embedding: []const f32, limit: usize) !std.ArrayList(sqlite.VecResult) {
        return try self.db.searchNearestVectors("image_embeddings", query_embedding, limit);
    }

    /// Store a prompt embedding in the database
    pub fn storePromptEmbedding(self: *VectorDb, image_id: u64, prompt: []const u8, embedding: [*]const f32) !void {
        // First, store the prompt
        {
            const sql = "INSERT OR REPLACE INTO prompts (image_id, prompt_text) VALUES (?, ?)";
            var stmt = try self.db.prepare(sql);
            defer stmt.deinit();

            try stmt.bind(1, image_id);
            try stmt.bind(2, prompt);

            _ = try stmt.step();
        }

        // Then, store the embedding
        {
            const sql = "INSERT OR REPLACE INTO prompt_embeddings (image_id, embedding) VALUES (?, vector_embed(?, 512))";
            var stmt = try self.db.prepare(sql);
            defer stmt.deinit();

            try stmt.bind(1, image_id);
            try stmt.bindBlob(2, std.mem.sliceAsBytes(embedding[0..512]));

            _ = try stmt.step();
        }
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
};