const std = @import("std");
const sqlite = @import("sqlite");
const models = @import("models.zig");
const log = std.log.scoped(.db);

pub const TrashStats = struct {
    count: i64 = 0,
    total_bytes: i64 = 0,
};

pub const LibraryInfo = struct {
    id: u64,
    path: []const u8, // heap-allocated
};

pub const FolderCount = struct {
    path: []const u8, // heap-allocated; caller frees
    count: i64,
};

pub const DbStats = struct {
    total_bytes: i64 = 0,
    thumbnail_count: i64 = 0,
    thumbnail_bytes: i64 = 0,
    prompt_embedding_count: i64 = 0,
    image_embedding_count: i64 = 0,
};

pub const ImageMeta = struct {
    id: u64,
    mtime: ?i64,
    has_thumbnail: bool,
    has_prompt_embedding: bool,
    has_image_embedding: bool,
    seen: bool = false,
};

/// A single raw PNG text chunk (tEXt or iTXt), as shown in the detail panel.
pub const RawChunk = struct {
    keyword: []const u8,
    display_text: []const u8, // pretty-printed JSON or raw text
    is_json: bool,
};

/// Full metadata for a single image, used by the detail panel.
pub const ImageDetails = struct {
    id: u64,
    library_id: u64,
    library_path: []const u8,
    creation_date: ?[]const u8,
    positive_prompt_text: ?[]const u8,
    negative_prompt_text: ?[]const u8,
    model: ?[]const u8,
    cfg: ?f64,
    steps: ?i64,
    seed: ?i64,
    sampler: ?[]const u8,
    scheduler: ?[]const u8,
    loras: ?[]const u8,
    trashed_at: ?[]const u8, // formatted by SQLite as "YYYY-MM-DD HH:MM:SS"
    // Populated from file-system after DB query, not stored in DB.
    width: ?u32 = null,
    height: ?u32 = null,
    file_size: ?i64 = null,
    raw_chunks: []RawChunk = &.{},
    raw_chunks_owned: bool = false,

    pub fn deinit(self: *ImageDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.library_path);
        if (self.creation_date) |s| allocator.free(s);
        if (self.positive_prompt_text) |s| allocator.free(s);
        if (self.negative_prompt_text) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
        if (self.sampler) |s| allocator.free(s);
        if (self.scheduler) |s| allocator.free(s);
        if (self.loras) |s| allocator.free(s);
        if (self.trashed_at) |s| allocator.free(s);
        for (self.raw_chunks) |c| {
            allocator.free(c.keyword);
            allocator.free(c.display_text);
        }
        if (self.raw_chunks_owned) allocator.free(self.raw_chunks);
    }
};

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

// Each entry is applied in order; never edit existing entries, only append.
const migrations = [_][]const u8{
    // v1: libraries table
    \\CREATE TABLE libraries (
    \\  id INTEGER PRIMARY KEY,
    \\  path TEXT UNIQUE NOT NULL
    \\) STRICT;
    ,
    // v2: images table with full parse metadata.
    // loras is stored as a JSON array of strings.
    \\CREATE TABLE images (
    \\  id INTEGER PRIMARY KEY,
    \\  library_id INTEGER NOT NULL,
    \\  library_path TEXT NOT NULL,
    \\  creation_date TEXT DEFAULT CURRENT_TIMESTAMP,
    \\  hash TEXT,
    \\  thumbnail BLOB,
    \\  positive_prompt_text TEXT,
    \\  negative_prompt_text TEXT,
    \\  generated_description TEXT,
    \\  model TEXT,
    \\  cfg REAL,
    \\  steps INTEGER,
    \\  seed INTEGER,
    \\  sampler TEXT,
    \\  scheduler TEXT,
    \\  loras TEXT,
    \\  FOREIGN KEY (library_id) REFERENCES libraries(id) ON DELETE CASCADE
    \\) STRICT;
    ,
    // v3: embedding tables (will be replaced at v8). vec0 virtual tables are not STRICT.
    \\CREATE VIRTUAL TABLE image_embeddings USING vec0(vector float[2048]);
    \\CREATE VIRTUAL TABLE positive_prompt_embeddings USING vec0(vector float[2048]);
    ,
    // v4: mtime for fast change detection — stat before hashing.
    \\ALTER TABLE images ADD COLUMN mtime INTEGER;
    ,
    // v5: index for fast per-library path lookups during scan
    \\CREATE INDEX IF NOT EXISTS idx_images_library_path ON images (library_id, library_path);
    ,
    // v6: soft-delete (trash) support
    \\ALTER TABLE images ADD COLUMN trashed_at INTEGER;
    \\ALTER TABLE images ADD COLUMN trash_name TEXT;
    \\ALTER TABLE images ADD COLUMN trash_file_size INTEGER;
    ,
    // v7: FTS5 full-text index on positive_prompt_text
    \\CREATE VIRTUAL TABLE prompt_fts USING fts5(positive_prompt_text, content=images, content_rowid=id);
    \\INSERT INTO prompt_fts(rowid, positive_prompt_text) SELECT id, positive_prompt_text FROM images WHERE positive_prompt_text IS NOT NULL;
    \\CREATE TRIGGER prompt_fts_ai AFTER INSERT ON images BEGIN
    \\  INSERT INTO prompt_fts(rowid, positive_prompt_text) VALUES (new.id, new.positive_prompt_text);
    \\END;
    \\CREATE TRIGGER prompt_fts_ad AFTER DELETE ON images BEGIN
    \\  INSERT INTO prompt_fts(prompt_fts, rowid, positive_prompt_text) VALUES ('delete', old.id, old.positive_prompt_text);
    \\END;
    \\CREATE TRIGGER prompt_fts_au AFTER UPDATE OF positive_prompt_text ON images BEGIN
    \\  INSERT INTO prompt_fts(prompt_fts, rowid, positive_prompt_text) VALUES ('delete', old.id, old.positive_prompt_text);
    \\  INSERT INTO prompt_fts(rowid, positive_prompt_text) VALUES (new.id, new.positive_prompt_text);
    \\END;
    ,
    // v8: resize embedding vectors from 2048 to 768 (switched from Qwen3-VL to SigLIP2/snowflake)
    \\DROP TABLE IF EXISTS image_embeddings;
    \\DROP TABLE IF EXISTS positive_prompt_embeddings;
    \\CREATE VIRTUAL TABLE image_embeddings USING vec0(vector float[768]);
    \\CREATE VIRTUAL TABLE positive_prompt_embeddings USING vec0(vector float[768]);
    ,
    // v9: index on hash so duplicate detection (GROUP BY hash) is cheap.
    \\CREATE INDEX IF NOT EXISTS idx_images_hash ON images (hash);
    ,
};

