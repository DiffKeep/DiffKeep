const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");
const i18n = @import("i18n.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const SDLBackend = @import("backend");

const noto_cjk_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
const noto_cjk_bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

// Path to the config file: set from --config/-c flag, otherwise resolved from known folders.
var g_config: ?[]const u8 = null;
var g_cfg: config_mod.Config = .{};
var g_db: ?db_mod.VectorDb = null;

var g_library_dialog_open: bool = false;
var g_pending_library_buf: [4096]u8 = undefined;
var g_pending_library_len: usize = 0;
var g_libraries: std.ArrayList([]const u8) = .empty;
var g_confirm_remove_idx: ?usize = null;

fn libraryFolderCallback(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    g_library_dialog_open = false;
    const files = filelist orelse return;
    if (files[0] == null) return;
    const path = std.mem.span(files[0].?);
    const len = @min(path.len, g_pending_library_buf.len);
    @memcpy(g_pending_library_buf[0..len], path[0..len]);
    g_pending_library_len = len;
}

// Panel widths in logical pixels.  _open stores the last non-collapsed width.
var g_left_w: f32 = 240;
var g_left_w_open: f32 = 240;
var g_right_w: f32 = 300;
var g_right_w_open: f32 = 300;

const left_w_min: f32 = 160;
const left_w_max: f32 = 400;
const right_w_min: f32 = 220;
const right_w_max: f32 = 480;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = appStart },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = frame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

fn appStart() dvui.App.StartOptions {
    if (dvui.App.main_init) |init| {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.skip(); // skip argv[0] (executable path)
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                if (it.next()) |val| {
                    g_config = std.fs.path.join(init.gpa, &.{ val, "DiffKeep.cfg" }) catch null;
                }
            }
        }
    }

    return .{
        .size = .{ .w = 1200.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .title = "DiffKeep",
        .vsync = true,
    };
}

fn appInit(win: *dvui.Window) !void {
    _ = win;

    if (dvui.App.main_init) |init| {
        if (g_config == null) {
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .local_configuration)) |config_dir| {
                defer init.gpa.free(config_dir);
                g_config = try std.fs.path.join(init.gpa, &.{ config_dir, "DiffKeep", "DiffKeep.cfg"});
            }
        }

        if (g_config) |cfg_path| {
            g_cfg = try config_mod.load(init.gpa, init.io, cfg_path);
        }

        const db_path = blk: {
            if (g_cfg.data_path) |p| {
                break :blk try init.gpa.dupe(u8, p);
            }
            if (try known_folders.getPath(init.io, init.gpa, init.environ_map, .data)) |data_base| {
                defer init.gpa.free(data_base);
                var data_dir = try std.Io.Dir.openDirAbsolute(init.io, data_base, .{});
                defer data_dir.close(init.io);
                try data_dir.createDirPath(init.io, "DiffKeep");
                break :blk try std.fs.path.join(init.gpa, &.{ data_base, "DiffKeep", "diffkeep.db" });
            }
            break :blk null;
        };
        if (db_path) |p| {
            defer init.gpa.free(p);
            g_db = try db_mod.VectorDb.init(init.gpa, init.io, p);
        }

        if (g_db) |*db| {
            const paths = db.listLibraries(init.gpa) catch &[_][]const u8{};
            defer init.gpa.free(paths);
            try g_libraries.appendSlice(init.gpa, paths);
        }
    }

    std.log.info("DiffKeep {s} — config: {s}", .{
        build_options.version,
        g_config orelse "(none)",
    });

    try dvui.addFont("NotoSansCJK", noto_cjk_bytes, null);
    try dvui.addFont("NotoSansCJKBold", noto_cjk_bold_bytes, null);

    var theme = dvui.themeGet();
    theme.font_body = theme.font_body.withFamily("NotoSansCJK");
    theme.font_title = theme.font_title.withFamily("NotoSansCJKBold");
    theme.font_mono = theme.font_mono.withFamily("NotoSansCJK");
    dvui.themeSet(theme);
}

fn appDeinit() void {
    if (g_db) |*database| {
        database.deinit();
        database.pool.deinit();
    }
    if (dvui.App.main_init) |init| {
        if (g_config) |cfg_path| {
            config_mod.save(g_cfg, init.io, cfg_path) catch |err| {
                std.log.warn("failed to save config: {}", .{err});
            };
            init.gpa.free(cfg_path);
        }
        g_cfg.deinit(init.gpa);
        for (g_libraries.items) |p| init.gpa.free(p);
        g_libraries.deinit(init.gpa);
    }
}

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

