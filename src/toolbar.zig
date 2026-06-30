const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const icons = @import("icons");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const config_mod = @import("config.zig");
const filter_modal_mod = @import("filter_modal.zig");
const settings_modal_mod = @import("settings_modal.zig");
const search_mod = @import("search.zig");
const sidebar_mod = @import("sidebar.zig");
const detail_panel_mod = @import("detail_panel.zig");
const library_manager_mod = @import("library_manager.zig");
const widgets_mod = @import("widgets.zig");
const image_ops_mod = @import("image_ops.zig");

pub const left_w_min: f32 = 160;
pub const left_w_max: f32 = 400;
pub const right_w_min: f32 = 220;
pub const right_w_max: f32 = 480;

pub const RenderCtx = struct {
    search: *search_mod.SearchState,
    active_filters: *std.ArrayList(db_mod.ActiveFilter),
    filter_modal: *filter_modal_mod.FilterModalState,
    grid: *?image_grid_mod.GridState,
    db: *?db_mod.VectorDb,
    cfg: *const config_mod.Config,
    settings: *settings_modal_mod.SettingsModalState,
    db_stats: *?db_mod.DbStats,
    trash_stats: *?db_mod.TrashStats,
    duplicate_count: *i64,
    sidebar: *sidebar_mod.SidebarState,
    detail: *detail_panel_mod.DetailState,
    library_manager: *?library_manager_mod.LibraryManager,
    left_w: *f32,
    left_w_open: *f32,
    right_w: *f32,
    right_w_open: *f32,
    total_image_count: *i64,
    on_refresh_counts: *const fn () void,
    embedder_loading: bool,
};

