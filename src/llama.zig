const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.llama);

fn nanoNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}
const util = @import("util.zig");
const cmdFlags = @import("cmd_flags.zig");

pub const c = @import("llama_cpp");

pub const Token = c.llama_token;

pub const SamplingParams = struct {
    seed: u32 = 0,
    top_k: u32 = 40,
    top_p: f32 = 0.5,
    temperature: f32 = 0.7,
    repeat_n_last: usize = 256,
    repeat_penalty: f32 = 1.05,
    presence_penalty: f32 = 0,
    frequency_penalty: f32 = 0,
    json: bool = false,
};

pub const PoolOptions = struct {
    n_gpu_layers: ?u32 = null,
    n_ctx: u32 = 2048,
    n_batch: u32 = 64,
    n_ubatch: u32 = 64,
    n_threads: ?u32 = null,
    n_threads_batch: ?u32 = null,
    embeddings: bool = false,
    flash_attn: bool = false,
    mlock: bool = false,
    pooling_type: i32 = 1,
    /// Forward all llama.cpp log output. When false (default), only
    /// warnings and errors are forwarded; debug/info spam is suppressed.
    llama_verbose: bool = false,
};

/// A single-model, single-context, thread-safe pool.
pub const Pool = struct {
    allocator: std.mem.Allocator = undefined,
    options: PoolOptions,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    model: ?Model = null,
    context: ?Context = null,

    /// Initializes the pool.
    pub fn init(allocator: std.mem.Allocator, options: PoolOptions) Pool {
        const H = struct {
            var verbose: bool = false;
            fn trampoline(level: c.enum_ggml_log_level, data: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
                const msg = std.mem.trimEnd(u8, std.mem.span(data), &.{'\n'});
                if (level == c.GGML_LOG_LEVEL_ERROR) return log.err("{s}", .{msg});
                if (level == c.GGML_LOG_LEVEL_WARN)  return log.warn("{s}", .{msg});
                if (verbose) log.debug("{s}", .{msg});
            }
        };
        H.verbose = options.llama_verbose;

        c.llama_backend_init();
        c.ggml_backend_load_all();
        c.llama_log_set(H.trampoline, null);

        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Deinitializes the pool.
    pub fn deinit(self: *Pool) void {
        self.reset(undefined);
        c.llama_backend_free();
    }

    /// Resets the pool.
    pub fn reset(self: *Pool, options: PoolOptions) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer self.locked.store(false, .release);

        if (self.context) |*context| {
            context.deinit();
            self.context = null;
        }

        if (self.model) |*model| {
            model.deinit();
            self.model = null;
        }

        self.options = options;
    }

    /// Returns a context for the given model. The context must be released
    /// after use. This function is thread-safe. Fails if the context is busy
    /// for more than `timeout` milliseconds.
    pub fn get(self: *Pool, model_path: []const u8, timeout: u64) !*Context {
        const deadline = nanoNow() + @as(i64, @intCast(timeout)) * std.time.ns_per_ms;
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            if (nanoNow() > deadline) return error.ContextBusy;
            std.atomic.spinLoopHint();
        }
        errdefer self.locked.store(false, .release);

        if (self.model == null or !std.mem.eql(u8, self.model.?.path, model_path)) {
            // Reset if the model has changed.
            if (self.context != null) {
                self.context.?.deinit();
                self.model.?.deinit();
            }

            self.model = try Model.loadFromFile(self.allocator, model_path, self.modelParams());
            self.context = try Context.init(self.allocator, &self.model.?, self.contextParams());
        }

        return &self.context.?;
    }

    fn modelParams(self: *Pool) c.llama_model_params {
        var params = c.llama_model_default_params();

        // Metal never worked on Intel macs; on all other platforms use n_gpu_layers
        // if set, otherwise default to 999 (offload everything) on Apple Silicon
        // where Metal is always available, and 0 elsewhere.
        // see https://github.com/ggerganov/llama.cpp/issues/3423#issuecomment-1745511586
        const default_gpu_layers: u32 = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) 999 else 0;
        params.n_gpu_layers = @intCast(self.options.n_gpu_layers orelse default_gpu_layers);
        params.use_mlock = self.options.mlock;

        return params;
    }

    fn contextParams(self: *Pool) c.llama_context_params {
        var params = c.llama_context_default_params();
        const cpu_count = getPerfCpuCount();

        params.n_ctx = @intCast(self.options.n_ctx);
        params.n_batch = @intCast(self.options.n_batch);
        params.n_ubatch = @intCast(self.options.n_ubatch);
        params.embeddings = self.options.embeddings;
        params.n_threads = @intCast(self.options.n_threads orelse cpu_count);
        params.n_threads_batch = @intCast(self.options.n_threads_batch orelse self.options.n_threads orelse cpu_count);
        params.flash_attn_type = if (self.options.flash_attn) c.LLAMA_FLASH_ATTN_TYPE_ENABLED else c.LLAMA_FLASH_ATTN_TYPE_AUTO;
        params.pooling_type = self.options.pooling_type;

        return params;
    }

    /// Releases the context so that it can be used by other threads.
    pub fn release(self: *Pool, ctx: *Context) void {
        if (ctx == &self.context.?) {
            self.locked.store(false, .release);
        }
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    params: c.llama_model_params,
    ptr: *c.llama_model,

    /// Loads a model from a file.
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, params: c.struct_llama_model_params) !Model {
        const pathZ = try getShortPath(allocator, path);
        defer allocator.free(pathZ);

        // Load the model
        const ptr = c.llama_model_load_from_file(pathZ.ptr, params) orelse return error.InvalidModel;

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path), // save original, long path
            .params = params,
            .ptr = ptr,
        };
    }

    /// Loads a model from HuggingFace if it doesn't exist locally. saves models to [dataDir]/models/filename.revision
    pub fn loadFromHuggingFace(allocator: std.mem.Allocator, repo: []const u8, options: cmdFlags.Flags, filename: []const u8, revision: ?[]const u8, params: c.struct_llama_model_params) !Model {
        const rev = revision orelse "main";
        // Get data path for model
        const model_file = try std.fmt.allocPrint(allocator, "/Models/{s}.{s}", .{ filename, rev });
        defer allocator.free(model_file);
        const model_path = try util.getDataPath(allocator, options, model_file);
        defer allocator.free(model_path);

        // Check if model already exists
        if (!std.fs.cwd().access(model_path)) {
            // Construct HuggingFace API URL
            const url = try std.fmt.allocPrint(allocator, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ repo, rev, filename });
            defer allocator.free(url);
            std.debug.print("Downloading model {s}...\n", .{url});

            // Download model file
            var body = std.ArrayList(u8).init(allocator);
            defer body.deinit();
            var client = std.http.Client{ .allocator = allocator };
            defer client.deinit();
            std.debug.print("Downloading...\n", .{});
            _ = try client.fetch(.{
                .location = .{ .url = url },
                .response_storage = .{ .dynamic = &body },
                //.max_append_size = 17099152, // ~16 MB
            });
            const dl_file = try std.fs.cwd().createFile(model_path, .{});
            defer dl_file.close();
            try dl_file.writeAll(body.items);
        }

        // Load the downloaded model
        return loadFromFile(allocator, model_path, params);
    }

    /// Deinitializes the model.
    pub fn deinit(self: *Model) void {
        c.llama_model_free(self.ptr);
        self.allocator.free(self.path);
    }

    /// Returns the number of metadata entries.
    pub fn metaCount(self: *const Model) usize {
        return @intCast(c.llama_model_meta_count(self.ptr));
    }

    /// Returns the metadata key at the given index.
    pub fn metaKey(self: *const Model, allocator: std.mem.Allocator, index: usize) !?[:0]const u8 {
        const len = c.llama_model_meta_key_by_index(self.ptr, @intCast(index), null, 0);

        if (len < 0) {
            return null;
        }

        const buf = try allocator.allocSentinel(u8, @intCast(len), 0);
        _ = c.llama_model_meta_key_by_index(self.ptr, @intCast(index), buf.ptr, buf.len + 1);
        return buf;
    }

    pub fn metaValue(self: *const Model, allocator: std.mem.Allocator, key: [:0]const u8) !?[:0]const u8 {
        const len = c.llama_model_meta_val_str(self.ptr, key.ptr, null, 0);

        if (len < 0) {
            return null;
        }

        const buf = try allocator.allocSentinel(u8, @intCast(len), 0);
        _ = c.llama_model_meta_val_str(self.ptr, key.ptr, buf.ptr, buf.len + 1);
        return buf;
    }

    /// Tokenizes the input and appends the tokens to the given list.
    pub fn tokenize(self: *const Model, allocator: std.mem.Allocator, tokens: *std.ArrayList(Token), input: []const u8, special: bool) !void {
        try tokens.ensureUnusedCapacity(allocator, input.len / 2);
        var slice: []Token = tokens.items[tokens.items.len..];
        slice.len = tokens.capacity - tokens.items.len;

        const n_tokens = c.llama_tokenize(
            c.llama_model_get_vocab(self.ptr),
            input.ptr,
            @intCast(input.len),
            slice.ptr,
            @intCast(slice.len),
            c.llama_vocab_get_add_bos(c.llama_model_get_vocab(self.ptr)),
            special,
        );

        if (n_tokens >= 0) {
            tokens.items.len += @intCast(n_tokens);
        } else {
            try tokens.ensureUnusedCapacity(allocator, @intCast(-n_tokens));
            return self.tokenize(allocator, tokens, input, special);
        }
    }

    fn getShortPath(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
        // llama.cpp is using fopen() and it does not support UTF-8 paths on Windows
        // so what we need to do is to call GetShortPathName() to get the short path
        // and it should work
        if (comptime builtin.os.tag == .windows) {
            const w = struct {
                extern "kernel32" fn GetShortPathNameW(lpszLongPath: ?[*:0]const u16, lpszShortPath: ?[*:0]u16, cchBuffer: u32) callconv(std.os.windows.WINAPI) u32;
            };

            const wpath = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(wpath);

            var buf: [260:0]u16 = undefined;
            _ = w.GetShortPathNameW(wpath, &buf, buf.len);

            return std.unicode.utf16LeToUtf8AllocZ(allocator, &buf);
        }

        return allocator.dupeZ(u8, path);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    model: *Model,
    params: c.llama_context_params,
    ptr: *c.llama_context,
    sampler: *c.llama_sampler,
    tokens: std.ArrayList(Token) = .empty,
    n_past: usize = 0,
    candidates: std.ArrayList(c.llama_token_data) = .empty,
    buf: std.ArrayList(u8) = .empty,

    /// Initializes the context.
    pub fn init(allocator: std.mem.Allocator, model: *Model, params: c.struct_llama_context_params) !Context {
        var candidates: std.ArrayList(c.llama_token_data) = .empty;
        errdefer candidates.deinit(allocator);

        try candidates.resize(allocator, @intCast(c.llama_vocab_n_tokens(c.llama_model_get_vocab(model.ptr))));

        return .{
            .allocator = allocator,
            .model = model,
            .params = params,
            .ptr = c.llama_new_context_with_model(model.ptr, params) orelse return error.UnexpectedError,
            .sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()),
            .candidates = candidates,
        };
    }

    /// Deinitializes the context.
    pub fn deinit(self: *Context) void {
        c.llama_sampler_free(self.sampler);
        c.llama_free(self.ptr);
        self.tokens.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    /// Prepares the context for inference.
    pub fn prepare(self: *Context, prompt: []const u8, params: SamplingParams) !void {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(self.allocator);

        try self.model.tokenize(self.allocator, &tokens, prompt, true);
        self.buf.shrinkRetainingCapacity(0);

        // Encoder-only models (BERT-style) require the full sequence every time —
        // bidirectional attention can't reuse a partial KV cache from a previous prompt.
        const is_encoder_only = c.llama_model_has_encoder(self.model.ptr) and
            !c.llama_model_has_decoder(self.model.ptr);

        // Find the common part and set n_past accordingly.
        var n_past: usize = 0;

        if (!is_encoder_only) {
            for (0..@min(self.tokens.items.len, tokens.items.len)) |i| {
                if (self.tokens.items[i] != tokens.items[i]) break;
                n_past = i;
            }
        }

        // Remove the past tokens from the KV cache.
        const mem = c.llama_get_memory(self.ptr);
        if (!c.llama_memory_seq_rm(mem, 0, @intCast(n_past), -1)) {
            c.llama_memory_clear(mem, true);
        }


        c.llama_sampler_free(self.sampler);
        self.sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params());
        // TODO: grammar
        // TODO: penalties
        // c.llama_sampler_chain_add(self.sampler, c.llama_sampler_init_penalties(n_vocab: i32, special_eos_id: llama_token, linefeed_id: llama_token, params.repeat_n_last, params.repeat_penalty, params.frequency_penalty, params.presence_penalty, false, false));
        c.llama_sampler_chain_add(self.sampler, c.llama_sampler_init_top_k(@intCast(params.top_k)));
        c.llama_sampler_chain_add(self.sampler, c.llama_sampler_init_top_p(params.top_p, 1));
        c.llama_sampler_chain_add(self.sampler, c.llama_sampler_init_temp(params.temperature));
        c.llama_sampler_chain_add(self.sampler, c.llama_sampler_init_dist(@intCast(params.seed)));

        self.tokens.deinit(self.allocator);
        self.tokens = tokens;
        self.n_past = n_past;
    }

    /// Runs the inference.
    /// Does nothing if the context is already up-to-date.
    pub fn eval(self: *Context) !void {
        while (try self.evalOnce() > 0) {}
    }

    /// Runs one step of inference.
    /// Does nothing if the context is already up-to-date.
    /// Returns the number of tokens evaluated.
    pub fn evalOnce(self: *Context) !usize {
        const n_eval = @min(
            @as(usize, @intCast(self.params.n_batch)),
            self.tokens.items.len - self.n_past,
        );

        if (n_eval > 0) {
            if (c.llama_model_has_encoder(self.model.ptr) and !c.llama_model_has_decoder(self.model.ptr)) {
                if (c.llama_encode(self.ptr, c.llama_batch_get_one(&self.tokens.items[self.n_past], @intCast(n_eval))) != 0) {
                    return error.FailedToEval;
                }
            } else if (!c.llama_model_has_encoder(self.model.ptr) and c.llama_model_has_decoder(self.model.ptr)) {
                if (c.llama_decode(self.ptr, c.llama_batch_get_one(&self.tokens.items[self.n_past], @intCast(n_eval))) != 0) {
                    return error.FailedToEval;
                }
            } else {
                return error.ModelHasDecodeAndEncode;
            }

            self.n_past += n_eval;
        }

        return n_eval;
    }

    /// Generates next chunk of text.
    pub fn generate(self: *Context) !?[]const u8 {
        const token = try self.generateToken() orelse return null;

        var buf: [128]u8 = undefined;
        const n = c.llama_token_to_piece(c.llama_model_get_vocab(self.model.ptr), token, &buf, @intCast(buf.len), 0, true);

        if (n < 0) {
            return error.UnexpectedError;
        }

        const start = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, buf[0..@intCast(n)]);
        return self.buf.items[start..];
    }

    /// Generates a token using the given sampler and appends it to the context.
    fn generateToken(self: *Context) !?Token {
        if (self.tokens.items.len >= c.llama_n_ctx(self.ptr)) {
            // Truncate input if it's too long but keep some empty space for
            // new tokens.
            const cutoff: usize = @intCast(@divTrunc(c.llama_n_ctx(self.ptr), 2));
            for (self.tokens.items[cutoff..], 0..) |t, i| {
                self.tokens.items[i] = t;
            }
            self.tokens.items.len = cutoff;
            self.n_past = 0;

        }

        try self.eval();

        const token = try self.sampleToken() orelse return null;
        try self.tokens.append(self.allocator, token);
        return token;
    }

    /// Samples a token from the context.
    pub fn sampleToken(self: *Context) !?Token {
        const token = c.llama_sampler_sample(self.sampler, self.ptr, -1);

        if (c.llama_token_is_eog(c.llama_model_get_vocab(self.model.ptr), token)) {
            return null;
        }

        return token;
    }
};

