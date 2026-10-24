# DVUI Patterns Reference

Patterns extracted from the pixi project (a mature dvui/Zig 0.16 app) for use in DiffKeep.

---

## Panel Layout & Resizing

### `dvui.paned` with min/max constraints

The `autofit_first` option enforces pixel-based min/max on the first pane, which is what makes
`dvui.paned` usable for sidebars with bounded sizes.

```zig
var split_ratio: f32 = 0.22;

var outer = dvui.paned(@src(), .{
    .direction = .horizontal,
    .collapsed_size = 200,        // auto-collapse when window < 200px
    .split_ratio = &split_ratio,
    .handle_dynamic = .{ .handle_size_max = 8, .distance_max = 30 },
    .handle_margin = 2,
    .autofit_first = .{
        .min_split = 0.15,        // never narrower than 15%
        .max_split = 0.40,        // never wider than 40%
        .min_size = 180,          // absolute pixel floor
    },
}, .{ .expand = .both });
defer outer.deinit();
```

`autofit_first` constrains both the ratio and an absolute pixel minimum — useful for a sidebar
that should never become unusably narrow. The right panel uses a second nested `paned` with its
own `split_ratio`.

### `animateSplit` for smooth collapse/expand

```zig
// Collapse
outer.animateSplit(0.0);

// Expand to saved ratio
outer.animateSplit(saved_ratio);
```

The easing and duration are configurable via `dvui.Animation` stored under `"_split_ratio"` key.
pixi uses `dvui.easing.outQuint` for collapse (faster) and `dvui.easing.outBack` for expand.

---

## Animations

### `dvui.animate` — height/width/alpha transitions

```zig
var anim = dvui.animate(@src(), .{
    .kind = .vertical,          // .vertical, .horizontal, .alpha, or .none
    .duration = 350_000,        // microseconds (350ms)
    .easing = dvui.easing.outBack,
}, .{ .expand = .both });
defer anim.deinit();
```

Used for:
- Tree branch expand/collapse (`.vertical`, clips children to animated height)
- Panel slide-in/out (`.horizontal`)
- Tooltip/menu fade-in (`.alpha`)

For tree branches, pixi clips the children rect to the animated size to prevent overflow:
```zig
const clip_prev = dvui.clip(anim.data().contentRectScale().r);
// ... draw children ...
dvui.clipSet(clip_prev);
```

### Manual animation via `dvui.animation` / `dvui.animationGet`

```zig
dvui.animation(widget_id, "_my_key", dvui.Animation{
    .start_val = current_val,
    .end_val = target_val,
    .end_time = 400_000,
    .easing = dvui.easing.outQuad,
});

// Each frame:
if (dvui.animationGet(widget_id, "_my_key")) |a| {
    current_val = a.value();
}
```

---

## Persistent Widget State

### `dvui.dataGet` / `dvui.dataSet`

dvui's data slots persist across frames (until the widget is gone). Use these for any state
that needs to survive frame boundaries but doesn't belong in app globals.

```zig
// In init:
self.expanded = dvui.dataGet(null, wd.id, "_expanded", bool) orelse default_expanded;

// In deinit:
dvui.dataSet(null, wd.id, "_expanded", self.expanded);
// or remove if no longer needed:
dvui.dataRemove(null, wd.id, "_expanded");
```

---

## Scroll Areas

### Auto-overlay scrollbars

```zig
var scroll = dvui.scrollArea(@src(), .{
    .horizontal_bar = .auto_overlay,   // scrollbar overlays content, appears on hover
    .vertical_bar = .auto_overlay,
}, .{ .expand = .both });
defer scroll.deinit();
```

`.auto_overlay` keeps the content area full-width and fades the bar in/out on hover — much
cleaner than persistent scrollbars for a media browser.

### Edge shadows to indicate overflow

pixi has a custom `drawEdgeShadow` helper that draws a gradient rectangle at a panel edge to
hint that content continues off-screen. We can replicate this with `dvui.pathFillConvex` or
a simple gradient drawn via `dvui.Path`.

```zig
// After scroll.deinit(), query the scroll offset:
if (scroll.si.offset(.vertical) > 0.0) {
    // draw a top-edge gradient shadow over the scroll area rect
}
if (scroll.si.virtual_size.h > scroll.si.viewport.h) {
    // draw bottom-edge shadow
}
```

---

## Icons

### TVG icons with color override

```zig
dvui.icon(@src(), "my_icon", dvui.entypo.folder, .{
    .fill_color = dvui.themeGet().color(.control, .fill),
}, .{
    .min_size_content = .{ .h = 16 },
    .gravity_y = 0.5,
});
```

### Dynamic icon swap (chevron expand/collapse)

```zig
dvui.icon(@src(), "chevron",
    if (expanded) dvui.entypo.@"down-open" else dvui.entypo.@"right-open",
    .{ .fill_color = color },
    .{ .gravity_y = 0.5 });
```

Relevant icons for DiffKeep:
- `dvui.entypo.folder` / `dvui.entypo.@"folder-open"` — library nodes
- `dvui.entypo.@"down-open"` / `dvui.entypo.@"right-open"` — tree chevrons
- `dvui.entypo.search` — search bar
- `dvui.lucide.@"grip-vertical"` — drag handle affordance
- `dvui.lucide.x` — close/remove tags

---

## Theming & Colors

> DiffKeep does not call `themeGet().color(...)` at draw time. The palette lives in
> `src/style.zig` (`style.C`), which also builds the `dvui.Theme` that stock widgets
> pick up. Reach for a named colour (`style.C.rail`, `style.C.amber`) rather than a
> theme slot; the slots below are what `style.theme()` populates.


### Semantic color lookup

