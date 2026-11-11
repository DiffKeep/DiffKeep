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
    has_children: bool = false, // true if this folder has at least one subdirectory
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
    /// The row has a positive prompt (only those can get a prompt embedding).
    has_prompt: bool = false,
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
const migrations = [_][:0]const u8{
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
    // v10: per-image favorite flag (0/1) for curation.
    \\ALTER TABLE images ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
    ,
    // v11: media type — 0 = image, 1 = animated image, 2 = video.
    \\ALTER TABLE images ADD COLUMN media_type INTEGER NOT NULL DEFAULT 0;
    ,
    // v12: drop an image's embeddings with its row. vec0 tables can't take a
    // foreign key, and image ids are recycled, so an orphaned vector would be
    // inherited by the next image given that id (and, looking embedded, never
    // be recomputed). Also purge the orphans earlier deletes left behind.
    \\CREATE TRIGGER images_embeddings_ad AFTER DELETE ON images BEGIN
    \\  DELETE FROM image_embeddings WHERE rowid = old.id;
    \\  DELETE FROM positive_prompt_embeddings WHERE rowid = old.id;
    \\END;
    \\DELETE FROM image_embeddings WHERE rowid NOT IN (SELECT id FROM images);
    \\DELETE FROM positive_prompt_embeddings WHERE rowid NOT IN (SELECT id FROM images);
    ,
    // v13: prompt_clean used to drop `<( ... ):w>` weighted groups and `<...>`
    // placeholders with all their text. Drop the prompt vectors of every prompt
    // with a '<' so the startup scan's backfill re-embeds them cleaned correctly.
    \\DELETE FROM positive_prompt_embeddings WHERE rowid IN
    \\  (SELECT id FROM images WHERE positive_prompt_text LIKE '%<%');
    ,
    // v14: one live row per (library, path). The scan and the fs watcher could
    // both miss a new file and insert it twice; "remove redundant duplicates"
    // then trashed the file itself. Merge existing copies into the lowest id
    // (keeping a favorite set on any of them), then make the index unique.
    // Trashed rows are exempt: a new file may reuse a trashed image's path.
    \\UPDATE images SET favorite = 1
    \\WHERE trashed_at IS NULL AND favorite = 0 AND EXISTS (
    \\  SELECT 1 FROM images d WHERE d.trashed_at IS NULL AND d.favorite = 1
    \\    AND d.library_id = images.library_id AND d.library_path = images.library_path);
    \\DELETE FROM images WHERE trashed_at IS NULL AND EXISTS (
    \\  SELECT 1 FROM images k WHERE k.trashed_at IS NULL AND k.id < images.id
    \\    AND k.library_id = images.library_id AND k.library_path = images.library_path);
    \\CREATE UNIQUE INDEX idx_images_live_path ON images (library_id, library_path)
    \\  WHERE trashed_at IS NULL;
    ,
    // v15: `saveImage` sets every column, so the FTS update trigger re-indexed
    // the prompt on every save (each scan of a changed file, each reparse)
    // even when the prompt was the same. Only re-index when it changed.
    \\DROP TRIGGER prompt_fts_au;
    \\CREATE TRIGGER prompt_fts_au AFTER UPDATE OF positive_prompt_text ON images
    \\WHEN old.positive_prompt_text IS NOT new.positive_prompt_text BEGIN
    \\  INSERT INTO prompt_fts(prompt_fts, rowid, positive_prompt_text) VALUES ('delete', old.id, old.positive_prompt_text);
    \\  INSERT INTO prompt_fts(rowid, positive_prompt_text) VALUES (new.id, new.positive_prompt_text);
    \\END;
    ,
};

/// Bounds of the half-open range [`folder/`, `folder0`) holding exactly the
/// paths under `folder` ('0' is the byte after '/'). Unlike `LIKE 'folder/%'`
/// it is case-sensitive, has no `_`/`%` wildcards, and can use the path index.
/// Caller frees both.
fn folderRange(allocator: std.mem.Allocator, folder: []const u8) !struct { lo: []u8, hi: []u8 } {
    const lo = try allocator.print("{s}/", .{folder});
    errdefer allocator.free(lo);
    const hi = try allocator.print("{s}0", .{folder});
    return .{ .lo = lo, .hi = hi };
}

