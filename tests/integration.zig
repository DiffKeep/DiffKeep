const std = @import("std");
const dvui = @import("dvui");
const dk = @import("diffkeep");

const alloc = std.testing.allocator;
const io = std.testing.io;

// ── DB helpers ────────────────────────────────────────────────────────────────

/// Trash the row `id` in the DB only (no file move), at its current path.
fn trashById(db: *dk.VectorDb, id: u64, trash_name: []const u8, size: i64, at: i64) !void {
    var details = (try db.getImageDetails(alloc, id)).?;
    defer details.deinit(alloc);
    try std.testing.expect(try db.trashImage(id, details.library_path, trash_name, size, at));
}

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
    try trashById(&db, img.id, "img_trash.png", 1024, 1000);
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
    try std.testing.expect(try db.restoreImage(img.id, "img_trash.png", img.libraryPath));
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
    try trashById(&db, dup2, "b_trash.png", 1, 1000);
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
        _ = try db.storePromptEmbedding(img.id, img.libraryPath, &prompt_vec);
        _ = try db.storeImageEmbedding(img.id, img.libraryPath, &image_vec);
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
    try trashById(&db, ids[1], "b_trash.png", 1024, 1000);
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
    try grid.reloadImages();
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
    try grid.reloadImages();
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
    try grid.reloadImages();
    grid.awaitReload();
    grid.autoplay = true;
    try grid.reloadImages();
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
    try grid.reloadImages();
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
    try grid.reloadImages();
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
    try grid.setSearchQuery("kitten");
    try std.testing.expect(!grid.incomingBelongs("/lib/cats/x.png"));
    try grid.setSearchQuery(null);

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
    try trashById(&db, d, "d_trash.png", 0, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
    grid.awaitReload();

    // Library view: every non-trashed image, trashed one excluded.
    grid.view_mode = .library;
    try grid.reloadImages();
    grid.awaitReload();
    try expectGridIds(&grid, &.{ a, b, c });

    // Trash view: only the trashed image.
    grid.view_mode = .trash;
    try grid.reloadImages();
    grid.awaitReload();
    try expectGridIds(&grid, &.{d});

    // Duplicates view: only the images that share a hash.
    grid.view_mode = .duplicates;
    try grid.reloadImages();
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
    try grid.reloadImages();
    grid.awaitReload();

    // Pretend the user had scrolled down, then switch view.
    grid.scroll_info.viewport.y = 500;
    try grid.reloadImages();
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
    try grid.reloadImages();
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

test "toolbar: sort buttons do nothing while a search is active" {
    const path = "/tmp/diffkeep_test_toolbar_sort_disabled.db";
    var fix = ToolbarFix{};
    defer fix.deinit();
    fix.db = try openDb(path);
    defer fix.db.?.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    fix.grid = try dk.GridState.init(io, alloc, &fix.db.?, false, null);
    defer fix.grid.?.deinit();
    const grid = &fix.grid.?;
    g_toolbar_fix = &fix;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1600, .h = 400 } });
    defer t.deinit();
    dk.style.install();

    try grid.setSearchQuery("cat");
    try dvui.testing.settle(toolbarFrame);
    try dvui.testing.moveTo("sort-mode");
    try dvui.testing.click(.left);
    try dvui.testing.moveTo("search-box");
    try dvui.testing.settle(toolbarFrame);
    try dvui.testing.moveTo("sort-dir");
    try dvui.testing.click(.left);
    try dvui.testing.settle(toolbarFrame);
    try std.testing.expectEqual(dk.image_grid.SortMode.date, grid.sort_mode);
    try std.testing.expectEqual(dk.image_grid.SortDir.desc, grid.sort_dir);

    // Cleared: the same buttons work again, from the settings left untouched.
    // (Move off sort-dir first, so its tooltip isn't covering sort-mode.)
    try grid.setSearchQuery(null);
    try dvui.testing.moveTo("search-box");
    try dvui.testing.settle(toolbarFrame);
    try dvui.testing.moveTo("sort-mode");
    try dvui.testing.click(.left);
    try dvui.testing.settle(toolbarFrame);
    try std.testing.expectEqual(dk.image_grid.SortMode.name, grid.sort_mode);
    try dvui.testing.moveTo("sort-dir");
    try dvui.testing.click(.left);
    try dvui.testing.settle(toolbarFrame);
    try std.testing.expectEqual(dk.image_grid.SortDir.asc, grid.sort_dir);
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

    _ = try db.setFavorite(a, "/lib/a.png", true);
    _ = try db.setFavorite(c, "/lib/c.png", true);
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
    _ = try db.setFavorite(a, "/lib/a.png", false);
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());

    // A trashed favorite is excluded from the (non-trashed) favorite count.
    _ = try db.setFavorite(b, "/lib/b.png", true); // now b and c are favorites
    try std.testing.expectEqual(@as(i64, 2), try db.getFavoriteCount());
    try trashById(&db, b, "b_trash.png", 0, 1000);
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());
}

