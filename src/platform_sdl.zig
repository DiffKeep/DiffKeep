//! SDL-backed implementations of the `platform` seam. Imported only by app.zig
//! (the GUI entry point), so the SDL backend never enters the headless test
//! graph. Wire it up at startup with `platform.init(platform_sdl.vtable);`.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const platform = @import("platform.zig");
const window_state = @import("window_state.zig");
const config_mod = @import("config.zig");

pub const vtable: platform.Vtable = .{
    .copy_image_file = copyImageFile,
    .open_folder_dialog = openFolderDialog,
    .set_window_fullscreen = setWindowFullscreen,
    .capture_window_state = captureWindowState,
    .audio_open = audioOpen,
    .audio_feed = audioFeed,
    .audio_queued = audioQueued,
    .audio_set_gain = audioSetGain,
    .audio_set_paused = audioSetPaused,
    .audio_clear = audioClear,
    .audio_close = audioClose,
};

// ── Image clipboard ─────────────────────────────────────────────────────────
//
// SDL holds the data pointer until the clipboard is replaced, so the bytes are
// served lazily via a callback and freed by the cleanup callback.

const ClipboardImageData = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
};

fn clipboardImageCallback(userdata: ?*anyopaque, mime_type: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    _ = mime_type;
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    size.* = d.bytes.len;
    return d.bytes.ptr;
}

fn clipboardImageCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    d.gpa.free(d.bytes);
    d.gpa.destroy(d);
}

fn copyImageFile(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    copyImageFileImpl(path, gpa, io) catch {};
}

fn copyImageFileImpl(path: []const u8, gpa: std.mem.Allocator, io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len: usize = @intCast(try file.length(io));
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    const d = try gpa.create(ClipboardImageData);
    d.* = .{ .gpa = gpa, .bytes = bytes };
    var mime: [*c]const u8 = "image/png";
    _ = SDLBackend.c.SDL_SetClipboardData(clipboardImageCallback, clipboardImageCleanup, d, &mime, 1);
}

// ── Folder picker ───────────────────────────────────────────────────────────
//
// SDL's callback is C-typed and carries a single userdata pointer. Only one
// folder dialog is ever open at a time, so we bridge through file-local statics
// rather than allocating a context.

const FolderBridge = struct {
    var userdata: ?*anyopaque = null;
    var on_picked: platform.FolderPickedFn = undefined;

    fn cCallback(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const files = filelist orelse return on_picked(userdata, null);
        const first = files[0] orelse return on_picked(userdata, null);
        on_picked(userdata, std.mem.span(first));
    }
};

fn openFolderDialog(userdata: ?*anyopaque, on_picked: platform.FolderPickedFn) void {
    FolderBridge.userdata = userdata;
    FolderBridge.on_picked = on_picked;
    const sdl: *SDLBackend = dvui.currentWindow().backend.impl;
    SDLBackend.c.SDL_ShowOpenFolderDialog(FolderBridge.cCallback, null, sdl.window, null, false);
}

// ── Viewer window controls ──────────────────────────────────────────────────

fn setWindowFullscreen(handle: ?*anyopaque, fullscreen: bool) void {
    const win: *SDLBackend.c.SDL_Window = @ptrCast(handle orelse return);
    _ = SDLBackend.c.SDL_SetWindowFullscreen(win, fullscreen);
}

fn captureWindowState(handle: ?*anyopaque, out: *config_mod.WindowState) void {
    const win: *SDLBackend.c.SDL_Window = @ptrCast(handle orelse return);
    window_state.capture(win, out);
}

// ── Audio output (SDL3) ─────────────────────────────────────────────────────

fn audioOpen(sample_rate: i32, channels: i32) ?*anyopaque {
    _ = SDLBackend.c.SDL_InitSubSystem(SDLBackend.c.SDL_INIT_AUDIO);
    var spec: SDLBackend.c.SDL_AudioSpec = .{
        .format = SDLBackend.c.SDL_AUDIO_F32,
        .channels = channels,
        .freq = sample_rate,
    };
    const stream = SDLBackend.c.SDL_OpenAudioDeviceStream(
        SDLBackend.c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &spec,
        null,
        null,
    ) orelse return null;
    _ = SDLBackend.c.SDL_ResumeAudioStreamDevice(stream);
    return @ptrCast(stream);
}

fn audioFeed(handle: *anyopaque, pcm: []const u8) void {
    _ = SDLBackend.c.SDL_PutAudioStreamData(@ptrCast(handle), pcm.ptr, @intCast(pcm.len));
}

fn audioQueued(handle: *anyopaque) usize {
    const q = SDLBackend.c.SDL_GetAudioStreamQueued(@ptrCast(handle));
    return if (q < 0) 0 else @intCast(q);
}

fn audioSetGain(handle: *anyopaque, gain: f32) void {
    _ = SDLBackend.c.SDL_SetAudioStreamGain(@ptrCast(handle), gain);
}

fn audioSetPaused(handle: *anyopaque, paused: bool) void {
    if (paused) {
        _ = SDLBackend.c.SDL_PauseAudioStreamDevice(@ptrCast(handle));
    } else {
        _ = SDLBackend.c.SDL_ResumeAudioStreamDevice(@ptrCast(handle));
    }
}

fn audioClear(handle: *anyopaque) void {
    _ = SDLBackend.c.SDL_ClearAudioStream(@ptrCast(handle));
}

fn audioClose(handle: *anyopaque) void {
    SDLBackend.c.SDL_DestroyAudioStream(@ptrCast(handle));
}
