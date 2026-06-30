const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const platform = @import("platform.zig");
const library_manager_mod = @import("library_manager.zig");
const image_grid_mod = @import("image_grid.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

/// Highlight background options for a selected sidebar row; empty when not selected.
fn focusBg(selected: bool) dvui.Options {
    return if (selected) .{ .background = true, .color_fill = dvui.themeGet().focus } else .{};
}

pub const LibraryState = struct {
    id: u64,
    path: []const u8, // owned
    image_count: i64 = 0,
    expanded: bool = false,
    top_folders: []FolderNode = &.{}, // immediate subdirs of library root; owned
    top_loaded: bool = false,

    pub fn deinit(self: *LibraryState, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        freeFolderNodes(allocator, self.top_folders);
    }
};

pub const FolderNode = struct {
    path: []const u8, // full absolute path, heap-allocated, owned
    count: i64,
    has_children: bool = false, // whether this folder has subdirectories (known before expanding)
    children: []FolderNode = &.{}, // heap-allocated; empty until loaded
    loaded: bool = false,
    expanded: bool = false,
};

pub fn freeFolderNodes(allocator: std.mem.Allocator, nodes: []FolderNode) void {
    for (nodes) |*n| {
        allocator.free(n.path);
        freeFolderNodes(allocator, n.children);
    }
    if (nodes.len > 0) allocator.free(nodes);
}

pub const SidebarState = struct {
    library_dialog_open: bool = false,
    pending_library_buf: [4096]u8 = undefined,
    pending_library_len: usize = 0,
    libraries: std.ArrayList(LibraryState) = .empty,
    confirm_remove_idx: ?usize = null,
    filter_library_id: ?u64 = null,
    filter_folder: ?[]const u8 = null, // heap-allocated, owned

    pub fn deinit(self: *SidebarState, gpa: std.mem.Allocator) void {
        for (self.libraries.items) |*lib| lib.deinit(gpa);
        self.libraries.deinit(gpa);
        if (self.filter_folder) |f| gpa.free(f);
    }

    pub fn loadLibraries(self: *SidebarState, gpa: std.mem.Allocator, db: *db_mod.VectorDb) !void {
        if (db.listLibraries(gpa)) |libs| {
            defer {
                for (libs) |li| gpa.free(li.path);
                gpa.free(libs);
            }
            for (libs) |li| {
                const count = db.getLibraryImageCount(li.id) catch 0;
                try self.libraries.append(gpa, .{
                    .id = li.id,
                    .path = try gpa.dupe(u8, li.path),
                    .image_count = count,
                });
            }
        } else |_| {}
    }

    pub fn refreshLibraryCounts(self: *SidebarState, db: *db_mod.VectorDb, gpa: std.mem.Allocator) void {
        for (self.libraries.items) |*lib| {
            lib.image_count = db.getLibraryImageCount(lib.id) catch 0;
            if (lib.top_loaded) {
                freeFolderNodes(gpa, lib.top_folders);
                lib.top_folders = &.{};
                lib.top_loaded = false;
            }
        }
    }

    pub fn drainPendingLibrary(
        self: *SidebarState,
        gpa: std.mem.Allocator,
        io: std.Io,
        library_manager: ?*library_manager_mod.LibraryManager,
        db: ?*db_mod.VectorDb,
    ) !void {
        if (self.pending_library_len == 0) return;
        const path = self.pending_library_buf[0..self.pending_library_len];
        self.pending_library_len = 0;
        const duped = try gpa.dupe(u8, path);
        const lib_id: u64 = if (library_manager) |mgr|
            mgr.addLibrary(io, duped) catch 0
        else if (db) |d|
            d.storeLibrary(duped) catch 0
        else
            0;
        try self.libraries.append(gpa, .{
            .id = lib_id,
            .path = duped,
            .image_count = 0,
        });
    }

    /// Platform-agnostic folder-picker result handler. Invoked by the platform
    /// seam (real native dialog in production, never called in headless tests).
    fn onFolderPicked(userdata: ?*anyopaque, path: ?[]const u8) void {
        const self: *SidebarState = @ptrCast(@alignCast(userdata orelse return));
        self.library_dialog_open = false;
        const p = path orelse return;
        const len = @min(p.len, self.pending_library_buf.len);
        @memcpy(self.pending_library_buf[0..len], p[0..len]);
        self.pending_library_len = len;
    }

    fn renderFolderNode(
        self: *SidebarState,
        node: *FolderNode,
        lib: *LibraryState,
        depth: usize,
        gpa: std.mem.Allocator,
        db: ?*db_mod.VectorDb,
        grid: ?*image_grid_mod.GridState,
    ) void {
        const in_lib_view = if (grid) |g| g.view_mode == .library else false;
        const indent_x: f32 = 8.0 + @as(f32, @floatFromInt(depth)) * 14.0;
        const node_id_extra: usize = @truncate(std.hash.Fnv1a_32.hash(node.path));

        const is_selected = in_lib_view and
            self.filter_library_id == lib.id and
            self.filter_folder != null and
            std.mem.eql(u8, self.filter_folder.?, node.path);

        const row_bg = focusBg(is_selected);

        // Before a folder is expanded we rely on the has_children flag computed
        // at list time; once loaded, trust the actual children we found.
        const may_have_children = if (node.loaded) node.children.len > 0 else node.has_children;

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, row_bg.override(.{
                .id_extra = node_id_extra,
                .expand = .horizontal,
                .padding = .{ .x = indent_x, .y = 1, .w = 4, .h = 1 },
            }));
            defer row.deinit();

            if (dvui.clickedEx(row.data(), .{})) |_| {
                if (may_have_children or node.expanded) {
                    node.expanded = !node.expanded;
                    if (node.expanded and !node.loaded) {
                        if (db) |d| {
                            if (d.listImmediateSubdirs(gpa, lib.id, node.path)) |subs| {
                                if (gpa.alloc(FolderNode, subs.len)) |new_nodes| {
                                    for (subs, 0..) |s, i| {
                                        new_nodes[i] = .{ .path = s.path, .count = s.count, .has_children = s.has_children };
                                    }
                                    gpa.free(subs);
                                    node.children = new_nodes;
                                } else |_| {
                                    for (subs) |s| gpa.free(s.path);
                                    gpa.free(subs);
                                }
                            } else |_| {}
                            node.loaded = true;
                        }
                    }
                }
                if (self.filter_folder) |f| gpa.free(f);
                self.filter_folder = gpa.dupe(u8, node.path) catch null;
                self.filter_library_id = lib.id;
                if (grid) |g| {
                    g.filter_library_id = lib.id;
                    g.filter_folder_path = self.filter_folder;
                    g.filter_library_path = lib.path;
                    g.view_mode = .library;
                    if (db) |d| g.reloadImages(d) catch {};
                }
            }

            if (may_have_children or node.expanded) {
                const tvg = if (node.expanded) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right";
                dvui.icon(@src(), "expand", tvg, .{}, .{
                    .id_extra = node_id_extra,
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                });
            } else {
                _ = dvui.spacer(@src(), .{
                    .id_extra = node_id_extra,
                    .min_size_content = .{ .w = 12, .h = 0 },
                });
            }

            dvui.label(@src(), "{s}", .{std.fs.path.basename(node.path)}, .{
                .id_extra = node_id_extra,
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            dvui.label(@src(), "{d}", .{node.count}, .{
                .id_extra = node_id_extra +% 1,
                .gravity_y = 0.5,
                .padding = .{ .x = 4, .w = 0 },
            });
        }

        if (node.expanded) {
            for (node.children) |*child| {
                self.renderFolderNode(child, lib, depth + 1, gpa, db, grid);
            }
        }
    }

    /// Render the left sidebar. Returns true if image counts need a refresh.
    pub fn render(
        self: *SidebarState,
        panel_w: f32,
        gpa: std.mem.Allocator,
        db: ?*db_mod.VectorDb,
        grid: ?*image_grid_mod.GridState,
        library_manager: ?*library_manager_mod.LibraryManager,
        cfg_trash_enabled: bool,
        trash_stats: ?db_mod.TrashStats,
        duplicate_count: i64,
    ) !bool {
        var needs_count_refresh = false;

        var sidebar = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = panel_w, .h = 0 },
            .expand = .vertical,
            .background = true,
        });
        defer sidebar.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        // ── "Library" master header (clears filter, shows all) ───────────
        {
            const in_library = if (grid) |g| g.view_mode == .library else true;
            const unfiltered = self.filter_library_id == null and self.filter_folder == null;
            const bg = focusBg(in_library and unfiltered);
            var lib_hdr = dvui.box(@src(), .{ .dir = .horizontal }, bg.override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 4, .w = 4, .h = 4 },
            }));
            defer lib_hdr.deinit();
            {
                var lbl_area = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 0.5 });
                defer lbl_area.deinit();
                if (dvui.clickedEx(lbl_area.data(), .{})) |_| {
                    if (self.filter_folder) |f| gpa.free(f);
                    self.filter_folder = null;
                    self.filter_library_id = null;
                    if (grid) |g| {
                        g.filter_library_id = null;
                        g.filter_folder_path = null;
                        g.filter_library_path = null;
                        g.view_mode = .library;
                        if (db) |d| g.reloadImages(d) catch {};
                    }
                }
                dvui.label(@src(), "{s}", .{i18n.t(.nav_library)}, .{ .font = bold, .gravity_y = 0.5 });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            }
            if (dvui.buttonIcon(@src(), "add library", dvui.entypo.plus, .{}, .{}, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(3),
            })) {
                if (!self.library_dialog_open) {
                    self.library_dialog_open = true;
                    platform.openFolderDialog(self, SidebarState.onFolderPicked);
                }
            }
        }

        if (self.libraries.items.len == 0) {
            dvui.label(@src(), "{s}", .{i18n.t(.library_empty)}, .{ .padding = .all(8) });
        } else {
            for (self.libraries.items, 0..) |*lib, idx| {
                const in_lib_view = if (grid) |g| g.view_mode == .library else false;
                const lib_selected = self.filter_library_id == lib.id and self.filter_folder == null;

                var row_hov = false;
                {
                    const lib_bg = focusBg(lib_selected and in_lib_view);
                    var lib_row = dvui.box(@src(), .{ .dir = .horizontal }, lib_bg.override(.{
                        .id_extra = idx,
                        .expand = .horizontal,
                        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    }));
                    defer lib_row.deinit();

                    const row_id = lib_row.data().id;
                    row_hov = dvui.dataGet(null, row_id, "_hov", bool) orelse false;
                    for (dvui.events()) |*e| {
                        if (e.evt == .mouse and e.evt.mouse.action == .position)
                            row_hov = dvui.eventMatchSimple(e, lib_row.data());
                    }
                    dvui.dataSet(null, row_id, "_hov", row_hov);

                    const expand_tvg = if (lib.expanded) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right";
                    if (dvui.buttonIcon(@src(), "expand", expand_tvg, .{}, .{}, .{
                        .id_extra = idx,
                        .min_size_content = .{ .w = 14, .h = 14 },
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(2),
                        .margin = .{},
                    })) {
                        lib.expanded = !lib.expanded;
                        if (lib.expanded and !lib.top_loaded) {
                            if (db) |d| {
                                if (d.listImmediateSubdirs(gpa, lib.id, lib.path)) |subs| {
                                    if (gpa.alloc(FolderNode, subs.len)) |new_nodes| {
                                        for (subs, 0..) |s, i| {
                                            new_nodes[i] = .{ .path = s.path, .count = s.count, .has_children = s.has_children };
                                        }
                                        gpa.free(subs);
                                        lib.top_folders = new_nodes;
                                    } else |_| {
                                        for (subs) |s| gpa.free(s.path);
                                        gpa.free(subs);
                                    }
                                } else |_| {}
                                lib.top_loaded = true;
                            }
                        }
                    }

                    {
                        var name_area = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = idx,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                        });
                        defer name_area.deinit();
                        if (dvui.clickedEx(name_area.data(), .{})) |_| {
                            if (self.filter_folder) |f| gpa.free(f);
                            self.filter_folder = null;
                            self.filter_library_id = lib.id;
                            if (grid) |g| {
                                g.filter_library_id = lib.id;
                                g.filter_folder_path = null;
                                g.filter_library_path = lib.path;
                                g.view_mode = .library;
                                if (db) |d| g.reloadImages(d) catch {};
                            }
                        }
                        dvui.label(@src(), "{s}", .{std.fs.path.basename(lib.path)}, .{
                            .id_extra = idx,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                        });
                    }

                    dvui.label(@src(), "{d}", .{lib.image_count}, .{
                        .id_extra = idx,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 4, .w = 0 },
                    });

                    if (row_hov) {
                        if (dvui.buttonIcon(@src(), "remove library", dvui.entypo.minus, .{}, .{}, .{
                            .id_extra = idx,
                            .min_size_content = .{ .w = 10, .h = 10 },
                            .gravity_y = 0.5,
                            .padding = dvui.Rect.all(2),
                        })) {
                            self.confirm_remove_idx = idx;
                        }
                    }
                }

                if (lib.expanded) {
                    for (lib.top_folders) |*node| {
                        self.renderFolderNode(node, lib, 1, gpa, db, grid);
                    }
                }
            }
        }

        // ── Trash section ─────────────────────────────────────────────────
        if (cfg_trash_enabled) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 8 } });

            const in_trash = if (grid) |g| g.view_mode == .trash else false;
            const trash_bg = focusBg(in_trash);
            var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, trash_bg.override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .tag = "nav-trash",
            }));
            defer trash_row.deinit();
            if (dvui.clickedEx(trash_row.data(), .{})) |_| {
                if (grid) |g| {
                    if (g.view_mode != .trash) {
                        g.view_mode = .trash;
                        if (db) |d| g.reloadImages(d) catch {};
                    }
                }
            }
            dvui.label(@src(), "{s}", .{i18n.t(.sidebar_trash)}, .{ .font = bold, .gravity_y = 0.5 });
            if (trash_stats) |ts| {
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                dvui.label(@src(), "{d}", .{ts.count}, .{ .gravity_y = 0.5 });
            }
        }

        // ── Duplicates section (always shown, like Trash) ─────────────────
        {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 8 } });

            const in_dupes = if (grid) |g| g.view_mode == .duplicates else false;
            const dupes_bg = focusBg(in_dupes);
            var dupes_row = dvui.box(@src(), .{ .dir = .horizontal }, dupes_bg.override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .tag = "nav-duplicates",
            }));
            defer dupes_row.deinit();
            if (dvui.clickedEx(dupes_row.data(), .{})) |_| {
                if (grid) |g| {
                    if (g.view_mode != .duplicates) {
                        g.view_mode = .duplicates;
                        if (db) |d| g.reloadImages(d) catch {};
                    }
                }
            }
            dvui.label(@src(), "{s}", .{i18n.t(.sidebar_duplicates)}, .{ .font = bold, .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            dvui.label(@src(), "{d}", .{duplicate_count}, .{ .gravity_y = 0.5 });
        }

        // ── Library removal confirmation modal ───────────────────────────
        if (self.confirm_remove_idx) |idx| {
            if (idx < self.libraries.items.len) {
                const lib = &self.libraries.items[idx];
                const name = std.fs.path.basename(lib.path);

                var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
                    .min_size_content = .{ .w = 360, .h = 0 },
                });
                defer float.deinit();
                float.autoSize();

                var content = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .padding = .all(16),
                });
                defer content.deinit();

                dvui.label(@src(), "{s}", .{i18n.t(.library_remove_title)}, .{ .font = bold, .margin = .{ .h = 6 } });
                dvui.label(@src(), "{s}", .{name}, .{});
                dvui.label(@src(), "{s}", .{lib.path}, .{ .margin = .{ .h = 14 } });

                {
                    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
                    defer btn_row.deinit();

                    if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
                        self.confirm_remove_idx = null;
                    }
                    if (dvui.button(@src(), i18n.t(.action_remove), .{}, .{ .margin = .all(4) })) {
                        self.confirm_remove_idx = null;
                        var removed = self.libraries.orderedRemove(idx);
                        const removed_id = removed.id;
                        if (library_manager) |mgr| {
                            mgr.removeLibrary(removed.path) catch {};
                        } else if (db) |d| {
                            _ = d.removeLibrary(removed.path) catch {};
                        }
                        removed.deinit(gpa);
                        if (self.filter_library_id == removed_id) {
                            if (self.filter_folder) |f| gpa.free(f);
                            self.filter_folder = null;
                            self.filter_library_id = null;
                            if (grid) |g| {
                                g.filter_library_id = null;
                                g.filter_folder_path = null;
                                g.filter_library_path = null;
                            }
                        }
                        if (grid) |g| {
                            if (db) |d| g.reloadImages(d) catch {};
                        }
                        needs_count_refresh = true;
                    }
                }
            } else {
                self.confirm_remove_idx = null;
            }
        }

        return needs_count_refresh;
    }
};
