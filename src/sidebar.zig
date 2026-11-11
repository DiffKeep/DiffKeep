const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const i18n = @import("i18n.zig");
const log = std.log.scoped(.sidebar);
const icons = @import("icons");
const app_icons = @import("app_icons.zig");
const platform = @import("platform.zig");
const library_manager_mod = @import("library_manager.zig");
const counts_mod = @import("counts.zig");
const folder_loader_mod = @import("folder_loader.zig");
const image_grid_mod = @import("image_grid.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");

/// Background options for a sidebar row.
///
/// A selected row is a raised slab with a blue left edge, not a saturated blue
/// fill: the sidebar is read top to bottom and a solid accent bar in the middle
/// of that column reads as an error before it reads as "you are here". The
/// accent is on the edge, where the eye tracks the column.
/// Width and height of the hover-only remove button's reserved slot. Must be at
/// least the button's own footprint (10px icon + 2px padding each side).
const remove_slot: f32 = 16;

/// The border and the fill are ALWAYS present, and only their colours change.
/// A border occupies space, so giving one only to the selected row would shift
/// every label 2px sideways as the selection moves down the list.
fn rowBg(selected: bool) dvui.Options {
    return .{
        .background = true,
        .color_fill = .{ .color = if (selected) style.C.sel_row else style.C.rail },
        .border = .{ .x = 2 },
        .color_border = .{ .color = if (selected) style.C.blue else style.C.rail },
        .corners = style.R.chip,
    };
}

/// Colour for a row's title: bright when it is the selected one, dim otherwise.
/// Shape carries the selection; colour only confirms it.
fn rowText(selected: bool) dvui.Color {
    return if (selected) style.C.text_hi else style.C.text_dim;
}

/// A row's right-aligned image count. Monospaced because these are figures a
/// user compares down the column, and faint because none of them is the point.
fn countLabel(src: std.builtin.SourceLocation, count: i64, id_extra: usize) void {
    dvui.label(src, "{d}", .{count}, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .padding = .{ .x = 6, .w = 2 },
        .font = style.F.mono,
        .color_text = .{ .color = style.C.text_faint },
    });
}

pub const LibraryState = struct {
    id: u64,
    path: []const u8, // owned
    image_count: i64 = 0,
    expanded: bool = false,
    top_folders: []FolderNode = &.{}, // immediate subdirs of library root; owned
    top_loaded: bool = false,
    top_requested: bool = false, // a background load of `top_folders` is queued

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
    requested: bool = false, // a background load of `children` is queued
    expanded: bool = false,
};

pub fn freeFolderNodes(allocator: std.mem.Allocator, nodes: []FolderNode) void {
    for (nodes) |*n| {
        allocator.free(n.path);
        freeFolderNodes(allocator, n.children);
    }
    if (nodes.len > 0) allocator.free(nodes);
}

/// Build the new list of folder rows from a fresh load, carrying each
/// folder's expanded state and loaded children over from `old` by path, so a
/// refresh doesn't collapse the tree. Takes ownership of `fresh` (and its
/// paths) and frees `old`; on failure `old` is left as it was.
fn mergeFolders(gpa: std.mem.Allocator, old: []FolderNode, fresh: []folder_loader_mod.FolderCount) ![]FolderNode {
    const nodes = gpa.alloc(FolderNode, fresh.len) catch |err| {
        for (fresh) |f| gpa.free(f.path);
        gpa.free(fresh);
        return err;
    };
    for (fresh, nodes) |f, *n| {
        n.* = .{ .path = f.path, .count = f.count, .has_children = f.has_children };
        for (old) |*o| {
            if (!std.mem.eql(u8, o.path, f.path)) continue;
            n.expanded = o.expanded;
            n.loaded = o.loaded;
            n.requested = o.requested;
            n.children = o.children;
            o.children = &.{};
            break;
        }
    }
    gpa.free(fresh);
    freeFolderNodes(gpa, old);
    return nodes;
}

/// The node for folder `path` in `nodes`' subtree, if it is there.
fn findFolder(nodes: []FolderNode, path: []const u8) ?*FolderNode {
    for (nodes) |*n| {
        if (std.mem.eql(u8, n.path, path)) return n;
        if (std.mem.startsWith(u8, path, n.path) and path.len > n.path.len and path[n.path.len] == '/')
            return findFolder(n.children, path);
    }
    return null;
}

