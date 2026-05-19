const std = @import("std");
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const i18n = @import("i18n.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

pub fn filterColumnLabel(kind: db_mod.FilterColumn) [:0]const u8 {
    return switch (kind) {
        .model     => i18n.t(.detail_model),
        .sampler   => i18n.t(.detail_sampler),
        .scheduler => i18n.t(.detail_scheduler),
    };
}

fn filterMatchesTyped(opt: []const u8, typed: []const u8) bool {
    if (typed.len == 0) return true;
    if (typed.len > opt.len) return false;
    var i: usize = 0;
    outer: while (i + typed.len <= opt.len) : (i += 1) {
        for (typed, 0..) |c, j| {
            if (std.ascii.toLower(c) != std.ascii.toLower(opt[i + j])) continue :outer;
        }
        return true;
    }
    return false;
}

pub const FilterModalState = struct {
    open: bool = false,
    kind: db_mod.FilterColumn = .model,
    value_buf: [256]u8 = std.mem.zeroes([256]u8),
    options: ?[][]const u8 = null,
    options_kind: ?db_mod.FilterColumn = null,

    pub fn deinit(self: *FilterModalState, gpa: std.mem.Allocator) void {
        if (self.options) |opts| {
            for (opts) |s| gpa.free(s);
            gpa.free(opts);
            self.options = null;
        }
    }

    pub fn render(
        self: *FilterModalState,
        active_filters: *std.ArrayList(db_mod.ActiveFilter),
        db: ?*db_mod.VectorDb,
        grid: ?*image_grid_mod.GridState,
    ) !void {
        if (!self.open) return;

        // Fetch autocomplete options when kind changes or first open.
        if (self.options_kind == null or self.options_kind.? != self.kind) {
            if (dvui.App.main_init) |init| {
                self.deinit(init.gpa);
                if (db) |d| {
                    self.options = d.getDistinctColumnValues(init.gpa, self.kind) catch null;
                }
            }
            self.options_kind = self.kind;
        }

        var float = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &self.open,
            .resize = .none,
        }, .{
            .min_size_content = .{ .w = 380, .h = 0 },
        });
        defer float.deinit();
        float.autoSize();
        float.dragAreaSet(dvui.Rect.Physical{});

        var content = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(16),
        });
        defer content.deinit();

        dvui.label(@src(), "{s}", .{i18n.t(.filter_heading)}, .{ .font = bold, .margin = .{ .h = 10 } });

        // Kind selector chips
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .h = 8 },
            });
            defer row.deinit();

            const chip_base: dvui.Options = .{
                .corner_radius = dvui.Rect.all(12),
                .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                .margin = .{ .w = 4 },
                .gravity_y = 0.5,
            };

            const kinds = [_]db_mod.FilterColumn{ .model, .sampler, .scheduler };
            for (kinds) |kind| {
                const selected = self.kind == kind;
                const chip_opts = if (selected)
                    chip_base.override(.{
                        .id_extra = @intFromEnum(kind),
                        .background = true,
                        .color_fill = dvui.themeGet().focus,
                    })
                else
                    chip_base.override(.{ .id_extra = @intFromEnum(kind) });
                if (dvui.button(@src(), filterColumnLabel(kind), .{}, chip_opts)) {
                    if (self.kind != kind) {
                        self.kind = kind;
                        self.value_buf = std.mem.zeroes([256]u8);
                        self.options_kind = null; // trigger re-fetch
                    }
                }
            }
        }

        // Value text entry
        {
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = self.value_buf[0..] },
                .placeholder = i18n.t(.filter_search_placeholder),
            }, .{
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .h = 4 },
            });
            te.deinit();
        }

        // Autocomplete options
        {
            const typed = std.mem.sliceTo(&self.value_buf, 0);
            const opts = self.options orelse &.{};
            var shown: usize = 0;
            for (opts, 0..) |opt, oi| {
                if (shown >= 8) break;
                if (!filterMatchesTyped(opt, typed)) continue;
                shown += 1;
                if (dvui.button(@src(), opt, .{}, .{
                    .id_extra = oi,
                    .expand = .horizontal,
                    .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                    .margin = .{ .h = 1 },
                })) {
                    @memset(&self.value_buf, 0);
                    const len = @min(opt.len, self.value_buf.len - 1);
                    @memcpy(self.value_buf[0..len], opt[0..len]);
                }
            }
        }

        // Action buttons
        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_x = 1.0,
                .margin = .{ .y = 12 },
            });
            defer btn_row.deinit();

            if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
                self.open = false;
            }

            const val = std.mem.sliceTo(&self.value_buf, 0);
            const can_add = val.len > 0;
            const theme = dvui.themeGet();
            if (dvui.button(@src(), i18n.t(.filter_add), .{}, .{
                .margin = .all(4),
                .color_fill       = if (!can_add) theme.fill else null,
                .color_fill_hover = if (!can_add) theme.fill else null,
                .color_fill_press = if (!can_add) theme.fill else null,
                .color_text       = if (!can_add) theme.border else null,
                .color_text_hover = if (!can_add) theme.border else null,
                .color_text_press = if (!can_add) theme.border else null,
            }) and can_add) {
                if (dvui.App.main_init) |init| {
                    const owned_val = try init.gpa.dupe(u8, val);
                    try active_filters.append(init.gpa, .{
                        .column = self.kind,
                        .value = owned_val,
                    });
                    if (grid) |g| {
                        g.filters = active_filters.items;
                        if (db) |d| g.reloadImages(d) catch {};
                    }
                }
                self.open = false;
            }
        }
    }
};
