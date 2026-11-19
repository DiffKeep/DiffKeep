const std = @import("std");

const c = @import("video_c");

pub const Info = struct {
    width: u32,
    height: u32,
    duration_sec: f64,
    has_video: bool,
    has_audio: bool,
    nb_frames: i64,
};

/// Probe a media file's streams/dimensions/duration. Cheap (header only).
pub fn probe(path: [:0]const u8) !Info {
    var raw: c.DiffkeepVideoInfo = undefined;
    if (c.diffkeep_video_probe(path.ptr, &raw) != 0) return error.VideoProbeFailed;
    return .{
        .width = @intCast(@max(0, raw.width)),
        .height = @intCast(@max(0, raw.height)),
        .duration_sec = raw.duration_sec,
        .has_video = raw.has_video != 0,
        .has_audio = raw.has_audio != 0,
        .nb_frames = raw.nb_frames,
    };
}

/// What a library scan reads from a video. All parts are allocator-owned.
pub const ScanData = struct {
    /// First frame fitted to the requested size, or null if it didn't decode.
    frame: ?Frame,
    workflow: ?[]u8,
    prompt: ?[]u8,
    /// A1111-style "parameters" tag (TensorPencil's videos), or null.
    parameters: ?[]u8,

    pub fn deinit(self: ScanData, allocator: std.mem.Allocator) void {
        if (self.frame) |f| allocator.free(f.pixels);
        if (self.workflow) |w| allocator.free(w);
        if (self.prompt) |p| allocator.free(p);
        if (self.parameters) |p| allocator.free(p);
    }
};

/// Open `path` once for a scan: its ComfyUI "workflow"/"prompt" tags, its
/// "parameters" tag (TensorPencil) and its
/// first frame, fitted to `max_dim` px on the long edge (0 = native).
pub fn scanFile(allocator: std.mem.Allocator, path: [:0]const u8, max_dim: u32) !ScanData {
    var raw: c.DiffkeepVideoScan = undefined;
    if (c.diffkeep_video_scan(path.ptr, @intCast(max_dim), &raw) != 0) return error.VideoOpenFailed;
    defer c.diffkeep_video_scan_free(&raw);

    const workflow = if (raw.workflow) |w| try allocator.dupe(u8, std.mem.span(w)) else null;
    errdefer if (workflow) |w| allocator.free(w);
    const prompt = if (raw.prompt) |p| try allocator.dupe(u8, std.mem.span(p)) else null;
    errdefer if (prompt) |p| allocator.free(p);
    const parameters = if (raw.parameters) |p| try allocator.dupe(u8, std.mem.span(p)) else null;
    errdefer if (parameters) |p| allocator.free(p);
    const frame: ?Frame = if (raw.pixels) |px| blk: {
        const len: usize = @intCast(raw.width * raw.height * 4);
        break :blk .{
            .pixels = try allocator.dupe(u8, @as([*]const u8, @ptrCast(px))[0..len]),
            .width = @intCast(raw.width),
            .height = @intCast(raw.height),
        };
    } else null;
    return .{ .frame = frame, .workflow = workflow, .prompt = prompt, .parameters = parameters };
}

/// Read a format-level metadata tag (e.g. "workflow"/"prompt"); null if absent.
/// The returned slice is allocator-owned.
pub fn readTag(allocator: std.mem.Allocator, path: [:0]const u8, key: [:0]const u8) !?[]u8 {
    var out: [*c]u8 = null;
    if (c.diffkeep_video_read_tag(path.ptr, key.ptr, &out) != 0) return null;
    defer c.diffkeep_video_free(out);
    return try allocator.dupe(u8, std.mem.span(out));
}

pub const Frame = struct { pixels: []u8, width: u32, height: u32 };

/// A w x h RGBA8 buffer: `reuse` if it is that size, else a new allocation
/// (and `reuse` is freed).
pub fn frameBuffer(allocator: std.mem.Allocator, reuse: ?[]u8, w: c_int, h: c_int) ![]u8 {
    if (w <= 0 or h <= 0) {
        if (reuse) |b| allocator.free(b);
        return error.BadFrameSize;
    }
    const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    if (reuse) |b| {
        if (b.len == len) return b;
        allocator.free(b);
    }
    return allocator.alloc(u8, len);
}

pub const DecodedFrame = struct { pixels: []u8, width: u32, height: u32, pts_ms: i64 };

