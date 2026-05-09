const std = @import("std");
pub const llama = @import("llama.zig");
pub const c = llama.c;

pub const MtmdContext = opaque {};

pub extern fn mtmd_log_set(callback: c.ggml_log_callback, user_data: ?*anyopaque) void;

pub extern fn mtmd_wrapper_init(
    mmproj_fname: [*:0]const u8,
    text_model: *c.llama_model,
    n_threads: c_int,
) ?*MtmdContext;

pub extern fn mtmd_wrapper_free(ctx: *MtmdContext) void;

pub extern fn mtmd_wrapper_embed_image_file(
    mctx: *MtmdContext,
    lctx: *c.llama_context,
    image_path: [*:0]const u8,
    prefix: [*:0]const u8,
    out_embd: [*]f32,
    n_embd: c_int,
    n_batch: c_int,
    max_size: u32,
) c_int;

pub extern fn mtmd_wrapper_embed_rgb(
    mctx: *MtmdContext,
    lctx: *c.llama_context,
    rgb: [*]const u8,
    nx: u32,
    ny: u32,
    prefix: [*:0]const u8,
    out_embd: [*]f32,
    n_embd: c_int,
    n_batch: c_int,
    max_size: u32,
) c_int;

pub extern fn reranker_wrapper_find_yn_tokens(
    model: *const c.llama_model,
    out_yes_id: *i32,
    out_no_id: *i32,
) void;

pub extern fn reranker_wrapper_score_image_file(
    mctx: *MtmdContext,
    lctx: *c.llama_context,
    query: [*:0]const u8,
    instruction: [*:0]const u8,
    image_path: [*:0]const u8,
    token_yes_id: i32,
    token_no_id: i32,
    n_batch: i32,
    max_size: u32,
) f32;

pub const VlContext = struct {
    allocator: std.mem.Allocator,
    model_path: []const u8,
    mctx: *MtmdContext,
    pool: llama.Pool,
    /// Longest image edge is scaled down to this before encoding.
    /// 0 means no resize. Typical values: 336, 448, 672.
    max_image_size: u32 = 448,

    pub fn init(allocator: std.mem.Allocator, model_path: []const u8, mmproj_path: []const u8) !VlContext {
        const log = std.log.scoped(.mtmd);
        const H = struct {
            fn trampoline(level: c.enum_ggml_log_level, data: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
                const msg = std.mem.trimEnd(u8, std.mem.span(data), &.{'\n'});
                if (level == c.GGML_LOG_LEVEL_ERROR) return log.err("{s}", .{msg});
                if (level == c.GGML_LOG_LEVEL_WARN)  return log.warn("{s}", .{msg});
            }
        };
        mtmd_log_set(H.trampoline, null);

        var pool = llama.Pool.init(allocator, .{
            .embeddings   = true,
            .pooling_type = -1, // model decides
            .n_ctx        = 8192,
            .n_batch      = 512,
            .n_ubatch     = 512,
            .n_gpu_layers = 999,
        });

        // Load the model so we can hand the llama_model* to mtmd.
        const ctx = try pool.get(model_path, 30_000);

        const model_ptr = pool.model.?.ptr;
        const mmproj_z = try allocator.dupeZ(u8, mmproj_path);
        defer allocator.free(mmproj_z);

        const n_threads: c_int = @intCast(std.Thread.getCpuCount() catch 4);
        const mctx = mtmd_wrapper_init(mmproj_z, model_ptr, n_threads) orelse {
            pool.release(ctx);
            pool.deinit();
            return error.MtmdInitFailed;
        };
        pool.release(ctx);

        return .{
            .allocator  = allocator,
            .model_path = model_path,
            .mctx       = mctx,
            .pool       = pool,
        };
    }

    pub fn deinit(self: *VlContext) void {
        mtmd_wrapper_free(self.mctx);
        self.pool.deinit();
    }

    /// Embed an image file. Returns a caller-owned normalized slice.
    pub fn embedImageFile(
        self: *VlContext,
        allocator: std.mem.Allocator,
        image_path: []const u8,
        prefix: []const u8,
    ) ![]f32 {
        const ctx = try self.pool.get(self.model_path, 30_000);
        defer self.pool.release(ctx);

        const n_embd: usize = @intCast(c.llama_model_n_embd(self.pool.model.?.ptr));
        const embd = try allocator.alloc(f32, n_embd);
        errdefer allocator.free(embd);

        // Clear KV cache so sequential calls don't bleed into each other.
        c.llama_memory_clear(c.llama_get_memory(ctx.ptr), true);
        ctx.n_past = 0;

        const path_z   = try allocator.dupeZ(u8, image_path);
        defer allocator.free(path_z);
        const prefix_z = try allocator.dupeZ(u8, prefix);
        defer allocator.free(prefix_z);

        const rc = mtmd_wrapper_embed_image_file(
            self.mctx, ctx.ptr,
            path_z, prefix_z,
            embd.ptr, @intCast(n_embd), 512,
            self.max_image_size,
        );
        if (rc != 0) return error.EmbedFailed;

        normalize(embd);
        return embd;
    }

    /// Embed raw RGB pixels (RGBRGB..., len = nx*ny*3).
    pub fn embedRgb(
        self: *VlContext,
        allocator: std.mem.Allocator,
        rgb: []const u8,
        nx: u32,
        ny: u32,
        prefix: []const u8,
    ) ![]f32 {
        const ctx = try self.pool.get(self.model_path, 30_000);
        defer self.pool.release(ctx);

        const n_embd: usize = @intCast(c.llama_model_n_embd(self.pool.model.?.ptr));
        const embd = try allocator.alloc(f32, n_embd);
        errdefer allocator.free(embd);

        c.llama_memory_clear(c.llama_get_memory(ctx.ptr), true);
        ctx.n_past = 0;

        const prefix_z = try allocator.dupeZ(u8, prefix);
        defer allocator.free(prefix_z);

        const rc = mtmd_wrapper_embed_rgb(
            self.mctx, ctx.ptr,
            rgb.ptr, nx, ny,
            prefix_z,
            embd.ptr, @intCast(n_embd), 512,
            self.max_image_size,
        );
        if (rc != 0) return error.EmbedFailed;

        normalize(embd);
        return embd;
    }
};

