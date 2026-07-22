/// Parity check: TensorPencil (native Zig) vs ONNX Runtime for the Snowflake
/// Arctic Embed M v2.0 text encoder.
///
/// Embeds a set of representative texts through both backends and reports the
/// cosine similarity between the resulting 768-d vectors. This proves the TP
/// text-embedding path reproduces the ONNX vectors DiffKeep currently ships,
/// before ONNX is removed from the text embedding space.
///
/// Two things are validated per text:
///   1. Tokenizer parity — TP's Unigram tokenizer produces the exact same framed
///      id sequence (<s> … </s>) as DiffKeep's production `onnx_tokenizers`.
///   2. Encoder parity — feeding those identical ids to TP vs ONNX yields vectors
///      with cosine ≈ 1. Compared against both the fp32 reference (`model.onnx`)
///      and the int8 model DiffKeep actually ships (`model_int8.onnx`).
///
/// Usage:
///   test_tp_parity [snowflake_dir]
/// Default snowflake_dir: Models/snowflake-arctic-embed-m-v2.0
const std = @import("std");
const ort_c = @import("onnxruntime_c");
const tp = @import("TensorPencil");
const tokenizers = @import("onnx_tokenizers.zig");
const print = @import("util.zig").print;

const UnigramTokenizer = tokenizers.UnigramTokenizer;

const DEFAULT_DIR = "Models/snowflake-arctic-embed-m-v2.0";
const SNOW_QUERY_PREFIX = "query: ";
const MAX_TOKENS = 512;
const EMBED_DIM = tp.models.embed_snowflake.embed_dim; // 768

/// Cosine parity floor (guide claim: >= 0.999 vs the ONNX reference).
const PARITY_FLOOR: f32 = 0.999;

// ── Test corpus ────────────────────────────────────────────────────────────
//
// Mix of short search-queries (is_query = prefix "query: ") and longer
// AI-image-prompt documents (is_query = false, raw text), mirroring DiffKeep's
// asymmetric usage.

const Text = struct { s: []const u8, is_query: bool };

const CORPUS = [_]Text{
    .{ .s = "cat", .is_query = true },
    .{ .s = "cyberpunk city at night", .is_query = true },
    .{ .s = "a woman with red hair", .is_query = true },
    .{ .s = "dragon breathing fire", .is_query = true },
    .{ .s = "watercolor landscape", .is_query = true },
    .{ .s = "a photorealistic portrait of an elderly fisherman, weathered face, soft rim lighting, 85mm lens, shallow depth of field", .is_query = false },
    .{ .s = "masterpiece, best quality, 1girl, silver hair, blue eyes, ornate fantasy armor, standing in a snowy forest, volumetric light", .is_query = false },
    .{ .s = "a neon-lit cyberpunk street market, rain-slicked pavement, holographic signs, crowds under umbrellas, cinematic, 8k", .is_query = false },
    .{ .s = "oil painting of a stormy sea crashing against jagged cliffs, dramatic sky, impressionist brushwork", .is_query = false },
    .{ .s = "cute corgi puppy wearing a tiny wizard hat, studio photo, bokeh background", .is_query = false },
};

// ── ORT helpers ──────────────────────────────────────────────────────────────

const OrtApi = ort_c.struct_OrtApi;

fn ortCheck(status: ?*ort_c.OrtStatus, api: *const OrtApi) !void {
    const s = status orelse return;
    const msg = api.GetErrorMessage.?(s);
    std.log.err("ORT error: {s}", .{msg});
    api.ReleaseStatus.?(s);
    return error.OrtError;
}

