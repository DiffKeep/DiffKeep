/// ONNX Runtime + SigLIP2 B-16 search quality test.
///
/// Usage:
///   test_onnx_search <images_dir> <model_dir>
///
/// <model_dir> should contain the Immich SigLIP2 export layout:
///   visual/model.onnx    — image encoder
///   textual/model.onnx   — text encoder
///   tokenizer.json       — HuggingFace tokenizer (Unigram/Metaspace)
///
/// Download models from: https://huggingface.co/immich-app/ViT-B-16-SigLIP2__webli
///
/// Options:
///   --chunk-size N   max tokens per prompt chunk (default: 60)
///   --top-k N        candidates to show per query (default: 5)
const std = @import("std");
const ort_c = @import("onnxruntime_c");
const png = @import("image/png-data.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const ParseResult = @import("parse/comfy.zig").ParseResult;

const vips_c = @cImport(@cInclude("vips_helper.h"));

// ── Constants ─────────────────────────────────────────────────────────────────

const SIGLIP_IMAGE_SIZE = 224;
const SIGLIP_MAX_TOKENS = 64;
const SIGLIP_MEAN: [3]f32 = .{ 0.5, 0.5, 0.5 };
const SIGLIP_STD: [3]f32  = .{ 0.5, 0.5, 0.5 };

// ── Test queries (same set as test_cross_modal_search for apples-to-apples) ───

const Query = struct {
    text:     []const u8,
    relevant: []const []const u8,
};

const QUERIES = [_]Query{
    .{ .text = "sword",         .relevant = &.{"05.11.57-80085_00001_.png"} },
    .{ .text = "cloak",         .relevant = &.{"05.11.57-80085_00001_.png", "18.30.39-80085_00001_.png"} },
    .{ .text = "unicorn",       .relevant = &.{"12.04.07-80085_00001_.png"} },
    .{ .text = "apple",         .relevant = &.{"17.57.54-80085_00001_.png"} },
    .{ .text = "bird",          .relevant = &.{"18.04.11-80085_00001_.png"} },
    .{ .text = "cat",           .relevant = &.{"18.17.12-80085_00001_.png"} },
    .{ .text = "butterfly",     .relevant = &.{"21.20.13-80085_00001_.png"} },
    .{ .text = "cold",          .relevant = &.{"21.01.42-80085_00001_.png"} },
    .{ .text = "ramen",         .relevant = &.{"18.12.42-80085_00001_.png"} },
    .{ .text = "fantasy",       .relevant = &.{"05.11.57-80085_00001_.png", "12.04.07-80085_00001_.png"} },
    .{ .text = "flower",        .relevant = &.{"21.20.13-80085_00001_.png", "12.04.07-80085_00001_.png"} },
    .{ .text = "dock",          .relevant = &.{"18.11.21-80085_00001_.png", "18.36.29-80085_00001_.png"} },
    .{ .text = "japan",         .relevant = &.{"18.30.13-80085_00001_.png", "18.12.42-80085_00001_.png"} },
    .{ .text = "water",         .relevant = &.{"18.11.21-80085_00001_.png", "18.32.27-80085_00001_.png"} },
};

// ── BpeTokenizer ──────────────────────────────────────────────────────────────
//
// BPE tokenizer reading HuggingFace tokenizer.json.
// Normalisation: replace ' ' with ▁ (matching this model's normalizer config).
// Merge algorithm: standard BPE — repeatedly merge the lowest-rank adjacent pair.

const BpeTokenizer = struct {
    allocator:    std.mem.Allocator,
    vocab:        std.StringHashMap(u32), // piece → id (pieces are owned)
    merge_ranks:  std.StringHashMap(u32), // "a\x00b" → rank (keys are owned)
    unk_id:       u32,

    const METASPACE = "\xe2\x96\x81"; // U+2581 ▁

    /// Initialise from tokenizer.json bytes (HuggingFace format, BPE model).
    /// Parses the full JSON tree; expect ~200 MB peak allocation for a 34 MB file.
    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !BpeTokenizer {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const model = parsed.value.object.get("model") orelse return error.MissingModelKey;
        const vocab_obj = model.object.get("vocab") orelse return error.MissingVocabKey;
        const merges_arr = model.object.get("merges") orelse return error.MissingMergesKey;
        const unk_tok = model.object.get("unk_token") orelse return error.MissingUnkToken;

        // Build vocab map
        var vocab = std.StringHashMap(u32).init(allocator);
        errdefer {
            var it = vocab.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            vocab.deinit();
        }
        try vocab.ensureTotalCapacity(@intCast(vocab_obj.object.count()));

        var vocab_it = vocab_obj.object.iterator();
        while (vocab_it.next()) |kv| {
            const piece = try allocator.dupe(u8, kv.key_ptr.*);
            vocab.putAssumeCapacityNoClobber(piece, @intCast(kv.value_ptr.integer));
        }

        const unk_id = vocab.get(unk_tok.string) orelse 0;

        // Build merge ranks map (key = "piece_a\x00piece_b")
        var merge_ranks = std.StringHashMap(u32).init(allocator);
        errdefer {
            var it = merge_ranks.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            merge_ranks.deinit();
        }
        try merge_ranks.ensureTotalCapacity(@intCast(merges_arr.array.items.len));

        for (merges_arr.array.items, 0..) |entry, rank| {
            const a = entry.array.items[0].string;
            const b = entry.array.items[1].string;
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ a, b });
            merge_ranks.putAssumeCapacityNoClobber(key, @intCast(rank));
        }

        return .{
            .allocator   = allocator,
            .vocab       = vocab,
            .merge_ranks = merge_ranks,
            .unk_id      = unk_id,
        };
    }

    pub fn deinit(self: *BpeTokenizer) void {
        var kit = self.vocab.iterator();
        while (kit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.vocab.deinit();

        var mit = self.merge_ranks.iterator();
        while (mit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.merge_ranks.deinit();
    }

    /// Encode text → int64 token IDs, capped at max_tokens. Caller owns slice.
    pub fn encode(
        self: *const BpeTokenizer,
        allocator: std.mem.Allocator,
        text: []const u8,
        max_tokens: usize,
    ) ![]i64 {
        const pieces = try self.bpeEncode(allocator, text);
        defer {
            for (pieces) |p| allocator.free(p);
            allocator.free(pieces);
        }

        const n = @min(pieces.len, max_tokens);
        const ids = try allocator.alloc(i64, n);
        for (pieces[0..n], ids) |p, *id| {
            id.* = @intCast(self.vocab.get(p) orelse self.unk_id);
        }
        return ids;
    }

    /// Count tokens without building the ID array.
    pub fn countTokens(self: *const BpeTokenizer, text: []const u8) !usize {
        const pieces = try self.bpeEncode(self.allocator, text);
        defer {
            for (pieces) |p| self.allocator.free(p);
            self.allocator.free(pieces);
        }
        return pieces.len;
    }

    /// Core BPE: returns owned slice of owned piece strings.
    fn bpeEncode(self: *const BpeTokenizer, allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
        // Normalise: replace ASCII space with ▁
        var norm: std.ArrayList(u8) = .empty;
        defer norm.deinit(allocator);
        for (text) |b| {
            if (b == ' ') try norm.appendSlice(allocator, METASPACE)
            else try norm.append(allocator, b);
        }
        if (norm.items.len == 0) return allocator.alloc([]const u8, 0);

        // Split into individual UTF-8 codepoints as owned strings
        var tokens: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }

        var i: usize = 0;
        while (i < norm.items.len) {
            const cp_len = utf8CharLen(norm.items[i]);
            const end = @min(i + cp_len, norm.items.len);
            try tokens.append(allocator, try allocator.dupe(u8, norm.items[i..end]));
            i = end;
        }

        // BPE merge loop: repeatedly find + apply the lowest-rank adjacent pair
        while (tokens.items.len > 1) {
            var best_rank: u32 = std.math.maxInt(u32);
            var best_idx:  usize = 0;
            var found = false;

            for (0..tokens.items.len - 1) |j| {
                var key_buf: [512]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{
                    tokens.items[j], tokens.items[j + 1],
                }) catch continue; // skip if pair too long for buffer
                if (self.merge_ranks.get(key)) |rank| {
                    if (rank < best_rank) {
                        best_rank = rank;
                        best_idx = j;
                        found = true;
                    }
                }
            }

            if (!found) break;

            // Merge tokens[best_idx] and tokens[best_idx+1] in place
            const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{
                tokens.items[best_idx], tokens.items[best_idx + 1],
            });
            allocator.free(tokens.items[best_idx]);
            allocator.free(tokens.items[best_idx + 1]);
            tokens.items[best_idx] = merged;
            _ = tokens.orderedRemove(best_idx + 1);
        }

        return tokens.toOwnedSlice(allocator);
    }

    fn utf8CharLen(first_byte: u8) usize {
        if (first_byte & 0x80 == 0)   return 1;
        if (first_byte & 0xE0 == 0xC0) return 2;
        if (first_byte & 0xF0 == 0xE0) return 3;
        return 4;
    }
};

