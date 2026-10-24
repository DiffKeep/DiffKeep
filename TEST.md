# TEST.md — DiffKeep Testing Plan

## Overview

Two test layers, both run via `zig build test`:

| Layer | Root | Backend | What it covers |
|---|---|---|---|
| Unit | `src/test.zig` | none (pure Zig) | Logic with no external deps |
| Integration | `tests/integration.zig` | `dvui .testing` | Headless dvui, in-memory DB, widget behaviour |

---

## Layer 1 — Pure Logic Unit Tests

**Entry point:** `src/test.zig` (already wired to `zig build test`)

The file currently imports only `parse/comfy.zig`. Expand it to cover every module
that has no external C dependencies:

```zig
// src/test.zig
pub const comfy_parser  = @import("parse/comfy.zig");
pub const config        = @import("config.zig");
pub const models        = @import("models.zig");
// Add more pure modules here as they accumulate tests.

test { @import("std").testing.refAllDecls(@This()); }
```

Good candidates for standalone `test` blocks inside their own files:
- `src/config.zig` — `Config` key=value parse/round-trip, unknown-key tolerance, missing-file defaults
- `src/models.zig` — data-struct invariants if any
- `src/parse/comfy.zig` — already has tests; add edge-case fixtures as they're found

**Rule:** if a module's test block needs `libvips`, `libllama`, or `libsqlite` it does
not belong in this layer.

---

## Layer 2 — Headless dvui Integration Tests

### How dvui's testing backend works

dvui ships a `src/backends/testing.zig` that implements the full `Backend` interface
with no SDL, no GPU, and no OS window.  `dvui.testing.init()` gives you a real
`dvui.Window` with a deterministic clock and a simulated 600×400 screen.

```zig
var t = try dvui.testing.init(.{ .allocator = gpa });
defer t.deinit();
// t.window is a live *dvui.Window
```

Running frames and injecting input:
```zig
try dvui.testing.settle(my_frame_fn);   // run frames until dvui.refresh() is not called
try t.moveTo("my-tag");                 // move mouse to centre of tagged widget
try t.click(.left);                     // press + release
try t.writeText("hello");               // text input
try t.pressKey(.tab, .{});
```

Assertions:
```zig
try t.expectVisible("toolbar");
try t.expectFocused("search-box");
try t.tagGet("some-tag");               // returns TagData{.rect, .visible, .id}
```

Widgets are found by name.  Tag a widget inside the frame function with:
```zig
dvui.tag("my-tag", .{});   // call this anywhere a widget is in scope
```

Snapshot / regression testing:
```zig
try t.snapshot(@src(), frame_fn);       // hash widget state; DVUI_SNAPSHOT_WRITE=1 to seed
```

### Build.zig changes

Add a second dvui dependency compiled against the testing backend, then wire a new
integration test executable that imports it.

```zig
// build.zig additions (after the existing dvui_dep block)

const dvui_testing_dep = b.dependency("dvui", .{
    .target  = target,
    .optimize = optimize,
    .backend = .testing,
});

// Module rooted at the library entry point (see app.zig refactor below).
// Wire it with the testing backend so every @import("dvui") inside resolves
// to the headless backend.
const diffkeep_test_module = b.createModule(.{
    .target          = target,
    .optimize        = optimize,
    .root_source_file = b.path("src/diffkeep.zig"),  // see §App.zig refactor
});
diffkeep_test_module.addImport("dvui",          dvui_testing_dep.module("dvui_testing"));
diffkeep_test_module.addImport("backend",       dvui_testing_dep.module("testing"));
diffkeep_test_module.addImport("known-folders", known_folders);
diffkeep_test_module.addImport("sqlite",        sqlite_module_zig);
diffkeep_test_module.addImport("icons",         icons_dep.module("icons"));
// vips and llama: link them even though most tests won't call them.
// The test binary is larger but no stubs are needed.

const integration_module = b.addModule("diffkeep-integration-tests", .{
    .target           = target,
    .optimize         = optimize,
    .root_source_file = b.path("tests/integration.zig"),
});
integration_module.addImport("diffkeep", diffkeep_test_module);
integration_module.addImport("dvui",     dvui_testing_dep.module("dvui_testing"));

const integration_tests = b.addTest(.{
    .name        = "diffkeep-integration-tests",
    .root_module = integration_module,
});
integration_tests.root_module.link_libcpp = true;
// Re-use the same sqlite_lib and vips_helper_lib already built above.
integration_tests.root_module.linkLibrary(sqlite_lib);
integration_tests.root_module.addIncludePath(b.path("lib/sqlite"));
integration_tests.root_module.addIncludePath(b.path("lib/sqlite-vec"));
integration_tests.root_module.linkLibrary(vips_helper_lib);
integration_tests.root_module.addIncludePath(b.path("lib/vips"));
integration_tests.root_module.linkSystemLibrary("vips", .{});
// llama + mtmd: call addLlama / addMtmd the same way the main exe does.

test_step.dependOn(&b.addRunArtifact(integration_tests).step);
```

### The shim (`tests/diffkeep_shim.zig`)

Modelled directly on pixi's `tests/pixi_shim.zig`.  The shim does the minimum
work required to make DiffKeep's global state safe to call:

