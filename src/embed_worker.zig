//! `EmbedWorker` — computes the embeddings the DB is missing, in the
//! background. Scans and the fs watcher only index (rows, metadata,
//! thumbnails) and `poke` it; it reads what is pending from the DB itself
//! (`VectorDb.pendingEmbeds`). So its total is the real number left for every
//! indexed image, the scan never waits on it, and while there is a backlog
//! its batches are full (and go to the GPU).
//!
//! An embedding is stored only while its row still holds the path and
//! content hash the worker read (`storeImageEmbedding`): a row deleted, or its
//! file replaced, while the worker embedded it doesn't get the stale vector.
//! A file that changes later loses its vectors with its old hash (DB trigger,
//! migration v17) and is pending again.

const std = @import("std");
const db_mod = @import("db.zig");
const embedder_mod = @import("embedder.zig");
const prompt_clean = @import("parse/prompt_clean.zig");
const bg = @import("bg.zig");

const log = std.log.scoped(.embed_worker);

const VectorDb = db_mod.VectorDb;
const EmbedKinds = VectorDb.EmbedKinds;
const PendingEmbed = VectorDb.PendingEmbed;

/// Rows claimed for one batched forward. 32 gives the CUDA batches enough work
/// to beat CPU (see `test_tp_batch`: gemma 4.7 ms/item at b=32 vs 6.0 on CPU;
/// siglip even more). The embedder's router sends batches at or above
/// `config.embed_gpu_threshold` to the GPU and smaller ones to the CPU.
pub const batch_size: usize = 32;

/// How often a pass recounts what is pending while rows are being added.
const recount_interval_ns: i96 = std.time.ns_per_s;

/// The work queue's item: "embed whatever is pending". At most one waits.
const Pass = struct {
    fn eql(_: Pass, _: Pass) bool {
        return true;
    }
    fn free(_: std.mem.Allocator, _: Pass) void {}
};

pub const Progress = struct {
    /// A pass is queued or running.
    active: bool,
    /// Rows embedded (or given up on) since the worker last went idle.
    done: u32,
    /// `done` plus what is still pending (at the last count).
    total: u32,
};

pub const EmbedWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *VectorDb,
    /// Passes, one at a time.
    passes: bg.WorkQueue(Pass),
    /// Changed only while no pass runs (`configure`), so passes read them
    /// without a lock. Borrowed.
    embedder: ?*embedder_mod.Embedder = null,
    /// What the config asks for (a kind also needs its encoder loaded).
    kinds: EmbedKinds,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    /// Rows may have been added since the last count.
    dirty: std.atomic.Value(bool) = .init(false),
    /// Wakes the render loop to show progress (any thread).
    wakeup_fn: ?*const fn () void = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db: *VectorDb, kinds: EmbedKinds) EmbedWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .db = db,
            .passes = .init(allocator, io, 1, passWorker, Pass.free),
            .kinds = kinds,
        };
    }

    /// Stop the running pass and wait for it.
    pub fn deinit(self: *EmbedWorker) void {
        self.stop.store(true, .release);
        self.passes.deinit();
    }

    /// Rows were added or changed and may need embeddings: run a pass, unless
    /// one is already waiting (a running one may have passed their ids). Any
    /// thread.
    pub fn poke(self: *EmbedWorker) void {
        self.dirty.store(true, .release);
        _ = self.passes.pushUnique(.{}, Pass.eql) catch |err|
            log.warn("queue embedding pass: {} (pending rows wait for the next change)", .{err});
    }

    /// Swap the embedder and the kinds wanted: stops and awaits the running
    /// pass first, so when this returns nothing uses the old embedder. Then
    /// embeds whatever the new setup leaves pending. Main thread.
    pub fn configure(self: *EmbedWorker, embedder: ?*embedder_mod.Embedder, kinds: EmbedKinds) void {
        self.stop.store(true, .release);
        self.passes.pause();
        self.passes.awaitIdle();
        self.stop.store(false, .release);
        self.embedder = embedder;
        self.kinds = kinds;
        if (embedder) |emb| {
            // Surface a missing encoder: otherwise that kind just never runs.
            if (kinds.prompt and !emb.hasPromptEncoder())
                log.warn("prompt_embeddings on but no text encoder loaded — check text_model_dir; prompts won't be embedded", .{});
            if (kinds.image and !emb.hasVisualEncoder())
                log.warn("image_embeddings on but no visual encoder loaded — check visual_model_dir (needs a timm SigLIP2 dir with open_clip_model.safetensors); images won't be embedded", .{});
        }
        self.passes.unpause();
        self.poke();
    }

    /// Whether a pass is queued or running (and may be using the embedder).
    pub fn busy(self: *EmbedWorker) bool {
        return self.passes.busy();
    }

    pub fn progress(self: *EmbedWorker) Progress {
        const done = self.done.load(.acquire);
        return .{
            .active = self.busy(),
            .done = done,
            // Rows added since the last count can make `done` run ahead.
            .total = @max(done, self.total.load(.acquire)),
        };
    }

    /// Wait until no pass is queued or running (tests, benchmarks).
    pub fn awaitIdle(self: *EmbedWorker) void {
        self.passes.awaitIdle();
    }
};