pub const RerankContext = struct {
    allocator: std.mem.Allocator,
    model_path: []const u8,
    mctx: *MtmdContext,
    pool: llama.Pool,
    max_image_size: u32 = 448,
    yes_id: i32,
    no_id: i32,

    pub fn init(allocator: std.mem.Allocator, model_path: []const u8, mmproj_path: []const u8) !RerankContext {
        const log = std.log.scoped(.reranker);
        const H = struct {
            fn trampoline(level: c.enum_ggml_log_level, data: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
                const msg = std.mem.trimEnd(u8, std.mem.span(data), &.{'\n'});
                if (level == c.GGML_LOG_LEVEL_ERROR) return log.err("{s}", .{msg});
                if (level == c.GGML_LOG_LEVEL_WARN)  return log.warn("{s}", .{msg});
            }
        };
        mtmd_log_set(H.trampoline, null);

        // Generation pool — embeddings=false, pooling_type unused.
        var pool = llama.Pool.init(allocator, .{
            .embeddings   = false,
            .pooling_type = 0,
            .n_ctx        = 8192,
            .n_batch      = 512,
            .n_ubatch     = 512,
            .n_gpu_layers = 999,
        });

        const ctx = try pool.get(model_path, 30_000);
        const model_ptr = pool.model.?.ptr;

        var yes_id: i32 = -1;
        var no_id:  i32 = -1;
        reranker_wrapper_find_yn_tokens(model_ptr, &yes_id, &no_id);
        if (yes_id < 0 or no_id < 0) {
            pool.release(ctx);
            pool.deinit();
            return error.YesNoTokensNotFound;
        }
        std.log.info("Reranker yes_id={d} no_id={d}", .{ yes_id, no_id });

        const mmproj_z = try allocator.dupeZ(u8, mmproj_path);
        defer allocator.free(mmproj_z);
        const n_threads: c_int = @intCast(std.Thread.getCpuCount() catch 4);
        const mctx = mtmd_wrapper_init(mmproj_z, model_ptr, n_threads) orelse {
            pool.release(ctx);
            pool.deinit();
            return error.MtmdInitFailed;
        };
        pool.release(ctx);

        return .{
            .allocator  = allocator,
            .model_path = model_path,
            .mctx       = mctx,
            .pool       = pool,
            .yes_id     = yes_id,
            .no_id      = no_id,
        };
    }

    pub fn deinit(self: *RerankContext) void {
        mtmd_wrapper_free(self.mctx);
        self.pool.deinit();
    }

    /// Score a (query, image) pair. Returns logit_yes - logit_no (higher = more relevant).
    pub fn scoreImageFile(
        self: *RerankContext,
        allocator: std.mem.Allocator,
        query: []const u8,
        instruction: []const u8,
        image_path: []const u8,
    ) !f32 {
        const ctx = try self.pool.get(self.model_path, 60_000);
        defer self.pool.release(ctx);

        const query_z = try allocator.dupeZ(u8, query);
        defer allocator.free(query_z);
        const instr_z = try allocator.dupeZ(u8, instruction);
        defer allocator.free(instr_z);
        const path_z  = try allocator.dupeZ(u8, image_path);
        defer allocator.free(path_z);

        const score = reranker_wrapper_score_image_file(
            self.mctx, ctx.ptr,
            query_z, instr_z, path_z,
            self.yes_id, self.no_id,
            512, self.max_image_size,
        );
        if (std.math.isNan(score)) return error.RerankFailed;
        return score;
    }
};

fn normalize(v: []f32) void {
    var sq: f32 = 0;
    for (v) |x| sq += x * x;
    const n = @sqrt(sq);
    if (n > 0) for (v) |*x| { x.* /= n; };
}
