//! Bundled fonts and their registration, shared by the app and the headless
//! test harness so named-font lookups ("NotoSansCJKBold") resolve in both
//! instead of logging a fallback error.

const std = @import("std");
const dvui = @import("dvui");

pub const regular_bytes = @embedFile("fonts/NotoSansCJK-Regular.ttc");
pub const bold_bytes = @embedFile("fonts/NotoSansCJK-Bold.ttc");

/// Add the bundled CJK fonts to the current dvui window's font database.
/// Call once after the window exists.
pub fn register() (std.mem.Allocator.Error || dvui.FontError)!void {
    try dvui.addFont("NotoSansCJK", regular_bytes, null);
    try dvui.addFont("NotoSansCJKBold", bold_bytes, null);
}
