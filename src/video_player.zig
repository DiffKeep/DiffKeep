const std = @import("std");
const log = std.log.scoped(.video_player);
const video = @import("video");
const vips = @import("vips");
const media = @import("media.zig");
const platform = @import("platform.zig");

/// A frame source. Real videos (mp4/webm) decode through libav*, which also
/// carries audio. Animated images (gif/webp) decode through vips, because
/// libav* only decodes the first frame of animated WebP. Both expose the same
/// forward-decode + seek contract, so the player machinery is identical.
pub const Frame = video.DecodedFrame;

pub const Source = union(enum) {
    video: video.Decoder,
    anim: vips.AnimDecoder,

    fn fps(self: Source) f64 {
        return switch (self) {
            inline else => |d| d.fps(),
        };
    }

    /// `reuse` is consumed (see `video.Decoder.next`).
    fn next(self: Source, gpa: std.mem.Allocator, reuse: ?[]u8) !?video.DecodedFrame {
        switch (self) {
            .video => |d| return d.next(gpa, reuse),
            .anim => |d| {
                const f = (try d.next(gpa, reuse)) orelse return null;
                return .{ .pixels = f.pixels, .width = f.width, .height = f.height, .pts_ms = f.pts_ms };
            },
        }
    }

    fn seek(self: Source, ts_ms: i64) void {
        switch (self) {
            inline else => |d| d.seek(ts_ms),
        }
    }

    fn close(self: Source) void {
        switch (self) {
            inline else => |d| d.close(),
        }
    }
};

