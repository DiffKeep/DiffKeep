const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;
    // A release build carries its own libvips and FFmpeg (see `Pinned`): a
    // Windows build always, a Linux one when asked.
    const bundle_libs = is_windows or (b.option(bool, "bundle-libs", "Linux: link the pinned libvips and FFmpeg packages and install them beside the executable, instead of the system's (a release build)") orelse false);

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
        // A cross build doesn't search the system's libraries either. X11, Xi and
        // wayland-client are on every desktop the release runs on; link against
        // the build machine's (CI installs their -dev packages).
        if (!target.query.isNative()) exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        exe.root_module.linkSystemLibrary("X11", .{});
        exe.root_module.linkSystemLibrary("Xi", .{});
        exe.root_module.linkSystemLibrary("wayland-client", .{});
    } else if (os == .windows) {
        exe.root_module.linkSystemLibrary("ole32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("uuid", .{});
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/icons/diffkeep.rc") });
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
    // The licenses travel with the binary: About names the third-party file.
    b.installFile("LICENSE", "bin/LICENSE");
    b.installFile("THIRD_PARTY_LICENSES.txt", "bin/THIRD_PARTY_LICENSES.txt");

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
    // Platform header translations the app imports (also used by `check`).
    var os_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    // A cross build (a release asks for an older glibc) doesn't search the
    // system's headers: take X11's and Wayland's from SDL's header package.
    const linux_headers: ?std.Build.LazyPath = if (os == .linux and !target.query.isNative())
        (try b.dependencyLazy("sdl_linux_deps", .{})).path("include")
    else
        null;
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
        if (linux_headers) |h| {
            x11_c.addIncludePath(h);
            wayland_c.addIncludePath(h);
        }
        try os_imports.append(b.allocator, .{ .name = "x11_c", .module = x11_c.mod });
        try os_imports.append(b.allocator, .{ .name = "wayland_c", .module = wayland_c.mod });
    }
    for (os_imports.items) |imp| exe.root_module.addImport(imp.name, imp.module);

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
            // On macOS _POSIX_C_SOURCE hides the BSD types (u_int, ...) that
            // sqlite's Darwin code needs through <sys/sysctl.h>; there the
            // full API is the default.
            if (os.isDarwin()) "-D_DARWIN_C_SOURCE" else "-D_POSIX_C_SOURCE=200809L",
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
    const vips_pinned = if (is_windows) try Pinned.link(b, vips_helper_mod, &.{.{
        .dep = "vips_win",
        .includes = &.{ "include", "include/glib-2.0", "lib/glib-2.0/include" },
        .libs = &.{ "lib/libvips.lib", "lib/libgio-2.0.lib", "lib/libgobject-2.0.lib", "lib/libglib-2.0.lib" },
        .dll_dir = "bin",
        .licenses = &.{ "LICENSE", "versions.json" },
    }}) else if (bundle_libs) try Pinned.link(b, vips_helper_mod, &.{
        .{
            .dep = "vips_linux_dev",
            .includes = &.{ "include", "include/glib-2.0" },
        },
        .{
            .dep = "vips_linux",
            .includes = &.{"lib/glib-2.0/include"},
            // One library: sharp's build folds libvips' dependencies and glib into it.
            .shared = &.{"lib/libvips-cpp.so.8.18.7"},
            .licenses = &.{ "README.md", "versions.json" },
        },
    }) else blk: {
        vips_helper_mod.linkSystemLibrary("vips", .{});
        break :blk null;
    };
    if (vips_pinned) |l| l.installWith(b.getInstallStep());

    const vips_helper_lib = b.addLibrary(.{
        .name = "vips_helper",
        .root_module = vips_helper_mod,
    });

    const vips_module = b.addModule("vips", .{
        .root_source_file = b.path("src/vips.zig"),
        .imports = &.{.{ .name = "vips_c", .module = vips_c.mod }},
    });

    // *** video (libav*) ***
    // Linked like vips: the system's through pkg-config, or the pinned build.
    // The C wrapper itself is fully portable.
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
    const av_pinned = if (is_windows) try Pinned.link(b, video_helper_mod, &.{.{
        .dep = "ffmpeg_win",
        .includes = &.{"include"},
        .libs = &.{ "lib/avformat.lib", "lib/avcodec.lib", "lib/avutil.lib", "lib/swscale.lib", "lib/swresample.lib" },
        .dll_dir = "bin",
        .licenses = &.{"LICENSE.txt"},
    }}) else if (bundle_libs) try Pinned.link(b, video_helper_mod, &.{.{
        .dep = "ffmpeg_linux",
        .includes = &.{"include"},
        .shared = &.{ "lib/libavformat.so.62", "lib/libavcodec.so.62", "lib/libavutil.so.60", "lib/libswscale.so.9", "lib/libswresample.so.6" },
        .licenses = &.{"LICENSE.txt"},
    }}) else blk: {
        for (av_libs) |lib| video_helper_mod.linkSystemLibrary(lib, .{});
        break :blk null;
    };
    if (av_pinned) |l| l.installWith(b.getInstallStep());

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
        .pinned = .{ vips_pinned, av_pinned },
    };
    try wireCore(b, exe, exe.root_module, core);

    // *** check: compile the app's Zig code for -Dtarget, no binary ***
    // Links none of the C libraries (libvips, libav*, sqlite, the drag
    // helpers), so other platforms' code can be checked from Linux without
    // their builds of those libraries: `zig build check -Dtarget=x86_64-windows-gnu`.
    const check_exe = b.addExecutable(.{
        .name = "DiffKeep-check",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/app.zig"),
        }),
    });
    check_exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    check_exe.root_module.addImport("backend", dvui_dep.module("sdl3"));
    for (os_imports.items) |imp| check_exe.root_module.addImport(imp.name, imp.module);
    try wireImports(b, check_exe, check_exe.root_module, core);
    const check_step = b.step("check", "Compile the app's Zig code for -Dtarget without building a binary or linking C libraries");
    check_step.dependOn(&check_exe.step);

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
    video_probe_exe.root_module.addImport("vips", vips_module);
    core.linkPinned(video_probe_exe.root_module);
    b.installArtifact(video_probe_exe);
    const run_video_probe = core.runPinned(b, b.addRunArtifact(video_probe_exe));
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
    // The embedder decodes a video's first frame for its image embedding.
    bench_embed_exe.root_module.addImport("video", video_module);
    bench_embed_exe.root_module.linkLibrary(video_helper_lib);
    core.linkPinned(bench_embed_exe.root_module);
    try addTensorPencil(b, bench_embed_exe, bench_embed_exe.root_module);
    const run_bench_embed = core.runPinned(b, b.addRunArtifact(bench_embed_exe));
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
    const run_bench_scan = core.runPinned(b, b.addRunArtifact(bench_scan_exe));
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

    test_step.dependOn(&core.runPinned(b, b.addRunArtifact(integration_tests)).step);

    // *** check-lib: `check` without SDL ***
    // The integration tests' build, compiled with no binary and no C
    // libraries linked: everything but app.zig's SDL layer, against dvui's
    // headless backend. For targets whose SDL needs an SDK this machine
    // lacks (macOS): `zig build check-lib -Dtarget=aarch64-macos`.
    // Own modules: the integration tests' have the C libraries linked in.
    const check_lib_dk = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/diffkeep.zig"),
    });
    check_lib_dk.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    const check_lib = b.addTest(.{
        .name = "diffkeep-check-lib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/integration.zig"),
        }),
    });
    check_lib.root_module.addImport("diffkeep", check_lib_dk);
    check_lib.root_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    try wireImports(b, check_lib, check_lib_dk, core);
    const check_lib_step = b.step("check-lib", "Like check, minus the SDL layer (app.zig): for targets whose SDL can't be built here");
    check_lib_step.dependOn(&check_lib.step);
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
    /// The pinned libvips and FFmpeg, when the build bundles them (null: the
    /// system's, which the shim libraries carry on themselves).
    pinned: [2]?Pinned.Linked,

    /// Link the pinned libraries, if any, into a binary that links the shims.
    fn linkPinned(core: Core, module: *std.Build.Module) void {
        for (core.pinned) |p| if (p) |l| l.linkInto(module);
    }

    /// A run of a binary from the cache: let it find the pinned libraries.
    fn runPinned(core: Core, b: *std.Build, run: *std.Build.Step.Run) *std.Build.Step.Run {
        const windows = run.producer != null and run.producer.?.rootModuleTarget().os.tag == .windows;
        for (core.pinned) |p| if (p) |l| l.findFrom(b, run, windows);
        return run;
    }
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
    core.linkPinned(root);
    try wireImports(b, compile, import_mod, core);
}