// setupSchema runs all pending migrations and bootstraps any remaining tables
// on a dedicated raw connection so that pool connections (which call
// prepareStatements on open) always find a complete schema.
fn setupSchema(allocator: std.mem.Allocator, path: []const u8) !void {
    const c = sqlite.c;

    const path_z = try allocator.dupeSentinel(u8, path, 0);
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

    const exec = struct {
        fn run(conn: *c.sqlite3, sql: [*:0]const u8) !void {
            var msg: [*c]u8 = null;
            if (c.sqlite3_exec(conn, sql, null, null, &msg) != c.SQLITE_OK) {
                log.err("schema: {s}: {s}", .{ sql, if (msg != null) msg else c.sqlite3_errmsg(conn) });
                if (msg != null) c.sqlite3_free(msg);
                return error.MigrationFailed;
            }
        }
    }.run;

    // Wait for another instance's lock instead of failing on the first BEGIN.
    try exec(db, "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");

    // Determine current schema version
    var ver_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &ver_stmt, null) != c.SQLITE_OK)
        return error.MigrationFailed;
    const stepped = c.sqlite3_step(ver_stmt);
    const version: usize = @intCast(c.sqlite3_column_int64(ver_stmt, 0));
    _ = c.sqlite3_finalize(ver_stmt);
    if (stepped != c.SQLITE_ROW) return error.MigrationFailed;
    // An older build opening a newer DB: refuse rather than misread it.
    if (version > migrations.len) return error.SchemaTooNew;

    // Apply any pending migrations, each in its own transaction with its version bump.
    for (migrations[version..], version..) |sql, idx| {
        try exec(db, "BEGIN IMMEDIATE");
        errdefer exec(db, "ROLLBACK") catch {};
        exec(db, sql.ptr) catch {
            log.err("migration {d} failed", .{idx + 1});
            return error.MigrationFailed;
        };
        var buf: [64]u8 = undefined;
        const pragma = try std.mem.printSentinel(&buf, "PRAGMA user_version = {d}", .{idx + 1}, 0);
        try exec(db, pragma.ptr);
        try exec(db, "COMMIT");
        log.info("applied migration {d}", .{idx + 1});
    }
}

pub const FilterColumn = enum {
    model, sampler, scheduler,
    /// Virtual column: not stored, derived from the file extension of
    /// `library_path` at query time. See listImagesFiltered / getDistinctColumnValues.
    format,
    /// Backed by the `media_type` column, but with custom value→SQL mapping
    /// ("image" includes animated). See listImagesFiltered.
    resource_type,
    pub fn name(self: FilterColumn) []const u8 { return @tagName(self); }
};

pub const ActiveFilter = struct {
    column: FilterColumn,
    value: []const u8,
};

/// One SQLite connection plus a shared pool. The handle returned by `init` owns
/// the pool; `getConnection` hands out further handles (one per thread) that
/// share it by pointer. Deinit every `getConnection` handle before the owner.
/// sqlite-vec's largest accepted KNN `k` (SQLITE_VEC_VEC0_K_MAX).
const vec0_k_max: usize = 4096;

