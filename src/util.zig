const std = @import("std");
const cmdFlags = @import("cmd_flags.zig");

pub fn getDataPath(allocator: std.mem.Allocator, options: *const cmdFlags.Flags, filename: []const u8) ![]const u8 {
    // If user specified a data path through command line, use that
    if (options.data_path) |path| {
        return try std.fs.path.join(
            allocator,
            &[_][]const u8{ try allocator.dupe(u8, path), filename }
        );
    }

    // Otherwise, get the standard app data directory
    const app_data_dir = try std.fs.getAppDataDir(allocator, "DiffKeep");
    defer allocator.free(app_data_dir);

    // Make sure the directory exists
    std.fs.makeDirAbsolute(app_data_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Build the path to the database file
    return try std.fs.path.join(allocator, &[_][]const u8{ app_data_dir, filename });
}