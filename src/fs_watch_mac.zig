/// FSEvents-based file system watcher (macOS / iOS).
///
/// Uses CoreServices FSEventStream for recursive directory watching.
/// CoreServices is loaded dynamically via std.DynLib — no framework linkage needed.
/// A serial GCD dispatch queue serializes all stream operations.
///
/// Only .png files trigger events.
const std = @import("std");
const dispatch = std.c.dispatch;
const log = std.log.scoped(.fs_watch);

// ── CoreFoundation / FSEvents types ──────────────────────────────────────────

const CFAllocatorRef = ?*const opaque {};
const CFArrayRef = *const opaque {};
const CFStringRef = *const opaque {};
const CFTimeInterval = f64;
const CFIndex = i32;

const CFStringEncoding = enum(u32) {
    invalid_id = std.math.maxInt(u32),
    mac_roman = 0,
    windows_latin_1 = 0x500,
    iso_latin_1 = 0x201,
    next_step_latin = 0xB01,
    ascii = 0x600,
    unicode = 0x100,
    utf8 = 0x8000100,
    non_lossy_ascii = 0xBFF,
};

const CFArrayCallBacks = opaque {};

const FSEventStreamRef = *opaque {};
const ConstFSEventStreamRef = *const @typeInfo(FSEventStreamRef).pointer.child;

const FSEventStreamContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?*const fn (info: ?*const anyopaque) callconv(.c) *const anyopaque,
    release: ?*const fn (info: ?*const anyopaque) callconv(.c) void,
    copy_description: ?*const fn (info: ?*const anyopaque) callconv(.c) CFStringRef,
};

const FSEventStreamEventId = enum(u64) {
    since_now = std.math.maxInt(u64),
    _,
};

const FSEventStreamCreateFlags = packed struct(u32) {
    use_cf_types: bool = false,
    no_defer: bool = false,
    watch_root: bool = false,
    ignore_self: bool = false,
    file_events: bool = false,
    _: u27 = 0,
};

const FSEventStreamEventFlags = packed struct(u32) {
    must_scan_sub_dirs: bool,
    user_dropped: bool,
    kernel_dropped: bool,
    event_ids_wrapped: bool,
    history_done: bool,
    root_changed: bool,
    mount: bool,
    unmount: bool,
    item_created: bool,
    item_removed: bool,
    item_inode_meta_mod: bool,
    item_renamed: bool,
    item_modified: bool,
    item_finder_info_mod: bool,
    item_change_owner: bool,
    item_xattr_mod: bool,
    item_is_file: bool,
    item_is_dir: bool,
    item_is_symlink: bool,
    item_is_hardlink: bool,
    item_is_last_hardlink: bool,
    item_cloned: bool,
    _pad: u10 = 0,
};

const FSEventStreamCallback = *const fn (
    stream: ConstFSEventStreamRef,
    client_callback_info: ?*anyopaque,
    num_events: usize,
    event_paths: *anyopaque,
    event_flags: [*]const FSEventStreamEventFlags,
    event_ids: [*]const FSEventStreamEventId,
) callconv(.c) void;

// ── Resolved symbols ──────────────────────────────────────────────────────────

const ResolvedSymbols = struct {
    FSEventStreamCreate: *const fn (
        allocator: CFAllocatorRef,
        callback: FSEventStreamCallback,
        ctx: ?*const FSEventStreamContext,
        paths_to_watch: CFArrayRef,
        since_when: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags,
    ) callconv(.c) FSEventStreamRef,
    FSEventStreamSetDispatchQueue: *const fn (stream: FSEventStreamRef, queue: dispatch.queue_t) callconv(.c) void,
    FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) bool,
    FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    CFStringCreateWithCString: *const fn (
        alloc: CFAllocatorRef,
        c_str: [*:0]const u8,
        encoding: CFStringEncoding,
    ) callconv(.c) CFStringRef,
    CFArrayCreate: *const fn (
        allocator: CFAllocatorRef,
        values: [*]const usize,
        num_values: CFIndex,
        call_backs: ?*const CFArrayCallBacks,
    ) callconv(.c) CFArrayRef,
    CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
};

const Spinlock = @import("spinlock.zig").Spinlock;

// ── Public types ──────────────────────────────────────────────────────────────

pub const DirtyEvent = struct {
    library_id: u64,
    /// Heap-allocated absolute path.  Caller must free after processing.
    path: []u8,
    deleted: bool,
};

// ── Internal context types ────────────────────────────────────────────────────

