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
        .name = "stablekeepr",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
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
