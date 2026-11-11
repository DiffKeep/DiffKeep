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
const counts_mod = @import("counts.zig");
const style = @import("style.zig");

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
    favorite_count: *i64,
    sidebar: *sidebar_mod.SidebarState,
    detail: *detail_panel_mod.DetailState,
    library_manager: *?library_manager_mod.LibraryManager,
    left_w: *f32,
    left_w_open: *f32,
    right_w: *f32,
    right_w_open: *f32,
    total_image_count: *i64,
    /// Background counts; refreshed after a sidebar change, and asked for
    /// the database stats when Settings opens. Null: nothing to refresh.
    counts: ?*counts_mod.CountsLoader = null,
    /// For the "working" indicator while a bulk operation runs.
    file_ops: ?*image_ops_mod.FileOps = null,
    embedder_loading: bool,
};

pub fn renderToolbar(ctx: RenderCtx) void {
    var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
        .background = true,
        .color_fill = .{ .color = style.C.chrome },
        .border = style.Edge.bottom,
        .color_border = .{ .color = style.hairline },
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
                .background = true,
                .color_fill = .{ .color = style.C.sunken },
                .border = style.Edge.all,
                .color_border = .{ .color = style.hairline_hi },
                .corners = style.R.button,
                .padding = .{ .x = 9, .y = 5, .w = 9, .h = 5 },
                .font = style.F.input,
            });
            defer te.deinit();
        }

        if (ctx.search.buf[0] != 0) {
            if (dvui.buttonIcon(@src(), i18n.t(.a11y_search_clear), dvui.entypo.cross, .{}, .{}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 14, .h = 14 },
                .padding = dvui.Rect.all(3),
                .margin = .{ .x = 4 },
                .corners = style.R.chip,
                .color_text = .{ .color = style.C.text_dim },
                .tag = "search-clear",
            })) {
                @memset(&ctx.search.buf, 0);
                ctx.search.force_search = true;
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    // Search mode: one segmented well rather than four loose buttons. The modes
    // are mutually exclusive and the set never changes, which is exactly what a
    // segmented control says and a row of toggles does not.
    {
        const modes = [_]image_grid_mod.SearchMode{ .fts, .semantic, .visual, .combined };
        const labels = [_][]const u8{
            i18n.t(.search_mode_fts),
            i18n.t(.search_mode_semantic),
            i18n.t(.search_mode_visual),
            i18n.t(.search_mode_combined),
        };
        const has_prompt = if (ctx.search.embedder) |e| e.hasPromptEncoder() else false;
        const has_visual = if (ctx.search.embedder) |e| e.hasVisualEncoder() else false;
        const enabled = [_]bool{ true, has_prompt, has_visual, has_prompt and has_visual };

        var active: usize = 0;
        for (modes, 0..) |m, i| if (ctx.search.mode == m) { active = i; };

        var well = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
        defer well.deinit();

        if (style.segmented(@src(), &labels, active, .{ .enabled = &enabled })) |picked| {
            if (ctx.search.mode != modes[picked]) {
                ctx.search.mode = modes[picked];
                ctx.search.force_search = true;
            }
        }
        // One tooltip for the whole well: the per-segment reason is always the
        // same ("no model loaded"), so four identical tooltips were four copies
        // of one sentence.
        if (!has_prompt or !has_visual) {
            dvui.tooltip(@src(), .{
                .active_rect = well.data().rectScale().r,
                .delay = 400_000,
            }, "{s}", .{i18n.t(.search_no_model_hint)}, .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    // A search in flight is the machine working, so it is amber.
    if (ctx.search.isSearchLoading(if (ctx.grid.*) |*g| g else null)) {
        _ = dvui.spinner(@src(), .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .margin = .{ .x = 4 },
            .color_text = .{ .color = style.C.amber },
        });
        dvui.label(@src(), "{s}", .{i18n.t(.search_loading)}, .{
            .gravity_y = 0.5,
            .margin = .{ .w = 4 },
            .font = style.F.mono,
            .color_text = .{ .color = style.C.amber },
        });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    const chip: dvui.Options = .{
        .corners = style.R.button,
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
        .margin = .{ .x = 2, .w = 2 },
        .gravity_y = 0.5,
    };
    var filter_remove_idx: ?usize = null;
    for (ctx.active_filters.items, 0..) |f, fi| {
        // An active filter is a choice the user made, so it is blue — a tinted
        // fill and border rather than a solid slab, which would out-shout the
        // grid it is filtering.
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi,
            .corners = style.R.button,
            .padding = .{ .x = 8, .y = 4, .w = 4, .h = 4 },
            .margin = .{ .x = 2, .w = 2 },
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = style.over(style.C.chrome, style.C.blue, 0.14) },
            .border = style.Edge.all,
            .color_border = .{ .color = style.tint(style.C.blue, 90) },
        });
        defer pill.deinit();
        dvui.label(@src(), "{s}: {s}", .{ filter_modal_mod.filterColumnLabel(f.column), f.value }, .{
            .id_extra = fi,
            .gravity_y = 0.5,
            .font = style.F.mono,
            .color_text = .{ .color = style.C.text_hi },
        });
        if (dvui.buttonIcon(@src(), i18n.t(.a11y_remove_filter), dvui.entypo.cross, .{}, .{}, .{
            .id_extra = fi,
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(2),
            .margin = .{ .x = 4 },
            .corners = style.R.chip,
            .color_text = .{ .color = style.C.text_dim },
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
            grid.reloadImages() catch {};
        }
    }

    if (dvui.button(@src(), i18n.t(.toolbar_add_filter), .{}, chip.override(.{
        .id_extra = 4,
        .font = style.F.ui,
        .color_fill = .{ .color = style.C.raised_dim },
        .color_text = .{ .color = style.C.text_dim },
        .border = style.Edge.all,
        .color_border = .{ .color = style.hairline },
    }))) {
        ctx.filter_modal.open = true;
        ctx.filter_modal.value_buf = std.mem.zeroes([256]u8);
        ctx.filter_modal.kind = .model;
        ctx.filter_modal.options_kind = null;
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

    if (ctx.grid.*) |*grid| {
        // Thumbnail size is a value the user sets, so the filled bar is blue.
        // `color_fill` here paints the empty track and the knob; `color_bar` is
        // the filled portion.
        _ = dvui.slider(@src(), .{ .fraction = &grid.thumb_fraction, .color_bar = style.C.blue }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 80, .h = 14 },
            .color_fill = .{ .color = style.C.track },
        });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // Autoplay toggle: live-play animated/video cells in the grid (muted).
        // Accent-tinted when on so its state reads at a glance.
        {
            const on = grid.autoplay;
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 7, .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "autoplay_icon", icons.tvg.lucide.film, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
                .color_text = .{ .color = if (on) style.C.blue else style.C.text_dim },
            });
            if (bw.clicked()) grid.autoplay = !grid.autoplay;
            bw.drawFocus();
            const tip = if (on) i18n.t(.toolbar_autoplay_on) else i18n.t(.toolbar_autoplay_off);
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{tip}, .{});
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 0 } });

        // A search shows results in rank order, so the sort controls are
        // greyed out and inert; the settings themselves are left alone, so
        // they apply again when the search is cleared.
        const sort_enabled = !grid.isRelevanceRanked();
        const sort_color = if (sort_enabled) style.C.text_dim else style.C.text_ghost;
        const relevance_tip = i18n.t(.toolbar_sort_by_relevance);

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
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 5, .tag = "sort-mode", .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "sort_mode_icon", sort_mode_tvg, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
                .color_text = .{ .color = sort_color },
            });
            if (bw.clicked() and sort_enabled) {
                grid.sort_mode = switch (grid.sort_mode) {
                    .date => .name,
                    .name => .random,
                    .random => .date,
                };
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{if (sort_enabled) sort_mode_tip else relevance_tip}, .{});
        }

        if (grid.sort_mode == .random) {
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .tag = "sort-dir", .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "reshuffle_icon", icons.tvg.lucide.dices, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
                .color_text = .{ .color = sort_color },
            });
            if (bw.clicked() and sort_enabled) {
                grid.sort_seed +%= 1;
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{if (sort_enabled) i18n.t(.toolbar_reshuffle) else relevance_tip}, .{});
        } else {
            const dir_tvg = if (grid.sort_dir == .asc) icons.tvg.lucide.@"arrow-up" else icons.tvg.lucide.@"arrow-down";
            const dir_tip = if (grid.sort_dir == .asc) i18n.t(.toolbar_sort_ascending) else i18n.t(.toolbar_sort_descending);
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, chip.override(.{ .id_extra = 6, .tag = "sort-dir", .min_size_content = .{ .w = 16, .h = 16 } }));
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();
            dvui.icon(@src(), "sort_dir_icon", dir_tvg, .{}, .{
                .gravity_x = 0.5, .gravity_y = 0.5,
                .min_size_content = .{ .w = 16, .h = 16 },
                .expand = .ratio,
                .color_text = .{ .color = sort_color },
            });
            if (bw.clicked() and sort_enabled) {
                grid.sort_dir = if (grid.sort_dir == .asc) .desc else .asc;
                grid.applySortOrder();
            }
            bw.drawFocus();
            dvui.tooltip(@src(), .{ .active_rect = bw.data().rectScale().r, .delay = 500_000 }, "{s}", .{if (sort_enabled) dir_tip else relevance_tip}, .{});
        }
    }
}

