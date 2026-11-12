const std = @import("std");
const log = std.log.scoped(.sqlite);

pub const c = @import("sqlite_c");

pub const Error = error{
    SQLiteError,
    OutOfMemory,
    InvalidArgument,
    DatabaseBusy,
    DatabaseLocked,
    TableNotFound,
    NotFound,
};

pub const VecResult = struct { id: i64, distance: f32 };

/// Heap-allocated so every `VectorDb` handle can share one pool by pointer:
/// a copied pool would have its own mutex and its own view of `connections`.
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    connections: std.ArrayList(Database),
    /// Connections handed out by `acquire` and not yet `release`d.
    outstanding: usize = 0,
    mutex: std.Io.Mutex,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, init_pool_size: usize) !*ConnectionPool {
        const pool = try allocator.create(ConnectionPool);
        errdefer allocator.destroy(pool);
        pool.* = .{
            .allocator = allocator,
            .io = io,
            .db_path = try allocator.dupe(u8, db_path),
            .connections = .empty,
            .mutex = std.Io.Mutex.init,
        };
        errdefer pool.closeAll();

        // Create the initial connections
        try pool.connections.ensureTotalCapacity(allocator, init_pool_size);
        for (0..init_pool_size) |_| {
            const db = try Database.open(allocator, db_path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX);
            pool.connections.appendAssumeCapacity(db);
        }

        return pool;
    }

    /// Close every pooled connection and free the pool. All acquired
    /// connections must have been released first.
    pub fn destroy(self: *ConnectionPool) void {
        std.debug.assert(self.outstanding == 0);
        self.closeAll();
        self.allocator.destroy(self);
    }

    fn closeAll(self: *ConnectionPool) void {
        for (self.connections.items) |*conn| {
            conn.close();
        }
        self.connections.deinit(self.allocator);
        self.allocator.free(self.db_path);
    }

    pub fn acquire(self: *ConnectionPool) !Database {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        log.debug("Current pool size: {d}", .{self.connections.items.len});

        const db = self.connections.pop() orelse
            try Database.open(self.allocator, self.db_path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX);
        self.outstanding += 1;
        return db;
    }

    pub fn release(self: *ConnectionPool, db: *Database) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        std.debug.assert(self.outstanding > 0);
        self.outstanding -= 1;
        // A connection that can't go back into the pool is closed, not leaked.
        self.connections.append(self.allocator, db.*) catch db.close();
    }
};



pub const PreparedStatement = struct {
    stmt: *c.sqlite3_stmt,

    pub fn deinit(self: *PreparedStatement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn reset(self: *PreparedStatement) !void {
        const result = c.sqlite3_reset(self.stmt);
        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }

        // Also clear any existing bindings
        const clear_result = c.sqlite3_clear_bindings(self.stmt);
        if (clear_result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
    }

    pub fn bind(self: *PreparedStatement, index: usize, value: anytype) !void {
        const T = @TypeOf(value);
        const result = switch (T) {
            i32 => c.sqlite3_bind_int(self.stmt, @intCast(index), value),
            i64, u64 => c.sqlite3_bind_int64(self.stmt, @intCast(index), @intCast(value)),
            f64 => c.sqlite3_bind_double(self.stmt, @intCast(index), value),
            []const u8 => bindTextCopy(self.stmt, @intCast(index), value),
            // Add more types as needed
            else => @compileError("Unsupported type for binding: " ++ @typeName(T)),
        };

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
    }

    /// `sqlite3_bind_text` with a copy sqlite owns and frees: what
    /// SQLITE_TRANSIENT asks for. SQLITE_TRANSIENT itself is the address -1 as
    /// a function pointer, which Zig rejects where functions are aligned
    /// (aarch64: Apple Silicon, ARM Linux).
    fn bindTextCopy(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) c_int {
        // sqlite3_malloc64(0) is NULL, which would bind NULL, not "".
        if (value.len == 0) return c.sqlite3_bind_text(stmt, index, "", 0, c.SQLITE_STATIC);
        const copy: [*]u8 = @ptrCast(c.sqlite3_malloc64(value.len) orelse return c.SQLITE_NOMEM);
        @memcpy(copy[0..value.len], value);
        // sqlite calls the destructor even when the bind fails.
        return c.sqlite3_bind_text64(stmt, index, copy, value.len, &c.sqlite3_free, c.SQLITE_UTF8);
    }

    pub fn bindBlob(self: *PreparedStatement, index: usize, data: []const u8) !void {
        const result = c.sqlite3_bind_blob(self.stmt, @intCast(index), data.ptr, @intCast(data.len), c.SQLITE_STATIC);

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
    }

    pub fn bindNull(self: *PreparedStatement, index: usize) !void {
        const result = c.sqlite3_bind_null(self.stmt, @intCast(index));

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
    }


    pub fn step(self: *PreparedStatement) !bool {
        const result = c.sqlite3_step(self.stmt);
        switch (result) {
            c.SQLITE_ROW => return true,
            c.SQLITE_DONE => return false,
            else => {
                // Ask the statement for its connection: a back-pointer to the
                // `Database` would dangle once the struct is copied or moved.
                const err_msg = c.sqlite3_errmsg(c.sqlite3_db_handle(self.stmt));
                log.err("SQLite step error: {s} (code: {d})", .{ err_msg, result });
                return Error.SQLiteError;
            },

        }
    }

    // Add methods for column access
    pub fn columnInt(self: *PreparedStatement, col: usize) i32 {
        return c.sqlite3_column_int(self.stmt, @intCast(col));
    }

    pub fn columnInt64(self: *PreparedStatement, col: usize) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(col));
    }

    pub fn columnFloat(self: *PreparedStatement, col: usize) f32 {
        return @floatCast(c.sqlite3_column_double(self.stmt, @intCast(col)));
    }

    pub fn columnDouble(self: *PreparedStatement, col: usize) f64 {
        return c.sqlite3_column_double(self.stmt, @intCast(col));
    }

    /// Empty for NULL or a zero-length value (SQLite returns a null pointer for both).
    pub fn columnText(self: *PreparedStatement, col: usize) []const u8 {
        const text = c.sqlite3_column_text(self.stmt, @intCast(col));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(col));
        if (text == null or len == 0) return &.{};
        return text[0..@intCast(len)];
    }

    /// Empty for NULL or a zero-length blob (SQLite returns a null pointer for both).
    pub fn columnBlob(self: *PreparedStatement, col: usize) []const u8 {
        const blob = c.sqlite3_column_blob(self.stmt, @intCast(col));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(col));
        if (blob == null or len == 0) return &.{};
        return @as([*]const u8, @ptrCast(blob))[0..@intCast(len)];
    }

    pub fn columnIsNull(self: *PreparedStatement, col: usize) bool {
        return c.sqlite3_column_type(self.stmt, @intCast(col)) == c.SQLITE_NULL;
    }
};