pub fn renderToolbar(ctx: RenderCtx) void {
    var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
        .background = true,
    });
    defer toolbar.deinit();

    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer search_row.deinit();

        {
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = ctx.search.buf[0..] },
                .placeholder = i18n.t(.search_placeholder),
            }, .{
                .tag = "search-box",
                .expand = .horizontal,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(5),
                .min_size_content = .{ .h = 22 },
            });
            defer te.deinit();
        }

        if (ctx.search.buf[0] != 0) {
            if (dvui.buttonIcon(@src(), "search_clear", dvui.entypo.cross, .{}, .{}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .padding = dvui.Rect.all(3),
                .margin = .{ .x = 4 },
            })) {
                @memset(&ctx.search.buf, 0);
                ctx.search.force_search = true;
            }
        }
    }

    {
        const modes = [_]struct { mode: image_grid_mod.SearchMode, label: [:0]const u8 }{
            .{ .mode = .fts,      .label = i18n.t(.search_mode_fts) },
            .{ .mode = .semantic, .label = i18n.t(.search_mode_semantic) },
            .{ .mode = .visual,   .label = i18n.t(.search_mode_visual) },
            .{ .mode = .combined, .label = i18n.t(.search_mode_combined) },
        };
        for (modes, 0..) |m, mi| {
            const active = ctx.search.mode == m.mode;
            const enabled: bool = switch (m.mode) {
                .fts      => true,
                .semantic => if (ctx.search.embedder) |e| e.hasPromptEncoder() else false,
                .visual   => if (ctx.search.embedder) |e| e.hasVisualEncoder() else false,
                .combined => if (ctx.search.embedder) |e| e.hasPromptEncoder() and e.hasVisualEncoder() else false,
            };
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, .{
                .id_extra = mi,
                .gravity_y = 0.5,
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 2, .w = 2 },
                .color_fill = if (active) dvui.themeGet().focus else null,
            });
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.label(@src(), "{s}", .{m.label}, .{
                .id_extra = mi,
                .gravity_y = 0.5,
                .color_text = if (enabled) null else dvui.Color{ .r = 110, .g = 110, .b = 110, .a = 255 },
            });
            if (bw.clicked() and enabled) {
                if (ctx.search.mode != m.mode) {
                    ctx.search.mode = m.mode;
                    ctx.search.force_search = true;
                }
            }
            bw.drawFocus();
            if (!enabled) {
                dvui.tooltip(@src(), .{
                    .active_rect = bw.data().rectScale().r,
                    .delay = 200_000,
                }, "{s}", .{i18n.t(.search_no_model_hint)}, .{});
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 0 } });

    if (ctx.search.isSearchLoading()) {
        _ = dvui.spinner(@src(), .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .margin = .{ .x = 4 },
        });
        dvui.label(@src(), "{s}", .{i18n.t(.search_loading)}, .{
            .gravity_y = 0.5,
            .margin = .{ .w = 4 },
        });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    const chip: dvui.Options = .{
        .corner_radius = dvui.Rect.all(12),
        .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
        .margin = .{ .x = 2, .w = 2 },
        .gravity_y = 0.5,
    };
    var filter_remove_idx: ?usize = null;
    for (ctx.active_filters.items, 0..) |f, fi| {
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi,
            .corner_radius = dvui.Rect.all(12),
            .padding = .{ .x = 8, .y = 3, .w = 4, .h = 3 },
            .margin = .{ .x = 2, .w = 2 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = dvui.themeGet().focus,
        });
        defer pill.deinit();
        dvui.label(@src(), "{s}: {s}", .{ filter_modal_mod.filterColumnLabel(f.column), f.value }, .{
            .id_extra = fi,
            .gravity_y = 0.5,
        });
        if (dvui.buttonIcon(@src(), "remove_filter", dvui.entypo.cross, .{}, .{}, .{
            .id_extra = fi,
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(2),
            .margin = .{ .x = 4 },
        })) {
            filter_remove_idx = fi;
        }
    }
    if (filter_remove_idx) |ri| {
        if (dvui.App.main_init) |init| {
            const f = ctx.active_filters.orderedRemove(ri);
            init.gpa.free(f.value);
        }
        if (ctx.grid.*) |*grid| {
            grid.filters = ctx.active_filters.items;
            if (ctx.db.*) |*db| grid.reloadImages(db) catch {};
        }
    }

    if (dvui.button(@src(), i18n.t(.toolbar_add_filter), .{}, chip.override(.{ .id_extra = 4 }))) {
        ctx.filter_modal.open = true;
        ctx.filter_modal.value_buf = std.mem.zeroes([256]u8);
        ctx.filter_modal.kind = .model;
        ctx.filter_modal.options_kind = null;
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    if (ctx.grid.*) |*grid| {
        _ = dvui.slider(@src(), .{ .fraction = &grid.thumb_fraction }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 80, .h = 16 },
        });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        {
            const sort_mode_tvg = switch (grid.sort_mode) {
                .date   => icons.tvg.lucide.calendar,
                .name   => icons.tvg.lucide.@"a-arrow-down",
                .random => icons.tvg.entypo.shuffle,
            };
            const sort_mode_tip = switch (grid.sort_mode) {
                .date   => i18n.t(.toolbar_sort_by_date),
                .name   => i18n.t(.toolbar_sort_by_name),
                .random => i18n.t(.toolbar_sort_randomly),
            };
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 5, .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "sort_mode_icon", sort_mode_tvg, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
            });
            if (bw.clicked()) {
                grid.sort_mode = switch (grid.sort_mode) {
                    .date => .name,
                    .name => .random,
                    .random => .date,
                };
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{sort_mode_tip}, .{});
        }

        if (grid.sort_mode == .random) {
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "reshuffle_icon", icons.tvg.lucide.dices, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
            });
            if (bw.clicked()) {
                grid.sort_seed +%= 1;
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{i18n.t(.toolbar_reshuffle)}, .{});
        } else {
            const dir_tvg = if (grid.sort_dir == .asc) icons.tvg.lucide.@"arrow-up" else icons.tvg.lucide.@"arrow-down";
            const dir_tip = if (grid.sort_dir == .asc) i18n.t(.toolbar_sort_ascending) else i18n.t(.toolbar_sort_descending);
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "sort_dir_icon", dir_tvg, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
            });
            if (bw.clicked()) {
                grid.sort_dir = if (grid.sort_dir == .asc) .desc else .asc;
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{dir_tip}, .{});
        }
    }
}

