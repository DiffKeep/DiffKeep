const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const git_version = get_git_version(b.allocator, b.graph.io) catch "dev";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", git_version);

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
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("backend", dvui_dep.module("sdl3"));
    exe.root_module.addImport("known-folders", known_folders);

    const icons_dep = b.dependency("icons", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("icons", icons_dep.module("icons"));
    exe.root_module.link_libcpp = true;
    const os = target.result.os.tag;
    if (os == .linux) {
        exe.root_module.linkSystemLibrary("X11", .{});
        exe.root_module.linkSystemLibrary("Xcursor", .{});
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
                \\#include <X11/Xcursor/Xcursor.h>
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

    exe.root_module.linkLibrary(sqlite_lib);
    exe.root_module.addIncludePath(b.path("lib/sqlite"));
    exe.root_module.addIncludePath(b.path("lib/sqlite-vec"));

    const sqlite_module_zig = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .imports = &.{.{ .name = "sqlite_c", .module = sqlite_c.mod }},
    });

    exe.root_module.addImport("sqlite", sqlite_module_zig);

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

    exe.root_module.linkLibrary(vips_helper_lib);
    exe.root_module.addIncludePath(b.path("lib/vips"));
    exe.root_module.addImport("vips", vips_module);

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

    exe.root_module.linkLibrary(video_helper_lib);
    exe.root_module.addIncludePath(b.path("lib/video"));
    exe.root_module.addImport("video", video_module);

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

    // TensorPencil — all embeddings (EmbeddingGemma text + SigLIP2 image/text)
    try addTensorPencil(b, exe, exe.root_module);

    // Dev/research tools (not part of the GUI, useful for data pipeline work)

    const parse_threads_exe = b.addExecutable(.{
        .name = "test_parse_threads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_parse_all_in_dir_threads.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    try addLlama(b, parse_threads_exe);
    try addMtmd(b, parse_threads_exe);
    b.installArtifact(parse_threads_exe);
    const run_parse_threads = b.addRunArtifact(parse_threads_exe);
    run_parse_threads.step.dependOn(b.getInstallStep());
    run_parse_threads.addPassthruArgs();
    const parse_threads_step = b.step("parse_threads", "Concurrently parse PNG metadata across a directory tree");
    parse_threads_step.dependOn(&run_parse_threads.step);

    const test_embed_exe = b.addExecutable(.{
        .name = "test_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_embed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    try addLlama(b, test_embed_exe);
    b.installArtifact(test_embed_exe);
    const run_test_embed = b.addRunArtifact(test_embed_exe);
    run_test_embed.step.dependOn(b.getInstallStep());
    run_test_embed.addPassthruArgs();
    const test_embed_step = b.step("test_embed", "Test embedding generation with a GGUF model");
    test_embed_step.dependOn(&run_test_embed.step);

    const search_quality_exe = b.addExecutable(.{
        .name = "test_search_quality",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_search_quality.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    try addLlama(b, search_quality_exe);
    b.installArtifact(search_quality_exe);
    const run_search_quality = b.addRunArtifact(search_quality_exe);
    run_search_quality.step.dependOn(b.getInstallStep());
    run_search_quality.addPassthruArgs();
    const search_quality_step = b.step("test_search_quality", "Evaluate embedding search quality with short queries");
    search_quality_step.dependOn(&run_search_quality.step);

    const vl_embed_exe = b.addExecutable(.{
        .name = "test_vl_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_vl_embed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    try addLlama(b, vl_embed_exe);
    try addMtmd(b, vl_embed_exe);
    b.installArtifact(vl_embed_exe);
    const run_vl_embed = b.addRunArtifact(vl_embed_exe);
    run_vl_embed.step.dependOn(b.getInstallStep());
    run_vl_embed.addPassthruArgs();
    const vl_embed_step = b.step("test_vl_embed", "Test VL image embedding with Qwen3-VL");
    vl_embed_step.dependOn(&run_vl_embed.step);

    const cross_modal_exe = b.addExecutable(.{
        .name = "test_cross_modal_search",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_cross_modal_search.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    try addLlama(b, cross_modal_exe);
    try addMtmd(b, cross_modal_exe);
    b.installArtifact(cross_modal_exe);
    const run_cross_modal = b.addRunArtifact(cross_modal_exe);
    run_cross_modal.step.dependOn(b.getInstallStep());
    run_cross_modal.addPassthruArgs();
    const cross_modal_step = b.step("test_cross_modal", "Test text→image cross-modal search quality");
    cross_modal_step.dependOn(&run_cross_modal.step);

    const text_search_exe = b.addExecutable(.{
        .name = "test_text_search",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_text_search.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    try addLlama(b, text_search_exe);
    b.installArtifact(text_search_exe);
    const run_text_search = b.addRunArtifact(text_search_exe);
    run_text_search.step.dependOn(b.getInstallStep());
    run_text_search.addPassthruArgs();
    const text_search_step = b.step("test_text_search", "Test text retrieval quality across embedding models");
    text_search_step.dependOn(&run_text_search.step);

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
    diffkeep_test_module.addImport("sqlite", sqlite_module_zig);
    diffkeep_test_module.addImport("vips", vips_module);
    diffkeep_test_module.addIncludePath(b.path("lib/vips"));
    diffkeep_test_module.addImport("video", video_module);
    diffkeep_test_module.addIncludePath(b.path("lib/video"));
    diffkeep_test_module.addOptions("build_options", options);
    // icons is pure TVG data (no backend dependency); UI modules need it to compile.
    diffkeep_test_module.addImport("icons", icons_dep.module("icons"));

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
    integration_tests.root_module.linkLibrary(sqlite_lib);
    integration_tests.root_module.addIncludePath(b.path("lib/sqlite"));
    integration_tests.root_module.addIncludePath(b.path("lib/sqlite-vec"));
    integration_tests.root_module.linkLibrary(vips_helper_lib);
    integration_tests.root_module.addIncludePath(b.path("lib/vips"));
    integration_tests.root_module.linkSystemLibrary("vips", .{});
    integration_tests.root_module.linkLibrary(video_helper_lib);
    integration_tests.root_module.addIncludePath(b.path("lib/video"));
    for (av_libs) |lib| integration_tests.root_module.linkSystemLibrary(lib, .{});
    try addTensorPencil(b, integration_tests, diffkeep_test_module);

    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

fn addLlama(b: *std.Build, exe: anytype) !void {
    try addLlamaEx(b, exe, exe.root_module);
}

/// Like addLlama but adds the llama_cpp Zig import to `import_mod` instead of
/// exe.root_module. Used for the integration test build where the import must
/// land on diffkeep_test_module (not the test runner's root module).
fn addLlamaEx(b: *std.Build, exe: anytype, import_mod: *std.Build.Module) !void {
    const target = exe.root_module.resolved_target.?;
    const dep = b.dependency("llama_cpp", .{});

    const llama_cpp: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "llama_cpp",
        .c_source_file = dep.path("include/llama.h"),
        .target = target,
        .optimize = .fast,
    });

    llama_cpp.addIncludePath(dep.path("include"));
    llama_cpp.addIncludePath(dep.path("ggml/include"));

    const bin = b.dependency(b.fmt("llama_cpp_{s}", .{@tagName(target.result.os.tag)}), .{});
    const bin_path = bin.path(".");

    exe.root_module.addLibraryPath(bin_path);
    exe.root_module.linkSystemLibrary("llama", .{});
    exe.root_module.linkSystemLibrary("ggml", .{});

    const libs_to_install = [_][]const u8{
        "libllama.so",
        "libggml.so",
        "libggml-base.so",
        "libggml-cpu-x64.so",
        "libggml-rpc.so",
        "libllama-common.so",
    };
    inline for (libs_to_install) |lib| {
        const step = b.addInstallBinFile(bin_path.path(b, lib), lib);
        b.getInstallStep().dependOn(&step.step);
    }

    const os = target.result.os.tag;
    if (os == .linux) {
        const gpu_plugins = .{
            .{ "llama_cpp_linux_vulkan", "libggml-vulkan.so" },
            .{ "llama_cpp_linux_rocm",   "libggml-hip.so"   },
            .{ "llama_cpp_linux_sycl",   "libggml-sycl.so"  },
        };
        inline for (gpu_plugins) |plugin| {
            const pkg_name = plugin[0];
            const so_name  = plugin[1];
            if (b.lazyDependency(pkg_name, .{})) |gpu_dep| {
                const step = b.addInstallBinFile(gpu_dep.path(".").path(b, so_name), so_name);
                b.getInstallStep().dependOn(&step.step);
            }
        }
    }

    import_mod.addImport("llama_cpp", llama_cpp.mod);
}

fn addMtmd(b: *std.Build, exe: anytype) !void {
    const target = exe.root_module.resolved_target.?;
    const bin = b.dependency(b.fmt("llama_cpp_{s}", .{@tagName(target.result.os.tag)}), .{});
    const bin_path = bin.path(".");

    const mtmd_wrapper_mod = b.createModule(.{
        .target = target,
        .optimize = .fast,
        .link_libc = true,
        .link_libcpp = true,
    });
    mtmd_wrapper_mod.addCSourceFile(.{
        .file = b.path("lib/mtmd/mtmd_wrapper.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions" },
    });
    mtmd_wrapper_mod.addCSourceFile(.{
        .file = b.path("lib/mtmd/reranker_wrapper.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions" },
    });
    mtmd_wrapper_mod.addIncludePath(b.path("lib/mtmd"));

    const mtmd_lib = b.addLibrary(.{
        .name = "mtmd_wrapper",
        .root_module = mtmd_wrapper_mod,
    });

    exe.root_module.linkLibrary(mtmd_lib);
    exe.root_module.addIncludePath(b.path("lib/mtmd"));
    exe.root_module.addLibraryPath(bin_path);
    exe.root_module.linkSystemLibrary("mtmd", .{});

    const step = b.addInstallBinFile(bin_path.path(b, "libmtmd.so"), "libmtmd.so");
    b.getInstallStep().dependOn(&step.step);

    const mtmd_zig = b.createModule(.{
        .root_source_file = b.path("src/mtmd.zig"),
    });
    exe.root_module.addImport("mtmd", mtmd_zig);
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

fn get_git_version(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const version_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "describe", "--tags", "--always" } });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);

    if (version_result.stdout.len == 0) return error.GitDescribeFailed;

    const status_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "status", "--porcelain" } });
    defer allocator.free(status_result.stdout);
    defer allocator.free(status_result.stderr);

    const trimmed_version = std.mem.trimEnd(u8, version_result.stdout, "\n");

    if (status_result.stdout.len > 0) {
        return try allocator.print("{s}(DIRTY)", .{trimmed_version});
    }
    return try allocator.dupe(u8, trimmed_version);
}