test "db: setFavorite on a recycled id leaves the new image alone" {
    const path = "/tmp/diffkeep_test_favorite_stale.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib = try db.storeLibrary("/lib");
    const a = try makeImage(&db, lib, "/lib/a.png");
    try std.testing.expect(try db.deleteImage(a, "/lib/a.png"));
    // The new image may reuse a's id; a stale tile still says "/lib/a.png".
    const b = try makeImage(&db, lib, "/lib/b.png");
    try std.testing.expect(!try db.setFavorite(a, "/lib/a.png", true));
    try std.testing.expectEqual(@as(i64, 0), try db.getFavoriteCount());
    try std.testing.expect(try db.setFavorite(b, "/lib/b.png", true));
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
    _ = try db.setFavorite(a, "/lib/a.png", true);
    _ = try db.setFavorite(c, "/lib/c.png", true);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
    grid.awaitReload();

    // Library view: every entry carries the correct favorite flag.
    grid.view_mode = .library;
    try grid.reloadImages();
    grid.awaitReload();
    for (grid.images.items) |e| {
        try std.testing.expectEqual(e.id == a or e.id == c, e.favorite);
    }
    _ = b;

    // Favorites view: only favorited images, all flagged.
    grid.view_mode = .favorites;
    try grid.reloadImages();
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
    try grid.reloadImages();
    grid.awaitReload();
    grid.view_mode = .library;
    try grid.reloadImages();
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
    _ = try db.storePromptEmbedding(img.id, img.libraryPath, &vec);
    _ = try db.storeImageEmbedding(img.id, img.libraryPath, &vec);
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "image_embeddings"));
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "positive_prompt_embeddings"));

    try std.testing.expect(try db.deleteImage(img.id, img.libraryPath));
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
    try trashById(&db, b.id, "b_trash.png", 1, 1000);
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
    try grid.reloadImages();
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
    for (0..5000) |_| {
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
    defer dk.image_ops.fileOpsJoin();

    const lib_id = try db.storeLibrary(dir ++ "/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/b.png");
    defer b.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
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
    try grid.reloadImages();
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
    try grid.reloadImages();
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
    try trashById(&db, b.id, "b.png", 1, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    // Nothing loads synchronously anymore.
    try std.testing.expectEqual(@as(usize, 0), grid.images.items.len);

    // Two requests in a row: the trash view is superseded by the library view.
    grid.view_mode = .trash;
    try grid.reloadImages();
    grid.view_mode = .library;
    try grid.reloadImages();
    try std.testing.expect(grid.reloadPending());
    grid.awaitReload();
    try std.testing.expect(!grid.reloadPending());
    try std.testing.expectEqual(@as(usize, 1), grid.images.items.len);
    try std.testing.expectEqual(a.id, grid.images.items[0].id);

    // An image removed while a load is in flight stays out of its result.
    try grid.reloadImages();
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
        _ = try db.storePromptEmbedding(img.id, img.libraryPath, &v);
        if (k < 4) try trashById(&db, img.id, "t", 1, 1000);
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
    try trashById(&db, b.id, "b.png", 1, 1000);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var search: dk.search.SearchState = .{};
    defer search.deinit(alloc);

    // A search is fired, then the user opens the trash before it lands.
    search.run(&grid);
    try std.testing.expect(search.isSearchLoading(&grid));
    grid.view_mode = .trash;
    try grid.reloadImages();
    grid.awaitReload();
    try std.testing.expect(!search.isSearchLoading(&grid));
    try expectGridIds(&grid, &.{b.id});

    // An embedding finishing now doesn't pull the user back to the library.
    const gen = search.startEmbedGeneration(io, alloc);
    try std.testing.expect(search.deliverEmbedding(gen, .{ .prompt = try alloc.dupe(f32, &dupVec(0)) }));
    search.applyEmbedIfDone(alloc, &grid);
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
    try grid.reloadImages();
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
    _ = try db.storePromptEmbedding(a.id, a.libraryPath, &v);
    _ = try db.storeImageEmbedding(b.id, b.libraryPath, &v);

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

/// Sum of vertex-interpolated alpha (0..1, composited) of `tri` at point `p`.
fn meshCoverage(tri: dvui.Triangles, p: dvui.Point.Physical) f32 {
    var a: f32 = 0;
    var i: usize = 0;
    while (i < tri.indices.len) : (i += 3) {
        const v0 = tri.vertexes[tri.indices[i]];
        const v1 = tri.vertexes[tri.indices[i + 1]];
        const v2 = tri.vertexes[tri.indices[i + 2]];
        const d = (v1.pos.y - v2.pos.y) * (v0.pos.x - v2.pos.x) + (v2.pos.x - v1.pos.x) * (v0.pos.y - v2.pos.y);
        if (@abs(d) < 1e-9) continue;
        const l0 = ((v1.pos.y - v2.pos.y) * (p.x - v2.pos.x) + (v2.pos.x - v1.pos.x) * (p.y - v2.pos.y)) / d;
        const l1 = ((v2.pos.y - v0.pos.y) * (p.x - v2.pos.x) + (v0.pos.x - v2.pos.x) * (p.y - v2.pos.y)) / d;
        const l2 = 1 - l0 - l1;
        if (l0 < 0 or l1 < 0 or l2 < 0) continue;
        const va: f32 = l0 * @as(f32, @floatFromInt(v0.col.a)) + l1 * @as(f32, @floatFromInt(v1.col.a)) + l2 * @as(f32, @floatFromInt(v2.col.a));
        a += va / 255.0 * (1 - a);
    }
    return a;
}

test "icons: favorite star is a solid fill, not a hollow outline" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var mesh = dvui.render_tvg.MeshBuilder.init(alloc);
    defer mesh.deinit();
    try dvui.render_tvg.appendTvg(scratch.allocator(), &mesh, dk.app_icons.star, .{ .w = 16, .h = 16 }, .{
        .keep_aspect = true,
        .fill_color_override = .{ .color = .white },
    });
    const tri = mesh.toTriangles();

    // The star's middle is interior: a filled star covers it fully, the
    // package's broken stroke-only star leaves it empty.
    try std.testing.expect(meshCoverage(tri, .{ .x = 8, .y = 10 }) > 0.99);
    try std.testing.expect(meshCoverage(tri, .{ .x = 0.5, .y = 15.5 }) < 0.01);
}

// ── Review regressions (2026-11): DB layer ───────────────────────────────────

fn dupVec(axis: usize) [768]f32 {
    var v: [768]f32 = @splat(0);
    v[axis] = 1.0;
    return v;
}

test "db: storing an embedding again replaces the old vector" {
    const path = "/tmp/diffkeep_test_vec_replace.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer img.deinit(alloc);

    // A changed or reparsed image is embedded again: the new vector must win.
    _ = try db.storePromptEmbedding(img.id, img.libraryPath, &dupVec(0));
    _ = try db.storePromptEmbedding(img.id, img.libraryPath, &dupVec(1));
    _ = try db.storeImageEmbedding(img.id, img.libraryPath, &dupVec(0));
    _ = try db.storeImageEmbedding(img.id, img.libraryPath, &dupVec(1));
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "positive_prompt_embeddings"));
    try std.testing.expectEqual(@as(i64, 1), try embeddingRowCount(&db, "image_embeddings"));

    for ([_]bool{ true, false }) |prompt| {
        const hits = if (prompt)
            try db.searchByPromptEmbedding(alloc, &dupVec(1), 5, 0.9)
        else
            try db.searchByImageEmbedding(alloc, &dupVec(1), 5, 0.9);
        defer {
            for (hits) |h| alloc.free(h.path);
            alloc.free(hits);
        }
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(img.id, hits[0].id);
    }
}

test "db: a lookup that finds a row doesn't pin the connection to a stale snapshot" {
    const path = "/tmp/diffkeep_test_stale_snapshot.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);

    var other = try db.getConnection();
    defer other.deinit();

    // Cached-statement hits on `db`, then another connection commits.
    var again = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer again.deinit(alloc);
    _ = try db.storeLibrary("/lib");
    _ = try db.getLibraryIdByPath("/lib");
    _ = try other.setFavorite(a.id, "/lib/a.png", true);

    // `db` must see that commit and be able to write after it.
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());
    _ = try db.setFavorite(a.id, "/lib/a.png", false);
    try std.testing.expectEqual(@as(i64, 0), try other.getFavoriteCount());
}

test "db: folder queries match the folder exactly, not LIKE wildcards or other case" {
    const path = "/tmp/diffkeep_test_folder_like.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    for ([_][]const u8{
        "/lib/img_1/a.png", "/lib/imgX1/b.png", // `_` is a LIKE wildcard
        "/lib/cats/c.png",  "/lib/Cats/d.png", // LIKE is ASCII case-insensitive
        "/lib/100%/e.png",  "/lib/100x/f.png", // `%` too
    }) |p| {
        var img = try db.findOrCreateImage(alloc, lib_id, p);
        img.deinit(alloc);
    }

    const cases = [_]struct { folder: []const u8, want: []const u8 }{
        .{ .folder = "/lib/img_1", .want = "/lib/img_1/a.png" },
        .{ .folder = "/lib/cats", .want = "/lib/cats/c.png" },
        .{ .folder = "/lib/100%", .want = "/lib/100%/e.png" },
    };
    for (cases) |cs| {
        const in_folder = try db.listImagesInFolder(alloc, lib_id, cs.folder);
        defer {
            for (in_folder) |e| alloc.free(e.path);
            alloc.free(in_folder);
        }
        try std.testing.expectEqual(@as(usize, 1), in_folder.len);
        try std.testing.expectEqualStrings(cs.want, in_folder[0].path);

        const filtered = try db.listImagesFiltered(alloc, lib_id, cs.folder, null, &.{});
        defer {
            for (filtered) |e| alloc.free(e.path);
            alloc.free(filtered);
        }
        try std.testing.expectEqual(@as(usize, 1), filtered.len);
        try std.testing.expectEqualStrings(cs.want, filtered[0].path);
    }

    // A nested folder's subtree must not pick up a sibling that only LIKE-matches.
    {
        var img = try db.findOrCreateImage(alloc, lib_id, "/lib/cats/sub/g.png");
        img.deinit(alloc);
        var img2 = try db.findOrCreateImage(alloc, lib_id, "/lib/Cats/sub2/h.png");
        img2.deinit(alloc);
    }
    const subs = try db.listImmediateSubdirs(alloc, lib_id, "/lib/cats");
    defer {
        for (subs) |s| alloc.free(s.path);
        alloc.free(subs);
    }
    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("/lib/cats/sub", subs[0].path);
}

