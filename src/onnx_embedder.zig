/// ONNX embedding backend for DiffKeep.
///
/// Wraps three models:
///   - Snowflake Arctic Embed M v2.0 — text prompt search (768-dim)
///   - SigLIP2 ViT-B-16 visual encoder — image embedding at index time (768-dim)
///   - SigLIP2 ViT-B-16 textual encoder — cross-modal query embedding (768-dim)
///
/// All three are optional: pass null dirs to skip loading a model.
/// OrtSession.Run() is thread-safe; the public embed functions may be called
/// from multiple threads concurrently.
const std          = @import("std");
const ort          = @import("onnxruntime_c");
const vips         = @cImport(@cInclude("vips_helper.h"));
const build_options = @import("build_options");

const log = std.log.scoped(.onnx_embedder);

// ── Constants ─────────────────────────────────────────────────────────────────

const SNOW_MAX_TOKENS    = 512;
const SIGLIP_MAX_TOKENS  = 64;
const SIGLIP_IMAGE_SIZE  = 224;
const SIGLIP_MEAN: [3]f32 = .{ 0.5, 0.5, 0.5 };
const SIGLIP_STD:  [3]f32 = .{ 0.5, 0.5, 0.5 };

// ── ORT helpers ───────────────────────────────────────────────────────────────

const OrtApi = ort.struct_OrtApi;

fn ortCheck(status: ?*ort.OrtStatus, api: *const OrtApi) !void {
    const s = status orelse return;
    const msg = api.GetErrorMessage.?(s);
    log.err("ORT: {s}", .{msg});
    api.ReleaseStatus.?(s);
    return error.OrtError;
}

fn logAvailableProviders(api: *const OrtApi) void {
    var providers: [*c][*c]u8 = null;
    var count: c_int = 0;
    const status = api.GetAvailableProviders.?(&providers, &count);
    if (status != null) {
        api.ReleaseStatus.?(status);
        log.warn("GetAvailableProviders failed", .{});
        return;
    }
    defer _ = api.ReleaseAvailableProviders.?(providers, count);
    log.info("ORT available providers ({d}):", .{count});
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        log.info("  [{d}] {s}", .{ i, std.mem.span(providers[i]) });
    }
}

// ── UnigramTokenizer (Snowflake Arctic Embed) ─────────────────────────────────
//
// SentencePiece Unigram model loaded from HuggingFace tokenizer.json.
// Pre-tokenisation: split on whitespace, prepend ▁ (U+2581) to each word.
// Decoding: Viterbi over log-scores.
// Frame: <s>=0 … </s>=2.

