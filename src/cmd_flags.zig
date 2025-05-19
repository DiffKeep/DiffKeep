pub const Flags = struct {
    pub const description =
    \\DiffKeep runtime arguments help.
    ;

    // Optional description of some or all of the flags (must match field names in the struct).
    pub const descriptions = .{
        .version = "Print build version and exit.",
        .parse_file = "Path to the file to parse.",
        .model_path = "Path to the model to use for generating embeddings (must product 768 vectors).",
        .search_similar = "Search term to do a search across the image database.",
        .data_path = "Optional path to the data directory. Defaults to platform's user data directory with a DiffKeep subdirectory.",
    };

    parse_file: ?[]const u8,
    version: bool,
    model_path: ?[]const u8 = null,
    search_similar: ?[]const u8 = null,
    data_path: ?[]const u8 = null,

    // Optional declaration to define shorthands. These can be chained e.g '-fs large'.
    pub const switches = .{
        .version = 'v',
        .parse_file = 'f',
        .model_path = 'm',
        .search_similar = 's',
        .data_path = 'd',
    };
};