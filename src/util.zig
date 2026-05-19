const std = @import("std");

/// Write a formatted string to stdout.  Buffer is 4096 bytes; larger output will error.
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

pub fn getDataPath(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, filename: []const u8) ![]const u8 {
    // Make sure the directory exists
    std.Io.Dir.createDirAbsolute(io, data_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Build the path to the database file
    return try std.fs.path.join(allocator, &[_][]const u8{ data_path, filename });
}