// setupSchema runs all pending migrations and bootstraps any remaining tables
// on a dedicated raw connection so that pool connections (which call
// prepareStatements on open) always find a complete schema.
fn setupSchema(allocator: std.mem.Allocator, path: []const u8) !void {
    const c = sqlite.c;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var raw: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path_z, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK)
        return error.DatabaseOpenFailed;
    defer _ = c.sqlite3_close(raw);
    const db = raw.?;

    var err_msg: [*c]u8 = null;
    if (c.sqlite3_vec_init(db, &err_msg, null) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return error.VecExtensionFailed;
    }

    _ = c.sqlite3_exec(db, "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;", null, null, null);

    // Determine current schema version
    var ver_stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &ver_stmt, null);
    _ = c.sqlite3_step(ver_stmt);
    const version: usize = @intCast(c.sqlite3_column_int64(ver_stmt, 0));
    _ = c.sqlite3_finalize(ver_stmt);

    // Apply any pending migrations
    for (migrations[version..], version..) |sql, idx| {
        _ = c.sqlite3_exec(db, "BEGIN", null, null, null);
        err_msg = null;
        if (c.sqlite3_exec(db, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) {
                log.err("migration {d} failed: {s}", .{ idx + 1, err_msg });
                c.sqlite3_free(err_msg);
            }
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
            return error.MigrationFailed;
        }
        var buf: [64]u8 = undefined;
        const pragma = try std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{idx + 1});
        _ = c.sqlite3_exec(db, pragma.ptr, null, null, null);
        _ = c.sqlite3_exec(db, "COMMIT", null, null, null);
        log.info("applied migration {d}", .{idx + 1});
    }

}

pub const FilterColumn = enum {
    model, sampler, scheduler,
    pub fn name(self: FilterColumn) []const u8 { return @tagName(self); }
};

pub const ActiveFilter = struct {
    column: FilterColumn,
    value: []const u8,
};