test "db: an empty thumbnail blob reads back without crashing" {
    const path = "/tmp/diffkeep_test_empty_blob.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer img.deinit(alloc);
    img.thumbnail = try alloc.dupe(u8, "");
    try db.saveImage(&img);

    var again = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer again.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), again.thumbnail.?.len);
    const bytes = (try db.getThumbnailBytes(alloc, img.id)).?;
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "db: closing every connection closes the database cleanly (WAL removed)" {
    const path = "/tmp/diffkeep_test_clean_close.db";
    const wal = path ++ "-wal";
    {
        var db = try openDb(path);
        defer db.deinit();
        const lib_id = try db.storeLibrary("/lib");
        var img = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
        img.deinit(alloc);
        var conn = try db.getConnection();
        conn.deinit();
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // SQLite deletes the WAL when the last connection closes; a connection that
    // failed to close (unfinalized statements) leaves it behind.
    const gone = blk: {
        std.Io.Dir.cwd().access(io, wal, .{}) catch break :blk true;
        break :blk false;
    };
    std.Io.Dir.cwd().deleteFile(io, wal) catch {};
    try std.testing.expect(gone);
}

test "db: a database from a newer build is rejected, not a crash" {
    const path = "/tmp/diffkeep_test_newer_schema.db";
    {
        var db = try openDb(path);
        defer db.deinit();
        try db.db.exec("PRAGMA user_version = 9999");
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.testing.expectError(error.SchemaTooNew, dk.VectorDb.init(alloc, io, path));
}

// ── Review regressions (2026-11): image identity ─────────────────────────────

fn rawCount(db: *dk.VectorDb, sql: [:0]const u8) !i64 {
    var stmt = try db.db.prepare(sql);
    defer stmt.deinit();
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

test "db: a path has at most one live row; a new file at a trashed path gets its own" {
    const path = "/tmp/diffkeep_test_unique_path.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var old = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer old.deinit(alloc);

    // The schema refuses a second live row (the scan/watcher race).
    try std.testing.expectEqual(@as(i64, 1), try rawCount(&db,
        "SELECT count(*) FROM sqlite_master WHERE name = 'idx_images_live_path' AND sql LIKE 'CREATE UNIQUE%'"));

    // ComfyUI reuses a trashed image's name: the new file is a new image, not
    // the trashed row coming back to life.
    try trashById(&db, old.id, "1_a.png", 1, 1000);
    var new = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer new.deinit(alloc);
    try std.testing.expect(new.id != old.id);
    try std.testing.expectEqual(@as(i64, 1), (try db.getTrashStats()).count);
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());
}

test "db: upgrading merges duplicate live rows left by the old scan/watcher race" {
    const path = "/tmp/diffkeep_test_dedupe_migration.db";
    {
        var db = try openDb(path);
        defer db.deinit();
        const lib_id = try db.storeLibrary("/lib");
        var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
        a.deinit(alloc);
        // Recreate the pre-index state: no unique index, two rows for one path.
        try db.db.exec("DROP INDEX IF EXISTS idx_images_live_path");
        try db.db.exec("INSERT INTO images (library_id, library_path, favorite) VALUES (1, '/lib/a.png', 1)");
        try db.db.exec("PRAGMA user_version = 13");
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var db = try dk.VectorDb.init(alloc, io, path);
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());
    // The favorite set on the dropped copy survives on the kept row.
    try std.testing.expectEqual(@as(i64, 1), try db.getFavoriteCount());
}

test "db: trash, restore and delete by a stale id don't touch the row now holding it" {
    const path = "/tmp/diffkeep_test_guarded_ops.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/new.png");
    defer img.deinit(alloc);

    // A stale grid entry still believes this id is "/lib/old.png".
    try std.testing.expect(!try db.trashImage(img.id, "/lib/old.png", "x", 1, 1000));
    try std.testing.expect(!try db.deleteImage(img.id, "/lib/old.png"));
    try std.testing.expectEqual(@as(i64, 1), try db.getTotalImageCount());

    try std.testing.expect(try db.trashImage(img.id, "/lib/new.png", "5_new.png", 1, 1000));
    // Trashing twice is a no-op, and restore needs the matching trash name.
    try std.testing.expect(!try db.trashImage(img.id, "/lib/new.png", "5_new.png", 1, 1000));
    try std.testing.expect(!try db.restoreImage(img.id, "other.png", "/lib/new.png"));
    try std.testing.expect(try db.restoreImage(img.id, "5_new.png", "/lib/new.png"));
    try std.testing.expectEqual(@as(i64, 0), (try db.getTrashStats()).count);
}

test "db: an embedding finished after its image was deleted isn't stored" {
    const path = "/tmp/diffkeep_test_orphan_embed.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    var gone = try db.findOrCreateImage(alloc, lib_id, "/lib/gone.png");
    defer gone.deinit(alloc);
    const gone_id = gone.id;
    try std.testing.expect(try db.deleteImage(gone_id, "/lib/gone.png"));
    // The id is recycled before the queued embedding lands.
    var next = try db.findOrCreateImage(alloc, lib_id, "/lib/next.png");
    defer next.deinit(alloc);
    try std.testing.expectEqual(gone_id, next.id);

    try std.testing.expect(!try db.storePromptEmbedding(gone_id, "/lib/gone.png", &dupVec(0)));
    try std.testing.expect(!try db.storeImageEmbedding(gone_id, "/lib/gone.png", &dupVec(0)));
    try std.testing.expectEqual(@as(i64, 0), try embeddingRowCount(&db, "positive_prompt_embeddings"));
    try std.testing.expectEqual(@as(i64, 0), try embeddingRowCount(&db, "image_embeddings"));
}

test "db: redundant-duplicate removal never counts two rows for one file" {
    const path = "/tmp/diffkeep_test_dedupe_same_path.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Two libraries that both reach /pics/sub/a.png (an overlap from before
    // overlapping libraries were refused).
    const outer = try db.storeLibrary("/pics");
    const inner = try db.storeLibrary("/pics/sub");
    for ([_]u64{ outer, inner }) |lib| {
        var img = try db.findOrCreateImage(alloc, lib, "/pics/sub/a.png");
        defer img.deinit(alloc);
        img.hash = try alloc.dupe(u8, "h1");
        try db.saveImage(&img);
    }
    try std.testing.expectEqual(@as(i64, 0), try db.getRedundantDuplicateCount());
    const reds = try db.listRedundantDuplicates(alloc);
    defer alloc.free(reds);
    try std.testing.expectEqual(@as(usize, 0), reds.len);
}

test "library_manager: a library inside or around an existing one is refused" {
    const dir = "/tmp/diffkeep_test_lib_overlap";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/pics/sub");
    try cwd.createDirPath(io, dir ++ "/pictures");
    defer cwd.deleteTree(io, dir) catch {};

    var db = try openDb(dir ++ "/test.db");
    defer db.deinit();

    var mgr = dk.LibraryManager.init(alloc, io, &db, false, false, false, null, null);
    defer mgr.deinit(io);

    _ = try mgr.addLibrary(dir ++ "/pics/");
    // Stored without the trailing slash, so folder queries line up.
    try std.testing.expect((try db.getLibraryIdByPath(dir ++ "/pics")) != null);
    try std.testing.expectError(error.LibraryExists, mgr.addLibrary(dir ++ "/pics"));
    try std.testing.expectError(error.LibraryOverlaps, mgr.addLibrary(dir ++ "/pics/sub"));
    try std.testing.expectError(error.LibraryOverlaps, mgr.addLibrary(dir));
    try std.testing.expectError(error.LibraryOverlaps, mgr.addLibrary("/"));
    // A sibling that merely shares a prefix is fine.
    _ = try mgr.addLibrary(dir ++ "/pictures");
}

test "image_ops: restoring next to a new file at the old path keeps both" {
    const dir = "/tmp/diffkeep_test_restore_clash";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/lib");
    try cwd.createDirPath(io, dir ++ "/data/trash");
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/a.png", .data = "old" });

    g_ops_db = try openDb(dir ++ "/data/test.db");
    const db = &g_ops_db.?;
    defer db.deinit();
    g_ops_data_dir = dir ++ "/data";
    dk.image_ops.init(.{
        .db = &g_ops_db,
        .data_dir = &g_ops_data_dir,
        .cfg = &dk.g_cfg,
        .on_counts_changed = opsNoop,
        .on_images_removed = opsRemoved,
        .on_wakeup = opsNoop,
    });
    defer dk.image_ops.fileOpsJoin();

    const lib_id = try db.storeLibrary(dir ++ "/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/a.png");
    defer a.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
    grid.awaitReload();
    try grid.selection.put(a.id, {});
    dk.image_ops.performTrash(io, alloc, &grid);
    try pollFileOps(&grid);

    // ComfyUI writes a new a.png, which the scan indexes as a new image.
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/a.png", .data = "new" });
    var b = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/a.png");
    defer b.deinit(alloc);

    grid.view_mode = .trash;
    try grid.reloadImages();
    grid.awaitReload();
    grid.selection.clearRetainingCapacity();
    try grid.selection.put(a.id, {});
    dk.image_ops.performRestore(io, alloc, &grid);
    try pollFileOps(&grid);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", try cwd.readFile(io, dir ++ "/lib/a.png", &buf));
    try std.testing.expectEqualStrings("old", try cwd.readFile(io, dir ++ "/lib/a (1).png", &buf));
    try std.testing.expectEqual(@as(i64, 2), try db.getTotalImageCount());
    var restored = (try db.getImageDetails(alloc, a.id)).?;
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings(dir ++ "/lib/a (1).png", restored.library_path);
}

test "image_ops: trashing an entry whose row is gone leaves the file alone" {
    const dir = "/tmp/diffkeep_test_trash_stale";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/lib");
    try cwd.createDirPath(io, dir ++ "/data/trash");
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/a.png", .data = "a" });

    g_ops_db = try openDb(dir ++ "/data/test.db");
    const db = &g_ops_db.?;
    defer db.deinit();
    g_ops_data_dir = dir ++ "/data";
    dk.image_ops.init(.{
        .db = &g_ops_db,
        .data_dir = &g_ops_data_dir,
        .cfg = &dk.g_cfg,
        .on_counts_changed = opsNoop,
        .on_images_removed = opsRemoved,
        .on_wakeup = opsNoop,
    });
    defer dk.image_ops.fileOpsJoin();

    // A viewer still shows id 77 for a.png, but that row no longer exists.
    dk.image_ops.performOnEntry(io, .{ .id = 77, .path = dir ++ "/lib/a.png", .filename = "a.png", .mtime = null }, .trash);
    dk.image_ops.fileOpsJoin();
    try cwd.access(io, dir ++ "/lib/a.png", .{});
}

// ── Review regressions (2026-11): search ordering ────────────────────────────

test "grid: vector search results stay in relevance order, not the sort order" {
    const path = "/tmp/diffkeep_test_relevance_order.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    // Nearest first: c, a, b — the reverse of both name and mtime order.
    const names = [_][]const u8{ "/lib/a.png", "/lib/b.png", "/lib/c.png" };
    const angles = [_]f32{ 0.3, 0.6, 0.0 };
    var ids: [3]u64 = undefined;
    for (names, angles, 0..) |n, t, k| {
        var img = try db.findOrCreateImage(alloc, lib_id, n);
        defer img.deinit(alloc);
        img.mtime = @intCast(100 + k);
        try db.saveImage(&img);
        ids[k] = img.id;
        var v: [768]f32 = @splat(0);
        v[0] = @cos(t);
        v[1] = @sin(t);
        _ = try db.storePromptEmbedding(img.id, n, &v);
    }

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var q: [768]f32 = @splat(0);
    q[0] = 1.0;
    grid.search_mode = .semantic;
    grid.query_embeddings = .{ .prompt = &q };
    grid.semantic_min_similarity = -1;
    for ([_]dk.image_grid.SortMode{ .date, .name, .random }) |mode| {
        grid.sort_mode = mode;
        try grid.reloadImages();
        grid.awaitReload();
        try std.testing.expectEqual(@as(usize, 3), grid.images.items.len);
        try std.testing.expectEqual(ids[2], grid.images.items[0].id);
        try std.testing.expectEqual(ids[0], grid.images.items[1].id);
        try std.testing.expectEqual(ids[1], grid.images.items[2].id);
    }
}

test "grid: text search results stay in rank order; sort settings return after" {
    const path = "/tmp/diffkeep_test_fts_rank_order.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const lib_id = try db.storeLibrary("/lib");
    // BM25 ranks b (most "cat", shortest) first, then c, then a: different
    // from name and date order in either direction.
    const names = [_][]const u8{ "/lib/a.png", "/lib/b.png", "/lib/c.png" };
    const prompts = [_][]const u8{ "cat dog bird fish horse", "cat cat cat", "cat dog" };
    var ids: [3]u64 = undefined;
    for (names, prompts, 0..) |n, pr, k| {
        var img = try db.findOrCreateImage(alloc, lib_id, n);
        defer img.deinit(alloc);
        img.mtime = @intCast(100 + k);
        img.positivePromptText = try alloc.dupe(u8, pr);
        try db.saveImage(&img);
        ids[k] = img.id;
    }

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    grid.search_mode = .fts;
    try grid.setSearchQuery("cat");
    try std.testing.expect(grid.isRelevanceRanked());
    for ([_]dk.image_grid.SortMode{ .date, .name, .random }) |mode| {
        for ([_]dk.image_grid.SortDir{ .asc, .desc }) |dir| {
            grid.sort_mode = mode;
            grid.sort_dir = dir;
            try grid.reloadImages();
            grid.awaitReload();
            try std.testing.expectEqual(@as(usize, 3), grid.images.items.len);
            try std.testing.expectEqual(ids[1], grid.images.items[0].id);
            try std.testing.expectEqual(ids[2], grid.images.items[1].id);
            try std.testing.expectEqual(ids[0], grid.images.items[2].id);
        }
    }

    // A query with nothing searchable left is not a search.
    try grid.setSearchQuery(" \"* ");
    try std.testing.expect(!grid.isRelevanceRanked());

    // Clearing the search applies the sort settings again.
    try grid.setSearchQuery(null);
    try std.testing.expect(!grid.isRelevanceRanked());
    grid.sort_mode = .name;
    grid.sort_dir = .asc;
    try grid.reloadImages();
    grid.awaitReload();
    try std.testing.expectEqual(ids[0], grid.images.items[0].id);
    try std.testing.expectEqual(ids[1], grid.images.items[1].id);
    try std.testing.expectEqual(ids[2], grid.images.items[2].id);
}

// ── Review regressions (2026-11): scanning ───────────────────────────────────

/// A valid 1x1 RGB PNG with no metadata chunks.
const plain_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90\x77\x53\xde\x00\x00\x00\x0c\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\x00\x00\x03\x01\x01\x00\xc9\xfe\x92\xef\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

fn waitForScans(mgr: *dk.LibraryManager) !void {
    for (0..2000) |_| {
        if (!mgr.isScanActive()) return;
        try std.Io.sleep(io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    }
    return error.ScanTimedOut;
}

fn rescanAll(mgr: *dk.LibraryManager) !void {
    try mgr.scanAllLibraries();
    try waitForScans(mgr);
}

fn setMtime(path: []const u8, secs: i64) !void {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, secs) * std.time.ns_per_s } } });
}

