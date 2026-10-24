# ZIG.md — Zig 0.17.0 Notes

Breaking changes and gotchas met in this codebase, on Zig 0.17.0 and the 0.16.0 changes
that still apply. Add a change here when you meet a new one, and delete a workaround
when it is resolved. The release notes miss several std renames; TensorPencil's ZIG.md
(`../TensorPencil/ZIG.md`) has a longer 0.17 list, and ggufy's 0.17 commit is a second
reference.

---

## Zig 0.17.0: what changed here

Language:
- `a ** n` is gone: `var v: [n]f32 = @splat(0);`, `queue: [n]?T = @splat(null)`.
  A repeated string: `&@as([80]u8, @splat('='))`.
- `@cImport` is gone. `build.zig` translates each header with the `translate_c` package
  (`Translator`) and the Zig file imports the module by name: `sqlite_c`, `vips_c`,
  `video_c`, `x11_c`, `wayland_c`, `llama_cpp`. Multi-header modules use a generated
  header (`b.addWriteFiles().add("x.h", "#include <a.h>\n...")`). A new C header means a
  new `Translator` plus `addImport` on every module that uses it.
- `@intFromEnum` / `@enumFromInt` are deprecated: `@backingInt(e)` and
  `@fromBackingInt(i)`; the argument must be exactly the backing type (`@intCast` it
  when it isn't, e.g. a `usize` dropdown index into an `enum(u8)`).
- `@typeInfo` is struct-of-arrays: `inline for (info.field_names, info.field_types) |name, T|`.
- `@import("builtin").os` / `.cpu` are deprecated: `builtin.target.os`, `builtin.target.cpu`.

std (renames):
- `std.fmt.allocPrint(a, ...)` -> `a.print(...)`; `std.fmt.bufPrint` -> `std.mem.print`;
  `std.fmt.bufPrintZ(b, f, x)` -> `std.mem.printSentinel(b, f, x, 0)`;
  `a.dupeZ(u8, s)` -> `a.dupeSentinel(u8, s, 0)`.
- `mem.indexOf*` -> `mem.find*` (`indexOfScalar` -> `findScalar`, `indexOfPos` ->
  `findPos`, `lastIndexOfScalar` -> `findScalarLast`).
- `std.fs.path` -> `std.Io.Dir.path`.
- `ArrayListUnmanaged` -> `ArrayList` (it was already unmanaged; the alias is deprecated).
- `ArrayList` now carries a pointer-stability `SafetyLock` (safe builds). Mutating a list
  after `deinit` (which sets it `undefined`) now panics in `assertUnlocked` instead of
  silently scribbling memory. That is how the integration tests' reversed
  `pool.deinit` / `db.deinit` defers were found.

Build system:
- `b.args` is gone: `run.addPassthruArgs()`.
- `OptimizeMode` is `std.lang.Optimize`, tags `.debug`, `.safe`, `.fast`, `.small`
  (`-Doptimize=ReleaseFast` is still accepted on the command line).
- `b.addModule` registers a package-wide NAMED module, and adding the same name twice
  panics at configure time. Helpers called once per executable must use `b.createModule`.
- `build.zig` runs in a separate configure process whose result is cached. The configurer
  compiles the `build.zig` of every package present in `zig-pkg/` or the global cache,
  INCLUDING lazy ones nothing asked for. dvui's optional pugl backend pulls in
  `cairo_zig` and `libexpat`, which are not 0.17-ready: if `zig build --fetch` (which
  fetches every lazy dep) ever pulled them, configure fails with errors in
  `zig-pkg/cairo_zig-*/build.zig`. Fix: remove those packages from `zig-pkg/` and
  `~/.cache/zig/p/`, and don't use `zig build --fetch` here.
- Configure-time logic is cached, so anything it computes from the outside world (a
  `std.process.run` of git, say) goes stale. Compute it in a build step instead: the app
  version comes from `tools/git_version.zig`, run with `has_side_effects = true`, its
  `captureStdOut()` added as an anonymous import and read with `@embedFile("git_version")`.

dvui (pinned to the commit TensorPencil uses, 0.6.0-dev):
- `Options.color_*` and path `.color` are `?ColorOrGradient`, not `Color`: wrap a
  `Color` as `.{ .color = c }`. Theme fields (`.fill`, `.text`, ...) are still `Color`.
- `Options.corner_radius: Rect` -> `Options.corners: CornerRect` (`.all(r)`, `.square`,
  `.round(r)`); `style.R` holds `CornerRect`s. `Theme.max_default_corner_radius` is gone
  (no cap; the theme's `corner` sets the default).
- Dragging is per button: `dragPreStart(me.button, me.p, opts)`, `dragging(me, name)`
  (the whole `Event.Mouse`), `dragEnd(me.button)`.
- `SDLBackend.initWindow` no longer takes `.allocator`, and by default persists window
  geometry itself (`persist_window_geometry`). DiffKeep turns that off because it keeps
  geometry in its own config.
- `Window.end(.{})` now calls `setCursor`, `textInputRect` and `renderPresent` itself.
  Our frame loops pass `.manage_backend = false` and call them by hand, because the DnD
  cursor must override dvui's after `end`. Backend calls no longer return errors.

---

## ArrayList is now always unmanaged

`std.ArrayList` no longer stores an allocator internally. The allocator is passed at every call site.

```zig
// Old
var list = std.ArrayList(T).init(allocator);
list.append(item);
list.deinit();

// New (0.16.0)
var list: std.ArrayList(T) = .empty;
list.append(allocator, item);
list.deinit(allocator);
```

Affected methods: `.deinit(alloc)`, `.append(alloc, item)`, `.appendSlice(alloc, items)`,
`.resize(alloc, n)`, `.ensureUnusedCapacity(alloc, n)`, `.clearAndFree(alloc)`, `.orderedRemove(idx)` (no alloc needed).

## `callconv(.C)` → `callconv(.c)`

Calling convention tags are now lowercase.

```zig
fn myFn() callconv(.c) void { ... }  // was .C
```

## `std.mem.trimRight` → `std.mem.trimEnd`

```zig
std.mem.trimEnd(u8, str, "\n")  // was trimRight
```

## `std.Thread.Semaphore` removed

Use `std.atomic.Value(bool)` for a simple spinlock, or `std.Io.Semaphore` (requires an `std.Io` argument).

## `std.Thread.Mutex` removed

Use `std.Io.Mutex` instead. Lock and unlock require an `std.Io` argument:

```zig
mutex: std.Io.Mutex = std.Io.Mutex.init,

mutex.lockUncancelable(io);
defer mutex.unlock(io);
```

## `std.time.nanoTimestamp()` removed

Use the `std.Io` clock API instead:

```zig
const now_ns = std.Io.Clock.real.now(io).nanoseconds;
```

## File / directory I/O uses `std.Io`

Most I/O operations now require passing an `std.Io` value through the call stack.
`std.Io.Dir.cwd()` replaces `std.fs.cwd()`, and file operations take `io` as the first argument.

```zig
var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
defer dir.close(io);
var file = try dir.openFile(io, "foo.txt", .{});
defer file.close(io);
```

## `std.ArrayList` / `std.ArrayListUnmanaged` default init is `.empty`

`.{}` no longer works as a default initializer for these types; use `.empty`:

```zig
var list: std.ArrayList(T) = .empty;
var list: std.ArrayListUnmanaged(T) = .empty;
```

This also applies to struct field defaults:
```zig
items: std.ArrayListUnmanaged(T) = .empty,
```

## `std.BoundedArray` removed

Use a plain fixed-size array with a count instead:

```zig
// Was: var tasks = std.BoundedArray(T, N){};  tasks.append(v) catch {};  tasks.slice()
var tasks: [N]T = undefined;
var task_count: usize = 0;
tasks[task_count] = v; task_count += 1;  // guard task_count < N yourself
tasks[0..task_count]
```

## `std.process.run` signature changed

```zig
// 0.16.0 — takes allocator and io
const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "describe" } });
```

## `std.posix.PROT`, `std.posix.MAP` are packed structs, not flag namespaces

In 0.16.0, `PROT` and `MAP` are `packed struct(u32)` with boolean fields.
Use struct literal syntax instead of bitwise OR:

```zig
// Old (does not compile)
std.posix.PROT.READ | std.posix.PROT.WRITE

// New (0.16.0)
std.posix.PROT{ .READ = true, .WRITE = true }
// or inline as the argument:
.{ .READ = true, .WRITE = true }
```

Same applies to `MAP`:
```zig
// Old
std.posix.MAP.SHARED

// New
std.posix.MAP{ .TYPE = .SHARED }
// or inline:
.{ .TYPE = .SHARED }
```

## `std.posix.write`, `std.posix.close`, `std.posix.ftruncate` removed

These thin POSIX wrappers were removed. For contexts without `std.Io`, use raw
Linux syscalls instead:

```zig
_ = std.os.linux.write(fd, buf.ptr, buf.len);
_ = std.os.linux.close(fd);
const rc = std.os.linux.ftruncate(fd, length);
if (std.posix.errno(rc) != .SUCCESS) return error.FtruncateFailed;
```

## `std.time.sleep` removed

Use `std.Io.sleep(io, duration, clock)` instead. `duration` is `std.Io.Duration{ .nanoseconds = N }`,
`clock` is `.real` (the only member of `std.Io.Clock`):

```zig
std.Io.sleep(io, .{ .nanoseconds = 1_000_000 }, .real) catch {};  // 1ms
```

## `std.process.Child.Term` tags are lowercase (0.16.0)

```zig
// Old
if (result.term != .Exited or result.term.Exited != 0) { ... }

// New (0.16.0)
if (result.term != .exited or result.term.exited != 0) { ... }
```