fn passWorker(q: *bg.WorkQueue(Pass)) void {
    const self: *EmbedWorker = @fieldParentPtr("passes", q);
    // A new run of passes: progress counts from here.
    self.done.store(0, .release);
    self.total.store(0, .release);
    while (q.next()) |_| {
        runPass(self);
        // Stopped (`configure`, shutdown): run it again once resumed.
        if (self.stop.load(.acquire)) q.requeueFront(.{}, Pass.eql);
    }
    // The status bar drops the line.
    if (self.wakeup_fn) |wake| wake();
}

/// One pass over the pending rows, in id order, by a few consumers sharing
/// one cursor.
const PassState = struct {
    worker: *EmbedWorker,
    emb: *embedder_mod.Embedder,
    kinds: EmbedKinds,
    mutex: std.Io.Mutex = .init,
    /// Rows up to this id are claimed this pass.
    cursor: u64 = 0,
    last_count_ns: i96 = 0,

    /// Claim the next batch of pending rows; empty when the pass is done.
    /// Caller frees each row, then the slice.
    fn claim(p: *PassState, conn: *VectorDb) ![]PendingEmbed {
        const w = p.worker;
        p.mutex.lockUncancelable(w.io);
        defer p.mutex.unlock(w.io);
        const rows = try conn.pendingEmbeds(w.allocator, p.kinds, p.cursor, batch_size);
        if (rows.len > 0) p.cursor = rows[rows.len - 1].id;
        if (w.dirty.load(.acquire) and now(w.io) - p.last_count_ns >= recount_interval_ns)
            p.recountLocked(conn);
        return rows;
    }

    /// total = done + pending. Pending includes rows other consumers hold, as
    /// they are not stored (or counted done) yet.
    fn recountLocked(p: *PassState, conn: *VectorDb) void {
        const w = p.worker;
        w.dirty.store(false, .release);
        p.last_count_ns = now(w.io);
        const pending = conn.countPendingEmbeds(p.kinds) catch |err| {
            log.warn("count pending embeddings: {}", .{err});
            return;
        };
        const total = @as(u64, w.done.load(.acquire)) + pending;
        w.total.store(@intCast(@min(total, std.math.maxInt(u32))), .release);
        if (w.wakeup_fn) |wake| wake();
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn runPass(self: *EmbedWorker) void {
    const emb = self.embedder orelse return;
    const kinds: EmbedKinds = .{
        .prompt = self.kinds.prompt and emb.hasPromptEncoder(),
        .image = self.kinds.image and emb.hasVisualEncoder(),
    };
    if (!kinds.any()) return;
    var pass: PassState = .{ .worker = self, .emb = emb, .kinds = kinds };
    {
        var conn = self.db.getConnection() catch |err| {
            log.warn("embedding pass db connection: {}", .{err});
            return;
        };
        defer conn.deinit();
        pass.mutex.lockUncancelable(self.io);
        pass.recountLocked(&conn);
        pass.mutex.unlock(self.io);
    }
    // Several consumers only pay off on the GPU: its forward is serialized by
    // the embed mutex, but image decode (vips) is CPU-heavy and serial within
    // a batch, so a few consumers decode concurrently to keep the GPU fed. On
    // CPU one consumer already uses every core.
    const n_consumers: usize = if (emb.hasGpu()) 4 else 1;
    var group: std.Io.Group = .init;
    var spawned: usize = 0;
    for (0..n_consumers) |_| {
        group.concurrent(self.io, consumer, .{&pass}) catch |err| {
            log.warn("spawn embed consumer: {}", .{err});
            continue;
        };
        spawned += 1;
    }
    if (spawned == 0) consumer(&pass);
    group.await(self.io) catch |err| log.warn("embed consumers await: {}", .{err});
    log.debug("embedding pass done: {d} / {d}", .{ self.done.load(.acquire), self.total.load(.acquire) });
}

fn consumer(p: *PassState) void {
    const w = p.worker;
    var conn = w.db.getConnection() catch |err| {
        log.warn("embed consumer db connection: {}", .{err});
        return;
    };
    defer conn.deinit();
    while (!w.stop.load(.acquire)) {
        // Rows it can't read stay pending, for the next pass.
        const rows = p.claim(&conn) catch |err| {
            log.warn("read pending embeddings: {}", .{err});
            return;
        };
        defer {
            for (rows) |r| r.deinit(w.allocator);
            w.allocator.free(rows);
        }
        if (rows.len == 0) return;
        embedBatch(w.allocator, &conn, p.emb, rows, &w.stop);
        _ = w.done.fetchAdd(@intCast(rows.len), .acq_rel);
        if (w.wakeup_fn) |wake| wake();
    }
}

/// Embed a claimed batch: prompts and images go through the batched embedder
/// as separate sub-batches, then each vector is stored against its row. On a
/// batch-level failure that sub-batch is retried per item (single items route
/// to CPU), so one bad file can't sink the batch. Rows that fail for a reason
/// other than their content stay pending, for the next pass.
pub fn embedBatch(
    allocator: std.mem.Allocator,
    db: *VectorDb,
    emb: *embedder_mod.Embedder,
    rows: []const PendingEmbed,
    stop: *std.atomic.Value(bool),
) void {
    if (emb.hasPromptEncoder()) embedPrompts(allocator, db, emb, rows, stop);
    if (stop.load(.acquire)) return;
    if (emb.hasVisualEncoder()) embedImages(allocator, db, emb, rows, stop);
}

fn embedPrompts(
    allocator: std.mem.Allocator,
    db: *VectorDb,
    emb: *embedder_mod.Embedder,
    rows: []const PendingEmbed,
    stop: *std.atomic.Value(bool),
) void {
    var texts: [batch_size][]const u8 = undefined;
    var text_rows: [batch_size]*const PendingEmbed = undefined;
    var nt: usize = 0;
    // Prompts over the encoder's window: embedded one by one from their
    // chunks (`Embedder.embedPrompt`) after the batch.
    var long_texts: [batch_size][]const u8 = undefined;
    var long_rows: [batch_size]*const PendingEmbed = undefined;
    var nl: usize = 0;
    defer for (texts[0..nt]) |t| allocator.free(t);
    defer for (long_texts[0..nl]) |t| allocator.free(t);
    for (rows) |*row| {
        const raw = row.prompt orelse continue;
        // Strip ComfyUI/A1111 markup so the embedder sees natural language.
        // Out of memory it stays pending, for the next pass.
        const cleaned = prompt_clean.cleanPrompt(allocator, raw) catch |err| {
            log.warn("prompt for {d}: {}", .{ row.id, err });
            continue;
        };
        if (cleaned.len == 0) {
            allocator.free(cleaned);
            skip(db, row, .prompt);
            continue;
        }
        if (!emb.promptFits(allocator, cleaned)) {
            long_texts[nl] = cleaned;
            long_rows[nl] = row;
            nl += 1;
            continue;
        }
        texts[nt] = cleaned;
        text_rows[nt] = row;
        nt += 1;
    }
    if (nt > 0 and !stop.load(.acquire)) {
        if (emb.embedPromptBatch(allocator, texts[0..nt])) |vecs| {
            defer {
                for (vecs) |v| allocator.free(v);
                allocator.free(vecs);
            }
            for (vecs, text_rows[0..nt]) |vec, row| storePrompt(db, row, vec);
        } else |err| {
            log.warn("prompt embed batch failed ({}); retrying per item", .{err});
            for (texts[0..nt], text_rows[0..nt]) |t, row| embedOnePrompt(allocator, db, emb, row, t);
        }
    }
    for (long_texts[0..nl], long_rows[0..nl]) |t, row| {
        if (stop.load(.acquire)) break;
        embedOnePrompt(allocator, db, emb, row, t);
    }
}

fn embedImages(
    allocator: std.mem.Allocator,
    db: *VectorDb,
    emb: *embedder_mod.Embedder,
    rows: []const PendingEmbed,
    stop: *std.atomic.Value(bool),
) void {
    var paths: [batch_size][:0]const u8 = undefined;
    var img_rows: [batch_size]*const PendingEmbed = undefined;
    var ni: usize = 0;
    for (rows) |*row| {
        if (!row.want_image) continue;
        paths[ni] = row.path;
        img_rows[ni] = row;
        ni += 1;
    }
    if (ni == 0) return;
    if (emb.embedImageBatch(allocator, paths[0..ni], stop)) |vecs| {
        defer {
            for (vecs) |v| if (v.len != 0) allocator.free(v);
            allocator.free(vecs);
        }
        // Empty vec = that image failed to decode (skipped, not fatal to the
        // batch); the rest still embedded in one forward. Empty slots are also
        // what a stopped batch returns.
        for (vecs, img_rows[0..ni]) |vec, row| {
            if (vec.len != 0) {
                storeImage(db, row, vec);
            } else if (!stop.load(.acquire)) {
                log.warn("image {d} didn't decode; not embedded until it changes", .{row.id});
                skip(db, row, .image);
            }
        }
    } else |err| {
        log.warn("image embed batch failed ({}); retrying per item", .{err});
        for (img_rows[0..ni]) |row| {
            if (stop.load(.acquire)) break;
            embedOneImage(allocator, db, emb, row);
        }
    }
}

fn storePrompt(db: *VectorDb, row: *const PendingEmbed, vec: []const f32) void {
    const stored = db.storePromptEmbedding(row.id, row.path, row.hash, vec) catch |err| {
        log.warn("store prompt embedding: {}", .{err});
        return;
    };
    if (!stored) log.debug("prompt embedding for {s} dropped: image removed or changed", .{std.Io.Dir.path.basename(row.path)});
}

fn storeImage(db: *VectorDb, row: *const PendingEmbed, vec: []const f32) void {
    const stored = db.storeImageEmbedding(row.id, row.path, row.hash, vec) catch |err| {
        log.warn("store image embedding: {}", .{err});
        return;
    };
    if (!stored) log.debug("image embedding for {s} dropped: image removed or changed", .{std.Io.Dir.path.basename(row.path)});
}

/// Don't offer `row` for a `kind` embedding again until its content changes.
fn skip(db: *VectorDb, row: *const PendingEmbed, kind: VectorDb.EmbedKind) void {
    db.skipEmbed(row.id, row.hash, kind) catch |err|
        log.warn("mark {s} of {d} unembeddable: {} (it's tried again next pass)", .{ @tagName(kind), row.id, err });
}

/// Fallback: embed one already-cleaned prompt (CPU for a short one) and store it.
fn embedOnePrompt(allocator: std.mem.Allocator, db: *VectorDb, emb: *embedder_mod.Embedder, row: *const PendingEmbed, cleaned: []const u8) void {
    if (emb.embedPrompt(allocator, cleaned)) |vec| {
        defer allocator.free(vec);
        storePrompt(db, row, vec);
    } else |err| switch (err) {
        // No chunk of it fits the encoder: nothing to embed.
        error.PromptTooLong => skip(db, row, .prompt),
        else => log.warn("prompt embed for {d} failed ({}); tried again next pass", .{ row.id, err }),
    }
}

/// Fallback: embed one image (CPU) and store it.
fn embedOneImage(allocator: std.mem.Allocator, db: *VectorDb, emb: *embedder_mod.Embedder, row: *const PendingEmbed) void {
    if (emb.embedImage(allocator, row.path)) |vec| {
        defer allocator.free(vec);
        storeImage(db, row, vec);
    } else |err| log.warn("image embed for {d} failed ({}); tried again next pass", .{ row.id, err });
}
