const std = @import("std");
const video = @import("video");
const vips = @import("vips");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.log.err("usage: video_probe <file> [max_dim]", .{});
        return error.MissingArgument;
    };
    // Optional: downscale decoder frames to fit this many px (grid autoplay size).
    const max_dim: u32 = if (args.next()) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;

    const info = try video.probe(path);
    std.log.info("video={} audio={} {d}x{d} duration={d:.2}s nb_frames={d}", .{
        info.has_video, info.has_audio, info.width, info.height, info.duration_sec, info.nb_frames,
    });

    if (try video.readTag(allocator, path, "workflow")) |w| {
        defer allocator.free(w);
        std.log.info("workflow tag: {d} bytes", .{w.len});
    } else std.log.info("workflow tag: (none)", .{});

    if (try video.readTag(allocator, path, "prompt")) |p| {
        defer allocator.free(p);
        std.log.info("prompt tag: {d} bytes", .{p.len});
    } else std.log.info("prompt tag: (none)", .{});

    try vips.init();
    defer vips.deinit();

    // libav* frame decode. Non-fatal: animated WebP fails here (libav* can't
    // decode it) but is still handled by the vips anim decoder below.
    if (video.firstFrameRgba(allocator, path)) |f| {
        defer allocator.free(f.pixels);
        std.log.info("first frame: {d}x{d} ({d} bytes rgba)", .{ f.width, f.height, f.pixels.len });
        const jpeg = try vips.rgbaToJpeg(allocator, f.pixels, f.width, f.height, 320);
        defer allocator.free(jpeg);
        std.log.info("poster jpeg: {d} bytes (valid JPEG: {})", .{
            jpeg.len, jpeg.len > 2 and jpeg[0] == 0xFF and jpeg[1] == 0xD8,
        });

        // Decoder session: decode every frame, then seek back and decode one.
        var dec = try video.Decoder.open(path, max_dim);
        defer dec.close();
        std.log.info("decoder fps: {d:.3}", .{dec.fps()});
        var count: usize = 0;
        var last_pts: i64 = -1;
        var fdim: struct { w: u32, h: u32 } = .{ .w = 0, .h = 0 };
        while (try dec.next(allocator)) |fr| {
            defer allocator.free(fr.pixels);
            count += 1;
            last_pts = fr.pts_ms;
            fdim = .{ .w = fr.width, .h = fr.height };
        }
        std.log.info("decoded {d} frames, last pts={d}ms, frame {d}x{d} (max_dim={d})", .{ count, last_pts, fdim.w, fdim.h, max_dim });

        dec.seek(0);
        if (try dec.next(allocator)) |fr| {
            defer allocator.free(fr.pixels);
            std.log.info("after seek(0): first frame pts={d}ms", .{fr.pts_ms});
        }
    } else |err| {
        std.log.info("libav* frame decode failed ({s}) — expected for animated WebP", .{@errorName(err)});
    }

    // Audio decoder: decode all PCM, verify total duration.
    if (video.AudioDecoder.open(path)) |adec| {
        defer adec.close();
        var total_bytes: usize = 0;
        var audio_last_pts: i64 = 0;
        while (try adec.next(allocator)) |chunk| {
            defer allocator.free(chunk.pcm);
            total_bytes += chunk.pcm.len;
            audio_last_pts = chunk.pts_ms;
        }
        const samples_per_ch = total_bytes / (adec.channels * @sizeOf(f32));
        const dur_s = @as(f64, @floatFromInt(samples_per_ch)) / @as(f64, @floatFromInt(adec.sample_rate));
        std.log.info("audio: {d}Hz {d}ch, {d} bytes (~{d:.2}s, last pts={d}ms)", .{
            adec.sample_rate, adec.channels, total_bytes, dur_s, audio_last_pts,
        });
    } else {
        std.log.info("audio: (none)", .{});
    }

    // Animated-image decoder (gif / animated webp) via vips — the fallback for
    // formats libav* can't fully decode (animated WebP in particular).
    const open_t0 = std.Io.Clock.real.now(init.io).nanoseconds;
    if (vips.AnimDecoder.open(path, max_dim)) |adec| {
        defer adec.close();
        const open_ms = @as(f64, @floatFromInt(@max(0, std.Io.Clock.real.now(init.io).nanoseconds - open_t0))) / 1_000_000.0;
        std.log.info("anim: {d} frames, {d}ms, fps={d:.3} — open took {d:.1}ms", .{
            adec.frameCount(), adec.durationMs(), adec.fps(), open_ms,
        });
        var acount: usize = 0;
        var a_last: i64 = -1;
        var adim: struct { w: u32, h: u32 } = .{ .w = 0, .h = 0 };
        const t0 = std.Io.Clock.real.now(init.io).nanoseconds;
        while (try adec.next(allocator)) |fr| {
            defer allocator.free(fr.pixels);
            acount += 1;
            a_last = fr.pts_ms;
            adim = .{ .w = fr.width, .h = fr.height };
        }
        const ns: u64 = @intCast(@max(0, std.Io.Clock.real.now(init.io).nanoseconds - t0));
        const per_ms = if (acount > 0) @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(acount)) / 1_000_000.0 else 0;
        std.log.info("anim decoded {d} frames, last pts={d}ms, frame {d}x{d} (max_dim={d}) — {d:.2}ms/frame, {d:.1}ms total", .{ acount, a_last, adim.w, adim.h, max_dim, per_ms, @as(f64, @floatFromInt(ns)) / 1_000_000.0 });
        adec.seek(0);
        if (try adec.next(allocator)) |fr| {
            defer allocator.free(fr.pixels);
            std.log.info("anim after seek(0): first frame pts={d}ms", .{fr.pts_ms});
        }
    } else |_| {
        std.log.info("anim: (not an animated image)", .{});
    }
}
