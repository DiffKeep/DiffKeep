const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version string from git, computed on every build: a configure-time
    // lookup would be cached by Zig 0.17 and go stale. Embedded via
    // @embedFile("git_version").
    const git_version_tool = b.addExecutable(.{
        .name = "git_version",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/git_version.zig"),
            .target = b.graph.host,
        }),
    });
    const run_git_version = b.addRunArtifact(git_version_tool);
    run_git_version.has_side_effects = true;
    const git_version = run_git_version.captureStdOut(.{});

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    // *** dvui / SDL3 ***
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    // *** Main executable ***
    const exe = b.addExecutable(.{
        .name = "DiffKeep",
        .root_module = b.addModule("App", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/app.zig"),
        }),
    });
    exe.root_module.strip = optimize != .debug;
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("backend", dvui_dep.module("sdl3"));

    const icons_dep = b.dependency("icons", .{ .target = target, .optimize = optimize });
    exe.root_module.link_libcpp = true;
    const os = target.result.os.tag;
    if (os == .linux) {
        exe.root_module.linkSystemLibrary("X11", .{});
        exe.root_module.linkSystemLibrary("Xi", .{});
        exe.root_module.linkSystemLibrary("wayland-client", .{});
    } else if (os == .windows) {
        exe.root_module.linkSystemLibrary("ole32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("uuid", .{});
        exe.root_module.addCSourceFile(.{
            .file = b.path("lib/dnd/dnd_win32.c"),
            .flags = &.{ "-DUNICODE", "-D_UNICODE" },
        });
    } else if (os == .macos) {
        exe.root_module.linkFramework("AppKit", .{});
        exe.root_module.addCSourceFile(.{
            .file = b.path("lib/dnd/dnd_macos.m"),
            .flags = &.{ "-fobjc-arc" },
        });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run DiffKeep");
    run_step.dependOn(&run_cmd.step);

    // *** C header translations (replaces @cImport) ***
    const translate_c = b.dependency("translate_c", .{});
    const sqlite_c: Translator = .init(translate_c, .{
        .name = "sqlite_c",
        .c_source_file = b.addWriteFiles().add("sqlite_c.h",
            \\#include <sqlite3.h>
            \\#include <sqlite-vec.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    sqlite_c.addIncludePath(b.path("lib/sqlite"));
    sqlite_c.addIncludePath(b.path("lib/sqlite-vec"));
    const vips_c: Translator = .init(translate_c, .{
        .name = "vips_c",
        .c_source_file = b.path("lib/vips/vips_helper.h"),
        .target = target,
        .optimize = optimize,
    });
    const video_c: Translator = .init(translate_c, .{
        .name = "video_c",
        .c_source_file = b.path("lib/video/video_helper.h"),
        .target = target,
        .optimize = optimize,
    });
    if (os == .linux) {
        const x11_c: Translator = .init(translate_c, .{
            .name = "x11_c",
            .c_source_file = b.addWriteFiles().add("x11_c.h",
                \\#include <X11/Xlib.h>
                \\#include <X11/Xatom.h>
                \\#include <X11/extensions/XInput2.h>
                \\
            ),
            .target = target,
            .optimize = optimize,
        });
        const wayland_c: Translator = .init(translate_c, .{
            .name = "wayland_c",
            .c_source_file = b.addWriteFiles().add("wayland_c.h", "#include <wayland-client.h>\n"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("x11_c", x11_c.mod);
        exe.root_module.addImport("wayland_c", wayland_c.mod);
    }

    // *** sqlite ***
    const sqlite_c_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_c_module.addCSourceFile(.{
        .file = b.path("lib/sqlite/sqlite3.c"),
        .flags = &[_][]const u8{
            "-std=c99",
            "-D_POSIX_C_SOURCE=200809L",
            "-DSQLITE_ENABLE_RTREE",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_USE_URI=1",
            "-DSQLITE_ENABLE_COLUMN_METADATA",
        },
    });
    sqlite_c_module.addCSourceFile(.{
        .file = b.path("lib/sqlite-vec/sqlite-vec.c"),
        .flags = &[_][]const u8{
            "-std=gnu99",
            "-D_GNU_SOURCE",
            "-DSQLITE_CORE",
            "-DSQLITE_EXTENSION_INIT1=",
        },
    });
    sqlite_c_module.linkSystemLibrary("m", .{});
    sqlite_c_module.addIncludePath(b.path("lib/sqlite"));
    sqlite_c_module.addIncludePath(b.path("lib/sqlite-vec"));

    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite",
        .root_module = sqlite_c_module,
    });

    const sqlite_module_zig = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .imports = &.{.{ .name = "sqlite_c", .module = sqlite_c.mod }},
    });

    // *** vips ***
    const vips_helper_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vips_helper_mod.addCSourceFile(.{
        .file = b.path("lib/vips/vips_helper.c"),
        .flags = &.{},
    });
    vips_helper_mod.addIncludePath(b.path("lib/vips"));
    vips_helper_mod.linkSystemLibrary("vips", .{});

    const vips_helper_lib = b.addLibrary(.{
        .name = "vips_helper",
        .root_module = vips_helper_mod,
    });

    const vips_module = b.addModule("vips", .{
        .root_source_file = b.path("src/vips.zig"),
        .imports = &.{.{ .name = "vips_c", .module = vips_c.mod }},
    });

    // *** video (libav*) ***
    // System-linked like vips; pkg-config (default for linkSystemLibrary) supplies
    // the per-platform include/lib paths. The C wrapper itself is fully portable.
    const av_libs = [_][]const u8{ "avformat", "avcodec", "avutil", "swscale", "swresample" };
    const video_helper_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    video_helper_mod.addCSourceFile(.{
        .file = b.path("lib/video/video_helper.c"),
        .flags = &.{},
    });
    video_helper_mod.addIncludePath(b.path("lib/video"));
    for (av_libs) |lib| video_helper_mod.linkSystemLibrary(lib, .{});

    const video_helper_lib = b.addLibrary(.{
        .name = "video_helper",
        .root_module = video_helper_mod,
    });

    const video_module = b.addModule("video", .{
        .root_source_file = b.path("src/video.zig"),
        .imports = &.{.{ .name = "video_c", .module = video_c.mod }},
    });

    // Everything the app's own modules need, shared with the integration tests
    // so the two builds can't drift apart.
    const core: Core = .{
        .sqlite_lib = sqlite_lib,
        .sqlite = sqlite_module_zig,
        .vips_lib = vips_helper_lib,
        .vips = vips_module,
        .video_lib = video_helper_lib,
        .video = video_module,
        .icons = icons_dep.module("icons"),
        .known_folders = known_folders,
        .git_version = git_version,
    };
    try wireCore(b, exe, exe.root_module, core);

    // Dev tool: probe a media file's streams/metadata/first-frame.
    const video_probe_exe = b.addExecutable(.{
        .name = "video_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_video.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    video_probe_exe.root_module.linkLibrary(video_helper_lib);
    video_probe_exe.root_module.addIncludePath(b.path("lib/video"));
    video_probe_exe.root_module.addImport("video", video_module);
    video_probe_exe.root_module.linkLibrary(vips_helper_lib);
    video_probe_exe.root_module.addIncludePath(b.path("lib/vips"));
    video_probe_exe.root_module.linkSystemLibrary("vips", .{});
    video_probe_exe.root_module.addImport("vips", vips_module);
    b.installArtifact(video_probe_exe);
    const run_video_probe = b.addRunArtifact(video_probe_exe);
    run_video_probe.step.dependOn(b.getInstallStep());
    run_video_probe.addPassthruArgs();
    const video_probe_step = b.step("video_probe", "Probe a media file via libav* (dimensions, metadata tags, first frame)");
    video_probe_step.dependOn(&run_video_probe.step);

    // Dev tool: batch throughput bench for the TensorPencil encoders
    const tp_batch_exe = b.addExecutable(.{
        .name = "test_tp_batch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_tp_batch.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    try addTensorPencil(b, tp_batch_exe, tp_batch_exe.root_module);
    const run_tp_batch = b.addRunArtifact(tp_batch_exe);
    run_tp_batch.addPassthruArgs();
    const tp_batch_step = b.step("test_tp_batch", "Bench TensorPencil single vs batch embed throughput (cpu/vulkan/cuda)");
    tp_batch_step.dependOn(&run_tp_batch.step);

    // Dev tool: retrieval-quality + speed A/B, current encoders vs EmbeddingGemma 2
    const bench_embed_exe = b.addExecutable(.{
        .name = "bench_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_embed.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bench_embed_exe.root_module.addImport("vips", vips_module);
    bench_embed_exe.root_module.linkLibrary(vips_helper_lib);
    try addTensorPencil(b, bench_embed_exe, bench_embed_exe.root_module);
    const run_bench_embed = b.addRunArtifact(bench_embed_exe);
    run_bench_embed.addPassthruArgs();
    const bench_embed_step = b.step("bench_embed", "A/B retrieval quality + speed: current encoders vs EmbeddingGemma 2");
    bench_embed_step.dependOn(&run_bench_embed.step);

    // Dev tool: time a full library scan into a throwaway DB
    const bench_scan_exe = b.addExecutable(.{
        .name = "bench_scan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_scan.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    try wireCore(b, bench_scan_exe, bench_scan_exe.root_module, core);
    const run_bench_scan = b.addRunArtifact(bench_scan_exe);
    run_bench_scan.addPassthruArgs();
    const bench_scan_step = b.step("bench_scan", "Time a full library scan (parse/hash/thumbnail, no embeddings) of a folder");
    bench_scan_step.dependOn(&run_bench_scan.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // *** Integration tests (headless dvui + in-memory SQLite) ***
    const dvui_testing_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
    });

    // Library module rooted at diffkeep.zig, wired with the headless backend.
    const diffkeep_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/diffkeep.zig"),
    });
    diffkeep_test_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));

    const integration_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/integration.zig"),
    });
    integration_module.addImport("diffkeep", diffkeep_test_module);
    integration_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));

    const integration_tests = b.addTest(.{
        .name = "diffkeep-integration-tests",
        .root_module = integration_module,
    });
    integration_tests.root_module.link_libcpp = true;
    try wireCore(b, integration_tests, diffkeep_test_module, core);

    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

/// The C libraries and Zig modules behind the app's own code (src/diffkeep.zig
/// and src/app.zig). dvui is not here: the app and the tests use different
/// backends.
const Core = struct {
    sqlite_lib: *std.Build.Step.Compile,
    sqlite: *std.Build.Module,
    vips_lib: *std.Build.Step.Compile,
    vips: *std.Build.Module,
    video_lib: *std.Build.Step.Compile,
    video: *std.Build.Module,
    icons: *std.Build.Module,
    known_folders: *std.Build.Module,
    git_version: std.Build.LazyPath,
};

/// Link `core`'s C libraries into `compile` and add its imports (plus
/// TensorPencil) to `import_mod`, the module rooted at the app's code
/// (`compile.root_module` for the app; the diffkeep library module for the
/// integration tests).
fn wireCore(b: *std.Build, compile: *std.Build.Step.Compile, import_mod: *std.Build.Module, core: Core) !void {
    const root = compile.root_module;
    root.linkLibrary(core.sqlite_lib);
    root.linkLibrary(core.vips_lib);
    root.linkLibrary(core.video_lib);
    for ([_]*std.Build.Module{ root, import_mod }) |m| {
        m.addIncludePath(b.path("lib/sqlite"));
        m.addIncludePath(b.path("lib/sqlite-vec"));
        m.addIncludePath(b.path("lib/vips"));
        m.addIncludePath(b.path("lib/video"));
    }
    import_mod.addImport("sqlite", core.sqlite);
    import_mod.addImport("vips", core.vips);
    import_mod.addImport("video", core.video);
    import_mod.addImport("icons", core.icons);
    import_mod.addImport("known-folders", core.known_folders);
    import_mod.addAnonymousImport("git_version", .{ .root_source_file = core.git_version });
    // TensorPencil: all embeddings (EmbeddingGemma text + SigLIP2 image/text).
    try addTensorPencil(b, compile, import_mod);
}

/// Add the TensorPencil native-Zig inference library. `import_mod` receives the
/// `TensorPencil` import (may differ from exe.root_module for the test build).
/// ggml is disabled: the embedding encoders compute in f32 (native Zig GEMM),
/// so ggml's block-quant kernels aren't needed and skipping them keeps the link
/// free of ggml's C library + libc++.
fn addTensorPencil(b: *std.Build, exe: anytype, import_mod: *std.Build.Module) !void {
    const target = exe.root_module.resolved_target.?;
    const optimize = exe.root_module.optimize.?;
    const tp_dep = b.dependency("TensorPencil", .{
        .target = target,
        .optimize = optimize,
        .ggml = false,
    });
    import_mod.addImport("TensorPencil", tp_dep.module("TensorPencil"));
}
