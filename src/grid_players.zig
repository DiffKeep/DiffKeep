//! Grid autoplay: live players for the animated/video cells on screen.
//!
//! Live playback of animated/video cells in the grid (opt-in, muted). Currently
//! UNBOUNDED: every visible playable cell gets a player, created as soon as it
//! scrolls into view (no concurrency cap or per-frame open throttle). Off-screen
//! players are still evicted after a short grace so memory/threads don't grow
//! without bound as you scroll.
//!
//! Opening a player does file IO, so a small pool of opener threads does it;
//! the grid asks for players while it renders (`request`), draws them with
//! `draw`, and calls `beginFrame` / `endFrame` around its rows.

const std = @import("std");
const dvui = @import("dvui");
const video_player_mod = @import("video_player.zig");

// Frames decoded to fit this many px (long edge). Kept modest: animated cells are
// decoded whole into an in-memory cache (see the vips anim decoder), so this
// directly bounds per-clip memory, and it's only a grid preview so slight softness
// is fine.
const grid_player_dim = 256;
// Keep a player alive briefly after its cell scrolls off, so scrubbing back and
// forth doesn't thrash open/close (each close joins a decode thread).
const player_evict_grace_frames: u64 = 30;
// Opening a player does file I/O (avformat/vips header read) + spawns a decode
// thread — too slow for the render thread. A small pool opens them off-thread and
// hands the ready player back to be installed on the next frame.
const max_player_openers = 4;

/// A request to open a player for a cell, handed to an opener thread. `path_z` is
/// heap-owned; the opener frees it after use.
const PlayerOpenReq = struct { id: u64, path_z: [:0]u8 };
/// An opened player handed back to the main thread (player == null on open error).
const ReadyPlayer = struct { id: u64, player: ?*video_player_mod.VideoPlayer };

/// A live player bound to one animated/video grid cell. Owns the current decoded
/// frame (packed RGBA8) shown in place of the static thumbnail.
const CellPlayer = struct {
    player: *video_player_mod.VideoPlayer,
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    tex_hash: u64 = 0,
    last_touched: u64 = 0, // player_frame when this cell was last visible
};

