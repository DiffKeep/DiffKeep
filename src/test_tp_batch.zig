//! DiffKeep-side batch throughput bench for the TensorPencil embedding encoders.
//!
//! Purpose: prove — from *DiffKeep's own build* (the `TensorPencil` module
//! imported with `.ggml = false`, no extra GPU link wiring) — that we can drive
//! TP's batched forward (`tp.embed.embedTextBatch` / `embedImageBatch`) on CPU,
//! Vulkan, and CUDA, and measure the single-vs-batch speedup. This is the
//! "before wiring it into the app" checkpoint: it does NOT touch scan.zig or
//! onnx_embedder.zig; it only exercises the TP façade directly so we can pick a
//! batch size + backend before changing the indexing pipeline.
//!
//! The GPU backends dlopen the Vulkan loader / CUDA driver at runtime (kernels
//! are embedded in the tp_gpu module), so DiffKeep's plain module import reaches
//! them with no linkSystemLibrary changes.
//!
//! Build in ReleaseFast (Debug f32 matmul is very slow):
//!   zig build test_tp_batch -Doptimize=ReleaseFast -- [opts]
//!
//!   --backend cpu|vulkan|cuda   compute backend (default cpu)
//!   --model all|snowflake|gemma|siglip-text|siglip-visual  (default all)
//!   --count N                   total items to encode (default 64)
//!   --batch B                   items per batched forward (default 1)
//!   --seq S                     approx target token count for text (default ~16)
//!   --reps R                    timed repetitions, best-of reported (default 3)
//!
//! DiffKeep's production spaces: text `.semantic` = gemma; cross-modal query =
//! siglip-text; image index = siglip-visual. snowflake is kept for A/B.

const std = @import("std");
const tp = @import("TensorPencil");

const embed = tp.embed;
const print = std.debug.print;

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.real.now(io).nanoseconds);
}

const Which = enum { snowflake, gemma, siglip_text, siglip_visual };

// Model dirs relative to DiffKeep's cwd (must hold safetensors + tokenizer.json).
const model_dir = struct {
    const snowflake = "Models/snowflake-arctic-embed-m-v2.0";
    const gemma = "Models/embeddinggemma-300m";
    const siglip = "Models/ViT-B-16-SigLIP2-timm";
};

const Args = struct {
    backend_name: []const u8 = "cpu",
    model: []const u8 = "all",
    count: usize = 64,
    batch: usize = 1,
    seq: usize = 16,
    reps: usize = 3,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else "";
        if (std.mem.eql(u8, arg, "--backend")) {
            a.backend_name = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--model")) {
            a.model = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--count")) {
            a.count = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--batch")) {
            a.batch = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seq")) {
            a.seq = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--reps")) {
            a.reps = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        }
    }
    return a;
}

// Build `count` distinct-ish text inputs of roughly `seq` tokens each. Suffixing
// the index keeps tokenization per-item distinct (mirrors real prompt variety).
fn buildTexts(gpa: std.mem.Allocator, count: usize, seq: usize) ![][]const u8 {
    const base = "a photograph of a red bicycle leaning against a brick wall ";
    const reps = @max(1, seq / 12);
    const texts = try gpa.alloc([]const u8, count);
    for (texts, 0..) |*t, i| {
        var buf: std.ArrayList(u8) = .empty;
        for (0..reps) |_| try buf.appendSlice(gpa, base);
        const suffix = try gpa.print("#{d}", .{i});
        try buf.appendSlice(gpa, suffix);
        t.* = try buf.toOwnedSlice(gpa);
    }
    return texts;
}

// Preprocessed [-1,1] CHW tensors (what libvips hands SigLIP visual at 224²).
fn buildImages(gpa: std.mem.Allocator, count: usize) ![][]const f32 {
    const n = 3 * 224 * 224;
    const imgs = try gpa.alloc([]const f32, count);
    for (imgs, 0..) |*im, i| {
        const buf = try gpa.alloc(f32, n);
        for (buf, 0..) |*v, j| v.* = @sin(@as(f32, @floatFromInt((j + i * 7) % 257)) * 0.0245);
        im.* = buf;
    }
    return imgs;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(gpa);
    const a = try parseArgs(argv);

    const backend: embed.Backend = blk: {
        if (std.mem.eql(u8, a.backend_name, "cpu")) break :blk .cpu;
        if (std.mem.eql(u8, a.backend_name, "vulkan")) {
            const ctx = try tp.gpu.context.Context.init(gpa, io);
            break :blk .{ .vulkan = ctx };
        }
        if (std.mem.eql(u8, a.backend_name, "cuda")) {
            const be = try tp.gpu.cuda.Backend.init(gpa);
            break :blk .{ .cuda = be };
        }
        return error.UnknownBackend;
    };

    print("test_tp_batch: backend={s} count={d} batch={d} seq~{d} reps={d}\n", .{ a.backend_name, a.count, a.batch, a.seq, a.reps });
    print("{s:<16} {s:>10} {s:>12} {s:>12}\n", .{ "model", "ms/item", "items/s", "ms/batch" });

    const want_all = std.mem.eql(u8, a.model, "all");
    const sel = struct {
        fn on(name: []const u8, m: []const u8, all: bool) bool {
            return all or std.mem.eql(u8, m, name);
        }
    }.on;

    if (sel("snowflake", a.model, want_all)) try benchText(gpa, io, .snowflake, backend, a);
    if (sel("gemma", a.model, want_all)) try benchText(gpa, io, .gemma, backend, a);
    if (sel("siglip-text", a.model, want_all)) try benchText(gpa, io, .siglip_text, backend, a);
    if (sel("siglip-visual", a.model, want_all)) try benchImage(gpa, io, backend, a);
}