const ScanFixture = struct {
    dir: []const u8,
    db: dk.VectorDb,
    mgr: dk.LibraryManager,
    lib_id: u64,

    fn init(self: *ScanFixture, dir: []const u8, thumbnails_in_db: bool) !void {
        self.dir = dir;
        const db_path = try std.mem.concat(alloc, u8, &.{ dir, ".db" });
        defer alloc.free(db_path);
        self.db = try openDb(db_path);
        self.mgr = dk.LibraryManager.init(alloc, io, &self.db, thumbnails_in_db, false, false, null, null);
        self.lib_id = try self.mgr.addLibrary(dir);
        try waitForScans(&self.mgr);
    }

    fn deinit(self: *ScanFixture) void {
        self.mgr.deinit(io);
        self.db.deinit();
        const db_path = std.mem.concat(alloc, u8, &.{ self.dir, ".db" }) catch unreachable;
        defer alloc.free(db_path);
        std.Io.Dir.cwd().deleteFile(io, db_path) catch {};
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch {};
    }

    fn row(self: *ScanFixture, name: []const u8) !dk.Image {
        const p = try std.Io.Dir.path.join(alloc, &.{ self.dir, name });
        defer alloc.free(p);
        return self.db.findOrCreateImage(alloc, self.lib_id, p);
    }
};

fn freshDir(dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
}

