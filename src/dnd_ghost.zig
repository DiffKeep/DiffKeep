const std = @import("std");
const vips = @import("vips");

pub const DragItem = struct {
    path:       []const u8,
    thumb_jpeg: []const u8,
};

pub const GhostResult = struct { pixels: []u8, width: u32, height: u32 };

const ghost_thumb_px: c_int = 96;
const ghost_offset_px: u32  = 5;

/// Returns a heap-allocated RGBA canvas, or null if no thumbnails decoded.
/// Caller frees the pixels slice with allocator.free().
pub fn composeGhost(allocator: std.mem.Allocator, items: []const DragItem) ?GhostResult {
    const n: u32 = @intCast(@min(items.len, 3));
    if (n == 0) return null;

    const thumb_px: u32 = @intCast(ghost_thumb_px);
    const canvas_w = thumb_px + (n - 1) * ghost_offset_px;
    const canvas_h = canvas_w;

    const canvas = allocator.alloc(u8, canvas_w * canvas_h * 4) catch return null;
    @memset(canvas, 0);

    var layer: usize = n;
    while (layer > 0) {
        layer -= 1;
        if (items[layer].thumb_jpeg.len == 0) continue;

        const dec = vips.jpegBytesToRgba(allocator, items[layer].thumb_jpeg, ghost_thumb_px)
            catch continue;
        defer allocator.free(dec.pixels);

        const tw = dec.width;
        const th = dec.height;
        const box_x: u32 = @as(u32, @intCast(layer)) * ghost_offset_px;
        const box_y: u32 = box_x;
        const pad_x: u32 = (thumb_px - @min(tw, thumb_px)) / 2;
        const pad_y: u32 = (thumb_px - @min(th, thumb_px)) / 2;

        for (0..th) |row| {
            for (0..tw) |col| {
                const si = (row * tw + col) * 4;
                const sa: u32 = dec.pixels[si + 3];
                if (sa == 0) continue;

                const dx = box_x + pad_x + col;
                const dy = box_y + pad_y + row;
                if (dx >= canvas_w or dy >= canvas_h) continue;

                const di = (dy * canvas_w + dx) * 4;
                const da: u32 = canvas[di + 3];
                const na: u32 = sa + da * (255 - sa) / 255;
                if (na == 0) continue;
                canvas[di + 0] = @intCast((@as(u32, dec.pixels[si + 0]) * sa + @as(u32, canvas[di + 0]) * da * (255 - sa) / 255) / na);
                canvas[di + 1] = @intCast((@as(u32, dec.pixels[si + 1]) * sa + @as(u32, canvas[di + 1]) * da * (255 - sa) / 255) / na);
                canvas[di + 2] = @intCast((@as(u32, dec.pixels[si + 2]) * sa + @as(u32, canvas[di + 2]) * da * (255 - sa) / 255) / na);
                canvas[di + 3] = @intCast(na);
            }
        }
    }

    for (0..canvas_w * canvas_h) |px| {
        if (canvas[px * 4 + 3] != 0) return .{ .pixels = canvas, .width = canvas_w, .height = canvas_h };
    }
    allocator.free(canvas);
    return null;
}
