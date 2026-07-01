const std = @import("std");
const dvui = @import("dvui");
const dk = @import("diffkeep");

const alloc = std.testing.allocator;
const io = std.testing.io;

// ── DB helpers ────────────────────────────────────────────────────────────────

fn openDb(path: []const u8) !dk.VectorDb {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return dk.VectorDb.init(alloc, io, path);
}

// Defers must be declared by the caller — use this to close in consistent order:
//   defer db.deinit();
//   defer db.pool.deinit();
//   defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

// ── DB tests ──────────────────────────────────────────────────────────────────

test "db: all migrations apply without error" {
    const path = "/tmp/diffkeep_test_migrations.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "db: library CRUD" {
    const path = "/tmp/diffkeep_test_lib_crud.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/my/photos");
    try std.testing.expect(lib_id > 0);

    // storeLibrary is idempotent — same path returns same id
    const lib_id2 = try db.storeLibrary("/my/photos");
    try std.testing.expectEqual(lib_id, lib_id2);

    // getLibraryIdByPath
    const found = try db.getLibraryIdByPath("/my/photos");
    try std.testing.expectEqual(@as(?u64, lib_id), found);
    const not_found = try db.getLibraryIdByPath("/nope");
    try std.testing.expect(not_found == null);

    // listLibraries
    const libs = try db.listLibraries(alloc);
    defer {
        for (libs) |li| alloc.free(li.path);
        alloc.free(libs);
    }
    try std.testing.expectEqual(@as(usize, 1), libs.len);
    try std.testing.expectEqualStrings("/my/photos", libs[0].path);

    // removeLibrary
    try db.removeLibrary("/my/photos");
    const after = try db.getLibraryIdByPath("/my/photos");
    try std.testing.expect(after == null);
}

test "db: image create, save metadata, and retrieve details" {
    const path = "/tmp/diffkeep_test_img_details.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");

    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/cat.png");
    defer img.deinit(alloc);

    img.positivePromptText = try alloc.dupe(u8, "a fluffy cat");
    img.negativePromptText = try alloc.dupe(u8, "blurry");
    img.model              = try alloc.dupe(u8, "deliberate_v2");
    img.sampler            = try alloc.dupe(u8, "Euler a");
    img.scheduler          = try alloc.dupe(u8, "Karras");
    img.cfg                = 7.5;
    img.steps              = 20;
    img.seed               = 99999;
    try db.saveImage(&img);

    var details = (try db.getImageDetails(alloc, img.id)).?;
    defer details.deinit(alloc);

    try std.testing.expectEqualStrings("a fluffy cat", details.positive_prompt_text.?);
    try std.testing.expectEqualStrings("blurry",       details.negative_prompt_text.?);
    try std.testing.expectEqualStrings("deliberate_v2", details.model.?);
    try std.testing.expectEqualStrings("Euler a",       details.sampler.?);
    try std.testing.expectEqualStrings("Karras",        details.scheduler.?);
    try std.testing.expectEqual(@as(f64, 7.5),          details.cfg.?);
    try std.testing.expectEqual(@as(i64, 20),           details.steps.?);
    try std.testing.expectEqual(@as(i64, 99999),        details.seed.?);

    // Total count
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());
}

test "db: FTS5 prompt search" {
    const path = "/tmp/diffkeep_test_fts.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");

    // Two images — only one has "kitten" in the prompt
    var img1 = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer img1.deinit(alloc);
    img1.positivePromptText = try alloc.dupe(u8, "a fluffy kitten playing");
    try db.saveImage(&img1);

    var img2 = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer img2.deinit(alloc);
    img2.positivePromptText = try alloc.dupe(u8, "a majestic eagle soaring");
    try db.saveImage(&img2);

    const hits = try db.searchPrompts(alloc, "kitten");
    defer {
        for (hits) |e| alloc.free(e.path);
        alloc.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(img1.id, hits[0].id);

    // No results for an unknown word
    const no_hits = try db.searchPrompts(alloc, "dinosaur");
    defer alloc.free(no_hits);
    try std.testing.expectEqual(@as(usize, 0), no_hits.len);
}