/// Stateful decoder session for playback. Not thread-safe; use from one thread.
pub const Decoder = struct {
    handle: *c.DiffkeepDecoder,

    /// `max_dim` downscales frames to fit that many px on the long edge (for the
    /// grid); 0 keeps native resolution.
    pub fn open(path: [:0]const u8, max_dim: u32) !Decoder {
        const h = c.diffkeep_decoder_open(path.ptr, @intCast(max_dim)) orelse return error.VideoOpenFailed;
        return .{ .handle = h };
    }

    pub fn close(self: Decoder) void {
        c.diffkeep_decoder_close(self.handle);
    }

    pub fn fps(self: Decoder) f64 {
        return c.diffkeep_decoder_fps(self.handle);
    }

    /// Decode the next frame, or null at end-of-stream. The pixels go into
    /// `reuse` when it is the right size, saving an allocation per frame;
    /// otherwise into a new allocation. `reuse` is consumed either way (kept
    /// in the frame, or freed).
    pub fn next(self: Decoder, allocator: std.mem.Allocator, reuse: ?[]u8) !?DecodedFrame {
        var w: c_int = 0;
        var h: c_int = 0;
        var pts: i64 = 0;
        const r = c.diffkeep_decoder_next(self.handle, &w, &h, &pts);
        if (r <= 0) {
            if (reuse) |b| allocator.free(b);
            return if (r == 0) null else error.VideoDecodeFailed;
        }
        const pixels = try frameBuffer(allocator, reuse, w, h);
        errdefer allocator.free(pixels);
        if (c.diffkeep_decoder_read(self.handle, pixels.ptr, pixels.len) != 0) return error.VideoDecodeFailed;
        return .{ .pixels = pixels, .width = @intCast(w), .height = @intCast(h), .pts_ms = pts };
    }

    /// Seek to ~ts_ms (keyframe at or before).
    pub fn seek(self: Decoder, ts_ms: i64) void {
        _ = c.diffkeep_decoder_seek(self.handle, ts_ms);
    }
};

pub const AudioChunk = struct { pcm: []u8, pts_ms: i64 }; // interleaved f32 stereo

/// Audio decoder session: resamples to interleaved f32 stereo. Not thread-safe.
pub const AudioDecoder = struct {
    handle: *c.DiffkeepAudioDecoder,
    sample_rate: u32,
    channels: u32,

    /// Returns null if the file has no audio stream.
    pub fn open(path: [:0]const u8) ?AudioDecoder {
        var rate: c_int = 0;
        var ch: c_int = 0;
        const h = c.diffkeep_audio_open(path.ptr, &rate, &ch) orelse return null;
        return .{ .handle = h, .sample_rate = @intCast(rate), .channels = @intCast(ch) };
    }

    pub fn close(self: AudioDecoder) void {
        c.diffkeep_audio_close(self.handle);
    }

    /// Next PCM chunk (allocator-owned), or null at end-of-stream.
    pub fn next(self: AudioDecoder, allocator: std.mem.Allocator) !?AudioChunk {
        var buf: ?*anyopaque = null;
        var n: c_int = 0;
        var pts: i64 = 0;
        const r = c.diffkeep_audio_next(self.handle, &buf, &n, &pts);
        if (r == 0) return null;
        if (r < 0) return error.AudioDecodeFailed;
        defer c.diffkeep_video_free(buf);
        const len: usize = @intCast(@max(0, n));
        const src = if (len == 0) &[_]u8{} else @as([*]const u8, @ptrCast(buf.?))[0..len];
        return .{ .pcm = try allocator.dupe(u8, src), .pts_ms = pts };
    }

    pub fn seek(self: AudioDecoder, ts_ms: i64) void {
        _ = c.diffkeep_audio_seek(self.handle, ts_ms);
    }
};

/// Decode the first video frame to packed RGBA8. Caller frees `pixels`.
pub fn firstFrameRgba(allocator: std.mem.Allocator, path: [:0]const u8) !Frame {
    var buf: ?*anyopaque = null;
    var w: c_int = 0;
    var h: c_int = 0;
    if (c.diffkeep_video_first_frame_rgba(path.ptr, &buf, &w, &h) != 0) return error.VideoDecodeFailed;
    defer c.diffkeep_video_free(buf);
    const len: usize = @intCast(w * h * 4);
    return .{
        .pixels = try allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]),
        .width = @intCast(w),
        .height = @intCast(h),
    };
}