// Drag handle between two panels.  Click to collapse/expand; drag to resize.
// `side` indicates which panel the handle controls (its width grows left for
// .left, right for .right).  Width values are in logical pixels.
fn panelHandle(
    src: std.builtin.SourceLocation,
    comptime side: enum { left, right },
    width: *f32,
    width_open: *f32,
    w_min: f32,
    w_max: f32,
) void {
    var h = dvui.box(src, .{}, .{
        .min_size_content = .{ .w = 10, .h = 0 },
        .expand = .vertical,
        .background = true,
    });
    defer h.deinit();

    const id = h.data().id;
    const scale = h.data().contentRectScale().s;

    // Apply any running collapse/expand animation.
    if (dvui.animationGet(id, "_w")) |anim| {
        width.* = anim.value();
    }

    const collapsed = width.* < 2;
    var is_hovered = dvui.dataGet(null, id, "_hov", bool) orelse false;
    var dragged = dvui.dataGet(null, id, "_drag", bool) orelse false;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .position => {
                is_hovered = dvui.eventMatchSimple(e, h.data());
                if (is_hovered) dvui.cursorSet(.arrow_w_e);
            },
            .press => {
                if (me.button.pointer() and dvui.eventMatchSimple(e, h.data())) {
                    e.handle(@src(), h.data());
                    dvui.captureMouse(h.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .cursor = .arrow_w_e });
                    dragged = false;
                }
            },
            .motion => |delta| {
                if (dvui.captured(id)) {
                    if (dvui.dragging(me.p, null) != null) {
                        const dx: f32 = switch (side) {
                            .left => delta.x,
                            .right => -delta.x,
                        };
                        width.* = std.math.clamp(width.* + dx / scale, w_min, w_max);
                        width_open.* = width.*;
                        dragged = true;
                    }
                }
            },
            .release => {
                if (dvui.captured(id)) {
                    dvui.captureMouse(null, e.num);
                    if (!dragged) {
                        if (collapsed) {
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = @max(width_open.*, w_min),
                                .end_time = 200_000,
                                .easing = dvui.easing.outQuad,
                            });
                        } else {
                            width_open.* = width.*;
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = 0,
                                .end_time = 150_000,
                                .easing = dvui.easing.outQuad,
                            });
                        }
                    }
                    dragged = false;
                }
            },
            else => {},
        }
    }

    dvui.dataSet(null, id, "_hov", is_hovered);
    dvui.dataSet(null, id, "_drag", dragged);

    if (is_hovered or collapsed) {
        const ch: []const u8 = switch (side) {
            .left => if (collapsed) "›" else "‹",
            .right => if (collapsed) "‹" else "›",
        };
        dvui.label(@src(), "{s}", .{ch}, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .expand = .both,
        });
    }
}

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    if (g_pending_library_len > 0) {
        const path = g_pending_library_buf[0..g_pending_library_len];
        g_pending_library_len = 0;
        if (dvui.App.main_init) |init| {
            const duped = try init.gpa.dupe(u8, path);
            if (g_db) |*db| {
                _ = db.storeLibrary(duped) catch {};
            }
            try g_libraries.append(init.gpa, duped);
        }
    }

    // ── Main column ──────────────────────────────────────────────────────
    var col = dvui.box(@src(), .{}, .{ .expand = .both });
    defer col.deinit();

    // ── Toolbar ──────────────────────────────────────────────────────────
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .background = true,
        });
        defer toolbar.deinit();

        // Search field — expands to fill available width
        {
            var te = dvui.textEntry(@src(), .{
                .text = .{ .internal = .{} },
                .placeholder = i18n.t(.search_placeholder),
            }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(5),
                .min_size_content = .{ .h = 22 },
            });
            defer te.deinit();
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // Filter chips
        const chip: dvui.Options = .{
            .corner_radius = dvui.Rect.all(12),
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = .{ .x = 2, .w = 2 },
            .gravity_y = 0.5,
        };
        _ = dvui.button(@src(), "model: any \u{25bc}", .{}, chip.override(.{ .id_extra = 1 }));
        _ = dvui.button(@src(), "aspect: 1:1 \u{25bc}", .{}, chip.override(.{ .id_extra = 2 }));
        _ = dvui.button(@src(), "date: 30d \u{25bc}", .{}, chip.override(.{ .id_extra = 3 }));
        _ = dvui.button(@src(), "+ filter", .{}, chip.override(.{ .id_extra = 4 }));
    }

    // ── Content row: [left panel] [handle] [center] [handle] [right panel] ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true });
        defer row.deinit();

        // ── Left sidebar ──────────────────────────────────────────────────
        if (g_left_w >= 2) {
            var sidebar = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = g_left_w, .h = 0 },
                .expand = .vertical,
                .background = true,
            });
            defer sidebar.deinit();

            {
                var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 4, .h = 4 },
                });
                defer header.deinit();
                dvui.label(@src(), "{s}", .{i18n.t(.nav_library)}, .{ .font = bold, .gravity_y = 0.5 });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                if (dvui.buttonIcon(@src(), "add library", dvui.entypo.plus, .{}, .{}, .{
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(3),
                })) {
                    if (!g_library_dialog_open) {
                        g_library_dialog_open = true;
                        const sdl: *SDLBackend = dvui.currentWindow().backend.impl;
                        SDLBackend.c.SDL_ShowOpenFolderDialog(
                            libraryFolderCallback,
                            null,
                            sdl.window,
                            null,
                            false,
                        );
                    }
                }
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            if (g_libraries.items.len == 0) {
                dvui.label(@src(), "{s}", .{i18n.t(.library_empty)}, .{ .padding = .all(8) });
            } else {
                for (g_libraries.items, 0..) |lib_path, idx| {
                    var lib_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = idx,
                        .expand = .horizontal,
                        .padding = .{ .x = 8, .y = 2, .w = 4, .h = 2 },
                    });
                    defer lib_row.deinit();

                    const row_id = lib_row.data().id;
                    var row_hov = dvui.dataGet(null, row_id, "_hov", bool) orelse false;
                    for (dvui.events()) |*e| {
                        if (e.evt == .mouse and e.evt.mouse.action == .position)
                            row_hov = dvui.eventMatchSimple(e, lib_row.data());
                    }
                    dvui.dataSet(null, row_id, "_hov", row_hov);

                    dvui.label(@src(), "{s}", .{std.fs.path.basename(lib_path)}, .{
                        .expand = .horizontal,
                        .gravity_y = 0.5,
                    });

                    if (row_hov) {
                        if (dvui.buttonIcon(@src(), "remove library", dvui.entypo.minus, .{}, .{}, .{
                            .min_size_content = .{ .w = 10, .h = 10 },
                            .gravity_y = 0.5,
                            .padding = dvui.Rect.all(2),
                        })) {
                            g_confirm_remove_idx = idx;
                        }
                    }
                }
            }
        }

        panelHandle(@src(), .left, &g_left_w, &g_left_w_open, left_w_min, left_w_max);

        // ── Center: image grid ────────────────────────────────────────────
        {
            var grid_area = dvui.box(@src(), .{}, .{ .expand = .both });
            defer grid_area.deinit();

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            // TODO: image grid
            dvui.label(@src(), "(image grid)", .{}, .{ .padding = .all(8) });
        }

        panelHandle(@src(), .right, &g_right_w, &g_right_w_open, right_w_min, right_w_max);

        // ── Right: metadata panel ─────────────────────────────────────────
        if (g_right_w >= 2) {
            var meta = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = g_right_w, .h = 0 },
                .expand = .vertical,
                .background = true,
            });
            defer meta.deinit();

            {
                var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 6 },
                });
                defer header.deinit();
                dvui.label(@src(), "(image title)", .{}, .{ .font = bold });
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            // TODO: metadata fields for selected image
            const lp: dvui.Options = .{ .padding = .{ .x = 8, .y = 2 } };
            const bp: dvui.Options = .{ .font = bold, .padding = .{ .x = 8, .y = 2 } };
            dvui.label(@src(), "{s}", .{i18n.t(.detail_model)},   bp);
            dvui.label(@src(), "(model)",   .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_sampler)}, bp);
            dvui.label(@src(), "(sampler)", .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_steps)},   bp);
            dvui.label(@src(), "(steps)",   .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_size)},    bp);
            dvui.label(@src(), "(size)",    .{}, lp);
            dvui.label(@src(), "{s}", .{i18n.t(.detail_seed)},    bp);
            dvui.label(@src(), "(seed)",    .{}, lp);
        }
    }

    // ── Statusbar ──────────────────────────────────────────────────────────
    {
        var statusbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 2, .w = 4, .h = 2 },
            .background = true,
        });
        defer statusbar.deinit();

        dvui.label(@src(), "{s}{d}/{d}", .{ i18n.t(.status_bar_image_count), 0, 0 }, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        _ = dvui.buttonIcon(@src(), "settings", dvui.entypo.cog, .{}, .{}, .{
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(3),
            .margin = .{ .w = 2 },
        });
    }

    // ── Library removal confirmation modal ────────────────────────────────────
    if (g_confirm_remove_idx) |idx| {
        if (idx < g_libraries.items.len) {
            const path = g_libraries.items[idx];
            const name = std.fs.path.basename(path);

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

            dvui.label(@src(), "Remove library?", .{}, .{ .font = bold, .margin = .{ .h = 6 } });
            dvui.label(@src(), "{s}", .{name}, .{});
            dvui.label(@src(), "{s}", .{path}, .{ .margin = .{ .h = 14 } });

            {
                var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
                defer btn_row.deinit();

                if (dvui.button(@src(), "Cancel", .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                }
                if (dvui.button(@src(), "Remove", .{}, .{ .margin = .all(4) })) {
                    g_confirm_remove_idx = null;
                    if (dvui.App.main_init) |init| {
                        const removed = g_libraries.orderedRemove(idx);
                        if (g_db) |*db| _ = db.removeLibrary(removed) catch {};
                        init.gpa.free(removed);
                    }
                }
            }
        } else {
            g_confirm_remove_idx = null;
        }
    }

    return .ok;
}
