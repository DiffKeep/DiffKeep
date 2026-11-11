const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const library_manager_mod = @import("library_manager.zig");
const models_mod = @import("models.zig");

// UI modules — re-exported so the headless test build compiles and can drive
// them. They reach the backend only through the `platform` seam, so they build
// against dvui's `.testing` backend.
pub const platform = @import("platform.zig");
pub const fonts = @import("fonts.zig");
pub const style = @import("style.zig");
pub const app_icons = @import("app_icons.zig");
pub const sidebar = @import("sidebar.zig");
pub const toolbar = @import("toolbar.zig");
pub const detail_panel = @import("detail_panel.zig");
pub const settings_modal = @import("settings_modal.zig");
pub const filter_modal = @import("filter_modal.zig");
pub const delete_dialog = @import("delete_dialog.zig");
pub const search = @import("search.zig");
pub const image_viewer = @import("image_viewer.zig");
pub const image_grid = image_grid_mod;
pub const thumb_loader = @import("thumb_loader.zig");
pub const view_query = @import("view_query.zig");
pub const image_ops = @import("image_ops.zig");
pub const vips = @import("vips");
pub const video = @import("video");
pub const library_manager = library_manager_mod;
pub const counts = @import("counts.zig");
pub const video_player = @import("video_player.zig");
pub const app_state = @import("app_state.zig");

pub const Config = config_mod.Config;
pub const VectorDb = db_mod.VectorDb;
pub const ActiveFilter = db_mod.ActiveFilter;
pub const DbStats = db_mod.DbStats;
pub const TrashStats = db_mod.TrashStats;
pub const ImageDetails = db_mod.ImageDetails;
pub const GridState = image_grid_mod.GridState;
pub const ImageEntry = image_grid_mod.ImageEntry;
pub const LibraryManager = library_manager_mod.LibraryManager;
pub const Image = models_mod.Image;
pub const Library = models_mod.Library;
