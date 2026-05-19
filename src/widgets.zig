const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const icons = @import("icons");

/// Drag handle between two panels.  Click to collapse/expand; drag to resize.
/// `side` controls which direction the handle adjusts (left panel grows .left,
/// right panel grows .right).  Widths are in logical pixels.
pub fn panelHandle(
    src: std.builtin.SourceLocation,
    comptime side: enum { left, right },
    width: *f32,
    width_open: *f32,
    w_min: f32,
    w_max: f32,
) void {
    var h = dvui.box(src, .{}, .{
        .min_size_content = .{ .w = 10, .h = 0 },
        .expand = .vertical,
        .background = true,
    });
    defer h.deinit();

    const id = h.data().id;
    const scale = h.data().contentRectScale().s;

    if (dvui.animationGet(id, "_w")) |anim| {
        width.* = anim.value();
    }

    const collapsed = width.* < 2;
    var is_hovered = dvui.dataGet(null, id, "_hov", bool) orelse false;
    var dragged = dvui.dataGet(null, id, "_drag", bool) orelse false;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .position => {
                is_hovered = dvui.eventMatchSimple(e, h.data());
                if (is_hovered) dvui.cursorSet(.arrow_w_e);
            },
            .press => {
                if (me.button.pointer() and dvui.eventMatchSimple(e, h.data())) {
                    e.handle(@src(), h.data());
                    dvui.captureMouse(h.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .cursor = .arrow_w_e });
                    dragged = false;
                }
            },
            .motion => |delta| {
                if (dvui.captured(id)) {
                    if (dvui.dragging(me.p, null) != null) {
                        const dx: f32 = switch (side) {
                            .left => delta.x,
                            .right => -delta.x,
                        };
                        width.* = std.math.clamp(width.* + dx / scale, w_min, w_max);
                        width_open.* = width.*;
                        dragged = true;
                    }
                }
            },
            .release => {
                if (dvui.captured(id)) {
                    dvui.captureMouse(null, e.num);
                    if (!dragged) {
                        if (collapsed) {
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = @max(width_open.*, w_min),
                                .end_time = 200_000,
                                .easing = dvui.easing.outQuad,
                            });
                        } else {
                            width_open.* = width.*;
                            dvui.animation(id, "_w", dvui.Animation{
                                .start_val = width.*,
                                .end_val = 0,
                                .end_time = 150_000,
                                .easing = dvui.easing.outQuad,
                            });
                        }
                    }
                    dragged = false;
                }
            },
            else => {},
        }
    }

    dvui.dataSet(null, id, "_hov", is_hovered);
    dvui.dataSet(null, id, "_drag", dragged);

    {
        const tvg = switch (side) {
            .left  => if (collapsed) icons.tvg.lucide.@"chevron-right" else icons.tvg.lucide.@"chevron-left",
            .right => if (collapsed) icons.tvg.lucide.@"chevron-left"  else icons.tvg.lucide.@"chevron-right",
        };
        dvui.icon(@src(), "pane_toggle", tvg, .{}, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .min_size_content = .{ .w = 10, .h = 10 },
        });
    }

    const tip = if (collapsed) i18n.t(.pane_click_to_expand) else i18n.t(.pane_drag_to_resize);
    dvui.tooltip(@src(), .{ .active_rect = h.data().rectScale().r, .delay = 500_000 }, "{s}", .{tip}, .{});
}
