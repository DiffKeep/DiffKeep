const std = @import("std");
const flags = @import("flags");
const zigimg = @import("zigimg");
const importInfo = @import("image/png-data.zig");

const build_options = @import("build_options");

const log = if (@import("builtin").target.os.tag == .windows)
    struct {
        pub fn output(comptime fmt: []const u8, args: anytype) !void {
            // On Windows GUI, write to a log file instead
            const log_file = try std.fs.cwd().createFile("debug.log", .{});
            defer log_file.close();
            try log_file.writer().print(fmt, args);
        }
        pub fn log(comptime fmt: []const u8, args: anytype) !void {
            return .output(fmt, args);
        }
    }
else
    struct {
        pub fn output(comptime fmt: []const u8, args: anytype) !void {
            // output to stdout
            try std.io.getStdOut().writer().print(fmt, args);
        }
        pub fn log(comptime fmt: []const u8, args: anytype) !void {
            // output to stderr
            try std.io.getStdErr().writer().print(fmt, args);
        }
    };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const options = flags.parseOrExit(args, "stablekeepr", Flags, .{
        // Use the `colors` option to provide a colorscheme for the error/help messages.
        // Specifying this as empty: `.colors = .{}` will disable colors.
        // Each field is a list of type `std.io.tty.Color`.
        .colors = &.{
            .error_label = &.{ .bright_red, .bold },
            .command_name = &.{.bright_green},
            .header = &.{ .yellow, .bold },
            .usage = &.{.dim},
        },
    });

    if (options.version == true) {
        try log.output("Version: {s}\n", .{build_options.version});
        return;
    }

    try log.log("Parsing file: {s}\n", .{options.parse_file});
    const file = try std.fs.cwd().openFile(options.parse_file, .{});
    defer file.close();

    var info_buffer: [16384 * 128]u8 = undefined;
    var info_stream = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(info_buffer[0..]) };

    var infoOptions = importInfo.PngInfoOptions{
        .processor = importInfo.init(info_stream.writer(), gpa.allocator()),
    };
    defer importInfo.deinit(&infoOptions.processor);
    var stream = zigimg.Image.Stream{ .file = file };
    var result = try zigimg.formats.png.load(&stream, gpa.allocator(), infoOptions.get());
    defer result.deinit(gpa.allocator());

    if (infoOptions.processor.prompt) |prompt| {
        try log.output("Prompt: {s}\n", .{prompt});
    } else {
        try log.output("No prompt found in image\n", .{});
    }
    if (infoOptions.processor.workflow) |workflow| {
        try log.output("Workflow: {s}\n", .{workflow});
    } else {
        try log.output("No workflow found in image\n", .{});
    }

}

const Flags = struct {
    pub const description =
    \\DiffKeep runtime arguments help.
    ;

    // Optional description of some or all of the flags (must match field names in the struct).
    pub const descriptions = .{
        .version = "Print build version and exit.",
        .parse_file = "Path to the file to parse.",
    };

    parse_file: []const u8,
    version: bool,

    // Optional declaration to define shorthands. These can be chained e.g '-fs large'.
    pub const switches = .{
        .version = 'v',
        .parse_file = 'f',
    };
};