const UnigramTokenizer = struct {
    allocator:       std.mem.Allocator,
    vocab:           std.StringHashMap(VocabEntry), // owned keys
    bos_id:          i64,
    eos_id:          i64,
    unk_id:          i64,
    max_piece_bytes: usize,

    const VocabEntry = struct { id: i64, score: f32 };
    const METASPACE = "\xe2\x96\x81"; // UTF-8 for ▁

    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !UnigramTokenizer {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const model     = parsed.value.object.get("model") orelse return error.MissingModel;
        const vocab_arr = model.object.get("vocab") orelse return error.MissingVocab;

        var vocab = std.StringHashMap(VocabEntry).init(allocator);
        errdefer {
            var it = vocab.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            vocab.deinit();
        }

        const items = vocab_arr.array.items;
        try vocab.ensureTotalCapacity(@intCast(items.len));

        var max_bytes: usize = 0;
        for (items, 0..) |entry, idx| {
            const pair  = entry.array.items;
            const piece = try allocator.dupe(u8, pair[0].string);
            const score: f32 = @floatCast(pair[1].float);
            vocab.putAssumeCapacityNoClobber(piece, .{ .id = @intCast(idx), .score = score });
            if (piece.len > max_bytes) max_bytes = piece.len;
        }

        const bos_id = if (vocab.get("<s>"))   |e| e.id else 0;
        const eos_id = if (vocab.get("</s>"))  |e| e.id else 2;
        const unk_id = if (vocab.get("<unk>")) |e| e.id else 3;

        return .{
            .allocator       = allocator,
            .vocab           = vocab,
            .bos_id          = bos_id,
            .eos_id          = eos_id,
            .unk_id          = unk_id,
            .max_piece_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *UnigramTokenizer) void {
        var it = self.vocab.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.vocab.deinit();
    }

    /// Tokenize: <s> + subwords + </s>, capped at max_len. Caller owns result.
    pub fn tokenize(
        self:      *const UnigramTokenizer,
        allocator: std.mem.Allocator,
        text:      []const u8,
        max_len:   usize,
    ) ![]i64 {
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(allocator);
        try ids.append(allocator, self.bos_id);

        var it = std.mem.splitAny(u8, text, " \t\n\r");
        while (it.next()) |raw_word| {
            if (raw_word.len == 0) continue;
            if (ids.items.len >= max_len - 1) break;

            const word = try std.fmt.allocPrint(allocator, "{s}{s}", .{ METASPACE, raw_word });
            defer allocator.free(word);

            const word_ids = try self.viterbi(allocator, word);
            defer allocator.free(word_ids);

            for (word_ids) |id| {
                if (ids.items.len >= max_len - 1) break;
                try ids.append(allocator, id);
            }
        }

        try ids.append(allocator, self.eos_id);
        return ids.toOwnedSlice(allocator);
    }

    fn viterbi(self: *const UnigramTokenizer, allocator: std.mem.Allocator, word: []const u8) ![]i64 {
        const n = word.len;
        const NEG_INF: f64 = -std.math.floatMax(f64);

        const dp         = try allocator.alloc(f64, n + 1);
        defer allocator.free(dp);
        const prev_start = try allocator.alloc(usize, n + 1);
        defer allocator.free(prev_start);
        const prev_id    = try allocator.alloc(i64, n + 1);
        defer allocator.free(prev_id);

        @memset(dp, NEG_INF);
        dp[0] = 0.0;

        for (1..n + 1) |i| {
            const max_back = @min(i, self.max_piece_bytes);
            var l: usize = 1;
            while (l <= max_back) : (l += 1) {
                const j = i - l;
                if (dp[j] <= NEG_INF) continue;
                if (self.vocab.get(word[j..i])) |e| {
                    const score: f64 = dp[j] + @as(f64, e.score);
                    if (score > dp[i]) {
                        dp[i]         = score;
                        prev_start[i] = j;
                        prev_id[i]    = e.id;
                    }
                }
            }
        }

        if (dp[n] <= NEG_INF) {
            return try allocator.dupe(i64, &.{self.unk_id});
        }

        var result: std.ArrayList(i64) = .empty;
        defer result.deinit(allocator);
        var pos: usize = n;
        while (pos > 0) {
            try result.append(allocator, prev_id[pos]);
            pos = prev_start[pos];
        }
        std.mem.reverse(i64, result.items);
        return result.toOwnedSlice(allocator);
    }
};

// ── BpeTokenizer (SigLIP2 textual encoder) ────────────────────────────────────
//
// Standard BPE with ▁ (Metaspace) normalisation.
// Loaded from HuggingFace tokenizer.json (SigLIP2 uses its own 256k vocab BPE).

const BpeTokenizer = struct {
    allocator:   std.mem.Allocator,
    vocab:       std.StringHashMap(u32), // piece → id (owned keys)
    merge_ranks: std.StringHashMap(u32), // "a\x00b" → rank (owned keys)
    unk_id:      u32,

    const METASPACE = "\xe2\x96\x81";

    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !BpeTokenizer {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const model       = parsed.value.object.get("model") orelse return error.MissingModelKey;
        const vocab_obj   = model.object.get("vocab")  orelse return error.MissingVocabKey;
        const merges_arr  = model.object.get("merges") orelse return error.MissingMergesKey;
        const unk_tok     = model.object.get("unk_token") orelse return error.MissingUnkToken;

        var vocab = std.StringHashMap(u32).init(allocator);
        errdefer {
            var it = vocab.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            vocab.deinit();
        }
        try vocab.ensureTotalCapacity(@intCast(vocab_obj.object.count()));

        var vi = vocab_obj.object.iterator();
        while (vi.next()) |kv| {
            const piece = try allocator.dupe(u8, kv.key_ptr.*);
            vocab.putAssumeCapacityNoClobber(piece, @intCast(kv.value_ptr.integer));
        }

        const unk_id = vocab.get(unk_tok.string) orelse 0;

        var merge_ranks = std.StringHashMap(u32).init(allocator);
        errdefer {
            var it = merge_ranks.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            merge_ranks.deinit();
        }
        try merge_ranks.ensureTotalCapacity(@intCast(merges_arr.array.items.len));

        for (merges_arr.array.items, 0..) |entry, rank| {
            const a   = entry.array.items[0].string;
            const b   = entry.array.items[1].string;
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

    /// Encode → int64 IDs capped at max_tokens. Caller owns result.
    pub fn encode(
        self:      *const BpeTokenizer,
        allocator: std.mem.Allocator,
        text:      []const u8,
        max_tokens: usize,
    ) ![]i64 {
        const pieces = try self.bpeEncode(allocator, text);
        defer {
            for (pieces) |p| allocator.free(p);
            allocator.free(pieces);
        }
        const n   = @min(pieces.len, max_tokens);
        const ids = try allocator.alloc(i64, n);
        for (pieces[0..n], ids) |p, *id|
            id.* = @intCast(self.vocab.get(p) orelse self.unk_id);
        return ids;
    }

    fn bpeEncode(self: *const BpeTokenizer, allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
        var norm: std.ArrayList(u8) = .empty;
        defer norm.deinit(allocator);
        for (text) |b| {
            if (b == ' ') try norm.appendSlice(allocator, METASPACE)
            else try norm.append(allocator, b);
        }
        if (norm.items.len == 0) return allocator.alloc([]const u8, 0);

        var tokens: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }

        var i: usize = 0;
        while (i < norm.items.len) {
            const cp_len = utf8CharLen(norm.items[i]);
            const end    = @min(i + cp_len, norm.items.len);
            try tokens.append(allocator, try allocator.dupe(u8, norm.items[i..end]));
            i = end;
        }

        while (tokens.items.len > 1) {
            var best_rank: u32  = std.math.maxInt(u32);
            var best_idx:  usize = 0;
            var found = false;

            for (0..tokens.items.len - 1) |j| {
                var key_buf: [512]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{
                    tokens.items[j], tokens.items[j + 1],
                }) catch continue;
                if (self.merge_ranks.get(key)) |rank| {
                    if (rank < best_rank) { best_rank = rank; best_idx = j; found = true; }
                }
            }
            if (!found) break;

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
        if (first_byte & 0x80 == 0)    return 1;
        if (first_byte & 0xE0 == 0xC0) return 2;
        if (first_byte & 0xF0 == 0xE0) return 3;
        return 4;
    }
};

// ── OnnxEmbedder ──────────────────────────────────────────────────────────────

pub const OnnxEmbedder = struct {
    allocator: std.mem.Allocator,
    api:       *const OrtApi,
    env:       *ort.OrtEnv,
    opts:      *ort.OrtSessionOptions,
    mem_info:  *ort.OrtMemoryInfo,

    // Snowflake text encoder (prompt search)
    snow_session: ?*ort.OrtSession = null,
    snow_tok:     ?UnigramTokenizer = null,

    // SigLIP2 visual encoder (image indexing)
    siglip_visual: ?*ort.OrtSession = null,

    // SigLIP2 textual encoder (cross-modal query)
    siglip_text: ?*ort.OrtSession = null,
    siglip_tok:  ?BpeTokenizer = null,

    /// Initialise.  Pass absolute paths to model dirs; null = skip that model.
    ///   text_dir   : snowflake-arctic-embed-m-v2.0 dir (onnx/model_int8.onnx + tokenizer.json)
    ///   visual_dir : ViT-B-16-SigLIP2__webli dir (visual/model.onnx + textual/model.onnx + textual/tokenizer.json)
    ///   use_gpu    : try to add the CUDA execution provider (requires GPU build)
    ///   gpu_device_id : CUDA device index (0 = first GPU)
    pub fn init(
        io:           std.Io,
        allocator:    std.mem.Allocator,
        text_dir:     ?[]const u8,
        visual_dir:   ?[]const u8,
        use_gpu:      bool,
        gpu_device_id: u32,
    ) !OnnxEmbedder {
        const api: *const OrtApi = @ptrCast(
            ort.OrtGetApiBase().*.GetApi.?(ort.ORT_API_VERSION).?,
        );

        var env: ?*ort.OrtEnv = null;
        try ortCheck(api.CreateEnv.?(ort.ORT_LOGGING_LEVEL_WARNING, "diffkeep", &env), api);
        var env_owned = true;
        errdefer if (env_owned) api.ReleaseEnv.?(env);

        var opts: ?*ort.OrtSessionOptions = null;
        try ortCheck(api.CreateSessionOptions.?(&opts), api);
        var opts_owned = true;
        errdefer if (opts_owned) api.ReleaseSessionOptions.?(opts);
        try ortCheck(api.SetSessionGraphOptimizationLevel.?(opts, ort.ORT_ENABLE_ALL), api);

        log.info("ORT init: use_gpu={} build_gpu={} gpu_device_id={}", .{ use_gpu, build_options.gpu, gpu_device_id });
        logAvailableProviders(api);

        var gpu_registered = false;
        if (build_options.gpu and use_gpu) {
            log.info("GPU path: attempting CUDA execution provider on device {d}", .{gpu_device_id});
            if (api.SessionOptionsAppendExecutionProvider_CUDA) |append_cuda| {
                log.info("  SessionOptionsAppendExecutionProvider_CUDA API present, calling...", .{});
                var cuda_opts = std.mem.zeroes(ort.struct_OrtCUDAProviderOptions);
                cuda_opts.device_id = @intCast(gpu_device_id);
                cuda_opts.gpu_mem_limit = std.math.maxInt(usize);
                cuda_opts.do_copy_in_default_stream = 1;
                if (ortCheck(append_cuda(opts.?, &cuda_opts), api)) {
                    log.info("  CUDA execution provider registered on device {d}", .{gpu_device_id});
                    gpu_registered = true;
                } else |err| {
                    log.warn("  CUDA provider append failed ({}); sessions will run on CPU", .{err});
                }
            } else {
                log.warn("  SessionOptionsAppendExecutionProvider_CUDA function pointer is null in this ORT build", .{});
            }
        } else if (use_gpu and !build_options.gpu) {
            log.warn("GPU requested in config but binary was not built with -Dgpu=true; running on CPU", .{});
        } else {
            log.info("running on CPU (use_gpu={} build_gpu={})", .{ use_gpu, build_options.gpu });
        }

        // When the GPU provider is active, ORT's CPU thread pool only manages kernel
        // submission and completion signalling — not the actual compute. The default
        // (one thread per core) causes excessive spinning. Cap to 1.
        if (gpu_registered) {
            try ortCheck(api.SetIntraOpNumThreads.?(opts, 1), api);
            try ortCheck(api.SetInterOpNumThreads.?(opts, 1), api);
            log.info("ORT GPU mode: capped inter/intra-op thread pool to 1", .{});
        }

        // CPU-only fallback opts — only needed when GPU provider was registered.
        // Sessions don't hold a reference to opts after CreateSession returns, so
        // we can release cpu_opts as soon as all sessions are loaded (via defer).
        var cpu_opts: ?*ort.OrtSessionOptions = null;
        if (gpu_registered) {
            var co: ?*ort.OrtSessionOptions = null;
            try ortCheck(api.CreateSessionOptions.?(&co), api);
            errdefer api.ReleaseSessionOptions.?(co);
            try ortCheck(api.SetSessionGraphOptimizationLevel.?(co, ort.ORT_ENABLE_ALL), api);
            cpu_opts = co;
        }
        defer if (cpu_opts) |co| api.ReleaseSessionOptions.?(co);

        var mem: ?*ort.OrtMemoryInfo = null;
        try ortCheck(api.CreateCpuMemoryInfo.?(
            ort.OrtDeviceAllocator, ort.OrtMemTypeDefault, &mem,
        ), api);
        var mem_owned = true;
        errdefer if (mem_owned) api.ReleaseMemoryInfo.?(mem);

        var self = OnnxEmbedder{
            .allocator = allocator,
            .api       = api,
            .env       = env.?,
            .opts      = opts.?,
            .mem_info  = mem.?,
        };
        env_owned  = false;
        opts_owned = false;
        mem_owned  = false;
        errdefer self.deinit();

        // Which session opts to use: start with GPU opts, switch to CPU on first failure.
        var try_gpu = gpu_registered;

        // Load Snowflake text encoder
        if (text_dir) |dir| {
            const cur_opts = if (try_gpu) opts.? else cpu_opts orelse opts.?;
            self.snow_session = loadSession(allocator, api, env.?, cur_opts, dir, "onnx/model_int8.onnx") catch |err| blk: {
                if (try_gpu) {
                    log.warn("snowflake GPU session failed ({}); falling back to CPU for all remaining sessions", .{err});
                    try_gpu = false;
                    break :blk try loadSession(allocator, api, env.?, cpu_opts.?, dir, "onnx/model_int8.onnx");
                }
                return err;
            };
            const tok_json = try readFile(io, allocator, dir, "tokenizer.json");
            defer allocator.free(tok_json);
            self.snow_tok = try UnigramTokenizer.initFromJson(allocator, tok_json);
            log.info("snowflake loaded from {s} (gpu={})", .{ dir, try_gpu });
        }

        // Load SigLIP2 visual + textual encoders
        if (visual_dir) |dir| {
            {
                const cur_opts = if (try_gpu) opts.? else cpu_opts orelse opts.?;
                self.siglip_visual = loadSession(allocator, api, env.?, cur_opts, dir, "visual/model.onnx") catch |err| blk: {
                    if (try_gpu) {
                        log.warn("siglip2 visual GPU session failed ({}); falling back to CPU for all remaining sessions", .{err});
                        try_gpu = false;
                        break :blk try loadSession(allocator, api, env.?, cpu_opts.?, dir, "visual/model.onnx");
                    }
                    return err;
                };
            }
            {
                const cur_opts = if (try_gpu) opts.? else cpu_opts orelse opts.?;
                self.siglip_text = loadSession(allocator, api, env.?, cur_opts, dir, "textual/model.onnx") catch |err| blk: {
                    if (try_gpu) {
                        log.warn("siglip2 textual GPU session failed ({}); falling back to CPU", .{err});
                        try_gpu = false;
                        break :blk try loadSession(allocator, api, env.?, cpu_opts.?, dir, "textual/model.onnx");
                    }
                    return err;
                };
            }
            const tok_json = try readFile(io, allocator, dir, "textual/tokenizer.json");
            defer allocator.free(tok_json);
            self.siglip_tok = try BpeTokenizer.initFromJson(allocator, tok_json);
            log.info("siglip2 loaded from {s} (gpu={})", .{ dir, try_gpu });
        }

        return self;
    }

    pub fn deinit(self: *OnnxEmbedder) void {
        if (self.siglip_tok)  |*t| t.deinit();
        if (self.snow_tok)    |*t| t.deinit();
        if (self.siglip_text)   |s| self.api.ReleaseSession.?(s);
        if (self.siglip_visual) |s| self.api.ReleaseSession.?(s);
        if (self.snow_session)  |s| self.api.ReleaseSession.?(s);
        self.api.ReleaseMemoryInfo.?(self.mem_info);
        self.api.ReleaseSessionOptions.?(self.opts);
        self.api.ReleaseEnv.?(self.env);
    }

    pub fn hasPromptEncoder(self: *const OnnxEmbedder) bool {
        return self.snow_session != null;
    }

    pub fn hasVisualEncoder(self: *const OnnxEmbedder) bool {
        return self.siglip_visual != null;
    }

    // ── Public embed functions ────────────────────────────────────────────────

    /// Embed a prompt text string (snowflake, 768-dim, L2-norm). Caller owns result.
    pub fn embedPrompt(self: *OnnxEmbedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const session = self.snow_session orelse return error.ModelNotLoaded;
        const tok     = &(self.snow_tok   orelse return error.ModelNotLoaded);
        const ids     = try tok.tokenize(allocator, text, SNOW_MAX_TOKENS);
        defer allocator.free(ids);
        return runSnowflake(self, allocator, session, ids);
    }

    /// Embed an image file (siglip2 visual, 768-dim, L2-norm). Caller owns result.
    pub fn embedImage(self: *OnnxEmbedder, allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
        const session = self.siglip_visual orelse return error.ModelNotLoaded;
        const tensor  = try loadImageAsTensor(allocator, path);
        defer allocator.free(tensor);
        return runSigLipVisual(self, allocator, session, tensor);
    }

    /// Embed a query text for visual search (siglip2 text encoder, 768-dim, L2-norm). Caller owns result.
    pub fn embedQueryForVisual(self: *OnnxEmbedder, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const session = self.siglip_text orelse return error.ModelNotLoaded;
        const tok     = &(self.siglip_tok orelse return error.ModelNotLoaded);
        const ids64   = try tok.encode(allocator, text, SIGLIP_MAX_TOKENS - 4);
        defer allocator.free(ids64);
        return runSigLipText(self, allocator, session, ids64);
    }

    // ── Batch inference ───────────────────────────────────────────────────────
    //
    // These models were exported with a static batch dimension of 1 and cannot
    // accept a larger batch tensor directly.  The batch methods below run N
    // sequential GPU calls so that the scan pipeline can keep CPU and GPU busy
    // concurrently: EMBED_BATCH_SIZE files are parsed in parallel, then their
    // embeddings are generated here one at a time before the next CPU batch starts.

    /// Embed a slice of prompt texts sequentially. Caller owns the returned
    /// slice and every sub-slice (free each vec then the outer slice).
    pub fn embedPromptBatch(
        self:      *OnnxEmbedder,
        allocator: std.mem.Allocator,
        texts:     []const []const u8,
    ) ![][]f32 {
        const results = try allocator.alloc([]f32, texts.len);
        errdefer {
            for (results) |r| allocator.free(r);
            allocator.free(results);
        }
        for (texts, 0..) |text, i|
            results[i] = try self.embedPrompt(allocator, text);
        return results;
    }

    /// Embed a slice of images sequentially. Caller owns the returned slice
    /// and every sub-slice.
    pub fn embedImageBatch(
        self:      *OnnxEmbedder,
        allocator: std.mem.Allocator,
        paths:     []const [:0]const u8,
    ) ![][]f32 {
        const results = try allocator.alloc([]f32, paths.len);
        errdefer {
            for (results) |r| allocator.free(r);
            allocator.free(results);
        }
        for (paths, 0..) |path, i|
            results[i] = try self.embedImage(allocator, path);
        return results;
    }

    // ── Internal runner functions ─────────────────────────────────────────────

    fn runSnowflake(
        self:    *OnnxEmbedder,
        allocator: std.mem.Allocator,
        session: *ort.OrtSession,
        ids:     []i64,
    ) ![]f32 {
        const seq_len: i64 = @intCast(ids.len);
        const shape = [_]i64{ 1, seq_len };

        const mask = try allocator.alloc(i64, ids.len);
        defer allocator.free(mask);
        @memset(mask, 1);

        var ids_val: ?*ort.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, ids.ptr, ids.len * @sizeOf(i64),
            &shape, shape.len, ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &ids_val,
        ), self.api);
        defer self.api.ReleaseValue.?(ids_val);

        var mask_val: ?*ort.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, mask.ptr, mask.len * @sizeOf(i64),
            &shape, shape.len, ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &mask_val,
        ), self.api);
        defer self.api.ReleaseValue.?(mask_val);

        const input_names  = [_][*:0]const u8{ "input_ids", "attention_mask" };
        const output_names = [_][*:0]const u8{"sentence_embedding"};
        const inputs       = [_]?*const ort.OrtValue{ ids_val, mask_val };
        var output: ?*ort.OrtValue = null;

        try ortCheck(self.api.Run.?(
            session, null,
            &input_names, &inputs, inputs.len,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        return extractAndNormalize(self, allocator, output.?);
    }

    fn runSigLipVisual(
        self:    *OnnxEmbedder,
        allocator: std.mem.Allocator,
        session: *ort.OrtSession,
        tensor:  []f32,
    ) ![]f32 {
        const shape = [_]i64{ 1, 3, SIGLIP_IMAGE_SIZE, SIGLIP_IMAGE_SIZE };

        var input: ?*ort.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, tensor.ptr, tensor.len * @sizeOf(f32),
            &shape, shape.len, ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input,
        ), self.api);
        defer self.api.ReleaseValue.?(input);

        const input_names  = [_][*:0]const u8{"image"};
        const output_names = [_][*:0]const u8{"embedding"};
        var output: ?*ort.OrtValue = null;

        try ortCheck(self.api.Run.?(
            session, null,
            &input_names, &[_]?*const ort.OrtValue{input}, 1,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        return extractAndNormalize(self, allocator, output.?);
    }

    fn runSigLipText(
        self:    *OnnxEmbedder,
        allocator: std.mem.Allocator,
        session: *ort.OrtSession,
        ids64:   []i64,
    ) ![]f32 {
        var ids32: [SIGLIP_MAX_TOKENS]i32 = @splat(0);
        for (ids64, 0..) |src, k| ids32[k] = @intCast(src);

        const shape = [_]i64{ 1, SIGLIP_MAX_TOKENS };

        var ids_val: ?*ort.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, &ids32, ids32.len * @sizeOf(i32),
            &shape, shape.len, ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &ids_val,
        ), self.api);
        defer self.api.ReleaseValue.?(ids_val);

        const input_names  = [_][*:0]const u8{"text"};
        const output_names = [_][*:0]const u8{"embedding"};
        var output: ?*ort.OrtValue = null;

        try ortCheck(self.api.Run.?(
            session, null,
            &input_names, &[_]?*const ort.OrtValue{ids_val}, 1,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        return extractAndNormalize(self, allocator, output.?);
    }

    fn extractAndNormalize(self: *OnnxEmbedder, allocator: std.mem.Allocator, val: *ort.OrtValue) ![]f32 {
        var raw: ?*anyopaque = null;
        try ortCheck(self.api.GetTensorMutableData.?(val, &raw), self.api);

        var info: ?*ort.OrtTensorTypeAndShapeInfo = null;
        try ortCheck(self.api.GetTensorTypeAndShape.?(val, &info), self.api);
        defer self.api.ReleaseTensorTypeAndShapeInfo.?(info);

        var n_elem: usize = 0;
        try ortCheck(self.api.GetTensorShapeElementCount.?(info, &n_elem), self.api);

        const src: [*]const f32 = @ptrCast(@alignCast(raw.?));
        const result = try allocator.dupe(f32, src[0..n_elem]);
        l2Normalize(result);
        return result;
    }
};

