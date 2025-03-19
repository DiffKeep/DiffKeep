const std = @import("std");
const sqlite = @import("sqlite");

pub const VectorDb = struct {
    db: sqlite.Database,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !VectorDb {
        var db = try sqlite.Database.open(allocator, path);
        errdefer db.close();

        // Initialize the database with vector tables
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA synchronous = NORMAL");

        // Create a vector table for image embeddings (example with 512 dimensions)
        try db.createVectorTable("image_embeddings", 512);

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
};