fn benchText(gpa: std.mem.Allocator, io: std.Io, which: Which, backend: embed.Backend, a: Args) !void {
    const kind: embed.TextModelKind = switch (which) {
        .snowflake => .arctic_embed_m_v2,
        .gemma => .embeddinggemma,
        .siglip_text => .siglip2_text,
        .siglip_visual => unreachable,
    };
    const dir = switch (which) {
        .snowflake => model_dir.snowflake,
        .gemma => model_dir.gemma,
        .siglip_text => model_dir.siglip,
        .siglip_visual => unreachable,
    };
    std.Io.Dir.cwd().access(io, dir, .{}) catch {
        print("{s:<16} (skipped: {s} missing)\n", .{ @tagName(which), dir });
        return;
    };
    var enc = try embed.TextEncoder.open(gpa, io, kind, dir, backend);
    defer enc.deinit();

    const texts = try buildTexts(gpa, a.count, a.seq);
    // Index-time documents (what scan.zig embeds); DiffKeep queries are single.
    const opts: embed.Options = .{ .role = .document };

    // Warmup: primes weights + device buffers so timed reps measure steady state.
    {
        const w = try enc.embedTextBatch(gpa, texts[0..@min(a.batch, a.count)], opts);
        for (w) |v| gpa.free(v);
        gpa.free(w);
    }

    var best: u64 = std.math.maxInt(u64);
    for (0..a.reps) |_| {
        const t0 = nowNs(io);
        var off: usize = 0;
        while (off < a.count) {
            const end = @min(off + a.batch, a.count);
            const vecs = try enc.embedTextBatch(gpa, texts[off..end], opts);
            for (vecs) |v| gpa.free(v);
            gpa.free(vecs);
            off = end;
        }
        best = @min(best, nowNs(io) - t0);
    }
    report(@tagName(which), best, a);
}

fn benchImage(gpa: std.mem.Allocator, io: std.Io, backend: embed.Backend, a: Args) !void {
    const dir = model_dir.siglip;
    std.Io.Dir.cwd().access(io, dir, .{}) catch {
        print("{s:<16} (skipped: {s} missing)\n", .{ "siglip-visual", dir });
        return;
    };
    var enc = try embed.ImageEncoder.open(gpa, io, dir, backend);
    defer enc.deinit();

    const imgs = try buildImages(gpa, a.count);
    {
        const w = try enc.embedImageBatch(gpa, imgs[0..@min(a.batch, a.count)]);
        for (w) |v| gpa.free(v);
        gpa.free(w);
    }

    var best: u64 = std.math.maxInt(u64);
    for (0..a.reps) |_| {
        const t0 = nowNs(io);
        var off: usize = 0;
        while (off < a.count) {
            const end = @min(off + a.batch, a.count);
            const vecs = try enc.embedImageBatch(gpa, imgs[off..end]);
            for (vecs) |v| gpa.free(v);
            gpa.free(vecs);
            off = end;
        }
        best = @min(best, nowNs(io) - t0);
    }
    report("siglip-visual", best, a);
}

fn report(name: []const u8, best_ns: u64, a: Args) void {
    const total_ms = @as(f64, @floatFromInt(best_ns)) / 1e6;
    const per_item = total_ms / @as(f64, @floatFromInt(a.count));
    const items_s = 1000.0 / per_item;
    const n_batches = std.math.divCeil(usize, a.count, a.batch) catch 1;
    const per_batch = total_ms / @as(f64, @floatFromInt(n_batches));
    print("{s:<16} {d:>10.3} {d:>12.1} {d:>12.3}\n", .{ name, per_item, items_s, per_batch });
}
