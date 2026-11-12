//! What the status bar's activity section shows: every background process
//! running right now, side by side (a scan can index, embed and load a model
//! at once). No UI: `toolbar.zig` renders the list this builds.

const std = @import("std");

/// The library scans' state (`LibraryManager.scanActivity`).
pub const Scan = struct {
    /// A scan is queued or running.
    active: bool = false,
    files_scanned: u32 = 0,
};

/// The embed worker's state (`LibraryManager.embedActivity`).
pub const Embed = struct {
    /// A pass is queued or running.
    active: bool = false,
    done: u32 = 0,
    /// `done` plus what is still pending; 0 until counted.
    total: u32 = 0,
};

/// Everything the activity section can show, read once per frame.
pub const State = struct {
    scan: Scan = .{},
    embed: Embed = .{},
    embedder_loading: bool = false,
    searching: bool = false,
    downloading: bool = false,
};

pub const Activity = union(enum) {
    /// Files looked at so far.
    indexing: u32,
    embedding: struct { done: u32, total: u32 },
    embed_model_loading,
    searching,
    downloading,
};

pub const max = @typeInfo(Activity).@"union".field_names.len;

/// The activities running in `s`, in display order.
pub fn list(s: State, buf: *[max]Activity) []const Activity {
    var n: usize = 0;
    if (s.scan.active) {
        buf[n] = .{ .indexing = s.scan.files_scanned };
        n += 1;
    }
    // A pass with nothing to do (total 0) isn't worth a line.
    if (s.embed.active and s.embed.total > 0) {
        buf[n] = .{ .embedding = .{ .done = s.embed.done, .total = s.embed.total } };
        n += 1;
    }
    if (s.embedder_loading) {
        buf[n] = .embed_model_loading;
        n += 1;
    }
    if (s.searching) {
        buf[n] = .searching;
        n += 1;
    }
    if (s.downloading) {
        buf[n] = .downloading;
        n += 1;
    }
    return buf[0..n];
}

test "idle shows nothing" {
    var buf: [max]Activity = undefined;
    try std.testing.expectEqual(0, list(.{}, &buf).len);
}

test "indexing and embedding show together" {
    var buf: [max]Activity = undefined;
    const got = list(.{
        .scan = .{ .active = true, .files_scanned = 40 },
        .embed = .{ .active = true, .done = 3, .total = 9 },
    }, &buf);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqual(40, got[0].indexing);
    try std.testing.expectEqual(3, got[1].embedding.done);
    try std.testing.expectEqual(9, got[1].embedding.total);
}

test "embedding shows on its own once the scan is done" {
    var buf: [max]Activity = undefined;
    const got = list(.{ .embed = .{ .active = true, .done = 3, .total = 9 } }, &buf);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expect(got[0] == .embedding);
}

test "an embedding pass with nothing to do isn't shown" {
    var buf: [max]Activity = undefined;
    try std.testing.expectEqual(0, list(.{ .embed = .{ .active = true } }, &buf).len);
}

test "counters left from finished work are not shown" {
    var buf: [max]Activity = undefined;
    try std.testing.expectEqual(0, list(.{
        .scan = .{ .files_scanned = 40 },
        .embed = .{ .done = 9, .total = 9 },
    }, &buf).len);
}

test "model loading, search and download show alongside a scan" {
    var buf: [max]Activity = undefined;
    const got = list(.{
        .scan = .{ .active = true },
        .embedder_loading = true,
        .searching = true,
        .downloading = true,
    }, &buf);
    try std.testing.expectEqual(4, got.len);
    try std.testing.expect(got[0] == .indexing);
    try std.testing.expect(got[1] == .embed_model_loading);
    try std.testing.expect(got[2] == .searching);
    try std.testing.expect(got[3] == .downloading);
}
