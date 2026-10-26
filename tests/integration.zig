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

// Callers close and clean up with:
//   defer db.deinit();
//   defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

// ── DB tests ──────────────────────────────────────────────────────────────────

test "db: all migrations apply without error" {
    const path = "/tmp/diffkeep_test_migrations.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "db: library CRUD" {
    const path = "/tmp/diffkeep_test_lib_crud.db";
    var db = try openDb(path);
    defer db.deinit();
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

        var prompt_vec: [dim]f32 = @splat(0);
        var image_vec: [dim]f32 = @splat(0);
        prompt_vec[k] = 1.0; // prompt axis k
        image_vec[k + 10] = 1.0; // image axis k+10 (distinct from prompt axes)
        try db.storePromptEmbedding(img.id, &prompt_vec);
        try db.storeImageEmbedding(img.id, &image_vec);
    }

    // Prompt query nearest to image b (axis 1).
    {
        var q: [dim]f32 = @splat(0);
        q[1] = 1.0;
        const hits = try db.searchByPromptEmbedding(alloc, &q, 3, -1.0);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(ids[1], hits[0].id);
    }

    // Image query nearest to image c (axis 12).
    {
        var q: [dim]f32 = @splat(0);
        q[12] = 1.0;
        const hits = try db.searchByImageEmbedding(alloc, &q, 3, -1.0);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(ids[2], hits[0].id);
    }

    // A similarity threshold drops the orthogonal (sim = 0) tail.
    {
        var q: [dim]f32 = @splat(0);
        q[1] = 1.0;
        const hits = try db.searchByPromptEmbedding(alloc, &q, 3, 0.5);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(ids[1], hits[0].id);
    }

    // Combined search: prompt leg matches b, visual leg matches c; RRF puts
    // both ahead of a, which neither leg ranked first.
    {
        var pq: [dim]f32 = @splat(0);
        pq[1] = 1.0;
        var vq: [dim]f32 = @splat(0);
        vq[12] = 1.0;
        const hits = try db.searchCombined(alloc, &pq, &vq, 2, -1.0, -1.0);
        defer {
            for (hits) |e| alloc.free(e.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 2), hits.len);
        for (hits) |e| try std.testing.expect(e.id == ids[1] or e.id == ids[2]);
    }

    // Trashed images must be excluded from results.
    try db.trashImage(ids[1], "b_trash.png", 1024, 1000);
    {
        var q: [dim]f32 = @splat(0);
        q[1] = 1.0;
        const hits = try db.searchByPromptEmbedding(alloc, &q, 3, -1.0);
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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/cat.png");
    img.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);

    g_grid_test_ptr = &grid;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.style.install();

    try dvui.testing.settle(gridFrame);
    // "grid-empty" should not be registered when images are present
    try std.testing.expect(dvui.tagGet("grid-empty") == null);
}

