# Drag-and-Drop Source — Implementation Plan

DiffKeep needs to act as a **drag source** so images can be dragged from the
grid into other applications.  SDL3 only supports being a drop *target*, so
all four platforms require custom native code.

---

## Decisions

| Decision | Choice |
|---|---|
| Multi-file | Yes — drag all selected images, not just the one under the cursor |
| Ghost image | Yes — composited stack of up to 3 thumbnails |
| Windows threading | Dedicated drag thread (keeps render loop alive during `DoDragDrop`) |

---

## File layout

```
src/dnd.zig             public API, compile-time platform dispatch
src/dnd_linux.zig       runtime X11 vs. Wayland detection + dispatch
lib/dnd/dnd_win32.c     COM IDropSource + IDataObject implementation
lib/dnd/dnd_macos.m     Objective-C NSDraggingSource implementation
lib/vips/vips_helper.c  add diffkeep_jpeg_to_rgba_scaled() for ghost compositing
lib/vips/vips_helper.h  declare the new function
```

No separate `dnd_windows.zig` / `dnd_macos.zig` files — the thin Zig glue for
those platforms lives directly in `dnd.zig` inside comptime blocks.

---

## Public API

```zig
// Each item to be dragged.  Caller keeps all slices alive until tick() returns
// .idle (i.e. for the lifetime of the drag).
pub const DragItem = struct {
    path:       []const u8,  // absolute path on disk
    thumb_jpeg: []const u8,  // JPEG bytes from GridState.committed cache; may be empty
};

pub const DragSource = struct {
    pub fn init(sdl_window: *SDL_Window, allocator: std.mem.Allocator) ?DragSource
    pub fn deinit(*DragSource) void
    pub fn isDragging(*const DragSource) bool
    pub fn startDrag(*DragSource, items: []const DragItem) void
    pub fn pumpEvents(*DragSource) void   // call once per frame BEFORE SDL_PollEvent
    pub fn tick(*DragSource, io: std.Io) void
};
```

`startDrag` replaces `startFileDrag`.  The allocator is stored and used to
allocate the composited ghost bitmap (freed when the drag ends).

---

## Ghost image compositing

Used by: **Windows** (passed to `IDragSourceHelper`), **Wayland** (rendered
into a `wl_surface` icon), **macOS** (each `NSDraggingItem` gets its own
`NSImage`).  X11 XDND has no standard ghost mechanism — cursor change only.

### New vips helper function

Add to `lib/vips/vips_helper.c` and `lib/vips/vips_helper.h`:

```c
// Decode a JPEG buffer from memory, scale to fit within `target_size` (aspect-
// preserved), and return packed RGBA8 pixels via `out`.  Caller frees with
// diffkeep_vips_free().  Returns 0 on success, -1 on error.
int diffkeep_jpeg_to_rgba_scaled(
    const void *jpeg_data, size_t jpeg_len,
    int target_size,
    void **out, size_t *out_len,
    int *out_w, int *out_h
);
```

Implementation: `vips_jpegload_buffer` → `vips_thumbnail_image` → add alpha →
`vips_image_write_to_memory`.

### Compositing algorithm (Zig, platform-shared)

```
ghost_thumb_px = 96           // each thumbnail scaled to fit this box
offset_px      = 5            // each layer shifted right+down by this much
n              = min(items.len, 3)
canvas_w       = ghost_thumb_px + (n-1)*offset_px
canvas_h       = ghost_thumb_px + (n-1)*offset_px
```

Fill canvas with transparent black.  Then for `i` from `n-1` down to `0`
(back layer first):

1. Call `diffkeep_jpeg_to_rgba_scaled` on `items[i].thumb_jpeg` with
   `target_size = ghost_thumb_px`.  Skip if `thumb_jpeg` is empty.
2. Centre-fit the decoded pixels into a `ghost_thumb_px × ghost_thumb_px` box
   (letterbox with transparent padding).
3. Alpha-composite that box onto the canvas at `(i*offset_px, i*offset_px)`.

Result: one `[]u8` RGBA buffer + `canvas_w`/`canvas_h`, heap-allocated,
freed by `DragSource.deinit` or when the drag ends.

