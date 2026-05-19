const std = @import("std");
const builtin = @import("builtin");
const SDLBackend = @import("backend");

const platform = switch (builtin.os.tag) {
    .linux   => @import("dnd_linux.zig"),

    // ── Windows ──────────────────────────────────────────────────────────────
    .windows => struct {
        const ghost_mod = @import("dnd_ghost.zig");

        const win32 = struct {
            pub extern fn dnd_win32_init() bool;
            pub extern fn dnd_win32_deinit() void;
            pub extern fn dnd_win32_start_drag(
                paths: [*]const [*:0]const u16,
                path_count: c_int,
                ghost_rgba: ?*const anyopaque,
                ghost_w: c_int,
                ghost_h: c_int,
            ) bool;
            pub extern fn dnd_win32_is_dragging() bool;
        };

        pub const DragItem = ghost_mod.DragItem;

        pub const DragSource = struct {
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?@This() {
                _ = sdl_window;
                if (!win32.dnd_win32_init()) return null;
                return .{ .allocator = allocator };
            }

            pub fn deinit(_: *@This()) void {
                win32.dnd_win32_deinit();
            }

            pub fn isDragging(_: *const @This()) bool {
                return win32.dnd_win32_is_dragging();
            }

            pub fn startDrag(self: *@This(), items: []const @This().DragItem) void {
                if (items.len == 0) return;

                const ghost = ghost_mod.composeGhost(self.allocator, items);
                defer if (ghost) |g| self.allocator.free(g.pixels);

                // Convert paths to null-terminated UTF-16.
                var wide_paths: std.ArrayList([*:0]const u16) = .empty;
                defer {
                    for (wide_paths.items) |p| self.allocator.free(std.mem.span(p));
                    wide_paths.deinit(self.allocator);
                }
                for (items) |item| {
                    const w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, item.path)
                        catch continue;
                    wide_paths.append(self.allocator, w) catch {
                        self.allocator.free(w);
                        continue;
                    };
                }
                if (wide_paths.items.len == 0) return;

                if (ghost) |g| {
                    _ = win32.dnd_win32_start_drag(
                        wide_paths.items.ptr,
                        @intCast(wide_paths.items.len),
                        g.pixels.ptr,
                        @intCast(g.width),
                        @intCast(g.height),
                    );
                } else {
                    _ = win32.dnd_win32_start_drag(
                        wide_paths.items.ptr,
                        @intCast(wide_paths.items.len),
                        null, 0, 0,
                    );
                }
            }

            pub fn pumpEvents(_: *@This()) void {}

            pub fn tick(_: *@This(), _: std.Io) void {}
        };
    },

    // ── macOS ─────────────────────────────────────────────────────────────────
    .macos   => struct {
        const macos_c = struct {
            pub extern fn dnd_macos_init(sdl_window: *anyopaque) bool;
            pub extern fn dnd_macos_deinit() void;
            pub extern fn dnd_macos_start_drag(
                paths: [*]const [*:0]const u8,
                path_count: c_int,
                jpeg_bufs: [*]const ?*const anyopaque,
                jpeg_lens: [*]const usize,
            ) void;
            pub extern fn dnd_macos_is_dragging() bool;
        };

        pub const DragItem = struct {
            path:       []const u8,
            thumb_jpeg: []const u8,
        };

        pub const DragSource = struct {
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, sdl_window: *SDLBackend.c.SDL_Window) ?@This() {
                if (!macos_c.dnd_macos_init(sdl_window)) return null;
                return .{ .allocator = allocator };
            }

            pub fn deinit(_: *@This()) void {
                macos_c.dnd_macos_deinit();
            }

            pub fn isDragging(_: *const @This()) bool {
                return macos_c.dnd_macos_is_dragging();
            }

            pub fn startDrag(self: *@This(), items: []const @This().DragItem) void {
                if (items.len == 0) return;
                const n = @min(items.len, 3);

                var path_ptrs: [3][*:0]const u8 = undefined;
                var path_bufs: [3][:0]const u8 = undefined;
                defer for (path_bufs[0..n]) |b| self.allocator.free(b);

                for (0..n) |i| {
                    path_bufs[i] = self.allocator.dupeZ(u8, items[i].path) catch return;
                    path_ptrs[i] = path_bufs[i].ptr;
                }

                var jpeg_ptrs: [3]?*const anyopaque = undefined;
                var jpeg_lens: [3]usize = undefined;
                for (0..n) |i| {
                    if (items[i].thumb_jpeg.len > 0) {
                        jpeg_ptrs[i] = items[i].thumb_jpeg.ptr;
                        jpeg_lens[i] = items[i].thumb_jpeg.len;
                    } else {
                        jpeg_ptrs[i] = null;
                        jpeg_lens[i] = 0;
                    }
                }

                macos_c.dnd_macos_start_drag(
                    &path_ptrs,
                    @intCast(n),
                    &jpeg_ptrs,
                    &jpeg_lens,
                );
            }

            pub fn pumpEvents(_: *@This()) void {}

            pub fn tick(_: *@This(), _: std.Io) void {}
        };
    },

    // ── Unsupported platform stub ─────────────────────────────────────────────
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
