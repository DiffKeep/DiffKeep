const std = @import("std");
const builtin = @import("builtin");
const SDLBackend = @import("backend");

const platform = switch (builtin.os.tag) {
    .linux   => @import("dnd_linux.zig"),
    .windows => @compileError("Windows DnD not yet implemented — see DRAG-DROP.md"),
    .macos   => @compileError("macOS DnD not yet implemented — see DRAG-DROP.md"),
    else     => struct {
        pub const DragItem = struct { path: []const u8, thumb_jpeg: []const u8 };
        pub const DragSource = struct {
            pub fn init(_: std.mem.Allocator, _: *SDLBackend.c.SDL_Window) ?@This() { return null; }
            pub fn deinit(_: *@This()) void {}
            pub fn isDragging(_: *const @This()) bool { return false; }
            pub fn startDrag(_: *@This(), _: anytype) void {}
            pub fn pumpEvents(_: *@This()) void {}
            pub fn tick(_: *@This(), _: std.Io) void {}
        };
    },
};

pub const DragItem   = platform.DragItem;
pub const DragSource = platform.DragSource;