```zig
// tests/diffkeep_shim.zig
const std     = @import("std");
const dvui    = @import("dvui");
const app_mod = @import("diffkeep");  // the library module

pub const Ctx = struct {
    t:   dvui.testing,
    cfg: app_mod.Config,
    db:  app_mod.VectorDb,

    pub fn deinit(self: *Ctx) void {
        self.db.deinit();
        self.t.deinit();
    }
};

pub fn init(gpa: std.mem.Allocator) !Ctx {
    var t = try dvui.testing.init(.{ .allocator = gpa });
    errdefer t.deinit();

    // In-memory SQLite — no disk, no cleanup.
    var db = try app_mod.VectorDb.open(gpa, ":memory:");
    errdefer db.deinit();

    // Minimal config — all defaults, no file I/O.
    const cfg = app_mod.Config{};

    // Wire globals that tests read.
    app_mod.g_cfg    = cfg;
    app_mod.g_db     = &db;
    // Leave g_grid / g_library_manager zero-initialised; set fields per test
    // as needed rather than expanding the shim.

    return .{ .t = t, .cfg = cfg, .db = db };
}
```

**Convention (borrowed from pixi):** if a new test fails because some global is
zero/null/empty, set just that field at the top of that test.  Do not expand
the shim for every new need.

### Tests to write first

Good first integration tests — they exercise real code paths, need a live dvui
window, but don't require vips or llama:

1. **DB migrations** — `VectorDb.open(":memory:")` applies all migrations without
   error; key tables and columns exist afterwards.

2. **Config round-trip** — `Config.saveToFile` + `Config.loadFromFile` preserves
   every field (use a temp file or an in-memory writer).

3. **GridState renders on empty library** — call the grid frame sub-function with
   zero images; assert no crash and the placeholder text is visible.

4. **Metadata panel shows/hides on selection** — select an image ID, assert the
   panel widget is visible; deselect, assert hidden.  Requires dvui tagging in
   the frame function (see below).

5. **Search box accepts input and fires a query** — `t.moveTo("search-box")`,
   `t.click(.left)`, `t.writeText("cat")`, settle, assert results widget
   visible.

---

## App.zig Refactor — Making the UI Testable

### Current state

`src/app.zig` is the executable root.  It owns all globals and has one large
`frame()` function that renders the entire UI inline.  There is no separate
library module, so there is nothing to import from tests.

### Target state

Split into two files:

```
src/
  app.zig          — thin executable entry point: main(), appInit/appDeinit,
                     wires dvui callbacks, owns global variables, calls into lib
  diffkeep.zig     — library root: re-exports all testable modules and public
                     types; this is what tests import
```

`diffkeep.zig` re-exports everything tests need:
```zig
// src/diffkeep.zig
pub const Config         = @import("config.zig").Config;
pub const VectorDb       = @import("db.zig").VectorDb;
pub const GridState      = @import("image_grid.zig").GridState;
pub const LibraryManager = @import("library_manager.zig").LibraryManager;
pub const Image          = @import("models.zig").Image;
pub const Library        = @import("models.zig").Library;

// Global state pointers — the shim sets these before tests run.
pub var g_cfg:             Config          = .{};
pub var g_db:              ?*VectorDb      = null;
pub var g_grid:            ?*GridState     = null;
pub var g_library_manager: ?*LibraryManager = null;
```

`app.zig` imports `diffkeep.zig` as `const dk = @import("diffkeep.zig")` and
accesses globals through it.

### Frame function decomposition

The large inline `frame()` in `app.zig` should be broken into sub-functions,
each of which takes its inputs explicitly and can be called from a test frame:

```zig
// Suggested split (approximate)
fn renderToolbar(cfg: *Config, search_state: *SearchState) !void { ... }
fn renderSidebar(libraries: []const Library, selection: *SidebarState) !void { ... }
fn renderGrid(grid: *GridState) !void { ... }
fn renderMetadataPanel(image: ?*const Image) !void { ... }
fn renderStatusBar(status: StatusLine) !void { ... }
```

A test frame then calls whichever sub-functions it cares about:

```zig
fn frame() !dvui.App.Result {
    try diffkeep.renderToolbar(&ctx.cfg, &search_state);
    return .ok;
}
try dvui.testing.settle(frame);
try t.expectVisible("search-box");
```

This decomposition also improves the production code — globals are read once at
the `frame()` level and passed down, making data flow explicit and eliminating
silent dependencies on global mutable state in the rendering functions.

### Tagging widgets for tests

Add `dvui.tag("name", .{})` calls to the sub-functions for any widget a test
will need to assert on.  Keep tag names stable — they are part of the test API.

```zig
// Inside renderToolbar
var search = try dvui.textEntry(...);
dvui.tag("search-box", .{});
defer search.deinit();
```

### Migration order

Do the refactor incrementally, not all at once:

1. Create `src/diffkeep.zig` as a re-export stub; update `build.zig` to expose
   it as a module; confirm `zig build` still works.
2. Move global variable declarations from `app.zig` to `diffkeep.zig`; update
   all references.
3. Write the first integration test (DB migrations) using the shim — no frame
   sub-functions needed yet.
4. Extract one sub-function (e.g. `renderMetadataPanel`) and write a test for
   it.  Repeat per panel as needed.

---

## Running Tests

```bash
# All tests (unit + integration)
zig build test

# Filter by name
zig build test -Dtest-filter="db migrations"

# Seed snapshot baselines (run once after writing snapshot tests)
DVUI_SNAPSHOT_WRITE=1 zig build test

# Generate debug images for a snapshot test
zig build test -Dsnapshot-images=debug
```