pub const VectorDb = struct {
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    pool: *sqlite.ConnectionPool,
    owns_pool: bool,
    io: std.Io,
    db_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !VectorDb {
        try setupSchema(allocator, path);

        const pool = try sqlite.ConnectionPool.create(allocator, io, path, 4);
        errdefer pool.destroy();

        return VectorDb{
            .db = try pool.acquire(),
            .pool = pool,
            .owns_pool = true,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn getConnection(self: *VectorDb) !VectorDb {
        log.debug("Getting a new connection", .{});
        return VectorDb{
            .db = try self.pool.acquire(),
            .pool = self.pool,
            .owns_pool = false,
            .allocator = self.allocator,
            .io = self.io,
        };
    }

    /// Return the connection to the pool; the owning handle also destroys the pool.
    pub fn deinit(self: *VectorDb) void {
        log.debug("Releasing connection", .{});
        self.pool.release(&self.db);
        if (self.owns_pool) self.pool.destroy();
        self.* = undefined;
    }

    /// Store (or replace) the image embedding of row `id`, but only while that
    /// row still holds `path`: an embedding finished after its image was deleted
    /// would otherwise land on whichever image SQLite gives the recycled id.
    /// Returns whether it was stored.
    pub fn storeImageEmbedding(self: *VectorDb, id: u64, path: []const u8, embedding: []const f32) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        return self.db.insertVector("image_embeddings", @as(i64, @intCast(id)), path, embedding);
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
            defer stmt.reset() catch {};

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
            defer stmt.reset() catch {};

            try stmt.bind(1, library_path);
            _ = try stmt.step();
        }

        // Return the ID of the newly inserted library
        return @intCast(self.db.getLastInsertRowID());
    }

    /// Prompt-embedding counterpart of `storeImageEmbedding` (same `path` guard).
    pub fn storePromptEmbedding(self: *VectorDb, image_id: u64, path: []const u8, embedding: []const f32) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        return self.db.insertVector("positive_prompt_embeddings", @as(i64, @intCast(image_id)), path, embedding);
    }

    /// KNN search on positive_prompt_embeddings. query must be L2-normalized, 768-dim.
    /// Results with cosine similarity below `min_similarity` are dropped (pass -1 to disable).
    pub fn searchByPromptEmbedding(self: *VectorDb, allocator: std.mem.Allocator, query: []const f32, limit: usize, min_similarity: f32) ![]GridEntry {
        return self.searchByEmbedding(allocator, "positive_prompt_embeddings", query, limit, min_similarity);
    }

    /// KNN search on image_embeddings. query must be L2-normalized, 768-dim.
    /// Results with cosine similarity below `min_similarity` are dropped (pass -1 to disable).
    pub fn searchByImageEmbedding(self: *VectorDb, allocator: std.mem.Allocator, query: []const f32, limit: usize, min_similarity: f32) ![]GridEntry {
        return self.searchByEmbedding(allocator, "image_embeddings", query, limit, min_similarity);
    }

    /// KNN over a vec0 embedding table using the optimized MATCH path, then a
    /// rowid join to non-trashed images preserving KNN order.
    /// The tables use the default L2 metric; since all stored vectors and the
    /// query are L2-normalized, L2 order equals cosine order and
    /// sim = 1 - d²/2 recovers cosine similarity for thresholding.
    /// `table` is a compile-time-trusted internal identifier (not user input).
    fn searchByEmbedding(self: *VectorDb, allocator: std.mem.Allocator, comptime table: []const u8, query: []const f32, limit: usize, min_similarity: f32) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime FROM images WHERE id = ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        var knn = try self.db.prepare(
            "SELECT rowid, distance FROM " ++ table ++ " WHERE vector MATCH ? AND k = ?",
        );
        defer knn.deinit();

        // Over-fetch to absorb rows the trash filter removes. If trashed rows
        // still leave the result short and KNN hasn't run out of neighbours
        // above the similarity floor, re-query with a larger k and continue
        // past the rows already checked (KNN order is stable).
        var k: usize = @min(limit * 2, vec0_k_max);
        var checked: usize = 0;
        while (true) {
            try knn.reset();
            try knn.bindBlob(1, std.mem.sliceAsBytes(query));
            try knn.bind(2, @as(i64, @intCast(k)));
            var rows: usize = 0;
            var exhausted = false;
            while (try knn.step()) : (rows += 1) {
                const d: f32 = @floatCast(knn.columnDouble(1));
                const sim = 1.0 - (d * d) / 2.0;
                // KNN returns nearest-first; the first miss ends the useful prefix.
                if (sim < min_similarity) {
                    exhausted = true;
                    break;
                }
                if (rows < checked) continue;
                if (list.items.len >= limit) break;
                try stmt.reset();
                try stmt.bind(1, knn.columnInt64(0));
                if (!try stmt.step()) continue; // trashed or deleted
                const id: u64 = @intCast(stmt.columnInt64(0));
                const path = try allocator.dupe(u8, stmt.columnText(1));
                errdefer allocator.free(path);
                const mtime: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnInt64(2);
                try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime });
            }
            if (rows < k) exhausted = true; // fewer neighbours than asked for
            checked = rows;
            if (list.items.len >= limit or exhausted or k >= vec0_k_max) break;
            k = @min(k * 4, vec0_k_max);
        }
        return list.toOwnedSlice(allocator);
    }

    /// RRF-merged KNN search over both prompt and image embeddings.
    /// The two tables live in different embedding spaces, so each leg takes its
    /// own query vector: `prompt_query` from the text-retrieval encoder
    /// (EmbeddingGemma) and `visual_query` from the cross-modal text encoder
    /// (SigLIP2).  Runs both KNNs independently (top `limit` each), merges via
    /// Reciprocal Rank Fusion (k=60), and returns the top `limit` results
    /// sorted by combined score descending.  Both vectors must be
    /// L2-normalized, 768-dim.
    pub fn searchCombined(
        self: *VectorDb,
        allocator: std.mem.Allocator,
        prompt_query: []const f32,
        visual_query: []const f32,
        limit: usize,
        prompt_min_similarity: f32,
        visual_min_similarity: f32,
    ) ![]GridEntry {
        const prompt_results = try self.searchByPromptEmbedding(allocator, prompt_query, limit, prompt_min_similarity);
        defer {
            for (prompt_results) |e| allocator.free(e.path);
            allocator.free(prompt_results);
        }
        const image_results = try self.searchByImageEmbedding(allocator, visual_query, limit, visual_min_similarity);
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

    /// The live (non-trashed) row at `image_path`, creating it if there is none.
    /// Caller owns all Image string fields; free with image.deinit(allocator).
    pub fn findOrCreateImage(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64, image_path: []const u8) !models.Image {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        if (try self.findLiveImage(allocator, library_id, image_path)) |img| return img;

        {
            var stmt = self.db.statements.insert_image;
            try stmt.reset();
            defer stmt.reset() catch {};
            try stmt.bind(1, library_id);
            try stmt.bind(2, image_path);
            _ = try stmt.step();
        }
        // Another connection (the fs watcher racing a scan) inserted the path
        // between our find and insert: the unique index made ours a no-op.
        if (sqlite.c.sqlite3_changes(self.db.db) == 0) {
            if (try self.findLiveImage(allocator, library_id, image_path)) |img| return img;
            return error.ImageRowVanished;
        }
        log.debug("created new image {s}", .{image_path});

        const id: u64 = @intCast(self.db.getLastInsertRowID());
        const path_copy = try allocator.dupe(u8, image_path);
        errdefer allocator.free(path_copy);
        return models.Image{
            .id = id,
            .libraryId = library_id,
            .libraryPath = path_copy,
            .creationDate = try self.getCurrentTimestamp(allocator),
            .positivePromptText = null,
            .negativePromptText = null,
            .generatedDescription = null,
            .thumbnail = null,
            .hash = null,
            .mtime = null,
        };
    }

    /// find_image lookup; caller holds db_mutex.
    fn findLiveImage(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64, image_path: []const u8) !?models.Image {
        var stmt = self.db.statements.find_image;
        try stmt.reset();
        // A cached statement left mid-result keeps the connection's read
        // transaction (and its stale WAL snapshot) open; always reset it.
        defer stmt.reset() catch {};
        try stmt.bind(1, library_id);
        try stmt.bind(2, image_path);
        if (!try stmt.step()) return null;

        const dupeOpt = struct {
            fn f(a: std.mem.Allocator, st: *sqlite.PreparedStatement, col: usize) !?[]u8 {
                return if (st.columnIsNull(col)) null else try a.dupe(u8, st.columnText(col));
            }
        }.f;

        var img = models.Image{
            .id = @intCast(stmt.columnInt64(0)),
            .libraryId = @intCast(stmt.columnInt64(1)),
            .libraryPath = try allocator.dupe(u8, stmt.columnText(2)),
            .creationDate = &.{},
            .positivePromptText = null,
            .negativePromptText = null,
            .generatedDescription = null,
            .thumbnail = null,
            .hash = null,
            .mtime = if (stmt.columnIsNull(9)) null else stmt.columnInt64(9),
            .cfg = if (stmt.columnIsNull(13)) null else stmt.columnDouble(13),
            .steps = if (stmt.columnIsNull(14)) null else stmt.columnInt64(14),
            .seed = if (stmt.columnIsNull(15)) null else stmt.columnInt64(15),
        };
        errdefer img.deinit(allocator);
        img.creationDate = try allocator.dupe(u8, stmt.columnText(3));
        img.positivePromptText = try dupeOpt(allocator, &stmt, 4);
        img.negativePromptText = try dupeOpt(allocator, &stmt, 5);
        img.generatedDescription = try dupeOpt(allocator, &stmt, 6);
        img.thumbnail = if (stmt.columnIsNull(7)) null else try allocator.dupe(u8, stmt.columnBlob(7));
        img.hash = try dupeOpt(allocator, &stmt, 8);
        img.model = try dupeOpt(allocator, &stmt, 10);
        img.sampler = try dupeOpt(allocator, &stmt, 11);
        img.scheduler = try dupeOpt(allocator, &stmt, 12);
        img.loras = try dupeOpt(allocator, &stmt, 16);
        log.debug("found existing image id={d} {s}", .{ img.id, image_path });
        return img;
    }

    pub fn saveImage(self: *VectorDb, image: *const models.Image) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = self.db.statements.update_image;
        try stmt.reset();
        defer stmt.reset() catch {};

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
        defer stmt.reset() catch {};
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

    pub const RemovedLibrary = struct {
        /// Every image row the library had (live and trashed).
        ids: []u64,
        /// Trash file names of its trashed images, to delete from disk.
        trash_names: [][]const u8,

        pub fn deinit(r: RemovedLibrary, a: std.mem.Allocator) void {
            a.free(r.ids);
            for (r.trash_names) |n| a.free(n);
            a.free(r.trash_names);
        }
    };

    /// Delete library `library_id` and (by cascade) all its images, in one
    /// transaction, returning what the caller must clean up outside the DB.
    pub fn removeLibraryById(self: *VectorDb, allocator: std.mem.Allocator, library_id: u64) !RemovedLibrary {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};

        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        {
            var stmt = try self.db.prepare("SELECT id, trash_name FROM images WHERE library_id = ?");
            defer stmt.deinit();
            try stmt.bind(1, library_id);
            while (try stmt.step()) {
                try ids.append(allocator, @intCast(stmt.columnInt64(0)));
                if (!stmt.columnIsNull(1)) {
                    const n = try allocator.dupe(u8, stmt.columnText(1));
                    errdefer allocator.free(n);
                    try names.append(allocator, n);
                }
            }
        }
        {
            var stmt = try self.db.prepare("DELETE FROM libraries WHERE id = ?");
            defer stmt.deinit();
            try stmt.bind(1, library_id);
            _ = try stmt.step();
        }
        try self.db.exec("COMMIT");
        const id_slice = try ids.toOwnedSlice(allocator);
        errdefer allocator.free(id_slice);
        return .{ .ids = id_slice, .trash_names = try names.toOwnedSlice(allocator) };
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

        const range = try folderRange(allocator, parent_path);
        defer allocator.free(range.lo);
        defer allocator.free(range.hi);

        var stmt = try self.db.prepare(
            "SELECT library_path FROM images WHERE library_id = ? AND library_path >= ? AND library_path < ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        try stmt.bind(2, @as([]const u8, range.lo));
        try stmt.bind(3, @as([]const u8, range.hi));

        const Agg = struct { count: i64, has_children: bool };
        var map: std.StringHashMap(Agg) = .init(allocator);
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
            const slash_pos = std.mem.findScalar(u8, rest, '/') orelse continue;
            if (slash_pos == 0) continue;
            const child_end = prefix_len + slash_pos;
            const child_path = path[0..child_end];
            // A further "/" past "child/" means this image lives in a deeper
            // subdirectory, so the child folder itself has children.
            const deeper = std.mem.findScalar(u8, path[child_end + 1 ..], '/') != null;
            const gop = try map.getOrPut(child_path);
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                if (deeper) gop.value_ptr.has_children = true;
            } else {
                const owned = try allocator.dupe(u8, child_path);
                errdefer allocator.free(owned);
                gop.key_ptr.* = owned;
                gop.value_ptr.* = .{ .count = 1, .has_children = deeper };
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
                try result.append(allocator, .{
                    .path = path_copy,
                    .count = kv.value_ptr.count,
                    .has_children = kv.value_ptr.has_children,
                });
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
                const dir = std.Io.Dir.path.dirname(path) orelse continue;
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
        const range = try folderRange(allocator, folder_path);
        defer allocator.free(range.lo);
        defer allocator.free(range.hi);
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime FROM images WHERE library_id = ? AND library_path >= ? AND library_path < ? AND trashed_at IS NULL ORDER BY id",
        );
        defer stmt.deinit();
        try stmt.bind(1, library_id);
        try stmt.bind(2, @as([]const u8, range.lo));
        try stmt.bind(3, @as([]const u8, range.hi));
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
        // Embedding presence is checked against vec0's plain `<table>_rowids`
        // shadow tables: a rowid lookup through the vec0 virtual table costs
        // ~0.4 ms, so joining it took ~17 s for a 44k-image library (39 ms this
        // way). The prefetch test in tests/integration.zig catches a sqlite-vec
        // upgrade that renames them.
        var stmt = try self.db.prepare(
            \\SELECT i.id, i.library_path, i.mtime,
            \\       (i.thumbnail IS NOT NULL), (i.positive_prompt_text IS NOT NULL),
            \\       EXISTS (SELECT 1 FROM positive_prompt_embeddings_rowids r WHERE r.rowid = i.id),
            \\       EXISTS (SELECT 1 FROM image_embeddings_rowids r WHERE r.rowid = i.id)
            \\FROM images i
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
            const has_prompt = stmt.columnInt64(4) != 0;
            const has_prompt_embedding = stmt.columnInt64(5) != 0;
            const has_image_embedding = stmt.columnInt64(6) != 0;
            const gop = try map.getOrPut(path);
            if (gop.found_existing) {
                allocator.free(path);
                continue;
            }
            gop.value_ptr.* = .{ .id = id, .mtime = mtime, .has_thumbnail = has_thumbnail, .has_prompt = has_prompt, .has_prompt_embedding = has_prompt_embedding, .has_image_embedding = has_image_embedding };
        }
        return map;
    }

    /// Deletes the image matching (library_id, path) and returns its id, or null
    /// if no row matched. The id lets the caller drop the image from the grid /
    /// viewers incrementally instead of reloading the whole list.
    /// Remove the DB row for a file that disappeared from its library directory.
    /// Only affects non-trashed rows: trashing an image moves its file out of the
    /// library (which the fs watcher reports as a deletion), but that row must be
    /// preserved — its `trashed_at` is already set and it lives on in the trash.
    pub fn deleteImageByPath(self: *VectorDb, library_id: u64, path: []const u8) !?u64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);

        var sel = try self.db.prepare(
            "SELECT id FROM images WHERE library_id = ? AND library_path = ? AND trashed_at IS NULL",
        );
        defer sel.deinit();
        try sel.bind(1, library_id);
        try sel.bind(2, path);
        const id: ?u64 = if (try sel.step()) @intCast(sel.columnInt64(0)) else null;

        var stmt = try self.db.prepare(
            "DELETE FROM images WHERE library_id = ? AND library_path = ? AND trashed_at IS NULL",
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

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }

        if (column == .format) {
            // "format" is virtual — derive the distinct file extensions present.
            var stmt = try self.db.prepare(
                \\SELECT DISTINCT ext FROM (
                \\  SELECT CASE
                \\    WHEN LOWER(library_path) LIKE '%.png'  THEN 'png'
                \\    WHEN LOWER(library_path) LIKE '%.jpeg' THEN 'jpeg'
                \\    WHEN LOWER(library_path) LIKE '%.jpg'  THEN 'jpg'
                \\    WHEN LOWER(library_path) LIKE '%.webp' THEN 'webp'
                \\    WHEN LOWER(library_path) LIKE '%.gif'  THEN 'gif'
                \\    WHEN LOWER(library_path) LIKE '%.mp4'  THEN 'mp4'
                \\    WHEN LOWER(library_path) LIKE '%.webm' THEN 'webm'
                \\    ELSE NULL END AS ext
                \\  FROM images WHERE trashed_at IS NULL
                \\) WHERE ext IS NOT NULL ORDER BY ext
            );
            defer stmt.deinit();
            while (try stmt.step()) {
                try list.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
            }
        } else if (column == .resource_type) {
            // Offer image / animated / video, but only those actually present.
            var stmt = try self.db.prepare(
                "SELECT SUM(media_type != 2) > 0, SUM(media_type = 1) > 0, SUM(media_type = 2) > 0" ++
                    " FROM images WHERE trashed_at IS NULL",
            );
            defer stmt.deinit();
            if (try stmt.step()) {
                if (stmt.columnInt64(0) != 0) try list.append(allocator, try allocator.dupe(u8, "image"));
                if (stmt.columnInt64(1) != 0) try list.append(allocator, try allocator.dupe(u8, "animated"));
                if (stmt.columnInt64(2) != 0) try list.append(allocator, try allocator.dupe(u8, "video"));
            }
        } else {
            const col = column.name();
            const sql = try allocator.print("SELECT DISTINCT {s} FROM images WHERE {s} IS NOT NULL AND {s} != '' ORDER BY {s} LIMIT 500",
                .{ col, col, col, col });
            defer allocator.free(sql);
            var stmt = try self.db.prepare(sql);
            defer stmt.deinit();
            while (try stmt.step()) {
                try list.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
            }
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
        if (folder_path != null) try sql.appendSlice(allocator, " AND images.library_path >= ? AND images.library_path < ?");
        for (filters) |f| {
            if (f.column == .format) {
                // Virtual column: match the file extension of library_path.
                try sql.appendSlice(allocator, " AND LOWER(images.library_path) LIKE ?");
            } else if (f.column == .resource_type) {
                // "image" means non-video (includes animated); others are exact.
                if (std.mem.eql(u8, f.value, "image"))
                    try sql.appendSlice(allocator, " AND images.media_type != ?")
                else
                    try sql.appendSlice(allocator, " AND images.media_type = ?");
            } else {
                try sql.appendSlice(allocator, " AND images.");
                try sql.appendSlice(allocator, f.column.name());
                try sql.appendSlice(allocator, " = ?");
            }
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
            const range = try folderRange(allocator, fp);
            defer allocator.free(range.lo);
            defer allocator.free(range.hi);
            try stmt.bind(param, @as([]const u8, range.lo));
            try stmt.bind(param + 1, @as([]const u8, range.hi));
            param += 2;
        }
        for (filters) |f| {
            if (f.column == .format) {
                // Build a lowercase "%.<ext>" LIKE pattern (matches LOWER(library_path)).
                const pattern = try allocator.print("%.{s}", .{f.value});
                defer allocator.free(pattern);
                for (pattern) |*ch| ch.* = std.ascii.toLower(ch.*);
                try stmt.bind(param, @as([]const u8, pattern));
            } else if (f.column == .resource_type) {
                // image → != 2 (non-video); animated → 1; video → 2; unknown → no match.
                const mt: i64 = if (std.mem.eql(u8, f.value, "image")) 2
                    else if (std.mem.eql(u8, f.value, "animated")) 1
                    else if (std.mem.eql(u8, f.value, "video")) 2
                    else -1;
                try stmt.bind(param, mt);
            } else {
                try stmt.bind(param, f.value);
            }
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
        favorite: bool = false, // populated by listFavorites; otherwise marked by the grid on load
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

    // The destructive row operations below match `id` AND the path (or trash
    // name) the caller saw: a grid or viewer entry can outlive its row, and
    // SQLite recycles ids, so an id alone may now name a different image.
    // Each returns whether a row matched.

    /// Mark the live row `id` at `path` as trashed.
    pub fn trashImage(self: *VectorDb, id: u64, path: []const u8, trash_name: []const u8, file_size: i64, trashed_at: i64) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "UPDATE images SET trashed_at = ?, trash_name = ?, trash_file_size = ? " ++
                "WHERE id = ? AND library_path = ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, trashed_at);
        try stmt.bind(2, trash_name);
        try stmt.bind(3, file_size);
        try stmt.bind(4, id);
        try stmt.bind(5, path);
        _ = try stmt.step();
        return sqlite.c.sqlite3_changes(self.db.db) > 0;
    }

    /// Bring the trashed row `id` (still named `trash_name`) back as a live
    /// image at `path`, which may differ from its old path when that is taken.
    pub fn restoreImage(self: *VectorDb, id: u64, trash_name: []const u8, path: []const u8) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "UPDATE images SET trashed_at = NULL, trash_name = NULL, trash_file_size = NULL, library_path = ? " ++
                "WHERE id = ? AND trash_name = ? AND trashed_at IS NOT NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, path);
        try stmt.bind(2, id);
        try stmt.bind(3, trash_name);
        _ = try stmt.step();
        return sqlite.c.sqlite3_changes(self.db.db) > 0;
    }

    /// Whether a live row (in any library) already holds `path`.
    pub fn livePathExists(self: *VectorDb, path: []const u8) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT 1 FROM images WHERE library_path = ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, path);
        return try stmt.step();
    }

    /// Media classification stored per image (column `media_type`).
    pub const MediaType = enum(i64) { image = 0, animated = 1, video = 2 };

    /// Set an image's media type (image / animated image / video).
    pub fn setMediaType(self: *VectorDb, id: u64, media_type: MediaType) !void {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("UPDATE images SET media_type = ? WHERE id = ?");
        defer stmt.deinit();
        try stmt.bind(1, @backingInt(media_type));
        try stmt.bind(2, id);
        _ = try stmt.step();
    }

    /// Set (or clear) an image's favorite flag.
    /// Set the favorite flag of image `id`, only if it is still at `path`
    /// (ids are recycled). Returns whether a row matched.
    pub fn setFavorite(self: *VectorDb, id: u64, path: []const u8, favorite: bool) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("UPDATE images SET favorite = ? WHERE id = ? AND library_path = ?");
        defer stmt.deinit();
        try stmt.bind(1, @as(i64, if (favorite) 1 else 0));
        try stmt.bind(2, id);
        try stmt.bind(3, path);
        _ = try stmt.step();
        return sqlite.c.sqlite3_changes(self.db.db) > 0;
    }

    /// Number of favorited, non-trashed images (for the sidebar badge).
    pub fn getFavoriteCount(self: *VectorDb) !i64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM images WHERE favorite = 1 AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        if (try stmt.step()) return stmt.columnInt64(0);
        return 0;
    }

    /// All favorited, non-trashed images, ordered by id. Used by the Favorites view.
    pub fn listFavorites(self: *VectorDb, allocator: std.mem.Allocator) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "SELECT id, library_path, mtime FROM images WHERE favorite = 1 AND trashed_at IS NULL ORDER BY id",
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
            try list.append(allocator, .{ .id = id, .path = path, .mtime = mtime, .favorite = true });
        }
        return list.toOwnedSlice(allocator);
    }

    /// The set of favorited image ids. Used to mark entries when (re)loading a
    /// view without adding a column to every grid query. Caller owns the slice.
    pub fn listFavoriteIds(self: *VectorDb, allocator: std.mem.Allocator) ![]u64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT id FROM images WHERE favorite = 1");
        defer stmt.deinit();
        var list: std.ArrayList(u64) = .empty;
        errdefer list.deinit(allocator);
        while (try stmt.step()) try list.append(allocator, @intCast(stmt.columnInt64(0)));
        return list.toOwnedSlice(allocator);
    }

    pub const MediaTypeRow = struct { id: u64, media_type: MediaType };

    /// All images whose media_type is not the default (0 = plain image): i.e.
    /// animated images and videos. Used to mark grid entries after (re)loading a
    /// view, the same way listFavoriteIds avoids a column on every grid query.
    /// This set is small (animated + video) relative to the full library.
    pub fn listNonImageMediaTypes(self: *VectorDb, allocator: std.mem.Allocator) ![]MediaTypeRow {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT id, media_type FROM images WHERE media_type != 0");
        defer stmt.deinit();
        var list: std.ArrayList(MediaTypeRow) = .empty;
        errdefer list.deinit(allocator);
        while (try stmt.step()) {
            try list.append(allocator, .{
                .id = @intCast(stmt.columnInt64(0)),
                .media_type = @fromBackingInt(stmt.columnInt64(1)),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Delete the live (non-trashed) row `id` whose file at `path` is gone, and
    /// report whether a row was deleted. Matching the path guards against an id
    /// SQLite has since recycled; skipping trashed rows keeps images whose file
    /// was moved to the trash.
    pub fn deleteMissingImage(self: *VectorDb, id: u64, path: []const u8) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare(
            "DELETE FROM images WHERE id = ? AND library_path = ? AND trashed_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bind(1, id);
        try stmt.bind(2, path);
        _ = try stmt.step();
        return sqlite.c.sqlite3_changes(self.db.db) > 0;
    }

    /// Permanently delete row `id` (live or trashed) if it still has `path`.
    pub fn deleteImage(self: *VectorDb, id: u64, path: []const u8) !bool {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("DELETE FROM images WHERE id = ? AND library_path = ?");
        defer stmt.deinit();
        try stmt.bind(1, id);
        try stmt.bind(2, path);
        _ = try stmt.step();
        return sqlite.c.sqlite3_changes(self.db.db) > 0;
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

    // The "redundant" duplicates are the copies to remove to leave one of each
    // hash. The safety guarantee: a row is only selected when a lower-id live
    // row with the same hash lives at a DIFFERENT path, i.e. a separate file is
    // kept. Two rows for one file (overlapping libraries from before those were
    // refused) are not duplicates — trashing one would trash the only copy.
    const redundant_dupes_predicate =
        \\trashed_at IS NULL AND hash IS NOT NULL
        \\AND EXISTS (
        \\  SELECT 1 FROM images k
        \\  WHERE k.hash = images.hash AND k.trashed_at IS NULL
        \\    AND k.id < images.id AND k.library_path != images.library_path
        \\)
    ;

    /// Count of redundant duplicate copies (total to remove for "keep one of each").
    pub fn getRedundantDuplicateCount(self: *VectorDb) !i64 {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM images WHERE " ++ redundant_dupes_predicate);
        defer stmt.deinit();
        if (try stmt.step()) return stmt.columnInt64(0);
        return 0;
    }

    /// Every redundant duplicate copy (id + path), keeping the lowest id of each
    /// hash group. Used by "remove all but one". Caller owns each path.
    pub fn listRedundantDuplicates(self: *VectorDb, allocator: std.mem.Allocator) ![]GridEntry {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        var stmt = try self.db.prepare("SELECT id, library_path FROM images WHERE " ++ redundant_dupes_predicate ++ " ORDER BY id");
        defer stmt.deinit();
        var list: std.ArrayList(GridEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
        }
        while (try stmt.step()) {
            const id: u64 = @intCast(stmt.columnInt64(0));
            const path = try allocator.dupe(u8, stmt.columnText(1));
            try list.append(allocator, .{ .id = id, .path = path, .mtime = null });
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