/// Full-width, accent-coloured action bar shown above the grid in the duplicates
/// and trash views, explaining the bulk action and offering the button:
///  * duplicates → accent (highlight) banner: move all but one of each to Trash.
///  * trash      → danger (err) banner: permanently empty the trash.
/// While a bulk op runs it shows a "Working…" label in place of the button.
fn renderActionBanner(grid: *image_grid_mod.GridState, duplicate_count: i64, trash_stats: ?db_mod.TrashStats, bulk_active: bool) void {
    const Action = enum { dedupe, empty_trash };
    var action: Action = undefined;
    var accent: style.Color = undefined;
    var description: [:0]const u8 = undefined;
    var button_text: [:0]const u8 = undefined;
    switch (grid.view_mode) {
        .duplicates => {
            if (duplicate_count <= 0) return;
            action = .dedupe;
            accent = style.C.blue;
            description = i18n.t(.dupes_banner_text);
            button_text = i18n.t(.dupes_remove_button);
        },
        .trash => {
            const has_items = if (trash_stats) |ts| ts.count > 0 else false;
            if (!has_items) return;
            action = .empty_trash;
            accent = style.C.danger;
            description = i18n.t(.trash_banner_text);
            button_text = i18n.t(.settings_empty_trash);
        },
        .library, .favorites => return,
    }

    // A tinted wash with an accent left edge, not a saturated slab: the banner
    // sits directly above the grid and a solid accent there would out-shout
    // every thumbnail under it. `over` resolves the wash to an opaque colour
    // because dvui paints the border rect first and insets the background.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 9, .w = 12, .h = 9 },
        .background = true,
        .color_fill = .{ .color = style.over(style.C.canvas, accent, 0.12) },
        .border = .{ .x = 2, .h = 1 },
        .color_border = .{ .color = style.tint(accent, 150) },
    });
    defer bar.deinit();

    // Description fills the bar and pushes the action to the right edge.
    dvui.label(@src(), "{s}", .{description}, .{
        .gravity_y = 0.5,
        .expand = .horizontal,
        .color_text = .{ .color = style.C.text_hi },
    });

    // A bulk op in flight is the machine working: amber, with the spinner that
    // says so, never a disabled-looking grey.
    if (bulk_active) {
        _ = dvui.spinner(@src(), .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .margin = .{ .w = 6 },
            .color_text = .{ .color = style.C.amber },
        });
        dvui.label(@src(), "{s}", .{i18n.t(.action_working)}, .{
            .gravity_y = 0.5,
            .font = style.F.mono,
            .color_text = .{ .color = style.C.amber },
        });
        return;
    }

    if (dvui.button(@src(), button_text, .{}, .{
        .gravity_y = 0.5,
        .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        .corners = style.R.button,
        .font = style.F.ui,
        .style = if (action == .empty_trash) .err else .control,
    })) {
        switch (action) {
            .dedupe => grid.dedupe_requested = true,
            .empty_trash => grid.empty_trash_requested = true,
        }
    }
}