pub const PlayerPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    wakeup_fn: ?*const fn () void,
    /// Live players by image id. Main-thread only.
    live: std.AutoHashMap(u64, CellPlayer),
    frame: u64 = 0, // bumped once per frame for touch/evict
    // Background opener pipeline. queue/ready/in_flight are shared with opener
    // threads (guarded by mutex); failed is main-thread only. The queue is
    // rebuilt each frame from the visible cells, like the thumbnail loader's.
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    queue: std.ArrayList(PlayerOpenReq) = .empty,
    ready: std.ArrayList(ReadyPlayer) = .empty,
    in_flight: std.AutoHashMap(u64, void),
    failed: std.AutoHashMap(u64, void), // opens that errored; don't retry
    openers: [max_player_openers]std.Thread = undefined,
    opener_count: usize = 0,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, wakeup_fn: ?*const fn () void) PlayerPool {
        return .{
            .io = io,
            .allocator = allocator,
            .wakeup_fn = wakeup_fn,
            .live = std.AutoHashMap(u64, CellPlayer).init(allocator),
            .in_flight = std.AutoHashMap(u64, void).init(allocator),
            .failed = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    /// Start the opener threads. They idle until a player is requested, so
    /// it's cheap to always have them. Call once the pool is at its final
    /// address.
    pub fn start(self: *PlayerPool) !void {
        const np = @min(std.Thread.getCpuCount() catch 2, max_player_openers);
        for (0..np) |_| {
            self.openers[self.opener_count] = try std.Thread.spawn(.{}, openerFn, .{self});
            self.opener_count += 1;
        }
    }

    /// Stop the openers and free every player. Runs at shutdown, outside any
    /// dvui frame, so it leaves the texture cache alone.
    pub fn deinit(self: *PlayerPool) void {
        self.stop.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        for (0..self.opener_count) |_| self.cond.signal(self.io);
        self.mutex.unlock(self.io);
        for (self.openers[0..self.opener_count]) |t| t.join();

        // No opener threads left, so the pipeline is now ours alone to tear down.
        // Tear down live players first (clearGridPlayersEx still reads failed),
        // then the pipeline maps/lists.
        self.clearGridPlayersEx(false);
        self.live.deinit();
        for (self.queue.items) |r| self.allocator.free(r.path_z);
        self.queue.deinit(self.allocator);
        for (self.ready.items) |rp| if (rp.player) |p| p.deinit();
        self.ready.deinit(self.allocator);
        self.in_flight.deinit();
        self.failed.deinit();
    }

    /// Before the grid draws its rows: with autoplay on, install the players
    /// the openers finished and drop stale open requests; off, tear every
    /// player down and discard opens that land.
    pub fn beginFrame(self: *PlayerPool, autoplay: bool) void {
        if (autoplay) {
            self.frame +%= 1;
            self.syncPlayerPipeline(true);
        } else {
            if (self.live.count() > 0) self.clear(); // just turned off
            self.syncPlayerPipeline(false);
        }
    }

    /// After the rows: evict players whose cell scrolled off. Returns whether
    /// any survivor is still playing (keep the render loop spinning).
    pub fn endFrame(self: *PlayerPool) bool {
        return self.evictStaleCellPlayers();
    }

    /// Advance the (already-open) player for a visible cell and return it so its
    /// current frame can be drawn, or null if no player exists yet (opening, or
    /// never requested). Never opens — that happens off-thread via requestPlayer.
    pub fn draw(self: *PlayerPool, id: u64, now_ns: i128) ?*CellPlayer {
        const cp = self.live.getPtr(id) orelse return null;
        cp.last_touched = self.frame;
        if (cp.player.tick(now_ns)) |frame| {
            if (cp.pixels) |old| {
                dvui.textureInvalidateCache(cp.tex_hash);
                self.allocator.free(old);
            }
            cp.pixels = frame.pixels;
            cp.width = frame.width;
            cp.height = frame.height;
            cp.tex_hash = (dvui.ImageSource{ .pixels = .{
                .rgba = frame.pixels, .width = frame.width, .height = frame.height,
            } }).hash();
        }
        return cp;
    }

    /// Queue an off-thread open for a visible playable cell that has no player yet.
    /// No-op if the open is already in flight or previously failed. The queue is
    /// rebuilt each frame (see syncPlayerPipeline), so only currently-visible cells
    /// stay queued.
    pub fn request(self: *PlayerPool, id: u64, path: []const u8) void {
        if (self.failed.contains(id)) return; // main-thread only; no lock
        const path_z = self.allocator.dupeSentinel(u8, path, 0) catch return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.in_flight.contains(id)) { self.allocator.free(path_z); return; }
        for (self.queue.items) |r| if (r.id == id) { self.allocator.free(path_z); return; };
        self.queue.append(self.allocator, .{ .id = id, .path_z = path_z }) catch {
            self.allocator.free(path_z);
            return;
        };
        self.cond.signal(self.io);
    }

    /// Per-frame pipeline sync: drop stale open requests (visible cells re-queue
    /// during row render) and take the players the openers finished. When
    /// `install` is true, ready players are installed into grid_players; otherwise
    /// (autoplay off) they're discarded. Runs on the main thread.
    fn syncPlayerPipeline(self: *PlayerPool, install: bool) void {
        self.mutex.lockUncancelable(self.io);
        for (self.queue.items) |r| self.allocator.free(r.path_z);
        self.queue.clearRetainingCapacity();
        var ready = self.ready; // move the finished list out from under the lock
        self.ready = .empty;
        self.mutex.unlock(self.io);
        defer ready.deinit(self.allocator);

        for (ready.items) |rp| {
            const player = rp.player orelse {
                if (install) self.failed.put(rp.id, {}) catch {};
                continue;
            };
            if (!install) { player.deinit(); continue; }
            const gop = self.live.getOrPut(rp.id) catch { player.deinit(); continue; };
            if (gop.found_existing) { player.deinit(); continue; } // already have one
            gop.value_ptr.* = .{ .player = player, .last_touched = self.frame };
        }
    }

    /// Free a single cell player (joins its decode thread and releases frames).
    /// `invalidate` drops the frame's cached GPU texture — only valid mid-frame
    /// (dvui requires an active window); the deinit path passes false since the
    /// whole window is being torn down.
    fn destroyCellPlayer(self: *PlayerPool, cp: *CellPlayer, invalidate: bool) void {
        cp.player.deinit();
        if (cp.pixels) |p| {
            if (invalidate) dvui.textureInvalidateCache(cp.tex_hash);
            self.allocator.free(p);
        }
    }

    /// Evict players whose cell hasn't been visible for `player_evict_grace_frames`.
    /// Also returns true if any surviving player is still playing (so the render
    /// loop keeps spinning to advance playback).
    fn evictStaleCellPlayers(self: *PlayerPool) bool {
        var any_playing = false;
        // Collect stale keys first — removing during iteration can invalidate the
        // iterator, and (with no cap) any number may go stale in one frame. Only
        // destroy after collecting, so a player is never freed while its map entry
        // survives (that would be a use-after-free next frame).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.live.iterator();
        while (it.next()) |kv| {
            const cp = kv.value_ptr;
            if (self.frame - cp.last_touched > player_evict_grace_frames) {
                // If the append fails (OOM), leave the entry: it stays alive and is
                // retried next frame — never destroyed-but-orphaned.
                stale.append(self.allocator, kv.key_ptr.*) catch {};
            } else if (cp.player.isPlaying()) {
                any_playing = true;
            }
        }
        for (stale.items) |id| {
            if (self.live.getPtr(id)) |cp| self.destroyCellPlayer(cp, true);
            _ = self.live.remove(id);
        }
        return any_playing;
    }

    /// Tear down all grid players (autoplay turned off, view reloaded, or deinit).
    /// `invalidate` must be false when called outside a dvui frame (deinit).
    /// Also drops any queued (not-yet-opened) requests and the failed-open set;
    /// in-flight opens still complete but their players are discarded on the next
    /// syncPlayerPipeline. (deinit clears the queue itself after joining openers.)
    fn clearGridPlayersEx(self: *PlayerPool, invalidate: bool) void {
        var it = self.live.iterator();
        while (it.next()) |kv| self.destroyCellPlayer(kv.value_ptr, invalidate);
        self.live.clearRetainingCapacity();
        self.failed.clearRetainingCapacity();
    }

    /// Tear down all grid players from within a frame (autoplay off / view reload).
    pub fn clear(self: *PlayerPool) void {
        self.clearGridPlayersEx(true);
    }

    /// Background opener: pops a request, opens the player (file I/O + decode
    /// thread spawn — the work we keep off the render thread), and hands it back.
    fn openerFn(self: *PlayerPool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.stop.load(.acquire))
                self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.stop.load(.acquire)) { self.mutex.unlock(self.io); break; }
            const req = self.queue.orderedRemove(0);
            self.in_flight.put(req.id, {}) catch {};
            self.mutex.unlock(self.io);

            const player = video_player_mod.VideoPlayer.init(self.allocator, self.io, req.path_z, .{
                .wakeup_fn = self.wakeup_fn,
                .audio = false,
                .max_dim = grid_player_dim,
            }) catch null;
            self.allocator.free(req.path_z);

            self.mutex.lockUncancelable(self.io);
            _ = self.in_flight.remove(req.id);
            self.ready.append(self.allocator, .{ .id = req.id, .player = player }) catch {
                self.mutex.unlock(self.io);
                if (player) |p| p.deinit(); // couldn't hand it back; don't leak
                continue;
            };
            self.mutex.unlock(self.io);
            if (self.wakeup_fn) |w| w();
        }
    }

};