test "scan: an emptied library folder (unmounted drive) keeps its images" {
    const dir = "/tmp/diffkeep_test_scan_unmounted";
    try freshDir(dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/a.png", .data = plain_png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/b.png", .data = plain_png });
    var fx: ScanFixture = undefined;
    try fx.init(dir, false);
    defer fx.deinit();
    try std.testing.expectEqual(@as(i64, 2), try fx.db.getTotalImageCount());

    // The mount point is still there but empty: not evidence the files are gone.
    try std.Io.Dir.cwd().deleteFile(io, dir ++ "/a.png");
    try std.Io.Dir.cwd().deleteFile(io, dir ++ "/b.png");
    try rescanAll(&fx.mgr);
    try std.testing.expectEqual(@as(i64, 2), try fx.db.getTotalImageCount());
}

test "scan: rows the scan removes are reported so the grid drops them" {
    const dir = "/tmp/diffkeep_test_scan_removed_ids";
    try freshDir(dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/a.png", .data = plain_png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/b.png", .data = plain_png });
    var fx: ScanFixture = undefined;
    try fx.init(dir, false);
    defer fx.deinit();

    var a = try fx.row("a.png");
    defer a.deinit(alloc);
    // Deleted while the app was closed: only the next scan notices.
    try std.Io.Dir.cwd().deleteFile(io, dir ++ "/a.png");
    try rescanAll(&fx.mgr);

    var removed: std.ArrayList(u64) = .empty;
    defer removed.deinit(alloc);
    fx.mgr.drainRemovedIds(io, &removed);
    try std.testing.expectEqualSlices(u64, &.{a.id}, removed.items);
}

test "scan: an unreadable subfolder doesn't abort the scan or lose its images" {
    const dir = "/tmp/diffkeep_test_scan_unreadable";
    try freshDir(dir);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir ++ "/locked");
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/locked/l.png", .data = plain_png });
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/a.png", .data = plain_png });
    var fx: ScanFixture = undefined;
    try fx.init(dir, false);
    defer fx.deinit();
    try std.testing.expectEqual(@as(i64, 2), try fx.db.getTotalImageCount());

    try cwd.setFilePermissions(io, dir ++ "/locked", .fromMode(0o000), .{});
    defer cwd.setFilePermissions(io, dir ++ "/locked", .fromMode(0o755), .{}) catch {};
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/b.png", .data = plain_png });
    try rescanAll(&fx.mgr);
    // b.png indexed, l.png (unreadable, not gone) kept.
    try std.testing.expectEqual(@as(i64, 3), try fx.db.getTotalImageCount());
}

test "scan: an image without metadata still gets its hash and thumbnail" {
    const dir = "/tmp/diffkeep_test_scan_no_meta";
    try freshDir(dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/plain.png", .data = plain_png });
    var fx: ScanFixture = undefined;
    try fx.init(dir, true);
    defer fx.deinit();

    var img = try fx.row("plain.png");
    defer img.deinit(alloc);
    try std.testing.expect(img.hash != null);
    try std.testing.expect(img.thumbnail != null);
    try std.testing.expect(img.mtime != null);
}

test "scan: a file rewritten without metadata drops the old prompt" {
    const dir = "/tmp/diffkeep_test_scan_lost_meta";
    try freshDir(dir);
    const cwd = std.Io.Dir.cwd();
    var src_buf: [1100000]u8 = undefined;
    const with_meta = try cwd.readFile(io, "test-artifacts/chunk-data.png", &src_buf);
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/x.png", .data = with_meta });
    try setMtime(dir ++ "/x.png", 1_000_000);
    var fx: ScanFixture = undefined;
    try fx.init(dir, false);
    defer fx.deinit();
    {
        var img = try fx.row("x.png");
        defer img.deinit(alloc);
        try std.testing.expect(img.positivePromptText != null);
    }

    try cwd.writeFile(io, .{ .sub_path = dir ++ "/x.png", .data = plain_png });
    try setMtime(dir ++ "/x.png", 2_000_000);
    try rescanAll(&fx.mgr);
    var img = try fx.row("x.png");
    defer img.deinit(alloc);
    try std.testing.expect(img.positivePromptText == null);
    try std.testing.expect(img.model == null);
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(plain_png, &expected_hash, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected_hash, .lower), img.hash.?);
}

test "library_manager: quiesce stops running scans and resumes them afterwards" {
    const dir = "/tmp/diffkeep_test_quiesce";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ "a", "b" }) |lib| {
        for (0..40) |k| {
            const p = try std.mem.print(&buf, "{s}/{s}/{d}.png", .{ dir, lib, k });
            try cwd.createDirPath(io, std.Io.Dir.path.dirname(p).?);
            try cwd.writeFile(io, .{ .sub_path = p, .data = plain_png });
        }
    }
    var db = try openDb(dir ++ ".db");
    defer std.Io.Dir.cwd().deleteFile(io, dir ++ ".db") catch {};
    defer db.deinit();
    var mgr = dk.LibraryManager.init(alloc, io, &db, false, false, false, null, null);
    defer mgr.deinit(io);

    _ = try mgr.addLibrary(dir ++ "/a");
    _ = try mgr.addLibrary(dir ++ "/b");
    // Swapping the embedder: nothing may still be scanning when this returns.
    mgr.quiesce(io);
    try std.testing.expect(!mgr.scanUsesEmbedder());
    // …and the interrupted / queued scans still complete.
    try waitForScans(&mgr);
    try std.testing.expectEqual(@as(i64, 80), try db.getTotalImageCount());
}

// ── Review regressions (2026-11): search state ───────────────────────────────

test "search: the grid keeps its own copy of the FTS query" {
    const path = "/tmp/diffkeep_test_search_owned_query.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var search: dk.search.SearchState = .{};
    defer search.deinit(alloc);

    @memcpy(search.buf[0..3], "cat");
    search.fire(io, alloc, &grid);
    grid.awaitReload();
    // The user keeps typing; a later, unrelated reload must still use "cat".
    @memcpy(search.buf[0..3], "dog");
    try std.testing.expectEqualStrings("cat", grid.search_query.?);
}

test "search: a superseded query embedding is dropped and doesn't end the newer one's loading" {
    const path = "/tmp/diffkeep_test_search_stale_embed.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var search: dk.search.SearchState = .{};
    defer search.deinit(alloc);

    const old_gen = search.startEmbedGeneration(io, alloc);
    const new_gen = search.startEmbedGeneration(io, alloc);
    // The old task finishes after the new one started: refused (and freed).
    try std.testing.expect(!search.deliverEmbedding(old_gen, .{ .prompt = try alloc.dupe(f32, &dupVec(0)) }));
    search.applyEmbedIfDone(alloc, &grid);
    try std.testing.expect(search.isSearchLoading(&grid));
    try std.testing.expect(!grid.query_embeddings.any());

    try std.testing.expect(search.deliverEmbedding(new_gen, .{ .prompt = try alloc.dupe(f32, &dupVec(1)) }));
    search.applyEmbedIfDone(alloc, &grid);
    try std.testing.expect(grid.query_embeddings.prompt != null);
    try std.testing.expectEqual(@as(f32, 1.0), grid.query_embeddings.prompt.?[1]);
    grid.awaitReload();
    try std.testing.expect(!search.isSearchLoading(&grid));
}

test "search: clearing the box cancels a semantic query still embedding" {
    const path = "/tmp/diffkeep_test_search_cancel_embed.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var search: dk.search.SearchState = .{};
    defer search.deinit(alloc);

    search.mode = .semantic;
    const gen = search.startEmbedGeneration(io, alloc); // "dog" is embedding…
    @memset(&search.buf, 0); // …and the user clears the box.
    search.fire(io, alloc, &grid);
    grid.awaitReload();
    try std.testing.expect(!search.deliverEmbedding(gen, .{ .prompt = try alloc.dupe(f32, &dupVec(0)) }));
    search.applyEmbedIfDone(alloc, &grid);
    try std.testing.expect(!grid.query_embeddings.any());
    try std.testing.expect(!search.isSearchLoading(&grid));
}

// ── Review regressions (2026-11): decoding ───────────────────────────────────