// ── Image loading ─────────────────────────────────────────────────────────────

fn loadImageAsTensor(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    if (vips.diffkeep_image_to_rgb_square(path.ptr, SIGLIP_IMAGE_SIZE, &buf, &len) != 0)
        return error.VipsLoadFailed;
    defer vips.diffkeep_vips_free(buf);

    const pixels: [*]const u8 = @ptrCast(buf.?);
    const n_pixels = SIGLIP_IMAGE_SIZE * SIGLIP_IMAGE_SIZE;
    std.debug.assert(len == n_pixels * 3);

    const tensor = try allocator.alloc(f32, 3 * n_pixels);
    for (0..n_pixels) |p| {
        for (0..3) |c| {
            const raw: f32 = @as(f32, @floatFromInt(pixels[p * 3 + c])) / 255.0;
            tensor[c * n_pixels + p] = (raw - SIGLIP_MEAN[c]) / SIGLIP_STD[c];
        }
    }
    return tensor;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn l2Normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    const norm = @sqrt(sum);
    if (norm > 0) {
        for (v) |*x| x.* /= norm;
    }
}

fn loadSession(
    allocator:  std.mem.Allocator,
    api:        *const OrtApi,
    env:        *ort.OrtEnv,
    opts:       *ort.OrtSessionOptions,
    dir:        []const u8,
    rel_path:   []const u8,
) !*ort.OrtSession {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel_path });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var session: ?*ort.OrtSession = null;
    try ortCheck(api.CreateSession.?(env, path_z.ptr, opts, &session), api);
    return session.?;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, rel_path: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel_path });
    defer allocator.free(path);
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const sz = try f.length(io);
    const buf = try allocator.alloc(u8, sz);
    errdefer allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}
