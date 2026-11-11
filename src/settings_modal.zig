const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("i18n.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const image_grid_mod = @import("image_grid.zig");
const detail_panel_mod = @import("detail_panel.zig");
const library_manager_mod = @import("library_manager.zig");
const search_mod = @import("search.zig");
const image_ops = @import("image_ops.zig");
const style = @import("style.zig");
const fonts = @import("fonts.zig");

const log = std.log.scoped(.settings);

// Shared presets, so every field in the two columns is built the same way.

/// A sunken, hairlined text field — the same skin as the toolbar's search box.
const input_opts: dvui.Options = .{
    .expand = .horizontal,
    .background = true,
    .color_fill = .{ .color = style.C.sunken },
    .border = style.Edge.all,
    .color_border = .{ .color = style.hairline_hi },
    .corners = style.R.button,
    .padding = .{ .x = 9, .y = 6, .w = 9, .h = 6 },
    .font = style.F.input,
    .margin = .{ .h = 4 },
};

/// A compact secondary action sitting beside a field or a stat row.
const small_button: dvui.Options = .{
    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
    .corners = style.R.button,
    .font = style.F.ui,
};

/// A field caption. Uppercase mono, because the settings screen is a list of
/// things to find rather than text to read, and a head that scans beats a head
/// that reads.
fn fieldHead(src: std.builtin.SourceLocation, text: []const u8, top: f32) void {
    style.sectionHead(src, text, .{ .padding = .{}, .margin = .{ .y = top, .h = 6 } });
}

/// "A background job is running" — the same amber spinner-and-caption the
/// status bar uses, so the two read as one language.
fn runningLine(src: std.builtin.SourceLocation, text: []const u8) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer line.deinit();
    _ = dvui.spinner(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 12, .h = 12 },
        .color_text = .{ .color = style.C.amber },
    });
    dvui.label(@src(), "{s}", .{text}, .{
        .gravity_y = 0.5,
        .margin = .{ .x = 6 },
        .font = style.F.mono,
        .color_text = .{ .color = style.C.amber },
    });
}

// HuggingFace download sources for the bundled models.
// Text encoder: EmbeddingGemma 300m (native-Zig via TensorPencil, loads
// safetensors). unsloth is the ungated mirror of google/embeddinggemma-300m.
const gemma_hf_base = "https://huggingface.co/unsloth/embeddinggemma-300m/resolve/main";
const gemma_dir_name = "embeddinggemma-300m";
const gemma_dl_files = [_][]const u8{
    "tokenizer.json",
    "model.safetensors",
    "2_Dense/model.safetensors",
    "3_Dense/model.safetensors",
};

// Visual + cross-modal-text encoder: SigLIP2 ViT-B-16 (native-Zig via
// TensorPencil, loads the open_clip safetensors — both towers in one file).
// timm is the source for the open_clip checkpoint + tokenizer.
const siglip2_hf_base = "https://huggingface.co/timm/ViT-B-16-SigLIP2/resolve/main";
const siglip2_dir_name = "ViT-B-16-SigLIP2-timm";
const siglip2_dl_files = [_][]const u8{ "open_clip_model.safetensors", "tokenizer.json" };