fn getPerfCpuCount() usize {
    if (builtin.os.tag == .macos) {
        var count: c_int = 0;
        var len: usize = @sizeOf(c_int);

        std.posix.sysctlbynameZ("hw.perflevel0.physicalcpu", &count, &len, null, 0) catch {};
        if (count > 0) return @intCast(count);
    }

    return std.Thread.getCpuCount() catch 4;
}

const grammar = struct {
    const JSON_RULES = rulePtrs(&.{
        &.{ ref(1), end(0) },
        &.{ ch('{'), ref(7), ref(11), ch('}'), end(0) }, // ref(7), end(0) },
        &.{ ref(1), alt(0), ref(3), alt(0), ref(4), alt(0), ref(5), alt(0), ref(6), ref(7), end(0) },
        &.{ ch('['), ref(7), ref(15), ch(']'), ref(7), end(0) },
        &.{ ch('"'), ref(18), ch('"'), ref(7), end(0) },
        &.{ ref(19), ref(25), ref(29), ref(7), end(0) },
        &.{ ch('t'), ch('r'), ch('u'), ch('e'), alt(0), ch('f'), ch('a'), ch('l'), ch('s'), ch('e'), alt(0), ch('n'), ch('u'), ch('l'), ch('l'), end(0) },
        &.{ ref(31), end(0) },
        &.{ ref(4), ch(':'), ref(7), ref(2), ref(10), end(0) },
        &.{ ch(','), ref(7), ref(4), ch(':'), ref(7), ref(2), end(0) },
        &.{ ref(9), ref(10), alt(0), end(0) },
        &.{ ref(8), alt(0), end(0) },
        &.{ ref(2), ref(14), end(0) },
        &.{ ch(','), ref(7), ref(2), end(0) },
        &.{ ref(13), ref(14), alt(0), end(0) },
        &.{ ref(12), alt(0), end(0) },
        &.{ chNot('"'), chAlt('\\'), alt(0), ch('\\'), ref(17), end(0) },
        &.{ ch('"'), chAlt('\\'), chAlt('/'), chAlt('b'), chAlt('f'), chAlt('n'), chAlt('r'), chAlt('t'), alt(0), ch('u'), ch('0'), chRnu('9'), chAlt('a'), chRnu('f'), chAlt('A'), chRnu('F'), ch('0'), chRnu('9'), chAlt('a'), chRnu('f'), chAlt('A'), chRnu('F'), ch('0'), chRnu('9'), chAlt('a'), chRnu('f'), chAlt('A'), chRnu('F'), ch('0'), chRnu('9'), chAlt('a'), chRnu('f'), chAlt('A'), chRnu('F'), end(0) },
        &.{ ref(16), ref(18), alt(0), end(0) },
        &.{ ref(20), ref(21), end(0) },
        &.{ ch('-'), alt(0), end(0) },
        &.{ ch('0'), chRnu('9'), alt(0), ch('1'), chRnu('9'), ref(22), end(0) },
        &.{ ch('0'), chRnu('9'), ref(22), alt(0), end(0) },
        &.{ ch('.'), ref(24), end(0) },
        &.{ ch('0'), chRnu('9'), ref(24), alt(0), ch('0'), chRnu('9'), end(0) },
        &.{ ref(23), alt(0), end(0) },
        &.{ ch('e'), chAlt('E'), ref(27), ref(28), end(0) },
        &.{ ch('-'), chAlt('+'), alt(0), end(0) },
        &.{ ch('0'), chRnu('9'), ref(28), alt(0), ch('0'), chRnu('9'), end(0) },
        &.{ ref(26), alt(0), end(0) },
        &.{ ch(' '), chAlt('\u{0009}'), chAlt('\u{000A}'), ref(7), end(0) },
        &.{ ref(30), alt(0), end(0) },
    });

    fn rulePtrs(comptime rules: []const []const c.llama_grammar_element) []const [*c]const c.llama_grammar_element {
        var ptrs: [rules.len][*]const c.llama_grammar_element = undefined;
        for (rules, 0..) |rule, i| ptrs[i] = rule.ptr;
        const res = ptrs;
        return &res;
    }

    fn ref(i: usize) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_RULE_REF, .value = @intCast(i) };
    }

    fn end(i: usize) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_END, .value = @intCast(i) };
    }

    fn ch(v: u8) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_CHAR, .value = @intCast(v) };
    }

    fn chNot(v: u8) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_CHAR_NOT, .value = @intCast(v) };
    }

    fn chAlt(v: u8) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_CHAR_ALT, .value = @intCast(v) };
    }

    fn chRnu(v: u8) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_CHAR_RNG_UPPER, .value = @intCast(v) };
    }

    fn alt(i: usize) c.llama_grammar_element {
        return .{ .type = c.LLAMA_GRETYPE_ALT, .value = @intCast(i) };
    }
};

