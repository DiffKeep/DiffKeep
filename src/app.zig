const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const known_folders = @import("known-folders");

const build_options = @import("build_options");

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

    {
        var content = dvui.box(@src(), .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        defer content.deinit();

        dvui.label(@src(), "DiffKeep", .{}, .{ .font = .theme(.title) });
        dvui.label(@src(), "AI Image Library Manager", .{}, .{});
    }

    return .ok;
}
