/// Embedding backend for DiffKeep — every encoder runs natively via TensorPencil
/// (no ONNX Runtime):
///   - EmbeddingGemma 300m (text)      — prompt search, 768-dim
///   - SigLIP2 ViT-B-16 visual (image) — image index, 768-dim
///   - SigLIP2 ViT-B-16 text           — cross-modal query, 768-dim
///
/// All three are optional: pass null dirs to skip loading a model. Every encoder
/// produces an L2-normalized 768-d vector; do NOT re-normalize downstream.
///
/// Adaptive backend routing: TensorPencil batch=1 on the GPU is *slower* than CPU
/// (kernel-dispatch latency dominates), while big batches are far faster on the
/// GPU. So each embed call picks its backend by item count: `n >= threshold`
/// (config `embed_gpu_threshold`) routes to the configured GPU, otherwise CPU.
/// A lone new image (watcher) and every search query therefore run on CPU; a scan
/// that floods the queue batches onto the GPU.
///
/// Threading: TensorPencil GPU backends are single-stream/serial and the three
/// encoders share one GPU handle, and they all share the mutable `.backend` field
/// this router flips per call — so every embed call is serialized by `mutex`.
/// That costs nothing: a batched forward already uses the whole device (or, on
/// CPU, every core), so there is no throughput left for concurrent callers.
const std = @import("std");
const tp  = @import("TensorPencil");
const vips = @import("vips").c;
const config = @import("config.zig");
const media = @import("media.zig");
const video = @import("video");

const log = std.log.scoped(.embedder);

// ── Constants ─────────────────────────────────────────────────────────────────

const SIGLIP_IMAGE_SIZE  = 224;
const SIGLIP_MEAN: [3]f32 = .{ 0.5, 0.5, 0.5 };
const SIGLIP_STD:  [3]f32 = .{ 0.5, 0.5, 0.5 };

/// Conservative gemma content-token budget. The model takes up to `max_seq`
/// (2048) framed tokens (content + role prefix + <bos> + <eos>) and returns
/// error.SequenceTooLong past it; the reserve leaves room for the prefix
/// (~8 tokens), the 2 frame tokens, and tokenization-boundary slack. A prompt
/// over it is embedded in chunks (see `embedPrompt`).
const GEMMA_CONTENT_BUDGET: usize = tp.models.embed_gemma.max_seq - 16;

/// Tokens per chunk of a prompt too long to embed in one pass. Below the
/// budget: a chunk decoded from token ids can tokenize a few tokens longer
/// at its edges.
pub const prompt_chunk_tokens: usize = GEMMA_CONTENT_BUDGET - 8;

/// The most chunks a long prompt is embedded from; the rest is left to text
/// search. Prompts that long are runaway generations repeating themselves
/// (one of 51k real prompts is 360 KB of a looping LLM output): what they
/// mean is at the start, and every chunk costs a forward pass.
pub const max_prompt_chunks: usize = 8;

/// How many chunks of `size` tokens a prompt of `n` tokens is embedded from.
pub fn promptChunkCount(n: usize, size: usize) usize {
    return @min(std.math.divCeil(usize, n, size) catch unreachable, max_prompt_chunks);
}

/// The normalized mean of unit vectors: one prompt vector from its chunks.
/// Averaging blurs a prompt that changes subject, but image prompts mostly
/// describe one scene. Caller owns the result.
pub fn meanNormalized(allocator: std.mem.Allocator, vecs: []const []const f32) ![]f32 {
    const out = try allocator.alloc(f32, vecs[0].len);
    @memset(out, 0);
    for (vecs) |v| for (out, v) |*o, x| {
        o.* += x;
    };
    var norm: f32 = 0;
    for (out) |x| norm += x * x;
    norm = @sqrt(norm);
    if (norm > 0) for (out) |*x| {
        x.* /= norm;
    };
    return out;
}

/// Which GPU backend to prefer for batched work (falls back to CPU per call when
/// the batch is below the threshold, or entirely when the handle failed to open).
/// Defined in config so it is the single source of truth for the persisted value.
pub const GpuBackend = config.GpuBackend;

// ── Embedder ────────────────────────────────────────────────────────────────