pub const VectorDb = struct {
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    pool: sqlite.ConnectionPool,
    io: std.Io,
    db_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !VectorDb {
        try setupSchema(allocator, path);

        var pool = try sqlite.ConnectionPool.init(allocator, io, path, 4);
        errdefer pool.deinit();

        const db = try pool.acquire();

        return VectorDb{
            .db = db,
            .pool = pool,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn getConnection(self: *VectorDb) !VectorDb {
        log.debug("Getting a new connection", .{});
        return VectorDb{
            .db = try self.pool.acquire(),
            .pool = self.pool,
            .allocator = self.allocator,
            .io = self.io,
        };
    }

    pub fn deinit(self: *VectorDb) void {
        log.debug("Releasing connection", .{});
        self.pool.release(&self.db) catch {};
    }

    pub fn storeImageEmbedding(self: *VectorDb, id: u64, embedding: []const f32) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.insertVector("image_embeddings", @as(i64, @intCast(id)), embedding);
    }

    pub fn findSimilarImages(self: *VectorDb, query_embedding: []const f32, limit: usize) !std.ArrayList(sqlite.VecResult) {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        return try self.db.searchNearestVectors("image_embeddings", query_embedding, limit);
    }

    pub fn storeLibrary(self: *VectorDb, library_path: []const u8) !u32 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
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
    pub fn storePromptEmbedding(self: *VectorDb, image_id: u64, embedding: []const f32) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.insertVector("positive_prompt_embeddings", @as(i64, @intCast(image_id)), embedding);
    }

    /// KNN search on positive_prompt_embeddings. query must be L2-normalized, 768-dim.
    pub fn searchByPromptEmbedding(self: *VectorDb, allocator: std.mem.Allocator, query: []const f32, limit: usize) ![]GridEntry {
        return self.searchByEmbedding(allocator, "positive_prompt_embeddings", query, limit);
    }

    /// KNN search on image_embeddings. query must be L2-normalized, 768-dim.
    pub fn searchByImageEmbedding(self: *VectorDb, allocator: std.mem.Allocator, query: []const f32, limit: usize) ![]GridEntry {
        return self.searchByEmbedding(allocator, "image_embeddings", query, limit);
    }

    /// Cosine-distance KNN over a vec0 embedding table joined to non-trashed images.
    /// `table` is a compile-time-trusted internal identifier (not user input).
    fn searchByEmbedding(self: *VectorDb, allocator: std.mem.Allocator, comptime table: []const u8, query: []const f32, limit: usize) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT i.id, i.library_path, i.mtime\n" ++
            "FROM images i\n" ++
            "JOIN " ++ table ++ " e ON e.rowid = i.id\n" ++
            "WHERE i.trashed_at IS NULL\n" ++
            "ORDER BY vec_distance_cosine(e.vector, ?) ASC\n" ++
            "LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindBlob(1, std.mem.sliceAsBytes(query));
        try stmt.bind(2, @as(i64, @intCast(limit)));
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    /// RRF-merged KNN search over both prompt and image embeddings.
    /// Runs both queries independently (top `limit` each), merges via Reciprocal
    /// Rank Fusion (k=60), and returns the top `limit` results sorted by combined
    /// score descending.  query must be L2-normalized, 768-dim.
    pub fn searchCombined(self: *VectorDb, allocator: std.mem.Allocator, query: []const f32, limit: usize) ![]GridEntry {
        const prompt_results = try self.searchByPromptEmbedding(allocator, query, limit);
        defer {
            for (prompt_results) |e| allocator.free(e.path);
            allocator.free(prompt_results);
        }
        const image_results = try self.searchByImageEmbedding(allocator, query, limit);
        defer {
            for (image_results) |e| allocator.free(e.path);
            allocator.free(image_results);
        }

        const RrfEntry = struct { score: f32, id: u64, path: []const u8, mtime: ?i64 };
        var map = std.AutoHashMap(u64, RrfEntry).init(allocator);
        defer map.deinit();

        const rrf_k: f32 = 60.0;

        for (prompt_results, 0..) |entry, rank| {
            const contrib: f32 = 1.0 / (rrf_k + @as(f32, @floatFromInt(rank + 1)));
            const gop = try map.getOrPut(entry.id);
            if (gop.found_existing) {
                gop.value_ptr.score += contrib;
            } else {
                gop.value_ptr.* = .{ .score = contrib, .id = entry.id, .path = entry.path, .mtime = entry.mtime };
            }
        }
        for (image_results, 0..) |entry, rank| {
            const contrib: f32 = 1.0 / (rrf_k + @as(f32, @floatFromInt(rank + 1)));
            const gop = try map.getOrPut(entry.id);
            if (gop.found_existing) {
                gop.value_ptr.score += contrib;
            } else {
                gop.value_ptr.* = .{ .score = contrib, .id = entry.id, .path = entry.path, .mtime = entry.mtime };
            }
        }

        // Collect, sort descending by score
        var merged = try allocator.alloc(RrfEntry, map.count());
        defer allocator.free(merged);
        var it = map.valueIterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) merged[i] = v.*;
        std.sort.pdq(RrfEntry, merged, {}, struct {
            fn lt(_: void, a: RrfEntry, b: RrfEntry) bool { return a.score > b.score; }
        }.lt);

        // Build result slice (dupe paths, they'll be freed by callers)
        const n = @min(merged.len, limit);
        var out = try allocator.alloc(GridEntry, n);
        var out_filled: usize = 0;
        errdefer {
            for (out[0..out_filled]) |e| allocator.free(e.path);
            allocator.free(out);
        }
        for (merged[0..n]) |e| {
            out[out_filled] = .{ .id = e.id, .path = try allocator.dupe(u8, e.path), .mtime = e.mtime };
            out_filled += 1;
        }
        return out;
    }

    /// Caller owns all Image string fields; free with image.deinit(allocator).
    pub fn findOrCreateImage(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64, image_path: []const u8) !models.Image {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        {
            var stmt = self.db.statements.find_image;
            try stmt.reset();
            try stmt.bind(1, library_id);
            try stmt.bind(2, image_path);
            if (try stmt.step()) {
                log.debug("found existing image id={d} {s}", .{ stmt.columnInt64(0), image_path });
                return models.Image{
                    .id = @intCast(stmt.columnInt64(0)),
                    .libraryId = @intCast(stmt.columnInt64(1)),
                    .libraryPath = try allocator.dupe(u8, stmt.columnText(2)),
                    .creationDate = try allocator.dupe(u8, stmt.columnText(3)),
                    .positivePromptText = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
                    .negativePromptText = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
                    .generatedDescription = if (stmt.columnIsNull(6)) null else try allocator.dupe(u8, stmt.columnText(6)),
                    .thumbnail = if (stmt.columnIsNull(7)) null else try allocator.dupe(u8, stmt.columnBlob(7)),
                    .hash = if (stmt.columnIsNull(8)) null else try allocator.dupe(u8, stmt.columnText(8)),
                    .mtime = if (stmt.columnIsNull(9)) null else stmt.columnInt64(9),
                    .model = if (stmt.columnIsNull(10)) null else try allocator.dupe(u8, stmt.columnText(10)),
                    .sampler = if (stmt.columnIsNull(11)) null else try allocator.dupe(u8, stmt.columnText(11)),
                    .scheduler = if (stmt.columnIsNull(12)) null else try allocator.dupe(u8, stmt.columnText(12)),
                    .cfg = if (stmt.columnIsNull(13)) null else stmt.columnDouble(13),
                    .steps = if (stmt.columnIsNull(14)) null else stmt.columnInt64(14),
                    .seed = if (stmt.columnIsNull(15)) null else stmt.columnInt64(15),
                    .loras = if (stmt.columnIsNull(16)) null else try allocator.dupe(u8, stmt.columnText(16)),
                };
            }
        }

        {
            var stmt = self.db.statements.insert_image;
            try stmt.reset();
            try stmt.bind(1, library_id);
            try stmt.bind(2, image_path);
            _ = try stmt.step();
            log.debug("created new image {s}", .{image_path});
        }

        return models.Image{
            .id = @intCast(self.db.getLastInsertRowID()),
            .libraryId = library_id,
            .libraryPath = try allocator.dupe(u8, image_path),
            .creationDate = try self.getCurrentTimestamp(allocator),
            .positivePromptText = null,
            .negativePromptText = null,
            .generatedDescription = null,
            .thumbnail = null,
            .hash = null,
            .mtime = null,
        };
    }

    pub fn saveImage(self: *VectorDb, image: *const models.Image) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = self.db.statements.update_image;
        try stmt.reset();

        if (image.positivePromptText) |text| try stmt.bind(1, text) else try stmt.bindNull(1);
        if (image.negativePromptText) |text| try stmt.bind(2, text) else try stmt.bindNull(2);
        if (image.generatedDescription) |text| try stmt.bind(3, text) else try stmt.bindNull(3);
        if (image.thumbnail) |thumb| try stmt.bindBlob(4, thumb) else try stmt.bindNull(4);
        if (image.hash) |hash| try stmt.bind(5, hash) else try stmt.bindNull(5);
        if (image.mtime) |mt| try stmt.bind(6, mt) else try stmt.bindNull(6);
        if (image.model) |v| try stmt.bind(7, v) else try stmt.bindNull(7);
        if (image.sampler) |v| try stmt.bind(8, v) else try stmt.bindNull(8);
        if (image.scheduler) |v| try stmt.bind(9, v) else try stmt.bindNull(9);
        if (image.cfg) |v| try stmt.bind(10, v) else try stmt.bindNull(10);
        if (image.steps) |v| try stmt.bind(11, v) else try stmt.bindNull(11);
        if (image.seed) |v| try stmt.bind(12, v) else try stmt.bindNull(12);
        if (image.loras) |v| try stmt.bind(13, v) else try stmt.bindNull(13);
        try stmt.bind(14, image.id);

        _ = try stmt.step();
    }

    pub fn getLibraryIdByPath(self: *VectorDb, path: []const u8) !?u64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = self.db.statements.find_library;
        try stmt.reset();
        try stmt.bind(1, path);
        if (try stmt.step()) return @intCast(stmt.columnInt64(0));
        return null;
    }

    pub fn removeLibrary(self: *VectorDb, path: []const u8) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("DELETE FROM libraries WHERE path = ?");
        defer stmt.deinit();
        try stmt.bind(1, path);
        _ = try stmt.step();
    }

    pub fn listLibraries(self: *VectorDb, allocator: std.mem.Allocator) ![]LibraryInfo {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT id, path FROM libraries ORDER BY id");
        defer stmt.deinit();
        var list: std.ArrayList(LibraryInfo) = .empty;
        errdefer {
            for (list.items) |li| allocator.free(li.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            try list.append(allocator, .{ .id = id, .path = path });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getLibraryImageCount(self: *VectorDb, library_id: u64) !i64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM images WHERE library_id = ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        if (try stmt.step()) return stmt.columnInt64(0);
        return 0;
    }

    pub fn getTotalImageCount(self: *VectorDb) !i64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM images WHERE trashed_at IS NULL",
        );
        defer stmt.deinit();
        if (try stmt.step()) return stmt.columnInt64(0);
        return 0;
    }

    /// Returns immediate subdirectories of parent_path (one level deep) with their subtree
    /// image counts (i.e. all images under each immediate child, not just direct children).
    /// Result paths are heap-allocated; caller frees each .path and the slice.
    pub fn listImmediateSubdirs(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64, parent_path: []const u8) ![]FolderCount {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        const pattern = try std.fmt.allocPrint(allocator, "{s}/%", .{parent_path});
        defer allocator.free(pattern);

        var stmt = try self.db.prepare(
            "SELECT library_path FROM images WHERE library_id = ? AND library_path LIKE ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        try stmt.bind(2, @as([]const u8, pattern));

        var map: std.StringHashMap(i64) = .init(allocator);
        defer {
            var kit = map.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            map.deinit();
        }

        const prefix_len = parent_path.len + 1; // skip parent + "/"
        while (try stmt.step()) {
            const path = stmt.columnText(0);
            if (path.len <= prefix_len) continue;
            const rest = path[prefix_len..];
            // Find first "/" after prefix to get immediate child directory name.
            // Images sitting directly in parent_path have no further slash — skip them.
            const slash_pos = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            if (slash_pos == 0) continue;
            const child_end = prefix_len + slash_pos;
            const child_path = path[0..child_end];
            const gop = try map.getOrPut(child_path);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                const owned = try allocator.dupe(u8, child_path);
                errdefer allocator.free(owned);
                gop.key_ptr.* = owned;
                gop.value_ptr.* = 1;
            }
        }

        var result: std.ArrayList(FolderCount) = .empty;
        errdefer {
            for (result.items) |fc| allocator.free(fc.path);
            result.deinit(allocator);
        }
        {
            var it = map.iterator();
            while (it.next()) |kv| {
                const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
                errdefer allocator.free(path_copy);
                try result.append(allocator, .{ .path = path_copy, .count = kv.value_ptr.* });
            }
        }
        std.mem.sortUnstable(FolderCount, result.items, {}, struct {
            pub fn lessThan(_: void, a: FolderCount, b: FolderCount) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return result.toOwnedSlice(allocator);
    }

    /// Returns distinct parent directories of images in the library with their image counts.
    /// Uses a HashMap with owned keys; result paths are duplicated into the returned slice.
    pub fn listLibraryFolders(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64) ![]FolderCount {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        var map: std.StringHashMap(i64) = .init(allocator);
        defer {
            var kit = map.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            map.deinit();
        }

        {
            var stmt = try self.db.prepare(
                "SELECT library_path FROM images WHERE library_id = ? AND trashed_at IS NULL",
            );
            defer stmt.deinit();
            try stmt.bind(1, library_id);
            while (try stmt.step()) {
                const path = stmt.columnText(0);
                const dir = std.fs.path.dirname(path) orelse continue;
                const gop = try map.getOrPut(dir);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    const owned = try allocator.dupe(u8, dir);
                    errdefer allocator.free(owned);
                    gop.key_ptr.* = owned;
                    gop.value_ptr.* = 1;
                }
            }
        }

        // Build result; duplicate keys so map's defer can free originals safely.
        var result: std.ArrayList(FolderCount) = .empty;
        errdefer {
            for (result.items) |fc| allocator.free(fc.path);
            result.deinit(allocator);
        }
        {
            var it = map.iterator();
            while (it.next()) |kv| {
                const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
                errdefer allocator.free(path_copy);
                try result.append(allocator, .{ .path = path_copy, .count = kv.value_ptr.* });
            }
        }
        std.mem.sortUnstable(FolderCount, result.items, {}, struct {
            pub fn lessThan(_: void, a: FolderCount, b: FolderCount) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return result.toOwnedSlice(allocator);
    }

    /// Returns all non-trashed images in a library, ordered by id.
    pub fn listLibraryImages(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime FROM images WHERE library_id = ? AND trashed_at IS NULL ORDER BY id",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Returns all non-trashed images whose path is under folder_path/, ordered by id.
    pub fn listImagesInFolder(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64, folder_path: []const u8) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        const pattern: []u8 = try std.fmt.allocPrint(allocator, "{s}/%", .{folder_path});
        defer allocator.free(pattern);
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime FROM images WHERE library_id = ? AND library_path LIKE ? AND trashed_at IS NULL ORDER BY id",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        try stmt.bind(2, @as([]const u8, pattern));
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Returns all image paths for a library, sorted — used for startup merge-join reconciliation.
    pub fn listImagePaths(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64) ![][]const u8 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT library_path FROM images WHERE library_id = ? ORDER BY library_path",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |p| allocator.free(p);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            try list.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
        }
        return list.toOwnedSlice(allocator);
    }

    /// Single-query prefetch of all image metadata for a library.
    /// Returns a map keyed by library_path (caller-owned; free each key then call deinit).
    pub fn prefetchLibraryImages(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64) !std.StringHashMap(ImageMeta) {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var map = std.StringHashMap(ImageMeta).init(allocator);
        errdefer {
            var it = map.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            map.deinit();
        }
        var stmt = try self.db.prepare(
            \\SELECT i.id, i.library_path, i.mtime,
            \\       (i.thumbnail IS NOT NULL),
            \\       (pe.rowid IS NOT NULL),
            \\       (ie.rowid IS NOT NULL)
            \\FROM images i
            \\LEFT JOIN positive_prompt_embeddings pe ON pe.rowid = i.id
            \\LEFT JOIN image_embeddings ie ON ie.rowid = i.id
            \\WHERE i.library_id = ? AND i.trashed_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            const has_thumbnail = stmt.columnInt64(3) != 0;
            const has_prompt_embedding = stmt.columnInt64(4) != 0;
            const has_image_embedding = stmt.columnInt64(5) != 0;
            try map.put(path, .{ .id = id, .mtime = mtime, .has_thumbnail = has_thumbnail, .has_prompt_embedding = has_prompt_embedding, .has_image_embedding = has_image_embedding });
        }
        return map;
    }

    /// Deletes the image matching (library_id, path) and returns its id, or null
    /// if no row matched. The id lets the caller drop the image from the grid /
    /// viewers incrementally instead of reloading the whole list.
    pub fn deleteImageByPath(self: *VectorDb, library_id: u64, path: []const u8) !?u64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        var sel = try self.db.prepare(
            "SELECT id FROM images WHERE library_id = ? AND library_path = ?",
        );
        defer sel.deinit();
        try sel.bind(1, library_id);
        try sel.bind(2, path);
        const id: ?u64 = if (try sel.step()) @intCast(sel.columnInt64(0)) else null;

        var stmt = try self.db.prepare(
            "DELETE FROM images WHERE library_id = ? AND library_path = ?",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        try stmt.bind(2, path);
        _ = try stmt.step();
        return id;
    }

    fn getCurrentTimestamp(self: *VectorDb, allocator: std.mem.Allocator) ![]const u8 {
        var stmt = try self.db.prepare("SELECT CURRENT_TIMESTAMP");
        defer stmt.deinit();

        if (try stmt.step()) {
            return try allocator.dupe(u8, stmt.columnText(0));
        }

        return error.FailedToGetTimestamp;
    }

    /// FTS5 full-text search on positive_prompt_text.
    /// Returns matching non-trashed images in BM25 rank order.
    pub fn searchPrompts(self: *VectorDb, allocator: std.mem.Allocator, query: []const u8) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            \\SELECT i.id, i.library_path, i.mtime
            \\FROM images i
            \\JOIN (SELECT rowid, rank FROM prompt_fts WHERE prompt_fts MATCH ?) fts
            \\  ON fts.rowid = i.id
            \\WHERE i.trashed_at IS NULL
            \\ORDER BY fts.rank
            \\LIMIT 1000
        );
        defer stmt.deinit();
        try stmt.bind(1, query);
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Returns distinct non-empty values for the given column, sorted, up to 500 entries.
    /// Caller owns each string and the slice.
    pub fn getDistinctColumnValues(self: *VectorDb, allocator: std.mem.Allocator, column: FilterColumn) ![][]const u8 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        const col = column.name();
        const sql = try std.fmt.allocPrint(allocator,
            "SELECT DISTINCT {s} FROM images WHERE {s} IS NOT NULL AND {s} != '' ORDER BY {s} LIMIT 500",
            .{ col, col, col, col });
        defer allocator.free(sql);
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            try list.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
        }
        return list.toOwnedSlice(allocator);
    }

    /// List non-trashed images with optional library, folder, FTS search, and metadata filters.
    /// Builds SQL dynamically; all user values go through bind params.
    pub fn listImagesFiltered(
        self: *VectorDb,
        allocator: std.mem.Allocator,
        library_id: ?u64,
        folder_path: ?[]const u8,
        search_query: ?[]const u8,
        filters: []const ActiveFilter,
    ) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);
        // When an FTS query is present, JOIN the virtual table so we can ORDER BY BM25 rank.
        // The FTS param appears first in the SQL, so it must be bound first.
        try sql.appendSlice(allocator, "SELECT images.id, images.library_path, images.mtime FROM images");
        if (search_query != null) {
            try sql.appendSlice(allocator,
                " JOIN (SELECT rowid, rank FROM prompt_fts WHERE prompt_fts MATCH ?) fts" ++
                " ON fts.rowid = images.id");
        }
        try sql.appendSlice(allocator, " WHERE images.trashed_at IS NULL");
        if (library_id != null) try sql.appendSlice(allocator, " AND images.library_id = ?");
        if (folder_path != null) try sql.appendSlice(allocator, " AND images.library_path LIKE ?");
        for (filters) |f| {
            try sql.appendSlice(allocator, " AND images.");
            try sql.appendSlice(allocator, f.column.name());
            try sql.appendSlice(allocator, " = ?");
        }
        if (search_query != null) {
            try sql.appendSlice(allocator, " ORDER BY fts.rank LIMIT 10000");
        } else {
            try sql.appendSlice(allocator, " ORDER BY images.id LIMIT 10000");
        }

        var stmt = try self.db.prepare(sql.items);
        defer stmt.deinit();

        var param: u32 = 1;
        // FTS query bound first (JOIN appears before WHERE)
        if (search_query) |q| {
            try stmt.bind(param, q);
            param += 1;
        }
        if (library_id) |lib_id| {
            try stmt.bind(param, lib_id);
            param += 1;
        }
        if (folder_path) |fp| {
            const pattern = try std.fmt.allocPrint(allocator, "{s}/%", .{fp});
            defer allocator.free(pattern);
            try stmt.bind(param, @as([]const u8, pattern));
            param += 1;
        }
        for (filters) |f| {
            try stmt.bind(param, f.value);
            param += 1;
        }

        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getStats(self: *VectorDb) !DbStats {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stats = DbStats{};

        {
            var stmt = try self.db.prepare("PRAGMA page_count");
            defer stmt.deinit();
            if (try stmt.step()) stats.total_bytes = stmt.columnInt64(0);
        }
        {
            var stmt = try self.db.prepare("PRAGMA page_size");
            defer stmt.deinit();
            if (try stmt.step()) stats.total_bytes *= stmt.columnInt64(0);
        }
        {
            var stmt = try self.db.prepare(
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(thumbnail)), 0) FROM images WHERE thumbnail IS NOT NULL",
            );
            defer stmt.deinit();
            if (try stmt.step()) {
                stats.thumbnail_count = stmt.columnInt64(0);
                stats.thumbnail_bytes = stmt.columnInt64(1);
            }
        }
        {
            var stmt = try self.db.prepare("SELECT COUNT(*) FROM positive_prompt_embeddings");
            defer stmt.deinit();
            if (try stmt.step()) stats.prompt_embedding_count = stmt.columnInt64(0);
        }
        {
            var stmt = try self.db.prepare("SELECT COUNT(*) FROM image_embeddings");
            defer stmt.deinit();
            if (try stmt.step()) stats.image_embedding_count = stmt.columnInt64(0);
        }

        return stats;
    }

    pub fn clearThumbnails(self: *VectorDb) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("UPDATE images SET thumbnail = NULL");
        defer stmt.deinit();
        _ = try stmt.step();
    }

    pub fn clearPromptEmbeddings(self: *VectorDb) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("DELETE FROM positive_prompt_embeddings");
        defer stmt.deinit();
        _ = try stmt.step();
    }

    pub fn clearImageEmbeddings(self: *VectorDb) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("DELETE FROM image_embeddings");
        defer stmt.deinit();
        _ = try stmt.step();
    }

    pub const GridEntry = struct {
        id: u64,
        path: []const u8,       // heap-allocated; caller owns
        mtime: ?i64,
        trashed_at: ?i64 = null,
        trash_name: ?[]const u8 = null, // heap-allocated; caller owns (only set for trash entries)
    };

    /// Returns all non-trashed images ordered by id. Used to populate the grid on startup.
    pub fn listAllImages(self: *VectorDb, allocator: std.mem.Allocator) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT id, library_path, mtime FROM images WHERE trashed_at IS NULL ORDER BY id");
        defer stmt.deinit();
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Move an image to the trash: record trashed_at, trash_name, and file_size.
    pub fn trashImage(self: *VectorDb, id: u64, trash_name: []const u8, file_size: i64, trashed_at: i64) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "UPDATE images SET trashed_at = ?, trash_name = ?, trash_file_size = ? WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bind(1, trashed_at);
        try stmt.bind(2, trash_name);
        try stmt.bind(3, file_size);
        try stmt.bind(4, id);
        _ = try stmt.step();
    }

    /// Restore a trashed image: clear trashed_at, trash_name, trash_file_size.
    pub fn restoreImage(self: *VectorDb, id: u64) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "UPDATE images SET trashed_at = NULL, trash_name = NULL, trash_file_size = NULL WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bind(1, id);
        _ = try stmt.step();
    }

    /// Permanently delete an image row from the DB.
    pub fn deleteImage(self: *VectorDb, id: u64) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("DELETE FROM images WHERE id = ?");
        defer stmt.deinit();
        try stmt.bind(1, id);
        _ = try stmt.step();
    }

    /// Returns all trashed images ordered by trashed_at descending.
    pub fn listTrashImages(self: *VectorDb, allocator: std.mem.Allocator) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime, trashed_at, trash_name FROM images WHERE trashed_at IS NOT NULL ORDER BY trashed_at DESC",
        );
        defer stmt.deinit();
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| {
                allocator.free(e.path);
                if (e.trash_name) |tn| allocator.free(tn);
            }
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(path);
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            const trashed_at: ?i64 = if (stmt.columnIsNull(3)) null else stmt.columnInt64(3);
            const trash_name: ?[]const u8 = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4));
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime, .trashed_at = trashed_at, .trash_name = trash_name });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Number of non-trashed images whose file hash is shared by at least one
    /// other non-trashed image (i.e. the size of the duplicate set). Zero when
    /// there are no duplicates.
    pub fn getDuplicateCount(self: *VectorDb) !i64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            \\SELECT COUNT(*) FROM images
            \\WHERE trashed_at IS NULL AND hash IS NOT NULL AND hash IN (
            \\  SELECT hash FROM images
            \\  WHERE trashed_at IS NULL AND hash IS NOT NULL
            \\  GROUP BY hash HAVING COUNT(*) > 1
            \\)
        );
        defer stmt.deinit();
        if (try stmt.step()) return stmt.columnInt64(0);
        return 0;
    }

    /// Returns every non-trashed image that shares its hash with another, ordered
    /// by hash (so duplicate groups are contiguous) then id. Used by the
    /// Duplicates view. Caller owns each path.
    pub fn listDuplicateImages(self: *VectorDb, allocator: std.mem.Allocator) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            \\SELECT id, library_path, mtime FROM images
            \\WHERE trashed_at IS NULL AND hash IS NOT NULL AND hash IN (
            \\  SELECT hash FROM images
            \\  WHERE trashed_at IS NULL AND hash IS NOT NULL
            \\  GROUP BY hash HAVING COUNT(*) > 1
            \\)
            \\ORDER BY hash, id
        );
        defer stmt.deinit();
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getTrashStats(self: *VectorDb) !TrashStats {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT COUNT(*), COALESCE(SUM(trash_file_size), 0) FROM images WHERE trashed_at IS NOT NULL",
        );
        defer stmt.deinit();
        if (try stmt.step()) {
            return .{ .count = stmt.columnInt64(0), .total_bytes = stmt.columnInt64(1) };
        }
        return .{};
    }

    /// Deletes all DB rows for trash entries older than cutoff_timestamp.
    /// Returns the list of trash_names so the caller can delete the files from disk.
    /// Caller must free each string and the slice itself.
    pub fn purgeExpiredTrash(self: *VectorDb, allocator: std.mem.Allocator, cutoff_timestamp: i64) ![][]const u8 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        {
            var stmt = try self.db.prepare(
                "SELECT trash_name FROM images WHERE trashed_at IS NOT NULL AND trashed_at <= ?",
            );
            defer stmt.deinit();
            try stmt.bind(1, cutoff_timestamp);
            while (try stmt.step()) {
                if (!stmt.columnIsNull(0)) {
                    try names.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
                }
            }
        }
        {
            var stmt = try self.db.prepare(
                "DELETE FROM images WHERE trashed_at IS NOT NULL AND trashed_at <= ?",
            );
            defer stmt.deinit();
            try stmt.bind(1, cutoff_timestamp);
            _ = try stmt.step();
        }
        return names.toOwnedSlice(allocator);
    }

    /// Fetches the thumbnail BLOB for one image. Returns null if none stored.
    /// Intended for the grid's loader worker thread on a dedicated connection —
    /// does NOT acquire db_mutex, so never call this on the shared db connection.
    pub fn getThumbnailBytes(self: *VectorDb, allocator: std.mem.Allocator, id: u64) !?[]u8 {
        var stmt = try self.db.prepare("SELECT thumbnail FROM images WHERE id = ?");
        defer stmt.deinit();
        try stmt.bind(1, id);
        if (try stmt.step()) {
            if (stmt.columnIsNull(0)) return null;
            return try allocator.dupe(u8, stmt.columnBlob(0));
        }
        return null;
    }

    /// Fetch just the positive prompt text for a single image. Returns null if not found or no prompt.
    pub fn getPositivePromptText(self: *VectorDb, allocator: std.mem.Allocator, id: u64) !?[]const u8 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT positive_prompt_text FROM images WHERE id = ?");
        defer stmt.deinit();
        try stmt.bind(1, id);
        if (!try stmt.step()) return null;
        if (stmt.columnIsNull(0)) return null;
        return try allocator.dupe(u8, stmt.columnText(0));
    }

    /// Fetch full metadata for a single image by ID. Returns null if not found.
    pub fn getImageDetails(self: *VectorDb, allocator: std.mem.Allocator, id: u64) !?ImageDetails {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            \\SELECT library_id, library_path, creation_date, positive_prompt_text, negative_prompt_text,
            \\       model, cfg, steps, seed, sampler, scheduler, loras,
            \\       DATETIME(trashed_at, 'unixepoch')
            \\FROM images WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bind(1, id);
        if (!try stmt.step()) return null;

        const library_id_val: u64 = @intCast(stmt.columnInt64(0));

        const library_path = try allocator.dupe(u8, stmt.columnText(1));
        errdefer allocator.free(library_path);

        const creation_date: ?[]const u8 = if (stmt.columnIsNull(2)) null else
            try allocator.dupe(u8, stmt.columnText(2));
        errdefer if (creation_date) |s| allocator.free(s);

        const positive_prompt_text: ?[]const u8 = if (stmt.columnIsNull(3)) null else
            try allocator.dupe(u8, stmt.columnText(3));
        errdefer if (positive_prompt_text) |s| allocator.free(s);

        const negative_prompt_text: ?[]const u8 = if (stmt.columnIsNull(4)) null else
            try allocator.dupe(u8, stmt.columnText(4));
        errdefer if (negative_prompt_text) |s| allocator.free(s);

        const model: ?[]const u8 = if (stmt.columnIsNull(5)) null else
            try allocator.dupe(u8, stmt.columnText(5));
        errdefer if (model) |s| allocator.free(s);

        const cfg: ?f64 = if (stmt.columnIsNull(6)) null else stmt.columnDouble(6);
        const steps: ?i64 = if (stmt.columnIsNull(7)) null else stmt.columnInt64(7);
        const seed: ?i64 = if (stmt.columnIsNull(8)) null else stmt.columnInt64(8);

        const sampler: ?[]const u8 = if (stmt.columnIsNull(9)) null else
            try allocator.dupe(u8, stmt.columnText(9));
        errdefer if (sampler) |s| allocator.free(s);

        const scheduler: ?[]const u8 = if (stmt.columnIsNull(10)) null else
            try allocator.dupe(u8, stmt.columnText(10));
        errdefer if (scheduler) |s| allocator.free(s);

        const loras: ?[]const u8 = if (stmt.columnIsNull(11)) null else
            try allocator.dupe(u8, stmt.columnText(11));
        errdefer if (loras) |s| allocator.free(s);

        const trashed_at: ?[]const u8 = if (stmt.columnIsNull(12)) null else
            try allocator.dupe(u8, stmt.columnText(12));
        errdefer if (trashed_at) |s| allocator.free(s);

        return ImageDetails{
            .id = id,
            .library_id = library_id_val,
            .library_path = library_path,
            .creation_date = creation_date,
            .positive_prompt_text = positive_prompt_text,
            .negative_prompt_text = negative_prompt_text,
            .model = model,
            .cfg = cfg,
            .steps = steps,
            .seed = seed,
            .sampler = sampler,
            .scheduler = scheduler,
            .loras = loras,
            .trashed_at = trashed_at,
        };
    }

    /// Reset an image's mtime to 0 so the next scan unconditionally re-parses it.
    pub fn resetImageMtimeById(self: *VectorDb, id: u64) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("UPDATE images SET mtime = 0 WHERE id = ?");
        defer stmt.deinit();
        try stmt.bind(1, id);
        _ = try stmt.step();
    }
};
