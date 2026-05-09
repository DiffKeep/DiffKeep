const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Get git version or commit hash
    const git_version = get_git_version(b.allocator, b.graph.io) catch "dev";

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for build options
    const options = b.addOptions();
    options.addOption([]const u8, "version", git_version);

    const exe = b.addExecutable(.{
        .name = "DiffKeep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });

    // Add the options module
    exe.root_module.addOptions("build_options", options);

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("clap", clap.module("clap"));

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");
    exe.root_module.addImport("known-folders", known_folders);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // *** GUI (dvui + SDL3) ***
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const gui_exe = b.addExecutable(.{
        .name = "DiffKeep-gui",
        .root_module = b.addModule("DiffKeepApp", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/app.zig"),
        }),
    });
    gui_exe.root_module.strip = optimize != .Debug;
    gui_exe.root_module.addOptions("build_options", options);
    gui_exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    gui_exe.root_module.addImport("backend", dvui_dep.module("sdl3"));
    gui_exe.root_module.link_libcpp = true;

    const gui_install = b.addInstallArtifact(gui_exe, .{});
    const gui_step = b.step("gui", "Build the GUI");
    gui_step.dependOn(&gui_install.step);

    const run_gui_cmd = b.addRunArtifact(gui_exe);
    run_gui_cmd.step.dependOn(&gui_install.step);
    if (b.args) |args| run_gui_cmd.addArgs(args);
    const run_gui_step = b.step("run-gui", "Run the GUI");
    run_gui_step.dependOn(&run_gui_cmd.step);

    // *** sqlite ***
    // Create a module for the SQLite C sources
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

    // Link SQLite with our executable
    exe.root_module.linkLibrary(sqlite_lib);
    exe.root_module.addIncludePath(b.path("lib/sqlite"));
    exe.root_module.addIncludePath(b.path("lib/sqlite-vec"));

    const sqlite_module_zig = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
    });
    sqlite_module_zig.addIncludePath(b.path("lib/sqlite"));
    sqlite_module_zig.addIncludePath(b.path("lib/sqlite-vec"));

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
    });
    vips_module.addIncludePath(b.path("lib/vips"));

    exe.root_module.linkLibrary(vips_helper_lib);
    exe.root_module.addImport("vips", vips_module);

    // llamacpp
    try addLlama(b, exe);

    const test_full_directory_exe = b.addExecutable(.{
        .name = "test_full_directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_parse_all_in_dir.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_test_full_directory = b.addRunArtifact(test_full_directory_exe);
    if (b.args) |args| {
        run_test_full_directory.addArgs(args);
    }

    const test_full_directory_step = b.step("test_full_directory", "Run the parser on all files in directory");
    test_full_directory_step.dependOn(&run_test_full_directory.step);

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
    if (b.args) |args| run_parse_threads.addArgs(args);
    const parse_threads_step = b.step("parse_threads", "Concurrently parse PNG metadata across a directory tree");
    parse_threads_step.dependOn(&run_parse_threads.step);

    const get_workflow_exe = b.addExecutable(.{
        .name = "get_workflow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/get_workflow_chunk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const get_workflow = b.addRunArtifact(get_workflow_exe);
    if (b.args) |args| {
        get_workflow.addArgs(args);
    }

    const get_workflow_step = b.step("get_workflow", "Get the workflow chunk from a single PNG file");
    get_workflow_step.dependOn(&get_workflow.step);

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
    if (b.args) |args| {
        run_test_embed.addArgs(args);
    }
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
    if (b.args) |args| run_search_quality.addArgs(args);
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
    if (b.args) |args| run_vl_embed.addArgs(args);
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
    if (b.args) |args| run_cross_modal.addArgs(args);
    const cross_modal_step = b.step("test_cross_modal", "Test text→image cross-modal search quality");
    cross_modal_step.dependOn(&run_cross_modal.step);

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
}

fn addLlama(b: *std.Build, exe: anytype) !void {
    const target = exe.root_module.resolved_target.?;
    const dep = b.dependency("llama_cpp", .{});

    const llama_cpp = b.addTranslateC(.{
        .root_source_file = dep.path("include/llama.h"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    llama_cpp.addIncludePath(dep.path("include"));
    llama_cpp.addIncludePath(dep.path("ggml/include"));

    const bin = b.dependency(b.fmt("llama_cpp_{s}", .{@tagName(target.result.os.tag)}), .{});
    // b9048+ tarballs unpack to a flat directory (zig strips the llama-bNNNN/ prefix)
    const bin_path = bin.path(".");

    exe.root_module.addLibraryPath(bin_path);
    exe.root_module.linkSystemLibrary("llama", .{});
    exe.root_module.linkSystemLibrary("ggml", .{});

    // Copy shared libraries to the output directory.
    // libggml-cpu-x64.so is the generic CPU backend; the arch-specific variants
    // (alderlake, cannonlake, etc.) are dlopen'd at runtime for dispatch — install
    // them all so the runtime can pick the best one.
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

    // Install GPU backend plugins. ggml loads these at runtime via dlopen and
    // calls ggml_backend_score() on each to pick the best available backend.
    // Plugins whose runtime dependencies are missing (no CUDA driver, no Vulkan
    // loader, no ROCm) are silently skipped — CPU fallback always works.
    const os = target.result.os.tag;
    if (os == .linux) {
        const gpu_plugins = .{
            .{ "llama_cpp_linux_vulkan", "libggml-vulkan.so" }, // NVIDIA + AMD + Intel
            .{ "llama_cpp_linux_rocm",   "libggml-hip.so"    }, // AMD via ROCm
            .{ "llama_cpp_linux_sycl",   "libggml-sycl.so"   }, // Intel Arc via oneAPI
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

    exe.root_module.addImport("llama_cpp", llama_cpp.createModule());
}

fn addMtmd(b: *std.Build, exe: anytype) !void {
    const target = exe.root_module.resolved_target.?;
    const bin = b.dependency(b.fmt("llama_cpp_{s}", .{@tagName(target.result.os.tag)}), .{});
    const bin_path = bin.path(".");

    const mtmd_wrapper_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
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

    // Install libmtmd.so alongside the binary.
    const step = b.addInstallBinFile(bin_path.path(b, "libmtmd.so"), "libmtmd.so");
    b.getInstallStep().dependOn(&step.step);

    const mtmd_zig = b.addModule("mtmd", .{
        .root_source_file = b.path("src/mtmd.zig"),
    });
    exe.root_module.addImport("mtmd", mtmd_zig);
}

// Get git version or commit hash, and append (DIRTY) if the working tree is not clean
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
        return try std.fmt.allocPrint(allocator, "{s}(DIRTY)", .{trimmed_version});
    }
    return try allocator.dupe(u8, trimmed_version);
}
