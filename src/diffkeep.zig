const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const library_manager_mod = @import("library_manager.zig");
const models_mod = @import("models.zig");
const onnx_mod = @import("onnx_embedder.zig");

pub const Config = config_mod.Config;
pub const VectorDb = db_mod.VectorDb;
pub const GridState = image_grid_mod.GridState;
pub const LibraryManager = library_manager_mod.LibraryManager;
pub const Image = models_mod.Image;
pub const Library = models_mod.Library;

/// Global state — owned by app.zig in production; set by the test shim in tests.
pub var g_cfg: Config = .{};
pub var g_db: ?VectorDb = null;
pub var g_grid: ?GridState = null;
pub var g_library_manager: ?LibraryManager = null;
pub var g_embedder: ?onnx_mod.OnnxEmbedder = null;