// ── Sentence-aware text chunker ───────────────────────────────────────────────
//
// Splits a long prompt into chunks that each fit within max_tokens.
// Prefers splitting at: paragraph breaks > sentence ends > comma phrases > words.
// Returns a slice of owned strings; caller frees each element and the slice.

pub fn chunkText(
    allocator: std.mem.Allocator,
    text: []const u8,
    tokenizer: *const BpeTokenizer,
    max_tokens: usize,
) ![][]const u8 {
    // Stage 1: split into candidate segments at semantic boundaries
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    try splitIntoSegments(allocator, text, &segments);

    // Stage 2: merge segments greedily until max_tokens is approached
    var chunks: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (chunks.items) |c| allocator.free(c);
        chunks.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var current_tokens: usize = 0;

    for (segments.items) |seg| {
        const seg_tokens = tokenizer.countTokens(seg) catch continue;
        if (seg_tokens == 0) continue;

        if (current_tokens + seg_tokens > max_tokens and current_tokens > 0) {
            // Flush current chunk
            try chunks.append(allocator, try allocator.dupe(u8, current.items));
            current.clearRetainingCapacity();
            current_tokens = 0;
        }

        // If a single segment exceeds max_tokens, sub-split at word boundaries
        if (seg_tokens > max_tokens) {
            const sub = try splitLongSegment(allocator, seg, tokenizer, max_tokens);
            defer {
                for (sub) |s| allocator.free(s);
                allocator.free(sub);
            }
            for (sub) |s| try chunks.append(allocator, try allocator.dupe(u8, s));
            continue;
        }

        if (current.items.len > 0) {
            try current.append(allocator, ' ');
        }
        try current.appendSlice(allocator, seg);
        current_tokens += seg_tokens;
    }

    if (current.items.len > 0) {
        try chunks.append(allocator, try allocator.dupe(u8, current.items));
    }

    return chunks.toOwnedSlice(allocator);
}