/// Snowflake ONNX text encoder: input_ids + attention_mask → sentence_embedding.
/// Model path is caller-supplied so we can load either the fp32 reference or the
/// int8 shipping model.
const OnnxSnowflake = struct {
    allocator: std.mem.Allocator,
    api:       *const OrtApi,
    session:   *ort_c.OrtSession,
    mem_info:  *ort_c.OrtMemoryInfo,

    pub fn init(
        allocator:  std.mem.Allocator,
        api:        *const OrtApi,
        env:        *ort_c.OrtEnv,
        opts:       *ort_c.OrtSessionOptions,
        model_path: [:0]const u8,
    ) !OnnxSnowflake {
        var session: ?*ort_c.OrtSession = null;
        try ortCheck(api.CreateSession.?(env, model_path.ptr, opts, &session), api);
        errdefer api.ReleaseSession.?(session);

        var mem: ?*ort_c.OrtMemoryInfo = null;
        try ortCheck(api.CreateCpuMemoryInfo.?(
            ort_c.OrtDeviceAllocator, ort_c.OrtMemTypeDefault, &mem,
        ), api);

        return .{ .allocator = allocator, .api = api, .session = session.?, .mem_info = mem.? };
    }

    pub fn deinit(self: *OnnxSnowflake) void {
        self.api.ReleaseMemoryInfo.?(self.mem_info);
        self.api.ReleaseSession.?(self.session);
    }

    /// Embed framed token ids. Returns an L2-normalized 768-d vector (caller owns).
    pub fn embed(self: *OnnxSnowflake, ids: []i64) ![]f32 {
        const seq_len: i64 = @intCast(ids.len);
        const shape = [_]i64{ 1, seq_len };

        const mask = try self.allocator.alloc(i64, ids.len);
        defer self.allocator.free(mask);
        @memset(mask, 1);

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

// ── Helpers ──────────────────────────────────────────────────────────────────

fn l2Normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    const norm = @sqrt(sum);
    if (norm > 0) for (v) |*x| { x.* /= norm; };
}

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |av, bv| s += av * bv;
    return s;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const sz = try f.length(io);
    const buf = try allocator.alloc(u8, sz);
    errdefer allocator.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

fn joinZ(allocator: std.mem.Allocator, dir: []const u8, rel: []const u8) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel });
    defer allocator.free(s);
    return allocator.dupeZ(u8, s);
}

/// Tokenize with TP's Unigram tokenizer, then frame <s>=0 … </s>=2. Returns
/// caller-owned framed ids as u32 (what TP's Model.embed expects).
fn tpTokenizeFramed(
    allocator: std.mem.Allocator,
    tok:       *const tp.tokenizer.Tokenizer,
    text:      []const u8,
) ![]u32 {
    var content: std.ArrayList(u32) = .empty;
    defer content.deinit(allocator);
    try tok.encode(allocator, text, &content);

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);
    try ids.append(allocator, 0); // <s>
    // Cap content so the framed sequence stays within the model's 512 limit.
    const cap = @min(content.items.len, MAX_TOKENS - 2);
    try ids.appendSlice(allocator, content.items[0..cap]);
    try ids.append(allocator, 2); // </s>
    return ids.toOwnedSlice(allocator);
}

// ── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io  = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const dir = args.next() orelse DEFAULT_DIR;

    // ── Load tokenizers (production Unigram + TP Unigram from the same json) ──
    const tok_json = blk: {
        const p = try std.fmt.allocPrint(gpa, "{s}/tokenizer.json", .{dir});
        defer gpa.free(p);
        break :blk try readFile(io, gpa, p);
    };
    defer gpa.free(tok_json);

    var prod_tok = try UnigramTokenizer.initFromJson(gpa, tok_json);
    defer prod_tok.deinit();
    var tp_tok = try tp.tokenizer.Tokenizer.initUnigramFromTokenizerJson(gpa, tok_json);
    defer tp_tok.deinit();
    try print(io, "Tokenizers loaded (production + TensorPencil Unigram)\n", .{});

    // ── Load TP snowflake model ──────────────────────────────────────────────
    try print(io, "Loading TensorPencil snowflake model (safetensors)...\n", .{});
    var tp_model = try tp.models.embed_snowflake.Model.open(gpa, io, dir);
    defer tp_model.deinit();

    // ── Load ONNX sessions: fp32 reference + int8 shipping model ─────────────
    const api: *const OrtApi = @ptrCast(ort_c.OrtGetApiBase().*.GetApi.?(ort_c.ORT_API_VERSION).?);
    var env: ?*ort_c.OrtEnv = null;
    try ortCheck(api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "tp_parity", &env), api);
    defer api.ReleaseEnv.?(env);
    var opts: ?*ort_c.OrtSessionOptions = null;
    try ortCheck(api.CreateSessionOptions.?(&opts), api);
    defer api.ReleaseSessionOptions.?(opts);
    try ortCheck(api.SetSessionGraphOptimizationLevel.?(opts, ort_c.ORT_ENABLE_ALL), api);

    const fp32_path = try joinZ(gpa, dir, "onnx/model.onnx");
    defer gpa.free(fp32_path);
    const int8_path = try joinZ(gpa, dir, "onnx/model_int8.onnx");
    defer gpa.free(int8_path);

    try print(io, "Loading ONNX fp32 reference ({s})...\n", .{fp32_path});
    var onnx_fp32 = try OnnxSnowflake.init(gpa, api, env.?, opts.?, fp32_path);
    defer onnx_fp32.deinit();
    try print(io, "Loading ONNX int8 shipping model ({s})...\n", .{int8_path});
    var onnx_int8 = try OnnxSnowflake.init(gpa, api, env.?, opts.?, int8_path);
    defer onnx_int8.deinit();

    // ── Compare ──────────────────────────────────────────────────────────────
    try print(io, "\n", .{});
    try print(io, "                                                    tok    TP·fp32    TP·int8   fp32·int8\n", .{});
    try print(io, "----------------------------------------------------------------------------------------\n", .{});

    var tok_mismatches: usize = 0;
    var min_fp32: f32 = 1.0;
    var min_int8: f32 = 1.0;
    var sum_fp32: f32 = 0;
    var sum_int8: f32 = 0;

    for (CORPUS) |t| {
        const prefixed = if (t.is_query)
            try std.fmt.allocPrint(gpa, SNOW_QUERY_PREFIX ++ "{s}", .{t.s})
        else
            try gpa.dupe(u8, t.s);
        defer gpa.free(prefixed);

        // Tokenize both ways.
        const ids_onnx = try prod_tok.tokenize(gpa, prefixed, MAX_TOKENS);
        defer gpa.free(ids_onnx);
        const ids_tp = try tpTokenizeFramed(gpa, &tp_tok, prefixed);
        defer gpa.free(ids_tp);

        // Tokenizer parity: same framed id sequence?
        var tok_ok = ids_onnx.len == ids_tp.len;
        if (tok_ok) {
            for (ids_onnx, ids_tp) |a, b| {
                if (@as(i64, @intCast(b)) != a) { tok_ok = false; break; }
            }
        }
        if (!tok_ok) tok_mismatches += 1;

        // Embed. ONNX uses the framed i64 ids; TP uses the framed u32 ids.
        const v_fp32 = try onnx_fp32.embed(ids_onnx);
        defer gpa.free(v_fp32);
        const v_int8 = try onnx_int8.embed(ids_onnx);
        defer gpa.free(v_int8);

        const v_tp = try gpa.alloc(f32, EMBED_DIM);
        defer gpa.free(v_tp);
        try tp_model.embed(io, gpa, ids_tp, v_tp);

        const cos_fp32 = dot(v_tp, v_fp32);
        const cos_int8 = dot(v_tp, v_int8);
        const cos_ref  = dot(v_fp32, v_int8); // ONNX-internal fp32 vs int8 baseline

        min_fp32 = @min(min_fp32, cos_fp32);
        min_int8 = @min(min_int8, cos_int8);
        sum_fp32 += cos_fp32;
        sum_int8 += cos_int8;

        var label_buf: [52]u8 = undefined;
        const label = labelOf(&label_buf, t);
        try print(io, "{s} {s}  {d:.6}   {d:.6}   {d:.6}\n", .{
            label, if (tok_ok) "ok " else "BAD", cos_fp32, cos_int8, cos_ref,
        });
    }

    const n: f32 = @floatFromInt(CORPUS.len);
    try print(io, "----------------------------------------------------------------------------------------\n", .{});
    try print(io, "tokenizer mismatches: {d}/{d}\n", .{ tok_mismatches, CORPUS.len });
    try print(io, "TP vs fp32:  min {d:.6}  mean {d:.6}\n", .{ min_fp32, sum_fp32 / n });
    try print(io, "TP vs int8:  min {d:.6}  mean {d:.6}\n", .{ min_int8, sum_int8 / n });

    const pass = tok_mismatches == 0 and min_fp32 >= PARITY_FLOOR;
    try print(io, "\nRESULT: {s} (parity floor {d:.3} vs fp32 reference)\n", .{
        if (pass) "PASS" else "FAIL", PARITY_FLOOR,
    });
    if (!pass) return error.ParityCheckFailed;
}

/// Left-justified, truncated label for the results table.
fn labelOf(buf: []u8, t: Text) []const u8 {
    const marker = if (t.is_query) "[q] " else "[d] ";
    @memset(buf, ' ');
    @memcpy(buf[0..marker.len], marker);
    const room = buf.len - marker.len;
    const take = @min(t.s.len, room);
    @memcpy(buf[marker.len..][0..take], t.s[0..take]);
    return buf;
}
