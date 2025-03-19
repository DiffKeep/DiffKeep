const std = @import("std");
const flags = @import("flags");
const db = @import("db.zig");

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
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

    if (options.parse_file != null) {
        try log.log("Parsing file: {s}\n", .{options.parse_file orelse ""});
        const file = try std.fs.cwd().openFile(options.parse_file orelse "", .{});
        defer file.close();
    }

    // Initialize the vector database
    var vector_db = try db.VectorDb.init(allocator, "diffkeep.db");
    defer vector_db.deinit();

    // Example: Store an image embedding
    const example_embedding = [_]f32{0.1, 0.2, 0.3} ++ [_]f32{0.0} ** 509;
    try vector_db.storeImageEmbedding(1, &example_embedding);

    // Example: Find similar images
    const query_embedding = [_]f32{0.11, 0.19, 0.31} ++ [_]f32{0.0} ** 509;
    var results = try vector_db.findSimilarImages(&query_embedding, 10);
    defer results.deinit();

    // Print results
    std.debug.print("Found {} similar images\n", .{results.items.len});
    for (results.items) |result| {
        std.debug.print("Image ID: {}, Distance: {d:.6}\n", .{result.id, result.distance});
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

    parse_file: ?[]const u8,
    version: bool,

    // Optional declaration to define shorthands. These can be chained e.g '-fs large'.
    pub const switches = .{
        .version = 'v',
        .parse_file = 'f',
    };
};