/// Full-width, accent-coloured action bar shown above the grid in the duplicates
/// and trash views, explaining the bulk action and offering the button:
///  * duplicates → accent (highlight) banner: move all but one of each to Trash.
///  * trash      → danger (err) banner: permanently empty the trash.
/// While a bulk op runs it shows a "Working…" label in place of the button.
fn renderActionBanner(grid: *image_grid_mod.GridState, duplicate_count: i64, trash_stats: ?db_mod.TrashStats) void {
    const Action = enum { dedupe, empty_trash };
    var action: Action = undefined;
    var style: dvui.Theme.Style.Name = undefined;
    var description: [:0]const u8 = undefined;
    var button_text: [:0]const u8 = undefined;
    switch (grid.view_mode) {
        .duplicates => {
            if (duplicate_count <= 0) return;
            action = .dedupe;
            style = .highlight;
            description = i18n.t(.dupes_banner_text);
            button_text = i18n.t(.dupes_remove_button);
        },
        .trash => {
            const has_items = if (trash_stats) |ts| ts.count > 0 else false;
            if (!has_items) return;
            action = .empty_trash;
            style = .err;
            description = i18n.t(.trash_banner_text);
            button_text = i18n.t(.settings_empty_trash);
        },
        .library => return,
    }

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .background = true,
        .style = style,
    });
    defer bar.deinit();

    // Description fills the bar and pushes the action to the right edge.
    dvui.label(@src(), "{s}", .{description}, .{
        .style = style,
        .gravity_y = 0.5,
        .expand = .horizontal,
    });

    if (image_ops_mod.bulkActive()) {
        dvui.label(@src(), "{s}", .{i18n.t(.action_working)}, .{ .style = style, .gravity_y = 0.5 });
        return;
    }

    if (dvui.button(@src(), button_text, .{}, .{
        .gravity_y = 0.5,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .corner_radius = dvui.Rect.all(4),
    })) {
        switch (action) {
            .dedupe => grid.dedupe_requested = true,
            .empty_trash => grid.empty_trash_requested = true,
        }
    }
}

pub fn renderContent(ctx: RenderCtx) !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true });
    defer row.deinit();

    if (ctx.left_w.* >= 2) {
        if (dvui.App.main_init) |init| {
            if (try ctx.sidebar.render(
                ctx.left_w.*,
                init.gpa,
                if (ctx.db.*) |*db| db else null,
                if (ctx.grid.*) |*g| g else null,
                if (ctx.library_manager.*) |*mgr| mgr else null,
                ctx.cfg.trash_enabled,
                ctx.trash_stats.*,
                ctx.duplicate_count.*,
            )) ctx.on_refresh_counts();
        }
    }

    widgets_mod.panelHandle(@src(), .left, ctx.left_w, ctx.left_w_open, left_w_min, left_w_max);

    {
        var grid_area = dvui.box(@src(), .{}, .{ .expand = .both });
        defer grid_area.deinit();

        if (ctx.grid.*) |*grid| {
            grid.trash_enabled = ctx.cfg.trash_enabled;
            renderActionBanner(grid, ctx.duplicate_count.*, ctx.trash_stats.*);
            grid.render();
        } else {
            dvui.label(@src(), "(no library)", .{}, .{ .padding = .all(8) });
        }
    }

    widgets_mod.panelHandle(@src(), .right, ctx.right_w, ctx.right_w_open, right_w_min, right_w_max);

    if (ctx.right_w.* >= 2) {
        const focused_id: ?u64 = if (ctx.grid.*) |*grid|
            if (grid.focused_idx) |fi|
                (if (fi < grid.images.items.len) grid.images.items[fi].id else null)
            else null
        else null;
        const filename: []const u8 = if (ctx.grid.*) |*grid|
            if (grid.focused_idx) |fi|
                (if (fi < grid.images.items.len) grid.images.items[fi].filename else "")
            else ""
        else "";
        if (dvui.App.main_init) |init| {
            // If the focused image was just reparsed/changed, force the detail
            // panel to reload now that the fresh data is in the DB.
            if (focused_id) |fid| {
                if (ctx.grid.*) |*grid| {
                    if (grid.wasRefreshedThisFrame(fid)) ctx.detail.id = null;
                }
            }
            if (ctx.db.*) |*db| ctx.detail.update(focused_id, db, init.gpa, init.io);
            ctx.detail.renderPanel(ctx.right_w.*, filename, init.gpa, init.io);
            if (ctx.detail.reparse_requested) {
                ctx.detail.reparse_requested = false;
                if (ctx.detail.detail) |d| {
                    if (ctx.library_manager.*) |*mgr|
                        mgr.reparseImage(init.io, d.id, d.library_id, d.library_path);
                }
            }
        }
    }
}