/// `wireCore` without linking the C libraries: enough to compile the Zig code
/// (the `check` step), not to link a binary.
fn wireImports(b: *std.Build, compile: *std.Build.Step.Compile, import_mod: *std.Build.Module, core: Core) !void {
    const root = compile.root_module;
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

/// A prebuilt library package (`build.zig.zon`) standing in for pkg-config: what a
/// Windows build always links, and a Linux one under -Dbundle-libs, so a release
/// carries its own libvips and FFmpeg. The same helper as TensorPencil's build.zig.
const Pinned = struct {
    dep: []const u8,
    includes: []const []const u8 = &.{},
    /// Import libs, linked by exact path: Zig's `-l` search does not try
    /// every naming scheme these packages use (`libvips.lib`).
    libs: []const []const u8 = &.{},
    /// A directory whose DLLs install beside the executable (Windows).
    dll_dir: ?[]const u8 = null,
    /// Shared libraries, each linked by path and installed beside the executable
    /// under its own name (its soname), which it finds through `$ORIGIN`.
    shared: []const []const u8 = &.{},
    /// Installed to `share/licenses/<dep>/`: the libraries ship with their terms.
    licenses: []const []const u8 = &.{},

    const Linked = struct {
        /// Install the libraries beside the executable, and their licenses.
        installs: []const *std.Build.Step,
        /// The import libs and shared libraries, for `linkInto`.
        objects: []const std.Build.LazyPath,
        /// Shared libraries are found beside the executable (`$ORIGIN`).
        rpath_origin: bool,
        /// Where the libraries are, for a run of a binary that is not installed
        /// (a dev tool or test run from the cache).
        dir: ?[]const u8,

        fn installWith(self: Linked, step: *std.Build.Step) void {
            for (self.installs) |s| step.dependOn(s);
        }

        /// Link the libraries into an executable's (or test's) root module. The
        /// C shims are static libraries, which don't carry these on to what
        /// links them, so every binary that links a shim takes them itself.
        fn linkInto(self: Linked, module: *std.Build.Module) void {
            for (self.objects) |o| module.addObjectFile(o);
            if (self.rpath_origin) module.addRPathSpecial("$ORIGIN");
        }

        /// Let `run` (of a binary in the cache) find the libraries.
        fn findFrom(self: Linked, b: *std.Build, run: *std.Build.Step.Run, windows: bool) void {
            const dir = self.dir orelse return;
            const name = if (windows) "PATH" else "LD_LIBRARY_PATH";
            const sep = if (windows) ";" else ":";
            const prev = run.getEnvMap().get(name) orelse b.graph.environ_map.get(name) orelse "";
            run.setEnvironmentVariable(name, if (prev.len == 0) dir else b.fmt("{s}{s}{s}", .{ dir, sep, prev }));
        }
    };

    /// Points `module` (the C shim's) at every package's headers, and returns
    /// the libraries for the binaries that link it (`Linked.linkInto`).
    fn link(b: *std.Build, module: *std.Build.Module, pkgs: []const Pinned) !Linked {
        var installs: std.ArrayList(*std.Build.Step) = .empty;
        var objects: std.ArrayList(std.Build.LazyPath) = .empty;
        var shared = false;
        var dir: ?[]const u8 = null;
        for (pkgs) |pkg| {
            // A missing package returns `build` here; the runner fetches it and reruns.
            const d = try b.dependencyLazy(pkg.dep, .{});
            for (pkg.includes) |p| module.addIncludePath(d.path(p));
            for (pkg.libs) |p| try objects.append(b.allocator, d.path(p));
            if (pkg.dll_dir) |sub| {
                // Recursive, so vips' loader modules keep the subdirectory it looks in.
                const dlls = b.addInstallDirectory(.{
                    .source_dir = d.path(sub),
                    .install_dir = .bin,
                    .install_subdir = "",
                    .include_extensions = &.{".dll"},
                });
                try installs.append(b.allocator, &dlls.step);
                dir = try d.builder.root.joinString(b.allocator, sub);
            }
            for (pkg.shared) |p| {
                shared = true;
                try objects.append(b.allocator, d.path(p));
                try installs.append(b.allocator, &b.addInstallBinFile(d.path(p), std.Io.Dir.path.basename(p)).step);
                dir = try d.builder.root.joinString(b.allocator, std.Io.Dir.path.dirname(p).?);
            }
            for (pkg.licenses) |p| {
                try installs.append(b.allocator, &b.addInstallFile(d.path(p), b.fmt("share/licenses/{s}/{s}", .{ pkg.dep, std.Io.Dir.path.basename(p) })).step);
            }
        }
        return .{ .installs = installs.items, .objects = objects.items, .rpath_origin = shared, .dir = dir };
    }
};