test "db: trash and restore lifecycle" {
    const path = "/tmp/diffkeep_test_trash.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/img.png");
    defer img.deinit(alloc);

    // Image is initially visible in the all-images list
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());

    // Trash it
    try db.trashImage(img.id, "img_trash.png", 1024, 1000);
    try std.testing.expectEqual(@as(i64, 0), try db.getTotalImageCount());

    const trash = try db.listTrashImages(alloc);
    defer {
        for (trash) |e| {
            alloc.free(e.path);
            if (e.trash_name) |tn| alloc.free(tn);
        }
        alloc.free(trash);
    }
    try std.testing.expectEqual(@as(usize, 1), trash.len);
    try std.testing.expectEqualStrings("img_trash.png", trash[0].trash_name.?);

    const stats = try db.getTrashStats();
    try std.testing.expectEqual(@as(i64, 1),    stats.count);
    try std.testing.expectEqual(@as(i64, 1024), stats.total_bytes);

    // The fs watcher sees the trashed file leave the library dir and calls
    // deleteImageByPath. That must NOT remove the trashed row, or the item
    // vanishes from the trash even though the count still shows it.
    const removed = try db.deleteImageByPath(lib_id, "/lib/img.png");
    try std.testing.expect(removed == null);
    try std.testing.expectEqual(@as(i64, 1), (try db.getTrashStats()).count);
    const still_there = try db.listTrashImages(alloc);
    defer {
        for (still_there) |e| {
            alloc.free(e.path);
            if (e.trash_name) |tn| alloc.free(tn);
        }
        alloc.free(still_there);
    }
    try std.testing.expectEqual(@as(usize, 1), still_there.len);

    // Restore it
    try db.restoreImage(img.id);
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());
    const empty_trash = try db.listTrashImages(alloc);
    defer alloc.free(empty_trash);
    try std.testing.expectEqual(@as(usize, 0), empty_trash.len);

    // A genuine deletion of a non-trashed file still removes the row.
    const removed2 = try db.deleteImageByPath(lib_id, "/lib/img.png");
    try std.testing.expectEqual(img.id, removed2.?);
    try std.testing.expectEqual(@as(i64, 0), try db.getTotalImageCount());
}

test "db: duplicate detection by hash" {
    const path = "/tmp/diffkeep_test_dupes.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");

    // Helper: create an image with a given hash.
    const make = struct {
        fn f(d: *dk.VectorDb, lib: u64, p: []const u8, h: []const u8) !u64 {
            var img = try d.findOrCreateImage(alloc, lib, p);
            defer img.deinit(alloc);
            if (img.hash) |old| alloc.free(old);
            img.hash = try alloc.dupe(u8, h);
            try d.saveImage(&img);
            return img.id;
        }
    }.f;

    // Two images share hash "aaa"; one is unique ("bbb").
    const dup1 = try make(&db, lib_id, "/lib/a.png", "aaa");
    const dup2 = try make(&db, lib_id, "/lib/b.png", "aaa");
    _ = try make(&db, lib_id, "/lib/c.png", "bbb");

    // The two "aaa" images are duplicates of each other; "bbb" is not counted.
    try std.testing.expectEqual(@as(i64, 2), try db.getDuplicateCount());

    const dupes = try db.listDuplicateImages(alloc);
    defer {
        for (dupes) |e| alloc.free(e.path);
        alloc.free(dupes);
    }
    try std.testing.expectEqual(@as(usize, 2), dupes.len);
    // Both returned ids are the "aaa" pair (ordered by hash then id).
    try std.testing.expectEqual(dup1, dupes[0].id);
    try std.testing.expectEqual(dup2, dupes[1].id);

    // Trashing one of the pair leaves the other unique → no duplicates remain.
    try db.trashImage(dup2, "b_trash.png", 1, 1000);
    try std.testing.expectEqual(@as(i64, 0), try db.getDuplicateCount());
    const after = try db.listDuplicateImages(alloc);
    defer alloc.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "db: redundant duplicates keep exactly one per hash and never the unique" {
    const path = "/tmp/diffkeep_test_redundant.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    const make = struct {
        fn f(d: *dk.VectorDb, lib: u64, p: []const u8, h: ?[]const u8) !u64 {
            var img = try d.findOrCreateImage(alloc, lib, p);
            defer img.deinit(alloc);
            if (img.hash) |old| alloc.free(old);
            img.hash = if (h) |hh| try alloc.dupe(u8, hh) else null;
            try d.saveImage(&img);
            return img.id;
        }
    }.f;

    // hash "aaa": 3 copies; hash "bbb": 2 copies; "ccc": unique; one NULL-hash row.
    const a1 = try make(&db, lib_id, "/lib/a1.png", "aaa");
    const a2 = try make(&db, lib_id, "/lib/a2.png", "aaa");
    const a3 = try make(&db, lib_id, "/lib/a3.png", "aaa");
    const b1 = try make(&db, lib_id, "/lib/b1.png", "bbb");
    const b2 = try make(&db, lib_id, "/lib/b2.png", "bbb");
    const c1 = try make(&db, lib_id, "/lib/c1.png", "ccc");
    const n1 = try make(&db, lib_id, "/lib/n1.png", null);

    // Redundant = all-but-lowest-id of each duplicated group = (a2,a3,b2).
    try std.testing.expectEqual(@as(i64, 3), try db.getRedundantDuplicateCount());
    const reds = try db.listRedundantDuplicates(alloc);
    defer {
        for (reds) |e| alloc.free(e.path);
        alloc.free(reds);
    }
    var got = std.AutoHashMap(u64, void).init(alloc);
    defer got.deinit();
    for (reds) |e| try got.put(e.id, {});
    try std.testing.expectEqual(@as(usize, 3), got.count());
    // The kept copies (a1, b1), the unique (c1) and the NULL-hash row (n1) must
    // NEVER be selected for removal.
    try std.testing.expect(got.contains(a2) and got.contains(a3) and got.contains(b2));
    try std.testing.expect(!got.contains(a1) and !got.contains(b1));
    try std.testing.expect(!got.contains(c1) and !got.contains(n1));
}

