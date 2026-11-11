# TEST.md — how DiffKeep is tested

`zig build test` runs two test binaries. Both must pass after every change.

| Layer | Root | dvui backend | Covers |
|---|---|---|---|
| Unit | `src/test.zig` | none | Pure logic with no C libraries: ComfyUI parsing, prompt cleaning, config, PNG chunk reading, media types, the watcher's event logic. |
| Integration | `tests/integration.zig` | `.testing` (headless) | Everything else: the DB, scans on temp dirs, the library manager, background loaders, image ops, search, the grid and viewer state, and UI panels driven through dvui's testing backend. |

Note: `zig build test` caches a passing run. To re-run an unchanged binary (for
example to check for flaky tests), run it directly:
`$(ls -t .zig-cache/o/*/diffkeep-integration-tests | head -1)`.

## Unit layer

Add a module to `src/test.zig` when its tests need no C library (no SQLite,
libvips, libav or TensorPencil). Its `test` blocks live in the module itself.

## Integration layer

`build.zig` builds `src/diffkeep.zig` (the library root that re-exports the
app's modules) against dvui's headless backend, and links it the same way as
the app through `wireCore`, so both builds see the same C libraries and
imports. UI modules reach SDL only through the `platform` seam
(`src/platform.zig`), which stays at its no-op defaults in tests.

Conventions:

- **Databases** are real files under `/tmp`, opened with `openDb(path)` (it
  deletes a stale file first). Close and delete them with
  `defer db.deinit(); defer std.Io.Dir.cwd().deleteFile(io, path) catch {};`.
  Use a distinct path per test. Not `:memory:`: each connection from the pool
  would get its own empty database.
- **Files on disk** go in a fresh temp dir (`freshDir`); `ScanFixture` sets up
  a DB, a `LibraryManager` and one library over a dir and waits for its scan.
- **Background work**: wait with the component's own await (`grid.awaitReload()`,
  `mgr.awaitFileTasks(io)`, `loader.awaitIdle()`, `search.awaitEmbed`, …), not
  with sleeps. Where there is no await, poll with a generous bound (5000
  iterations of a few ms) so a loaded machine doesn't fail the test.
- **UI tests** render one panel in a frame function, then drive it:
  ```zig
  var t = try dvui.testing.init(.{});   // .window_size if the widget is off-screen at 600x400
  defer t.deinit();
  dk.style.install();
  try dvui.testing.settle(frameFn);
  try dvui.testing.moveTo("search-box");  // widgets are found by their .tag
  try dvui.testing.click(.left);
  try dvui.testing.writeText("cat");
  try dvui.testing.settle(frameFn);
  ```
  Tags (`.tag = "name"` in a widget's options) are part of the test API; keep
  them stable. A hovered button's tooltip can cover its neighbour, so move the
  pointer away (`moveTo` another widget, then settle) before clicking next to
  it.
- **Fixes come with a test** that fails before the fix and passes after,
  where that's practical. Code that needs SDL itself (clipboard, windows,
  drag-and-drop) can't run here.

`tests/integration.zig` is grouped by area (DB, grid, viewer, sidebar, scan,
library manager, image ops, …); put a new test next to the ones for the same
area and reuse the helpers near the top of each group.
