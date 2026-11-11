const std = @import("std");
const log = std.log.scoped(.delete_dialog);
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const image_grid_mod = @import("image_grid.zig");
const image_ops = @import("image_ops.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");

pub const DeleteDialogState = struct {
    skip_delete_confirm: bool = false,
    skip_permanent_delete_confirm: bool = false,
    open: bool = false,
    force: bool = false,
    count: usize = 0,
    name_buf: [512]u8 = undefined,
    name_len: usize = 0,
    /// The images the dialog was opened for. A background reload while it is
    /// open replaces the grid's selection, so confirm re-selects these.
    ids: std.ArrayList(u64) = .empty,

    pub fn deinit(self: *DeleteDialogState, gpa: std.mem.Allocator) void {
        self.ids.deinit(gpa);
    }

    /// Remember the grid's selection (or focused image) as the dialog's target.
    pub fn snapshot(self: *DeleteDialogState, gpa: std.mem.Allocator, grid: *const image_grid_mod.GridState) void {
        self.ids.clearRetainingCapacity();
        // All or nothing: a dialog acting on part of what was picked would
        // delete a different set than the user chose.
        self.ids.ensureTotalCapacity(gpa, @max(grid.selection.count(), 1)) catch |err| {
            log.warn("delete dialog: {}", .{err});
            return;
        };
        if (grid.selection.count() > 0) {
            var it = grid.selection.keyIterator();
            while (it.next()) |id| self.ids.appendAssumeCapacity(id.*);
        } else if (grid.focused_idx) |fi| {
            if (fi < grid.images.items.len) self.ids.appendAssumeCapacity(grid.images.items[fi].id);
        }
    }

    /// Select exactly the snapshotted images that are still in the grid.
    pub fn restoreSelection(self: *const DeleteDialogState, grid: *image_grid_mod.GridState) void {
        grid.selection.clearRetainingCapacity();
        grid.selection.ensureTotalCapacity(@intCast(self.ids.items.len)) catch |err| {
            log.warn("restore selection: {}", .{err});
            return;
        };
        for (self.ids.items) |id| {
            if (grid.entryById(id) != null) grid.selection.putAssumeCapacity(id, {});
        }
    }

    pub fn render(
        self: *DeleteDialogState,
        trash_enabled: bool,
        grid: ?*image_grid_mod.GridState,
        file_ops: ?*image_ops.FileOps,
        gpa: std.mem.Allocator,
    ) !void {
        if (!self.open) return;

        var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
            .min_size_content = .{ .w = 360, .h = 0 },
        });
        defer float.deinit();
        float.autoSize();

        var content = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(18),
        });
        defer content.deinit();

        const permanent = self.force or !trash_enabled;
        const title = if (permanent) i18n.t(.confirm_delete_title) else i18n.t(.confirm_trash_title);
        style.modalTitle(@src(), title);

        if (self.count == 1) {
            const name = self.name_buf[0..self.name_len];
            fonts.richLabel(@src(), name, .{
                .font = style.F.row_hi,
                .color_text = .{ .color = style.C.text_hi },
                .margin = .{ .h = 16 },
            });
        } else {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 16 } });
            defer line.deinit();
            dvui.label(@src(), "{d} ", .{self.count}, .{
                .font = style.F.mono_val, .color_text = .{ .color = style.C.text_hi }, .gravity_y = 0.5,
            });
            dvui.label(@src(), "{s}", .{i18n.t(.confirm_files_selected)}, .{
                .color_text = .{ .color = style.C.text_dim }, .gravity_y = 0.5,
            });
        }

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
        defer btn_row.deinit();

        if (dvui.button(@src(), i18n.t(.action_cancel), .{}, .{ .margin = .all(4) })) {
            self.open = false;
        }

        if (self.count == 1) {
            const skip_label = if (permanent) i18n.t(.confirm_delete_no_ask) else i18n.t(.confirm_trash_no_ask);
            if (dvui.button(@src(), skip_label, .{}, .{ .margin = .all(4) })) {
                self.open = false;
                if (permanent) self.skip_permanent_delete_confirm = true
                else           self.skip_delete_confirm = true;
                if (grid) |g| {
                    self.restoreSelection(g);
                    perform(file_ops, gpa, g, permanent);
                }
            }
        }

        const confirm_label = if (permanent) i18n.t(.confirm_delete) else i18n.t(.confirm_move_to_trash);
        const confirmed = if (permanent)
            dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4), .style = .err })
        else
            style.primaryButton(@src(), confirm_label, .{ .margin = .all(4) });
        if (confirmed) {
            self.open = false;
            if (grid) |g| {
                self.restoreSelection(g);
                perform(file_ops, gpa, g, permanent);
            }
        }
    }
};

fn perform(file_ops: ?*image_ops.FileOps, gpa: std.mem.Allocator, grid: *image_grid_mod.GridState, permanent: bool) void {
    const ops = file_ops orelse return;
    if (permanent) ops.performDelete(gpa, grid) else ops.performTrash(gpa, grid);
}