test "db: listImmediateSubdirs path logic" {
    const path = "/tmp/diffkeep_test_subdirs.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");

    // Images at several locations. /lib/cats has a deeper subdir (kittens),
    // /lib/dogs does not.
    for ([_][]const u8{
        "/lib/cats/a.png",
        "/lib/cats/b.png",
        "/lib/cats/kittens/c.png",
        "/lib/dogs/rex.png",
        // image directly under /lib — no subdirectory, should NOT appear
        "/lib/top.png",
    }) |img_path| {
        var img = try db.findOrCreateImage(alloc, lib_id, img_path);
        img.deinit(alloc);
    }

    const subdirs = try db.listImmediateSubdirs(alloc, lib_id, "/lib");
    defer {
        for (subdirs) |fc| alloc.free(fc.path);
        alloc.free(subdirs);
    }

    // Results are sorted by path; cats×3 (2 direct + 1 in kittens), dogs×1.
    try std.testing.expectEqual(@as(usize, 2), subdirs.len);
    try std.testing.expectEqualStrings("/lib/cats", subdirs[0].path);
    try std.testing.expectEqual(@as(i64, 3),        subdirs[0].count);
    // /lib/cats has the "kittens" subdirectory; /lib/dogs has none.
    try std.testing.expect(subdirs[0].has_children);
    try std.testing.expectEqualStrings("/lib/dogs", subdirs[1].path);
    try std.testing.expectEqual(@as(i64, 1),        subdirs[1].count);
    try std.testing.expect(!subdirs[1].has_children);

    // Drilling into /lib/cats yields "kittens", which itself has no children.
    const cats_subs = try db.listImmediateSubdirs(alloc, lib_id, "/lib/cats");
    defer {
        for (cats_subs) |fc| alloc.free(fc.path);
        alloc.free(cats_subs);
    }
    try std.testing.expectEqual(@as(usize, 1), cats_subs.len);
    try std.testing.expectEqualStrings("/lib/cats/kittens", cats_subs[0].path);
    try std.testing.expect(!cats_subs[0].has_children);
}

test "db: vector KNN search (prompt + image) ranks nearest and excludes trash" {
    const path = "/tmp/diffkeep_test_vec_knn.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");

    // Three images with one-hot embeddings on distinct axes.
    const dim = 768;
    var ids: [3]u64 = undefined;
    for (0..3) |k| {
        var img = try db.findOrCreateImage(alloc, lib_id, switch (k) {
            0 => "/lib/a.png",
            1 => "/lib/b.png",
            else => "/lib/c.png",
        });
        defer img.deinit(alloc);
        ids[k] = img.id;

        var prompt_vec = [_]f32{0} ** dim;
        var image_vec = [_]f32{0} ** dim;
        prompt_vec[k] = 1.0; // prompt axis k
        image_vec[k + 10] = 1.0; // image axis k+10 (distinct from prompt axes)
        try db.storePromptEmbedding(img.id, &prompt_vec);
        try db.storeImageEmbedding(img.id, &image_vec);
    }

    // Prompt query nearest to image b (axis 1).
    {
        var q = [_]f32{0} ** dim;
        q[1] = 1.0;
        const hits = try db.searchByPromptEmbedding(alloc, &q, 3);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(ids[1], hits[0].id);
    }

    // Image query nearest to image c (axis 12).
    {
        var q = [_]f32{0} ** dim;
        q[12] = 1.0;
        const hits = try db.searchByImageEmbedding(alloc, &q, 3);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(ids[2], hits[0].id);
    }

    // Trashed images must be excluded from results.
    try db.trashImage(ids[1], "b_trash.png", 1024, 1000);
    {
        var q = [_]f32{0} ** dim;
        q[1] = 1.0;
        const hits = try db.searchByPromptEmbedding(alloc, &q, 3);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 2), hits.len);
        for (hits) |e| try std.testing.expect(e.id != ids[1]);
    }
}

// ── Grid tests ────────────────────────────────────────────────────────────────

var g_grid_test_ptr: *dk.GridState = undefined;

fn gridFrame() anyerror!dvui.App.Result {
    g_grid_test_ptr.render();
    return .ok;
}

test "grid: empty library shows placeholder" {
    const path = "/tmp/diffkeep_test_grid_empty.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    g_grid_test_ptr = &grid;

    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.testing.settle(gridFrame);
    try dvui.testing.expectVisible("grid-empty");
}