On **macOS** the OS stacks `NSDraggingItem` objects natively, so we skip the
manual composite and just pass each item's JPEG to AppKit as `NSImage` directly
(AppKit decodes JPEG natively).  The composite path is only needed on Windows
and Wayland.

---

## Platform: X11 (XDND protocol v5)

**State machine**: `idle → dragging → finishing → idle`

### Tick (each frame while dragging)

1. `XQueryPointer` on `src_win` — yields root-relative cursor coords and button
   mask.
2. If left button released → `finishDrag`.
3. `XQueryPointer` on root window → yields `top_child` (the top-level window
   directly under cursor).
4. `findTarget(top_child)`:
   - Walk *down* from `top_child` using `XTranslateCoordinates` to find the
     innermost child under cursor.
   - Walk *back up* from innermost child to `top_child`, returning the first
     window with `XdndAware` property set.
   - Also check `XdndProxy` on `top_child` as a fallback for embedded toolkits
     (e.g. older GTK apps).
   - This two-pass descent/ascent is what most implementations skip; it is
     required for Firefox, VSCode, Electron, etc.
5. On target change: send `XdndLeave` to old target, then `XdndEnter` to new
   target.  `XdndEnter` includes MIME type `text/uri-list`.
6. Send `XdndPosition` every frame.  `data.l[3]` (timestamp) = `CurrentTime`
   (0).  `data.l[4]` = `XdndActionCopy`.
7. On button release with accepted target: send `XdndDrop` (`data.l[2]` =
   `CurrentTime`).  Transition to `finishing`.
8. On button release with no accepted target or no target: send `XdndLeave`,
   transition to `idle`.

### Event interception (`pumpEvents`)

Use `XCheckIfEvent` with a predicate before `SDL_PollEvent`.  Intercept:
- `ClientMessage` where `message_type` = `XdndStatus` or `XdndFinished`
- `SelectionRequest` where `selection` = `XdndSelection`

SDL3 discards unrecognised `ClientMessage` events and never processes
`SelectionRequest`, so we must steal them before SDL sees them.

### SelectionRequest handler (providing drop data)

When a drop target requests `XdndSelection` with target type `text/uri-list`:

```
file:///path/to/image1.png\r\n
file:///path/to/image2.png\r\n
```

Build a flat buffer of all paths, `XChangeProperty` on the requestor window,
then send `SelectionNotify`.

Handle the `MULTIPLE` atom: iterate atom pairs and answer each one.

### No ghost image

XDND has no standard drag-image mechanism.  Cursor change (the OS default
arrow) is the only visual feedback.  Do not try to implement X11 cursor
compositing — it requires XFixes and is not worth the complexity.

### Multi-file: `text/uri-list`

```
file:///abs/path/to/a.png\r\n
file:///abs/path/to/b.png\r\n
```

Build once in `startDrag`, store as an allocated `[]u8` for the
`SelectionRequest` handler.

---

## Platform: Wayland (`wl_data_device` protocol)

### Init sequence

1. Get `wl_display*` from `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`.
2. Get `wl_surface*` from `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER`.
3. `wl_display_get_registry(display)` — our own registry on SDL's connection.
   Binding our own globals does not conflict with SDL's; Wayland allows multiple
   references to the same global from the same client connection.
4. Registry listener: capture `wl_seat` and `wl_data_device_manager`.
5. `wl_display_roundtrip(display)` to flush initial registry events.
6. From `wl_seat`, get `wl_pointer`.  Add listener:
   - `wl_pointer.button` (action = pressed, our surface has focus) → store
     serial as `last_button_serial`.
   - `wl_pointer.enter` → mark surface as focused, store its serial.
7. `wl_data_device_manager.get_data_device(our_seat)` → `wl_data_device`.

### The serial problem

`wl_data_device.start_drag` requires a serial from a recent button-press event
on the source surface.  SDL3 does not expose this serial in its event structs.
Binding our own `wl_seat` / `wl_pointer` gives us the raw Wayland events
including serials.  The serial from our listener is the same serial SDL
received, and is valid for our `start_drag` call on the same connection.

### `startDrag`

1. Create `wl_data_source` via `wl_data_device_manager.create_data_source()`.
2. `wl_data_source.offer("text/uri-list")`.
3. Attach listener: `send`, `cancelled`, `dnd_drop_performed`, `dnd_finished`.
4. Build ghost RGBA via composite algorithm; create `wl_surface` + `wl_shm`
   buffer and attach it as the icon (see below).