pub const SidebarState = struct {
    // The folder dialog's callback may run on another thread (SDL documents
    // this), so it publishes its result through atomics: the buffer is written
    // before `pending_library_len` is stored (release) and read after it is
    // loaded (acquire).
    library_dialog_open: std.atomic.Value(bool) = .init(false),
    pending_library_buf: [4096]u8 = undefined,
    pending_library_len: std.atomic.Value(usize) = .init(0),
    /// Wakes the render loop when the folder dialog resolves.
    wakeup_fn: ?*const fn () void = null,
    libraries: std.ArrayList(LibraryState) = .empty,
    confirm_remove_idx: ?usize = null,
    /// Why the last i18n.t(.a11y_add_library) was refused; shown until the next attempt.
    add_error: ?[:0]const u8 = null,
    filter_library_id: ?u64 = null,
    filter_folder: ?[]const u8 = null, // heap-allocated, owned
    /// Loads folder lists in the background. Set with `initFolderLoader`;
    /// without it the library trees stay empty.
    folders: ?folder_loader_mod.FolderLoader = null,

    pub fn initFolderLoader(self: *SidebarState, gpa: std.mem.Allocator, io: std.Io, db: *db_mod.VectorDb) void {
        self.folders = folder_loader_mod.FolderLoader.init(gpa, io, db);
        self.folders.?.wakeup_fn = self.wakeup_fn;
    }

    pub fn deinit(self: *SidebarState, gpa: std.mem.Allocator) void {
        if (self.folders) |*f| f.deinit();
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

    /// Show freshly loaded per-library counts (from counts.zig). An open
    /// library whose count changed has its loaded folder lists reloaded, so
    /// their counts stay current; the tree keeps its shape meanwhile.
    pub fn applyLibraryCounts(self: *SidebarState, counts: []const counts_mod.LibraryCount) void {
        for (self.libraries.items) |*lib| {
            for (counts) |c| {
                if (c.id != lib.id or c.count == lib.image_count) continue;
                lib.image_count = c.count;
                if (lib.top_loaded) self.requestLoadedFolders(lib);
            }
        }
    }

    /// Queue a reload of every folder list of `lib` that is loaded.
    fn requestLoadedFolders(self: *SidebarState, lib: *LibraryState) void {
        const loader = if (self.folders) |*f| f else return;
        loader.request(lib.id, lib.path);
        requestLoadedNodes(loader, lib.id, lib.top_folders);
    }

    fn requestLoadedNodes(loader: *folder_loader_mod.FolderLoader, library_id: u64, nodes: []FolderNode) void {
        for (nodes) |*n| {
            if (!n.loaded) continue;
            loader.request(library_id, n.path);
            requestLoadedNodes(loader, library_id, n.children);
        }
    }

    /// Main thread: put finished folder loads into the trees. A list for a
    /// library or folder that is no longer shown is dropped.
    pub fn applyFolderResults(self: *SidebarState, gpa: std.mem.Allocator) void {
        const loader = if (self.folders) |*f| f else return;
        const results = loader.take();
        defer gpa.free(results);
        for (results) |r| {
            defer gpa.free(r.path);
            const lib = for (self.libraries.items) |*l| {
                if (l.id == r.library_id) break l;
            } else null;
            const is_root = if (lib) |l| std.mem.eql(u8, l.path, r.path) else false;
            const node: ?*FolderNode = if (lib) |l| (if (is_root) null else findFolder(l.top_folders, r.path)) else null;
            if (is_root) lib.?.top_requested = false;
            if (node) |n| n.requested = false;

            // A failed load keeps what is shown, and counts as loaded so an
            // open library doesn't retry every frame.
            if (is_root) lib.?.top_loaded = true;
            if (node) |n| n.loaded = true;
            const fresh = r.folders orelse continue;
            if (is_root) {
                const l = lib.?;
                l.top_folders = mergeFolders(gpa, l.top_folders, fresh) catch l.top_folders;
            } else if (node) |n| {
                n.children = mergeFolders(gpa, n.children, fresh) catch n.children;
            } else {
                for (fresh) |f| gpa.free(f.path);
                gpa.free(fresh);
            }
        }
    }

    pub fn drainPendingLibrary(
        self: *SidebarState,
        gpa: std.mem.Allocator,
        library_manager: ?*library_manager_mod.LibraryManager,
    ) !void {
        const len = self.pending_library_len.load(.acquire);
        if (len == 0) return;
        const path = self.pending_library_buf[0..len];
        defer self.pending_library_len.store(0, .release);
        self.add_error = null;
        const mgr = library_manager orelse return;
        const lib_id = mgr.addLibrary(path) catch |err| {
            self.add_error = switch (err) {
                error.LibraryExists => i18n.t(.library_add_exists),
                error.LibraryOverlaps => i18n.t(.library_add_overlaps),
                else => i18n.t(.library_add_failed),
            };
            return;
        };
        try self.libraries.append(gpa, .{
            .id = lib_id,
            .path = try gpa.dupe(u8, library_manager_mod.normalizeLibraryPath(path)),
            .image_count = 0,
        });
    }

    /// Platform-agnostic folder-picker result handler. Invoked by the platform
    /// seam (real native dialog in production, never called in headless tests).
    fn onFolderPicked(userdata: ?*anyopaque, path: ?[]const u8) void {
        const self: *SidebarState = @ptrCast(@alignCast(userdata orelse return));
        defer self.library_dialog_open.store(false, .release);
        defer if (self.wakeup_fn) |wake| wake();
        const p = path orelse return;
        const len = @min(p.len, self.pending_library_buf.len);
        @memcpy(self.pending_library_buf[0..len], p[0..len]);
        self.pending_library_len.store(len, .release);
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

        const row_bg = rowBg(is_selected);

        // Before a folder is expanded we rely on the has_children flag computed
        // at list time; once loaded, trust the actual children we found.
        const may_have_children = if (node.loaded) node.children.len > 0 else node.has_children;

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, row_bg.override(.{
                .id_extra = node_id_extra,
                .expand = .horizontal,
                .padding = .{ .x = indent_x, .y = 3, .w = 4, .h = 3 },
            }));
            defer row.deinit();

            if (dvui.clickedEx(row.data(), .{})) |_| {
                if (may_have_children or node.expanded) {
                    node.expanded = !node.expanded;
                    if (node.expanded and !node.loaded and !node.requested) {
                        if (self.folders) |*loader| {
                            loader.request(lib.id, node.path);
                            node.requested = true;
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
                    g.reloadImages() catch {};
                }
            }

            if (may_have_children or node.expanded) {
                const tvg = if (node.expanded) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right";
                dvui.icon(@src(), "expand", tvg, .{}, .{
                    .id_extra = node_id_extra,
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                    .color_text = .{ .color = style.C.text_ghost },
                });
            } else {
                _ = dvui.spacer(@src(), .{
                    .id_extra = node_id_extra,
                    .min_size_content = .{ .w = 12, .h = 0 },
                });
            }

            // A folder name comes from the filesystem, so it can hold anything;
            // drawn through the run splitter so a CJK or emoji path is glyphs
            // rather than boxes, and on one line so the list never reflows.
            fonts.richLine(@src(), std.Io.Dir.path.basename(node.path), .{
                .id_extra = node_id_extra,
                .expand = .horizontal,
                .gravity_y = 0.5,
                .font = style.F.row,
                .color_text = .{ .color = rowText(is_selected) },
            });
            countLabel(@src(), node.count, node_id_extra +% 1);
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
        favorite_count: i64,
    ) !bool {
        var needs_count_refresh = false;
        self.applyFolderResults(gpa);

        var sidebar = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = panel_w, .h = 0 },
            .max_size_content = .{ .w = panel_w, .h = 0 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = style.C.rail },
            .border = style.Edge.right,
            .color_border = .{ .color = style.hairline_soft },
        });
        defer sidebar.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = false,
            .padding = .{ .x = 6, .y = 8, .w = 6, .h = 8 },
        });
        defer scroll.deinit();

        // ── "Library" master header (clears filter, shows all) ───────────
        {
            const in_library = if (grid) |g| g.view_mode == .library else true;
            const unfiltered = self.filter_library_id == null and self.filter_folder == null;
            const selected = in_library and unfiltered;
            const bg = rowBg(selected);
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
                        g.reloadImages() catch {};
                    }
                }
                style.sectionHead(@src(), i18n.t(.nav_library), .{
                    .gravity_y = 0.5,
                    .padding = .{},
                    .color_text = .{ .color = if (selected) style.C.text_hi else style.C.text_ghost },
                });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            }
            if (dvui.buttonIcon(@src(), i18n.t(.a11y_add_library), dvui.entypo.plus, .{}, .{}, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(3),
                .background = false,
                .corners = style.R.chip,
                .color_text = .{ .color = style.C.text_dim },
            })) {
                if (!self.library_dialog_open.load(.acquire)) {
                    self.library_dialog_open.store(true, .release);
                    platform.openFolderDialog(self, SidebarState.onFolderPicked);
                }
            }
        }

        if (self.add_error) |msg| {
            dvui.label(@src(), "{s}", .{msg}, .{
                .padding = .all(8),
                .color_text = .{ .color = style.C.text_dim },
            });
        }
        if (self.libraries.items.len == 0) {
            dvui.label(@src(), "{s}", .{i18n.t(.library_empty)}, .{
                .padding = .all(8),
                .color_text = .{ .color = style.C.text_ghost },
            });
        } else {
            for (self.libraries.items, 0..) |*lib, idx| {
                const in_lib_view = if (grid) |g| g.view_mode == .library else false;
                const lib_selected = self.filter_library_id == lib.id and self.filter_folder == null;

                var row_hov = false;
                const lib_is_selected = lib_selected and in_lib_view;
                {
                    const lib_bg = rowBg(lib_is_selected);
                    var lib_row = dvui.box(@src(), .{ .dir = .horizontal }, lib_bg.override(.{
                        .id_extra = idx,
                        .expand = .horizontal,
                        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
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
                    if (dvui.buttonIcon(@src(), i18n.t(.a11y_expand_library), expand_tvg, .{}, .{}, .{
                        .id_extra = idx,
                        .min_size_content = .{ .w = 14, .h = 14 },
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(2),
                        .margin = .{},
                        .background = false,
                        .color_text = .{ .color = style.C.text_ghost },
                    })) {
                        lib.expanded = !lib.expanded;
                    }
                    // Load an open library's folder list the first time it is
                    // shown; applyLibraryCounts reloads it when counts change.
                    if (lib.expanded and !lib.top_loaded and !lib.top_requested) {
                        if (self.folders) |*loader| {
                            loader.request(lib.id, lib.path);
                            lib.top_requested = true;
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
                                g.reloadImages() catch {};
                            }
                        }
                        // A library is a root, so its name gets the 500-weight
                        // row role — enough to rank above the folders nested
                        // under it without a second colour.
                        fonts.richLine(@src(), std.Io.Dir.path.basename(lib.path), .{
                            .id_extra = idx,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                            .font = style.F.row_hi,
                            .color_text = .{ .color = rowText(lib_is_selected) },
                        });
                    }

                    countLabel(@src(), lib.image_count, idx);

                    // The remove button appears on hover, but its SLOT is always
                    // there. Adding a widget to the row on hover changed the
                    // row's width and height, so pointing at a library made the
                    // list twitch and re-flow under the cursor.
                    {
                        var slot = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = idx,
                            .min_size_content = .{ .w = remove_slot, .h = remove_slot },
                            .gravity_y = 0.5,
                        });
                        defer slot.deinit();
                        if (row_hov) {
                            if (dvui.buttonIcon(@src(), i18n.t(.a11y_remove_library), dvui.entypo.minus, .{}, .{}, .{
                                .id_extra = idx,
                                .min_size_content = .{ .w = 10, .h = 10 },
                                .gravity_x = 0.5,
                                .gravity_y = 0.5,
                                .padding = dvui.Rect.all(2),
                                .margin = .{},
                                .background = false,
                                .corners = style.R.chip,
                                .color_text = .{ .color = style.C.text_ghost },
                            })) {
                                self.confirm_remove_idx = idx;
                            }
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

        // ── The three fixed views ─────────────────────────────────────────
        // Trash, Duplicates and Favorites are not part of the library tree, so
        // a hairline separates them from it rather than a blank gap, which on a
        // scrolled list just looks like the tree ended.
        style.hsep(@src());

        // ── Trash section ─────────────────────────────────────────────────
        if (cfg_trash_enabled) {
            const in_trash = if (grid) |g| g.view_mode == .trash else false;
            var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, rowBg(in_trash).override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
                .tag = "nav-trash",
            }));
            defer trash_row.deinit();
            if (dvui.clickedEx(trash_row.data(), .{})) |_| {
                if (grid) |g| {
                    if (g.view_mode != .trash) {
                        g.view_mode = .trash;
                        g.reloadImages() catch {};
                    }
                }
            }
            dvui.icon(@src(), "trash", icons.tvg.lucide.@"trash-2", .{}, .{
                .min_size_content = .{ .w = 13, .h = 13 },
                .gravity_y = 0.5,
                .margin = .{ .w = 6 },
                .color_text = .{ .color = if (in_trash) style.C.text_hi else style.C.text_ghost },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.sidebar_trash)}, .{
                .font = style.F.row_hi,
                .gravity_y = 0.5,
                .color_text = .{ .color = rowText(in_trash) },
            });
            if (trash_stats) |ts| {
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                countLabel(@src(), ts.count, 0);
            }
        }

        // ── Duplicates section (always shown, like Trash) ─────────────────
        {
            const in_dupes = if (grid) |g| g.view_mode == .duplicates else false;
            var dupes_row = dvui.box(@src(), .{ .dir = .horizontal }, rowBg(in_dupes).override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
                .tag = "nav-duplicates",
            }));
            defer dupes_row.deinit();
            if (dvui.clickedEx(dupes_row.data(), .{})) |_| {
                if (grid) |g| {
                    if (g.view_mode != .duplicates) {
                        g.view_mode = .duplicates;
                        g.reloadImages() catch {};
                    }
                }
            }
            dvui.icon(@src(), "duplicates", icons.tvg.lucide.copy, .{}, .{
                .min_size_content = .{ .w = 13, .h = 13 },
                .gravity_y = 0.5,
                .margin = .{ .w = 6 },
                .color_text = .{ .color = if (in_dupes) style.C.text_hi else style.C.text_ghost },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.sidebar_duplicates)}, .{
                .font = style.F.row_hi,
                .gravity_y = 0.5,
                .color_text = .{ .color = rowText(in_dupes) },
            });
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            countLabel(@src(), duplicate_count, 0);
        }

        // ── Favorites quick filter ────────────────────────────────────────
        {
            const in_favorites = if (grid) |g| g.view_mode == .favorites else false;
            var fav_row = dvui.box(@src(), .{ .dir = .horizontal }, rowBg(in_favorites).override(.{
                .expand = .horizontal,
                .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
                .tag = "nav-favorites",
            }));
            defer fav_row.deinit();
            if (dvui.clickedEx(fav_row.data(), .{})) |_| {
                if (grid) |g| {
                    if (g.view_mode != .favorites) {
                        g.view_mode = .favorites;
                        g.reloadImages() catch {};
                    }
                }
            }
            // The only gold thing in the sidebar, and it matches the star on
            // the cells this view collects.
            dvui.icon(@src(), "favorites", app_icons.star, .{}, .{
                .min_size_content = .{ .w = 13, .h = 13 },
                .gravity_y = 0.5,
                .margin = .{ .w = 6 },
                .color_text = .{ .color = if (in_favorites) style.C.star else style.tint(style.C.star, 150) },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.sidebar_favorites)}, .{
                .font = style.F.row_hi,
                .gravity_y = 0.5,
                .color_text = .{ .color = rowText(in_favorites) },
            });
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            countLabel(@src(), favorite_count, 0);
        }

        // ── Library removal confirmation modal ───────────────────────────
        if (self.confirm_remove_idx) |idx| {
            if (idx < self.libraries.items.len) {
                const lib = &self.libraries.items[idx];
                const name = std.Io.Dir.path.basename(lib.path);

                var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
                    .min_size_content = .{ .w = 360, .h = 0 },
                });
                defer float.deinit();
                float.autoSize();

                var content = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .padding = .all(18),
                });
                defer content.deinit();

                style.modalTitle(@src(), i18n.t(.library_remove_title));
                fonts.richLabel(@src(), name, .{
                    .font = style.F.row_hi,
                    .color_text = .{ .color = style.C.text_hi },
                });
                // The full path is the detail that confirms WHICH library, so it
                // is monospaced and dimmed — scanned, not read.
                fonts.richLabel(@src(), lib.path, .{
                    .font = style.F.mono,
                    .color_text = .{ .color = style.C.text_faint },
                    .margin = .{ .y = 4, .h = 16 },
                });

                {
                    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
                    defer btn_row.deinit();

                    if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
                        self.confirm_remove_idx = null;
                    }
                    if (dvui.button(@src(), i18n.t(.action_remove), .{}, .{ .margin = .all(4), .style = .err })) {
                        self.confirm_remove_idx = null;
                        var removed = self.libraries.orderedRemove(idx);
                        const removed_id = removed.id;
                        if (library_manager) |mgr| {
                            if (dvui.App.main_init) |init| mgr.removeLibrary(init.io, removed.path) catch |err|
                                log.warn("remove library: {}", .{err});
                        } else if (db) |d| {
                            d.removeLibrary(removed.path) catch |err| log.warn("remove library: {}", .{err});
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
                            g.reloadImages() catch {};
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
