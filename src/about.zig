//! The About dialog: DiffKeep's version and license, and the licenses of the
//! software it is built from and the models it downloads.
//!
//! `third_party` and `models` are the one list of notices; keep them in step
//! with build.zig.zon, build.zig's system libraries, src/fonts and the model
//! downloads in settings_modal.zig. Names and license identifiers are proper
//! nouns and SPDX ids, the same in every language, so they are not in i18n.

const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const style = @import("style.zig");

pub const Notice = struct {
    name: []const u8,
    /// SPDX identifier (or the license's own name where there is none).
    license: []const u8,
    holder: []const u8,
    /// Empty when the project has no public home.
    url: []const u8 = "",
};

/// Linked into, compiled into, or embedded in the app.
pub const third_party = [_]Notice{
    .{ .name = "dvui", .license = "MIT", .holder = "David Vanderson and contributors", .url = "https://github.com/david-vanderson/dvui" },
    .{ .name = "SDL 3", .license = "Zlib", .holder = "Sam Lantinga", .url = "https://libsdl.org" },
    .{ .name = "HIDAPI (in SDL 3)", .license = "HIDAPI original license", .holder = "Alan Ott, Signal 11 Software", .url = "https://github.com/libusb/hidapi" },
    .{ .name = "yuv2rgb (in SDL 3)", .license = "BSD-3-Clause", .holder = "Adrien Descamps", .url = "https://github.com/descampsa/yuv2rgb" },
    .{ .name = "SQLite", .license = "Public domain", .holder = "D. Richard Hipp", .url = "https://sqlite.org" },
    .{ .name = "sqlite-vec", .license = "MIT OR Apache-2.0", .holder = "Alex Garcia", .url = "https://github.com/asg017/sqlite-vec" },
    .{ .name = "libvips", .license = "LGPL-2.1-or-later", .holder = "John Cupitt and contributors", .url = "https://libvips.org" },
    .{ .name = "FFmpeg (libavformat, libavcodec, libavutil, libswscale, libswresample)", .license = "LGPL-2.1-or-later", .holder = "The FFmpeg developers", .url = "https://ffmpeg.org" },
    .{ .name = "FreeType", .license = "FTL", .holder = "The FreeType Project", .url = "https://freetype.org" },
    .{ .name = "stb_image", .license = "MIT OR Unlicense", .holder = "Sean Barrett", .url = "https://github.com/nothings/stb" },
    .{ .name = "tinyfiledialogs", .license = "Zlib", .holder = "Guillaume Vareille", .url = "https://sourceforge.net/projects/tinyfiledialogs" },
    .{ .name = "tree-sitter", .license = "MIT", .holder = "Max Brunsfeld", .url = "https://tree-sitter.github.io" },
    .{ .name = "TensorPencil", .license = "MIT", .holder = "Quentin Skousen" },
    .{ .name = "known-folders", .license = "MIT", .holder = "ziglibs", .url = "https://github.com/ziglibs/known-folders" },
    .{ .name = "IBM Plex Sans, IBM Plex Mono", .license = "OFL-1.1", .holder = "IBM Corp.", .url = "https://github.com/IBM/plex" },
    .{ .name = "Noto Sans CJK, Noto Emoji", .license = "OFL-1.1", .holder = "Google LLC", .url = "https://github.com/notofonts" },
    .{ .name = "Bitstream Vera Sans", .license = "Bitstream Vera Fonts License", .holder = "Bitstream, Inc.", .url = "https://www.gnome.org/fonts/" },
    .{ .name = "Lucide icons", .license = "ISC AND MIT", .holder = "Lucide contributors; Cole Bemis (Feather)", .url = "https://lucide.dev" },
    .{ .name = "Heroicons", .license = "MIT", .holder = "Tailwind Labs", .url = "https://heroicons.com" },
};

/// Shipped next to the executable (build.zig installs it): the full texts of
/// the licenses listed here. Keep it in step with `third_party`.
pub const license_file_name = "THIRD_PARTY_LICENSES.txt";

