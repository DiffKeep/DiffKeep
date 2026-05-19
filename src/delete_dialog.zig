const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const image_grid_mod = @import("image_grid.zig");

const bold = dvui.Font.find(.{ .family = "NotoSansCJKBold" });

pub const DeleteDialogState = struct {
    skip_delete_confirm: bool = false,
    skip_permanent_delete_confirm: bool = false,
    open: bool = false,
    force: bool = false,
    count: usize = 0,
    name_buf: [512]u8 = undefined,
    name_len: usize = 0,

    pub fn render(
        self: *DeleteDialogState,
        trash_enabled: bool,
        grid: ?*image_grid_mod.GridState,
        perform_trash: *const fn (std.Io, std.mem.Allocator, *image_grid_mod.GridState) void,
        perform_delete: *const fn (std.Io, std.mem.Allocator, *image_grid_mod.GridState) void,
    ) !void {
        if (!self.open) return;

        var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{
            .min_size_content = .{ .w = 360, .h = 0 },
        });
        defer float.deinit();
        float.autoSize();

        var content = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(16),
        });
        defer content.deinit();

        const permanent = self.force or !trash_enabled;
        const title = if (permanent) i18n.t(.confirm_delete_title) else i18n.t(.confirm_trash_title);
        dvui.label(@src(), "{s}", .{title}, .{ .font = bold, .margin = .{ .h = 8 } });

        if (self.count == 1) {
            const name = self.name_buf[0..self.name_len];
            dvui.label(@src(), "{s}", .{name}, .{ .margin = .{ .h = 12 } });
        } else {
            dvui.label(@src(), "{d} files selected", .{self.count}, .{ .margin = .{ .h = 12 } });
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
                    if (dvui.App.main_init) |init| {
                        if (permanent) perform_delete(init.io, init.gpa, g)
                        else           perform_trash(init.io, init.gpa, g);
                    }
                }
            }
        }

        const confirm_label = if (permanent) i18n.t(.confirm_delete) else i18n.t(.confirm_move_to_trash);
        if (dvui.button(@src(), confirm_label, .{}, .{ .margin = .all(4) })) {
            self.open = false;
            if (grid) |g| {
                if (dvui.App.main_init) |init| {
                    if (permanent) perform_delete(init.io, init.gpa, g)
                    else           perform_trash(init.io, init.gpa, g);
                }
            }
        }
    }
};