/// Create an embedding from a prompt string using the LLM
pub fn createEmbeddingFromPrompt(allocator: std.mem.Allocator, ctx: *Context, prompt: []const u8, ctx_size: u32) !std.ArrayList([]const f32) {
    // Count tokens without preparing the context (avoid polluting KV cache state).
    var count_tokens: std.ArrayList(Token) = .empty;
    defer count_tokens.deinit(allocator);
    try ctx.model.tokenize(allocator, &count_tokens, prompt, true);

    var prompts: std.ArrayList([]const u8) = .empty;
    const prompts_owns_strings = count_tokens.items.len > ctx_size;
    defer {
        if (prompts_owns_strings) {
            for (prompts.items) |p| allocator.free(p);
        }
        prompts.deinit(allocator);
    }

    if (prompts_owns_strings) {
        // need to split the prompt into pieces
        try chunkByTokens(allocator, prompt, ctx, ctx_size, &prompts);
    } else {
        // put the single prompt into prompts (no dupe — we don't own it)
        try prompts.append(allocator, prompt);
    }

    // loop over each prompt segment and generate an embedding
    var embeddings: std.ArrayList([]const f32) = .empty;
    for (prompts.items) |p| {
        // Prepare and run — one prepare per chunk, no double-prepare.
        try ctx.prepare(p, .{
            .seed = 0,
            .temperature = 0.0,
        });
        // Run the model to get embeddings
        try ctx.eval();

        // Get the embedding size from the model
        const n_embd = @as(usize, @intCast(c.llama_model_n_embd(ctx.model.ptr)));
        const embedding = try allocator.alloc(f32, n_embd);
        errdefer allocator.free(embedding);

        // Try seq embedding first (mean/cls pooling), fall back to raw
        const embd = c.llama_get_embeddings_seq(ctx.ptr, 0) orelse
            c.llama_get_embeddings(ctx.ptr) orelse
            return error.EmbeddingFailed;
        @memcpy(embedding, embd[0..n_embd]);

        // Normalize the embedding (L2 norm)
        var sum_squared: f32 = 0.0;
        for (embedding) |val| {
            sum_squared += val * val;
        }

        const norm = @sqrt(sum_squared);
        if (norm > 0.0) {
            for (embedding) |*val| {
                val.* /= norm;
            }
        }

        try embeddings.append(allocator, embedding);
    }

    return embeddings;
}

