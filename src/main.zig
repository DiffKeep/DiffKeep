const std = @import("std");
const flags = @import("flags");

const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    const options = flags.parseOrExit(&args, "stablekeepr", Flags, .{
        // Use the `colors` option to provide a colorscheme for the error/help messages.
        // Specifying this as empty: `.colors = .{}` will disable colors.
        // Each field is a list of type `std.io.tty.Color`.
        .colors = .{
            .error_label = &.{ .bright_red, .bold },
            .command_name = &.{.bright_green},
            .header = &.{ .yellow, .bold },
            .usage = &.{.dim},
        },
    });

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    if (options.version == true) {
        try stdout.print("{s}.\n", .{build_options.version});
        try bw.flush(); // don't forget to flush!
        return;
    }

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

const Flags = struct {
    pub const description =
    \\StableKeepr runtime arguments help.
    ;

    // Optional description of some or all of the flags (must match field names in the struct).
    pub const descriptions = .{
        .version = "Print build version and exit.",
    };

    version: bool,

    // Optional declaration to define shorthands. These can be chained e.g '-fs large'.
    pub const switches = .{
        .version = 'v',
    };
};

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
