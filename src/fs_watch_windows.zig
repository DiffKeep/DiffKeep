/// NtNotifyChangeDirectoryFileEx-based file system watcher (Windows).
///
/// Creates one thread per library that issues async NtNotifyChangeDirectoryFileEx
/// requests and waits on both the IO completion event and a stop event.
/// Only .png files trigger events.
const std = @import("std");
const windows = std.os.windows;
const log = std.log.scoped(.fs_watch);

// ── NtWaitForMultipleObjects (not in stdlib) ──────────────────────────────────

extern "ntdll" fn NtWaitForMultipleObjects(
    Count: windows.ULONG,
    Handles: [*]const windows.HANDLE,
    WaitType: windows.WAIT_TYPE,
    Alertable: windows.BOOLEAN,
    Timeout: ?*const windows.LARGE_INTEGER,
) callconv(.winapi) windows.NTSTATUS;

const Spinlock = @import("spinlock.zig").Spinlock;

// ── Public types ──────────────────────────────────────────────────────────────

pub const DirtyEvent = struct {
    library_id: u64,
    /// Heap-allocated absolute path.  Caller must free after processing.
    path: []u8,
    deleted: bool,
};

// ── Per-library watch state ───────────────────────────────────────────────────

const LibWatch = struct {
    watcher: *FsWatcher,
    library_id: u64,
    /// Owned copy of the library root path (UTF-8).
    path: []u8,
    dir_handle: windows.HANDLE,
    /// Manual-reset event; set to stop the thread.
    stop_event: windows.HANDLE,
    thread: std.Thread,
    buffer: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.INFORMATION)),
    iosb: windows.IO_STATUS_BLOCK,
};

// ── Public API ────────────────────────────────────────────────────────────────