pub fn renderContent(ctx: RenderCtx) !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.C.canvas },
    });
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
                ctx.favorite_count.*,
            )) if (ctx.counts) |c| c.request();
        }
    }

    widgets_mod.panelHandle(@src(), .left, ctx.left_w, ctx.left_w_open, left_w_min, left_w_max);

    {
        var grid_area = dvui.box(@src(), .{}, .{ .expand = .both });
        defer grid_area.deinit();

        if (ctx.grid.*) |*grid| {
            grid.trash_enabled = ctx.cfg.trash_enabled;
            renderActionBanner(grid, ctx.duplicate_count.*, ctx.trash_stats.*, if (ctx.file_ops) |o| o.bulkActive() else false);
            grid.render();
        } else {
            dvui.label(@src(), "{s}", .{i18n.t(.library_empty)}, .{
                .padding = .all(12),
                .color_text = .{ .color = style.C.text_ghost },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
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
                        mgr.reparseImage(d.id, d.library_id, d.library_path);
                }
            }
        }
    }
}

/// One "the machine is busy" line: amber spinner, amber mono caption. Every
/// background job in the status bar reads identically, so the user learns one
/// shape rather than four.
fn activityLine(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer line.deinit();
    _ = dvui.spinner(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 12, .h = 12 },
        .color_text = .{ .color = style.C.amber },
    });
    dvui.label(@src(), fmt, args, .{
        .gravity_y = 0.5,
        .margin = .{ .x = 6 },
        .font = style.F.mono,
        .color_text = .{ .color = style.C.amber },
    });
}

