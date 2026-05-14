const std = @import("std");
const log = std.log.scoped(.sqlite);

pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

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

pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    connections: std.ArrayList(Database),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, init_pool_size: usize) !ConnectionPool {
        var pool = ConnectionPool{
            .allocator = allocator,
            .io = io,
            .db_path = try allocator.dupe(u8, db_path),
            .connections = .empty,
            .mutex = std.Io.Mutex.init,
        };
        errdefer pool.deinit();

        // Create the initial connections
        try pool.connections.ensureTotalCapacity(allocator, init_pool_size);
        for (0..init_pool_size) |_| {
            const db = try Database.open(allocator, db_path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX);
            try pool.connections.append(allocator, db);
        }

        return pool;
    }

    pub fn deinit(self: *ConnectionPool) void {
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

        if (self.connections.items.len == 0) {
            // Create a new connection if pool is empty
            const db = try Database.open(self.allocator, self.db_path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX);
            try self.connections.append(self.allocator, db);
        }

        return self.connections.pop().?;
    }

    pub fn release(self: *ConnectionPool, db: *Database) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.connections.append(self.allocator, db.*);
    }
};



pub const PreparedStatement = struct {
    stmt: *c.sqlite3_stmt,
    db: *Database,

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
            []const u8 => c.sqlite3_bind_text(self.stmt, @intCast(index), value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT),
            // Add more types as needed
            else => @compileError("Unsupported type for binding: " ++ @typeName(T)),
        };

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
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
                const err_msg = c.sqlite3_errmsg(self.db.db);
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

    pub fn columnText(self: *PreparedStatement, col: usize) []const u8 {
        const text = c.sqlite3_column_text(self.stmt, @intCast(col));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(col));
        return text[0..@intCast(len)];
    }

    pub fn columnBlob(self: *PreparedStatement, col: usize) []const u8 {
        const blob = c.sqlite3_column_blob(self.stmt, @intCast(col));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(col));
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
};

pub const Database = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    statements: Statements,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, flags: usize) !Database {
        log.debug("Creating a new database connection", .{});
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(path.ptr, &db, @intCast(flags), null);

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

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.db);
    }

    fn prepareStatements(db: *Database) !Statements {
        return Statements {
            .find_library = try db.prepare("SELECT id FROM libraries WHERE path = ?"),
            .insert_library = try db.prepare("INSERT INTO libraries (path) VALUES (?)"),
            .find_image = try db.prepare(
                \\SELECT id, library_id, library_path, creation_date, positive_prompt_text,
                \\       negative_prompt_text, generated_description, thumbnail, hash, mtime
                \\FROM images
                \\WHERE library_id = ? AND library_path = ?
            ),
            .insert_image = try db.prepare(
                \\INSERT INTO images (library_id, library_path)
                \\VALUES (?, ?)
            ),
            .update_image = try db.prepare(
                \\UPDATE images
                \\SET positive_prompt_text = ?,
                \\    negative_prompt_text = ?,
                \\    generated_description = ?,
                \\    thumbnail = ?,
                \\    hash = ?,
                \\    mtime = ?
                \\WHERE id = ?
            ),
        };
    }

    pub fn prepare(self: *Database, sql: []const u8) !PreparedStatement {
        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);

        if (result != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.db);
            log.err("SQLite prepare error: {s}", .{err_msg});
            return Error.SQLiteError;
        }

        return PreparedStatement{
            .stmt = stmt.?,
            .db = self,
        };
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
        const sql = try std.fmt.allocPrint(self.allocator, "CREATE VIRTUAL TABLE IF NOT EXISTS {s} USING vec0(vector float[{d}])", .{ table_name, dimensions });
        defer self.allocator.free(sql);

        try self.exec(sql);
    }

    // Insert a vector into the table
    pub fn insertVector(self: *Database, table_name: []const u8, _: usize, vector: []const f32) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO {s} (id, vector) VALUES (?, ?)", .{table_name});
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.db);
            log.err("SQLite prepare error: {s}", .{err_msg});
            return Error.SQLiteError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, @ptrCast(vector.ptr), @intCast(vector.len * @sizeOf(f32)), c.SQLITE_STATIC);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE) {
            const err_msg = c.sqlite3_errmsg(self.db);
            log.err("SQLite step error: {s}", .{err_msg});
            return Error.SQLiteError;
        }
    }

    // Search for nearest vectors
    pub fn searchNearestVectors(self: *Database, table_name: []const u8, query_vector: []const f32, limit: usize) !std.ArrayList(VecResult) {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT id, vec_distance_cosine(vector, ?) as distance FROM {s} ORDER BY distance LIMIT ?", .{table_name});
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, @ptrCast(query_vector.ptr), @intCast(query_vector.len * @sizeOf(f32)), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(limit));

        var results = std.ArrayList(VecResult).init(self.allocator);
        errdefer results.deinit();

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const distance = @as(f32, @floatCast(c.sqlite3_column_double(stmt, 1)));

            try results.append(.{ .id = id, .distance = distance });
        }

        return results;
    }
};