5. `wl_data_device.start_drag(source, our_surface, icon_surface, last_button_serial)`.
6. `wl_display_flush(display)`.

### Ghost surface (Wayland icon)

1. `wl_compositor.create_surface()` → icon `wl_surface`.
2. `wl_shm.create_pool(fd, size)` → pool.  Use `memfd_create` or `shm_open` for
   the backing fd.
3. `wl_shm_pool.create_buffer(format=ARGB8888, …)` → `wl_buffer`.
4. Write composited RGBA pixels into the shm mapping (note: Wayland ARGB8888 is
   little-endian BGRA in memory — swap R and B channels from our RGBA buffer).
5. `wl_surface.attach(buffer, 0, 0)` → `wl_surface.commit()`.
6. Set hotspot to centre: `wl_data_device.start_drag` does not take a hotspot;
   the compositor positions the icon at the cursor.  Use `wl_surface.set_buffer_scale`
   if HiDPI scaling is needed.
7. Destroy icon surface and shm objects in `cancelled`/`dnd_finished` handler.

### `wl_data_source.send` handler

```c
// mime_type == "text/uri-list"
write(fd, uri_list_buf, uri_list_len);
close(fd);  // compositor owns fd; caller must close
```

### `pumpEvents`

`wl_display_dispatch_pending(display)` — processes buffered Wayland events
without blocking.  Call before `SDL_PollEvent` each frame.

### Multi-file: `text/uri-list`

Same format as X11.  Write all URIs to the fd in `send`.

---

## Platform: Windows (OLE drag-and-drop)

### `lib/dnd/dnd_win32.c`

Implements two COM interfaces via manual vtables (no ATL/MFC).

**`MyDropSource`** (`IDropSource`):
- `QueryContinueDrag(fEscapePressed, grfKeyState)`:
  - Escape pressed → `DRAGDROP_S_CANCEL`
  - Left button released → `DRAGDROP_S_DROP`
  - Otherwise → `S_OK`
- `GiveFeedback` → `DRAGDROP_S_USEDEFAULTCURSORS`

**`MyDataObject`** (`IDataObject`):
- `GetData` for `CF_HDROP + TYMED_HGLOBAL`:
  Build a `DROPFILES` struct in an `HGLOBAL`.  Layout:
  ```
  DROPFILES header (fWide=TRUE)
  wchar_t path1\0
  wchar_t path2\0
  \0              ← double-null terminator
  ```
  Supports any number of paths.
- `QueryGetData` for `CF_HDROP` → `S_OK`, else `DV_E_FORMATETC`.
- All other `IDataObject` methods → `E_NOTIMPL`.

**Ghost image via `IDragSourceHelper`**:
- After creating `MyDataObject`, call `CoCreateInstance(CLSID_DragDropHelper)`.
- Build a 32-bit top-down DIB from the composited RGBA buffer.
  Windows DIBs are BGRA; swap R↔B from our RGBA data.
- `IDragSourceHelper::InitializeFromBitmap(sdi, data_object)` where `sdi.hbmp`
  is the DIB and `sdi.ptOffset` is the hotspot (centre of bitmap).
- If `CoCreateInstance` fails (rare), silently skip the ghost image; the drag
  still works.

**Exposed C functions**:

```c
BOOL dnd_win32_init(void);      // call once on main thread at app startup
void dnd_win32_deinit(void);    // call at app exit
// path_list: array of UTF-16 strings; ghost_rgba/w/h: composited bitmap or NULL
BOOL dnd_win32_start_drag(
    const wchar_t **paths, int path_count,
    const void *ghost_rgba, int ghost_w, int ghost_h);
BOOL dnd_win32_is_dragging(void);
```

### Threading

`DoDragDrop` is a blocking modal message loop.  The drag thread:

1. `OleInitialize(NULL)` — establishes a COM STA for this thread.
2. Build `MyDataObject` and `MyDropSource` on this thread (same apartment).
3. Optionally call `IDragSourceHelper::InitializeFromBitmap`.
4. `DoDragDrop(data_obj, drop_src, DROPEFFECT_COPY, &effect)`.
5. Release COM objects.
6. `OleUninitialize()`.
7. Set `done` atomic to `true`.