test "grid: render with images doesn't crash" {
    const path = "/tmp/diffkeep_test_grid_images.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/cat.png");
    img.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);

    g_grid_test_ptr = &grid;

    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.testing.settle(gridFrame);
    // "grid-empty" should not be registered when images are present
    try std.testing.expect(dvui.tagGet("grid-empty") == null);
}

test "grid: autoplay renders playable cells without crashing (missing files fall back)" {
    const path = "/tmp/diffkeep_test_grid_autoplay.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    _ = try makeImage(&db, lib, "/lib/still.png");
    const gif = try makeImage(&db, lib, "/lib/anim.gif");
    const clip = try makeImage(&db, lib, "/lib/clip.mp4");
    try db.setMediaType(gif, .animated);
    try db.setMediaType(clip, .video);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    grid.autoplay = true;
    try grid.reloadImages(&db);

    g_grid_test_ptr = &grid;
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    // The files don't exist, so each player open fails and the cell falls back to
    // its poster — the point is that the autoplay path (create/fail/evict) is
    // exercised over several frames without crashing or leaking a live player.
    try dvui.testing.settle(gridFrame);
    try std.testing.expectEqual(@as(usize, 0), grid.grid_players.count());

    // Toggling autoplay off is a no-op here (nothing live) and must not crash.
    grid.autoplay = false;
    try dvui.testing.settle(gridFrame);
    try std.testing.expectEqual(@as(usize, 0), grid.grid_players.count());
}

// ── UI panel tests (headless dvui, driving real widgets via tags) ───────────────
//
// These exercise the sidebar/toolbar/detail panels through the .testing backend.
// They are possible because those modules reach the SDL backend only through the
// `platform` seam (see src/platform.zig), which is left at its no-op defaults in
// tests.

var g_sidebar: *dk.sidebar.SidebarState = undefined;
var g_sidebar_db: *dk.VectorDb = undefined;
var g_sidebar_grid: *dk.GridState = undefined;

fn sidebarFrame() anyerror!dvui.App.Result {
    _ = g_sidebar.render(220, alloc, g_sidebar_db, g_sidebar_grid, null, true, null, 0, 0) catch {};
    return .ok;
}

test "sidebar: clicking Trash / Duplicates switches the grid view" {
    const path = "/tmp/diffkeep_test_sidebar_nav.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var sb = dk.sidebar.SidebarState{};
    defer sb.deinit(alloc);

    g_sidebar = &sb;
    g_sidebar_db = &db;
    g_sidebar_grid = &grid;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.fonts.register() catch {};

    try dvui.testing.settle(sidebarFrame);
    try std.testing.expect(grid.view_mode == .library);

    try dvui.testing.moveTo("nav-trash");
    try dvui.testing.click(.left);
    try dvui.testing.settle(sidebarFrame);
    try std.testing.expect(grid.view_mode == .trash);

    try dvui.testing.moveTo("nav-duplicates");
    try dvui.testing.click(.left);
    try dvui.testing.settle(sidebarFrame);
    try std.testing.expect(grid.view_mode == .duplicates);

    try dvui.testing.moveTo("nav-favorites");
    try dvui.testing.click(.left);
    try dvui.testing.settle(sidebarFrame);
    try std.testing.expect(grid.view_mode == .favorites);
}

var g_detail_details: dk.ImageDetails = undefined;

fn detailFrame() anyerror!dvui.App.Result {
    dk.detail_panel.renderContent(g_detail_details);
    return .ok;
}

test "detail panel: Copy on the prompt writes it to the clipboard" {
    g_detail_details = .{
        .id = 1,
        .library_id = 1,
        .library_path = "/lib/a.png",
        .creation_date = null,
        .positive_prompt_text = "a fluffy cat",
        .negative_prompt_text = null,
        .model = null,
        .cfg = null,
        .steps = null,
        .seed = null,
        .sampler = null,
        .scheduler = null,
        .loras = null,
        .trashed_at = null,
    };

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.fonts.register() catch {};

    try dvui.testing.settle(detailFrame);
    try dvui.testing.moveTo("copy-prompt");
    try dvui.testing.click(.left);
    try dvui.testing.settle(detailFrame);

    // dvui's testing backend implements clipboardTextSet/clipboardText, so we can
    // assert the decoupled copy path actually wrote the prompt.
    try std.testing.expectEqualStrings("a fluffy cat", dvui.clipboardText());
}

fn noopRefresh() void {}

