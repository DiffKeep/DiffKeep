//! Build-time helper: prints the app version from git, e.g. "v0.3-12-gabc123",
//! suffixed "(DIRTY)" when the working tree has changes. Prints "dev" when git
//! or the repository is unavailable, so a source tarball still builds.
//! Run on every build by build.zig (`has_side_effects`), never at configure
//! time, whose result Zig caches.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // One-shot tool: everything is freed with the process arena.
    const version = describe(init.arena.allocator(), init.io) catch "dev";
    try std.Io.File.stdout().writeStreamingAll(init.io, version);
}

fn describe(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const tag = try git(arena, io, &.{ "git", "describe", "--tags", "--always" });
    if (tag.len == 0) return error.NoVersion;
    const status = try git(arena, io, &.{ "git", "status", "--porcelain" });
    if (status.len > 0) return arena.print("{s}(DIRTY)", .{tag});
    return tag;
}

fn git(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) return error.GitFailed;
    return std.mem.trimEnd(u8, result.stdout, "\n");
}
