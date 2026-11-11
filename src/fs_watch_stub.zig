const std = @import("std");
const common = @import("fs_watch_common.zig");

pub const DirtyEvent = common.DirtyEvent;

pub const FsWatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !FsWatcher {
        _ = allocator;
        return error.NotImplemented;
    }
    pub fn start(self: *FsWatcher) !void { _ = self; }
    pub fn deinit(self: *FsWatcher) void { _ = self; }
    pub fn addLibrary(self: *FsWatcher, library_id: u64, path: []const u8) !void { _ = self; _ = library_id; _ = path; }
    pub fn removeLibrary(self: *FsWatcher, library_id: u64) void { _ = self; _ = library_id; }
    pub fn drainEvents(self: *FsWatcher) std.ArrayList(DirtyEvent) { _ = self; return .empty; }
    pub fn takeLost(self: *FsWatcher) bool { _ = self; return false; }
};