/// Threaded media player: a background thread decodes frames into a small bounded
/// queue; the render loop pulls the current frame, fps-paced, via `tick()`.
/// Supports play/pause, seeking (scrub), and frame-stepping. Loops at EOS.
/// Drives both real videos (with audio) and animated images (no audio).
pub const VideoPlayer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    source: Source,
    frame_duration_ns: i128,
    frame_duration_ms: i64,
    duration_ms: i64,

    mutex: std.Io.Mutex = std.Io.Mutex.init,
    not_full: std.Io.Condition = std.Io.Condition.init,
    queue: [capacity]?video.DecodedFrame = @splat(null),
    /// The `seek_gen` each queued frame was decoded under; frames from before
    /// the latest seek are dropped, never shown.
    queue_gen: [capacity]u64 = @splat(0),
    /// Bumped by every `requestSeek` (guarded by mutex).
    seek_gen: u64 = 0,
    head: usize = 0,
    count: usize = 0,
    /// Pixel buffers of shown or dropped frames, for the decoder to fill again
    /// instead of allocating one per frame (guarded by mutex).
    spare: [max_spare]?[]u8 = @splat(null),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// Pending seek target (ms). Set by the UI thread, consumed by the decoder.
    seek_target_ms: ?i64 = null,

    // Main-thread-only state.
    playing: bool = true,
    /// Pacing: each frame is due at the previous one's due time plus the gap
    /// between their timestamps (animations have per-frame delays; videos can
    /// be variable-rate). `started` false = the next frame is due now.
    started: bool = false,
    last_due_ns: i128 = 0,
    last_pts_ms: i64 = 0,
    pending_step: u32 = 0, // one-shot frame pops (frame-step / show-after-seek)
    current_pts_ms: i64 = 0,
    wakeup_fn: ?*const fn () void = null,

    // Audio (present only when the file has an audio stream and a device opened).
    audio_decoder: ?video.AudioDecoder = null,
    audio_stream: ?*anyopaque = null,
    audio_thread: ?std.Thread = null,
    audio_seek_target_ms: ?i64 = null, // guarded by mutex
    volume: f32 = 1.0,
    muted: bool = false,

    const capacity = 4;
    /// The queue, plus the frame on screen, plus one being decoded.
    const max_spare = capacity + 2;
    // Pacing debt beyond this (ns) resyncs the clock to now rather than
    // fast-forwarding — covers startup buffering gaps and decode stalls.
    const resync_threshold_ns: i128 = 250 * std.time.ns_per_ms;

    pub const Options = struct {
        wakeup_fn: ?*const fn () void = null,
        /// Play the audio track (videos only). The grid disables this so many
        /// cells can autoplay silently without each grabbing an audio device.
        audio: bool = true,
        /// Downscale decoded frames to fit this many px on the long edge; 0 keeps
        /// native resolution. The grid decodes at thumbnail size.
        max_dim: u32 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: [:0]const u8, opts: Options) !*VideoPlayer {
        const self = try gpa.create(VideoPlayer);
        errdefer gpa.destroy(self);

        // Real videos go through libav*; animated images through vips.
        const is_video = media.isVideoFile(path);
        const source: Source = if (is_video)
            .{ .video = try video.Decoder.open(path, opts.max_dim) }
        else
            .{ .anim = try vips.AnimDecoder.open(path, opts.max_dim) };
        errdefer source.close();

        const fps = source.fps();
        const fps_eff: f64 = if (fps > 0.1) fps else 25.0;
        // Video duration comes from a header probe; animated-image duration is the
        // sum of per-frame delays, known to the decoder.
        const duration_ms: i64 = switch (source) {
            .video => if (video.probe(path)) |i| @intFromFloat(i.duration_sec * 1000.0) else |err| blk: {
                log.warn("duration of {s}: {}", .{ std.Io.Dir.path.basename(path), err });
                break :blk 0;
            },
            .anim => |d| d.durationMs(),
        };

        self.* = .{
            .gpa = gpa,
            .io = io,
            .source = source,
            .frame_duration_ns = @intFromFloat(1_000_000_000.0 / fps_eff),
            .frame_duration_ms = @intFromFloat(1000.0 / fps_eff),
            .duration_ms = duration_ms,
            .wakeup_fn = opts.wakeup_fn,
        };
        self.thread = try std.Thread.spawn(.{}, decodeLoop, .{self});

        // Audio (videos only, and only when requested): open the stream + device,
        // then start the feeder thread. Animated images have no audio track; the
        // grid opts out so silent autoplay doesn't grab an audio device per cell.
        if (is_video and opts.audio) {
            if (video.AudioDecoder.open(path)) |adec| {
                if (platform.audioOpen(@intCast(adec.sample_rate), @intCast(adec.channels))) |stream| {
                    self.audio_decoder = adec;
                    self.audio_stream = stream;
                    self.audio_thread = std.Thread.spawn(.{}, audioLoop, .{self}) catch blk: {
                        platform.audioClose(stream);
                        adec.close();
                        self.audio_decoder = null;
                        self.audio_stream = null;
                        break :blk null;
                    };
                } else {
                    adec.close(); // no playback device available
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *VideoPlayer) void {
        self.stop.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        self.not_full.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |t| t.join();
        if (self.audio_thread) |t| t.join();
        if (self.audio_stream) |s| platform.audioClose(s);
        if (self.audio_decoder) |a| a.close();

        self.freeQueued();
        self.source.close();
        self.gpa.destroy(self);
    }

    pub fn isPlaying(self: *const VideoPlayer) bool {
        return self.playing;
    }

    pub fn togglePlay(self: *VideoPlayer) void {
        self.playing = !self.playing;
        self.started = false; // re-sync cadence to "now" on resume
        self.setAudioPaused(!self.playing);
    }

    /// Stop playback (and audio) if it is running.
    pub fn pause(self: *VideoPlayer) void {
        if (self.playing) self.togglePlay();
    }

    fn setAudioPaused(self: *VideoPlayer, paused: bool) void {
        if (self.audio_stream) |s| platform.audioSetPaused(s, paused);
    }

    pub fn hasAudio(self: *const VideoPlayer) bool {
        return self.audio_stream != null;
    }

    pub fn volumeLevel(self: *const VideoPlayer) f32 {
        return self.volume;
    }

    pub fn isMuted(self: *const VideoPlayer) bool {
        return self.muted;
    }

    fn applyGain(self: *VideoPlayer) void {
        if (self.audio_stream) |s| platform.audioSetGain(s, if (self.muted) 0 else self.volume);
    }

    pub fn setVolume(self: *VideoPlayer, v: f32) void {
        self.volume = std.math.clamp(v, 0, 1);
        self.muted = false; // dragging volume unmutes
        self.applyGain();
    }

    pub fn toggleMute(self: *VideoPlayer) void {
        self.muted = !self.muted;
        self.applyGain();
    }

    pub fn position(self: *const VideoPlayer) i64 {
        return self.current_pts_ms;
    }

    pub fn duration(self: *const VideoPlayer) i64 {
        return self.duration_ms;
    }

    /// Step one frame forward (and pause).
    pub fn stepForward(self: *VideoPlayer) void {
        self.playing = false;
        self.setAudioPaused(true);
        self.pending_step += 1;
    }

    /// Step ~one frame backward (and pause). Approximate — seeks to just before
    /// the current frame and shows the nearest frame there.
    pub fn stepBackward(self: *VideoPlayer) void {
        self.playing = false;
        self.setAudioPaused(true);
        self.requestSeek(self.current_pts_ms - self.frame_duration_ms - 1);
    }

    /// Seek to `target_ms`; shows the frame at/after the target.
    pub fn requestSeek(self: *VideoPlayer, target_ms: i64) void {
        const clamped = std.math.clamp(target_ms, 0, if (self.duration_ms > 0) self.duration_ms else target_ms);
        self.mutex.lockUncancelable(self.io);
        self.seek_target_ms = clamped;
        self.seek_gen += 1;
        if (self.audio_stream != null) self.audio_seek_target_ms = clamped;
        self.not_full.signal(self.io); // wake the decode thread if it's queue-full
        self.mutex.unlock(self.io);
        self.current_pts_ms = clamped; // optimistic; corrected when the frame lands
        // Exactly one frame to show at the target. NOT `+= 1`: a drag fires many
        // seeks, and accumulating would make it pop a burst of frames on release.
        self.pending_step = 1;
        self.started = false;
    }

    /// Pop the frame to display now (ownership transfers to the caller), or null.
    /// `now_ns` is a monotonic time (see `nowNs`).
    pub fn tick(self: *VideoPlayer, now_ns: i128) ?video.DecodedFrame {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropStaleLocked();

        // One-shot pop for frame-step / show-after-seek (ignores the clock).
        if (self.pending_step > 0) {
            const frame = self.popLocked() orelse return null; // not ready; retry next tick
            self.pending_step -= 1;
            self.current_pts_ms = frame.pts_ms;
            return frame;
        }

        if (!self.playing) return null;

        // Don't start (or keep advancing) the cadence clock until a frame is
        // actually buffered, so startup latency isn't burned off later by
        // fast-forwarding.
        var result: ?video.DecodedFrame = null;
        while (self.count > 0) {
            const head = self.queue[self.head].?;
            var due = if (self.started) self.dueOf(head.pts_ms) else now_ns;
            // Far behind (startup gap, decode stall): resync to now instead of
            // racing through the buffered frames.
            if (now_ns - due > resync_threshold_ns) due = now_ns;
            if (now_ns < due) break;
            // If the render loop is slower than the clip, several frames come
            // due at once: keep only the last, so speed stays correct.
            if (result) |prev| self.recycleLocked(prev.pixels);
            result = self.popLocked().?;
            self.started = true;
            self.last_due_ns = due;
            self.last_pts_ms = head.pts_ms;
        }
        if (result) |frame| self.current_pts_ms = frame.pts_ms;
        return result;
    }

    /// When `tick` next has a frame to return (monotonic ns, see `nowNs`), or
    /// null if that depends on the decoder (nothing queued: its push wakes the
    /// app) or nothing will play. The UI sets a timer for it instead of
    /// redrawing every frame (a 24 fps clip on a 144 Hz screen drew 6x over).
    pub fn nextDueNs(self: *VideoPlayer, now_ns: i128) ?i128 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        if (self.queue_gen[self.head] != self.seek_gen) return now_ns; // stale: drop now
        if (self.pending_step > 0) return now_ns;
        if (!self.playing) return null;
        if (!self.started) return now_ns;
        const due = self.dueOf(self.queue[self.head].?.pts_ms);
        return if (now_ns - due > resync_threshold_ns) now_ns else due;
    }

    /// When the frame with `pts_ms` is due, following the last shown frame.
    /// Timestamps that don't advance sensibly (a loop back to the start, or a
    /// missing/odd pts) fall back to the average frame duration.
    fn dueOf(self: *const VideoPlayer, pts_ms: i64) i128 {
        const delta = pts_ms - self.last_pts_ms;
        const step: i128 = if (delta > 0 and delta < 10_000)
            @as(i128, delta) * std.time.ns_per_ms
        else
            self.frame_duration_ns;
        return self.last_due_ns + step;
    }

    /// Drop queued frames decoded before the latest seek. Caller holds mutex.
    fn dropStaleLocked(self: *VideoPlayer) void {
        while (self.count > 0 and self.queue_gen[self.head] != self.seek_gen) {
            const f = self.popLocked().?;
            self.recycleLocked(f.pixels);
        }
    }

    /// Give back the pixels of a frame from `tick` once it is no longer shown
    /// (instead of freeing them), so the decoder can reuse the buffer.
    pub fn recycle(self: *VideoPlayer, pixels: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.recycleLocked(pixels);
    }

    fn recycleLocked(self: *VideoPlayer, pixels: []u8) void {
        for (&self.spare) |*b| if (b.* == null) {
            b.* = pixels;
            return;
        };
        self.gpa.free(pixels);
    }

    fn takeSpare(self: *VideoPlayer) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.spare) |*b| if (b.*) |px| {
            b.* = null;
            return px;
        };
        return null;
    }

    /// Free every queued frame and spare buffer (deinit, tests).
    pub fn freeQueued(self: *VideoPlayer) void {
        while (self.count > 0) {
            const f = self.queue[self.head].?;
            self.gpa.free(f.pixels);
            self.queue[self.head] = null;
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
        for (&self.spare) |*b| if (b.*) |px| {
            self.gpa.free(px);
            b.* = null;
        };
    }

    /// Monotonic time for `tick`: unaffected by wall-clock changes.
    pub fn nowNs(io: std.Io) i128 {
        return std.Io.Clock.awake.now(io).nanoseconds;
    }

    /// Pop the queue head (caller holds the mutex). Signals the decode thread.
    fn popLocked(self: *VideoPlayer) ?video.DecodedFrame {
        if (self.count == 0) return null;
        const frame = self.queue[self.head].?;
        self.queue[self.head] = null;
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        self.not_full.signal(self.io);
        return frame;
    }

    // ── decode thread ────────────────────────────────────────────────────────

    fn flushQueue(self: *VideoPlayer) void {
        self.mutex.lockUncancelable(self.io);
        while (self.count > 0) {
            const f = self.queue[self.head].?;
            self.recycleLocked(f.pixels);
            self.queue[self.head] = null;
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
        self.mutex.unlock(self.io);
        self.not_full.signal(self.io);
    }

    /// Queue a decoded frame, tagged with the `seek_gen` it was decoded under.
    pub fn pushFrame(self: *VideoPlayer, frame: video.DecodedFrame, gen: u64) void {
        self.mutex.lockUncancelable(self.io);
        if (self.count >= capacity) { // only possible across a seek; drop
            self.recycleLocked(frame.pixels);
            self.mutex.unlock(self.io);
            return;
        }
        const tail = (self.head + self.count) % capacity;
        self.queue[tail] = frame;
        self.queue_gen[tail] = gen;
        self.count += 1;
        self.mutex.unlock(self.io);
        if (self.wakeup_fn) |w| w();
    }

    fn doSeek(self: *VideoPlayer, target_ms: i64, gen: u64) void {
        self.source.seek(target_ms);
        self.flushQueue();
        // Decode forward, keeping the nearest frame below the target as a fallback,
        // and deliver the first frame at/after the target. If we hit EOF first
        // (e.g. seeking to the very end), deliver that nearest frame instead — so
        // seeking to the end shows the last frame rather than looping to the start.
        var nearest: ?video.DecodedFrame = null;
        while (!self.stop.load(.acquire)) {
            const r = self.source.next(self.gpa, self.takeSpare()) catch break;
            const frame = r orelse break; // EOF
            if (nearest) |n| self.recycle(n.pixels);
            nearest = null;
            if (frame.pts_ms < target_ms) {
                nearest = frame;
                continue;
            }
            self.pushFrame(frame, gen);
            return;
        }
        if (nearest) |n| self.pushFrame(n, gen); // EOF/stop → show the closest frame we found
    }

    fn decodeLoop(self: *VideoPlayer) void {
        while (!self.stop.load(.acquire)) {
            // Service a pending seek first.
            self.mutex.lockUncancelable(self.io);
            const seek = self.seek_target_ms;
            self.seek_target_ms = null;
            const gen = self.seek_gen;
            self.mutex.unlock(self.io);
            if (seek) |target| {
                self.doSeek(target, gen);
                continue;
            }

            // Wait for queue space (wake on stop or a new seek).
            self.mutex.lockUncancelable(self.io);
            while (self.count >= capacity and !self.stop.load(.acquire) and self.seek_target_ms == null)
                self.not_full.waitUncancelable(self.io, &self.mutex);
            const stopping = self.stop.load(.acquire);
            const has_seek = self.seek_target_ms != null;
            self.mutex.unlock(self.io);
            if (stopping) break;
            if (has_seek) continue;

            const res = self.source.next(self.gpa, self.takeSpare()) catch break;
            if (res) |frame| {
                self.pushFrame(frame, gen);
            } else {
                self.source.seek(0); // EOS → loop
            }
        }
    }

    fn sleepMs(self: *VideoPlayer, ms: u64) void {
        std.Io.sleep(self.io, .{ .nanoseconds = @intCast(ms * 1_000_000) }, .awake) catch {};
    }

    /// Audio feeder thread: keeps the output stream fed ~200ms ahead (so it plays
    /// in real time), honoring pause/seek/loop. Sync is loose (both audio and
    /// video are real-time paced), which is fine for these short clips.
    fn audioLoop(self: *VideoPlayer) void {
        const stream = self.audio_stream orelse return;
        const adec = self.audio_decoder orelse return;
        const threshold: usize = @intCast(adec.sample_rate * adec.channels * @sizeOf(f32) / 5);

        while (!self.stop.load(.acquire)) {
            self.mutex.lockUncancelable(self.io);
            const seek = self.audio_seek_target_ms;
            self.audio_seek_target_ms = null;
            self.mutex.unlock(self.io);
            if (seek) |t| {
                adec.seek(t);
                platform.audioClear(stream);
                continue;
            }

            if (!self.playing) {
                self.sleepMs(20);
                continue;
            }
            if (platform.audioQueued(stream) > threshold) {
                self.sleepMs(10);
                continue;
            }

            const chunk = adec.next(self.gpa) catch break;
            if (chunk) |c| {
                defer self.gpa.free(c.pcm);
                if (c.pcm.len > 0) platform.audioFeed(stream, c.pcm);
            } else {
                adec.seek(0); // EOS → loop
            }
        }
    }
};