/// Owns every piece of app state the toolbar's RenderCtx points at, so a test
/// can build a valid context with one struct.
const ToolbarFix = struct {
    search: dk.search.SearchState = .{},
    filters: std.ArrayList(dk.ActiveFilter) = .empty,
    filter_modal: dk.filter_modal.FilterModalState = .{},
    grid: ?dk.GridState = null,
    db: ?dk.VectorDb = null,
    cfg: dk.Config = .{},
    settings: dk.settings_modal.SettingsModalState = .{},
    db_stats: ?dk.DbStats = null,
    trash_stats: ?dk.TrashStats = null,
    duplicate_count: i64 = 0,
    favorite_count: i64 = 0,
    sidebar: dk.sidebar.SidebarState = .{},
    detail: dk.detail_panel.DetailState = .{},
    library_manager: ?dk.LibraryManager = null,
    left_w: f32 = 220,
    left_w_open: f32 = 220,
    right_w: f32 = 280,
    right_w_open: f32 = 280,
    total_image_count: i64 = 0,

    fn deinit(self: *ToolbarFix) void {
        self.filters.deinit(alloc);
        self.search.deinit(alloc);
        self.sidebar.deinit(alloc);
        self.detail.deinit(alloc);
    }

    fn ctx(self: *ToolbarFix) dk.toolbar.RenderCtx {
        return .{
            .search = &self.search,
            .active_filters = &self.filters,
            .filter_modal = &self.filter_modal,
            .grid = &self.grid,
            .db = &self.db,
            .cfg = &self.cfg,
            .settings = &self.settings,
            .db_stats = &self.db_stats,
            .trash_stats = &self.trash_stats,
            .duplicate_count = &self.duplicate_count,
            .favorite_count = &self.favorite_count,
            .sidebar = &self.sidebar,
            .detail = &self.detail,
            .library_manager = &self.library_manager,
            .left_w = &self.left_w,
            .left_w_open = &self.left_w_open,
            .right_w = &self.right_w,
            .right_w_open = &self.right_w_open,
            .total_image_count = &self.total_image_count,
            .on_refresh_counts = noopRefresh,
            .embedder_loading = false,
        };
    }
};

var g_toolbar_fix: *ToolbarFix = undefined;

fn toolbarFrame() anyerror!dvui.App.Result {
    dk.toolbar.renderToolbar(g_toolbar_fix.ctx());
    return .ok;
}

test "toolbar: typing into the search box fills the query buffer" {
    var fix = ToolbarFix{};
    defer fix.deinit();
    g_toolbar_fix = &fix;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.fonts.register() catch {};

    try dvui.testing.settle(toolbarFrame);
    try dvui.testing.moveTo("search-box");
    try dvui.testing.click(.left);
    try dvui.testing.writeText("kitten");
    try dvui.testing.settle(toolbarFrame);

    const typed = std.mem.sliceTo(&fix.search.buf, 0);
    try std.testing.expectEqualStrings("kitten", typed);
}

// ── Viewer logic tests (no rendering; pure ViewerState navigation) ──────────────
//
// ViewerState reaches the SDL backend only through the platform seam (window
// fullscreen / geometry), so its image-list navigation is testable headlessly.

test "viewer: navigateTo clamps and removeImages keeps the current index sane" {
    var images: std.ArrayList(dk.ImageEntry) = .empty;
    for ([_]u64{ 10, 11, 12, 13 }, 0..) |id, i| {
        const p = try std.fmt.allocPrint(alloc, "/lib/img{d}.png", .{i});
        try images.append(alloc, .{
            .id = id,
            .path = p,
            .filename = std.fs.path.basename(p),
            .mtime = null,
        });
    }
    // db = null so navigateTo skips the detail-panel DB refresh; no cfg/wakeup.
    var vs = dk.image_viewer.ViewerState.init(alloc, 1, images, 0, null, null, io, null, null);
    defer vs.deinit();

    // navigateTo clamps past the end.
    vs.navigateTo(99);
    try std.testing.expectEqual(@as(usize, 3), vs.current_idx);
    try std.testing.expectEqual(@as(u64, 13), vs.currentImage().?.id);

    vs.navigateTo(1);
    try std.testing.expectEqual(@as(usize, 1), vs.current_idx);

    var ids = std.AutoHashMap(u64, void).init(alloc);
    defer ids.deinit();

    // Removing an image before the current one shifts the index down with it.
    try ids.put(10, {});
    vs.removeImages(&ids);
    try std.testing.expectEqual(@as(u64, 11), vs.currentImage().?.id);
    try std.testing.expect(vs.open);

    // Removing the current image re-targets a valid neighbour.
    ids.clearRetainingCapacity();
    try ids.put(11, {});
    vs.removeImages(&ids);
    try std.testing.expectEqual(@as(u64, 12), vs.currentImage().?.id);

    // Removing every remaining image closes the viewer.
    ids.clearRetainingCapacity();
    try ids.put(12, {});
    try ids.put(13, {});
    vs.removeImages(&ids);
    try std.testing.expect(!vs.open);
}