test "grid: autoplay renders playable cells without crashing (missing files fall back)" {
    const path = "/tmp/diffkeep_test_grid_autoplay.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    _ = try makeImage(&db, lib, "/lib/still.png");
    const gif = try makeImage(&db, lib, "/lib/anim.gif");
    const clip = try makeImage(&db, lib, "/lib/clip.mp4");
    try db.setMediaType(gif, .animated);
    try db.setMediaType(clip, .video);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();
    grid.autoplay = true;
    try grid.reloadImages(&db);
    grid.awaitReload();

    g_grid_test_ptr = &grid;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.style.install();

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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();
    var sb = dk.sidebar.SidebarState{};
    defer sb.deinit(alloc);

    g_sidebar = &sb;
    g_sidebar_db = &db;
    g_sidebar_grid = &grid;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.style.install();

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
    dk.style.install();

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
    dk.style.install();

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
        const p = try alloc.print("/lib/img{d}.png", .{i});
        try images.append(alloc, .{
            .id = id,
            .path = p,
            .filename = std.Io.Dir.path.basename(p),
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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

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
    const dummy_embedding: [4]f32 = @splat(0.0);
    grid.query_embeddings = .{ .prompt = &dummy_embedding };
    try std.testing.expect(!grid.incomingBelongs("/lib/cats/x.png"));
    grid.query_embeddings = .{ .visual = &dummy_embedding };
    try std.testing.expect(!grid.incomingBelongs("/lib/cats/x.png"));
    grid.query_embeddings = .{};
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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeHashedImage(&db, lib, "/lib/a.png", "dup"); // duplicate pair…
    const b = try makeHashedImage(&db, lib, "/lib/b.png", "dup"); // …with a
    const c = try makeHashedImage(&db, lib, "/lib/c.png", "uniq");
    const d = try makeHashedImage(&db, lib, "/lib/d.png", "trash-me");
    try db.trashImage(d, "d_trash.png", 0, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

    // Library view: every non-trashed image, trashed one excluded.
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try expectGridIds(&grid, &.{ a, b, c });

    // Trash view: only the trashed image.
    grid.view_mode = .trash;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try expectGridIds(&grid, &.{d});

    // Duplicates view: only the images that share a hash.
    grid.view_mode = .duplicates;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try expectGridIds(&grid, &.{ a, b });
}

test "grid: reloadImages resets the scroll position to the top" {
    const path = "/tmp/diffkeep_test_grid_scroll.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

    // Pretend the user had scrolled down, then switch view.
    grid.scroll_info.viewport.y = 500;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try std.testing.expectEqual(@as(f32, 0), grid.scroll_info.viewport.y);
}

test "grid: a scanned image is only injected if it belongs to the current view" {
    const path = "/tmp/diffkeep_test_grid_incoming.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Empty DB → grid starts empty in the (default) library view.
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();
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
    dk.style.install();

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

test "grid: favorites view lists only favorites; loaded entries carry the favorite flag" {
    const path = "/tmp/diffkeep_test_grid_favorites.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeImage(&db, lib, "/lib/a.png");
    const b = try makeImage(&db, lib, "/lib/b.png");
    const c = try makeImage(&db, lib, "/lib/c.png");
    try db.setFavorite(a, true);
    try db.setFavorite(c, true);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

    // Library view: every entry carries the correct favorite flag.
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    grid.awaitReload();
    for (grid.images.items) |e| {
        try std.testing.expectEqual(e.id == a or e.id == c, e.favorite);
    }
    _ = b;

    // Favorites view: only favorited images, all flagged.
    grid.view_mode = .favorites;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try expectGridIds(&grid, &.{ a, c });
    for (grid.images.items) |e| try std.testing.expect(e.favorite);
}

test "viewer: setFavorite updates the current image's favorite flag" {
    var images: std.ArrayList(dk.ImageEntry) = .empty;
    for ([_]u64{ 10, 11 }, 0..) |id, i| {
        const p = try alloc.print("/lib/img{d}.png", .{i});
        try images.append(alloc, .{
            .id = id,
            .path = p,
            .filename = std.Io.Dir.path.basename(p),
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

test "grid: a load flags animated and video entries from the DB" {
    const path = "/tmp/diffkeep_test_media_types.db";
    var db = try openDb(path);
    defer db.deinit();
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
    try grid.reloadImages(&db);
    grid.awaitReload();
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    grid.awaitReload();

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
        const p = try alloc.print("/lib/m{d}.bin", .{cse.id});
        try images.append(alloc, .{
            .id = cse.id,
            .path = p,
            .filename = std.Io.Dir.path.basename(p),
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

// ── Design system ─────────────────────────────────────────────────────────────
//
// The palette and type scale have no visible failure mode: a wrong cap ratio or
// an unregistered family shifts every size or silently substitutes dvui's
// built-in Vera, and nothing errors. These tests are the only thing standing
// between a font swap and a screen that quietly went generic.

test "style: cap_ratio matches the bundled face" {
    // The whole type scale is nominal px times this number. If a font update
    // changed the face's cap height, every size in the app would shift and
    // nothing would fail — so read it back out of the file.
    const ttf = dk.fonts.plex_sans_regular;
    const n = std.mem.readInt(u16, ttf[4..6], .big);
    var head: ?usize = null;
    var os2: ?usize = null;
    for (0..n) |i| {
        const rec = 12 + 16 * i;
        const tag = ttf[rec..][0..4];
        const off = std.mem.readInt(u32, ttf[rec + 8 ..][0..4], .big);
        if (std.mem.eql(u8, tag, "head")) head = off;
        if (std.mem.eql(u8, tag, "OS/2")) os2 = off;
    }
    const upem: f32 = @floatFromInt(std.mem.readInt(u16, ttf[head.? + 18 ..][0..2], .big));
    const cap: f32 = @floatFromInt(std.mem.readInt(i16, ttf[os2.? + 88 ..][0..2], .big));
    try std.testing.expectApproxEqAbs(dk.style.cap_ratio, cap / upem, 0.001);
}

test "style: type roles convert nominal px to dvui cap-height sizes" {
    const F = dk.style.F;
    // 12.5px prose at 1.65 line spacing, as the design states it, lifted by the
    // one global scale knob.
    try std.testing.expectApproxEqAbs(@as(f32, 12.5 * dk.style.ui_scale * dk.style.cap_ratio), F.prose.size, 0.001);
    // Nothing may fall below dvui's own default cap height by more than a step:
    // the roles are a hierarchy, not a licence to go unreadable. `mono_hd` is
    // the floor, and it is the smallest thing the design has.
    try std.testing.expect(F.mono_hd.size >= 9.0);
    try std.testing.expect(dk.style.theme().font_body.size >= dvui.Font.DefaultSize);
    // dvui multiplies its line-height factor by the hhea span, NOT the cap
    // height, so the factor carries that division; recovering 1.65 proves the
    // round trip through both conversions.
    try std.testing.expectApproxEqAbs(@as(f32, 1.65), F.prose.line_height_factor * dk.style.natural_line, 0.001);
    // Every role must resolve to a family we actually register, or dvui
    // silently substitutes its built-in Vera and the screen goes generic.
    for ([_]dvui.Font{
        F.app,   F.ui,    F.ui_sm,   F.ui_hi, F.row,      F.row_hi,
        F.prose, F.input, F.mono,    F.code,  F.mono_sm,  F.mono_hd,
        F.mono_val, F.caption,
    }) |f| {
        const fam = f.familyName();
        const known = std.mem.eql(u8, fam, dk.fonts.sans) or std.mem.eql(u8, fam, dk.fonts.sans_med) or
            std.mem.eql(u8, fam, dk.fonts.mono) or std.mem.eql(u8, fam, dk.fonts.mono_med);
        errdefer std.debug.print("role family {s} is not a registered family\n", .{fam});
        try std.testing.expect(known);
    }
}

test "style: accents keep their reserved meanings distinct" {
    const C = dk.style.C;
    // Amber ("the machine is working") and blue ("the user owns this") must not
    // drift toward each other: the whole screen's legibility rests on
    // warm = machine, cool = user being obvious without a legend.
    try std.testing.expect(C.amber.r > C.amber.b);
    try std.testing.expect(C.blue.b > C.blue.r);
    // Danger has to be tellable from amber at a glance, or a destructive
    // confirm reads as a progress indicator.
    try std.testing.expect(C.danger.r > C.danger.g * 2);
    // Every surface is darker than every text colour, so no palette edit can
    // produce an invisible label by swapping two constants.
    const surfaces = [_]dvui.Color{ C.canvas, C.chrome, C.rail, C.sunken, C.card, C.chip, C.sel_row, C.thumb_well };
    const texts = [_]dvui.Color{ C.text_hi, C.text, C.text_dim, C.text_faint, C.text_ghost };
    for (surfaces) |s| {
        for (texts) |t| {
            try std.testing.expect(@as(u16, t.r) + t.g + t.b > @as(u16, s.r) + s.g + s.b);
        }
    }
}

test "fonts: tier 1 coverage parses to the Plex faces' real cmap" {
    dk.fonts.buildCoverage();
    const base = dvui.Font{ .family = dvui.Font.array(dk.fonts.sans), .size = 12 };
    // Latin, plus the Greek / Cyrillic / Vietnamese that tier 1 also covers. A
    // parse that silently found nothing would route these to tier 2 instead.
    for ([_]u21{ 'A', 'z', '7', 'Ω', 'Д', 'ế', '·', '×', '→' }) |cp| {
        const fam = dk.fonts.fontFor(cp, .{}, base).familyName();
        errdefer std.debug.print("U+{X} went to {s}, want tier 1\n", .{ cp, fam });
        try std.testing.expectEqualStrings(dk.fonts.sans, fam);
    }
}

test "fonts: run splitting sends each codepoint to a face that has it" {
    dk.fonts.buildCoverage();
    const base = dvui.Font{ .family = dvui.Font.array(dk.fonts.sans), .size = 12 };
    const Case = struct { cp: u21, want: []const u8 };
    // A prompt or filename can hold any of these; each must land on a face that
    // actually has the glyph, or it draws as a tofu box.
    for ([_]Case{
        .{ .cp = '日', .want = dk.fonts.cjk },
        .{ .cp = '한', .want = dk.fonts.cjk },
        .{ .cp = '─', .want = dk.fonts.cjk },
        .{ .cp = 0x1F98A, .want = dk.fonts.emoji_family }, // 🦊 in a filename
        .{ .cp = '⚙', .want = dk.fonts.emoji_family },
    }) |c| {
        const fam = dk.fonts.fontFor(c.cp, .{}, base).familyName();
        errdefer std.debug.print("U+{X} -> {s}, want {s}\n", .{ c.cp, fam, c.want });
        try std.testing.expectEqualStrings(c.want, fam);
    }
}

test "fonts: mono content leaves mono rather than showing tofu" {
    dk.fonts.buildCoverage();
    const m = dvui.Font{ .family = dvui.Font.array(dk.fonts.mono), .size = 10 };
    try std.testing.expectEqualStrings(dk.fonts.mono, dk.fonts.fontFor('4', .{ .code = true }, m).familyName());
    // A CJK model name in a mono slot renders proportional, not as boxes. See
    // fonts.zig on why the mono fallback is the proportional CJK face.
    try std.testing.expectEqualStrings(dk.fonts.cjk, dk.fonts.fontFor('日', .{ .code = true }, m).familyName());
}

test "fonts: medium weight keeps its own family but borrows real bold and italic faces" {
    dk.fonts.buildCoverage();
    const med = dvui.Font{ .family = dvui.Font.array(dk.fonts.sans_med), .size = 11 };
    // Upright 500 stays on the Medium family...
    try std.testing.expectEqualStrings(dk.fonts.sans_med, dk.fonts.fontFor('A', .{}, med).familyName());
    // ...but there is no Medium Bold or Medium Italic file, so those resolve to
    // the regular family's SemiBold / Italic rather than a face that is absent.
    const b = dk.fonts.fontFor('A', .{ .bold = true }, med);
    try std.testing.expectEqualStrings(dk.fonts.sans, b.familyName());
    try std.testing.expectEqual(dvui.Font.Weight.bold, b.weight);
    const it = dk.fonts.fontFor('A', .{ .italic = true }, med);
    try std.testing.expectEqualStrings(dk.fonts.sans, it.familyName());
    try std.testing.expectEqual(dvui.Font.Style.italic, it.style);
}

test "style: ellipsize measures the text rather than counting characters" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    _ = try dvui.testing.step(struct {
        fn frame() anyerror!dvui.App.Result {
            dk.style.install();
            const font = dk.style.F.row;
            var buf: [256]u8 = undefined;

            // Fits: returned unchanged, no copy into the buffer.
            const short = "cat.png";
            try std.testing.expectEqualStrings(short, dk.style.ellipsize(&buf, short, font, 400));

            // Does not fit: cut and given an ellipsis, and the result is
            // actually within the budget.
            const long = "a-very-long-generated-filename-with-no-spaces-at-all.png";
            const cut = dk.style.ellipsize(&buf, long, font, 80);
            try std.testing.expect(cut.len < long.len);
            try std.testing.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
            try std.testing.expect(font.textSize(cut).w <= 80);
            // The cut never lands inside a UTF-8 sequence.
            try std.testing.expect(std.unicode.utf8ValidateSlice(cut));

            // An ideograph is twice a Latin letter's width, so a character
            // budget would cut this at half the room it has. Measured, it keeps
            // fewer characters than the Latin string at the same width.
            const cjk = "猫の写真-------------------------------------.png";
            const cjk_cut = dk.style.ellipsize(&buf, cjk, font, 80);
            try std.testing.expect(std.unicode.utf8ValidateSlice(cjk_cut));
            try std.testing.expect(font.textSize(cjk_cut).w <= 80);

            return .ok;
        }
    }.frame);
}

// ── Connection pool / missing files ──────────────────────────────────────────

fn embeddingRowCount(db: *dk.VectorDb, table: []const u8) !i64 {
    var buf: [96]u8 = undefined;
    var stmt = try db.db.prepare(try std.mem.print(&buf, "SELECT count(*) FROM {s}", .{table}));
    defer stmt.deinit();
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

test "db: getConnection handles share one pool and return their connections" {
    const path = "/tmp/diffkeep_test_pool_share.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.testing.expectEqual(@as(usize, 1), db.pool.outstanding);
    const idle_before = db.pool.connections.items.len;

    var a = try db.getConnection();
    var b = try db.getConnection();
    // Same pool object, not a copy: both acquisitions are visible to the owner.
    try std.testing.expectEqual(db.pool, a.pool);
    try std.testing.expectEqual(db.pool, b.pool);
    try std.testing.expectEqual(@as(usize, 3), db.pool.outstanding);
    try std.testing.expectEqual(idle_before - 2, db.pool.connections.items.len);

    a.deinit();
    b.deinit();
    try std.testing.expectEqual(@as(usize, 1), db.pool.outstanding);
    try std.testing.expectEqual(idle_before, db.pool.connections.items.len);
}

test "db: deleting an image drops its embeddings, so a recycled id starts clean" {
    const path = "/tmp/diffkeep_test_embed_cascade.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer img.deinit(alloc);
    var vec: [768]f32 = @splat(0);
    vec[0] = 1.0;
    try db.storePromptEmbedding(img.id, &vec);
    try db.storeImageEmbedding(img.id, &vec);
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "image_embeddings"));
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "positive_prompt_embeddings"));

    try db.deleteImage(img.id);
    try std.testing.expectEqual(@as(i64, 0), try embeddingRowCount(&db, "image_embeddings"));
    try std.testing.expectEqual(@as(i64, 0), try embeddingRowCount(&db, "positive_prompt_embeddings"));
}

test "db: deleteMissingImage only removes the live row at that path" {
    const path = "/tmp/diffkeep_test_delete_missing.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);

    // Wrong path for the id (e.g. the id was recycled): untouched.
    try std.testing.expect(!try db.deleteMissingImage(a.id, "/lib/other.png"));
    // A trashed row keeps living in the trash even though its file left the library.
    try db.trashImage(b.id, "b_trash.png", 1, 1000);
    try std.testing.expect(!try db.deleteMissingImage(b.id, "/lib/b.png"));
    try std.testing.expectEqual(@as(i64, 1), (try db.getTrashStats()).count);

    try std.testing.expect(try db.deleteMissingImage(a.id, "/lib/a.png"));
    try std.testing.expectEqual(@as(i64, 0), try db.getTotalImageCount());
}

test "grid: fileDeleted needs the file gone but its directory present" {
    const dir = "/tmp/diffkeep_test_file_deleted";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/here.png", .data = "x" });

    try std.testing.expect(!dk.image_grid.fileDeleted(io, dir ++ "/here.png"));
    try std.testing.expect(dk.image_grid.fileDeleted(io, dir ++ "/gone.png"));
    // Whole directory missing (unmounted drive, moved folder): not a deletion.
    try std.testing.expect(!dk.image_grid.fileDeleted(io, dir ++ "/nodir/gone.png"));
}

test "grid: a deleted file is removed from the DB and drained; other failures aren't retried" {
    const dir = "/tmp/diffkeep_test_grid_missing";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    // Exists but isn't an image: the load fails without the file being gone.
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/broken.png", .data = "not a png" });

    const path = "/tmp/diffkeep_test_grid_missing.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary(dir);
    var gone = try db.findOrCreateImage(alloc, lib_id, dir ++ "/gone.png");
    defer gone.deinit(alloc);
    var broken = try db.findOrCreateImage(alloc, lib_id, dir ++ "/broken.png");
    defer broken.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages(&db);
    grid.awaitReload();

    grid.noteLoadFailure(gone.id, dir ++ "/gone.png");
    grid.noteLoadFailure(broken.id, dir ++ "/broken.png");

    var drained: std.ArrayList(u64) = .empty;
    defer drained.deinit(alloc);
    grid.drainMissingIds(alloc, &drained);
    try std.testing.expectEqualSlices(u64, &.{gone.id}, drained.items);
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());

    // The broken file stays in the library but is no longer re-requested...
    try std.testing.expect(grid.load_failed.contains(broken.id));
    // ...until it changes (or its id is recycled) and is invalidated.
    grid.invalidateThumbnail(broken.id);
    try std.testing.expect(!grid.load_failed.contains(broken.id));
}

// ── Background file operations ───────────────────────────────────────────────

var g_ops_db: ?dk.VectorDb = null;
var g_ops_data_dir: ?[]const u8 = null;
var g_ops_removed: usize = 0;

fn opsNoop() void {}
fn opsRemoved(ids: *const std.AutoHashMap(u64, void)) void {
    g_ops_removed += ids.count();
}

/// Poll until the file-op worker has applied something (or time out).
fn pollFileOps(grid: *dk.GridState) !void {
    for (0..500) |_| {
        if (dk.image_ops.fileOpsPoll(io, alloc, grid)) return;
        try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    return error.FileOpTimedOut;
}

test "image_ops: trash, restore and delete run off the main thread and update the grid" {
    const dir = "/tmp/diffkeep_test_file_ops";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/lib");
    try cwd.createDirPath(io, dir ++ "/data/trash");
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/a.png", .data = "a" });
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/b.png", .data = "b" });

    g_ops_db = try openDb(dir ++ "/data/test.db");
    const db = &g_ops_db.?;
    defer db.deinit();
    g_ops_data_dir = dir ++ "/data";
    g_ops_removed = 0;
    dk.image_ops.init(.{
        .db = &g_ops_db,
        .data_dir = &g_ops_data_dir,
        .cfg = &dk.g_cfg,
        .on_counts_changed = opsNoop,
        .on_images_removed = opsRemoved,
        .on_wakeup = opsNoop,
    });
    defer dk.image_ops.fileOpsJoin(io);

    const lib_id = try db.storeLibrary(dir ++ "/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/b.png");
    defer b.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, db, false, null);
    defer grid.deinit();
    try grid.reloadImages(db);
    grid.awaitReload();
    try std.testing.expectEqual(@as(usize, 2), grid.images.items.len);

    // Trash a: the file moves to <data>/trash, the row is marked, the grid drops it.
    try grid.selection.put(a.id, {});
    dk.image_ops.performTrash(io, alloc, &grid);
    try pollFileOps(&grid);
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), g_ops_removed);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dir ++ "/lib/a.png", .{}));
    try std.testing.expectEqual(@as(i64, 1), (try db.getTrashStats()).count);

    // Restore it from the trash view.
    grid.view_mode = .trash;
    try grid.reloadImages(db);
    grid.awaitReload();
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);
    grid.selection.clearRetainingCapacity();
    try grid.selection.put(a.id, {});
    dk.image_ops.performRestore(io, alloc, &grid);
    try pollFileOps(&grid);
    try cwd.access(io, dir ++ "/lib/a.png", .{});
    try std.testing.expectEqual(@as(i64, 0), (try db.getTrashStats()).count);

    // Permanently delete b: file and row are gone.
    grid.view_mode = .library;
    try grid.reloadImages(db);
    grid.awaitReload();
    grid.selection.clearRetainingCapacity();
    try grid.selection.put(b.id, {});
    dk.image_ops.performDelete(io, alloc, &grid);
    try pollFileOps(&grid);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dir ++ "/lib/b.png", .{}));
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());
}

