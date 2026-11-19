const std = @import("std");
const log = std.log.scoped(.filter_modal);
const dvui = @import("dvui");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const i18n = @import("i18n.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");
const bg = @import("bg.zig");

pub fn filterColumnLabel(kind: db_mod.FilterColumn) [:0]const u8 {
    return switch (kind) {
        .model     => i18n.t(.detail_model),
        .sampler   => i18n.t(.detail_sampler),
        .scheduler => i18n.t(.detail_scheduler),
        .generator => i18n.t(.detail_generator),
        .format    => i18n.t(.detail_format),
        .resource_type => i18n.t(.detail_resource_type),
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

/// A column's distinct values, the autocomplete options.
const Options = struct {
    values: [][]const u8,

    fn free(o: *Options, a: std.mem.Allocator) void {
        for (o.values) |v| a.free(v);
        a.free(o.values);
    }
};

const OptionsLoad = bg.Latest(Options, Options.free);

/// Read `kind`'s distinct values on a connection of its own. The query scans
/// the whole table, so it runs in the background.
fn optionsTask(_: OptionsLoad.Ticket, db: *db_mod.VectorDb, gpa: std.mem.Allocator, kind: db_mod.FilterColumn) ?Options {
    var conn = db.getConnection() catch |err| {
        log.warn("filter options connection: {}", .{err});
        return null;
    };
    defer conn.deinit();
    const values = conn.getDistinctColumnValues(gpa, kind) catch |err| {
        log.warn("filter options: {}", .{err});
        return null;
    };
    return .{ .values = values };
}

pub const FilterModalState = struct {
    open: bool = false,
    kind: db_mod.FilterColumn = .model,
    value_buf: [256]u8 = std.mem.zeroes([256]u8),
    /// The shown kind's options; null until they have loaded.
    options: ?Options = null,
    /// The kind whose options were last requested.
    options_kind: ?db_mod.FilterColumn = null,
    load: OptionsLoad = .{},
    /// The library, set once by the owner; options load on a connection of
    /// their own. Without it there are no options.
    db: ?*db_mod.VectorDb = null,

    /// Waits for a running options load.
    pub fn deinit(self: *FilterModalState, gpa: std.mem.Allocator) void {
        self.load.deinit();
        self.freeOptions(gpa);
    }

    fn freeOptions(self: *FilterModalState, gpa: std.mem.Allocator) void {
        if (self.options) |*o| o.free(gpa);
        self.options = null;
    }

    /// Request `kind`'s options when it changes (or the dialog first opens),
    /// and show them once they arrive.
    pub fn updateOptions(self: *FilterModalState, gpa: std.mem.Allocator, io: std.Io, wakeup: ?*const fn () void) void {
        const db = self.db orelse return;
        if (self.options_kind != self.kind) {
            self.freeOptions(gpa);
            self.options_kind = self.kind;
            self.load.wakeup_fn = wakeup;
            _ = self.load.start(io, gpa, optionsTask, .{ db, gpa, self.kind }) catch |err|
                log.warn("filter options load: {}", .{err});
        }
        const outcome = self.load.take() orelse return;
        const o = outcome.value orelse return;
        self.freeOptions(gpa);
        self.options = o;
    }

    /// Wait for the running options load and show it (tests).
    pub fn awaitOptions(self: *FilterModalState, gpa: std.mem.Allocator, io: std.Io) void {
        self.load.awaitAll();
        self.updateOptions(gpa, io, null);
    }

    pub fn render(
        self: *FilterModalState,
        active_filters: *std.ArrayList(db_mod.ActiveFilter),
        grid: ?*image_grid_mod.GridState,
        wakeup: ?*const fn () void,
    ) !void {
        if (!self.open) return;

        if (dvui.App.main_init) |init| self.updateOptions(init.gpa, init.io, wakeup);

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
            .padding = .all(18),
        });
        defer content.deinit();

        style.modalTitle(@src(), i18n.t(.filter_heading));

        // Kind selector: the same segmented well the toolbar uses for search
        // modes, because it is the same kind of choice — one of a fixed set.
        {
            const kinds = [_]db_mod.FilterColumn{ .generator, .model, .sampler, .scheduler, .format, .resource_type };
            var labels: [kinds.len][]const u8 = undefined;
            var active: usize = 0;
            for (kinds, 0..) |kind, i| {
                labels[i] = filterColumnLabel(kind);
                if (self.kind == kind) active = i;
            }
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .h = 10 },
            });
            defer row.deinit();
            if (style.segmented(@src(), &labels, active, .{ .font = style.F.ui_sm })) |picked| {
                if (self.kind != kinds[picked]) {
                    self.kind = kinds[picked];
                    self.value_buf = std.mem.zeroes([256]u8);
                    self.options_kind = null; // trigger re-fetch
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
                .background = true,
                .color_fill = .{ .color = style.C.sunken },
                .border = style.Edge.all,
                .color_border = .{ .color = style.hairline_hi },
                .corners = style.R.button,
                .padding = .{ .x = 9, .y = 6, .w = 9, .h = 6 },
                .font = style.F.input,
                .margin = .{ .h = 6 },
            });
            te.deinit();
        }

        // Autocomplete options. Flat rows, not buttons: eight raised slabs in a
        // column read as eight competing actions, where this is one list the
        // user picks from.
        {
            const typed = std.mem.sliceTo(&self.value_buf, 0);
            const opts: []const []const u8 = if (self.options) |o| o.values else &.{};
            var shown: usize = 0;
            for (opts, 0..) |opt, oi| {
                if (shown >= 8) break;
                if (!filterMatchesTyped(opt, typed)) continue;
                shown += 1;
                var bw: dvui.ButtonWidget = undefined;
                bw.init(@src(), .{}, .{
                    .id_extra = oi,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = style.C.chrome },
                    .color_fill_hover = .{ .color = style.C.sel_row },
                    .color_fill_press = .{ .color = style.C.raised },
                    .corners = style.R.chip,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .margin = .{ .h = 1 },
                });
                defer bw.deinit();
                bw.processEvents();
                bw.drawBackground();
                // Option values come from the database (model names, samplers),
                // so they can carry any script.
                fonts.richLine(@src(), opt, .{
                    .id_extra = oi,
                    .expand = .horizontal,
                    .gravity_y = 0.5,
                    .font = style.F.mono,
                    .color_text = .{ .color = if (bw.hovered()) style.C.text_hi else style.C.text_dim },
                });
                if (bw.clicked()) {
                    @memset(&self.value_buf, 0);
                    const len = @min(opt.len, self.value_buf.len - 1);
                    @memcpy(self.value_buf[0..len], opt[0..len]);
                }
                bw.drawFocus();
            }
        }

        // Action buttons
        {
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_x = 1.0,
                .margin = .{ .y = 14 },
            });
            defer btn_row.deinit();

            if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
                self.open = false;
            }

            const val = std.mem.sliceTo(&self.value_buf, 0);
            const can_add = val.len > 0;
            // With nothing typed there is nothing to add, so Add is ghosted
            // rather than removed — the button's slot is what tells the user
            // the field above it is the thing to fill in.
            const added = if (can_add)
                style.primaryButton(@src(), i18n.t(.filter_add), .{ .margin = .all(4) })
            else blk: {
                _ = dvui.button(@src(), i18n.t(.filter_add), .{}, .{
                    .margin = .all(4),
                    .color_fill = .{ .color = style.C.raised_dim },
                    .color_fill_hover = .{ .color = style.C.raised_dim },
                    .color_fill_press = .{ .color = style.C.raised_dim },
                    .color_text = .{ .color = style.C.text_ghost },
                    .color_text_hover = .{ .color = style.C.text_ghost },
                    .color_text_press = .{ .color = style.C.text_ghost },
                });
                break :blk false;
            };
            if (added) {
                if (dvui.App.main_init) |init| {
                    const owned_val = try init.gpa.dupe(u8, val);
                    try active_filters.append(init.gpa, .{
                        .column = self.kind,
                        .value = owned_val,
                    });
                    if (grid) |g| {
                        g.filters = active_filters.items;
                        g.reloadImages();
                    }
                }
                self.open = false;
            }
        }
    }
};