test "grid: incomingBelongs respects the active view filters" {
    const path = "/tmp/diffkeep_test_grid_belongs.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // Fully unfiltered "all images" view accepts anything.
    try std.testing.expect(grid.incomingBelongs("/lib/a.png"));

    // Library filter: only images under the library root belong.
    grid.filter_library_path = "/lib";
    try std.testing.expect(grid.incomingBelongs("/lib/sub/a.png"));
    try std.testing.expect(!grid.incomingBelongs("/other/a.png"));
    try std.testing.expect(!grid.incomingBelongs("/lib")); // the root itself is not "inside"
    try std.testing.expect(!grid.incomingBelongs("/libfoo/a.png")); // prefix is not containment

    // Folder filter takes precedence over the library root.
    grid.filter_folder_path = "/lib/cats";
    try std.testing.expect(grid.incomingBelongs("/lib/cats/x.png"));
    try std.testing.expect(!grid.incomingBelongs("/lib/dogs/x.png"));

    // An active text search means membership can't be cheaply decided, so new
    // images are withheld until the query is re-run.
    grid.search_query = "kitten";
    try std.testing.expect(!grid.incomingBelongs("/lib/cats/x.png"));
    grid.search_query = null;

    // Same for an active embedding (semantic/visual) query.
    const dummy_embedding = [_]f32{0.0} ** 4;
    grid.query_embedding = &dummy_embedding;
    try std.testing.expect(!grid.incomingBelongs("/lib/cats/x.png"));
    grid.query_embedding = null;
}

// ── Grid ↔ DB integration ───────────────────────────────────────────────────────

/// Assert the grid holds exactly `want_ids` (order-independent — the grid sorts
/// by date, so never assert on position).
fn expectGridIds(grid: *const dk.GridState, want_ids: []const u64) !void {
    try std.testing.expectEqual(want_ids.len, grid.images.items.len);
    for (want_ids) |want| {
        var found = false;
        for (grid.images.items) |e| {
            if (e.id == want) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("grid is missing expected id {d}\n", .{want});
            return error.GridMissingId;
        }
    }
}

/// Create an image with a hash; returns its id. (Shared shape with the dup tests.)
fn makeHashedImage(db: *dk.VectorDb, lib: u64, p: []const u8, h: []const u8) !u64 {
    var img = try db.findOrCreateImage(alloc, lib, p);
    defer img.deinit(alloc);
    if (img.hash) |old| alloc.free(old);
    img.hash = try alloc.dupe(u8, h);
    try db.saveImage(&img);
    return img.id;
}

test "grid: reloadImages reflects the active view_mode" {
    const path = "/tmp/diffkeep_test_grid_views.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeHashedImage(&db, lib, "/lib/a.png", "dup"); // duplicate pair…
    const b = try makeHashedImage(&db, lib, "/lib/b.png", "dup"); // …with a
    const c = try makeHashedImage(&db, lib, "/lib/c.png", "uniq");
    const d = try makeHashedImage(&db, lib, "/lib/d.png", "trash-me");
    try db.trashImage(d, "d_trash.png", 0, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // Library view: every non-trashed image, trashed one excluded.
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    try expectGridIds(&grid, &.{ a, b, c });

    // Trash view: only the trashed image.
    grid.view_mode = .trash;
    try grid.reloadImages(&db);
    try expectGridIds(&grid, &.{d});

    // Duplicates view: only the images that share a hash.
    grid.view_mode = .duplicates;
    try grid.reloadImages(&db);
    try expectGridIds(&grid, &.{ a, b });
}

test "grid: reloadImages resets the scroll position to the top" {
    const path = "/tmp/diffkeep_test_grid_scroll.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // Pretend the user had scrolled down, then switch view.
    grid.scroll_info.viewport.y = 500;
    try grid.reloadImages(&db);
    try std.testing.expectEqual(@as(f32, 0), grid.scroll_info.viewport.y);
}

test "grid: a scanned image is only injected if it belongs to the current view" {
    const path = "/tmp/diffkeep_test_grid_incoming.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Empty DB → grid starts empty in the (default) library view.
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    grid.filter_library_path = "/lib";
    grid.filter_folder_path = "/lib/cats";

    // Two images arrive from a background scan: one inside the folder, one not.
    grid.notifier.push(io, 100, "/lib/cats/new.png", 0);
    grid.notifier.push(io, 101, "/lib/dogs/other.png", 0);
    grid.update();

    // Only the in-folder image is shown; the other is dropped (it will appear
    // when its own folder/view is loaded).
    try expectGridIds(&grid, &.{100});
}

var g_clear_fix: *ToolbarFix = undefined;

fn clearFrame() anyerror!dvui.App.Result {
    dk.toolbar.renderToolbar(g_clear_fix.ctx());
    return .ok;
}

test "toolbar: the clear button empties the search query" {
    var fix = ToolbarFix{};
    defer fix.deinit();
    // Pre-fill the query so the clear button renders.
    @memcpy(fix.search.buf[0..3], "cat");
    g_clear_fix = &fix;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.fonts.register() catch {};

    try dvui.testing.settle(clearFrame);
    try dvui.testing.moveTo("search-clear");
    try dvui.testing.click(.left);
    try dvui.testing.settle(clearFrame);

    try std.testing.expectEqual(@as(u8, 0), fix.search.buf[0]);
}

// ── Favorites ───────────────────────────────────────────────────────────────────

/// Create a plain image; returns its id.
fn makeImage(db: *dk.VectorDb, lib: u64, p: []const u8) !u64 {
    var img = try db.findOrCreateImage(alloc, lib, p);
    defer img.deinit(alloc);
    return img.id;
}

test "db: favorite flag set/count/list lifecycle" {
    const path = "/tmp/diffkeep_test_favorites.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeImage(&db, lib, "/lib/a.png");
    const b = try makeImage(&db, lib, "/lib/b.png");
    const c = try makeImage(&db, lib, "/lib/c.png");

    try std.testing.expectEqual(@as(i64, 0), try db.getFavoriteCount());

    try db.setFavorite(a, true);
    try db.setFavorite(c, true);
    try std.testing.expectEqual(@as(i64, 2), try db.getFavoriteCount());

    {
        const favs = try db.listFavorites(alloc);
        defer {
            for (favs) |e| alloc.free(e.path);
            alloc.free(favs);
        }
        try std.testing.expectEqual(@as(usize, 2), favs.len);
        for (favs) |e| try std.testing.expect(e.favorite);
    }

    // Clearing a favorite drops the count.
    try db.setFavorite(a, false);
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());

    // A trashed favorite is excluded from the (non-trashed) favorite count.
    try db.setFavorite(b, true); // now b and c are favorites
    try std.testing.expectEqual(@as(i64, 2), try db.getFavoriteCount());
    try db.trashImage(b, "b_trash.png", 0, 1000);
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());
}