/// 3x2 8-bit greyscale PNG (one band).
const grey_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x03\x00\x00\x00\x02\x08\x00\x00\x00\x00\xb8\x1f\x39\xc6\x00\x00\x00\x0e\x49\x44\x41\x54\x78\x9c\x63\x60\xb0\xa9\x60\x00\x62\x00\x04\xb8\x01\x69\xed\xad\xdd\x62\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

test "vips: a greyscale image decodes to 4 bytes per pixel" {
    const dir = "/tmp/diffkeep_test_grey_decode";
    try freshDir(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/g.png", .data = grey_png });
    try dk.vips.init();

    const img = try dk.vips.loadImageRgbaWithDims(alloc, dir ++ "/g.png");
    defer alloc.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 3), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqual(@as(usize, 3 * 2 * 4), img.pixels.len);
    // Second pixel is grey 60: R = G = B = 60, opaque.
    try std.testing.expectEqualSlices(u8, &.{ 60, 60, 60, 255 }, img.pixels[4..8]);
}

// ── Review regressions (2026-11): bulk file operations ───────────────────────

test "image_ops: duplicate removal runs on the file-op queue and updates grid and viewers" {
    const dir = "/tmp/diffkeep_test_bulk_dedupe";
    const cwd = std.Io.Dir.cwd();
    try freshDir(dir);
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/lib");
    try cwd.createDirPath(io, dir ++ "/data/trash");
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/a.png", .data = "same" });
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/lib/b.png", .data = "same" });

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
    defer dk.image_ops.fileOpsJoin();

    const lib_id = try db.storeLibrary(dir ++ "/lib");
    var ids: [2]u64 = undefined;
    for ([_][]const u8{ dir ++ "/lib/a.png", dir ++ "/lib/b.png" }, 0..) |p, k| {
        var img = try db.findOrCreateImage(alloc, lib_id, p);
        defer img.deinit(alloc);
        img.hash = try alloc.dupe(u8, "h");
        try db.saveImage(&img);
        ids[k] = img.id;
    }
    var grid = try dk.GridState.init(io, alloc, db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
    grid.awaitReload();

    // The user trashes b while "remove duplicates" is also asked for: both go
    // through one queue, so b is trashed exactly once and nothing is orphaned.
    try grid.selection.put(ids[1], {});
    dk.image_ops.performTrash(io, alloc, &grid);
    dk.image_ops.startRemoveRedundantDuplicates(io);
    try pollFileOps(&grid);
    for (0..5000) |_| {
        _ = dk.image_ops.fileOpsPoll(io, alloc, &grid);
        if (!dk.image_ops.bulkActive()) break;
        try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    try std.testing.expect(!dk.image_ops.bulkActive());
    try std.testing.expectEqual(@as(i64, 1), (try db.getTrashStats()).count);
    try cwd.access(io, dir ++ "/lib/a.png", .{});
    try expectGridIds(&grid, &.{ids[0]});
    try std.testing.expectEqual(@as(usize, 1), g_ops_removed);
}

// ── Review regressions (2026-11): fs watcher events ──────────────────────────

test "library_manager: a burst of watcher events is merged per path, latest state wins" {
    var batch: dk.library_manager.PendingFileEvents = .{};
    defer batch.deinit(alloc);
    for (0..1000) |k| {
        var buf: [32]u8 = undefined;
        const p = try std.mem.print(&buf, "/lib/{d}.png", .{k % 10});
        try batch.add(alloc, .{ .library_id = 1, .path = try alloc.dupe(u8, p), .deleted = k >= 990 });
    }
    try batch.add(alloc, .{ .library_id = 1, .path = try alloc.dupe(u8, "/lib/0.png"), .deleted = false, .kind = .rescan_library });
    try std.testing.expectEqual(@as(usize, 11), batch.events.items.len);
    for (batch.events.items) |ev| {
        if (ev.kind == .file) try std.testing.expect(ev.deleted);
    }
}

test "library_manager: files deleted on disk are removed in the background and reported" {
    const path = "/tmp/diffkeep_test_watch_deletes.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);

    var mgr = dk.LibraryManager.init(alloc, io, &db, false, false, false, null, null);
    defer mgr.deinit(io);
    var batch: dk.library_manager.PendingFileEvents = .{};
    defer batch.deinit(alloc);
    try batch.add(alloc, .{ .library_id = lib_id, .path = try alloc.dupe(u8, "/lib/a.png"), .deleted = true });
    try batch.add(alloc, .{ .library_id = lib_id, .path = try alloc.dupe(u8, "/lib/b.png"), .deleted = true });
    mgr.flushFileEvents(io, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.events.items.len);
    mgr.awaitFileTasks(io);

    var removed: std.ArrayList(u64) = .empty;
    defer removed.deinit(alloc);
    mgr.drainRemovedIds(io, &removed);
    std.mem.sort(u64, removed.items, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ a.id, b.id }, removed.items);
    try std.testing.expectEqual(@as(i64, 0), try db.getTotalImageCount());
}

test "library_manager: a burst of new files is indexed by a bounded set of workers" {
    const dir = "/tmp/diffkeep_test_watch_burst";
    try freshDir(dir);
    var fx: ScanFixture = undefined;
    try fx.init(dir, false);
    defer fx.deinit();

    const n = 40;
    for (0..n) |k| {
        var buf: [96]u8 = undefined;
        const p = try std.mem.print(&buf, dir ++ "/f{d}.png", .{k});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = plain_png });
        fx.mgr.processFileEvent(fx.lib_id, try alloc.dupe(u8, p));
        // The same file reported again while queued is not queued twice.
        fx.mgr.processFileEvent(fx.lib_id, try alloc.dupe(u8, p));
        try std.testing.expect(fx.mgr.file_queue.load().workers <= dk.library_manager.max_file_workers);
    }
    fx.mgr.awaitFileTasks(io);
    try std.testing.expectEqual(@as(u32, 0), fx.mgr.file_queue.load().workers);
    try std.testing.expectEqual(@as(usize, 0), fx.mgr.file_queue.load().queued);
    try std.testing.expectEqual(@as(i64, n), try fx.db.getTotalImageCount());
}

test "sidebar: an expanded library keeps its folders after the counts refresh" {
    const path = "/tmp/diffkeep_test_sidebar_refresh.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    var img = try db.findOrCreateImage(alloc, lib_id, "/lib/cats/a.png");
    img.deinit(alloc);

    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    var sb = dk.sidebar.SidebarState{};
    defer sb.deinit(alloc);
    try sb.loadLibraries(alloc, &db);
    sb.initFolderLoader(alloc, io, &db);
    sb.libraries.items[0].expanded = true;

    g_sidebar = &sb;
    g_sidebar_db = &db;
    g_sidebar_grid = &grid;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    dk.style.install();

    try dvui.testing.settle(sidebarFrame);
    sb.folders.?.awaitIdle();
    try dvui.testing.settle(sidebarFrame);
    try std.testing.expectEqual(@as(usize, 1), sb.libraries.items[0].top_folders.len);
    // A favorite toggle or file op refreshes the counts…
    sb.applyLibraryCounts(&.{.{ .id = lib_id, .count = 2 }});
    try dvui.testing.settle(sidebarFrame);
    sb.folders.?.awaitIdle();
    try dvui.testing.settle(sidebarFrame);
    // …and the open tree still shows its folders.
    try std.testing.expectEqual(@as(usize, 1), sb.libraries.items[0].top_folders.len);
}

fn folderNode(nodes: []dk.sidebar.FolderNode, path: []const u8) ?*dk.sidebar.FolderNode {
    for (nodes) |*n| if (std.mem.eql(u8, n.path, path)) return n;
    return null;
}

