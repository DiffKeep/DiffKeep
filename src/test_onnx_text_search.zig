/// ONNX text retrieval quality: nomic-embed-text-v1.5 vs snowflake-arctic-embed-m-v2.0.
///
/// Usage:
///   test_onnx_text_search <images_dir> <nomic_dir> <snowflake_dir> [gemma_dir]
///
/// If [gemma_dir] is given, EmbeddingGemma (TensorPencil) is also evaluated
/// across several prompt/prefix styles (gemma-*).
///
/// Each model dir must contain:
///   onnx/model_int8.onnx   — quantised sentence encoder
///   tokenizer.json         — HuggingFace tokenizer
///
/// Tests several configurations and reports MRR/@1/@3/@5 split by query tier:
///   nomic-bare     : nomic (ONNX), no prefix
///   nomic-native   : nomic (ONNX), "search_query: " / "search_document: "
///   snowflake      : snowflake (ONNX int8), no prefix
///   snowflake-tp   : snowflake (TensorPencil, native Zig fp32), no prefix
///   snowflake-tp-q : snowflake (TensorPencil), "query: " on queries only
///
/// snowflake vs snowflake-tp is the apples-to-apples check that the TP text
/// encoder reproduces ONNX retrieval quality. The snowflake dir must also carry
/// `model.safetensors` (TP loads safetensors, not ONNX).
const std = @import("std");
const ort_c = @import("onnxruntime_c");
const tp = @import("TensorPencil");
const png = @import("image/png-data.zig");
const ComfyParser = @import("parse/comfy.zig").ComfyParser;
const ParseResult = @import("parse/comfy.zig").ParseResult;

// ── ORT helpers ───────────────────────────────────────────────────────────────

const OrtApi = ort_c.struct_OrtApi;

fn ortCheck(status: ?*ort_c.OrtStatus, api: *const OrtApi) !void {
    const s = status orelse return;
    const msg = api.GetErrorMessage.?(s);
    std.log.err("ORT error: {s}", .{msg});
    api.ReleaseStatus.?(s);
    return error.OrtError;
}

// ── WordPiece tokenizer ───────────────────────────────────────────────────────
//
// Implements BERT-style WordPiece for nomic-embed-text.
// Normalisation: lowercase + strip ASCII control chars.
// Pre-tokenisation: split on whitespace and ASCII punctuation.
// WordPiece: greedy longest-match with "##" continuing-subword prefix.
// Frame: [CLS]=101 ... [SEP]=102.