test "grid: favorites view lists only favorites; markFavorites flags entries" {
    const path = "/tmp/diffkeep_test_grid_favorites.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeImage(&db, lib, "/lib/a.png");
    const b = try makeImage(&db, lib, "/lib/b.png");
    const c = try makeImage(&db, lib, "/lib/c.png");
    try db.setFavorite(a, true);
    try db.setFavorite(c, true);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // Library view: every entry carries the correct favorite flag.
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    for (grid.images.items) |e| {
        try std.testing.expectEqual(e.id == a or e.id == c, e.favorite);
    }
    _ = b;

    // Favorites view: only favorited images, all flagged.
    grid.view_mode = .favorites;
    try grid.reloadImages(&db);
    try expectGridIds(&grid, &.{ a, c });
    for (grid.images.items) |e| try std.testing.expect(e.favorite);
}

test "viewer: setFavorite updates the current image's favorite flag" {
    var images: std.ArrayList(dk.ImageEntry) = .empty;
    for ([_]u64{ 10, 11 }, 0..) |id, i| {
        const p = try std.fmt.allocPrint(alloc, "/lib/img{d}.png", .{i});
        try images.append(alloc, .{
            .id = id,
            .path = p,
            .filename = std.fs.path.basename(p),
            .mtime = null,
        });
    }
    var vs = dk.image_viewer.ViewerState.init(alloc, 1, images, 0, null, null, io, null, null);
    defer vs.deinit();

    try std.testing.expect(!vs.currentFavorite()); // id 10
    vs.setFavorite(10, true);
    try std.testing.expect(vs.currentFavorite());

    vs.navigateTo(1); // id 11
    try std.testing.expect(!vs.currentFavorite());
    vs.setFavorite(11, true);
    try std.testing.expect(vs.currentFavorite());

    // Toggling an id not present is a no-op (no crash).
    vs.setFavorite(999, true);
    try std.testing.expect(vs.currentFavorite());
}

// ── Format filter ───────────────────────────────────────────────────────────────

fn sliceSetContains(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test "db: format filter matches by file extension (query-time, case-insensitive)" {
    const path = "/tmp/diffkeep_test_format_filter.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    _ = try makeImage(&db, lib, "/lib/a.png");
    _ = try makeImage(&db, lib, "/lib/e.PNG"); // uppercase ext still counts as png
    _ = try makeImage(&db, lib, "/lib/b.webp");
    _ = try makeImage(&db, lib, "/lib/c.webp");
    _ = try makeImage(&db, lib, "/lib/d.jpg");

    // Distinct formats present (sorted), derived from the extensions — no gif here.
    {
        const fmts = try db.getDistinctColumnValues(alloc, .format);
        defer {
            for (fmts) |s| alloc.free(s);
            alloc.free(fmts);
        }
        try std.testing.expectEqual(@as(usize, 3), fmts.len);
        try std.testing.expect(sliceSetContains(fmts, "png"));
        try std.testing.expect(sliceSetContains(fmts, "webp"));
        try std.testing.expect(sliceSetContains(fmts, "jpg"));
    }

    // Filtering by "webp" returns only the two webp.
    {
        const filters = [_]dk.ActiveFilter{.{ .column = .format, .value = "webp" }};
        const res = try db.listImagesFiltered(alloc, null, null, null, &filters);
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 2), res.len);
        for (res) |e| try std.testing.expect(std.ascii.endsWithIgnoreCase(e.path, ".webp"));
    }

    // "png" matches both lowercase and uppercase extensions on disk.
    {
        const filters = [_]dk.ActiveFilter{.{ .column = .format, .value = "png" }};
        const res = try db.listImagesFiltered(alloc, null, null, null, &filters);
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 2), res.len);
    }

    // The filter value itself is matched case-insensitively too.
    {
        const filters = [_]dk.ActiveFilter{.{ .column = .format, .value = "WEBP" }};
        const res = try db.listImagesFiltered(alloc, null, null, null, &filters);
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 2), res.len);
    }
}