test "grid: background reloads apply only the latest request and keep removed images out" {
    const path = "/tmp/diffkeep_test_async_reload.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);
    try db.trashImage(b.id, "b.png", 1, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    // Nothing loads synchronously anymore.
    try std.testing.expectEqual(@as(usize, 0), grid.images.items.len);

    // Two requests in a row: the trash view is superseded by the library view.
    grid.view_mode = .trash;
    try grid.reloadImages(&db);
    grid.view_mode = .library;
    try grid.reloadImages(&db);
    try std.testing.expect(grid.reloadPending());
    grid.awaitReload();
    try std.testing.expect(!grid.reloadPending());
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);
    try std.testing.expectEqual(a.id, grid.images.items[0].id);

    // An image removed while a load is in flight stays out of its result.
    try grid.reloadImages(&db);
    var ids = std.AutoHashMap(u64, void).init(alloc);
    defer ids.deinit();
    try ids.put(a.id, {});
    dk.image_ops.removeFromGrid(&grid, &ids);
    grid.awaitReload();
    try std.testing.expectEqual(@as(usize, 0), grid.images.items.len);
}

test "db: vector search fills the limit past trashed nearest neighbours" {
    const path = "/tmp/diffkeep_test_vec_trash_fill.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    // Six images whose prompt vectors get steadily further from the query
    // (axis 0); the four nearest are trashed.
    var ids: [6]u64 = undefined;
    for (&ids, 0..) |*id, k| {
        var buf: [32]u8 = undefined;
        var img = try db.findOrCreateImage(alloc, lib_id, try std.mem.print(&buf, "/lib/{d}.png", .{k}));
        defer img.deinit(alloc);
        id.* = img.id;
        var v: [768]f32 = @splat(0);
        const t: f32 = @as(f32, @floatFromInt(k)) * 0.1;
        v[0] = @cos(t);
        v[1] = @sin(t);
        try db.storePromptEmbedding(img.id, &v);
        if (k < 4) try db.trashImage(img.id, "t", 1, 1000);
    }
    var q: [768]f32 = @splat(0);
    q[0] = 1.0;
    // limit 2 over-fetches k = 4 at first: all four are trashed, so the search
    // must widen to reach the two live images.
    const hits = try db.searchByPromptEmbedding(alloc, &q, 2, -1.0);
    defer {
        for (hits) |e| alloc.free(e.path);
        alloc.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(ids[4], hits[0].id);
    try std.testing.expectEqual(ids[5], hits[1].id);
}

test "search: a late search result or embedding can't replace a different view" {
    const path = "/tmp/diffkeep_test_search_race.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);
    try db.trashImage(b.id, "b.png", 1, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var search: dk.search.SearchState = .{};
    defer search.deinit(alloc);

    // A search is fired, then the user opens the trash before it lands.
    search.run(&grid, &db);
    try std.testing.expect(search.isSearchLoading(&grid));
    grid.view_mode = .trash;
    try grid.reloadImages(&db);
    grid.awaitReload();
    try std.testing.expect(!search.isSearchLoading(&grid));
    try expectGridIds(&grid, &.{b.id});

    // An embedding finishing now doesn't pull the user back to the library.
    search.embed_done.store(true, .release);
    search.pending_embeddings_gen = search.embed_generation.load(.acquire);
    search.applyEmbedIfDone(alloc, &grid, &db);
    try std.testing.expectEqual(dk.image_grid.ViewMode.trash, grid.view_mode);
    try std.testing.expect(!grid.reloadPending());
}

test "grid: an image scanned in while a load is running survives the load" {
    const path = "/tmp/diffkeep_test_scan_during_load.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // Hold the DB so the load can't finish, then let a scan report an image the
    // load's query won't contain.
    db.db_mutex.lockUncancelable(io);
    try grid.reloadImages(&db);
    grid.notifier.push(io, 77, "/lib/new.png", 0);
    grid.update();
    try expectGridIds(&grid, &.{77});
    db.db_mutex.unlock(io);

    grid.awaitReload();
    try expectGridIds(&grid, &.{77});
}

test "db: scan prefetch reports which images already have embeddings" {
    const path = "/tmp/diffkeep_test_prefetch_embeds.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);
    var v: [768]f32 = @splat(0);
    v[0] = 1.0;
    try db.storePromptEmbedding(a.id, &v);
    try db.storeImageEmbedding(b.id, &v);

    var known = try db.prefetchLibraryImages(alloc, lib_id);
    defer {
        var it = known.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        known.deinit();
    }
    const ma = known.get("/lib/a.png").?;
    const mb = known.get("/lib/b.png").?;
    try std.testing.expect(ma.has_prompt_embedding and !ma.has_image_embedding);
    try std.testing.expect(!mb.has_prompt_embedding and mb.has_image_embedding);
}