const Statements = struct {
    find_library: PreparedStatement,
    insert_library: PreparedStatement,
    find_image: PreparedStatement,
    insert_image: PreparedStatement,
    update_image: PreparedStatement,

    fn finalize(self: *Statements) void {
        inline for (@typeInfo(Statements).@"struct".field_names) |name| {
            @field(self, name).deinit();
        }
    }
};

pub const Database = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    statements: Statements,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, flags: usize) !Database {
        log.debug("Creating a new database connection", .{});
        // sqlite3_open_v2 reads a C string: `path` is a plain slice, so terminate it.
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(path_z.ptr, &db, @intCast(flags), null);

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }

        // Initialize the vector extension
        var err_msg: [*c]u8 = null;
        const init_result = c.sqlite3_vec_init(db, &err_msg, null);
        if (init_result != c.SQLITE_OK) {
            if (err_msg != null) {
                log.debug("SQLite vector extension init error: {s}\n", .{err_msg});
                c.sqlite3_free(err_msg);
            }
            _ = c.sqlite3_close(db);
            return Error.SQLiteError;
        }

        var self = Database{
            .db = db.?,
            .allocator = allocator,
            .statements = undefined,
        };
        errdefer _ = c.sqlite3_close(self.db);

        // initialize with the needed stuff
        try self.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA cache_size = -2000;
            \\PRAGMA page_size = 4096;
            \\PRAGMA mmap_size = 8388608;
            \\PRAGMA temp_store = MEMORY;
            \\PRAGMA busy_timeout = 5000;
            \\PRAGMA foreign_keys = ON
        );

        self.statements = try self.prepareStatements();

        return self;
    }

    /// Finalize the cached statements, then close. `sqlite3_close` refuses (and
    /// leaks the connection) while any statement is unfinalized.
    pub fn close(self: *Database) void {
        self.statements.finalize();
        if (c.sqlite3_close(self.db) != c.SQLITE_OK)
            log.err("sqlite3_close: {s}", .{c.sqlite3_errmsg(self.db)});
    }

    fn prepareStatements(db: *Database) !Statements {
        var out: Statements = undefined;
        var n: usize = 0;
        errdefer inline for (@typeInfo(Statements).@"struct".field_names, 0..) |name, i| {
            if (i < n) @field(out, name).deinit();
        };
        inline for (@typeInfo(Statements).@"struct".field_names) |name| {
            @field(out, name) = try db.prepare(@field(statement_sql, name));
            n += 1;
        }
        return out;
    }

    const statement_sql = .{
        .find_library = "SELECT id FROM libraries WHERE path = ?",
        .insert_library = "INSERT INTO libraries (path) VALUES (?)",
        // Live rows only: a trashed row keeps its old path while a new file
        // may now live there, and that file is a different image.
        .find_image =
            \\SELECT id, library_id, library_path, creation_date, positive_prompt_text,
            \\       negative_prompt_text, generated_description, thumbnail, hash, mtime,
            \\       model, sampler, scheduler, cfg, steps, seed, loras
            \\FROM images
            \\WHERE library_id = ? AND library_path = ? AND trashed_at IS NULL
        ,
        // DO NOTHING when another connection inserted the path first (unique
        // index, migration v14); the caller re-runs find_image.
        .insert_image =
            \\INSERT INTO images (library_id, library_path)
            \\VALUES (?, ?)
            \\ON CONFLICT DO NOTHING
        ,
        .update_image =
            \\UPDATE images
            \\SET positive_prompt_text = ?,
            \\    negative_prompt_text = ?,
            \\    generated_description = ?,
            \\    thumbnail = ?,
            \\    hash = ?,
            \\    mtime = ?,
            \\    model = ?,
            \\    sampler = ?,
            \\    scheduler = ?,
            \\    cfg = ?,
            \\    steps = ?,
            \\    seed = ?,
            \\    loras = ?
            \\WHERE id = ?
        ,
    };

    pub fn prepare(self: *Database, sql: []const u8) !PreparedStatement {
        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);

        if (result != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.db);
            log.err("SQLite prepare error: {s}", .{err_msg});
            return Error.SQLiteError;
        }

        return PreparedStatement{ .stmt = stmt.? };
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        var err_msg: [*c]u8 = null;
        const result = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);

        if (result != c.SQLITE_OK) {
            defer _ = c.sqlite3_free(err_msg);
            log.err("{s}", .{err_msg});
            return Error.SQLiteError;
        }
    }

    // Add method to get the last insert ID
    pub fn getLastInsertRowID(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    // Create a vector search virtual table
    pub fn createVectorTable(self: *Database, table_name: []const u8, dimensions: usize) !void {
        const sql = try self.allocator.print("CREATE VIRTUAL TABLE IF NOT EXISTS {s} USING vec0(vector float[{d}])", .{ table_name, dimensions });
        defer self.allocator.free(sql);

        try self.exec(sql);
    }

    /// Insert or replace the vector for `id`, only while `images` row `id` still
    /// has `owner_path`. Returns whether it was stored. vec0 ignores `INSERT OR
    /// REPLACE` (an existing rowid fails with a UNIQUE error), so delete first,
    /// inside a savepoint so a failed insert keeps the old vector.
    pub fn insertVector(self: *Database, table_name: []const u8, id: i64, owner_path: []const u8, vector: []const f32) !bool {
        try self.exec("SAVEPOINT insert_vector");
        errdefer self.exec("ROLLBACK TO insert_vector; RELEASE insert_vector") catch {};

        const del_sql = try self.allocator.print("DELETE FROM {s} WHERE rowid = ?", .{table_name});
        defer self.allocator.free(del_sql);
        var del = try self.prepare(del_sql);
        defer del.deinit();
        try del.bind(1, id);
        _ = try del.step();

        const sql = try self.allocator.print(
            "INSERT INTO {s}(rowid, vector) SELECT ?1, ?2 " ++
                "WHERE EXISTS (SELECT 1 FROM images WHERE id = ?1 AND library_path = ?3)",
            .{table_name},
        );
        defer self.allocator.free(sql);
        var ins = try self.prepare(sql);
        defer ins.deinit();
        try ins.bind(1, id);
        try ins.bindBlob(2, std.mem.sliceAsBytes(vector));
        try ins.bind(3, owner_path);
        _ = try ins.step();
        const stored = c.sqlite3_changes(self.db) > 0;

        try self.exec("RELEASE insert_vector");
        return stored;
    }

    // Search for nearest vectors
    /// KNN via the vec0 MATCH fast path. `distance` is the table's metric
    /// (L2 by default); with L2-normalized vectors the ranking equals cosine.
    pub fn searchNearestVectors(self: *Database, table_name: []const u8, query_vector: []const f32, limit: usize) !std.ArrayList(VecResult) {
        const sql = try self.allocator.print("SELECT rowid, distance FROM {s} WHERE vector MATCH ? AND k = ?", .{table_name});
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, @ptrCast(query_vector.ptr), @intCast(query_vector.len * @sizeOf(f32)), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(limit));

        var results: std.ArrayList(VecResult) = .empty;
        errdefer results.deinit(self.allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const distance = @as(f32, @floatCast(c.sqlite3_column_double(stmt, 1)));

            try results.append(self.allocator, .{ .id = id, .distance = distance });
        }

        return results;
    }
};
