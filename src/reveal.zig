//! "Show in file manager": open the folder holding a file, with the file
//! selected where the platform allows it.
//!
//! Windows: `explorer.exe /select,<path>`. macOS: `open -R <path>`. Linux and
//! the BSDs: the freedesktop `org.freedesktop.FileManager1.ShowItems` D-Bus
//! call (Nautilus, Dolphin, Nemo, Thunar, Caja, ... implement it) through
//! `dbus-send`, falling back to `xdg-open` on the folder (no selection) when no
//! file manager answers.
//!
//! Spawning is IO, so `reveal` runs the commands on a detached thread that
//! owns its own copy of the path (C heap): it may outlive the caller's frame
//! and touches nothing else.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.reveal);

const Os = std.Target.Os.Tag;

/// One command to try; the next is tried only if this one fails.
pub const Attempt = struct {
    argv: []const []const u8,
    /// explorer.exe exits 1 even when it opened the window, so its exit code
    /// says nothing; only a failure to spawn counts.
    check_exit: bool = true,
};

/// The commands that reveal `path` on `os`, in the order to try them.
/// Strings are allocated in `arena`.
pub fn attempts(arena: std.mem.Allocator, os: Os, path: []const u8) ![]const Attempt {
    switch (os) {
        .windows => {
            const sel = try std.mem.concat(arena, u8, &.{ "/select,", path });
            return arena.dupe(Attempt, &.{
                .{ .argv = try arena.dupe([]const u8, &.{ "explorer.exe", sel }), .check_exit = false },
            });
        },
        .macos => return arena.dupe(Attempt, &.{
            .{ .argv = try arena.dupe([]const u8, &.{ "open", "-R", path }) },
        }),
        else => {
            const uri = try fileUri(arena, path);
            // dbus-send splits `array:string:` on commas; `fileUri` escapes them.
            const items = try std.mem.concat(arena, u8, &.{ "array:string:", uri });
            const dir = std.Io.Dir.path.dirname(path) orelse path;
            return arena.dupe(Attempt, &.{
                .{ .argv = try arena.dupe([]const u8, &.{
                    "dbus-send",                  "--session",
                    "--print-reply",              "--dest=org.freedesktop.FileManager1",
                    "--type=method_call",         "/org/freedesktop/FileManager1",
                    "org.freedesktop.FileManager1.ShowItems", items,
                    "string:",
                }) },
                .{ .argv = try arena.dupe([]const u8, &.{ "xdg-open", dir }) },
            });
        },
    }
}

/// `file://` URI for an absolute POSIX path: every byte but the RFC 3986
/// unreserved set and `/` is percent-encoded (so spaces, commas, `#`, `%` and
/// non-ASCII UTF-8 bytes all survive).
pub fn fileUri(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    for (path) |c| {
        const keep = std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '.', '_', '~', '/' => true,
            else => false,
        };
        if (keep) {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(arena);
}

/// Reveal `path` in the system file manager, on a background thread.
/// Failures are logged; nothing comes back.
pub fn reveal(io: std.Io, path: []const u8) void {
    const a = std.heap.c_allocator;
    const job = a.create(Job) catch |err| {
        log.warn("reveal {s}: {}", .{ path, err });
        return;
    };
    job.* = .{ .io = io, .path = a.dupe(u8, path) catch |err| {
        log.warn("reveal {s}: {}", .{ path, err });
        a.destroy(job);
        return;
    } };
    const t = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
        log.warn("reveal {s}: spawn thread: {}", .{ path, err });
        job.destroy();
        return;
    };
    t.detach();
}

const Job = struct {
    io: std.Io,
    path: []u8,

    fn destroy(j: *Job) void {
        std.heap.c_allocator.free(j.path);
        std.heap.c_allocator.destroy(j);
    }

    fn run(j: *Job) void {
        defer j.destroy();
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const list = attempts(arena, builtin.target.os.tag, j.path) catch |err| {
            log.warn("reveal {s}: {}", .{ j.path, err });
            return;
        };
        for (list) |at| {
            const result = std.process.run(arena, j.io, .{ .argv = at.argv }) catch |err| {
                log.warn("reveal: {s} failed to start: {}", .{ at.argv[0], err });
                continue;
            };
            if (!at.check_exit) return;
            if (result.term == .exited and result.term.exited == 0) return;
            log.warn("reveal: {s} failed ({}): {s}", .{ at.argv[0], result.term, std.mem.trim(u8, result.stderr, " \r\n") });
        }
        log.warn("reveal {s}: no file manager could be opened", .{j.path});
    }
};

test "fileUri escapes everything but unreserved bytes and slashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const uri = try fileUri(arena.allocator(), "/home/me/A b,c#%/é~x_y-z.png");
    try std.testing.expectEqualStrings("file:///home/me/A%20b%2Cc%23%25/%C3%A9~x_y-z.png", uri);
}

test "attempts per platform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const win = try attempts(a, .windows, "C:\\pics\\a b.png");
    try std.testing.expectEqual(@as(usize, 1), win.len);
    try std.testing.expectEqualStrings("explorer.exe", win[0].argv[0]);
    try std.testing.expectEqualStrings("/select,C:\\pics\\a b.png", win[0].argv[1]);
    try std.testing.expect(!win[0].check_exit);

    const mac = try attempts(a, .macos, "/Users/me/a.png");
    try std.testing.expectEqualStrings("open", mac[0].argv[0]);
    try std.testing.expectEqualStrings("-R", mac[0].argv[1]);
    try std.testing.expectEqualStrings("/Users/me/a.png", mac[0].argv[2]);

    const lin = try attempts(a, .linux, "/home/me/x,y/a.png");
    try std.testing.expectEqual(@as(usize, 2), lin.len);
    try std.testing.expectEqualStrings("dbus-send", lin[0].argv[0]);
    try std.testing.expectEqualStrings("array:string:file:///home/me/x%2Cy/a.png", lin[0].argv[7]);
    try std.testing.expectEqualStrings("xdg-open", lin[1].argv[0]);
    try std.testing.expectEqualStrings("/home/me/x,y", lin[1].argv[1]);
}
