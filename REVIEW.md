# DiffKeep code review — 2026-11-10

This review was read-only; no source files were changed. Eleven reviewers took part:

- seven covered sections of the code: data layer; scan/parse; native media and embedder; grid/search/ops; viewer; app shell and UI; platform;
- two covered the places where modules meet: threading and lifecycle, and data ownership;
- one did a structural review of the project as a whole;
- the eleventh was the consolidation pass, where I removed duplicates and checked the top items against the code.

Where several reviewers found the same issue, it is listed once with a count of how many found it. **✔ verified** means I checked it against the code myself.

Out of scope: the llama.cpp/mtmd research tools, the vendored SQLite and sqlite-vec, and the mtmd headers.

---

## Tier 1 — data loss, crashes, corruption

| # | Issue | Where | Notes |
|---|---|---|---|
| 1 | **Embedder freed while still in use.** Changing a model or GPU setting in Settings calls `g_embedder.deinit()` on the main thread. Scans, embed consumers, watcher tasks and search embed tasks still hold the raw `*Embedder`. `onClosed` also queues a rescan *before* the deinit, so the new scan takes the old pointer. `pollEmbedderLoad` deinits and refills the same slot, so stale holders silently switch models. | app.zig:536, :792, :1009; library_manager.zig:236/276; scan.zig:435; search.zig:185 | Found by 5 of 6 reviewers. ✔ verified. Fix: stop scans and await `scan_group`/`file_group`/`embed_group` before the deinit, or refcount the embedder. Null `mgr.embedder` *before* `onClosed` rescans. |
| 2 | **Dedupe can trash the only copy of a file.** The "keep MIN(id) per hash" rule counts rows. The same file can have two rows, either from nested libraries or from the scan and the watcher racing `findOrCreateImage` (see #3). The higher-id row is trashed, so the file moves to trash, and the remaining row then points at a missing file and is deleted. Trash is purged after 30 days. | db.zig:1446; image_ops.zig:529 | ✔ verified. |
| 3 | **Duplicate rows for the same path.** `findOrCreateImage` does a SELECT then an INSERT on separate pool connections, and there is no UNIQUE index on `(library_id, library_path)`. The startup or backfill scan and a watcher CLOSE_WRITE task for a new file both insert it, giving two tiles and two embeddings, and feeding #2. Nested libraries aren't rejected either. | db.zig:138, :510-563; library_manager.zig:108 | Found by 4. Fix: a migration that dedupes, then a partial UNIQUE index `WHERE trashed_at IS NULL`, plus `INSERT … ON CONFLICT DO NOTHING`. Reject overlapping libraries. |
| 4 | **A new file saved at a trashed image's path merges into the trashed row, and Restore overwrites it.** `find_image` doesn't filter on `trashed_at`. ComfyUI reuses `_00042_.png`, so the new image lands in the trashed row and never appears in the library. Restore then uses `rename`, which replaces the destination (the cross-device copy overwrites too), destroying the new file. | sqlite.zig:261-267; image_ops.zig:26-44, :304-316 | ✔ verified (`find_image`). Found by 2. Fix: add `AND trashed_at IS NULL`. Restore must not overwrite: use NOREPLACE, or rename on conflict. |
| 5 | **A scan can wipe a whole library.** Reconciliation deletes every row the walk didn't see. Two triggers: an unmounted NAS or USB drive whose empty mount-point directory still exists; or a filesystem returning `DT_UNKNOWN` (NFS, FUSE, XFS without ftype), which makes the walker skip every entry. Either way all rows are deleted, along with their favorites and descriptions. | scan.zig:317-328, :376 | Fix: stat `.unknown` entries. Refuse to reconcile when the walk saw 0 or very few files against a large known set. |
| 6 | **Cached prepared statements hold a dangling `*Database`.** `prepareStatements` runs on the stack-local `self` in `Database.open`, which is then returned by value. `step()`'s error path calls `sqlite3_errmsg(self.db.db)`, reading a dead stack frame, so any BUSY or step error on find/insert/update image or library is undefined behaviour and likely a crash. | sqlite.zig:230-250, :151, :302 | ✔ verified. Fix: use `sqlite3_db_handle(stmt)` and drop the back-pointer. |
| 7 | **Cached statements are never reset after a row hit.** `storeLibrary`, `findOrCreateImage` and `getLibraryIdByPath` return on `step()==true` without `sqlite3_reset`. The connection stays in an open read transaction on a stale WAL snapshot. Its next write fails immediately with SQLITE_BUSY_SNAPSHOT, which `busy_timeout` doesn't help with, and the WAL can't checkpoint. Concretely, `removeLibrary`'s DELETE can fail and the error is swallowed in the sidebar, so the library comes back on restart. This combines with #6 to crash. | db.zig:325-333, :514-539, :592 | The reviewer reproduced the mechanism in Python WAL. Fix: `defer stmt.reset()` on every exit path. |
| 8 | **Re-embedding never replaces vectors.** `INSERT OR REPLACE` into vec0 fails with a UNIQUE error, because sqlite-vec ignores the conflict clause. Changed or reparsed images keep their old prompt and image vectors, and the failure is only logged at warn level. | sqlite.zig:334 | ✔ verified (sqlite-vec.c:4239, no delete before the insert). Fix: DELETE then INSERT in one transaction. Add a test that stores twice. |
| 9 | **Orphan embeddings are inherited when ids are recycled.** The embed queue lags behind the scan. If a row is deleted before its vector is stored, the v12 trigger has already fired, so the vector is written for a dead id. The next insert reuses that id: the prefetch sees an embedding already present and skips it, and search returns the new image for the old content. | scan.zig:546-575; db.zig:176-186 | Found by 2. Fix: store the vector only if `id AND library_path` is still live, in one transaction (or use AUTOINCREMENT). |
| 10 | **Stale ids act on the wrong row.** Scan reconciliation and the trash purge delete rows without reporting their ids to the grid or viewers. `deleteImage`, `trashImage`, `restoreImage` and `setFavorite` match on id only. A stale tile whose id was recycled therefore deletes, trashes or favorites a *different* image. `trashOne` also moves the file even when the UPDATE matched 0 rows, leaving an orphan in trash. | scan.zig:318-327; db.zig:1216, :1354, :1501; image_ops.zig:285-301, :396-418; image_grid.zig:979 | Found by 3. Fix: push the removed ids through `removed_ids`, guard every mutation on `id AND library_path`, and check `sqlite3_changes`. |
| 11 | **Deleting from a viewer opened from Trash permanently deletes without confirmation.** `openViewerDeleteDialog` ignores `trash_name`, so it shows "Move to trash" (or skips the prompt if "don't ask" is set) and then hard-deletes. | app.zig:913 | Found by 2. ✔ verified. A one-line fix. |
| 12 | **Bulk ops (dedupe, empty trash) race single file ops.** There is no serialization. The rollback calls `restoreImage` on a row whose file has already been moved, which leaves orphaned trash files. | image_ops.zig:473-533 vs :239-332 | Plausible. Fix: run bulk ops as jobs on the same worker queue. |
| 13 | **Greyscale images are returned as 2 bytes per pixel.** `vips_addalpha` on a 1-band image gives 2 bands, and the callers index `w*h*4`. Opening or dragging a grey PNG causes a bounds panic in safe builds, or a heap over-read in ReleaseFast. | vips_helper.c:383-475; dnd_ghost.zig:44; dnd_linux.zig:766; image_viewer.zig:212 | The reviewer verified this with the vips CLI. Fix: `vips_colourspace(sRGB)` plus a uchar cast before addalpha, and assert `len == w*h*4` as an error, not a debug assert. |
| 14 | **Malicious or odd metadata can hang the scan and block quit.** `followPromptToText` recurses with no visited set: a self-referencing node at depth 20 means about 11²⁰ calls. `processFile` never checks `stop`, and quitting waits on `scan_group`. | comfy.zig:633-656 | Fix: a visited set per traversal. |
| 15 | **Windows drag-and-drop use-after-free.** The C drag thread keeps borrowed `paths` and `ghost_rgba` pointers, and the Zig side frees them as soon as the call returns. | dnd.zig:50-80; dnd_win32.c:305-326 | Windows-only. Fix: deep-copy in C. |

## Tier 2 — main-thread IO and UI freezes (violates the CLAUDE.md rule)

- **Detail panel**: every focus change and every viewer navigation (even with the info pane closed) opens and reads the **whole file** and parses all PNG chunks on the UI thread. Focusing a 500 MB video reads all 500 MB. Files: detail_panel.zig:67-149, image_viewer.zig:137/333.
- **Viewer video/animation open**: `VideoPlayer.init` runs in `render()`. Animated WebP/GIF files up to 96 MB are fully decoded synchronously, and videos are opened three times. Failed opens are retried every frame. Files: image_viewer.zig:466-475, video_player.zig:97-133. Found by 2.
- **DB queries on the UI thread**:
  - `refreshCounts` runs a duplicates GROUP BY, a trash SUM and per-library COUNTs on every favorite toggle or file op.
  - Total and per-library COUNTs re-run **every frame the grid length changes**, which means continuously during a scan.
  - `getStats` does `SUM(LENGTH(thumbnail))`.
  - Clear thumbnails/embeddings, `getDistinctColumnValues`, `listImmediateSubdirs` and the `removeLibrary` cascade all run there too.
  - Files: app.zig:91, :504-510; toolbar.zig:604; settings_modal.zig:495; sidebar.zig:200/386/622; filter_modal.zig:59.
- **Watcher deletes**: `processFileEvent(deleted)` runs one DELETE plus triggers per file inside `frame()`, so `rm *.png` on 5k files freezes the UI. Event dedup is O(n²) (app.zig:707-731). Found by 4.
- **Background view loads share `g_db`** (image_grid.zig:293, `LoadCtx.db = &g_db`). They hold `db_mutex` for a 50k-row list or a KNN query, so every main-thread point query blocks behind them. Fix: give `GridState` its own `getConnection()`, and wrap `loadView` in one read transaction. Found by 4.
- **`removeFromGrid`** uses `orderedRemove` in a loop, which is O(n·k). Deleting 10k of 55k images takes seconds (image_ops.zig:63-77).
- **Per-frame work during a scan**: the incoming drain rebuilds an id hash set and re-sorts all 55k entries (image_grid.zig:971-1019).
- **Copy image** reads the whole file synchronously and always advertises it as `image/png` (platform_sdl.zig:53-63).
- **Config save** on settings close is non-atomic file IO on the main thread (see Tier 3).

## Tier 3 — correctness bugs (medium)

**Scan and index**
- Images with no prompt (JPGs, non-Comfy images, over-long prompts) are reprocessed on **every** scan: full row and BLOB fetch, a `vips.nPages` call, and an empty `EmbedInput` that inflates progress (scan.zig:401, :753-770).
- Images without metadata skip hashing, thumbnail and image embedding on the first pass, so dedupe misses them. A changed file that hits these early returns keeps the old prompt, hash and embeddings, and the stale hash can feed dedupe (scan.zig:815-870).
- A file read mid-write is parsed as truncated, but its mtime (whole seconds) is still stored, so it is never reparsed. The short-read byte count is ignored (scan.zig:805-821).
- One unreadable subdirectory aborts the whole library scan (`try` on openDir/next) (scan.zig:352-368).
- Videos are fully read into memory to hash them, with up to 32 tasks in parallel, which can cause OOM. Stream into Blake3 instead (scan.zig:687-702).
- One bad metadata section, such as a `NaN` in the workflow JSON, disables the prompt/parameters fallbacks (comfy.zig:860-868).
- Flux `CLIPTextEncodeFlux` prompts are never found, because of a substring-match order bug (comfy.zig:604-624).
- The PNG parser allocates the untrusted chunk length (up to 4 GB) before any bounds check, copies every chunk including IDAT, and discards already-parsed text chunks on truncation (png-data.zig:92-101).
- Bursts of watcher events spawn one task, one SQLite connection and one CPU encoder per file. The pool never shrinks (library_manager.zig:116; sqlite.zig:67-76).

**Removing a library**
- Its in-flight scan isn't cancelled, which floods FK errors and creates orphan embeddings.
- Ghost tiles are re-added from the notifier and `load_added`.
- Viewers aren't told.
- Trashed files of that library are orphaned in `trash/` forever.
- Files: sidebar.zig:617-639; library_manager.zig:150-157; db.zig:599-606.

**Search and grid**
- `pending_embeddings` is raced between the embed worker and the main thread. This can cause a leak or double free, and the spinner can stop early (search.zig:47-60 vs :173-176). Found by 2.
- `grid.search_query` borrows the live text-box buffer, so later reloads run FTS on half-typed text (app.zig:654-663). Found by 3.
- Clearing the query or switching to FTS doesn't bump `embed_generation`. An in-flight semantic result lands later and replaces the grid while the search box is empty.
- KNN and RRF relevance order is thrown away by `applySortOrder` (image_grid.zig:741). It needs a "relevance" sort, or should skip sorting for vector searches. **Is this intended?**
- A thumbnail load in flight survives `invalidateThumbnail`. With id recycling, it shows the old thumbnail or permanently marks `load_failed` (image_grid.zig:1070-1098). Found by 3.
- The notifier is only drained in library view, so it grows without bound and causes ghost re-adds (image_grid.zig:967).
- Prefetched thumbnails are evicted and reloaded about every 45 s. `committed` has no byte cap. Visible cells hash their full JPEG every frame (`.invalidation = .bytes`) (image_grid.zig:1494).
- Cross-device `moveFile` reads the whole file into RAM, isn't atomic, and drops mtime (image_ops.zig:34-43).

**DB and config**
- Folder filters use `LIKE 'p/%'`, which is case-insensitive and treats `_` and `%` as wildcards (db.zig:657, :810, :1083). Use a range predicate, which can also use the index.
- `Database.close` doesn't finalize the cached statements, so `sqlite3_close` returns BUSY and leaks every connection. The WAL is never checkpointed. `open` leaks on error (sqlite.zig:253).
- Config is written by truncate-then-write. Any parse error, including an unknown enum value, aborts startup (config.zig:66-76, :158-172).
- `setupSchema` ignores BEGIN/COMMIT/user_version return codes, has no busy_timeout, and **panics** when the DB version is newer than the binary (db.zig:214-240).
- `columnBlob` and `columnText` on zero-length or NULL values `@ptrCast` a null pointer and panic (`getThumbnailBytes`, `creationDate`).
- Library paths aren't normalized. A trailing slash or Windows `\` breaks folder queries and `pathInside`. A failed add still appends a sidebar row with id 0 (sidebar.zig:128-149).

**UI**
- The sidebar folder tree goes empty after any count refresh while a library is expanded (sidebar.zig:117-125).
- The model-download thread writes into the text-entry buffer that dvui is editing, is detached, and is never joined. `awaitDownloads` is an empty stub, and partial downloads aren't atomic (settings_modal.zig:119-214).
- "Empty trash" in Settings skips confirmation (settings_modal.zig:396).
- "Copy image" stores a borrowed `entry.path` that can be freed before it is used the next frame (image_grid.zig:1617 → app.zig:592).
- The delete dialog acts on the selection at confirm time. A reload while the dialog is open clears it, and Confirm does nothing (delete_dialog.zig:84).
- The SDL folder-picker callback may run off the main thread and writes shared buffers unsynchronized (sidebar.zig:154; platform_sdl.zig:76).
- `g_favorite_count` is 0 at startup. The grid's `thumbnails_in_db` is never updated after a settings change.

**Viewer**
- After a list change, stale decode threads can fill the wrong slot, so the viewer shows the wrong image under a filename. A per-slot generation is needed (image_viewer.zig:1154-1165).
- A decode failure leaves an infinite spinner with no error state.
- Evicted decode threads are never joined while the viewer stays open, so the number of threads is unbounded. `orphan_threads.append(..) catch t.join()` joins while holding `cache_mutex`, which deadlocks on OOM (image_viewer.zig:258-314).
- Wheel zoom doesn't keep the point under the cursor fixed (math bug). The correct update is `pan' = (pan+u)·z/z' − u` (image_viewer.zig:1021).
- Animation pacing uses average fps instead of per-frame pts, and uses `Clock.real` (video_player.zig:291).
- Removing an earlier image restarts the playing video, because `video_player_idx` isn't shifted.
- Stream-mode animation segfaults after a failed reopen on a backward seek (vips_helper.c:402-473).
- If `ViewerManager.open` fails, it calls `SDL_Quit` under the main window (viewer_manager.zig:197-203). The workaround in `ViewerWindow.deinit` is a Band-Aid: set `back.sdl_quit=false` once instead.
- Closing a viewer leaves audio playing until it is reaped. Shortcuts fire behind the modal delete dialog.

**Platform (Linux)**
- inotify `IN_Q_OVERFLOW` is silently dropped, so bursts of more than 16k events are lost. Trigger a rescan instead (fs_watch_linux.zig:289-310).
- `DT_UNKNOWN` subdirectories are never watched. Hitting the watch limit (ENOSPC) produces log spam per directory but no signal to the user.
- The X11 DnD watcher thread busy-spins, because `poll` is level-triggered and it never reads. It floods SDL wakeups and pins a core while dragging (dnd_linux.zig:991-1003).
- There is no X11 error handler during a drag, so a BadWindow from a vanishing foreign window can `exit()` the app. `XDefineCursor` is used on foreign windows. XdndStatus/Finished aren't matched to the target.
- A Wayland drag can stay stuck in `.dragging` if the compositor ignores a bad serial. `wlDataSourceSend` does a single blocking write, which can self-deadlock when dropping onto our own window.
- `pushCmd` dropping `.stop` on OOM hangs `deinit`. Nested libraries share inode-keyed wds.

**Platform (Windows/mac, never compiled on Linux)**
- **Windows**:
  - `NtCreateFile` is called without the `\??\` prefix, so the watcher likely can't open any directory.
  - A failed re-arm leaves `NtWaitForSingleObject(null)` waiting forever, so quit hangs.
  - `EnumFormatEtc` and `SetData` aren't implemented, so the drag ghost doesn't show.
- **mac**:
  - `CFIndex = i32` should be `isize`.
  - FSEvents rename events are treated as deletes, so atomic-save files disappear.
  - The `must_scan_sub_dirs` flag is ignored.
- Add a cross-compile CI step to catch this kind of rot.

## Tier 4 — efficiency

- libvips concurrency is never limited, so every `vips_thumbnail` spawns a pool sized to the core count on top of the app's own parallelism. That likely explains much of the ~60 threads and malloc-arena pressure. Use `vips_concurrency_set(1–2)` (vips_helper.c:99).
- Videos are opened three times per scan (first frame plus two `readTag` calls, each with `find_stream_info`). Use one combined C call.
- Video playback copies each frame three times and allocates and frees per frame. Viewer decodes peak at 2× image size because of the dupe from C to Zig. Decode straight into Zig-owned buffers.
- `saveImage` rewrites every column, including the thumbnail BLOB and the prompt, on each call. That fires the FTS update trigger even when nothing changed. Add a `WHEN old.x IS NOT new.x` guard.
- The notifier dupes every path twice. The embed queue is unbounded and LIFO, though its comment says FIFO.
- `generate_thumbnail` re-reads the file it already has in memory. `findOrCreateImage` fetches the thumbnail BLOB only to null-check it.
- `style.ellipsize` is O(n²) per frame. Large raw-metadata JSON is re-laid out every frame while expanded.
- Settings changes queue duplicate full rescans with no dedupe in `pending`.

## Structural (summary of the architecture reviewer)

There are no import cycles. The problems are dependency direction and module size:

1. **Split `image_grid.zig`** (1982 lines, six jobs) into `view_query.zig` (domain types, `loadView`, FTS sanitize; no dvui), `thumb_loader.zig`, a player pool, and the grid UI. search.zig and image_ops.zig (both services) currently import the UI grid. image_ops should return results instead of mutating `GridState`.
2. **Replace about 35 `g_*` globals with an explicit `AppState`.** `frame()` is about 355 lines. Make image_ops a struct instance instead of module singletons. That makes `frame()` drivable from dvui's testing backend.
3. **One background-task abstraction.** The pattern "spawn, then atomic done flag, then wakeup, then poll, then swap" is hand-written at least 7 times, across 27 atomic bools, in three concurrency styles. A generic `LatestTask(T)` / `Job(T)` on `std.Io` would remove most of the races above (#search embed race, stale results, detached download thread).
4. **Move service logic out of the UI.** The HTTP download lives in settings_modal, and the sidebar, toolbar and detail panel query the DB directly. Rule to adopt: UI reads `AppState` snapshots and never `VectorDb`.
5. **Build**:
   - Stop installing the six llama.cpp research binaries and the GPU plugin libs by default. Put them behind `-Dresearch` with lazy deps; the ROCm/SYCL tarballs are multi-GB.
   - Delete the orphaned, non-compiling files: `queue.zig`, `get_workflow_chunk.zig`, `parse/parse_library.zig`, `test_runner.zig`.
   - Unify exe and test module wiring (`wireCore`); they have already drifted.
6. **Tests**:
   - The `png-data.zig` tests never run (not imported, and stale).
   - Untested: `scan.zig` reconcile, library_manager, the fs_watch → DB path, dnd, viewer_manager, filters → query, and all of `frame()`.
   - Highest value: a scan reconcile against a temp dir; the duplicate-row + dedupe and trashed-path tests implied by Tier 1; `loadView` across every mode combination; a PNG/comfy malformed-input corpus.
7. **Error policy**: there are 100 `catch {}` and about 50 `catch null/0/false`. image_grid has 30 swallowed allocation failures on map puts that corrupt state. DB read errors render as "0 images".
8. **Shared `fs_watch_common.zig`.** The event queue and `DirtyEvent` are copied across the three backends, which have already diverged. Consider replacing the custom spinlock with `std.Io.Mutex`.
9. **Doc drift**:
   - CLAUDE.md's module table omits about 20 live modules.
   - Its threading model omits about 6 threads.
   - The trash column is `trash_file_size`, not `file_size_bytes`.
   - TEST.md is stale.
   - `models.zig` links libvips (move `generate_thumbnail` into scan).

## Hardcoded English (i18n rule)

- `fmtBytes` units (detail_panel.zig:21-24).
- `buttonIcon` names `"add library"`, `"remove library"`, `"settings"` and `"search_clear"` (sidebar.zig:329/448, toolbar.zig:85/592). These may be accessibility labels.

## Checked and found sound

- Shutdown order in `appDeinit`.
- Linux inotify buffer parsing and the wake-pipe shutdown.
- URI percent-encoding.
- C/GLib allocator pairing.
- ffmpeg cleanup on every path.
- vec0 KNN fast path, L2 normalization and `sim = 1 - d²/2`.
- Query prefixes per space.
- RRF math.
- Grid reload generation swap.
- `noteLoadFailure` guards.
- No i18n violations in labels.

## Suggested fix order

1. **Quick, high-value**:
   - #11 (one line);
   - #6 and #7 (statement back-pointer and reset);
   - #8 (vec0 delete before insert);
   - #4 (`find_image` trashed filter, and restore without overwrite);
   - #13 (greyscale);
   - #14 (visited set);
   - `vips_concurrency_set`.
2. **One migration plus guards**: a UNIQUE path index and `ON CONFLICT` (#3), which fixes #2. Path-guarded mutations and reporting removed ids (#9, #10).
3. **Embedder lifecycle** (#1): quiesce or refcount it.
4. **Scan safety**: reconcile guard (#5), per-subdirectory errors, the no-prompt reprocessing loop, streaming hashes.
5. **Main-thread IO sweep** (Tier 2): background counts, details and viewer open; a dedicated loader connection; batched watcher deletes.
6. **Structural**: #3 (task abstraction) first, then split image_grid, then `AppState`.

---

## Fix status (2026-11-10, same day)

Tests went red then green unless marked *(fix only)*. "Red" was sometimes a compile failure because the fix needed a new API. Final state: 88/88 integration tests and 49/49 unit tests pass, stable over 15+ repeated runs. `zig build` is clean.

### Tier 1

| # | Status |
|---|---|
| 1 Embedder freed in use | Fixed. `releaseEmbedder` awaits search embeds and `LibraryManager.quiesce`s scans and file tasks (interrupted scans are re-queued). Tested: quiesce stops scans and resumes them. The swap itself is *(fix only)*: it needs real models. |
| 2 Dedupe trashes only copy | Fixed. The predicate needs a kept copy at a **different path**. Tested. |
| 3 Duplicate rows | Fixed. Migration v14 merges duplicates (keeping favorites) and adds a partial UNIQUE index; insert uses `ON CONFLICT DO NOTHING`. Tested (schema and migration). |
| 4 New file at trashed path / restore overwrite | Fixed. `find_image` ignores trashed rows; restore goes beside the existing file as `name (1).ext`; `moveFile` never replaces its target (exclusive streamed copy across devices, keeps mtime). Tested. |
| 5 Scan wipes a library | Fixed. Reconcile is skipped when no media was seen but rows exist; `DT_UNKNOWN` entries are stat'ed. Tested (emptied mount point). |
| 6 Dangling `*Database` | Fixed. Statements use `sqlite3_db_handle` *(fix only)*. |
| 7 Statements never reset | Fixed. Tested (stale WAL snapshot). |
| 8 vec0 replace | Fixed (delete and insert in a savepoint). Tested. |
| 9 Orphan embeddings | Fixed. Stores are guarded on id + path. Tested. |
| 10 Stale ids | Fixed. Scan-removed ids are reported; trash, restore and delete are guarded on id + path; a stale trash doesn't move the file. Tested. (`setFavorite` is still id-only.) |
| 11 Viewer delete from Trash | Fixed *(fix only; app.zig is not in the test graph)*. |
| 12 Bulk ops race | Fixed: one worker queue. Dedupe now updates viewers too. Tested. |
| 13 Greyscale RGBA | Fixed: `to_rgba8` in C plus a layout check in Zig. Tested. |
| 14 Comfy graph blow-up | Fixed (visited set). Tested. |
| 15 Windows DnD UAF | Fixed (C deep copy) *(fix only; it compiles for x86_64-windows)*. |

### Tier 2–3 also fixed

- **Main thread:**
  - counts load in the background (`counts.zig`), no longer per frame;
  - the detail panel loads in the background, newest selection wins, and only PNGs are parsed;
  - viewer players open on a thread;
  - the grid has its own view connection;
  - watcher deletions run in one background transaction, with an O(n) event merge;
  - `removeFromGrid` is a single pass;
  - copy-image does no IO at copy time and uses the file's real MIME type.
- **Scan:**
  - no-prompt images aren't reprocessed every scan;
  - images without metadata get a hash, thumbnail and image embedding;
  - a file rewritten without metadata loses its stale prompt;
  - mid-write PNGs are retried;
  - an unreadable subfolder is skipped (and its rows kept);
  - videos are hashed by streaming;
  - one bad metadata section no longer hides the others;
  - Flux prompts are found;
  - the PNG parser bounds-checks lengths, copies only metadata chunks and keeps the chunks read before a truncation.
- **DB/config:**
  - folder filters use a range instead of LIKE;
  - connections close cleanly (WAL removed);
  - a schema from a newer build is rejected;
  - empty blobs read safely;
  - config is saved atomically and loads leniently.
- **Library removal:** it stops its scan, then deletes rows and trashed files in the background, and reports the ids.
- **Search:** the result slot is mutex-guarded with a generation; the grid owns its FTS query; clearing the box or switching to FTS cancels the embed; all search results (text and vector) keep relevance order, and the sort buttons are greyed out and inert while a search is active (the sort settings apply again once it is cleared).
- **Grid:**
  - an in-flight thumbnail of an invalidated id is dropped;
  - the notifier is drained in every view;
  - an expanded sidebar tree survives a counts refresh;
  - the delete dialog acts on the images it opened for;
  - "Empty trash" in Settings asks for confirmation;
  - the folder-picker callback is thread-safe;
  - the favorites count is set at startup;
  - `thumbnails_in_db` reaches the grid.
- **Viewer:**
  - stale decodes are dropped (slot generations);
  - a failed decode or open shows an error rather than an endless spinner, and isn't retried every frame;
  - evicted decode threads are reaped instead of piling up (and no join under the lock);
  - zoom keeps the point under the cursor fixed;
  - pacing follows per-frame timestamps on a monotonic clock;
  - a scrub never shows a pre-seek frame;
  - the player index follows removals;
  - no `SDL_Quit` from a viewer;
  - closing a viewer pauses its audio;
  - keyboard shortcuts are inactive while the delete dialog is open.
- **Platform:**
  - inotify `Q_OVERFLOW` triggers a rescan; `DT_UNKNOWN` entries are stat'ed; ENOSPC warns once; a lost `.stop` can't hang shutdown;
  - X11 DnD: an error handler swallows BadWindow on drag displays, and the watcher no longer busy-spins;
  - Wayland: the URI list is written from a thread with a write loop;
  - Windows: watcher paths get the `\??\` prefix (tested natively), and quit no longer hangs after a failed re-arm;
  - macOS: `CFIndex` is `isize`; rename vs delete is decided by file existence; must-scan and dropped events trigger a rescan.
- **Model downloads:** a self-contained detached job; no UI-buffer race; downloads to `.part` and renames.
- **Misc:** i18n for byte units and icon-button labels; a stopped scan no longer logs "decode failed"; docs updated (CLAUDE.md, ZIG.md).

### Fixed in a second pass (2026-11-10)

- Settings DB stats, the clear-cache buttons and the dedupe count now come from the background counts loader.
- Sidebar folder lists load on a background worker (`folder_loader.zig`); a counts refresh reloads open lists without collapsing the tree.
- Copy-image reads the file on a background task at copy time; paste only hands over the bytes.
- Watcher-reported files go to a queue drained by at most 4 workers instead of one task each; a removed library's queued files are dropped.
- `setFavorite` matches id AND path.
- The sidebar and detail panel are shut down before the DB closes (their background loads use it).

### Structural work (2026-11-10)

- Build: llama.cpp research tools and orphaned files removed; app and tests wired through one `wireCore`.
- `bg.zig` (`Latest`, `WorkQueue`) replaces the hand-written background-task code in eight places.
- `image_grid.zig` split into the widget, `view_query.zig`, `thumb_loader.zig` and `grid_players.zig`.
- `fs_watch_common.zig` (`DirtyEvent`, `EventQueue`) shared by the watcher backends. The stronger cross-target check this added found the Windows watcher didn't compile under 0.17; fixed.
- `AppState` (`app_state.zig`) replaces app.zig's globals and runs headless in tests; `FileOps` is an instance.
- Still open from the structural list: viewer decode slots, video player threads, model downloads and the embedder load thread keep their own threading (different shapes from `bg.zig`'s); search.zig still drives the grid widget directly; the Windows/macOS parts of `dnd.zig` and `app.zig` can't be type-checked from Linux (a Windows build stops at finding libvips/libav).

### Efficiency pass (2026-11-11)

Measured with the new `zig build bench_scan` (1,500 PNGs plus a few videos, 8 cores, embeddings off, quiet machine):
- libvips runs one worker per operation (`vips_concurrency_set(1)`; `VIPS_CONCURRENCY` still overrides). Scan ~11% faster, peak threads 230 → 130, peak RSS ~1 GB → ~0.68 GB.
- The FTS update trigger fires only when the prompt changed (migration v15). Tested: an unchanged save writes 1 row instead of 9.
- A video is opened once per scan instead of three times, and its poster frame is scaled during conversion rather than copied at full size. Tested with a small tagged MP4 fixture (`tests/fixtures/tagged.mp4`).
- New grid images during a scan are merged into the sorted list (O(n + k log k)) instead of re-sorting the whole grid, and the "already shown" check no longer hashes the whole grid. Tested against a full stable sort for every mode; not timed.

### Not done (deliberately left; say if you want any)

- **Efficiency:**
  - fewer frame copies;
  - thumbnail TTL/cap;
  - `ellipsize`;
  - raw-JSON relayout;
  - embed queue backpressure;
  - viewer refresh at full vsync.
- **Platform:**
  - X11 XdndStatus/Finished target matching;
  - `XDefineCursor` on foreign windows;
  - Wayland drag stuck on a bad serial;
  - Windows `EnumFormatEtc`/`SetData`;
  - video `start_time` offsets.
- **Other:** GPU weight eviction at embedder deinit.
- **Unverified at runtime:** none of this was exercised in the running GUI (only `zig build` and the test suites). The Windows and macOS code was only compile-checked.