const WordPieceTokenizer = struct {
    allocator:       std.mem.Allocator,
    vocab:           std.StringHashMap(i64), // owned keys
    unk_id:          i64,
    cls_id:          i64,
    sep_id:          i64,
    max_piece_bytes: usize,

    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !WordPieceTokenizer {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const model    = parsed.value.object.get("model") orelse return error.MissingModel;
        const vocab_obj = model.object.get("vocab") orelse return error.MissingVocab;

        var vocab = std.StringHashMap(i64).init(allocator);
        errdefer {
            var it = vocab.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            vocab.deinit();
        }
        try vocab.ensureTotalCapacity(@intCast(vocab_obj.object.count()));

        var max_bytes: usize = 0;
        var vi = vocab_obj.object.iterator();
        while (vi.next()) |kv| {
            const piece = try allocator.dupe(u8, kv.key_ptr.*);
            vocab.putAssumeCapacityNoClobber(piece, kv.value_ptr.integer);
            if (piece.len > max_bytes) max_bytes = piece.len;
        }

        const unk_id = vocab.get("[UNK]") orelse 100;
        const cls_id = vocab.get("[CLS]") orelse 101;
        const sep_id = vocab.get("[SEP]") orelse 102;

        return .{
            .allocator       = allocator,
            .vocab           = vocab,
            .unk_id          = unk_id,
            .cls_id          = cls_id,
            .sep_id          = sep_id,
            .max_piece_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *WordPieceTokenizer) void {
        var it = self.vocab.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.vocab.deinit();
    }

    /// Tokenize text: [CLS] + subwords + [SEP], capped at max_len tokens total.
    /// Returned slice is caller-owned.
    pub fn tokenize(
        self:      *const WordPieceTokenizer,
        allocator: std.mem.Allocator,
        text:      []const u8,
        max_len:   usize,
    ) ![]i64 {
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(allocator);
        try ids.append(allocator, self.cls_id);

        // Normalise: lowercase + strip ASCII control chars
        const norm = try normalise(allocator, text);
        defer allocator.free(norm);

        // Split on whitespace and punctuation
        var word_start: ?usize = null;
        var i: usize = 0;
        while (i <= norm.len) : (i += 1) {
            const at_end = (i == norm.len);
            const c = if (at_end) @as(u8, ' ') else norm[i];
            const is_ws = std.ascii.isWhitespace(c);
            const is_p  = !at_end and isPunct(c);

            if (is_ws or is_p) {
                if (word_start) |ws| {
                    if (ids.items.len < max_len - 1)
                        try self.appendWord(allocator, &ids, norm[ws..i], max_len - 1);
                    word_start = null;
                }
                if (is_p and ids.items.len < max_len - 1)
                    try self.appendWord(allocator, &ids, norm[i .. i + 1], max_len - 1);
            } else {
                if (word_start == null) word_start = i;
            }
        }

        try ids.append(allocator, self.sep_id);
        return ids.toOwnedSlice(allocator);
    }

    fn appendWord(
        self:      *const WordPieceTokenizer,
        allocator: std.mem.Allocator,
        ids:       *std.ArrayList(i64),
        word:      []const u8,
        cap:       usize,
    ) !void {
        if (word.len == 0) return;

        const buf = try allocator.alloc(u8, self.max_piece_bytes + 2);
        defer allocator.free(buf);

        var tokens: std.ArrayList(i64) = .empty;
        defer tokens.deinit(allocator);
        var is_unk = false;

        var start: usize = 0;
        outer: while (start < word.len) {
            var end = @min(word.len, start + self.max_piece_bytes);
            while (end > start and (word[end - 1] & 0xC0) == 0x80) end -= 1;

            while (end > start) {
                const piece: []const u8 = if (start == 0)
                    word[0..end]
                else blk: {
                    buf[0] = '#';
                    buf[1] = '#';
                    @memcpy(buf[2..2 + (end - start)], word[start..end]);
                    break :blk buf[0 .. 2 + (end - start)];
                };

                if (self.vocab.get(piece)) |id| {
                    try tokens.append(allocator, id);
                    start = end;
                    continue :outer;
                }

                end -= 1;
                while (end > start and (word[end] & 0xC0) == 0x80) end -= 1;
            }

            is_unk = true;
            break;
        }

        if (is_unk) {
            if (ids.items.len < cap) try ids.append(allocator, self.unk_id);
        } else {
            for (tokens.items) |id| {
                if (ids.items.len >= cap) break;
                try ids.append(allocator, id);
            }
        }
    }

    fn normalise(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (text) |c| {
            if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') continue;
            if (c == '\t' or c == '\n' or c == '\r') {
                try out.append(allocator, ' ');
            } else {
                try out.append(allocator, std.ascii.toLower(c));
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn isPunct(c: u8) bool {
        return c > 0x20 and c < 0x7F and !std.ascii.isAlphanumeric(c);
    }
};

// ── Unigram (SentencePiece) tokenizer ────────────────────────────────────────
//
// Implements SentencePiece Unigram for snowflake-arctic-embed.
// Pre-tokenisation: split on whitespace, prepend ▁ (U+2581) to each word.
// Viterbi decoding over log-scores.
// Frame: <s>=0 ... </s>=2.

const UnigramTokenizer = struct {
    allocator:       std.mem.Allocator,
    vocab:           std.StringHashMap(VocabEntry), // owned keys
    bos_id:          i64,
    eos_id:          i64,
    unk_id:          i64,
    max_piece_bytes: usize,

    const VocabEntry = struct { id: i64, score: f32 };
    const METASPACE = "\xe2\x96\x81"; // UTF-8 for ▁ (U+2581)

    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !UnigramTokenizer {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const model    = parsed.value.object.get("model") orelse return error.MissingModel;
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
            const pair = entry.array.items;
            const piece_str = pair[0].string;
            const score: f32 = @floatCast(pair[1].float);
            const piece = try allocator.dupe(u8, piece_str);
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

    /// Tokenize text: <s> + subwords + </s>, capped at max_len tokens total.
    /// Returned slice is caller-owned.
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

// ── Sentence encoder ──────────────────────────────────────────────────────────
//
// nomic:     input_ids + token_type_ids + attention_mask → last_hidden_state → mean-pool
// snowflake: input_ids + attention_mask → sentence_embedding (pre-pooled)

const EncoderKind = enum { nomic, snowflake };

const SentenceEncoder = struct {
    allocator: std.mem.Allocator,
    api:       *const OrtApi,
    session:   *ort_c.OrtSession,
    mem_info:  *ort_c.OrtMemoryInfo,
    kind:      EncoderKind,

    pub fn init(
        allocator:  std.mem.Allocator,
        api:        *const OrtApi,
        env:        *ort_c.OrtEnv,
        opts:       *ort_c.OrtSessionOptions,
        model_path: [:0]const u8,
        kind:       EncoderKind,
    ) !SentenceEncoder {
        var session: ?*ort_c.OrtSession = null;
        try ortCheck(api.CreateSession.?(env, model_path.ptr, opts, &session), api);
        errdefer api.ReleaseSession.?(session);

        var mem: ?*ort_c.OrtMemoryInfo = null;
        try ortCheck(api.CreateCpuMemoryInfo.?(
            ort_c.OrtDeviceAllocator, ort_c.OrtMemTypeDefault, &mem,
        ), api);

        return .{
            .allocator = allocator,
            .api       = api,
            .session   = session.?,
            .mem_info  = mem.?,
            .kind      = kind,
        };
    }

    pub fn deinit(self: *SentenceEncoder) void {
        self.api.ReleaseMemoryInfo.?(self.mem_info);
        self.api.ReleaseSession.?(self.session);
    }

    /// Embed token ids.  Returns L2-normalised embedding. Caller owns slice.
    pub fn embed(self: *SentenceEncoder, ids: []i64) ![]f32 {
        const seq_len: i64 = @intCast(ids.len);
        const shape = [_]i64{ 1, seq_len };

        const mask = try self.allocator.alloc(i64, ids.len);
        defer self.allocator.free(mask);
        @memset(mask, 1);

        const type_ids = try self.allocator.alloc(i64, ids.len);
        defer self.allocator.free(type_ids);
        @memset(type_ids, 0);

        var ids_val: ?*ort_c.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, ids.ptr, ids.len * @sizeOf(i64),
            &shape, shape.len, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &ids_val,
        ), self.api);
        defer self.api.ReleaseValue.?(ids_val);

        var mask_val: ?*ort_c.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, mask.ptr, mask.len * @sizeOf(i64),
            &shape, shape.len, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &mask_val,
        ), self.api);
        defer self.api.ReleaseValue.?(mask_val);

        var type_val: ?*ort_c.OrtValue = null;
        try ortCheck(self.api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info, type_ids.ptr, type_ids.len * @sizeOf(i64),
            &shape, shape.len, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &type_val,
        ), self.api);
        defer self.api.ReleaseValue.?(type_val);

        return switch (self.kind) {
            .nomic     => try self.runNomic(ids_val.?, type_val.?, mask_val.?, ids.len),
            .snowflake => try self.runSnowflake(ids_val.?, mask_val.?),
        };
    }

    fn runNomic(
        self:     *SentenceEncoder,
        ids_val:  *ort_c.OrtValue,
        type_val: *ort_c.OrtValue,
        mask_val: *ort_c.OrtValue,
        seq_len:  usize,
    ) ![]f32 {
        const input_names  = [_][*:0]const u8{ "input_ids", "token_type_ids", "attention_mask" };
        const output_names = [_][*:0]const u8{"last_hidden_state"};
        const inputs = [_]?*const ort_c.OrtValue{ ids_val, type_val, mask_val };
        var output: ?*ort_c.OrtValue = null;

        try ortCheck(self.api.Run.?(
            self.session, null,
            &input_names, &inputs, inputs.len,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        var raw: ?*anyopaque = null;
        try ortCheck(self.api.GetTensorMutableData.?(output, &raw), self.api);

        var info: ?*ort_c.OrtTensorTypeAndShapeInfo = null;
        try ortCheck(self.api.GetTensorTypeAndShape.?(output, &info), self.api);
        defer self.api.ReleaseTensorTypeAndShapeInfo.?(info);

        var n_elem: usize = 0;
        try ortCheck(self.api.GetTensorShapeElementCount.?(info, &n_elem), self.api);

        const hidden_dim = n_elem / seq_len;
        const hs: [*]const f32 = @ptrCast(@alignCast(raw.?));

        const result = try self.allocator.alloc(f32, hidden_dim);
        @memset(result, 0);
        for (0..seq_len) |i| {
            for (0..hidden_dim) |j| {
                result[j] += hs[i * hidden_dim + j];
            }
        }
        const scale = 1.0 / @as(f32, @floatFromInt(seq_len));
        for (result) |*v| v.* *= scale;

        l2Normalize(result);
        return result;
    }

    fn runSnowflake(
        self:     *SentenceEncoder,
        ids_val:  *ort_c.OrtValue,
        mask_val: *ort_c.OrtValue,
    ) ![]f32 {
        const input_names  = [_][*:0]const u8{ "input_ids", "attention_mask" };
        const output_names = [_][*:0]const u8{"sentence_embedding"};
        const inputs = [_]?*const ort_c.OrtValue{ ids_val, mask_val };
        var output: ?*ort_c.OrtValue = null;

        try ortCheck(self.api.Run.?(
            self.session, null,
            &input_names, &inputs, inputs.len,
            &output_names, 1, &output,
        ), self.api);
        defer self.api.ReleaseValue.?(output);

        var raw: ?*anyopaque = null;
        try ortCheck(self.api.GetTensorMutableData.?(output, &raw), self.api);

        var info: ?*ort_c.OrtTensorTypeAndShapeInfo = null;
        try ortCheck(self.api.GetTensorTypeAndShape.?(output, &info), self.api);
        defer self.api.ReleaseTensorTypeAndShapeInfo.?(info);

        var n_elem: usize = 0;
        try ortCheck(self.api.GetTensorShapeElementCount.?(info, &n_elem), self.api);

        const src: [*]const f32 = @ptrCast(@alignCast(raw.?));
        const result = try self.allocator.dupe(f32, src[0..n_elem]);
        l2Normalize(result);
        return result;
    }
};

// ── Queries ───────────────────────────────────────────────────────────────────

const Query = struct {
    text:     []const u8,
    relevant: []const []const u8,
    tier:     enum { exact, semantic },
};

const QUERIES = [_]Query{
    .{ .text = "sword",        .relevant = &.{"05.11.57-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "cloak",        .relevant = &.{"05.11.57-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "runic",        .relevant = &.{"05.11.57-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "graveyard",    .relevant = &.{"18.10.26-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "overcoat",     .relevant = &.{"18.10.26-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "dock",         .relevant = &.{"18.11.21-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "auburn hair",  .relevant = &.{"18.11.21-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "sequoia",      .relevant = &.{"18.13.34-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "denim jacket", .relevant = &.{"18.03.17-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "freckles",     .relevant = &.{"18.11.21-80085_00001_.png"}, .tier = .exact    },
    .{ .text = "pier",         .relevant = &.{"18.11.21-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "cemetery",     .relevant = &.{"18.10.26-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "redwood tree", .relevant = &.{"18.13.34-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "weapon",       .relevant = &.{"05.11.57-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "jacket",       .relevant = &.{"18.03.17-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "tombstone",    .relevant = &.{"18.10.26-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "waterfront",   .relevant = &.{"18.11.21-80085_00001_.png"}, .tier = .semantic },
    .{ .text = "giant tree",   .relevant = &.{"18.13.34-80085_00001_.png"}, .tier = .semantic },
};

// ── Model/prefix configurations to test ──────────────────────────────────────

const Backend = enum { nomic_onnx, snowflake_onnx, snowflake_tp, gemma_tp };

const ModelCfg = struct {
    name:         []const u8,
    backend:      Backend,
    query_prefix: []const u8,
    doc_prefix:   []const u8,
};

// EmbeddingGemma prompt templates come straight from the model's own
// config_sentence_transformers.json / README: query prompts are
// "task: {desc} | query: " and document prompts are "title: {t|none} | text: ".
// We try the canonical retrieval pair plus a few alternative framings to see
// which suits DiffKeep's short-keyword → image-prompt retrieval.
const MODEL_CFGS = [_]ModelCfg{
    .{ .name = "nomic-bare",       .backend = .nomic_onnx,     .query_prefix = "",               .doc_prefix = "" },
    .{ .name = "nomic-native",     .backend = .nomic_onnx,     .query_prefix = "search_query: ", .doc_prefix = "search_document: " },
    .{ .name = "snowflake",        .backend = .snowflake_onnx, .query_prefix = "",               .doc_prefix = "" },
    .{ .name = "snowflake-tp",     .backend = .snowflake_tp,   .query_prefix = "",               .doc_prefix = "" },
    .{ .name = "snowflake-tp-q",   .backend = .snowflake_tp,   .query_prefix = "query: ",        .doc_prefix = "" },
    .{ .name = "gemma-retrieval",  .backend = .gemma_tp,       .query_prefix = "task: search result | query: ",       .doc_prefix = "title: none | text: " },
    .{ .name = "gemma-qa",         .backend = .gemma_tp,       .query_prefix = "task: question answering | query: ",  .doc_prefix = "title: none | text: " },
    .{ .name = "gemma-sts",        .backend = .gemma_tp,       .query_prefix = "task: sentence similarity | query: ", .doc_prefix = "task: sentence similarity | query: " },
    .{ .name = "gemma-bare",       .backend = .gemma_tp,       .query_prefix = "",                                    .doc_prefix = "" },
    .{ .name = "gemma-query-both", .backend = .gemma_tp,       .query_prefix = "task: search result | query: ",       .doc_prefix = "task: search result | query: " },
};

/// Dispatches tokenize + embed across the three backends so the eval loop is
/// backend-agnostic. All backends return an L2-normalized vector (caller owns).
const Encoders = struct {
    nomic_tok: *const WordPieceTokenizer,
    snow_tok:  *const UnigramTokenizer,
    tp_tok:    *const tp.tokenizer.Tokenizer,
    nomic_enc: *SentenceEncoder,
    snow_enc:  *SentenceEncoder,
    tp_model:  *const tp.models.embed_snowflake.Model,
    // Optional: only loaded when a gemma dir is passed on the command line.
    gemma_tok:   ?*const tp.tokenizer.Tokenizer = null,
    gemma_model: ?*const tp.models.embed_gemma.Model = null,
    io:        std.Io,

    fn embed(self: Encoders, allocator: std.mem.Allocator, backend: Backend, text: []const u8) ![]f32 {
        switch (backend) {
            .nomic_onnx => {
                const ids = try self.nomic_tok.tokenize(allocator, text, MAX_TOKENS);
                defer allocator.free(ids);
                return self.nomic_enc.embed(ids);
            },
            .snowflake_onnx => {
                const ids = try self.snow_tok.tokenize(allocator, text, MAX_TOKENS);
                defer allocator.free(ids);
                return self.snow_enc.embed(ids);
            },
            .snowflake_tp => {
                // TP tokenizer emits content ids only; frame <s>=0 … </s>=2.
                var content: std.ArrayList(u32) = .empty;
                defer content.deinit(allocator);
                try self.tp_tok.encode(allocator, text, &content);

                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(allocator);
                try ids.append(allocator, 0);
                const cap = @min(content.items.len, MAX_TOKENS - 2);
                try ids.appendSlice(allocator, content.items[0..cap]);
                try ids.append(allocator, 2);

                const out = try allocator.alloc(f32, tp.models.embed_snowflake.embed_dim);
                errdefer allocator.free(out);
                try self.tp_model.embed(self.io, allocator, ids.items, out);
                return out; // already L2-normalized by TP
            },
            .gemma_tp => {
                const tok   = self.gemma_tok   orelse return error.GemmaNotLoaded;
                const model = self.gemma_model orelse return error.GemmaNotLoaded;

                // Gemma tokenizer emits content ids only; frame <bos>=2 … <eos>=1.
                var content: std.ArrayList(u32) = .empty;
                defer content.deinit(allocator);
                try tok.encode(allocator, text, &content);

                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(allocator);
                try ids.append(allocator, 2);
                // EmbeddingGemma asserts framed seq <= 512; cap content at 510.
                const cap = @min(content.items.len, MAX_TOKENS - 2);
                try ids.appendSlice(allocator, content.items[0..cap]);
                try ids.append(allocator, 1);

                const out = try allocator.alloc(f32, tp.models.embed_gemma.embed_dim);
                errdefer allocator.free(out);
                try model.embed(self.io, allocator, ids.items, out);
                return out; // already L2-normalized by TP
            },
        }
    }
};

const MAX_TOKENS = 512;

// ── Metrics ───────────────────────────────────────────────────────────────────

const Metrics = struct {
    mrr:   f32 = 0,
    top1:  usize = 0,
    top3:  usize = 0,
    top5:  usize = 0,
    total: usize = 0,

    fn update(self: *Metrics, rank: usize) void {
        self.total += 1;
        if (rank == 0) return;
        self.mrr += 1.0 / @as(f32, @floatFromInt(rank));
        if (rank <= 1) self.top1 += 1;
        if (rank <= 3) self.top3 += 1;
        if (rank <= 5) self.top5 += 1;
    }
};

// ── ImageEntry ────────────────────────────────────────────────────────────────

const ImageEntry = struct {
    path:   []const u8, // owned
    prompt: []const u8, // owned

    fn deinit(self: ImageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prompt);
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

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

fn extractPrompt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parser = try png.PngParser.init(a, io);
    defer parser.deinit();

    const sz = try file.length(io);
    const buf = try a.alloc(u8, sz);
    _ = try file.readPositionalAll(io, buf, 0);
    try parser.parseBuffer(buf);

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
    const text = pr.positive_prompt orelse return null;
    return try allocator.dupe(u8, text);
}

fn usage() void {
    std.log.err("Usage: test_onnx_text_search <images_dir> <nomic_dir> <snowflake_dir> [gemma_dir]", .{});
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

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io        = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const images_dir = args.next() orelse { usage(); return; };
    const nomic_dir  = args.next() orelse { usage(); return; };
    const snow_dir   = args.next() orelse { usage(); return; };
    const gemma_dir  = args.next(); // optional: enables the gemma-* configs

    // ── Load tokenizers ───────────────────────────────────────────────────

    try println(io, "Loading nomic tokenizer...", .{});
    const nomic_tok_json = blk: {
        const p = try std.fmt.allocPrint(allocator, "{s}/tokenizer.json", .{nomic_dir});
        defer allocator.free(p);
        var f = try std.Io.Dir.cwd().openFile(io, p, .{});
        defer f.close(io);
        const sz = try f.length(io);
        const buf = try allocator.alloc(u8, sz);
        _ = try f.readPositionalAll(io, buf, 0);
        break :blk buf;
    };
    defer allocator.free(nomic_tok_json);
    var nomic_tok = try WordPieceTokenizer.initFromJson(allocator, nomic_tok_json);
    defer nomic_tok.deinit();
    try println(io, "  WordPiece vocab: {d} entries", .{nomic_tok.vocab.count()});

    try println(io, "Loading snowflake tokenizer...", .{});
    const snow_tok_json = blk: {
        const p = try std.fmt.allocPrint(allocator, "{s}/tokenizer.json", .{snow_dir});
        defer allocator.free(p);
        var f = try std.Io.Dir.cwd().openFile(io, p, .{});
        defer f.close(io);
        const sz = try f.length(io);
        const buf = try allocator.alloc(u8, sz);
        _ = try f.readPositionalAll(io, buf, 0);
        break :blk buf;
    };
    defer allocator.free(snow_tok_json);
    var snow_tok = try UnigramTokenizer.initFromJson(allocator, snow_tok_json);
    defer snow_tok.deinit();
    try println(io, "  Unigram vocab:   {d} entries", .{snow_tok.vocab.count()});

    // ── Load ORT sessions ─────────────────────────────────────────────────

    try println(io, "Initialising ORT...", .{});
    const api: *const OrtApi = @ptrCast(
        ort_c.OrtGetApiBase().*.GetApi.?(ort_c.ORT_API_VERSION).?,
    );

    var env: ?*ort_c.OrtEnv = null;
    try ortCheck(api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "text_search", &env), api);
    defer api.ReleaseEnv.?(env);

    var opts: ?*ort_c.OrtSessionOptions = null;
    try ortCheck(api.CreateSessionOptions.?(&opts), api);
    defer api.ReleaseSessionOptions.?(opts);
    try ortCheck(api.SetSessionGraphOptimizationLevel.?(opts, ort_c.ORT_ENABLE_ALL), api);

    const nomic_path = blk: {
        const s = try std.fmt.allocPrint(allocator, "{s}/onnx/model_int8.onnx", .{nomic_dir});
        defer allocator.free(s);
        break :blk try allocator.dupeZ(u8, s);
    };
    defer allocator.free(nomic_path);

    const snow_path = blk: {
        const s = try std.fmt.allocPrint(allocator, "{s}/onnx/model_int8.onnx", .{snow_dir});
        defer allocator.free(s);
        break :blk try allocator.dupeZ(u8, s);
    };
    defer allocator.free(snow_path);

    try println(io, "Loading nomic model...", .{});
    var nomic_enc = try SentenceEncoder.init(allocator, api, env.?, opts.?, nomic_path, .nomic);
    defer nomic_enc.deinit();

    try println(io, "Loading snowflake model...", .{});
    var snow_enc = try SentenceEncoder.init(allocator, api, env.?, opts.?, snow_path, .snowflake);
    defer snow_enc.deinit();

    // ── Load TensorPencil snowflake (native Zig, safetensors) ─────────────
    try println(io, "Loading TensorPencil snowflake tokenizer + model...", .{});
    var tp_tok = try tp.tokenizer.Tokenizer.initUnigramFromTokenizerJson(allocator, snow_tok_json);
    defer tp_tok.deinit();
    var tp_model = try tp.models.embed_snowflake.Model.open(allocator, io, snow_dir);
    defer tp_model.deinit();

    // ── Load EmbeddingGemma (optional, TensorPencil, safetensors) ─────────
    var gemma_tok: ?tp.tokenizer.Tokenizer = null;
    defer if (gemma_tok) |*t| t.deinit();
    var gemma_model: ?tp.models.embed_gemma.Model = null;
    defer if (gemma_model) |*m| m.deinit();

    if (gemma_dir) |gdir| {
        try println(io, "Loading EmbeddingGemma tokenizer + model from {s}...", .{gdir});
        const gtok_json = blk: {
            const p = try std.fmt.allocPrint(allocator, "{s}/tokenizer.json", .{gdir});
            defer allocator.free(p);
            var f = try std.Io.Dir.cwd().openFile(io, p, .{});
            defer f.close(io);
            const sz = try f.length(io);
            const buf = try allocator.alloc(u8, sz);
            _ = try f.readPositionalAll(io, buf, 0);
            break :blk buf;
        };
        defer allocator.free(gtok_json);
        gemma_tok   = try tp.tokenizer.Tokenizer.initGemma4FromTokenizerJson(allocator, gtok_json);
        gemma_model = try tp.models.embed_gemma.Model.open(allocator, io, gdir);
    } else {
        try println(io, "(no gemma dir given — gemma-* configs will be skipped)", .{});
    }

    const enc_set = Encoders{
        .nomic_tok   = &nomic_tok,
        .snow_tok    = &snow_tok,
        .tp_tok      = &tp_tok,
        .nomic_enc   = &nomic_enc,
        .snow_enc    = &snow_enc,
        .tp_model    = &tp_model,
        .gemma_tok   = if (gemma_tok)   |*t| t else null,
        .gemma_model = if (gemma_model) |*m| m else null,
        .io          = io,
    };

    // ── Scan images ───────────────────────────────────────────────────────

    try println(io, "\nScanning images in {s}...", .{images_dir});
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
                allocator.free(full);
                continue;
            }
            try entries.append(allocator, .{ .path = full, .prompt = prompt.? });
        }
    }
    try println(io, "Loaded {d} images.\n", .{entries.items.len});

    // ── Run each configuration ────────────────────────────────────────────

    const top_k = 5;

    try println(io, "{s:<20} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6}", .{
        "config", "MRR", "@1", "@3", "@5", "ex-MRR", "sem-MRR",
    });
    try println(io, "{s}", .{"-" ** 62});

    for (MODEL_CFGS) |cfg| {
        if (cfg.backend == .gemma_tp and enc_set.gemma_model == null) continue;
        const t_cfg_start = nanoNow();

        // Embed all documents
        const doc_embs = try allocator.alloc([]f32, entries.items.len);
        defer {
            for (doc_embs) |e| allocator.free(e);
            allocator.free(doc_embs);
        }

        for (entries.items, 0..) |entry, idx| {
            const full_doc = try std.fmt.allocPrint(
                allocator, "{s}{s}", .{ cfg.doc_prefix, entry.prompt },
            );
            defer allocator.free(full_doc);

            doc_embs[idx] = try enc_set.embed(allocator, cfg.backend, full_doc);
        }

        // Evaluate queries
        var all   = Metrics{};
        var exact = Metrics{};
        var sem   = Metrics{};

        for (QUERIES) |query| {
            const full_q = try std.fmt.allocPrint(
                allocator, "{s}{s}", .{ cfg.query_prefix, query.text },
            );
            defer allocator.free(full_q);

            const q_emb = try enc_set.embed(allocator, cfg.backend, full_q);
            defer allocator.free(q_emb);

            var scores = try allocator.alloc(f32, entries.items.len);
            defer allocator.free(scores);
            for (doc_embs, 0..) |de, i| scores[i] = dot(q_emb, de);

            var ranking = try allocator.alloc(usize, entries.items.len);
            defer allocator.free(ranking);
            for (ranking, 0..) |*r, i| r.* = i;
            insertionSortDesc(ranking, scores);

            var best_rank: usize = 0;
            outer: for (ranking[0..@min(top_k, ranking.len)], 1..) |idx, rank| {
                const name = std.fs.path.basename(entries.items[idx].path);
                for (query.relevant) |rel| {
                    if (std.mem.eql(u8, name, rel)) {
                        best_rank = rank;
                        break :outer;
                    }
                }
            }

            all.update(best_rank);
            if (query.tier == .exact) exact.update(best_rank) else sem.update(best_rank);
        }

        const elapsed_s = @as(f64, @floatFromInt(nanoNow() - t_cfg_start)) / 1e9;
        try println(io, "{s:<20} {:>6.3} {:>5.0}% {:>5.0}% {:>5.0}% {:>6.3} {:>6.3}  ({d:.1}s)", .{
            cfg.name,
            all.mrr   / @as(f32, @floatFromInt(all.total)),
            100.0 * @as(f32, @floatFromInt(all.top1)) / @as(f32, @floatFromInt(all.total)),
            100.0 * @as(f32, @floatFromInt(all.top3)) / @as(f32, @floatFromInt(all.total)),
            100.0 * @as(f32, @floatFromInt(all.top5)) / @as(f32, @floatFromInt(all.total)),
            exact.mrr / @as(f32, @floatFromInt(exact.total)),
            sem.mrr   / @as(f32, @floatFromInt(sem.total)),
            elapsed_s,
        });
    }
}