pub const Embedder = struct {
    allocator: std.mem.Allocator,
    io:        std.Io,
    /// Serializes every embed call (shared GPU handle + shared `.backend` field).
    mutex:     std.Io.Mutex = .init,
    /// Batch size at/above which a call routes to the GPU (min 1).
    threshold: usize,

    // At most one GPU handle, shared by all encoders. null = CPU-only (either
    // `.none` was requested or the device/driver was unavailable at init).
    vk:   ?*tp.gpu.context.Context = null,
    cuda: ?*tp.gpu.cuda.Backend    = null,

    // Encoders, opened once and reused. Opened with `.cpu`; the per-call router
    // flips `.backend` before dispatch (the loaded weights are backend-agnostic —
    // GPU dispatch uploads them to the handle's pointer-keyed cache on first use).
    text:   ?tp.embed.TextEncoder  = null, // EmbeddingGemma — semantic space
    xmodal: ?tp.embed.TextEncoder  = null, // SigLIP2 text   — cross-modal query
    image:  ?tp.embed.ImageEncoder = null, // SigLIP2 visual — image index

    /// Initialise.  Pass absolute paths to model dirs; null = skip that model.
    ///   text_dir    : embeddinggemma-300m dir (model.safetensors + 2_Dense/ + 3_Dense/ + tokenizer.json)
    ///   visual_dir  : ViT-B-16-SigLIP2 timm dir (open_clip_model.safetensors + tokenizer.json)
    ///   gpu_backend : which GPU to prefer for batched work (none/vulkan/cuda)
    ///   threshold   : batch size at/above which calls use the GPU
    pub fn init(
        io:          std.Io,
        allocator:   std.mem.Allocator,
        text_dir:    ?[]const u8,
        visual_dir:  ?[]const u8,
        gpu_backend: GpuBackend,
        threshold:   usize,
    ) !Embedder {
        var self = Embedder{
            .allocator = allocator,
            .io        = io,
            .threshold = @max(threshold, 1),
        };
        errdefer self.deinit();

        // GPU handle — graceful fallback to CPU if the device/driver is missing.
        switch (gpu_backend) {
            .none => {},
            .vulkan => self.vk = tp.gpu.context.Context.init(allocator, io) catch |err| blk: {
                log.warn("vulkan init failed ({}); embedding stays on CPU", .{err});
                break :blk null;
            },
            .cuda => self.cuda = tp.gpu.cuda.Backend.init(allocator) catch |err| blk: {
                log.warn("cuda init failed ({}); embedding stays on CPU", .{err});
                break :blk null;
            },
        }
        log.info("embedder gpu backend: requested={s} active={s} threshold={d}", .{
            @tagName(gpu_backend), if (self.hasGpu()) @tagName(gpu_backend) else "cpu", self.threshold,
        });

        // Each encoder loads independently: a stale or missing visual dir must not
        // disable text search (and vice versa). Failures log and leave that encoder
        // null, so hasPromptEncoder/hasVisualEncoder reflect what actually loaded.
        if (text_dir) |dir| {
            if (tp.embed.TextEncoder.open(allocator, io, .embeddinggemma, dir, .cpu)) |enc| {
                self.text = enc;
                log.info("embeddinggemma text encoder loaded from {s}", .{dir});
            } else |err| log.warn("embeddinggemma load from {s} failed: {}", .{ dir, err });
        }
        if (visual_dir) |dir| {
            if (tp.embed.ImageEncoder.open(allocator, io, dir, .cpu)) |enc| {
                self.image = enc;
            } else |err| log.warn("siglip2 visual load from {s} failed: {}", .{ dir, err });
            if (tp.embed.TextEncoder.open(allocator, io, .siglip2_text, dir, .cpu)) |enc| {
                self.xmodal = enc;
            } else |err| log.warn("siglip2 text load from {s} failed: {}", .{ dir, err });
            if (self.image != null or self.xmodal != null)
                log.info("siglip2 encoders loaded from {s}", .{dir});
        }
        return self;
    }

    pub fn deinit(self: *Embedder) void {
        // TensorPencil drops an encoder's device weights through its current
        // `.backend`, which the router leaves at whatever the last call used
        // (often `.cpu`, after a one-item search query): point every encoder
        // at the GPU handle first, or a reload leaves the old weights on the
        // device. Under the mutex, with the CUDA context bound to this thread,
        // like any other device call. (Callers have already stopped all users.)
        self.mutex.lockUncancelable(self.io);
        const gpu = self.backendFor(std.math.maxInt(usize)); // .cpu without a GPU
        self.bindThreadFor(gpu);
        if (self.text)   |*e| { e.backend = gpu; e.deinit(); }
        if (self.xmodal) |*e| { e.backend = gpu; e.deinit(); }
        if (self.image)  |*e| { e.backend = gpu; e.deinit(); }
        if (self.cuda)   |be|  be.deinit();
        if (self.vk)     |ctx| ctx.deinit();
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn hasPromptEncoder(self: *const Embedder) bool {
        return self.text != null;
    }

    pub fn hasVisualEncoder(self: *const Embedder) bool {
        return self.image != null;
    }

    /// True when a GPU handle is active. Scan uses this to decide how many embed
    /// consumers to spawn (extra consumers only help overlap CPU decode with the
    /// serial GPU batch).
    pub fn hasGpu(self: *const Embedder) bool {
        return self.cuda != null or self.vk != null;
    }

    /// Backend for a batch of `n` items: the configured GPU when the batch is big
    /// enough and a handle exists, otherwise CPU.
    fn backendFor(self: *const Embedder, n: usize) tp.embed.Backend {
        if (n >= self.threshold) {
            if (self.cuda) |be|  return .{ .cuda = be };
            if (self.vk)   |ctx| return .{ .vulkan = ctx };
        }
        return .cpu;
    }

    /// CUDA driver contexts are per-thread state (TP's Backend.bindThread): a
    /// thread issuing device work must make the context current first, or the
    /// driver returns INVALID_CONTEXT. We create the backend on one thread but
    /// drive embeds from io worker threads that vary per call, so bind on the
    /// calling thread right before each CUDA dispatch (under the embed mutex, so
    /// only this thread touches the context). Cheap + idempotent; no-op otherwise.
    fn bindThreadFor(_: *const Embedder, backend: tp.embed.Backend) void {
        switch (backend) {
            .cuda => |be| be.bindThread(),
            else => {},
        }
    }

    // ── Public embed functions ────────────────────────────────────────────────

    /// True if `text` is short enough to embed on the gemma text encoder without
    /// overrunning its sliding window. Callers must skip prompts that don't fit —
    /// TensorPencil currently asserts (panics) on an over-window input. Read-only
    /// tokenize (encode uses its own arena), so this is safe to call concurrently
    /// without the embed mutex. Returns false when no text encoder is loaded.
    pub fn promptFits(self: *Embedder, allocator: std.mem.Allocator, text: []const u8) bool {
        const enc = if (self.text) |*e| e else return false;
        // A token spans >= 1 byte, so token count <= byte count. If the raw text is
        // already within the content budget by bytes, it fits by tokens too — skip
        // the tokenize (the common short-prompt case). The façade tokenizes once at
        // embed time, so only prompts over-budget *by bytes* are ever encoded twice.
        if (text.len <= GEMMA_CONTENT_BUDGET) return true;
        // Precise check needs the tokenizer, which is NOT safe to run concurrently
        // with other encodes — the embed path tokenizes under this same mutex, so
        // serialize here too (this path only hits rare over-budget-by-bytes texts).
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var content: std.ArrayList(u32) = .empty;
        defer content.deinit(allocator);
        enc.tok.encode(allocator, text, &content) catch return false;
        return content.items.len <= GEMMA_CONTENT_BUDGET;
    }

    /// Embed a *search query* for prompt search (gemma, 768-dim, L2-norm).
    pub fn embedPromptQuery(self: *Embedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const enc = if (self.text) |*e| e else return error.ModelNotLoaded;
        if (!self.promptFits(allocator, text)) return error.PromptTooLong;
        return self.embedTextOne(enc, allocator, text, .query);
    }

    /// Split a prompt into at most `max_prompt_chunks` texts of `chunk_tokens`
    /// tokens each (`prompt_chunk_tokens` for real use), cut on token
    /// boundaries. A chunk that doesn't fit the budget once re-tokenized is
    /// dropped. Caller owns them.
    pub fn promptChunks(self: *Embedder, allocator: std.mem.Allocator, text: []const u8, chunk_tokens: usize) ![][]u8 {
        const enc = if (self.text) |*e| e else return error.ModelNotLoaded;
        var chunks: std.ArrayList([]u8) = .empty;
        errdefer {
            for (chunks.items) |c| allocator.free(c);
            chunks.deinit(allocator);
        }
        {
            // The tokenizer isn't safe to run concurrently with an encode.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(allocator);
            try enc.tok.encode(allocator, text, &ids);
            const n = promptChunkCount(ids.items.len, chunk_tokens);
            for (0..n) |i| {
                const run = ids.items[i * chunk_tokens .. @min(ids.items.len, (i + 1) * chunk_tokens)];
                const piece = try enc.tok.decodeAlloc(allocator, run);
                errdefer allocator.free(piece);
                try chunks.append(allocator, piece);
            }
        }
        // Checked outside the lock (promptFits takes it itself).
        var kept: usize = 0;
        for (chunks.items) |c| {
            if (self.promptFits(allocator, c)) {
                chunks.items[kept] = c;
                kept += 1;
            } else {
                log.warn("prompt chunk over the budget after re-tokenizing; dropped", .{});
                allocator.free(c);
            }
        }
        chunks.shrinkRetainingCapacity(kept);
        return chunks.toOwnedSlice(allocator);
    }

    /// Embed an index-time prompt *document* (gemma, 768-dim, L2-norm).
    /// One over the token budget is embedded from its chunks, averaged
    /// (`promptChunks`, `meanNormalized`).
    pub fn embedPrompt(self: *Embedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const enc = if (self.text) |*e| e else return error.ModelNotLoaded;
        if (self.promptFits(allocator, text)) return self.embedTextOne(enc, allocator, text, .document);
        return self.embedPromptChunked(allocator, text, prompt_chunk_tokens);
    }

    /// Embed `text` from its chunks of `chunk_tokens` tokens, averaged.
    pub fn embedPromptChunked(self: *Embedder, allocator: std.mem.Allocator, text: []const u8, chunk_tokens: usize) ![]f32 {
        const chunks = try self.promptChunks(allocator, text, chunk_tokens);
        defer {
            for (chunks) |c| allocator.free(c);
            allocator.free(chunks);
        }
        if (chunks.len == 0) return error.PromptTooLong;
        // On the GPU whenever there is one, however few chunks: each is a
        // near-full window, far more work than the short single items the
        // CPU threshold is for (a 2-chunk prompt took ~7 s on the CPU).
        const vecs = try self.embedDocuments(allocator, @ptrCast(chunks), std.math.maxInt(usize));
        defer {
            for (vecs) |v| allocator.free(v);
            allocator.free(vecs);
        }
        return meanNormalized(allocator, @ptrCast(vecs));
    }

    /// Embed a query text for visual search (siglip2 text encoder, 768-dim, L2-norm).
    pub fn embedQueryForVisual(self: *Embedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const enc = if (self.xmodal) |*e| e else return error.ModelNotLoaded;
        return self.embedTextOne(enc, allocator, text, .query); // role ignored (symmetric)
    }

    /// Embed an image file (siglip2 visual, 768-dim, L2-norm). Caller owns result.
    pub fn embedImage(self: *Embedder, allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
        const enc = if (self.image) |*e| e else return error.ModelNotLoaded;
        const tensor = try loadImageAsTensor(allocator, path); // CPU decode, no lock
        defer allocator.free(tensor);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const backend = self.backendFor(1);
        enc.backend = backend;
        self.bindThreadFor(backend);
        return enc.embedImage(allocator, tensor);
    }

    // ── Batch inference (true batched forwards via TensorPencil) ────────────────

    /// Embed a batch of index-time prompt documents (gemma). One caller-owned
    /// vector per input (free each vec then the outer slice). Routes to the GPU
    /// when `texts.len >= threshold`. Every text MUST pass `promptFits` first —
    /// an over-window input panics inside TensorPencil (this keeps the batched
    /// result aligned 1:1 with the caller's ids).
    pub fn embedPromptBatch(
        self:      *Embedder,
        allocator: std.mem.Allocator,
        texts:     []const []const u8,
    ) ![][]f32 {
        return self.embedDocuments(allocator, texts, texts.len);
    }

    /// `embedPromptBatch`, routed as if it were a batch of `route_n` items
    /// (see `backendFor`).
    fn embedDocuments(self: *Embedder, allocator: std.mem.Allocator, texts: []const []const u8, route_n: usize) ![][]f32 {
        const enc = if (self.text) |*e| e else return error.ModelNotLoaded;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const backend = self.backendFor(route_n);
        enc.backend = backend;
        self.bindThreadFor(backend);
        return enc.embedTextBatch(allocator, texts, .{ .role = .document });
    }

    /// Embed a batch of images (siglip2 visual). One caller-owned vector per input.
    /// Decodes every path to a CHW tensor (CPU, no lock) before the batched
    /// forward. Routes to the GPU when `paths.len >= threshold`.
    pub fn embedImageBatch(
        self:      *Embedder,
        allocator: std.mem.Allocator,
        paths:     []const [:0]const u8,
        stop:      ?*std.atomic.Value(bool),
    ) ![][]f32 {
        const enc = if (self.image) |*e| e else return error.ModelNotLoaded;
        const n = paths.len;

        // One result slot per input path; an empty slice means "skipped" (its image
        // failed to decode). Caller stores non-empty vecs and skips empties.
        const out = try allocator.alloc([]f32, n);
        for (out) |*v| v.* = &.{};
        errdefer {
            for (out) |v| if (v.len != 0) allocator.free(v);
            allocator.free(out);
        }

        // Decode into a compact list of successfully-decoded tensors + their
        // original slot indices. A failed decode is skipped (its slot stays empty)
        // so one bad file cannot sink the whole GPU batch. Decode runs without the
        // embed lock; cross-batch decode parallelism comes from the scan's multiple
        // embed consumers (not a nested io group — that is not safe to spawn from
        // inside a consumer task).
        const batch = try allocator.alloc([]const f32, n);
        const idx = try allocator.alloc(usize, n);
        var m: usize = 0;
        defer {
            for (batch[0..m]) |t| allocator.free(t);
            allocator.free(batch);
            allocator.free(idx);
        }
        for (paths, 0..) |p, i| {
            // Stop decoding promptly on close/cancel (decode is the slow part).
            if (stop) |s| if (s.load(.acquire)) break;
            // Not embedded; the next scan queues it again.
            const t = loadImageAsTensor(allocator, p) catch |err| {
                log.warn("embed {s}: {}", .{ std.Io.Dir.path.basename(p), err });
                continue;
            };
            batch[m] = t;
            idx[m] = i;
            m += 1;
        }
        // Skip the GPU forward entirely if stopped; decoded tensors are freed by the
        // defer above, and `out` (all-empty here) is returned.
        if (m == 0 or (stop != null and stop.?.load(.acquire))) return out;

        // One batched forward over the decoded images (GPU when m >= threshold).
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const backend = self.backendFor(m);
        enc.backend = backend;
        self.bindThreadFor(backend);
        const got = try enc.embedImageBatch(allocator, batch[0..m]);
        // Scatter results to their original slots; each vec is moved into `out`,
        // so free only the transient outer slice `got`.
        defer allocator.free(got);
        for (0..m) |k| out[idx[k]] = got[k];
        return out;
    }

    // ── Internal ────────────────────────────────────────────────────────────────

    fn embedTextOne(
        self:      *Embedder,
        enc:       *tp.embed.TextEncoder,
        allocator: std.mem.Allocator,
        text:      []const u8,
        role:      tp.embed.Role,
    ) ![]f32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const backend = self.backendFor(1);
        enc.backend = backend;
        self.bindThreadFor(backend);
        return enc.embedText(allocator, text, .{ .role = role });
    }
};