test "sidebar: folder lists load in the background; a refresh keeps the open tree" {
    const path = "/tmp/diffkeep_test_sidebar_folder_loader.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    for ([_][]const u8{ "/lib/cats/a.png", "/lib/cats/kittens/b.png", "/lib/dogs/c.png" }) |p|
        _ = try makeImage(&db, lib_id, p);

    var sb = dk.sidebar.SidebarState{};
    defer sb.deinit(alloc);
    try sb.loadLibraries(alloc, &db);
    sb.initFolderLoader(alloc, io, &db);
    const lib = &sb.libraries.items[0];
    const loader = &sb.folders.?;

    // Nothing is listed until the background load lands.
    loader.request(lib_id, "/lib");
    loader.awaitIdle();
    try std.testing.expectEqual(@as(usize, 0), lib.top_folders.len);
    sb.applyFolderResults(alloc);
    try std.testing.expect(lib.top_loaded);
    try std.testing.expectEqual(@as(usize, 2), lib.top_folders.len);

    // Open /lib/cats and load its children.
    const cats = folderNode(lib.top_folders, "/lib/cats").?;
    try std.testing.expectEqual(@as(i64, 2), cats.count);
    cats.expanded = true;
    loader.request(lib_id, "/lib/cats");
    loader.awaitIdle();
    sb.applyFolderResults(alloc);
    try std.testing.expectEqual(@as(usize, 1), cats.children.len);

    // A new image changes the library count: the loaded lists reload with
    // the new counts, and /lib/cats stays open with its children.
    _ = try makeImage(&db, lib_id, "/lib/cats/kittens/d.png");
    sb.applyLibraryCounts(&.{.{ .id = lib_id, .count = 4 }});
    loader.awaitIdle();
    sb.applyFolderResults(alloc);
    const cats2 = folderNode(lib.top_folders, "/lib/cats").?;
    try std.testing.expectEqual(@as(i64, 3), cats2.count);
    try std.testing.expect(cats2.expanded);
    try std.testing.expectEqual(@as(usize, 1), cats2.children.len);
    try std.testing.expectEqual(@as(i64, 2), cats2.children[0].count);

    // A list for a library that is gone is dropped (and freed).
    loader.request(999, "/gone");
    loader.awaitIdle();
    sb.applyFolderResults(alloc);
}

test "grid: scan notifications don't pile up while another view is shown" {
    const path = "/tmp/diffkeep_test_notifier_other_view.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    grid.view_mode = .trash;
    try grid.reloadImages();
    grid.awaitReload();

    for (0..100) |k| grid.notifier.push(io, k + 1, "/lib/x.png", 0);
    grid.update();
    try std.testing.expectEqual(@as(usize, 0), grid.notifier.incoming.items.len);
    try std.testing.expectEqual(@as(usize, 0), grid.images.items.len);
}

test "grid: a thumbnail load in flight when its id is invalidated is discarded" {
    const path = "/tmp/diffkeep_test_thumb_inflight.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();

    // A worker is decoding id 7's old file when the id is recycled.
    grid.queue_mutex.lockUncancelable(io);
    try grid.in_flight.put(7, {});
    grid.queue_mutex.unlock(io);
    grid.invalidateThumbnail(7);

    // The old image's thumbnail must not land in the cache…
    grid.finishLoad(7, "/lib/old.png", try alloc.dupe(u8, "old-jpeg"));
    try std.testing.expect(grid.pending.get(7) == null);
    // …nor may a failed old load block the new image's thumbnail.
    grid.queue_mutex.lockUncancelable(io);
    try grid.in_flight.put(7, {});
    grid.queue_mutex.unlock(io);
    grid.invalidateThumbnail(7);
    grid.finishLoad(7, "/lib/old.png", null);
    try std.testing.expect(!grid.load_failed.contains(7));

    // A load that wasn't invalidated is kept.
    grid.queue_mutex.lockUncancelable(io);
    try grid.in_flight.put(8, {});
    grid.queue_mutex.unlock(io);
    grid.finishLoad(8, "/lib/new.png", try alloc.dupe(u8, "new-jpeg"));
    try std.testing.expect(grid.pending.get(8) != null);
}

// ── Review regressions (2026-11): removing a library ─────────────────────────

test "library_manager: removing a library stops its scan, reports its images and deletes its trash" {
    const dir = "/tmp/diffkeep_test_remove_lib";
    const cwd = std.Io.Dir.cwd();
    try freshDir(dir);
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir ++ "/lib");
    try cwd.createDirPath(io, dir ++ "/data/trash");
    var buf: [128]u8 = undefined;
    for (0..60) |k| {
        try cwd.writeFile(io, .{ .sub_path = try std.mem.print(&buf, "{s}/lib/{d}.png", .{ dir, k }), .data = plain_png });
    }
    var db = try openDb(dir ++ "/data/test.db");
    defer db.deinit();
    var mgr = dk.LibraryManager.init(alloc, io, &db, false, false, false, null, null);
    defer mgr.deinit(io);
    mgr.data_dir = dir ++ "/data";

    const lib_id = try mgr.addLibrary(dir ++ "/lib");
    try waitForScans(&mgr);
    // One image is in the trash (its file moved to <data>/trash).
    var t = try db.findOrCreateImage(alloc, lib_id, dir ++ "/lib/0.png");
    defer t.deinit(alloc);
    try trashById(&db, t.id, "1_0.png", 1, 1000);
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/data/trash/1_0.png", .data = plain_png });

    // Removed while a rescan is running.
    try mgr.scanAllLibraries();
    try mgr.removeLibrary(io, dir ++ "/lib");
    try std.testing.expect(!mgr.isScanActive() or mgr.activeLibrary() != lib_id);
    mgr.awaitFileTasks(io);
    try waitForScans(&mgr);

    try std.testing.expectEqual(@as(i64, 0), try db.getTotalImageCount());
    try std.testing.expectEqual(@as(i64, 0), (try db.getTrashStats()).count);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dir ++ "/data/trash/1_0.png", .{}));
    var removed: std.ArrayList(u64) = .empty;
    defer removed.deinit(alloc);
    mgr.drainRemovedIds(io, &removed);
    try std.testing.expectEqual(@as(usize, 60), removed.items.len);
}

// ── Review regressions (2026-11): viewer ─────────────────────────────────────

fn viewerImages(ids: []const u64) !std.ArrayList(dk.ImageEntry) {
    var images: std.ArrayList(dk.ImageEntry) = .empty;
    for (ids, 0..) |id, i| {
        const p = try alloc.print("/lib/img{d}.png", .{i});
        try images.append(alloc, .{ .id = id, .path = p, .filename = std.Io.Dir.path.basename(p), .mtime = null });
    }
    return images;
}

test "viewer: wheel zoom keeps the point under the cursor still" {
    const s: f32 = 1.5;
    for ([_]f32{ 0.2, 1.0, 3.0 }) |z| {
        for ([_]f32{ 1.12, 1.0 / 1.12, 4.0 }) |f| {
            const pan: f32 = 37;
            const u: f32 = -120; // cursor, in image units from the image centre
            const z2 = z * f;
            const before = (pan + u) * z * s; // screen offset of that image point
            const pan2 = dk.image_viewer.zoomPanAbout(pan, u, z, z2);
            const after = (pan2 + u) * z2 * s;
            try std.testing.expectApproxEqAbs(before, after, 1e-3);
        }
    }
}

test "viewer: removing an earlier image doesn't restart the playing video" {
    var vs = dk.image_viewer.ViewerState.init(alloc, 1, try viewerImages(&.{ 10, 11, 12 }), 2, null, null, io, null, null);
    defer vs.deinit();
    // A player is open for the current entry (index 2).
    vs.video_player_idx = 2;
    var ids = std.AutoHashMap(u64, void).init(alloc);
    defer ids.deinit();
    try ids.put(10, {});
    vs.removeImages(&ids);
    try std.testing.expectEqual(@as(usize, 1), vs.current_idx);
    try std.testing.expectEqual(vs.current_idx, vs.video_player_idx);
}

test "viewer: a decode that finishes after the list changed is discarded" {
    var vs = dk.image_viewer.ViewerState.init(alloc, 1, try viewerImages(&.{ 10, 11, 12 }), 0, null, null, io, null, null);
    defer vs.deinit();
    // A load for slot 0 was started (generation g) …
    const g = vs.claimSlot(0, 1);
    // … then the list changed and the slot was claimed again for another image.
    vs.flushCache();
    _ = vs.claimSlot(0, 1);
    // The old decode lands: it must not fill the re-claimed slot.
    try std.testing.expect(!vs.deliverDecode(0, g, .{ .pixels = try alloc.alloc(u8, 4), .width = 1, .height = 1 }));
    // A failed decode marks its slot failed instead of spinning forever.
    const g2 = vs.claimSlot(1, 2);
    try std.testing.expect(vs.deliverDecode(1, g2, null));
    try std.testing.expect(vs.cache_slots[1].failed);
}

