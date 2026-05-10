const std = @import("std");

// All strings are sentinel-terminated so they work with both dvui labels ([]const u8)
// and APIs that require [:0]const u8 (e.g. window title, file dialogs).
pub const Strings = struct {
    window_title: [:0]const u8,

    nav_library: [:0]const u8,
    nav_search: [:0]const u8,
    nav_settings: [:0]const u8,

    library_empty: [:0]const u8,
    library_scan: [:0]const u8,
    library_scanning: [:0]const u8,

    search_placeholder: [:0]const u8,
    search_no_results: [:0]const u8,

    detail_prompt: [:0]const u8,
    detail_model: [:0]const u8,
    detail_sampler: [:0]const u8,
    detail_steps: [:0]const u8,
    detail_size: [:0]const u8,
    detail_seed: [:0]const u8,

    settings_config_dir: [:0]const u8,
    settings_model_path: [:0]const u8,
};

pub const en: Strings = .{
    .nav_library = "Library",
    .nav_search = "Search",
    .nav_settings = "Settings",

    .library_empty = "No images found. Add a folder to get started.",
    .library_scan = "Scan folder\u{2026}",
    .library_scanning = "Scanning\u{2026}",

    .search_placeholder = "Search prompts\u{2026}",
    .search_no_results = "No results.",

    .detail_prompt = "Prompt",
    .detail_model = "Model",
    .detail_sampler = "Sampler",
    .detail_steps = "Steps",
    .detail_size = "Size",
    .detail_seed = "Seed",

    .settings_config_dir = "Config directory",
    .settings_model_path = "Embedding model",
};

pub var active: *const Strings = &en;

pub fn t(comptime field: std.meta.FieldEnum(Strings)) [:0]const u8 {
    return @field(active.*, @tagName(field));
}