// ── Image loading ─────────────────────────────────────────────────────────────

/// The SigLIP2 input pixels for `path`: packed RGB8, 224 x 224. Caller owns
/// them. A video stands in with its first frame (the image loader can't open
/// one): it gets an image embedding for visual search like any image.
pub fn siglipPixels(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    if (media.isVideoFile(path)) {
        // Decoded at twice the input size: plenty for a 224² squash.
        const dec = try video.Decoder.open(path, 2 * SIGLIP_IMAGE_SIZE);
        defer dec.close();
        const frame = (try dec.next(allocator, null)) orelse return error.VideoDecodeFailed;
        defer allocator.free(frame.pixels);
        if (vips.diffkeep_rgba_to_rgb_square(frame.pixels.ptr, @intCast(frame.width), @intCast(frame.height),
            SIGLIP_IMAGE_SIZE, &buf, &len) != 0) return error.VipsLoadFailed;
    } else if (vips.diffkeep_image_to_rgb_square(path.ptr, SIGLIP_IMAGE_SIZE, &buf, &len) != 0)
        return error.VipsLoadFailed;
    defer vips.diffkeep_vips_free(buf);
    // A real check, not an assert: ReleaseFast would compile that out and
    // read past a buffer of any other layout.
    if (len != SIGLIP_IMAGE_SIZE * SIGLIP_IMAGE_SIZE * 3) return error.BadPixelLayout;
    return allocator.dupe(u8, @as([*]const u8, @ptrCast(buf.?))[0..len]);
}

/// Decode+resize `path` to the SigLIP2 preprocessed tensor: 224², /255, mean/std
/// 0.5, planar CHW `f32` ([3*224*224]) — exactly what TensorPencil's visual tower
/// expects. Caller owns the result.
fn loadImageAsTensor(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    const pixels = try siglipPixels(allocator, path);
    defer allocator.free(pixels);
    const n_pixels = SIGLIP_IMAGE_SIZE * SIGLIP_IMAGE_SIZE;

    const tensor = try allocator.alloc(f32, 3 * n_pixels);
    for (0..n_pixels) |p| {
        for (0..3) |c| {
            const raw: f32 = @as(f32, @floatFromInt(pixels[p * 3 + c])) / 255.0;
            tensor[c * n_pixels + p] = (raw - SIGLIP_MEAN[c]) / SIGLIP_STD[c];
        }
    }
    return tensor;
}
