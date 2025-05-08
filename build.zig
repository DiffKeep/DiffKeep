const std = @import("std");
const process = std.process;
const ChildProcess = std.process.Child;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Get git version or commit hash
    const git_version = get_git_version(b.allocator) catch "dev";

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
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    // Add the options module
    exe.root_module.addOptions("build_options", options);

    const flags = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("flags", flags.module("flags"));

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

    // *** sqlite ***
    // Add SQLite as a module
    const sqlite_module = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = target,
        .optimize = optimize,
    });

    // Add SQLite source file
    sqlite_module.addCSourceFile(.{
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

    // Add vector search extension
    sqlite_module.addCSourceFile(.{
        .file = b.path("lib/sqlite-vec/sqlite-vec.c"),
        .flags = &[_][]const u8{
            "-std=gnu99",
            "-D_GNU_SOURCE",
            "-DSQLITE_CORE",
            "-DSQLITE_EXTENSION_INIT1=",
        },
    });

    // Link with math library
    sqlite_module.linkLibC();
    sqlite_module.linkSystemLibrary("m");
    sqlite_module.addIncludePath(b.path("lib/sqlite"));
    sqlite_module.addIncludePath(b.path("lib/sqlite-vec"));

    // Link SQLite with our executable
    exe.linkLibrary(sqlite_module);

    // Add include directories
    exe.addIncludePath(b.path("lib/sqlite"));
    exe.addIncludePath(b.path("lib/sqlite-vec"));

    const sqlite_module_zig = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
    });
    sqlite_module_zig.addIncludePath(b.path("lib/sqlite"));
    sqlite_module_zig.addIncludePath(b.path("lib/sqlite-vec"));

    exe.root_module.addImport("sqlite", sqlite_module_zig);

    // llamacpp
    try addLlama(b, exe);

    const test_full_directory_exe = b.addExecutable(.{
        .name = "test_full_directory",
        .root_source_file = b.path("src/test_parse_all_in_dir.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test_full_directory = b.addRunArtifact(test_full_directory_exe);
    if (b.args) |args| {
        run_test_full_directory.addArgs(args);
    }

    const test_full_directory_step = b.step("test_full_directory", "Run the parser on all files in directory");
    test_full_directory_step.dependOn(&run_test_full_directory.step);

    const get_workflow_exe = b.addExecutable(.{
        .name = "get_workflow",
        .root_source_file = b.path("src/get_workflow_chunk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const get_workflow = b.addRunArtifact(get_workflow_exe);
    if (b.args) |args| {
        get_workflow.addArgs(args);
    }

    const get_workflow_step = b.step("get_workflow", "Get the workflow chunk from a single PNG file");
    get_workflow_step.dependOn(&get_workflow.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    exe_unit_tests.root_module.addImport("sqlite", sqlite_module_zig);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
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
    const bin_path = bin.path(switch (target.result.os.tag) {
        .windows => ".",
        else => "bin",
    });

    exe.addLibraryPath(bin_path);
    exe.linkSystemLibrary("llama");

    // Copy the shared libraries to the output directory
    const install_llama_lib = b.addInstallBinFile(
        bin_path.path(b, "libllama.so"),
        "libllama.so"
    );
    const install_ggml_lib = b.addInstallBinFile(
        bin_path.path(b, "libggml.so"),
        "libggml.so"
    );
    const install_ggml_base_lib = b.addInstallBinFile(
        bin_path.path(b, "libggml-base.so"),
        "libggml-base.so"
    );
    const install_ggml_cpu_lib = b.addInstallBinFile(
        bin_path.path(b, "libggml-cpu.so"),
        "libggml-cpu.so"
    );
    const install_ggml_rpc_lib = b.addInstallBinFile(
        bin_path.path(b, "libggml-rpc.so"),
        "libggml-rpc.so"
    );

    b.getInstallStep().dependOn(&install_llama_lib.step);
    b.getInstallStep().dependOn(&install_ggml_lib.step);
    b.getInstallStep().dependOn(&install_ggml_base_lib.step);
    b.getInstallStep().dependOn(&install_ggml_cpu_lib.step);
    b.getInstallStep().dependOn(&install_ggml_rpc_lib.step);

    exe.root_module.addImport("llama_cpp", llama_cpp.createModule());
}

// Get git version or commit hash, and append (DIRTY) if the working tree is not clean
fn get_git_version(allocator: std.mem.Allocator) ![]const u8 {
    // Get version/hash
    var child = ChildProcess.init(&.{ "git", "describe", "--tags", "--always",}, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const version = try child.stdout.?.reader().readAllAlloc(allocator, 1024);
    _ = try child.wait();

    // If version is empty, return error
    if (version.len == 0) {
        return error.GitDescribeFailed;
    }

    // Check if working tree is dirty
    var status_child = ChildProcess.init(&.{ "git", "status", "--porcelain" }, allocator);
    status_child.stdout_behavior = .Pipe;
    status_child.stderr_behavior = .Pipe;
    try status_child.spawn();
    const status = try status_child.stdout.?.reader().readAllAlloc(allocator, 1024);
    _ = try status_child.wait();

    const trimmed_version = std.mem.trimRight(u8, version, "\n");

    // If status has any output, working tree is dirty
    if (status.len > 0) {
        const dirty_version = try std.fmt.allocPrint(allocator, "{s}(DIRTY)", .{trimmed_version});
        return dirty_version;
    }

    return trimmed_version;
}
