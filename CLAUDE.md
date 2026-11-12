# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ground Rules

- Never run `git add` or `git commit` unless directly requested.
- `zig build` produces no output on success; any output indicates a warning or error.
- **Read `ZIG.md` before doing any work.** It documents Zig 0.17.0 (and still-relevant 0.16.0) breaking changes for this codebase. When you encounter and resolve a new Zig change, add it to `ZIG.md`.
- Don't add hardcoded English strings in the UI. Use localization and translation mechanisms instead.
- We want the code to be clean, with clear seperation of concerns, modular, and testable.
- Stick to Zig whenever reasonably possible rather than dropping to C.
- If there is ambiguity in a request, don't guess or assume; ask for clarification.
- When adding a new feature or fixing a bug, add unit / integration tests as appropriate.
- Make sure all tests are still passing after working on something. If they aren't, fix it - even if the test was previously broken.
- NEVER add any IO tasks to the main thread. This will freeze the UI and result in a bad experience.
- Don't swallow errors (`catch {}`, `catch null`) where losing them leaves wrong state. Reserve capacity before an irreversible step (a file trashed, a row deleted) so recording it can't fail; when an in-memory update can't be completed, reload from the DB (`GridState.resync`); a DB read that fails is shown as failed, never as empty. Log failures at `warn`: an `err` log fails any test that triggers it.
- Remember that the best code is often the simplest code. Tend towards simple solutions where possible, that will work for all the edge cases.
- If the user asks for something that may cause issues, push back and get confirmation before doing it.
- If you see existing code that may cause issues or is Band-Aid patch code, call it out and suggest a fix.

## Build & Run Commands

```bash
# Build and run the GUI
zig build run

# Build only
zig build

# Run unit tests (src/test.zig)
zig build test

# Compile for another platform without its C libraries (no binary)
zig build check -Dtarget=x86_64-windows-gnu      # whole app
zig build check-lib -Dtarget=aarch64-macos       # minus the SDL layer (macOS SDL needs Apple's SDK)

# Dev tools (not part of the GUI)
zig build video_probe -- file.mp4         # probe a media file's streams/metadata/first frame
zig build test_tp_batch -- ...            # TensorPencil single vs batch embed throughput
zig build bench_embed -Doptimize=ReleaseFast -- --corpus FILE  # encoder quality/speed A/B
zig build bench_scan -Doptimize=ReleaseFast -- DIR [--runs N] [--text-model D] [--visual-model D]  # full-scan time/RSS, throwaway DB

# Pass --config / -c <dir> to use <dir>/DiffKeep.cfg. The DB stays at the XDG data dir
# unless that config sets data_path (the DB file path) — set it for throwaway runs.
zig build run -- --config /path/to/data/dir
```

## Architecture Overview