```zig
const fill   = dvui.themeGet().color(.control, .fill);
const hover  = dvui.themeGet().color(.control, .fill_hover);
const text   = dvui.themeGet().color(.window, .text);
const accent = dvui.themeGet().color(.highlight, .fill);
const err    = dvui.themeGet().color(.err, .fill);
```

### State-driven color selection

```zig
const color: dvui.Color = if (selected)
    dvui.themeGet().color(.highlight, .fill)
else if (hovered)
    dvui.themeGet().color(.window, .text)
else
    dvui.themeGet().color(.window, .fill);
```

### Adjust brightness for dark/light themes

```zig
const adjusted = base_color.lighten(if (dvui.themeGet().dark) -10 else 10);
```

### Box shadow

```zig
.box_shadow = .{
    .color = .black,
    .alpha = 0.25,
    .offset = .{ .x = 0, .y = 2 },
    .fade = 8,
    .corner_radius = dvui.Rect.all(10),
},
```

---

## Tree View / Hierarchical List

pixi ships a `TreeWidget` (src/editor/widgets/TreeWidget.zig) with full drag-reorder and
multi-selection. For DiffKeep's folder sidebar, the key patterns are:

```zig
var tree = dvui.TreeWidget.tree(@src(), .{}, .{ .expand = .both });
defer tree.deinit();

const branch = tree.branch(@src(), .{
    .expanded = true,
    .animation_duration = 350_000,
    .animation_easing = dvui.easing.outQuad,
}, .{ .id_extra = folder_id, .expand = .horizontal });
defer branch.deinit();

if (branch.expander(@src(), .{ .indent = 20 }, .{ .expand = .both })) {
    // draw children recursively
}
```

`branch.expander()` handles the animated height clip. Children rendered inside it are hidden
when collapsed without any manual height tracking.

---

## Multi-Selection

pixi's `TreeSelection` module handles click-mode dispatch:

```zig
const click_mode = dvui.TreeSelection.clickModeFromMod(
    dvui.currentWindow().modifiers
);
// .replace  — plain click
// .toggle   — Ctrl/Cmd click
// .extend   — Shift click (range from anchor)
```

For the image grid, the same semantics apply: track `selected_ids`, `primary_id`, and
`anchor_id` in app state, then apply click mode on each thumbnail click.

---

## Tooltips

```zig
var tt = dvui.FloatingTooltipWidget.init(@src(), .{
    .active_rect = button.data().rectScale().r,
    .delay = 350_000,    // 350ms hover before showing
}, .{});
defer tt.deinit();

if (tt.shown()) {
    var fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = 200_000 }, .{});
    defer fade.deinit();
    dvui.label(@src(), "tooltip text", .{}, .{});
}
```

---

## Context Menus

```zig
var ctx = dvui.context(@src(),
    .{ .rect = item.data().borderRectScale().r },
    .{});
defer ctx.deinit();

if (ctx.activePoint()) |pt| {
    var menu = dvui.floatingMenu(@src(),
        .{ .from = dvui.Rect.Natural.fromPoint(pt) },
        .{});
    defer menu.deinit();

    if (dvui.menuItemLabel(@src(), "Open in Explorer", .{}, .{ .expand = .horizontal }) != null) {
        // handle action
        menu.close();
    }
}
```

---

## Visual Selection Feedback

For the image grid, pixi uses colored borders + edge shadows between selected and adjacent items.
Preferred pattern for a grid cell:

```zig
var cell = dvui.box(@src(), .{}, .{
    .id_extra = image_id,
    .border = if (selected) dvui.Rect.all(2) else dvui.Rect.all(0),
    .color_border = if (selected) accent_color else .transparent,
    .corner_radius = dvui.Rect.all(4),
});
defer cell.deinit();
```

---

## Floating Dialogs

```zig
var win = dvui.floatingWindow(@src(), .{
    .modal = true,
    .center_on = screen_rect,
    .resize = .all,
}, .{
    .corner_radius = dvui.Rect.all(10),
    .box_shadow = .{ .color = .black, .alpha = 0.35, .fade = 10 },
});
defer win.deinit();

win.autoSize();   // size to content on first frame
```

---

## Text Entry Sizing

### Narrowing an entry needs a height, or it collapses

`TextEntryWidget.init` derives its own `min_size_content` from the font
(`Font.sizeM(14, 1)`), then — for single-line entries only — clamps
`max_size_content` to whatever `min_size_content` ended up being:

```zig
var options = defaults.themeOverride(opts.theme).min_sizeM(defaultMWidth, 1);
options = options.override(opts);                      // your opts REPLACE the computed size
if (!init_opts.multiline and options.max_size_content == null) {
    options = options.override(.{ .max_size_content = .size(options.min_size_contentGet()) });
}
```

Because `override` replaces the whole `min_size_content`, passing only a width
sets the height to 0 — and the clamp then pins the entry to zero content height.
It renders as an empty rounded pill with the text invisible, and nothing errors.

```zig
// WRONG — collapses to an empty pill
.min_size_content = .{ .w = 52 },

// RIGHT — go through the helper, which supplies both from the font
.min_size_content = style.entrySize(style.F.mono_val, 5),
```

Width-only is *sometimes* survivable: `.expand = .horizontal` wins over the
`max_size_content` clamp horizontally, so a full-width entry with
`.min_size_content = .{ .h = 20 }` looks fine. The failure is height-specific.
Simplest rule: on a text entry, either set neither dimension or set both.

### A `textLayout` paints a background by default

`TextLayoutWidget.defaults` has `.background = true` with `.style = .content`, so
a text layout left alone paints a canvas-coloured slab behind itself — which over
a sidebar row or a rail covers the surface it is sitting on. `fonts.richLabel` /
`fonts.richLine` default it to false; a plain `dvui.textLayout` needs
`.background = false` explicitly.