/// Split text into sentence/phrase-level segments (does not allocate new strings,
/// returns slices into `text`).
fn splitIntoSegments(
    allocator: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const c = text[i];

        // Paragraph break: highest priority split
        if (c == '\n' and i + 1 < text.len and text[i + 1] == '\n') {
            const seg = std.mem.trim(u8, text[start..i], " \t\n\r");
            if (seg.len > 0) try out.append(allocator, seg);
            i += 2;
            // Skip any additional blank lines
            while (i < text.len and text[i] == '\n') i += 1;
            start = i;
            continue;
        }

        // Single newline
        if (c == '\n') {
            const seg = std.mem.trim(u8, text[start..i], " \t\n\r");
            if (seg.len > 0) try out.append(allocator, seg);
            start = i + 1;
            i += 1;
            continue;
        }

        // Sentence end: .  !  ?  followed by space (guard against abbreviations)
        if ((c == '.' or c == '!' or c == '?') and i + 1 < text.len and text[i + 1] == ' ') {
            // Skip likely abbreviations: single uppercase letter before dot
            const is_abbr = c == '.' and i > 0 and
                ((text[i - 1] >= 'A' and text[i - 1] <= 'Z') or
                 (i > 1 and text[i - 2] == ' ' and text[i - 1] >= 'A' and text[i - 1] <= 'Z'));
            if (!is_abbr) {
                const seg = std.mem.trim(u8, text[start .. i + 1], " \t");
                if (seg.len > 0) try out.append(allocator, seg);
                start = i + 2;
                i += 2;
                continue;
            }
        }

        // Comma phrase: split on ", " only — keeps the comma with the preceding segment
        if (c == ',' and i + 1 < text.len and text[i + 1] == ' ') {
            const seg = std.mem.trim(u8, text[start .. i + 1], " \t");
            if (seg.len > 0) try out.append(allocator, seg);
            start = i + 2;
            i += 2;
            continue;
        }

        i += 1;
    }

    // Remaining tail
    const seg = std.mem.trim(u8, text[start..], " \t\n\r");
    if (seg.len > 0) try out.append(allocator, seg);
}