test "db: resource_type filter (image includes animated; video separate)" {
    const path = "/tmp/diffkeep_test_resource_filter.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const img = try makeImage(&db, lib, "/lib/a.png"); // stays media_type=image (0)
    const ani = try makeImage(&db, lib, "/lib/b.webp");
    const vid = try makeImage(&db, lib, "/lib/c.mp4");
    try db.setMediaType(ani, .animated);
    try db.setMediaType(vid, .video);

    const filterIds = struct {
        fn f(d: *dk.VectorDb, value: []const u8) ![]dk.VectorDb.GridEntry {
            const filters = [_]dk.ActiveFilter{.{ .column = .resource_type, .value = value }};
            return d.listImagesFiltered(alloc, null, null, null, &filters);
        }
    }.f;

    // "image" includes static + animated, excludes video.
    {
        const res = try filterIds(&db, "image");
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 2), res.len);
        for (res) |e| try std.testing.expect(e.id == img or e.id == ani);
    }
    // "animated" → only the animated webp.
    {
        const res = try filterIds(&db, "animated");
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 1), res.len);
        try std.testing.expectEqual(ani, res[0].id);
    }
    // "video" → only the mp4.
    {
        const res = try filterIds(&db, "video");
        defer {
            for (res) |e| alloc.free(e.path);
            alloc.free(res);
        }
        try std.testing.expectEqual(@as(usize, 1), res.len);
        try std.testing.expectEqual(vid, res[0].id);
    }

    // Distinct options reflect what's present (all three here).
    {
        const types = try db.getDistinctColumnValues(alloc, .resource_type);
        defer {
            for (types) |s| alloc.free(s);
            alloc.free(types);
        }
        try std.testing.expectEqual(@as(usize, 3), types.len);
        try std.testing.expect(sliceSetContains(types, "image"));
        try std.testing.expect(sliceSetContains(types, "animated"));
        try std.testing.expect(sliceSetContains(types, "video"));
    }
}

// ── Animated / video playback classification ─────────────────────────────────

test "grid: markMediaTypes flags animated and video entries from the DB" {
    const path = "/tmp/diffkeep_test_media_types.db";
    var db = try openDb(path);
    defer db.deinit();
    defer db.pool.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const still = try makeImage(&db, lib, "/lib/a.png"); // stays .image
    const gif = try makeImage(&db, lib, "/lib/b.gif");
    const webp = try makeImage(&db, lib, "/lib/c.webp");
    const clip = try makeImage(&db, lib, "/lib/d.mp4");
    try db.setMediaType(gif, .animated);
    try db.setMediaType(webp, .animated);
    try db.setMediaType(clip, .video);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    grid.view_mode = .library;
    try grid.reloadImages(&db);

    for (grid.images.items) |e| {
        const want: dk.VectorDb.MediaType = if (e.id == clip)
            .video
        else if (e.id == gif or e.id == webp)
            .animated
        else
            .image;
        try std.testing.expectEqual(want, e.media_type);
    }
    _ = still;
}

test "viewer: currentIsPlayable is true for video and animated, false for static" {
    const cases = [_]struct { id: u64, mt: dk.VectorDb.MediaType, playable: bool }{
        .{ .id = 1, .mt = .image, .playable = false },
        .{ .id = 2, .mt = .animated, .playable = true },
        .{ .id = 3, .mt = .video, .playable = true },
    };
    var images: std.ArrayList(dk.ImageEntry) = .empty;
    for (cases) |cse| {
        const p = try std.fmt.allocPrint(alloc, "/lib/m{d}.bin", .{cse.id});
        try images.append(alloc, .{
            .id = cse.id,
            .path = p,
            .filename = std.fs.path.basename(p),
            .mtime = null,
            .media_type = cse.mt,
        });
    }
    var vs = dk.image_viewer.ViewerState.init(alloc, 1, images, 0, null, null, io, null, null);
    defer vs.deinit();

    for (cases, 0..) |cse, i| {
        vs.navigateTo(i);
        try std.testing.expectEqual(cse.playable, vs.currentIsPlayable());
    }
}
