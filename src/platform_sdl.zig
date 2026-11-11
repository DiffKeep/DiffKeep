//! SDL-backed implementations of the `platform` seam. Imported only by app.zig
//! (the GUI entry point), so the SDL backend never enters the headless test
//! graph. Wire it up at startup with `platform.init(platform_sdl.vtable);`.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const platform = @import("platform.zig");
const window_state = @import("window_state.zig");
const config_mod = @import("config.zig");
const media = @import("media.zig");

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
// Copying starts reading the file on a background task and offers the data to
// SDL at once; the data callback (called on the main thread when another app
// pastes) awaits that read, which has long finished by then, and hands over
// the bytes. The cleanup callback frees them when the clipboard is replaced.

const ClipboardImageData = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    /// The background read; `bytes` is valid once it is awaited.
    read: std.Io.Group = .init,
    bytes: ?[]u8 = null,

    fn readTask(d: *ClipboardImageData) void {
        d.bytes = readWholeFile(d.gpa, d.io, d.path) catch |err| blk: {
            std.log.warn("copy image {s}: {}", .{ d.path, err });
            break :blk null;
        };
    }
};

fn clipboardImageCallback(userdata: ?*anyopaque, mime_type: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    _ = mime_type;
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    d.read.await(d.io) catch {};
    const bytes = d.bytes orelse {
        size.* = 0;
        return null;
    };
    size.* = bytes.len;
    return bytes.ptr;
}

fn clipboardImageCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const d: *ClipboardImageData = @ptrCast(@alignCast(userdata.?));
    d.read.await(d.io) catch {};
    if (d.bytes) |b| d.gpa.free(b);
    d.gpa.free(d.path);
    d.gpa.destroy(d);
}

fn readWholeFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len: usize = @intCast(try file.length(io));
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != len) return error.ShortRead;
    return bytes;
}

fn copyImageFile(path: []const u8, gpa: std.mem.Allocator, io: std.Io) void {
    copyImageFileImpl(path, gpa, io) catch |err| std.log.warn("copy image: {}", .{err});
}

fn copyImageFileImpl(path: []const u8, gpa: std.mem.Allocator, io: std.Io) !void {
    // Advertise the file's real format; a video can't be pasted as an image.
    const mime_z = media.imageMimeType(path) orelse return;
    const d = try gpa.create(ClipboardImageData);
    errdefer gpa.destroy(d);
    d.* = .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path) };
    errdefer gpa.free(d.path);
    try d.read.concurrent(io, ClipboardImageData.readTask, .{d});
    var mime: [*c]const u8 = mime_z.ptr;
    if (!SDLBackend.c.SDL_SetClipboardData(clipboardImageCallback, clipboardImageCleanup, d, &mime, 1)) {
        d.read.await(io) catch {};
        if (d.bytes) |b| gpa.free(b);
        return error.ClipboardFailed;
    }
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
