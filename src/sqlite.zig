const std = @import("std");

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

pub const PreparedStatement = struct {
    stmt: *c.sqlite3_stmt,
    db: *Database,

    pub fn deinit(self: *PreparedStatement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn bind(self: *PreparedStatement, index: usize, value: anytype) !void {
        const T = @TypeOf(value);
        const result = switch (T) {
            i32 => c.sqlite3_bind_int(self.stmt, @intCast(index), value),
            i64 => c.sqlite3_bind_int64(self.stmt, @intCast(index), value),
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
        const result = c.sqlite3_bind_blob(
            self.stmt,
            @intCast(index),
            data.ptr,
            @intCast(data.len),
            c.SQLITE_STATIC
        );

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }
    }

    pub fn step(self: *PreparedStatement) !bool {
        const result = c.sqlite3_step(self.stmt);
        switch (result) {
            c.SQLITE_ROW => return true,
            c.SQLITE_DONE => return false,
            else => return Error.SQLiteError,
        }
    }

    // Add more methods for fetching results as needed
};

pub const Database = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open(path.ptr, &db);

        if (result != c.SQLITE_OK) {
            return Error.SQLiteError;
        }

        // Initialize the vector extension
        var err_msg: [*c]u8 = null;
        const init_result = c.sqlite3_vec_init(db, &err_msg, null);
        if (init_result != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("SQLite vector extension init error: {s}\n", .{err_msg});
                c.sqlite3_free(err_msg);
            }
            _ = c.sqlite3_close(db);
            return Error.SQLiteError;
        }

        return Database{
            .db = db.?,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn prepare(self: *Database, sql: []const u8) !PreparedStatement {
        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);

        if (result != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.db);
            std.log.err("SQLite prepare error: {s}", .{err_msg});
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
            std.log.err("{s}", .{err_msg});
            return Error.SQLiteError;
        }
    }

    // Create a vector search virtual table
    pub fn createVectorTable(self: *Database, table_name: []const u8, dimensions: usize) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "CREATE VIRTUAL TABLE IF NOT EXISTS {s} USING vec0(id INTEGER PRIMARY KEY, vector float[{d}])", .{ table_name, dimensions });
        defer self.allocator.free(sql);

        try self.exec(sql);
    }

    // Insert a vector into the table
    pub fn insertVector(self: *Database, table_name: []const u8, _: usize, vector: []const f32) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO {s} (vector) VALUES (?)", .{table_name});
        defer self.allocator.free(sql);

        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_result = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(self.db);
            std.log.err("SQLite prepare error: {s}", .{err_msg});
            return Error.SQLiteError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_blob(stmt, 1, @ptrCast(vector.ptr), @intCast(vector.len * @sizeOf(f32)), c.SQLITE_STATIC);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_DONE) {
            const err_msg = c.sqlite3_errmsg(self.db);
            std.log.err("SQLite step error: {s}", .{err_msg});
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
