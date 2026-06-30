//! Platform seam.
//!
//! Indirection over backend-specific services (native clipboard image data,
//! native folder picker) so UI modules can call them without importing the SDL
//! backend (`@import("backend")`) directly. Keeping those imports out of the UI
//! modules lets them compile against dvui's headless `.testing` backend for unit
//! tests.
//!
//! `app.zig` installs the real SDL-backed implementations at startup via
//! `init()` (see `platform_sdl.zig`). Tests leave the no-op defaults, or install
//! a spy vtable to assert that an action was invoked.
//!
//! Note: plain *text* clipboard does NOT go through here — use dvui's
//! backend-agnostic `dvui.clipboardTextSet()` / `dvui.clipboardText()` instead,
//! which the testing backend implements.

const std = @import("std");
const config_mod = @import("config.zig");

/// Called when the native folder picker resolves. `path` is null if the user
/// cancelled. The slice is only valid for the duration of the call.
pub const FolderPickedFn = *const fn (userdata: ?*anyopaque, path: ?[]const u8) void;

pub const Vtable = struct {
    /// Copy the image file at `path` to the system clipboard as image data.
    copy_image_file: *const fn (path: []const u8, gpa: std.mem.Allocator, io: std.Io) void = noopCopyImageFile,
    /// Open a native "choose folder" dialog. When it resolves, `on_picked` is
    /// invoked with `userdata` and the chosen path (or null on cancel).
    open_folder_dialog: *const fn (userdata: ?*anyopaque, on_picked: FolderPickedFn) void = noopOpenFolderDialog,
    /// Set a window's fullscreen state. `handle` is an opaque native window
    /// handle (the SDL window pointer in production); null is a no-op.
    set_window_fullscreen: *const fn (handle: ?*anyopaque, fullscreen: bool) void = noopSetWindowFullscreen,
    /// Sample a window's current geometry into `out` (see config.WindowState).
    capture_window_state: *const fn (handle: ?*anyopaque, out: *config_mod.WindowState) void = noopCaptureWindowState,
};

var vtable: Vtable = .{};

/// Install the platform implementations. Called once at startup by app.zig.
pub fn init(vt: Vtable) void {
    vtable = vt;
}

pub fn copyImageFile(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    vtable.copy_image_file(path, gpa, io);
}

pub fn openFolderDialog(userdata: ?*anyopaque, on_picked: FolderPickedFn) void {
    vtable.open_folder_dialog(userdata, on_picked);
}

pub fn setWindowFullscreen(handle: ?*anyopaque, fullscreen: bool) void {
    vtable.set_window_fullscreen(handle, fullscreen);
}

pub fn captureWindowState(handle: ?*anyopaque, out: *config_mod.WindowState) void {
    vtable.capture_window_state(handle, out);
}

fn noopCopyImageFile(_: []const u8, _: std.mem.Allocator, _: std.Io) void {}
fn noopOpenFolderDialog(_: ?*anyopaque, _: FolderPickedFn) void {}
fn noopSetWindowFullscreen(_: ?*anyopaque, _: bool) void {}
fn noopCaptureWindowState(_: ?*anyopaque, _: *config_mod.WindowState) void {}
