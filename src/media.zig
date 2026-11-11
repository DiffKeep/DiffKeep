//! Single source of truth for which file types DiffKeep indexes. Shared by the
//! scanner, the fs watchers, and the grid so their notions of "supported media"
//! can never drift apart.

const std = @import("std");

/// Image extensions (decoded via libvips). PNG and ComfyUI WebP also carry
/// parseable metadata.
pub const image_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".gif" };
/// Video extensions (decoded/probed via libav*).
pub const video_extensions = [_][]const u8{ ".mp4", ".webm" };
/// Image formats that can be multi-frame (checked for animation at scan time).
pub const animatable_extensions = [_][]const u8{ ".gif", ".webp" };

fn hasAnyExt(name: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

pub fn isImageFile(name: []const u8) bool {
    return hasAnyExt(name, &image_extensions);
}

pub fn isVideoFile(name: []const u8) bool {
    return hasAnyExt(name, &video_extensions);
}

/// Any indexable media file (image or video).
pub fn isSupportedMediaFile(name: []const u8) bool {
    return isImageFile(name) or isVideoFile(name);
}

/// A potentially-animated image (gif/webp); worth a frame-count check.
pub fn isAnimatableImage(name: []const u8) bool {
    return hasAnyExt(name, &animatable_extensions);
}

/// The clipboard MIME type for an image file, or null for files that can't be
/// pasted as an image (video).
pub fn imageMimeType(name: []const u8) ?[:0]const u8 {
    if (std.ascii.endsWithIgnoreCase(name, ".png")) return "image/png";
    if (std.ascii.endsWithIgnoreCase(name, ".jpg") or std.ascii.endsWithIgnoreCase(name, ".jpeg")) return "image/jpeg";
    if (std.ascii.endsWithIgnoreCase(name, ".webp")) return "image/webp";
    if (std.ascii.endsWithIgnoreCase(name, ".gif")) return "image/gif";
    return null;
}

test "clipboard MIME type follows the file's format" {
    try std.testing.expectEqualStrings("image/png", imageMimeType("/a/b.PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMimeType("x.jpeg").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMimeType("x.jpg").?);
    try std.testing.expectEqualStrings("image/webp", imageMimeType("x.webp").?);
    try std.testing.expectEqualStrings("image/gif", imageMimeType("x.gif").?);
    try std.testing.expect(imageMimeType("x.mp4") == null);
}

test "media file classification (images, video, animatable, case-insensitive)" {
    const t = std.testing;
    try t.expect(isImageFile("a.png"));
    try t.expect(isImageFile("A.PNG")); // case-insensitive
    try t.expect(isImageFile("x.webp"));
    try t.expect(isImageFile("y.jpeg"));
    try t.expect(!isImageFile("clip.mp4"));

    try t.expect(isVideoFile("clip.mp4"));
    try t.expect(isVideoFile("v.WEBM"));
    try t.expect(!isVideoFile("a.png"));

    try t.expect(isSupportedMediaFile("a.jpg"));
    try t.expect(isSupportedMediaFile("v.mp4"));
    try t.expect(!isSupportedMediaFile("notes.txt"));
    try t.expect(!isSupportedMediaFile("noext"));

    try t.expect(isAnimatableImage("a.gif"));
    try t.expect(isAnimatableImage("a.webp"));
    try t.expect(!isAnimatableImage("a.png")); // static-only formats excluded
    try t.expect(!isAnimatableImage("a.mp4"));
}