/// One model download, run by a detached thread. The thread touches nothing
/// but this struct (thread-safe C heap, never the app allocator or UI
/// buffers), so it may outlive the settings screen, or even app shutdown while
/// curl runs; the main thread reads the result once `done` is set and then
/// frees it (`take`).
const Download = struct {
    const a = std.heap.c_allocator;

    io: std.Io,
    target_dir: []u8, // owned
    hf_base: []const u8, // static
    files: []const []const u8, // static
    wakeup_fn: ?*const fn () void,
    ok: bool = false, // valid once `done`
    done: std.atomic.Value(bool) = .init(false),

    fn start(io: std.Io, data_dir: []const u8, model_dir_name: []const u8, hf_base: []const u8, files: []const []const u8, wakeup_fn: ?*const fn () void) ?*Download {
        const target_dir = std.mem.concat(a, u8, &.{ data_dir, "/models/", model_dir_name }) catch return null;
        const d = a.create(Download) catch {
            a.free(target_dir);
            return null;
        };
        d.* = .{
            .io = io,
            .target_dir = target_dir,
            .hf_base = hf_base,
            .files = files,
            .wakeup_fn = wakeup_fn,
        };
        const t = std.Thread.spawn(.{}, run, .{d}) catch |err| {
            log.warn("spawn download thread: {}", .{err});
            a.free(d.target_dir);
            a.destroy(d);
            return null;
        };
        t.detach();
        return d;
    }

    /// Main thread, after `done`: the downloaded model dir (owned by the
    /// caller's `gpa`), or null on failure. Frees the job.
    fn take(d: *Download, gpa: std.mem.Allocator) ?[]u8 {
        defer {
            a.free(d.target_dir);
            a.destroy(d);
        }
        if (!d.ok) return null;
        return gpa.dupe(u8, d.target_dir) catch null;
    }

    fn run(d: *Download) void {
        d.ok = d.fetchAll();
        const wake = d.wakeup_fn; // `d` may be freed once `done` is set
        d.done.store(true, .release);
        if (wake) |w| w();
    }

    fn fetchAll(d: *Download) bool {
        for (d.files) |rel_path| {
            const out_path = std.mem.concat(a, u8, &.{ d.target_dir, "/", rel_path }) catch return false;
            defer a.free(out_path);
            // Download beside the target and rename into place, so an
            // interrupted download never leaves a truncated model file.
            const part = std.mem.concat(a, u8, &.{ out_path, ".part" }) catch return false;
            defer a.free(part);
            const url = std.mem.concat(a, u8, &.{ d.hf_base, "/", rel_path }) catch return false;
            defer a.free(url);

            const result = std.process.run(a, d.io, .{
                .argv = &.{ "curl", "-L", "-f", "-s", "-S", "--create-dirs", "-o", part, url },
            }) catch |err| {
                log.warn("curl spawn failed for {s}: {}", .{ url, err });
                return false;
            };
            a.free(result.stdout);
            a.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) {
                log.warn("curl failed (exit {}) for {s}", .{ result.term, url });
                std.Io.Dir.cwd().deleteFile(d.io, part) catch {};
                return false;
            }
            const cwd = std.Io.Dir.cwd();
            std.Io.Dir.rename(cwd, part, cwd, out_path, d.io) catch |err| {
                log.warn("install {s}: {}", .{ rel_path, err });
                return false;
            };
        }
        return true;
    }
};

pub const ScanSnapshot = struct {
    thumbnails_in_db: bool = false,
    prompt_embeddings: bool = false,
    image_embeddings: bool = false,
};