Main thread's `dnd_win32_is_dragging()` checks the atomic; `tick()` in Zig
joins the thread once `done` is set.

`dnd_win32_init()` on the main thread calls `OleInitialize` for the main STA
(required for COM registration even though dragging runs on another thread).

### Zig side (inside `dnd.zig` comptime block for `.windows`)

```zig
// Convert []const []const u8 paths → [][:0]const u16 (UTF-16)
// Composite ghost RGBA
// Spawn std.Thread running the C drag thread function
// In tick(): if thread done, join and set phase = .idle
```

### Multi-file: `CF_HDROP`

The `DROPFILES` + multiple null-terminated wide-char paths already described
above.  `fWide = TRUE` required.

---

## Platform: macOS (AppKit `NSDraggingSession`)

### `lib/dnd/dnd_macos.m`

**NSEvent capture**

SDL owns the `NSView`; we cannot override `mouseDown:`.  Install a local
monitor at init time:

```objc
g_monitor = [NSEvent
    addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
    handler:^(NSEvent *ev) {
        g_last_mouse_down = ev;  // ARC retains it
        return ev;               // still delivered to SDL
    }];
```

**`DKDragSource`** (implements `NSDraggingSource`):

```objc
- (NSDragOperation)draggingSession:(NSDraggingSession *)s
    sourceOperationMaskForDraggingContext:(NSDraggingContext)ctx {
    return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)s
           endedAtPoint:(NSPoint)p
              operation:(NSDragOperation)op {
    g_is_dragging = false;
}
```

**`dnd_macos_start_drag(paths, path_count, jpeg_bufs, jpeg_lens)`**:

```objc
NSMutableArray *items = [NSMutableArray array];
for (int i = 0; i < path_count; i++) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:paths[i]]];
    NSPasteboardItem *pbi = [[NSPasteboardItem alloc] init];
    [pbi setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:pbi];

    // Thumbnail as NSImage (AppKit decodes JPEG natively — no vips needed here)
    NSImage *thumb = nil;
    if (jpeg_bufs[i] && jpeg_lens[i] > 0) {
        NSData *d = [NSData dataWithBytes:jpeg_bufs[i] length:jpeg_lens[i]];
        thumb = [[NSImage alloc] initWithData:d];
    }

    // Offset each item so AppKit stacks them visibly
    NSPoint loc = [g_ns_view convertPoint:[g_last_mouse_down locationInWindow]
                                 fromView:nil];
    float off = i * 4.0f;
    NSRect frame = NSMakeRect(loc.x - 32 + off, loc.y - 32 - off, 64, 64);
    [di setDraggingFrame:frame contents:thumb];
    [items addObject:di];
}
[g_ns_view beginDraggingSessionWithItems:items
                                   event:g_last_mouse_down
                                  source:g_drag_source_obj];
g_is_dragging = true;
```

AppKit natively stacks multiple `NSDraggingItem` objects — no manual
compositing needed on this platform.  Pass up to 3 items with their JPEG data.

**Get `NSView`**:

```objc
NSWindow *nswin = (__bridge NSWindow *)SDL_GetPointerProperty(
    SDL_GetWindowProperties(sdl_win),
    SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
g_ns_view = nswin.contentView;
```

**Exposed C functions**:

```c
bool dnd_macos_init(void *sdl_window);
void dnd_macos_deinit(void);
// jpeg_bufs[i] / jpeg_lens[i] may be NULL/0 if thumbnail not loaded
void dnd_macos_start_drag(
    const char **paths, int path_count,
    const void **jpeg_bufs, const size_t *jpeg_lens);
bool dnd_macos_is_dragging(void);
```

---

## Linux runtime dispatch (`src/dnd_linux.zig`)

```zig
const Backend = union(enum) {
    x11:     X11State,
    wayland: WaylandState,
};
```

In `init`: check `SDL_PROP_WINDOW_X11_DISPLAY_POINTER` first; if non-null, use
X11.  Otherwise check `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`; if non-null,
use Wayland.  If neither, return `null`.

All public methods (`startDrag`, `pumpEvents`, `tick`, etc.) dispatch on the
tag.

---

## Changes to existing files

### `src/image_grid.zig`