pub const gemma_terms_url = "https://ai.google.dev/gemma/terms";

/// Downloaded on request (Settings), never shipped with the app.
pub const models = [_]Notice{
    .{ .name = "EmbeddingGemma 300M", .license = "Gemma Terms of Use", .holder = "Google LLC", .url = gemma_terms_url },
    .{ .name = "SigLIP 2 ViT-B-16", .license = "Apache-2.0", .holder = "Google LLC", .url = "https://huggingface.co/timm/ViT-B-16-SigLIP2" },
};

pub const AboutState = struct {
    open: bool = false,
    /// The app version, set once by app.zig (the build stamps it there).
    version: []const u8 = "dev",

    pub fn render(self: *AboutState) void {
        if (!self.open) return;

        const win = dvui.windowRect();
        var rect = dvui.Rect{ .x = win.w * 0.2, .y = win.h * 0.1, .w = win.w * 0.6, .h = win.h * 0.8 };
        var float = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &self.open,
            .resize = .none,
            .rect = &rect,
        }, .{ .min_size_content = .{ .w = 480, .h = 300 } });
        defer float.deinit();
        float.dragAreaSet(.{});

        var outer = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(20),
            .background = true,
            .color_fill = .{ .color = style.C.chrome },
            .tag = "about-dialog",
        });
        defer outer.deinit();

        style.modalTitle(@src(), i18n.t(.about_heading));
        dvui.label(@src(), "{s} {s}", .{ i18n.t(.about_version), self.version }, .{
            .font = style.F.mono_val,
            .color_text = .{ .color = style.C.text_hi },
            .padding = .{},
        });
        dvui.labelNoFmt(@src(), i18n.t(.about_copyright), .{}, .{
            .color_text = .{ .color = style.C.text_dim },
            .padding = .{},
            .margin = .{ .y = 4, .h = 12 },
        });

        {
            // Takes the room left over, and asks for none: the list must not
            // push the Close button off the dialog.
            var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .expand = .both,
                .max_size_content = dvui.Options.MaxSize.height(0),
                .background = false,
            });
            defer scroll.deinit();

            style.sectionHead(@src(), i18n.t(.about_third_party), .{ .padding = .{}, .margin = .{ .h = 6 } });
            for (third_party, 0..) |n, i| noticeRow(n, i);
            style.sectionHead(@src(), i18n.t(.about_models), .{ .padding = .{}, .margin = .{ .y = 14, .h = 6 } });
            for (models, 0..) |n, i| noticeRow(n, third_party.len + i);
            dvui.labelNoFmt(@src(), i18n.t(.about_full_texts), .{}, .{
                .color_text = .{ .color = style.C.text_dim },
                .padding = .{},
                .margin = .{ .y = 14 },
            });
            dvui.labelNoFmt(@src(), license_file_name, .{}, .{
                .font = style.F.mono,
                .color_text = .{ .color = style.C.text_hi },
                .padding = .{},
            });
        }

        if (dvui.button(@src(), i18n.t(.action_close), .{}, .{ .gravity_x = 1.0, .margin = .{ .y = 12 }, .tag = "about-close" })) {
            self.open = false;
        }
    }
};

fn noticeRow(n: Notice, id: usize) void {
    var row = dvui.box(@src(), .{}, .{ .id_extra = id, .expand = .horizontal, .margin = .{ .h = 6 } });
    defer row.deinit();
    dvui.label(@src(), "{s}  \u{00b7}  {s}", .{ n.name, n.license }, .{
        .color_text = .{ .color = style.C.text_hi },
        .padding = .{},
    });
    const sep: []const u8 = if (n.url.len > 0) "  \u{00b7}  " else "";
    dvui.label(@src(), "{s}{s}{s}", .{ n.holder, sep, n.url }, .{
        .font = style.F.mono,
        .color_text = .{ .color = style.C.text_dim },
        .padding = .{},
    });
}