fn chunkByTokens(allocator: std.mem.Allocator, text: []const u8, ctx: *Context, max_tokens: usize, output_list: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var token_chunk: std.ArrayList(Token) = .empty;
    defer token_chunk.deinit(allocator);
    while (start < text.len) {
        var end = start;
        var token_count: usize = 0;

        // Keep extending the current chunk until we hit max tokens
        while (end < text.len and token_count < max_tokens) {
            // Find next semantic boundary (sentence or paragraph)
            const next_boundary = findNextSemanticBoundary(text, end);

            // Count tokens in this segment
            const segment = text[end..next_boundary];
            // Clear the token chunk before each use
            token_chunk.clearAndFree(allocator);
            try ctx.model.tokenize(allocator, &token_chunk, segment, false);
            const segment_tokens = token_chunk.items.len;

            // If adding this segment would exceed our limit, stop
            if (token_count + segment_tokens > max_tokens and token_count > 0) {
                break;
            }

            // Otherwise add it to our chunk
            token_count += segment_tokens;
            end = next_boundary;
        }

        // Create the chunk
        if (end > start) {
            const chunk = try allocator.dupe(u8, text[start..end]);
            try output_list.append(allocator, chunk);
            start = end;
        } else {
            // Fallback if we can't make progress (single token too large)
            end = @min(start + 100, text.len);
            const chunk = try allocator.dupe(u8, text[start..end]);
            try output_list.append(allocator, chunk);
            start = end;
        }
    }
}

fn findNextSemanticBoundary(text: []const u8, start: usize) usize {
    // Look for paragraph breaks, sentence ends, etc.
    for (text[start..], 0..) |char, i| {
        const pos = start + i;

        // Paragraph break
        if (pos + 1 < text.len and char == '\n' and text[pos + 1] == '\n') {
            return pos + 2;
        }

        // Sentence end
        if (pos + 1 < text.len and (char == '.' or char == '!' or char == '?') and
            (text[pos + 1] == ' ' or text[pos + 1] == '\n'))
        {
            return pos + 2;
        }
    }

    return text.len; // If no boundary found, return end of text
}