Replace:
```zig
drag_requested: bool = false,
drag_requested_path: []const u8 = "",
```
With:
```zig
drag_requested: bool = false,
drag_requested_ids: std.ArrayListUnmanaged(u64) = .empty,
```

The drag gesture trigger (around line 799) now appends the IDs of all selected
images instead of storing a single path.  If the dragged image is not in the
selection, add just that image's ID.

`deinit` must call `drag_requested_ids.deinit(allocator)`.

### `src/app.zig`

In the section that consumes `grid.drag_requested` (around line 1062):

```zig
if (grid.drag_requested) {
    grid.drag_requested = false;
    if (g_dnd) |*dnd| {
        // Build DragItem slice from drag_requested_ids
        var items = std.ArrayList(dnd_mod.DragItem).init(gpa);
        defer items.deinit();
        for (grid.drag_requested_ids.items) |id| {
            // Find ImageEntry for id
            for (grid.images.items) |entry| {
                if (entry.id != id) continue;
                const thumb = grid.committed.get(id);
                try items.append(.{
                    .path       = entry.path,
                    .thumb_jpeg = if (thumb) |t| t.bytes else &.{},
                });
                break;
            }
        }
        dnd.startDrag(items.items);
        grid.drag_requested_ids.clearRetainingCapacity();
    }
}
```

Replace `dnd.pumpX11Events()` → `dnd.pumpEvents()` at line 1434.

### `build.zig`

Remove the unconditional `linkSystemLibrary("X11", .{})`.  Replace with:

```zig
const os = target.result.os.tag;
if (os == .linux) {
    exe.root_module.linkSystemLibrary("X11", .{});
    exe.root_module.linkSystemLibrary("wayland-client", .{});
} else if (os == .windows) {
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("uuid", .{});
    exe.root_module.addCSourceFile(.{
        .file = b.path("lib/dnd/dnd_win32.c"),
        .flags = &.{ "-DUNICODE", "-D_UNICODE" },
    });
} else if (os == .macos) {
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.addCSourceFile(.{
        .file = b.path("lib/dnd/dnd_macos.m"),
        .flags = &.{ "-fobjc-arc" },
    });
}
```

---

## Implementation order

1. **X11 rewrite** — primary dev platform; fastest feedback loop.  Get correct
   target-window descent/ascent, multi-file URI list, and event interception.
2. **Windows** — `DoDragDrop` is well-documented; COM boilerplate is mechanical.
   Implement ghost via `IDragSourceHelper` after basic drop works.
3. **macOS** — clean AppKit API, ARC handles memory.  Only tricky part is the
   `NSEvent` capture via local monitor.
4. **Wayland** — most protocol work; the serial capture and `wl_shm` icon
   surface need careful testing across Mutter (GNOME), KWin (KDE), and
   wlroots-based compositors.

---

## Known gotchas

- **X11 `XdndPosition` timestamp**: must be `CurrentTime` (0), not a
  `gettimeofday` timestamp.  Many broken implementations get this wrong.
- **X11 target descent**: only checking the top-level window misses Electron,
  Firefox, VSCode.  Must walk innermost child → top-level.
- **Wayland serial staleness**: if the button press serial is too old (e.g. the
  user pressed, then switched focus, then came back), `start_drag` silently
  fails.  Capture the serial as late as possible (in the pointer listener, not
  at app init).
- **Windows COM apartments**: `MyDataObject` and `MyDropSource` must be created
  on the same thread that calls `DoDragDrop`.  Do not create them on the main
  thread and pass them to the drag thread.
- **Windows DIB format**: `BITMAPINFOHEADER.biHeight` must be negative for a
  top-down bitmap (our composited output is top-down).  Positive height means
  bottom-up and will display upside-down.
- **Wayland ARGB8888**: despite the name, the wire format is little-endian
  `[B G R A]` in memory — i.e. BGRA32, not RGBA32.  Swap R↔B when copying
  from our composite buffer.
- **macOS `beginDraggingSession` must be called on the main thread** from
  within an event handler context.  `startDrag` is called from the dvui render
  loop, which runs on the main thread, so this is satisfied automatically.
- **`wl_data_source.send` fd ownership**: the compositor transfers fd ownership
  to the source.  The source *must* close it after writing, even on error.