pub fn renderStatusBar(ctx: RenderCtx) void {
    var statusbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 5, .w = 6, .h = 5 },
        .background = true,
        .color_fill = .{ .color = style.C.chrome },
        .border = style.Edge.top,
        .color_border = .{ .color = style.hairline },
    });
    defer statusbar.deinit();

    // ── Section 1: image count ──────────────────────────────────────────────
    // Figures the user compares against each other, so they are monospaced and
    // their units are dimmed away from them.
    {
        var count_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 170 },
            .gravity_y = 0.5,
        });
        defer count_box.deinit();

        const figure: dvui.Options = .{ .font = style.F.mono_val, .color_text = .{ .color = style.C.text_hi }, .gravity_y = 0.5 };
        const unit: dvui.Options = .{ .font = style.F.mono, .color_text = .{ .color = style.C.text_faint }, .gravity_y = 0.5 };

        if (ctx.library_manager.* != null) {
            const displayed: usize = if (ctx.grid.*) |*grid| grid.images.items.len else 0;
            const total: i64 = ctx.total_image_count.*;
            dvui.label(@src(), "{d}", .{displayed}, figure);
            if (@as(i64, @intCast(displayed)) < total) {
                dvui.label(@src(), " {s} ", .{i18n.t(.status_out_of)}, unit);
                dvui.label(@src(), "{d}", .{total}, figure);
                dvui.label(@src(), " {s}", .{i18n.t(.status_images)}, unit);
            } else {
                dvui.label(@src(), " {s}", .{i18n.t(.status_images)}, unit);
            }
        } else {
            dvui.label(@src(), "{s}", .{i18n.t(.status_no_database)}, unit);
        }
    }

    style.vsep(@src());

    // ── Section 2: current activity ─────────────────────────────────────────
    {
        var activity_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 220 },
            .gravity_y = 0.5,
        });
        defer activity_box.deinit();

        const is_scanning = if (ctx.library_manager.*) |*mgr| mgr.isScanActive() else false;
        const is_searching = ctx.search.isSearchLoading(if (ctx.grid.*) |*g| g else null);
        const is_downloading = ctx.settings.gemma_dl != null or ctx.settings.siglip2_dl != null;

        if (is_scanning) {
            const embed_total = if (ctx.library_manager.*) |*mgr| mgr.embedsTotal() else 0;
            if (embed_total > 0) {
                const embed_done = if (ctx.library_manager.*) |*mgr| mgr.embedsDone() else 0;
                activityLine(@src(), "{s}: {d} / {d}", .{ i18n.t(.status_embedding), embed_done, embed_total });
            } else {
                const scanned = if (ctx.library_manager.*) |*mgr| mgr.filesScanned() else 0;
                activityLine(@src(), "{s}: {d}", .{ i18n.t(.status_indexing), scanned });
            }
        } else if (is_searching) {
            activityLine(@src(), "{s}", .{i18n.t(.search_loading)});
        } else if (ctx.embedder_loading) {
            activityLine(@src(), "{s}", .{i18n.t(.status_loading_model)});
        } else if (is_downloading) {
            activityLine(@src(), "{s}", .{i18n.t(.settings_download_running)});
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dvui.buttonIcon(@src(), i18n.t(.nav_settings), dvui.entypo.cog, .{}, .{}, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(4),
        .margin = .{ .w = 2 },
        .corners = style.R.chip,
        .background = false,
        .color_text = .{ .color = style.C.text_dim },
    })) {
        ctx.settings.open = !ctx.settings.open;
        if (ctx.settings.open) {
            if (ctx.counts) |c| c.requestStats();
            ctx.settings.scan_snapshot = .{
                .thumbnails_in_db = ctx.cfg.thumbnails_in_db,
                .prompt_embeddings = ctx.cfg.prompt_embeddings,
                .image_embeddings = ctx.cfg.image_embeddings,
            };
            @memcpy(&ctx.settings.model_snapshot.text_dir, &ctx.settings.text_model_dir_buf);
            @memcpy(&ctx.settings.model_snapshot.visual_dir, &ctx.settings.visual_model_dir_buf);
            @memcpy(&ctx.settings.data_path_snapshot, &ctx.settings.data_path_buf);
            ctx.settings.gpu_snapshot = .{
                .backend = ctx.cfg.embed_gpu_backend,
                .threshold = ctx.cfg.embed_gpu_threshold,
            };
        }
    }
}