/// Sub-split a segment that is too long to fit in max_tokens by splitting at spaces.
fn splitLongSegment(
    allocator: std.mem.Allocator,
    seg: []const u8,
    tokenizer: *const BpeTokenizer,
    max_tokens: usize,
) ![][]const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (chunks.items) |c| allocator.free(c);
        chunks.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var current_tokens: usize = 0;

    var words = std.mem.splitScalar(u8, seg, ' ');
    while (words.next()) |word| {
        const word_tokens = tokenizer.countTokens(word) catch 1;
        if (current_tokens + word_tokens > max_tokens and current_tokens > 0) {
            try chunks.append(allocator, try allocator.dupe(u8, current.items));
            current.clearRetainingCapacity();
            current_tokens = 0;
        }
        if (current.items.len > 0) try current.append(allocator, ' ');
        try current.appendSlice(allocator, word);
        current_tokens += word_tokens;
    }
    if (current.items.len > 0) {
        try chunks.append(allocator, try allocator.dupe(u8, current.items));
    }
    return chunks.toOwnedSlice(allocator);
}

// ── Image preprocessing ───────────────────────────────────────────────────────

/// Load image from path, resize/crop to SIGLIP_IMAGE_SIZE × SIGLIP_IMAGE_SIZE,
/// and return a CHW float32 tensor normalised to [-1, 1].
/// Caller owns the returned slice (3 * H * W f32 values).
fn loadImageAsTensor(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    if (vips_c.diffkeep_image_to_rgb_square(path.ptr, SIGLIP_IMAGE_SIZE, &buf, &len) != 0)
        return error.VipsLoadFailed;
    defer vips_c.diffkeep_vips_free(buf);

    const pixels: [*]const u8 = @ptrCast(buf.?);
    const n_pixels = SIGLIP_IMAGE_SIZE * SIGLIP_IMAGE_SIZE;
    std.debug.assert(len == n_pixels * 3);

    // Convert HWC uint8 → CHW float32, normalise to [-1, 1]
    const tensor = try allocator.alloc(f32, 3 * n_pixels);
    for (0..n_pixels) |p| {
        for (0..3) |c| {
            const raw: f32 = @as(f32, @floatFromInt(pixels[p * 3 + c])) / 255.0;
            tensor[c * n_pixels + p] = (raw - SIGLIP_MEAN[c]) / SIGLIP_STD[c];
        }
    }
    return tensor;
}

// ── ORT helpers ───────────────────────────────────────────────────────────────

const OrtApi = ort_c.struct_OrtApi;

fn ortCheck(status: ?*ort_c.OrtStatus, api: *const OrtApi) !void {
    const s = status orelse return;
    const msg = api.GetErrorMessage.?(s);
    std.log.err("ORT error: {s}", .{msg});
    api.ReleaseStatus.?(s);
    return error.OrtError;
}

// ── SigLIP2 encoder ───────────────────────────────────────────────────────────

