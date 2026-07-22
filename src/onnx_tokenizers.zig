//! Pure-Zig tokenizers for the ONNX embedding models, kept free of any C
//! imports so they can be unit-tested (and golden-tested against HuggingFace
//! `tokenizers` output) without linking onnxruntime.

const std = @import("std");

// ── UnigramTokenizer (Snowflake Arctic Embed) ─────────────────────────────────
//
// SentencePiece Unigram model loaded from HuggingFace tokenizer.json.
// Pre-tokenisation: split on whitespace, prepend ▁ (U+2581) to each word.
// Decoding: Viterbi over log-scores.
// Frame: <s>=0 … </s>=2.

pub const UnigramTokenizer = struct {
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
// The model's TemplateProcessing post-processor appends <eos> to every
// sequence; unknown pieces fall back to per-byte <0xXX> tokens.

pub const BpeTokenizer = struct {
    allocator:   std.mem.Allocator,
    vocab:       std.StringHashMap(u32), // piece → id (owned keys)
    merge_ranks: std.StringHashMap(u32), // "a\x00b" → rank (owned keys)
    unk_id:      u32,
    eos_id:      u32,

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

        // <eos> id: prefer the added_tokens declaration, fall back to the
        // vocab entry, then to the conventional Gemma id 1.
        var eos_id: u32 = vocab.get("<eos>") orelse 1;
        if (parsed.value.object.get("added_tokens")) |added| {
            for (added.array.items) |tok| {
                const content = tok.object.get("content") orelse continue;
                if (std.mem.eql(u8, content.string, "<eos>")) {
                    eos_id = @intCast(tok.object.get("id").?.integer);
                }
            }
        }

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
            .eos_id      = eos_id,
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

    /// Encode → int64 IDs ending in <eos>, at most max_tokens total.
    /// Unknown pieces fall back to per-byte <0xXX> tokens. Caller owns result.
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

        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(allocator);
        const content_max = max_tokens - 1; // reserve the final slot for <eos>
        outer: for (pieces) |p| {
            if (ids.items.len >= content_max) break;
            if (self.vocab.get(p)) |id| {
                try ids.append(allocator, @intCast(id));
                continue;
            }
            for (p) |b| {
                if (ids.items.len >= content_max) break :outer;
                var buf: [6]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "<0x{X:0>2}>", .{b}) catch unreachable;
                try ids.append(allocator, @intCast(self.vocab.get(key) orelse self.unk_id));
            }
        }
        try ids.append(allocator, @intCast(self.eos_id));
        return ids.toOwnedSlice(allocator);
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

// ── Tests ─────────────────────────────────────────────────────────────────────

const mini_bpe_json =
    \\{"model":{"type":"BPE","unk_token":"<unk>",
    \\ "vocab":{"<pad>":0,"<eos>":1,"<unk>":2,"a":6,"<0x41>":4,"<0x42>":5},
    \\ "merges":[]},
    \\ "added_tokens":[{"id":1,"content":"<eos>"}]}
;

test "BpeTokenizer appends <eos>" {
    const alloc = std.testing.allocator;
    var tok = try BpeTokenizer.initFromJson(alloc, mini_bpe_json);
    defer tok.deinit();
    const ids = try tok.encode(alloc, "a", 64);
    defer alloc.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ 6, 1 }, ids);
}

test "BpeTokenizer byte fallback for unknown pieces" {
    const alloc = std.testing.allocator;
    var tok = try BpeTokenizer.initFromJson(alloc, mini_bpe_json);
    defer tok.deinit();
    const ids = try tok.encode(alloc, "AB", 64);
    defer alloc.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ 4, 5, 1 }, ids);
}

test "BpeTokenizer truncation keeps <eos> last" {
    const alloc = std.testing.allocator;
    var tok = try BpeTokenizer.initFromJson(alloc, mini_bpe_json);
    defer tok.deinit();
    const ids = try tok.encode(alloc, "aaaaaa", 4);
    defer alloc.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ 6, 6, 6, 1 }, ids);
}

/// Reads a whole file, or null if it doesn't exist (test-only helper for the
/// golden-parity tests below, which are skipped when models aren't on disk).
fn readModelFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = std.testing.io;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const sz = f.length(io) catch return null;
    const buf = allocator.alloc(u8, sz) catch return null;
    _ = f.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

// Golden IDs generated with HuggingFace `tokenizers`:
//   Tokenizer.from_file(<tokenizer.json>).encode(text).ids
// Skipped when the model dir isn't present.
test "BpeTokenizer parity with HF tokenizers (SigLIP2)" {
    const alloc = std.testing.allocator;
    const json = readModelFile(alloc, "Models/ViT-B-16-SigLIP2__webli/textual/tokenizer.json") orelse return;
    defer alloc.free(json);
    var tok = try BpeTokenizer.initFromJson(alloc, json);
    defer tok.deinit();

    const cases = [_]struct { text: []const u8, ids: []const i64 }{
        .{ .text = "a photo of a cat", .ids = &.{ 235250, 2686, 576, 476, 4401, 1 } },
        .{ .text = "neon city at night, rain", .ids = &.{ 74743, 3413, 696, 3354, 235269, 8980, 1 } },
        .{ .text = "emoji 🐈 test", .ids = &.{ 62400, 235248, 243532, 2121, 1 } },
    };
    for (cases) |case| {
        const ids = try tok.encode(alloc, case.text, 64);
        defer alloc.free(ids);
        try std.testing.expectEqualSlices(i64, case.ids, ids);
    }
}

test "UnigramTokenizer parity with HF tokenizers (Snowflake)" {
    const alloc = std.testing.allocator;
    const json = readModelFile(alloc, "Models/snowflake-arctic-embed-m-v2.0/tokenizer.json") orelse return;
    defer alloc.free(json);
    var tok = try UnigramTokenizer.initFromJson(alloc, json);
    defer tok.deinit();

    const cases = [_]struct { text: []const u8, ids: []const i64 }{
        .{ .text = "query: neon city at night", .ids = &.{ 0, 41, 1294, 12, 108, 191, 26349, 99, 17431, 2 } },
        .{ .text = "a photo of a cat", .ids = &.{ 0, 10, 16186, 111, 10, 7515, 2 } },
    };
    for (cases) |case| {
        const ids = try tok.tokenize(alloc, case.text, 512);
        defer alloc.free(ids);
        try std.testing.expectEqualSlices(i64, case.ids, ids);
    }
}
