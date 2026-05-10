const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");
const i18n = @import("i18n.zig");

const noto_cjk_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
const noto_cjk_bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

// Config directory: set from --config/-c flag, otherwise resolved from known folders.
var g_config_dir: ?[]const u8 = null;

// Panel split ratios, stored here so dvui uses our values as the source of truth.
var g_left_ratio: f32 = 0.22;
var g_left_saved: f32 = 0.22;
var g_right_ratio: f32 = 0.72;
var g_right_saved: f32 = 0.72;

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
                    g_config_dir = init.gpa.dupe(u8, val) catch null;
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

    if (g_config_dir == null) {
        if (dvui.App.main_init) |init| {
            g_config_dir = try known_folders.getPath(init.io, init.gpa, init.environ_map, .local_configuration);
        }
    }

    std.log.info("DiffKeep {s} — config: {s}", .{
        build_options.version,
        g_config_dir orelse "(none)",
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
    if (dvui.App.main_init) |init| {
        if (g_config_dir) |dir| init.gpa.free(dir);
    }
}

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    // Capture panel toggle clicks before creating the paned widgets they act on.
    var toggle_left = false;
    var toggle_right = false;

    // ── Main column ──────────────────────────────────────────────────────
    var col = dvui.box(@src(), .{}, .{ .expand = .both });
    defer col.deinit();

    // ── Toolbar ──────────────────────────────────────────────────────────
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4 },
            .background = true,
        });
        defer toolbar.deinit();

        if (dvui.button(@src(), "≡", .{}, .{ .id_extra = 1 })) toggle_left = true;
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        // TODO: search text field
        dvui.label(@src(), "{s}", .{i18n.t(.search_placeholder)}, .{});
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dvui.button(@src(), "≡", .{}, .{ .id_extra = 2 })) toggle_right = true;
    }

    // ── Left sidebar | (center + right) ──────────────────────────────────
    {
        var outer = dvui.paned(@src(), .{
            .direction = .horizontal,
            .collapsed_size = 1,
            .split_ratio = &g_left_ratio,
            .handle_dynamic = .{ .handle_size_max = 8, .distance_max = 30 },
            .handle_margin = 2,
        }, .{ .expand = .both });
        defer outer.deinit();

        if (toggle_left) {
            if (g_left_ratio < 0.01) {
                outer.animateSplit(g_left_saved);
            } else {
                g_left_saved = g_left_ratio;
                outer.animateSplit(0.0);
            }
        }

        if (outer.showFirst()) {
            var sidebar = dvui.box(@src(), .{}, .{
                .expand = .both,
                .background = true,
            });
            defer sidebar.deinit();

            {
                var header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 6 },
                });
                defer header.deinit();
                dvui.label(@src(), "{s}", .{i18n.t(.nav_library)}, .{ .font = bold });
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            // TODO: folder tree
            dvui.label(@src(), "(folder tree)", .{}, .{ .padding = .all(8) });
        }
        outer.draw();

        // ── Center (image grid) | Right (metadata) ────────────────────────────
        if (outer.showSecond()) {
            var inner = dvui.paned(@src(), .{
                .direction = .horizontal,
                .collapsed_size = 1,
                .split_ratio = &g_right_ratio,
                .handle_dynamic = .{ .handle_size_max = 8, .distance_max = 30 },
                .handle_margin = 2,
            }, .{ .expand = .both });
            defer inner.deinit();

            if (toggle_right) {
                if (g_right_ratio > 0.99) {
                    inner.animateSplit(g_right_saved);
                } else {
                    g_right_saved = g_right_ratio;
                    inner.animateSplit(1.0);
                }
            }

            if (inner.showFirst()) {
                var grid_area = dvui.box(@src(), .{}, .{ .expand = .both });
                defer grid_area.deinit();

                var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
                defer scroll.deinit();

                // TODO: image grid
                dvui.label(@src(), "(image grid)", .{}, .{ .padding = .all(8) });
            }
            inner.draw();

            if (inner.showSecond()) {
                var meta = dvui.box(@src(), .{}, .{
                    .expand = .both,
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
    }

    // ── Statusbar ──────────────────────────────────────────────────────────
    {
        var statusbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4 },
            .background = true,
        });
        defer statusbar.deinit();

        dvui.label(@src(), "{s}{d}/{d}", .{i18n.t(.status_bar_image_count), 0, 0}, .{});
    }

    return .ok;
}