// ── Review regressions (2026-11): counts off the render thread ───────────────

test "counts: the loader computes every count on its own connection" {
    const path = "/tmp/diffkeep_test_counts.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    for ([_][]const u8{ "/lib/a.png", "/lib/b.png", "/lib/c.png" }, 0..) |p, k| {
        var img = try db.findOrCreateImage(alloc, lib_id, p);
        defer img.deinit(alloc);
        img.hash = try alloc.dupe(u8, if (k < 2) "same" else "other");
        try db.saveImage(&img);
        if (k == 0) _ = try db.setFavorite(img.id, p, true);
        if (k == 2) try trashById(&db, img.id, "t.png", 10, 1000);
    }

    var loader = dk.counts.CountsLoader.init(alloc, io, &db);
    defer loader.deinit();
    loader.request();
    loader.request(); // coalesces with the running load
    var got: ?dk.counts.Counts = null;
    for (0..5000) |_| {
        got = loader.poll();
        if (got != null) break;
        try std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var c = got orelse return error.CountsTimedOut;
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 2), c.total);
    try std.testing.expectEqual(@as(i64, 1), c.trash.?.count);
    try std.testing.expectEqual(@as(i64, 2), c.duplicates);
    try std.testing.expectEqual(@as(i64, 1), c.favorites);
    try std.testing.expectEqual(@as(usize, 1), c.libraries.len);
    try std.testing.expectEqual(@as(i64, 2), c.libraries[0].count);
    try std.testing.expectEqual(@as(i64, 1), c.redundant_duplicates);
    try std.testing.expect(c.db_stats == null); // not asked for
}

test "counts: stats load on request, and clearing a cache runs in the background" {
    const path = "/tmp/diffkeep_test_counts_stats.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    for ([_][]const u8{ "/lib/a.png", "/lib/b.png" }) |p| {
        var img = try db.findOrCreateImage(alloc, lib_id, p);
        defer img.deinit(alloc);
        img.thumbnail = try alloc.dupe(u8, "jpegbytes");
        try db.saveImage(&img);
    }

    var loader = dk.counts.CountsLoader.init(alloc, io, &db);
    defer loader.deinit();

    loader.requestStats();
    loader.awaitIdle();
    var c1 = loader.poll() orelse return error.NoCounts;
    defer c1.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 2), c1.db_stats.?.thumbnail_count);

    // A plain refresh that lands before the stats were read keeps them.
    loader.requestStats();
    loader.awaitIdle();
    loader.request();
    loader.awaitIdle();
    var c2 = loader.poll() orelse return error.NoCounts;
    defer c2.deinit(alloc);
    try std.testing.expect(c2.db_stats != null);

    loader.clear(.thumbnails);
    loader.awaitIdle();
    var c3 = loader.poll() orelse return error.NoCounts;
    defer c3.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 0), c3.db_stats.?.thumbnail_count);
    try std.testing.expectEqual(@as(i64, 2), c3.total);
}

test "detail panel: details load in the background and the newest selection wins" {
    const dir = "/tmp/diffkeep_test_detail_async";
    try freshDir(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var src_buf: [1100000]u8 = undefined;
    const png = try std.Io.Dir.cwd().readFile(io, "test-artifacts/chunk-data.png", &src_buf);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/a.png", .data = png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/b.png", .data = plain_png });

    var db = try openDb(dir ++ "/t.db");
    defer db.deinit();
    const lib_id = try db.storeLibrary(dir);
    var a = try db.findOrCreateImage(alloc, lib_id, dir ++ "/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, dir ++ "/b.png");
    defer b.deinit(alloc);

    var ds: dk.detail_panel.DetailState = .{};
    defer ds.deinit(alloc);
    // Arrowing quickly: a, then b. Only b's details may be shown.
    ds.update(a.id, &db, alloc, io);
    ds.update(b.id, &db, alloc, io);
    ds.awaitLoad(alloc);
    try std.testing.expectEqual(b.id, ds.detail.?.id);
    try std.testing.expectEqual(@as(?u32, 1), ds.detail.?.width);

    ds.update(a.id, &db, alloc, io);
    ds.awaitLoad(alloc);
    try std.testing.expectEqual(a.id, ds.detail.?.id);
    try std.testing.expect(ds.detail.?.raw_chunks.len == 2);
    try std.testing.expectEqual(@as(?i64, @intCast(png.len)), ds.detail.?.file_size);
}

fn testFrame(pts: i64) !dk.video_player.Frame {
    return .{ .pixels = try alloc.alloc(u8, 4), .width = 1, .height = 1, .pts_ms = pts };
}

fn freeFrame(f: ?dk.video_player.Frame) void {
    if (f) |fr| alloc.free(fr.pixels);
}

test "video player: frames play at their own timestamps, not an average rate" {
    // A GIF that holds its first frame for 2 s, then runs 50 ms frames.
    var p: dk.video_player.VideoPlayer = .{
        .gpa = alloc, .io = io, .source = undefined,
        .frame_duration_ns = 100 * std.time.ns_per_ms, .frame_duration_ms = 100, .duration_ms = 2100,
    };
    defer p.freeQueued();
    for ([_]i64{ 0, 2000, 2050 }) |pts| p.pushFrame(try testFrame(pts), p.seek_gen);

    const ms = std.time.ns_per_ms;
    const f0 = p.tick(0);
    defer freeFrame(f0);
    try std.testing.expectEqual(@as(i64, 0), f0.?.pts_ms);
    try std.testing.expect(p.tick(150 * ms) == null); // average fps would advance here
    const f1 = p.tick(2000 * ms);
    defer freeFrame(f1);
    try std.testing.expectEqual(@as(i64, 2000), f1.?.pts_ms);
    try std.testing.expect(p.tick(2020 * ms) == null);
    const f2 = p.tick(2050 * ms);
    defer freeFrame(f2);
    try std.testing.expectEqual(@as(i64, 2050), f2.?.pts_ms);
}

test "video player: a scrub never shows a frame decoded before the seek" {
    var p: dk.video_player.VideoPlayer = .{
        .gpa = alloc, .io = io, .source = undefined,
        .frame_duration_ns = 40 * std.time.ns_per_ms, .frame_duration_ms = 40, .duration_ms = 5000,
    };
    defer p.freeQueued();
    p.playing = false;
    for ([_]i64{ 0, 40, 80 }) |pts| p.pushFrame(try testFrame(pts), p.seek_gen);
    p.requestSeek(3000);
    // The queue still holds pre-seek frames: none may be shown for the seek.
    try std.testing.expect(p.tick(0) == null);
    p.pushFrame(try testFrame(3000), p.seek_gen);
    const f = p.tick(0);
    defer freeFrame(f);
    try std.testing.expectEqual(@as(i64, 3000), f.?.pts_ms);
}

test "delete dialog: confirming acts on the images chosen when it opened" {
    const path = "/tmp/diffkeep_test_delete_snapshot.db";
    var db = try openDb(path);
    defer db.deinit();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const lib_id = try db.storeLibrary("/lib");
    var a = try db.findOrCreateImage(alloc, lib_id, "/lib/a.png");
    defer a.deinit(alloc);
    var b = try db.findOrCreateImage(alloc, lib_id, "/lib/b.png");
    defer b.deinit(alloc);
    var grid = try dk.GridState.init(io, alloc, &db, false, null);
    defer grid.deinit();
    try grid.reloadImages();
    grid.awaitReload();

    var dlg: dk.delete_dialog.DeleteDialogState = .{};
    defer dlg.deinit(alloc);
    try grid.selection.put(a.id, {});
    dlg.snapshot(alloc, &grid);
    // A background reload lands while the dialog is open and clears the selection.
    grid.selection.clearRetainingCapacity();
    try grid.selection.put(b.id, {});
    dlg.restoreSelection(&grid);
    try std.testing.expectEqual(@as(u32, 1), grid.selection.count());
    try std.testing.expect(grid.selection.contains(a.id));
}