pub const FsWatcher = struct {
    allocator: std.mem.Allocator,
    dirty_lock: Spinlock = .{},
    dirty_events: std.ArrayList(DirtyEvent) = .empty,
    on_dirty: ?*const fn () void = null,
    watches_lock: Spinlock = .{},
    watches: std.ArrayList(*LibWatch) = .empty,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator) !FsWatcher {
        log.info("initialized (NtNotifyChangeDirectoryFileEx)", .{});
        return .{ .allocator = allocator };
    }

    pub fn start(self: *FsWatcher) !void {
        self.started = true;
    }

    pub fn deinit(self: *FsWatcher) void {
        // Stop and join all watch threads.
        self.watches_lock.lock();
        const watches = self.watches;
        self.watches = .empty;
        self.watches_lock.unlock();

        for (watches.items) |w| {
            stopLibWatch(w);
            self.allocator.free(w.path);
            self.allocator.destroy(w);
        }
        @constCast(&watches).deinit(self.allocator);

        for (self.dirty_events.items) |ev| self.allocator.free(ev.path);
        self.dirty_events.deinit(self.allocator);
    }

    pub fn addLibrary(self: *FsWatcher, library_id: u64, path: []const u8) !void {
        const watch = try self.allocator.create(LibWatch);
        errdefer self.allocator.destroy(watch);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        // Convert UTF-8 path to null-terminated UTF-16.
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path);
        defer self.allocator.free(path_w);

        // Open the directory via NtCreateFile.
        var dir_handle: windows.HANDLE = undefined;
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        const uni = windows.UNICODE_STRING{
            .Length = @intCast(path_w.len * 2),
            .MaximumLength = @intCast((path_w.len + 1) * 2),
            .Buffer = @constCast(path_w.ptr),
        };
        const obj_attrs = windows.OBJECT.ATTRIBUTES{
            .Length = @sizeOf(windows.OBJECT.ATTRIBUTES),
            .RootDirectory = null,
            .ObjectName = @constCast(&uni),
            .Attributes = 0,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        switch (windows.ntdll.NtCreateFile(
            &dir_handle,
            .{
                .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true } },
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{ .READ = true },
            },
            &obj_attrs,
            &iosb,
            null,
            .{},
            .VALID_FLAGS,
            .OPEN,
            .{
                .DIRECTORY_FILE = true,
                .IO = .ASYNCHRONOUS,
                .OPEN_FOR_BACKUP_INTENT = true,
            },
            null,
            0,
        )) {
            .SUCCESS => {},
            .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .NOT_A_DIRECTORY => return error.NotDir,
            .ACCESS_DENIED => return error.AccessDenied,
            else => |rc| return windows.unexpectedStatus(rc),
        }
        errdefer windows.CloseHandle(dir_handle);

        // Create a manual-reset stop event (initially non-signaled).
        var stop_event: windows.HANDLE = undefined;
        switch (windows.ntdll.NtCreateEvent(
            &stop_event,
            .{ .MAXIMUM_ALLOWED = true },
            null,
            .Notification,
            windows.FALSE,
        )) {
            .SUCCESS => {},
            else => |rc| return windows.unexpectedStatus(rc),
        }
        errdefer windows.CloseHandle(stop_event);

        watch.* = .{
            .watcher = self,
            .library_id = library_id,
            .path = path_copy,
            .dir_handle = dir_handle,
            .stop_event = stop_event,
            .thread = undefined,
            .buffer = undefined,
            .iosb = undefined,
        };

        watch.thread = try std.Thread.spawn(.{}, libWatchThread, .{watch});

        self.watches_lock.lock();
        self.watches.append(self.allocator, watch) catch {
            self.watches_lock.unlock();
            // Thread is running; signal stop and join before returning error.
            _ = windows.ntdll.NtSetEvent(stop_event, null);
            watch.thread.join();
            return error.OutOfMemory;
        };
        self.watches_lock.unlock();

        log.info("watching library {} path={s}", .{ library_id, path });
    }

    pub fn removeLibrary(self: *FsWatcher, library_id: u64) void {
        self.watches_lock.lock();
        var idx: ?usize = null;
        for (self.watches.items, 0..) |w, i| {
            if (w.library_id == library_id) { idx = i; break; }
        }
        const watch = if (idx) |i| self.watches.orderedRemove(i) else null;
        self.watches_lock.unlock();

        if (watch) |w| {
            stopLibWatch(w);
            self.allocator.free(w.path);
            self.allocator.destroy(w);
        }
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

// ── Watch thread ──────────────────────────────────────────────────────────────

fn libWatchThread(watch: *LibWatch) void {
    // Create an auto-reset event for IO completion.
    var io_event: windows.HANDLE = undefined;
    switch (windows.ntdll.NtCreateEvent(
        &io_event,
        .{ .MAXIMUM_ALLOWED = true },
        null,
        .Synchronization,
        windows.FALSE,
    )) {
        .SUCCESS => {},
        else => return,
    }
    defer windows.CloseHandle(io_event);

    // Issue initial async notify request.
    switch (windows.ntdll.NtNotifyChangeDirectoryFileEx(
        watch.dir_handle,
        io_event,
        null,
        null,
        &watch.iosb,
        &watch.buffer,
        watch.buffer.len,
        .{ .FILE_NAME = true, .LAST_WRITE = true },
        windows.TRUE,
        .Notify,
    )) {
        .PENDING, .SUCCESS => {},
        else => return,
    }

    const handles = [2]windows.HANDLE{ io_event, watch.stop_event };

    while (true) {
        const status = NtWaitForMultipleObjects(
            2,
            &handles,
            .Any,
            windows.FALSE,
            null,
        );

        switch (status) {
            .SUCCESS => {
                // io_event fired (index 0): process notification.
                processWinNotify(watch);

                // Re-issue the request.
                switch (windows.ntdll.NtNotifyChangeDirectoryFileEx(
                    watch.dir_handle,
                    io_event,
                    null,
                    null,
                    &watch.iosb,
                    &watch.buffer,
                    watch.buffer.len,
                    .{ .FILE_NAME = true, .LAST_WRITE = true },
                    windows.TRUE,
                    .Notify,
                )) {
                    .PENDING, .SUCCESS => {},
                    else => break,
                }
            },
            else => {
                // stop_event signaled or error.
                break;
            },
        }
    }

    // Cancel any pending IO before exiting.
    var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
    _ = windows.ntdll.NtCancelIoFileEx(watch.dir_handle, &watch.iosb, &cancel_iosb);
    // Wait for the IO to complete/cancel.
    _ = windows.ntdll.NtWaitForSingleObject(io_event, windows.FALSE, null);

    log.info("watch thread for library {} stopped", .{watch.library_id});
}

fn processWinNotify(watch: *LibWatch) void {
    const allocator = watch.watcher.allocator;
    const byte_count = watch.iosb.u.Information;
    if (byte_count == 0) return;

    var offset: usize = 0;
    while (offset < byte_count) {
        const info: *windows.FILE.NOTIFY.INFORMATION =
            @ptrCast(@alignCast(&watch.buffer[offset]));

        const filename_w = info.fileName();
        const filename_u8 = std.unicode.utf16LeToUtf8Alloc(allocator, filename_w) catch {
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
            continue;
        };
        defer allocator.free(filename_u8);

        if (std.mem.endsWith(u8, filename_u8, ".png")) {
            const FILE_ACTION_REMOVED: windows.ULONG = 2;
            const FILE_ACTION_RENAMED_OLD_NAME: windows.ULONG = 4;
            const deleted = info.Action == FILE_ACTION_REMOVED or
                info.Action == FILE_ACTION_RENAMED_OLD_NAME;

            // Build full path: watch.path + "\\" + filename_u8
            const full_path = std.mem.concat(allocator, u8, &.{
                watch.path, "\\", filename_u8,
            }) catch {
                if (info.NextEntryOffset == 0) break;
                offset += info.NextEntryOffset;
                continue;
            };

            log.info("win notify: {s} deleted={}", .{ full_path, deleted });
            watch.watcher.pushEvent(.{
                .library_id = watch.library_id,
                .path = full_path,
                .deleted = deleted,
            });
        }

        if (info.NextEntryOffset == 0) break;
        offset += info.NextEntryOffset;
    }
}

fn stopLibWatch(watch: *LibWatch) void {
    _ = windows.ntdll.NtSetEvent(watch.stop_event, null);
    watch.thread.join();
    windows.CloseHandle(watch.dir_handle);
    windows.CloseHandle(watch.stop_event);
}
