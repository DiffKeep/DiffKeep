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

    // Images at three locations
    for ([_][]const u8{
        "/lib/cats/a.png",
        "/lib/cats/b.png",
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

    // Results are sorted by path; cats×2, dogs×1
    try std.testing.expectEqual(@as(usize, 2), subdirs.len);
    try std.testing.expectEqualStrings("/lib/cats", subdirs[0].path);
    try std.testing.expectEqual(@as(i64, 2),        subdirs[0].count);
    try std.testing.expectEqualStrings("/lib/dogs", subdirs[1].path);
    try std.testing.expectEqual(@as(i64, 1),        subdirs[1].count);
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
