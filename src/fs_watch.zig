const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.target.os.tag) {
    .linux => @import("fs_watch_linux.zig"),
    .macos, .ios => @import("fs_watch_mac.zig"),
    .windows => @import("fs_watch_windows.zig"),
    else => @import("fs_watch_stub.zig"),
};

pub const DirtyEvent = impl.DirtyEvent;
pub const FsWatcher = impl.FsWatcher;

test {
    std.testing.refAllDecls(impl);
}
