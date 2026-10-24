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

# Dev/research tools (data pipeline, not part of the GUI)
zig build parse_threads -- /path/to/dir   # concurrent PNG metadata parsing
zig build test_embed -- model.gguf        # test text embedding generation
zig build test_vl_embed -- model.gguf img.png  # test VL image embedding
zig build test_cross_modal -- model.gguf  # evaluate text→image search quality
zig build test_search_quality             # evaluate embedding search quality

# Pass --config / -c <dir> to use <dir>/DiffKeep.cfg. The DB stays at the XDG data dir
# unless that config sets data_path (the DB file path) — set it for throwaway runs.
zig build run -- --config /path/to/data/dir
```

## Architecture Overview

DiffKeep is a desktop image-library manager for AI-generated images, built with Zig 0.17 + [dvui](https://github.com/david-vanderson/dvui) (SDL3 backend). Its three main jobs are: (1) scan folder libraries and parse ComfyUI/PNG metadata, (2) store metadata + embeddings in SQLite, and (3) present a resizable 3-pane GUI.

### Key modules

| File | Role |
|---|---|
| `src/app.zig` | Entry point. Owns all global state (`g_grid`, `g_db`, `g_library_manager`, `g_cfg`). Wires together dvui callbacks (`appInit`/`frame`/`appDeinit`) and renders the toolbar, left sidebar, center grid, right metadata panel, and status bar. |
| `src/image_grid.zig` | `GridState` — renders the thumbnail grid, manages a background worker thread for JPEG loading, handles keyboard navigation and multi-select. Uses `ImageNotifier` to wake the render loop from the worker. |
| `src/library_manager.zig` | `LibraryManager` — queues background `io` concurrent scans per library, proxies add/remove to the DB. |
| `src/scan.zig` | `LibraryScanner` — walks a directory tree, detects new/changed/removed images (mtime-first, hash on change), generates thumbnails via libvips, and optionally runs text/image embeddings. |
| `src/db.zig` | `VectorDb` — thin SQLite wrapper. Schema is append-only migration list. Embeds sqlite-vec for KNN vector search (768-dim float32). Supports soft-delete (trash) with 30-day auto-purge. `getConnection()` hands out per-thread handles sharing one pool. |
| `src/embedder.zig` | `Embedder` — all embeddings via TensorPencil: EmbeddingGemma 300M (prompts), SigLIP2 visual (images) and SigLIP2 text (visual queries). Batches route to CUDA/Vulkan at or above `embed_gpu_threshold`, single items to CPU. |
| `src/image_ops.zig` | Trash / delete / restore and bulk ops (empty trash, dedupe), all on background threads; `fileOpsPoll` / `bulkPoll` apply results each frame. |
| `src/config.zig` | `Config` struct loaded/saved as JSON in the XDG config dir. |
| `src/i18n.zig` | Compile-time string table (English only so far). |
| `src/models.zig` | Shared data structs (`Library`, `Image`). |
| `src/parse/comfy.zig` | Parses ComfyUI workflow JSON embedded in PNG metadata (`tEXt` chunks). |
| `src/image/png-data.zig` | Low-level PNG chunk reader for extracting raw metadata bytes. |
| `src/vips.zig` | Thin Zig wrapper around libvips (via `lib/vips/vips_helper.c`) for thumbnail generation. |
| `src/llama.zig` / `src/mtmd.zig` | llama.cpp wrappers used only by the older research tools (`test_embed`, `test_vl_embed`, …), not by the app. |
| `src/sqlite.zig` | Low-level Zig bindings for the bundled SQLite + sqlite-vec C libraries. |
| `src/notifier.zig` | `ImageNotifier` — channel used by the scan/load worker threads to push new image IDs to `GridState` without blocking. |

### External dependencies (build.zig.zon)

- **dvui** — immediate-mode GUI framework, SDL3 backend
- **TensorPencil** (`../TensorPencil`, path dependency) — native-Zig embedding encoders
- **translate-c** — C header translation (replaces `@cImport` in Zig 0.17)
- **llama.cpp b9048** — research tools only
- **known-folders** — XDG/platform data/config path resolution
- **sqlite + sqlite-vec** — bundled in `lib/` as C source files

### Threading model

The render loop runs on the main thread and does no file or DB IO beyond small point queries. Background work, each waking the render loop via a custom SDL event (`g_wakeup_event_type`):
1. `LibraryManager` dispatches `std.Io` concurrent tasks for library scans. Each scan produces thumbnail bytes and embeddings, then calls `ImageNotifier` to push new IDs.
2. `GridState` worker threads load thumbnails from disk/DB. A thumbnail that fails because its file was deleted outside the app removes the row (`noteLoadFailure`).
3. `GridState.reloadImages` loads a view (list + favorites + media types) as a background task; `update()` swaps in the newest result. Tests call `awaitReload()`.
4. `SearchState` (`search.zig`) embeds queries and runs searches as background tasks, through the same `image_grid.loadView`.
5. `image_ops` runs file operations on its own worker threads.

### Database schema

Append-only migration list in `db.zig:migrations`. Tables: `libraries`, `images` (full PNG parse metadata + optional BLOB thumbnail), `image_embeddings` (vec0, 768-dim), `positive_prompt_embeddings` (vec0, 768-dim). Soft-delete via `trashed_at`/`trash_name`/`file_size_bytes` columns. vec0 tables take no foreign keys: trigger `images_embeddings_ad` (v12) deletes an image's embeddings with its row, since ids are recycled. Rows whose file was deleted outside the app are removed by the scan, the fs watcher, or the grid loader on a failed thumbnail load (`GridState.noteLoadFailure`; only when the file's directory still exists).

### Search architecture

Four modes (`image_grid.zig:SearchMode`): FTS5 full-text, semantic prompt KNN (EmbeddingGemma 300M), visual KNN (SigLIP2 ViT-B-16, text→image), and combined (RRF merge of both KNNs, k = 60 — one query embedding **per space**, they are not interchangeable). All encoders run in TensorPencil (`embedder.zig`), which also owns the tokenizers.

Conventions that matter for quality — breaking any of these silently degrades search:
- KNN queries MUST use the vec0 fast path: `WHERE vector MATCH ? AND k = ?` — never `ORDER BY vec_distance_*()`, which falls back to a per-row full scan.
- Vectors are L2-normalized; the vec0 tables use the default L2 metric, so ranking equals cosine and `sim = 1 - d²/2` recovers cosine similarity.
- Prompt documents are cleaned via `parse/prompt_clean.zig` (drops `<lora:…>`-style tags, unwraps weights and `(…)` / `[…]` / `<(…):w>` groups) and embedded with the `title: none | text: ` prefix; queries get `task: search result | query: ` (use `embedPromptQuery`, not `embedPrompt`). TensorPencil applies both prefixes. Prompts over the encoder's 512-token window are skipped, not truncated.
- Visual queries go through the SigLIP2 text encoder with no prefix (`embedQueryForVisual`).
- KNN hits below the per-space min-similarity thresholds (config: `semantic_min_similarity` / `visual_min_similarity`) are dropped so the grid isn't padded with the top-k tail.

Encoder evaluation: `zig build bench_embed -Doptimize=ReleaseFast -- --corpus FILE [--speed]` (`src/bench_embed.zig`) A/Bs the current encoders against EmbeddingGemma 2 on labeled corpora (`bench/images32.json`; corpus format in the file header). Result (Oct 2026, 300-image hand-labeled library slice, 50 queries): Gemma 2 image search tied SigLIP2 (MRR 0.990 vs 0.980) but its prompt search was clearly worse than EmbeddingGemma 300M (0.82 vs 0.96), and all-Gemma 2 combined search lost to the current RRF combo (0.95 vs 0.98) while indexing images ~1.7x slower. Not adopted. Untested: Gemma 2's mixed text+image input (one vector from prompt + pixels), which TensorPencil doesn't support yet.