DiffKeep is a desktop image-library manager for AI-generated images, built with Zig 0.17 + [dvui](https://github.com/david-vanderson/dvui) (SDL3 backend). Its three main jobs are: (1) scan folder libraries and parse ComfyUI/PNG metadata, (2) store metadata + embeddings in SQLite, and (3) present a resizable 3-pane GUI.

### Key modules

| File | Role |
|---|---|
| `src/app.zig` | Entry point: the SDL window and event loop, viewer windows, native drag-and-drop, and the wakeup event. Owns one `AppState` (`g_app`) and drives it from dvui's callbacks (`appInit`/`frame`/`appDeinit`). Keep it to what needs SDL. |
| `src/app_state.zig` | `AppState` — everything the main window holds (config, DB, grid, library manager, embedder and its loader, watcher, file ops, counts, panels, dialogs, search, filters) and its per-frame logic (`frame`: apply background results, act on grid requests, search debounce, watcher flush, render). No SDL: what needs it comes in through `Hooks`, so tests run whole frames headless. |
| `src/image_grid.zig` | `GridState` — the grid widget: the image list, selection, keyboard navigation, view reloads (`bg.Latest`) and rendering. |
| `src/view_query.zig` | What a view shows and how it loads, with no UI: view/search/sort types, `ImageEntry`, `ViewQuery`, `loadView`, FTS sanitising, relevance and sort order. Services and tests use it without the widget. |
| `src/thumb_loader.zig` | `ThumbLoader` — the grid's thumbnail cache (least recently shown evicted past 64 MB; freed entries hand their texture key back for the grid to invalidate) and loader threads (visible cells first; queue rebuilt each frame). A thumbnail that fails because its file was deleted outside the app removes the row (`noteLoadFailure`). |
| `src/grid_players.zig` | `PlayerPool` — grid autoplay: live players for on-screen animated/video cells, opened by a small thread pool. |
| `src/library_manager.zig` | `LibraryManager` — queues background `io` concurrent scans per library, proxies add/remove to the DB. |
| `src/scan.zig` | `LibraryScanner` — walks a directory tree, detects new/changed/removed images (mtime-first, hash on change), generates thumbnails via libvips, and optionally runs text/image embeddings. |
| `src/db.zig` | `VectorDb` — thin SQLite wrapper. Schema is append-only migration list. Embeds sqlite-vec for KNN vector search (768-dim float32). Supports soft-delete (trash) with 30-day auto-purge. `getConnection()` hands out per-thread handles sharing one pool. |
| `src/embedder.zig` | `Embedder` — all embeddings via TensorPencil: EmbeddingGemma 300M (prompts), SigLIP2 visual (images; a video by its first frame) and SigLIP2 text (visual queries). Batches route to CUDA/Vulkan at or above `embed_gpu_threshold`, single items to CPU. |
| `src/image_ops.zig` | `FileOps` (owned by `AppState`) — trash / delete / restore and the bulk ops (empty trash, dedupe) as jobs on one worker; `poll` applies results each frame. |
| `src/config.zig` | `Config` struct loaded/saved as JSON in the XDG config dir (saved via temp file + rename; an unparseable file loads as defaults, kept as `.bak`). |
| `src/counts.zig` | `CountsLoader` — sidebar/toolbar/settings counts (total, trash, duplicates, favorites, per library; DB stats on `requestStats`) loaded in the background, plus the settings' clear-cache ops (`clear`); `AppState.refreshCounts()` requests, `applyCounts()` shows. |
| `src/bg.zig` | Background-task building blocks: `Latest(T)` (a newer request supersedes older ones; only the newest result is taken — grid view loads, search query embeddings, detail panel) and `WorkQueue(Item)` (FIFO drained by up to N workers — library scans, watcher file workers, file ops, folder lists, count refreshes). Use these rather than hand-writing spawn/flag/poll code. |
| `src/folder_loader.zig` | `FolderLoader` — the sidebar's folder lists (`listImmediateSubdirs`) loaded on one background worker; `SidebarState.applyFolderResults` merges them into the tree, keeping its open folders. |
| `src/i18n.zig` | Compile-time string table (English only so far). |
| `src/app_icons.zig` | Vendored TVG icons. The `icons` package's heroicons/solid set is broken (stored as hollow strokes), so the favorite star lives in `src/icons/` instead. Don't use `icons.tvg.heroicons.solid.*`. |
| `src/fs_watch.zig` | File watcher: picks the backend (`fs_watch_linux.zig` inotify, `fs_watch_mac.zig` FSEvents, `fs_watch_windows.zig`); `fs_watch_common.zig` holds the shared `DirtyEvent` and `EventQueue`. Other-platform backends only type-check when referenced: `zig test -target x86_64-windows-gnu -fno-emit-bin src/fs_watch.zig` (and `aarch64-macos`). |
| `src/models.zig` | Shared data structs (`Library`, `Image`). |
| `src/parse/comfy.zig` | Parses ComfyUI workflow JSON embedded in PNG metadata (`tEXt` chunks). |
| `src/image/png-data.zig` | Low-level PNG chunk reader for extracting raw metadata bytes. |
| `src/vips.zig` | Thin Zig wrapper around libvips (via `lib/vips/vips_helper.c`) for thumbnail generation. `vips.init` sets one worker per vips operation (our own threads supply the parallelism; measured faster and leaner than the per-core default). |
| `src/sqlite.zig` | Low-level Zig bindings for the bundled SQLite + sqlite-vec C libraries. |
| `src/notifier.zig` | `ImageNotifier` — channel used by the scan/load worker threads to push new image IDs to `GridState` without blocking. |

### External dependencies (build.zig.zon)

- **dvui** — immediate-mode GUI framework, SDL3 backend
- **TensorPencil** (`../TensorPencil`, path dependency) — native-Zig embedding encoders
- **translate-c** — C header translation (replaces `@cImport` in Zig 0.17)
- **known-folders** — XDG/platform data/config path resolution
- **sqlite + sqlite-vec** — bundled in `lib/` as C source files

### Threading model

The render loop runs on the main thread and does no file or DB IO beyond small point queries. Background work, each waking the render loop via a custom SDL event (`g_wakeup_event_type`); new background work should use `bg.zig`'s `Latest` or `WorkQueue`:
1. `LibraryManager` dispatches `std.Io` concurrent tasks for library scans. Each scan produces thumbnail bytes and embeddings, then calls `ImageNotifier` to push new IDs. Watcher-reported new/changed files go to a queue drained by at most `max_file_workers` file workers.
2. `ThumbLoader` (the grid's) worker threads load thumbnails from disk/DB. A thumbnail that fails because its file was deleted outside the app removes the row (`noteLoadFailure`).
3. `GridState.reloadImages` loads a view (list + favorites + media types) as a background task on the grid's own connection (`view_db`); `update()` swaps in the newest result. Tests call `awaitReload()`.
4. `SearchState` (`search.zig`) embeds queries in the background (a `bg.Latest`: only the newest query's embedding is applied) and never touches the grid: `fire` / `takeEmbedded` return a `view_query.Search`, which `AppState` hands to `GridState.showSearch` (a grid load, through the same `view_query.loadView`). The grid copies what it is given.
5. `image_ops` runs every file operation — single-image trash/delete/restore and the bulk empty-trash / dedupe — as jobs on one worker thread, so they never race each other.
6. `LibraryManager.flushFileEvents` removes rows for watcher-reported deletions in one background transaction; `removeLibrary` stops the library's scan and deletes its rows and trashed files in the background. Both report removed ids through `drainRemovedIds`.
7. `counts.zig` (`CountsLoader`, also the settings' DB stats and cache clearing), `folder_loader.zig` (sidebar folder lists), the detail panel (`DetailState`) and the filter dialog's options load in the background; the viewer decodes images on an `std.Io.Group` and opens video/animation players with a `bg.Latest`. Copy-image reads the file on a background task at copy time. UI widgets never query the DB: a widget that loads holds the `VectorDb` (set once by `AppState`) only to open its loader's own connection.
   Not on `bg.zig`, on purpose: the video player's decode/audio loops, the file watchers and the X11 drag watcher (long-running loops), the thumbnail loader and grid player openers (a visible-first queue rebuilt each frame), model downloads (detached, so quitting doesn't wait on curl), and the embedder load (one at a time, the newest waiting request wins: never two models' weights loading at once).
8. The embedder is freed only after `AppState.releaseEmbedder` has awaited every user of it (`SearchState.awaitEmbed`, `LibraryManager.quiesce`).

### Database schema

Append-only migration list in `db.zig:migrations`. Tables: `libraries`, `images` (full PNG parse metadata + optional BLOB thumbnail), `image_embeddings` (vec0, 768-dim), `positive_prompt_embeddings` (vec0, 768-dim). Soft-delete via `trashed_at`/`trash_name`/`trash_file_size` columns. A (library, path) has at most one live row (partial unique index `idx_images_live_path`, v14; trashed rows are exempt, so a new file may reuse a trashed image's path). Destructive row operations (`trashImage`, `restoreImage`, `deleteImage`, `setFavorite`) and embedding stores match the id AND the path the caller saw, since ids are recycled and a grid/viewer entry can outlive its row; they return whether a row matched. Library paths are stored without a trailing separator, and overlapping libraries are refused. Folder filters use the range `path >= 'f/' AND path < 'f0'`, never `LIKE`. vec0 tables take no foreign keys: trigger `images_embeddings_ad` (v12) deletes an image's embeddings with its row, since ids are recycled. Rows whose file was deleted outside the app are removed by the scan, the fs watcher, or the grid loader on a failed thumbnail load (`ThumbLoader.noteLoadFailure`; only when the file's directory still exists).

### Search architecture

Four modes (`view_query.zig:SearchMode`): FTS5 full-text, semantic prompt KNN (EmbeddingGemma 300M), visual KNN (SigLIP2 ViT-B-16, text→image), and combined (RRF merge of both KNNs, k = 60 — one query embedding **per space**, they are not interchangeable). All encoders run in TensorPencil (`embedder.zig`), which also owns the tokenizers.

Conventions that matter for quality — breaking any of these silently degrades search:
- KNN queries MUST use the vec0 fast path: `WHERE vector MATCH ? AND k = ?` (optionally `AND rowid IN (...)`) — never `ORDER BY vec_distance_*()`, which falls back to a per-row full scan.
- Vectors are L2-normalized; the vec0 tables use the default L2 metric, so ranking equals cosine and `sim = 1 - d²/2` recovers cosine similarity.
- Prompt documents are cleaned via `parse/prompt_clean.zig` (drops `<lora:…>`-style tags, unwraps weights and `(…)` / `[…]` / `<(…):w>` groups) and embedded with the `title: none | text: ` prefix; queries get `task: search result | query: ` (use `embedPromptQuery`, not `embedPrompt`). TensorPencil applies both prefixes. A prompt over the encoder's window is split on token boundaries into at most 8 window-sized chunks, embedded (on the GPU when there is one) and averaged (`embedPrompt` → `embedPromptChunked`); text past 8 chunks is left to FTS.
- Visual queries go through the SigLIP2 text encoder with no prefix (`embedQueryForVisual`).
- Every mode is narrowed the same way by the selected library/folder and the filter chips (`db.Scope`: `appendScopeWhere` / `bindScope`), and filters come BEFORE ranking: vector searches pass the trash and the scope into the KNN as `rowid IN (SELECT ...)`, which sqlite-vec applies inside its scan, so the k nearest are the k nearest that qualify.
- KNN hits below the per-space min-similarity thresholds (config: `semantic_min_similarity` / `visual_min_similarity`) are dropped so the grid isn't padded with the top-k tail.

Encoder evaluation: `zig build bench_embed -Doptimize=ReleaseFast -- --corpus FILE [--speed]` (`src/bench_embed.zig`) A/Bs the current encoders against EmbeddingGemma 2 on labeled corpora (`bench/images32.json`; corpus format in the file header). Result (Oct 2026, 300-image hand-labeled library slice, 50 queries): Gemma 2 image search tied SigLIP2 (MRR 0.990 vs 0.980) but its prompt search was clearly worse than EmbeddingGemma 300M (0.82 vs 0.96), and all-Gemma 2 combined search lost to the current RRF combo (0.95 vs 0.98) while indexing images ~1.7x slower. Not adopted. Untested: Gemma 2's mixed text+image input (one vector from prompt + pixels), which TensorPencil doesn't support yet.