const SigLip2Encoder = struct {
    allocator: std.mem.Allocator,
    api:       *const OrtApi,
    env:       *ort_c.OrtEnv,
    opts:      *ort_c.OrtSessionOptions,
    visual:    *ort_c.OrtSession,
    textual:   *ort_c.OrtSession,
    mem_info:  *ort_c.OrtMemoryInfo,

    pub fn init(
        allocator: std.mem.Allocator,
        visual_path: [:0]const u8,
        textual_path: [:0]const u8,
    ) !SigLip2Encoder {
        const api: *const OrtApi = @ptrCast(ort_c.OrtGetApiBase().*.GetApi.?(ort_c.ORT_API_VERSION).?);

        var env: ?*ort_c.OrtEnv = null;
        try ortCheck(api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "siglip", &env), api);
        errdefer api.ReleaseEnv.?(env);

        var opts: ?*ort_c.OrtSessionOptions = null;
        try ortCheck(api.CreateSessionOptions.?(&opts), api);
        errdefer api.ReleaseSessionOptions.?(opts);

        // Enable all available optimisations
        try ortCheck(api.SetSessionGraphOptimizationLevel.?(opts, ort_c.ORT_ENABLE_ALL), api);

        var vis: ?*ort_c.OrtSession = null;
        try ortCheck(api.CreateSession.?(env, visual_path.ptr, opts, &vis), api);
        errdefer api.ReleaseSession.?(vis);

        var txt: ?*ort_c.OrtSession = null;
        try ortCheck(api.CreateSession.?(env, textual_path.ptr, opts, &txt), api);
        errdefer api.ReleaseSession.?(txt);

        var mem: ?*ort_c.OrtMemoryInfo = null;
        try ortCheck(api.CreateCpuMemoryInfo.?(ort_c.OrtDeviceAllocator, ort_c.OrtMemTypeDefault, &mem), api);

        return .{
            .allocator = allocator,
            .api       = api,
            .env       = env.?,
            .opts      = opts.?,
            .visual    = vis.?,
            .textual   = txt.?,
            .mem_info  = mem.?,
        };
    }

    pub fn deinit(self: *SigLip2Encoder) void {
        self.api.ReleaseMemoryInfo.?(self.mem_info);
        self.api.ReleaseSession.?(self.textual);
        self.api.ReleaseSession.?(self.visual);
        self.api.ReleaseSessionOptions.?(self.opts);
        self.api.ReleaseEnv.?(self.env);
    }

    /// Embed a single image from file path. Returns L2-normalised embedding.
    /// Caller owns the returned slice.
    pub fn embedImage(self: *SigLip2Encoder, path: [:0]const u8) ![]f32 {
        const tensor_data = try loadImageAsTensor(self.allocator, path);
        defer self.allocator.free(tensor_data);

        const shape = [_]i64{ 1, 3, SIGLIP_IMAGE_SIZE, SIGLIP_IMAGE_SIZE };
        var input: ?*ort_c.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info,
            tensor_data.ptr,
            tensor_data.len * @sizeOf(f32),
            &shape,
            shape.len,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &input,
        ), self.api);
        defer self.api.ReleaseValue.?(input);

        const input_names  = [_][*:0]const u8{"image"};
        const output_names = [_][*:0]const u8{"embedding"};
        var output: ?*ort_c.OrtValue = null;

        try ortCheck(self.api.Run.?(
            self.visual, null,
            &input_names, &[_]?*const ort_c.OrtValue{input}, 1,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        return self.extractEmbedding(output.?);
    }

    /// Embed a text chunk. Returns L2-normalised embedding.
    /// Caller owns the returned slice.
    pub fn embedText(
        self: *SigLip2Encoder,
        tokenizer: *const BpeTokenizer,
        text: []const u8,
        max_tokens: usize,
    ) ![]f32 {
        // Encode (capped at max_tokens), then pad to model's fixed SIGLIP_MAX_TOKENS length
        const ids64 = try tokenizer.encode(self.allocator, text, max_tokens);
        defer self.allocator.free(ids64);

        var ids32: [SIGLIP_MAX_TOKENS]i32 = @splat(0);
        for (ids64, 0..) |src, k| ids32[k] = @intCast(src);

        const seq_shape = [_]i64{ 1, SIGLIP_MAX_TOKENS };

        var ids_val: ?*ort_c.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, &ids32, ids32.len * @sizeOf(i32),
            &seq_shape, seq_shape.len,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &ids_val,
        ), self.api);
        defer self.api.ReleaseValue.?(ids_val);

        const input_names  = [_][*:0]const u8{"text"};
        const output_names = [_][*:0]const u8{"embedding"};
        var output: ?*ort_c.OrtValue = null;

        try ortCheck(self.api.Run.?(
            self.textual, null,
            &input_names, &[_]?*const ort_c.OrtValue{ids_val}, 1,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        return self.extractEmbedding(output.?);
    }

    fn extractEmbedding(self: *SigLip2Encoder, val: *ort_c.OrtValue) ![]f32 {
        var raw: ?*anyopaque = null;
        try ortCheck(self.api.GetTensorMutableData.?(val, &raw), self.api);

        var info: ?*ort_c.OrtTensorTypeAndShapeInfo = null;
        try ortCheck(self.api.GetTensorTypeAndShape.?(val, &info), self.api);
        defer self.api.ReleaseTensorTypeAndShapeInfo.?(info);

        var n_elem: usize = 0;
        try ortCheck(self.api.GetTensorShapeElementCount.?(info, &n_elem), self.api);

        const src: [*]const f32 = @ptrCast(@alignCast(raw.?));
        const result = try self.allocator.dupe(f32, src[0..n_elem]);
        l2Normalize(result);
        return result;
    }
};