pub const SettingsModalState = struct {
    open: bool = false,
    scan_snapshot: ScanSnapshot = .{},
    model_snapshot: struct {
        text_dir:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
        visual_dir: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    } = .{},
    gpu_snapshot: struct {
        backend: config_mod.GpuBackend = .cuda,
        threshold: usize = 4,
    } = .{},
    text_model_dir_buf:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    visual_model_dir_buf: [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    data_path_buf:        [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    data_path_snapshot:   [4096:0]u8 = std.mem.zeroes([4096:0]u8),
    /// Set to true by onClosed() or applyCompletedDownloads() when model paths changed; cleared by app.zig.
    model_paths_changed: bool = false,
    /// "Empty trash" was clicked; app.zig asks for confirmation (it deletes
    /// files for good), like the toolbar's trash-view button does.
    empty_trash_requested: bool = false,

    gemma_dl: ?*Download = null,
    siglip2_dl: ?*Download = null,

    pub fn initFromConfig(self: *SettingsModalState, cfg: *const config_mod.Config) void {
        if (cfg.text_model_dir) |p| {
            const len = @min(p.len, self.text_model_dir_buf.len - 1);
            @memcpy(self.text_model_dir_buf[0..len], p[0..len]);
            self.text_model_dir_buf[len] = 0;
        }
        if (cfg.visual_model_dir) |p| {
            const len = @min(p.len, self.visual_model_dir_buf.len - 1);
            @memcpy(self.visual_model_dir_buf[0..len], p[0..len]);
            self.visual_model_dir_buf[len] = 0;
        }
        if (cfg.data_path) |p| {
            const len = @min(p.len, self.data_path_buf.len - 1);
            @memcpy(self.data_path_buf[0..len], p[0..len]);
            self.data_path_buf[len] = 0;
        }
    }

    pub fn render(
        self: *SettingsModalState,
        cfg: *config_mod.Config,
        db_stats: *?db_mod.DbStats,
        trash_stats: *?db_mod.TrashStats,
        data_dir: ?[]const u8,
        db: ?*db_mod.VectorDb,
        wakeup_fn: ?*const fn () void,
    ) !void {
        if (!self.open) return;

        const win = dvui.windowRect();
        const margin_x = @max(60, win.w * 0.07);
        const margin_y = @max(40, win.h * 0.07);
        var modal_rect = dvui.Rect{
            .x = margin_x,
            .y = margin_y,
            .w = win.w - 2 * margin_x,
            .h = win.h - 2 * margin_y,
        };
        var float = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &self.open,
            .resize = .none,
            .rect = &modal_rect,
        }, .{
            .min_size_content = .{ .w = 600, .h = 300 },
        });
        defer float.deinit();
        float.dragAreaSet(.{});

        var outer = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = .all(20),
            .background = true,
            .color_fill = .{ .color = style.C.chrome },
        });
        defer outer.deinit();

        style.modalTitle(@src(), i18n.t(.settings_heading));

        {
            var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .expand = .both,
                .max_size_content = dvui.Options.MaxSize.height(0),
                .background = false,
            });
            defer scroll.deinit();

            var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer cols.deinit();

            // ── Left column ───────────────────────────────────────────────────
            {
                var left_col = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 280 },
                    .padding = .{ .w = 12 },
                });
                defer left_col.deinit();

                fieldHead(@src(), i18n.t(.settings_scan_section), 0);
                _ = dvui.checkbox(@src(), &cfg.thumbnails_in_db, i18n.t(.settings_thumbnails_in_db), .{ .margin = .{ .h = 6 } });
                _ = dvui.checkbox(@src(), &cfg.prompt_embeddings, i18n.t(.settings_prompt_embeddings), .{ .margin = .{ .h = 6 } });
                _ = dvui.checkbox(@src(), &cfg.image_embeddings, i18n.t(.settings_image_embeddings), .{ .margin = .{ .h = 6 } });

                fieldHead(@src(), i18n.t(.settings_model_path), 14);
                {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = self.text_model_dir_buf[0..] },
                        .placeholder = i18n.t(.settings_model_placeholder),
                    }, input_opts);
                    defer te.deinit();
                }
                {
                    var dl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 4 } });
                    defer dl_row.deinit();
                    if (self.gemma_dl != null) {
                        runningLine(@src(), i18n.t(.settings_download_running));
                    } else {
                        if (dvui.button(@src(), i18n.t(.settings_download_text_model), .{}, small_button)) {
                            if (dvui.App.main_init) |init| {
                                if (data_dir) |dd| self.gemma_dl = Download.start(init.io, dd, gemma_dir_name, gemma_hf_base, &gemma_dl_files, wakeup_fn);
                            }
                        }
                    }
                }

                fieldHead(@src(), i18n.t(.settings_mmproj_path), 10);
                {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = self.visual_model_dir_buf[0..] },
                        .placeholder = i18n.t(.settings_mmproj_placeholder),
                    }, input_opts);
                    defer te.deinit();
                }
                {
                    var dl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .h = 4 } });
                    defer dl_row.deinit();
                    if (self.siglip2_dl != null) {
                        runningLine(@src(), i18n.t(.settings_download_running));
                    } else {
                        if (dvui.button(@src(), i18n.t(.settings_download_siglip2), .{}, small_button)) {
                            if (dvui.App.main_init) |init| {
                                if (data_dir) |dd| self.siglip2_dl = Download.start(init.io, dd, siglip2_dir_name, siglip2_hf_base, &siglip2_dl_files, wakeup_fn);
                            }
                        }
                    }
                }

                fieldHead(@src(), i18n.t(.settings_backend_section), 16);
                {
                    // Enum tags map 1:1 to indices: none=0(CPU), vulkan=1, cuda=2.
                    var backend_idx: usize = @backingInt(cfg.embed_gpu_backend);
                    const backend_names = [_][]const u8{ i18n.t(.settings_backend_cpu), "Vulkan", "CUDA" };
                    if (dvui.dropdown(@src(), &backend_names, .{ .choice = &backend_idx }, .{}, .{
                        .margin = .{ .h = 6 },
                        .min_size_content = .{ .w = 120, .h = 22 },
                        .corners = style.R.button,
                        .font = style.F.ui,
                    })) {
                        cfg.embed_gpu_backend = @fromBackingInt(@intCast(backend_idx));
                    }
                }
                if (cfg.embed_gpu_backend != .none) {
                    var thr_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .h = 4 },
                    });
                    defer thr_row.deinit();
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_gpu_threshold)}, .{
                        .gravity_y = 0.5,
                        .margin = .{ .w = 8 },
                        .color_text = .{ .color = style.C.text_dim },
                    });
                    // Narrowing an entry has to go through `entrySize`; see the
                    // comment on it for why a bare width collapses the field.
                    _ = dvui.textEntryNumber(@src(), usize, .{ .value = &cfg.embed_gpu_threshold, .min = 1 },
                        input_opts.override(.{
                            .expand = .none,
                            .gravity_y = 0.5,
                            .min_size_content = style.entrySize(style.F.mono_val, 5),
                            .margin = .{},
                            .font = style.F.mono_val,
                        }));
                }

                fieldHead(@src(), i18n.t(.settings_trash_section), 22);
                _ = dvui.checkbox(@src(), &cfg.trash_enabled, i18n.t(.settings_trash_enable), .{ .margin = .{ .h = 6 } });
                if (cfg.trash_enabled) {
                    if (trash_stats.*) |ts| {
                        const tb = detail_panel_mod.fmtBytes(ts.total_bytes);
                        var trash_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .expand = .horizontal,
                            .margin = .{ .h = 6 },
                        });
                        defer trash_row.deinit();
                        dvui.label(@src(), "{d} {s} ({d:.1} {s})", .{ ts.count, i18n.t(.settings_items), tb.value, tb.unit }, .{
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                            .font = style.F.mono,
                            .color_text = .{ .color = style.C.text_dim },
                        });
                        // Emptying the trash deletes the files for good.
                        if (dvui.button(@src(), i18n.t(.settings_empty_trash), .{},
                            small_button.override(.{ .gravity_y = 0.5, .style = .err }))) {
                            self.empty_trash_requested = true;
                        }
                    }
                }

                fieldHead(@src(), i18n.t(.settings_data_path), 18);
                {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = self.data_path_buf[0..] },
                        .placeholder = i18n.t(.settings_data_path_placeholder),
                    }, input_opts);
                    defer te.deinit();
                }
                // Show where data currently lives so an empty (default) field is unambiguous.
                if (data_dir) |dd| {
                    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 6 } });
                    defer line.deinit();
                    dvui.label(@src(), "{s} ", .{i18n.t(.settings_data_path_default)}, .{
                        .gravity_y = 0.5,
                        .font = style.F.mono,
                        .color_text = .{ .color = style.C.text_faint },
                    });
                    // A path is arbitrary filesystem data, so it goes through
                    // the run splitter rather than a plain label.
                    fonts.richLine(@src(), dd, .{
                        .gravity_y = 0.5,
                        .expand = .horizontal,
                        .font = style.F.mono,
                        .color_text = .{ .color = style.C.text_dim },
                    });
                }
                dvui.label(@src(), "{s}", .{i18n.t(.settings_data_path_warning)}, .{
                    .color_text = .{ .color = style.C.danger },
                });
            }

            // A hairline between the columns, so the two groups read as two
            // rather than as one list that happens to wrap.
            style.vsep(@src());

            // ── Right column ──────────────────────────────────────────────────
            {
                var right_col = dvui.box(@src(), .{}, .{
                    .expand = .both,
                    .min_size_content = .{ .w = 280 },
                    .padding = .{ .x = 12 },
                });
                defer right_col.deinit();

                fieldHead(@src(), i18n.t(.settings_database_section), 0);
                if (db_stats.*) |stats| {
                    const total = detail_panel_mod.fmtBytes(stats.total_bytes);
                    dvui.label(@src(), "{s}{d:.1} {s}", .{ i18n.t(.settings_db_total_size_label), total.value, total.unit }, .{
                        .margin = .{ .h = 12 },
                        .font = style.F.mono_val,
                        .color_text = .{ .color = style.C.text_hi },
                    });

                    const db_label_keys = [_]std.meta.FieldEnum(i18n.Strings){
                        .settings_db_thumbnails_label,
                        .settings_db_prompt_embeddings_label,
                        .settings_db_image_embeddings_label,
                    };
                    const db_rows = [_]struct {
                        count: i64,
                        bytes: i64,
                        clear_fn: *const fn (*db_mod.VectorDb) anyerror!void,
                    }{
                        .{ .count = stats.thumbnail_count,        .bytes = stats.thumbnail_bytes,                   .clear_fn = db_mod.VectorDb.clearThumbnails },
                        .{ .count = stats.prompt_embedding_count, .bytes = stats.prompt_embedding_count * 768 * 4,  .clear_fn = db_mod.VectorDb.clearPromptEmbeddings },
                        .{ .count = stats.image_embedding_count,  .bytes = stats.image_embedding_count * 768 * 4,   .clear_fn = db_mod.VectorDb.clearImageEmbeddings },
                    };
                    inline for (db_label_keys, db_rows, 0..) |label_key, r, ri| {
                        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = ri,
                            .expand = .horizontal,
                            .margin = .{ .h = 6 },
                        });
                        defer row.deinit();
                        const sz = detail_panel_mod.fmtBytes(r.bytes);
                        dvui.label(@src(), "{s}{d} ({d:.1} {s})", .{ i18n.t(label_key), r.count, sz.value, sz.unit }, .{
                            .id_extra = ri,
                            .expand = .horizontal,
                            .gravity_y = 0.5,
                            .font = style.F.mono,
                            .color_text = .{ .color = style.C.text_dim },
                        });
                        // Clearing a cache throws away derived data that has to
                        // be recomputed, so it reads as destructive.
                        if (dvui.button(@src(), i18n.t(.action_clear), .{}, small_button.override(.{
                            .id_extra = ri,
                            .gravity_y = 0.5,
                            .style = .err,
                        }))) {
                            if (db) |d| {
                                r.clear_fn(d) catch {};
                                db_stats.* = d.getStats() catch null;
                            }
                        }
                    }
                } else {
                    dvui.label(@src(), "{s}", .{i18n.t(.settings_db_no_database)}, .{
                        .color_text = .{ .color = style.C.text_ghost },
                    });
                }
            }
        }

        {
            style.hsep(@src());
            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .margin = .{ .y = 4 } });
            defer btn_row.deinit();
            // Settings apply as they are changed, so Close is the only exit and
            // therefore the primary — there is nothing here to cancel.
            if (style.primaryButton(@src(), i18n.t(.action_close), .{ .margin = .all(4) })) {
                self.open = false;
            }
        }
    }

    /// Main thread, each frame: apply finished model downloads. The path goes
    /// into the settings field; when the screen is closed it is applied to the
    /// config right away (onClosed handles it when open).
    pub fn applyCompletedDownloads(self: *SettingsModalState, cfg: *config_mod.Config, data_dir: ?[]const u8) void {
        _ = data_dir;
        const init = dvui.App.main_init orelse return;
        inline for (.{ .{ "gemma_dl", "text_model_dir_buf", "text_model_dir" }, .{ "siglip2_dl", "visual_model_dir_buf", "visual_model_dir" } }) |f| {
            if (@field(self, f[0])) |d| if (d.done.load(.acquire)) {
                @field(self, f[0]) = null;
                if (d.take(init.gpa)) |dir| {
                    defer init.gpa.free(dir);
                    const buf = &@field(self, f[1]);
                    const len = @min(dir.len, buf.len - 1);
                    @memcpy(buf[0..len], dir[0..len]);
                    buf[len] = 0;
                    if (!self.open) {
                        if (@field(cfg, f[2])) |p| init.gpa.free(p);
                        @field(cfg, f[2]) = init.gpa.dupe(u8, buf[0..len]) catch null;
                        self.model_paths_changed = true;
                    }
                }
            };
        }
    }

    pub fn onClosed(
        self: *SettingsModalState,
        cfg: *config_mod.Config,
        library_manager: *?library_manager_mod.LibraryManager,
        search: *search_mod.SearchState,
    ) void {
        _ = search;
        var need_rescan = false;

        const changed = cfg.thumbnails_in_db != self.scan_snapshot.thumbnails_in_db or
            cfg.prompt_embeddings != self.scan_snapshot.prompt_embeddings or
            cfg.image_embeddings != self.scan_snapshot.image_embeddings;
        if (changed) {
            if (library_manager.*) |*mgr| {
                mgr.thumbnails_in_db = cfg.thumbnails_in_db;
                mgr.prompt_embeddings = cfg.prompt_embeddings;
                mgr.image_embeddings = cfg.image_embeddings;
            }
            need_rescan = true;
        }

        const model_changed =
            !std.mem.eql(u8, &self.text_model_dir_buf, &self.model_snapshot.text_dir) or
            !std.mem.eql(u8, &self.visual_model_dir_buf, &self.model_snapshot.visual_dir);
        if (model_changed) {
            if (dvui.App.main_init) |init| {
                if (cfg.text_model_dir) |p| init.gpa.free(p);
                const text_str = std.mem.sliceTo(&self.text_model_dir_buf, 0);
                cfg.text_model_dir = if (text_str.len > 0) init.gpa.dupe(u8, text_str) catch null else null;
                if (cfg.visual_model_dir) |p| init.gpa.free(p);
                const visual_str = std.mem.sliceTo(&self.visual_model_dir_buf, 0);
                cfg.visual_model_dir = if (visual_str.len > 0) init.gpa.dupe(u8, visual_str) catch null else null;
            }
            self.model_paths_changed = true;
            if (cfg.prompt_embeddings or cfg.image_embeddings) need_rescan = true;
        }

        const gpu_changed = cfg.embed_gpu_backend != self.gpu_snapshot.backend or
            cfg.embed_gpu_threshold != self.gpu_snapshot.threshold;
        if (gpu_changed) {
            self.model_paths_changed = true;
        }

        // The data path only takes effect on the next launch (the DB and all
        // derived directories are opened once at startup), so just persist it
        // into the config here — no live re-init or rescan.
        if (!std.mem.eql(u8, &self.data_path_buf, &self.data_path_snapshot)) {
            if (dvui.App.main_init) |init| {
                if (cfg.data_path) |p| init.gpa.free(p);
                const data_str = std.mem.sliceTo(&self.data_path_buf, 0);
                cfg.data_path = if (data_str.len > 0) init.gpa.dupe(u8, data_str) catch null else null;
            }
        }

        if (need_rescan) {
            if (library_manager.*) |*mgr| {
                if (dvui.App.main_init) |init| {
                    mgr.scanAllLibraries(init.io) catch |err| {
                        std.log.warn("rescan after config change: {}", .{err});
                    };
                }
            }
        }
    }
};