/// Per-stream context; heap-allocated, lives as long as the stream is active.
const StreamCtx = struct {
    watcher: *FsWatcher,
    library_id: u64,
    /// Null-terminated, owned by this struct.
    path: [:0]u8,
};

const StreamEntry = struct {
    stream: FSEventStreamRef,
    ctx: *StreamCtx,
};

/// Heap-allocated ctx for async addLibrary dispatch.
const AddCtx = struct {
    watcher: *FsWatcher,
    library_id: u64,
    path: [:0]u8, // owned
};

/// Heap-allocated ctx for async removeLibrary dispatch.
const RemoveCtx = struct {
    watcher: *FsWatcher,
    library_id: u64,
};

// ── Public API ────────────────────────────────────────────────────────────────

pub const FsWatcher = struct {
    allocator: std.mem.Allocator,
    dirty_lock: Spinlock = .{},
    dirty_events: std.ArrayList(DirtyEvent) = .empty,
    on_dirty: ?*const fn () void = null,
    core_services: std.DynLib,
    rs: ResolvedSymbols,
    dispatch_queue: dispatch.queue_t,
    /// Maps library_id → StreamEntry.
    streams: std.AutoHashMap(u64, StreamEntry),

    pub fn init(allocator: std.mem.Allocator) !FsWatcher {
        var core_services = std.DynLib.open(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        ) catch return error.OpenFrameworkFailed;
        errdefer core_services.close();

        var rs: ResolvedSymbols = undefined;
        inline for (@typeInfo(ResolvedSymbols).@"struct".fields) |f| {
            @field(rs, f.name) = core_services.lookup(f.type, f.name) orelse
                return error.MissingCoreServicesSymbol;
        }

        const q = dispatch.queue_create("diffkeep-fswatch", dispatch.QUEUE_SERIAL()) orelse
            return error.SystemResources;

        log.info("initialized (FSEvents + GCD)", .{});
        return .{
            .allocator = allocator,
            .core_services = core_services,
            .rs = rs,
            .dispatch_queue = q,
            .streams = std.AutoHashMap(u64, StreamEntry).init(allocator),
        };
    }

    /// No-op: GCD handles threading.
    pub fn start(self: *FsWatcher) !void {
        _ = self;
    }

    pub fn deinit(self: *FsWatcher) void {
        // Stop/release all streams synchronously on the serial queue.
        dispatch.sync_f(self.dispatch_queue, self, deinitOnQueue);
        // Release the queue itself.
        self.dispatch_queue.as_object().release();
        self.core_services.close();
        for (self.dirty_events.items) |ev| self.allocator.free(ev.path);
        self.dirty_events.deinit(self.allocator);
        self.streams.deinit();
    }

    pub fn addLibrary(self: *FsWatcher, library_id: u64, path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(path_z);
        const ctx = try self.allocator.create(AddCtx);
        ctx.* = .{ .watcher = self, .library_id = library_id, .path = path_z };
        dispatch.async_f(self.dispatch_queue, ctx, doAddLibrary);
    }

    pub fn removeLibrary(self: *FsWatcher, library_id: u64) void {
        const ctx = self.allocator.create(RemoveCtx) catch return;
        ctx.* = .{ .watcher = self, .library_id = library_id };
        dispatch.async_f(self.dispatch_queue, ctx, doRemoveLibrary);
    }

    /// Drain all pending file events.  The caller owns each DirtyEvent.path
    /// slice and must free it after processing.
    pub fn drainEvents(self: *FsWatcher) std.ArrayList(DirtyEvent) {
        self.dirty_lock.lock();
        const list = self.dirty_events;
        self.dirty_events = .empty;
        self.dirty_lock.unlock();
        return list;
    }

    fn pushEvent(self: *FsWatcher, ev: DirtyEvent) void {
        self.dirty_lock.lock();
        self.dirty_events.append(self.allocator, ev) catch {
            self.dirty_lock.unlock();
            self.allocator.free(ev.path);
            return;
        };
        self.dirty_lock.unlock();
        if (self.on_dirty) |cb| cb();
    }
};

// ── GCD callbacks ─────────────────────────────────────────────────────────────