// ── Search helpers ────────────────────────────────────────────────────────────

fn l2Normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    const norm = @sqrt(sum);
    if (norm > 0) {
        for (v) |*x| x.* /= norm;
    }
}

fn dot(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    var s: f32 = 0;
    for (a[0..len], b[0..len]) |av, bv| s += av * bv;
    return s;
}

/// Max cosine similarity between query and all chunks for one image.
fn maxChunkSim(query: []const f32, chunks: []const []const f32) f32 {
    var best: f32 = -std.math.floatMax(f32);
    for (chunks) |c| {
        const s = dot(query, c);
        if (s > best) best = s;
    }
    return best;
}

fn insertionSortDesc(ranking: []usize, scores: []f32) void {
    for (1..ranking.len) |i| {
        const key = ranking[i];
        var j = i;
        while (j > 0 and scores[ranking[j - 1]] < scores[key]) {
            ranking[j] = ranking[j - 1];
            j -= 1;
        }
        ranking[j] = key;
    }
}

// ── Image entry ───────────────────────────────────────────────────────────────

const ImageEntry = struct {
    path:         []const u8, // owned
    prompt:       []const u8, // owned
    img_emb:      []f32,      // owned, L2-normalised
    chunk_embs:   [][]f32,    // owned, each L2-normalised

    fn deinit(self: ImageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prompt);
        allocator.free(self.img_emb);
        for (self.chunk_embs) |e| allocator.free(e);
        allocator.free(self.chunk_embs);
    }
};

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const images_dir = args.next() orelse return usage();
    const model_dir  = args.next() orelse return usage();

    var max_chunk_tokens: usize = SIGLIP_MAX_TOKENS - 4; // leave room for special tokens
    var top_k: usize = 5;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--chunk-size")) {
            const v = args.next() orelse return argErr("--chunk-size requires a value");
            max_chunk_tokens = std.fmt.parseInt(usize, v, 10) catch return argErr("--chunk-size: invalid integer");
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            const v = args.next() orelse return argErr("--top-k requires a value");
            top_k = std.fmt.parseInt(usize, v, 10) catch return argErr("--top-k: invalid integer");
        }
    }

    // ── Build model paths ─────────────────────────────────────────────────
    const visual_path = blk: {
        const s = try std.fmt.allocPrint(allocator, "{s}/visual/model.onnx", .{model_dir});
        defer allocator.free(s);
        break :blk try allocator.dupeZ(u8, s);
    };
    defer allocator.free(visual_path);
    const textual_path = blk: {
        const s = try std.fmt.allocPrint(allocator, "{s}/textual/model.onnx", .{model_dir});
        defer allocator.free(s);
        break :blk try allocator.dupeZ(u8, s);
    };
    defer allocator.free(textual_path);
    const tok_path = try std.fmt.allocPrint(allocator, "{s}/textual/tokenizer.json", .{model_dir});
    defer allocator.free(tok_path);

    // ── Load tokenizer ────────────────────────────────────────────────────
    try println(io, "Loading tokenizer from {s}...", .{tok_path});
    const tok_json = blk: {
        var f = try std.Io.Dir.cwd().openFile(io, tok_path, .{});
        defer f.close(io);
        const sz = try f.length(io);
        const buf = try allocator.alloc(u8, sz);
        _ = try f.readPositionalAll(io, buf, 0);
        break :blk buf;
    };
    defer allocator.free(tok_json);

    var tokenizer = try BpeTokenizer.initFromJson(allocator, tok_json);
    defer tokenizer.deinit();
    try println(io, "Tokenizer loaded: {d} vocab entries, {d} merge rules",
        .{ tokenizer.vocab.count(), tokenizer.merge_ranks.count() });

    // ── Load ONNX sessions ────────────────────────────────────────────────
    try println(io, "Loading models...", .{});
    var encoder = try SigLip2Encoder.init(allocator, visual_path, textual_path);
    defer encoder.deinit();
    try println(io, "Models loaded.", .{});

    // ── Scan images ───────────────────────────────────────────────────────
    var entries: std.ArrayList(ImageEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    {
        var dir = try std.Io.Dir.cwd().openDir(io, images_dir, .{ .iterate = true });
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |de| {
            if (de.kind != .file or !std.mem.endsWith(u8, de.name, ".png")) continue;

            const full = try std.fs.path.join(allocator, &.{ images_dir, de.name });
            errdefer allocator.free(full);

            const prompt = extractPrompt(allocator, io, full) catch |err| {
                std.log.warn("skip {s}: {}", .{ de.name, err });
                allocator.free(full);
                continue;
            };
            if (prompt == null) {
                std.log.warn("skip {s}: no prompt", .{de.name});
                allocator.free(full);
                continue;
            }
            errdefer allocator.free(prompt.?);

            // Image embedding
            const full_z = try allocator.dupeZ(u8, full);
            defer allocator.free(full_z);
            const t0_img = nanoNow();
            const img_emb = encoder.embedImage(full_z) catch |err| {
                std.log.warn("embed image {s}: {}", .{ de.name, err });
                allocator.free(full);
                allocator.free(prompt.?);
                continue;
            };
            const img_ms = @as(f64, @floatFromInt(nanoNow() - t0_img)) / 1e6;

            // Chunk and embed prompt
            const t0_txt = nanoNow();
            const chunks = try chunkText(allocator, prompt.?, &tokenizer, max_chunk_tokens);
            defer {
                for (chunks) |c| allocator.free(c);
                allocator.free(chunks);
            }

            var chunk_embs: std.ArrayList([]f32) = .empty;
            errdefer {
                for (chunk_embs.items) |e| allocator.free(e);
                chunk_embs.deinit(allocator);
            }
            for (chunks) |chunk| {
                const emb = try encoder.embedText(&tokenizer, chunk, max_chunk_tokens);
                try chunk_embs.append(allocator, emb);
            }
            const txt_ms = @as(f64, @floatFromInt(nanoNow() - t0_txt)) / 1e6;

            try println(io, "  {s}  img={d:.1}ms  {d} chunks={d:.1}ms", .{
                de.name, img_ms, chunks.len, txt_ms,
            });

            try entries.append(allocator, .{
                .path       = full,
                .prompt     = prompt.?,
                .img_emb    = img_emb,
                .chunk_embs = try chunk_embs.toOwnedSlice(allocator),
            });
        }
    }

    if (entries.items.len == 0) {
        try println(io, "No images found in {s}", .{images_dir});
        return;
    }
    try println(io, "\nEmbedded {d} images.\n", .{entries.items.len});

    // ── Run queries ───────────────────────────────────────────────────────
    const corpus = entries.items;
    var img_ranking  = try allocator.alloc(usize, corpus.len);
    defer allocator.free(img_ranking);
    var txt_ranking  = try allocator.alloc(usize, corpus.len);
    defer allocator.free(txt_ranking);
    var img_scores   = try allocator.alloc(f32, corpus.len);
    defer allocator.free(img_scores);
    var txt_scores   = try allocator.alloc(f32, corpus.len);
    defer allocator.free(txt_scores);

    var vis_mrr:  f32 = 0;
    var txt_mrr:  f32 = 0;
    var vis_top1: usize = 0;
    var txt_top1: usize = 0;
    var vis_top5: usize = 0;
    var txt_top5: usize = 0;

    for (QUERIES) |q| {
        const t0 = nanoNow();
        const q_emb = try encoder.embedText(&tokenizer, q.text, max_chunk_tokens);
        defer allocator.free(q_emb);
        const q_ms = @as(f64, @floatFromInt(nanoNow() - t0)) / 1e6;

        for (0..corpus.len) |i| {
            img_ranking[i] = i;
            txt_ranking[i] = i;
            img_scores[i]  = dot(q_emb, corpus[i].img_emb);
            txt_scores[i]  = maxChunkSim(q_emb, corpus[i].chunk_embs);
        }
        insertionSortDesc(img_ranking, img_scores);
        insertionSortDesc(txt_ranking, txt_scores);

        const vis_rank = bestRank(corpus, img_ranking, q.relevant);
        const txt_rank = bestRank(corpus, txt_ranking, q.relevant);

        vis_mrr  += 1.0 / @as(f32, @floatFromInt(vis_rank));
        txt_mrr  += 1.0 / @as(f32, @floatFromInt(txt_rank));
        if (vis_rank <= 1) vis_top1 += 1;
        if (txt_rank <= 1) txt_top1 += 1;
        if (vis_rank <= 5) vis_top5 += 1;
        if (txt_rank <= 5) txt_top5 += 1;

        try println(io, "query \"{s}\"  ({d:.2}ms)", .{ q.text, q_ms });
        try println(io, "  visual  best=#{d}  txt best=#{d}", .{ vis_rank, txt_rank });

        const show = @min(top_k, corpus.len);
        for (img_ranking[0..show], 0..) |idx, r| {
            const name = std.fs.path.basename(corpus[idx].path);
            try println(io, "    vis #{d} {d:.4}  {s}", .{ r + 1, img_scores[idx], name });
        }
    }

    const n: f32 = @floatFromInt(QUERIES.len);
    try println(io, "\n── Visual search (text→image embeddings) ──────────────", .{});
    try println(io, "  MRR={d:.3}  @1={d:.0}%  @5={d:.0}%", .{
        vis_mrr / n,
        @as(f32, @floatFromInt(vis_top1)) / n * 100,
        @as(f32, @floatFromInt(vis_top5)) / n * 100,
    });
    try println(io, "── Prompt chunk search (text→chunk embeddings) ────────", .{});
    try println(io, "  MRR={d:.3}  @1={d:.0}%  @5={d:.0}%", .{
        txt_mrr / n,
        @as(f32, @floatFromInt(txt_top1)) / n * 100,
        @as(f32, @floatFromInt(txt_top5)) / n * 100,
    });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn bestRank(corpus: []const ImageEntry, ranking: []const usize, relevant: []const []const u8) usize {
    var best: usize = corpus.len + 1;
    for (relevant) |rel| {
        for (ranking, 0..) |idx, r| {
            if (std.mem.eql(u8, std.fs.path.basename(corpus[idx].path), rel)) {
                if (r + 1 < best) best = r + 1;
                break;
            }
        }
    }
    return best;
}

fn extractPrompt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parser = try png.PngParser.init(a, io);
    defer parser.deinit();

    const file_size = try file.length(io);
    const buffer = try a.alloc(u8, file_size);
    _ = try file.readPositionalAll(io, buffer, 0);
    try parser.parseBuffer(buffer);

    var a1111_text:    ?[]const u8 = null;
    var workflow_text: ?[]const u8 = null;
    var prompt_text:   ?[]const u8 = null;

    {
        const chunks = parser.getITxtChunks() catch &[_]png.Chunk{};
        defer a.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseITxtChunk(chunk) catch continue;
            defer content.deinit(a);
            if (std.mem.eql(u8, content.keyword, "parameters") and !content.compressed and a1111_text == null)
                a1111_text = a.dupe(u8, content.text) catch null;
        }
    }
    {
        const chunks = try parser.getTExtChunks();
        defer a.free(chunks);
        for (chunks) |chunk| {
            var content = parser.parseTExtChunk(chunk) catch continue;
            defer content.deinit(a);
            if (std.mem.eql(u8, content.keyword, "workflow")) {
                if (workflow_text == null) workflow_text = a.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "prompt")) {
                if (prompt_text == null) prompt_text = a.dupe(u8, content.text) catch null;
            } else if (std.mem.eql(u8, content.keyword, "parameters")) {
                if (a1111_text == null) a1111_text = a.dupe(u8, content.text) catch null;
            }
        }
    }

    var comfy = ComfyParser.init(a);
    var result: ?ParseResult = null;
    if (a1111_text) |t|    result = comfy.parseA1111Parameters(t) catch null;
    if (result == null) if (workflow_text) |t| { result = comfy.parseWorkflow(t) catch null; };
    if (result == null) if (prompt_text)   |t| { result = comfy.parsePromptChunk(t) catch null; };

    var pr = result orelse return null;
    defer pr.deinit(a);
    const prompt = pr.positive_prompt orelse return null;
    return try allocator.dupe(u8, prompt);
}

fn nanoNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn println(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt ++ "\n", args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

fn argErr(msg: []const u8) error{InvalidArgument} {
    std.log.err("{s}", .{msg});
    return error.InvalidArgument;
}

fn usage() error{MissingArgument} {
    std.log.err(
        "usage: test_onnx_search <images_dir> <model_dir>\n" ++
        "  model_dir must contain: visual/model.onnx, textual/model.onnx, tokenizer.json\n" ++
        "  options: --chunk-size N  --top-k N",
        .{},
    );
    return error.MissingArgument;
}
