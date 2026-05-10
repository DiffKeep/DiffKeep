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

fn frame() !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) return .close;
        if (e.evt == .app and e.evt.app.action == .quit) return .close;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var pad = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(16) });
    defer pad.deinit();

    const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });
    dvui.label(@src(), "Font test — NotoSansCJK Regular + Bold", .{}, .{ .font = dvui.Font.theme(.title) });

    // Latin
    dvui.label(@src(), "Latin:", .{}, .{ .font = bold });
    dvui.label(@src(), "The quick brown fox jumps over the lazy dog.", .{}, .{});

    // Simplified Chinese
    dvui.label(@src(), "Simplified Chinese:", .{}, .{ .font = bold });
    dvui.label(@src(), "杰作 最高品质 超级细节 完美照明", .{}, .{});

    // Japanese
    dvui.label(@src(), "Japanese:", .{}, .{ .font = bold });
    dvui.label(@src(), "傑作 最高品質 ひらがな カタカナ 日本語テスト", .{}, .{});

    // Korean
    dvui.label(@src(), "Korean:", .{}, .{ .font = bold });
    dvui.label(@src(), "걸작 최고 품질 한국어 테스트", .{}, .{});

    // Cyrillic
    dvui.label(@src(), "Cyrillic:", .{}, .{ .font = bold });
    dvui.label(@src(), "Шедевр высокое качество детализация", .{}, .{});

    // Size variation
    dvui.label(@src(), "Size variation:", .{}, .{ .font = bold });
    dvui.label(@src(), "12px 杰作 masterpiece걸작", .{}, .{ .font = dvui.Font.theme(.body).withSize(12) });
    dvui.label(@src(), "16px 杰作 masterpiece걸작", .{}, .{ .font = dvui.Font.theme(.body).withSize(16) });
    dvui.label(@src(), "24px 杰作 masterpiece걸작", .{}, .{ .font = dvui.Font.theme(.body).withSize(24) });
    dvui.label(@src(), "36px 杰作 masterpiece걸작", .{}, .{ .font = dvui.Font.theme(.body).withSize(36) });

    // Weight comparison
    dvui.label(@src(), "Weight comparison:", .{}, .{ .font = bold });
    dvui.label(@src(), "Regular: 杰作 masterpiece걸작 Шедевр", .{}, .{});
    dvui.label(@src(), "Bold:    杰作 masterpiece걸작 Шедевр", .{}, .{ .font = bold });


    return .ok;
}