fn doAddLibrary(raw: ?*anyopaque) callconv(.c) void {
    const add_ctx: *AddCtx = @ptrCast(@alignCast(raw));
    const watcher = add_ctx.watcher;
    const allocator = watcher.allocator;
    defer allocator.destroy(add_ctx);

    const rs = watcher.rs;

    // Build CFString for path.
    const cf_str = rs.CFStringCreateWithCString(null, add_ctx.path.ptr, .utf8);
    defer rs.CFRelease(cf_str);

    // Build CFArray of one path.
    const values = [1]usize{@intFromPtr(cf_str)};
    const cf_array = rs.CFArrayCreate(null, &values, 1, null);
    defer rs.CFRelease(cf_array);

    // Allocate StreamCtx.
    const stream_ctx = allocator.create(StreamCtx) catch {
        allocator.free(add_ctx.path);
        return;
    };
    stream_ctx.* = .{
        .watcher = watcher,
        .library_id = add_ctx.library_id,
        .path = add_ctx.path,
    };

    // Create the FSEventStream.
    const stream = rs.FSEventStreamCreate(
        null,
        &fseventsCallback,
        &.{
            .version = 0,
            .info = stream_ctx,
            .retain = null,
            .release = null,
            .copy_description = null,
        },
        cf_array,
        .since_now,
        0.05,
        .{ .no_defer = true, .file_events = true },
    );

    rs.FSEventStreamSetDispatchQueue(stream, watcher.dispatch_queue);
    _ = rs.FSEventStreamStart(stream);

    watcher.streams.put(add_ctx.library_id, .{ .stream = stream, .ctx = stream_ctx }) catch {
        rs.FSEventStreamStop(stream);
        rs.FSEventStreamInvalidate(stream);
        rs.FSEventStreamRelease(stream);
        allocator.free(stream_ctx.path);
        allocator.destroy(stream_ctx);
        return;
    };

    log.info("FSEvents: watching library {} path={s}", .{ add_ctx.library_id, add_ctx.path });
}

fn doRemoveLibrary(raw: ?*anyopaque) callconv(.c) void {
    const rem_ctx: *RemoveCtx = @ptrCast(@alignCast(raw));
    const watcher = rem_ctx.watcher;
    const allocator = watcher.allocator;
    defer allocator.destroy(rem_ctx);

    stopAndFreeStream(watcher, rem_ctx.library_id);
}

fn deinitOnQueue(raw: ?*anyopaque) callconv(.c) void {
    const watcher: *FsWatcher = @ptrCast(@alignCast(raw));
    var it = watcher.streams.keyIterator();
    // Collect keys first to avoid mutation during iteration.
    var keys_buf: [256]u64 = undefined;
    var count: usize = 0;
    while (it.next()) |k| {
        if (count < keys_buf.len) {
            keys_buf[count] = k.*;
            count += 1;
        }
    }
    for (keys_buf[0..count]) |lib_id| {
        stopAndFreeStream(watcher, lib_id);
    }
    watcher.streams.clearRetainingCapacity();
}

fn stopAndFreeStream(watcher: *FsWatcher, library_id: u64) void {
    const entry = watcher.streams.fetchRemove(library_id) orelse return;
    const rs = watcher.rs;
    rs.FSEventStreamStop(entry.value.stream);
    rs.FSEventStreamInvalidate(entry.value.stream);
    rs.FSEventStreamRelease(entry.value.stream);
    watcher.allocator.free(entry.value.ctx.path);
    watcher.allocator.destroy(entry.value.ctx);
    log.info("FSEvents: stopped watching library {}", .{library_id});
}

// ── FSEvents callback ─────────────────────────────────────────────────────────

fn fseventsCallback(
    stream: ConstFSEventStreamRef,
    client_callback_info: ?*anyopaque,
    num_events: usize,
    event_paths_ptr: *anyopaque,
    event_flags_ptr: [*]const FSEventStreamEventFlags,
    event_ids_ptr: [*]const FSEventStreamEventId,
) callconv(.c) void {
    _ = stream;
    _ = event_ids_ptr;

    const ctx: *StreamCtx = @ptrCast(@alignCast(client_callback_info));
    const watcher = ctx.watcher;
    const allocator = watcher.allocator;

    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(event_paths_ptr));
    const flags = event_flags_ptr[0..num_events];
    const path_arr = paths[0..num_events];

    for (path_arr, flags) |raw_path, f| {
        if (f.history_done) continue;
        if (!f.item_is_file) continue;

        const event_path = std.mem.span(raw_path);
        if (!std.mem.endsWith(u8, event_path, ".png")) continue;

        const deleted = f.item_removed or f.item_renamed;

        const path_copy = allocator.dupe(u8, event_path) catch continue;
        log.info("FSEvents: file event {s} deleted={}", .{ event_path, deleted });
        watcher.pushEvent(.{
            .library_id = ctx.library_id,
            .path = path_copy,
            .deleted = deleted,
        });
    }
}