pub fn renderStatusBar(ctx: RenderCtx) void {
    var statusbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 2, .w = 4, .h = 2 },
        .background = true,
    });
    defer statusbar.deinit();

    // ── Section 1: image count ──────────────────────────────────────────────
    {
        var count_box = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 160 },
            .gravity_y = 0.5,
        });
        defer count_box.deinit();

        if (ctx.library_manager.* != null) {
            const displayed: usize = if (ctx.grid.*) |*grid| grid.images.items.len else 0;
            const total: i64 = ctx.total_image_count.*;
            if (@as(i64, @intCast(displayed)) < total) {
                dvui.label(@src(), "{d} {s} {s} {d}", .{
                    displayed,
                    i18n.t(.status_out_of),
                    i18n.t(.status_images),
                    total,
                }, .{ .gravity_y = 0.5 });
            } else {
                dvui.label(@src(), "{d} {s}", .{ displayed, i18n.t(.status_images) }, .{ .gravity_y = 0.5 });
            }
        } else {
            dvui.label(@src(), "{s}", .{i18n.t(.status_no_database)}, .{ .gravity_y = 0.5 });
        }
    }

    // ── Section 2: current activity ─────────────────────────────────────────
    {
        var activity_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 220 },
            .gravity_y = 0.5,
        });
        defer activity_box.deinit();

        const is_scanning = if (ctx.library_manager.*) |*mgr| mgr.isScanActive() else false;
        const is_searching = ctx.search.isSearchLoading();
        const is_downloading = ctx.settings.snowflake_dl_running.load(.acquire) or
            ctx.settings.siglip2_dl_running.load(.acquire);

        if (is_scanning) {
            _ = dvui.spinner(@src(), .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 12, .h = 12 },
            });
            const embed_total = if (ctx.library_manager.*) |*mgr| mgr.embedsTotal() else 0;
            if (embed_total > 0) {
                const embed_done = if (ctx.library_manager.*) |*mgr| mgr.embedsDone() else 0;
                dvui.label(@src(), "{s}: {d} / {d}", .{ i18n.t(.status_embedding), embed_done, embed_total }, .{
                    .gravity_y = 0.5,
                    .margin = .{ .x = 4 },
                });
            } else {
                const scanned = if (ctx.library_manager.*) |*mgr| mgr.filesScanned() else 0;
                dvui.label(@src(), "{s}: {d}", .{ i18n.t(.status_indexing), scanned }, .{
                    .gravity_y = 0.5,
                    .margin = .{ .x = 4 },
                });
            }
        } else if (is_searching) {
            _ = dvui.spinner(@src(), .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 12, .h = 12 },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.search_loading)}, .{
                .gravity_y = 0.5,
                .margin = .{ .x = 4 },
            });
        } else if (ctx.embedder_loading) {
            _ = dvui.spinner(@src(), .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 12, .h = 12 },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.status_loading_model)}, .{
                .gravity_y = 0.5,
                .margin = .{ .x = 4 },
            });
        } else if (is_downloading) {
            _ = dvui.spinner(@src(), .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 12, .h = 12 },
            });
            dvui.label(@src(), "{s}", .{i18n.t(.settings_download_running)}, .{
                .gravity_y = 0.5,
                .margin = .{ .x = 4 },
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dvui.buttonIcon(@src(), "settings", dvui.entypo.cog, .{}, .{}, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(3),
        .margin = .{ .w = 2 },
    })) {
        ctx.settings.open = !ctx.settings.open;
        if (ctx.settings.open) {
            if (ctx.db.*) |*db| {
                ctx.db_stats.* = db.getStats() catch null;
                ctx.trash_stats.* = db.getTrashStats() catch null;
            }
            ctx.settings.scan_snapshot = .{
                .thumbnails_in_db = ctx.cfg.thumbnails_in_db,
                .prompt_embeddings = ctx.cfg.prompt_embeddings,
                .image_embeddings = ctx.cfg.image_embeddings,
            };
            @memcpy(&ctx.settings.model_snapshot.text_dir, &ctx.settings.text_model_dir_buf);
            @memcpy(&ctx.settings.model_snapshot.visual_dir, &ctx.settings.visual_model_dir_buf);
            ctx.settings.gpu_snapshot = .{
                .use_gpu = ctx.cfg.use_gpu,
                .gpu_device_id = ctx.cfg.gpu_device_id,
            };
        }
    }
}
